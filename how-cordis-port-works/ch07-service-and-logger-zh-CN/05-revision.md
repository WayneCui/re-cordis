# 第 7 章：重写后的 Service 与 Logger

当我们翻开 `service.reb` 和 `logger.reb` 时，那些最扣人心弦的移植工作其实已经尘埃落定。而这正是这两个文件如此有趣的原因：它们向我们展示了，在决定了哪些 Cordis 行为是核心结构，哪些只是 JavaScript 的语法糖之后，究竟还剩下些什么。

在原版 Cordis 中，`Service` 是一个非常丰满的抽象：包含了构造时的注册、通过 `symbols.invoke` 实现的可选调用行为、追踪器元数据，以及通过拦截链（intercept chain）进行的配置解析。Rebol 移植版保留了构造时注册和配置解析，但拒绝重建完整的可调用（callable）服务幻象。`make-service` 会注入 `ctx` 和 `name`，然后通过 `reflect/provide` 注册服务。`service-resolve-config` 依然遵循拦截链的规则，并且仍然会给 `Config.merge` 接管的机会，但最终得到的是一个普通的对象模型，而不是一个充满代理（Proxy）机制的可调用模型。

## 什么是真正重要并留存下来的

最简单的重写方法莫过于把每个服务都变成一个简单的记录（record），然后宣布大功告成。但这种做法会遗漏 Cordis 用户实际依赖的两件事。首先，服务必须将自身注册为被持有的运行时值，以便 Fiber 能够依赖它们。其次，配置叠加必须依然按照可预测的顺序进行解析。`service.reb` 将这两点都保留了下来。

`logger.reb` 则更具启发性，因为原版中充满了依赖于调用点遮蔽（call-site shadowing）的便利特性。Logger 的名称可以来自显式传入的参数、拦截配置，或是当前的服务调用者。Rebol 移植版完全保留了前两条路径，并简化了最后一条。`logger-create` 首先从显式输入中解析 `name`，然后是拦截配置，接着是 Fiber 名称。测试代码对缺失的可追踪上下文行为非常坦诚：对于这个同步的、没有 Proxy 的初代版本来说，某些源码场景是刻意被排除在外的。

这种坦诚正是该移植版的优势之一。它没有假装这个简化版的 Logger 与原版 Cordis 完全一致。它保留了有界缓冲区、导出器（exporter）注册、按名称设置日志级别，以及基于拦截的命名，然后明确地标出了哪些部分因为宿主语言的限制而在第一版中代价过高。

## 总结

这两个文件是该移植版区分“有用的抽象”与“宿主语言特性”的最后一道过滤器。一个服务仍然需要宿主上下文、公开名称以及配置解析，因为这些定义了运行时行为。一个日志记录器仍然需要导出器、级别和合理的名称来源，因为这些会影响调试。我们要避免的一个误区是：认为那些被抛弃的可调用技巧是该特性的本质。它们通常只是一个便利层，包裹着移植版至今仍在坚守的规则。

自我检查：当 `logger/create` 没有获得显式名称时，在回退到当前的 Fiber 名称之前，它会查阅哪条配置链？

---

## 实验

```bash
cd ch07-service-and-logger/code
bash run.sh
```

预期输出：

```text
PASS  custom Config.merge is used
PASS  intercept-based logger naming works
PASS  per-name log levels work
==== service-test: 16 passed, 0 failed ====
==== logger-test: 18 passed, 0 failed ====
```

### 动手尝试

1. 在 `../../logger.reb` 中，跳过 `logger-create` 内部的 `service-resolve-config`，观察基于拦截的 logger 命名如何失效。
2. 更改默认的日志级别查找逻辑，使其忽略特定于导出器的级别，然后重新运行过滤测试。
3. 在 `../../service.reb` 中，移除 `Config.merge` 快速路径，对比自定义合并配置如何退化为普通的“最后写入生效”行为。

### 源码对照

| 路径 | 符号 |
|------|--------|
| `service.reb` | `make-service`, `service-resolve-config`, `service-filter` |
| `logger.reb` | `make-logger-service`, `logger-create`, `emit-log` |
| `ref/core/service.ts` | `Service`, `[symbols.resolveConfig]()` |
| `ref/core/logger.ts` | `LoggerService`, `_resolveConfig()`, `Logger` |

这个移植版裁剪了许多 JS 的便利特性，但保留了对应用代码至关重要的运行时契约。