# Chapter 07 Service and Logger After the Rewrite

By the time we reach `service.reb` and `logger.reb`, most of the dramatic translation work has already happened. That is exactly why these files are interesting. They show what remains once the port has decided which Cordis behaviors are structural and which were mostly JavaScript ergonomics.

`Service` in upstream Cordis is a rich abstraction: constructor-time registration, optional callable behavior via `symbols.invoke`, tracker metadata, and config resolution through intercept chains. The Rebol port keeps the constructor-time registration and the config resolution, but it declines to rebuild the full callable-service illusion. `make-service` injects `ctx` and `name`, then registers the service with `reflect/provide`. `service-resolve-config` still honors the intercept chain and still gives `Config.merge` a chance to take over, but the result is a plain object model instead of a callable proxy-rich one.

## What survives because it matters

The naive rewrite here would be to turn every service into a simple record and call it done. That would miss two things Cordis users actually rely on. First, services must register themselves as owned runtime values so fibers can depend on them. Second, config overlays must still resolve in a predictable order. `service.reb` keeps both.

`logger.reb` is even more revealing because the upstream version is full of conveniences that depend on call-site shadowing. Logger names can come from the explicit argument, from intercept config, or from the current service caller. The Rebol port preserves the first two paths completely and simplifies the last one. `logger-create` resolves `name` from explicit input, then intercept config, then `fiber-name`. The tests are honest about the missing traceable context behavior. Some source scenarios are intentionally out of scope for the synchronous, no-Proxy first version.

That honesty is one of the strengths of the port. It does not pretend the simplified logger is identical to upstream Cordis. It preserves bounded buffers, exporter registration, per-name log levels, and intercept-driven naming, then clearly marks where the host language made the rest too expensive for version one.

## Wrap-up

These two files are the port's final filter for "useful abstraction" versus "host-language flourish." A service still needs a home context, a public name, and config resolution because those define runtime behavior. A logger still needs exporters, levels, and a sensible name source because those affect debugging. The misconception to avoid is thinking the dropped callable tricks were the essence of the feature. They were often a convenience layer around rules that the port still keeps. Self-check: when `logger/create` gets no explicit name, which config chain does it consult before falling back to the current fiber name?

---

## Experiments

```bash
cd ch07-service-and-logger/code
bash run.sh
```

Expected output:

```text
PASS  custom Config.merge is used
PASS  intercept-based logger naming works
PASS  per-name log levels work
==== service-test: 16 passed, 0 failed ====
==== logger-test: 18 passed, 0 failed ====
```

### Try this

1. In `../../logger.reb`, skip `service-resolve-config` inside `logger-create` and watch intercept-based logger names stop working.
2. Change the default log level lookup so it ignores exporter-specific levels, then rerun the filtering tests.
3. In `../../service.reb`, remove the `Config.merge` fast path and compare how custom merged config collapses back to plain last-write-wins behavior.

### Against the source

| Path | Symbol |
|------|--------|
| `service.reb` | `make-service`, `service-resolve-config`, `service-filter` |
| `logger.reb` | `make-logger-service`, `logger-create`, `emit-log` |
| `ref/core/service.ts` | `Service`, `[symbols.resolveConfig]()` |
| `ref/core/logger.ts` | `LoggerService`, `_resolveConfig()`, `Logger` |

The port trims a lot of JS convenience, but it keeps the runtime contract that matters to application code.
