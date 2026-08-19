REBOL []

; ============================================================
; fiber.reb - Rebol3 port of the cordis Fiber state machine (P3)
; Upstream: ref/core/fiber.ts (486 lines)
;
; Core non-obvious mechanics (ROADMAP §4.3, must preserve):
;   1. fiber state machine: PENDING->LOADING->ACTIVE / ->UNLOADING->(reload|PENDING)
;   2. reactive epoch: inject depends on the concatenated uid string of impls; provide/dispose triggers notification
;      -> checkImpl -> refresh -> epoch changes -> reload/unload
;   3. effect() scoped cleanup: run disposers in reverse order on unload (LIFO)
;
; Synchronous simplifications (ROADMAP §7 limits):
;   - No Promise: _reload/_unload are fully synchronous, inertia is a logic! flag
;   - No generator: effect returns function/disposer objects, block-of-disposers, or none
;   - Error propagation: returns an error! object or string (no exception stack)
;   - resolveConfig: schema validation is not supported here (added later in P7 service)
;
; Key Rebol constraints:
;   - Callbacks/disposers are always wrapper objects (function! auto-evaluates in containers)
;   - Plugin callback = object + apply method (spike convention)
;   - Object methods may only reference their own fields (self-contained), no frame closures
;   - Equality checks always use equal?/same?
; ============================================================

do %./utils.reb
do %./events.reb

; ------------------------------------------------------------
; Constants
; ------------------------------------------------------------

inactive-epoch: "__INACTIVE__"

fiber-state: context [
    PENDING: 0
    LOADING: 1
    ACTIVE: 2
    FAILED: 3
    DISPOSED: 4
    UNLOADING: 5
]

; Registry of all plugin fibers (used by notify before P4 reflect is formalized)
all-fibers: copy []

; ------------------------------------------------------------
; fiber type
; ------------------------------------------------------------

fiber-type: make object! [
    uid: none
    parent: none            ; Context (parent context)
    ctx: none               ; its own context (extend or parent)
    config: none
    state: fiber-state/PENDING
    epoch: none             ; string! or inactive-epoch
    inject: make map! []    ; name(word!) → config
    runtime: none           ; [name callback fibers Config] or none (root)
    store: none             ; name -> impl snapshot (non-none when ACTIVE)
    disposables: none       ; DisposableList
    hooks: make map! []     ; _hooks: word → DisposableList (internal-update)
    error: none
    inertia: none           ; synchronous version: logic! true = loading/unloading
    dispose: none           ; unload entry point (wrapper object, root = restart)

    ; ---- Method shell (delegates to standalone functions, self-contained) ----
    ; Note: function arguments must be passed as :word (Oldes auto-calls function values in argument position)
    assert-active: func [] [fiber-assert-active self]
    effect: func [execute [function!] label [string!]] [fiber-effect self :execute label]
    restart: func [] [fiber-restart self]
    await: func [] [fiber-await self]
    update: func [config no-save [logic!]] [fiber-update self config no-save]
    name: does [fiber-name self]
    get-effects: does [fiber-get-effects self]
]

; ------------------------------------------------------------
; Helpers
; ------------------------------------------------------------

map-remove-key: func [m [map!] key /local nm k v] [
    nm: make map! []
    foreach [k v] m [
        unless equal? k key [put nm k v]
    ]
    nm
]

