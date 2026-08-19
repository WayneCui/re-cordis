# Chapter 02 Events Without Variadics

Cordis events look simple at the call site. You `on`, `once`, `emit`, `bail`, or `waterfall`, and the framework handles the rest. In TypeScript that simplicity rides on two conveniences: variadic arguments and implicit `this` binding. Rebol gives this port neither convenience in the same shape, so `events.reb` has to answer a precise question: what is the smallest event model that still preserves Cordis behavior?

The answer is not "copy the old API exactly." The answer is "keep the five dispatch modes, but pack payloads into blocks and make listeners explicit objects." That one move removes several host-language fights at once. The port no longer needs arbitrary varargs decoding, and it no longer stores raw `function!` values in maps where Rebol may auto-evaluate them. A listener becomes `object! [call: func [...]]`, and the payload becomes one `block!`.

## The hook list matters more than the syntax sugar

The naive port would focus on syntax first: how do we simulate `emit(name, ...args)`? `events.reb` goes the other way. It preserves the hook structure and the dispatch semantics, then lets the call shape change. `emit`, `parallel`, `serial`, `bail`, and `waterfall` all begin by resolving callbacks through `resolve-callbacks`. That step is the real heart of the file. It decides which hooks are visible under the current filter and whether an internal dispatch event should fire.

That choice turns out to be the same design move we saw in Chapter 01. The port keeps the mechanism and drops the host-language flourishes. `thisArg` is no longer a magical receiver; it is an explicit object passed down the call chain. Internal listener bookkeeping for `internal-update` no longer hides inside function closures; it sits in `fiber/hooks` through `register`.

`waterfall` is where this approach becomes easiest to trust. Instead of leaning on nested JS closures, the Rebol version builds a `next` wrapper object whose `call` method either invokes the next callback or the inner fallback. The result reads more mechanical than the TypeScript version, but the mechanical nature is exactly what makes it portable.

## Wrap-up

Think of `EventsService` in this port as a switchboard with tagged envelopes instead of a function-call trampoline. Each event payload travels as one block, each listener is a callable object with a `call` slot, and each dispatch mode decides when the next envelope is allowed onto the line. The common mistake is to think the port became "less Cordis" because the syntax changed. What actually survives is the more important layer: hook visibility, short-circuit rules, and fiber-scoped cleanup. Self-check: if a listener for `internal-update` is not global, where does the port store it so plugin disposal can remove it automatically?

---

## Experiments

```bash
cd ch02-events-hooks/code
bash run.sh
```

Expected output:

```text
PASS  parallel aggregates two errors
PASS  serial returns the first bailed value
PASS  waterfall composes to 4
==== events-test: 15 passed, 0 failed ====
```

### Try this

1. In `../../events.reb`, change `is-bailed` so `false` counts as a real result, then rerun the lab and watch `bail` stop too early.
2. Remove the `append args next` step in `waterfall` and observe how the chain loses its continuation.
3. Add a new listener in `../../test/events-test.reb` that prepends itself, and confirm the order through a small counter list.

### Against the source

| Path | Symbol |
|------|--------|
| `events.reb` | `make-events-service`, `resolve-callbacks`, `emit`, `waterfall`, `register` |
| `ref/core/events.ts` | `EventsService._resolve`, `parallel()`, `bail()`, `waterfall()` |

The surface syntax is different, but the dispatch modes and lifecycle coupling stay recognizably Cordis.
