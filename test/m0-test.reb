REBOL []

; ============================================================
; test/m0-test.reb - M0 trusted-lab regression tests
; Verifies:
;   1. runtime scope isolates fibers between roots
;   2. lifecycle journal records stable, replayable trace lines
; ============================================================

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

assert-trace-equal: func [ctx [object!] expected-path [file! string!] label [string!] /local actual expected] [
    actual: join-trace-lines runtime-trace-lines ctx
    expected: normalize-trace-text to-string read to-file expected-path
    assert equal? expected actual label
]

assert-text-equal: func [actual [string!] expected-path [file! string!] label [string!] /local expected] [
    expected: normalize-trace-text to-string read to-file expected-path
    assert equal? expected normalize-trace-text actual label
]

expected-path: func [name [string!]] [
    to-file rejoin [%../scenarios/expected/ name]
]

; ------------------------------------------------------------
; Test 1: dual root runtime scope - providing in root A does not activate root B
; ------------------------------------------------------------

consumer: make object! [
    name: "consumer"
    inject: ['foo]
    apply: func [ctx [object!] config] [none]
]

root-a: make-context
root-b: make-context
runtime-clear-trace root-a
runtime-clear-trace root-b

fb-a: root-a/registry/plugin consumer make map! [] root-a
fb-b: root-b/registry/plugin consumer make map! [] root-b
root-a/reflect/provide 'foo "a" none root-a

assert equal? fiber-state/ACTIVE fb-a/state "root A consumer becomes ACTIVE"
assert equal? fiber-state/PENDING fb-b/state "root B consumer stays PENDING"
assert equal? 1 length? runtime-fibers-of root-a "root A runtime keeps 1 plugin fiber"
assert equal? 1 length? runtime-fibers-of root-b "root B runtime keeps 1 plugin fiber"
dual-trace: rejoin [
    "# root-a^/" join-trace-lines runtime-trace-lines root-a "^/^/"
    "# root-b^/" join-trace-lines runtime-trace-lines root-b
]
assert-text-equal dual-trace (expected-path "m0-dual-root.trace") "dual-root trace matches golden"

; ------------------------------------------------------------
; Test note:
;   greeter-update and isolate trace regression each run in a dedicated
;   test file so every scenario gets a fresh Rebol process.
; ------------------------------------------------------------

print rejoin ["^/==== m0-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
