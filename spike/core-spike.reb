REBOL [
    Title:   "Cordis Core P0 Spike (Rebol3)"
    Date:    18-Aug-2026
    Version: 0.2.0
    Author:  "Hermes Agent"
    License: "MIT"
]

; ============================================================
; Cordis core 最小可运行移植 spike
; 目标: 证明 4 个核心反共识机制在 Rebol 中可落地
;   1. fiber 状态机 + epoch 反应式 (依赖可用->启动, 消失->卸载, 回来->重启)
;   2. effect() 作用域清理 (卸载时逆序执行 disposer)
;   3. 事件 5 模式分发 (emit/bail/waterfall, 负载 block 化)
;   4. provide/notify 服务注册与通知
; 参考: cordiverse/cordis packages/core (fiber.ts/reflect.ts/events.ts/registry.ts)
;
; 关键 Rebol 约束 (Oldes):
;   - 不存 function! 于 map/block (自动求值) -> 回调一律 object! [call: ...]
;   - 不用 #() 空 map 字面量 (malconstruct) -> make map! []
;   - make object! [x: x] 的 RHS 被新对象字段遮蔽 -> 闭包捕获或创建后赋值
; ============================================================

; ---------- 常量 ----------
inactive-epoch: "__INACTIVE__"

fiber-state: context [
    PENDING: 0
    LOADING: 1
    ACTIVE: 2
    FAILED: 3
    DISPOSED: 4
    UNLOADING: 5
]

; ---------- 全局 ----------
all-fibers: copy []          ; 所有 plugin fiber (notify 用)
pass-count: 0
fail-count: 0

; ---------- 工具 ----------
check: func [label [string!] cond [logic!]] [
    either cond [
        pass-count: pass-count + 1
        print rejoin ["  PASS  " label]
    ][
        fail-count: fail-count + 1
        print rejoin ["  FAIL  " label]
    ]
]

map-remove: func [m [map!] key [word!] /local nm k v] [
    nm: make map! []
    foreach [k v] m [
        unless to-logic k = key [put nm k v]
    ]
    nm
]

block-remove-same: func [b [block!] v /local i] [
    i: 1
    while [i <= length? b] [
        if same? pick b i v [
            remove at b i
            return b
        ]
        i: i + 1
    ]
    b
]

map-get-block: func [m [map!] key [word!] /local v] [
    v: select m key
    either v [v][copy []]
]

; ============================================================
; 1. events: 5 模式分发 (emit/bail/waterfall), 负载 = 单个 block
;    listener 统一为 object! [call: func [args [block!]] [...]]
; ============================================================
events-on: func [ctx [object!] name [word!] listener [object!]] [
    ; 注册为 fiber effect -> 随 fiber 卸载自动移除
    ; 注意: 返回的 disposer 自包含 (ev-ctx/ev-name/ev-listener 字段),
    ; 因为 Oldes 中方法对创建函数局部的闭包在帧销毁后失效
    fiber-effect ctx/fiber make object! [
        run: func [] [
            hb: select ctx/events/hooks name
            either hb [][
                hb: copy []
                put ctx/events/hooks name hb
            ]
            append hb listener
            make object! [
                ev-ctx: ctx
                ev-name: name
                ev-listener: listener
                dispose: func [] [
                    hb2: select ev-ctx/events/hooks ev-name
                    if hb2 [block-remove-same hb2 ev-listener]
                ]
            ]
        ]
    ] rejoin ["ctx.on(" name ")"]
]

events-emit: func [ctx [object!] name [word!] args [block!]] [
    hb: map-get-block ctx/events/hooks name
    foreach h hb [h/call args]
]

events-bail: func [ctx [object!] name [word!] args [block!] /local hb r] [
    hb: map-get-block ctx/events/hooks name
    foreach h hb [
        r: h/call args
        if r [return r]
    ]
    none
]

; waterfall: 每个 listener 收到 (args, next), next/call args none 继续链
make-waterfall-step: func [hook [object!] next-obj [object!]] [
    make object! [
        step-hook: hook
        step-next: next-obj
        call: func [a [block!] n [object! none!]] [
            step-hook/call a step-next
        ]
    ]
]

