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
#   BRANCH GITHUB_TOKEN DEBUG

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
[ "${DEBUG:-false}" = "true" ] && set -x

set -e
# trustabl reads TRUSTABL_RULES_REPO from the env (empty = its default).
export TRUSTABL_RULES_REPO="$RULES_REPO"

# Optional GitHub auth (set GITHUB_TOKEN as a secret) to dodge the 60 req/hr
# anonymous GitHub API limit on version lookup + download.
AUTH=()
[ -n "${GITHUB_TOKEN:-}" ] && AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

# ---- validate the gate inputs ----
# A misconfigured gate must not be mistaken for a scan result. An unrecognized
# severity ranks below every real one, so it would fail every build that found
# anything; a non-numeric risk threshold is silently treated as 0, disabling the
# gate the pipeline believes it configured. Both are configuration errors, so
# they exit 2 — per docs/EVALUATION.md, the scan did not complete and its output
# should not be trusted — and they do so before anything is downloaded.
SEV_THRESHOLD=$(printf '%s' "$SEV_THRESHOLD" | tr '[:upper:]' '[:lower:]')
case "$SEV_THRESHOLD" in
  none|info|low|medium|high|critical) ;;
  *) echo "Invalid SEVERITY_THRESHOLD '$SEVERITY_THRESHOLD' (want one of: none, info, low, medium, high, critical)" >&2
     exit 2 ;;
esac
case "$RISK_THRESHOLD" in
  ''|*[!0-9]*)
     echo "Invalid RISK_SCORE_THRESHOLD '$RISK_SCORE_THRESHOLD' (want an integer in 0-100; 0 disables)" >&2
     exit 2 ;;
esac
if [ "$RISK_THRESHOLD" -gt 100 ]; then
  echo "RISK_SCORE_THRESHOLD $RISK_THRESHOLD out of range (0-100)" >&2
  exit 2
fi

# ---- resolve branch label ----
# CodeBuild gives refs/heads/<branch> in CODEBUILD_WEBHOOK_HEAD_REF; CodeCatalyst
# exposes none reliably, so fall back to git on the checkout.
BR="$BRANCH_INPUT"
if [ -z "$BR" ]; then BR="${CODEBUILD_WEBHOOK_HEAD_REF:-}"; BR="${BR#refs/heads/}"; fi
if [ -z "$BR" ]; then
  if git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
    if   git -C "$TARGET" show-ref --verify --quiet refs/heads/main;   then BR=main
    elif git -C "$TARGET" show-ref --verify --quiet refs/heads/master; then BR=master
    else BR=$(git -C "$TARGET" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
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
  exit 1
fi
echo "Trustabl version: $VER"

# ---- install the release binary ----
VNUM="${VER#v}"
case "$(uname -s)" in
  Linux)  OS=linux ;;
  Darwin) OS=darwin ;;
  *) echo "Unsupported OS $(uname -s)"; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "Unsupported arch $(uname -m)"; exit 1 ;;
esac
ASSET="trustabl_${VNUM}_${OS}_${ARCH}.tar.gz"
DEST="$(pwd)/.trustabl-bin"
mkdir -p "$DEST"
# The release download URL (Accept: application/octet-stream) increments the
# upstream trustabl/trustabl per-asset download_count.
curl -fSL -H "Accept: application/octet-stream" "${AUTH[@]}" \
  -o "$DEST/$ASSET" \
  "https://github.com/trustabl/trustabl/releases/download/${VER}/${ASSET}"

# ---- verify checksum (sha256 against the release checksums.txt) ----
if curl -fsSL "${AUTH[@]}" -o "$DEST/checksums.txt" \
     "https://github.com/trustabl/trustabl/releases/download/${VER}/checksums.txt" 2>/dev/null; then
  EXPECTED=$(grep " ${ASSET}\$" "$DEST/checksums.txt" | awk '{print $1}' | head -1)
  if [ -n "$EXPECTED" ]; then
    ACTUAL=$(sha256sum "$DEST/$ASSET" | awk '{print $1}')
    if [ "$EXPECTED" != "$ACTUAL" ]; then
      echo "Checksum mismatch for $ASSET: expected $EXPECTED, got $ACTUAL"
      exit 1
    fi
    echo "checksum verified: $ASSET"
  else
    echo "WARNING: $ASSET not listed in checksums.txt — skipping verification"
  fi
else
  echo "WARNING: could not fetch checksums.txt — skipping verification"
fi

