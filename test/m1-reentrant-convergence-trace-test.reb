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

join-trace-lines: func [lines [block!] /local out] [
    out: copy ""
    foreach line lines [append out rejoin [line "^/"]]
    normalize-trace-text out
]

expected-path: func [name [string!]] [
    to-file rejoin [%../scenarios/expected/ name]
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

actual: copy "# snapshots^/"
append actual rejoin [
    "t0-provider=" fiber-state-name provider/state
    " t0-consumer=" fiber-state-name consumer/state
    "^/"
]

runtime-step root 1000
append actual rejoin [
    "t1000-provider=" fiber-state-name provider/state
    " t1000-consumer=" fiber-state-name consumer/state
    " applied=" mold applied
    "^/"
]

provider/update make map! [value: 2] false
append actual rejoin [
    "after-provider-update=" fiber-state-name provider/state
    " consumer=" fiber-state-name consumer/state
    "^/"
]

consumer/update make map! [mode: "new"] false
append actual rejoin [
    "after-consumer-update=" fiber-state-name consumer/state
    " applied=" mold applied
    "^/"
]

runtime-step root 1000
append actual rejoin [
    "t2000-provider=" fiber-state-name provider/state
    " t2000-consumer=" fiber-state-name consumer/state
    " applied=" mold applied
    "^/^/# trace^/"
]
append actual join-trace-lines runtime-trace-lines root
actual: normalize-trace-text actual

expected: normalize-trace-text to-string read (expected-path "m1-reentrant-convergence.trace")

assert equal? expected actual "reentrant convergence trace matches golden"

print rejoin ["^/==== m1-reentrant-convergence-trace-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
