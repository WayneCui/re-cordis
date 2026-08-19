# Cordis Rebol 移植版工作原理

如果你只看表面的 API，这个移植版看起来平静得有些欺骗性。它有 `make-context`，有插件，有服务，而且所有的测试都是绿色的。但真正的难点，隐藏在这片平静的水面之下。TypeScript 版本的 Cordis 严重依赖语言特性来默默地为你传递上下文：`Proxy` 负责重写属性访问，装饰器用来附加注入元数据，可调用服务通过 `symbols.invoke` 进行路由，而异步 Fiber（async fibers）则能在底层依赖发生变化时自动暂停。

Rebol3 并没有赋予这个移植版上述任何一种天赋。这就是为什么这个代码仓库值得像读书一样去阅读。它不仅仅是用另一种语法把 Cordis 重新写了一遍，而是做出了艰难的抉择：哪些行为是不可或缺的？哪些 JavaScript 的奇技淫巧可以被丢弃？又有哪些机制必须用更朴素的形式重新构建？其结果是诞生了一个更小巧的系统，但同时也是一个更加暴露底层细节的系统：你能看清每个文件在设计上做出的取舍。

两条启动命令：

```bash
cd ch01-context-root/code && bash run.sh
./verify-all.sh
```

源码目录：`../`（这是 **Rebol3** 源码，在 `../ref/core` 中附带了一份 **TypeScript** 的参考副本）。教学代码始终与源码相邻，每一章末尾的 "Against the source"（对比源码）表格都会将你引回真实的文件路径和符号。

**约定：** 各章节的内容不会修改移植版自身的代码。它们会运行现有的测试和示例，然后让你去微调一些小巧的教学切片或是现有的测试输入，以此让旧有的心智模型以一种清晰可见的方式被打破。

```text
Context root
  -> Events hooks
    -> Fiber state and cleanup
      -> Reflect service lookup
        -> Registry plugin runtime
          -> Isolation and intercept chains
            -> Service and Logger surface
              -> Greeter example
```

这个顺序也就是移植版的轮廓。必须先由 `Context` 构建起共享的运行时环境；`Events` 需要提供一个地方来注册钩子；`Fiber` 赋予了插件生命周期，而不再是裸露的回调函数；`Reflect` 移除了缺失的 `Proxy` 魔法，代之以显式的查找规则；`Registry` 将一个插件的声明转化为了一个活跃的 Fiber；随后，隔离（Isolation）与拦截（intercept）解释了为什么同一个服务名称在不同的上下文中可能意味着截然不同的东西。只有在这一切铺垫完成之后，`Service` 和 `Logger` 才会让人觉得顺理成章、不再有令人费解的巧思。

因此，本书与其说是提供一份文件字典，不如说是在回答读者心中的疑问。为什么根节点的构建要按照那个顺序发生？为什么 Fiber 更像是一份租约而不是一个线程？为什么 `reflect.reb` 掌管着服务的可见性？为什么 `logger.reb` 成了最后彻底简化 Cordis 在 JS 中那些大型工效学设计的地方？当我们最终到达 greeter 示例时，这个示例给人的感觉应该像是严谨的拼装，而非魔法。

## 章节导读

| 章节 | 简写 | 读者疑问 | 核心？ |
|------|------|------|------|
| 01 | `context-root` | 为什么根上下文在返回自身之前要先构建世界？ | 否 |
| 02 | `events-hooks` | 在去除了可变参数（variadics）和隐式的 `this` 之后，Cordis 的事件机制是如何存活的？ | 是 |
| 03 | `fiber-epochs` | 为什么插件的 Fiber 是一份可以在 pending、active 等状态之间来回切换的租约？ | 是 |
| 04 | `reflect-without-proxy` | 当语言无法拦截字段访问时，用什么来替代 Cordis 的 `Proxy` 门面？ | 是 |
| 05 | `registry-plugins` | 注册表（registry）是如何将一个插件声明转化为一个运行时外加一个活跃的 Fiber 的？ | 否 |
| 06 | `isolation-and-config` | 为什么隔离与拦截被实现为了显式的调用链，而不是魔法般的继承？ | 是 |
| 07 | `service-and-logger` | 在剥离了大部分 JS 元编程之后，`Service` 和 `Logger` 还剩下什么？ | 是 |
| 08 | `greeter-app` | 整个移植版在一个可运行的小应用中，还能保持 Cordis 的味道吗？ | 否 |

## 目录

- [第01章 为什么根上下文按顺序构建](./ch01-context-root/chapter.md)
- [第02章 没有可变参数的事件](./ch02-events-hooks/chapter.md)
- [第03章 作为租约的 Fiber](./ch03-fiber-epochs/chapter.md)
- [第04章 没有 Proxy 的 Reflect](./ch04-reflect-without-proxy/chapter.md)
- [第05章 注册表将插件转化为运行时](./ch05-registry-plugins/chapter.md)
- [第06章 隔离与拦截链](./ch06-isolation-and-config/chapter.md)
- [第07章 重写后的 Service 与 Logger](./ch07-service-and-logger/chapter.md)
- [第08章 检验移植版的一个小应用](./ch08-greeter-app/chapter.md)

## 如何阅读

如果你想走捷径，直击设计的核心赌注，请先阅读第 03、04 和 06 章。这三章阐述了移植版真正的核心命题：保留响应式的插件生命周期，但用显式的数据结构来替代隐式的运行时魔法。如果你在对比 Cordis 调试一些行为差异，第 04 章是最好的起点，因为在那里，缺失的 `Proxy` 行为不再是抽象的讨论，而是变成了具体的查找规则。

如果你更关心应用层代码，请按顺序阅读第 01、05 和 08 章。它们展示了根节点设置、插件注册以及一个小应用是如何组装在一起的，而不需要你在第一遍阅读时就吸收所有内部细节。第 07 章最好在之后阅读，因为只有当你理解了调用者上下文在这个移植版中意味着什么，日志记录器的命名和服务的构建才说得通。

## 验证

```bash
./verify-all.sh
# expect: 8 chapter labs OK
```

快速查找表位于 [appendix/quick-reference.md](./appendix/quick-reference.md)。