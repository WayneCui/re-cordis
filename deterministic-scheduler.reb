REBOL []

; ============================================================
; deterministic-scheduler.reb - explicit step/tick scheduler for M1
;
; Task protocol:
;   object! with:
;     task-kind: 'scheduled
;     delay: integer!
;     run: func [] [...]
; ============================================================

scheduled-task?: func [value] [
    all [
        object? value
        equal? select value 'task-kind 'scheduled
        integer? select value 'delay
        in value 'run
    ]
]

make-scheduled-value: func [delay [integer!] value /local task] [
    task: make object! [
        task-kind: 'scheduled
        delay: 0
        payload: none
        run: func [] [payload]
    ]
    task/delay: delay
    task/payload: value
    task
]

scheduler-remove-item: func [items [block!] target [object!] /local i] [
    i: 1
    while [i <= length? items] [
        if same? pick items i target [
            remove at items i
            return items
        ]
        i: i + 1
    ]
    items
]

make-deterministic-scheduler: func [/local scheduler] [
    scheduler: make object! [
        now: 0
        serial: 0
        queue: copy []

        schedule: func [delay [integer!] task [object!] /local item] [
            serial: serial + 1
            item: make object! [
                due: 0
                order: 0
                task-ref: none
                done: false
            ]
            item/due: now + delay
            item/order: serial
            item/task-ref: task
            append queue item
            item
        ]

        next-item: func [/local best item] [
            best: none
            foreach item queue [
                if any [
                    none? best
                    item/due < best/due
                    all [equal? item/due best/due  item/order < best/order]
                ] [best: item]
            ]
            best
        ]

        run-until: func [target [integer!] /local item result] [
            while [all [item: next-item  item/due <= target]] [
                scheduler-remove-item queue item
                now: item/due
                item/done: true
                result: try [item/task-ref/run]
                if error? result [print result]
            ]
            now: target
            none
        ]

        step: func [delta [integer!]] [
            run-until now + delta
        ]

        flush: func [] [
            while [not empty? queue] [
                item: next-item
                run-until item/due
            ]
            none
        ]

        pending?: does [not empty? queue]
    ]
    scheduler
]
