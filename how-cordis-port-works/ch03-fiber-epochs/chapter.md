# Chapter 03 Fiber as a Lease

If one file deserves the phrase "this is the soul of the system," it is `fiber.reb`. Everything else in the port can be simplified more aggressively than the upstream Cordis source. This file cannot. A plugin is not just a callback to run once. It is a piece of behavior that becomes active only while its dependencies are available, cleans up in reverse order, and may come back later when the dependency epoch changes again.

That is why the file is built around a reactive lease, not around a thread. The word "fiber" can mislead readers coming from async runtimes, but the implementation here makes the intended meaning plain. A fiber owns effects while it is active. Lose the required service, and the lease is revoked. Provide the service again, and the same plugin may reload under a new epoch.

## Why a plain callback lifecycle fails

The naive port would let `registry.reb` call `plugin/apply`, keep the returned disposer, and call it when someone asks for disposal. That model breaks the moment an injected dependency appears late or disappears temporarily. The consumer plugin would either start too early and crash on missing services, or never restart after a provider comes back.

`fiber.reb` preserves the upstream answer. Each fiber keeps an `inject` map, a `store` of resolved implementations, an `epoch` string, and a state machine with `PENDING`, `LOADING`, `ACTIVE`, `FAILED`, `DISPOSED`, and `UNLOADING`. `fiber-refresh` recomputes the visible implementations and concatenates provider `uid`s into an epoch string. If any required service is absent, the epoch becomes `inactive-epoch`. `fiber-set-epoch` then decides whether the plugin should reload or unload.

The most revealing detail is not the epoch string itself but the cleanup rule in `fiber-effect`. Effects collect disposers into a `DisposableList`, and unloading runs them in reverse order. The roadmap calls out that this LIFO order surprised the port once and corrected the test rather than the code. That is a good sign. It means the port is following source behavior even when the behavior is not what instinct suggests.

## Wrap-up

Think of a fiber here as a signed room reservation, not as a worker. The reservation lists what services must exist, and the epoch is the list of provider identities attached to that reservation. If one provider disappears, the reservation is no longer valid, so the room is cleared in reverse setup order. The usual misconception is to treat a fiber as "the plugin object itself." It is narrower than that. It is one activation of the plugin under one dependency snapshot. Self-check: when `foo` disappears and then returns, which function recomputes whether the fiber should stay pending or reload?

---

## Experiments

> **Day 3 reading guide**: [fiber-reading-guide-zh-CN.md](../fiber-reading-guide-zh-CN.md) (function-by-function, line ranges, test anchors)

```bash
cd ch03-fiber-epochs/code
bash run.sh
bash probe-epoch.sh   # watch epoch/state transitions (labs 2/3)
```

Expected output:

```text
PASS  starts after provide
PASS  returns to pending when the dependency disappears
PASS  disposer runs once
==== fiber-test: 55 passed, 0 failed ====
```

### Try this

1. In `../../fiber.reb`, change the unload cleanup order so disposers run in insertion order, then rerun the tests that cover nested cleanup.
2. Print the computed `epoch-str` inside `fiber-refresh` and watch it change as providers appear, disappear, and return.
3. In `../../test/fiber-test.reb`, add a second injected dependency to one plugin and observe how the epoch becomes a concatenation of multiple provider ids.

### Against the source

| Path | Symbol |
|------|--------|
| `fiber.reb` | `fiber-effect`, `fiber-refresh`, `fiber-set-epoch`, `make-plugin-fiber` |
| `ref/core/fiber.ts` | `Fiber`, `_checkImpl()`, `_refresh()`, `_setEpoch()` |

The port drops async machinery, but it keeps the crucial idea that plugin liveness is derived from dependency visibility, not from one-time startup.
