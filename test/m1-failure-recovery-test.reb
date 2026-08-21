REBOL []

; ============================================================
; test/m1-failure-recovery-test.reb - M1 async failed->recovery tests
; Verifies:
;   1. async reload failure enters FAILED and cleans listeners
;   2. update clears the error and schedules a fresh reload
;   3. recovered fiber returns to ACTIVE without duplicate listeners
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

hits: 0

plugin: make object! [
    name: "async-failing"
    inject: []
    apply: func [ctx [object!] config /local listener fail? raw-fail] [
        listener: make object! [
            call: func [args [block!] this-arg [object! none!]] [hits: hits + 1]
        ]
        ctx/events/on 'ping listener make map! [] ctx
        raw-fail: select config 'fail
        fail?: either word? :raw-fail [get raw-fail][false]
        either fail? [
            make object! [
                task-kind: 'scheduled
                delay: 1000
                run: func [] [print undefined-async-fail]
            ]
        ][
            make-scheduled-value 1000 1
        ]
    ]
]

root: make-context
runtime-use-scheduler root make-deterministic-scheduler
runtime-clear-trace root
fb: root/registry/plugin plugin make map! [fail: true] root

assert equal? fiber-state/LOADING fb/state "failure-recovery: initial state LOADING"
runtime-step root 1000
assert equal? fiber-state/FAILED fb/state "failure-recovery: failed async reload -> FAILED"
assert equal? 1 length? root/logger/buffer "failure-recovery: logger recorded one failure"
root/events/emit 'ping [] none
assert equal? 0 hits "failure-recovery: failed listener cleaned up"

fb/update make map! [fail: false] false
assert equal? fiber-state/LOADING fb/state "failure-recovery: update clears error and re-enters LOADING"
runtime-step root 1000
assert equal? fiber-state/ACTIVE fb/state "failure-recovery: recovered fiber becomes ACTIVE"
assert equal? 1 length? root/logger/buffer "failure-recovery: no extra logger error on recovery"
root/events/emit 'ping [] none
assert equal? 1 hits "failure-recovery: recovered listener fires once"

print rejoin ["^/==== m1-failure-recovery-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
