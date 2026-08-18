REBOL []

; ============================================================
; test/fiber-test.reb — fiber.reb 行为测试 (P3)
; 移植自 ref/tests/fiber.spec.ts + dispose.spec.ts (同步版)
; 运行: rebol3 -s test/fiber-test.reb
; ============================================================

do %../utils.reb
do %../events.reb
do %../fiber.reb

passed: 0
failed: 0

assert: func [cond [logic!] label [string!]] [
    either cond [
        passed: passed + 1
        print rejoin ["PASS  " label]
    ][
        failed: failed + 1
        print rejoin ["FAIL  " label]
    ]
]

; ------------------------------------------------------------
; 环境: stub registry/reflect/logger + ctx 工厂
; ------------------------------------------------------------

notify-impls: func [names [block!] /local fb name] [
    foreach fb all-fibers [
        foreach name names [
            if find keys-of fb/inject name [
                fiber-check-impl fb name
                fiber-refresh fb
            ]
        ]
    ]
]

make-stub-registry: func [] [
    make object! [
        counter: 0
        has: func [callback] [true]
        delete: func [callback] [none]
    ]
]

make-stub-reflect: func [] [
    make object! [
        store: make map! []
        get-impl: func [name [word!] strict [logic!] /local impl] [
            impl: select store name
            either impl [
                either all [strict  not equal? impl/fiber/state fiber-state/ACTIVE] [none][impl]
            ][none]
        ]
        notify: func [names [block!]] [notify-impls names]
    ]
]

make-stub-logger: func [] [
    make object! [
        error-log: copy []
        info-log: copy []
        error: func [e] [append error-log e]
        info: func [e] [append info-log e]
    ]
]

