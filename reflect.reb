REBOL []

; ============================================================
; reflect.reb — cordis ReflectService 的 Rebol3 移植 (P4 + P6 isolate)
; 上游: ref/core/reflect.ts (281 行) + isolate 语义
;
; 语义映射:
;   - Proxy handler → 显式方法 (ROADMAP §4.1)
;   - store 键 = isolate 标签 + name (isolate 链, ROADMAP §4.6):
;     "iso-xxx/foo" 字符串键; root 默认标签 'default
;   - 方法显式接收 act-ctx (上游 traceable 隐式, Rebol 显式)
;   - provide → fiber.effect 注册 impl + notify; 返回 disposer
;   - notify → 遍历 all-fibers, 同 isolate 标签的注入 fiber 才响应
;   - accessor/mixin → 简化
;   - trace/bind → 原样返回 (traceable 丢弃)
;
; 关键约束: 回调存 wrapper 对象; 对象比较用 same?; make map! 用 compose
; ============================================================

do %./utils.reb
do %./events.reb
do %./fiber.reb

; ------------------------------------------------------------
; isolate 辅助
; ------------------------------------------------------------

default-isolate: 'default

; ctx 的 isolate 标签 (name → label)
ctx-isolate-label: func [ctx [object!] name [word!] /local m] [
    m: select ctx 'isolate-map
    either m [
        any [select m name  default-isolate]
    ][default-isolate]
]

; store 键 = "label/name" (字符串键, 隔离不同 ctx 的同类服务)
isolate-store-key: func [ctx [object!] name [word!]] [
    rejoin [ctx-isolate-label ctx name  "/"  to-string name]
]

; ------------------------------------------------------------
; notify — 通知同 isolate 标签下注入该服务的所有 fiber
; ------------------------------------------------------------

reflect-notify: func [svc [object!] names [block!] act-ctx [object!] /local fb name updated impl] [
    foreach fb all-fibers [
        updated: false
        foreach name names [
            if find keys-of fb/inject name [
                ; filter: 同 isolate 标签才响应
                if equal? ctx-isolate-label fb/ctx name  ctx-isolate-label act-ctx name [
                    updated: true
                    fiber-check-impl fb name
                ]
            ]
        ]
        if updated [fiber-refresh fb]
    ]
    ; internal/service 事件
    foreach name names [
        impl: svc/get-impl name false act-ctx
        svc/ctx/events/emit 'internal-service reduce [name  either impl [impl/value][none]] none
    ]
    none
]

; ------------------------------------------------------------
; ReflectService 工厂
; ------------------------------------------------------------

