REBOL []

; ============================================================
; thenable.reb - settle protocol for values that are not ready yet
;
; Why this file exists:
;   Rebol3 has no Promise. Cordis waterfall listeners in the harness
;   await next(). This module is the smallest stand-in: a value is either
;   ready or it has waiters. The deterministic scheduler (optional) is how
;   tests advance time; the kernel does not own I/O.
;
; Invariants:
;   - resolve is idempotent
;   - resolving with another thenable flattens (no nested thenable values)
;   - waiters are objects with call: func [value] (functions cannot live in blocks)
;   - thenable-wait on a plain value returns that value
; ============================================================

thenable?: func [value] [
    to-logic all [
        object? value
        equal? select value 'kind 'thenable
        logic? select value 'pending
        in value 'then
        in value 'resolve
    ]
]

make-thenable: func [/local t] [
    t: make object! [
        kind: 'thenable
        pending: true
        value: none
        waiters: copy []

        resolve: func [v /local waiter w] [
            if not pending [return none]
            if thenable? v [
                waiter: make object! [
                    dest: none
                    call: func [inner] [dest/resolve inner]
                ]
                waiter/dest: self
                v/then waiter
                return none
            ]
            pending: false
            value: v
            foreach w copy waiters [w/call v]
            clear waiters
            none
        ]

        then: func [ok-cb [object!]] [
            either pending [
                append waiters ok-cb
            ][
                ok-cb/call value
            ]
            self
        ]
    ]
    t
]

; Lift a plain value into an already-resolved thenable. Thenables pass through.
thenable-of: func [value /local t] [
    if thenable? value [return value]
    t: make-thenable
    t/resolve value
    t
]

; If value is a thenable, map its settlement; otherwise call mapper now.
; mapper is an object with call: func [value]
thenable-map: func [value mapper [object!] /local out waiter] [
    either thenable? value [
        out: make-thenable
        waiter: make object! [
            dest: out
            map-ref: mapper
            call: func [v] [dest/resolve map-ref/call v]
        ]
        value/then waiter
        out
    ][
        mapper/call value
    ]
]

; Pump scheduler until value is ready, or return it as-is.
thenable-wait: func [value scheduler [object! none!] /local n item] [
    n: 0
    while [all [thenable? value  value/pending  n < 10000]] [
        either all [object? scheduler  scheduler/pending?] [
            item: scheduler/next-item
            unless item [break]
            scheduler/run-until item/due
        ][
            break
        ]
        n: n + 1
    ]
    either all [thenable? value  not value/pending] [value/value] [value]
]

; Resolve after `ms` of scheduler time. Does not touch the wall clock.
thenable-delay: func [scheduler [object!] ms [integer!] value /local t task] [
    t: make-thenable
    task: make object! [
        task-kind: 'scheduled
        delay: ms
        target: t
        payload: value
        run: func [] [target/resolve payload]
    ]
    scheduler/schedule ms task
    t
]
