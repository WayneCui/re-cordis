REBOL []

; ============================================================
; test/m1-reentrant-convergence-test.reb - M1 reentrant churn tests
; Verifies:
;   1. async provider load activates a waiting consumer
;   2. provider update can overlap with consumer update
;   3. both fibers converge to the last epoch/config after churn
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

make-async-provider: func [delay [integer!]] [
    make object! [
        name: "async-provider"
        inject: []
        load-delay: delay
        apply: func [ctx [object!] config /local task] [
            task: make object! [
                task-kind: 'scheduled
                delay: 0
                ctx-ref: none
                value-ref: none
                run: func [] [ctx-ref/reflect/provide 'provider value-ref none ctx-ref]
            ]
            task/delay: load-delay
            task/ctx-ref: ctx
            task/value-ref: select config 'value
            task
        ]
    ]
]

applied: copy []

consumer-plugin: make object! [
    name: "consumer"
    inject: ['provider]
    apply: func [ctx [object!] config /local value mode] [
        value: ctx/reflect/get 'provider true ctx
        mode: select config 'mode
        append/only applied reduce [value mode]
        none
    ]
]

root: make-context
runtime-use-scheduler root make-deterministic-scheduler
runtime-clear-trace root

provider: root/registry/plugin (make-async-provider 1000) make map! [value: 1] root
consumer: root/registry/plugin consumer-plugin make map! [mode: "old"] root

assert equal? fiber-state/LOADING provider/state "reentrant: provider starts LOADING"
assert equal? fiber-state/PENDING consumer/state "reentrant: consumer waits for provider"

runtime-step root 1000
assert equal? fiber-state/ACTIVE provider/state "reentrant: provider becomes ACTIVE after load"
assert equal? fiber-state/ACTIVE consumer/state "reentrant: consumer activates after provider load"
assert equal? [[1 "old"]] applied "reentrant: consumer sees initial provider/config pair"

provider/update make map! [value: 2] false
assert equal? fiber-state/LOADING provider/state "reentrant: provider re-enters LOADING on update"
assert equal? fiber-state/PENDING consumer/state "reentrant: consumer drops to PENDING during provider churn"

consumer/update make map! [mode: "new"] false
assert equal? fiber-state/PENDING consumer/state "reentrant: consumer update stays pending without provider"
assert equal? [[1 "old"]] applied "reentrant: no eager rerun during churn"

runtime-step root 1000
assert equal? fiber-state/ACTIVE provider/state "reentrant: provider converges to ACTIVE"
assert equal? fiber-state/ACTIVE consumer/state "reentrant: consumer converges to ACTIVE"
assert equal? [[1 "old"] [2 "new"]] applied "reentrant: consumer sees final provider/config pair"

print rejoin ["^/==== m1-reentrant-convergence-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
