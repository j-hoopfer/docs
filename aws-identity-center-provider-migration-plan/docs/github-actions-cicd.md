# GitHub Actions CI/CD for Terraform

Automate Terraform deployments with GitHub Actions using secure OIDC authentication (no static AWS credentials).

---

## User Stories

### Story 1: Developer Creates Pull Request

**As a developer, when I create a PR:**

1. I push changes to a feature branch
2. GitHub Actions automatically runs:
   - `terraform fmt -check` (code formatting validation)
   - `terraform validate` (syntax validation)
   - `terraform plan` (preview changes)
3. Plan output is posted as a comment on my PR
4. I can review what will change before merging
5. Team reviews PR and plan output
6. If checks fail, I fix issues and push again

**Result:** No surprises - I see exactly what will change before it's applied.

### Story 2: PR Gets Merged to Develop

**As a developer, when my PR is approved and merged:**

1. PR is merged to `develop` branch
2. GitHub Actions automatically:
   - Runs `terraform plan` one more time (verify nothing changed)
   - Runs `terraform apply` to Dev environment
   - Posts results as a comment
3. Changes are live in Dev within minutes
4. I can verify changes in Dev environment

**Result:** Automatic deployment to Dev - no manual steps.

### Story 3: Deploying to Production

**As a platform engineer, when promoting to Production:**

1. Create a PR from `develop` to `main` branch
2. GitHub Actions runs `terraform plan` against Prod backend
3. Team reviews plan and approves PR
4. PR is merged to `main`
5. GitHub Actions automatically deploys to Prod (with environment approval)
6. Deployment results posted to Slack/GitHub

**Result:** Production deployments are controlled, auditable, and `main` always reflects production state.

### Story 4: Rollback When Things Break

**As an engineer, when something breaks:**

1. Revert the merged PR in GitHub
2. GitHub Actions automatically applies the previous state
3. Infrastructure reverts to last known good state
4. Incident resolved

**Result:** Fast rollback using Git history.

---

## Architecture Overview

**Important:** AWS Identity Center is a **global service** - there is ONE instance per AWS Organization, not separate instances per environment.

```
┌─────────────────────────────────────────────────────────┐
│ GitHub Repository (tf-aws-identity)                     │
│                                                          │
│  ┌──────────────┐      ┌──────────────┐                │
│  │ Pull Request │─────▶│ Terraform    │                │
│  │ to develop   │      │ Plan         │                │
│  └──────────────┘      └──────┬───────┘                │
│                               │                         │
│                          Post comment                   │
│                          (review carefully!)            │
│                               │                         │
│  ┌──────────────┐      ┌─────▼────────┐                │
│  │ PR develop   │─────▶│ Terraform    │                │
│  │ → main       │      │ Plan         │                │
│  └──────────────┘      └──────┬───────┘                │
│                               │                         │
│  ┌──────────────┐      ┌─────▼────────┐                │
│  │ Merge to     │─────▶│ Terraform    │◀── Manual     │
│  │ main         │      │ Apply        │    Approval    │
│  │ (Stable)     │      │              │    Required!   │
│  └──────────────┘      └──────┬───────┘                │
│                               │                         │
└───────────────────────────────┼─────────────────────────┘
                                │
                         OIDC Authentication
                                │
                ┌───────────────▼────────────────┐
                │ AWS Organization               │
                │ Management Account             │
                │                                │
                │ ┌────────────────────────┐    │
                │ │ Identity Center        │    │
                │ │ (Global Service)       │    │
                │ │                        │    │
                │ │ Manages SSO for:       │    │
                │ │ • Dev Account          │    │
                │ │ • Prod Account         │    │
                │ │ • All other accounts   │    │
                │ └────────────────────────┘    │
                │                                │
                │ ┌────────────────────────┐    │
                │ │ S3 State Bucket        │    │
                │ │ terraform-state-mgmt-* │    │
                │ └────────────────────────┘    │
                └────────────────────────────────┘
```

**Key Point:** You're managing ONE Identity Center instance that controls access to ALL accounts in your organization. There is no "dev Identity Center" to test in.

---

## Part 1: AWS OIDC Setup (One-Time)

### What is OIDC?

**Old way (bad):**

- Create AWS access keys (long-lived credentials)
- Store in GitHub Secrets
- If GitHub is compromised, your AWS is compromised

**New way (OIDC - good):**

