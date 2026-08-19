# Chapter 06 Isolation and Intercept Chains

The first time you see `ctx.isolate('foo')` in Cordis, it is tempting to read it as a naming trick: the same service name, but in a private room. The upstream implementation makes that room feel almost effortless because prototype inheritance and `Proxy` lookup hide the machinery. The Rebol port cannot hide it, so `context.reb`, `reflect.reb`, and `service.reb` have to show what "private room" really means.

What they show is pleasingly plain. Isolation is a map from service name to label. Intercept is a chain of config maps ordered from the current context back toward the root. Nothing in this design depends on metaprogramming. Everything depends on consistent lookup rules.

## Why explicit chains beat fake inheritance

The naive port would try to recreate JavaScript prototype tricks with ad hoc object copying. That approach usually fails in one of two ways. Either child contexts stop seeing updates from the parent because you copied too much, or they see too much because every isolated context still points to the same service slot. The port's answer is to separate the two concerns.

For service visibility, `reflect.reb` computes an isolate-aware key with `isolate-store-key`. A provider in one label namespace simply does not collide with a provider in another namespace. For configuration overlays, `context.reb` stores an explicit `intercept-chain`, and `service-resolve-config` in `service.reb` walks that chain from root to leaf, then applies `base` and `head` overlays with a defined precedence.

That choice does more than replace missing JS features. It also makes the rules inspectable in tests. You can print `intercept-chain`. You can compare isolate labels directly. You can see that two child contexts sharing the same label share the same visible provider. The runtime becomes easier to teach precisely because less happens behind the reader's back.

## Wrap-up

Isolation and intercept in this port are stacked tracing paper, not sealed rooms. Each new context adds one more visible layer: maybe a new isolate label for one service, maybe one more config map at the head of the intercept chain. The common mistake is to think `extend`, `isolate`, and `intercept` all do the same kind of cloning. They do not. Isolation changes service identity boundaries. Intercept changes config resolution order. Self-check: when two isolated contexts use the same explicit label for `foo`, why do they see the same provider but still keep separate context objects?

---

## Experiments

```bash
cd ch06-isolation-and-config/code
bash run.sh
```

Expected output:

```text
PASS  a private provider wakes only one isolated plugin
PASS  a shared label wakes both isolated plugins
PASS  leaf config overrides root config
==== context-test: 16 passed, 0 failed ====
==== service-test: 16 passed, 0 failed ====
```

### Try this

1. In `../../context.reb`, make `isolate` reuse the old map instead of copying it, then rerun the shared-label and private-label tests.
2. Reverse the merge order inside `service-resolve-config` and watch root config incorrectly override leaf config.
3. Print `ctx/isolate-map` and `ctx/intercept-chain` in a temporary debug run to see how the two mechanisms evolve independently.

### Against the source

| Path | Symbol |
|------|--------|
| `context.reb` | `isolate`, `intercept`, `make-child-ctx` |
| `reflect.reb` | `ctx-isolate-label`, `isolate-store-key`, `reflect-notify` |
| `service.reb` | `service-resolve-config`, `service-filter` |
| `ref/core/context.ts` | `isolate()`, `intercept()` |
| `ref/core/service.ts` | `[symbols.resolveConfig]()` |

This is the chapter where hidden inheritance becomes explicit chain management.
