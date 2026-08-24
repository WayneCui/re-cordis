REBOL []

do %../include/api.reb

escape-yaml-string: func [text [string!]] [
    if any [find text #" "  find text ":"  find text #"#"] [
        return rejoin [#"^"" text #"^""]
    ]
    text
]

format-entry-yaml: func [item [map!] /level n [integer!] /local pad out entry-id plugin-name cfg sub k v depth] [
    depth: any [n 0]
    pad: copy ""
    loop depth [append pad "  "]
    out: copy ""

    entry-id: entry-id-of item
    if string? entry-id [
        append out rejoin [pad "- id: " entry-id newline]
    ]

    plugin-name: entry-name-of item
    if any [string? plugin-name  word? plugin-name] [
        append out rejoin [pad "  name: " mold plugin-name newline]
    ]

    either entry-group? item [
        append out rejoin [pad "  group: true" newline]
        sub: entry-config-of item
        if block? sub [
            append out rejoin [pad "  config:" newline]
            foreach child sub [
                append out format-entry-yaml/level child depth + 2
            ]
        ]
    ][
        if entry-disabled? item [
            append out rejoin [pad "  disabled: true" newline]
        ]
        cfg: entry-config-of item
        if map? cfg [
            append out rejoin [pad "  config:" newline]
            foreach [k v] cfg [
                append out rejoin [pad "  " mold k ": " either string? v [escape-yaml-string v][mold v] newline]
            ]
        ]
    ]
    out
]
