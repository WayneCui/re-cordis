REBOL []
do %../include/api.reb

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

bundle-patch: make map! []
ea: make map! []
put ea 'id "a"
put ea 'name "alpha"
eb: make map! []
put eb 'id "b"
put eb 'name "beta"
put bundle-patch 'insert reduce [ea eb]
bundle: reduce [bundle-patch]
profile: copy []
pb: make map! []
put pb 'id "b"
pc: make map! []
put pc 'watch true
put pb 'config pc
append profile pb
home: reduce [
    make map! [id "a" disabled true]
]
composed: compose-entry-layers reduce [bundle profile home]
assert equal? 2 length? composed "two rows after layers"
a: none
b: none
foreach entry composed [
    if equal? entry-id-of entry "a" [a: entry]
    if equal? entry-id-of entry "b" [b: entry]
]
assert map? a "row a present"
assert map? b "row b present"
assert equal? true entry-disabled? a "home disables a"
assert equal? true select entry-config-of b 'watch "profile patches b"

print rejoin ["^/==== layer-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
