REBOL []

; ============================================================
; test/m1-inertia-test.reb - M1 deterministic scheduler tests
; Verifies:
;   1. inertia lock 1
;   2. inertia lock 2
;   3. provider removal while consumer is ACTIVE
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

make-async-disposer: func [delay [integer!]] [
    make object! [
        delay-ref: delay
        dispose: func [] [make-scheduled-value delay-ref none]
    ]
]

make-async-consumer: func [delay-load [integer!] delay-unload [integer!]] [
    make object! [
        name: "async-consumer"
        inject: ['foo]
        load-delay: delay-load
        unload-delay: delay-unload
        apply: func [ctx [object!] config] [
            make-scheduled-value load-delay make-async-disposer unload-delay
        ]
    ]
]

; ------------------------------------------------------------
; Test 1: inertia lock 1
; ------------------------------------------------------------

root1: make-context
runtime-use-scheduler root1 make-deterministic-scheduler
runtime-clear-trace root1
d1: root1/reflect/provide 'foo 1 none root1
fb1: root1/registry/plugin (make-async-consumer 1000 1000) make map! [] root1
assert equal? fiber-state/LOADING fb1/state "lock1: initial state LOADING"
runtime-step root1 400
assert equal? fiber-state/LOADING fb1/state "lock1: 400ms still LOADING"
d1/dispose
runtime-step root1 400
assert equal? fiber-state/LOADING fb1/state "lock1: 800ms still LOADING"
runtime-step root1 400
assert equal? fiber-state/UNLOADING fb1/state "lock1: 1200ms enters UNLOADING"
root1/reflect/provide 'foo 1 none root1
runtime-step root1 1000
assert equal? fiber-state/LOADING fb1/state "lock1: 2200ms returns to LOADING"
runtime-step root1 1000
assert equal? fiber-state/ACTIVE fb1/state "lock1: 3200ms converges to ACTIVE"

; ------------------------------------------------------------
; Test 2: inertia lock 2
; ------------------------------------------------------------

root2: make-context
runtime-use-scheduler root2 make-deterministic-scheduler
d2: root2/reflect/provide 'foo 1 none root2
fb2: root2/registry/plugin (make-async-consumer 1000 1000) make map! [] root2
assert equal? fiber-state/LOADING fb2/state "lock2: initial state LOADING"
runtime-step root2 400
assert equal? fiber-state/LOADING fb2/state "lock2: 400ms still LOADING"
d2/dispose
runtime-step root2 400
assert equal? fiber-state/LOADING fb2/state "lock2: 800ms still LOADING"
root2/reflect/provide 'foo 2 none root2
runtime-step root2 400
assert equal? fiber-state/ACTIVE fb2/state "lock2: 1200ms directly returns ACTIVE"

; ------------------------------------------------------------
; Test 3: inertia lock 3
; ------------------------------------------------------------

root3: make-context
runtime-use-scheduler root3 make-deterministic-scheduler
d3: root3/reflect/provide 'foo 1 none root3
fb3: root3/registry/plugin (make-async-consumer 1000 1000) make map! [] root3
runtime-step root3 1000
assert equal? fiber-state/ACTIVE fb3/state "lock3: after 1000ms consumer ACTIVE"
d3/dispose
assert equal? fiber-state/UNLOADING fb3/state "lock3: dispose immediately enters UNLOADING"
runtime-step root3 1000
assert equal? fiber-state/PENDING fb3/state "lock3: after disposer settles consumer PENDING"

print rejoin ["^/==== m1-inertia-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
