#!/usr/bin/env bash
# Test harness for scan/trustabl-scan.sh.
#
# Each test gets a throwaway workspace holding a locally built "release" — a real
# gzipped tarball containing the stub engine, plus a real checksums.txt over it.
# The stub curl serves that directory by URL basename, so the scanner's download,
# sha256 verification, extraction and invocation all run for real; only the
# network and the engine itself are substituted.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STUB_DIR="$REPO_ROOT/test/stubs"
FIXTURE_DIR="$REPO_ROOT/test/fixtures"
SCANNER="$REPO_ROOT/scan/trustabl-scan.sh"

# The version every test pins, so no test needs the latest-release lookup.
TEST_VERSION="v9.9.9"

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""
FAILURES=()

# sha256_of prints the sha256 of a file. Written portably because the harness has
# to run wherever the scanner does.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# asset_name mirrors the scanner's own OS/arch asset naming, so the release the
# harness builds is the one the scanner asks for.
asset_name() {
  local os arch
  case "$(uname -s)" in
    Linux)  os=linux ;;
    Darwin) os=darwin ;;
    *) echo "unsupported OS $(uname -s)" >&2; return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "unsupported arch $(uname -m)" >&2; return 1 ;;
  esac
  echo "trustabl_${TEST_VERSION#v}_${os}_${arch}.tar.gz"
}

# new_workspace prints the path to a fresh workspace with a built release in
# ./release. Callers cd into it (the scanner writes its artifacts to $PWD).
new_workspace() {
  local ws asset staging
  ws="$(mktemp -d "${TMPDIR:-/tmp}/trustabl-test.XXXXXX")"
  mkdir -p "$ws/release" "$ws/work"

  asset="$(asset_name)"
  staging="$ws/staging"
  mkdir -p "$staging"
  cp "$STUB_DIR/trustabl" "$staging/trustabl"
  chmod +x "$staging/trustabl"
  tar -czf "$ws/release/$asset" -C "$staging" trustabl

  printf '%s  %s\n' "$(sha256_of "$ws/release/$asset")" "$asset" > "$ws/release/checksums.txt"
  printf '{"tag_name":"%s"}\n' "$TEST_VERSION" > "$ws/release/latest"

  echo "$ws"
}

# run_scan <workspace> [KEY=VALUE ...] runs the scanner in $workspace/work with
# the stubs on PATH. It sets SCAN_EXIT and SCAN_OUT; it never aborts the caller.
run_scan() {
  local ws="$1"; shift
  SCAN_OUT="$(
    cd "$ws/work" && env \
      PATH="$STUB_DIR:$PATH" \
      STUB_RELEASE_DIR="$ws/release" \
      STUB_JSON="${STUB_JSON:-$FIXTURE_DIR/findings.json}" \
      STUB_SARIF="${STUB_SARIF:-$FIXTURE_DIR/findings.sarif}" \
      VERSION="$TEST_VERSION" \
      BRANCH="test-branch" \
      "$@" \
      bash "$SCANNER" 2>&1
  )"
  SCAN_EXIT=$?
  return 0
}

# env_var <workspace> <NAME> prints the value the scanner wrote to trustabl.env.
env_var() {
  sed -n "s/^$2=//p" "$1/work/trustabl.env"
}

# ---- assertions ----

fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILURES+=("$CURRENT_TEST: $1")
  printf '  not ok — %s\n' "$1"
}

assert_eq() {
  if [ "$2" = "$3" ]; then return 0; fi
  fail "$1: expected '$3', got '$2'"
}

assert_contains() {
  case "$2" in
    *"$3"*) return 0 ;;
  esac
  fail "$1: output did not contain '$3'"
}

assert_not_contains() {
  case "$2" in
    *"$3"*) fail "$1: output unexpectedly contained '$3'"; return 0 ;;
  esac
}

assert_file() {
  [ -f "$1" ] && return 0
  fail "expected file $1 to exist"
}

# it <name> <function> runs one test and reports the result.
it() {
  CURRENT_TEST="$1"
  TESTS_RUN=$((TESTS_RUN + 1))
  local before=$TESTS_FAILED
  "$2"
  if [ "$TESTS_FAILED" -eq "$before" ]; then printf 'ok %d — %s\n' "$TESTS_RUN" "$1"; else printf 'NOT OK %d — %s\n' "$TESTS_RUN" "$1"; fi
}

summarize() {
  echo
  echo "1..$TESTS_RUN"
  if [ "$TESTS_FAILED" -gt 0 ]; then
    echo "$TESTS_FAILED failure(s):"
    printf '  - %s\n' "${FAILURES[@]}"
    return 1
  fi
  echo "all $TESTS_RUN test(s) passed"
}
