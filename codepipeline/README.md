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
`trustabl-summary.md`, `trustabl.env`, `trustabl.asff.json`) are emitted to the
artifact bucket.

**Optional — Security Hub:** set `SECURITY_HUB=true` on the CodeBuild project.
The scanner writes `trustabl.asff.json` and then calls
`aws securityhub batch-import-findings`. Needs Security Hub enabled in the
region and IAM `securityhub:BatchImportFindings` plus `sts:GetCallerIdentity`
on the CodeBuild role.

## Quickstart — from zero (console)

**You need:** an AWS account, your code in a repo AWS can read (GitHub via a
CodeStar connection, CodeCommit, or S3), and a CodePipeline (or make one).

### 1. Vendor the plugin into your repo
Copy these two into your repo, keeping the layout, then commit + push:

```
your-repo/
├── scan/trustabl-scan.sh        # the scanner
├── scan/to-asff.sh              # JSON → Security Hub ASFF
└── codepipeline/buildspec.yml   # tells CodeBuild to run it
```

### 2. Make a CodeBuild project
Console → **CodeBuild → Create build project**:
- **Environment image:** `aws/codebuild/standard:7.0` (has bash, curl, jq, git)
- **Buildspec:** "Use a buildspec file" → path `codepipeline/buildspec.yml`
- **Service role:** let CodeBuild create one (it needs CloudWatch Logs)
- *(optional)* **Env vars:** `SEVERITY_THRESHOLD`, `RISK_SCORE_THRESHOLD`,
  `VERSION` (pin a tag), `GITHUB_TOKEN` (dodges GitHub's 60-req/hr anon limit),
  `REPORT_ONLY=true` (trial without gating), `SECURITY_HUB=true` (import ASFF)
- **`GITHUB_TOKEN` is a credential** — add it with type **Secrets Manager** or
  **Parameter Store**, not as a plaintext environment variable. Plaintext env
  vars are readable by anyone with `codebuild:BatchGetProjects`.

### 3. Add it to your pipeline
CodePipeline → your pipeline → **Edit** → add a **Build/Test** stage →
action provider **AWS CodeBuild** → pick the project → input artifact = your
Source output → **add an output artifact** (name it e.g. `TrustablResults`).

The output artifact is not optional if you want the reports. A CodeBuild action
takes [`0 to 5` output artifacts](https://docs.aws.amazon.com/codepipeline/latest/userguide/action-reference-CodeBuild.html#action-reference-CodeBuild-output),
and they are what "make the artifacts that are defined in the CodeBuild
buildspec file available to subsequent actions". Declare none and the
`artifacts:` block in `buildspec.yml` has nowhere to go — the gate still works,
but `trustabl.json` / `trustabl.sarif` are discarded with the container.

### 4. Run it (Release change)
Each run downloads the trustabl binary (sha256-verified), scans your checkout,
prints the readiness report, uploads `trustabl.json` / `trustabl.sarif` /
`trustabl-summary.md` / `trustabl.env` as artifacts, and **fails the stage if
any finding is medium-or-higher** — so the pipeline stops on unsafe agent code.

> **Want report-only (don't block the pipeline)?** Set `REPORT_ONLY=true` on
> the CodeBuild project. That publishes artifacts and still fails the build on
> scanner errors (exit 2). Do not use `|| true` — that also swallows a dead
> scanner, which [docs/EVALUATION.md](../docs/EVALUATION.md) says not to trust.
>
> Equivalent without the env var: change the build command in your buildspec to
> `- bash "$CODEBUILD_SRC_DIR/scan/trustabl-scan.sh" || [ $? -eq 1 ]`.
> Exit 1 means the scan ran and gated; exit 2 means it did not run — a missing
> tool, an unreachable release, unusable rules. See
> [exit codes](../docs/EVALUATION.md#exit-codes).

### CLI (alternative to steps 2–3)
After vendoring (step 1), replace `<you>/<repo>` and `<acct>`:

```bash
# one-time: connect the account to GitHub. Required for ANY GitHub source, not
# just private repos, and it must happen BEFORE create-project -- otherwise the
# next command fails with "No Access token found".
aws codebuild import-source-credentials --token <PAT> \
  --server-type GITHUB --auth-type PERSONAL_ACCESS_TOKEN

# one-time: a CodeBuild service role (trust + CloudWatch Logs)
aws iam create-role --role-name trustabl-codebuild \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"codebuild.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam put-role-policy --role-name trustabl-codebuild --policy-name logs \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],"Resource":"*"}]}'

# create the project, pointing at your repo's vendored buildspec
aws codebuild create-project --name trustabl-scan \
  --source '{"type":"GITHUB","location":"https://github.com/<you>/<repo>.git","buildspec":"codepipeline/buildspec.yml"}' \
  --artifacts '{"type":"NO_ARTIFACTS"}' \
  --environment '{"type":"LINUX_CONTAINER","image":"aws/codebuild/standard:7.0","computeType":"BUILD_GENERAL1_SMALL"}' \
  --service-role arn:aws:iam::<acct>:role/trustabl-codebuild

# run a one-off scan (gate + logs)
aws codebuild start-build --project-name trustabl-scan
```

`NO_ARTIFACTS` = scan + gate only. To keep `trustabl.json`/`.sarif`, switch to
`--artifacts '{"type":"S3","location":"<bucket>","name":"trustabl-results","packaging":"ZIP"}'`
— and grant the service role write access to that bucket, which the logs-only
policy above does not:

```bash
aws iam put-role-policy --role-name trustabl-codebuild --policy-name artifacts \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:PutObject","s3:GetBucketAcl","s3:GetBucketLocation"],"Resource":["arn:aws:s3:::<bucket>","arn:aws:s3:::<bucket>/*"]}]}'
```

Without it `UPLOAD_ARTIFACTS` fails with AccessDenied and the build goes red for
a reason unrelated to the scan. An SSE-KMS bucket also needs `kms:GenerateDataKey`
on the key. Wire the project into a pipeline with `aws codepipeline
create-pipeline` (or the console, step 3).

**Notes**
- Runs on Linux CodeBuild images only (the script targets Linux/macOS).
- **Set `BRANCH` if you want a meaningful branch label.** In a pipeline-triggered
  build the script cannot work it out: `CODEBUILD_WEBHOOK_HEAD_REF` is set only
  for *webhook* events, `CODEBUILD_SOURCE_REPO_URL` "may be empty" when the build
  originates from CodePipeline, and a source artifact is an unzipped snapshot
  with no `.git` to fall back on. Without it every report reads
  `Repository: .` / `Branch: unknown`. Pass the real values as environment
  variables on the action — `BRANCH` is read by the script but is not in the
  root README's inputs table.
- **Don't change `SARIF_FILE` / `JSON_FILE`** unless you also edit the
  `artifacts.files` list in `buildspec.yml` to match. The script honours them,
  but the buildspec collects the default names — point them elsewhere and the
  files are produced and then silently dropped, with nothing in the log to say
  why.
- Full input list: see the [root README](../README.md).
