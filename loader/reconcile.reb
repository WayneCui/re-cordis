REBOL [
    Title: "Cordis Port - Entry Reconciler (M2)"
    File: %reconcile.reb
    Note: {
        Incremental entry tree reconcile by stable id.
        Same id + equal options => keep; config-only change => fiber/update;
        identity-affecting change or parent move => dispose + remount;
        missing id => dispose; new id => mount.
        Groups have no fiber; children use the group's mount-ctx.
    }
]

do %api.reb

; Local map remove (avoid depending on fiber.reb helpers).
reconcile-map-remove: func [m [map!] key /local nm k v] [
    nm: make map! []
    foreach [k v] m [
        unless equal? k key [put nm k v]
    ]
    nm
]

; Synthetic auto-id key (string; Rebol words cannot contain $).
reconcile-id-key: "reconcile-id"

; ---------------------------------------------------------------------------
; Equality / remount decision
; ---------------------------------------------------------------------------

entry-value-equal?: func [a b] [
    case [
        same? a b [true]
        all [none? a none? b] [true]
        any [none? a none? b] [false]
        all [map? a map? b] [entry-map-equal? a b]
        all [block? a block? b] [
            if (length? a) <> (length? b) [return false]
            repeat i length? a [
                unless entry-value-equal? a/:i b/:i [return false]
            ]
            true
        ]
        true [equal? a b]
    ]
]

entry-map-equal?: func [a [map!] b [map!] /local ka kb] [
    ka: sort copy keys-of a
    kb: sort copy keys-of b
    unless equal? ka kb [return false]
    foreach k ka [
        unless entry-value-equal? select a k select b k [return false]
    ]
    true
]

; Options equal for keep / update (ignore synthetic reconcile-id).
entry-options-equal?: func [a [map!] b [map!] /local ka kb k] [
    ka: sort copy keys-of a
    kb: sort copy keys-of b
    remove-each k ka [equal? k reconcile-id-key]
    remove-each k kb [equal? k reconcile-id-key]
    unless equal? ka kb [return false]
    foreach k ka [
        unless entry-value-equal? select a k select b k [return false]
    ]
    true
]

; True when dispose+remount is required (not mere config update).
entry-needs-remount?: func [old [map!] new [map!] /local keys k] [
    keys: [name isolate intercept inject group]
    foreach k keys [
        unless entry-value-equal? select old k select new k [return true]
    ]
    false
]

; ---------------------------------------------------------------------------
; Flatten tree -> list of handles [id parent-id options]
; ---------------------------------------------------------------------------

ensure-entry-id: func [options [map!] /local id] [
    id: any [entry-id-of options select options reconcile-id-key]
    unless string? id [
        id: form random 100000000
        put options reconcile-id-key id
    ]
    id
]

flatten-entries: func [
    entries [block!]
    parent-id [string! none!]
    into [block!]
    /local item id sub handle
] [
    foreach item entries [
        unless map? item [continue]
        id: ensure-entry-id item
        handle: make object! [
            id: none
            parent-id: none
            options: none
        ]
        handle/id: id
        handle/parent-id: parent-id
        handle/options: item
        append into handle
        if entry-group? item [
            sub: entry-config-of item
            if block? sub [flatten-entries sub id into]
        ]
    ]
    into
]

new-entry-handle: func [
    id [string!]
    parent-id [string! none!]
    options [map!]
    /local h
] [
    h: make object! [
        id: none
        parent-id: none
        options: none
        fiber: none
        mount-ctx: none
        child-ids: copy []
    ]
    h/id: id
    h/parent-id: parent-id
    h/options: options
    h
]

; ---------------------------------------------------------------------------
; Reconciler — all state on the object (no outer-frame closure).
; ---------------------------------------------------------------------------

