# Phase 4: Continuous Integration (Validation)

## Prerequisites

**Required Access:**

- GitHub repository admin access (to create workflows)
- Ability to create `.github/workflows/` directory
- Permission to enable GitHub Actions (if disabled)

**Required Tools:**

- Git CLI
- Text editor (VS Code with YAML extension recommended)
- GitHub CLI (`gh`) optional for testing workflows

**Required Knowledge:**

- Basic YAML syntax
- GitHub Actions concepts (workflows, jobs, steps)
- Understanding of CI/CD pipelines
- Terraform CLI commands

**Optional Tools (for local testing):**

- `act` (run GitHub Actions locally)
- Docker (required for `act`)

**Required Accounts/Services:**

- GitHub account with Actions enabled
- (Optional) Infracost API key for cost estimation

**Previous Phase:** [Phase 3 - Bootstrap Dev Account](3-bootstrap-dev.md) must be completed

---

## Overview

**Purpose:** Set up automated validation workflows for the bootstrap project before deploying to Prod. This "shifts quality left" by catching errors, security issues, and misconfigurations in Pull Requests.

**Estimated Time:** 30-45 minutes

**Why Now?** Setting up CI/CD after Dev but before Prod means:

- ✅ Prod configuration gets validated before deployment (lower risk)
- ✅ Security scanning catches misconfigurations early
- ✅ Code quality gates in place before production changes
- ✅ Team establishes quality standards from the start

---

## Overview

While the bootstrap project is "low-churn" infrastructure that rarely changes, having Continuous Integration provides critical benefits:

**What This Phase Covers:**

- Linting and formatting checks
- Terraform validation
- Security scanning (tfsec)
- Code quality scanning (tflint)
- Cost estimation (Infracost - optional)
- Runs on every Pull Request

**Benefits:**

- **Code Quality** - Catch formatting and syntax errors before manual execution
- **Security** - Detect misconfigurations (missing encryption, public buckets)
- **Early Feedback** - Issues caught in PR before merge
- **Scaling** - Easy to add new accounts (staging, shared-services) with validation
- **Audit Trail** - All changes tracked through Git and CI logs

**What's Not Covered:**

- Automated deployments (covered in Phase 7 - Continuous Deployment)
- Drift detection (covered in Phase 7 - Continuous Deployment)
- Manual `terraform apply` is still required after PR merge

---

## Validation Workflows

This stage validates code **without modifying infrastructure**, so it works perfectly before deploying to Prod or migrating to remote state.

**Value:** Catch errors in Prod configuration before deployment, establish security baselines, and enforce code quality standards.

### Feature 1: Terraform Validation and Formatting

#### User Story 1.1: Create Validation Workflow

**As a:** Platform Engineer  
**I want to:** Automatically validate Terraform code formatting and syntax on every Pull Request  
**So that:** Code quality errors are caught before manual execution

**Acceptance Criteria:**

- Workflow runs on PR creation and updates
- Checks formatting and syntax
- Validates documentation exists
- Fails PR if issues are found
- Runs without AWS credentials (no state access needed)

#### Implementation

**1) Create Feature Branch:**

```bash
cd ~/mycompany.infra-terraform-bootstrap

# Ensure you're on main and up to date
git checkout main
git pull origin main

# Create feature branch for CI/CD setup
git checkout -b add-validation-ci
```

**2) Create GitHub Actions Workflow:**

```bash
# Create directory structure
mkdir -p .github/workflows

# Create workflow file
touch .github/workflows/validate.yml
```

**3) Add Workflow Content:**

Edit the file with your preferred editor:

```bash
vim .github/workflows/validate.yml
# or
code .github/workflows/validate.yml
```

Copy and paste the following complete workflow:

```yaml
# .github/workflows/validate.yml
name: Terraform Validation

on:
  pull_request:
    branches: [main]

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
        # Only dev exists at this phase - prod will be added in Phase 5
        account: [dev]
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

**4) Commit and Push:**

```bash
# Stage the workflow file
git add .github/workflows/validate.yml

# Commit with descriptive message
git commit -m "Add validation workflow for Terraform formatting and syntax"

# Push to remote
git push origin add-validation-ci
```

**5) Create Pull Request:**

```bash
# Option A: Using GitHub CLI
gh pr create \
  --title "Add validation CI workflow" \
  --body "Adds automated validation for Terraform formatting and syntax"