events-waterfall: func [ctx [object!] name [word!] args [block!] inner [object!] /local hb i h nxt] [
    hb: copy map-get-block ctx/events/hooks name
    i: length? hb
    nxt: inner
    while [i > 0] [
        h: pick hb i
        nxt: make-waterfall-step h nxt
        i: i - 1
    ]
    nxt/call args none
]

ctx-once: func [ctx [object!] name [word!] listener [object!] /local wl] [
    wl: make object! [
        once-ctx: ctx
        once-name: name
        once-listener: listener
        self-ref: none
        call: func [args [block!]] [
            r: once-listener/call args
            hb: select once-ctx/events/hooks once-name
            if hb [block-remove-same hb self-ref]
            r
        ]
    ]
    wl/self-ref: wl
    events-on ctx name wl
]

ctx-on: func [ctx [object!] name [word!] listener [object!]] [events-on ctx name listener]
ctx-emit: func [ctx [object!] name [word!] args [block!]] [events-emit ctx name args]
ctx-bail: func [ctx [object!] name [word!] args [block!]] [events-bail ctx name args]

; ============================================================
; 2. fiber: 状态机 + effect + epoch
; ============================================================
fiber-type: make object! [
    uid: none
    parent: none
    ctx: none
    config: none
    state: 0
    epoch: none
    inject: none
    runtime: none
    store: none
    disposables: none
    error: none
    inertia: none
]

fiber-effect: func [fb [object!] execute [object!] label [string!] /local local-list result d wrapper] [
    if none? fb/uid [
        print rejoin ["[error] inactive context: " label]
        return none
    ]
    local-list: copy []
    result: execute/run
    either object? result [
        append local-list result
    ][
        if block? result [
            foreach d result [append local-list d]
        ]
    ]
    wrapper: make object! [
        done: false
        items: local-list
        dispose: func [] [
            if done [exit]
            done: true
            foreach d reverse copy items [d/dispose]
        ]
    ]
    append fb/disposables wrapper
    wrapper
]

reload-fiber: func [fb [object!] /local result d] [
    either fb/runtime [
        result: try [fb/runtime/callback/apply fb/ctx fb/config]
        either error? result [
            print rejoin ["[fiber] apply failed: " mold result]
            fb/error: result
            fb/epoch: inactive-epoch
            fb/state: fiber-state/FAILED
        ][
            either object? result [
                append fb/disposables result
            ][
                if block? result [
                    foreach d result [append fb/disposables d]
                ]
            ]
            fb/state: fiber-state/ACTIVE
        ]
    ][
        fb/state: fiber-state/ACTIVE
    ]
]

unload-fiber: func [fb [object!] /local d] [
    foreach d reverse copy fb/disposables [d/dispose]
    fb/disposables: copy []
    either none? fb/uid [
        fb/state: fiber-state/DISPOSED
    ][
        either to-logic fb/epoch = inactive-epoch [
            fb/state: fiber-state/PENDING
        ][
            reload-fiber fb
        ]
    ]
]

set-epoch: func [fb [object!] epoch-str [string!] /local old] [
    old: fb/epoch
    if to-logic epoch-str = old [exit]
    fb/epoch: epoch-str
    if fb/inertia [exit]
    fb/inertia: true
    either to-logic epoch-str = inactive-epoch [
        fb/state: fiber-state/UNLOADING
        unload-fiber fb
    ][
        fb/state: fiber-state/LOADING
        reload-fiber fb
    ]
    fb/inertia: none
    ; 执行期间 epoch 可能被副作用改变 -> 重入检查
    unless to-logic fb/epoch = epoch-str [
        set-epoch fb fb/epoch
    ]
]

check-impl: func [fb [object!] name [word!] /local impl] [
    impl: fb/ctx/reflect/reflect-get-impl name true
    either impl [
        either impl/check [
            either impl/check/call [] [
                put fb/store name impl
            ][
                fb/store: map-remove fb/store name
            ]
        ][
            put fb/store name impl
        ]
    ][
        fb/store: map-remove fb/store name
    ]
]

refresh: func [fb [object!] /local epoch-str name impl] [
    epoch-str: ""
    foreach name keys-of fb/inject [
        impl: select fb/store name
        either impl [
            append epoch-str rejoin [":" impl/fiber/uid]
        ][
            epoch-str: inactive-epoch
            break
        ]
    ]
    set-epoch fb epoch-str
]

