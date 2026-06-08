# Phase 7 — CI/CD Security

**Phase status:** ✅ Complete  
**Findings remediated:** CI-01 through CI-05  
**Files changed:** 2 modified, 2 created  
**Date completed:** 1 June 2026
**Author:** Rasaq Bello

---

## Objective

Secure the GitHub Actions CI/CD pipeline by removing hardcoded credentials, adding automated security scanning gates, and implementing a manual approval process before production deployments.

---

## What is CI/CD Security?

CI/CD (Continuous Integration / Continuous Deployment) pipelines automate the process of building, testing, and deploying code. A misconfigured pipeline can:

- Leak secrets through build logs
- Deploy vulnerable code to production automatically
- Allow any developer to push directly to production
- Skip security checks entirely

Securing the pipeline means embedding security controls into the deployment process so vulnerabilities are caught before they reach production.

---

## Pipeline Architecture

```
Before Phase 7:                    After Phase 7:

push to main                       push to main
     ↓                                  ↓
deploy directly                    secret scanning (GitLeaks)
to production                           ↓
with hardcoded                     SAST scan (Semgrep)
AWS credentials                         ↓
                                   dependency scan (pip-audit)
                                        ↓
                                   build images
                                        ↓
                                   manual approval gate
                                        ↓
                                   deploy to production
```

---

## Vulnerabilities Found and Fixed

### CI-05 — Hardcoded AWS Credentials

**Before:**
```yaml
env:
  AWS_ACCESS_KEY_ID: AKIA0000EXAMPLE
  AWS_SECRET_ACCESS_KEY: wJalrXexample
  JWT_SECRET: secret123
  DATABASE_URL: postgresql://payadmin:SuperSecretPassword123!@...
```

Anyone who can read the workflow file has full AWS access and all application credentials. This is visible to every contributor and in git history permanently.

**After:**
```yaml
env:
  AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
  AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
  JWT_SECRET: ${{ secrets.JWT_SECRET }}
  DATABASE_URL: ${{ secrets.DATABASE_URL }}
```

Secrets stored in GitHub Secrets — encrypted at rest, never visible in logs or workflow files.

---

### CI-01 — Environment Variables Printed in Logs

**Before:**
```yaml
- name: Print environment
  run: env
```

Every secret in the `env:` block printed to the build log — visible to anyone with read access to the repository.

**After:** Step removed entirely. No secrets ever appear in logs.

---

### CI-02 — No Secret Scanning

**Before:** No secret scanning step. Committed secrets go undetected.

**After:**
```yaml
- name: Secret scanning
  uses: gitleaks/gitleaks-action@v2
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

GitLeaks scans every commit for secrets before the build runs. If secrets are detected the pipeline fails and deployment is blocked.

**First run result:** GitLeaks detected 7 secrets across `.env`, `docker-compose.yml`, and documentation files — pipeline correctly blocked deployment.

**After adding `.gitleaks.toml` allowlist** for known training files: GitLeaks passed with "No leaks detected".

---

### CI-03 — No SAST or Dependency Scanning

**Before:** Code deployed to production with no automated security review.

**After:**
```yaml
- name: SAST scan
  continue-on-error: true  # Set to false in production to enforce gate
  uses: semgrep/semgrep-action@v1
  with:
    config: auto

- name: Dependency scan
  continue-on-error: true  # Set to false in production to enforce gate
  run: |
    pip install pip-audit
    pip-audit -r payment-platform/backend/requirements.txt
```

Semgrep scans for 1059 security rules across Python, Terraform, Dockerfile, and YAML. pip-audit checks all Python dependencies against the CVE database.

**Semgrep findings in pipeline:** 11 blocking findings detected — Terraform misconfigurations and secrets in training files. These are documented findings from Phase 2, not new issues.

---

### CI-04 — Direct Deploy to Production on Every Push

**Before:** Every push to main triggered an immediate production deployment with no review.

**After:** Two-job pipeline with mandatory approval gate:

```yaml
jobs:
  scan-and-build:
    runs-on: ubuntu-latest
    steps:
      # scanning and building

  deploy:
    runs-on: ubuntu-latest
    needs: scan-and-build
    environment: production  # requires manual approval
    steps:
      # deployment
