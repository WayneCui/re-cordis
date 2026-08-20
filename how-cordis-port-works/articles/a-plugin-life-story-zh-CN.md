# 我是一个 Cordis 插件：从注册到被卸载的一生

我是 `receptionist`，一个 Cordis 插件。我没有 `main` 函数，也没有 `while true`。我的一生只有三件事：声明我要什么、在拿到东西后开工、在失去东西或被赶走时把现场收拾干净。

这篇文章不是使用手册，而是我的自述。我想让你看到：框架不是替我跑起来就完事，它真正在管的是——**我什么时候可以活，什么时候必须死，以及死的时候别把别人的东西也带走**。

## 一、我出生时，手里只有一张需求单

我的定义很简单：

```rebol
receptionist: make object! [
    name: "receptionist"
    inject: ['greeter]
    apply: func [ctx [object!] config] [...]
]
```

`inject: ['greeter]` 是我的需求单：没有 `greeter` 服务，我不开工。`apply` 是我的工作函数，但它不是构造函数——Cordis 不会一注册我就调用它。它更像一份合同：条件满足时，框架才会让我签字上岗。

很多人第一次写插件时会犯一个错误：在 `apply` 里假设依赖已经存在，然后直接调用。如果 `greeter` 还没被 `provide`，我会立刻崩溃。Cordis 不这么干。它把我放进一个**租约**里，而不是直接把我扔上生产线。

## 二、框架给我发了一张「租约」，不是工牌

在 Cordis 里，每个插件实例都对应一个 **Fiber**。这个词容易让人想到线程或协程，但在这里它更像一份房间预订协议：

- 协议上写着我要哪些服务（`inject`）
- 协议上记录着当前给我服务的 Provider 是谁（`epoch`）
- 协议里夹着我开工后产生的所有「副作用」清单（`disposables`）

我刚被注册时，状态是 `PENDING`，纪元是 `__INACTIVE__`。意思是：房间订好了，但钥匙还没拿到。

直到有人调用：

```rebol
root/reflect/provide 'greeter greeter-service none root
```

`reflect` 会把 `greeter` 写进服务表，然后通知所有声明依赖它的 Fiber。我的 Fiber 会重新计算纪元：把提供者的 uid 拼成一串，比如 `:0`。只要这串不是 `__INACTIVE__`，框架就知道——我可以上岗了。

## 三、开工：apply 被调用，副作用被记账

纪元一变，我的 Fiber 从 `PENDING` 变成 `LOADING`，然后 `apply` 被调用。

我在 `apply` 里做了三件事：

1. 从 `ctx/reflect/get 'greeter` 拿到服务
2. 用 `ctx/events/on` 订阅了 `guest-arrived`
3. 用 `ctx/fiber/effect` 注册了一个「前台」清理器

注意第 2、3 步：它们不是普通的函数调用，而是**副作用**。Cordis 要求我把这些副作用登记在案，因为框架要在我被卸载时，按**相反顺序**把它们清理掉。

这就是 `fiber-effect` 的作用。它立刻执行我给的函数，把返回的 disposer 收进 Fiber 的 `disposables` 列表。如果我返回一个 block，它就逐个收；如果我返回的对象带 `meta`，它还会挂成树状结构，方便调试。

## 四、服务更新：我不是被重启，而是被「换约」

最反直觉的部分来了。当 `greeter` 的配置从 `"Hello"` 改成 `"Hi"` 时，Cordis 不会直接改我的字段。它会：

1. 让旧的 `greeter` Provider 卸载
2. 我的 Fiber 发现依赖消失，纪元变回 `__INACTIVE__`
3. 我进入 `UNLOADING`，框架按**逆序**执行我的 disposers
4. 新的 `greeter` 上线，纪元变成新的 uid 串
5. 我重新 `LOADING`，`apply` 再跑一次

看 greeter 例子的输出：

```text
--- update prefix Hello -> Hi ---
desk-closed served=1
greeter-down
greeter-up Hi
app-ready
updated
served:Hi Ada
```

`desk-closed` 先于 `greeter-up Hi` 出现，说明我的清理器在旧 Provider 下线、新 Provider 上线之间执行。这不是「重启」，而是**换约**：旧租约作废，新租约生效，中间必须把房间打扫干净。

## 五、隔离：同名服务，不同房间

Cordis 的 `isolate` 让我可以在同一个应用里拥有多个互不相干的 `greeter`。

```rebol
ctx-a: root2/isolate 'greeter none
ctx-b: root2/isolate 'greeter none
```

`ctx-a` 和 `ctx-b` 各自 `provide 'greeter` 时，只有对应房间里的插件会启动。根房间的 `greeter` 不会串到 A 房间，A 的也不会串到 B。

实现上，`reflect` 的 store key 不是简单的 `'greeter`，而是 `label/name`。`isolate` 给每个上下文分配一个标签，服务查找时按标签隔离。这就是为什么同一个服务名可以在不同房间里代表完全不同的东西。

## 六、死亡：dispose 不是删除，而是履约

当我被 `dispose` 时，Cordis 不会直接把我从内存里抹掉。它会：

1. 把我的 Fiber 的 `uid` 置为 `none`
2. 发出 `internal-plugin` 事件
3. 从 registry 里移除我的 runtime
4. 把纪元设为 `__INACTIVE__`
5. 触发 `fiber-unload`，逆序执行所有 disposers

如果我的 disposer 抛错，框架不会崩溃，而是把错误记进 logger，继续清理剩下的。这是 Cordis 的底线：**一个插件的死亡不能拖垮整个系统**。

## 七、为什么 Cordis 要这么麻烦？

因为「插件」不是「函数」。函数调用一次就结束，插件却要长期持有资源：事件监听、定时器、数据库连接、文件句柄。如果框架不跟踪这些副作用，卸载插件时就会泄漏。

Cordis 的答案是：**把生命周期显式化**。

- 依赖用 `inject` 声明，而不是在代码里隐式调用
- 副作用用 `effect` 注册，而不是散落在闭包里
- 状态用 `epoch` 驱动，而不是靠回调顺序
- 清理用 LIFO 保证，而不是靠程序员记得写 `finally`

这套设计没有魔法。你看到的正是 Cordis 的骨架：**插件的存活性，源自于依赖的可见性；插件的可靠性，源自于副作用的可撤销性**。

## 八、给新手的三个忠告

如果你刚开始写 Cordis 插件，记住这三件事：

1. **不要在 `apply` 里假设依赖已经存在**。先声明 `inject`，让框架决定你什么时候能活。
2. **所有副作用都要登记**。事件监听、定时器、外部连接，都要通过 `ctx/fiber/effect` 或 `ctx/events/on` 注册，让框架能替你清理。
3. **dispose 是合同，不是建议**。返回的 disposer 必须真的能释放资源，否则更新配置或卸载插件时，你会留下一地狼藉。

我的一生很简单：等依赖、开工、登记副作用、在失去依赖或被赶走时逆序清理。Cordis 的复杂性不在我身上，而在框架如何**可靠地**让我活、让我死。理解了这一点，你就理解了 Cordis 的核心。

---

*本文示例代码见 `examples/greeter.reb`，测试见 `test/fiber-test.reb`。*
