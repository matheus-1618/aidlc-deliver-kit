# Release Gate

MANDATORY: Follow stage-protocol.md for approval gates, question format, and completion messages.

This stage turns finished code into a release candidate and parks for the HUMAN
release decision. Nothing is merged here — merging happens in deploy-execute,
strictly after approval.

## Steps

### Step 1: Load Agent Personas

Load aidlc-release-manager-agent persona from `agents/aidlc-release-manager-agent.md` and knowledge from `{{HARNESS_DIR}}/knowledge/aidlc-release-manager-agent/`.

### Step 2: Assess the release candidate

- Identify the current intent branch (the branch this workspace is on: `git branch --show-current`).
- Verify the working tree is clean and pushed; if the engine reports unpushed work, stop and report.
- Confirm the canonical structure exists per the deliver flavor the intent references (see the flavor knowledge): at minimum `site/index.html` and `infra/main.tf`; the lambda-backend flavor also requires `backend/index.mjs`. If either is missing, this intent is not deliverable — write the gap in the release notes and park with a question explaining what is missing.

### Step 3: Open (or find) the release pull request

Using the `github` MCP server:
- Check with `list_pull_requests` whether an open PR already exists from the intent branch to `main`. If yes, reuse it.
- Otherwise `create_pull_request`: base `main`, head the intent branch, title `Release: <intent title>`, body summarizing WHAT is being released (site content, infrastructure resources the terraform will create, flavor name) and linking the intent.

### Step 4: Write the release notes artifact

Write `release-notes.md` (under this stage's record dir, engine-resolved) containing:
- PR number and URL
- The exact resources `infra/main.tf` will create (read the file; list them)
- The flavor's security invariants and whether the code respects them (each invariant listed in the flavor's knowledge: bucket public access blocked, OAC, default_tags, `deliver-` prefix, empty backend block, and for lambda-backend the exec-role minimalism) — check each one explicitly against the file content
- Estimated monthly cost order-of-magnitude (static-site: cents)
- The rollback path (destroy-production workflow)

### Step 5: Park for the release decision

Park with a single decision question per stage-protocol: "Release PR #<n> to production?" summarizing the release notes. The human answer is the gate. Do not proceed past this point in this stage.

## Outputs

release-notes.md (under this stage's record dir, engine-resolved)
---8<---STAGE-SPLIT---
# Deploy Execute

MANDATORY: Follow stage-protocol.md for approval gates, question format, and completion messages.

The release gate has been approved. This stage merges the release PR and drives
the production pipeline to completion. You never touch cloud credentials — the
pipeline does the deploying; you conduct and record it.

## Steps

### Step 1: Load Agent Personas

Load aidlc-release-manager-agent persona from `agents/aidlc-release-manager-agent.md` and knowledge from `{{HARNESS_DIR}}/knowledge/aidlc-release-manager-agent/`.

### Step 2: Load Prior Context

Read `release-notes.md` from `<record>/operation/release-gate/` — it carries the PR number this stage acts on. If it is absent, stop and report: the release gate did not complete.

### Step 3: Merge the release PR

Using the `github` MCP server: `merge_pull_request` with merge_method `squash`. Record the merge commit SHA. If the merge is rejected (conflict, branch protection), do NOT force anything — write the failure detail to the deployment log and park with a question describing the conflict and the options.

### Step 4: Watch the pipeline run

The merge push triggers workflow `deploy-production`. Poll with `actions_list` (filter by the workflow, branch `main`) until the run for your merge commit appears, then `actions_get` every ~30 seconds until it reaches a conclusion. Bound your patience: if the run has not concluded after 15 minutes, record the timeout and park with a question.

Run selection rules (there may be more than one run on `main`):
- Adopt the run whose head SHA equals YOUR merge commit. Prefer `push`-event runs; among candidates, the most recent.
- A re-run of a failed run raises `run_attempt` on the SAME run id — always read the latest attempt's conclusion, and record the full attempt history in the deployment log.

### Step 4b: Pipeline failure — the retry is conducted HERE, never outside

If the adopted run concludes `failure`:
1. Fetch the failed step's log tail with `get_job_logs` (failed_only) and write the exact error into the deployment log.
2. Park with a question carrying the error and these options: (A) retry the pipeline, (B) abort the release. Diagnose in the question text whether the failure looks transient (network, throttling) or structural (permissions, invalid template) — a structural failure will fail again unchanged, and the question must say so.
3. On approval of retry: re-trigger the pipeline yourself with `actions_run_trigger` (workflow `deploy-production`, ref `main`), adopt the NEW run, and return to Step 4. Never ask a human to click anything in GitHub; the platform conducts, GitHub executes.
4. On abort: record the decision and finish the stage reporting the release did NOT reach production.

### Step 5: Extract the deploy outputs

On conclusion `success`: fetch the deploy job logs with `get_job_logs` and extract the deploy-outputs JSON block (keys: status, url, site_bucket, distribution_id, commit, run_url, deployed_at).
On conclusion `failure`: follow Step 4b — the failure/retry loop lives inside this stage.

## Outputs

deployment-log.md (under this stage's record dir, engine-resolved) — merge SHA, run id and URL, conclusion, timing, and the raw deploy-outputs JSON block fenced verbatim.
---8<---STAGE-SPLIT---
# Deploy Verify

MANDATORY: Follow stage-protocol.md for approval gates, question format, and completion messages.

The pipeline reported a deploy. This stage independently verifies the running
environment and materializes the environment manifest — the platform's
canonical record of WHAT is on the air. The blocking sensor on this stage fails
it if the manifest is missing or malformed: write it exactly as specified.

## Steps

### Step 1: Load Agent Personas

Load aidlc-release-manager-agent persona from `agents/aidlc-release-manager-agent.md` and knowledge from `{{HARNESS_DIR}}/knowledge/aidlc-release-manager-agent/`.

### Step 2: Load Prior Context

Read `deployment-log.md` from `<record>/operation/deploy-execute/` and parse the deploy-outputs JSON block (url, site_bucket, distribution_id, commit, run_url, deployed_at).

### Step 3: Verify the environment independently

- `curl -sS -o /dev/null -w '%{http_code}' <url>` — expect 200. CloudFront may take a minute to settle: retry up to 6 times, 20 seconds apart.
- `curl -sS <url>` — confirm the body is the site's HTML (contains the `<title>` your site defined).
- Record the observed HTTP status.

### Step 4: Write the environment manifest

Write `environments/production.json` at the REPOSITORY ROOT of the workspace (not the record dir), exactly per the flavor's manifest schema (see the flavor knowledge); resources carries site_bucket and distribution_id, plus backend_function and api_url when the flavor has a backend. This file is the machine-readable state of production and lives in git history.

### Step 5: Write the verification report

Write `deploy-verification.md` (under this stage's record dir, engine-resolved): the URL, verification method and observed status, the full manifest fenced, and the teardown instruction (workflow `destroy-production`, trigger via `actions_run_trigger` or the GitHub UI).

### Step 6: Park for final acknowledgement

Park with a question presenting the LIVE URL and the manifest summary: "Production verified at <url> (HTTP 200). Acknowledge to close the delivery." This is the demo's closing moment — make the summary worthy of it.

## Outputs

deploy-verification.md (under this stage's record dir, engine-resolved); environments/production.json (repository root — committed by the engine with this stage's work)
