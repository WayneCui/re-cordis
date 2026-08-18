REBOL []

; ============================================================
; logger.reb — cordis LoggerService 的 Rebol3 移植 (P8)
; 上游: ref/core/logger.ts (240 行) + logger.spec.ts (可同步部分)
;
; 语义映射:
;   - LoggerService (extends Service) → make-logger-service (P7 make-service 注册 'logger)
;   - createCallable → logger 服务对象方法 error/info/warn/debug
;     + create name → logger 实例 (上游 ctx.logger('name'))
;   - name 解析 (上游 [symbols.invoke]): 显式 name > intercept('logger').name
;     > fiber name (fiber-name, 默认 "root")
;   - level 过滤: exporter.levels[name] ?? levels.default ?? logger.level ?? INFO(2)
;   - exporter: 注册返回 disposer; 默认 exporter 写 bounded buffer
;   - message: [sn ts name type level args fiber] (ts 同步版固定 0)
;
; 简化 (ROADMAP §7):
;   - 无 traceable 上下文穿透 → 服务内调用 name 一律走解析链 (不区分调用者 fiber)
;   - 无 formatter/%s 占位符替换 → args 原样存 (测试断言 args/1)
;   - 无 WeakRef → fiber-ref 直接引用或 none
; ============================================================

do %./utils.reb
do %./events.reb
do %./fiber.reb
do %./reflect.reb
do %./registry.reb
do %./context.reb
do %./service.reb

; ------------------------------------------------------------
; level 常量 (上游 LoggerLevel)
; ------------------------------------------------------------

logger-level: context [
    ERROR: 0
    WARN: 1
    INFO: 2
    DEBUG: 3
]

; type word → level 数字 (select 块内值都是字面量 → case 求值)
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
; emit-log — 核心: level 过滤 + 分发到所有 exporter
; ------------------------------------------------------------

emit-log: func [lg [object!] type [word!] args [block!] /local svc sn msg lvl sn-v type-v args-v] [
    svc: lg/svc-ref
    sn: svc/sn-message + 1
    svc/sn-message: sn
    lvl: logger-type-level type
    ; 坑点: make object! [sn: sn] RHS 被自身字段遮蔽 → 前缀变量
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
        ; levels 键统一 word (lg/name 是 string → to-word 匹配)
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
; logger 实例工厂 (上游 Logger 类)
; name: 显式 > intercept('logger').name > fiber-name
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

; 服务对象快捷方法 (上游 ctx.logger.info(...))
emit-svc: func [svc [object!] type [word!] msg] [
    emit-log logger-create svc none type reduce [msg]
]

; ------------------------------------------------------------
; LoggerService 工厂
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

        ; exporter 注册 → 返回 disposer (自包含)
        ; 坑点: make object! [svc-ref: self] 里 self = 新对象自身 → 帧局部捕获
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

        ; 便捷日志方法 (name 走解析链)
        error: func [msg] [emit-svc self 'error msg]
        warn: func [msg] [emit-svc self 'warn msg]
        info: func [msg] [emit-svc self 'info msg]
        debug: func [msg] [emit-svc self 'debug msg]

        ; 命名 logger 实例
        create: func [name [word! string!]] [logger-create self to-word name]
    ]
    make-service root-ctx 'logger svc
    ; 默认 exporter: bounded buffer (上游构造时注册)
    ; 坑点: 方法不能闭包帧局部 svc → svc-ref 字段自包含
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
