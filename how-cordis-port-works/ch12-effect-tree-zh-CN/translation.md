# 第 12 章：副作用树可视化

在前面的章节中，我们严重依赖于 `fiber/disposables`。当一个 Fiber 卸载时，它会反向遍历这个列表并执行清理函数。但是，随着插件注入其他插件，以及插件注册事件和提供服务，这个扁平的列表实际上代表了一个深刻的、具有层级关系的所属权树。

为了真正理解 Cordis 的生命周期，我们需要能够看到这棵树。

## 可视化所属权

每次你调用诸如 `ctx.on`、`ctx.provide` 或 `ctx.plugin` 的 API 时，就会创建一个**副作用（Effect）**。在我们的移植版中，这些副作用是包含一个 `meta` 字段的包装器对象。

```rebol
meta: make object! [
    label: none
    owner: none
    disposed: false
    dispose-reason: none
    children: copy []
]
```

至关重要的是，一个副作用可以拥有一个子 Fiber。当你调用 `ctx.plugin()` 时，注册在父 Fiber 上的副作用将负责管理新创建的子插件 Fiber 的生命周期。

我们构建了一个检查器（`inspector.reb`）来递归遍历这种关系：Fiber -> Disposables (Effects) -> 子 Fibers。

## 动手实验：导出树结构

运行本章的场景：

```bash
cd ch12-effect-tree/code
bash run.sh
```

检查器遍历运行时并打印出当前的挂载层级结构：

```text
root#0 (ACTIVE)
└── [Effect] ctx.plugin()
    └── consumer#1 (ACTIVE)
        ├── [Effect] ctx.on(ping)
        └── [Effect] ctx.provide(foo)
```

这个简单的 ASCII 输出对于调试来说无比强大。它在视觉上证明了：
1. `root` Fiber 拥有一个标签为 `ctx.plugin()` 的副作用。
2. 该副作用拥有 `consumer#1` Fiber。
3. `consumer#1` Fiber 拥有两个副作用：一个事件监听器（`ctx.on(ping)`）和一个服务提供者（`ctx.provide(foo)`）。

如果 `consumer#1` 失败或被卸载，这棵树清楚地表明它的两个子副作用必须被销毁。

## 受信任的实验平台

随着确定性调度器、失败恢复、重入收敛以及副作用树可视化功能的就位，我们的 Rebol 移植版已经成功复制了 Cordis 生命周期中最深层的复杂性。我们现在拥有了一个受信任的、隔离的且高度可观测的平台，可以用于尝试各种插件架构。

## 对照真源

| Rebol 移植版 | 上游 Cordis (TypeScript) | 差异原因 |
| --- | --- | --- |
| `dump-effect-tree` | 上游无直接等价物 | 专门为该移植版构建，以提供生命周期正确挂载和清理的视觉证明，帮助在缺乏原生 JS 内存管理的情况下进行调试。 |
| `meta` 包装器 | 闭包作用域（Closure scope） | 上游 Cordis 依赖 JS 垃圾回收和闭包作用域来隐式跟踪副作用的所属权。移植版将其具象化为显式的 `meta` 数据结构以便于遍历。 |