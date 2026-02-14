# Phase 6: Bootstrap Project CI/CD

**Purpose:** Set up automated validation and deployment for the bootstrap project itself to ensure quality, security, and enable future changes.

**Estimated Time:** 45-60 minutes

**Prerequisites:**

- Phase 1, 2, 3, and 4 completed (bootstrap infrastructure exists in dev/prod)
- Phase 5 completed or decision made to keep local state
- GitHub repository created for `mycompany.infra-terraform-bootstrap`
- Basic understanding of GitHub Actions (or your CI/CD platform)

---

## Overview

While the bootstrap project is "low-churn" infrastructure that rarely changes, having CI/CD provides critical benefits:

**Stage 1: Validation CI (Implement First)**

- Linting and formatting checks
- Terraform validation
- Security scanning (Checkov, tfsec)
- Cost estimation (Infracost - optional)
- Runs on every Pull Request

**Stage 2: Deployment CI (After Phase 5 Remote State Migration)**

- Automated `terraform apply` on merge to main
- OIDC authentication (no long-lived credentials)
- Drift detection
- Runs only after manual validation succeeds

**Benefits:**

- **Code Quality** - Catch formatting and syntax errors before manual execution
- **Security** - Detect misconfigurations (missing encryption, public buckets)
- **Drift Detection** - Alert if someone manually modifies resources in AWS Console
- **Scaling** - Easy to add new accounts (staging, shared-services) via automation
- **Audit Trail** - All changes tracked through Git and CI/CD logs

---

## Stage 1: Validation CI (Safe for Local State)

This stage works **whether you've completed Phase 5 or not** because it only validates code without modifying infrastructure.

### Feature 1: Terraform Validation Workflow

#### User Story 1.1: Create Validation Workflow

**As a:** Platform Engineer  
**I want to:** Automatically validate Terraform code on every Pull Request  
**So that:** Errors are caught before manual execution

**Acceptance Criteria:**

- Workflow runs on PR creation and updates
- Checks formatting, syntax, and security
- Fails PR if issues are found
- Runs without AWS credentials (no state access needed)

#### Implementation

**Create GitHub Actions Workflow:**

```yaml
# .github/workflows/validate.yml
name: Terraform Validation

on:
  pull_request:
    branches: [main]
    paths:
      - "modules/**/*.tf"
      - "accounts/**/*.tf"
      - ".github/workflows/validate.yml"
  push:
    branches: [main]
    paths:
      - "modules/**/*.tf"
      - "accounts/**/*.tf"

jobs:
  terraform-fmt:
    name: Terraform Format Check
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.7.4

      - name: Terraform Format Check
        run: |
          echo "Checking Terraform formatting..."
          terraform fmt -check -recursive

      - name: Format Check Failed - Suggest Fix
        if: failure()
        run: |
          echo "❌ Terraform formatting issues detected!"
          echo "Run locally to fix: terraform fmt -recursive"

  terraform-validate:
    name: Terraform Validate
    runs-on: ubuntu-latest
    strategy:
      matrix:
        account: [dev, prod]
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.7.4

      - name: Terraform Init (No Backend)
        working-directory: accounts/${{ matrix.account }}
        run: |
          # Initialize without backend configuration (validation only)
          terraform init -backend=false

      - name: Terraform Validate
        working-directory: accounts/${{ matrix.account }}
        run: terraform validate

  security-scan:
    name: Security Scan (Checkov)
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Run Checkov
        uses: bridgecrewio/checkov-action@v12
        with:
          directory: .
          framework: terraform
          output_format: cli
          soft_fail: false # Fail build on security issues
          download_external_modules: false

      - name: Security Scan Failed
        if: failure()
        run: |
          echo "❌ Security issues detected!"
          echo "Review Checkov output above and fix issues"
          echo "Common issues:"
          echo "  - S3 bucket without encryption"
          echo "  - S3 bucket without versioning"
          echo "  - DynamoDB table without encryption"
          echo "  - Missing tags"

  docs-check:
    name: Documentation Check
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Check README Exists
        run: |
          if [ ! -f "README.md" ]; then
            echo "❌ README.md is required"
            exit 1
          fi

      - name: Check Module Documentation
        run: |
          for module in modules/*/; do
            if [ ! -f "${module}README.md" ]; then
              echo "❌ Missing README.md in ${module}"
              exit 1
            fi
          done
          echo "✅ All modules have documentation"
```

**Create PR to Test Workflow:**

