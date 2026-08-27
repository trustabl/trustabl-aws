# Trustabl on Amazon CodeCatalyst

> [!IMPORTANT]
> **CodeCatalyst is closed to new customers as of November 7, 2025.** Existing
> customers can keep using it as normal, and this integration is for them. If
> you cannot open a CodeCatalyst space, that is why — use
> [CodePipeline](../codepipeline/README.md) instead. See
> [How to migrate from CodeCatalyst](https://docs.aws.amazon.com/codecatalyst/latest/userguide/migration.html).

1. **Vendor** this plugin into your repo: copy `scan/` to your repo.
2. Add `codecatalyst/workflows/trustabl.yaml` to `.codecatalyst/workflows/` in
   your repo (or paste it via the CodeCatalyst workflow editor).
3. **Configure** via the `Variables` block in the workflow (see the root README
   inputs table), e.g. `SEVERITY_THRESHOLD=high`.

A gate failure exits non-zero -> the action fails. Findings surface in the
**Reports** tab via the SARIF report (`trustabl.sarif`).

**Alternative path:** instead of the native script, run the existing GitHub
Action inside a CodeCatalyst workflow. This is supported — the action
identifier is `aws/github-actions-runner@v1`, and you paste the GitHub Action's
`steps:` block into the CodeCatalyst action's `Steps:`:

```yaml
Actions:
  Trustabl_Scan:
    Identifier: aws/github-actions-runner@v1
    Inputs:
      Sources:
        - WorkflowSource
    Configuration:
      Steps:
        - name: Trustabl
          uses: trustabl/trustabl-action@v0
```

It is not a drop-in, though, and AWS says "detailed migration steps are outside
the scope of this guide":

- **`${{ secrets.GITHUB_TOKEN }}` does not exist here.** CodeCatalyst has no
  GitHub secrets context, and AWS's own porting example shows that line being
  deleted. If the action wants a token for GitHub API rate limits, supply it
  from a CodeCatalyst secret instead.
- Anything the action relies on outside its `steps:` block has to be
  re-expressed in CodeCatalyst's own YAML.
- Reports and artifacts are configured on the CodeCatalyst action
  (`Outputs.Reports`, `Outputs.Artifacts`), not by the GitHub Action.

The native script above avoids all of that, which is why it is the documented
path. See [GitHub Actions action YAML](https://docs.aws.amazon.com/codecatalyst/latest/userguide/github-action-ref.html).

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

**`GITHUB_TOKEN` is a credential.** Store it as a CodeCatalyst **secret** and
reference it from the `Variables` block, rather than pasting the value into the
workflow file — the workflow is committed to the repository.

### 3. Push
The workflow triggers on push to `main`. CodeCatalyst → your project →
**CI/CD → Workflows** shows the run. It downloads the trustabl binary
(sha256-verified), scans the checkout, uploads `trustabl.json` /
`trustabl.sarif` / `trustabl-summary.md` / `trustabl.env`, surfaces findings in
the **Reports** tab (SARIF), and **fails the run on any medium-or-higher
finding**.

> **Report-only (don't block)?** Set `REPORT_ONLY=true` in the workflow
> Variables. That publishes artifacts and still fails on scanner errors
> (exit 2). Do not use `|| true` — that also swallows a dead scanner.
>
> Equivalent without the env var: change the workflow `Run:` line to
> `- Run: bash scan/trustabl-scan.sh || [ $? -eq 1 ]`.
> Exit 1 means the scan ran and gated; exit 2 means it did not run — a missing
> tool, an unreachable release, unusable rules. See
> [exit codes](../docs/EVALUATION.md#exit-codes).

### CLI?
CodeCatalyst workflows are **file-driven** — there's no separate CLI to create
the run. Committing `.codecatalyst/workflows/trustabl.yaml` and pushing *is* the
setup; the run triggers automatically. Manage runs from the CodeCatalyst
console (CodeCatalyst has no standalone scan CLI like CodeBuild).

**Notes**
- Linux build image only.
- `Format: SARIFSCA` is correct: it is the only SARIF value CodeCatalyst accepts
  in the YAML editor. The docs read "For SARIF, specify **SARIF** (visual
  editor) or `SARIFSCA` (YAML editor)". There is no separate SAST-SARIF enum —
  the SA formats are `ESLINTJSON` and `PYLINTJSON` — so a SARIF report goes in
  under the SCA format regardless of the tool that produced it. See
  [Build and test actions YAML](https://docs.aws.amazon.com/codecatalyst/latest/userguide/build-action-ref.html).
- The workflow sets `AutoDiscoverReports: Enabled: false`. Auto-discovery
  defaults to on and inspects every file the action generates, which would
  surface `trustabl.sarif` a second time next to the manual report.