make-entry-reconciler: func [
    "Incremental entry mount/update/dispose by stable id."
    root [object!]
    plugin-map [map!]
    /local rec
] [
    rec: make object! [
        root: none
        plugins: none
        store: none

        get: func [id [string!]] [select self/store id]

        size: does [length? keys-of self/store]

        set-handle: func [id [string!] h [object!]] [
            put self/store id h
            h
        ]

        drop-handle: func [id [string!]] [
            self/store: reconcile-map-remove self/store id
        ]

        link-child: func [parent-id [string! none!] id [string!] /local parent] [
            unless string? parent-id [exit]
            parent: self/get parent-id
            if object? parent [
                unless find parent/child-ids id [
                    append parent/child-ids id
                ]
            ]
        ]

        resolve-parent-ctx: func [parent-id [string! none!] /local h] [
            if none? parent-id [return self/root]
            h: self/get parent-id
            unless object? h [return self/root]
            either object? h/mount-ctx [h/mount-ctx] [self/root]
        ]

        dispose-subtree: func [id [string!] /local h kid kids] [
            h: self/get id
            unless object? h [exit]
            kids: copy h/child-ids
            foreach kid kids [self/dispose-subtree kid]
            if object? h/fiber [
                try [h/fiber/dispose/dispose]
            ]
            if string? h/parent-id [
                if object? self/get h/parent-id [
                    remove find (self/get h/parent-id)/child-ids id
                ]
            ]
            self/drop-handle id
        ]

        remount-subtree: func [id [string!] /local h kids kid] [
            h: self/get id
            unless object? h [exit]
            kids: copy h/child-ids
            foreach kid kids [self/dispose-subtree kid]
            clear h/child-ids
            if object? h/fiber [
                try [h/fiber/dispose/dispose]
                h/fiber: none
            ]
            h/mount-ctx: none
        ]

        mount-leaf: func [
            id [string!]
            options [map!]
            parent-id [string! none!]
            /local ctx name plugin cfg fiber h
        ] [
            if entry-disabled? options [exit]
            ctx: self/resolve-parent-ctx parent-id
            ctx: entry-mount-ctx ctx options
            name: entry-plugin-name options
            unless word? name [exit]
            plugin: select self/plugins name
            unless object? plugin [
                cause-error 'user 'message rejoin ["unknown plugin: " mold name]
            ]
            cfg: entry-config-of options
            fiber: ctx/registry/plugin plugin any [cfg none] ctx
            h: new-entry-handle id parent-id options
            h/fiber: fiber
            h/mount-ctx: ctx
            self/set-handle id h
            self/link-child parent-id id
            fiber
        ]

        mount-group: func [
            id [string!]
            options [map!]
            parent-id [string! none!]
            /local ctx h
        ] [
            if entry-disabled? options [exit]
            ctx: self/resolve-parent-ctx parent-id
            ctx: entry-mount-ctx ctx options
            h: new-entry-handle id parent-id options
            h/fiber: none
            h/mount-ctx: ctx
            self/set-handle id h
            self/link-child parent-id id
            h
        ]

        apply-desired: func [
            desired [block!]
            /local item id parent-id options old cfg
        ] [
            foreach item desired [
                id: item/id
                parent-id: item/parent-id
                options: item/options
                old: self/get id

                if entry-disabled? options [
                    if object? old [self/dispose-subtree id]
                    continue
                ]

                unless object? old [
                    either entry-group? options [
                        self/mount-group id options parent-id
                    ] [
                        self/mount-leaf id options parent-id
                    ]
                    continue
                ]

                unless equal? old/parent-id parent-id [
                    self/remount-subtree id
                    self/drop-handle id
                    either entry-group? options [
                        self/mount-group id options parent-id
                    ] [
                        self/mount-leaf id options parent-id
                    ]
                    continue
                ]

                if entry-options-equal? old/options options [continue]

                if entry-needs-remount? old/options options [
                    self/remount-subtree id
                    self/drop-handle id
                    either entry-group? options [
                        self/mount-group id options parent-id
                    ] [
                        self/mount-leaf id options parent-id
                    ]
                    continue
                ]

                old/options: options
                if all [not entry-group? options object? old/fiber] [
                    cfg: entry-config-of options
                    old/fiber/update any [cfg none] false
                ]
            ]
        ]

        reconcile: func [
            "Apply desired entry tree; returns self."
            entries [block!]
            /local desired ids id
        ] [
            desired: flatten-entries entries none copy []
            ids: collect [
                foreach item desired [keep item/id]
            ]
            foreach id reverse copy keys-of self/store [
                unless find ids id [
                    if object? self/get id [self/dispose-subtree id]
                ]
            ]
            self/apply-desired desired
            self
        ]

        stop: does [
            foreach id reverse copy keys-of self/store [
                if object? self/get id [self/dispose-subtree id]
            ]
            self
        ]
    ]
    rec/root: root
    rec/plugins: plugin-map
    rec/store: make map! []
    rec
]