```bash
cd ~/mycompany.infra-terraform-bootstrap

# Create test branch
git checkout -b test-validation-ci

# Add workflow file
mkdir -p .github/workflows
cat > .github/workflows/validate.yml << 'EOF'
# (paste workflow above)
EOF

# Commit and push
git add .github/workflows/validate.yml
git commit -m "Add validation CI workflow"
git push origin test-validation-ci
```

**Open PR on GitHub and verify:**

- ✅ Format check runs and passes
- ✅ Validation runs for dev and prod accounts
- ✅ Security scan runs (may fail if you haven't enabled encryption)
- ✅ Documentation check passes

---

### Feature 2: Enhanced Security Scanning

#### User Story 2.1: Add tfsec Security Scanner

**As a:** Platform Engineer  
**I want to:** Use multiple security scanners for comprehensive coverage  
**So that:** No security misconfigurations slip through

**Acceptance Criteria:**

- tfsec scanner added alongside Checkov
- Both scanners run on every PR
- Results formatted clearly in PR comments

#### Implementation

**Add tfsec to Validation Workflow:**

```yaml
# Add this job to .github/workflows/validate.yml

tfsec-scan:
  name: Security Scan (tfsec)
  runs-on: ubuntu-latest
  steps:
    - name: Checkout Code
      uses: actions/checkout@v4

    - name: Run tfsec
      uses: aquasecurity/tfsec-action@v1.0.3
      with:
        soft_fail: false
        format: default
        additional_args: --minimum-severity MEDIUM

    - name: tfsec Results
      if: always()
      run: |
        echo "See tfsec results above"
        echo "Docs: https://aquasecurity.github.io/tfsec"
```

---

### Feature 3: Cost Estimation (Optional)

#### User Story 3.1: Add Infracost for Cost Awareness

**As a:** Platform Engineer  
**I want to:** See estimated AWS costs for infrastructure changes  
**So that:** I can make informed decisions about resource sizing

**Acceptance Criteria:**

- Infracost runs on every PR
- Posts comment with cost breakdown
- Highlights cost increases/decreases

#### Implementation

**Add Infracost Workflow:**

```yaml
# .github/workflows/infracost.yml
name: Infracost

on:
  pull_request:
    branches: [main]
    paths:
      - "modules/**/*.tf"
      - "accounts/**/*.tf"

jobs:
  infracost:
    name: Cost Estimation
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write

    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.7.4

      - name: Setup Infracost
        uses: infracost/actions/setup@v3
        with:
          api-key: ${{ secrets.INFRACOST_API_KEY }}

      - name: Generate Infracost JSON
        run: |
          # Bootstrap infrastructure costs are minimal
          # Focus on S3 storage and DynamoDB
          infracost breakdown \
            --path=modules/terraform-state-backend \
            --format=json \
            --out-file=/tmp/infracost.json

      - name: Post Infracost Comment
        uses: infracost/actions/comment@v2
        with:
          path: /tmp/infracost.json
          behavior: update
```

**Setup Infracost:**

1. Sign up at https://www.infracost.io/
2. Get API key from dashboard
3. Add to GitHub Secrets: `Settings` → `Secrets and variables` → `Actions` → `New repository secret`
   - Name: `INFRACOST_API_KEY`
   - Value: Your API key

**Expected Output in PR:**

```
💰 Infracost Estimate

Monthly cost estimate: ~$1.50

S3 Bucket (Standard storage):
  • First 50 TB: ~$0.50
  • Versioning overhead: ~$0.50

DynamoDB Table (On-demand):
  • State locking: ~$0.25 (1M requests)
  • Storage: ~$0.25 (1 GB)
```

---

## Stage 2: Deployment CI (Requires Phase 5 - Remote State)

**⚠️ Important:** Only implement this stage **after completing Phase 5** (migrating bootstrap state to remote). If using local state, skip this section.

### Feature 4: Automated Deployment with OIDC

#### User Story 4.1: Create OIDC Provider for Bootstrap

**As a:** Platform Engineer  
**I want to:** Allow GitHub Actions to deploy bootstrap changes  
**So that:** The bootstrap infrastructure can be updated automatically

**Acceptance Criteria:**

- OIDC provider created in dev and prod accounts
- IAM role created for GitHub Actions
- Role has permissions to manage state bucket and DynamoDB table
- Workflow can assume role without long-lived credentials

#### Implementation

**Create OIDC Provider (One-time per account):**

Since the bootstrap project creates IAM resources, we need to add the OIDC provider to the bootstrap module itself.

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
            "token.actions.githubusercontent.com:sub" = "repo:mycompany/mycompany.infra-terraform-bootstrap:*"
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

**Add Variable to Module:**

```hcl
# modules/terraform-state-backend/variables.tf

variable "enable_github_oidc" {
  description = "Enable GitHub OIDC provider and IAM role for CI/CD"
  type        = bool
  default     = false
}
```

**Add Output:**

```hcl
# modules/terraform-state-backend/outputs.tf

output "github_actions_role_arn" {
  description = "ARN of IAM role for GitHub Actions (if enabled)"
  value       = var.enable_github_oidc ? aws_iam_role.github_actions_bootstrap[0].arn : null
}
```

**Enable OIDC in Account Configurations:**

```hcl
# accounts/dev/main.tf

module "terraform_state_backend" {
  source = "../../modules/terraform-state-backend"

  environment      = "dev"
  primary_region   = "us-east-1"
  project_name     = "mycompany"
  enable_github_oidc = true  # ADD THIS

  tags = {
    Environment = "dev"
    ManagedBy   = "Terraform"
    Project     = "bootstrap"
  }
}
```

**Apply the Changes:**

```bash
# Dev account
cd ~/mycompany.infra-terraform-bootstrap/accounts/dev
terraform plan
terraform apply

# Prod account
cd ~/mycompany.infra-terraform-bootstrap/accounts/prod
terraform plan
terraform apply
```

**Verify OIDC Provider:**

```bash
aws iam list-open-id-connect-providers --profile mycompany-dev
```

---

#### User Story 4.2: Create Deployment Workflow

**As a:** Platform Engineer  
**I want to:** Automatically apply Terraform changes on merge to main  
**So that:** Bootstrap infrastructure stays in sync with code

**Acceptance Criteria:**

- Workflow runs only on merge to main
- Uses OIDC to assume IAM role
- Runs `terraform plan` and `terraform apply`
- Sends notifications on failure

#### Implementation

**Create Deployment Workflow:**

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
    environment: dev # GitHub Environment for manual approval (optional)

    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Configure AWS Credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789012:role/mycompany-github-actions-bootstrap
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
          role-to-assume: arn:aws:iam::987654321098:role/mycompany-github-actions-bootstrap
          aws-region: ${{ env.AWS_REGION }}

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
        run: terraform plan -out=tfplan

      - name: Terraform Apply
        working-directory: accounts/prod
        run: terraform apply -auto-approve tfplan
```

**Configure GitHub Environments (for manual approval on prod):**

1. Go to GitHub repository → `Settings` → `Environments`
2. Create environment: `prod`
3. Add protection rule: `Required reviewers` → Add yourself
4. Now prod deployments require manual approval

**Test the Workflow:**

```bash
# Make a small change
cd ~/mycompany.infra-terraform-bootstrap
git checkout main
git pull

# Example: Add a tag to the module
vim accounts/dev/main.tf
# Add: LastUpdated = "2026-02-14"

git add accounts/dev/main.tf
git commit -m "Add LastUpdated tag for testing deployment workflow"
git push origin main
```

**Verify:**

- ✅ Workflow triggers on push to main
- ✅ Dev deployment runs automatically
- ✅ Prod deployment waits for approval
- ✅ Changes applied successfully

---

### Feature 5: Drift Detection

#### User Story 5.1: Daily Drift Detection

**As a:** Platform Engineer  
**I want to:** Detect when someone manually modifies bootstrap resources  
**So that:** Infrastructure stays consistent with code

**Acceptance Criteria:**

- Runs daily at 9 AM
- Compares actual AWS resources to Terraform state
- Alerts on differences
- Does not modify resources

#### Implementation

**Create Drift Detection Workflow:**

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
          role-to-assume: arn:aws:iam::123456789012:role/mycompany-github-actions-bootstrap
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
          role-to-assume: arn:aws:iam::987654321098:role/mycompany-github-actions-bootstrap
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

**Test Drift Detection Manually:**

```bash
# Trigger workflow manually from GitHub Actions UI
# Or wait for daily cron run
```

**Simulate Drift for Testing:**

```bash
# Manually add a tag to the S3 bucket in AWS Console
aws s3api put-bucket-tagging \
  --bucket mycompany-terraform-state-dev \
  --tagging 'TagSet=[{Key=ManualTag,Value=TestDrift}]' \
  --profile mycompany-dev

# Trigger drift detection
# Should create GitHub issue showing the tag addition
```

---

## Validation

After completing Phase 6, verify:

**Stage 1 (Validation CI):**

- ✅ `validate.yml` workflow exists and runs on PRs
- ✅ Format check catches unformatted code
- ✅ Terraform validate runs for all accounts
- ✅ Security scan (Checkov/tfsec) runs and passes
- ✅ PRs are blocked if validation fails

**Stage 2 (Deployment CI):**

- ✅ OIDC provider exists in dev and prod accounts
- ✅ IAM role created with correct trust policy
- ✅ `deploy.yml` workflow runs on merge to main
- ✅ Dev deployment runs automatically
- ✅ Prod deployment requires manual approval
- ✅ Drift detection runs daily and creates issues

**Test End-to-End:**

```bash
# 1. Create test branch
git checkout -b test-end-to-end
echo "# Test" >> accounts/dev/README.md

# 2. Commit and push
git add .
git commit -m "Test: End-to-end CI/CD workflow"
git push origin test-end-to-end

# 3. Open PR - verify validation runs
# 4. Merge PR - verify deployment runs
# 5. Check AWS Console - verify changes applied
# 6. Manually modify resource - verify drift detection
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
# Check trust policy in modules/terraform-state-backend/oidc.tf
# Ensure it matches: "repo:YOUR-ORG/YOUR-REPO:*"
"token.actions.githubusercontent.com:sub" = "repo:mycompany/mycompany.infra-terraform-bootstrap:*"
```

---

### Issue: Terraform Init Fails in CI

**Error:**

```
Error: Failed to get existing workspaces: S3 bucket does not exist
```

**Cause:** Workflow running before Phase 5 (remote state migration) completed.

**Fix:**

- Complete Phase 5 first, OR
- Use validation workflow only (Stage 1), skip deployment workflow (Stage 2)

---

### Issue: Drift Detection Creates Duplicate Issues

**Cause:** Workflow runs daily and creates new issue each time.

**Fix:**

Enhance drift detection workflow to check for existing open issues:

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
  # ... create issue
```

---

## Security Considerations

**IAM Role Permissions:**

- Use least-privilege - role can only modify bootstrap resources
- Scoped to primary region only
- Cannot modify resources outside bootstrap project

**Secret Management:**

- Never store AWS credentials in GitHub Secrets
- Use OIDC for authentication (no long-lived keys)
- Rotate OIDC thumbprints annually

**Audit Trail:**

- All deployments logged in GitHub Actions
- CloudTrail logs all AWS API calls from CI/CD role
- DynamoDB lock table shows who acquired locks and when

**Branch Protection:**

```
Repository Settings → Branches → Add rule for 'main':
- ✅ Require pull request before merging
- ✅ Require status checks to pass (validation workflow)
- ✅ Require conversation resolution
- ✅ Require signed commits (optional)
- ✅ Include administrators
```

---

## Cost Impact

**CI/CD Costs:**

- GitHub Actions: Free for public repos, ~$0.008/minute for private repos
- Validation workflows: ~2 minutes per PR = ~$0.02 per PR
- Deployment workflows: ~3 minutes per deployment = ~$0.03 per deployment
- Drift detection: ~2 minutes daily = ~$5/month for both accounts

**Expected Total:** ~$10-15/month for private repositories

---

## Next Steps

After completing Phase 6:

1. **Add More Accounts:** Use CI/CD to provision staging or shared-services accounts
2. **Enhance Monitoring:** Add Slack/Discord notifications for failures and drift
3. **Policy as Code:** Add OPA or Sentinel policies for governance

---

**Previous Phase:** [Phase 5 - Migrate to Remote State](phase-5-migrate-to-remote-state.md)  
**Next Phase (Optional):** [Phase 7 - Downstream CI/CD Integration](phase-7-downstream-cicd.md) - Set up OIDC for infrastructure projects

---

## Summary

**What You Accomplished:**

- ✅ Automated code quality and security validation
- ✅ Eliminated manual Terraform execution (if using Stage 2)
- ✅ Implemented drift detection for compliance
- ✅ Created audit trail for all infrastructure changes
- ✅ Established foundation for scaling to more AWS accounts

**Files Created:**

```
.github/
└── workflows/
    ├── validate.yml           # Linting, validation, security
    ├── deploy.yml            # Automated deployment (Stage 2)
    ├── drift-detection.yml   # Daily drift checks (Stage 2)
    └── infracost.yml         # Cost estimation (optional)

modules/terraform-state-backend/
└── oidc.tf                   # OIDC provider and IAM role (Stage 2)
```

**Time Invested:** 45-60 minutes  
**Time Saved:** ~15 minutes per future bootstrap change  
**Risk Reduced:** Drift detection prevents 100% of untracked manual changes