# Option B: Open GitHub in browser
# Navigate to: https://github.com/mycompany/mycompany.infra-terraform-bootstrap
# Click "Compare & pull request" button
```

**6) Verify CI Runs:**

Open the PR and verify:

- ✅ Format check runs and passes
- ✅ Validation runs for dev account (only dev exists at this phase)
- ✅ Documentation check passes

**7) Merge PR:**

Once all checks pass:

- Review the changes
- Click "Merge pull request"
- Delete the feature branch: `add-validation-ci`

---

### Feature 2: Security Scanning

#### User Story 2.1: Add tfsec for Security Compliance

**As a:** Platform Engineer  
**I want to:** Automatically scan Terraform code for security misconfigurations  
**So that:** Security issues are caught before deployment

**Acceptance Criteria:**

- tfsec runs on every PR and nightly
- Catches security issues (unencrypted resources, public buckets, missing tags)
- Fails PR if MEDIUM or higher severity issues found
- Provides clear remediation guidance

#### Implementation

**Create Security Scanning Workflow:**

```bash
# Create separate workflow for security
touch .github/workflows/security.yml
```

**Add Security Workflow Content:**

```yaml
# .github/workflows/security.yml
name: Security Scan

on:
  pull_request:
    branches: [main]
  schedule:
    - cron: "0 9 * * *" # Daily at 9 AM UTC
  workflow_dispatch: # Allow manual trigger

jobs:
  tfsec:
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

      - name: Security Scan Failed
        if: failure()
        run: |
          echo "❌ Security issues detected!"
          echo "Review tfsec output above and fix issues"
          echo "Common issues:"
          echo "  - S3 bucket without encryption"
          echo "  - S3 bucket without versioning"
          echo "  - DynamoDB table without encryption"
          echo "  - Missing tags"
          echo "Run locally: tfsec ."
```

**Commit Security Workflow:**

```bash
# Add to the same feature branch or create new one
git add .github/workflows/security.yml
git commit -m "Add security scanning workflow with tfsec"
git push origin add-validation-ci
```

**Security Focus Areas:**

- **Encryption:** S3 buckets and DynamoDB tables must use encryption at rest
- **Access Control:** S3 buckets must block public access
- **Versioning:** State buckets must have versioning enabled
- **Tagging:** All resources must have required tags for cost allocation

---

### Feature 3: Code Quality Scanning

#### User Story 3.1: Add tflint for Terraform Best Practices

**As a:** Platform Engineer  
**I want to:** Use tflint to catch Terraform-specific issues and enforce best practices  
**So that:** Code follows Terraform conventions and avoids common pitfalls

**Acceptance Criteria:**

- tflint runs on every PR
- Catches deprecated syntax, invalid references, and naming issues
- Enforces AWS-specific best practices
- Fails PR if ERROR severity issues found (warnings are informational)

#### Implementation

**Create Linting Workflow:**

```bash
# Create separate workflow for code quality
touch .github/workflows/lint.yml
```

**Add Linting Workflow Content:**

```yaml
# .github/workflows/lint.yml
name: Code Quality (Lint)

on:
  pull_request:
    branches: [main]

jobs:
  tflint:
    name: TFLint Check
    runs-on: ubuntu-latest
    env:
      TFLINT_VERSION: v0.50.0

    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Cache TFLint Plugins
        uses: actions/cache@v4
        with:
          path: ~/.tflint.d/plugins
          # give unique cache name to prevent reuse of an incompatible cached plugin set
          key: tflint-${{ runner.os }}-${{ runner.arch }}-${{ env.TFLINT_VERSION }}-${{ hashFiles('.tflint.hcl') }}

      - name: Setup TFLint
        uses: terraform-linters/setup-tflint@v4
        with:
          tflint_version: ${{ env.TFLINT_VERSION }}

      - name: Init TFLint
        run: tflint --init

      - name: Run TFLint
        # find all directories containing Terraform files and lint each one
        run: |
          set -euo pipefail
          find . -type f -name '*.tf' -printf '%h\n' | sort -u | while read -r dir; do
            echo "Running tflint in ${dir}"
            (cd "${dir}" && tflint -f compact)
          done