tar -xzf "$DEST/$ASSET" -C "$DEST"
export PATH="$DEST:$PATH"

# ---- scan ----
set +e
SCAN_START=$(date -u +%Y-%m-%dT%H:%M:%S)

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
SCAN_END=$(date -u +%Y-%m-%dT%H:%M:%S)

# trustabl's overall_score is a float in [0.0, 1.0]; scale to [0,100] ints.
RAW_SCORE=$(jq -r '.overall_score // 1' "$JSON_FILE")
SCORE=$(awk -v s="$RAW_SCORE" 'BEGIN{ v = s*100; if (v<0) v=0; if (v>100) v=100; printf "%d", v + 0.5 }')
RISK=$(( 100 - SCORE ))
COUNT=$(jq -r '.findings | length // 0' "$JSON_FILE")
MAX_SEV=$(jq -r '
  [.findings[].severity] as $s
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
PROJ_JQ='
  def sw($s): if $s=="critical" then 1.0 elif $s=="high" then 0.7 elif $s=="medium" then 0.4 elif $s=="low" then 0.15 else 0.05 end;
  def removed($rm): reduce (.findings[]? | select(.severity as $s | $rm | index($s))) as $f ({}; .[$f.tool_name] = ((.[$f.tool_name] // 0) + (sw($f.severity) * $f.confidence)));
  def projected($rm): removed($rm) as $r | [ .readiness[]? | (.weighted_severity - (($r[.tool_name]) // 0)) as $w | (if $w<0 then 0 else $w end) as $w2 | (1 - $w2/3.0) as $s | (if $s<0 then 0 else $s end) ] | (if length==0 then 1 else min end);
  def p100($x): ($x*100 + 0.5 | floor);
  [ p100(projected(["critical"])), p100(projected(["critical","high"])), p100(projected(["critical","high","medium"])), p100(projected(["critical","high","medium","low"])), p100(projected(["critical","high","medium","low","info"])) ] | @tsv
'
read P_CRIT P_CH P_CHM P_CHML P_ALL < <(jq -r "$PROJ_JQ" "$JSON_FILE" 2>/dev/null | tr -d '\r')
: "${P_CRIT:=$SCORE}"; : "${P_CH:=$SCORE}"; : "${P_CHM:=$SCORE}"; : "${P_CHML:=$SCORE}"; : "${P_ALL:=100}"
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
md_emoji() { local v="$1" w=10 f e i out=""; f=$(awk -v v="$v" -v w="$w" 'BEGIN{n=int(v/100*w+0.5);if(n>w)n=w;if(n<0)n=0;print n}'); if [ "$v" -ge 70 ] 2>/dev/null; then e="🟩"; elif [ "$v" -ge 40 ] 2>/dev/null; then e="🟨"; else e="🟥"; fi; for ((i=0;i<f;i++)); do out+="$e"; done; for ((i=f;i<w;i++)); do out+="⬜"; done; printf '%s' "$out"; }
md_count() { local v="$1" m="$2" w=8 f i out=""; f=$(awk -v v="$v" -v m="$m" -v w="$w" 'BEGIN{if(m<=0)m=1;n=int(v/m*w+0.5);if(n>w)n=w;if(n<0)n=0;print n}'); for ((i=0;i<f;i++)); do out+="▰"; done; for ((i=f;i<w;i++)); do out+="▱"; done; printf '%s' "$out"; }
trunc() { local s="$1" max="$2"; if [ ${#s} -gt "$max" ]; then printf '%s~' "${s:0:$((max-1))}"; else printf '%s' "$s"; fi; }

D_ALL=$(( P_ALL - SCORE ))
L1=$(( P_CRIT - SCORE )); L2=$(( P_CH - P_CRIT )); L3=$(( P_CHM - P_CH )); L4=$(( P_CHML - P_CHM )); L5=$(( P_ALL - P_CHML ))
SUB=$(trunc "$REPO  -  $BR  -  $COUNT findings" 56)
SMAX=1; for n in "$SEV_CRIT" "$SEV_HIGH" "$SEV_MED" "$SEV_LOW" "$SEV_INFO"; do [ "$n" -gt "$SMAX" ] 2>/dev/null && SMAX="$n"; done

echo ""
printf '%b+%s+%b\n' "$FG_CYA" "$DASH_TOP" "$RESET"
center "TRUSTABL SCAN REPORT" "$BOLD"
center "$SUB" "$DIM"
center "Readiness  $SCORE -> $P_ALL  (+$D_ALL)" "$BOLD"
printf '%b+%s+%s+%b\n' "$FG_CYA" "$DASH_L" "$DASH_R" "$RESET"
cell "Repository" "$FG_MAG" "$(trunc "$REPO" "$VAL_W")"
cell "Branch"     "$FG_CYA" "$(trunc "$BR" "$VAL_W")"
printf '%b+%s+%s+%b\n' "$FG_CYA" "$DASH_L" "$DASH_R" "$RESET"
gauge "Readiness now"  "$SCORE" 12 "$(score_color "$SCORE")" "$SCORE/100"
gauge "Projected all"  "$P_ALL" 12 "$(score_color "$P_ALL")" "$P_ALL/100  +$D_ALL"
printf '%b+%s+%s+%b\n' "$FG_CYA" "$DASH_L" "$DASH_R" "$RESET"
barcell "critical" "$SEV_CRIT" "$SMAX" "$(sev_color critical)" "$SEV_CRIT"
barcell "high"     "$SEV_HIGH" "$SMAX" "$(sev_color high)"     "$SEV_HIGH"
barcell "medium"   "$SEV_MED"  "$SMAX" "$(sev_color medium)"   "$SEV_MED"
barcell "low"      "$SEV_LOW"  "$SMAX" "$(sev_color low)"      "$SEV_LOW"
barcell "info"     "$SEV_INFO" "$SMAX" "$(sev_color info)"     "$SEV_INFO"
printf '%b+%s+%s+%b\n' "$FG_CYA" "$DASH_L" "$DASH_R" "$RESET"
cell "Fix critical" "$DIM" "$SCORE -> $P_CRIT  (+$L1)"
cell "Fix +high"    "$DIM" "$P_CRIT -> $P_CH  (+$L2)"
cell "Fix +medium"  "$DIM" "$P_CH -> $P_CHM  (+$L3)"
cell "Fix +low"     "$DIM" "$P_CHM -> $P_CHML  (+$L4)"
cell "Fix +info"    "$DIM" "$P_CHML -> $P_ALL  (+$L5)"
printf '%b+%s+%s+%b\n' "$FG_CYA" "$DASH_L" "$DASH_R" "$RESET"
cell "Findings"     "$BOLD" "$COUNT"
cell "Max severity" "$(sev_color "$MAX_SEV")" "$MAX_SEV"
cell "Native exit"  "$([ "$NATIVE_CODE" = "0" ] && printf '%s' "$FG_GRN" || printf '%s' "$FG_RED")" "$NATIVE_CODE"
printf '%b+%s+%s+%b\n' "$FG_CYA" "$DASH_L" "$DASH_R" "$RESET"
printf '%b  Projected = estimate from trustabl'\''s own formula; listed fixes resolved, nothing new. Not a re-scan.%b\n' "$DIM" "$RESET"
echo ""

FAIL=0; REASONS=()
if [ "$NATIVE_CODE" = "2" ]; then FAIL=1; REASONS+=("scanner error (exit 2)"); fi
if [ "$NATIVE_CODE" = "1" ]; then FAIL=1; REASONS+=("trustabl gated (medium+ or --strict)"); fi

RST="$RISK_THRESHOLD"
if [ "$RST" -gt 0 ] 2>/dev/null && [ "$RISK" -ge "$RST" ]; then
  FAIL=1; REASONS+=("risk $RISK >= threshold $RST")
fi

sev_rank() { case "$1" in critical) echo 4;; high) echo 3;; medium) echo 2;; low) echo 1;; info) echo 0;; *) echo -1;; esac; }
ST="$SEV_THRESHOLD"
if [ "$ST" != "none" ] && [ "$ST" != "" ]; then
  if [ "$(sev_rank "$MAX_SEV")" -ge "$(sev_rank "$ST")" ] && [ "$COUNT" -gt 0 ]; then
    FAIL=1; REASONS+=("max severity $MAX_SEV >= threshold $ST")
  fi
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
  echo "Readiness Score goes from \`$SCORE\` → \`$P_ALL\` (**+$D_ALL**)"
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

if [ "$FAIL" = "1" ]; then
  printf '%b\n' "${RED}✗ Failed due to: ${REASONS[*]}${RESET}"
  echo "### ❌ Failed — ${REASONS[*]}" >> "$SUMMARY"
  exit 1
fi

printf '%b\n' "${GREEN}✓ Successfully passed scanning${RESET}"
echo "### ✅ Successfully passed scanning" >> "$SUMMARY"
exit 0
