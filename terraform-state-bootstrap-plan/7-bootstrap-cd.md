# Phase 7: Continuous Deployment (Bootstrap Automation)

## Prerequisites

**Required Access:**

- GitHub repository admin access (to create workflows)
- AWS Dev and Prod account access (to create OIDC providers)
- Permission to create IAM roles and policies

**Required Tools:**

- Git CLI
- Terraform >= 1.7.0
- AWS CLI configured with SSO profiles
- Text editor (VS Code with YAML extension recommended)

**Required Knowledge:**

- GitHub Actions OIDC authentication
- IAM roles and trust policies
- Terraform remote state for this bootstrap project
- GitHub Environments for approval workflows

**Required Accounts/Services:**

- GitHub account with Actions enabled
- AWS Dev and Prod accounts with remote state configured

**Previous Phase:** [Phase 6 - Migrate to Remote State](6-migrate-to-remote-state.md) must be completed

**⚠️ Critical:** This phase requires remote state (Phase 6) to be completed. Local state does not support automated deployments safely.

---

## Overview

**Purpose:** Automate Terraform deployments for the bootstrap project using GitHub Actions with OIDC authentication. This eliminates manual `terraform apply` commands while maintaining security and audit trails.

**Estimated Time:** 60-90 minutes

**Why After Remote State?** Automated deployments require:

- ✅ Remote state for concurrent access and locking
- ✅ State backend for GitHub Actions to read/write state
- ✅ Proper state locking to prevent conflicts
- ✅ Audit trail of all state changes

**Why Optional?** Continuous Deployment adds:

- **Automation** - Changes deploy automatically on merge to main
- **Consistency** - No human error in manual deployments
- **Speed** - Faster iteration cycle
- **Audit** - Complete trail of who deployed what and when

However, manual deployments are perfectly acceptable for low-churn bootstrap infrastructure.

---

## Features

### Feature 1: OIDC Authentication Setup

#### User Story 1.1: Create OIDC Provider for Bootstrap

**As a:** Platform Engineer  
**I want to:** Allow GitHub Actions to deploy bootstrap changes using OIDC  
**So that:** Deployments are secure without long-lived credentials

**Acceptance Criteria:**

- OIDC provider created in dev and prod accounts
- IAM role created for GitHub Actions
- Role has permissions to manage state bucket and DynamoDB table
- Workflow can assume role without long-lived credentials
- Trust policy restricts access to specific GitHub repository

#### Implementation

**1) Add OIDC Resources to Terraform Module:**

Create a new file in the bootstrap module:

```hcl
# modules/terraform-state-backend/oidc.tf (NEW FILE)

# GitHub OIDC Provider
resource "aws_iam_openid_connect_provider" "github_actions" {
  count = var.enable_github_oidc ? 1 : 0

  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com"
  ]

  # GitHub's thumbprint - verify at:
  # https://github.blog/changelog/2022-01-13-github-actions-update-on-oidc-based-deployments-to-aws/
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd"
  ]

  tags = merge(
    var.tags,
    {
      Name      = "${var.project_name}-github-oidc"
      ManagedBy = "Terraform"
    }
  )
}

# IAM Role for GitHub Actions
resource "aws_iam_role" "github_actions_bootstrap" {
  count = var.enable_github_oidc ? 1 : 0

  name        = "${var.project_name}-github-actions-bootstrap"
  description = "Role for GitHub Actions to manage Terraform bootstrap infrastructure"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github_actions[0].arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # IMPORTANT: Replace with your actual GitHub org/repo
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:*"
          }
        }
      }
    ]
  })

  tags = merge(
    var.tags,
    {
      Name      = "${var.project_name}-github-actions-bootstrap"
      ManagedBy = "Terraform"
    }
  )
}

# Policy: Allow managing state bucket and DynamoDB table
resource "aws_iam_role_policy" "github_bootstrap_state_management" {
  count = var.enable_github_oidc ? 1 : 0

  name = "BootstrapStateManagement"
  role = aws_iam_role.github_actions_bootstrap[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "StateReadWrite"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:GetBucketVersioning",
          "s3:GetBucketTagging",
          "s3:PutBucketTagging"
        ]
        Resource = [
          aws_s3_bucket.terraform_state.arn,
          "${aws_s3_bucket.terraform_state.arn}/*"
        ]
      },
      {
        Sid    = "StateLocking"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:DeleteItem",
          "dynamodb:DescribeTable",
          "dynamodb:UpdateTable",
          "dynamodb:TagResource",
          "dynamodb:ListTagsOfResource"
        ]
        Resource = aws_dynamodb_table.terraform_locks.arn
      },
      {
        Sid    = "ManageBootstrapResources"
        Effect = "Allow"
        Action = [
          "s3:CreateBucket",
          "s3:PutBucketVersioning",
          "s3:PutBucketEncryption",
          "s3:PutBucketPublicAccessBlock",
          "s3:PutBucketLogging",
          "s3:PutBucketPolicy",
          "s3:PutLifecycleConfiguration",
          "dynamodb:CreateTable",
          "dynamodb:UpdateTimeToLive",
          "iam:CreatePolicy",
          "iam:GetPolicy",
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:ListPolicyVersions"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = var.primary_region
          }
        }
      }
    ]
  })
}
```

