REBOL []

; ============================================================
; service.reb - Rebol3 port of the cordis Service base class (P7)
; Upstream: ref/core/service.ts (80 lines) + logger.ts _resolveConfig (intercept consumer)
;
; Semantic mapping:
;   - JS class extends Service -> Rebol service object + make-service factory
;   - Auto-registration during construction: super(ctx, name) -> reflect.provide(name, self, check)
;   - resolveConfig(base, head) -> walk ctx/intercept-chain to collect config for this service name
;     + base/head, then merge them (Config.merge takes priority, otherwise later values overwrite earlier ones)
;   - symbols (init/check/config/invoke/extend/tracker) -> conventional fields:
;       init   object! [call: func [args this-arg] [...]]   (executed when the plugin loads)
;       check  object! [call: ...]                          (reflect check)
;       Config object! [merge: wrapper] or map!             (config merge/defaults)
;   - No class/prototype chain: service object fields are self-contained and methods reference self
;
; Constraints: use put with make map! (block values are parsed as nested maps); callbacks are always wrapper objects
; ============================================================

do %./utils.reb
do %./events.reb
do %./fiber.reb
do %./reflect.reb
do %./registry.reb
do %./context.reb

; ------------------------------------------------------------
; Service construction - register the service into reflect + inject ctx/name
; Upstream: super(ctx, name) -> this.name = name; reflect.provide(name, self, check)
; Rebol: make-service ctx name svc-obj (name is passed explicitly, matching super(ctx, name))
; svc-obj convention (user-constructed, required fields):
;   name: none   (word! injected during construction)
;   ctx: none    (injected during construction)
;   check: object! [call: ...] (optional, service value check)
;   init: object! [call: ...]  (optional, plugin load hook - user calls it from apply)
;   Config: object! [merge: wrapper] (optional, resolveConfig merger)
; ------------------------------------------------------------

make-service: func [ctx [object!] name [word!] svc-obj [object!] /local check] [
    svc-obj/ctx: ctx
    svc-obj/name: name
    ; Register the service (pass check as-is; reflect.provide receives the wrapper object directly)
    check: select svc-obj 'check
    ctx/reflect/provide name svc-obj check ctx
    svc-obj
]

; ------------------------------------------------------------
; Port of Service.resolveConfig(base, head)
; Upstream: walk the intercept prototype chain to collect config for name, unshift in reverse order
;       (root first), base unshifted to the front, head pushed to the end; then Config.merge or Object.assign
; Rebol: intercept-chain = [leaf ... root] block, collect by walking in order,
;       so configs = [base root ... leaf head], where later values overwrite earlier ones during merge
; ------------------------------------------------------------

service-resolve-config: func [svc [object!] base head /local chain configs m cfg conf mw merged] [
    chain: select svc/ctx 'intercept-chain
    unless chain [chain: copy []]
    configs: copy []
    ; Walk from leaf to root, inserting at the head -> configs = [root ... leaf] (upstream unshift semantics)
    foreach m chain [
        cfg: select m svc/name
        if not none? cfg [insert configs cfg]
    ]
    if not none? base [insert configs base]
    if not none? head [append configs head]
    ; Config.merge takes priority (wrapper object)
    conf: select svc 'Config
    if conf [
        mw: select conf 'merge
        if mw [return mw/call configs none]
    ]
    ; Default merge: later values overwrite earlier ones
    merged: make map! []
    foreach m configs [
        if map? m [
            foreach [k v] m [put merged k v]
        ]
    ]
    merged
]

; ------------------------------------------------------------
; Port of Service.extend(props) - copy the service instance + override fields
; Upstream: Object.create(this) + Object.assign(props)
; Rebol: make-service wraps a new object (reusing the original ctx), unknown props go into extra
; Simplified: create a new object directly and copy known fields (self-contained field list)
; ------------------------------------------------------------

service-extend: func [svc [object!] props [map!] /local new k v] [
    new: make object! [
        ctx: svc/ctx
        name: svc/name
        value: none
        extra: make map! []   ; unknown fields (objects cannot add fields dynamically)
    ]
    ; Copy known fields (self-contained list)
    foreach k [ctx name value] [
        v: select svc k
        if not none? v [set-path [new k] v]
    ]
    foreach [k v] props [
        unless find [ctx name value] k [put new/extra k v]
    ]
    new
]

; ------------------------------------------------------------
; Port of Service.filter(ctx) - filter by matching isolate labels
; Upstream: ctx[symbols.isolate][name] === this.ctx[symbols.isolate][name]
; Rebol: compare via ctx-isolate-label (reflect.reb)
; ------------------------------------------------------------

service-filter: func [svc [object!] other [object!]] [
    equal? ctx-isolate-label svc/ctx svc/name  ctx-isolate-label other svc/name
]
