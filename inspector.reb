REBOL []

; ============================================================
; inspector.reb - Effect Tree Inspector for Cordis Fibers
; ============================================================

do %./logger.reb

build-fiber-node: func [fb [object!] /local r] [
    r: collect-fiber-effects fb
    make object! [
        type: 'fiber
        tag: fiber-tag fb
        state: fiber-state-name fb/state
        children: r
    ]
]

collect-fiber-effects: func [fb [object!] /local results wrapper] [
    results: copy []
    foreach wrapper fb/disposables/values [
        if select wrapper 'meta [
            append results build-effect-node wrapper
        ]
    ]
    results
]

build-effect-node: func [wrapper [object!] /local node item ch] [
    ch: copy []
    foreach item wrapper/items [
        either select item 'meta [
            append ch build-effect-node item
        ][
            if in item 'target-fb [
                append ch build-fiber-node item/target-fb
            ]
        ]
    ]
    make object! [
        type: 'effect
        label: wrapper/meta/label
        disposed: wrapper/meta/disposed
        children: ch
    ]
]

format-tree: func [node [object!] prefix [string!] is-last [logic!] /local out child-prefix i child] [
    out: copy ""
    either equal? node/type 'fiber [
        append out rejoin [prefix  either is-last ["└── "]["├── "]  node/tag " (" node/state ")" "^/"]
    ][
        append out rejoin [prefix  either is-last ["└── "]["├── "]  "[Effect] " node/label  either node/disposed [" (DISPOSED)"][""] "^/"]
    ]
    child-prefix: rejoin [prefix  either is-last ["    "]["│   "]]
    i: 1
    while [i <= length? node/children] [
        child: pick node/children i
        append out format-tree child child-prefix (i = length? node/children)
        i: i + 1
    ]
    out
]

dump-effect-tree: func [ctx [object!] /local root-node out i child] [
    root-node: build-fiber-node ctx/fiber
    out: copy ""
    append out rejoin [root-node/tag " (" root-node/state ")" "^/"]
    i: 1
    while [i <= length? root-node/children] [
        child: pick root-node/children i
        append out format-tree child "" (i = length? root-node/children)
        i: i + 1
    ]
    out
]
