# 第 06 章 隔离区与拦截链

当你第一次在 Cordis 中看到 `ctx.isolate('foo')` 时，你很容易将其理解为一个命名上的把戏：还是同一个服务名称，只不过把它放进了一个“私人房间”。上游的实现让这个“私人房间”感觉几乎毫不费力，因为原型（prototype）继承和 `Proxy` 查找隐藏了背后的机制。而 Rebol 移植版无法隐藏它，所以 `context.reb`、`reflect.reb` 和 `service.reb` 必须展示出“私人房间”的真正含义。

它们所展示的内容令人愉悦地朴素。隔离区（Isolation）是一个从服务名到标签（label）的映射。拦截（Intercept）是一个配置映射的链条，按从当前上下文向根节点回溯的顺序排列。这个设计中没有任何东西依赖于元编程。一切都依赖于一致的查找规则。

## 为什么显式链条胜过伪造的继承

天真的移植版会尝试用临时的对象复制来重现 JavaScript 的原型技巧。这种方法通常会以两种方式之一失败。要么因为你复制了太多，子上下文不再能看到父上下文的更新；要么因为每个隔离的上下文依然指向同一个服务插槽，导致它们看到了太多的东西。移植版的答案是将这两个关注点分离开来。

对于服务的可见性，`reflect.reb` 使用 `isolate-store-key` 计算一个感知隔离区的键。一个标签命名空间中的 Provider（**解释：服务的提供者，负责注册并提供具体实现**）根本不会与另一个命名空间中的 Provider（**解释：服务的提供者，负责注册并提供具体实现**）发生冲突。对于配置的叠加，`context.reb` 存储了一个显式的 `intercept-chain`，而 `service.reb` 中的 `service-resolve-config` 会从根节点到叶子节点遍历这条链，然后按照预定义的优先级应用 `base` 和 `head` 的叠加。

这个选择不仅仅是替换了缺失的 JS 特性。它还使得这些规则在测试中变得可检查。你可以打印 `intercept-chain`。你可以直接比较 isolate 标签。你可以看到共享同一个标签的两个子上下文，也共享着同一个可见的 Provider（**解释：服务的提供者，负责注册并提供具体实现**）。运行时变得更容易教学，恰恰是因为在读者背后发生的“暗箱操作”变少了。

## 总结

在这个移植版中，隔离与拦截就像是叠在一起的描图纸，而不是密封的房间。每个新的上下文都会添加一个新的可见层：也许是为某个服务添加一个新的 isolate 标签，也许是在拦截链的头部添加一个新的配置映射。常见的错误是认为 `extend`、`isolate` 和 `intercept` 都在做同一种克隆。它们不是。隔离改变的是服务身份的边界。拦截改变的是配置解析的顺序。自我检查：当两个隔离的上下文为 `foo` 使用相同的显式标签时，为什么它们能看到同一个 Provider（**解释：服务的提供者，负责注册并提供具体实现**），但依然保持独立的上下文对象？

---

## 实验

```bash
cd ch06-isolation-and-config/code
bash run.sh
```

预期输出：

```text
PASS  a private provider wakes only one isolated plugin
PASS  a shared label wakes both isolated plugins
PASS  leaf config overrides root config
==== context-test: 16 passed, 0 failed ====
==== service-test: 16 passed, 0 failed ====
```

### 试一试

1. 在 `../../context.reb` 中，让 `isolate` 重用旧的映射而不是复制它，然后重新运行共享标签和私有标签的测试。
2. 颠倒 `service-resolve-config` 内部的合并顺序，观察根配置如何错误地覆盖叶子配置。
3. 在一次临时的调试运行中打印 `ctx/isolate-map` 和 `ctx/intercept-chain`，看看这两种机制是如何独立演进的。

### 对照源码

| 路径 | 符号 |
|------|--------|
| `context.reb` | `isolate`, `intercept`, `make-child-ctx` |
| `reflect.reb` | `ctx-isolate-label`, `isolate-store-key`, `reflect-notify` |
| `service.reb` | `service-resolve-config`, `service-filter` |
| `ref/core/context.ts` | `isolate()`, `intercept()` |
| `ref/core/service.ts` | `[symbols.resolveConfig]()` |

在这一章里，隐藏的继承变成了一种显式的链条管理，这不得不说是一种架构上的巧思。