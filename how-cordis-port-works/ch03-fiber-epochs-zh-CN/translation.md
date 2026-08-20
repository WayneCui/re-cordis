# 第 03 章 作为租约的 Fiber

如果说有哪个文件配得上“系统的灵魂（soul of the system）”这一称呼，那一定非 `fiber.reb` 莫属。这个移植版中的其他所有部分，都可以比上游的 Cordis 源码进行更为激进的简化，唯独这个文件不行。一个插件绝不仅仅是一个只运行一次的回调函数，它是一段只有在依赖项可用时才会激活的行为。它在卸载时会按照相反的顺序进行清理，并且在依赖纪元（dependency epoch）再次发生改变时，它可能会重新回归。

正因如此，这个文件是围绕着响应式租约（reactive lease）构建的，而不是围绕线程（thread）。“Fiber”这个词可能会误导那些有着异步运行时背景的读者，但这里的实现让其真正的意图变得非常直白：一个 Fiber 在处于激活状态时，拥有并管理着各种副作用（effects）。一旦丢失了所必需的服务，该租约就会被撤销；而当服务再次提供时，同一个插件可能会在一个全新的纪元下重新加载。

## 为什么普通的生命周期回调会失败

最直接的移植思路往往是让 `registry.reb` 调用 `plugin/apply`，保留返回的清理器（disposer），然后在需要卸载时调用它。然而，这种模型在注入的依赖延迟出现或暂时消失的那一刻就会彻底崩溃。Consumer（**解释：服务消费者**）插件要么启动得太早并因缺失服务而崩溃，要么在 Provider（**解释：服务提供者**）回归后永远无法重新启动。

`fiber.reb` 保留了上游的解决方案。每个 Fiber 维护着一个 `inject` 映射表、一个用于存放已解析实现的 `store`、一个 `epoch` 字符串，以及一个包含 `PENDING`、`LOADING`、`ACTIVE`、`FAILED`、`DISPOSED` 和 `UNLOADING` 的状态机。`fiber-refresh` 会重新计算当前可见的实现，并将 Provider（**解释：服务提供者**）的 `uid` 拼接到一个纪元字符串中。如果任何所需的服务发生缺失，该纪元就会变成 `inactive-epoch`。随后，`fiber-set-epoch` 会根据状态决定该插件是应该重新加载还是直接卸载。

这里最能说明问题的细节并不是纪元字符串本身，而是 `fiber-effect` 中的清理规则。副作用（effects）将清理器收集到一个 `DisposableList` 中，卸载时会以相反的顺序运行它们。路线图特别指出，这种 LIFO（后进先出）的顺序曾是移植版经历的一次巧思（surprise），它迫使我们去修正测试用例，而不是修改代码。这是一个好兆头。这意味着移植版正在忠实地遵循源码的行为，哪怕这种行为与我们的第一直觉相悖。

## 总结

你可以把这里的 Fiber 想象成一份签署好的房间预订协议，而不是一个工人。这份预订协议列出了必须存在的服务，而纪元就是附加在该预订上的 Provider（**解释：服务提供者**）身份列表。如果其中一个 Provider（**解释：服务提供者**）消失了，预订就不再有效，因此房间会按照与设置时相反的顺序被清理。常见的误解是把 Fiber 等同于“插件对象本身”，但它的定义其实要狭义得多——它仅仅是在特定的依赖快照下，插件的一次激活。自我检查：当 `foo` 消失然后又回归时，究竟是哪个函数重新计算了该 Fiber 是应该保持挂起状态，还是重新加载？

---

## 实验

> **Day 3 阅读清单**：[fiber-reading-guide-zh-CN.md](../fiber-reading-guide-zh-CN.md)（逐函数 + 行号 + 测试锚点）

```bash
cd ch03-fiber-epochs/code
bash run.sh
bash probe-epoch.sh   # 观察 epoch / state 变化（实验 2/3）
```

预期输出：

```text
PASS  starts after provide
PASS  returns to pending when the dependency disappears
PASS  disposer runs once
==== fiber-test: 55 passed, 0 failed ====
```

### 尝试一下

1. 在 `../../fiber.reb` 中，改变卸载时的清理顺序，让清理器按照插入顺序运行，然后重新运行涵盖嵌套清理的测试。
2. 在 `fiber-refresh` 内部打印计算出的 `epoch-str`，并观察它随着 Provider（**解释：服务提供者**）出现、消失和回归而发生的变化。
3. 在 `../../test/fiber-test.reb` 中，给一个插件添加第二个注入的依赖，并观察纪元是如何变成多个 Provider（**解释：服务提供者**）ID 的拼接字符串的。

### 源码对比

| 路径 | 符号 |
|------|--------|
| `fiber.reb` | `fiber-effect`, `fiber-refresh`, `fiber-set-epoch`, `make-plugin-fiber` |
| `ref/core/fiber.ts` | `Fiber`, `_checkImpl()`, `_refresh()`, `_setEpoch()` |

移植版虽然去除了异步机制，但保留了最核心的思想：插件的存活性源自于依赖的可见性，而不是一次性的启动。