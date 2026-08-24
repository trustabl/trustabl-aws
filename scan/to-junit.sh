#!/usr/bin/env bash
# Convert a Trustabl JSON ScanResult into JUnit XML for AWS CodeBuild Reports
# (file-format: JUNITXML).
#
# Usage:
#   to-junit.sh [json] [out]
#
# Defaults: JSON_FILE/trustabl.json, JUNIT_FILE/trustabl-junit.xml.
#
# Offline. Needs jq. Does not call AWS APIs — CodeBuild ingests the XML when
# the buildspec `reports:` block is enabled (extra IAM; see codepipeline/README).
#
# CodeBuild exposes at most 500 test cases per report. Findings are ordered
# critical > high > medium > low > info, then rule_id, file_path, start_line.
# Truncation is logged on stderr and recorded as testsuite properties; the
# original JSON/SARIF remain the complete result.
set -euo pipefail

JSON="${1:-${JSON_FILE:-trustabl.json}}"
OUT="${2:-${JUNIT_FILE:-trustabl-junit.xml}}"
MAX_CASES="${CODEBUILD_REPORT_MAX_CASES:-500}"
MAX_NAME=1000
MAX_MSG=5000

if [ ! -f "$JSON" ]; then
  echo "to-junit: JSON result not found: $JSON" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "to-junit: jq is required" >&2
  exit 2
fi
if ! [[ "$MAX_CASES" =~ ^[1-9][0-9]*$ ]]; then
  echo "to-junit: CODEBUILD_REPORT_MAX_CASES must be a positive integer" >&2
  exit 2
fi

# Reject non-objects (malformed, empty, truncated) before mapping.
if ! jq -e 'type == "object"' "$JSON" >/dev/null 2>&1; then
  echo "to-junit: not a JSON object (malformed Trustabl ScanResult): $JSON" >&2
  exit 2
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

