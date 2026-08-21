# Chapter 12: Effect Tree Observability

Throughout the previous chapters, we have relied heavily on `fiber/disposables`. When a fiber unloads, it walks backwards through this list and executes cleanup functions. But as plugins inject other plugins, and plugins register events and provide services, this flat list actually represents a deep, hierarchical tree of ownership.

To truly understand the Cordis lifecycle, we need to be able to see this tree.

## Visualizing Ownership

Every time you call an API like `ctx.on`, `ctx.provide`, or `ctx.plugin`, an **Effect** is created. In our port, these effects are wrapper objects that contain a `meta` field.

```rebol
meta: make object! [
    label: none
    owner: none
    disposed: false
    dispose-reason: none
    children: copy []
]
```

Crucially, an effect can own a child Fiber. When you call `ctx.plugin()`, the effect that is registered on the parent fiber is responsible for managing the lifecycle of the newly created child plugin fiber.

We built an inspector (`inspector.reb`) that recursively traverses this relationship: Fiber -> Disposables (Effects) -> Child Fibers.

## Hands-on: Dumping the Tree

Run the scenario for this chapter:

```bash
cd ch12-effect-tree/code
bash run.sh
```

The inspector traverses the runtime and prints the current mounting hierarchy:

```text
root#0 (ACTIVE)
└── [Effect] ctx.plugin()
    └── consumer#1 (ACTIVE)
        ├── [Effect] ctx.on(ping)
        └── [Effect] ctx.provide(foo)
```

This simple ASCII output is incredibly powerful for debugging. It proves visually that:
1. The `root` fiber owns an effect labeled `ctx.plugin()`.
2. That effect owns the `consumer#1` fiber.
3. The `consumer#1` fiber owns two effects: an event listener (`ctx.on(ping)`) and a service provider (`ctx.provide(foo)`).

If `consumer#1` were to fail or be unloaded, the tree clearly shows that its two child effects must be disposed of.

## The Trusted Platform

With the deterministic scheduler, failure recovery, reentrant convergence, and effect tree observability all in place, our Rebol port has successfully replicated the deepest complexities of the Cordis lifecycle. We now have a trusted, isolated, and highly observable platform for experimenting with plugin architectures.

## Against the Source

| Rebol Port | Upstream Cordis (TypeScript) | Why the difference? |
| --- | --- | --- |
| `dump-effect-tree` | No direct upstream equivalent | Built specifically for this port to provide visual proof of correct lifecycle mounting and cleanup, aiding in debugging the absence of native JS memory management. |
| `meta` wrapper | Closure scope | Upstream Cordis relies on JS garbage collection and closure scope to track effect ownership implicitly. The port reifies this into explicit `meta` data structures for traversability. |