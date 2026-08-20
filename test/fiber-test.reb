REBOL []

; ============================================================
; test/fiber-test.reb - behavior tests for fiber.reb (P3)
; Ported from ref/tests/fiber.spec.ts + dispose.spec.ts (synchronous version)
; Run: rebol3 -s test/fiber-test.reb
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
; Test environment: stub registry/reflect/logger + ctx factory
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

; Child ctx factory: includes extend (root-ref field closure, supports nested extend)
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
    ; Construction order (ROADMAP §3): fiber -> reflect -> registry -> events -> logger
    rf: make-fiber-root root
    root/fiber: rf
    root/registry: make-stub-registry
    root/reflect: make-stub-reflect
    root/logger: make-stub-logger
    root/events: make-events-service root
    ; Match upstream context.ts: replace root fiber disposables after construction,
    ; dropping the internal handler wrapper (the hook is already inserted into events)
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

; Simulate service provide/unprovide (stub used before P4 reflect is formalized)
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
; Test 1: reactive dependencies - pending -> provide -> unprovide -> re-provide
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
assert equal? 0 length? order "not started when dependency not provided"
assert equal? fiber-state/PENDING fb1/state "no dependency -> PENDING"
simulate-provide root1 'foo "v1"
assert equal? 1 length? order "starts after provide"
assert equal? 'start first order "start marker"
assert equal? fiber-state/ACTIVE fb1/state "dependency provided -> ACTIVE"
simulate-unprovide root1 'foo
assert equal? 2 length? order "stops after unprovide"
assert equal? 'stop second order "stop marker"
assert equal? fiber-state/PENDING fb1/state "dependency gone -> PENDING"
simulate-provide root1 'foo "v2"
assert equal? 3 length? order "restarts after re-provide"
assert equal? 'start pick order 3 "restart marker"

; ------------------------------------------------------------
; Test 2: plugin error -> FAILED, listener still works
; ------------------------------------------------------------

