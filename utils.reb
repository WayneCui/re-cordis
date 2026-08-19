REBOL []

; ============================================================
; utils.reb - Rebol3 port of cordis core utils (P1)
; Upstream: ref/core/utils.ts (278 lines)
;
; Kept:
;   - DisposableList   (used by events/registry: push/delete/clear/length/iteration)
;   - symbols          (used by service/registry/events/logger, Symbol.for -> word!)
;   - compose-error    (error helper, synchronous simplification: no JS stack, attach a context label)
;
; Dropped (ROADMAP §4.2, traceable Proxy mechanism, only needed for JS this semantics):
;   createTraceable / withProps / createShadow / createShadowMethod /
;   createCallable / joinPrototype / isConstructor / isObject /
;   getPropertyDescriptor / buildOuterStack
; ============================================================

; ------------------------------------------------------------
; symbols - Symbol.for('cordis.xxx') -> word! constants
; Note: word! cannot contain '/' (the scanner parses it as a path!), so use '-' instead
; ------------------------------------------------------------

shadow:         'cordis-shadow
caller:         'cordis-caller
receiver:       'cordis-receiver
original:       'cordis-original
metadata:       'cordis-metadata
init-hooks:     'cordis-initHooks
check-proto:    'cordis-checkProto
effect:         'cordis-effect
filter:         'cordis-filter
isolate:        'cordis-isolate
intercept:      'cordis-intercept
init:           'cordis-init
check:          'cordis-check
config:         'cordis-config
invoke:         'cordis-invoke
extend:         'cordis-extend
tracker:        'cordis-tracker
resolve-config: 'cordis-resolveConfig

; ------------------------------------------------------------
; DisposableList
;
; TS semantics:
;   push(value)  -> () => map.delete(sn)   unload function
;   delete(value) -> bool                  delete by value (identity comparison)
;   clear()      -> values.reverse()       clear and return values in reverse order
;   length       → map.size
;   iteration    -> map.values()
;
; Rebol implementation shape (gotcha: function! auto-evaluates in containers; make object! methods
; cannot close over frame-local variables, so the disposer must be self-contained):
;   - Instance is an object!, data: map! (sn -> value), sn increments
;   - push returns a disposer object [list-ref idx dispose], and dispose calls
;     list-ref/remove idx - pass references through fields, not closures
;   - map! has no native remove-key -> rebuild the map via remove/delete
;   - Equality checks always use equal? (returns logic!, not string)
; ------------------------------------------------------------

make-disposable-list: func [][
    lst: make object! [
        sn: 0
        data: make map! []
        self-ref: none

        remove: func [idx [integer!] /local new] [
            new: make map! []
            foreach [k v] data [
                unless equal? k idx [put new k v]
            ]
            data: new
        ]

        push: func [value [object! block! word! integer!] /local idx] [
            sn: sn + 1
            idx: sn
            put data idx value
            make object! compose/deep [
                list-ref: (self-ref)
                idx: (idx)
                dispose: func [] [
                    list-ref/remove idx
                    none
                ]
            ]
        ]

        delete: func [value /local found new] [
            found: false
            new: make map! []
            foreach [k v] data [
                either same? v value [
                    found: true
                ][
                    put new k v
                ]
            ]
            data: new
            found
        ]

        clear: func [/local vals] [
            vals: collect [foreach [k v] data [keep v]]
            data: make map! []
            reverse vals
        ]

        length: does [length? data]

        values: does [collect [foreach [k v] data [keep v]]]
    ]
    lst/self-ref: lst
    lst
]

; ------------------------------------------------------------
; compose-error - error helper (synchronous simplification)
;
; TS semantics: wrap a callback, catch exceptions, append stack information to the error, then rethrow
; Rebol implementation: no stack; catch with try and return an error string on failure (fail loudly),
;   with an attached context label for easier localization (for example "plugin foo")
; ------------------------------------------------------------

compose-error: func [
    callback [function!]
    context-label [string!]
][
    result: try [callback]
    either error? result [
        rejoin ["[compose-error:" context-label "] " result/id " " result/arg1]
    ][
        result
    ]
]
