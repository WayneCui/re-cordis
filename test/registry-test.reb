REBOL []

; ============================================================
; test/registry-test.reb - behavior tests for registry.reb (P5)
; Ported from ref/tests/plugin.spec.ts (synchronous version)
; Run: rebol3 -s test/registry-test.reb
; ============================================================

do %../utils.reb
do %../events.reb
do %../fiber.reb
do %../reflect.reb
do %../registry.reb

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
; Test environment
; ------------------------------------------------------------

make-stub-logger: func [] [
    make object! [
        error-log: copy []
        info-log: copy []
        error: func [e] [append error-log e]
        info: func [e] [append info-log e]
    ]
]

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

make-root: func [/local root rf] [
    root: make-child-ctx none make map! []
    root/root-ref: root
    rf: make-fiber-root root
    root/fiber: rf
    root/registry: make-registry-service root
    root/reflect: make-reflect-service root
    root/logger: make-stub-logger
    root/events: make-events-service root
    root/fiber/disposables: make-disposable-list
    root
]

; ------------------------------------------------------------
; Test 1: object plugin apply + config passthrough
; ------------------------------------------------------------

t1-calls: 0
t1-config: none
t1-plugin: make object! [
    name: "t1"
    inject: []
    apply: func [ctx [object!] config] [
        t1-calls: t1-calls + 1
        t1-config: select config 'msg
        none
    ]
]
root1: make-root
fb1: root1/registry/plugin t1-plugin make map! [msg: "hello"] none
assert equal? 1 t1-calls "object plugin apply called once"
assert equal? "hello" t1-config "config passthrough"
assert equal? fiber-state/ACTIVE fb1/state "plugin ACTIVE"
assert equal? 1 root1/registry/size "registry size 1"
assert root1/registry/has t1-plugin "registry.has hit"

; Register the same plugin again -> reuse the runtime
root1/registry/plugin t1-plugin make map! [msg: "world"] none
assert equal? 2 t1-calls "same plugin re-register apply 2nd time"
assert equal? "world" t1-config "second config"
assert equal? 1 root1/registry/size "same plugin shares runtime, size still 1"

; ------------------------------------------------------------
; Test 2: invalid plugin error
; ------------------------------------------------------------

root2: make-root
bad1: make object! [name: "no-apply"]
r2: root2/registry/plugin bad1 none none
assert not none? find r2 "invalid plugin" "no apply method errors"

; ------------------------------------------------------------
; Test 3: registry API
; ------------------------------------------------------------

root3: make-root
p3a: make object! [name: "a"  inject: []  apply: func [ctx [object!] config] [none]]
p3b: make object! [name: "b"  inject: []  apply: func [ctx [object!] config] [none]]
fb3a: root3/registry/plugin p3a none none
fb3b: root3/registry/plugin p3b none none
assert equal? 2 root3/registry/size "size = 2"
assert equal? 2 length? root3/registry/keys "keys = 2"
assert equal? 2 length? root3/registry/values "values = 2"
assert equal? 2 length? root3/registry/entries "entries = 2"
cnt3: 0
root3/registry/for-each func [k v] [cnt3: cnt3 + 1]
assert equal? 2 cnt3 "forEach iterates 2 times"

; ------------------------------------------------------------
; Test 4: delete plugin -> fiber unload
; ------------------------------------------------------------

