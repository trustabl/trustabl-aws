#!/usr/bin/env bash
# Offline tests for scan/to-junit.sh. No AWS credentials, no trustabl binary.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONV="$ROOT/scan/to-junit.sh"
FIX="$ROOT/test/fixtures"
OUT="$(mktemp)"
ERR="$(mktemp)"
trap 'rm -f "$OUT" "$ERR" "$OUT.a" "$OUT.ctl.json" "$OUT.bad"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

PYTHON="${PYTHON:-}"
if command -v python >/dev/null 2>&1 && python -c "import xml.etree.ElementTree" >/dev/null 2>&1; then
  PYTHON=python
elif command -v python3 >/dev/null 2>&1 && python3 -c "import xml.etree.ElementTree" >/dev/null 2>&1; then
  PYTHON=python3
else
  fail "python with xml.etree.ElementTree is required"
fi

xml_parse() {
  "$PYTHON" - "$1" <<'PY'
import sys, xml.etree.ElementTree as ET
path = sys.argv[1]
tree = ET.parse(path)
root = tree.getroot()
assert root.tag == "testsuite", root.tag
print("parsed", root.attrib.get("tests"), root.attrib.get("failures"))
PY
}

# 1. zero findings (null array — real engine shape)
bash "$CONV" "$FIX/junit-empty.json" "$OUT"
xml_parse "$OUT" >/dev/null
"$PYTHON" - "$OUT" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
assert root.attrib["tests"] == "0"
assert root.attrib["failures"] == "0"
assert root.attrib["errors"] == "0"
assert list(root.findall("testcase")) == []
props = {p.attrib["name"]: p.attrib["value"] for p in root.find("properties")}
assert props["trustabl.findings.total"] == "0"
assert props["trustabl.findings.published"] == "0"
assert props["trustabl.findings.truncated"] == "false"
print("ok empty")
PY
ok "zero findings"

# 2. one finding
bash "$CONV" "$FIX/junit-one.json" "$OUT"
"$PYTHON" - "$OUT" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
cases = root.findall("testcase")
assert len(cases) == 1, len(cases)
assert root.attrib["tests"] == "1"
assert root.attrib["failures"] == "1"
assert cases[0].find("failure").attrib["type"] == "medium"
assert "TOOL-001" in cases[0].attrib["name"]
print("ok one")
PY
ok "one finding"

# 3 + 4. multiple / all severities
bash "$CONV" "$FIX/junit-mixed.json" "$OUT"
"$PYTHON" - "$OUT" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
cases = root.findall("testcase")
assert len(cases) == 5, len(cases)
assert root.attrib["tests"] == "5"
assert root.attrib["failures"] == "5"
order = [c.find("failure").attrib["type"] for c in cases]
assert order == ["critical", "high", "medium", "low", "info"], order
# classname = category; name carries severity + rule + path
assert cases[0].attrib["classname"] == "openai_sdk"
assert cases[0].attrib["name"].startswith("[critical] TOOL-001")
assert "src/tools/shell.py:12" in cases[0].attrib["name"]
assert cases[0].attrib["file"] == "src/tools/shell.py"
assert cases[0].attrib["line"] == "12"
fail = cases[0].find("failure")
assert fail.attrib["message"] == "Unsandboxed shell tool"
body = fail.text or ""
assert "Severity: critical" in body
assert "Rule: TOOL-001" in body
assert "Explanation:" in body
assert "Remediation:" in body
assert "Constrain the argv" in body
assert "Category: openai_sdk" in body
assert "Scope: tool" in body
print("ok mixed")
PY
ok "mixed severities and metadata"

# 5–10. escaping: quotes, ampersands, angles, multiline, unusual path, missing fields
bash "$CONV" "$FIX/junit-escape.json" "$OUT"
"$PYTHON" - "$OUT" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
cases = root.findall("testcase")
assert len(cases) == 2, len(cases)
# round-trip through XML parser: special chars survived
a = cases[0]
assert a.attrib["classname"] == "mcp"
body = a.find("failure").text or ""
assert "A & B" in body
assert "<script>" in body
assert 'He said "hi"' in body
assert "it's fine" in body
assert "line1" in body and "line2" in body
assert "fix line 1" in body and "fix line 2" in body
assert "weird/path with spaces & <x>/file.py" in (a.attrib.get("file") or "")
raw = open(sys.argv[1], encoding="utf-8").read()
assert "&lt;script&gt;" in raw
assert "<lt;" not in raw
assert "&amp;" in raw
assert "&quot;" in raw or "&#34;" in raw
assert "&apos;" in raw or "&#39;" in raw
# missing optional fields: second finding still converts
b = cases[1]
assert b.find("failure") is not None
assert b.attrib["name"]
assert "MISSING-1" in b.attrib["name"]
print("ok escape")
PY
ok "XML escaping, multiline, unusual path, missing fields"

# Control characters are stripped; non-numeric start_line becomes 0.
"$PYTHON" - "$OUT.ctl.json" <<'PY'
import json, sys
json.dump({
    "overall_score": 1,
    "findings": [{
        "rule_id": "CTL-1",
        "severity": "low",
        "title": "ctrl",
        "explanation": "ok\abell",
        "suggested_fix": "x",
        "file_path": "a.py",
        "start_line": "nope",
        "end_line": 3,
    }],
}, open(sys.argv[1], "w"))
PY
bash "$CONV" "$OUT.ctl.json" "$OUT"
"$PYTHON" - "$OUT" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
case = root.find("testcase")
assert case.attrib["line"] == "0"
body = case.find("failure").text or ""
assert "\x07" not in body
assert "bell" in body
ET.parse(sys.argv[1])
print("ok control/line")
PY
rm -f "$OUT.ctl.json"
ok "control characters stripped; non-numeric line coerced to 0"

