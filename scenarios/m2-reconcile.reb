REBOL []
; scenarios/m2-reconcile.reb — incremental Entry Reconciler demo
do %./common.reb
do %../loader/reconcile.reb

make-counting-plugin: func [label [word!] /local counter plugin] [
    counter: make object! [n: 0]
    plugin: make object! [
        name: none
        inject: []
        counter: none
        count: does [counter/n]
        apply: func [ctx [object!] config] [
            counter/n: counter/n + 1
            print rejoin ["  apply " name " config=" mold config]
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

root: make-context
r: make-entry-reconciler root plugin-map

print "# step1 mount [A, B]"
r/reconcile reduce [
    make map! [id "a" name "alpha"]
    make map! [id "b" name "beta"]
]
print rejoin ["store=" r/size " A=" pa/count " B=" pb/count]

print "# step2 reconcile [A, C]  (A keep, B dispose, C mount)"
r/reconcile reduce [
    make map! [id "a" name "alpha"]
    make map! [id "c" name "gamma"]
]
print rejoin ["store=" r/size " A=" pa/count " B=" pb/count " C=" pc/count]

print "# step3 config update on A"
ea: make map! [id "a" name "alpha"]
put ea 'config make map! [n: 2]
r/reconcile reduce [
    ea
    make map! [id "c" name "gamma"]
]
print rejoin ["A apply count after update=" pa/count]

print "# step4 remove group with child"
child: make map! [id "leaf" name "alpha"]
group: make map! [id "g" group true]
put group 'config reduce [child]
r/reconcile reduce [group]
print rejoin ["with group store=" r/size]
r/reconcile reduce []
print rejoin ["after group remove store=" r/size]

r/stop
print "done"