order4: copy []
p4: make object! [
    name: "p4"
    inject: []
    apply: func [ctx [object!] config] [
        append order4 'p4-start
        make object! [dispose: func [] [append order4 'p4-stop]]
    ]
]
root4: make-root
fb4: root4/registry/plugin p4 none none
assert equal? 1 length? order4 "p4 started"
root4/registry/delete p4
assert equal? 0 root4/registry/size "size 0 after delete"
assert equal? 2 length? order4 "p4 stopped"
assert equal? 'p4-stop second order4 "p4 stop marker"
assert equal? fiber-state/DISPOSED fb4/state "fiber DISPOSED"

; ------------------------------------------------------------
; Test 5: inject convenience helper
; ------------------------------------------------------------

t5-args: none
t5-fn: func [ctx [object!] config] [
    ; Explicit version: read the service from reflect store (no Proxy field)
    t5-args: reduce [ctx/reflect/get 'foo true ctx  config]
    none
]
root5: make-root
root5/reflect/provide 'foo "foo-val" none root5
fb5: root5/registry/inject ['foo] 't5-fn none
print ["[dbg-t5] t5-args: " mold t5-args " len: " length? t5-args]
print ["[dbg-t5] fb5 state: " fb5/state " store keys: " mold keys-of root5/reflect/store]
print ["[dbg-t5] logger errors: " length? root5/logger/error-log]
foreach e5 root5/logger/error-log [print ["  [dbg-t5] err id: " e5/id " near: " mold e5/near]]
assert equal? reduce ["foo-val" none] t5-args "inject injects foo service and calls"

; ------------------------------------------------------------
; Test 6: inactive context - operations after dispose should error
; ------------------------------------------------------------

t6-calls: 0
t6-inner: func [ctx [object!] config] [t6-calls: t6-calls + 1]
root6: make-root
inner-cb: make object! [name: "inner6"  inject: []  apply: func [ctx [object!] config] [t6-calls: t6-calls + 1]]
order6: copy []
p6: make object! [
    name: "p6"
    inject: []
    apply: func [ctx [object!] config] [
        append order6 'p6-start
        ; dispose methods cannot close over the apply frame's ctx -> store it in a field
        make object! [
            p6-ctx: ctx
            dispose: func [/local fx6] [
                append order6 'p6-dispose
                r6: p6-ctx/registry/plugin inner-cb none p6-ctx
                ; find returns a position (truthy) -> none? is false -> should yield 'ok
                append order6 reduce [either none? find r6 "inactive" ['fail]['ok]]
                fx6: func [] [none]
                r6b: p6-ctx/fiber/effect :fx6 "x"
                append order6 reduce [either none? find r6b "INACTIVE_EFFECT" ['fail2]['ok2]]
            ]
        ]
    ]
]
root6: make-root
fb6: root6/registry/plugin p6 none none
assert equal? 1 length? order6 "p6 started"
fb6/dispose/dispose
print ["[dbg-test6] order6: " mold order6]
assert equal? 4 length? order6 "dispose all executed"
assert equal? 'ok pick order6 3 "plugin errors after inactive"
assert equal? 'ok2 pick order6 4 "effect errors after inactive"
assert equal? 0 t6-calls "inner plugin not started"

; ------------------------------------------------------------
; Test 7: nested plugins - registry size lifecycle
; ------------------------------------------------------------

evt-calls: 0
evt-listen: func [args [block!]] [evt-calls: evt-calls + 1]
nest3: make object! [
    name: "nest3"
    inject: []
    apply: func [ctx [object!] config] [
        ctx/events/on 'evt 'evt-listen make map! [] ctx
        none
    ]
]
nest2: make object! [
    name: "nest2"
    inject: []
    apply: func [ctx [object!] config] [
        ctx/events/on 'evt 'evt-listen make map! [] ctx
        ctx/registry/plugin nest3 none ctx
        none
    ]
]
nest1: make object! [
    name: "nest1"
    inject: []
    apply: func [ctx [object!] config] [
        ctx/events/on 'evt 'evt-listen make map! [] ctx
        ctx/registry/plugin nest2 none ctx
        none
    ]
]
root7: make-root
root7/events/on 'evt 'evt-listen make map! [] none
fb7: root7/registry/plugin nest1 none none
assert equal? 3 root7/registry/size "nested 3 runtimes"
evt-calls: 0
root7/events/emit 'evt [] none
assert equal? 4 evt-calls "4 listeners triggered"
; Unload the root -> everything nested unloads as well
fb7/dispose/dispose
assert equal? 0 root7/registry/size "registry size 0 after unload"
evt-calls: 0
root7/events/emit 'evt [] none
assert equal? 1 evt-calls "only root listener remains"
; Repeated dispose is idempotent
fb7/dispose/dispose
assert equal? 0 root7/registry/size "repeated dispose size still 0"

; ------------------------------------------------------------
; Test 8: root dispose - clear root disposables
; ------------------------------------------------------------

d8: 0
p8: make object! [
    name: "p8"
    inject: []
    apply: func [ctx [object!] config] [
        make object! [dispose: func [] [d8: d8 + 1]]
    ]
]
root8: make-root
fb8: root8/registry/plugin p8 none none
assert equal? 0 d8 "disposer not called"
assert equal? 0 root8/fiber/uid "root uid = 0"
assert equal? 1 fb8/uid "plugin uid = 1"
assert equal? 1 root8/fiber/disposables/length "root disposables 1"
root8/fiber/dispose/dispose
assert equal? 0 root8/fiber/uid "root uid still 0"
assert none? fb8/uid "plugin uid -> none"
assert equal? 1 d8 "disposer called once"
assert equal? 0 root8/fiber/disposables/length "root disposables cleared"
root8/fiber/dispose/dispose
assert equal? 1 d8 "repeated root dispose is idempotent"

; ------------------------------------------------------------
; Test 9: ctx name
; ------------------------------------------------------------

t9-name: none
p9: make object! [
    name: "bar9"
    inject: []
    apply: func [ctx [object!] config] [
        t9-name: ctx/fiber/name
        none
    ]
]
root9: make-root
root9/registry/plugin p9 none none
assert equal? "bar9" t9-name "plugin ctx name = bar9"
assert equal? "root" root9/fiber/name "root name"

print rejoin ["^/==== registry-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