make-reflect-service: func [root-ctx [object!] /local svc] [
    svc: make object! [
        ctx: root-ctx
        store: make map! []      ; "label/name" → impl
        props: make map! []      ; name → 属性声明 map!

        ; ----------------------------------------------------
        ; 查询 (显式 act-ctx)
        ; ----------------------------------------------------
        get-impl: func [name [word!] strict [logic!] act-ctx [object!] /local key impl] [
            key: isolate-store-key act-ctx name
            impl: select self/store key
            either impl [
                either all [strict  not equal? impl/fiber/state fiber-state/ACTIVE] [none][impl]
            ][none]
        ]

        get: func [name [word!] strict [logic!] act-ctx [object!] /local impl] [
            impl: get-impl name strict act-ctx
            either impl [impl/value][none]
        ]

        ; provide during LOADING skips notify; fiber-notify-active calls this on ACTIVE
        notify: func [names [block!] act-ctx [object!]] [
            reflect-notify self names act-ctx
        ]

        set: func [name [word!] value act-ctx [object!] /local key impl] [
            key: isolate-store-key act-ctx name
            impl: select self/store key
            unless impl [
                return reflect-error rejoin ["cannot set property " to-string name " without provide"]
            ]
            if not same? impl/fiber act-ctx/fiber [
                return reflect-error rejoin ["cannot set property " to-string name " in multiple fibers"]
            ]
            impl/value: value
            true
        ]

        ; ----------------------------------------------------
        ; provide — 注册服务 (fiber.effect, 卸载自动清理)
        ; ----------------------------------------------------
        provide: func [name [word!] value check [object! none!] act-ctx [object!] /local ex] [
            ; 坑点: make object! 内 self = 新对象自身 → 先取 ex 帧局部
            ex: func [/local svc-obj key] [
                svc-obj: self
                key: isolate-store-key act-ctx name
                ; props 声明
                p: select svc-obj/props name
                either p [
                    if not equal? select p 'type "service" [
                        print rejoin ["[ReflectError] property " to-string name " is already declared as " select p 'type]
                        return none
                    ]
                ][
                    put svc-obj/props name make map! [type: "service"]
                ]
                ; 重复注册检查 (同 isolate)
                if select svc-obj/store key [
                    print rejoin ["[ReflectError] service " to-string name " has been registered"]
                    return none
                ]
                impl: make object! [name: none value: none fiber: none check: none]
                impl/name: name
                impl/value: value
                impl/fiber: act-ctx/fiber
                impl/check: check
                put svc-obj/store key impl
                unless act-ctx/fiber/store [act-ctx/fiber/store: make map! []]
                put act-ctx/fiber/store name impl
                if equal? act-ctx/fiber/state fiber-state/ACTIVE [
                    reflect-notify svc-obj reduce [name] act-ctx
                ]
                ; disposer — 自包含 (svc-ref/key-ref 字段)
                make object! [
                    svc-ref: svc-obj
                    key-ref: key
                    name-ref: name
                    ctx-ref: act-ctx
                    dispose: func [] [
                        svc-ref/store: map-remove-key svc-ref/store key-ref
                        reflect-notify svc-ref reduce [name-ref] ctx-ref
                        if ctx-ref/fiber/store [
                            ctx-ref/fiber/store: map-remove-key ctx-ref/fiber/store name-ref
                        ]
                        none
                    ]
                ]
            ]
            act-ctx/fiber/effect :ex rejoin ["ctx.provide(" to-string name ")"]
        ]

        ; ----------------------------------------------------
        ; accessor — 声明访问器属性 (get/set 为 wrapper 对象)
        ; ----------------------------------------------------
        accessor: func [name [word! lit-word!] options [map!] /local ex] [
            ex: func [/local svc-obj] [
                svc-obj: self
                if select svc-obj/props name [
                    print rejoin ["[ReflectError] property " to-string name " already declared"]
                    return none
                ]
                put svc-obj/props name make map! compose/deep [
                    type: "accessor"
                    get: (select options 'get)
                    set: (select options 'set)
                ]
                make object! [
                    svc-ref: svc-obj
                    name-ref: name
                    dispose: func [] [
                        svc-ref/props: map-remove-key svc-ref/props name-ref
                        none
                    ]
                ]
            ]
            self/ctx/fiber/effect :ex rejoin ["ctx.accessor(" to-string name ")"]
        ]

        ; ----------------------------------------------------
        ; mixin — 委托 accessor: ctx.<key> 从 source 服务取字段
        ; ----------------------------------------------------
        mixin: func [source [word!] mixins [block!] /local ex] [
            ex: func [/local svc-obj key get-w raw-key] [
                svc-obj: self
                foreach raw-key mixins [
                    ; lit-word 键与对象字段 word 不匹配 → to-word
                    key: to-word raw-key
                    get-w: make object! [
                        svc-ref: svc-obj
                        src: source
                        k: key
                        call: func [args [block!] this-arg [object! none!] /local impl s act] [
                            ; 显式版: 从 reflect store 取服务 (无 Proxy 字段)
                            act: either this-arg [this-arg][svc-ref/ctx]
                            impl: svc-ref/get-impl src true act
                            either impl [
                                s: impl/value
                                either s [select s k][none]
                            ][none]
                        ]
                    ]
                    svc-obj/accessor key make map! compose/deep [
                        get: (get-w)
                        set: (none)
                    ]
                ]
                none
            ]
            self/ctx/fiber/effect :ex rejoin ["ctx.mixin(" to-string source ")"]
        ]

        ; ----------------------------------------------------
        ; trace/bind — traceable 丢弃, 原样返回
        ; ----------------------------------------------------
        trace: func [value] [value]
        bind: func [value] [value]
    ]
    svc
]

; ------------------------------------------------------------
; 错误助手
; ------------------------------------------------------------

reflect-error: func [msg [string!]] [
    rejoin ["[ReflectError] " msg]
]
