REBOL []

; ============================================================
; reflect.reb - Rebol3 port of cordis ReflectService (P4 + P6 isolate)
; Upstream: ref/core/reflect.ts (281 lines) + isolate semantics
;
; Semantic mapping:
;   - Proxy handler -> explicit methods (ROADMAP §4.1)
;   - store key = isolate label + name (isolate chain, ROADMAP §4.6):
;     string key "iso-xxx/foo"; root defaults to label 'default
;   - Methods explicitly receive act-ctx (upstream traceable is implicit, Rebol is explicit)
;   - provide -> register impl via fiber.effect + notify; returns a disposer
;   - notify -> walk all-fibers; only injected fibers under the same isolate label respond
;   - accessor/mixin -> simplified
;   - trace/bind -> returned unchanged (traceable is dropped)
;
; Key constraints: callbacks are stored as wrapper objects; object comparison uses same?; use compose with make map!
; ============================================================

do %./utils.reb
do %./events.reb
do %./fiber.reb
do %./runtime-scope.reb

; ------------------------------------------------------------
; isolate helpers
; ------------------------------------------------------------

default-isolate: 'default

; ctx isolate label (name -> label)
ctx-isolate-label: func [ctx [object!] name [word!] /local m] [
    m: select ctx 'isolate-map
    either m [
        any [select m name  default-isolate]
    ][default-isolate]
]

; store key = "label/name" (string key, isolates same-kind services across different ctx instances)
isolate-store-key: func [ctx [object!] name [word!]] [
    rejoin [ctx-isolate-label ctx name  "/"  to-string name]
]

; ------------------------------------------------------------
; notify - inform all fibers that inject this service under the same isolate label
; ------------------------------------------------------------

reflect-notify: func [svc [object!] names [block!] act-ctx [object!] /local fb name updated impl] [
    runtime-record act-ctx 'service.notify reduce [
        'names names
        'scope (ctx-isolate-label act-ctx first names)
    ]
    foreach fb runtime-fibers-of act-ctx [
        updated: false
        foreach name names [
            if find keys-of fb/inject name [
                ; filter: only the same isolate label should react
                if equal? ctx-isolate-label fb/ctx name  ctx-isolate-label act-ctx name [
                    updated: true
                    fiber-check-impl fb name
                ]
            ]
        ]
        if updated [fiber-refresh fb]
    ]
    ; internal/service event
    foreach name names [
        impl: svc/get-impl name false act-ctx
        svc/ctx/events/emit 'internal-service reduce [name  either impl [impl/value][none]] none
    ]
    none
]

; ------------------------------------------------------------
; ReflectService factory
; ------------------------------------------------------------

