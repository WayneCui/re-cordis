REBOL []

; ============================================================
; registry.reb - Rebol3 port of cordis RegistryService (P5)
; Upstream: ref/core/registry.ts (214 lines)
;
; Semantic mapping:
;   - _internal Map<Function, Runtime> -> runtimes block (list of runtime objects,
;     find-runtime matches callbacks with same?)
;   - plugin(plugin, config) -> resolve -> find/create runtime -> make-plugin-fiber
;   - inject(deps, callback) -> wrap into a plugin object {inject, apply}
;   - decorator @Inject -> declarative inject field (ROADMAP §4.4)
;   - counter increments (used by make-plugin-fiber)
;   - delete -> remove the runtime + dispose all fibers
;
; Constraints: callbacks are stored as wrapper objects; object comparison uses same?; use compose with make map!
; ============================================================

do %./utils.reb
do %./events.reb
do %./fiber.reb
do %./reflect.reb

; ------------------------------------------------------------
; Inject.resolve - inject declaration -> map! (name -> config/none)
; ------------------------------------------------------------

resolve-inject: func [inject [block! map! none!] /local result name val] [
    result: make map! []
    either block? inject [
        foreach name inject [
            ; Literal block elements are lit-word -> convert with to-word
            put result to-word name none
        ]
    ][
        if map? inject [
            foreach [name val] inject [
                put result name either none? val [none][val]
            ]
        ]
    ]
    result
]

; ------------------------------------------------------------
; RegistryService factory
; ------------------------------------------------------------

make-registry-service: func [root-ctx [object!] /local svc] [
    svc: make object! [
        ctx: root-ctx
        counter: 0
        runtimes: copy []          ; block of runtime objects

        find-runtime: func [callback [object!] /local rt] [
            foreach rt self/runtimes [
                if same? rt/callback callback [return rt]
            ]
            none
        ]

        ; ---- Collection API ----
        size: does [length? self/runtimes]
        keys: does [collect [foreach rt self/runtimes [keep rt/callback]]]
        values: does [collect [foreach rt self/runtimes [keep rt]]]
        entries: does [collect [foreach rt self/runtimes [keep/only reduce [rt/callback rt]]]]
        for-each: func [cb [function!] /local rt] [
            foreach rt self/runtimes [cb rt/callback rt]
            none
        ]

        has: func [callback [object!]] [
            not none? find-runtime callback
        ]

        delete: func [callback [object!] /local rt] [
            rt: find-runtime callback
            unless rt [return none]
            block-remove-same self/runtimes rt
            foreach fb rt/fibers/values [fb/dispose/dispose]
            rt
        ]

        ; ---- reload: swap a named plugin's fibers for a new callback ----
        ; Old fibers are disposed (effects unwind: services unprovide, listeners detach),
        ; then the new plugin mounts under each old fiber's parent ctx with its config.
        ; On mount failure the old callback is re-mounted (rollback).
        find-runtime-by-name: func [name [string!] /local rt] [
            foreach rt self/runtimes [
                if equal? rt/name name [return rt]
            ]
            none
        ]

        reload: func [name [string!] new-plugin [object!] /local rt old-callback mounts result m fb] [
            unless all [object? new-plugin in new-plugin 'apply] [
                return "[RegistryError] reload: new plugin must be an object with apply"
            ]
            rt: find-runtime-by-name name
            unless rt [
                return rejoin ["[RegistryError] reload: plugin not found: " name]
            ]
            old-callback: rt/callback
            mounts: copy []
            foreach fb rt/fibers/values [
                append/only mounts reduce [fb/config fb/parent]
            ]
            self/delete old-callback
            result: true
            foreach m mounts [
                fb: self/plugin new-plugin m/1 m/2
                if string? fb [
                    result: fb
                    break
                ]
                if any [fb/error equal? fb/state fiber-state/FAILED] [
                    result: rejoin ["[RegistryError] reload: new plugin failed to start: " mold any [fb/error ""]]
                    break
                ]
            ]
            unless equal? result true [
                self/delete new-plugin
                foreach m mounts [self/plugin old-callback m/1 m/2]
            ]
            result
        ]

        ; ---- plugin registration ----
        ; ctx parameter: explicit caller ctx (upstream traceable is implicit, Rebol is explicit; default is root)
        plugin: func [plugin [object!] config ctx [object! none!] /local callback rt inject-map fb r act-ctx] [
            ; Note: select auto-calls method fields -> use in to test for existence
            callback: either in plugin 'apply [plugin][none]
            unless callback [
                return rejoin ["[RegistryError] invalid plugin, expect object with an apply method"]
            ]
            act-ctx: either ctx [ctx][self/ctx]
            r: act-ctx/fiber/assert-active
            if r [return r]
            rt: find-runtime callback
            unless rt [
                rt: make object! [name: none callback: none fibers: none Config: none]
                rt/name: select plugin 'name
                rt/callback: callback
                rt/fibers: make-disposable-list
                rt/Config: select plugin 'Config
                append self/runtimes rt
            ]
            inject-map: resolve-inject select plugin 'inject
            fb: make-plugin-fiber act-ctx config inject-map rt
            fb
        ]

        ; ---- inject convenience helper (wrap into a plugin object) ----
        inject: func [deps [block!] apply-word [word!] ctx [object! none!] /local p] [
            p: make object! [
                name: none
                inject: deps
                apply-word-ref: none
                apply: func [ctx [object!] config] [do reduce [apply-word-ref ctx config]]
            ]
            p/apply-word-ref: apply-word
            p/name: to-string apply-word
            self/plugin p none ctx
        ]
    ]
    svc
]