block-remove-same: func [b [block!] v /local i] [
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

; ------------------------------------------------------------
; resolveConfig - simplified version (schema validation is added later in P7 service)
; ------------------------------------------------------------

resolve-config: func [runtime [object! none!] config] [
    unless runtime [return config]
    unless runtime/Config [return config]
    ; Config = word! function name (validator), invoked to return validated config
    do reduce [runtime/Config config]
]

; ------------------------------------------------------------
; State query and updates
; ------------------------------------------------------------

fiber-get-state: func [fb [object!]] [
    either none? fb/uid [
        fiber-state/DISPOSED
    ][
        either fb/error [
            fiber-state/FAILED
        ][
            either not equal? fb/epoch inactive-epoch [
                fiber-state/ACTIVE
            ][
                fiber-state/PENDING
            ]
        ]
    ]
]

; ACTIVE <-> non-ACTIVE boundary changes -> notify reflect (re-evaluate impls)
; ACTIVE <-> non-ACTIVE boundary changes -> notify reflect (re-evaluate impls)
; Note: must use same? (identity comparison) - equal? recursively compares objects deeply,
; and the ctx<->fiber cyclic reference would cause infinite-recursion segfaults
fiber-notify-active: func [fb [object!] /local impl name] [
    foreach [name impl] fb/ctx/reflect/store [
        if same? impl/fiber fb [
            fb/ctx/reflect/notify reduce [impl/name] fb/ctx
        ]
    ]
]

; Update state; when it changes, emit internal-status + notify ACTIVE boundary transitions
fiber-update-state: func [fb [object!] new-state [integer! none!] /local old] [
    old: fb/state
    either new-state [fb/state: new-state][fb/state: fiber-get-state fb]
    if equal? old fb/state [exit]
    fb/ctx/events/emit 'internal-status reduce [fb old] fb
    ; Only notify ACTIVE <-> non-ACTIVE transitions
    either equal? old fiber-state/ACTIVE [
        if not equal? fb/state fiber-state/ACTIVE [fiber-notify-active fb]
    ][
        if equal? fb/state fiber-state/ACTIVE [fiber-notify-active fb]
    ]
]

; ------------------------------------------------------------
; _checkImpl / _refresh / _setEpoch
; ------------------------------------------------------------

fiber-check-impl: func [fb [object!] name [word!] /local impl r] [
    ; After unload store becomes none, rebuild it before re-evaluation
    unless fb/store [fb/store: make map! []]
    impl: fb/ctx/reflect/get-impl name true fb/ctx
    either impl [
        either impl/check [
            r: try [impl/check/call []]
            either error? r [
                fb/ctx/logger/error r
                fb/store: map-remove-key fb/store name
            ][
                either r [
                    put fb/store name impl
                ][
                    fb/store: map-remove-key fb/store name
                ]
            ]
        ][
            put fb/store name impl
        ]
    ][
        fb/store: map-remove-key fb/store name
    ]
]

fiber-refresh: func [fb [object!] /local epoch-str name impl] [
    ; After unload store becomes none; upstream checkImpl maintains a private _store,
    ; Rebol merges store/_store, so rebuild it before refresh
    unless fb/store [fb/store: make map! []]
    foreach name keys-of fb/inject [fiber-check-impl fb name]
    epoch-str: ""
    foreach name keys-of fb/inject [
        impl: select fb/store name
        either impl [
            append epoch-str rejoin [":" impl/fiber/uid]
        ][
            epoch-str: inactive-epoch
            break
        ]
    ]
    fiber-set-epoch fb epoch-str
]

; Dependency epoch changes -> reload/unload (synchronous version, inertia flag prevents re-entry)
fiber-set-epoch: func [fb [object!] epoch-str [string!] /local old] [
    old: fb/epoch
    if equal? epoch-str old [exit]
    fb/epoch: epoch-str
    if fb/inertia [exit]
    fb/inertia: true
    either equal? epoch-str inactive-epoch [
        fiber-update-state fb fiber-state/UNLOADING
        fiber-unload fb
    ][
        either equal? old inactive-epoch [
            fiber-update-state fb fiber-state/LOADING
            fiber-reload fb
        ][
            ; non->non: unload first (internal re-entry checks will continue into reload)
            fiber-update-state fb fiber-state/UNLOADING
            fiber-unload fb
        ]
    ]
    fb/inertia: none
    ; The epoch may change due to side effects during execution -> re-entry check
    unless equal? fb/epoch epoch-str [
        fiber-set-epoch fb fb/epoch
    ]
]

; ------------------------------------------------------------
; _reload / _unload
; ------------------------------------------------------------

fiber-reload: func [fb [object!] /local old-epoch result d] [
    old-epoch: fb/epoch
    ; After unload store becomes none, rebuild it before snapshotting
    either fb/store [fb/store: copy fb/store][fb/store: make map! []]
    result: try [fb/runtime/callback/apply fb/ctx fb/config]
    either error? result [
        fb/ctx/logger/error result
        fb/error: result
        fb/epoch: inactive-epoch
        fiber-update-state fb fiber-state/FAILED
        ; Match upstream: if reload fails -> unload to clean up disposables
        fiber-unload fb
    ][
        either object? result [
            fb/disposables/push result
        ][
            if block? result [
                foreach d result [fb/disposables/push d]
            ]
        ]
        either equal? fb/epoch old-epoch [
            fiber-update-state fb fiber-state/ACTIVE
        ][
            ; The epoch changed during execution -> continue unloading
            fiber-unload fb
        ]
    ]
]

fiber-unload: func [fb [object!] /local ds d r] [
    ds: fb/disposables/clear
    foreach d ds [
        ; Append none at the end so try still yields none rather than unset when dispose has no return value
        r: try [d/dispose  none]
        if error? r [fb/ctx/logger/error r]
    ]
    fb/store: none
    either none? fb/uid [
        fiber-update-state fb fiber-state/DISPOSED
    ][
        either fb/error [
            fiber-update-state fb fiber-state/FAILED
        ][
            either equal? fb/epoch inactive-epoch [
                fiber-update-state fb fiber-state/PENDING
            ][
                ; epoch is not INACTIVE -> reload
                fiber-update-state fb fiber-state/LOADING
                fiber-reload fb
            ]
        ]
    ]
]

; ------------------------------------------------------------
; effect - core of scoped cleanup
; execute: function! runs immediately and returns:
;   - disposer object (object!) -> collect one
;   - block (block of disposer objects) -> collect one by one (replacing generator)
;   - none -> nothing
; Returns a wrapper object (idempotent dispose, with meta)
; ------------------------------------------------------------

fiber-effect: func [fb [object!] execute [function!] label [string!] /local local-list children-list result d wrapper] [
    if none? fb/uid [
        return rejoin ["[CordisError:INACTIVE_EFFECT] cannot create effect on inactive context"]
    ]
    local-list: copy []
    children-list: copy []
    ; execute protocol: must return object/disposer/block/none (an explicit value).
    ; Returning unset violates the protocol -> "needs a value" error (fail loudly)
    result: try [execute]
    either error? result [
        ; Clean up already-collected items in reverse order, then propagate the error (upstream: dispose() + throw)
        foreach d reverse local-list [d/dispose]
        return result
    ][
        either object? result [
            append local-list result
            if select result 'meta [
                fb/disposables/delete result
                append children-list select result 'meta
            ]
        ][
            if block? result [
                foreach d result [
                    append local-list d
                    if select d 'meta [
                        fb/disposables/delete d
                        append children-list select d 'meta
                    ]
                ]
            ]
        ]
    ]
    wrapper: make object! [
        done: false
        items: local-list
        ; Gotcha: in make object! [label: label], the RHS is shadowed by the new field -> assign after creation
        meta: make object! [label: none  children: copy []]
        dispose: func [] [
            if done [exit]
            done: true
            foreach d reverse items [d/dispose]
            none
        ]
    ]
    wrapper/meta/label: label
    wrapper/meta/children: children-list
    fb/disposables/push wrapper
    wrapper
]

