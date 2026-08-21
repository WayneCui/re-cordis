REBOL []

; ============================================================
; test/inspector-test.reb - Verify Effect Tree formatting
; ============================================================

do %../inspector.reb

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

normalize-text: func [text [string!]] [
    while [all [not empty? text  equal? #"^/" last text]] [remove back tail text]
    text
]

consumer-plugin: make object! [
    name: "consumer"
    inject: []
    apply: func [ctx config /local l] [
        l: make object! [call: func [a t][none]]
        ctx/events/on 'ping l make map! [] ctx
        ctx/reflect/provide 'foo 1 none ctx
    ]
]

root: make-context
fb1: root/registry/plugin consumer-plugin make map! [] root

actual: dump-effect-tree root

expected: {root#0 (ACTIVE)
└── [Effect] ctx.plugin()
    └── consumer#1 (ACTIVE)
        ├── [Effect] ctx.on(ping)
        └── [Effect] ctx.provide(foo)}

assert equal? (normalize-text expected) (normalize-text actual) "inspector dumps formatted tree correctly"

print rejoin ["^/==== inspector-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
