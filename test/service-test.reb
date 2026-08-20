REBOL []

; ============================================================
; test/service-test.reb - behavior tests for service.reb (P7)
; Ported from ref/tests/service.spec.ts (synchronously portable parts)
; Run: rebol3 -s test/service-test.reb
;
; Skipped (synchronous version limits, ROADMAP §7):
;   - pending inject (async Service.init suspension)
;   - traceable effect (Proxy context tunneling)
; ============================================================

do %../utils.reb
do %../events.reb
do %../fiber.reb
do %../reflect.reb
do %../registry.reb
do %../context.reb
do %../service.reb
do %../logger.reb

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

make-stub-logger: func [] [
    make object! [
        error-log: copy []
        info-log: copy []
        error: func [e] [append error-log e]
        info: func [e] [append info-log e]
    ]
]

; ------------------------------------------------------------
; Test 1: service construction auto-registers (super(ctx, name) -> reflect.provide)
; ------------------------------------------------------------

root1: make-context
root1/logger: make-stub-logger
foo1: make object! [
    ctx: none
    name: none
    value: 42
]
make-service root1 'foo1 foo1
; Note: the service value is the service object itself (upstream provide(name, self))
assert same? foo1 root1/reflect/get 'foo1 true root1 "service auto-registers after construction (reflect.get)"
assert equal? 'foo1 foo1/name "service name injected"
assert equal? 42 select foo1 'value "service fields preserved"
assert equal? root1 foo1/ctx "service ctx injected"

; ------------------------------------------------------------
; Test 2: basic resolveConfig (base + head merge, no intercept)
; ------------------------------------------------------------

root2: make-context
root2/logger: make-stub-logger
foo2: make object! [ctx: none name: none]
make-service root2 'foo2 foo2
cfg2: service-resolve-config foo2 make map! [a: 1] make map! [b: 2]
assert equal? 1 select cfg2 'a "resolveConfig base applied"
assert equal? 2 select cfg2 'b "resolveConfig head applied"

; ------------------------------------------------------------
; Test 3: resolveConfig across multiple intercept layers (core chained-shadowing behavior)
; ------------------------------------------------------------

root3: make-context
root3/logger: make-stub-logger
; intercept uses immutable shadowing: it returns a new ctx, so you must capture it
root3: root3/intercept 'foo3 make map! [a: 1]
sub3: root3/extend make map! []
sub3: sub3/intercept 'foo3 make map! [b: 2]
foo3: make object! [ctx: none name: none]
make-service sub3 'foo3 foo3
cfg3: service-resolve-config foo3 none none
assert equal? 1 select cfg3 'a "chained shadowing: root layer a preserved"
assert equal? 2 select cfg3 'b "chained shadowing: leaf layer b applied"

; ------------------------------------------------------------
; Test 4: leaf layer overrides same key from root + base precedence
; ------------------------------------------------------------

root4: make-context
root4/logger: make-stub-logger
root4: root4/intercept 'foo4 make map! [level: 'base]
sub4: root4/extend make map! []
sub4: sub4/intercept 'foo4 make map! [level: 'leaf]
foo4: make object! [ctx: none name: none]
make-service sub4 'foo4 foo4
cfg4: service-resolve-config foo4 none none
assert equal? 'leaf select cfg4 'level "leaf config overrides root"
cfg4b: service-resolve-config foo4 make map! [level: 'base-arg] none
assert equal? 'leaf select cfg4b 'level "chain config overrides base arg"
cfg4c: service-resolve-config foo4 none make map! [level: 'head]
assert equal? 'head select cfg4c 'level "head arg has highest priority"

; ------------------------------------------------------------
; Test 5: custom Config.merge merger
; ------------------------------------------------------------

merge-log: copy []
root5: make-context
root5/logger: make-stub-logger
foo5: make object! [
    ctx: none
    name: none
    Config: make object! [
        merge: make object! [
            call: func [configs [block!] this-arg] [
                append merge-log length? configs
                make map! [custom: 'merged]
            ]
        ]
    ]
]
make-service root5 'foo5 foo5
cfg5: service-resolve-config foo5 make map! [a: 1] make map! [b: 2]
assert equal? 'merged select cfg5 'custom "Config.merge custom merge applied"
assert equal? 2 first merge-log "merge receives all config (base+head)"

; ------------------------------------------------------------
; Test 6: multiple injects - services used as plugins, each init runs once after dependencies are satisfied
; Upstream: Foo.inject=['qux'], Bar.inject=['foo','qux'], Qux has no dependencies
; ------------------------------------------------------------

order6: copy []
qux-t: make object! [
    name: "qux"
    inject: none
    apply: func [ctx [object!] config] [
        append order6 'qux
        make-service ctx 'qux make object! [ctx: none name: none]
        none
    ]
]
foo-t: make object! [
    name: "foo"
    inject: ['qux]
    apply: func [ctx [object!] config] [
        append order6 'foo
        make-service ctx 'foo make object! [ctx: none name: none]
        none
    ]
]
bar-t: make object! [
    name: "bar"
    inject: ['foo 'qux]
    apply: func [ctx [object!] config] [
        append order6 'bar
        make-service ctx 'bar make object! [ctx: none name: none]
        none
    ]
]
root6: make-context
root6/logger: make-stub-logger
root6/registry/plugin qux-t none root6
root6/registry/plugin foo-t none root6
root6/registry/plugin bar-t none root6
assert equal? 3 length? order6 "multiple injects: each of 3 services init once"
assert equal? 'qux first order6 "dependency order: qux with no deps first"
assert equal? 'bar last order6 "bar with most deps last"

print rejoin ["^/==== service-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
