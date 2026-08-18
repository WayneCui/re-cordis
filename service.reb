REBOL []

; ============================================================
; service.reb — cordis Service 基类的 Rebol3 移植 (P7)
; 上游: ref/core/service.ts (80 行) + logger.ts _resolveConfig (intercept 消费)
;
; 语义映射:
;   - JS class extends Service → Rebol 服务对象 + make-service 工厂
;   - 构造自动注册: super(ctx, name) → reflect.provide(name, self, check)
;   - resolveConfig(base, head) → 遍历 ctx/intercept-chain 收集本服务
;     name 的配置 + base/head, 合并 (Config.merge 优先, 否则后者覆盖前者)
;   - symbols (init/check/config/invoke/extend/tracker) → 约定字段:
;       init   object! [call: func [args this-arg] [...]]   (插件加载时执行)
;       check  object! [call: ...]                          (reflect check)
;       Config object! [merge: wrapper] 或 map!             (配置合并/默认)
;   - 无 class/原型链: 服务对象字段自包含, 方法引用 self
;
; 约束: make map! 用 put (block 值会被嵌套 map 解析); 回调一律 wrapper 对象
; ============================================================

do %./utils.reb
do %./events.reb
do %./fiber.reb
do %./reflect.reb
do %./registry.reb
do %./context.reb

; ------------------------------------------------------------
; Service 构造 — 注册服务到 reflect + 注入 ctx/name
; 上游: super(ctx, name) → this.name = name; reflect.provide(name, self, check)
; Rebol: make-service ctx name svc-obj (名字显式传, 对齐 super(ctx, name))
; svc-obj 约定 (用户构造, 必须声明字段):
;   name: none   (构造时注入 word!)
;   ctx: none    (构造时注入)
;   check: object! [call: ...] (可选, 服务值检查)
;   init: object! [call: ...]  (可选, 插件加载钩子 — 用户自行在 apply 调用)
;   Config: object! [merge: wrapper] (可选, resolveConfig 合并器)
; ------------------------------------------------------------

make-service: func [ctx [object!] name [word!] svc-obj [object!] /local check] [
    svc-obj/ctx: ctx
    svc-obj/name: name
    ; 注册服务 (check 原样传递, reflect.provide 的 check 参数就是 wrapper 对象)
    check: select svc-obj 'check
    ctx/reflect/provide name svc-obj check ctx
    svc-obj
]

; ------------------------------------------------------------
; Service.resolveConfig(base, head) 移植
; 上游: 遍历 intercept 原型链收集 name 的 config, 逆序 unshift (根在前),
;       base unshift 最前, head push 最后; Config.merge 或 Object.assign
; Rebol: intercept-chain = [leaf ... root] block, 顺序遍历收集,
;       configs = [base 根 ... 叶 head], 合并时后者覆盖前者
; ------------------------------------------------------------

service-resolve-config: func [svc [object!] base head /local chain configs m cfg conf mw merged] [
    chain: select svc/ctx 'intercept-chain
    unless chain [chain: copy []]
    configs: copy []
    ; 从叶到根遍历, insert 头部 → configs = [根 ... 叶] (上游 unshift 语义)
    foreach m chain [
        cfg: select m svc/name
        if not none? cfg [insert configs cfg]
    ]
    if not none? base [insert configs base]
    if not none? head [append configs head]
    ; Config.merge 优先 (wrapper 对象)
    conf: select svc 'Config
    if conf [
        mw: select conf 'merge
        if mw [return mw/call configs none]
    ]
    ; 默认合并: 后者覆盖前者
    merged: make map! []
    foreach m configs [
        if map? m [
            foreach [k v] m [put merged k v]
        ]
    ]
    merged
]

; ------------------------------------------------------------
; Service.extend(props) 移植 — 复制服务实例 + 覆盖字段
; 上游: Object.create(this) + Object.assign(props)
; Rebol: make-service 包装新对象 (引用原 ctx), props 字段经 extra 存储
; 简化: 直接创建新对象, 复制已知字段 (自包含字段列表)
; ------------------------------------------------------------

service-extend: func [svc [object!] props [map!] /local new k v] [
    new: make object! [
        ctx: svc/ctx
        name: svc/name
        value: none
        extra: make map! []   ; 未知字段 (对象不能动态加字段)
    ]
    ; 复制已知字段 (自包含列表)
    foreach k [ctx name value] [
        v: select svc k
        if not none? v [set-path [new k] v]
    ]
    foreach [k v] props [
        unless find [ctx name value] k [put new/extra k v]
    ]
    new
]

; ------------------------------------------------------------
; Service.filter(ctx) 移植 — 同 isolate 标签过滤
; 上游: ctx[symbols.isolate][name] === this.ctx[symbols.isolate][name]
; Rebol: ctx-isolate-label (reflect.reb) 比较
; ------------------------------------------------------------

service-filter: func [svc [object!] other [object!]] [
    equal? ctx-isolate-label svc/ctx svc/name  ctx-isolate-label other svc/name
]