extend-ctx: func [parent [object!] /local child] [
    child: make object! [
        fiber: none
        reflect: parent/reflect
        registry: parent/registry
        events: parent/events
        logger: parent/logger
    ]
    child
]

; ============================================================
; 3. reflect: provide/get/unprovide + notify
; ============================================================
reflect-service: make object! [
    ctx: none
    store: none

    reflect-get-impl: func [name [word!] strict [logic!] /local impl] [
        impl: select store name
        either impl [
            either all [strict  not to-logic impl/fiber/state = fiber-state/ACTIVE] [
                none
            ][
                impl
            ]
        ][none]
    ]

    reflect-provide: func [name [word!] value check-fn [object! none!] /local impl] [
        impl: make object! [name: none value: none fiber: none check: check-fn]
        impl/name: name
        impl/value: value
        impl/fiber: ctx/fiber
        put store name impl
        put ctx/fiber/store name impl
        notify-impls reduce [name]
        make object! [
            prov-name: name
            dispose: func [] [
                reflect-unprovide prov-name
            ]
        ]
    ]

    reflect-unprovide: func [name [word!]] [
        store: map-remove store name
        ctx/fiber/store: map-remove ctx/fiber/store name
        notify-impls reduce [name]
    ]
]

notify-impls: func [names [block!] /local fb name] [
    foreach fb all-fibers [
        foreach name names [
            ; 查键存在性 (注入值可能是 none)
            if find keys-of fb/inject name [
                check-impl fb name
                refresh fb
            ]
        ]
    ]
]

; ============================================================
; 4. registry + context
; ============================================================
registry-service: make object! [
    ctx: none
    counter: 0
    runtimes: none

    plugin: func [ctx [object!] plugin [object!] config /local callback runtime-key runtime] [
        callback: plugin
        runtime-key: to-word rejoin ["rt-" ctx/registry/counter]
        runtime: make object! [name: none callback: none fibers: copy [] Config: none]
        runtime/name: plugin/name
        runtime/callback: callback
        put runtimes runtime-key runtime
        make-plugin-fiber ctx plugin config runtime
    ]
]

make-plugin-fiber: func [parent [object!] plugin [object!] config runtime [object!] /local fb child-ctx inject-map wrapper name] [
    inject-map: make map! []
    if block? plugin/inject [
        foreach name plugin/inject [put inject-map name none]
    ]
    child-ctx: extend-ctx parent
    parent/registry/counter: parent/registry/counter + 1
    fb: make fiber-type []
    fb/uid: parent/registry/counter
    fb/parent: parent
    fb/ctx: child-ctx
    fb/config: config
    fb/inject: inject-map
    fb/runtime: runtime
    fb/state: fiber-state/PENDING
    fb/epoch: inactive-epoch
    fb/store: make map! []
    fb/disposables: copy []
    child-ctx/fiber: fb
    append runtime/fibers fb
    append all-fibers fb

    ; dispose wrapper 注册在 parent fiber 上 (JS: this.dispose = parent.fiber.effect(...))
    wrapper: fiber-effect parent/fiber make object! [
        run: func [] [
            make object! [
                target-fb: fb
                dispose: func [] [
                    if none? target-fb/uid [exit]
                    target-fb/uid: none
                    block-remove-same target-fb/runtime/fibers target-fb
                    set-epoch target-fb inactive-epoch
                    if to-logic target-fb/epoch = inactive-epoch [target-fb/state: fiber-state/DISPOSED]
                ]
            ]
        ]
    ] "ctx.plugin()"

    ; 初始 refresh: 无依赖 -> 立即加载; 有依赖未就绪 -> 保持 PENDING
    refresh fb
    wrapper
]

make-fiber-root: func [root [object!] /local fb] [
    fb: make fiber-type []
    fb/uid: 0
    fb/parent: root
    fb/ctx: root
    fb/state: fiber-state/ACTIVE
    fb/epoch: ""
    fb/runtime: none
    fb/store: make map! []
    fb/disposables: copy []
    fb/inject: make map! []
    fb
]

