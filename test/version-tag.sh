#!/usr/bin/env bash
# Release tags are v-prefixed. VERSION=0.1.7 must still download v0.1.7.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scan/trustabl-scan.sh"
fail=0

die() { echo "FAIL: $*" >&2; fail=1; }
pass() { echo "ok: $*"; }

# The production normalizer, minus the "Trustabl version" echo.
snippet() {
  awk '/^# Release tags are v-prefixed/,/^echo "Trustabl version:/' "$SCRIPT" | sed '$d'
}

normalize() {
  local VER="$1"
  VER="$VER" bash -c '
    set -e
    '"$(snippet)"'
    printf "%s" "$VER"
  '
}

got=$(normalize "0.1.7")
if [ "$got" = "v0.1.7" ]; then
  pass "unprefixed pin 0.1.7 becomes v0.1.7"
else
  die "unprefixed pin 0.1.7 became '$got', want v0.1.7"
fi

got=$(normalize "v0.1.7")
if [ "$got" = "v0.1.7" ]; then
  pass "already-prefixed pin is left alone"
else
  die "prefixed pin v0.1.7 became '$got', want v0.1.7"
fi

if [ "$fail" -ne 0 ]; then
  echo "version-tag tests failed" >&2
  exit 1
fi
echo "all version-tag tests passed"