fiber-get-effects: func [fb [object!] /local result d m] [
    result: copy []
    foreach d fb/disposables/values [
        m: select d 'meta
        if m [append result m]
    ]
    result
]

; ------------------------------------------------------------
; Assertions / names
; ------------------------------------------------------------

fiber-assert-active: func [fb [object!]] [
    if none? fb/uid [
        return rejoin ["[CordisError:INACTIVE_EFFECT] cannot create effect on inactive context"]
    ]
    none
]

fiber-name: func [fb [object!] /local f] [
    f: fb
    forever [
        if f/runtime [
            if f/runtime/name [return f/runtime/name]
        ]
        f: f/parent/fiber
        if same? f f/parent/fiber [break]
    ]
    "root"
]

; ------------------------------------------------------------
; await / restart / update
; ------------------------------------------------------------

fiber-await: func [fb [object!]] [
    ; Synchronous version: no real waiting; on error return the error object (upstream throws)
    if fb/error [return fb/error]
    fb
]

fiber-restart: func [fb [object!] /local r] [
    fiber-assert-active fb
    fiber-set-epoch fb inactive-epoch
    fiber-refresh fb
    fiber-await fb
]

fiber-update: func [fb [object!] config no-save [logic!] /local final-w] [
    fiber-assert-active fb
    config: resolve-config fb/runtime config
    final-w: make object! [
        target-fb: fb
        call: func [args [block!] this-arg [object! none!]] [
            target-fb/config: args/1
            target-fb/error: none
            fiber-restart target-fb
        ]
    ]
    fb/ctx/events/waterfall 'internal-update reduce [config no-save] final-w fb
]

