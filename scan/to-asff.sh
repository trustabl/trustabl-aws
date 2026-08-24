#!/usr/bin/env bash
# Convert a Trustabl JSON ScanResult into AWS Security Hub ASFF (2018-10-08)
# and optionally import it with `aws securityhub batch-import-findings`.
#
# Usage:
#   to-asff.sh [json] [out] [resource-id]
#   to-asff.sh --import [json] [out] [resource-id]
#
# Defaults: JSON_FILE/trustabl.json, trustabl.asff.json, TARGET/repo.
#
# Does not require AWS credentials unless --import is set. Placeholders are
# used for ProductArn / AwsAccountId and rewritten at import time from
# `aws sts get-caller-identity` + AWS_REGION.
set -euo pipefail

IMPORT=false
if [ "${1:-}" = "--import" ]; then IMPORT=true; shift; fi

JSON="${1:-${JSON_FILE:-trustabl.json}}"
OUT="${2:-trustabl.asff.json}"
RESOURCE="${3:-${TARGET:-repository}}"

if [ ! -f "$JSON" ]; then
  echo "to-asff: JSON result not found: $JSON" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "to-asff: jq is required" >&2
  exit 2
fi

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
ACCOUNT="${AWS_ACCOUNT_ID:-000000000000}"
NOW=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
GENERATOR="trustabl"

# Security Hub BatchImportFindings accepts a JSON array of findings.
jq --arg region "$REGION" \
   --arg account "$ACCOUNT" \
   --arg now "$NOW" \
   --arg gen "$GENERATOR" \
   --arg resource "$RESOURCE" \
   --arg product "arn:aws:securityhub:${REGION}:${ACCOUNT}:product/${ACCOUNT}/default" \
   '
   def sev_label($s):
     if $s == "critical" then "CRITICAL"
     elif $s == "high" then "HIGH"
     elif $s == "medium" then "MEDIUM"
     elif $s == "low" then "LOW"
     else "INFORMATIONAL" end;
   def clip($s; $n):
     ($s | tostring) as $t
     | if ($t | length) <= $n then $t else $t[0:$n-1] + "…" end;
   . as $root
   | ($root.findings // []) as $findings
   | [ $findings[]?
       | . as $f
       | ($f.severity // $f.level // "info") as $sev
       | ($f.id // $f.rule_id // $f.check_id // $f.title // "finding") as $fid
       | ($f.title // $f.rule_id // $f.message // "Trustabl finding") as $title
       | ($f.message // $f.description // $f.title // "No description provided") as $desc
       | ($f.file // $f.path // $f.location.file // $f.location.uri // $resource) as $file
       | {
           SchemaVersion: "2018-10-08",
           Id: ("trustabl/" + ($fid | tostring) + "/" + ($file | tostring)),
           ProductArn: $product,
           GeneratorId: $gen,
           AwsAccountId: $account,
           Types: ["Software and Configuration Checks/Code Analysis/Agent Reliability"],
           CreatedAt: $now,
           UpdatedAt: $now,
           Severity: { Label: sev_label($sev) },
           Title: clip($title; 256),
           Description: clip($desc; 1024),
           Remediation: {
             Recommendation: {
               Text: clip(($f.fix // $f.remediation // $f.suggestion // "See the Trustabl finding for the suggested fix."); 512)
             }
           },
           Resources: [
             {
               Type: "Other",
               Id: clip($file; 512),
               Partition: "aws",
               Region: $region
             }
           ],
           ProductFields: {
             "trustabl/rule": (($f.rule_id // $f.id // "") | tostring),
             "trustabl/tool": (($f.tool_name // $f.tool // "") | tostring),
             "trustabl/readiness": (($root.overall_score // "") | tostring)
           }
         }
     ]
   ' "$JSON" > "$OUT"

COUNT=$(jq 'length' "$OUT")
echo "to-asff: wrote $COUNT finding(s) to $OUT"

if [ "$IMPORT" != "true" ]; then
  exit 0
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "to-asff: aws CLI is required for --import" >&2
  exit 2
fi

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:?set AWS_REGION or AWS_DEFAULT_REGION to import}}"
PRODUCT="arn:aws:securityhub:${REGION}:${ACCOUNT}:product/${ACCOUNT}/default"

TMP=$(mktemp)
jq --arg account "$ACCOUNT" --arg region "$REGION" --arg product "$PRODUCT" \
  'map(.AwsAccountId = $account | .ProductArn = $product | .Resources |= map(.Region = $region))' \
  "$OUT" > "$TMP"
mv "$TMP" "$OUT"

# Security Hub accepts at most 100 findings per BatchImportFindings call.
TOTAL=$(jq 'length' "$OUT")
OFFSET=0
while [ "$OFFSET" -lt "$TOTAL" ]; do
  CHUNK=$(mktemp)
  jq -c --argjson skip "$OFFSET" '.[$skip:$skip+100]' "$OUT" > "$CHUNK"
  aws securityhub batch-import-findings --region "$REGION" --findings "file://${CHUNK}"
  rm -f "$CHUNK"
  OFFSET=$(( OFFSET + 100 ))
done
echo "to-asff: imported $TOTAL finding(s) into Security Hub ($REGION)"
