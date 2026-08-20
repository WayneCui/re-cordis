REBOL []

; ============================================================
; runtime-scope.reb - root-scoped runtime registry for M0
;
; Purpose:
;   - remove process-global fiber notifications from the real runtime path
;   - keep a per-root list of plugin fibers and one lifecycle journal
;   - preserve a legacy fallback so old stub tests can migrate gradually
; ============================================================

do %./utils.reb
do %./lifecycle-journal.reb

; Legacy compatibility only. New contexts should attach runtime-scope-ref.
all-fibers: copy []

runtime-block-remove-same: func [b [block!] v /local i] [
    i: 1
    while [i <= length? b] [
        if same? pick b i v [
            remove at b i
            return b
        ]
        i: i + 1
    ]
    b
]

runtime-block-has-same?: func [b [block!] v /local item] [
    foreach item b [if same? item v [return true]]
    false
]

make-runtime-scope: func [root-ctx [object!] /local scope] [
    scope: make object! [
        root-ctx: root-ctx
        fibers: copy []
        journal: none
    ]
    scope/journal: make-lifecycle-journal root-ctx
    scope
]

legacy-runtime-scope: make object! [
    root-ctx: none
    fibers: all-fibers
    journal: none
]

ctx-runtime-scope: func [ctx [object! none!] /local root scope] [
    unless ctx [return legacy-runtime-scope]
    scope: select ctx 'runtime-scope-ref
    if scope [return scope]
    root: any [select ctx 'root-ref  ctx]
    scope: select root 'runtime-scope-ref
    any [scope  legacy-runtime-scope]
]

runtime-fibers-of: func [ctx [object! none!] /local scope] [
    scope: ctx-runtime-scope ctx
    copy scope/fibers
]

runtime-register-fiber: func [ctx [object!] fb [object!] /local scope] [
    scope: ctx-runtime-scope ctx
    unless runtime-block-has-same? scope/fibers fb [
        append scope/fibers fb
    ]
    fb
]

runtime-unregister-fiber: func [ctx [object!] fb [object!] /local scope] [
    scope: ctx-runtime-scope ctx
    runtime-block-remove-same scope/fibers fb
    fb
]

runtime-journal-of: func [ctx [object! none!] /local scope] [
    scope: ctx-runtime-scope ctx
    select scope 'journal
]

runtime-record: func [ctx [object! none!] kind [word! string!] fields [block! none!] /local journal] [
    journal: runtime-journal-of ctx
    if journal [journal/record kind fields]
    none
]

runtime-clear-trace: func [ctx [object! none!] /local journal] [
    journal: runtime-journal-of ctx
    if journal [journal/clear]
    none
]

runtime-trace-lines: func [ctx [object! none!] /local journal] [
    journal: runtime-journal-of ctx
    either journal [journal/trace-lines][copy []]
]
