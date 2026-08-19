# 第 8 章：一个检验移植版的微型应用

在经历了七章关于内部机制的探讨之后，唯一公道的问题是：当你实际尝试使用这个移植版时，它用起来还像 Cordis 吗？`examples/greeter.reb` 这个例子虽然很小，但绝不是个摆设。它涵盖了本书一直在构建的路径：创建一个上下文，注册一个类似 Provider（**解释：服务的提供者，用于在上下文中注册和提供功能实现**） 的插件，注入一个依赖插件，触发一个事件，更新配置，销毁运行时，然后在隔离的房间内重复这个思路。

这个例子之所以能奏效，是因为早期的那些简化都是“外科手术式”的精准裁剪，而非随意的乱砍。这个应用不需要 `Proxy` 字段拦截也能实现响应式。它需要的是 `reflect/provide`、`registry/plugin`、作用域限定在**Fiber**（Fiber）的副作用，以及在销毁时会自动消失的事件钩子。因此，这个例子成为了本书论点的一个极佳的集成测试：如果在正确的地方对内部机制进行了简化，那么在应用层面讲出来的故事依然应该自然流畅。这是一个真正的巧思（surprise）。

## 是组装，而不是变魔术

`examples/greeter.reb` 中的 Provider（**解释：服务的提供者，用于在上下文中注册和提供功能实现**） 插件通过 `make-service` 注册了一个名为 `greeter` 的服务。作为 Consumer（**解释：服务的消费者，用于声明对特定服务的依赖并使用它们**） 的依赖插件 `receptionist` 注入了 `greeter`，订阅了 `guest-arrived` 事件，并使用了一个作用域在**Fiber**内的副作用，以便在销毁时能干净利落地关闭接待台。随后，该例子将 Provider 的配置从 `"Hello"` 更新为 `"Hi"`，并让运行时展示这意味着什么：Provider 卸载、Consumer 挂起或重新加载，然后在新纪元（epoch）下输出新的结果。

第二个场景证明了“隔离（isolation）”不仅仅是停留在某一个章节里的概念。三个上下文在不同的房间下注册了同一个 `iso-guest` 插件。每个房间都在等待属于它自己的 `greeter` Provider 出现。这就是整个移植版的缩影：响应式的启动条件、显式的所有权，以及感知隔离区的可见性。

这个例子最棒的地方在于，它不需要读者盲目地相信这些抽象。它会直接打印出正在发生的事情。一个能够在正确的时机说出 "greeter-up"、"served:Hi Ada" 和 "desk-closed" 的微型系统，通常比又一篇架构总结能教会你更多的东西。

---

## 实验

```bash
cd ch08-greeter-app/code
bash run.sh
```

预期输出：

```text
=== scene 1: greeter + receptionist ===
greeter-up Hello
served:Hello Ada
--- update prefix Hello -> Hi ---
served:Hi Ada
=== scene 2: isolate rooms ===
all pending (no greeter yet)
```

### 动手尝试

1. 在 `../../examples/greeter.reb` 中，移除 `receptionist` 中的 `inject: ['greeter]` 声明，观察该例子如何不再清晰地表达依赖契约。
2. 给 `ctx-a` 和 `ctx-b` 赋予相同的显式隔离标签（isolate label），并将此时的房间启动顺序与当前私有房间的行为进行对比。
3. 在 `receptionist` 下再添加一个事件监听器，并确认当插件的**Fiber**关闭时，销毁操作会同时移除这两个监听器。

### 源码对照

| 路径 | 符号 |
|------|--------|
| `examples/greeter.reb` | `greeter-plugin`, `receptionist`, `iso-guest` |
| `context.reb` | `make-context`, `isolate` |
| `registry.reb` | `plugin` |
| `fiber.reb` | `update`, `dispose` |

在前面章节中看似各自为战的机制，现在已经汇聚成了一个连贯的运行时循环。