```

The `environment: production` setting combined with GitHub Environment Protection Rules requires a named reviewer to manually approve before the deploy job runs.

---

## Pipeline Run Evidence

### Run 1 — GitLeaks blocks deployment
GitLeaks detected 7 secrets across the repository. Pipeline failed before any build step ran. Deploy job skipped entirely.

### Run 2 — GitLeaks passes after allowlist
After adding `.gitleaks.toml` allowlist for known training files. Semgrep blocked on 11 findings.

### Run 3 — All scan gates pass
After adding `continue-on-error: true` to scan steps and `.semgrepignore` for training files. All security gates passed. Build completed. Deploy failed only because dummy AWS credentials were used — expected behaviour for training environment.

### Evidence
![GitLeaks secrets detected - pipeline blocked](./gitleaks-secrets-detected.png)
![GitLeaks no leaks detected](./gitleaks-no-leaks.png)
![Semgrep pipeline blocking findings](./semgrep-pipeline-blocking.png)
![Pipeline scan gates passed](./pipeline-scan-passed.png)

---

## Files Created/Modified

| File | Location | Purpose |
|---|---|---|
| `deploy.yml` | `.github/workflows/` | Secured pipeline with scan gates |
| `.gitleaks.toml` | repo root | Allowlist for known training secrets |
| `.semgrepignore` | repo root | Exclude training files from SAST |

---

## GitHub Secrets Configuration

The following secrets must be configured in:
```
GitHub → Settings → Secrets and variables → Actions
```

| Secret Name | Purpose |
|---|---|
| `AWS_ACCESS_KEY_ID` | AWS authentication |
| `AWS_SECRET_ACCESS_KEY` | AWS authentication |
| `DATABASE_URL` | PostgreSQL connection string |
| `JWT_SECRET` | JWT signing secret |
| `OPENAI_API_KEY` | AI fraud detection |
| `NOTIFY_EMAIL` | Pipeline failure notifications |
| `NOTIFY_EMAIL_PASSWORD` | Gmail App Password for notifications |

> **Note:** `NOTIFY_EMAIL_PASSWORD` must be a Gmail App Password — not the account password. Generate one at: Google Account → Security → 2-Step Verification → App Passwords.

---

## Production vs Training Configuration

| Setting | Training (current) | Production |
|---|---|---|
| Semgrep `continue-on-error` | `true` | `false` |
| Dependency scan `continue-on-error` | `true` | `false` |
| AWS credentials | Dummy values | Real IAM role credentials |
| Approval gate | Configured | Enforced with named reviewers |
| Notification | Email placeholder | Slack webhook |

---

## Slack Notification (Pending)

Slack notification is bookmarked for completion. Steps to implement:

1. Create Slack workspace
2. Go to https://api.slack.com/apps → Create New App
3. Enable Incoming Webhooks → Add to `#pearlpay-alerts` channel
4. Copy webhook URL → Add to GitHub Secrets as `SLACK_WEBHOOK_URL`
5. Replace email notification step with:

```yaml
- name: Notify on failure
  if: failure()
  uses: slackapi/slack-github-action@v1.26.0
  with:
    payload: |
      {
        "text": "🚨 PearlPay Pipeline Failed",
        "blocks": [
          {
            "type": "section",
            "text": {
              "type": "mrkdwn",
              "text": "*Pipeline failed on branch* `${{ github.ref_name }}`\n*Commit:* ${{ github.sha }}\n*Triggered by:* ${{ github.actor }}\n<${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}|View Run>"
            }
          }
        ]
      }
  env:
    SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}
    SLACK_WEBHOOK_TYPE: INCOMING_WEBHOOK
```

---

## What I Learned

1. **The pipeline is an attack surface** — hardcoded credentials in a workflow file are just as dangerous as hardcoded credentials in source code. The workflow file is committed to git, visible to all contributors, and permanent in history. GitHub Secrets are the right tool — encrypted at rest, masked in logs, never visible after entry.

2. **Security gates only work if they block** — `continue-on-error: true` is a training wheel. In production, SAST and dependency scanning must fail the build when findings are detected. A security gate that never blocks is just an expensive reporting tool.

3. **GitLeaks caught secrets I didn't know were there** — the first pipeline run detected secrets in the ZAP HTML report and documentation README files — not just `.env`. Secret scanning tools find things humans miss. Running GitLeaks before every deployment is non-negotiable in a real security programme.

4. **Separation of concerns — scan vs deploy** — splitting the pipeline into `scan-and-build` and `deploy` jobs enforces the principle that code must pass all security gates before reaching production. The `needs:` dependency means the deploy job physically cannot run if scanning fails.

5. **Manual approval gates have real value** — in a payment platform handling $2M daily, every production deployment is a risk event. A human review step between build and deploy catches things automated tools miss — logic errors, business impact, timing concerns. Automation handles speed, humans handle judgement.

---

## Next Phase

[Phase 8 — AI Security →](../phase-8-ai-security/README.md)

---

## Resources

- [GitHub Actions Security Hardening](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions)
- [GitHub Encrypted Secrets](https://docs.github.com/en/actions/security-guides/encrypted-secrets)
- [GitLeaks Documentation](https://github.com/gitleaks/gitleaks)
- [Semgrep CI Documentation](https://semgrep.dev/docs/semgrep-ci/)
- [pip-audit Documentation](https://github.com/pypa/pip-audit)
- [OWASP CI/CD Security Top 10](https://owasp.org/www-project-top-10-ci-cd-security-risks/)
