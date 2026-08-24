# Changelog

All notable changes to the Trustabl AWS plugin are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- JUnit export (`scan/to-junit.sh`, `trustabl-junit.xml`) for optional AWS
  CodeBuild Reports. Findings become inspectable test cases in the Reports tab
  when the buildspec `reports:` block is enabled and the CodeBuild role has
  report-group IAM (`codepipeline/iam-reports.json`). The Trustabl gate is
  unchanged. CodeBuild's 500-case cap is applied after severity ordering;
  JSON/SARIF stay complete.

## [0.1.0] — 2026-06-17

### Added

- Initial release: a shared `trustabl` scanner for AWS CI/CD.
- **AWS CodePipeline** support via a CodeBuild `buildspec.yml`.
- **Amazon CodeCatalyst** support via a native workflow action.
- Downloads the upstream `trustabl` release binary (sha256-verified against the
  release `checksums.txt`), scans the source, prints a colored readiness report,
  emits `trustabl.json` + `trustabl.sarif`, and gates the build on
  `RISK_SCORE_THRESHOLD` / `SEVERITY_THRESHOLD`.