- GitHub requests temporary credentials from AWS
- AWS verifies request came from your GitHub repo
- Issues temporary credentials (valid 1 hour)
- No static credentials stored anywhere

### Step 1: Create OIDC Provider in AWS

Run this in **each AWS account** (Dev and Prod):

```bash
# Set your AWS profile
export AWS_PROFILE=dev  # Or prod

# Create OIDC provider for GitHub
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1

# Verify it was created
aws iam list-open-id-connect-providers
```

**Expected output:**

```json
{
  "OpenIDConnectProviderList": [
    {
      "Arn": "arn:aws:iam::471112975126:oidc-provider/token.actions.githubusercontent.com"
    }
  ]
}
```

### Step 2: Create IAM Role for GitHub Actions

**For Dev account (471112975126):**

```bash
export AWS_PROFILE=dev
export AWS_ACCOUNT_ID="471112975126"
export GITHUB_ORG="your-github-org"  # Replace with your GitHub org/user
export GITHUB_REPO="tf-aws-identity"

# Create trust policy
cat > /tmp/github-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${GITHUB_ORG}/${GITHUB_REPO}:*"
        }
      }
    }
  ]
}
EOF

# Create the role
aws iam create-role \
  --role-name GitHubActionsTerraformRole \
  --assume-role-policy-document file:///tmp/github-trust-policy.json \
  --description "Role for GitHub Actions to deploy Terraform" \
  --tags Key=ManagedBy,Value=Manual Key=Purpose,Value=CICD

# Create permissions policy
cat > /tmp/github-permissions.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformStateAccess",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetObject",
        "s3:PutObject"
      ],
      "Resource": [
        "arn:aws:s3:::terraform-state-dev-${AWS_ACCOUNT_ID}",
        "arn:aws:s3:::terraform-state-dev-${AWS_ACCOUNT_ID}/*"
      ]
    },
    {
      "Sid": "TerraformStateLocking",
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:DeleteItem"
      ],
      "Resource": "arn:aws:dynamodb:us-east-1:${AWS_ACCOUNT_ID}:table/terraform-state-locks"
    },
    {
      "Sid": "IdentityCenterManagement",
      "Effect": "Allow",
      "Action": [
        "sso:*",
        "sso-admin:*",
        "identitystore:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ReadOnlyAccess",
      "Effect": "Allow",
      "Action": [
        "organizations:Describe*",
        "organizations:List*"
      ],
      "Resource": "*"
    }
  ]
}
EOF

# Attach permissions policy
aws iam put-role-policy \
  --role-name GitHubActionsTerraformRole \
  --policy-name TerraformDeploymentPolicy \
  --policy-document file:///tmp/github-permissions.json

echo "✅ Role created: arn:aws:iam::${AWS_ACCOUNT_ID}:role/GitHubActionsTerraformRole"
```

**Repeat for Prod account** (change `AWS_ACCOUNT_ID` and `AWS_PROFILE`):

```bash
export AWS_PROFILE=prod
export AWS_ACCOUNT_ID="637423317953"
# Run the same commands above
```

### Step 3: Save Role ARNs

Save these for your GitHub Actions workflows:

```bash
# Dev Role ARN
arn:aws:iam::471112975126:role/GitHubActionsTerraformRole

# Prod Role ARN
arn:aws:iam::637423317953:role/GitHubActionsTerraformRole
```

---

## Part 2: GitHub Repository Setup

### Step 1: Create GitHub Secrets

Go to your repo: **Settings → Secrets and variables → Actions → New repository secret**

Add these secrets:

| Secret Name         | Value                                                       | Description   |
| ------------------- | ----------------------------------------------------------- | ------------- |
| `AWS_ROLE_ARN_DEV`  | `arn:aws:iam::471112975126:role/GitHubActionsTerraformRole` | Dev IAM role  |
| `AWS_ROLE_ARN_PROD` | `arn:aws:iam::637423317953:role/GitHubActionsTerraformRole` | Prod IAM role |

**Note:** AWS account IDs are not secret, but role ARNs are convenient to store as secrets for reusability.

### Step 2: Enable GitHub Environments (Optional but Recommended)

Go to **Settings → Environments → New environment**

**Create two environments:**

1. **dev**
   - No protection rules (automatic deployments)
