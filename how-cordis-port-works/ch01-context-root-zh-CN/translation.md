# 第 01 章 为什么根上下文需要按顺序构建

这个移植版本中的第一个巧思（surprise）在于，`make-context` 并非仅仅分配一个对象然后延迟填充字段，它实际上是在搭建一个运行时（runtime）。对于一个代码量勉强超过一屏幕的文件来说，这听起来像是个夸张的说法。但在这里，构建顺序至关重要，因为每一个后续的服务都假定前面的服务已经存在。如果 `reflect` 的创建早于根 Fiber（root fiber）的存在，那么对外提供的服务将无处注册；如果 `events` 在 `fiber` 之前就位，监听器就无法与插件的生命周期相绑定。因此，构造函数的执行顺序绝非形式主义（ceremony），这是整个移植项目中的首个核心架构决策。

在 TypeScript 中，`new Context()` 将部分搭建过程隐藏在 `Proxy` 背后，也藏在动态安装根节点行为的 `Fiber` 构造函数之中。而 Rebol 移植版则让这个执行顺序变得透明。[`context.reb`](../../context.reb) 使用 `make-child-ctx` 创建了一个类似子节点的空对象壳，通过 `make-fiber-root` 安装根 Fiber，随后依次构建 `reflect`、`registry`、`logger` 和 `events`。只有在这些组件全部就绪之后，它才会将 `root/fiber/disposables` 替换为一个全新的列表，这与 TypeScript 源码中调用 `this.fiber._disposables.clear()` 的做法遥相呼应。

## 本质上是协议的构造函数

最朴素的设计往往是先创建一个普通的上下文对象，然后让每个服务在首次使用时进行惰性初始化。这在 Rebol 中看起来很有吸引力，因为对象本身很容易修改。但它行不通，原因与 Cordis 在 TypeScript 中放弃这种做法如出一辙：各个服务在构建期间是相互依赖的。`registry.reb` 需要借助 `fiber.reb` 来创建插件的 Fiber；`reflect.reb` 需要一个活跃的根 Fiber，以便 `provide` 能将服务实现注册到当前所有者名下；而 `events.reb` 则希望通过 `effect` 来实现与 Fiber 生命周期绑定的清理机制。

移植版保留了这种依赖关系，但将其运作机制扁平化了。这里没有返回任何 `Proxy`。`context-is` 仅仅是对 `ctx-marker` 的标记检查；`extend`、`isolate` 和 `intercept` 全部通过克隆显式映射表或区块（blocks）来实现，而不是依赖原型继承。这是该代码库中反复出现的一个主题：当宿主语言无法将行为暗藏在字段访问背后时，运行时数据结构就必须变得清晰可见、可被检查。

因此，这个文件中最重要的一句话并不是什么算法技巧，而是 [`context.reb`](../../context.reb) 中的那行构建顺序注释：fiber、reflect、registry、logger、events。一旦你理解并认同了这一行，阅读整个代码库的方向也就找对了。

---

## 实验

```bash
cd ch01-context-root/code
bash run.sh
```

预期输出（末尾）：

```text
==== context-test: 22 passed, 0 failed ====
```

### 尝试一下

#### 1. 交换 `reflect` 和 `fiber` 的创建顺序

在 [`context.reb`](../../context.reb) 的 `make-context` 中，把 `make-reflect-service` 挪到 `make-fiber-root` 之前，然后重新运行 `bash run.sh`。

**预期：测试仍然全部通过。** 这不是文档写错了，而是实验本身在教你区分两种依赖：

- **构造期依赖**：服务在 `make-*-service` 执行期间就需要 `ctx/fiber`（例如 `logger` 通过 `reflect/provide` 自注册，`events` 通过 `fiber/effect` 注册内部监听器）。
- **运行期依赖**：`make-reflect-service` 只分配方法对象，直到调用 `provide`/`set` 才访问 `ctx/fiber`；而测试都在 `make-context` 完成之后才开始 `provide`。

因此，仅交换 `reflect` 与 `fiber` 是「弱违反」——`make-context` 返回时两者都已就绪，行为测试看不出差异。

要看到构造期假设真正被破坏，把 `logger` 或 `events` 挪到 `ctx/fiber: rf` **之前**（且不要提前赋值 fiber），再运行 `bash run.sh`：

```text
** Script error: cannot access fiber in path act-ctx/fiber/effect
** Where: provide make-service make-logger-service make-context
```

#### 2. 注释掉 `disposables` 重置

注释掉 `make-context` 末尾的 `ctx/fiber/disposables: make-disposable-list`，然后运行：

```bash
bash probe.sh
```

**预期：`context-test` 仍然 22 passed**（测试不检查 disposables），但 probe 输出会变化：

| 配置 | `disposables length` | effect labels |
|------|---------------------|---------------|
| 正常（有 reset） | 0 | （无） |
| 注释掉 reset | 2 | `ctx.on(internal-listener)`、`ctx.on(internal-update)` |

这 2 个包装器来自 [`events.reb`](../../events.reb) 构造时的两次 `svc/on`，每次注册都会走 `fiber/effect`。reset 行的作用就是丢弃这些一次性构建包装器，与 TypeScript 里 `this.fiber._disposables.clear()` 对应。

#### 3. 观察 `intercept-chain` 继承

[`test/context-test.reb`](../../test/context-test.reb) 的 Test 5 已包含相关断言（`intercept declaration applied`、`intercept chain inherited`）。运行 `bash run.sh` 确认通过后，可在 Test 5 临时加一行调试输出观察链条克隆：

```rebol
print mold select int5 'intercept-chain
```

`extend` 后子 ctx 应继承同一份 `[leaf ... root]` 链，lookup 时从头顺序匹配，第一个命中的 map 生效。

### 源码对比

| 路径 | 符号 |
|------|--------|
| `context.reb` | `make-context`, `make-child-ctx`, `context-is` |
| `ref/core/context.ts` | `Context.constructor`, `extend()`, `isolate()`, `intercept()` |

移植版去除了源码中的 `Proxy` 门面，转而将构建协议显式化。