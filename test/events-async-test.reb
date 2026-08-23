REBOL []

; ============================================================
; test/events-async-test.reb
; Waterfall may return a thenable when inner or a listener suspends.
; Sync chain from events-test.reb must keep working (run that file separately).
; Run: rebol3 -s test/events-async-test.reb
; ============================================================

do %../utils.reb
do %../events.reb
do %../deterministic-scheduler.reb

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
    ]
    ctx/fiber: make-stub-fiber
    ctx/events: make-events-service ctx
    ctx/root: ctx
    ctx
]

sched: make-deterministic-scheduler

async-inner: func [args [block!]] [
    thenable-delay sched 10 2
]

; listener: after next settles, add the first arg
wf-add: func [args [block!] /local nw] [
    nw: last args
    thenable-map nw/call make object! [
        addend: args/1
        call: func [v] [addend + v]
    ]
]

root: make-stub-ctx
ev: root/events
ev/on 'async-waterfall 'wf-add make map! [] none
ev/on 'async-waterfall 'wf-add make map! [] none
rw: ev/waterfall 'async-waterfall [1] 'async-inner none
assert thenable? rw "waterfall returns thenable when inner delays"
assert equal? 4 thenable-wait rw sched "two adders + delayed inner = 4"

; Short-circuit still skips next (and never schedules inner)
sched2: make-deterministic-scheduler
skip-next: func [args [block!]] [args/1]
root2: make-stub-ctx
root2/events/on 'async-waterfall 'skip-next make map! [] none
root2/events/on 'async-waterfall 'wf-add make map! [] none
rw2: root2/events/waterfall 'async-waterfall [9] 'async-inner none
assert equal? 9 rw2 "short-circuit stays sync and skips inner"
assert not sched2/pending? "short-circuit does not queue inner delay"

print rejoin ["^/==== events-async-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
