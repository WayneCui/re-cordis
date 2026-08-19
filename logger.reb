REBOL []

; ============================================================
; logger.reb - Rebol3 port of cordis LoggerService (P8)
; Upstream: ref/core/logger.ts (240 lines) + logger.spec.ts (synchronously portable parts)
;
; Semantic mapping:
;   - LoggerService (extends Service) -> make-logger-service (P7 make-service registers 'logger)
;   - createCallable -> logger service object methods error/info/warn/debug
;     + create name -> named logger instance (upstream ctx.logger('name'))
;   - name resolution (upstream [symbols.invoke]): explicit name > intercept('logger').name
;     > fiber name (fiber-name, default "root")
;   - level filtering: exporter.levels[name] ?? levels.default ?? logger.level ?? INFO(2)
;   - exporter: registration returns a disposer; the default exporter writes to the bounded buffer
;   - message: [sn ts name type level args fiber] (ts is fixed at 0 in the synchronous version)
;
; Simplifications (ROADMAP §7):
;   - No traceable context tunneling -> service-internal name lookup always follows the resolution chain
;     (caller fiber is not distinguished)
;   - No formatter/%s placeholder substitution -> args are stored as-is (tests assert against args/1)
;   - No WeakRef -> fiber-ref is a direct reference or none
; ============================================================

do %./utils.reb
do %./events.reb
do %./fiber.reb
do %./reflect.reb
do %./registry.reb
do %./context.reb
do %./service.reb

; ------------------------------------------------------------
; level constants (upstream LoggerLevel)
; ------------------------------------------------------------

logger-level: context [
    ERROR: 0
    WARN: 1
    INFO: 2
    DEBUG: 3
]

; type word -> numeric level (values inside a select block are literals -> case evaluates them)
logger-type-level: func [type [word!]] [
    case [
        equal? type 'error [logger-level/ERROR]
        equal? type 'warn [logger-level/WARN]
        equal? type 'info [logger-level/INFO]
        equal? type 'debug [logger-level/DEBUG]
        true [logger-level/INFO]
    ]
]

; ------------------------------------------------------------
; emit-log - core logic: level filtering + dispatch to all exporters
; ------------------------------------------------------------

emit-log: func [lg [object!] type [word!] args [block!] /local svc sn msg lvl sn-v type-v args-v] [
    svc: lg/svc-ref
    sn: svc/sn-message + 1
    svc/sn-message: sn
    lvl: logger-type-level type
    ; Gotcha: in make object! [sn: sn], the RHS is shadowed by the new field -> use a prefixed variable
    sn-v: sn
    type-v: type
    args-v: args
    msg: make object! [
        sn: sn-v
        ts: 0
        name: lg/name
        type: type-v
        level: lvl
        args: args-v
        fiber: lg/fiber-ref
    ]
    foreach [id exp] svc/exporters [
        ; Normalize levels keys to word (lg/name is a string -> match via to-word)
        target-level: any [
            select exp/levels to-word lg/name
            select exp/levels 'default
            any [lg/level  logger-level/INFO]
        ]
        if target-level >= lvl [exp/export msg]
    ]
    none
]

; ------------------------------------------------------------
; logger instance factory (upstream Logger class)
; name: explicit > intercept('logger').name > fiber-name
; ------------------------------------------------------------

logger-create: func [svc [object!] name [word! none!] /local cfg cfg-name lg] [
    cfg: service-resolve-config svc none none
    cfg-name: select cfg 'name
    lg: make object! [
        svc-ref: none
        name: none
        level: none
        fiber-ref: none
        error: func [msg] [emit-log self 'error reduce [msg]]
        warn: func [msg] [emit-log self 'warn reduce [msg]]
        info: func [msg] [emit-log self 'info reduce [msg]]
        debug: func [msg] [emit-log self 'debug reduce [msg]]
    ]
    lg/svc-ref: svc
    lg/name: either name [
        to-string name
    ][
        either cfg-name [to-string cfg-name][fiber-name svc/ctx/fiber]
    ]
    lg/level: any [select cfg 'level  logger-level/INFO]
    lg/fiber-ref: svc/ctx/fiber
    lg
]

; Shortcut methods on the service object (upstream ctx.logger.info(...))
emit-svc: func [svc [object!] type [word!] msg] [
    emit-log logger-create svc none type reduce [msg]
]

; ------------------------------------------------------------
; LoggerService factory
; ------------------------------------------------------------

make-logger-service: func [root-ctx [object!] /local svc default-exp] [
    svc: make object! [
        ctx: none
        name: none
        buffer-size: 1000
        buffer: copy []
        exporters: make map! []
        sn-message: 0
        sn-exporter: 0

        ; exporter registration -> returns a disposer (self-contained)
        ; Gotcha: inside make object! [svc-ref: self], self points to the new object -> capture the frame-local value first
        exporter: func [exp [object!] /local id svc-obj] [
            svc-obj: self
            sn-exporter: svc-obj/sn-exporter + 1
            id: svc-obj/sn-exporter
            put svc-obj/exporters id exp
            make object! [
                svc-ref: svc-obj
                id-ref: id
                dispose: func [] [
                    svc-ref/exporters: map-remove-key svc-ref/exporters id-ref
                    none
                ]
            ]
        ]

        ; Shortcut log methods (name follows the resolution chain)
        error: func [msg] [emit-svc self 'error msg]
        warn: func [msg] [emit-svc self 'warn msg]
        info: func [msg] [emit-svc self 'info msg]
        debug: func [msg] [emit-svc self 'debug msg]

        ; Named logger instance
        create: func [name [word! string!]] [logger-create self to-word name]
    ]
    make-service root-ctx 'logger svc
    ; Default exporter: bounded buffer (registered during upstream construction)
    ; Gotcha: methods cannot close over the frame-local svc -> make it self-contained through the svc-ref field
    default-exp: make object! [
        svc-ref: svc
        levels: make map! []
        export: func [msg /local overflow len] [
            append svc-ref/buffer msg
            len: length? svc-ref/buffer
            overflow: len - svc-ref/buffer-size
            if overflow = 1 [remove svc-ref/buffer]
            if overflow > 1 [remove/part svc-ref/buffer overflow]
        ]
    ]
    svc/exporter default-exp
    svc
]
