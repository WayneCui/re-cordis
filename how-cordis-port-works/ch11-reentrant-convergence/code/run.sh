#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
r3 -s test/m1-reentrant-convergence-test.reb
r3 -s test/m1-reentrant-convergence-trace-test.reb