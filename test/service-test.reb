REBOL []

; ============================================================
; test/service-test.reb — service.reb 行为测试 (P7)
; 移植自 ref/tests/service.spec.ts (同步版可移植部分)
; 运行: rebol3 -s test/service-test.reb
;
; 跳过 (同步版限制, ROADMAP §7):
;   - pending inject (async Service.init 挂起)
;   - traceable effect (Proxy 上下文穿透)
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
; Test 1: 服务构造自动注册 (super(ctx, name) → reflect.provide)
; ------------------------------------------------------------

root1: make-context
root1/logger: make-stub-logger
foo1: make object! [
    ctx: none
    name: none
    value: 42
]
make-service root1 'foo1 foo1
; 注意: 服务值就是服务对象本身 (上游 provide(name, self))
assert same? foo1 root1/reflect/get 'foo1 true root1 "服务构造后自动注册 (reflect.get)"
assert equal? 'foo1 foo1/name "服务 name 注入"
assert equal? 42 select foo1 'value "服务字段保留"
assert equal? root1 foo1/ctx "服务 ctx 注入"

; ------------------------------------------------------------
; Test 2: resolveConfig 基础 (base + head 合并, 无 intercept)
; ------------------------------------------------------------

root2: make-context
root2/logger: make-stub-logger
foo2: make object! [ctx: none name: none]
make-service root2 'foo2 foo2
cfg2: service-resolve-config foo2 make map! [a: 1] make map! [b: 2]
assert equal? 1 select cfg2 'a "resolveConfig base 生效"
assert equal? 2 select cfg2 'b "resolveConfig head 生效"

; ------------------------------------------------------------
; Test 3: resolveConfig 多层 intercept 链 (链式 shadowing 核心)
; ------------------------------------------------------------

root3: make-context
root3/logger: make-stub-logger
; intercept 不可变 shadowing: 返回新 ctx, 必须接住返回值
root3: root3/intercept 'foo3 make map! [a: 1]
sub3: root3/extend make map! []
sub3: sub3/intercept 'foo3 make map! [b: 2]
foo3: make object! [ctx: none name: none]
make-service sub3 'foo3 foo3
cfg3: service-resolve-config foo3 none none
assert equal? 1 select cfg3 'a "链式 shadowing: 根层 a 保留"
assert equal? 2 select cfg3 'b "链式 shadowing: 叶层 b 生效"

; ------------------------------------------------------------
; Test 4: 叶层覆盖根层同名键 + base 优先级
; ------------------------------------------------------------

root4: make-context
root4/logger: make-stub-logger
root4: root4/intercept 'foo4 make map! [level: 'base]
sub4: root4/extend make map! []
sub4: sub4/intercept 'foo4 make map! [level: 'leaf]
foo4: make object! [ctx: none name: none]
make-service sub4 'foo4 foo4
cfg4: service-resolve-config foo4 none none
assert equal? 'leaf select cfg4 'level "叶层配置覆盖根层"
cfg4b: service-resolve-config foo4 make map! [level: 'base-arg] none
assert equal? 'leaf select cfg4b 'level "链上配置覆盖 base 参数"
cfg4c: service-resolve-config foo4 none make map! [level: 'head]
assert equal? 'head select cfg4c 'level "head 参数优先级最高"

; ------------------------------------------------------------
; Test 5: Config.merge 自定义合并器
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
assert equal? 'merged select cfg5 'custom "Config.merge 自定义合并生效"
assert equal? 2 first merge-log "merge 收到全部 config (base+head)"

; ------------------------------------------------------------
; Test 6: multiple injects — 服务作为插件, 依赖满足后各 init 一次
; 上游: Foo.inject=['qux'], Bar.inject=['foo','qux'], Qux 无依赖
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
assert equal? 3 length? order6 "multiple injects: 三个服务 init 各一次"
assert equal? 'qux first order6 "依赖排序: 无依赖的 qux 最先"
assert equal? 'bar last order6 "依赖最多的 bar 最后"

print rejoin ["^/==== service-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
