REBOL []

do %./common.reb

applied: copy []

make-async-provider: func [delay [integer!]] [
    make object! [
        name: "async-provider"
        inject: []
        load-delay: delay
        apply: func [ctx [object!] config /local task] [
            task: make object! [
                task-kind: 'scheduled
                delay: 0
                ctx-ref: none
                value-ref: none
                run: func [] [ctx-ref/reflect/provide 'provider value-ref none ctx-ref]
            ]
            task/delay: load-delay
            task/ctx-ref: ctx
            task/value-ref: select config 'value
            task
        ]
    ]
]

consumer-plugin: make object! [
    name: "consumer"
    inject: ['provider]
    apply: func [ctx [object!] config /local value mode] [
        value: ctx/reflect/get 'provider true ctx
        mode: select config 'mode
        append/only applied reduce [value mode]
        none
    ]
]

root: make-context
runtime-use-scheduler root make-deterministic-scheduler
runtime-clear-trace root

provider: root/registry/plugin (make-async-provider 1000) make map! [value: 1] root
consumer: root/registry/plugin consumer-plugin make map! [mode: "old"] root

print "# snapshots"
print rejoin [
    "t0-provider=" fiber-state-name provider/state
    " t0-consumer=" fiber-state-name consumer/state
]

runtime-step root 1000
print rejoin [
    "t1000-provider=" fiber-state-name provider/state
    " t1000-consumer=" fiber-state-name consumer/state
    " applied=" mold applied
]

provider/update make map! [value: 2] false
print rejoin [
    "after-provider-update=" fiber-state-name provider/state
    " consumer=" fiber-state-name consumer/state
]

consumer/update make map! [mode: "new"] false
print rejoin [
    "after-consumer-update=" fiber-state-name consumer/state
    " applied=" mold applied
]

runtime-step root 1000
print rejoin [
    "t2000-provider=" fiber-state-name provider/state
    " t2000-consumer=" fiber-state-name consumer/state
    " applied=" mold applied
]

print ""
print-trace-section "trace" root
