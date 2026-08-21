# Chapter 11: Reentrant Epoch Convergence

The true test of a reactive lifecycle is how it handles rapid, overlapping changes. What happens if the ground shifts while a plugin is in the middle of getting up?

Consider this scenario:
1. A **Provider** starts asynchronously loading.
2. A **Consumer** starts asynchronously loading, depending on the Provider.
3. Before the Consumer finishes loading, the Provider updates its configuration, forcing the Provider to reload and emitting a new dependency value.

This is **reentrant epoch churn**. The Consumer is already busy loading the *old* configuration, but a *new* configuration has just arrived.

## Epoch Chasing

Cordis manages this chaos using **Epochs**. An epoch is a string representing the current state of a fiber's dependencies. Whenever a dependency changes, the fiber's epoch is updated.

When a fiber starts an asynchronous reload, it remembers the epoch it started with (`old-epoch`). Because of the inertia lock, any new updates that arrive during the reload do not interrupt the running task. The task is allowed to finish.

However, when the task completes, `fiber-complete-reload` performs a critical check:

```rebol
fiber-complete-reload: func [fb [object!] old-epoch [string!] result /local pending] [
    ; ...
    either equal? fb/epoch old-epoch [
        fiber-update-state fb fiber-state/ACTIVE
        pending: false
    ][
        fiber-update-state fb fiber-state/UNLOADING
        pending: fiber-unload fb
    ]
    ; ...
]
```

If `fb/epoch` (the current epoch) does not equal `old-epoch` (the epoch we started with), it means the world changed while we were loading. The fiber realizes its newly loaded state is already stale. It refuses to become `ACTIVE`. Instead, it immediately transitions to `UNLOADING` to tear down the stale state, and then loops back to `LOADING` to chase the new epoch.

## Hands-on: Surviving the Churn

Run the scenario for this chapter:

```bash
cd ch11-reentrant-convergence/code
bash run.sh
```

In this test, we deliberately update the provider's configuration while the consumer is still pending/loading.

1. `t=1000`: The provider finishes its initial load. The consumer activates and sees the initial value (`[1 "old"]`).
2. We immediately update the provider and the consumer. The provider re-enters `LOADING`. The consumer drops to `PENDING` because its dependency is churning.
3. The system does not eagerly rerun the consumer while the provider is still unstable.
4. `t=2000`: The provider converges to `ACTIVE` with its new configuration. The consumer finally activates and sees the final value (`[2 "new"]`).

The system seamlessly skipped the intermediate, unstable states and converged on the final truth.

## Against the Source

| Rebol Port | Upstream Cordis (TypeScript) | Why the difference? |
| --- | --- | --- |
| `fb/epoch` vs `old-epoch` | `if (this.epoch !== epoch) return this.inertia = this._unload()` | Same semantic mechanism: comparing the starting epoch against the current epoch to detect reentrant churn and force convergence. |
| Deduping disposables | `map.delete(sn)` / `map.set` | Upstream uses unique symbol keys or closures. Rebol requires explicit deduplication (`fiber-has-disposable?`) to prevent async reload loops from double-registering the same effect wrapper. |