; 子 ctx 工厂: 含 extend 方法 (闭包 root-ref 字段, 支持嵌套 extend)
make-child-ctx: func [root-ctx [object! none!] props [map!] /local new] [
    new: make object! [
        fiber: none
        events: none
        registry: none
        reflect: none
        logger: none
        filter: none
        root-ref: none
        extend: func [p [map!]] [make-child-ctx root-ref p]
    ]
    either root-ctx [
        new/fiber: any [select props 'fiber  root-ctx/fiber]
        new/events: root-ctx/events
        new/registry: root-ctx/registry
        new/reflect: root-ctx/reflect
        new/logger: root-ctx/logger
        new/filter: select props 'filter
        new/root-ref: root-ctx
    ][
        new/filter: select props 'filter
    ]
    new
]

make-ctx: func [/local ctx] [
    ctx: make-child-ctx none make map! []
    ctx/root-ref: ctx
    ctx
]

make-root: func [/local root rf] [
    root: make-ctx
    ; 构造顺序 (ROADMAP §3): fiber → reflect → registry → events → logger
    rf: make-fiber-root root
    root/fiber: rf
    root/registry: make-stub-registry
    root/reflect: make-stub-reflect
    root/logger: make-stub-logger
    root/events: make-events-service root
    ; 对齐上游 context.ts: 构造完成后替换 root fiber disposables,
    ; 丢弃 internal handler 的 wrapper (hook 已插入 events, wrapper 不再需要)
    root/fiber/disposables: make-disposable-list
    root
]

make-test-runtime: func [name [string!] plugin [object!] /local rt] [
    rt: make object! [name: none callback: none fibers: none Config: none]
    rt/name: name
    rt/callback: plugin
    rt/fibers: make-disposable-list
    rt
]

; 服务提供/撤销模拟 (P4 reflect 正式化前的桩)
simulate-provide: func [root [object!] name [word!] value /local impl] [
    impl: make object! [name: none value: none fiber: none check: none]
    impl/name: name
    impl/value: value
    impl/fiber: root/fiber
    put root/reflect/store name impl
    put root/fiber/store name impl
    root/reflect/notify reduce [name]
]

simulate-unprovide: func [root [object!] name [word!]] [
    root/reflect/store: map-remove-key root/reflect/store name
    root/fiber/store: map-remove-key root/fiber/store name
    root/reflect/notify reduce [name]
]

; ------------------------------------------------------------
; Test 1: 依赖反应式 — pending → provide → unprovide → re-provide
; ------------------------------------------------------------

order: copy []
dep-plugin: make object! [
    name: "dep"
    inject: ['foo]
    apply: func [ctx [object!] config] [
        append order 'start
        make object! [dispose: func [] [append order 'stop]]
    ]
]
root1: make-root
rt1: make-test-runtime "dep" dep-plugin
fb1: make-plugin-fiber root1 make map! [] make map! [foo: none] rt1
assert equal? 0 length? order "依赖未提供不启动"
assert equal? fiber-state/PENDING fb1/state "未提供依赖 → PENDING"
simulate-provide root1 'foo "v1"
assert equal? 1 length? order "provide 后启动"
assert equal? 'start first order "启动标记"
assert equal? fiber-state/ACTIVE fb1/state "提供依赖 → ACTIVE"
simulate-unprovide root1 'foo
assert equal? 2 length? order "unprovide 后停止"
assert equal? 'stop second order "停止标记"
assert equal? fiber-state/PENDING fb1/state "依赖消失 → PENDING"
simulate-provide root1 'foo "v2"
assert equal? 3 length? order "重新 provide 再启动"
assert equal? 'start pick order 3 "再启动标记"

; ------------------------------------------------------------
; Test 2: plugin error → FAILED, listener 仍有效
; ------------------------------------------------------------

err-callback: 0
err-listener: func [args [block!]] [err-callback: err-callback + 1]
err-plugin: make object! [
    name: "err-plugin"
    inject: []
    apply: func [ctx [object!] config] [
        ; 显式传 ctx: listener 注册到插件 fiber (上游 traceable 隐式, Rebol 显式)
        ctx/events/on 'evt 'err-listener make map! [] ctx
        if not any [select config 'foo] [print undefined-err-xyz]
    ]
]
root2: make-root
rt2: make-test-runtime "err-plugin" err-plugin
fb2: make-plugin-fiber root2 make map! [] make map! [] rt2
rt2b: make-test-runtime "err-plugin" err-plugin
fb2b: make-plugin-fiber root2 make map! [foo: true] make map! [] rt2b
assert equal? fiber-state/FAILED fb2/state "plugin error → FAILED"
assert equal? fiber-state/ACTIVE fb2b/state "正常 config → ACTIVE"
assert equal? 1 length? root2/logger/error-log "logger.error 记录 1 次"
root2/events/emit 'evt [] none
assert equal? 1 err-callback "ACTIVE 插件 listener 生效 (FAILED 的已清理)"

; ------------------------------------------------------------
; Test 3: dispose error — disposer 抛错不崩
; ------------------------------------------------------------

disp-count: 0
de-plugin: make object! [
    name: "de"
    inject: []
    apply: func [ctx [object!] config] [
        make object! [dispose: func [] [disp-count: disp-count + 1  print undefined-err-xyz]]
    ]
]
root3: make-root
rt3: make-test-runtime "de" de-plugin
fb3: make-plugin-fiber root3 make map! [] make map! [] rt3
assert equal? fiber-state/ACTIVE fb3/state "dispose-error 插件 ACTIVE"
assert equal? 0 disp-count "disposer 未调用"
fb3/dispose/dispose
assert equal? 1 disp-count "disposer 调用 1 次"
assert equal? 1 length? root3/logger/error-log "disposer 错误被记录"

; ------------------------------------------------------------
; Test 4: update config → 重启重跑
; ------------------------------------------------------------

uc-calls: 0
uc-configs: copy []
uc-plugin: make object! [
    name: "uc"
    inject: []
    apply: func [ctx [object!] config] [
        uc-calls: uc-calls + 1
        append uc-configs select config 'msg
        none
    ]
]
root4: make-root
rt4: make-test-runtime "uc" uc-plugin
fb4: make-plugin-fiber root4 make map! [msg: "hello"] make map! [] rt4
assert equal? 1 uc-calls "update: 首次调用"
assert equal? "hello" first uc-configs "update: config hello"
fb4/update make map! [msg: "world"] false
assert equal? 2 uc-calls "update: 第二次调用"
assert equal? "world" second uc-configs "update: config world"

; ------------------------------------------------------------
; Test 5: restart → 重跑, ACTIVE
; ------------------------------------------------------------

rc: 0
rs-plugin: make object! [
    name: "rs"
    inject: []
    apply: func [ctx [object!] config] [rc: rc + 1]
]
root5: make-root
rt5: make-test-runtime "rs" rs-plugin
fb5: make-plugin-fiber root5 make map! [] make map! [] rt5
assert equal? 1 rc "restart: 首次调用"
fb5/restart
assert equal? 2 rc "restart: 重跑"
assert equal? fiber-state/ACTIVE fb5/state "restart 后 ACTIVE"

; ------------------------------------------------------------
; Test 6: update while injected service — consumer 重跑
; ------------------------------------------------------------

applied: copy []
consumer-plugin: make object! [
    name: "consumer"
    inject: ['provider]
    apply: func [ctx [object!] config] [
        impl: select ctx/reflect/store 'provider
        append/only applied reduce [impl/value  select config 'mode]
        none
    ]
]
root6: make-root
simulate-provide root6 'provider 1
rt6: make-test-runtime "consumer" consumer-plugin
fb6: make-plugin-fiber root6 make map! [mode: "old"] make map! [provider: none] rt6
print ["[dbg] consumer state: " fb6/state " applied: " mold applied " store: " mold fb6/store]
assert equal? 1 length? applied "consumer 首次加载"
assert equal? reduce [1 "old"] first applied "consumer 首次 [1 old]"
fb6/update make map! [mode: "new"] false
assert equal? 2 length? applied "consumer update 重跑"
assert equal? reduce [1 "new"] second applied "consumer update [1 new]"
assert equal? fiber-state/ACTIVE fb6/state "consumer 仍 ACTIVE"

; ------------------------------------------------------------
; Test 7: dispose by plugin — getEffects + 幂等
; ------------------------------------------------------------

d1-count: 0
ep-plugin: make object! [
    name: "ep"
    inject: []
    apply: func [ctx [object!] config /local fx] [
        fx: func [] [make object! [dispose: func [] [d1-count: d1-count + 1]]]
        ctx/fiber/effect :fx "test"
        none
    ]
]
root7: make-root
rt7: make-test-runtime "ep" ep-plugin
fb7: make-plugin-fiber root7 make map! [] make map! [] rt7
ges: fb7/get-effects
assert equal? 1 length? ges "getEffects 含 1 个"
assert equal? "test" ges/1/label "effect label = test"
assert equal? 0 d1-count "disposer 未调用"
fb7/dispose/dispose
assert equal? 1 d1-count "fiber dispose → disposer 调用"
fb7/dispose/dispose
assert equal? 1 d1-count "重复 dispose 幂等"

; ------------------------------------------------------------
; Test 8: dispose manually — root effect
; ------------------------------------------------------------

d2-count: 0
root8: make-root
fx8: func [] [make object! [dispose: func [] [d2-count: d2-count + 1]]]
w8: root8/fiber/effect :fx8 "anonymous"
ges8: root8/fiber/get-effects
assert equal? 1 length? ges8 "root effect 注册"
assert equal? "anonymous" ges8/1/label "默认 label anonymous"
w8/dispose
assert equal? 1 d2-count "手动 dispose 调用"
w8/dispose
assert equal? 1 d2-count "重复手动 dispose 幂等"

; ------------------------------------------------------------
; Test 9: 块 effect — 嵌套 + 逆序清理 [3 2 1]
; ------------------------------------------------------------

seq9: copy []
; 坑点: disposer 方法不能闭包创建帧局部 (d9 的 n) → 存字段
d9: func [n /local d] [
    d: make object! [val: n  dispose: func [] [append seq9 val]]
    d
]
root9: make-root
fx9: func [] [
    fx9n: func [] [reduce [d9 3]]
    reduce [
        d9 1
        d9 2
        root9/fiber/effect :fx9n "nested"
    ]
]
w9: root9/fiber/effect :fx9 "anonymous"
assert equal? 0 length? seq9 "清理前无副作用"
w9/dispose
assert equal? [3 2 1] seq9 "块 effect 逆序清理 [3 2 1]"
; 嵌套 meta children
ges9: root9/fiber/get-effects
assert equal? 1 length? ges9 "嵌套后 1 个顶层 effect"
assert equal? 1 length? ges9/1/children "顶层 effect 1 个 child"
assert equal? "nested" ges9/1/children/1/label "child label = nested"

; ------------------------------------------------------------
; Test 10: effect 抛错传播 + 已收集清理
; ------------------------------------------------------------

seq10: copy []
root10: make-root
fx10: func [] [
    print undefined-err-xyz
    append seq10 1
]
r10: try [root10/fiber/effect :fx10 "err"]
assert error? r10 "effect 抛错传播"
assert equal? 0 length? seq10 "execute 抛错无部分收集 (副作用在报错后)"

; ------------------------------------------------------------
; Test 11: 嵌套插件 LIFO 清理
; ------------------------------------------------------------

order11: copy []
inner-listener: func [args [block!]] [append order11 'inner-event]
inner-plugin11: make object! [
    name: "inner"
    inject: []
    apply: func [ctx [object!] config] [
        append order11 'inner-start
        ctx/events/on 'e11 'inner-listener make map! [] ctx
        make object! [dispose: func [] [append order11 'inner-stop]]
    ]
]
outer-plugin11: make object! [
    name: "outer"
    inject: []
    apply: func [ctx [object!] config] [
        append order11 'outer-start
        make-plugin-fiber ctx none make map! [] (make-test-runtime "inner" inner-plugin11)
        make object! [dispose: func [] [append order11 'outer-stop]]
    ]
]
root11: make-root
rt11: make-test-runtime "outer" outer-plugin11
fb11: make-plugin-fiber root11 make map! [] make map! [] rt11
assert equal? 2 length? order11 "嵌套都启动"
root11/events/emit 'e11 [] none
assert equal? 3 length? order11 "inner 事件处理"
assert equal? 'inner-event pick order11 3 "inner 事件标记"
fb11/dispose/dispose
assert equal? 5 length? order11 "全部清理"
assert equal? 'outer-stop pick order11 4 "父 disposer 先于子卸载 (LIFO)"
assert equal? 'inner-stop pick order11 5 "子插件后卸载"

; ------------------------------------------------------------
; Test 12: root fiber 基本属性
; ------------------------------------------------------------

root12: make-root
assert equal? 0 root12/fiber/uid "root fiber uid = 0"
assert equal? fiber-state/ACTIVE root12/fiber/state "root fiber ACTIVE"
assert equal? "root" root12/fiber/name "root fiber name"

print rejoin ["^/==== fiber-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
