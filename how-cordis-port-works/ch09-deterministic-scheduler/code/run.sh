#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
r3 -s test/m1-inertia-test.reb
r3 -s test/m1-inertia-trace-test.reb