#!/usr/bin/env bash
# End-to-end tests for scan/trustabl-scan.sh. Run with: bash test/run-tests.sh
#
# The fixtures under test/fixtures are unmodified ScanResult / SARIF output from
# a real engine run, so the assertions below pin the scanner against the shape
# the engine actually emits rather than against a hand-written approximation.
#
#   clean.json     0 findings   overall_score 1.0
#   findings.json  3 findings   overall_score 0.9588…  (2 low, 1 medium)

set -uo pipefail

# shellcheck source=test/lib/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

WORKSPACES=()
workspace() {
  local ws
  ws="$(new_workspace)"
  WORKSPACES+=("$ws")
  echo "$ws"
}
cleanup() {
  local ws
  for ws in ${WORKSPACES+"${WORKSPACES[@]}"}; do rm -rf "$ws"; done
}
trap cleanup EXIT

# ---- tests ----

test_clean_scan_passes() {
  local ws; ws="$(workspace)"
  run_scan "$ws" STUB_JSON="$FIXTURE_DIR/clean.json" STUB_SARIF="$FIXTURE_DIR/findings.sarif"
  assert_eq "exit code" "$SCAN_EXIT" 0
  assert_contains "report" "$SCAN_OUT" "Successfully passed scanning"
  assert_eq "readiness" "$(env_var "$ws" TRUSTABL_READINESS_SCORE)" 100
  assert_eq "risk" "$(env_var "$ws" TRUSTABL_RISK_SCORE)" 0
  assert_eq "findings count" "$(env_var "$ws" TRUSTABL_FINDINGS_COUNT)" 0
  assert_eq "native exit" "$(env_var "$ws" TRUSTABL_EXIT_CODE)" 0
  # The engine emits `"findings": null` — not [] — when it finds nothing.
  assert_eq "max severity" "$(env_var "$ws" TRUSTABL_MAX_SEVERITY)" none
}

test_findings_scan_reports_engine_score() {
  local ws; ws="$(workspace)"
  run_scan "$ws"
  # overall_score 0.9588… scales to 96; risk is its complement.
  assert_eq "readiness" "$(env_var "$ws" TRUSTABL_READINESS_SCORE)" 96
  assert_eq "risk" "$(env_var "$ws" TRUSTABL_RISK_SCORE)" 4
  assert_eq "findings count" "$(env_var "$ws" TRUSTABL_FINDINGS_COUNT)" 3
  assert_eq "max severity" "$(env_var "$ws" TRUSTABL_MAX_SEVERITY)" medium
}

test_engine_gate_fails_the_build() {
  local ws; ws="$(workspace)"
  run_scan "$ws" STUB_EXIT=1
  assert_eq "exit code" "$SCAN_EXIT" 1
  assert_contains "reason" "$SCAN_OUT" "trustabl gated"
  assert_eq "native exit" "$(env_var "$ws" TRUSTABL_EXIT_CODE)" 1
}

test_engine_error_fails_the_build() {
  local ws; ws="$(workspace)"
  run_scan "$ws" STUB_EXIT=2
  # Asserted as "non-zero" rather than a specific code: a scanner error and a
  # gate failure are different things and which code carries that distinction
  # out to CodeBuild is a separate question from whether the build fails.
  [ "$SCAN_EXIT" -ne 0 ] || fail "exit code: expected non-zero, got $SCAN_EXIT"
  assert_contains "reason" "$SCAN_OUT" "scanner error (exit 2)"
  assert_eq "native exit" "$(env_var "$ws" TRUSTABL_EXIT_CODE)" 2
}

test_severity_threshold_gates_at_the_max_severity() {
  local ws; ws="$(workspace)"
  run_scan "$ws" SEVERITY_THRESHOLD=medium
  assert_eq "exit code" "$SCAN_EXIT" 1
  assert_contains "reason" "$SCAN_OUT" "max severity medium >= threshold medium"
}

