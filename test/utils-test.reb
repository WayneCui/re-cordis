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
assert equal? 0 l/length "length 初始为 0"

d1: l/push 111
d2: l/push 222
d3: l/push 333
assert equal? 3 l/length "push 3 个后 length = 3"
assert equal? [111 222 333] l/values "values 按插入序"

; disposer removes a middle item
d2/dispose
assert equal? 2 l/length "dispose 后 length = 2"
assert equal? [111 333] l/values "dispose 后 values 正确"

; dispose is idempotent when called again (harmless if the idx is already gone)
d2/dispose
assert equal? 2 l/length "重复 dispose 幂等"

; clear returns values in reverse order
vals: l/clear
assert equal? [333 111] vals "clear 返回逆序 values"
assert equal? 0 l/length "clear 后 length = 0"

; delete removes by value (identity comparison)
d4: l/push 444
d5: l/push 555
assert l/delete 444 "delete 找到并删除"
assert equal? [555] l/values "delete 后 values 正确"
assert not l/delete 999 "delete 不存在的值返回 false"
assert equal? 1 l/length "delete 失败后 length 不变"

; Object values can also be stored
obj1: make object! [x: 1]
obj2: make object! [x: 2]
do1: l/push obj1
do2: l/push obj2
assert equal? 3 l/length "对象值 push 后 length = 3"
do1/dispose
assert equal? reduce [555 obj2] l/values "对象 disposer 按身份删除"

; After clear, calling the disposer is still harmless
l/clear
d5/dispose
assert equal? 0 l/length "clear 后 disposer 调用无害"

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
assert equal? 42 ok "compose-error 正常路径返回结果"

err: compose-error does [print undefined-word-xyz] "test"
assert string? err "compose-error 错误路径返回字符串"
assert not none? find err "undefined-word-xyz" "compose-error 错误信息含上下文"

print rejoin ["^/==== utils-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
