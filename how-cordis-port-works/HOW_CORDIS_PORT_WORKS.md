# How the Cordis Rebol Port Works

If you start from the surface API, this port looks deceptively calm. There is a `make-context`, there are plugins, there are services, and the tests are green. The hard part is hidden a layer below that calm surface. Cordis in TypeScript relies on language features that quietly carry context for you: `Proxy` rewrites property access, decorators attach inject metadata, callable services route through `symbols.invoke`, and async fibers can pause while dependencies change underneath them.

Rebol3 does not give this port any of those gifts. That is why this repository is worth reading as a book. It does not merely restate Cordis in a different syntax. It chooses which behaviors are essential, which JavaScript tricks can be dropped, and which ones must be rebuilt in a plainer form. The result is a smaller system, but also a more exposed one: you can see the trade each file makes.

Two commands to start:

```bash
cd ch01-context-root/code && bash run.sh
./verify-all.sh
```

Source: `../` (**Rebol3**, with a **TypeScript** reference copy in `../ref/core`). The teaching code stays next to the source, and the "Against the source" table at the end of every chapter points back to real paths and symbols.

**Convention:** the chapters do not modify the port itself. They run the existing tests and examples, then ask you to tweak small teaching slices or existing test inputs so that the old mental model breaks in a visible way.

```text
Context root
  -> Events hooks
    -> Fiber state and cleanup
      -> Reflect service lookup
        -> Registry plugin runtime
          -> Isolation and intercept chains
            -> Service and Logger surface
              -> Greeter example
```

That order is the shape of the port. `Context` must build the shared runtime first. `Events` needs a place to register hooks. `Fiber` gives plugins a lifecycle instead of a naked callback. `Reflect` replaces the missing `Proxy` tricks with explicit lookup rules. `Registry` turns a plugin declaration into a live fiber. Isolation and intercept then explain why the same service name can mean different things in different contexts. Only after that do `Service` and `Logger` feel unsurprising.

The book therefore answers reader questions rather than offering a dictionary of files. Why does root construction happen in that order? Why is a fiber more like a lease than a thread? Why does `reflect.reb` own service visibility? Why is `logger.reb` the place where the last big pieces of Cordis's JS ergonomics finally get simplified? By the time we reach the greeter example, the example should feel like assembly, not magic.

## Chapter Map

| Chapter | Slug | Reader question | Core? |
|------|------|------|------|
| 01 | `context-root` | Why does the root context build the world before returning itself? | no |
| 02 | `events-hooks` | How do Cordis events survive after variadics and implicit `this` are removed? | yes |
| 03 | `fiber-epochs` | Why is a plugin fiber a lease that can go pending, active, and back again? | yes |
| 04 | `reflect-without-proxy` | What replaces Cordis's `Proxy` facade when the language cannot trap field access? | yes |
| 05 | `registry-plugins` | How does the registry turn a plugin declaration into a runtime plus one live fiber? | no |
| 06 | `isolation-and-config` | Why are isolation and intercept implemented as explicit chains instead of magic inheritance? | yes |
| 07 | `service-and-logger` | What remains of `Service` and `Logger` after most JS metaprogramming is stripped away? | yes |
| 08 | `greeter-app` | Can the whole port still feel like Cordis in a small runnable app? | no |
| 09 | `deterministic-scheduler` | How do we simulate async locks without a native event loop? | yes |
| 10 | `failure-recovery` | How does a fiber clean up and recover if it fails asynchronously? | yes |
| 11 | `reentrant-convergence` | What happens when dependencies churn while a plugin is already loading? | yes |
| 12 | `effect-tree` | How can we visualize the nested mounting and disposal ownership of a fiber? | no |

## Contents

- [Chapter 01 Why the Root Context Builds in Order](./ch01-context-root/chapter.md)
- [Chapter 02 Events Without Variadics](./ch02-events-hooks/chapter.md)
- [Chapter 03 Fiber as a Lease](./ch03-fiber-epochs/chapter.md)
- [Chapter 04 Reflect Without Proxy](./ch04-reflect-without-proxy/chapter.md)
- [Chapter 05 Registry Turns Plugins into Runtime](./ch05-registry-plugins/chapter.md)
- [Chapter 06 Isolation and Intercept Chains](./ch06-isolation-and-config/chapter.md)
- [Chapter 07 Service and Logger After the Rewrite](./ch07-service-and-logger/chapter.md)
- [Chapter 08 A Small App That Exercises the Port](./ch08-greeter-app/chapter.md)
- [Chapter 09 Deterministic Async Simulation](./ch09-deterministic-scheduler/chapter.md)
- [Chapter 10 Async Failure and Recovery](./ch10-failure-recovery/chapter.md)
- [Chapter 11 Reentrant Epoch Convergence](./ch11-reentrant-convergence/chapter.md)
- [Chapter 12 Effect Tree Observability](./ch12-effect-tree/chapter.md)

## How to Read

If you want the shortest path to the design gamble, read Chapters 03, 04, and 06 first. Those three chapters explain the port's real thesis: keep the reactive plugin lifecycle, but replace implicit runtime magic with explicit data structures. If you are debugging a behavior mismatch against Cordis, Chapter 04 is the best starting point because that is where missing `Proxy` behavior stops being abstract and becomes a concrete lookup rule.

If you mostly care about application code, read Chapters 01, 05, and 08 in order. They show how root setup, plugin registration, and a tiny app fit together without requiring you to absorb every internal detail on the first pass. Chapter 07 is best read after that, because logger naming and service construction only make sense once you know what a caller context means in this port.

## Verify

```bash
./verify-all.sh
# expect: 12 chapter labs OK
```

Lookup tables live in [appendix/quick-reference.md](./appendix/quick-reference.md).
