# 第 04 章 失去 Proxy 后的 Reflect

迟早，每一位 Cordis 的读者都会意识到同一件事：它很大一部分的人体工学实际上归功于 `ReflectService.handler`。在上游代码中，`Proxy` 让 `ctx.foo` 的含义变成了“寻找名为 `foo` 的可见服务，也许会遍历 Fiber 链，也许会触发内部钩子，也许会抛出一个定制的错误”。而 Rebol 移植版没有这样的语法糖。这意味着 `reflect.reb` 必须回答整个代码仓库中最难的翻译问题：一旦失去了直接的属性拦截能力，哪些行为是必须保留的核心精髓？

移植版保留了服务的语义，但抛弃了语法上的错觉。你不会得到一个神奇的属性空间。取而代之的是显式的方法：`get`、`set`、`provide`、`accessor`、`mixin` 和 `notify`。这听起来像是一种倒退，直到你追踪这些方法实际保留了什么。可见性依然取决于当前的隔离区（isolate）标签。Provider（**解释：服务的提供者，负责注册并提供具体实现**）依然属于特定的 Fiber。依赖通知依然会触发那些注入了变更服务的 Consumer（**解释：服务的消费者，依赖并使用已注册的服务**）的刷新。

## 为什么在这里显式查找更胜一筹

一个天真的移植版可能会尝试用代码生成技巧，或者通过重载对象字段来模拟 Cordis 的 `Proxy` 行为，直到每个服务都变成上下文对象上的一个真实插槽。这会让简单的演示看起来更接近上游的 API，但它会模糊掉最重要的所有权规则。相反，`reflect.reb` 保持了诚实。`isolate-store-key` 将一对值（当前的 isolate 标签和服务名）转换成一个存储键。`provide` 将一个实现对象写入 `store`，将其与当前的 Fiber 绑定，并返回一个可以再次将其移除的清理函数。然后，`notify` 会扫描所有的 Fiber，看看在同一个 isolate 标签下，哪些 Consumer（**解释：服务的消费者，依赖并使用已注册的服务**）关心这些发生了变更的名称。

这也是移植版的简化最为明显的地方。当一个服务没有直接存在时，上游的 Cordis 可以从一个影子上下文（shadow context）开始，向上遍历父级的 Fiber。Rebol 版本选择了一个更朴素的边界：显式的 act-ctx 参数和直接的 store 查找。结果没那么神奇了，但它让缺失的行为在代码中变得可见，而不是将其掩盖在宿主语言的元编程中。

错误处理的原则也很重要。源代码会抛出诸如 `cannot set property "foo" without provide` 这样的消息。即使实现方式不同，移植版也保留了这种风格。这种连续性是有用的，因为它允许测试表达相同的契约，而底层运行时的模型已经发生了改变。

## 总结

在这个移植版中，`Reflect` 就像是一个海关服务台。每一个服务在进入大众视野之前，都必须被声明、打上 isolate 标签，并与当前拥有它的 Fiber 绑定。一个诱人的误解是，因为 `Proxy` 消失了，所以会认为 `Reflect` 只是一个存储映射。事实并非如此。映射只是简单的部分。真正的工作是决定谁可以看到哪个实现，以及当这个答案发生改变时，必须通知哪些正在等待的 Fiber。自我检查：为什么 `notify` 在刷新一个被注入的 Fiber 之前要比较 isolate 标签？

---

## 实验

```bash
cd ch04-reflect-without-proxy/code
bash run.sh
```

预期输出：

```text
PASS  get returns the provided value
PASS  provide wakes the dependent fiber
PASS  internal-service fires once
==== reflect-test: 28 passed, 0 failed ====
```

### 试一试

1. 在 `../../reflect.reb` 中，暂时忽略 `reflect-notify` 内部的 `ctx-isolate-label`，观察隔离的上下文开始对彼此的 Provider（**解释：服务的提供者，负责注册并提供具体实现**）产生反应。
2. 修改 `set`，让它跳过 Fiber 的所有权检查，然后重新运行那些防止多个 Fiber 写入同一个服务的测试。
3. 在 `../../test/reflect-test.reb` 中，为相同的名称和 isolate 标签添加第二个 `provide` 调用，以显式地观察重复注册的路径。

### 对照源码

| 路径 | 符号 |
|------|--------|
| `reflect.reb` | `make-reflect-service`, `isolate-store-key`, `provide`, `notify`, `mixin` |
| `ref/core/reflect.ts` | `ReflectService.handler`, `provide()`, `notify()`, `mixin()` |

这一章是移植版最公开地用 API 的魔法换取显式的运行时数据的地方。