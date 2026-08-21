# Cordis Rebol 移植版工作原理

本书将带你深入探索 Cordis 的 Rebol3 移植版。这是一次硬核的真实工程翻译之旅，绝非走马观花的营销宣传。整个源码树非常精简，足以让人从头到尾通读，但它最吸引人的地方并不在于体量的小巧。真正的重点在于：一个原本严重依赖 `Proxy`、装饰器、可调用服务以及异步 Fiber 的框架，是如何在一门完全没有直接提供这些机制的语言中被重写出来的。

我们将顺着一条核心依赖主干，从根节点的构建一路剖析到可运行的示例。每一章都紧密贴合 [`../`](../) 目录下的真实代码文件，并且都在各自的 `code/` 目录下配有一个小巧的可运行实验。

从这里开始：

```bash
cd how-cordis-port-works/ch01-context-root/code && bash run.sh
cd how-cordis-port-works && ./verify-all.sh
```

连贯的前言与章节导读位于 [HOW_CORDIS_PORT_WORKS.md](../HOW_CORDIS_PORT_WORKS-zh-CN/translation.md)。

- [第 01 章 为什么根上下文按顺序构建](../HOW_CORDIS_PORT_WORKS-zh-CN/translation.md#目录)
- [第 02 章 没有可变参数的事件](../HOW_CORDIS_PORT_WORKS-zh-CN/translation.md#目录)
- [第 03 章 作为租约的 Fiber](../HOW_CORDIS_PORT_WORKS-zh-CN/translation.md#目录)
- [第 04 章 没有 Proxy 的反射](../HOW_CORDIS_PORT_WORKS-zh-CN/translation.md#目录)
- [第 05 章 注册表将插件转化为运行时](../HOW_CORDIS_PORT_WORKS-zh-CN/translation.md#目录)
- [第 06 章 隔离与拦截链](../HOW_CORDIS_PORT_WORKS-zh-CN/translation.md#目录)
- [第 07 章 重写后的服务与日志器](../HOW_CORDIS_PORT_WORKS-zh-CN/translation.md#目录)
- [第 08 章 演练移植版的小型应用](../HOW_CORDIS_PORT_WORKS-zh-CN/translation.md#目录)
- [第 09 章 确定性异步模拟](../HOW_CORDIS_PORT_WORKS-zh-CN/translation.md#目录)
- [第 10 章 异步失败与恢复](../HOW_CORDIS_PORT_WORKS-zh-CN/translation.md#目录)
- [第 11 章 重入纪元收敛](../HOW_CORDIS_PORT_WORKS-zh-CN/translation.md#目录)
- [第 12 章 副作用树可视化](../HOW_CORDIS_PORT_WORKS-zh-CN/translation.md#目录)