# Cordis Rebol 移植版工作原理

本书将带你深入探索 Cordis 的 Rebol3 移植版。这是一次硬核的真实工程翻译之旅，绝非走马观花的营销宣传。整个源码树非常精简，足以让人从头到尾通读，但它最吸引人的地方并不在于体量的小巧。真正的重点在于：一个原本严重依赖 `Proxy`、装饰器、可调用服务以及异步 Fiber 的框架，是如何在一门完全没有直接提供这些机制的语言中被重写出来的。

我们将顺着一条核心依赖主干，从根节点的构建一路剖析到可运行的示例。每一章都紧密贴合 [`../`](../) 目录下的真实代码文件，并且都在各自的 `code/` 目录下配有一个小巧的可运行实验。

从这里开始：

```bash
cd how-cordis-port-works/ch01-context-root/code && bash run.sh
cd how-cordis-port-works && ./verify-all.sh
```

连贯的前言与章节导读位于 [HOW_CORDIS_PORT_WORKS.md](./HOW_CORDIS_PORT_WORKS.md)。