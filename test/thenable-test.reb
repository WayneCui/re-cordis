REBOL []

; ============================================================
; test/thenable-test.reb
; Run: rebol3 -s test/thenable-test.reb
; ============================================================

do %../thenable.reb
do %../deterministic-scheduler.reb

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

; ------------------------------------------------------------
t: make-thenable
got: none
t/then make object! [call: func [v] [got: v]]
assert none? got "then before resolve does not run"
t/resolve 7
assert equal? 7 got "then after resolve runs"

; ------------------------------------------------------------
t2: make-thenable
t2/resolve "ready"
got2: none
t2/then make object! [call: func [v] [got2: v]]
assert equal? "ready" got2 "then on already-resolved runs immediately"

t2/resolve "ignored"
assert equal? "ready" got2 "second resolve is a no-op"

; ------------------------------------------------------------
inner: make-thenable
outer: make-thenable
flat: none
outer/then make object! [call: func [v] [flat: v]]
outer/resolve inner
assert none? flat "flatten waits on inner"
inner/resolve 11
assert equal? 11 flat "flatten delivers inner value"

; ------------------------------------------------------------
assert equal? 4 thenable-wait 4 none "wait on plain value"
assert equal? "x" thenable-wait thenable-of "x" none "wait on resolved thenable"

; ------------------------------------------------------------
sched: make-deterministic-scheduler
delayed: thenable-delay sched 10 42
assert thenable? delayed "delay returns thenable"
assert delayed/pending "delay is pending before pump"
assert equal? 42 thenable-wait delayed sched "wait pumps scheduler to settlement"

mapped: thenable-map 3 make object! [call: func [v] [v + 1]]
assert equal? 4 mapped "map on plain value is sync"

sched2: make-deterministic-scheduler
mapped2: thenable-map thenable-delay sched2 5 10 make object! [call: func [v] [v * 2]]
assert thenable? mapped2 "map on thenable stays thenable"
assert equal? 20 thenable-wait mapped2 sched2 "map applies after delay"

print rejoin ["^/==== thenable-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
