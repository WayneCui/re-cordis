REBOL []

do %./common.reb

iso-guest: make object! [
    name: "iso-guest"
    inject: ['greeter]
    apply: func [ctx [object!] config] [none]
]

root: make-context
runtime-clear-trace root

root/registry/plugin iso-guest make map! [room: "root"] root
ctx-a: root/isolate 'greeter 'room-a
ctx-a/registry/plugin iso-guest make map! [room: "A"] ctx-a
ctx-b: root/isolate 'greeter 'room-b
ctx-b/registry/plugin iso-guest make map! [room: "B"] ctx-b

root/reflect/provide 'greeter "g-root" none root
ctx-a/reflect/provide 'greeter "g-a" none ctx-a
ctx-b/reflect/provide 'greeter "g-b" none ctx-b

print-trace root
