REBOL []

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

normalize-trace-text: func [text [string!]] [
    while [all [not empty? text equal? #"^/" last text]] [remove back tail text]
    text
]

expected-path: func [name [string!]] [
    to-file rejoin [%../scenarios/expected/ name]
]

join-trace-lines: func [lines [block!] /local out] [
    out: copy ""
    foreach line lines [append out rejoin [line "^/"]]
    normalize-trace-text out
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

actual: copy "# snapshots^/"
append actual rejoin ["t0=" fiber-state-name fb/state "^/"]
runtime-step root 1000
append actual rejoin ["t1000=" fiber-state-name fb/state "^/"]
root/events/emit 'ping [] none
append actual rejoin ["hits-after-fail=" hits "^/"]
fb/update make map! [fail: false] false
append actual rejoin ["after-update=" fiber-state-name fb/state "^/"]
runtime-step root 1000
append actual rejoin ["t2000=" fiber-state-name fb/state "^/"]
root/events/emit 'ping [] none
append actual rejoin ["hits-after-recovery=" hits "^/^/# trace^/"]
append actual join-trace-lines runtime-trace-lines root
actual: normalize-trace-text actual
expected: normalize-trace-text to-string read (expected-path "m1-failure-recovery.trace")

assert equal? expected actual "failure recovery trace matches golden"

print rejoin ["^/==== m1-failure-recovery-trace-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
