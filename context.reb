REBOL []

; ============================================================
; context.reb — cordis Context 的 Rebol3 移植 (P6)
; 上游: ref/core/context.ts (78 行)
;
; 语义映射:
;   - Context 构造顺序 (ROADMAP §3): fiber → reflect → registry → events
;     → logger → 替换 root fiber disposables (对齐 _disposables.clear())
;   - Proxy handler → 显式方法 (reflect/registry/events 方法均收 act-ctx)
;   - extend(meta) → make-child-ctx (复制/覆盖字段)
;   - isolate(name, label) → 新 ctx + isolate-map (链式 map, ROADMAP §4.6)
;     reflect store 键 = label/name, 同标签共享服务
;   - intercept(name, config) → 新 ctx + intercept-map (声明链, P7 消费)
;   - Context.is → ctx 标记字段
;
; 约束: 方法自包含 (闭包 root-ref 字段); make map! 用 compose
; ============================================================

do %./utils.reb
do %./events.reb
do %./fiber.reb
do %./reflect.reb
do %./registry.reb

; ------------------------------------------------------------
; 子 ctx 工厂 — extend 的基础 (root-ref 字段闭包, 支持嵌套)
; ------------------------------------------------------------

make-child-ctx: func [root-ctx [object! none!] props [map!] /local new root-ref] [
    ; root-ref = 真正的根 (向上追溯); 继承参数 root-ctx = 直接父 ctx
    root-ref: either root-ctx [any [select root-ctx 'root-ref  root-ctx]][none]
    new: make object! [
        fiber: none
        events: none
        registry: none
        reflect: none
        logger: none
        filter: none
        root-ref: none
        isolate-map: make map! []     ; name → label word
        intercept-chain: copy []      ; [leaf ... root] 链式 block, 头部最新 (ROADMAP §4.6)
        extra: make map! []           ; extend 的未知字段 (对象不能动态加字段)
        ctx-marker: true              ; Context.is 标记

        ; 继承 self (直接父 ctx) 而非 root-ref — 隔离链依赖调用者
        extend: func [p [map!]] [make-child-ctx self p]

        ; isolate: 复制 isolate-map + 设标签 → 新 ctx
        isolate: func [name [word!] label [word! none!] /local m] [
            m: copy isolate-map
            put m name either label [label][to-word rejoin ["iso-" to-string name "-" random 99999]]
            extend make map! compose [isolate-map: (m)]
        ]

        ; intercept: 头部插入本层 map (链式 shadowing) → 新 ctx
        ; 坑点: make map! [k: (block)] 会把 block 值当嵌套 map 解析 → 用 put 存
        intercept: func [name [word!] config /local m chain props] [
            m: make map! []
            put m name config
            chain: compose [(m) (intercept-chain)]
            props: make map! []
            put props 'intercept-chain chain
            extend props
        ]
    ]
    either root-ctx [
        ; 继承父的 isolate/intercept 链 (隔离语义核心)
        new/isolate-map: either select props 'isolate-map [select props 'isolate-map][copy root-ctx/isolate-map]
        new/intercept-chain: either select props 'intercept-chain [select props 'intercept-chain][copy root-ctx/intercept-chain]
        new/fiber: any [select props 'fiber  root-ctx/fiber]
        new/events: root-ctx/events
        new/registry: root-ctx/registry
        new/reflect: root-ctx/reflect
        ; logger: 若 logger.reb 已加载则重建 (绑定新 ctx, 对齐上游新 Context 新 LoggerService,
        ; 使 intercept/isolate 后的 logger 能解析新 chain); 否则共享父 (旧测试无 logger 依赖)
        new/logger: either all [
            value? 'make-logger-service
            select props 'intercept-chain
        ] [make-logger-service new] [root-ctx/logger]
        new/filter: select props 'filter
        new/root-ref: root-ref
        ; 未知字段存入 extra (对象不能动态添加字段)
        foreach [k v] props [
            unless find [fiber events registry reflect logger filter isolate-map intercept-chain root-ref] k [
                put new/extra k v
            ]
        ]
    ][
        new/filter: select props 'filter
    ]
    new
]

; ------------------------------------------------------------
; Root Context 工厂
; 构造顺序: fiber → reflect → registry → events → logger
; 构造完成后替换 root fiber disposables (丢弃 internal handler wrapper)
; ------------------------------------------------------------

make-context: func [/local ctx rf] [
    ctx: make-child-ctx none make map! []
    ctx/root-ref: ctx
    rf: make-fiber-root ctx
    ctx/fiber: rf
    ctx/reflect: make-reflect-service ctx
    ctx/registry: make-registry-service ctx
    ctx/logger: make-logger-service ctx   ; P8: LoggerService (buffer + exporters)
    ctx/events: make-events-service ctx
    ; 对齐上游 context.ts: fiber._disposables.clear() → 替换列表
    ctx/fiber/disposables: make-disposable-list
    ctx
]

; ------------------------------------------------------------
; Context.is
; ------------------------------------------------------------

context-is: func [value] [
    either object? value [
        not none? select value 'ctx-marker
    ][false]
]
