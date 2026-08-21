# How the Cordis Rebol Port Works

12 executable chapters that prove the Rebol3 port of Cordis against the original TypeScript design constraints.

This book walks through the Rebol3 port of Cordis as a real engineering translation, not as a marketing tour. The source tree is small enough to read end to end, but the interesting part is not its size. The interesting part is how a framework that leans on `Proxy`, decorators, callable services, and async fibers gets rewritten for a language that offers none of those mechanisms directly.

We follow one dependency spine from root construction to a runnable example. Each chapter stays close to the real files in [`../`](../), and each chapter has a small runnable lab in its own `code/` directory.

Start here:

```bash
cd how-cordis-port-works/ch01-context-root/code && bash run.sh
cd how-cordis-port-works && ./verify-all.sh
```

The continuous preface and chapter map live in [HOW_CORDIS_PORT_WORKS.md](./HOW_CORDIS_PORT_WORKS.md).

- [Chapter 01 Why the Root Context Builds in Order](HOW_CORDIS_PORT_WORKS.md#chapter-map)
- [Chapter 02 Events Without Variadics](HOW_CORDIS_PORT_WORKS.md#chapter-map)
- [Chapter 03 Fiber as a Lease](HOW_CORDIS_PORT_WORKS.md#chapter-map)
- [Chapter 04 Reflect Without Proxy](HOW_CORDIS_PORT_WORKS.md#chapter-map)
- [Chapter 05 Registry Turns Plugins into Runtime](HOW_CORDIS_PORT_WORKS.md#chapter-map)
- [Chapter 06 Isolation and Intercept Chains](HOW_CORDIS_PORT_WORKS.md#chapter-map)
- [Chapter 07 Service and Logger After the Rewrite](HOW_CORDIS_PORT_WORKS.md#chapter-map)
- [Chapter 08 A Small App That Exercises the Port](HOW_CORDIS_PORT_WORKS.md#chapter-map)
- [Chapter 09 Deterministic Async Simulation](HOW_CORDIS_PORT_WORKS.md#chapter-map)
- [Chapter 10 Async Failure and Recovery](HOW_CORDIS_PORT_WORKS.md#chapter-map)
- [Chapter 11 Reentrant Epoch Convergence](HOW_CORDIS_PORT_WORKS.md#chapter-map)
- [Chapter 12 Effect Tree Observability](HOW_CORDIS_PORT_WORKS.md#chapter-map)
