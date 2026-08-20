REBOL []
; Probe root fiber disposables after make-context (ch01 experiment 2)
change-dir %../../../
do %context.reb
do %logger.reb

c: make-context
print ["disposables length:" c/fiber/disposables/length]
foreach eff c/fiber/get-effects [
    print ["  effect label:" eff/label]
]