**2) Add Variables to Module:**

```hcl
# modules/terraform-state-backend/variables.tf

variable "enable_github_oidc" {
  description = "Enable GitHub OIDC provider and IAM role for CI/CD"
  type        = bool
  default     = false
}

variable "github_org" {
  description = "GitHub organization name for OIDC trust policy"
  type        = string
  default     = ""
}

variable "github_repo" {
  description = "GitHub repository name for OIDC trust policy"
  type        = string
  default     = ""
}
```

**3) Add Output:**

```hcl
# modules/terraform-state-backend/outputs.tf

output "github_actions_role_arn" {
  description = "ARN of IAM role for GitHub Actions (if enabled)"
  value       = var.enable_github_oidc ? aws_iam_role.github_actions_bootstrap[0].arn : null
}
```

**4) Enable OIDC in Account Configurations:**

```hcl
# accounts/dev/main.tf

module "terraform_state_backend" {
  source = "../../modules/terraform-state-backend"

  environment        = "dev"
  primary_region     = "us-east-1"
  project_name       = "mycompany"
  enable_github_oidc = true  # Enable OIDC
  github_org         = "mycompany"
  github_repo        = "mycompany.infra-terraform-bootstrap"

  tags = {
    Environment = "dev"
    ManagedBy   = "Terraform"
    Project     = "bootstrap"
  }
}
```

```hcl
# accounts/prod/main.tf

module "terraform_state_backend" {
  source = "../../modules/terraform-state-backend"

  environment        = "prod"
  primary_region     = "us-east-1"
  project_name       = "mycompany"
  enable_github_oidc = true  # Enable OIDC
  github_org         = "mycompany"
  github_repo        = "mycompany.infra-terraform-bootstrap"

  tags = {
    Environment = "prod"
    ManagedBy   = "Terraform"
    Project     = "bootstrap"
  }
}
```

**5) Apply the Changes:**

```bash
# Dev account
cd ~/mycompany.infra-terraform-bootstrap/accounts/dev
terraform plan
terraform apply

# Capture the role ARN from output
terraform output github_actions_role_arn

# Prod account
cd ~/mycompany.infra-terraform-bootstrap/accounts/prod
terraform plan
terraform apply

# Capture the role ARN from output
terraform output github_actions_role_arn
```

**6) Verify OIDC Provider:**

```bash
# Check OIDC provider exists
aws iam list-open-id-connect-providers --profile mycompany-dev

# Check IAM role exists
aws iam get-role \
  --role-name mycompany-github-actions-bootstrap \
  --profile mycompany-dev
```

---

### Feature 2: Automated Deployment Workflow

#### User Story 2.1: Create Deployment Workflow

**As a:** Platform Engineer  
**I want to:** Automatically apply Terraform changes on merge to main  
**So that:** Bootstrap infrastructure stays in sync with code

**Acceptance Criteria:**

