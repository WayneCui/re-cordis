REBOL []

; ============================================================
; include/api.reb — entry helpers, patch merge, YAML compose.
; ============================================================

do %yaml.reb

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

entry-disabled?: func [entry [map!]] [
    val: any [select entry 'disabled select entry "disabled"]
    either none? val [false][true? val]
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

normalize-patch-block: func [items [block!]] [
    if empty? items [return items]
    either map? first items [items][reduce items]
]

normalize-patches: func [patches [block! none!]] [
    unless block? patches [return copy []]
    if empty? patches [return patches]
    normalize-patch-block patches
]

load-reb-patches: func [path [file!]] [
    unless exists? path [
        cause-error 'user 'message rejoin ["patch file not found: " mold path]
    ]
    patches: do path
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
                append sub normalize-patch-block patch-insert
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
