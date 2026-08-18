REBOL []

; ============================================================
; utils.reb — cordis core utils 的 Rebol3 移植 (P1)
; 上游: ref/core/utils.ts (278 行)
;
; 保留:
;   - DisposableList   (events/registry 使用: push/delete/clear/length/迭代)
;   - symbols          (service/registry/events/logger 使用, Symbol.for → word!)
;   - compose-error    (错误助手, 同步简化版: 无 JS stack, 附加 context 标签)
;
; 丢弃 (ROADMAP §4.2, traceable Proxy 机制, 仅 JS this 语义需要):
;   createTraceable / withProps / createShadow / createShadowMethod /
;   createCallable / joinPrototype / isConstructor / isObject /
;   getPropertyDescriptor / buildOuterStack
; ============================================================

; ------------------------------------------------------------
; symbols — Symbol.for('cordis.xxx') → word! 常量
; 注意: word! 不能含 '/' (scanner 解析为 path!), 用 '-' 代替
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
; TS 语义:
;   push(value)  → () => map.delete(sn)   卸载函数
;   delete(value) → bool                  按值删除 (身份比较)
;   clear()      → values.reverse()       清空并返回逆序 values
;   length       → map.size
;   迭代          → map.values()
;
; Rebol 落法 (坑点: function! 存容器 auto-eval; make object! 方法
; 不能闭包创建帧局部变量 → disposer 必须自包含):
;   - 实例为 object!, data: map! (sn → value), sn 递增
;   - push 返回 disposer 对象 [list-ref idx dispose], dispose 调
;     list-ref/remove idx — 字段传引用, 不依赖闭包
;   - map! 无 remove-key native → remove/delete 重建 map
;   - 相等性判断一律 equal? (返回 logic!, 不是 string)
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
; compose-error — 错误助手 (同步简化版)
;
; TS 语义: 包裹 callback, 捕获异常, 把调用栈信息附加到错误后重新抛出
; Rebol 落法: 无 stack; try 捕获, 出错返回错误信息字符串 (fail loudly),
;   附加 context 标签便于定位 (如 "plugin foo")
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
