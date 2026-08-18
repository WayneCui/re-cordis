REBOL []

; ============================================================
; registry.reb — cordis RegistryService 的 Rebol3 移植 (P5)
; 上游: ref/core/registry.ts (214 行)
;
; 语义映射:
;   - _internal Map<Function, Runtime> → runtimes block (runtime 对象列表,
;     find-runtime 用 same? 匹配 callback)
;   - plugin(plugin, config) → resolve → runtime 查找/创建 → make-plugin-fiber
;   - inject(deps, callback) → 包装成插件对象 {inject, apply}
;   - decorator @Inject → 声明式 inject 字段 (ROADMAP §4.4)
;   - counter 递增 (make-plugin-fiber 使用)
;   - delete → 移除 runtime + dispose 所有 fibers
;
; 约束: 回调存 wrapper 对象; 对象比较用 same?; make map! 用 compose
; ============================================================

do %./utils.reb
do %./events.reb
do %./fiber.reb
do %./reflect.reb

; ------------------------------------------------------------
; Inject.resolve — inject 声明 → map! (name → config/none)
; ------------------------------------------------------------

resolve-inject: func [inject [block! map! none!] /local result name val] [
    result: make map! []
    either block? inject [
        foreach name inject [
            ; 字面量块元素是 lit-word → to-word
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
; RegistryService 工厂
; ------------------------------------------------------------

make-registry-service: func [root-ctx [object!] /local svc] [
    svc: make object! [
        ctx: root-ctx
        counter: 0
        runtimes: copy []          ; block of runtime 对象

        find-runtime: func [callback [object!] /local rt] [
            foreach rt self/runtimes [
                if same? rt/callback callback [return rt]
            ]
            none
        ]

        ; ---- 集合 API ----
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

        ; ---- plugin 注册 ----
        ; ctx 参数: 显式调用者 ctx (上游 traceable 隐式, Rebol 显式; 缺省 root)
        plugin: func [plugin [object!] config ctx [object! none!] /local callback rt inject-map fb r act-ctx] [
            ; 注意: select 取方法字段会 auto-call → 用 in 检查存在性
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

        ; ---- inject 便捷方法 (包装成插件对象) ----
        inject: func [deps [block!] apply-word [word!] ctx [object! none!] /local p] [
            p: make object! [
                name: none
                inject: deps
                apply: func [ctx [object!] config] [do reduce [apply-word ctx config]]
            ]
            p/name: to-string apply-word
            self/plugin p none ctx
        ]
    ]
    svc
]