if ! jq -nr \
  --slurpfile root "$JSON" \
  --argjson max "$MAX_CASES" \
  --argjson max_name "$MAX_NAME" \
  --argjson max_msg "$MAX_MSG" \
  '
  # @html emits XML/HTML entities. Do not use gsub("&lt;") — jq treats "&"
  # in the replacement as the whole match, which produces "<lt;" / "\&lt;".
  def xml:
    tostring
    | gsub("\u0000|\u0001|\u0002|\u0003|\u0004|\u0005|\u0006|\u0007|\u0008|\u000b|\u000c|\u000e|\u000f|\u0010|\u0011|\u0012|\u0013|\u0014|\u0015|\u0016|\u0017|\u0018|\u0019|\u001a|\u001b|\u001c|\u001d|\u001e|\u001f|\u007f"; "")
    | @html;
  def safe_int:
    if type == "number" then floor else 0 end;
  def clip($s; $n):
    ($s | tostring) as $t
    | if ($t | length) <= $n then $t else $t[0:$n] end;
  def attr($s; $n):
    clip($s; $n) | gsub("\n"; " ") | gsub("\r"; " ") | xml;
  def sev_rank($s):
    ($s | tostring | ascii_downcase) as $d
    | if $d == "critical" then 0
      elif $d == "high" then 1
      elif $d == "medium" then 2
      elif $d == "low" then 3
      elif $d == "info" then 4
      else 5 end;
  def sev_label($s):
    if ($s == null) or ($s == "") then "info" else ($s | tostring) end;

  $root[0] as $scan
  | (if ($scan.findings | type) == "array" then $scan.findings
     elif $scan.findings == null then []
     else error("findings must be an array or null") end) as $raw
  | ($raw | map(select(type == "object"))) as $findings
  | ($findings
      | sort_by([
          sev_rank(.severity // "info"),
          (.rule_id // ""),
          (.file_path // ""),
          (.start_line // 0),
          (.tool_name // ""),
          (.title // "")
        ])) as $sorted
  | ($sorted | length) as $total
  | (if $total > $max then $sorted[0:$max] else $sorted end) as $pub
  | ($pub | length) as $published
  | ($total > $published) as $trunc
  | ($scan.repo // "") as $repo
  | ($scan.overall_score // "") as $score
  | [
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
      ("<testsuite name=\"trustabl\" tests=\"" + ($published | tostring)
        + "\" failures=\"" + ($published | tostring)
        + "\" errors=\"0\" skipped=\"0\">"),
      "  <properties>",
      ("    <property name=\"trustabl.findings.total\" value=\"" + ($total | tostring) + "\"/>"),
      ("    <property name=\"trustabl.findings.published\" value=\"" + ($published | tostring) + "\"/>"),
      ("    <property name=\"trustabl.findings.truncated\" value=\"" + (if $trunc then "true" else "false" end) + "\"/>"),
      ("    <property name=\"trustabl.overall_score\" value=\"" + ($score | tostring | xml) + "\"/>"),
      ("    <property name=\"trustabl.repo\" value=\"" + attr($repo; 512) + "\"/>"),
      "  </properties>",
      ($pub | to_entries | map(
        .key as $i
        | .value as $f
        | sev_label($f.severity) as $sev
        | ($f.rule_id // "unknown") as $rid
        | ($f.title // $rid) as $title
        | ($f.file_path // "") as $file
        | (($f.start_line // 0) | safe_int) as $line
        | (($f.end_line // $line) | safe_int) as $end
        | ($f.tool_name // "") as $tool
        | ($f.category // "trustabl") as $cat
        | ($f.scope // "") as $scope
        | ($f.explanation // "") as $expl
        | ($f.suggested_fix // "") as $fix
        | ($f.confidence // "") as $conf
        | ("[" + $sev + "] " + $rid + " " + $file
            + (if $line != 0 then (":" + ($line | tostring)) else "" end)
            + " " + $title + " #" + ($i | tostring)) as $name
        | (["Severity: " + $sev,
            "Rule: " + $rid,
            "Title: " + $title,
            "File: " + $file + (if $line != 0 then (":" + ($line | tostring)
              + (if $end != $line then ("-" + ($end | tostring)) else "" end)) else "" end),
            "Tool: " + $tool,
            "Category: " + $cat,
            "Scope: " + $scope,
            "Confidence: " + ($conf | tostring),
            "",
            "Explanation:",
            $expl,
            "",
            "Remediation:",
            $fix
          ] | join("\n")) as $body
        | "  <testcase classname=\"" + attr($cat; 256)
          + "\" name=\"" + attr($name; $max_name)
          + "\" file=\"" + attr($file; 512)
          + "\" line=\"" + ($line | tostring | xml)
          + "\">\n"
          + "    <failure type=\"" + attr($sev; 32)
          + "\" message=\"" + attr($title; 256)
          + "\">" + (clip($body; $max_msg) | xml)
          + "</failure>\n"
          + "  </testcase>"
      ) | join("\n")),
      "</testsuite>"
    ]
  | map(select(. != ""))
  | join("\n")
  + "\n"
  ' > "$TMP"; then
  echo "to-junit: failed to map ScanResult to JUnit XML" >&2
  exit 2
fi

mv "$TMP" "$OUT"
trap - EXIT

STATS=$(jq -e '
  (if (.findings | type) == "array" then .findings elif .findings == null then [] else [] end) as $f
  | ($f | map(select(type == "object")) | length) as $n
  | {total: $n, published: ([$n, '"$MAX_CASES"'] | min), truncated: ($n > '"$MAX_CASES"')}
' "$JSON" 2>/dev/null || echo "")

if [ -n "$STATS" ]; then
  TOTAL_N=$(printf '%s' "$STATS" | jq -r '.total')
  PUB_N=$(printf '%s' "$STATS" | jq -r '.published')
  TRUNC=$(printf '%s' "$STATS" | jq -r '.truncated')
  echo "to-junit: wrote $PUB_N of $TOTAL_N finding(s) to $OUT"
  if [ "$TRUNC" = "true" ]; then
    echo "to-junit: truncated — $TOTAL_N total Trustabl findings existed; $PUB_N published to CodeBuild Reports (cap $MAX_CASES). trustabl.json / trustabl.sarif remain complete." >&2
  fi
else
  echo "to-junit: wrote $OUT"
fi
