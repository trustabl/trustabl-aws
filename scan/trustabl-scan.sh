#!/usr/bin/env bash
# Trustabl — AWS scanner (shared by the CodePipeline buildspec and the
# CodeCatalyst workflow).
#
# Downloads the upstream `trustabl` release binary (sha256-verified against the
# release checksums.txt), scans the source, prints a colored readiness report,
# emits trustabl.json + trustabl.sarif + trustabl-summary.md + trustabl.env, and
# gates on RISK_SCORE_THRESHOLD / SEVERITY_THRESHOLD.
#
# Ported from the GitLab CI/CD component scanner (same scan/score/report logic);
# GitLab-only bits (gl-sast report, CI_* env) are swapped for AWS equivalents.
#
# Inputs are environment variables (all optional; sensible defaults):
#   TARGET VERSION DETECTORS STRICT RULES_REF RULES_REPO
#   SARIF_FILE JSON_FILE RISK_SCORE_THRESHOLD SEVERITY_THRESHOLD
#   BRANCH GITHUB_TOKEN DEBUG REPORT_ONLY SECURITY_HUB TRUSTABL_BIN_DIR

# ---- inputs (env, with defaults) ----
TARGET="${TARGET:-.}"
VERSION="${VERSION:-latest}"
DETECTORS="${DETECTORS:-}"
STRICT="${STRICT:-false}"
RULES_REF="${RULES_REF:-}"
RULES_REPO="${RULES_REPO:-}"
SARIF_FILE="${SARIF_FILE:-trustabl.sarif}"
JSON_FILE="${JSON_FILE:-trustabl.json}"
RISK_THRESHOLD="${RISK_SCORE_THRESHOLD:-0}"
SEV_THRESHOLD="${SEVERITY_THRESHOLD:-none}"
BRANCH_INPUT="${BRANCH:-}"
REPORT_ONLY="${REPORT_ONLY:-false}"
SECURITY_HUB="${SECURITY_HUB:-false}"

# ---- preflight: required commands ----
# The CodePipeline buildspec's install phase ends in `|| true` and hides its
# output, and the CodeCatalyst workflow installs nothing at all, so a build
# image can reach this point missing a dependency with nothing having said so.
# Naming the missing tool here beats the alternative: the first symptom is
# otherwise a downstream guard blaming the scan result for a missing binary.
#
# `git` is deliberately not required — every call is guarded, and without it
# the script degrades to BR=unknown and REPO=$TARGET. `tr` and `seq` are left
# out because they ship in coreutils alongside `head`.
MISSING=""
for _cmd in curl jq tar awk grep head uname; do
  command -v "$_cmd" >/dev/null 2>&1 || MISSING="$MISSING $_cmd"
done
if [ -n "$MISSING" ]; then
  echo "Missing required command(s):$MISSING"
  echo "Install them on the build image before scanning; the CodeBuild image"
  echo "aws/codebuild/standard:7.0 ships all of them."
  exit 2
fi
unset _cmd MISSING

[ "${DEBUG:-false}" = "true" ] && set -x

set -e

# Resolve output paths through their existing parent directories so equivalent
# spellings such as "report.json" and "./report.json" compare equal without
# requiring GNU realpath (the wrapper also supports macOS).
canonical_output_path() {
  local path="$1" dir base resolved_dir

  case "$path" in
    */*)
      dir="${path%/*}"
      base="${path##*/}"
      [ -n "$dir" ] || dir="/"
      ;;
    *)
      dir="."
      base="$path"
      ;;
  esac

  if resolved_dir=$(cd "$dir" 2>/dev/null && pwd -P); then
    printf '%s/%s\n' "${resolved_dir%/}" "$base"
  else
    # The later output redirection will report a missing parent directory. The
    # literal fallback still catches identical invalid configurations here.
    printf '%s\n' "$path"
  fi
}

if [ "$(canonical_output_path "$JSON_FILE")" = "$(canonical_output_path "$SARIF_FILE")" ]; then
  echo "Invalid output configuration: JSON_FILE and SARIF_FILE must use different paths" >&2
  exit 2
fi

# trustabl reads TRUSTABL_RULES_REPO from the env (empty = its default).
export TRUSTABL_RULES_REPO="$RULES_REPO"