test_severity_threshold_above_the_max_severity_passes() {
  local ws; ws="$(workspace)"
  run_scan "$ws" SEVERITY_THRESHOLD=high
  assert_eq "exit code" "$SCAN_EXIT" 0
  assert_contains "report" "$SCAN_OUT" "Successfully passed scanning"
}

test_risk_threshold_gates_when_met() {
  local ws; ws="$(workspace)"
  run_scan "$ws" RISK_SCORE_THRESHOLD=4
  assert_eq "exit code" "$SCAN_EXIT" 1
  assert_contains "reason" "$SCAN_OUT" "risk 4 >= threshold 4"
}

test_risk_threshold_above_the_risk_passes() {
  local ws; ws="$(workspace)"
  run_scan "$ws" RISK_SCORE_THRESHOLD=50
  assert_eq "exit code" "$SCAN_EXIT" 0
}

test_artifacts_are_written() {
  local ws; ws="$(workspace)"
  run_scan "$ws"
  assert_file "$ws/work/trustabl.json"
  assert_file "$ws/work/trustabl.sarif"
  assert_file "$ws/work/trustabl-summary.md"
  assert_file "$ws/work/trustabl.env"
  # The JSON artifact must be the engine's ScanResult verbatim.
  assert_eq "json artifact" "$(jq -r '.repo' "$ws/work/trustabl.json")" "testdata/handoffs"
  assert_eq "sarif artifact" "$(jq -r '.runs[0].results | length' "$ws/work/trustabl.sarif")" 3
}

test_output_paths_are_configurable() {
  local ws; ws="$(workspace)"
  run_scan "$ws" JSON_FILE=custom.json SARIF_FILE=custom.sarif
  assert_file "$ws/work/custom.json"
  assert_file "$ws/work/custom.sarif"
}

test_summary_records_the_severity_breakdown() {
  local ws; ws="$(workspace)"
  run_scan "$ws"
  local summary; summary="$(cat "$ws/work/trustabl-summary.md")"
  assert_contains "summary" "$summary" "| medium | 1 |"
  assert_contains "summary" "$summary" "| low | 2 |"
  assert_contains "summary" "$summary" "| critical | 0 |"
  assert_contains "summary" "$summary" "Successfully passed scanning"
}

test_scan_flags_reach_the_engine() {
  local ws; ws="$(workspace)"
  run_scan "$ws" STUB_ARGS_LOG="$ws/argv.log" \
    DETECTORS=claude_sdk,mcp STRICT=true RULES_REF=abc123
  local argv; argv="$(cat "$ws/argv.log")"
  assert_contains "argv" "$argv" "--detectors claude_sdk,mcp"
  assert_contains "argv" "$argv" "--strict"
  assert_contains "argv" "$argv" "--rules-ref abc123"
}

test_a_tampered_release_aborts_before_the_engine_runs() {
  local ws; ws="$(workspace)"
  # Rewrite the archive after checksums.txt was generated over the original.
  printf 'tampered' >> "$ws/release/$(asset_name)"
  run_scan "$ws" STUB_ARGS_LOG="$ws/argv.log"
  assert_eq "exit code" "$SCAN_EXIT" 2
  assert_contains "reason" "$SCAN_OUT" "Checksum mismatch"
  [ -f "$ws/argv.log" ] && fail "the engine ran despite a checksum mismatch"
}

test_an_unfetchable_checksums_file_aborts() {
  local ws; ws="$(workspace)"
  rm -f "$ws/release/checksums.txt"
  run_scan "$ws" STUB_ARGS_LOG="$ws/argv.log"
  assert_eq "exit code" "$SCAN_EXIT" 2
  assert_contains "reason" "$SCAN_OUT" "refusing to run an unverified trustabl binary"
  [ -f "$ws/argv.log" ] && fail "the engine ran without a verified checksum"
}

