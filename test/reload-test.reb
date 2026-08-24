REBOL []
do %../logger.reb
do %../loader/api.reb

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

; ---- mount v1, reload to v2 ----
root: make-context
v1: do %fixtures/greeter-v1.reb
root/registry/plugin v1 none root
g: root/reflect/get 'greeter true root
assert equal? "hello v1" g/greet "v1 service live"

r: reload-plugin root "greeter" %fixtures/greeter-v2.reb
assert equal? true r "reload v2 ok"
g2: root/reflect/get 'greeter true root
assert equal? "hello v2" g2/greet "v2 service live after reload"
assert equal? 1 root/registry/size "still one runtime"

; ---- reload with broken file: old plugin kept ----
r2: reload-plugin root "greeter" %fixtures/greeter-broken.reb
assert string? r2 "broken file returns error"
assert not none? find r2 "old plugin kept" "error says kept"
g3: root/reflect/get 'greeter true root
assert equal? "hello v2" g3/greet "v2 still live after failed reload"

; ---- reload with non-plugin file: old plugin kept ----
r3: reload-plugin root "greeter" %fixtures/not-a-plugin.reb
assert string? r3 "non-plugin returns error"
g4: root/reflect/get 'greeter true root
assert equal? "hello v2" g4/greet "v2 still live after non-plugin"

; ---- reload unknown name ----
r4: reload-plugin root "nope" %fixtures/greeter-v1.reb
assert string? r4 "unknown name returns error"
assert not none? find r4 "not found" "error mentions not found"

; ---- reload missing file ----
r5: reload-plugin root "greeter" %fixtures/does-not-exist.reb
assert string? r5 "missing file returns error"
g5: root/reflect/get 'greeter true root
assert equal? "hello v2" g5/greet "v2 still live after missing file"

; ---- dependent fiber sees the swap (epoch reload chain) ----
seen: copy []
watcher: make object! [
    name: "watcher"
    inject: [greeter]
    apply: func [ctx [object!] config] [
        ctx/events/on 'internal-service 'watch-service make map! [] ctx
        none
    ]
]
watch-service: func [args [block!]] [
    if equal? args/1 'greeter [append seen "svc"]
    none
]
root/registry/plugin watcher none root
reload-plugin root "greeter" %fixtures/greeter-v1.reb
assert not empty? seen "dependent fiber notified on reload"
g6: root/reflect/get 'greeter true root
assert equal? "hello v1" g6/greet "back to v1"

print rejoin ["^/==== reload-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
