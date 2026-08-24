# Trustabl on Amazon CodeCatalyst

1. **Vendor** this plugin into your repo: copy `scan/` to your repo.
2. Add `codecatalyst/workflows/trustabl.yaml` to `.codecatalyst/workflows/` in
   your repo (or paste it via the CodeCatalyst workflow editor).
3. **Configure** via the `Variables` block in the workflow (see the root README
   inputs table), e.g. `SEVERITY_THRESHOLD=high`.

A gate failure exits non-zero -> the action fails. Findings surface in the
**Reports** tab via the SARIF report (`trustabl.sarif`).

**Alternative (quick) path:** instead of the native script, run the existing
GitHub Action in a CodeCatalyst workflow via the GitHub Actions action
(`trustabl/trustabl-action@v0`). Verify GitHub-Actions-in-CodeCatalyst support
against current AWS docs.

## Quickstart — from zero (CodeCatalyst)

**You need:** an Amazon CodeCatalyst space + project, your repo connected to it,
and CodeCatalyst opened in a **supported region** — Oregon (`us-west-2`) or
Ireland (`eu-west-1`). It is *not* available in N. Virginia.

### 1. Vendor the plugin into your repo
Copy into your repo, keeping the layout, then commit + push:

```
your-repo/
├── scan/trustabl-scan.sh                    # the scanner
├── scan/to-asff.sh                          # JSON → Security Hub ASFF
└── .codecatalyst/workflows/trustabl.yaml    # the workflow (from codecatalyst/workflows/)
```

### 2. (optional) Tune it
Edit the `Variables` block in the workflow — `SEVERITY_THRESHOLD`,
`RISK_SCORE_THRESHOLD`, `VERSION`, or add a `GITHUB_TOKEN` (dodges GitHub's
60-req/hr anon limit). Full list: [root README](../README.md).

### 3. Push
The workflow triggers on push to `main`. CodeCatalyst → your project →
**CI/CD → Workflows** shows the run. It downloads the trustabl binary
(sha256-verified), scans the checkout, uploads `trustabl.json` /
`trustabl.sarif` / `trustabl-summary.md`, surfaces findings in the **Reports**
tab (SARIF), and **fails the run on any medium-or-higher finding**.

> **Report-only (don't block)?** Set `REPORT_ONLY=true` in the workflow
> Variables. That publishes artifacts and still fails on scanner errors
> (exit 2). Do not use `|| true` — that also swallows a dead scanner.

### CLI?
CodeCatalyst workflows are **file-driven** — there's no separate CLI to create
the run. Committing `.codecatalyst/workflows/trustabl.yaml` and pushing *is* the
setup; the run triggers automatically. Manage runs from the CodeCatalyst
console (CodeCatalyst has no standalone scan CLI like CodeBuild).

**Notes**
- Linux build image only.
- The SARIF report `Format` enum (`SARIFSCA`) — verify against current
  CodeCatalyst docs; the schema evolves.
