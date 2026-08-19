#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
rebol3 -s test/context-test.reb
rebol3 -s test/service-test.reb