- Workflow runs only on merge to main
- Uses OIDC to assume IAM role
- Runs `terraform plan` and `terraform apply`
- Sends notifications on failure
- Prod deployments require manual approval

#### Implementation

**1) Create Deployment Workflow:**

```bash
cd ~/mycompany.infra-terraform-bootstrap
touch .github/workflows/deploy.yml
```

**2) Add Deployment Workflow Content:**

```yaml
# .github/workflows/deploy.yml
name: Terraform Deploy

on:
  push:
    branches: [main]
    paths:
      - "modules/**/*.tf"
      - "accounts/**/*.tf"
  workflow_dispatch: # Allow manual trigger

# Required for OIDC
permissions:
  id-token: write
  contents: read

env:
  TERRAFORM_VERSION: 1.7.4
  AWS_REGION: us-east-1

jobs:
  deploy-dev:
    name: Deploy to Dev
    runs-on: ubuntu-latest
    environment: dev # GitHub Environment for optional approval

    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Configure AWS Credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN_DEV }}
          aws-region: ${{ env.AWS_REGION }}
          role-session-name: GitHubActions-Bootstrap-${{ github.run_id }}

      - name: Verify AWS Identity
        run: |
          aws sts get-caller-identity
          echo "✅ Assumed role successfully"

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TERRAFORM_VERSION }}

      - name: Terraform Init
        working-directory: accounts/dev
        run: terraform init

      - name: Terraform Plan
        working-directory: accounts/dev
        run: |
          terraform plan -out=tfplan
          terraform show -no-color tfplan > plan.txt

      - name: Terraform Apply
        working-directory: accounts/dev
        run: terraform apply -auto-approve tfplan

      - name: Notify on Failure
        if: failure()
        run: |
          echo "❌ Deployment to dev failed!"
          echo "Check logs at: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"
          # Add Slack/Discord/Email notification here

  deploy-prod:
    name: Deploy to Prod
    runs-on: ubuntu-latest
    needs: deploy-dev # Only run if dev succeeds
    environment: prod # Require manual approval

    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Configure AWS Credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN_PROD }}
          aws-region: ${{ env.AWS_REGION }}
          role-session-name: GitHubActions-Bootstrap-${{ github.run_id }}

      - name: Verify AWS Identity
        run: aws sts get-caller-identity

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TERRAFORM_VERSION }}

      - name: Terraform Init
        working-directory: accounts/prod
        run: terraform init

      - name: Terraform Plan
        working-directory: accounts/prod
        run: |
          terraform plan -out=tfplan
          terraform show -no-color tfplan > plan.txt

      - name: Terraform Apply
        working-directory: accounts/prod
        run: terraform apply -auto-approve tfplan

      - name: Notify on Success
        run: |
          echo "✅ Production deployment successful!"
          echo "Workflow: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"
```

**3) Add GitHub Secrets:**

```bash
# Get role ARNs from Terraform outputs
cd ~/mycompany.infra-terraform-bootstrap/accounts/dev
DEV_ROLE_ARN=$(terraform output -raw github_actions_role_arn)

cd ../prod
PROD_ROLE_ARN=$(terraform output -raw github_actions_role_arn)

echo "Dev Role ARN: $DEV_ROLE_ARN"
echo "Prod Role ARN: $PROD_ROLE_ARN"
```

Then add to GitHub:

1. Go to GitHub repository → `Settings` → `Secrets and variables` → `Actions`
2. Click `New repository secret`
3. Add `AWS_ROLE_ARN_DEV` with the dev role ARN
4. Add `AWS_ROLE_ARN_PROD` with the prod role ARN

**4) Configure GitHub Environments:**

**For Prod (Manual Approval Required):**

1. Go to GitHub repository → `Settings` → `Environments`
2. Click `New environment` → Name: `prod`
3. Check `Required reviewers`
4. Add yourself or your team as reviewers
5. Click `Save protection rules`

**For Dev (Optional - Immediate Deployment):**

1. Create environment: `dev`
2. Leave protection rules empty for automatic deployment
3. Or add approval for additional safety

