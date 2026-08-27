#!/usr/bin/env bash
# Prove the checkout's current branch is what gets reported — not "main exists".
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scan/trustabl-scan.sh"
fail=0

die() { echo "FAIL: $*" >&2; fail=1; }
pass() { echo "ok: $*"; }

# The production block, minus the "scanning branch" echo, so we can read $BR.
snippet() {
  awk '/^# ---- resolve branch label ----/,/^echo "Trustabl scanning branch:/' "$SCRIPT" | sed '$d'
}

label() {
  local target="$1"
  BRANCH= CODEBUILD_WEBHOOK_HEAD_REF= TARGET="$target" bash -c '
    set -e
    BRANCH_INPUT="${BRANCH:-}"
    '"$(snippet)"'
    printf "%s" "$BR"
  '
}

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
git -C "$workdir" init -b main >/dev/null
git -C "$workdir" config user.email "test@example.com"
git -C "$workdir" config user.name "test"
echo seed > "$workdir/f"
git -C "$workdir" add f
git -C "$workdir" commit -qm seed

git -C "$workdir" checkout -b feature >/dev/null 2>&1
echo feat >> "$workdir/f"
git -C "$workdir" add f
git -C "$workdir" commit -qm feat

got=$(label "$workdir")
if [ "$got" = "feature" ]; then
  pass "checked-out feature branch reports feature (not main)"
else
  die "checked-out feature branch reported '$got', want feature"
fi

git -C "$workdir" checkout main >/dev/null 2>&1
got=$(label "$workdir")
if [ "$got" = "main" ]; then
  pass "checked-out main reports main"
else
  die "checked-out main reported '$got', want main"
fi

# Detached at main's tip (CodeBuild's usual checkout) should still say main.
git -C "$workdir" checkout --detach >/dev/null 2>&1
got=$(label "$workdir")
if [ "$got" = "main" ]; then
  pass "detached HEAD at main tip reports main"
else
  die "detached HEAD at main tip reported '$got', want main"
fi

# Detached at the feature commit must not fall back to main.
git -C "$workdir" checkout --detach feature >/dev/null 2>&1
got=$(label "$workdir")
if [ "$got" = "unknown" ]; then
  pass "detached HEAD at a feature commit does not report main"
else
  die "detached HEAD at a feature commit reported '$got', want unknown"
fi

if [ "$fail" -ne 0 ]; then
  echo "branch-label tests failed" >&2
  exit 1
fi
echo "all branch-label tests passed"
