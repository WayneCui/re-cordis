REBOL []

; ============================================================
; test/m1-effect-tree-test.reb - M1 effect tree inspector tests
; Verifies:
;   1. effect metadata keeps owner/children information
;   2. manual plugin dispose marks root wrapper as manual
;   3. nested effect cleanup is marked as unload and runs once
; ============================================================

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

dispose-order: copy []

make-disposer: func [label [string!] /local d] [
    d: make object! [
        label-ref: ""
        dispose: func [] [append dispose-order label-ref]
    ]
    d/label-ref: label
    d
]

tree-plugin: make object! [
    name: "tree-plugin"
    inject: []
    apply: func [ctx [object!] config /local fx-child fx-root] [
        fx-child: func [] [
            reduce [make-disposer "child-leaf"]
        ]
        fx-root: func [] [
            reduce [
                make-disposer "root-leaf"
                ctx/fiber/effect :fx-child "child-effect"
            ]
        ]
        ctx/fiber/effect :fx-root "root-effect"
        none
    ]
]

root: make-context
fb: root/registry/plugin tree-plugin make map! [] root

plugin-meta: fb/dispose/meta
effects: fb/get-effects
inner-meta: effects/1
child-effect-meta: inner-meta/children/1

assert equal? "ctx.plugin()" plugin-meta/label "plugin wrapper label"
assert equal? "root#0" plugin-meta/owner "plugin wrapper owner is root"
assert not plugin-meta/disposed "plugin wrapper starts alive"
assert equal? 0 length? plugin-meta/children "plugin wrapper has no direct child effects"

assert equal? "root-effect" inner-meta/label "inner effect label"
assert equal? "tree-plugin#1" inner-meta/owner "inner effect owner is plugin fiber"
assert not inner-meta/disposed "inner effect starts alive"
assert equal? 1 length? inner-meta/children "inner effect has one child"

assert equal? "child-effect" child-effect-meta/label "grandchild effect label"
assert equal? "tree-plugin#1" child-effect-meta/owner "grandchild owner is plugin fiber"
assert not child-effect-meta/disposed "grandchild starts alive"

fb/dispose/dispose

assert equal? ["child-leaf" "root-leaf"] dispose-order "nested disposers run in reverse tree order"
assert plugin-meta/disposed "plugin wrapper marked disposed"
assert equal? "manual" plugin-meta/dispose-reason "plugin wrapper reason is manual"
assert inner-meta/disposed "inner effect marked disposed"
assert equal? "unload" inner-meta/dispose-reason "inner effect reason is unload"
assert child-effect-meta/disposed "grandchild effect marked disposed"
assert equal? "unload" child-effect-meta/dispose-reason "grandchild effect reason is unload"

fb/dispose/dispose
assert equal? ["child-leaf" "root-leaf"] dispose-order "repeated dispose stays idempotent"

print rejoin ["^/==== m1-effect-tree-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