2. **production**
   - ✅ Required reviewers: `@platform-team` (or specific users)
   - ✅ Wait timer: 5 minutes (gives time to cancel if needed)

This forces manual approval for Prod deployments.

---

## Part 3: Workflow Files

### Workflow 1: Pull Request (Plan Only)

Create `.github/workflows/terraform-plan.yml`:

```yaml
name: Terraform Plan

on:
  pull_request:
    paths:
      - "identity-center/**"
      - "common/**"
      - "backend-*.hcl"
      - ".github/workflows/terraform-plan.yml"

permissions:
  id-token: write # Required for OIDC
  contents: read
  pull-requests: write # Post plan as comment

env:
  TF_VERSION: "1.6.0"
  AWS_REGION: "us-east-1"

jobs:
  validate:
    name: Validate Terraform
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Terraform Format Check
        run: terraform fmt -check -recursive
        continue-on-error: false

      - name: Terraform Init
        run: terraform init -backend=false
        working-directory: identity-center/

      - name: Terraform Validate
        run: terraform validate
        working-directory: identity-center/

  plan-dev:
    name: Plan (Dev)
    runs-on: ubuntu-latest
    needs: validate

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Configure AWS Credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN_DEV }}
          aws-region: ${{ env.AWS_REGION }}
          role-session-name: GitHubActions-TerraformPlan

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Terraform Init
        run: terraform init -backend-config=../backend-dev.hcl
        working-directory: identity-center/

      - name: Terraform Plan
        id: plan
        run: |
          terraform plan -no-color -out=tfplan 2>&1 | tee plan.txt
          echo "exitcode=$?" >> $GITHUB_OUTPUT
        working-directory: identity-center/
        continue-on-error: true

      - name: Post Plan to PR
        uses: actions/github-script@v7
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          script: |
            const fs = require('fs');
            const plan = fs.readFileSync('identity-center/plan.txt', 'utf8');
            const truncatedPlan = plan.length > 65000 ? plan.substring(0, 65000) + '\n\n... (truncated)' : plan;

            const output = `#### Terraform Plan (Dev) 📝

            <details><summary>Show Plan</summary>

            \`\`\`terraform
            ${truncatedPlan}
            \`\`\`

            </details>

            *Pusher: @${{ github.actor }}, Action: \`${{ github.event_name }}\`*`;

            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: output
            });

      - name: Fail if Plan Failed
        if: steps.plan.outputs.exitcode != 0
        run: exit 1
```

### Workflow 2: Dev Deployment (On Merge to Develop)

Create `.github/workflows/terraform-deploy-dev.yml`:

```yaml
name: Deploy to Dev

on:
  push:
    branches:
      - develop
    paths:
      - "identity-center/**"
      - "common/**"
      - "backend-dev.hcl"

permissions:
  id-token: write
  contents: read
  pull-requests: write

env:
  TF_VERSION: "1.6.0"
  AWS_REGION: "us-east-1"

jobs:
  deploy:
    name: Deploy to Dev
    runs-on: ubuntu-latest
    environment: dev

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Configure AWS Credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN_DEV }}
          aws-region: ${{ env.AWS_REGION }}
          role-session-name: GitHubActions-TerraformApply-Dev

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Terraform Init
        run: terraform init -backend-config=../backend-dev.hcl
        working-directory: identity-center/

      - name: Terraform Plan
        run: terraform plan -out=tfplan
        working-directory: identity-center/

      - name: Terraform Apply
        run: terraform apply -auto-approve tfplan
        working-directory: identity-center/

      - name: Post Result
        if: always()
        uses: actions/github-script@v7
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          script: |
            const status = '${{ job.status }}';
            const emoji = status === 'success' ? '✅' : '❌';
            const message = `${emoji} Terraform deployment to **Dev** ${status}

            - Commit: ${{ github.sha }}
            - Actor: @${{ github.actor }}
            - Workflow: ${{ github.run_id }}`;

            // Post as commit comment
            github.rest.repos.createCommitComment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              commit_sha: context.sha,
              body: message
            });
```

### Workflow 3: Prod Deployment (On Merge to Main)

Create `.github/workflows/terraform-deploy-prod.yml`:

```yaml
name: Deploy to Production

on:
  push:
    branches:
      - main
    paths:
      - "identity-center/**"
      - "common/**"
      - "backend-prod.hcl"

permissions:
  id-token: write
  contents: read

