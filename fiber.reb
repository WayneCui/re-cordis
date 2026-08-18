REBOL []

; ============================================================
; fiber.reb — cordis Fiber 状态机的 Rebol3 移植 (P3)
; 上游: ref/core/fiber.ts (486 行)
;
; 核心反共识机制 (ROADMAP §4.3, 必保):
;   1. fiber 状态机: PENDING→LOADING→ACTIVE / →UNLOADING→(reload|PENDING)
;   2. epoch 反应式: inject 依赖 impl 的 uid 拼接串; provide/dispose 通知
;      → checkImpl → refresh → epoch 变化 → reload/unload
;   3. effect() 作用域清理: 卸载时逆序执行 disposer (LIFO)
;
; 同步版简化 (ROADMAP §7 限制):
;   - 无 Promise: _reload/_unload 全同步, inertia 为 logic! 标志
;   - 无 generator: effect 返回 函数/disposer 对象/block-of-disposers/none
;   - error 传播: 返回 error! 对象或字符串 (无异常栈)
;   - resolveConfig: 不支持 schema 验证 (P7 service 补)
;
; 关键 Rebol 约束:
;   - 回调/disposer 一律 wrapper 对象 (function! 存容器 auto-eval)
;   - 插件 callback = 对象 + apply 方法 (spike 约定)
;   - 对象方法只引用自身字段 (自包含), 不闭包创建帧
;   - 相等性判断一律 equal?/same?
; ============================================================

do %./utils.reb
do %./events.reb

; ------------------------------------------------------------
; 常量
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

; 所有 plugin fiber 注册表 (P4 reflect 正式化前, notify 用)
all-fibers: copy []

; ------------------------------------------------------------
; fiber 类型
; ------------------------------------------------------------

fiber-type: make object! [
    uid: none
    parent: none            ; Context (父 context)
    ctx: none               ; 自己的 context (extend 或 parent)
    config: none
    state: fiber-state/PENDING
    epoch: none             ; string! 或 inactive-epoch
    inject: make map! []    ; name(word!) → config
    runtime: none           ; [name callback fibers Config] 或 none (root)
    store: none             ; name → impl 快照 (ACTIVE 时非 none)
    disposables: none       ; DisposableList
    hooks: make map! []     ; _hooks: word → DisposableList (internal-update)
    error: none
    inertia: none           ; 同步版: logic! true = 加载/卸载中
    dispose: none           ; 卸载入口 (wrapper 对象, root = restart)

    ; ---- 方法壳 (内部调独立函数, 自包含) ----
    ; 注意: 函数参数用 :word 传 (Oldes: word 求值函数值在参数位置 auto-call)
    assert-active: func [] [fiber-assert-active self]
    effect: func [execute [function!] label [string!]] [fiber-effect self :execute label]
    restart: func [] [fiber-restart self]
    await: func [] [fiber-await self]
    update: func [config no-save [logic!]] [fiber-update self config no-save]
    name: does [fiber-name self]
    get-effects: does [fiber-get-effects self]
]

; ------------------------------------------------------------
; 辅助
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

; ------------------------------------------------------------
; resolveConfig — 简化版 (P7 service 补 schema 验证)
; ------------------------------------------------------------

resolve-config: func [runtime [object! none!] config] [
    unless runtime [return config]
    unless runtime/Config [return config]
    ; Config = word! 函数名 (validator), 调用返回验证后的 config
    do reduce [runtime/Config config]
]

; ------------------------------------------------------------
; 状态查询与更新
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

; ACTIVE ↔ 非 ACTIVE 边界变化 → 通知 reflect (impl 重新评估)
; ACTIVE ↔ 非 ACTIVE 边界变化 → 通知 reflect (impl 重新评估)
; 注意: 必须用 same? (身份比较) — equal? 对对象深度递归比较,
; ctx↔fiber 循环引用会导致无限递归段错误
fiber-notify-active: func [fb [object!] /local impl name] [
    foreach [name impl] fb/ctx/reflect/store [
        if same? impl/fiber fb [
            fb/ctx/reflect/notify reduce [impl/name] fb/ctx
        ]
    ]
]

