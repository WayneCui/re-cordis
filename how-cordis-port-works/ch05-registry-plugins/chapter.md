# Chapter 05 Registry Turns Plugins into Runtime

After the previous chapters, `registry.reb` reads almost like the point where the pieces finally agree on a common language. A plugin declaration can be a plain object with `apply`, an `inject` field, and maybe a `Config` hook. The registry's job is to normalize that declaration into a runtime identity and then ask `fiber.reb` to create one live activation.

That split between runtime identity and live activation is easy to miss, but it is the reason duplicate plugin registration behaves sensibly. Cordis does not want one runtime record per call. It wants one runtime record per callback plus many fibers that may be active under that runtime. The Rebol port keeps the same distinction, only in a more literal data structure: `runtimes` is a block of runtime objects, and `find-runtime` matches by callback identity.

## The registry is where plugin declarations stop being syntax

The naive design would let `ctx.plugin` call `plugin/apply` directly and forget everything else. That would work for the first happy-path demo and immediately fail on introspection, duplicate registration, disposal, and any feature that needs a stable runtime identity. `registry.reb` instead builds or reuses a runtime object with `name`, `callback`, `fibers`, and optional `Config`, then resolves `inject` through `resolve-inject`, and finally hands everything to `make-plugin-fiber`.

This is also where the port replaces decorators with data. Upstream Cordis can accumulate inject metadata through `@Inject`. The Rebol version chooses the blunt but readable form: declare `inject: ['foo 'bar]` on the plugin object, or pass a block to the registry's `inject` helper. That is a loss in syntactic polish and a gain in runtime transparency.

The deletion path shows why the runtime/fiber split is worth the extra structure. `delete` removes the runtime and then disposes every fiber registered under it. Without that split, disposal would either miss some activations or need to rediscover them through much weaker bookkeeping.

---

## Experiments

```bash
cd ch05-registry-plugins/code
bash run.sh
```

Expected output:

```text
PASS  object plugin apply runs once
PASS  the same plugin reuses one runtime
PASS  delete drops the runtime size to zero
==== registry-test: 41 passed, 0 failed ====
```

### Try this

1. In `../../registry.reb`, force `plugin` to create a fresh runtime every time and compare the resulting `size` assertions.
2. Change `resolve-inject` so block entries are not normalized with `to-word`, then see how lookups drift when tests pass literal words around.
3. Add a second fiber under the same plugin in `../../test/registry-test.reb` and inspect the runtime's `fibers` list before and after deletion.

### Against the source

| Path | Symbol |
|------|--------|
| `registry.reb` | `make-registry-service`, `resolve-inject`, `plugin`, `delete`, `inject` |
| `ref/core/registry.ts` | `RegistryService`, `Inject.resolve`, `plugin()`, `delete()` |

The port loses decorator machinery, but it keeps the operational idea that a plugin registration becomes one runtime record plus one fiber activation.
