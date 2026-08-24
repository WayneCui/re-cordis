REBOL []
; broken — syntax error at load time
make object! [
    name: "greeter"
    inject: []
    apply: func [ctx [object!] config] [
        this is not valid rebol $$$
    ]
