REBOL []

; ============================================================
; include/yaml.reb � minimal entry-list YAML (no !!js, no anchors).
; ============================================================

yaml-trim-indent: func [line [string!] /local n] [
    n: 0
    while [all [n < length? line  line/(n + 1) = #" "]] [n: n + 1]
    copy/part line n
]

yaml-parse-scalar: func [text /local low] [
    unless string? text [return text]
    low: lowercase copy text
    if any [equal? low "true"  equal? low "yes"] [return true]
    if any [equal? low "false"  equal? low "no"] [return false]
    if find text #"'" [return to-string text]
    if find text #"." [
        unless find text " " [try [return to-decimal text]]
    ]
    try [return to-integer text]
    to-string text
]

yaml-put-key: func [target [map!] key val] [
    put target to-word either string? key [key][form key] val
    none
]

yaml-split-key-val: func [text [string!] /local at-colon key val pair] [
    at-colon: find text ":"
    unless at-colon [return none]
    key: trim copy/part text at-colon
    val: trim copy skip at-colon 1
    pair: copy []
    append/only pair key
    append/only pair val
    pair
]

yaml-make-frame: func [lvl [integer!] kind [word!] data parent] [
    frame: make map! []
    put frame 'depth lvl
    put frame 'kind kind
    put frame 'data data
    put frame 'parent parent
    frame
]

yaml-active-map: func [stack [block!]] [
    cursor: last stack
    while [any [map? cursor  object? cursor]] [
        kind: select cursor 'kind
        either kind = 'entry [
            return select cursor 'data
        ][
            if kind = 'map [
                return select cursor 'data
            ]
        ]
        cursor: select cursor 'parent
        unless any [map? cursor  object? cursor] [break]
    ]
    none
]

yaml-parse-entry-yaml: func [text [string!] /local lines stack line indent content top rest kv key val entry nested parent kind current config-target nested-key nested-target] [
    entries: copy []
    current: none
    config-target: none
    nested-key: none
    nested-target: none

    foreach line split text newline [
        trimmed: trim copy line
        if empty? trimmed [continue]
        if trimmed/1 = #"#" [continue]

        indent: length? yaml-trim-indent line
        content: trim either indent > 0 [copy skip line indent][line]

        either content/1 = #"-" [
            current: make map! []
            config-target: none
            nested-key: none
            nested-target: none
            append entries current
            rest: trim copy skip content 1
            if kv: yaml-split-key-val rest [
                yaml-put-key current pick kv 1 yaml-parse-scalar pick kv 2
            ]
        ][
            kv: yaml-split-key-val content
            unless kv [continue]
            key: pick kv 1
            val: pick kv 2
            unless map? current [continue]
            either all [string? val  empty? val] [
                either equal? form key "config" [
                    nested: either entry-group? current [copy []][make map! []]
                    yaml-put-key current 'config nested
                    config-target: either block? nested [none][nested]
                    nested-key: none
                    nested-target: none
                ][
                    either any [equal? form key "isolate"  equal? form key "intercept"] [
                        nested: make map! []
                        yaml-put-key current key nested
                        nested-key: key
                        nested-target: nested
                        config-target: none
                    ][
                        nested: make map! []
                        yaml-put-key current key nested
                        nested-key: key
                        nested-target: nested
                        config-target: none
                    ]
                ]
            ][
                either all [map? nested-target  indent >= 2] [
                    yaml-put-key nested-target key yaml-parse-scalar val
                ][
                    either map? config-target [
                        yaml-put-key config-target key yaml-parse-scalar val
                    ][
                        yaml-put-key current key yaml-parse-scalar val
                    ]
                ]
            ]
        ]
    ]
    entries
]