env:
  TF_VERSION: "1.6.0"
  AWS_REGION: "us-east-1"

jobs:
  plan:
    name: Plan (Production)
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Configure AWS Credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN_PROD }}
          aws-region: ${{ env.AWS_REGION }}
          role-session-name: GitHubActions-TerraformPlan-Prod

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Terraform Init
        run: terraform init -backend-config=../backend-prod.hcl
        working-directory: identity-center/

      - name: Terraform Plan
        run: terraform plan -out=tfplan
        working-directory: identity-center/

      - name: Upload Plan Artifact
        uses: actions/upload-artifact@v4
        with:
          name: tfplan-prod
          path: identity-center/tfplan
          retention-days: 5

  deploy:
    name: Deploy to Production
    runs-on: ubuntu-latest
    needs: plan
    environment: production # Requires manual approval

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Configure AWS Credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN_PROD }}
          aws-region: ${{ env.AWS_REGION }}
          role-session-name: GitHubActions-TerraformApply-Prod

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Download Plan Artifact
        uses: actions/download-artifact@v4
        with:
          name: tfplan-prod
          path: identity-center/

      - name: Terraform Init
        run: terraform init -backend-config=../backend-prod.hcl
        working-directory: identity-center/

      - name: Terraform Apply
        run: terraform apply -auto-approve tfplan
        working-directory: identity-center/

      - name: Create Release
        uses: actions/create-release@v1
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          tag_name: ${{ github.ref }}
          release_name: Release ${{ github.ref }}
          body: |
            Deployed to Production

            - Infrastructure: AWS Identity Center
            - Environment: Production (637423317953)
            - Deployed by: @${{ github.actor }}
```

---

## Part 4: Usage Workflows

### Scenario 1: Normal Development

```bash
# 1. Create feature branch from develop
git checkout develop
git pull
git checkout -b feature/add-new-permission-set

# 2. Make changes to identity-center/main.tf
# (Add new permission set, update groups, etc.)

# 3. Commit and push
git add .
git commit -m "Add DataScientist permission set"
git push origin feature/add-new-permission-set

# 4. Create PR to develop branch in GitHub
# → GitHub Actions runs terraform plan against Dev
# → Plan is posted as comment on PR

# 5. Review plan, get approval, merge PR to develop
# → GitHub Actions automatically deploys to Dev

# 6. Verify changes in Dev environment
# → Test thoroughly before promoting to main
```

### Scenario 2: Deploy to Production

```bash
# 1. After testing in Dev, create PR from develop to main
git checkout develop
git pull

# In GitHub UI: Create Pull Request
# Base: main ← Compare: develop
# Title: "Release: Add DataScientist permission set"

# 2. GitHub Actions workflow runs
# → Runs terraform plan against Prod
# → Plan posted as comment on PR

# 3. Team reviews plan, approves PR
# → Merge PR to main

# 4. GitHub Actions deployment triggers
# → Waits for manual approval (environment protection)
# → Platform engineer approves in GitHub UI
# → Terraform apply runs against Prod

# 5. Verify changes in Prod environment
# → main branch now reflects production state
```

### Scenario 3: Rollback

```bash
# Rollback Dev (develop branch)
git checkout develop
git revert <commit-hash>
git push origin develop
# → Auto-deploys reverted state to Dev

# Rollback Prod (main branch)
# Method 1: Revert via PR
git checkout develop
git revert <commit-hash>
git push origin develop
# Test in Dev, then create PR develop → main

