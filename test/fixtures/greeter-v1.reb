REBOL []
; greeter v1 — provides 'greeter service with greet -> "hello v1"
make object! [
    name: "greeter"
    inject: []
    apply: func [ctx [object!] config] [
        ctx/reflect/provide 'greeter make object! [
            greet: does ["hello v1"]
        ] none ctx
        none
    ]
]
