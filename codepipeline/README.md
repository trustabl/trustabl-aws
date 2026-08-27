# Trustabl on AWS CodePipeline (via CodeBuild)

1. **Vendor** this plugin into your repo: copy `scan/` and
   `codepipeline/buildspec.yml` to your repo.
2. **Create a CodeBuild project** that uses `buildspec.yml`. Image
   `aws/codebuild/standard:7.0` (has bash, curl, jq, git, tar).
3. **Add a CodeBuild action** to a Build/Test **stage** of your pipeline, with
   the source artifact as input.
4. **Configure** via environment variables on the project/action (see the root
   README inputs table), e.g. `SEVERITY_THRESHOLD=high`.

A gate failure exits non-zero -> the CodeBuild action fails -> the pipeline
stage fails. Artifacts (`trustabl.json`, `trustabl.sarif`,
`trustabl-summary.md`, `trustabl-junit.xml`) are emitted to the artifact bucket.

**Optional — CodeBuild Reports:** the scanner always writes `trustabl-junit.xml`
(one JUnit test case per Trustabl finding). To show those in the CodeBuild
**Reports** tab, uncomment the `reports:` block in `buildspec.yml` and attach
report-group IAM (below). This is visibility only — it does not change the
Trustabl gate. JSON/SARIF remain the complete result (CodeBuild shows at most
500 test cases).

**Optional — Security Hub:** convert findings to ASFF and
`aws securityhub batch-import-findings` to surface them in Security Hub (needs
Security Hub enabled + IAM `securityhub:BatchImportFindings`). Not in v0.1.0.

## Quickstart — from zero (console)

**You need:** an AWS account, your code in a repo AWS can read (GitHub via a
CodeStar connection, CodeCommit, or S3), and a CodePipeline (or make one).

### 1. Vendor the plugin into your repo
Copy these into your repo, keeping the layout, then commit + push:

```
your-repo/
├── scan/trustabl-scan.sh        # the scanner
├── scan/to-junit.sh             # JSON → CodeBuild JUnit
└── codepipeline/buildspec.yml   # tells CodeBuild to run it
```

### 2. Make a CodeBuild project
Console → **CodeBuild → Create build project**:
- **Environment image:** `aws/codebuild/standard:7.0` (has bash, curl, jq, git)
- **Buildspec:** "Use a buildspec file" → path `codepipeline/buildspec.yml`
- **Service role:** let CodeBuild create one (it needs CloudWatch Logs)
- *(optional)* **Env vars:** `SEVERITY_THRESHOLD`, `RISK_SCORE_THRESHOLD`,
  `VERSION` (pin a tag), `GITHUB_TOKEN` (dodges GitHub's 60-req/hr anon limit)
- **`GITHUB_TOKEN` is a credential** — add it with type **Secrets Manager** or
  **Parameter Store**, not as a plaintext environment variable. Plaintext env
  vars are readable by anyone with `codebuild:BatchGetProjects`.

### 3. Add it to your pipeline
CodePipeline → your pipeline → **Edit** → add a **Build/Test** stage →
action provider **AWS CodeBuild** → pick the project → input artifact = your
Source output.

### 4. Run it (Release change)
Each run downloads the trustabl binary (sha256-verified), scans your checkout,
prints the readiness report, uploads `trustabl.json` / `trustabl.sarif` /
`trustabl-summary.md` / `trustabl-junit.xml` as artifacts, and **fails the stage
if any finding is medium-or-higher** — so the pipeline stops on unsafe agent
code.

> **Want report-only (don't block the pipeline)?** trustabl fails on medium+ by
> default. To make it advisory, change the build command in your buildspec to:
> `- bash "$CODEBUILD_SRC_DIR/scan/trustabl-scan.sh" || true`

### CLI (alternative to steps 2–3)
After vendoring (step 1), replace `<you>/<repo>` and `<acct>`:

```bash
# one-time: a CodeBuild service role (trust + CloudWatch Logs)
aws iam create-role --role-name trustabl-codebuild \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"codebuild.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam put-role-policy --role-name trustabl-codebuild --policy-name logs \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],"Resource":"*"}]}'
# CodeBuild Reports are optional — see "Enable CodeBuild Reports" below. Do not
# attach report-group IAM unless you uncomment `reports:` in the buildspec.

# create the project, pointing at your repo's vendored buildspec
aws codebuild create-project --name trustabl-scan \
  --source '{"type":"GITHUB","location":"https://github.com/<you>/<repo>.git","buildspec":"codepipeline/buildspec.yml"}' \
  --artifacts '{"type":"NO_ARTIFACTS"}' \
  --environment '{"type":"LINUX_CONTAINER","image":"aws/codebuild/standard:7.0","computeType":"BUILD_GENERAL1_SMALL"}' \
  --service-role arn:aws:iam::<acct>:role/trustabl-codebuild

# run a one-off scan (gate + logs). Private repos need a one-time:
#   aws codebuild import-source-credentials --token <PAT> --server-type GITHUB --auth-type PERSONAL_ACCESS_TOKEN
aws codebuild start-build --project-name trustabl-scan
```

`NO_ARTIFACTS` = scan + gate only; use `--artifacts '{"type":"S3","location":"<bucket>","name":"trustabl-results","packaging":"ZIP"}'`
to keep `trustabl.json`/`.sarif`. Wire the project into a pipeline with
`aws codepipeline create-pipeline` (or the console, step 3).

## Enable CodeBuild Reports (opt-in)

Existing Trustabl CodeBuild permissions (logs, plus S3 if you keep artifacts)
are enough to scan and gate. Native Reports need **additional** actions that
the logs-only CLI role above does **not** include:

- `codebuild:CreateReportGroup`
- `codebuild:CreateReport`
- `codebuild:UpdateReport`
- `codebuild:BatchPutTestCases`

Console-created CodeBuild roles often already have these, scoped to the
project. CLI-created logs-only roles do not — attaching Reports IAM without
uncommenting `reports:` does nothing; uncommenting `reports:` without the
IAM leaves the report status `INCOMPLETE` (CodeBuild still finishes
`UPLOAD_ARTIFACTS`; the scan gate is unchanged).

1. Uncomment the `reports:` block at the bottom of `codepipeline/buildspec.yml`.
   The report group name `trustabl-findings` becomes
   `<project-name>-trustabl-findings`.
2. Attach a scoped policy. Copy `codepipeline/iam-reports.json` and replace
   `<region>`, `<account-id>`, and `<project-name>`:

```bash
aws iam put-role-policy --role-name trustabl-codebuild --policy-name reports \
  --policy-document file://codepipeline/iam-reports.json
```

Prefer the report-group ARN in that file over `Resource: "*"`. A project named
`trustabl-scan` in `us-east-1` account `111122223333` uses:

`arn:aws:codebuild:us-east-1:111122223333:report-group/trustabl-scan-trustabl-findings`

CodeBuild does not fail the build because JUnit cases are failures; the
Trustabl scanner exit code remains the only gate. Zero findings produce a
valid empty JUnit suite (0 tests) — we do not fabricate passing cases.

CodeBuild retains reports for **30 days** and shows at most **500** test cases
(name ≤ 1000 characters, message ≤ 5000). If the scan has more than 500
findings, `to-junit.sh` publishes the first 500 after sorting
critical → high → medium → low → info, then `rule_id`, `file_path`,
`start_line`, and logs the truncation. `trustabl.json` / `trustabl.sarif` are
still complete.

**Notes**
- Runs on Linux CodeBuild images only (the script targets Linux/macOS).
- Full input list: see the [root README](../README.md).
