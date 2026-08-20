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

assert-trace-equal: func [ctx [object!] expected-file [file!] label [string!] /local actual expected] [
    actual: join-trace-lines runtime-trace-lines ctx
    expected: normalize-trace-text to-string read expected-file
    assert equal? expected actual label
]

iso-guest: make object! [
    name: "iso-guest"
    inject: ['greeter]
    apply: func [ctx [object!] config] [none]
]

root: make-context
runtime-clear-trace root
root/registry/plugin iso-guest make map! [room: "root"] root
ctx-a: root/isolate 'greeter 'room-a
ctx-a/registry/plugin iso-guest make map! [room: "A"] ctx-a
ctx-b: root/isolate 'greeter 'room-b
ctx-b/registry/plugin iso-guest make map! [room: "B"] ctx-b
root/reflect/provide 'greeter "g-root" none root
ctx-a/reflect/provide 'greeter "g-a" none ctx-a
ctx-b/reflect/provide 'greeter "g-b" none ctx-b

assert-trace-equal root (expected-path "m0-isolate-rooms.trace") "isolate trace matches golden"

print rejoin ["^/==== m0-isolate-trace-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
