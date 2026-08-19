# 第 01 章 为什么根上下文需要按顺序构建

这个移植版本中的第一个巧思（surprise）在于，`make-context` 并非仅仅分配一个对象然后延迟填充字段。它实际上是在搭建一个运行时（runtime）。对于一个长度勉强超过一屏幕的文件来说，这听起来像是个夸张的说法，但构建顺序至关重要，因为每一个后续的服务都假定前面的服务已经存在。如果 `reflect` 在根 Fiber（root fiber）存在之前就被创建，那么提供的服务将无处注册。如果 `events` 在 `fiber` 之前出现，监听器就无法与插件的生命周期绑定。因此，构造函数的顺序并非走过场（ceremony）。这是整个移植版本的第一个架构设计决策。

在 TypeScript 中，`new Context()` 将部分搭建过程隐藏在 `Proxy` 背后，也隐藏在动态安装根节点行为的 `Fiber` 构造函数背后。Rebol 移植版则让这个顺序变得透明。[`context.reb`](../../context.reb) 使用 `make-child-ctx` 创建了一个类似子节点的空对象壳，通过 `make-fiber-root` 安装根 Fiber，随后依次构建 `reflect`、`registry`、`logger` 和 `events`。只有在这些组件就位之后，它才会将 `root/fiber/disposables` 替换为一个全新的列表，这与 `context.ts` 中调用 `this.fiber._disposables.clear()` 的做法遥相呼应。

## 这是一个真正的协议，而不仅仅是构造函数

最简单的设计是创建一个普通的上下文对象，然后让每个服务在首次使用时惰性初始化。这在 Rebol 中看起来很有吸引力，因为对象很容易修改。但它失败的原因与 Cordis 在 TypeScript 中没有采用这种做法的原因相同：服务在构建期间相互依赖。`registry.reb` 需要 `fiber.reb` 来创建插件的 Fiber。`reflect.reb` 需要一个活跃的根 Fiber，以便 `provide` 能将服务实现注册到当前所有者名下。`events.reb` 则希望通过 `effect` 实现与 Fiber 生命周期绑定的清理机制。

移植版保留了这种依赖关系，但将其机制扁平化了。这里没有返回 `Proxy`。`context-is` 仅仅是对 `ctx-marker` 的标记检查。`extend`、`isolate` 和 `intercept` 全部是对显式映射表或区块（blocks）进行克隆，而不是依赖原型继承。这是该代码库中反复出现的主题：当宿主语言无法将行为暗藏在字段访问背后时，运行时数据结构就必须变得可被检查。

因此，这个文件中最重要的一句话不是什么算法技巧。而是 [`context.reb`](../../context.reb) 中的构建顺序注释：fiber、reflect、registry、events、logger。一旦你理解了这一行，整个代码库的阅读方向就清晰了。

---

## 实验

```bash
cd ch01-context-root/code
bash run.sh
```

预期输出：

```text
PASS  root fiber uid 0
PASS  reflect is constructed
PASS  registry is constructed
PASS  events is constructed
==== context-test: 16 passed, 0 failed ====
```

### 尝试一下

1. 在 `../../context.reb` 中，交换 `reflect` 和 `fiber` 的创建顺序，然后重新运行实验，观察后续的假设是如何被破坏的。
2. 注释掉重置 `ctx/fiber/disposables` 的那行代码，检查有多少构建时的包装器残留在根 Fiber 中。
3. 在 `../../test/context-test.reb` 中，围绕 `intercept-chain` 的继承添加一个新的断言，这样你就能直接看到被克隆的链条。

### 源码对比

| 路径 | 符号 |
|------|--------|
| `context.reb` | `make-context`, `make-child-ctx`, `context-is` |
| `ref/core/context.ts` | `Context.constructor`, `extend()`, `isolate()`, `intercept()` |

移植版去除了源码中的 `Proxy` 门面，转而将构建协议显式化。