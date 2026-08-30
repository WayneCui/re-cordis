REBOL []
; test/reconcile-test.reb — M2 Entry Reconciler
do %../logger.reb
do %../loader/reconcile.reb

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

make-counting-plugin: func [label [word!] /local counter plugin] [
    counter: make object! [n: 0]
    plugin: make object! [
        name: none
        inject: []
        counter: none
        count: does [counter/n]
        apply: func [ctx [object!] config] [
            counter/n: counter/n + 1
            none
        ]
    ]
    plugin/name: to-string label
    plugin/counter: counter
    plugin
]

pa: make-counting-plugin 'alpha
pb: make-counting-plugin 'beta
pc: make-counting-plugin 'gamma
plugin-map: make map! []
put plugin-map 'alpha pa
put plugin-map 'beta pb
put plugin-map 'gamma pc

; --- 1. [A,B] -> [A,C]: A kept, B disposed, C mounted ---
root: make-context
r: make-entry-reconciler root plugin-map
r/reconcile reduce [
    make map! [id "a" name "alpha"]
    make map! [id "b" name "beta"]
]
assert equal? 1 pa/count "AB: A mounted once"
assert equal? 1 pb/count "AB: B mounted once"
assert equal? 2 r/size "AB: store size 2"

r/reconcile reduce [
    make map! [id "a" name "alpha"]
    make map! [id "c" name "gamma"]
]
assert equal? 1 pa/count "AC: A not remounted"
assert equal? 1 pb/count "AC: B apply count unchanged after dispose"
assert equal? 1 pc/count "AC: C mounted"
assert none? r/get "b" "AC: B handle gone"
assert not none? r/get "c" "AC: C handle present"
assert equal? 2 r/size "AC: store size 2"

; --- 2. identical tree: no remount ---
before: pa/count
r/reconcile reduce [
    make map! [id "a" name "alpha"]
    make map! [id "c" name "gamma"]
]
assert equal? before pa/count "same tree: A untouched"
assert equal? 1 pc/count "same tree: C untouched"

; --- 3. config-only -> fiber/update (apply again), identity kept ---
cfg1: make map! [x: 1]
cfg2: make map! [x: 2]
entry-a: make map! [id "a" name "alpha"]
put entry-a 'config cfg1
root2: make-context
r2: make-entry-reconciler root2 plugin-map
pa2: make-counting-plugin 'alpha
pm2: make map! []
put pm2 'alpha pa2
r2: make-entry-reconciler root2 pm2
r2/reconcile reduce [entry-a]
assert equal? 1 pa2/count "config: initial mount"
fiber-a: select r2/get "a" 'fiber
entry-a2: make map! [id "a" name "alpha"]
put entry-a2 'config cfg2
r2/reconcile reduce [entry-a2]
assert equal? 2 pa2/count "config: update re-applies"
fiber-a2: select r2/get "a" 'fiber
assert same? fiber-a fiber-a2 "config: fiber identity kept"

; --- 4. disabled => dispose ---
root3: make-context
pa3: make-counting-plugin 'alpha
pm3: make map! []
put pm3 'alpha pa3
r3: make-entry-reconciler root3 pm3
r3/reconcile reduce [make map! [id "a" name "alpha"]]
assert equal? 1 r3/size "disable: mounted"
r3/reconcile reduce [make map! [id "a" name "alpha" disabled true]]
assert equal? 0 r3/size "disable: disposed"
assert equal? 1 pa3/count "disable: no remount apply"

; --- 5. remove group => dispose descendants ---
root4: make-context
pa4: make-counting-plugin 'alpha
pm4: make map! []
put pm4 'alpha pa4
r4: make-entry-reconciler root4 pm4
child: make map! [id "c" name "alpha"]
group: make map! [id "g" group true]
put group 'config reduce [child]
r4/reconcile reduce [group]
assert equal? 2 r4/size "group: group+child"
assert not none? r4/get "c" "group: child present"
r4/reconcile reduce []
assert equal? 0 r4/size "group removed: empty store"
assert none? r4/get "c" "group removed: child gone"
assert none? r4/get "g" "group removed: group gone"

; --- 6. parent move => remount under new parent ---
root5: make-context
pa5: make-counting-plugin 'alpha
pm5: make map! []
put pm5 'alpha pa5
r5: make-entry-reconciler root5 pm5
g1: make map! [id "g1" group true]
g2: make map! [id "g2" group true]
ch: make map! [id "leaf" name "alpha"]
put g1 'config reduce [ch]
r5/reconcile reduce [g1 g2]
assert equal? 1 pa5/count "move: initial mount"
assert equal? "g1" select r5/get "leaf" 'parent-id "move: parent g1"
; move leaf under g2
ch2: make map! [id "leaf" name "alpha"]
put g2 'config reduce [ch2]
g1b: make map! [id "g1" group true]
put g1b 'config copy []
r5/reconcile reduce [g1b g2]
assert equal? 2 pa5/count "move: remounted once"
assert equal? "g2" select r5/get "leaf" 'parent-id "move: parent g2"

r5/stop
assert equal? 0 r5/size "stop: cleared"

print rejoin ["^/==== reconcile-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
