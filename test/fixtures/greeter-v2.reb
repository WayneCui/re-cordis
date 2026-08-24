REBOL []
; greeter v2 — same plugin name, new behavior
make object! [
    name: "greeter"
    inject: []
    apply: func [ctx [object!] config] [
        ctx/reflect/provide 'greeter make object! [
            greet: does ["hello v2"]
        ] none ctx
        none
    ]
]
