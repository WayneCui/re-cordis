REBOL []

; ============================================================
; test/utils-test.reb - behavior tests for utils.reb (P1)
; No upstream utils.spec.ts, so assertions are written against TS DisposableList semantics
; Run: rebol3 -s test/utils-test.reb
; ============================================================

do %../utils.reb

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
; DisposableList
; ------------------------------------------------------------

l: make-disposable-list
assert equal? 0 l/length "length starts at 0"

d1: l/push 111
d2: l/push 222
d3: l/push 333
assert equal? 3 l/length "length = 3 after push 3 items"
assert equal? [111 222 333] l/values "values in insertion order"

; disposer removes a middle item
d2/dispose
assert equal? 2 l/length "length = 2 after dispose"
assert equal? [111 333] l/values "values correct after dispose"

; dispose is idempotent when called again (harmless if the idx is already gone)
d2/dispose
assert equal? 2 l/length "repeated dispose is idempotent"

; clear returns values in reverse order
vals: l/clear
assert equal? [333 111] vals "clear returns values in reverse order"
assert equal? 0 l/length "length = 0 after clear"

; delete removes by value (identity comparison)
d4: l/push 444
d5: l/push 555
assert l/delete 444 "delete finds and removes"
assert equal? [555] l/values "values correct after delete"
assert not l/delete 999 "delete missing value returns false"
assert equal? 1 l/length "length unchanged after failed delete"

; Object values can also be stored
obj1: make object! [x: 1]
obj2: make object! [x: 2]
do1: l/push obj1
do2: l/push obj2
assert equal? 3 l/length "length = 3 after pushing object values"
do1/dispose
assert equal? reduce [555 obj2] l/values "object disposer removes by identity"

; After clear, calling the disposer is still harmless
l/clear
d5/dispose
assert equal? 0 l/length "disposer call harmless after clear"

; ------------------------------------------------------------
; symbols
; ------------------------------------------------------------

assert equal? "cordis-shadow" to-string shadow "symbol shadow"
assert equal? "cordis-initHooks" to-string init-hooks "symbol initHooks"
assert equal? "cordis-resolveConfig" to-string resolve-config "symbol resolveConfig"
assert equal? "cordis-effect" to-string effect "symbol effect"

; ------------------------------------------------------------
; compose-error
; ------------------------------------------------------------

ok: compose-error does [42] "test"
assert equal? 42 ok "compose-error success path returns result"

err: compose-error does [print undefined-word-xyz] "test"
assert string? err "compose-error error path returns string"
assert not none? find err "undefined-word-xyz" "compose-error error message includes context"

print rejoin ["^/==== utils-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
