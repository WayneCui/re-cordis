REBOL []

do %./common.reb

hits: 0

plugin: make object! [
    name: "async-failing"
    inject: []
    apply: func [ctx [object!] config /local listener fail? raw-fail] [
        listener: make object! [
            call: func [args [block!] this-arg [object! none!]] [hits: hits + 1]
        ]
        ctx/events/on 'ping listener make map! [] ctx
        raw-fail: select config 'fail
        fail?: either word? :raw-fail [get raw-fail][false]
        either fail? [
            make object! [
                task-kind: 'scheduled
                delay: 1000
                run: func [] [print undefined-async-fail]
            ]
        ][
            make-scheduled-value 1000 1
        ]
    ]
]

root: make-context
runtime-use-scheduler root make-deterministic-scheduler
runtime-clear-trace root
fb: root/registry/plugin plugin make map! [fail: true] root

print "# snapshots"
print rejoin ["t0=" fiber-state-name fb/state]
runtime-step root 1000
print rejoin ["t1000=" fiber-state-name fb/state]
root/events/emit 'ping [] none
print rejoin ["hits-after-fail=" hits]
fb/update make map! [fail: false] false
print rejoin ["after-update=" fiber-state-name fb/state]
runtime-step root 1000
print rejoin ["t2000=" fiber-state-name fb/state]
root/events/emit 'ping [] none
print rejoin ["hits-after-recovery=" hits]
print ""
print-trace-section "trace" root