# Optional GitHub auth (set GITHUB_TOKEN as a secret) to dodge the 60 req/hr
# anonymous GitHub API limit on version lookup + download.
AUTH=()
[ -n "${GITHUB_TOKEN:-}" ] && AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

# ---- resolve branch label ----
# CodeBuild gives refs/heads/<branch> in CODEBUILD_WEBHOOK_HEAD_REF; CodeCatalyst
# exposes none reliably, so fall back to the checkout's current branch.
# `show-ref --verify refs/heads/main` only asks whether that ref exists — almost
# every repo has one — so it labeled feature-branch checkouts as "main".
BR="$BRANCH_INPUT"
if [ -z "$BR" ]; then BR="${CODEBUILD_WEBHOOK_HEAD_REF:-}"; BR="${BR#refs/heads/}"; fi
if [ -z "$BR" ]; then
  if git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
    BR=$(git -C "$TARGET" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    # CodeBuild often checks out a detached commit. Label it main/master only
    # when HEAD *is* that branch's tip, not merely because the ref exists.
    if [ "$BR" = "HEAD" ] || [ -z "$BR" ]; then
      HEAD_SHA=$(git -C "$TARGET" rev-parse HEAD 2>/dev/null || true)
      MAIN_SHA=$(git -C "$TARGET" rev-parse --verify refs/heads/main 2>/dev/null || true)
      MASTER_SHA=$(git -C "$TARGET" rev-parse --verify refs/heads/master 2>/dev/null || true)
      BR=""
      if [ -n "$HEAD_SHA" ] && [ -n "$MAIN_SHA" ] && [ "$HEAD_SHA" = "$MAIN_SHA" ]; then
        BR=main
      elif [ -n "$HEAD_SHA" ] && [ -n "$MASTER_SHA" ] && [ "$HEAD_SHA" = "$MASTER_SHA" ]; then
        BR=master
      fi
    fi
  fi
  [ -z "$BR" ] && BR=unknown
fi
echo "Trustabl scanning branch: $BR"

# ---- resolve version ----
VER="$VERSION"
if [ "$VER" = "latest" ]; then
  VER=$(curl -sSL "${AUTH[@]}" https://api.github.com/repos/trustabl/trustabl/releases/latest | jq -r '.tag_name // empty')
fi
if [ -z "$VER" ] || [ "$VER" = "null" ]; then
  echo "Could not resolve trustabl version. Pin 'VERSION' to a tag, or set GITHUB_TOKEN."
  exit 2
fi
# One path segment only. A slash, '..', or URL metacharacter in a pin or in
# tag_name from /releases/latest would change
# /releases/download/${VER}/${ASSET} and the local -o filename.
if [[ "$VER" == */* || "$VER" == *\\* || "$VER" == *..* || "$VER" == *[[:space:]]* || "$VER" == *:* || "$VER" == *@* ]]; then
  echo "Invalid trustabl version. Pin VERSION to a single release tag."
  exit 2
fi
# Release tags are v-prefixed (v0.1.7). Accept VERSION=0.1.7 too — otherwise the
# download URL is .../download/0.1.7/... which 404s against tag v0.1.7.
case "$VER" in
  v*) ;;
  *) VER="v$VER" ;;
esac
echo "Trustabl version: $VER"

# ---- install the release binary ----
VNUM="${VER#v}"
case "$(uname -s)" in
  Linux)  OS=linux ;;
  Darwin) OS=darwin ;;
  *) echo "Unsupported OS $(uname -s)"; exit 2 ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "Unsupported arch $(uname -m)"; exit 2 ;;
esac
ASSET="trustabl_${VNUM}_${OS}_${ARCH}.tar.gz"
# Keep the toolchain outside the tree we are about to analyse. With the default
# TARGET=".", a download dir under $(pwd) puts the tarball and everything it
# unpacks inside the scan target, so trustabl inventories its own release
# payload alongside the user's code. TRUSTABL_BIN_DIR overrides if a caller
# needs a fixed location (e.g. to cache it between runs).
if [ -n "${TRUSTABL_BIN_DIR:-}" ]; then
  DEST="$TRUSTABL_BIN_DIR"
else
  DEST="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/trustabl-bin.$$")"
  # Only clean up what we created — a caller-pinned dir may be a deliberate
  # cache. Best-effort; harmless if the runner discards the workspace anyway.
  trap 'rm -rf "$DEST"' EXIT
fi
mkdir -p "$DEST"
# The release download URL (Accept: application/octet-stream) increments the
# upstream trustabl/trustabl per-asset download_count.
curl -fSL -H "Accept: application/octet-stream" "${AUTH[@]}" \
  -o "$DEST/$ASSET" \
  "https://github.com/trustabl/trustabl/releases/download/${VER}/${ASSET}"

# ---- verify checksum (sha256 against the release checksums.txt) ----
# Verification is mandatory. As a warning it skipped exactly the cases that
# matter: a checksums.txt that cannot be fetched, and an asset missing from the
# one that can — the two shapes a substituted release takes. Everything the
# scanner then reports comes from a binary nobody vouched for.
#
# These exit 2, not 1. A failed verification is not a gate result; per
# docs/EVALUATION.md the scan did not complete and its output should not be
# trusted. A checksum mismatch exits 2 for the same reason.
if ! curl -fsSL "${AUTH[@]}" -o "$DEST/checksums.txt" \
     "https://github.com/trustabl/trustabl/releases/download/${VER}/checksums.txt"; then
  echo "Could not fetch checksums.txt for ${VER}; refusing to run an unverified trustabl binary." >&2
  exit 2
fi

# Exact field match: the asset name is the whole second column, never a suffix
# of some other entry.
EXPECTED=$(awk -v asset="$ASSET" '$2 == asset { print $1; exit }' "$DEST/checksums.txt")
if [ -z "$EXPECTED" ]; then
  echo "$ASSET is not listed in checksums.txt for ${VER}; refusing to run an unverified trustabl binary." >&2
  exit 2
fi

ACTUAL=$(sha256sum "$DEST/$ASSET" | awk '{print $1}')
if [ "$EXPECTED" != "$ACTUAL" ]; then
  echo "Checksum mismatch for $ASSET: expected $EXPECTED, got $ACTUAL" >&2
  exit 2
fi
echo "checksum verified: $ASSET"

tar -xzf "$DEST/$ASSET" -C "$DEST"
export PATH="$DEST:$PATH"

# ---- scan ----
set +e

# Resolve the repo label (report box + summary).
# Priority: explicit GitHub URL target -> target's git remote -> CodeBuild repo.
REPO=""
if [[ "$TARGET" =~ ^https?://github\.com/([^/]+/[^/]+)(\.git)?/?$ ]]; then
  REPO="${BASH_REMATCH[1]%.git}"
elif git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
  REMOTE=$(git -C "$TARGET" config --get remote.origin.url 2>/dev/null || true)
  if [[ "$REMOTE" =~ (github|gitlab)\.com[:/]([^/]+/.+?)(\.git)?$ ]]; then
    REPO="${BASH_REMATCH[2]%.git}"
  fi
fi
if [ -z "$REPO" ]; then
  SRC="${CODEBUILD_SOURCE_REPO_URL:-}"
  if [[ "$SRC" =~ github\.com[:/]([^/]+/.+?)(\.git)?$ ]]; then REPO="${BASH_REMATCH[1]%.git}"; fi
fi
[ -z "$REPO" ] && REPO="$TARGET"

BASE_ARGS=(scan "$TARGET")
[ -n "$DETECTORS" ] && BASE_ARGS+=(--detectors "$DETECTORS")
[ "$STRICT" = "true" ] && BASE_ARGS+=(--strict)
[ -n "$RULES_REF" ] && BASE_ARGS+=(--rules-ref "$RULES_REF")

# Run 1: SARIF (file emit).
trustabl "${BASE_ARGS[@]}" --format sarif > "$SARIF_FILE"
NATIVE_CODE=$?

# Run 2: JSON (drives thresholds, log summary, dotenv).
trustabl "${BASE_ARGS[@]}" --format json > "$JSON_FILE" || true

# Everything below reads the JSON ScanResult. If the engine did not produce one
# — it errored, was killed, ran out of disk — jq fails on every field and the
# defaults take over: readiness 0, risk 100, an empty findings count. That is
# not a bad repo, it is no repo, and reporting it as a score is worse than
# reporting nothing. Exit 2: the scan did not complete.
if ! jq -e 'type == "object" and has("overall_score")' "$JSON_FILE" >/dev/null 2>&1; then
  echo "trustabl produced no usable JSON ScanResult at '$JSON_FILE' (engine exit $NATIVE_CODE); refusing to report a score." >&2
  exit 2
fi

# trustabl's overall_score is a float in [0.0, 1.0]; scale to [0,100] ints.
RAW_SCORE=$(jq -r '.overall_score // 1' "$JSON_FILE")
SCORE=$(awk -v s="$RAW_SCORE" 'BEGIN{ v = s*100; if (v<0) v=0; if (v>100) v=100; printf "%d", v + 0.5 }')
RISK=$(( 100 - SCORE ))
COUNT=$(jq -r '.findings | length // 0' "$JSON_FILE")
# `.findings[]?` rather than `.findings[]`: the engine emits a null findings
# array on a clean scan, and iterating null is a jq error, not an empty list.
MAX_SEV=$(jq -r '
  [.findings[]?.severity] as $s
  | if ($s|length)==0 then "none"
    elif any($s[]; .=="critical") then "critical"
    elif any($s[]; .=="high")     then "high"
    elif any($s[]; .=="medium")   then "medium"
    elif any($s[]; .=="low")      then "low"
    else "info" end
' "$JSON_FILE")

# ---- dotenv outputs (downstream steps can `source trustabl.env`) ----
{
  echo "TRUSTABL_EXIT_CODE=$NATIVE_CODE"
  echo "TRUSTABL_READINESS_SCORE=$SCORE"
  echo "TRUSTABL_RISK_SCORE=$RISK"
  echo "TRUSTABL_MAX_SEVERITY=$MAX_SEV"
  echo "TRUSTABL_FINDINGS_COUNT=$COUNT"
} > trustabl.env

# ── Projected readiness (estimate — re-applies trustabl's own scoring) ──
# Per-tool score = max(0, 1 - weighted/3); overall = min over tools;
# per-finding weight = severityWeight*confidence. We re-apply that with
# selected severities "resolved" to project headroom. NOT a re-scan.
#
# The whole panel is anchored on projected([]) — the same min-over-tools
# formula with nothing resolved — NOT on .overall_score, which is weighted
# across surfaces and so measures a different thing. Mixing the two produced
# projections below the starting point (negative "headroom"). Every field is
# tolerant of malformed findings: one missing key must not void the panel.
PROJ_JQ='
  def num($v; $d): if ($v|type)=="number" then $v else $d end;
  def key($v; $d): if ($v|type)=="string" then $v else $d end;
  def sw($s): if $s=="critical" then 1.0 elif $s=="high" then 0.7 elif $s=="medium" then 0.4 elif $s=="low" then 0.15 else 0.05 end;
  def removed($rm): reduce (.findings[]? | select(.severity as $s | $rm | index($s))) as $f ({}; key($f.tool_name; "::untooled::") as $k | .[$k] = ((.[$k] // 0) + (sw($f.severity) * num($f.confidence; 1.0))));
  def projected($rm): removed($rm) as $r | [ .readiness[]? | (num(.weighted_severity; 0) - (($r[key(.tool_name; "::unmatched::")]) // 0)) as $w | (if $w<0 then 0 else $w end) as $w2 | (1 - $w2/3.0) as $s | (if $s<0 then 0 else $s end) ] | (if length==0 then 1 else min end);
  def p100($x): ($x*100 + 0.5 | floor);
  if ((.readiness|type) != "array") or ((.readiness|length) == 0) then empty
  else [ p100(projected([])), p100(projected(["critical"])), p100(projected(["critical","high"])), p100(projected(["critical","high","medium"])), p100(projected(["critical","high","medium","low"])), p100(projected(["critical","high","medium","low","info"])) ] | @tsv end
'
# Keep stderr: if jq still bails we say so in the log instead of silently
# rendering a made-up projection.
PROJ_RAW=$(jq -r "$PROJ_JQ" "$JSON_FILE" 2>&1 | tr -d '\r')
PROJ_OK=1
read -r P_BASE P_CRIT P_CH P_CHM P_CHML P_ALL <<<"$PROJ_RAW"
for p in "$P_BASE" "$P_CRIT" "$P_CH" "$P_CHM" "$P_CHML" "$P_ALL"; do
  case "$p" in ''|*[!0-9]*) PROJ_OK=0 ;; esac
done
if [ "$PROJ_OK" != "1" ]; then
  PROJ_WHY="${PROJ_RAW%%$'\n'*}"
  [ -z "$PROJ_WHY" ] && PROJ_WHY="no .readiness data in $JSON_FILE"
  echo "WARNING: projected readiness unavailable ($PROJ_WHY) — reporting no headroom"
  P_BASE=""; P_CRIT=""; P_CH=""; P_CHM=""; P_CHML=""; P_ALL=""
fi
# Conservative fallback: no headroom known, never a fabricated perfect score.
: "${P_BASE:=$SCORE}"; : "${P_CRIT:=$SCORE}"; : "${P_CH:=$SCORE}"; : "${P_CHM:=$SCORE}"; : "${P_CHML:=$SCORE}"; : "${P_ALL:=$SCORE}"
# Resolving more findings can only lower weighted severity, so the ladder is
# non-decreasing by construction; clamp anyway so no delta can come out negative.
[ "$P_CRIT" -lt "$P_BASE"  ] 2>/dev/null && P_CRIT="$P_BASE"
[ "$P_CH"   -lt "$P_CRIT"  ] 2>/dev/null && P_CH="$P_CRIT"
[ "$P_CHM"  -lt "$P_CH"    ] 2>/dev/null && P_CHM="$P_CH"
[ "$P_CHML" -lt "$P_CHM"   ] 2>/dev/null && P_CHML="$P_CHM"
[ "$P_ALL"  -lt "$P_CHML"  ] 2>/dev/null && P_ALL="$P_CHML"
read SEV_CRIT SEV_HIGH SEV_MED SEV_LOW SEV_INFO < <(jq -r '[.findings[]?.severity] as $s | "\([$s[]|select(.=="critical")]|length)\t\([$s[]|select(.=="high")]|length)\t\([$s[]|select(.=="medium")]|length)\t\([$s[]|select(.=="low")]|length)\t\([$s[]|select(.=="info")]|length)"' "$JSON_FILE" 2>/dev/null | tr -d '\r')
: "${SEV_CRIT:=0}"; : "${SEV_HIGH:=0}"; : "${SEV_MED:=0}"; : "${SEV_LOW:=0}"; : "${SEV_INFO:=0}"

# ── Pretty box-drawn console report ───────────────────────────
BOLD=$'\e[1m'; DIM=$'\e[2m'; RESET=$'\e[0m'
FG_RED=$'\e[1;31m'; FG_YEL=$'\e[1;33m'; FG_GRN=$'\e[1;32m'
FG_BLU=$'\e[1;34m'; FG_CYA=$'\e[1;36m'; FG_MAG=$'\e[1;35m'
VB="$FG_CYA|$RESET"

sev_color()  { case "$1" in critical|high) printf '%s' "$FG_RED";; medium) printf '%s' "$FG_YEL";; low) printf '%s' "$FG_BLU";; none) printf '%s' "$FG_GRN";; *) printf '%s' "$DIM";; esac; }
score_color() { if [ "$1" -ge 70 ] 2>/dev/null; then printf '%s' "$FG_GRN"; elif [ "$1" -ge 40 ] 2>/dev/null; then printf '%s' "$FG_YEL"; else printf '%s' "$FG_RED"; fi; }

DASH_TOP=$(printf '%.0s-' {1..58}); DASH_L=$(printf '%.0s-' {1..18}); DASH_R=$(printf '%.0s-' {1..39})
VAL_W=37

cell() { local label="$1" color="$2" val="$3" len=${#3} pad; pad=$(( VAL_W - len )); [ $pad -lt 0 ] && pad=0; printf '%s %-16s %s %b%s%b%*s %s\n' "$VB" "$label" "$VB" "$color" "$val" "$RESET" "$pad" '' "$VB"; }
bar() { local v="$1" m="$2" w="$3" c="$4" f; f=$(awk -v v="$v" -v m="$m" -v w="$w" 'BEGIN{if(m<=0)m=1;n=int(v/m*w+0.5);if(n>w)n=w;if(n<0)n=0;print n}'); printf '%b' "$c"; [ "$f" -gt 0 ] && printf '█%.0s' $(seq 1 "$f"); printf '%b' "$DIM"; [ "$f" -lt "$w" ] && printf '░%.0s' $(seq 1 $((w-f))); printf '%b' "$RESET"; }
gauge() { local label="$1" v="$2" w="$3" c="$4" suf="$5" b text vis pad; b=$(bar "$v" 100 "$w" "$c"); text="$b $suf"; vis=$(( w + 1 + ${#suf} )); pad=$(( VAL_W - vis )); [ $pad -lt 0 ] && pad=0; printf '%s %-16s %s %b%*s %s\n' "$VB" "$label" "$VB" "$text$RESET" "$pad" '' "$VB"; }
barcell() { local label="$1" v="$2" m="$3" c="$4" suf="$5" b text vis pad w=12; b=$(bar "$v" "$m" "$w" "$c"); text="$b $suf"; vis=$(( w + 1 + ${#suf} )); pad=$(( VAL_W - vis )); [ $pad -lt 0 ] && pad=0; printf '%s %-16s %s %b%*s %s\n' "$VB" "$label" "$VB" "$text$RESET" "$pad" '' "$VB"; }
center() { local t="$1" c="$2" len=${#1} lp rp; lp=$(( (58-len)/2 )); [ $lp -lt 0 ] && lp=0; rp=$(( 58-len-lp )); [ $rp -lt 0 ] && rp=0; printf '%b|%b%*s%b%s%b%*s%b|%b\n' "$FG_CYA" "$RESET" "$lp" '' "$c" "$t" "$RESET" "$rp" '' "$FG_CYA" "$RESET"; }
trunc() { local s="$1" max="$2"; if [ ${#s} -gt "$max" ]; then printf '%s~' "${s:0:$((max-1))}"; else printf '%s' "$s"; fi; }
sgn() { printf '%+d' "$1"; }

D_ALL=$(( P_ALL - P_BASE ))
L1=$(( P_CRIT - P_BASE )); L2=$(( P_CH - P_CRIT )); L3=$(( P_CHM - P_CH )); L4=$(( P_CHML - P_CHM )); L5=$(( P_ALL - P_CHML ))
SUB=$(trunc "$REPO  -  $BR  -  $COUNT findings" 56)
SMAX=1; for n in "$SEV_CRIT" "$SEV_HIGH" "$SEV_MED" "$SEV_LOW" "$SEV_INFO"; do [ "$n" -gt "$SMAX" ] 2>/dev/null && SMAX="$n"; done

echo ""
printf '%b+%s+%b\n' "$FG_CYA" "$DASH_TOP" "$RESET"
center "TRUSTABL SCAN REPORT" "$BOLD"
center "$SUB" "$DIM"
center "Projected  $P_BASE -> $P_ALL  ($(sgn "$D_ALL"))" "$BOLD"
printf '%b+%s+%s+%b\n' "$FG_CYA" "$DASH_L" "$DASH_R" "$RESET"
cell "Repository" "$FG_MAG" "$(trunc "$REPO" "$VAL_W")"
cell "Branch"     "$FG_CYA" "$(trunc "$BR" "$VAL_W")"
printf '%b+%s+%s+%b\n' "$FG_CYA" "$DASH_L" "$DASH_R" "$RESET"
gauge "Readiness now"  "$SCORE" 12 "$(score_color "$SCORE")" "$SCORE/100"
gauge "Projected all"  "$P_ALL" 12 "$(score_color "$P_ALL")" "$P_ALL/100  $(sgn "$D_ALL")"
printf '%b+%s+%s+%b\n' "$FG_CYA" "$DASH_L" "$DASH_R" "$RESET"
barcell "critical" "$SEV_CRIT" "$SMAX" "$(sev_color critical)" "$SEV_CRIT"
barcell "high"     "$SEV_HIGH" "$SMAX" "$(sev_color high)"     "$SEV_HIGH"
barcell "medium"   "$SEV_MED"  "$SMAX" "$(sev_color medium)"   "$SEV_MED"
barcell "low"      "$SEV_LOW"  "$SMAX" "$(sev_color low)"      "$SEV_LOW"
barcell "info"     "$SEV_INFO" "$SMAX" "$(sev_color info)"     "$SEV_INFO"
printf '%b+%s+%s+%b\n' "$FG_CYA" "$DASH_L" "$DASH_R" "$RESET"
cell "Fix critical" "$DIM" "$P_BASE -> $P_CRIT  ($(sgn "$L1"))"
cell "Fix +high"    "$DIM" "$P_CRIT -> $P_CH  ($(sgn "$L2"))"
cell "Fix +medium"  "$DIM" "$P_CH -> $P_CHM  ($(sgn "$L3"))"
cell "Fix +low"     "$DIM" "$P_CHM -> $P_CHML  ($(sgn "$L4"))"
cell "Fix +info"    "$DIM" "$P_CHML -> $P_ALL  ($(sgn "$L5"))"
printf '%b+%s+%s+%b\n' "$FG_CYA" "$DASH_L" "$DASH_R" "$RESET"
cell "Findings"     "$BOLD" "$COUNT"
cell "Max severity" "$(sev_color "$MAX_SEV")" "$MAX_SEV"
cell "Native exit"  "$([ "$NATIVE_CODE" = "0" ] && printf '%s' "$FG_GRN" || printf '%s' "$FG_RED")" "$NATIVE_CODE"
printf '%b+%s+%s+%b\n' "$FG_CYA" "$DASH_L" "$DASH_R" "$RESET"
printf '%b  Projected = estimate from trustabl'\''s own formula; listed fixes resolved, nothing new. Not a re-scan.%b\n' "$DIM" "$RESET"
if [ "$P_BASE" != "$SCORE" ]; then
  printf '%b  Projection baseline %s is the lowest-scoring surface; readiness %s is weighted across all of them.%b\n' "$DIM" "$P_BASE" "$SCORE" "$RESET"
fi
echo ""

# EXIT_CODE is the code this wrapper will exit with. docs/EVALUATION.md draws a
# hard line between the two failure kinds: exit 1 is "a result, not a
# malfunction", while exit 2 means "the scan did not complete and the output
# should not be trusted". Collapsing a scanner error into 1 makes a broken scan
# indistinguishable from a gate failure to CodeBuild and CodeCatalyst, so a
# native exit 2 is propagated as 2.
FAIL=0; EXIT_CODE=1; REASONS=()
if [ "$NATIVE_CODE" = "2" ]; then FAIL=1; EXIT_CODE=2; REASONS+=("scanner error (exit 2)"); fi
if [ "$NATIVE_CODE" = "1" ]; then FAIL=1; REASONS+=("trustabl gated (medium+ or --strict)"); fi

# Surrounding whitespace is trivially easy to introduce in a CI variable and
# must not change how a threshold is read. `[` already tolerated it (" 50"
# compared as 50); trimming just makes the guards below see the same string.
trim_ws() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# A malformed risk threshold used to fail OPEN: `[ abc -gt 0 ]` exits 2, the
# `2>/dev/null` swallowed it, the whole condition went false and the risk gate
# silently disappeared. Reject non-integers loudly instead. "+50"/"0050" stay
# legal (they always worked), 0 and empty still mean "gate disabled".
RST="$(trim_ws "$RISK_THRESHOLD")"
if [ -n "$RST" ] && ! [[ "$RST" =~ ^\+?[0-9]+$ ]]; then
  echo "ERROR: RISK_SCORE_THRESHOLD must be a non-negative integer or 0 to disable (got '$RISK_THRESHOLD')" >&2
  FAIL=1; REASONS+=("invalid RISK_SCORE_THRESHOLD '$RISK_THRESHOLD'")
elif [ -n "$RST" ] && [ "$RST" -gt 0 ] && [ "$RISK" -ge "$RST" ]; then
  FAIL=1; REASONS+=("risk $RISK >= threshold $RST")
fi

sev_rank() { case "$1" in critical) echo 4;; high) echo 3;; medium) echo 2;; low) echo 1;; info) echo 0;; *) echo -1;; esac; }
# Normalise before ranking. sev_rank's `*)` arm returns -1, which is <= every
# real severity, so an unrecognised threshold used to turn the gate into its
# LOOSEST setting (SEVERITY_THRESHOLD=HIGH failed a build on info-only
# findings) while printing a self-refuting reason. Trim + lowercase first, then
# reject anything still unranked rather than guessing what was meant.
ST="$(trim_ws "$SEV_THRESHOLD")"; ST="${ST,,}"
if [ -n "$ST" ] && [ "$ST" != "none" ]; then
  if [ "$(sev_rank "$ST")" -lt 0 ]; then
    echo "ERROR: SEVERITY_THRESHOLD must be one of critical, high, medium, low, info, none (got '$SEV_THRESHOLD')" >&2
    FAIL=1; REASONS+=("invalid SEVERITY_THRESHOLD '$SEV_THRESHOLD'")
  elif [ "$(sev_rank "$MAX_SEV")" -ge "$(sev_rank "$ST")" ] && [ "$COUNT" -gt 0 ]; then
    FAIL=1; REASONS+=("max severity $MAX_SEV >= threshold $ST")
  fi
fi

# REPORT_ONLY implements docs/EVALUATION.md step 1 ("scan without gating
# first") without `|| true`, which would also swallow scanner errors (exit 2).
if [ "$FAIL" = "1" ] && [ "$REPORT_ONLY" = "true" ] && [ "$NATIVE_CODE" != "2" ]; then
  echo "REPORT_ONLY=true: not failing the build (${REASONS[*]})"
  FAIL=0
  REASONS=()
fi

GREEN=$'\e[1;32m'; RED=$'\e[1;31m'; RESET=$'\e[0m'
# No native step-summary UI on AWS; write the markdown to an artifact instead.
SUMMARY="trustabl-summary.md"
: > "$SUMMARY"
{
  echo "## Trustabl scan"
  echo ""
  echo "**\`$REPO\` · \`$BR\` · $COUNT findings**"
  echo ""
  echo "Projected readiness goes from \`$P_BASE\` → \`$P_ALL\` (**$(sgn "$D_ALL")**) if every finding is resolved."
  echo ""
  echo "_Estimate from trustabl's own formula with the listed fixes resolved, nothing new — not a re-scan._"
  if [ "$P_BASE" != "$SCORE" ]; then
    echo ""
    echo "_Baseline \`$P_BASE\` is the lowest-scoring surface; the readiness score \`$SCORE\` is weighted across all of them._"
  fi
  echo ""
  echo "### Findings by severity"
  echo ""
  echo "| Severity | Count |"
  echo "|---|---|"
  echo "| critical | $SEV_CRIT |"
  echo "| high | $SEV_HIGH |"
  echo "| medium | $SEV_MED |"
  echo "| low | $SEV_LOW |"
  echo "| info | $SEV_INFO |"
  echo ""
  echo "| Metric | Value |"
  echo "|---|---|"
  echo "| Repository | \`$REPO\` |"
  echo "| Branch | \`$BR\` |"
  echo "| Readiness score | \`$SCORE\` |"
  echo "| Risk score | \`$RISK\` |"
  echo "| Findings | \`$COUNT\` |"
  echo "| Max severity | \`$MAX_SEV\` |"
  echo "| Native exit | \`$NATIVE_CODE\` |"
  echo ""
} >> "$SUMMARY"

# Always emit ASFF next to the other artifacts. SECURITY_HUB=true also
# batch-imports; that path is fail-closed (missing aws CLI, IAM, or Hub).
ASFF_SCRIPT="$(cd "$(dirname "$0")" && pwd)/to-asff.sh"
if [ -x "$ASFF_SCRIPT" ] || [ -f "$ASFF_SCRIPT" ]; then
  if [ "$SECURITY_HUB" = "true" ]; then
    bash "$ASFF_SCRIPT" --import "$JSON_FILE" trustabl.asff.json "$REPO"
  else
    bash "$ASFF_SCRIPT" "$JSON_FILE" trustabl.asff.json "$REPO" || echo "WARNING: ASFF conversion failed"
  fi
fi

if [ "$FAIL" = "1" ]; then
  printf '%b\n' "${RED}✗ Failed due to: ${REASONS[*]}${RESET}"
  echo "### ❌ Failed — ${REASONS[*]}" >> "$SUMMARY"
  # REPORT_ONLY already cleared gate hits above; remaining FAIL is scanner/I/O
  # (exit 2) or an invalid threshold (exit 1).
  exit "$EXIT_CODE"
fi

printf '%b\n' "${GREEN}✓ Successfully passed scanning${RESET}"
echo "### ✅ Successfully passed scanning" >> "$SUMMARY"
exit 0