; ------------------------------------------------------------
; Constructors
; ------------------------------------------------------------

make-fiber-root: func [root-ctx [object!] /local fb] [
    fb: make fiber-type []
    fb/uid: 0
    fb/parent: root-ctx
    fb/ctx: root-ctx
    fb/state: fiber-state/ACTIVE
    fb/epoch: ""
    fb/runtime: none
    fb/store: make map! []
    fb/disposables: make-disposable-list
    fb/inject: make map! []
    fb/dispose: make object! [
        target-fb: fb
        dispose: func [] [fiber-restart target-fb]
    ]
    fb
]

; Construct a plugin fiber (core of registry.plugin, formalized in P5)
; runtime: [name: string! callback: object+apply fibers: DisposableList Config: none]
make-plugin-fiber: func [parent-ctx [object!] config inject-map [map!] runtime [object!] /local fb child-ctx remove-fn ex dispose-fn] [
    fb: make fiber-type []
    ; Increment counter first, then read it (upstream getter: return ++this._counter)
    parent-ctx/registry/counter: parent-ctx/registry/counter + 1
    fb/uid: parent-ctx/registry/counter
    fb/parent: parent-ctx
    fb/config: config
    fb/inject: inject-map
    fb/runtime: runtime
    fb/state: fiber-state/PENDING
    fb/epoch: inactive-epoch
    fb/store: make map! []
    fb/disposables: make-disposable-list
    fb/error: none
    fb/inertia: none
    ; ctx = parent.extend({ fiber: this }) - note that make map! does not evaluate, so compose is required
    child-ctx: parent-ctx/extend make map! compose [fiber: (fb)]
    fb/ctx: child-ctx

    append all-fibers fb

    ; internal/plugin event
    fb/ctx/events/emit 'internal-plugin reduce [fb] fb

    ; Initial inject check
    foreach name keys-of fb/inject [fiber-check-impl fb name]

    ; dispose = parent.fiber.effect(register on parent fiber)
    ; Function arguments must be passed as :word (Oldes auto-call)
    ex: func [] [
        ; Insert into runtime.fibers (DisposableList push -> remove disposer)
        remove-fn: runtime/fibers/push fb
        fb/config: resolve-config runtime config
        fiber-refresh fb
        ; Return the unload disposer (self-contained)
        dispose-fn: make object! [
            target-fb: fb
            remover: remove-fn
            dispose: func [] [
                if none? target-fb/uid [exit]
                target-fb/uid: none
                target-fb/ctx/events/emit 'internal-plugin reduce [target-fb] target-fb
                ; Registry cleanup (formalized in P5)
                if target-fb/ctx/registry/has target-fb/runtime/callback [
                    remover/dispose
                    if empty? target-fb/runtime/fibers/values [
                        target-fb/ctx/registry/delete target-fb/runtime/callback
                    ]
                ]
                fiber-set-epoch target-fb inactive-epoch
                none
            ]
        ]
        dispose-fn
    ]
    fb/dispose: fiber-effect parent-ctx/fiber :ex "ctx.plugin()"

    ; ex already ran fiber-refresh (fiber-effect executes immediately), so do not repeat it here
    fb
]