**5) Commit and Test:**

```bash
cd ~/mycompany.infra-terraform-bootstrap

# Create feature branch
git checkout -b add-cd-workflow

# Add workflow
git add .github/workflows/deploy.yml
git commit -m "Add continuous deployment workflow with OIDC"
git push origin add-cd-workflow

# Create PR
gh pr create \
  --title "Add continuous deployment workflow" \
  --body "Enables automated deployments with OIDC authentication"

# Merge PR (after CI passes)
# Then verify deployment workflow runs on main
```

**6) Verify Deployment:**

- ✅ Workflow triggers on push to main
- ✅ Dev deployment runs automatically
- ✅ Prod deployment waits for approval
- ✅ Changes applied successfully
- ✅ AWS resources match Terraform code

---

### Feature 3: Drift Detection

#### User Story 3.1: Daily Drift Detection

**As a:** Platform Engineer  
**I want to:** Detect when someone manually modifies bootstrap resources  
**So that:** Infrastructure stays consistent with code

**Acceptance Criteria:**

- Runs daily at 9 AM UTC
- Compares actual AWS resources to Terraform state
- Creates GitHub issue on drift detection
- Does not modify resources

#### Implementation

**1) Create Drift Detection Workflow:**

```bash
touch .github/workflows/drift-detection.yml
```

**2) Add Drift Detection Workflow Content:**

```yaml
# .github/workflows/drift-detection.yml
name: Drift Detection

on:
  schedule:
    - cron: "0 9 * * *" # Daily at 9 AM UTC
  workflow_dispatch: # Allow manual trigger

permissions:
  id-token: write
  contents: read
  issues: write # To create GitHub issue on drift

env:
  TERRAFORM_VERSION: 1.7.4
  AWS_REGION: us-east-1

jobs:
  detect-drift-dev:
    name: Detect Drift - Dev
    runs-on: ubuntu-latest

    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN_DEV }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TERRAFORM_VERSION }}

      - name: Terraform Init
        working-directory: accounts/dev
        run: terraform init

      - name: Terraform Plan (Detect Drift)
        id: plan
        working-directory: accounts/dev
        run: |
          terraform plan -detailed-exitcode -no-color > plan.txt 2>&1 || echo "exitcode=$?" >> $GITHUB_OUTPUT
        continue-on-error: true

      - name: Check for Drift
        if: steps.plan.outputs.exitcode == '2'
        run: |
          echo "🚨 DRIFT DETECTED in dev account!"
          cat accounts/dev/plan.txt

      - name: Create GitHub Issue on Drift
        if: steps.plan.outputs.exitcode == '2'
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const plan = fs.readFileSync('accounts/dev/plan.txt', 'utf8');

            github.rest.issues.create({
              owner: context.repo.owner,
              repo: context.repo.repo,
              title: '🚨 Terraform Drift Detected - Dev Account',
              body: `Drift detected in dev account bootstrap infrastructure.
              
              **Detection Time:** ${new Date().toISOString()}
              **Workflow Run:** ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
              
              <details>
              <summary>Terraform Plan Output</summary>
              
              \`\`\`terraform
              ${plan}
              \`\`\`
              
              </details>
              
              **Next Steps:**
              1. Review the drift above
              2. Determine if manual changes should be kept or reverted
              3. Update Terraform code if manual changes should be preserved
              4. Run \`terraform apply\` to reconcile state
              `,
              labels: ['drift-detection', 'dev', 'infrastructure']
            });

  detect-drift-prod:
    name: Detect Drift - Prod
    runs-on: ubuntu-latest

    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN_PROD }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TERRAFORM_VERSION }}

      - name: Terraform Init
        working-directory: accounts/prod
        run: terraform init

      - name: Terraform Plan (Detect Drift)
        id: plan
        working-directory: accounts/prod
        run: |
          terraform plan -detailed-exitcode -no-color > plan.txt 2>&1 || echo "exitcode=$?" >> $GITHUB_OUTPUT
        continue-on-error: true

      - name: Check for Drift
        if: steps.plan.outputs.exitcode == '2'
        run: |
          echo "🚨🚨🚨 DRIFT DETECTED IN PROD!"
          cat accounts/prod/plan.txt

      - name: Create Critical GitHub Issue on Prod Drift
        if: steps.plan.outputs.exitcode == '2'
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const plan = fs.readFileSync('accounts/prod/plan.txt', 'utf8');

            github.rest.issues.create({
              owner: context.repo.owner,
              repo: context.repo.repo,
              title: '🚨🚨 CRITICAL: Terraform Drift Detected - PROD Account',
              body: `**CRITICAL:** Drift detected in PRODUCTION account bootstrap infrastructure.
              
              **Detection Time:** ${new Date().toISOString()}
              **Workflow Run:** ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
              
              <details>
              <summary>Terraform Plan Output</summary>
              
              \`\`\`terraform
              ${plan}
              \`\`\`
              
              </details>
              
              **Immediate Actions Required:**
              1. 🔍 Investigate who made manual changes
              2. 📋 Document the changes and reason
              3. 🔄 Update Terraform code to match desired state
              4. ✅ Run \`terraform apply\` to reconcile
              5. 📚 Update runbooks to prevent manual changes
              `,
              labels: ['drift-detection', 'prod', 'critical', 'infrastructure']
            });
