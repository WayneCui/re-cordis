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
    while [all [not empty? text  equal? #"^/" last text]] [remove back tail text]
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

root: make-context
runtime-use-scheduler root make-deterministic-scheduler
runtime-clear-trace root

d1: root/reflect/provide 'foo 1 none root
fb: root/registry/plugin (make-async-consumer 1000 1000) make map! [] root

output: copy "# snapshots^/"
append output rejoin ["t0=" (fiber-state-name fb/state) "^/"]
runtime-step root 400
append output rejoin ["t400=" (fiber-state-name fb/state) "^/"]
d1/dispose
runtime-step root 400
append output rejoin ["t800=" (fiber-state-name fb/state) "^/"]
runtime-step root 400
append output rejoin ["t1200=" (fiber-state-name fb/state) "^/"]
root/reflect/provide 'foo 1 none root
runtime-step root 1000
append output rejoin ["t2200=" (fiber-state-name fb/state) "^/"]
runtime-step root 1000
append output rejoin ["t3200=" (fiber-state-name fb/state) "^/^/# trace^/"]
append output (join-trace-lines (runtime-trace-lines root))

expected: normalize-trace-text (to-string read (expected-path "m1-inertia-lock-1.trace"))
assert equal? expected (normalize-trace-text output) "inertia lock 1 trace matches golden"

print rejoin ["^/==== m1-inertia-trace-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
