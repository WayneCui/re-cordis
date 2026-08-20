REBOL []

do %../logger.reb
do %../service.reb

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

assert-trace-equal: func [ctx [object!] expected-file [file!] label [string!] /local actual expected] [
    actual: join-trace-lines runtime-trace-lines ctx
    expected: normalize-trace-text to-string read expected-file
    assert equal? expected actual label
]

greeter-plugin: make object! [
    name: "greeter"
    inject: []
    apply: func [ctx [object!] config /local svc prefix] [
        prefix: any [all [map? config  select config 'prefix]  "Hello"]
        svc: make object! [
            ctx: none
            name: none
            prefix: none
            greet: func [who [string!]] [rejoin [prefix " " who]]
        ]
        svc/prefix: prefix
        make-service ctx 'greeter svc
        make object! [dispose: func [] [none]]
    ]
]

receptionist: make object! [
    name: "receptionist"
    inject: ['greeter]
    apply: func [ctx [object!] config /local listener ex] [
        listener: make object! [
            app-ctx: ctx
            call: func [args [block!] this-arg [object! none!] /local g] [
                g: app-ctx/reflect/get 'greeter true app-ctx
                either g [g/greet first args][none]
            ]
        ]
        ctx/events/on 'guest-arrived listener make map! [] ctx
        ex: func [] [make object! [dispose: func [] [none]]]
        ctx/fiber/effect :ex "desk"
        none
    ]
]

root: make-context
runtime-clear-trace root
desk-fb: root/registry/plugin receptionist make map! [] root
greeter-fb: root/registry/plugin greeter-plugin make map! [prefix: "Hello"] root
root/events/emit 'guest-arrived ["Ada"] none
greeter-fb/update make map! [prefix: "Hi"] false
desk-fb/dispose/dispose
greeter-fb/dispose/dispose

assert-trace-equal root (expected-path "m0-greeter-update.trace") "greeter update trace matches golden"

print rejoin ["^/==== m0-greeter-trace-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