```

**3) Test Drift Detection:**

```bash
# Simulate drift by manually modifying a resource
aws s3api put-bucket-tagging \
  --bucket mycompany-terraform-state-dev \
  --tagging 'TagSet=[{Key=ManualTag,Value=TestDrift}]' \
  --profile mycompany-dev

# Trigger workflow manually
gh workflow run drift-detection.yml

# Check for GitHub issue creation
gh issue list --label drift-detection
```

---

## Validation

**Continuous Deployment Verification:**

- ✅ OIDC provider exists in dev and prod accounts
- ✅ IAM role created with correct trust policy
- ✅ GitHub Secrets configured with role ARNs
- ✅ `deploy.yml` workflow exists
- ✅ Dev deployment runs automatically on merge
- ✅ Prod deployment requires manual approval
- ✅ Changes applied successfully to AWS

**Drift Detection Verification:**

- ✅ `drift-detection.yml` workflow exists
- ✅ Workflow runs on schedule (daily at 9 AM)
- ✅ Can be triggered manually
- ✅ Creates GitHub issue when drift detected
- ✅ Does not modify resources

**Test End-to-End:**

```bash
# 1. Make a small change
git checkout main
git pull
vim accounts/dev/main.tf
# Add a new tag: TestCD = "true"

# 2. Commit and push
git add accounts/dev/main.tf
git commit -m "Test: Continuous deployment workflow"
git push origin main

# 3. Verify workflow runs
gh run list --workflow=deploy.yml

# 4. Check AWS Console - verify changes applied
aws s3api get-bucket-tagging \
  --bucket mycompany-terraform-state-dev \
  --profile mycompany-dev

# 5. Simulate drift and verify detection
aws s3api put-bucket-tagging \
  --bucket mycompany-terraform-state-dev \
  --tagging 'TagSet=[{Key=DriftTest,Value=Manual}]' \
  --profile mycompany-dev

# 6. Trigger drift detection
gh workflow run drift-detection.yml

# 7. Verify issue created
gh issue list --label drift-detection
```

---

## Troubleshooting

### Issue: OIDC Trust Relationship Error

**Error:**

```
Error: An error occurred (AccessDenied) when calling AssumeRoleWithWebIdentity:
Not authorized to perform sts:AssumeRoleWithWebIdentity
```

**Cause:** GitHub repository reference in trust policy doesn't match actual repository.

**Fix:**

```hcl
# Verify github_org and github_repo variables match your actual repository
# accounts/dev/main.tf
module "terraform_state_backend" {
  # ...
  github_org  = "mycompany"  # Your GitHub organization
  github_repo = "mycompany.infra-terraform-bootstrap"  # Exact repo name
}
```

---

### Issue: Deployment Fails - State Locked

**Error:**

```
Error: Error acquiring the state lock
Lock Info:
  ID:        abc123
  Path:      mycompany-terraform-state-dev/dev/terraform.tfstate
