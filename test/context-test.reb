REBOL []

; ============================================================
; test/context-test.reb - behavior tests for context.reb (P6)
; Ported from ref/tests/isolate.spec.ts (synchronous version)
; Run: rebol3 -s test/context-test.reb
; ============================================================

do %../utils.reb
do %../events.reb
do %../fiber.reb
do %../reflect.reb
do %../registry.reb
do %../context.reb
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
; Test 1: construction order + Context.is
; ------------------------------------------------------------

root1: make-context
root1/logger: make-stub-logger
assert equal? 0 root1/fiber/uid "root fiber uid 0"
assert not none? root1/reflect "reflect 已构造"
assert not none? root1/registry "registry 已构造"
assert not none? root1/events "events 已构造"
assert context-is root1 "Context.is 识别 root"
assert not context-is 42 "Context.is 拒绝非 ctx"

; ------------------------------------------------------------
; Test 2: isolation - root/ctx1/ctx2 each provide independently and remain invisible to one another
; ------------------------------------------------------------

order2: copy []
iso-plugin: make object! [
    name: "iso2"
    inject: ['foo]
    apply: func [ctx [object!] config] [
        append order2 'iso-start
        make object! [
            iso-ctx: ctx
            dispose: func [] [append order2 'iso-stop]
        ]
    ]
]
root2: make-context
root2/logger: make-stub-logger
root2/registry/plugin iso-plugin make map! [] root2
ctx2a: root2/isolate 'foo none
ctx2a/registry/plugin iso-plugin make map! [] ctx2a
ctx2b: root2/isolate 'foo none
ctx2b/registry/plugin iso-plugin make map! [] ctx2b
assert equal? 0 length? order2 "3 区插件均未启动 (foo 未提供)"

d2-0: root2/reflect/provide 'foo 100 none root2
assert equal? 1 length? order2 "root provide → 仅 root 区插件启动"
rt2-0: first root2/registry/values
fbs2-0: rt2-0/fibers/values
assert equal? fiber-state/ACTIVE fbs2-0/1/state "root 区插件 ACTIVE"

d2-1: ctx2a/reflect/provide 'foo 200 none ctx2a
assert equal? 2 length? order2 "ctx1 provide → 仅 ctx1 区插件启动"
; Plugin state for the ctx1 zone (locate by isolate label, do not assume it is the last by traversal order)
label2a: select ctx2a/isolate-map 'foo
fbc2a: none
foreach rt2a ctx2a/registry/values [
    foreach fb2a rt2a/fibers/values [
        if equal? label2a select fb2a/ctx/isolate-map 'foo [fbc2a: fb2a]
    ]
]
assert equal? fiber-state/ACTIVE fbc2a/state "ctx1 区插件 ACTIVE"

d2-0/dispose
assert equal? 3 length? order2 "root unprovide → root 区插件停止"
rt2-0b: first root2/registry/values
fbs2-0b: rt2-0b/fibers/values
assert equal? fiber-state/PENDING fbs2-0b/1/state "root 区插件 PENDING"

d2-2: ctx2b/reflect/provide 'foo 300 none ctx2b
assert equal? 4 length? order2 "ctx2 provide → ctx2 区插件启动"

; ------------------------------------------------------------
; Test 3: shared label - ctx instances with the same label share the service
; ------------------------------------------------------------

order3: copy []
iso3-plugin: make object! [
    name: "iso3"
    inject: ['foo]
    apply: func [ctx [object!] config] [
        append order3 's3-start
        make object! [dispose: func [] [append order3 's3-stop]]
    ]
]
root3: make-context
root3/logger: make-stub-logger
shared-label: 'shared-foo
ctx3a: root3/isolate 'foo shared-label
ctx3b: root3/isolate 'foo shared-label
ctx3a/registry/plugin iso3-plugin make map! [] ctx3a
ctx3b/registry/plugin iso3-plugin make map! [] ctx3b
assert equal? 0 length? order3 "共享标签插件均未启动"

d3: ctx3a/reflect/provide 'foo 200 none ctx3a
assert equal? 2 length? order3 "同标签 provide → 两个插件都启动"

d3/dispose
assert equal? 4 length? order3 "unprovide → 两个插件都停止"

; ------------------------------------------------------------
; Test 4: extend - child ctx shares services and may override fields
; ------------------------------------------------------------

root4: make-context
root4/logger: make-stub-logger
d4: root4/reflect/provide 'svc4 "v4" none root4
sub4: root4/extend make map! [custom: 42]
assert equal? "v4" sub4/reflect/get 'svc4 true sub4 "子 ctx 可读父服务"
assert not none? select sub4/extra 'custom "extend 覆盖字段"
d4/dispose
assert none? sub4/reflect/get 'svc4 true sub4 "unprovide 后子 ctx 读不到"

; ------------------------------------------------------------
; Test 5: intercept - declare an interception chain
; ------------------------------------------------------------

root5: make-context
root5/logger: make-stub-logger
int5: root5/intercept 'foo make map! [enabled: true]
; Gotcha: the map! literal [enabled: true] stores word! 'true rather than logic! -> check presence via select
; intercept-chain is a chained block [leaf ... root], so lookup means the first sequential match wins
chain5: select int5 'intercept-chain
cfg5: none
foreach m5 chain5 [if select m5 'foo [cfg5: select m5 'foo]]
assert not none? select cfg5 'enabled "intercept 声明生效"
sub5: int5/extend make map! []
chain5b: select sub5 'intercept-chain
cfg5b: none
foreach m5b chain5b [if select m5b 'foo [cfg5b: select m5b 'foo]]
assert not none? select cfg5b 'enabled "intercept 链继承"

print rejoin ["^/==== context-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
