#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
rebol3 -s how-cordis-port-works/ch03-fiber-epochs/code/probe-epoch.reb
