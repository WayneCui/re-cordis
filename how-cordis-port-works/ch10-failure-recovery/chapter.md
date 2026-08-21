# Chapter 10: Async Failure and Recovery

A robust framework must anticipate failure. When a plugin applies synchronously and throws an error, the failure is immediate. But what happens if a plugin throws an error asynchronously, midway through its lifecycle? 

In Cordis, a fiber that fails during its asynchronous `_reload` phase transitions into a special `FAILED` state. More importantly, it must meticulously clean up any side effects it registered before the failure occurred.

## The Danger of Partial Application

Imagine an async plugin that registers an event listener synchronously at the start of its `apply` function, but then schedules an async task that eventually fails:

```rebol
apply: func [ctx [object!] config] [
    ctx/events/on 'ping listener make map! [] ctx
    
    make object! [
        task-kind: 'scheduled
        delay: 1000
        run: func [] [print undefined-async-fail] ; This will crash
    ]
]
```

When this plugin fails at `t=1000`, the `ping` listener is already active. If the framework simply marked the plugin as `FAILED` and walked away, emitting the `ping` event would trigger a listener belonging to a broken plugin, likely causing cascading failures.

## Cleaning Up and FAILED State

To prevent this, the fiber state machine catches the async error in `fiber-complete-reload`. It updates the state to `FAILED` and immediately triggers `fiber-unload`.

```rebol
fiber-complete-reload: func [fb [object!] old-epoch [string!] result /local pending] [
    either error? result [
        fb/ctx/logger/error result
        fb/error: result
        fb/epoch: inactive-epoch
        fiber-update-state fb fiber-state/FAILED
        pending: fiber-unload fb
    ]
    ; ...
]
```

The `fiber-unload` process walks backwards through the `disposables` list, executing the cleanup functions for every effect (like our `ping` listener) that was registered before the crash.

## The Path to Recovery

A `FAILED` fiber is not permanently dead. If the user corrects the configuration and calls `update`, the fiber is given a second chance.

```rebol
fiber-update: func [fb [object!] config no-save [logic!] /local final-w] [
    ; ...
    target-fb/config: args/1
    target-fb/error: none
    fiber-restart target-fb
]
```

The error is cleared, the epoch is reset, and the fiber transitions back to `LOADING`. If the new configuration resolves the issue, the fiber successfully reaches `ACTIVE`.

## Hands-on: Failing and Recovering

Run the scenario for this chapter:

```bash
cd ch10-failure-recovery/code
bash run.sh
```

Watch the trace output closely:
1. The plugin starts `LOADING` and registers `ctx.on(ping)`.
2. At `t=1000`, the async task crashes.
3. The framework catches the error, sets the state to `FAILED`, and crucially, executes `effect.dispose` for the `ping` listener with `reason="unload"`.
4. When we emit `ping`, the listener is not triggered (`hits-after-fail=0`).
5. We update the configuration with `fail: false`. The plugin re-enters `LOADING`, succeeds, and becomes `ACTIVE`.
6. Emitting `ping` now successfully triggers the listener (`hits-after-recovery=1`).

## Against the Source

| Rebol Port | Upstream Cordis (TypeScript) | Why the difference? |
| --- | --- | --- |
| `fiber-complete-reload` error branch | `catch (e)` in `_reload` | Upstream uses `try/catch` around the awaited Promise. Rebol uses `try` blocks evaluating `run-scheduled-task`, handling the error result synchronously. |
| `fiber-unload` on failure | `this._unload()` | Same semantic design: a failed reload must trigger a full unload to reclaim resources. |