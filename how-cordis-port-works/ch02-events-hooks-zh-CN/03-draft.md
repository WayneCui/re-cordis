# 第 02 章 没有可变参数的事件系统

Cordis 事件在调用端看起来非常简单。你只需要调用 `on`、`once`、`emit`、`bail` 或 `waterfall`，框架会处理剩下的所有事情。在 TypeScript 中，这种简单性依赖于两个便利特性：可变参数（variadic arguments）和隐式的 `this` 绑定。Rebol 没有为这个移植版提供相同形式的这两种便利，因此 `events.reb` 必须回答一个精确的问题：在保留 Cordis 行为的前提下，最小的事件模型是什么样的？

答案并不是“完全照搬旧的 API”。答案是“保留五种分发模式，但将负载（payloads）打包进区块（blocks）中，并将监听器变为显式的对象”。这一个举动立刻消除了好几个宿主语言层面的冲突。移植版不再需要进行任意的可变参数解码，也不再将原始的 `function!` 值存储在 Rebol 可能会自动对其求值的映射表中。一个监听器变成了一个 `object! [call: func [...]]`，而负载变成了一个单一的 `block!`。

## 钩子列表比语法糖更重要

朴素的移植版会首先关注语法：我们如何模拟 `emit(name, ...args)`？`events.reb` 则反其道而行之。它保留了钩子（hook）的结构和分发语义，然后允许调用的形式发生改变。`emit`、`parallel`、`serial`、`bail` 和 `waterfall` 全部从通过 `resolve-callbacks` 解析回调函数开始。这一步才是这个文件真正的核心。它决定了在当前过滤器下哪些钩子是可见的，以及是否应该触发内部的分发事件。

这个选择最终被证明与我们在第 01 章中看到的架构设计决策如出一辙。移植版保留了底层机制，放弃了宿主语言的华丽修饰。`thisArg` 不再是一个神奇的接收者；它是一个在调用链中向下传递的显式对象。用于 `internal-update` 的内部监听器簿记工作不再隐藏在函数闭包内；它通过 `register` 安置在 `fiber/hooks`（Fiber/钩子）中。

`waterfall` 是最能体现这种方法可靠性的地方。Rebol 版本没有依赖嵌套的 JS 闭包，而是构建了一个 `next` 包装器对象，其 `call` 方法要么调用下一个回调，要么调用内部的回退逻辑。结果读起来比 TypeScript 版本更具机械感，但这种机械本质恰恰是它具备可移植性的原因。

## 总结

可以把这个移植版中的 `EventsService` 想象成一个带有标签信封的电话交换机，而不是一个函数调用蹦床。每个事件负载作为一个单一的区块进行传递，每个监听器都是一个带有 `call` 槽位的可调用对象，而每种分发模式决定了下一个信封何时被允许进入线路。常见的误解是，因为语法变了，移植版变得“没那么 Cordis”了。但实际上留存下来的是更重要的层面：钩子的可见性、短路规则，以及与 Fiber 作用域绑定的清理机制。自我检查：如果一个用于 `internal-update` 的监听器不是全局的，那么移植版将它存储在哪里，以便插件卸载时可以自动移除它？

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

1. 在 `../../events.reb` 中，修改 `is-bailed` 使得 `false` 也算作一个真实的结果，然后重新运行实验，观察 `bail` 是如何过早停止的。
2. 移除 `waterfall` 中的 `append args next` 步骤，观察调用链是如何失去其延续性的。
3. 在 `../../test/events-test.reb` 中添加一个新的监听器，让它把自己前置（prepend），并通过一个小的计数器列表确认执行顺序。

### 源码对比

| 路径 | 符号 |
|------|--------|
| `events.reb` | `make-events-service`, `resolve-callbacks`, `emit`, `waterfall`, `register` |
| `ref/core/events.ts` | `EventsService._resolve`, `parallel()`, `bail()`, `waterfall()` |

表面语法有所不同，但分发模式和生命周期耦合依然保持着明显的 Cordis 风格。