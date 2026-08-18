REBOL []

; ============================================================
; events.reb — cordis EventsService 的 Rebol3 移植 (P2)
; 上游: ref/core/events.ts (178 行)
;
; 语义映射:
;   - 事件名 string → word! ('internal-update 等, '/' 不可用于 word)
;   - 变参事件 → block 参数 (ROADMAP §4.5): emit 'foo [a b c]
;   - listener → wrapper 对象 [name: word! call: func [args [block!]]]
;     (function! 存容器 auto-eval, 存 word 名 + do reduce ['apply :(name) args])
;   - hook → [ctx: 对象 cb: wrapper global: logic prepend: logic]
;   - thisArg (Session/Filter) 从 args 首元素解析 (object! 则 shift)
;   - filter 字段 = word! 名 (函数名), 经 do reduce 调用
;   - waterfall 的 next = 自包含 wrapper 对象, inner = word! 名
;   - parallel 同步化: 收集错误块返回 (上游 AggregateError)
;   - serial/bail 同步: 首个 is-bailed 结果返回
;   - register 通过 ctx/fiber/effect 注册 (fiber 卸载自动清理)
; ============================================================

do %./utils.reb

; ------------------------------------------------------------
; 辅助
; ------------------------------------------------------------

; is-bailed: value 非 none/false
is-bailed: func [value] [
    not any [none? value  equal? value false]
]

; 事件名是否内部事件 ('internal- 前缀)
internal-name?: func [name [word!]] [
    not none? find to-string name "internal-"
]

; 包装 listener (word! 函数名) → wrapper 对象
; call 签名: [args this-arg] — this-arg 供内部 handler (internal-update 链) 使用
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
; EventsService 工厂
; ------------------------------------------------------------

make-events-service: func [root-ctx [object!] /local svc ilw] [
    svc: make object! [
        ctx: root-ctx
        hooks: make map! []          ; name(word!) → block of hook 对象

        ; ----------------------------------------------------
        ; _resolve: 解析 thisArg + 过滤 callbacks (wrapper 列表)
        ; ----------------------------------------------------
        resolve-callbacks: func [mode [word!] name [word!] args [block!] this-arg [object! none!] /local hooks result filter-w] [
            if not internal-name? name [
                hooks: select hooks-dispatch
                if hooks [emit 'internal-dispatch reduce [mode name args this-arg] this-arg]
            ]
            hooks: select self/hooks name
            unless hooks [return copy []]
            result: copy []
            filter-w: none
            if this-arg [filter-w: select this-arg 'filter]
            foreach hook hooks [
                either any [hook/global  none? filter-w] [
                    append result hook/cb
                ][
                    if do reduce [filter-w hook/ctx] [append result hook/cb]
                ]
            ]
            result
        ]

        ; 惰性取 hooks 块
        hooks-dispatch: does [select self/hooks 'internal-dispatch]

        ; ----------------------------------------------------
        ; 五种分发
        ; ----------------------------------------------------
        emit: func [name [word!] args [block!] this-arg [object! none!] /local callbacks] [
            if none? this-arg [
                args: copy args
                if all [not empty? args  object? args/1] [
                    this-arg: args/1
                    remove args
                ]
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
            callbacks: resolve-callbacks 'waterfall name args this-arg
            ; next wrapper — 自包含 (cbs/arg-block/inner-w/this-ref 均为字段)
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
        ; 注册/注销
        ; ----------------------------------------------------
        register: func [label [string!] hooks [block!] lw [object!] opts [map!] act-ctx [object!] /local hook disp ex] [
            hook: make object! [
                ctx: act-ctx
                cb: lw
                global: any [select opts 'global false]
                prepend: any [select opts 'prepend false]
            ]
            ; 函数参数必须 :word 传递 (Oldes: word 求值函数值在参数位置 auto-call)
            ex: func [] [
                either hook/prepend [insert hooks hook][append hooks hook]
                ; disposer — 自包含 (hk/h 字段)
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
            ; internal/listener 特殊处理
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
            ; wrapper: 首次调用先 dispose 再调原 listener (自包含字段)
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
    ; constructor: internal/listener 特殊处理
    ; on('internal-update', 非 global) → 存入 fiber._hooks['internal-update']
    ; 的 DisposableList, 返回其 disposer
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
    ; constructor: internal/update 链 (global + prepend)
    ; waterfall('internal-update', config, noSave, final, fiber) 时
    ; 逐个调用 fiber._hooks['internal-update'] 的 listeners,
    ; 最后调用 final (fiber.restart)。listener 收 [config no-save next]
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
