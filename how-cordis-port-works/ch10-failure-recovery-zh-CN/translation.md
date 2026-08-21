# 第 10 章：异步失败与恢复

一个健壮的框架必须预见到失败。当一个插件同步应用（apply）并抛出错误时，失败是立即发生的。但是，如果一个插件在生命周期的中途异步抛出错误，会发生什么呢？

在 Cordis 中，在异步 `_reload` 阶段失败的 Fiber（**Fiber**，灵魂所在，代表插件在运行时的生命周期状态机）会过渡到一个特殊的 `FAILED` 状态。更重要的是，它必须一丝不苟地清理在失败发生之前注册的任何副作用。

## 部分应用的危险

想象一个异步插件，在它的 `apply` 函数开始时同步注册了一个事件监听器，但随后调度了一个最终会失败的异步任务：

```rebol
apply: func [ctx [object!] config] [
    ctx/events/on 'ping listener make map! [] ctx
    
    make object! [
        task-kind: 'scheduled
        delay: 1000
        run: func [] [print undefined-async-fail] ; 这里会崩溃
    ]
]
```

当这个插件在 `t=1000` 失败时，`ping` 监听器已经是活跃的。如果框架仅仅将插件标记为 `FAILED` 然后撒手不管，触发 `ping` 事件就会唤起一个属于已损坏插件的监听器，很可能会导致级联故障。

## 清理与 FAILED 状态

为了防止这种情况，Fiber 状态机会在 `fiber-complete-reload` 中捕获异步错误。它将状态更新为 `FAILED` 并立即触发 `fiber-unload`。

```rebol
fiber-complete-reload: func [fb [object!] old-epoch [string!] result /local pending] [
    either error? result [
        fb/ctx/logger/error result
        fb/error: result
        fb/epoch: inactive-epoch
        fiber-update-state fb fiber-state/FAILED
        pending: fiber-unload fb
    ]
    ; ...
]
```

`fiber-unload` 过程会反向遍历 `disposables` 列表，为崩溃前注册的每一个副作用（比如我们的 `ping` 监听器）执行清理函数。

## 恢复之路

处于 `FAILED` 状态的 Fiber 并没有永久死亡。如果用户纠正了配置并调用 `update`，Fiber 就会获得第二次机会。

```rebol
fiber-update: func [fb [object!] config no-save [logic!] /local final-w] [
    ; ...
    target-fb/config: args/1
    target-fb/error: none
    fiber-restart target-fb
]
```

错误被清除，纪元（epoch）被重置，Fiber 过渡回 `LOADING`。如果新配置解决了问题，Fiber 将成功达到 `ACTIVE` 状态。

## 动手实验：失败与恢复

运行本章的场景：

```bash
cd ch10-failure-recovery/code
bash run.sh
```

密切观察追踪输出：
1. 插件开始 `LOADING` 并注册 `ctx.on(ping)`。
2. 在 `t=1000`，异步任务崩溃。
3. 框架捕获错误，将状态设置为 `FAILED`，并且至关重要的是，以 `reason="unload"` 为由执行了 `ping` 监听器的 `effect.dispose`。
4. 当我们触发 `ping` 时，监听器没有被唤起（`hits-after-fail=0`）。
5. 我们将配置更新为 `fail: false`。插件重新进入 `LOADING`，执行成功，并变为 `ACTIVE`。
6. 现在触发 `ping` 成功唤起了监听器（`hits-after-recovery=1`）。

## 对照真源

| Rebol 移植版 | 上游 Cordis (TypeScript) | 差异原因 |
| --- | --- | --- |
| `fiber-complete-reload` 的错误分支 | `_reload` 中的 `catch (e)` | 上游在被 `await` 的 Promise 周围使用 `try/catch`。Rebol 在评估 `run-scheduled-task` 的 `try` 块中同步处理错误结果。 |
| 失败时调用 `fiber-unload` | `this._unload()` | 相同的语义设计：失败的重载必须触发完全卸载以回收资源。 |