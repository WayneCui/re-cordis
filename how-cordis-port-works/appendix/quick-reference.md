# Quick Reference

## One-Line Mental Models

| Chapter | Short model |
|------|------|
| 01 | `make-context` is a construction protocol, not a data constructor. |
| 02 | Events are hook lists plus dispatch modes, with payloads packed into blocks. |
| 03 | A fiber is a revocable lease on plugin effects. |
| 04 | `Reflect` is where missing `Proxy` behavior becomes explicit lookup and provide rules. |
| 05 | The registry owns runtime identity; a fiber is one activation of that identity. |
| 06 | Isolation and intercept are shadow chains you can inspect, not hidden prototype tricks. |
| 07 | `Service` and `Logger` keep the useful surface while dropping most callable magic. |
| 08 | The greeter example proves the port still feels reactive after the simplification. |

## What the Port Keeps

| Behavior | Where |
|------|------|
| Reactive dependency restarts | `fiber.reb`, `reflect.reb` |
| Plugin registration and disposal | `registry.reb`, `fiber.reb` |
| Event modes such as `emit`, `bail`, `waterfall` | `events.reb` |
| Isolated service scopes | `context.reb`, `reflect.reb` |
| Config overlay via intercept chains | `context.reb`, `service.reb`, `logger.reb` |

## What the Port Simplifies

| JavaScript feature | Rebol port decision |
|------|------|
| `Proxy` property interception | Replace with explicit `reflect/get`, `reflect/set`, `reflect/provide` |
| Decorators such as `@Inject` | Replace with declarative `inject` fields on plugin objects |
| Callable services via `symbols.invoke` | Keep only selected explicit helpers such as `logger/create` |
| Async fiber lifecycle | Make the first version fully synchronous |
| Traceable `this` shadowing | Drop it and pass `ctx` explicitly |
