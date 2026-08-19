REBOL []

; ============================================================
; test/events-test.reb - behavior tests for events.reb (P2)
; Ported from ref/tests/events.spec.ts (vitest cases)
; Run: rebol3 -s test/events-test.reb
; ============================================================

do %../utils.reb
do %../events.reb

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
; stub fiber / ctx (minimal stand-in before P3)
; ------------------------------------------------------------

make-stub-fiber: func [] [
    make object! [
        active: true
        disposables: make-disposable-list
        hooks: make map! []
        assert-active: func [] [
            unless active [print "ERROR: fiber not active"]
        ]
        effect: func [callback [function!] label [string!] /local disp] [
            disp: callback
            disposables/push disp
            disp
        ]
    ]
]

make-stub-ctx: func [/local ctx] [
    ctx: make object! [
        fiber: none
        events: none
        filter: none
        root: none
        extend: func [props [object!] /local new] [
            new: make object! [
                fiber: none
                events: none
                filter: none
                root: none
            ]
            new/fiber: root/fiber
            new/events: root/events
            new/filter: props/filter
            new/root: root
            new
        ]
    ]
    ctx/fiber: make-stub-fiber
    ctx/events: make-events-service ctx
    ctx/root: ctx
    ctx
]

; Filter/Session: the filter field = word! function name
filter-true:  func [ctx] [true]
filter-false: func [ctx] [false]

make-filter: func [flag /local f] [
    f: make object! [filter: none]
    f/filter: either flag ['filter-true]['filter-false]
    f
]
make-session: func [flag] [make-filter flag]

; ------------------------------------------------------------
; Test 1: ctx.on() - called by emit / removed by dispose
; ------------------------------------------------------------

c1: 0
cb1: func [args [block!]] [c1: c1 + 1]

root: make-stub-ctx
ev: root/events
d: ev/on 'test-event 'cb1 make map! [] none
ev/emit 'test-event [] none
assert equal? 1 c1 "on: emit 第1次调用"
ev/emit 'test-event [] none
assert equal? 2 c1 "on: emit 第2次调用"
d/dispose
ev/emit 'test-event [] none
assert equal? 2 c1 "on: dispose 后不再调用"

; ------------------------------------------------------------
; Test 2: ctx.once()
; ------------------------------------------------------------

c3: 0
cb3: func [args [block!]] [c3: c3 + 1]
d3: ev/once 'test-event 'cb3 make map! [] none
ev/emit 'test-event [] none
assert equal? 1 c3 "once: 第1次调用"
ev/emit 'test-event [] none
assert equal? 1 c3 "once: 第2次不调用"
d3/dispose
ev/emit 'test-event [] none
assert equal? 1 c3 "once: dispose 后不调用"

; ------------------------------------------------------------
; Test 3: emit/parallel - Session thisArg filtering
; ------------------------------------------------------------

c2: 0
cb2: func [args [block!]] [c2: c2 + 1]

ft-ctx: root/extend make-filter true
ft-ctx/events/on 'test-filter 'cb2 make map! [] none
ev/emit 'test-filter [] none
assert equal? 1 c2 "emit: 无 thisArg 全调用"
ev/emit 'test-filter reduce [make-session false] none
assert equal? 1 c2 "emit: Session(false) 排除过滤 ctx 的 hook"
ev/emit 'test-filter reduce [make-session true] none
assert equal? 2 c2 "emit: Session(true) 包含过滤 ctx 的 hook"

; parallel matches emit here (synchronous, no concurrency)
ev/parallel 'test-filter [] none
assert equal? 3 c2 "parallel: 无错误时正常调用"

; ------------------------------------------------------------
; Test 4: parallel - error aggregation (synchronous version returns an error block)
; ------------------------------------------------------------

err-a: func [args [block!]] [print undefined-word-a]
err-b: func [args [block!]] [print undefined-word-b]
pe: ev/parallel 'test-parallel [] none
assert none? pe "parallel: 无 listener 返回 none"
ev/on 'test-parallel 'err-a make map! [] none
ev/on 'test-parallel 'err-b make map! [] none
pe2: ev/parallel 'test-parallel [] none
assert block? pe2 "parallel: 有错误返回错误块"
assert equal? 2 length? pe2 "parallel: 聚合 2 个错误"

; ------------------------------------------------------------
; Test 5: serial - short-circuit on the first is-bailed result
; ------------------------------------------------------------

serial-c-count: 0
serial-a: func [args [block!]] [none]
serial-b: func [args [block!]] [42]
serial-c: func [args [block!]] [serial-c-count: serial-c-count + 1  99]
ev/on 'test-serial 'serial-a make map! [] none
ev/on 'test-serial 'serial-b make map! [] none
ev/on 'test-serial 'serial-c make map! [] none
r: ev/serial 'test-serial [] none
assert equal? 42 r "serial: 返回首个非空结果"
assert equal? 0 serial-c-count "serial: 短路后不调用后续"

; ------------------------------------------------------------
; Test 6: bail - same behavior as serial
; ------------------------------------------------------------

bail-a: func [args [block!]] [false]
bail-b: func [args [block!]] [true]
ev/on 'test-bail 'bail-a make map! [] none
ev/on 'test-bail 'bail-b make map! [] none
rb: ev/bail 'test-bail [] none
assert equal? true rb "bail: 返回首个非空结果 (false 跳过)"

; ------------------------------------------------------------
; Test 7: waterfall - chained next
; ------------------------------------------------------------

wfall-inner: func [args [block!]] [2]
wf1: func [args [block!] /local nw] [nw: last args  args/1 + nw/call]
wf2: func [args [block!] /local nw] [nw: last args  args/1 + nw/call]

ev/on 'test-waterfall 'wf1 make map! [] none
ev/on 'test-waterfall 'wf2 make map! [] none
rw: ev/waterfall 'test-waterfall [1] 'wfall-inner none
assert equal? 4 rw "waterfall: 链式累加 = 4"

; Midway short-circuit: wf3 does not call next
wf3: func [args [block!]] [args/1]
ev/on 'test-waterfall 'wf3 make map! [] none
rw2: ev/waterfall 'test-waterfall [1] 'wfall-inner none
assert equal? 3 rw2 "waterfall: 短路 = 3"

; ------------------------------------------------------------
; Test 8: internal/listener - internal-update is stored in fiber hooks
; ------------------------------------------------------------

iu-cb: func [args [block!]] [none]
diu: ev/on 'internal-update 'iu-cb make map! [] none
fiber-hooks: select root/fiber/hooks 'internal-update
assert not none? fiber-hooks "internal-update 非 global → 存入 fiber._hooks"
assert equal? 1 fiber-hooks/length "internal-update disposables 含 1 个 listener"
diu/dispose
assert equal? 0 fiber-hooks/length "internal-update disposer 移除 listener"

print rejoin ["^/==== events-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