# Method 2: Emergency rollback (direct to main - use sparingly)
git checkout main
git revert <commit-hash>
git push origin main
# → Requires approval, then deploys to Prod
# → Update develop to match:
git checkout develop
git merge main
git push origin develop
```

---

## Part 5: Security Best Practices

### ✅ DO:

1. **Use OIDC (never static credentials)**

   ```yaml
   # Good
   uses: aws-actions/configure-aws-credentials@v4
   with:
     role-to-assume: ${{ secrets.AWS_ROLE_ARN }}

   # Bad - never do this
   env:
     AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY }}
     AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_KEY }}
   ```

2. **Restrict OIDC role to specific repo**

   ```json
   "StringLike": {
     "token.actions.githubusercontent.com:sub": "repo:your-org/tf-aws-identity:*"
   }
   ```

3. **Use environment protection for Prod**
   - Require manual approval
   - Restrict to specific reviewers
   - Add wait timer

4. **Enable branch protection on `main` and `develop`**
   - **`main` branch (production):**
     - Require PR reviews (at least 2 approvers)
     - Require status checks to pass (terraform plan)
     - No direct pushes to main
     - Only allow merges from `develop`
   - **`develop` branch (development):**
     - Require PR reviews (at least 1 approver)
     - Require status checks to pass
     - No direct pushes to develop

5. **Audit deployments**

   ```bash
   # Review GitHub Actions logs
   # Check AWS CloudTrail for assumed role activity
   ```

6. **Use least-privilege IAM permissions**
   - Only grant permissions needed for Terraform
   - Separate roles for plan vs. apply (advanced)

### ❌ DON'T:

1. **Never store AWS credentials in GitHub Secrets**
2. **Never run `terraform apply` on PRs** (only on merge)
3. **Never skip approval for Prod deployments**
4. **Never give GitHub Actions admin access** (only what Terraform needs)
5. **Never commit `.tfstate` files** (already ignored by `.gitignore`)

---

## Part 6: Advanced Features

### Feature: Terraform Plan on Every Commit

Modify `terraform-plan.yml`:

```yaml
on:
  pull_request:
    # ... existing config
  push:
    branches-ignore:
      - main # Run plan on all branches except main
```

### Feature: Slack Notifications

Add to any workflow:

```yaml
- name: Notify Slack
  if: always()
  uses: slackapi/slack-github-action@v1
  with:
    payload: |
      {
        "text": "Terraform deployment ${{ job.status }}",
        "blocks": [
          {
            "type": "section",
            "text": {
              "type": "mrkdwn",
              "text": "*Terraform Deployment*\nStatus: ${{ job.status }}\nActor: @${{ github.actor }}\nEnvironment: Dev"
            }
          }
        ]
      }
  env:
    SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK }}
```

### Feature: Terraform Drift Detection

Create `.github/workflows/terraform-drift.yml`:

```yaml
name: Drift Detection

on:
  schedule:
    - cron: "0 9 * * MON" # Every Monday at 9 AM

jobs:
  detect-drift:
    runs-on: ubuntu-latest
    steps:
      # ... same setup as plan workflow

      - name: Terraform Plan (Drift Check)
        run: terraform plan -detailed-exitcode
        # Exit code 2 = changes detected (drift)

      - name: Create Issue if Drift Detected
        if: failure()
        uses: actions/github-script@v7
        with:
          script: |
            github.rest.issues.create({
              owner: context.repo.owner,
              repo: context.repo.repo,
              title: '🚨 Terraform Drift Detected in Dev',
              body: 'Scheduled drift detection found changes. Review immediately.',
              labels: ['terraform', 'drift']
            });
```

### Feature: Cost Estimation with Infracost

Add to `terraform-plan.yml`:

```yaml
- name: Setup Infracost
  uses: infracost/actions/setup@v2
  with:
    api-key: ${{ secrets.INFRACOST_API_KEY }}

- name: Generate Cost Estimate
  run: |
    infracost breakdown --path identity-center/ \
      --format json --out-file /tmp/infracost.json

- name: Post Cost Comment
  run: |
    infracost comment github --path /tmp/infracost.json \
      --repo ${{ github.repository }} \
      --pull-request ${{ github.event.number }} \
      --github-token ${{ secrets.GITHUB_TOKEN }}
```

---

## Troubleshooting

### Error: "No credentials found"

```
Error: failed to configure AWS credentials
```

**Fix:**

1. Verify OIDC provider exists in AWS:

   ```bash
   aws iam list-open-id-connect-providers
   ```

2. Check role trust policy allows your repo:

   ```bash
   aws iam get-role --role-name GitHubActionsTerraformRole
   ```

3. Verify secret `AWS_ROLE_ARN_DEV` is set in GitHub

### Error: "Access Denied" during apply

```
Error: operation error S3: PutObject, https response error StatusCode: 403
```

**Fix:** IAM role doesn't have S3 permissions. Update role policy:

```bash
aws iam get-role-policy \
  --role-name GitHubActionsTerraformRole \
  --policy-name TerraformDeploymentPolicy
```

### Error: "Backend initialization required"

```
Error: Backend configuration changed
```

**Fix:** Ensure `terraform init` runs before `terraform plan/apply`:

```yaml
- name: Terraform Init
  run: terraform init -backend-config=../backend-dev.hcl
