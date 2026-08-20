REBOL []
; Day 3 lab: print fiber epoch after inject refresh (ch03 experiment 2/3)
; Run: bash how-cordis-port-works/ch03-fiber-epochs/code/probe-epoch.sh

change-dir %../../../
do %context.reb
do %logger.reb

order: copy []
probe-plugin: make object! [
    name: "probe"
    inject: ['foo]
    apply: func [ctx [object!] config] [
        append order 'start
        print ["  apply epoch=" ctx/fiber/epoch " state=" ctx/fiber/state]
        make object! [dispose: func [] [append order 'stop  print "  dispose"]]
    ]
]

root: make-context
fb: root/registry/plugin probe-plugin make map! [] root
print ["after register:" "epoch=" fb/epoch "state=" fb/state "order=" mold order]

d: root/reflect/provide 'foo "v1" none root
print ["after provide:" "epoch=" fb/epoch "state=" fb/state "order=" mold order]

d/dispose
print ["after unprovide:" "epoch=" fb/epoch "state=" fb/state "order=" mold order]

root/reflect/provide 'foo "v2" none root
print ["after re-provide:" "epoch=" fb/epoch "state=" fb/state "order=" mold order]
