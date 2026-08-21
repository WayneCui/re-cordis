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
do %./runtime-scope.reb
do %./deterministic-scheduler.reb

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
    inertia-target: none
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

fiber-state-name: func [state [integer! none!]] [
    case [
        none? state ["none"]
        equal? state fiber-state/PENDING ["PENDING"]
        equal? state fiber-state/LOADING ["LOADING"]
        equal? state fiber-state/ACTIVE ["ACTIVE"]
        equal? state fiber-state/FAILED ["FAILED"]
        equal? state fiber-state/DISPOSED ["DISPOSED"]
        equal? state fiber-state/UNLOADING ["UNLOADING"]
        true [rejoin ["STATE-" state]]
    ]
]

run-disposer: func [disposer [object!]] [
    do reduce [get in disposer 'dispose]
    none
]

fiber-has-disposable?: func [fb [object!] candidate [object!] /local d] [
    foreach d fb/disposables/values [
        if same? d candidate [return true]
    ]
    false
]

fiber-tag: func [fb [object! none!] /local name uid] [
    unless fb [return "none"]
    name: either all [fb/runtime  fb/runtime/name] [fb/runtime/name]["root"]
    uid: either none? fb/uid ["disposed"][to-string fb/uid]
    rejoin [name "#" uid]
]

fiber-release-inertia: func [fb [object!] /local target] [
    target: fb/inertia-target
    fb/inertia: none
    fb/inertia-target: none
    unless equal? fb/epoch target [
        fiber-set-epoch fb fb/epoch
    ]
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
    runtime-record fb/ctx 'fiber.state reduce [
        'fiber (fiber-tag fb)
        'from (fiber-state-name old)
        'to (fiber-state-name fb/state)
    ]
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
    runtime-record fb/ctx 'fiber.epoch reduce [
        'fiber (fiber-tag fb)
        'from old
        'to epoch-str
    ]
    if fb/inertia [exit]
    fb/inertia: true
    fb/inertia-target: epoch-str
    either equal? epoch-str inactive-epoch [
        fiber-update-state fb fiber-state/UNLOADING
        if not fiber-unload fb [fiber-release-inertia fb]
    ][
        either equal? old inactive-epoch [
            fiber-update-state fb fiber-state/LOADING
            if not fiber-reload fb [fiber-release-inertia fb]
        ][
            ; non->non: unload first (internal re-entry checks will continue into reload)
            fiber-update-state fb fiber-state/UNLOADING
            if not fiber-unload fb [fiber-release-inertia fb]
        ]
    ]
]

; ------------------------------------------------------------
; _reload / _unload
; ------------------------------------------------------------

fiber-collect-reload-result: func [fb [object!] result /local d] [
    either object? result [
        unless fiber-has-disposable? fb result [fb/disposables/push result]
    ][
        if block? result [
            foreach d result [
                unless fiber-has-disposable? fb d [fb/disposables/push d]
            ]
        ]
    ]
]

fiber-complete-reload: func [fb [object!] old-epoch [string!] result /local pending] [
    either error? result [
        fb/ctx/logger/error result
        fb/error: result
        fb/epoch: inactive-epoch
        fiber-update-state fb fiber-state/FAILED
        pending: fiber-unload fb
    ][
        either scheduled-task? result [
            pending: fiber-schedule-reload fb old-epoch result
        ][
            fiber-collect-reload-result fb result
            either equal? fb/epoch old-epoch [
                fiber-update-state fb fiber-state/ACTIVE
                pending: false
            ][
                fiber-update-state fb fiber-state/UNLOADING
                pending: fiber-unload fb
            ]
        ]
    ]
    pending
]

fiber-schedule-reload: func [fb [object!] old-epoch [string!] task [object!] /local scheduler wrapper] [
    scheduler: runtime-scheduler-of fb/ctx
    unless scheduler [return fiber-complete-reload fb old-epoch try [run-scheduled-task task]]
    runtime-record fb/ctx 'task.schedule reduce [
        'fiber (fiber-tag fb)
        'phase "reload"
        'delay task/delay
    ]
    wrapper: make object! [
        target-fb: none
        old-epoch-ref: none
        task-ref: none
        run: func [/local result pending] [
            runtime-record target-fb/ctx 'task.run reduce [
                'fiber (fiber-tag target-fb)
                'phase "reload"
                'delay task-ref/delay
            ]
            result: try [run-scheduled-task task-ref]
            pending: fiber-complete-reload target-fb old-epoch-ref result
            if not pending [fiber-release-inertia target-fb]
            none
        ]
    ]
    wrapper/target-fb: fb
    wrapper/old-epoch-ref: old-epoch
    wrapper/task-ref: task
    scheduler/schedule task/delay wrapper
    true
]

fiber-reload: func [fb [object!] /local old-epoch result] [
    old-epoch: fb/epoch
    ; After unload store becomes none, rebuild it before snapshotting
    either fb/store [fb/store: copy fb/store][fb/store: make map! []]
    result: try [fb/runtime/callback/apply fb/ctx fb/config]
    fiber-complete-reload fb old-epoch result
]