```

### Workflow doesn't trigger

**Check:**

1. Workflow file is in `.github/workflows/` directory
2. YAML syntax is valid (use YAML linter)
3. `on:` triggers match your actions (push to main, PR, etc.)
4. File paths in `paths:` filter match your changes

### Plan comment doesn't appear on PR

**Fix:** Ensure workflow has `pull-requests: write` permission:

```yaml
permissions:
  id-token: write
  contents: read
  pull-requests: write # Required!
```

---

## Complete File Checklist

After setup, you should have:

```
tf-aws-identity/
├── .github/
│   └── workflows/
│       ├── terraform-plan.yml         ✅ Plan on PR
│       ├── terraform-deploy-dev.yml   ✅ Deploy to Dev
│       └── terraform-deploy-prod.yml  ✅ Deploy to Prod
├── identity-center/
│   ├── backend.tf
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
├── common/
│   └── locals.tf
├── backend-dev.hcl
├── backend-prod.hcl
└── docs/
    └── github-actions-cicd.md  ← This file
```

**GitHub Settings:**

- ✅ Secrets: `AWS_ROLE_ARN_DEV`, `AWS_ROLE_ARN_PROD`
- ✅ Environments: `dev`, `production` (with approval)
- ✅ Branch protection on `main`

**AWS Resources (per account):**

- ✅ OIDC provider for GitHub
- ✅ IAM role `GitHubActionsTerraformRole`
- ✅ S3 bucket for Terraform state
- ✅ DynamoDB table for state locking

---

## Testing Strategy for Global Services

### The Challenge: No "Dev" Identity Center

**AWS Identity Center is a GLOBAL service** - you cannot test changes in a separate "dev" environment because:

- Only ONE Identity Center instance exists per AWS Organization
- It resides in the Management Account (not Dev or Prod accounts)
- All changes affect production SSO access for ALL accounts
- Cannot create separate test instance without separate AWS Organization

### How to Deploy Safely Without a Test Environment

Since you can't test in a separate Identity Center, use these strategies:

#### 1. Rigorous Code Review

**GitHub Pull Request workflow:**

```
Developer creates feature branch
   ↓
terraform plan runs automatically
   ↓
Plan output posted as PR comment
   ↓
Team member reviews code + plan
   ↓
Required approval before merge
   ↓
Changes merged to develop
   ↓
Automatic deployment to production
```

**Configure branch protection:**

- Require pull request reviews before merging
- Require status checks to pass (terraform plan must succeed)
- Require approval from code owners
- No direct pushes to main branch

#### 2. Detailed terraform plan Inspection

The `terraform plan` output is your "test":

```bash
# Save and review plan before applying
terraform plan -out=tfplan

# Inspect in detail
terraform show tfplan

# Look for:
# - Resources being destroyed (red flags!)
# - Permission changes affecting critical users
# - New permission sets that might be too broad
# - Group assignments being removed
```

**What to check:**

- ✅ Only expected resources being created/modified/destroyed
- ✅ No unintended permission removals
- ✅ New permission sets follow least-privilege
- ✅ Group assignments match expected Google Workspace groups
- ✅ No typos in account IDs or permission set names

#### 3. Incremental Rollout Strategy

Instead of making big-bang changes, use incremental approach:

**Example: Migrating from old to new permission set**

```hcl
# Step 1: Create new permission set (but don't assign yet)
resource "aws_ssoadmin_permission_set" "developers_v2" {
  name        = "DevelopersV2"
  description = "New developer permissions with reduced scope"
  # ... permissions ...
}

# Step 2: Test with pilot group (small user group)
resource "aws_ssoadmin_account_assignment" "pilot" {
  instance_arn       = data.aws_ssoadmin_instances.identity_center.arns[0]
  permission_set_arn = aws_ssoadmin_permission_set.developers_v2.arn
  principal_id       = data.aws_identitystore_group.pilot_users.group_id
  principal_type     = "GROUP"
  target_id          = local.accounts.dev.id
  target_type        = "AWS_ACCOUNT"
}

# Step 3: After validation, expand to all developers
# Step 4: Remove old permission set assignments
# Step 5: Delete old permission set
```

**Benefits:**

- Small blast radius if something goes wrong
- Real-world validation with actual users
- Easy rollback (just remove pilot assignment)
- Gradual migration reduces risk

#### 4. Manual Approval Gates

Use GitHub Actions environments to require human approval:

```yaml
jobs:
  deploy:
    environment: production # Requires manual approval
    steps:
      - name: Apply Terraform
        run: terraform apply tfplan