make-root-context: func [/local root root-fiber] [
    root: make object! [fiber: none reflect: none registry: none events: none logger: none]
    root-fiber: make-fiber-root root
    root/fiber: root-fiber
    root/reflect: make reflect-service [ctx: root]
    root/reflect/store: make map! []
    root/registry: make registry-service [ctx: root]
    root/registry/runtimes: make map! []
    root/events: make object! [hooks: none]
    root/events/hooks: make map! []
    root/logger: make object! [
        error: func [e] [print rejoin ["[logger:error] " mold e]]
        info: func [e] [print rejoin ["[logger:info] " mold e]]
    ]
    root
]

; ============================================================
; 测试
; ============================================================
test-1: func [/local order root foo-plugin fb] [
    print "--- Test 1: pending inject -> provide -> unprovide -> re-provide"
    order: copy []
    root: make-root-context
    foo-plugin: make object! [
        name: "foo-plugin"
        inject: ['foo]
        apply: func [ctx [object!] config] [
            append order 'start-foo
            make object! [dispose: func [][append order 'stop-foo]]
        ]
    ]
    fb: root/registry/plugin root foo-plugin make map! []
    check "not started before provide" to-logic 0 = length? order
    root/reflect/reflect-provide 'foo "foo-value" none
    check "started after provide" to-logic 1 = length? order
    check "started first" to-logic 'start-foo = first order
    root/reflect/reflect-unprovide 'foo
    check "stopped after unprovide" to-logic 2 = length? order
    check "stopped second" to-logic 'stop-foo = second order
    root/reflect/reflect-provide 'foo "foo-value-2" none
    check "restarted after re-provide" to-logic 3 = length? order
    check "restarted third" to-logic 'start-foo = third order
]

test-2: func [/local order root inner-plugin outer-plugin fb] [
    print "--- Test 2: nested plugin cleanup (reverse order)"
    order: copy []
    root: make-root-context
    inner-plugin: make object! [
        name: "inner"
        inject: []
        apply: func [ctx [object!] config] [
            append order 'inner-start
            ctx-on ctx 'e make object! [call: func [args [block!]] [append order 'inner-event]]
            make object! [dispose: func [][append order 'inner-stop]]
        ]
    ]
    outer-plugin: make object! [
        name: "outer"
        inject: []
        apply: func [ctx [object!] config] [
            append order 'outer-start
            ctx/registry/plugin ctx inner-plugin make map! []
            make object! [dispose: func [][append order 'outer-stop]]
        ]
    ]
    fb: root/registry/plugin root outer-plugin make map! []
    check "both started" to-logic 2 = length? order
    ctx-emit root 'e []
    check "inner event handled" to-logic 3 = length? order
    check "inner event third" to-logic 'inner-event = third order
    fb/dispose
    ; 上游语义 (LIFO): outer fiber disposables = [inner-wrapper, outer-plugin-disposer]
    ; 逆序 -> outer-plugin-disposer 先跑, 再卸载 inner (inner-stop)
    check "all cleaned" to-logic 5 = length? order
    check "outer disposer first (LIFO)" to-logic 'outer-stop = pick order 4
    check "inner unloads after outer disposer" to-logic 'inner-stop = pick order 5
]

test-3: func [/local root hits r] [
    print "--- Test 3: emit / bail / once"
    root: make-root-context
    hits: copy []
    ctx-on root 'evt make object! [call: func [args [block!]] [append hits 'a]]
    ctx-on root 'evt make object! [call: func [args [block!]] [append hits 'b]]
    ctx-emit root 'evt []
    check "emit hits both" to-logic 2 = length? hits

    ctx-on root 'pick make object! [call: func [args [block!]] [return "first-value"]]
    ctx-on root 'pick make object! [call: func [args [block!]] [append hits 'never]]
    r: ctx-bail root 'pick []
    check "bail returns first value" to-logic "first-value" = r
    check "bail skips rest" to-logic 2 = length? hits

    ctx-once root 'once-evt make object! [call: func [args [block!]] [append hits 'once-hit]]
    ctx-emit root 'once-evt []
    ctx-emit root 'once-evt []
    check "once fires once" to-logic 3 = length? hits
]

main: func [] [
    test-1
    test-2
    test-3
    print rejoin ["--- " pass-count " passed, " fail-count " failed"]
]

main