err-callback: 0
err-listener: func [args [block!]] [err-callback: err-callback + 1]
err-plugin: make object! [
    name: "err-plugin"
    inject: []
    apply: func [ctx [object!] config] [
        ; Pass ctx explicitly: register the listener on the plugin fiber (upstream traceable is implicit, Rebol is explicit)
        ctx/events/on 'evt 'err-listener make map! [] ctx
        if not any [select config 'foo] [print undefined-err-xyz]
    ]
]
root2: make-root
rt2: make-test-runtime "err-plugin" err-plugin
fb2: make-plugin-fiber root2 make map! [] make map! [] rt2
rt2b: make-test-runtime "err-plugin" err-plugin
fb2b: make-plugin-fiber root2 make map! [foo: true] make map! [] rt2b
assert equal? fiber-state/FAILED fb2/state "plugin error -> FAILED"
assert equal? fiber-state/ACTIVE fb2b/state "normal config -> ACTIVE"
assert equal? 1 length? root2/logger/error-log "logger.error recorded once"
root2/events/emit 'evt [] none
assert equal? 1 err-callback "ACTIVE plugin listener works (FAILED cleaned up)"

; ------------------------------------------------------------
; Test 3: dispose error - disposer throws without crashing
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
assert equal? fiber-state/ACTIVE fb3/state "dispose-error plugin ACTIVE"
assert equal? 0 disp-count "disposer not called"
fb3/dispose/dispose
assert equal? 1 disp-count "disposer called once"
assert equal? 1 length? root3/logger/error-log "disposer error recorded"

; ------------------------------------------------------------
; Test 4: update config -> restart and rerun
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
assert equal? 1 uc-calls "update: first call"
assert equal? "hello" first uc-configs "update: config hello"
fb4/update make map! [msg: "world"] false
assert equal? 2 uc-calls "update: second call"
assert equal? "world" second uc-configs "update: config world"

; ------------------------------------------------------------
; Test 5: restart -> rerun, ACTIVE
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
assert equal? 1 rc "restart: first call"
fb5/restart
assert equal? 2 rc "restart: rerun"
assert equal? fiber-state/ACTIVE fb5/state "ACTIVE after restart"

; ------------------------------------------------------------
; Test 6: update while injected service is present - consumer reruns
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
assert equal? 1 length? applied "consumer first load"
assert equal? reduce [1 "old"] first applied "consumer first [1 old]"
fb6/update make map! [mode: "new"] false
assert equal? 2 length? applied "consumer update rerun"
assert equal? reduce [1 "new"] second applied "consumer update [1 new]"
assert equal? fiber-state/ACTIVE fb6/state "consumer still ACTIVE"

; ------------------------------------------------------------
; Test 7: dispose by plugin - getEffects + idempotence
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
assert equal? 1 length? ges "getEffects has 1 item"
assert equal? "test" ges/1/label "effect label = test"
assert equal? 0 d1-count "disposer not called"
fb7/dispose/dispose
assert equal? 1 d1-count "fiber dispose -> disposer called"
fb7/dispose/dispose
assert equal? 1 d1-count "repeated dispose is idempotent"

; ------------------------------------------------------------
; Test 8: dispose manually — root effect
; ------------------------------------------------------------

d2-count: 0
root8: make-root
fx8: func [] [make object! [dispose: func [] [d2-count: d2-count + 1]]]
w8: root8/fiber/effect :fx8 "anonymous"
ges8: root8/fiber/get-effects
assert equal? 1 length? ges8 "root effect registered"
assert equal? "anonymous" ges8/1/label "default label anonymous"
w8/dispose
assert equal? 1 d2-count "manual dispose called"
w8/dispose
assert equal? 1 d2-count "repeated manual dispose is idempotent"

; ------------------------------------------------------------
; Test 9: block effect - nesting + reverse cleanup [3 2 1]
; ------------------------------------------------------------

seq9: copy []
; Gotcha: disposer methods cannot close over frame locals (d9's n) -> store it in a field
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
assert equal? 0 length? seq9 "no side effects before cleanup"
w9/dispose
assert equal? [3 2 1] seq9 "block effect reverse cleanup [3 2 1]"
; Nested meta children
ges9: root9/fiber/get-effects
assert equal? 1 length? ges9 "1 top-level effect after nesting"
assert equal? 1 length? ges9/1/children "top-level effect has 1 child"
assert equal? "nested" ges9/1/children/1/label "child label = nested"

; ------------------------------------------------------------
; Test 10: effect error propagation + cleanup of already collected items
; ------------------------------------------------------------

seq10: copy []
root10: make-root
fx10: func [] [
    print undefined-err-xyz
    append seq10 1
]
r10: try [root10/fiber/effect :fx10 "err"]
assert error? r10 "effect error propagates"
assert equal? 0 length? seq10 "execute error: no partial collection (side effects after error)"

; ------------------------------------------------------------
; Test 11: nested plugin LIFO cleanup
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
assert equal? 2 length? order11 "nested both started"
root11/events/emit 'e11 [] none
assert equal? 3 length? order11 "inner event handled"
assert equal? 'inner-event pick order11 3 "inner event marker"
fb11/dispose/dispose
assert equal? 5 length? order11 "full cleanup"
assert equal? 'outer-stop pick order11 4 "parent disposer before child unload (LIFO)"
assert equal? 'inner-stop pick order11 5 "child plugin unloaded last"

; ------------------------------------------------------------
; Test 12: basic root fiber properties
; ------------------------------------------------------------

root12: make-root
assert equal? 0 root12/fiber/uid "root fiber uid = 0"
assert equal? fiber-state/ACTIVE root12/fiber/state "root fiber ACTIVE"
assert equal? "root" root12/fiber/name "root fiber name"

print rejoin ["^/==== fiber-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