```

**Approval workflow:**

1. PR merged to `main` branch
2. GitHub Actions prepares `terraform plan`
3. Workflow pauses and requests approval
4. Team lead reviews plan output
5. Approves or rejects deployment
6. If approved, `terraform apply` runs

#### 5. State File Versioning for Rollback

Your S3 bucket has versioning enabled - use it:

```bash
# List all state file versions
aws s3api list-object-versions \
  --bucket terraform-state-identity-center-MGMT-ACCT-ID \
  --prefix identity-center/terraform.tfstate

# Restore previous version if deployment went wrong
aws s3api get-object \
  --bucket terraform-state-identity-center-MGMT-ACCT-ID \
  --key identity-center/terraform.tfstate \
  --version-id <PREVIOUS-VERSION-ID> \
  restored-state.tfstate

# Replace current state
aws s3 cp restored-state.tfstate \
  s3://terraform-state-identity-center-MGMT-ACCT-ID/identity-center/terraform.tfstate
```

#### 6. Monitoring and Alerting

Set up CloudWatch alerts for Identity Center changes:

- SSO permission set modifications
- New group assignments
- Permission set deletions
- Authentication failures (may indicate broken config)

### When Separate AWS Organizations Make Sense

Creating a completely separate AWS Organization with its own Identity Center is **almost never the right answer**.

**Consider it ONLY if:**

| Scenario                  | Why It Might Make Sense                                                | Better Alternative                                               |
| ------------------------- | ---------------------------------------------------------------------- | ---------------------------------------------------------------- |
| **Regulatory Separation** | FedRAMP vs commercial workloads legally require separate organizations | If truly required, proceed. Otherwise, use SCPs and separate OUs |
| **Very Large Scale**      | 1000+ AWS accounts, unacceptable blast radius                          | Use OU-based isolation within single org, staged rollouts        |
| **Testing Org Structure** | Need to test AWS Control Tower migration or complex OU restructuring   | Create temporary test org, migrate, then destroy                 |
| **Multi-Tenant SaaS**     | Each customer gets isolated AWS Organization                           | Valid use case - each tenant needs complete isolation            |

**Why it's usually WRONG:**

❌ **2× Management Overhead**

- Maintain two SAML configurations in Google Workspace
- Two SCIM integrations to Google
- Duplicate all permission sets and assignments
- Users confused about which SSO portal to use

❌ **Cannot Test Realistically**

- Different Organization IDs, Account IDs, Identity Center instance IDs
- Different SCPs, OUs, account structures
- "Test org" doesn't prove "prod org" changes will work
- Need to manually duplicate changes across orgs

❌ **Expensive**

- Need duplicate AWS accounts for every environment
- Dev-Dev, Dev-Prod, Prod-Dev, Prod-Prod accounts
- Double CloudTrail, Config, GuardDuty costs
- Additional Google Workspace licenses if using separate directories

❌ **Operational Complexity**

- Keep two organizations in sync
- Drift between orgs causes prod incidents
- Difficult to replicate exact prod conditions

### Recommended Approach

**For 99% of organizations:**

Use the single Identity Center instance with:

1. ✅ Mandatory PR reviews for all changes
2. ✅ Detailed `terraform plan` inspection
3. ✅ Manual approval gates via GitHub Environments
4. ✅ Incremental rollouts with pilot groups
5. ✅ State versioning for fast rollback
6. ✅ CloudWatch monitoring and alerts

**This gives you:**

- Safety through process, not duplicate infrastructure
- Real production testing (pilot groups)
- Fast rollback capability
- No infrastructure overhead
- Clear audit trail via Git

---

## Next Steps

1. **Set up AWS OIDC** (Part 1)
2. **Configure GitHub Secrets** (Part 2)
3. **Add workflow files** (Part 3)
4. **Test with a PR** (create test branch, modify Terraform, create PR)
5. **Verify plan appears as comment**
6. **Merge PR and verify auto-deployment to Dev**
7. **Create Git tag to test Prod deployment**

Need help? Check GitHub Actions logs: **Actions tab → Click workflow run → Click job → Expand steps**
