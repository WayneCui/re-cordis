#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
r3 -s test/m1-failure-recovery-test.reb
r3 -s test/m1-failure-recovery-trace-test.reb