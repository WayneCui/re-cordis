# Chapter 04 Reflect Without Proxy

Sooner or later every reader of Cordis reaches the same realization: a great deal of its ergonomics is really `ReflectService.handler`. In the upstream code, a `Proxy` makes `ctx.foo` mean "find the visible service named `foo`, maybe walk the fiber chain, maybe trigger internal hooks, maybe throw a tailored error." The Rebol port has no such trapdoor. That means `reflect.reb` has to answer the hardest translation question in the repository: what behavior is essential enough to preserve once direct property interception is gone?

The port keeps the service semantics and drops the syntax illusion. You do not get a magical property space. You get explicit methods: `get`, `set`, `provide`, `accessor`, `mixin`, and `notify`. That sounds like a regression until you trace what those methods actually preserve. Visibility still depends on the current isolate label. Providers still belong to a specific fiber. Dependency notifications still trigger refresh on consumers that inject the changed service.

## Why explicit lookup wins here

A naive port might try to emulate Cordis's `Proxy` behavior with code generation tricks or by overloading object fields until every service became a real slot on the context object. That would make simple demos look closer to the upstream API, but it would blur the ownership rules that matter most. `reflect.reb` stays honest instead. `isolate-store-key` turns a pair of values, current isolate label and service name, into one storage key. `provide` writes an implementation object into `store`, ties it to the current fiber, and returns a disposer that removes it again. `notify` then scans all fibers to see which consumers care about the changed names under the same isolate label.

This is also where the port's simplification becomes clearest. Upstream Cordis can walk from a shadow context through parent fibers when a service is not directly present. The Rebol version chooses a plainer boundary: explicit act-ctx parameters and direct store lookup. The result is less magical, but it makes missing behavior visible in the code instead of smearing it across host-language metaprogramming.

The error discipline matters too. The source throws messages such as `cannot set property "foo" without provide`. The port preserves that style even when the implementation is different. That continuity is useful because it lets the tests express the same contract while the runtime model changes under the hood.

## Wrap-up

`Reflect` in this port is a customs desk. Every service must be declared, tagged with an isolate label, and tied to the fiber that currently owns it before it can cross into general visibility. The tempting misunderstanding is to think `Reflect` is only a storage map because the `Proxy` is gone. It is not. The map is the easy part. The real job is deciding who may see which implementation and which waiting fibers must be told when that answer changes. Self-check: why does `notify` compare isolate labels before refreshing an injected fiber?

---

## Experiments

```bash
cd ch04-reflect-without-proxy/code
bash run.sh
```

Expected output:

```text
PASS  get returns the provided value
PASS  provide wakes the dependent fiber
PASS  internal-service fires once
==== reflect-test: 28 passed, 0 failed ====
```

### Try this

1. In `../../reflect.reb`, temporarily ignore `ctx-isolate-label` inside `reflect-notify` and watch isolated contexts start reacting to each other's providers.
2. Change `set` so it skips the fiber ownership check, then rerun the tests that guard against multiple fibers writing the same service.
3. Add a second `provide` call for the same name and isolate label in `../../test/reflect-test.reb` to see the duplicate-registration path explicitly.

### Against the source

| Path | Symbol |
|------|--------|
| `reflect.reb` | `make-reflect-service`, `isolate-store-key`, `provide`, `notify`, `mixin` |
| `ref/core/reflect.ts` | `ReflectService.handler`, `provide()`, `notify()`, `mixin()` |

This chapter is where the port most openly trades API magic for explicit runtime data.
