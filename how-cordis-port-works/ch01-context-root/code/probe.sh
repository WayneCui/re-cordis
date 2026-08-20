#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
rebol3 -s how-cordis-port-works/ch01-context-root/code/probe-disposables.reb
