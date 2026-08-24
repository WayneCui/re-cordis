REBOL []

; ============================================================
; include/api.reb — entry helpers, patch merge, YAML compose.
; ============================================================

do %yaml.reb
do %layer.reb

include-warn: func [msg [string!]] [
    print rejoin ["[include warn] " msg]
]

include-warn-msg: func [text [string!]] [
    include-warn text
]

entry-id-of: func [entry [map!]] [
    any [select entry 'id select entry "id"]
]

entry-name-of: func [entry [map!]] [
    any [select entry 'name select entry "name"]
]

entry-config-of: func [entry [map!]] [
    any [select entry 'config select entry "config"]
]

entry-group?: func [entry [map!]] [
    true? any [select entry 'group select entry "group"]
]

; Entry mount target resolution: YAML `isolate` / `intercept` fields.
; isolate: map! [service label ...] -> ctx/isolate for each pair
; intercept: map! [service config-map ...] -> prepend-intercept (in-place, no new logger).
;   Applied on the (possibly isolated) mount ctx so descendants that copy intercept-chain
;   see it — e.g. agent-loop created later from root.
entry-mount-ctx: func [ctx [object!] entry [map!] /local isolate-map intercept-map k v target name cfg] [
    target: ctx
    isolate-map: any [select entry 'isolate select entry "isolate"]
    if map? isolate-map [
        foreach [k v] isolate-map [
            target: target/isolate k either none? v [none][to-word v]
        ]
    ]
    intercept-map: any [select entry 'intercept select entry "intercept"]
    if map? intercept-map [
        foreach [k v] intercept-map [
            name: either word? k [k][to-word form k]
            cfg: v
            if not map? cfg [
                ; scalar `logger: debug` -> logger name overlay
                either equal? name 'logger [
                    cfg: make map! []
                    put cfg 'name either word? v [v][to-word form v]
                ][
                    include-warn-msg rejoin ["entry " any [select entry 'id ""] ": intercept " form name " skipped (need a map)"]
                    cfg: none
                ]
            ]
            if map? cfg [
                target: target/prepend-intercept name cfg
            ]
        ]
    ]
    target
]

entry-disabled?: func [entry [map!]] [
    val: any [select entry 'disabled select entry "disabled"]
    either none? val [false][
        either word? val [
            equal? val 'true
        ][
            true? val
        ]
    ]
]

build-entry-index: func [entries [block!] /local map entry id sub child] [
    map: make map! []
    foreach entry entries [
        unless map? entry [continue]
        id: entry-id-of entry
        if string? id [put map id entry]
        if entry-group? entry [
            sub: entry-config-of entry
            if block? sub [
                foreach child sub [
                    unless map? child [continue]
                    id: entry-id-of child
                    if string? id [put map id child]
                ]
            ]
        ]
    ]
    map
]

read-entry-yaml: func [path [file!]] [
    yaml-parse-entry-yaml to-string read path
]

; Evaluate loaded patch rows: bare maps, or unevaluated make map! / compose from load/all.
run-make-expr: func [expr [block!] /local third] [
    unless all [
        block? expr
        greater? length? expr 2
        equal? pick expr 1 'make
        equal? pick expr 2 'map!
    ] [return none]
    third: pick expr 3
    either equal? third 'compose [
        unless greater? length? expr 3 [return none]
        make map! compose pick expr 4
    ][
        either block? third [
            make map! third
        ][
            none
        ]
    ]
]

eval-insert-expr: func [expr [block!] /local val] [
    if map? expr [return expr]
    val: try [run-make-expr expr]
    if error? val [return none]
    val
]

normalize-insert-block: func [items [block!] /local result i n expr val item] [
    if empty? items [return items]
    result: copy []
    i: 1
    n: length? items
    while [i <= n] [
        item: pick items i
        either map? item [
            append result item
            i: i + 1
        ][
            either equal? item 'make [
                expr: copy []
                while [i <= n] [
                    item: pick items i
                    if all [
                        greater? length? expr 0
                        equal? item 'make
                    ] [break]
                    append/only expr item
                    i: i + 1
                ]
                val: eval-insert-expr expr
                if map? val [append result val]
            ][
                val: try [do item]
                if map? val [append result val]
                i: i + 1
            ]
        ]
    ]
    result
]

normalize-patch-block: func [items [block!] /local patches ins key] [
    if empty? items [return items]
    patches: normalize-insert-block items
    foreach patch patches [
        ins: any [select patch 'insert select patch "insert"]
        if paren? ins [ins: do ins]
        if map? ins [ins: copy [ins]]
        if block? ins [
            ins: normalize-insert-block ins
            key: either find patch 'insert ['insert]["insert"]
            put patch key ins
        ]
    ]
    patches
]

normalize-patches: func [patches [block! none!]] [
    unless block? patches [return copy []]
    if empty? patches [return patches]
    normalize-patch-block patches
]

load-reb-patches: func [path [file!] /local patches parsed] [
    unless exists? path [
        cause-error 'user 'message rejoin ["patch file not found: " mold path]
    ]
    parsed: try [load/all to-string read path]
    if error? parsed [
        cause-error 'user 'message rejoin ["patch file unreadable: " mold path]
    ]
    if all [block? parsed  not empty? parsed] [
        patches: either block? first parsed [first parsed][parsed]
    ][
        patches: copy []
    ]
    unless block? patches [
        cause-error 'user 'message rejoin ["patch file must return block: " mold path]
    ]
    normalize-patches patches
]

patch-skip-key?: func [k] [
    any [k = 'id  k = "id"  k = 'insert  k = "insert"  k = 'name  k = "name"]
]

patch-put-value: func [target [map!] k v] [
    key: to-word either string? k [k][form k]
    if any [key = 'config  key = "config"] [
        cfg: entry-config-of target
        unless map? cfg [
            cfg: make map! []
            yaml-put-key target 'config cfg
        ]
        either map? v [
            foreach [ck cv] v [
                put cfg to-word either string? ck [ck][form ck] cv
            ]
        ][
            put target key v
        ]
        return none
    ]
    put target key v
    none
]

apply-entry-patches: func [
    entries [block!]
    patches [block! none!]
    /local data index patch patch-id patch-insert patch-name target sub tname k v
] [
    data: copy entries
    unless block? patches [return data]
    patches: normalize-patches patches
    index: build-entry-index data

    foreach patch patches [
        unless map? patch [continue]
        patch-id: any [select patch 'id select patch "id"]
        patch-insert: select patch 'insert
        if none? patch-insert [patch-insert: select patch "insert"]
        if paren? patch-insert [patch-insert: reduce patch-insert]
        patch-name: any [select patch 'name select patch "name"]

        if block? patch-insert [
            either string? patch-id [
                target: select index patch-id
                unless map? target [
                    include-warn-msg form reduce ["patch insert: entry " patch-id " not found"]
                    continue
                ]
                unless entry-group? target [
                    include-warn-msg form reduce ["patch insert: entry " patch-id " is not a group"]
                    continue
                ]
                sub: entry-config-of target
                unless block? sub [
                    sub: copy []
                    yaml-put-key target 'config sub
                ]
                append sub normalize-insert-block patch-insert
                foreach [k v] build-entry-index patch-insert [put index k v]
            ][
                append data patch-insert
                foreach [k v] build-entry-index patch-insert [put index k v]
            ]
            continue
        ]

        unless string? patch-id [
            include-warn-msg "patch: id is required for non-insert patches"
            continue
        ]

        target: select index patch-id
        unless map? target [
            include-warn-msg form reduce ["patch: entry " patch-id " not found"]
            continue
        ]

        if string? patch-name [
            tname: entry-name-of target
            unless equal? patch-name tname [
                include-warn-msg form reduce ["patch: name mismatch for " patch-id]
                continue
            ]
        ]

        foreach [k v] patch [
            unless patch-skip-key? k [patch-put-value target k v]
        ]
    ]
    data
]

compose-entry-config: func [
    config-file [file!]
    /patches patch-files [block! none!]
    /local base patch-list file
] [
    base: read-entry-yaml config-file
    patch-list: copy []
    if block? patch-files [
        foreach file patch-files [
            append patch-list load-reb-patches file
        ]
    ]
    apply-entry-patches base patch-list
]
