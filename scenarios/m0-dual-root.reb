REBOL []

do %./common.reb

consumer: make object! [
    name: "consumer"
    inject: ['foo]
    apply: func [ctx [object!] config] [none]
]

root-a: make-context
root-b: make-context
runtime-clear-trace root-a
runtime-clear-trace root-b

fb-a: root-a/registry/plugin consumer make map! [] root-a
fb-b: root-b/registry/plugin consumer make map! [] root-b

root-a/reflect/provide 'foo "a" none root-a

print-trace-section "root-a" root-a
print ""
print-trace-section "root-b" root-b
