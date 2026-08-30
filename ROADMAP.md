# Cordis → Rebol3 Porting Roadmap (cordis-rebol)

上游参考: cordiverse/cordis @ master, `packages/core` (9 个源文件, 1897 行)
本地参考: `~/Projects/cordis-port/ref/core/*.ts` + `ref/tests/*.spec.ts` (jsDelivr 拉取)
配套论文/文档: `~/Projects/deepseek-harness/docs/cordis-primer*.md`

## 1. 结论

**module-by-module, 先实现核心 (@cordisjs/core 全集)。** 不做 commit-by-commit:
历史噪音 (TS 特有 churn) 与语义鸿沟 (class/decorator/Proxy → context/make) 使 git
历史无法作为翻译路径; 终态架构才是翻译对象。历史仅作 consultative 参考。

核心源码体量小 (1897 行), 整包移植是可行的。真正的难点不在行数, 而在 4 个
JS 特有机制的语义映射 (见 §4)。

## 2. 上游结构 (packages/core)

| 文件 | LOC | 角色 | Rebol 落法 |
|---|---|---|---|
| utils.ts | 278 | DisposableList, symbols, **traceable Proxy 机制**, composeError, createCallable | 只留 DisposableList + 错误助手; **traceable 机制整体丢弃** (§4.2) |
| events.ts | 178 | EventsService: on/once/emit/parallel/serial/bail/waterfall + internal/* 钩子 | 原样移植; 变参事件 → block 参数 (§4.5) |
| fiber.ts | 486 | **Fiber 状态机**: effect()/epoch/_reload/_unload/_refresh | 核心移植对象; 同步化 (无 Promise) |
| reflect.ts | 281 | ReflectService: **Context Proxy handler**, provide/get/set/accessor/mixin/notify | Proxy → 显式方法; store/props 用 map! (§4.1) |
| registry.ts | 214 | RegistryService: plugin()/inject(), Inject.resolve, Plugin runtime | 原样移植; decorator → 声明式 inject 字段 |
| service.ts | 80 | Service 基类: provide/check/extend/resolveConfig | 原样移植 (对象化); createCallable → 简化 |
| context.ts | 78 | Context 类 + 构造顺序 + extend/isolate/intercept | 原样移植 (对象化) |
| logger.ts | 246 | LoggerService (callable, exporters, formatter) | **最后移植或 stub**; 与核心语义无关 |
| index.ts | 7 | 导出 | 聚合文件 |

## 3. 依赖 DAG 与加载顺序

运行期引用呈循环 (fiber ↔ registry ↔ reflect ↔ context), 但全部发生在**方法体内**
(call time)。Rebol 函数体晚绑定 — 只要加载时不调用, 文件加载顺序即拓扑序:

```
utils.reb ──→ events.reb ──→ fiber.reb ──→ reflect.reb ──→ registry.reb
                                                              │
context.reb ←── service.reb ←─────────────────────────────────┘
   │
   └──→ logger.reb (可最后/stub)
```

**Context 构造顺序 (必须保持)**: fiber(root) → reflect → registry → events → logger
→ fiber/_disposables clear。root fiber 先行 (runtime=none, state=ACTIVE, uid=0)。

注意: 加载期禁止调用任何引用后加载文件的函数 (模块级副作用仅限定义)。

## 4. 翻译决策 (最关键)

### 4.1 Proxy handler → 显式访问 (核心创意的最简落法)

TS 的 `new Proxy(this, ReflectService.handler)` 做三件事:
1. 未声明属性 → service 查找 (fiber 链上溯)
2. 特殊属性 (symbol/数字/`_` 前缀) → 直通
3. get/set 触发 `internal/get`/`internal/set` waterfall (可被插件拦截)

Rebol 无 Proxy。**简化映射**: 服务直接作为 context 对象的字段
(`ctx/events` `ctx/logger` `ctx/reflect` `ctx/registry` 等), 路径访问即查找;
"cannot get property without inject" 的报错语义由 fiber 层保留
(注入依赖缺失 → 插件不启动, 见 4.3)。`internal/get`/`internal/set` 拦截钩子
v1 不做 (记入限制)。

### 4.2 traceable Proxy 机制 → 显式 ctx 传递 (整体丢弃)

utils.ts 的 createTraceable/withProps/createShadow/createShadowMethod 是 cordis
最深的 JS 魔法: 用嵌套 Proxy 让 service 方法调用时自动把 `this.ctx` 换成**当前**
context, 并给方法调用者一个 shadow context。这是 JS `this` 语义的产物。

Rebol 无 `this`、无 Proxy。**直接丢弃**: service 持有自己的 ctx 字段, 插件代码
显式闭包 ctx。语义等价 (方法内 `ctx/xxx` 与调用者一致), 代码量大幅下降。

### 4.3 Fiber 状态机 + epoch 反应式 (必保, 核心反共识)

这是 cordis 的灵魂: 插件注入依赖; 依赖全部可用 → 启动 (PENDING→LOADING→ACTIVE);
任一依赖消失 → 卸载 (→UNLOADING); 依赖回来 → 重启。epoch = 各依赖 impl uid 的
拼接串; 任何 provide/dispose 通知 → notify → _checkImpl → _refresh → epoch 变化
→ _setEpoch → reload/unload。

Rebol 落法: fiber 为 object!, epoch 为 string!, 状态为整数枚举, 全部同步。
**必须保持**: (a) effect() 收集 disposer, 卸载时**逆序**执行; (b) provide 的
notify 遍历所有注入该服务的 fiber; (c) check 函数门控可用性。

### 4.4 装饰器/类/生成器 → 声明式

- `@Inject` class decorator → plugin 对象字段 `inject: [foo bar]` (block of words)
- `@Service.init` 方法 → plugin 回调本身 (启动); 返回 disposer (停止)
- 生成器 effect (yield disposer) → 改为**返回 block of disposers**
- `class Foo extends Service` → `make service-type [...]` 原型继承 (skill 模式)
- `Symbol` 键 → 带前缀的 word! 键 (`'cordis/isolate` 等)

### 4.5 变参事件 → block 参数

`emit(name, ...args)` 变参在 Rebol 里用 func 的 `/args`? 不 — Oldes refinement
有 bug。**约定: 事件负载统一为单个 block 参数**: `emit 'foo [a b c]`。
listener 签名 `call: func [args [block!]]`。内部事件 (internal/*) 负载固定, 同样
block 化。五种分发模式 (emit/parallel/serial/bail/waterfall) 全部保留; parallel
在同步版里 = emit (无并发), serial = 顺序直到 bail, bail = 首个非空即返回,
waterfall = 链式 next。

### 4.6 隔离/拦截链 → 链表式 map 链

`ctx.isolate(name)` / `ctx.intercept(name, config)` 用 `Object.create` 原型链
做不可变 shadowing。Rebol map! 无原型链 → 用**链式 block** `[map1 map2 ...]`
(头部为最新), 查找 = 顺序遍历首个命中; resolveConfig = 逆序收集合并。

### 4.7 函数存储 (Oldes 特有约束)

map!/block! 存 function! 会自动求值 → **一切回调存为 object! 方法**
(`make object! [call: func [args [block!]] [...]]`), 或存 word! 名间接调用。
disposer 同理: `make object! [dispose: func [][...]]`。

### 4.8 R3 行为陷阱 (Phase 5–6 实测)

1. **`do %file` 的嵌套相对路径会 rebase 到该脚本所在目录**。fixture 里再 `do`
   别的文件要用 `%../../agent-loop/api.reb` 这种相对自身目录的前缀, 不能假设
   继承调用者的 cwd。reload fixture / 测试脚本都受影响。
2. **`make map! [...]` 不求值 spec**: paren 原样存成 paren!, `'lit-word` 存成
   lit-word。需要求值用 `make map! compose [...]`; 测试里构造消息 map 一律用
   `put m 'kind 'tool-call` 逐键赋值, 别用 spec 块。
3. **函数参数无自动分组**: `put handle to-word name svc` 会把 `to-word` 这个
   函数本身当第二个参数, `name` 当第三个, `svc` 悬空——静默写错键。复合表达式
   作参数必须加括号: `put handle (to-word name) svc`。
4. **`make object!` 后给不存在的字段赋值报 invalid-path**: `make-service` 内部
   写 `svc-obj/name:`, 所以自定义 service object 必须预声明 `name: none`
   (llm 适配器 fixture 踩过)。
5. **r3 `print` 输出 UTF-8 中文到终端变 `?`**: examples 的 stdout 文案用英文,
   注释保留中文。

## 5. 实施阶段

| 阶段 | 交付 | 验证 (移植自 spec) |
|---|---|---|
| P0 spike ✅ | fiber+events+reflect+registry+context 最小可运行 | **17/17 通过**: pending→provide→run; unprovide→dispose; re-provide→restart; 嵌套清理 LIFO; emit/bail/once |
| P1 utils.reb | DisposableList, 错误助手, symbols | — |
| P2 events.reb | 5 模式分发 + internal/listener | events.spec: emit/serial/bail/waterfall/once |
| P3 fiber.reb | 状态机 + effect + epoch | fiber.spec, dispose.spec, invoke.spec |
| P4 reflect.reb | provide/get/set/accessor/mixin/notify | reflect.spec, service.spec |
| P5 registry.reb | plugin()/inject() + runtime | plugin.spec, associate.spec |
| P6 context.reb ✅ | Context + isolate/intercept + 构造顺序 | isolate.spec → 22/22 |
| P7 service.reb ✅ | Service 基类 + resolveConfig | service.spec → 16/16 |
| P8 logger.reb ✅ | LoggerService (可 stub) | logger.spec → 18/18 |

**全部 8 阶段完成 (2026-08-18): 223 断言全绿。**
累计: utils 22 + events 21 + fiber 55 + reflect 28 + registry 41 + context 22 + service 16 + logger 18。

每阶段验收: `rebol3 -s <file>.reb` 通过 + 对应 spec 的行为断言通过, 再进下一阶段。

## 8. P0 spike 验证结果与发现

`spike/core-spike.reb` (v0.2.0) — 17/17 断言通过:

- **pending inject 反应式**: 注入 'foo 未提供时插件不启动; provide 后立即启动;
  unprovide 后 disposer 运行 (停止); 重新 provide 再次启动 (epoch :0 → inactive → :0:0)
- **嵌套清理顺序 (反直觉发现)**: cordis 上游 fiber 清理是 **LIFO** — 外层 fiber 的
  disposables = [inner-wrapper, outer-plugin-disposer] (inner wrapper 在 outer apply
  期间先入列), 逆序执行 → **父插件自身 disposer 先于子插件卸载**。spike 行为与
  JS 源码语义逐行比对一致; 初版测试按"子先于父"的直觉写, 是测试错了不是代码错。
- **事件**: emit/bail/once 通过; waterfall 已实现 (internal/update 用) 待 P2 验证

### 新增 Rebol3 坑点 (spike 中发现, 已回写 skill)

1. **`#()` 空 map 字面量完全不可用** — 独立表达式也 malconstruct, 一律 `make map! []`
2. **`make object! [x: x]` RHS 被新对象自身字段遮蔽** — `parent/registry/counter`
   里的 parent 解析到 fiber-type 的 `parent: none` 字段 → 创建后赋值或闭包捕获
3. **make object! 方法对创建函数局部的闭包只在帧存活期有效** — 对象被返回、帧销毁后
   调用方法报 "word is not bound to a context" → 长生命周期对象必须自包含:
   状态存字段, 方法只引用字段 (bare word 解析到对象自身上下文 ✓)
4. **`[name]` 字面量 block 不求值** — `notify-impls [name]` 传的是 word, 用
   `notify-impls reduce [name]`
5. **Rebol 对象不能 set-path 添加不存在字段** — 先 `make object! [a: none b: none]`
   再赋值
6. **LIFO 清理语义** (上游 cordis): fiber 卸载 = disposables 逆序执行; 父插件
   disposer 先于子插件卸载 — 移植测试时不要按"子先于父"直觉断言

## 6.5 生命周期研究里程碑

| 里程碑 | 状态 | 说明 |
|---|---|---|
| M0 runtime scope / journal | ✅ | `runtime-scope.reb` + scenarios/m0-* |
| M1 deterministic scheduler | ✅ | inertia / failure / reentrant / effect-tree |
| **M2 Entry Reconciler** | ✅ | `loader/reconcile.reb`：按稳定 id 增量 mount/update/dispose；`test/reconcile-test.reb` 27/27 |
| M3 dual-mode HMR | ⏳ | `reload-plugin` 已有原子回滚；兼容 FAILED 模式未做 |

## 7. 已知限制 (v1 同步版)

- 无 Promise: `fiber.await()`/`plugin()` 的 thenable 语义 → 同步执行; async init
  (Service.init 挂起直到事件) 不支持 — 记入限制
- 无 Proxy: internal/get|set 拦截、traceable 上下文穿透不支持
- 无 generator: effect 支持 函数/block-of-disposers/none, 不支持惰性迭代
- 无 async iterator: _reload/_unload 全同步
- logger 格式化/exporters 简化

## 7. 参考

- 上游源码: `ref/core/*.ts` (jsDelivr, 与 master 同步)
- 行为规格: `ref/tests/*.spec.ts` (vitest 用例 = 移植验收标准)
- deepseek-harness 的 cordis-primer (README 链接的官方文档)
- Rebol3 坑点: mini-code-agent skill (rebol3-code-generation-guide.md)