test_an_asset_missing_from_checksums_aborts() {
  local ws; ws="$(workspace)"
  # A checksums.txt that lists some other asset — the release we are about to
  # run is not covered by it.
  printf '%s  %s\n' "$(sha256_of "$ws/release/$(asset_name)")" "trustabl_0.0.0_other_arch.tar.gz" \
    > "$ws/release/checksums.txt"
  run_scan "$ws" STUB_ARGS_LOG="$ws/argv.log"
  assert_eq "exit code" "$SCAN_EXIT" 2
  assert_contains "reason" "$SCAN_OUT" "is not listed in checksums.txt"
  [ -f "$ws/argv.log" ] && fail "the engine ran without a verified checksum"
}

test_a_pinned_version_skips_the_latest_lookup() {
  local ws; ws="$(workspace)"
  run_scan "$ws" STUB_CURL_LOG="$ws/curl.log"
  assert_not_contains "curl log" "$(cat "$ws/curl.log")" "releases/latest"
  assert_contains "report" "$SCAN_OUT" "Trustabl version: $TEST_VERSION"
}

test_the_branch_label_is_reported() {
  local ws; ws="$(workspace)"
  run_scan "$ws" BRANCH=release/1.2
  assert_contains "report" "$SCAN_OUT" "Trustabl scanning branch: release/1.2"
}

test_an_empty_scan_result_is_not_scored() {
  local ws; ws="$(workspace)"
  : > "$ws/empty.json"
  run_scan "$ws" STUB_JSON="$ws/empty.json"
  assert_eq "exit code" "$SCAN_EXIT" 2
  assert_contains "message" "$SCAN_OUT" "no usable JSON ScanResult"
  assert_not_contains "report" "$SCAN_OUT" "Successfully passed scanning"
}

test_a_truncated_scan_result_is_not_scored() {
  local ws; ws="$(workspace)"
  head -c 400 "$FIXTURE_DIR/findings.json" > "$ws/truncated.json"
  run_scan "$ws" STUB_JSON="$ws/truncated.json"
  assert_eq "exit code" "$SCAN_EXIT" 2
  assert_contains "message" "$SCAN_OUT" "no usable JSON ScanResult"
}

# ---- run ----

it "a clean scan passes and reports a perfect readiness"        test_clean_scan_passes
it "a scan with findings reports the engine's readiness"        test_findings_scan_reports_engine_score
it "the engine's gate exit fails the build"                     test_engine_gate_fails_the_build
it "the engine's error exit fails the build"                    test_engine_error_fails_the_build
it "SEVERITY_THRESHOLD gates at the max severity"               test_severity_threshold_gates_at_the_max_severity
it "SEVERITY_THRESHOLD above the max severity passes"           test_severity_threshold_above_the_max_severity_passes
it "RISK_SCORE_THRESHOLD gates when the risk meets it"          test_risk_threshold_gates_when_met
it "RISK_SCORE_THRESHOLD above the risk passes"                 test_risk_threshold_above_the_risk_passes
it "the scan artifacts are written"                             test_artifacts_are_written
it "JSON_FILE and SARIF_FILE relocate the artifacts"            test_output_paths_are_configurable
it "the summary records the severity breakdown"                 test_summary_records_the_severity_breakdown
it "DETECTORS, STRICT and RULES_REF reach the engine"           test_scan_flags_reach_the_engine
it "a tampered release aborts before the engine runs"           test_a_tampered_release_aborts_before_the_engine_runs
it "an unfetchable checksums.txt aborts"                        test_an_unfetchable_checksums_file_aborts
it "an asset missing from checksums.txt aborts"                 test_an_asset_missing_from_checksums_aborts
it "a pinned VERSION skips the latest-release lookup"           test_a_pinned_version_skips_the_latest_lookup
it "the branch label is reported"                               test_the_branch_label_is_reported
it "an empty ScanResult is not scored"                          test_an_empty_scan_result_is_not_scored
it "a truncated ScanResult is not scored"                       test_a_truncated_scan_result_is_not_scored

summarize