; 更新 state, 变化时 emit internal-status + ACTIVE 边界 notify
fiber-update-state: func [fb [object!] new-state [integer! none!] /local old] [
    old: fb/state
    either new-state [fb/state: new-state][fb/state: fiber-get-state fb]
    if equal? old fb/state [exit]
    fb/ctx/events/emit 'internal-status reduce [fb old] fb
    ; 仅通知 ACTIVE ↔ 非 ACTIVE 变化
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
    ; unload 后 store 为 none, 重新评估前重建
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
    ; unload 后 store 为 none; 上游 checkImpl 维护私有 _store,
    ; Rebol 合并 store/_store → refresh 前重建
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

; 依赖 epoch 变化 → 重载/卸载 (同步版, inertia 标志防重入)
fiber-set-epoch: func [fb [object!] epoch-str [string!] /local old] [
    old: fb/epoch
    if equal? epoch-str old [exit]
    fb/epoch: epoch-str
    if fb/inertia [exit]
    fb/inertia: true
    either equal? epoch-str inactive-epoch [
        fiber-update-state fb fiber-state/UNLOADING
        fiber-unload fb
    ][
        either equal? old inactive-epoch [
            fiber-update-state fb fiber-state/LOADING
            fiber-reload fb
        ][
            ; 非→非: 先卸载 (内部重入检查会接着 reload)
            fiber-update-state fb fiber-state/UNLOADING
            fiber-unload fb
        ]
    ]
    fb/inertia: none
    ; 执行期间 epoch 可能被副作用改变 → 重入检查
    unless equal? fb/epoch epoch-str [
        fiber-set-epoch fb fb/epoch
    ]
]

; ------------------------------------------------------------
; _reload / _unload
; ------------------------------------------------------------

fiber-reload: func [fb [object!] /local old-epoch result d] [
    old-epoch: fb/epoch
    ; unload 后 store 为 none, 快照前重建
    either fb/store [fb/store: copy fb/store][fb/store: make map! []]
    result: try [fb/runtime/callback/apply fb/ctx fb/config]
    either error? result [
        fb/ctx/logger/error result
        fb/error: result
        fb/epoch: inactive-epoch
        fiber-update-state fb fiber-state/FAILED
        ; 对齐上游: reload 出错 → unload 清理 disposables
        fiber-unload fb
    ][
        either object? result [
            fb/disposables/push result
        ][
            if block? result [
                foreach d result [fb/disposables/push d]
            ]
        ]
        either equal? fb/epoch old-epoch [
            fiber-update-state fb fiber-state/ACTIVE
        ][
            ; 执行期间 epoch 变了 → 继续卸载
            fiber-unload fb
        ]
    ]
]

fiber-unload: func [fb [object!] /local ds d r] [
    ds: fb/disposables/clear
    foreach d ds [
        ; 块尾加 none: dispose 无返回值时 try 结果仍是 none 而非 unset
        r: try [d/dispose  none]
        if error? r [fb/ctx/logger/error r]
    ]
    fb/store: none
    either none? fb/uid [
        fiber-update-state fb fiber-state/DISPOSED
    ][
        either fb/error [
            fiber-update-state fb fiber-state/FAILED
        ][
            either equal? fb/epoch inactive-epoch [
                fiber-update-state fb fiber-state/PENDING
            ][
                ; epoch 非 INACTIVE → 重新加载
                fiber-update-state fb fiber-state/LOADING
                fiber-reload fb
            ]
        ]
    ]
]

; ------------------------------------------------------------
; effect — 作用域清理核心
; execute: function! 立即执行, 返回:
;   - disposer 对象 (object!) → 单个收集
;   - 块 (block of disposer 对象) → 逐个收集 (替代 generator)
;   - none → 无
; 返回 wrapper 对象 (幂等 dispose, 带 meta)
; ------------------------------------------------------------

fiber-effect: func [fb [object!] execute [function!] label [string!] /local local-list children-list result d wrapper] [
    if none? fb/uid [
        return rejoin ["[CordisError:INACTIVE_EFFECT] cannot create effect on inactive context"]
    ]
    local-list: copy []
    children-list: copy []
    ; execute 协议: 必须返回 对象/disposer/块/none (显式值)。
    ; 返回 unset = 协议违规 → "needs a value" 报错 (fail loudly)
    result: try [execute]
    either error? result [
        ; 已收集的逆序清理, 然后传播错误 (上游: dispose() + throw)
        foreach d reverse local-list [d/dispose]
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
        ; 坑点: make object! [label: label] RHS 被自身字段遮蔽 → 创建后赋值
        meta: make object! [label: none  children: copy []]
        dispose: func [] [
            if done [exit]
            done: true
            foreach d reverse items [d/dispose]
            none
        ]
    ]
    wrapper/meta/label: label
    wrapper/meta/children: children-list
    fb/disposables/push wrapper
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
; 断言 / 名称
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
    ; 同步版: 无真实等待; 错误返回错误对象 (上游 throw)
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
    config: resolve-config fb/runtime config
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
; 构造函数
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

; 构造 plugin fiber (registry.plugin 的核心, P5 正式化)
; runtime: [name: string! callback: 对象+apply fibers: DisposableList Config: none]
make-plugin-fiber: func [parent-ctx [object!] config inject-map [map!] runtime [object!] /local fb child-ctx remove-fn ex dispose-fn] [
    fb: make fiber-type []
    ; counter 先增后取 (上游 getter: return ++this._counter)
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
    ; ctx = parent.extend({ fiber: this }) — 注意 make map! 不求值, 必须 compose
    child-ctx: parent-ctx/extend make map! compose [fiber: (fb)]
    fb/ctx: child-ctx

    append all-fibers fb

    ; internal/plugin 事件
    fb/ctx/events/emit 'internal-plugin reduce [fb] fb

    ; 初始 inject 检查
    foreach name keys-of fb/inject [fiber-check-impl fb name]

    ; dispose = parent.fiber.effect(注册到父 fiber)
    ; 函数参数必须 :word 传 (Oldes auto-call)
    ex: func [] [
        ; 插入 runtime.fibers (DisposableList push → remove disposer)
        remove-fn: runtime/fibers/push fb
        fb/config: resolve-config runtime config
        fiber-refresh fb
        ; 返回卸载 disposer (自包含)
        dispose-fn: make object! [
            target-fb: fb
            remover: remove-fn
            dispose: func [] [
                if none? target-fb/uid [exit]
                target-fb/uid: none
                target-fb/ctx/events/emit 'internal-plugin reduce [target-fb] target-fb
                ; registry 清理 (P5 正式化)
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

    ; ex 内已做 fiber-refresh (fiber-effect 立即执行), 此处不再重复
    fb
]
