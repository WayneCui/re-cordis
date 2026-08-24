REBOL []

; ============================================================
; loader/api.reb — mount entry lists onto cordis registry (no HMR).
; ============================================================

do %../include/api.reb
do %format.reb

loader-error: func [msg [string!]] [
    cause-error 'user 'message msg
]

entry-plugin-name: func [entry [map!]] [
    plugin-name: entry-name-of entry
    unless any [string? plugin-name  word? plugin-name] [
        loader-error "entry missing name"
    ]
    either string? plugin-name [to-word plugin-name][plugin-name]
]

mount-entry-list: func [
    ctx [object!]
    entries [block!]
    plugin-map [map!]
    /local item plugin plugin-name cfg sub
] [
    foreach item entries [
        if entry-disabled? item [continue]
        if entry-group? item [
            sub: entry-config-of item
            if block? sub [mount-entry-list ctx sub plugin-map]
            continue
        ]
        plugin-name: entry-plugin-name item
        plugin: select plugin-map plugin-name
        unless object? plugin [
            loader-error rejoin ["unknown plugin: " mold plugin-name]
        ]
        cfg: entry-config-of item
        ctx/registry/plugin plugin any [cfg none] ctx
    ]
    none
]

dump-entry-block: func [entries [block!] /local out item] [
    out: copy ""
    foreach item entries [
        append out format-entry-yaml item
    ]
    trim out
]
