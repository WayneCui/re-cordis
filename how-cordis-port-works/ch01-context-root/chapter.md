# Chapter 01 Why the Root Context Builds in Order

The first surprise in this port is that `make-context` is not just allocating an object and filling fields later. It is staging a runtime. That sounds like a grand claim for a file that is barely longer than a screenful, but the order matters because every later service assumes the earlier ones already exist. If `reflect` is created before the root fiber exists, there is nowhere to register provided services. If `events` comes before `fiber`, listeners cannot be tied to plugin lifetime. The constructor order is therefore not ceremony. It is the first design decision of the whole port.

In TypeScript, `new Context()` hides some of that staging behind a `Proxy` and behind the `Fiber` constructor that installs root behavior on the fly. The Rebol port makes the sequence visible. [`context.reb`](../../context.reb) creates a child-like object shell with `make-child-ctx`, installs the root fiber with `make-fiber-root`, then builds `reflect`, `registry`, `logger`, and `events`. Only after those pieces are in place does it replace `root/fiber/disposables` with a fresh list, mirroring `context.ts` calling `this.fiber._disposables.clear()`.

## A constructor that is really a protocol

The naive design would be to create a plain context object, then let each service lazily initialize itself when first used. That looks attractive in Rebol because objects are easy to mutate. It fails for the same reason Cordis does not do it in TypeScript: the services depend on each other during construction. `registry.reb` needs `fiber.reb` to create plugin fibers. `reflect.reb` needs a live root fiber so `provide` can register service implementations against the current owner. `events.reb` wants fiber-scoped cleanup through `effect`.

The port keeps that dependency shape but flattens the mechanics. There is no `Proxy` return value here. `context-is` is just a marker check on `ctx-marker`. `extend`, `isolate`, and `intercept` all clone explicit maps or blocks instead of relying on prototype inheritance. That is a recurring theme in this codebase: when the host language cannot smuggle behavior behind field access, the runtime data structures have to become inspectable.

The most important sentence in this file is therefore not a single algorithmic trick. It is the build order comment in [`context.reb`](../../context.reb): fiber, reflect, registry, logger, events. Once you believe that line, the rest of the repository reads in the right direction.

---

## Experiments

```bash
cd ch01-context-root/code
bash run.sh
```

Expected output (tail):

```text
==== context-test: 22 passed, 0 failed ====
```

### Try this

#### 1. Swap `reflect` and `fiber` creation order

In [`context.reb`](../../context.reb) `make-context`, move `make-reflect-service` before `make-fiber-root`, then rerun `bash run.sh`.

**Expected: all tests still pass.** This is not a doc bug. The lab teaches two kinds of dependency:

- **Construction-time**: a service needs `ctx/fiber` while `make-*-service` runs (`logger` self-registers via `reflect/provide`; `events` registers internal listeners via `fiber/effect`).
- **Run-time**: `make-reflect-service` only allocates methods; `provide`/`set` touch `ctx/fiber` later. Tests call `provide` only after `make-context` returns.

Swapping only `reflect` and `fiber` is a weak violation: both exist before any test runs.

To break construction assumptions, move `logger` or `events` before `ctx/fiber: rf` (without assigning fiber first), then rerun:

```text
** Script error: cannot access fiber in path act-ctx/fiber/effect
** Where: provide make-service make-logger-service make-context
```

#### 2. Comment out the `disposables` reset

Comment out `ctx/fiber/disposables: make-disposable-list` at the end of `make-context`, then run:

```bash
bash probe.sh
```

**Expected: `context-test` still 22 passed** (no assertion on disposables), but probe output changes:

| Config | `disposables length` | effect labels |
|--------|---------------------|---------------|
| Normal (with reset) | 0 | (none) |
| Reset commented out | 2 | `ctx.on(internal-listener)`, `ctx.on(internal-update)` |

Those two wrappers come from `make-events-service` calling `svc/on` twice during construction. The reset line drops them, mirroring TypeScript `this.fiber._disposables.clear()`.

#### 3. Inspect `intercept-chain` inheritance

[`test/context-test.reb`](../../test/context-test.reb) Test 5 already asserts `intercept declaration applied` and `intercept chain inherited`. After `bash run.sh` passes, you can temporarily print the cloned chain in Test 5:

```rebol
print mold select int5 'intercept-chain
```

After `extend`, the child ctx should inherit the same `[leaf ... root]` chain; lookup walks from the head and uses the first matching map.

### Against the source

| Path | Symbol |
|------|--------|
| `context.reb` | `make-context`, `make-child-ctx`, `context-is` |
| `ref/core/context.ts` | `Context.constructor`, `extend()`, `isolate()`, `intercept()` |

The port omits the `Proxy` facade from the source and makes the construction protocol explicit instead.
