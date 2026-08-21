# Chapter 09: Deterministic Async Simulation

Cordis heavily relies on asynchronous boundaries. When a plugin provides a service or returns an async disposer, the framework uses Promises to coordinate lifecycle phases. In JavaScript, `await Promise.resolve()` yields control back to the event loop, allowing other synchronous events to be processed before the current execution resumes. This naturally creates "inertia locks": if a dependency disappears while a plugin is still loading, the plugin doesn't immediately unload. It finishes its loading phase, and only then evaluates the new world state.

Rebol 3 does not have a native event loop or microtask queue. If we want to study Cordis's asynchronous convergence behaviors—like inertia locks—we need a deterministic way to simulate time and tasks.

## Building a Virtual Scheduler

Instead of hooking into real system time or threads, we built a virtual task scheduler (`deterministic-scheduler.reb`). It maintains a priority queue of tasks sorted by their target execution time.

When an asynchronous operation needs to happen—like simulating an async load or a delayed unload—we don't block the process. Instead, we register a scheduled task:

```rebol
make-scheduled-value: func [delay [integer!] value /local task] [
    task: make object! [
        task-kind: 'scheduled
        delay: delay
        payload: value
        run: func [] [payload]
    ]
    task
]
```

To move time forward, we call `runtime-step`, which advances the virtual clock and executes any tasks that fall within the time window. This gives us complete, deterministic control over the execution order, ensuring that our tests are completely reproducible.

## Reproducing the Inertia Lock

Let's look at the classic "Inertia Lock 1" scenario (`m1-inertia-lock-1.reb`). We create an asynchronous consumer that takes 1000ms to load.

```rebol
make-async-consumer: func [delay-load [integer!] delay-unload [integer!]] [
    make object! [
        name: "async-consumer"
        inject: ['foo]
        load-delay: delay-load
        unload-delay: delay-unload
        apply: func [ctx [object!] config] [
            make-scheduled-value load-delay make-async-disposer unload-delay
        ]
    ]
]
```

We provide the `foo` dependency and start the consumer. The consumer enters the `LOADING` state and schedules a load task for 1000ms in the future.

At 400ms, while the consumer is still loading, we suddenly dispose of the `foo` dependency!

What happens? The consumer does not immediately abort or crash. It is protected by the inertia lock. It stays in the `LOADING` state until the 1000ms task completes. Once it finishes loading, it realizes its dependency is gone, and transitions into `UNLOADING`.

## Hands-on: Observing the Convergence

Run the test for this chapter to trace the inertia lock:

```bash
cd ch09-deterministic-scheduler/code
bash run.sh
```

You will see the trace snapshots reflecting the state changes:

```text
t0=LOADING
t400=LOADING       # 400ms: dependency removed, still loading!
t800=LOADING       # 800ms: still loading!
t1200=UNLOADING    # 1000ms: load finishes, realizes dependency is missing, unloads
t2200=LOADING      # dependency is provided again, starts reloading
t3200=ACTIVE       # fully loaded
```

By decoupling asynchronous execution from real time, we have built a trusted platform to study Cordis's most complex lifecycle behaviors.

## Against the Source

| Rebol Port | Upstream Cordis (TypeScript) | Why the difference? |
| --- | --- | --- |
| `make-deterministic-scheduler` | `setTimeout`, `Promise` | Rebol lacks a native event loop, requiring manual virtual time stepping to simulate async locks. |
| `runtime-step` | `vi.advanceTimersByTimeAsync` | We control the tick explicitly instead of relying on Vitest's fake timers. |
| `fiber.inertia` (logic flag) | `fiber.inertia` (Promise) | Cordis awaits the inertia Promise. The port uses a synchronous boolean lock and defers continuation to the scheduler. |