```

**Cause:** Another deployment or manual `terraform apply` is running.

**Fix:**

Wait for the other operation to complete, or force-unlock if it's stuck:

```bash
# Check who has the lock
aws dynamodb get-item \
  --table-name mycompany-terraform-locks-dev \
  --key '{"LockID": {"S": "mycompany-terraform-state-dev/dev/terraform.tfstate-md5"}}' \
  --profile mycompany-dev

# Force unlock (use with caution)
cd accounts/dev
terraform force-unlock abc123
```

---

### Issue: Drift Detection Creates Duplicate Issues

**Cause:** Workflow runs daily and creates new issue each time drift persists.

**Fix:**

Enhance drift detection to check for existing open issues before creating new ones:

```yaml
- name: Check for Existing Drift Issue
  id: existing
  uses: actions/github-script@v7
  with:
    script: |
      const issues = await github.rest.issues.listForRepo({
        owner: context.repo.owner,
        repo: context.repo.repo,
        state: 'open',
        labels: 'drift-detection,dev'
      });
      return issues.data.length > 0;

- name: Create Issue Only if None Exists
  if: steps.plan.outputs.exitcode == '2' && steps.existing.outputs.result == 'false'
  uses: actions/github-script@v7
  # ... create issue
```

---

## Security Considerations

**IAM Role Permissions:**

- Use least-privilege - role can only modify bootstrap resources
- Scoped to primary region only
- Cannot modify resources outside bootstrap project
- Trust policy restricted to specific GitHub repository

**Secret Management:**

- Never store AWS credentials in GitHub Secrets
- Use OIDC for authentication (no long-lived keys)
- Rotate OIDC thumbprints annually
- Store only role ARNs in secrets (not credentials)

**Audit Trail:**

- All deployments logged in GitHub Actions
- CloudTrail logs all AWS API calls from CI/CD role
- DynamoDB lock table shows who acquired locks and when
- GitHub provides complete history of who approved prod deployments

**Branch Protection:**

Ensure main branch is protected:

```
Repository Settings → Branches → Add rule for 'main':
- ✅ Require pull request before merging
- ✅ Require status checks to pass (all CI workflows)
- ✅ Require conversation resolution
- ✅ Require signed commits (optional)
- ✅ Include administrators
- ✅ Require linear history
```

---

## Cost Impact

**Additional Costs:**

- Deployment workflows: ~3 minutes per deployment = ~$0.03
- Drift detection: ~2 minutes daily = ~$5/month for both accounts
- OIDC provider: Free
- IAM role: Free

**Expected Total:** ~$5-10/month for private repositories

---

## Next Steps

After completing Phase 7:

1. **Monitor Deployments:** Watch first few automated deployments closely
2. **Tune Notifications:** Add Slack/Discord webhooks for deployment status
3. **Enhance Drift Detection:** Add remediation workflows for common drift scenarios
4. **Scale Pattern:** Apply same CD approach to downstream Terraform projects

---

**Previous Phase:** [Phase 6 - Migrate to Remote State](6-migrate-to-remote-state.md)  
**Next Phase:** [Phase 8 - Next Steps](8-next-steps.md)

**Note:** Continuous Deployment is optional. Manual deployments are perfectly acceptable for bootstrap infrastructure.

---

## Summary

**What You Accomplished:**

- ✅ Set up OIDC authentication for GitHub Actions
- ✅ Automated Terraform deployments with approval gates
- ✅ Implemented drift detection with automated alerts
- ✅ Eliminated manual deployment steps
- ✅ Established secure, auditable deployment pipeline

**Files Created:**

```
modules/terraform-state-backend/
└── oidc.tf                   # OIDC provider and IAM role

.github/workflows/
├── deploy.yml                # Automated deployment
└── drift-detection.yml       # Daily drift checks
```

**Time Invested:** 60-90 minutes  
**Time Saved:** ~10 minutes per future bootstrap change  
**Risk Reduced:** 100% automation eliminates manual deployment errors
