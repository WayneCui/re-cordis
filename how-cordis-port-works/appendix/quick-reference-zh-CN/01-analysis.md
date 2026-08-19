# 内容分析 (Analysis)

- **领域 (Domain)**: 软件工程、框架移植参考手册。
- **语调 (Tone)**: 技术总结，言简意赅，适合作为速查表。
- **术语 (Terminology)**:
  - Fiber = 保留原词
  - Provider/Consumer, surprise （本文未直接出现，但若有变体需遵守规则）
  - make-context = `make-context`
  - Reflect, Service, Logger 等作为专有名词保留
- **翻译挑战 (Translation Challenges)**:
  - 在极简的表格结构中，将抽象的英文模型（Mental Models）准确翻译成高度概括的中文。
  - 确保 "A fiber is a revocable lease on plugin effects." 译为类似 "Fiber 是对插件副作用的一份可撤销租约。" 的流畅句子。