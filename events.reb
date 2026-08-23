REBOL []

; ============================================================
; events.reb - Rebol3 port of cordis EventsService (P2)
; Upstream: ref/core/events.ts (178 lines)
;
; Semantic mapping:
;   - Event name string -> word! ('internal-update etc., '/' cannot appear in a word)
;   - Variadic events -> block arguments (ROADMAP §4.5): emit 'foo [a b c]
;   - listener -> wrapper object [name: word! call: func [args [block!]]]
;     (function! auto-evaluates in containers, so store the word name + do reduce ['apply :(name) args])
;   - hook -> [ctx: object cb: wrapper global: logic prepend: logic]
;   - thisArg (Session/Filter) is parsed from the first element of args (shift if object!)
;   - filter field = word! name (function name), invoked through do reduce
;   - waterfall next = self-contained wrapper object, inner = word! name
;     inner / listeners may return a thenable (thenable.reb); next/call
;     propagates that value unchanged. Callers that need a ready result
;     use thenable-wait. Sync listeners that add numbers to next/call
;     remain valid only when the remainder is sync.
;   - parallel is synchronized: return an aggregated error block (upstream AggregateError)
;   - serial/bail are synchronized: return the first is-bailed result
;   - register is wired through ctx/fiber/effect (auto-cleaned when the fiber unloads)
; ============================================================

do %./utils.reb
do %./thenable.reb
do %./runtime-scope.reb

; ------------------------------------------------------------
; Helpers
; ------------------------------------------------------------

; is-bailed: value is not none/false
is-bailed: func [value] [
    not any [none? value  equal? value false]
]

; Whether the event name is an internal event ('internal-' prefix)
internal-name?: func [name [word!]] [
    not none? find to-string name "internal-"
]

; Wrap a listener (word! function name) -> wrapper object
; call signature: [args this-arg] - this-arg is used by internal handlers (internal-update chain)
wrap-listener: func [listener [word!] /local w] [
    w: make object! [
        name: listener
        call: func [args [block!] this-arg [object! none!]] [
            do reduce [name args]
        ]
    ]
    w
]

; ------------------------------------------------------------
; EventsService factory
; ------------------------------------------------------------

make-events-service: func [root-ctx [object!] /local svc ilw] [
    svc: make object! [
        ctx: root-ctx
        hooks: make map! []          ; name(word!) -> block of hook objects

        ; ----------------------------------------------------
        ; _resolve: parse thisArg + filter callbacks (wrapper list)
        ; ----------------------------------------------------
        resolve-callbacks: func [mode [word!] name [word!] args [block!] this-arg [object! none!] /local hooks result filter-w] [
            if not internal-name? name [
                hooks: select hooks-dispatch
                if hooks [emit 'internal-dispatch reduce [mode name args this-arg] this-arg]
            ]
            hooks: select self/hooks name
            unless hooks [return copy []]
            result: copy []
            foreach hook hooks [
                either any [
                    hook/global
                    not all [this-arg  not none? select this-arg 'filter]
                ] [
                    append result hook/cb
                ][
                    filter-w: select this-arg 'filter
                    if do reduce [filter-w hook/ctx] [append result hook/cb]
                ]
            ]
            result
        ]

        ; Lazily fetch the hooks block
        hooks-dispatch: does [select self/hooks 'internal-dispatch]

        ; ----------------------------------------------------
        ; Five dispatch modes
        ; ----------------------------------------------------
        emit: func [name [word!] args [block!] this-arg [object! none!] /local callbacks] [
            if none? this-arg [
                args: copy args
                if all [not empty? args  object? args/1] [
                    this-arg: args/1
                    remove args
                ]
            ]
            runtime-record any [this-arg self/ctx] 'event.dispatch reduce [
                'mode 'emit
                'name name
            ]
            callbacks: resolve-callbacks 'emit name args this-arg
            foreach cb callbacks [cb/call args this-arg]
            none
        ]

        parallel: func [name [word!] args [block!] this-arg [object! none!] /local callbacks errors r] [
            if none? this-arg [
                args: copy args
                if all [not empty? args  object? args/1] [
                    this-arg: args/1
                    remove args
                ]
            ]
            runtime-record any [this-arg self/ctx] 'event.dispatch reduce [
                'mode 'parallel
                'name name
            ]
            callbacks: resolve-callbacks 'parallel name args this-arg
            errors: copy []
            foreach cb callbacks [
                r: try [cb/call args this-arg]
                if error? r [append errors r]
            ]
            either empty? errors [none][errors]
        ]

        serial: func [name [word!] args [block!] this-arg [object! none!] /local callbacks r] [
            if none? this-arg [
                args: copy args
                if all [not empty? args  object? args/1] [
                    this-arg: args/1
                    remove args
                ]
            ]
            runtime-record any [this-arg self/ctx] 'event.dispatch reduce [
                'mode 'serial
                'name name
            ]
            callbacks: resolve-callbacks 'serial name args this-arg
            foreach cb callbacks [
                r: cb/call args this-arg
                if is-bailed r [return r]
            ]
            none
        ]

        bail: func [name [word!] args [block!] this-arg [object! none!] /local callbacks r] [
            if none? this-arg [
                args: copy args
                if all [not empty? args  object? args/1] [
                    this-arg: args/1
                    remove args
                ]
            ]
            runtime-record any [this-arg self/ctx] 'event.dispatch reduce [
                'mode 'bail
                'name name
            ]
            callbacks: resolve-callbacks 'bail name args this-arg
            foreach cb callbacks [
                r: cb/call args this-arg
                if is-bailed r [return r]
            ]
            none
        ]

        waterfall: func [name [word!] args [block!] inner [word! object!] this-arg [object! none!] /local callbacks next] [
            if none? this-arg [
                args: copy args
                if all [not empty? args  object? args/1] [
                    this-arg: args/1
                    remove args
                ]
            ]
            runtime-record any [this-arg self/ctx] 'event.dispatch reduce [
                'mode 'waterfall
                'name name
            ]
            callbacks: resolve-callbacks 'waterfall name args this-arg
            ; next wrapper - self-contained (cbs/arg-block/inner-w/this-ref are all fields)
            next: make object! [
                cbs: callbacks
                arg-block: args
                inner-w: inner
                this-ref: this-arg
                call: func [] [
                    either empty? cbs [
                        either object? inner-w [
                            inner-w/call arg-block this-ref
                        ][
                            do reduce [inner-w arg-block]
                        ]
                    ][
                        cb: first cbs
                        remove cbs
                        cb/call arg-block this-ref
                    ]
                ]
            ]
            append args next
            next/call
        ]

        ; ----------------------------------------------------
        ; Register/unregister
        ; ----------------------------------------------------
        register: func [label [string!] hooks [block!] lw [object!] opts [map!] act-ctx [object!] /local hook disp ex] [
            hook: make object! [
                ctx: act-ctx
                cb: lw
                global: any [select opts 'global false]
                prepend: any [select opts 'prepend false]
            ]
            ; Function arguments must be passed as :word (Oldes auto-calls function values in argument position)
            ex: func [] [
                either hook/prepend [insert hooks hook][append hooks hook]
                ; disposer - self-contained (hk/h fields)
                make object! [
                    hk: hooks
                    h: hook
                    dispose: func [] [
                        remove find/only hk h
                        none
                    ]
                ]
            ]
            disp: act-ctx/fiber/effect :ex label
            disp
        ]

        unregister: func [hooks [block!] lw [object!] /local h] [
            foreach h hooks [
                if same? h/cb lw [
                    remove find/only hooks h
                    return true
                ]
            ]
            none
        ]

        on: func [name [word!] listener [word! object!] options [map! none!] ctx [object! none!] /local opts lw special hooks label act-ctx] [
            act-ctx: either ctx [ctx][self/ctx]
            either map? options [opts: copy options][opts: make map! compose [prepend: (options)]]
            act-ctx/fiber/assert-active
            either object? listener [lw: listener][lw: wrap-listener listener]
            ; Special handling for internal/listener
            special: bail 'internal-listener reduce [act-ctx name lw opts] none
            if special [return special]
            hooks: select self/hooks name
            unless hooks [
                hooks: copy []
                put self/hooks name hooks
            ]
            label: rejoin ["ctx.on(" to-string name ")"]
            register label hooks lw opts act-ctx
        ]

        once: func [name [word!] listener [word! object!] options [map! none!] ctx [object! none!] /local lw ow disp] [
            lw: either object? listener [listener][wrap-listener listener]
            ; wrapper: dispose on first call, then call the original listener (self-contained fields)
            ow: make object! [
                inner: lw
                disp: none
                fired: false
                call: func [args [block!] this-arg [object! none!]] [
                    unless fired [
                        fired: true
                        if disp [disp/dispose]
                    ]
                    inner/call args this-arg
                ]
            ]
            disp: on name ow options ctx
            ow/disp: disp
            disp
        ]
    ]

    ; ----------------------------------------------------
    ; constructor: special handling for internal/listener
    ; on('internal-update', non-global) -> store into fiber._hooks['internal-update']
    ; DisposableList and return its disposer
    ; ----------------------------------------------------
    ilw: make object! [
        svc-ref: svc
        call: func [args [block!] this-arg [object! none!] /local name listener options hooks] [
            name: args/1
            listener: args/2
            options: args/3
            if all [
                equal? name 'internal-update
                not any [select options 'global]
            ] [
                hooks: select svc-ref/ctx/fiber/hooks 'internal-update
                unless hooks [
                    hooks: make-disposable-list
                    put svc-ref/ctx/fiber/hooks 'internal-update hooks
                ]
                hooks/push listener
            ]
        ]
    ]
    svc/on 'internal-listener ilw make map! [global: true] none

    ; ----------------------------------------------------
    ; constructor: internal/update chain (global + prepend)
    ; When waterfall('internal-update', config, noSave, final, fiber) runs,
    ; call listeners in fiber._hooks['internal-update'] one by one,
    ; then call final (fiber.restart). Listener receives [config no-save next]
    ; ----------------------------------------------------
    iuc: make object! [
        svc-ref: svc
        call: func [args [block!] this-arg [object! none!] /local config no-save final-fn fb hlist cbs nxt] [
            config: args/1
            no-save: args/2
            final-fn: args/3
            fb: this-arg
            hlist: select fb/hooks 'internal-update
            cbs: either hlist [hlist/values][copy []]
            nxt: make object! [
                cbs: cbs
                arg-block: reduce [config no-save]
                final-w: final-fn
                call: func [] [
                    either empty? cbs [
                        final-w/call arg-block none
                    ][
                        cb: first cbs
                        remove cbs
                        cb/call append copy arg-block self none
                    ]
                ]
            ]
            nxt/call
        ]
    ]
    svc/on 'internal-update iuc make map! [global: true prepend: true] none
    svc
]
