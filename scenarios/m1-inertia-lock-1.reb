REBOL []

do %./common.reb

make-async-disposer: func [delay [integer!]] [
    make object! [
        delay-ref: delay
        dispose: func [] [make-scheduled-value delay-ref none]
    ]
]

make-async-consumer: func [delay-load [integer!] delay-unload [integer!]] [
    make object! [
        name: "async-consumer"
        inject: ['foo]
        load-delay: delay-load
        unload-delay: delay-unload
        apply: func [ctx [object!] config] [
            make-scheduled-value load-delay make-async-disposer unload-delay
        ]
    ]
]

root: make-context
runtime-use-scheduler root make-deterministic-scheduler
runtime-clear-trace root

d1: root/reflect/provide 'foo 1 none root
fb: root/registry/plugin (make-async-consumer 1000 1000) make map! [] root

print "# snapshots"
print rejoin ["t0=" fiber-state-name fb/state]
runtime-step root 400
print rejoin ["t400=" fiber-state-name fb/state]
d1/dispose
runtime-step root 400
print rejoin ["t800=" fiber-state-name fb/state]
runtime-step root 400
print rejoin ["t1200=" fiber-state-name fb/state]
root/reflect/provide 'foo 1 none root
runtime-step root 1000
print rejoin ["t2200=" fiber-state-name fb/state]
runtime-step root 1000
print rejoin ["t3200=" fiber-state-name fb/state]
print ""
print-trace-section "trace" root