make-reflect-service: func [root-ctx [object!] /local svc] [
    svc: make object! [
        ctx: root-ctx
        store: make map! []      ; "label/name" -> impl
        props: make map! []      ; name -> property declaration map!

        ; ----------------------------------------------------
        ; Query operations (explicit act-ctx)
        ; ----------------------------------------------------
        get-impl: func [name [word!] strict [logic!] act-ctx [object!] /local key impl] [
            key: isolate-store-key act-ctx name
            impl: select self/store key
            either impl [
                either all [strict  not equal? impl/fiber/state fiber-state/ACTIVE] [none][impl]
            ][none]
        ]

        get: func [name [word!] strict [logic!] act-ctx [object!] /local impl] [
            impl: get-impl name strict act-ctx
            either impl [impl/value][none]
        ]

        ; provide during LOADING skips notify; fiber-notify-active calls this on ACTIVE
        notify: func [names [block!] act-ctx [object!]] [
            reflect-notify self names act-ctx
        ]

        set: func [name [word!] value act-ctx [object!] /local key impl] [
            key: isolate-store-key act-ctx name
            impl: select self/store key
            unless impl [
                return reflect-error rejoin ["cannot set property " to-string name " without provide"]
            ]
            if not same? impl/fiber act-ctx/fiber [
                return reflect-error rejoin ["cannot set property " to-string name " in multiple fibers"]
            ]
            impl/value: value
            true
        ]

        ; ----------------------------------------------------
        ; provide - register a service (fiber.effect, auto-cleaned on unload)
        ; ----------------------------------------------------
        provide: func [name [word!] value check [object! none!] act-ctx [object!] /local ex] [
            ; Gotcha: inside make object!, self points to the new object -> capture the ex frame-local value first
            ex: func [/local svc-obj key] [
                svc-obj: self
                key: isolate-store-key act-ctx name
                ; props declaration
                p: select svc-obj/props name
                either p [
                    if not equal? select p 'type "service" [
                        print rejoin ["[ReflectError] property " to-string name " is already declared as " select p 'type]
                        return none
                    ]
                ][
                    put svc-obj/props name make map! [type: "service"]
                ]
                ; Duplicate registration check (within the same isolate)
                if select svc-obj/store key [
                    print rejoin ["[ReflectError] service " to-string name " has been registered"]
                    return none
                ]
                impl: make object! [name: none value: none fiber: none check: none]
                impl/name: name
                impl/value: value
                impl/fiber: act-ctx/fiber
                impl/check: check
                put svc-obj/store key impl
                unless act-ctx/fiber/store [act-ctx/fiber/store: make map! []]
                put act-ctx/fiber/store name impl
                runtime-record act-ctx 'service.provide reduce [
                    'name name
                    'fiber (fiber-tag act-ctx/fiber)
                    'scope (ctx-isolate-label act-ctx name)
                ]
                if equal? act-ctx/fiber/state fiber-state/ACTIVE [
                    reflect-notify svc-obj reduce [name] act-ctx
                ]
                ; disposer - self-contained (svc-ref/key-ref fields)
                make object! [
                    svc-ref: svc-obj
                    key-ref: key
                    name-ref: name
                    ctx-ref: act-ctx
                    dispose: func [] [
                        svc-ref/store: map-remove-key svc-ref/store key-ref
                        runtime-record ctx-ref 'service.unprovide reduce [
                            'name name-ref
                            'fiber (fiber-tag ctx-ref/fiber)
                            'scope (ctx-isolate-label ctx-ref name-ref)
                        ]
                        reflect-notify svc-ref reduce [name-ref] ctx-ref
                        if ctx-ref/fiber/store [
                            ctx-ref/fiber/store: map-remove-key ctx-ref/fiber/store name-ref
                        ]
                        none
                    ]
                ]
            ]
            act-ctx/fiber/effect :ex rejoin ["ctx.provide(" to-string name ")"]
        ]

        ; ----------------------------------------------------
        ; accessor - declare accessor properties (get/set are wrapper objects)
        ; ----------------------------------------------------
        accessor: func [name [word! lit-word!] options [map!] /local ex] [
            ex: func [/local svc-obj] [
                svc-obj: self
                if select svc-obj/props name [
                    print rejoin ["[ReflectError] property " to-string name " already declared"]
                    return none
                ]
                put svc-obj/props name make map! compose/deep [
                    type: "accessor"
                    get: (select options 'get)
                    set: (select options 'set)
                ]
                make object! [
                    svc-ref: svc-obj
                    name-ref: name
                    dispose: func [] [
                        svc-ref/props: map-remove-key svc-ref/props name-ref
                        none
                    ]
                ]
            ]
            self/ctx/fiber/effect :ex rejoin ["ctx.accessor(" to-string name ")"]
        ]

        ; ----------------------------------------------------
        ; mixin - delegated accessor: ctx.<key> reads a field from the source service
        ; ----------------------------------------------------
        mixin: func [source [word!] mixins [block!] /local ex] [
            ex: func [/local svc-obj key get-w raw-key] [
                svc-obj: self
                foreach raw-key mixins [
                    ; lit-word keys do not match object field words -> convert with to-word
                    key: to-word raw-key
                    get-w: make object! [
                        svc-ref: svc-obj
                        src: source
                        k: key
                        call: func [args [block!] this-arg [object! none!] /local impl s act] [
                            ; Explicit version: read the service from reflect store (no Proxy field)
                            act: either this-arg [this-arg][svc-ref/ctx]
                            impl: svc-ref/get-impl src true act
                            either impl [
                                s: impl/value
                                either s [select s k][none]
                            ][none]
                        ]
                    ]
                    svc-obj/accessor key make map! compose/deep [
                        get: (get-w)
                        set: (none)
                    ]
                ]
                none
            ]
            self/ctx/fiber/effect :ex rejoin ["ctx.mixin(" to-string source ")"]
        ]

        ; ----------------------------------------------------
        ; trace/bind - traceable is dropped, return the value unchanged
        ; ----------------------------------------------------
        trace: func [value] [value]
        bind: func [value] [value]
    ]
    svc
]

; ------------------------------------------------------------
; Error helper
; ------------------------------------------------------------

reflect-error: func [msg [string!]] [
    rejoin ["[ReflectError] " msg]
]
