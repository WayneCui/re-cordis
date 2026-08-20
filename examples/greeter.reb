REBOL [
    Title:   "Cordis Rebol port - Greeter example"
    Date:    18-Aug-2026
    Version: 0.1.0
    File:    %greeter.reb
    Purpose: {
        Minimal app for the sync core subset:
        provide, inject, events, fiber/update, isolate, dispose.

        Counterpart: cordis-quickstart/ch08-mini-greeter-app

        Run from repo root:
            rebol3 -s examples/greeter.reb
    }
]

do %../logger.reb

; ------------------------------------------------------------
; Plugins
; ------------------------------------------------------------

; Provides the greeter service. No inject => starts immediately.
; apply returns a disposer; fiber/update unloads then reloads.
greeter-plugin: make object! [
    name: "greeter"
    inject: []
    apply: func [ctx [object!] config /local prefix svc] [
        prefix: any [all [map? config select config 'prefix] "Hello"]
        print rejoin ["greeter-up " prefix]
        svc: make object! [
            ctx: none
            name: none
            prefix: none
            greet: func [who [string!]] [rejoin [prefix " " who]]
        ]
        svc/prefix: prefix
        make-service ctx 'greeter svc
        make object! [
            dispose: func [] [print "greeter-down"]
        ]
    ]
]

; Injects greeter and listens to guest-arrived.
; Listener and desk effect are bound to the current Fiber.
receptionist: make object! [
    name: "receptionist"
    inject: ['greeter]
    apply: func [ctx [object!] config /local listener ex] [
        listener: make object! [
            app-ctx: none
            served: 0
            call: func [args [block!] this-arg [object! none!] /local g] [
                served: served + 1
                g: app-ctx/reflect/get 'greeter true app-ctx
                print rejoin ["served:" g/greet first args]
            ]
        ]
        listener/app-ctx: ctx
        ctx/events/on 'guest-arrived listener make map! [] ctx

        ex: func [] [
            d: make object! [
                desk: none
                dispose: func [] [
                    print rejoin ["desk-closed served=" desk/served]
                ]
            ]
            d/desk: listener
            d
        ]
        ctx/fiber/effect :ex "desk"
        print "app-ready"
        none
    ]
]

; Isolate scene: same greeter name, separate rooms.
iso-guest: make object! [
    name: "iso-guest"
    inject: ['greeter]
    apply: func [ctx [object!] config /local d] [
        print rejoin ["iso-start " any [all [map? config select config 'room] "root"]]
        d: make object! [
            room: none
            dispose: func [] [print rejoin ["iso-stop " room]]
        ]
        d/room: any [all [map? config select config 'room] "root"]
        d
    ]
]

; ------------------------------------------------------------
; Scene 1: provide -> inject -> event -> update -> dispose is quiet
; ------------------------------------------------------------

print "=== scene 1: greeter + receptionist ==="
root: make-context

desk-fb: root/registry/plugin receptionist make map! [] root
greeter-fb: root/registry/plugin greeter-plugin make map! [prefix: "Hello"] root

root/events/emit 'guest-arrived ["Ada"] none

print "--- update prefix Hello -> Hi ---"
; greeter unload unprovides; receptionist goes pending, then restarts.
greeter-fb/update make map! [prefix: "Hi"] false
print "updated"
root/events/emit 'guest-arrived ["Ada"] none

print "--- dispose plugins ---"
desk-fb/dispose/dispose
greeter-fb/dispose/dispose
print "app-disposed"
root/events/emit 'guest-arrived ["Ada"] none
print "(no served: after dispose -- listeners are gone)"

; ------------------------------------------------------------
; Scene 2: isolate -- three rooms, each provide is private
; ------------------------------------------------------------

print "^/=== scene 2: isolate rooms ==="
root2: make-context
root2/registry/plugin iso-guest make map! [room: "root"] root2
ctx-a: root2/isolate 'greeter none
ctx-a/registry/plugin iso-guest make map! [room: "A"] ctx-a
ctx-b: root2/isolate 'greeter none
ctx-b/registry/plugin iso-guest make map! [room: "B"] ctx-b
print "all pending (no greeter yet)"

root2/reflect/provide 'greeter "g-root" none root2
print "(only root started)"
ctx-a/reflect/provide 'greeter "g-A" none ctx-a
print "(only A started)"
ctx-b/reflect/provide 'greeter "g-B" none ctx-b
print "(only B started)"
print "done"
