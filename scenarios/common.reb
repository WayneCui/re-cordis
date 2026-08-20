REBOL []

do %../logger.reb

print-trace: func [ctx [object!]] [
    foreach line runtime-trace-lines ctx [print line]
]

print-trace-section: func [title [string!] ctx [object!]] [
    print rejoin ["# " title]
    print-trace ctx
]
