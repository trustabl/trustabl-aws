#!/usr/bin/env bash
# Offline tests for scan/to-asff.sh. No AWS credentials, no trustabl binary.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASFF="$ROOT/scan/to-asff.sh"
FIX="$ROOT/test/fixtures/scan.json"
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

bash "$ASFF" "$FIX" "$OUT" "demo/repo"

python3 - "$OUT" <<'PY'
import json, sys
path = sys.argv[1]
findings = json.load(open(path))
assert isinstance(findings, list), findings
assert len(findings) == 3, len(findings)
labels = {f["Severity"]["Label"] for f in findings}
assert labels == {"CRITICAL", "MEDIUM", "INFORMATIONAL"}, labels
ids = []
for f in findings:
    assert f["SchemaVersion"] == "2018-10-08"
    assert f["Id"].startswith("trustabl/")
    assert f["ProductArn"].startswith("arn:aws:securityhub:")
    assert f["AwsAccountId"]
    assert f["GeneratorId"] == "trustabl"
    assert f["Title"]
    assert f["Description"]
    assert f["Resources"][0]["Type"] == "Other"
    assert len(f["Title"]) <= 256
    assert len(f["Description"]) <= 1024
    assert "CVE" not in "".join(f["Types"])
    assert f["FindingProviderFields"]["Types"] == f["Types"]
    assert f["FindingProviderFields"]["Severity"]["Label"] == f["Severity"]["Label"]
    ids.append(f["Id"])
assert len(ids) == len(set(ids)), ids
# info/META must not be labelled as a defect severity
info = next(f for f in findings if "META" in f["Title"])
assert info["Severity"]["Label"] == "INFORMATIONAL"
print("ok: 3 findings, severity mapping, ASFF shape")
PY

# Empty findings -> empty array, still valid ASFF input
EMPTY="$(mktemp)"
echo '{"overall_score": 1, "findings": []}' > "$EMPTY"
bash "$ASFF" "$EMPTY" "$OUT" "demo/repo"
python3 - "$OUT" <<'PY'
import json, sys
findings = json.load(open(sys.argv[1]))
assert findings == []
print("ok: empty findings")
PY
rm -f "$EMPTY"

# --import without aws CLI must fail closed (exit 2), not skip
if command -v aws >/dev/null 2>&1; then
  echo "skip: aws CLI present; import fail-closed tested only when absent"
else
  set +e
  bash "$ASFF" --import "$FIX" "$OUT" "demo/repo"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || { echo "expected exit 2 without aws CLI, got $rc"; exit 1; }
  echo "ok: --import fail-closed without aws CLI"
fi