# 12. deterministic output
bash "$CONV" "$FIX/junit-mixed.json" "$OUT"
cp "$OUT" "$OUT.a"
bash "$CONV" "$FIX/junit-mixed.json" "$OUT"
cmp -s "$OUT.a" "$OUT" || fail "output was not deterministic"
rm -f "$OUT.a"
ok "deterministic output"

# 13. malformed JSON
set +e
bash "$CONV" "$FIX/junit-malformed.json" "$OUT" >"$ERR" 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "malformed JSON expected exit 2, got $rc"
grep -q "malformed\|not a JSON object" "$ERR" || fail "malformed JSON error was not clear: $(cat "$ERR")"
ok "malformed JSON exits 2"

# findings of the wrong type
set +e
echo '{"overall_score":1,"findings":"nope"}' > "$OUT.bad"
bash "$CONV" "$OUT.bad" "$OUT" >"$ERR" 2>&1
rc=$?
set -e
rm -f "$OUT.bad"
[ "$rc" -eq 2 ] || fail "bad findings type expected exit 2, got $rc"
ok "non-array findings exits 2"

# missing file
set +e
bash "$CONV" "$FIX/does-not-exist.json" "$OUT" >"$ERR" 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "missing file expected exit 2, got $rc"
ok "missing JSON exits 2"

# 14–16. 500 / 501 / severity ordering under truncation
"$PYTHON" - "$FIX" <<'PY'
import json, os, sys
fix = sys.argv[1]
sevs = ["info", "low", "medium", "high", "critical"]

def dump(n, path):
    findings = []
    for i in range(n):
        sev = sevs[i % 5]
        findings.append({
            "rule_id": f"R-{i:04d}",
            "category": "openai_sdk",
            "scope": "tool",
            "severity": sev,
            "tool_name": f"t{i}",
            "file_path": f"f/{i}.py",
            "start_line": i + 1,
            "end_line": i + 1,
            "title": f"title {i}",
            "explanation": f"expl {i}",
            "suggested_fix": f"fix {i}",
            "confidence": 0.5,
        })
    json.dump({"overall_score": 0.1, "repo": "demo/repo", "findings": findings},
              open(path, "w"), indent=0)

dump(500, os.path.join(fix, "_gen_500.json"))
dump(501, os.path.join(fix, "_gen_501.json"))
# 501 with one critical last so truncation-by-severity must keep it
findings = []
for i in range(500):
    findings.append({
        "rule_id": f"Z-{i:04d}",
        "category": "mcp",
        "scope": "tool",
        "severity": "info",
        "tool_name": "t",
        "file_path": f"z/{i}.py",
        "start_line": 1,
        "end_line": 1,
        "title": "info finding",
        "explanation": "e",
        "suggested_fix": "s",
        "confidence": 1,
    })
findings.append({
    "rule_id": "A-CRIT",
    "category": "openai_sdk",
    "scope": "tool",
    "severity": "critical",
    "tool_name": "danger",
    "file_path": "zzz/last.py",
    "start_line": 99,
    "end_line": 99,
    "title": "must be published",
    "explanation": "kept because critical ranks first",
    "suggested_fix": "fix it",
    "confidence": 1,
})
json.dump({"overall_score": 0.2, "findings": findings},
          open(os.path.join(fix, "_gen_order.json"), "w"))
print("generated")
PY

bash "$CONV" "$FIX/_gen_500.json" "$OUT" 2>"$ERR"
"$PYTHON" - "$OUT" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
assert root.attrib["tests"] == "500"
assert len(root.findall("testcase")) == 500
props = {p.attrib["name"]: p.attrib["value"] for p in root.find("properties")}
assert props["trustabl.findings.total"] == "500"
assert props["trustabl.findings.truncated"] == "false"
print("ok 500")
PY
ok "exactly 500 findings"

bash "$CONV" "$FIX/_gen_501.json" "$OUT" 2>"$ERR"
grep -q "501 total Trustabl findings existed" "$ERR" || fail "truncation log missing: $(cat "$ERR")"
grep -q "500 published to CodeBuild Reports" "$ERR" || fail "published count missing from log"
"$PYTHON" - "$OUT" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
assert root.attrib["tests"] == "500", root.attrib
assert len(root.findall("testcase")) == 500
props = {p.attrib["name"]: p.attrib["value"] for p in root.find("properties")}
assert props["trustabl.findings.total"] == "501"
assert props["trustabl.findings.published"] == "500"
assert props["trustabl.findings.truncated"] == "true"
print("ok 501")
PY
ok "501 findings truncated with log + properties"

bash "$CONV" "$FIX/_gen_order.json" "$OUT" 2>"$ERR"
"$PYTHON" - "$OUT" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
cases = root.findall("testcase")
assert len(cases) == 500
# critical last in input must be first in output
assert "A-CRIT" in cases[0].attrib["name"], cases[0].attrib["name"]
assert cases[0].find("failure").attrib["type"] == "critical"
# no info-only report should have dropped the critical
names = [c.attrib["name"] for c in cases]
assert any("must be published" in n for n in names)
# secondary sort: remaining are info, by rule_id then path
info = [c for c in cases[1:]]
assert all(c.find("failure").attrib["type"] == "info" for c in info)
print("ok severity order")
PY
ok ">500 deterministic severity ordering"

# 17. valid XML already asserted via ElementTree on every fixture
ok "valid XML parsing of generated output"

rm -f "$FIX/_gen_500.json" "$FIX/_gen_501.json" "$FIX/_gen_order.json"
echo "all to-junit tests passed"
