REBOL []

do %./common.reb

greeter-plugin: make object! [
    name: "greeter"
    inject: []
    apply: func [ctx [object!] config /local svc prefix] [
        prefix: any [all [map? config  select config 'prefix]  "Hello"]
        svc: make object! [
            ctx: none
            name: none
            prefix: none
            greet: func [who [string!]] [rejoin [prefix " " who]]
        ]
        svc/prefix: prefix
        make-service ctx 'greeter svc
        make object! [dispose: func [] [none]]
    ]
]

receptionist: make object! [
    name: "receptionist"
    inject: ['greeter]
    apply: func [ctx [object!] config /local listener ex] [
        listener: make object! [
            app-ctx: ctx
            call: func [args [block!] this-arg [object! none!] /local g] [
                g: app-ctx/reflect/get 'greeter true app-ctx
                either g [g/greet first args][none]
            ]
        ]
        ctx/events/on 'guest-arrived listener make map! [] ctx
        ex: func [] [make object! [dispose: func [] [none]]]
        ctx/fiber/effect :ex "desk"
        none
    ]
]

root: make-context
runtime-clear-trace root

desk-fb: root/registry/plugin receptionist make map! [] root
greeter-fb: root/registry/plugin greeter-plugin make map! [prefix: "Hello"] root
root/events/emit 'guest-arrived ["Ada"] none
greeter-fb/update make map! [prefix: "Hi"] false
desk-fb/dispose/dispose
greeter-fb/dispose/dispose

print-trace root
