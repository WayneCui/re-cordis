# 第 02 章 没有可变参数的事件系统

Cordis 的事件系统在调用端看起来非常简单。你只需调用 `on`、`once`、`emit`、`bail` 或 `waterfall`，框架就会处理好剩下的所有事情。在 TypeScript 中，这种简单性建立在两个便利特性之上：可变参数（variadic arguments）和隐式的 `this` 绑定。然而，Rebol 并没有为这个移植版提供相同形式的这两项便利，因此 `events.reb` 必须回答一个直击本质的问题：在保留 Cordis 行为的前提下，最小的事件模型是什么样的？

答案并非“完全照搬旧的 API”，而是“保留五种分发模式，但将负载（payloads）打包进区块（blocks）中，并将监听器转化为显式对象”。这一设计同时化解了多个宿主语言层面的冲突。移植版不再需要处理任意可变参数的解码，也不再将原始的 `function!` 值存储在 Rebol 可能会自动求值的映射表中。监听器变成了一个 `object! [call: func [...]]`，而负载则整合为一个单一的 `block!`。

## 钩子列表比语法糖更重要

最直接的移植思路往往会先关注语法：我们该如何模拟 `emit(name, ...args)`？但 `events.reb` 选择了相反的路径。它优先保留钩子（hook）的结构和分发语义，然后允许调用形式发生改变。`emit`、`parallel`、`serial`、`bail` 和 `waterfall` 的第一步全都是通过 `resolve-callbacks` 解析回调函数。这一步才是整个文件真正的核心：它决定了在当前过滤器下哪些钩子是可见的，以及是否应该触发内部的分发事件。

这一选择最终被证明与我们在第 01 章中看到的架构设计决策如出一辙。移植版保留了底层机制，剥离了宿主语言的华丽修饰。`thisArg` 不再是一个充满魔力的接收者，而是变成了一个在调用链中向下传递的显式对象。用于 `internal-update` 的内部监听器簿记工作不再隐藏于函数闭包内，而是通过 `register` 被直接安置在 `fiber/hooks`（Fiber 的钩子）中。

`waterfall` 是最能体现这种方法可靠性的地方。Rebol 版本没有依赖嵌套的 JS 闭包，而是构建了一个 `next` 包装器对象，其 `call` 方法要么调用下一个回调，要么执行内部的回退逻辑。其代码呈现比 TypeScript 版本更具机械感，但这种机械本质恰恰是它具备可移植性的原因所在。

## 总结

你可以把这个移植版中的 `EventsService` 想象成一个带有标签信封的电话交换机，而不是一个函数调用蹦床。每个事件负载作为一个单一的区块进行传递，每个监听器都是一个带有 `call` 槽位的可调用对象，而每种分发模式则决定了下一个信封何时被允许进入线路。常见的误解是，既然语法变了，移植版就变得“没那么 Cordis”了。但实际上真正留存下来的是更为重要的层面：钩子的可见性、短路规则，以及与 Fiber 作用域绑定的清理机制。自我检查：如果一个用于 `internal-update` 的监听器不是全局的，那么移植版将它存储在了哪里，从而保证在卸载插件时可以自动将其移除？

---

## 实验

```bash
cd ch02-events-hooks/code
bash run.sh
```

预期输出：

```text
PASS  parallel aggregates two errors
PASS  serial returns the first bailed value
PASS  waterfall composes to 4
==== events-test: 15 passed, 0 failed ====
```

### 尝试一下

1. 在 `../../events.reb` 中，修改 `is-bailed` 使得 `false` 也算作一个有效结果，然后重新运行实验，观察 `bail` 是如何过早停止的。
2. 移除 `waterfall` 中的 `append args next` 步骤，观察调用链是如何失去其延续性的。
3. 在 `../../test/events-test.reb` 中添加一个新的监听器，让它把自己前置（prepend），并通过一个微型计数器列表来确认执行顺序。

### 源码对比

| 路径 | 符号 |
|------|--------|
| `events.reb` | `make-events-service`, `resolve-callbacks`, `emit`, `waterfall`, `register` |
| `ref/core/events.ts` | `EventsService._resolve`, `parallel()`, `bail()`, `waterfall()` |

表面语法虽然不同，但分发模式和生命周期耦合依然保持着纯正的 Cordis 风格。