# Changelog

All notable changes to the Trustabl AWS plugin are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `REPORT_ONLY=true` for evaluation-guide trials: publishes artifacts without
  gating, but still fails on scanner errors (exit 2). Replaces the documented
  `|| true` workaround, which swallowed dead-scanner failures.
- ASFF export (`scan/to-asff.sh`, `trustabl.asff.json`) and optional
  `SECURITY_HUB=true` import into AWS Security Hub via
  `securityhub:BatchImportFindings`.
- Offline tests for the ASFF converter (`test/test-asff.sh`).


## [0.1.0] — 2026-06-17

### Added

- Initial release: a shared `trustabl` scanner for AWS CI/CD.
- **AWS CodePipeline** support via a CodeBuild `buildspec.yml`.
- **Amazon CodeCatalyst** support via a native workflow action.
- Downloads the upstream `trustabl` release binary (sha256-verified against the
  release `checksums.txt`), scans the source, prints a colored readiness report,
  emits `trustabl.json` + `trustabl.sarif`, and gates the build on
  `RISK_SCORE_THRESHOLD` / `SEVERITY_THRESHOLD`.
