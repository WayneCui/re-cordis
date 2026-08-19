# Chapter 08 A Small App That Exercises the Port

After seven chapters of internals, the only fair question is whether the port still feels like Cordis when you try to use it. `examples/greeter.reb` is small, but it is not decorative. It covers the path this book has been building toward: create a context, register a provider-like plugin, inject a dependent plugin, emit an event, update configuration, dispose the runtime, then repeat the same idea inside isolated rooms.

This example works because the earlier simplifications were surgical rather than random. The app does not need `Proxy` field traps to be reactive. It needs `reflect/provide`, `registry/plugin`, fiber-scoped effects, and event hooks that disappear on disposal. The example therefore becomes a good integration test for the book's thesis: if the internals were simplified in the right places, the application story should still read naturally.

## Assembly instead of magic

The provider plugin in `examples/greeter.reb` registers a service named `greeter` through `make-service`. The dependent `receptionist` plugin injects `greeter`, subscribes to `guest-arrived`, and uses a fiber-scoped effect to close the desk cleanly on disposal. Then the example updates the provider config from `"Hello"` to `"Hi"` and lets the runtime show what that means: provider unload, consumer pending or reload, then new output under the new epoch.

The second scene proves that isolation is not a chapter-only concept. Three contexts register the same `iso-guest` plugin under different rooms. Each room waits until its own `greeter` provider appears. That is the whole port in miniature: reactive start conditions, explicit ownership, and isolate-aware visibility.

The best part of this example is that it does not ask the reader to trust the abstraction. It prints what happens. A small system that says "greeter-up", "served:Hi Ada", and "desk-closed" at the right moments is often a better teacher than one more architectural summary.

---

## Experiments

```bash
cd ch08-greeter-app/code
bash run.sh
```

Expected output:

```text
=== scene 1: greeter + receptionist ===
greeter-up Hello
served:Hello Ada
--- update prefix Hello -> Hi ---
served:Hi Ada
=== scene 2: isolate rooms ===
all pending (no greeter yet)
```

### Try this

1. In `../../examples/greeter.reb`, remove the `inject: ['greeter]` declaration from `receptionist` and observe how the example stops expressing the dependency contract clearly.
2. Give `ctx-a` and `ctx-b` the same explicit isolate label and compare the room startup sequence with the current private-room behavior.
3. Add one more event listener under `receptionist` and confirm that disposal removes both listeners when the plugin fiber is closed.

### Against the source

| Path | Symbol |
|------|--------|
| `examples/greeter.reb` | `greeter-plugin`, `receptionist`, `iso-guest` |
| `context.reb` | `make-context`, `isolate` |
| `registry.reb` | `plugin` |
| `fiber.reb` | `update`, `dispose` |

What looked like separate mechanisms in earlier chapters now shows up as one coherent runtime loop.