fiber-finalize-unload: func [fb [object!] /local pending] [
    runtime-record fb/ctx 'fiber.unload-finalize reduce [
        'fiber (fiber-tag fb)
        'epoch fb/epoch
    ]
    fb/store: none
    either none? fb/uid [
        fiber-update-state fb fiber-state/DISPOSED
        pending: false
    ][
        either fb/error [
            fiber-update-state fb fiber-state/FAILED
            pending: false
        ][
            either equal? fb/epoch inactive-epoch [
                fiber-update-state fb fiber-state/PENDING
                pending: false
            ][
                ; epoch is not INACTIVE -> reload
                fiber-update-state fb fiber-state/LOADING
                pending: fiber-reload fb
            ]
        ]
    ]
    pending
]

fiber-schedule-unload: func [fb [object!] remaining [block!] task [object!] label [string! none!] /local scheduler wrapper r pending] [
    scheduler: runtime-scheduler-of fb/ctx
    unless scheduler [
        r: try [run-scheduled-task task]
        if error? r [
            fb/ctx/logger/error r
            return fiber-unload-step fb remaining
        ]
        return fiber-unload-step fb remaining
    ]
    runtime-record fb/ctx 'task.schedule reduce [
        'fiber (fiber-tag fb)
        'phase "unload"
        'delay task/delay
        'label label
    ]
    wrapper: make object! [
        target-fb: none
        rest-ref: copy []
        task-ref: none
        label-ref: none
        run: func [/local result pending] [
            runtime-record target-fb/ctx 'task.run reduce [
                'fiber (fiber-tag target-fb)
                'phase "unload"
                'delay task-ref/delay
                'label label-ref
            ]
            result: try [run-scheduled-task task-ref]
            either error? result [
                target-fb/ctx/logger/error result
                pending: fiber-unload-step target-fb rest-ref
            ][
                pending: fiber-unload-step target-fb rest-ref
            ]
            if not pending [fiber-release-inertia target-fb]
            none
        ]
    ]
    wrapper/target-fb: fb
    wrapper/rest-ref: copy remaining
    wrapper/task-ref: task
    wrapper/label-ref: label
    scheduler/schedule task/delay wrapper
    true
]

fiber-unload-step: func [fb [object!] ds [block!] /local d r label] [
    if empty? ds [return fiber-finalize-unload fb]
    d: first ds
    remove ds
    if in d 'dispose-reason [d/dispose-reason: "unload"]
    label: either all [select d 'meta  select d/meta 'label] [d/meta/label][none]
    r: try [run-disposer d]
    if error? r [
        fb/ctx/logger/error r
        return fiber-unload-step fb ds
    ]
    either scheduled-task? r [
        fiber-schedule-unload fb ds r label
    ][
        fiber-unload-step fb ds
    ]
]

fiber-unload: func [fb [object!] /local ds] [
    ds: fb/disposables/clear
    fiber-unload-step fb ds
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
        foreach d reverse local-list [run-disposer d]
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
        owner-fiber: fb
        dispose-reason: none
        ; Gotcha: in make object! [label: label], the RHS is shadowed by the new field -> assign after creation
        meta: make object! [
            label: none
            owner: none
            disposed: false
            dispose-reason: none
            children: copy []
        ]
        dispose: func [/local reason] [
            reason: any [dispose-reason  "manual"]
            if done [return none]
            runtime-record owner-fiber/ctx 'effect.dispose reduce [
                'fiber (fiber-tag owner-fiber)
                'label meta/label
                'reason reason
            ]
            meta/disposed: true
            meta/dispose-reason: reason
            dispose-reason: none
            done: true
            foreach d reverse items [
                if in d 'dispose-reason [d/dispose-reason: reason]
                run-disposer d
            ]
            none
        ]
    ]
    wrapper/meta/label: label
    wrapper/meta/owner: fiber-tag fb
    wrapper/meta/children: children-list
    fb/disposables/push wrapper
    runtime-record fb/ctx 'effect.register reduce [
        'fiber (fiber-tag fb)
        'label label
        'children (length? children-list)
    ]
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
    config: (resolve-config fb/runtime config)
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

    runtime-register-fiber parent-ctx fb
    runtime-record parent-ctx 'fiber.create reduce [
        'fiber (fiber-tag fb)
        'runtime runtime/name
    ]

    ; internal/plugin event
    fb/ctx/events/emit 'internal-plugin reduce [fb] fb

    ; Initial inject check
    foreach name keys-of fb/inject [fiber-check-impl fb name]

    ; dispose = parent.fiber.effect(register on parent fiber)
    ; Function arguments must be passed as :word (Oldes auto-call)
    ex: func [] [
        ; Insert into runtime.fibers (DisposableList push -> remove disposer)
        remove-fn: fb/runtime/fibers/push fb
        fb/config: (resolve-config fb/runtime fb/config)
        fiber-refresh fb
        ; Return the unload disposer (self-contained)
        dispose-fn: make object! [
            target-fb: fb
            remover: remove-fn
            dispose: func [] [
                if none? target-fb/uid [exit]
                runtime-record target-fb/ctx 'fiber.dispose reduce [
                    'fiber (fiber-tag target-fb)
                    'reason "plugin-dispose"
                ]
                runtime-unregister-fiber target-fb/ctx target-fb
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
