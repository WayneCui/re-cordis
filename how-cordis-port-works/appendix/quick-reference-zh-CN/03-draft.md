# 快速参考

## 一句话心智模型

| 章节 | 简明模型 |
|------|------|
| 01 | `make-context` 是一个构建协议，而不是数据构造器。 |
| 02 | 事件是钩子列表加上派发模式，有效载荷被打包在区块（blocks）中。 |
| 03 | Fiber 是对插件副作用的一份可撤销租约。 |
| 04 | `Reflect` 是缺失的 `Proxy` 行为变成显式查找与提供规则的地方。 |
| 05 | 注册表（registry）拥有运行时的身份标识；一个 Fiber 就是该身份的一次激活。 |
| 06 | 隔离与拦截是你可以检查的影子链，而不是隐藏的原型技巧。 |
| 07 | `Service` 和 `Logger` 保留了实用的接口表面，同时抛弃了大部分可调用的魔法。 |
| 08 | greeter 示例证明了移植版在简化之后依然保留了响应式的感觉。 |

## 移植版保留了什么

| 行为 | 所在位置 |
|------|------|
| 响应式的依赖重启 | `fiber.reb`, `reflect.reb` |
| 插件的注册与清理 | `registry.reb`, `fiber.reb` |
| 事件模式，如 `emit`, `bail`, `waterfall` | `events.reb` |
| 隔离的服务作用域 | `context.reb`, `reflect.reb` |
| 通过拦截链实现的配置覆盖 | `context.reb`, `service.reb`, `logger.reb` |

## 移植版简化了什么

| JavaScript 特性 | Rebol 移植版决策 |
|------|------|
| `Proxy` 属性拦截 | 替换为显式的 `reflect/get`、`reflect/set`、`reflect/provide` |
| 诸如 `@Inject` 的装饰器 | 替换为插件对象上声明式的 `inject` 字段 |
| 通过 `symbols.invoke` 实现的可调用服务 | 仅保留部分显式助手函数，如 `logger/create` |
| 异步 Fiber 生命周期 | 使第一个版本完全同步化 |
| 可追踪的 `this` 遮蔽（shadowing） | 丢弃它，改为显式传递 `ctx` |