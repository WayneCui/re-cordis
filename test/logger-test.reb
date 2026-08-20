REBOL []

; ============================================================
; test/logger-test.reb - behavior tests for logger.reb (P8)
; Ported from ref/tests/logger.spec.ts (synchronously portable parts)
; Run: rebol3 -s test/logger-test.reb
;
; Skipped (synchronous version limitation): name tunneling from inside a service (traceable context)
; ============================================================

do %../utils.reb
do %../events.reb
do %../fiber.reb
do %../reflect.reb
do %../registry.reb
do %../context.reb
do %../service.reb
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

; ------------------------------------------------------------
; Test 1: bounded buffer - size limit + chronological order (first upstream test)
; ------------------------------------------------------------

root1: make-context
root1/logger/buffer-size: 2
root1/logger/info "one"
root1/logger/info "two"
root1/logger/info "three"
b1: root1/logger/buffer
assert equal? 2 length? b1 "buffer stays bounded (size=2)"
assert equal? "two" b1/1/args/1 "buffer keeps latest two (first)"
assert equal? "three" b1/2/args/1 "buffer keeps latest two (second)"
root1/logger/buffer-size: 1
root1/logger/info "four"
assert equal? 1 length? root1/logger/buffer "buffer shrinks to size=1"
assert equal? "four" root1/logger/buffer/1/args/1 "keeps latest after shrink"
root1/logger/buffer-size: 0
root1/logger/info "five"
assert equal? 0 length? root1/logger/buffer "buffer-size 0 -> empty"

; ------------------------------------------------------------
; Test 2: exporter registration/unregistration - disposer isolation
; ------------------------------------------------------------

root2: make-context
root2/logger/exporters: make map! []   ; clear the default exporter
cap2: copy []
exp2a: make object! [
    levels: make map! []
    export: func [msg] [append cap2 msg/args/1]
]
d2a: root2/logger/exporter exp2a
root2/logger/info "hello"
assert equal? 1 length? cap2 "exporter received message"
assert equal? "hello" first cap2 "message content correct"
d2a/dispose
root2/logger/info "world"
assert equal? 1 length? cap2 "no more messages after unregister"

; The second exporter is unaffected by the first exporter's disposal
cap2b: copy []
exp2b: make object! [
    levels: make map! []
    export: func [msg] [append cap2b msg/args/1]
]
d2b: root2/logger/exporter exp2b
root2/logger/info "x"
assert equal? 1 length? cap2b "independent exporter receives normally"
d2b/dispose

; ------------------------------------------------------------
; Test 3: name resolution - default fiber name (upstream: 'root')
; ------------------------------------------------------------

root3: make-context
names3: copy []
root3/logger/exporters: make map! []
; debug(3) requires levels.default=3 (same as upstream setup)
root3/logger/exporter make object! [
    levels: make map! [default: 3]
    export: func [msg] [append names3 msg/name]
]
root3/logger/debug "hello"
assert equal? "root" first names3 "default name = fiber name (root)"

; ------------------------------------------------------------
; Test 4: explicit name parameter (upstream ctx.logger('custom'))
; ------------------------------------------------------------

lg4: root3/logger/create 'custom
lg4/debug "hello"
assert equal? "custom" names3/2 "explicit name applied"

; ------------------------------------------------------------
; Test 5: intercept name (upstream ctx.intercept('logger', {name}))
; Note: intercept uses immutable shadowing, so you must capture the returned ctx
; ------------------------------------------------------------

root5: make-context
root5: root5/intercept 'logger make map! [name: 'intercepted]
names5: copy []
root5/logger/exporters: make map! []
root5/logger/exporter make object! [
    levels: make map! [default: 3]
    export: func [msg] [append names5 msg/name]
]
root5/logger/debug "hello"
assert equal? "intercepted" first names5 "intercept name applied"

; ------------------------------------------------------------
; Test 6: level filtering - default INFO(2): error/warn/info pass, debug does not
; ------------------------------------------------------------

root6: make-context
types6: copy []
root6/logger/exporters: make map! []
root6/logger/exporter make object! [
    levels: make map! []
    export: func [msg] [append types6 msg/type]
]
root6/logger/error "e"
root6/logger/warn "w"
root6/logger/info "i"
root6/logger/debug "d"
assert equal? 3 length? types6 "default level INFO: 3 pass"
assert equal? 'error types6/1 "error passes"
assert not find types6 'debug "debug filtered out"

; levels.default = 3 (DEBUG) -> everything passes
root6b: make-context
types6b: copy []
root6b/logger/exporters: make map! []
root6b/logger/exporter make object! [
    levels: make map! [default: 3]
    export: func [msg] [append types6b msg/type]
]
root6b/logger/debug "d"
assert equal? 1 length? types6b "debug passes when levels.default=3"

; levels can be configured per name: only allow foo's debug
root6c: make-context
types6c: copy []
root6c/logger/exporters: make map! []
root6c/logger/exporter make object! [
    levels: make map! [foo: 3]
    export: func [msg] [append types6c msg/type]
]
lg6c: root6c/logger/create 'foo
lg6c/debug "d"
root6c/logger/debug "x"   ; name=root, not configured -> default INFO -> filtered out
assert equal? 1 length? types6c "per-name levels config applied"

print rejoin ["^/==== logger-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
