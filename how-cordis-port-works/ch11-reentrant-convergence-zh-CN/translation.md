# 第 11 章：重入纪元收敛

对响应式生命周期的真正考验，在于它如何处理快速、重叠的变更。如果在一个插件正试图启动的中途，它脚下的基础环境发生了改变，会发生什么？

考虑以下场景：
1. 一个提供者（**Provider**）开始异步加载。
2. 一个依赖于该提供者的消费者（**Consumer**）开始异步加载。
3. 在消费者完成加载之前，提供者更新了它的配置，迫使提供者重新加载并发出一个新的依赖值。

这就是**重入纪元动荡（reentrant epoch churn）**。消费者正忙于加载*旧的*配置，但*新的*配置已经到达了。

## 追逐纪元

Cordis 使用**纪元（Epochs）**来管理这种混乱。纪元是一个字符串，代表一个 Fiber 依赖项的当前状态。每当依赖项发生变化时，Fiber 的纪元就会更新。

当一个 Fiber 开始异步重载时，它会记住它开始时的纪元（`old-epoch`）。由于惯性锁的存在，在重载期间到达的任何新更新都不会中断正在运行的任务。任务会被允许完成。

然而，当任务完成时，`fiber-complete-reload` 会执行一项关键检查：

```rebol
fiber-complete-reload: func [fb [object!] old-epoch [string!] result /local pending] [
    ; ...
    either equal? fb/epoch old-epoch [
        fiber-update-state fb fiber-state/ACTIVE
        pending: false
    ][
        fiber-update-state fb fiber-state/UNLOADING
        pending: fiber-unload fb
    ]
    ; ...
]
```

如果 `fb/epoch`（当前纪元）不等于 `old-epoch`（我们开始时的纪元），这意味着世界在我们加载时发生了变化。Fiber 意识到它刚刚加载的状态已经过时了。它拒绝变为 `ACTIVE`。相反，它立即过渡到 `UNLOADING` 以拆除过时状态，然后循环回到 `LOADING` 以追逐新的纪元。

## 动手实验：在动荡中幸存

运行本章的场景：

```bash
cd ch11-reentrant-convergence/code
bash run.sh
```

在这个测试中，我们在消费者仍处于挂起/加载状态时，故意更新了提供者的配置。

1. `t=1000`：提供者完成了其初始加载。消费者被激活并看到了初始值（`[1 "old"]`）。
2. 我们立即更新提供者和消费者。提供者重新进入 `LOADING`。消费者回退到 `PENDING`，因为它的依赖项正在发生动荡。
3. 当提供者仍不稳定时，系统不会急于重新运行消费者。
4. `t=2000`：提供者带着新配置收敛到 `ACTIVE` 状态。消费者终于被激活并看到了最终值（`[2 "new"]`）。

系统无缝地跳过了中间不稳定的状态，并收敛于最终的真相。巧思（surprise）正隐藏在这种通过纪元比对跳过无效计算的设计中。

## 对照真源

| Rebol 移植版 | 上游 Cordis (TypeScript) | 差异原因 |
| --- | --- | --- |
| `fb/epoch` 对比 `old-epoch` | `if (this.epoch !== epoch) return this.inertia = this._unload()` | 相同的语义机制：将起始纪元与当前纪元进行比较，以检测重入动荡并强制收敛。 |
| 副作用清理函数去重 | `map.delete(sn)` / `map.set` | 上游使用唯一的 Symbol 键或闭包。Rebol 需要显式的去重逻辑（`fiber-has-disposable?`），以防止异步重载循环对同一个副作用包装器进行重复注册。 |