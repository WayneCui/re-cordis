REBOL []

; ============================================================
; context.reb - Rebol3 port of cordis Context (P6)
; Upstream: ref/core/context.ts (78 lines)
;
; Semantic mapping:
;   - Context construction order (ROADMAP §3): fiber -> reflect -> registry -> events
;     -> logger -> replace root fiber disposables (matching _disposables.clear())
;   - Proxy handler -> explicit methods (reflect/registry/events methods all receive act-ctx)
;   - extend(meta) -> make-child-ctx (copy/override fields)
;   - isolate(name, label) -> new ctx + isolate-map (chained map, ROADMAP §4.6)
;     reflect store key = label/name, services are shared under the same label
;   - intercept(name, config) -> new ctx + intercept-map (declaration chain, consumed by P7)
;   - Context.is -> ctx marker field
;
; Constraints: methods must be self-contained (closed over the root-ref field); use compose with make map!
; ============================================================

do %./utils.reb
do %./events.reb
do %./fiber.reb
do %./reflect.reb
do %./registry.reb

; ------------------------------------------------------------
; Child ctx factory - the basis of extend (root-ref field closure, supports nested extend)
; ------------------------------------------------------------

make-child-ctx: func [root-ctx [object! none!] props [map!] /local new root-ref] [
    ; root-ref = the true root (traced upward); input root-ctx = direct parent ctx
    root-ref: either root-ctx [any [select root-ctx 'root-ref  root-ctx]][none]
    new: make object! [
        fiber: none
        events: none
        registry: none
        reflect: none
        logger: none
        filter: none
        root-ref: none
        isolate-map: make map! []     ; name -> label word
        intercept-chain: copy []      ; [leaf ... root] chained block, newest at the head (ROADMAP §4.6)
        extra: make map! []           ; unknown fields from extend (objects cannot add fields dynamically)
        ctx-marker: true              ; Context.is marker

        ; Inherit self (direct parent ctx) rather than root-ref - the isolation chain depends on the caller
        extend: func [p [map!]] [make-child-ctx self p]

        ; isolate: copy isolate-map + set label -> new ctx
        isolate: func [name [word!] label [word! none!] /local m] [
            m: copy isolate-map
            put m name either label [label][to-word rejoin ["iso-" to-string name "-" random 99999]]
            extend make map! compose [isolate-map: (m)]
        ]

        ; intercept: insert the current-level map at the head (chained shadowing) -> new ctx
        ; Gotcha: make map! [k: (block)] parses a block value as a nested map -> use put instead
        intercept: func [name [word!] config /local m chain props] [
            m: make map! []
            put m name config
            chain: compose [(m) (intercept-chain)]
            props: make map! []
            put props 'intercept-chain chain
            extend props
        ]
    ]
    either root-ctx [
        ; Inherit the parent's isolate/intercept chains (core isolation semantics)
        new/isolate-map: either select props 'isolate-map [select props 'isolate-map][copy root-ctx/isolate-map]
        new/intercept-chain: either select props 'intercept-chain [select props 'intercept-chain][copy root-ctx/intercept-chain]
        new/fiber: any [select props 'fiber  root-ctx/fiber]
        new/events: root-ctx/events
        new/registry: root-ctx/registry
        new/reflect: root-ctx/reflect
        ; logger: if logger.reb is already loaded, rebuild it (bind to the new ctx, matching upstream where
        ; a new Context gets a new LoggerService so logger can resolve the new chain after intercept/isolate);
        ; otherwise share the parent's logger (older tests do not depend on logger)
        new/logger: either all [
            value? 'make-logger-service
            select props 'intercept-chain
        ] [make-logger-service new] [root-ctx/logger]
        new/filter: select props 'filter
        new/root-ref: root-ref
        ; Store unknown fields in extra (objects cannot add fields dynamically)
        foreach [k v] props [
            unless find [fiber events registry reflect logger filter isolate-map intercept-chain root-ref] k [
                put new/extra k v
            ]
        ]
    ][
        new/filter: select props 'filter
    ]
    new
]

; ------------------------------------------------------------
; Root Context factory
; Construction order: fiber -> reflect -> registry -> events -> logger
; Replace root fiber disposables after construction (drop the internal handler wrapper)
; ------------------------------------------------------------

make-context: func [/local ctx rf] [
    ctx: make-child-ctx none make map! []
    ctx/root-ref: ctx
    rf: make-fiber-root ctx
    ctx/fiber: rf
    ctx/reflect: make-reflect-service ctx
    ctx/registry: make-registry-service ctx
    ctx/logger: make-logger-service ctx   ; P8: LoggerService (buffer + exporters)
    ctx/events: make-events-service ctx
    ; Match upstream context.ts: fiber._disposables.clear() -> replace the list
    ctx/fiber/disposables: make-disposable-list
    ctx
]

; ------------------------------------------------------------
; Context.is
; ------------------------------------------------------------

context-is: func [value] [
    either object? value [
        not none? select value 'ctx-marker
    ][false]
]
