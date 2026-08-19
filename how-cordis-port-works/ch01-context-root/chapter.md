# Chapter 01 Why the Root Context Builds in Order

The first surprise in this port is that `make-context` is not just allocating an object and filling fields later. It is staging a runtime. That sounds like a grand claim for a file that is barely longer than a screenful, but the order matters because every later service assumes the earlier ones already exist. If `reflect` is created before the root fiber exists, there is nowhere to register provided services. If `events` comes before `fiber`, listeners cannot be tied to plugin lifetime. The constructor order is therefore not ceremony. It is the first design decision of the whole port.

In TypeScript, `new Context()` hides some of that staging behind a `Proxy` and behind the `Fiber` constructor that installs root behavior on the fly. The Rebol port makes the sequence visible. [`context.reb`](../../context.reb) creates a child-like object shell with `make-child-ctx`, installs the root fiber with `make-fiber-root`, then builds `reflect`, `registry`, `logger`, and `events`. Only after those pieces are in place does it replace `root/fiber/disposables` with a fresh list, mirroring `context.ts` calling `this.fiber._disposables.clear()`.

## A constructor that is really a protocol

The naive design would be to create a plain context object, then let each service lazily initialize itself when first used. That looks attractive in Rebol because objects are easy to mutate. It fails for the same reason Cordis does not do it in TypeScript: the services depend on each other during construction. `registry.reb` needs `fiber.reb` to create plugin fibers. `reflect.reb` needs a live root fiber so `provide` can register service implementations against the current owner. `events.reb` wants fiber-scoped cleanup through `effect`.

The port keeps that dependency shape but flattens the mechanics. There is no `Proxy` return value here. `context-is` is just a marker check on `ctx-marker`. `extend`, `isolate`, and `intercept` all clone explicit maps or blocks instead of relying on prototype inheritance. That is a recurring theme in this codebase: when the host language cannot smuggle behavior behind field access, the runtime data structures have to become inspectable.

The most important sentence in this file is therefore not a single algorithmic trick. It is the build order comment in [`context.reb`](../../context.reb): fiber, reflect, registry, events, logger. Once you believe that line, the rest of the repository reads in the right direction.

---

## Experiments

```bash
cd ch01-context-root/code
bash run.sh
```

Expected output:

```text
PASS  root fiber uid 0
PASS  reflect is constructed
PASS  registry is constructed
PASS  events is constructed
==== context-test: 16 passed, 0 failed ====
```

### Try this

1. In `../../context.reb`, swap the creation order of `reflect` and `fiber`, then rerun the lab and watch later assumptions break.
2. Comment out the line that resets `ctx/fiber/disposables` and inspect how many construction-time wrappers survive in the root fiber.
3. In `../../test/context-test.reb`, add one more assertion around `intercept-chain` inheritance so you can see the cloned chain directly.

### Against the source

| Path | Symbol |
|------|--------|
| `context.reb` | `make-context`, `make-child-ctx`, `context-is` |
| `ref/core/context.ts` | `Context.constructor`, `extend()`, `isolate()`, `intercept()` |

The port omits the `Proxy` facade from the source and makes the construction protocol explicit instead.
