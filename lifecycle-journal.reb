REBOL []

; ============================================================
; lifecycle-journal.reb - normalized lifecycle trace recorder for M0
; ============================================================

journal-normalize: func [value /local out] [
    case [
        none? value ["none"]
        logic? value [either value ["true"]["false"]]
        word? value [to-string value]
        string? value [mold value]
        true [mold value]
    ]
]

journal-render-entry: func [entry [object!] /local line key value] [
    line: copy to-string entry/kind
    foreach [key value] entry/fields [
        append line rejoin [" | " to-string key "=" journal-normalize value]
    ]
    line
]

make-lifecycle-journal: func [root-ctx [object!] /local journal] [
    journal: make object! [
        root-ctx: root-ctx
        sn: 0
        entries: copy []

        record: func [kind [word! string!] fields [block! none!] /local entry] [
            sn: sn + 1
            entry: make object! [
                seq: 0
                kind: none
                fields: copy []
            ]
            entry/seq: sn
            entry/kind: to-string kind
            entry/fields: either fields [copy fields][copy []]
            append entries entry
            entry
        ]

        clear: func [] [
            sn: 0
            entries: copy []
            none
        ]

        trace-lines: does [
            collect [foreach entry entries [keep journal-render-entry entry]]
        ]
    ]
    journal
]
