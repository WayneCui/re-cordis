REBOL []

; ============================================================
; test/reflect-test.reb - behavior tests for reflect.reb (P4)
; Ported from ref/tests/reflect.spec.ts (synchronous version)
; Run: rebol3 -s test/reflect-test.reb
; ============================================================

do %../utils.reb
do %../events.reb
do %../fiber.reb
do %../reflect.reb

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
; Test environment (real reflect service)
; ------------------------------------------------------------

make-stub-registry: func [] [
    make object! [
        counter: 0
        has: func [callback] [true]
        delete: func [callback] [none]
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
    root/registry: make-stub-registry
    root/reflect: make-reflect-service root
    root/logger: make-stub-logger
    root/events: make-events-service root
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

; ------------------------------------------------------------
; Test 1: basic provide / set / get
; ------------------------------------------------------------

root1: make-root
d1: root1/reflect/provide 'foo "foo-value" none root1
r1: root1/reflect/get 'foo true root1
assert equal? "foo-value" r1 "get 返回服务值"
r1b: root1/reflect/set 'foo "foo-value-2" root1
assert equal? true r1b "set 成功返回 true"
assert equal? "foo-value-2" root1/reflect/get 'foo true root1 "set 后 get 更新"
; get on a missing service
assert none? root1/reflect/get 'nope true root1 "get 不存在返回 none"
; impl record
impl1: root1/reflect/get-impl 'foo true root1
assert not none? impl1 "get-impl 找到"
assert same? root1/fiber impl1/fiber "impl.fiber = root fiber"

; ------------------------------------------------------------
; Test 2: duplicate provide / set without provide / error on set from multiple fibers
; ------------------------------------------------------------

root2: make-root
d2: root2/reflect/provide 'bar "v" none root2
d2b: root2/reflect/provide 'bar "v2" none root2
; Duplicate provide does not override (returns none, original value stays)
assert equal? "v" root2/reflect/get 'bar true root2 "重复 provide 原值保留"
; set without provide
r2: root2/reflect/set 'nope 42 root2
assert not none? find r2 "without provide" "set 未提供报错"
; set after unprovide
d2/dispose
r2b: root2/reflect/set 'bar 1 root2
assert not none? find r2b "without provide" "unprovide 后 set 报错"

; ------------------------------------------------------------
; Test 3: service injection - provide triggers dependent fiber startup
; ------------------------------------------------------------

order3: copy []
dep-plugin3: make object! [
    name: "dep3"
    inject: ['svc3]
    apply: func [ctx [object!] config] [
        append order3 'start3
        make object! [dispose: func [] [append order3 'stop3]]
    ]
]
root3: make-root
rt3: make-test-runtime "dep3" dep-plugin3
fb3: make-plugin-fiber root3 make map! [] make map! [svc3: none] rt3
assert equal? 0 length? order3 "依赖未提供不启动"
dp3: root3/reflect/provide 'svc3 "s3" none root3
assert equal? 1 length? order3 "provide 后启动"
assert equal? 'start3 first order3 "启动标记"
assert equal? fiber-state/ACTIVE fb3/state "依赖可用 → ACTIVE"
; unprovide -> stop
dp3/dispose
assert equal? 2 length? order3 "unprovide 后停止"
assert equal? 'stop3 second order3 "停止标记"
assert equal? fiber-state/PENDING fb3/state "依赖消失 → PENDING"
; provide again -> restart
root3/reflect/provide 'svc3 "s3-2" none root3
assert equal? 3 length? order3 "重新 provide 再启动"

; ------------------------------------------------------------
; Test 4: injected fibers can read the service value
; ------------------------------------------------------------

got-value: none
consumer4: make object! [
    name: "consumer4"
    inject: ['svc4]
    apply: func [ctx [object!] config] [
        got-value: ctx/reflect/get 'svc4 true ctx
        none
    ]
]
root4: make-root
dp4: root4/reflect/provide 'svc4 42 none root4
rt4: make-test-runtime "consumer4" consumer4
fb4: make-plugin-fiber root4 make map! [] make map! [svc4: none] rt4
assert equal? 42 got-value "注入 fiber 读取服务值 42"

; ------------------------------------------------------------
; Test 5: internal-service event
; ------------------------------------------------------------

svc-events: copy []
svc-listener: func [args [block!]] [append svc-events args/1]
root5: make-root
root5/events/on 'internal-service 'svc-listener make map! [] none
dp5: root5/reflect/provide 'svc5 "s5" none root5
assert equal? 1 length? svc-events "internal-service 触发 1 次"
assert equal? 'svc5 first svc-events "事件名 svc5"

; ------------------------------------------------------------
; Test 6: accessor / mixin (simplified)
; ------------------------------------------------------------

root6: make-root
; accessor
acc-count: 0
acc-get: make object! [
    call: func [args [block!] this-arg [object! none!]] [
        acc-count: acc-count + 1
        "from-accessor"
    ]
]
da: root6/reflect/accessor 'computed make map! compose [get: (acc-get) set: (none)]
assert not none? select root6/reflect/props 'computed "accessor 已声明"
pa: select root6/reflect/props 'computed
assert equal? "accessor" select pa 'type "accessor type"
ga: select pa 'get
assert equal? "from-accessor" ga/call [] none "accessor get 调用"

; mixin: source service + field delegation
svc-obj: make object! [bar: 1]
root6/reflect/provide 'foo6 svc-obj none root6
dm: root6/reflect/mixin 'foo6 ['bar]
pb: select root6/reflect/props 'bar
assert not none? pb "mixin 声明 bar accessor"
gb: select pb 'get
assert equal? 1 gb/call [] none "mixin get 从源服务取字段"

; ------------------------------------------------------------
; Test 7: service injection leak - dependent fiber stops after dispose
; ------------------------------------------------------------

order7: copy []
leak-plugin7: make object! [
    name: "leak7"
    inject: ['svc7]
    apply: func [ctx [object!] config] [
        append order7 'leak-start
        make object! [dispose: func [] [append order7 'leak-stop]]
    ]
]
root7: make-root
dp7: root7/reflect/provide 'svc7 "s7" none root7
rt7: make-test-runtime "leak7" leak-plugin7
fb7: make-plugin-fiber root7 make map! [] make map! [svc7: none] rt7
assert equal? 1 length? order7 "leak 插件启动"
fb7/dispose/dispose
assert equal? 2 length? order7 "leak 插件停止"
assert equal? fiber-state/DISPOSED fb7/state "fiber DISPOSED"

print rejoin ["^/==== reflect-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
