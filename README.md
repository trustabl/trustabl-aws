# Trustabl for AWS

Static reliability/safety scanner for AI-agent repos (Claude, OpenAI, Google
ADK, MCP), wired into AWS CI/CD. Downloads the upstream `trustabl` release
binary (sha256-verified), scans your source, prints a readiness report, emits
`trustabl.json` + `trustabl.sarif`, and gates the build on risk/severity.

One scanner (`scan/trustabl-scan.sh`), two integrations:

| Target | How | Setup |
|---|---|---|
| **AWS CodePipeline** | CodeBuild action using `codepipeline/buildspec.yml` | [codepipeline/README.md](codepipeline/README.md) |
| **Amazon CodeCatalyst** | Workflow action (`codecatalyst/workflows/trustabl.yaml`) | [codecatalyst/README.md](codecatalyst/README.md) |

## Inputs (environment variables)

| Var | Default | Description |
|---|---|---|
| `TARGET` | `.` | Path or GitHub URL to scan. |
| `VERSION` | `latest` | trustabl release tag (e.g. `v0.5.0`) or `latest`. |
| `DETECTORS` | _(all)_ | Comma-separated SDK subset (`claude_sdk,openai_sdk,google_adk,...`). |
| `STRICT` | `false` | Fail on any finding. |
| `RULES_REF` | _(default)_ | Pin a `trustabl-rules` git ref. |
| `RULES_REPO` | _(default)_ | Override the `trustabl-rules` source repo. |
| `SARIF_FILE` | `trustabl.sarif` | SARIF output path. |
| `JSON_FILE` | `trustabl.json` | JSON ScanResult output path. |
| `RISK_SCORE_THRESHOLD` | `0` | Fail when risk (100 − readiness) >= N. `0` disables. |
| `SEVERITY_THRESHOLD` | `none` | Fail when any finding >= severity (`none/low/medium/high/critical`). |
| `BRANCH` | _(detected)_ | Branch label for the report. Detected from `CODEBUILD_WEBHOOK_HEAD_REF`, else the checkout's git refs, else `unknown` — set it where neither applies (CodeCatalyst exposes no reliable branch variable). |
| `GITHUB_TOKEN` | _(none)_ | Optional — avoids GitHub's 60 req/hr anonymous rate limit. |
| `DEBUG` | `false` | `true` runs the scanner under `set -x`. Every command is echoed, so keep it off unless diagnosing — see the note below. |

> **`DEBUG=true` echoes every command, including the `curl` calls that carry
> `GITHUB_TOKEN` in an `Authorization` header.** CodeBuild and CodeCatalyst logs
> are readable by anyone with access to the project, so turn it off again once
> you have what you need, and prefer a token you can rotate.

## Outputs

`trustabl.json`, `trustabl.sarif`, `trustabl-summary.md`, and `trustabl.env`
(`TRUSTABL_READINESS_SCORE`, `TRUSTABL_RISK_SCORE`, `TRUSTABL_MAX_SEVERITY`,
`TRUSTABL_FINDINGS_COUNT`, `TRUSTABL_EXIT_CODE`).

## A note on "AWS Marketplace"

AWS has **no self-serve CI-plugin catalog** like the GitHub/Azure/Bitbucket
marketplaces. Distribution is **copy-paste**: vendor the `scan/` directory plus
the relevant wrapper into your repo. A native CodePipeline action provider is an
AWS Partner integration; an AWS Marketplace listing is a separate product
(container/SaaS) motion.
