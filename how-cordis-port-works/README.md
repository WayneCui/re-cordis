# How the Cordis Rebol Port Works

This book walks through the Rebol3 port of Cordis as a real engineering translation, not as a marketing tour. The source tree is small enough to read end to end, but the interesting part is not its size. The interesting part is how a framework that leans on `Proxy`, decorators, callable services, and async fibers gets rewritten for a language that offers none of those mechanisms directly.

We follow one dependency spine from root construction to a runnable example. Each chapter stays close to the real files in [`../`](../), and each chapter has a small runnable lab in its own `code/` directory.

Start here:

```bash
cd how-cordis-port-works/ch01-context-root/code && bash run.sh
cd how-cordis-port-works && ./verify-all.sh
```

The continuous preface and chapter map live in [HOW_CORDIS_PORT_WORKS.md](./HOW_CORDIS_PORT_WORKS.md).
