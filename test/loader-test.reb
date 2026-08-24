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

mount-count: 0
make-mock-plugin: func [label [word!]] [
    make object! [
        name: to-string label
        inject: []
        apply: func [ctx [object!] config] [
            mount-count: mount-count + 1
            none
        ]
    ]
]

plugin-map: make map! []
put plugin-map 'alpha make-mock-plugin 'alpha
put plugin-map 'beta make-mock-plugin 'beta

child: make map! [id "c" name "alpha"]
group: make map! [id "g" group true]
put group 'config reduce [child]
entries: reduce [
    make map! [id "a" name "alpha"]
    make map! [id "b" name "beta" disabled true]
    group
]

root: make-context
mount-count: 0
mount-entry-list root entries plugin-map
assert equal? 2 mount-count "enabled leaf entries mounted"

dump: dump-entry-block entries
assert not none? find dump "- id: a" "dump contains entry id"
assert not none? find dump "name:" "dump contains plugin name"

print rejoin ["^/==== loader-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
