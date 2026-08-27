# Trustabl for AWS

Catch AI-agent reliability issues before they ship, inside AWS CI/CD. Scans
agent repos built on the Claude Agent SDK, OpenAI Agents SDK, Google ADK,
LangChain, CrewAI, and MCP. Downloads the upstream `trustabl` release binary
(sha256-verified), prints a readiness report, emits `trustabl.json` +
`trustabl.sarif`, and gates the build on risk and severity.

One scanner (`scan/trustabl-scan.sh`), two integrations:

| Target | How | Setup |
|---|---|---|
| **AWS CodePipeline** | CodeBuild action using `codepipeline/buildspec.yml` | [codepipeline/README.md](codepipeline/README.md) |
| **Amazon CodeCatalyst** † | Workflow action (`codecatalyst/workflows/trustabl.yaml`) | [codecatalyst/README.md](codecatalyst/README.md) |

† CodeCatalyst has been closed to new customers since November 7, 2025. The
integration is maintained for existing customers; new users want CodePipeline.

## Demo

A sixty-second walkthrough: install it, gate it, run the first scan, and the
exit code CI reads.

[▶ Watch the demo](https://raw.githubusercontent.com/trustabl/trustabl-aws/main/assets/trustabl-demo.mp4) · [`assets/trustabl-demo.mp4`](assets/trustabl-demo.mp4)

Evaluating this against other tools? [docs/EVALUATION.md](docs/EVALUATION.md)
covers how to trial it and how to read what it reports.

## Inputs (environment variables)

| Var | Default | Description |
|---|---|---|
| `TARGET` | `.` | Path or GitHub URL to scan. |
| `VERSION` | `latest` | trustabl release tag (e.g. `v0.1.7`) or `latest`. A pin without the `v` (`0.1.7`) is accepted. |
| `DETECTORS` | _(all)_ | Comma-separated SDK subset (`claude_sdk,openai_sdk,google_adk,...`). |
| `STRICT` | `false` | Fail on any finding of `low` or above (`info` never gates), and on a scan that found no agent surfaces at all. |
| `RULES_REF` | _(default)_ | Pin a `trustabl-rules` git ref. |
| `RULES_REPO` | _(default)_ | Override the `trustabl-rules` source repo. |
| `SARIF_FILE` | `trustabl.sarif` | SARIF output path. |
| `JSON_FILE` | `trustabl.json` | JSON ScanResult output path. |
| `RISK_SCORE_THRESHOLD` | `0` | Fail when risk (100 − readiness) >= N. `0` disables. |
| `SEVERITY_THRESHOLD` | `none` | Fail when any finding >= severity (`none/low/medium/high/critical`). |
| `GITHUB_TOKEN` | _(none)_ | Optional — avoids GitHub's 60 req/hr anonymous rate limit. |
| `REPORT_ONLY` | `false` | Scan and publish artifacts without gating. Scanner errors (exit 2) still fail the build. |
| `SECURITY_HUB` | `false` | Import ASFF findings into AWS Security Hub (`securityhub:BatchImportFindings`). |
| `TRUSTABL_BIN_DIR` | _(temp dir)_ | Where to download/unpack the binary. Must sit outside `TARGET`. |

## Outputs

`trustabl.json`, `trustabl.sarif`, `trustabl-summary.md`, `trustabl.env`
(`TRUSTABL_READINESS_SCORE`, `TRUSTABL_RISK_SCORE`, `TRUSTABL_MAX_SEVERITY`,
`TRUSTABL_FINDINGS_COUNT`, `TRUSTABL_EXIT_CODE`), and `trustabl.asff.json` (ASFF
for Security Hub).

## A note on "AWS Marketplace"

AWS has **no self-serve CI-plugin catalog** like the GitHub/Azure/Bitbucket
marketplaces. Distribution is **copy-paste**: vendor the `scan/` directory plus
the relevant wrapper into your repo. A native CodePipeline action provider is an
AWS Partner integration; an AWS Marketplace listing is a separate product
(container/SaaS) motion.

### Quick Start: Vendor into your Project
Because AWS does not offer a native self-serve plugin marketplace, you can quickly vendor the Trustabl scanning system into your existing repository. Run this one-liner from your project root to fetch the latest scanner script and make it executable:

```bash
mkdir -p scan && curl -fsSL https://raw.githubusercontent.com/trustabl/trustabl-aws/main/scan/trustabl-scan.sh -o scan/trustabl-scan.sh && chmod +x scan/trustabl-scan.sh
```