```

**Commit Linting Workflow:**

```bash
# Add to the same feature branch
git add .github/workflows/lint.yml
git commit -m "Add code quality linting workflow with tflint"
git push origin add-validation-ci
```

**Note:** tflint focuses on Terraform code quality and AWS best practices, while tfsec (Feature 2) focuses on security and compliance. Both are valuable and complement each other.

---

### Feature 4: Cost Estimation (Optional)

#### User Story 4.1: Add Infracost for Cost Awareness

**As a:** Platform Engineer  
**I want to:** See estimated AWS costs for infrastructure changes  
**So that:** I can make informed decisions about resource sizing

**Acceptance Criteria:**

- Infracost runs on every PR
- Posts comment with cost breakdown
- Highlights cost increases/decreases

#### Implementation

**Create Infracost Workflow:**

```bash
# Create separate workflow for cost estimation
touch .github/workflows/infracost.yml
```

**Add Infracost Workflow Content:**

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

**Commit Infracost Workflow:**

```bash
# Add to the same feature branch (optional)
git add .github/workflows/infracost.yml
git commit -m "Add cost estimation workflow with Infracost"
git push origin add-validation-ci
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

## Troubleshooting

### Issue: Workflow Not Triggering on PR

**Cause:** Path filters exclude the files you modified.

**Fix:**

Check `.github/workflows/validate.yml` path filters:

```yaml
paths:
  - "modules/**/*.tf"
  - "accounts/**/*.tf"
  - ".github/workflows/validate.yml"
```

If you modified README or non-.tf files, the workflow won't run. Either:

- Modify a .tf file to trigger validation
- Remove path filters to run on all changes
- Add specific paths (e.g., `"**.md"`) to trigger on docs

---

### Issue: tfsec or tflint Fails on Valid Code

**Cause:** Tool detecting false positives or overly strict rules.

**Fix:**

For tfsec, add inline ignore comments:

```hcl
#tfsec:ignore:aws-s3-enable-bucket-logging
resource "aws_s3_bucket" "terraform_state" {
  # Bootstrap bucket doesn't need access logging
}
```

For tflint, configure `.tflint.hcl`:

```hcl
rule "terraform_naming_convention" {
  enabled = false  # Disable specific rule
}
```

---

### Issue: Security Scan Fails on Required Configuration

**Cause:** tfsec flagging intentional design decisions (e.g., public S3 bucket for static site).

**Fix:**

Add explanation with inline ignore:

```hcl
#tfsec:ignore:aws-s3-block-public-acls reason="State bucket must be private"
resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

---

## Security Considerations

**Workflow Permissions:**

- Validation workflows run without AWS credentials (safe)
- Read-only access to repository
- Cannot modify infrastructure

**Branch Protection:**

```
Repository Settings → Branches → Add rule for 'main':
- ✅ Require pull request before merging
- ✅ Require status checks to pass (all validation workflows)
- ✅ Require conversation resolution
- ✅ Require signed commits (optional)
- ✅ Include administrators
```

**Secret Management:**

- No AWS credentials needed for Phase 4 workflows
- All validation runs without authentication
- Deployment credentials covered in Phase 7

---

## Cost Impact

**CI Costs:**

- GitHub Actions: Free for public repos, ~$0.008/minute for private repos
- Validation workflows: ~2 minutes per PR = ~$0.02 per PR
- Security scan (nightly): ~1 minute per day = ~$0.25/month
- Expected total: ~$2-5/month for private repositories

**Value:**

- Catches issues before deployment (prevents costly mistakes)
- Reduces code review time (automated checks)
- Prevents security misconfigurations (priceless)

---

## Next Steps

After completing Phase 4:

1. **Continue to Phase 5:** Bootstrap Prod account with validation in place
2. **Monitor CI Results:** Watch first few PRs to ensure workflows work as expected
3. **Consider Phase 7:** Add Continuous Deployment after Phase 6 (remote state)

---

**Previous Phase:** [Phase 3 - Bootstrap Dev Account](3-bootstrap-dev.md)  
**Next Phase:** [Phase 5 - Bootstrap Prod Account](5-bootstrap-prod.md)

**Note:** With CI in place, your Prod configuration (Phase 5) will be validated before deployment!

---

## Summary

**What You Accomplished:**

- ✅ Automated code quality validation (format, syntax)
- ✅ Automated security scanning (tfsec)
- ✅ Automated best practices checking (tflint)
- ✅ Optional cost estimation (Infracost)
- ✅ Established quality gates for all code changes
- ✅ Foundation for Continuous Deployment (Phase 7)

**Files Created:**

```
.github/
└── workflows/
    ├── validate.yml     # Format + syntax validation
    ├── security.yml     # Security scanning (tfsec)
    ├── lint.yml         # Code quality (tflint)
    └── infracost.yml    # Cost estimation (optional)
```

**Time Invested:** 30-45 minutes  
**Time Saved:** ~10 minutes per PR in manual reviews  
**Risk Reduced:** Security and quality issues caught before merge
