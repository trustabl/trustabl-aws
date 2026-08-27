#!/usr/bin/env bash
# Offline: unresolved or path-breaking VERSION is setup I/O, so exit 2.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STUB="$(mktemp -d)"
LOG="$(mktemp)"
trap 'rm -rf "$STUB" "$LOG"' EXIT

run_scan() {
  set +e
  PATH="$STUB:$PATH" bash "$ROOT/scan/trustabl-scan.sh" >"$LOG" 2>&1
  rc=$?
  set -e
}

expect_exit_2() {
  local why="$1"
  [ "$rc" -eq 2 ] || {
    echo "expected exit 2 ($why), got $rc"
    cat "$LOG"
    exit 1
  }
}

# ---- unresolved latest ----
cat > "$STUB/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"tag_name":""}'
exit 0
EOF
chmod +x "$STUB/curl"

VERSION=latest run_scan
expect_exit_2 "unresolved VERSION"
echo "ok: unresolved VERSION exits 2"

# ---- pin that would leave /releases/download/${VER}/ ----
cat > "$STUB/curl" <<'EOF'
#!/usr/bin/env bash
echo "CURL_RAN $*" >&2
exit 0
EOF
chmod +x "$STUB/curl"

VERSION='v1.0.0/../../../tmp/pwn' run_scan
expect_exit_2 "VERSION path breakout"
if grep -q CURL_RAN "$LOG"; then
  echo "curl must not run when VERSION leaves the download path"
  cat "$LOG"
  exit 1
fi
echo "ok: VERSION with slash exits 2 without fetching"

# ---- tag_name from /releases/latest that would leave the path ----
cat > "$STUB/curl" <<'EOF'
#!/usr/bin/env bash
if printf '%s' "$*" | grep -q 'releases/download'; then
  echo "DOWNLOAD_RAN $*" >&2
  exit 0
fi
echo '{"tag_name":"v1.0.0/../evil"}'
exit 0
EOF
chmod +x "$STUB/curl"

VERSION=latest run_scan
expect_exit_2 "latest tag_name path breakout"
if grep -q DOWNLOAD_RAN "$LOG"; then
  echo "binary fetch must not run when latest tag_name leaves the download path"
  cat "$LOG"
  exit 1
fi
echo "ok: latest tag_name with slash exits 2 without downloading"
