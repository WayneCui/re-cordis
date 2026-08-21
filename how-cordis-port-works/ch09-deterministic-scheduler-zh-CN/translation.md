# 第 09 章：确定性异步模拟

Cordis 严重依赖异步边界。当插件提供服务（**Provider**，提供者，即向整个框架注册特定功能或数据的插件）或返回异步清理函数（disposer）时，框架会使用 Promise 来协调生命周期的各个阶段。在 JavaScript 中，`await Promise.resolve()` 会将控制权交还给事件循环，允许在当前执行恢复之前处理其他同步事件。这自然会产生“惯性锁（inertia locks）”：如果某个依赖项在一个插件仍在加载时消失，该插件不会立即卸载。它会完成其加载阶段，然后才评估新的世界状态。

Rebol 3 没有原生的事件循环或微任务队列。如果我们想要研究 Cordis 的异步收敛行为（例如惯性锁），我们需要一种确定性的方法来模拟时间和任务。

## 构建虚拟调度器

我们没有挂钩到真实的系统时间或线程，而是构建了一个虚拟任务调度器（`deterministic-scheduler.reb`）。它维护一个按目标执行时间排序的优先级任务队列。

当需要发生异步操作时（例如模拟异步加载或延迟卸载），我们不会阻塞进程。相反，我们会注册一个调度任务：

```rebol
make-scheduled-value: func [delay [integer!] value /local task] [
    task: make object! [
        task-kind: 'scheduled
        delay: delay
        payload: value
        run: func [] [payload]
    ]
    task
]
```

为了让时间向前推进，我们调用 `runtime-step`，它会推进虚拟时钟并执行落入该时间窗口内的任何任务。这为我们提供了对执行顺序的完全、确定性的控制，确保我们的测试是完全可重复的。

## 复现惯性锁

让我们来看看经典的“惯性锁 1”场景（`m1-inertia-lock-1.reb`）。我们创建一个需要 1000 毫秒才能加载的异步消费者（**Consumer**，消费者，即依赖并使用其他插件提供的服务的插件）。

```rebol
make-async-consumer: func [delay-load [integer!] delay-unload [integer!]] [
    make object! [
        name: "async-consumer"
        inject: ['foo]
        load-delay: delay-load
        unload-delay: delay-unload
        apply: func [ctx [object!] config] [
            make-scheduled-value load-delay make-async-disposer unload-delay
        ]
    ]
]
```

我们提供 `foo` 依赖项并启动消费者。消费者进入 `LOADING` 状态并调度一个 1000 毫秒后的加载任务。

在 400 毫秒时，当消费者仍在加载时，我们突然销毁了 `foo` 依赖项！

会发生什么？消费者不会立即中止或崩溃。它受到惯性锁的保护。它停留在 `LOADING` 状态，直到 1000 毫秒的任务完成。一旦它完成加载，它就会意识到其依赖项已消失，并过渡到 `UNLOADING` 状态。

## 动手实验：观察收敛过程

运行本章的测试来追踪惯性锁：

```bash
cd ch09-deterministic-scheduler/code
bash run.sh
```

你将密切观察反映状态变化的追踪快照：

```text
t0=LOADING
t400=LOADING       # 400ms：依赖项被移除，仍在加载！
t800=LOADING       # 800ms：仍在加载！
t1200=UNLOADING    # 1000ms：加载完成，意识到依赖项缺失，开始卸载
t2200=LOADING      # 依赖项再次被提供，开始重新加载
t3200=ACTIVE       # 完全加载
```

通过将异步执行与真实时间解耦，我们构建了一个受信任的平台，用于研究 Cordis 最复杂的生命周期行为。

## 对照真源

| Rebol 移植版 | 上游 Cordis (TypeScript) | 差异原因 |
| --- | --- | --- |
| `make-deterministic-scheduler` | `setTimeout`, `Promise` | Rebol 缺乏原生的事件循环，需要手动步进虚拟时间来模拟异步锁。 |
| `runtime-step` | `vi.advanceTimersByTimeAsync` | 我们显式地控制时钟滴答，而不是依赖 Vitest 的假定时器。 |
| `fiber.inertia` (logic flag) | `fiber.inertia` (Promise) | Cordis `await` 惯性 Promise。移植版使用同步的布尔锁，并将延续（continuation）推迟到调度器。 |