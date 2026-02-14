# Adding New AWS Accounts to Bootstrap

## Overview

After completing the initial bootstrap for Dev and Prod, you may need to add additional AWS accounts such as:

- **Staging** - Pre-production testing environment
- **Shared Services** - Centralized services (logging, monitoring, DNS)
- **Sandbox** - Developer experimentation environments
- **DR (Disaster Recovery)** - Production replica in different region

This guide explains the repeatable pattern for adding new accounts to your bootstrap infrastructure.

---

## The Pattern: CI/CD First, Then Configuration

**Critical Order:**

1. ✅ **Update CI/CD workflow** to include new account in validation matrix
2. ✅ **Create account configuration** files
3. ✅ **Create PR** - will be validated automatically
4. ✅ **Deploy infrastructure** after merge

**Why This Order?**

If you create account configuration files BEFORE updating the CI/CD workflow:

- ❌ PR validation will fail (workflow tries to validate account that doesn't exist in matrix)
- ❌ You'll need to update the workflow, commit again, force-push
- ❌ Creates messy Git history

**Correct Approach:**

- ✅ Update workflow first (in separate commit)
- ✅ Then create account config (PR will pass validation)
- ✅ Clean Git history, smooth workflow

---

## Step-by-Step: Adding a Staging Account

### Story A.1: Update CI/CD Workflow

**Update `.github/workflows/validate.yml`:**

```yaml
terraform-validate:
  name: Terraform Validate
  runs-on: ubuntu-latest
  strategy:
    matrix:
      # Add staging to the list
      account: [dev, staging, prod] # Previously: [dev, prod]
  steps:
    # ... rest unchanged
```

**Commit:**

```bash
git add .github/workflows/validate.yml
git commit -m "Add staging account to CI/CD validation matrix"
git push origin main
```

**Why Separate Commit?** Keeps the workflow update isolated. If anything goes wrong with account creation, the workflow is already updated.

---

### Story A.2: Create Staging Account Configuration

**Create directory:**

```bash
mkdir -p accounts/staging
```

**Create `accounts/staging/variables.tf`:**

```hcl
variable "aws_account_id" {
  description = "AWS Account ID for Staging environment"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "AWS Account ID must be exactly 12 digits."
  }
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "staging"
}

variable "primary_region" {
  description = "Primary AWS region for state storage"
  type        = string
  default     = "us-east-1"
}
```

**Create `accounts/staging/main.tf`:**

```hcl
module "terraform_backend" {
  source = "../../modules/terraform-state-backend"

  bucket_name     = "mycompany-terraform-state-${var.environment}"
  lock_table_name = "mycompany-terraform-locks"
  environment     = var.environment

  common_tags = {
    ManagedBy   = "Terraform"
    Repository  = "mycompany.infra-terraform-bootstrap"
    Environment = var.environment
    AccountID   = var.aws_account_id
  }
}
```

**Create `accounts/staging/providers.tf`:**

```hcl
terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # No backend configured - uses local state for initial bootstrap
}

provider "aws" {
  region = var.primary_region

  # Uncomment if using AWS SSO profile
  # profile = "mycompany-staging"
}
```

**Create `accounts/staging/outputs.tf`:**

```hcl
output "backend_configuration" {
  description = "Copy this to your infrastructure projects"
  value = <<-EOT
    # Add this to your Terraform configuration:

    terraform {
      backend "s3" {
        bucket         = "${module.terraform_backend.state_bucket_name}"
        key            = "{region}/{layer}/terraform.tfstate"  # Replace with actual path
        region         = "${var.primary_region}"
        encrypt        = true
        dynamodb_table = "${module.terraform_backend.lock_table_name}"
      }
    }
  EOT
}

output "state_bucket" {
  description = "S3 bucket for Terraform state"
  value       = module.terraform_backend.state_bucket_name
}

output "lock_table" {
  description = "DynamoDB table for state locking"
  value       = module.terraform_backend.lock_table_name
}

output "iam_policy_arn" {
  description = "IAM policy ARN for state access (attach to CI/CD roles)"
  value       = module.terraform_backend.iam_policy_arn
}
```

**Create `accounts/staging/terraform.tfvars.example`:**

```hcl
# Copy this to terraform.tfvars and update with actual values

aws_account_id = "111222333444"  # Replace with Staging account ID
environment    = "staging"
primary_region = "us-east-1"
```

---

### Story A.3: Create PR and Validate

**Create feature branch:**

```bash
git checkout -b add-staging-account
git add accounts/staging/
git commit -m "Add Staging account Terraform configuration"
git push origin add-staging-account
```

**Open Pull Request on GitHub**

**Verify CI/CD runs:**

- ✅ Format check passes
- ✅ Terraform validate runs for **dev, staging, AND prod**
- ✅ Security scan passes (Checkov/tfsec)
- ✅ No errors

**Merge PR:**

```bash
# After approval
git checkout main
git pull origin main
```

---

### Story A.4: Deploy to Staging Account

**Configure AWS credentials:**

```bash
aws sso login --profile mycompany-staging
export AWS_PROFILE=mycompany-staging

# Verify credentials
aws sts get-caller-identity
# Should show staging account ID
```

**Create terraform.tfvars:**

```bash
cd accounts/staging
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars
```

**Update with actual staging account ID:**

```hcl
aws_account_id = "111222333444"  # Your actual staging account ID
environment    = "staging"
primary_region = "us-east-1"
```

**Initialize and apply:**

```bash
terraform init
terraform plan
# Review plan - should create 7 resources

terraform apply
# Type 'yes' when prompted
```

**Capture backend configuration:**

```bash
terraform output backend_configuration > ../../BACKEND_CONFIG_STAGING.txt
```

**Verify in AWS Console:**

- S3 bucket: `mycompany-terraform-state-staging`
- DynamoDB table: `mycompany-terraform-locks`

---

### Story A.5: Commit Staging Configuration

**Important:** Only commit the configuration **after** successfully deploying.

```bash
cd ~/mycompany.infra-terraform-bootstrap

git add accounts/staging/
git commit -m "Add deployed Staging account configuration"
git push origin main
```

---

## Checklist for Adding New Accounts

Use this checklist every time you add a new AWS account:

**Pre-Work:**

- [ ] New AWS account created and accessible
- [ ] AWS SSO profile configured (e.g., `mycompany-staging`)
- [ ] Account ID documented (12 digits)
- [ ] Decided on environment name (staging, shared-services, etc.)

**Step 1: Update CI/CD (Separate Commit)**

- [ ] Updated `.github/workflows/validate.yml` matrix
- [ ] Added new account to list: `account: [dev, staging, prod]`
- [ ] Committed and pushed workflow update
- [ ] Verified workflow updated on main branch

**Step 2: Create Account Configuration**

- [ ] Created `accounts/{env}/` directory
- [ ] Created `variables.tf` with validation
- [ ] Created `main.tf` calling bootstrap module
- [ ] Created `providers.tf` (no backend block)
- [ ] Created `outputs.tf` with backend config
- [ ] Created `terraform.tfvars.example`

**Step 3: Validate via PR**

- [ ] Created feature branch
- [ ] Committed account configuration
- [ ] Pushed and opened PR
- [ ] CI/CD passed (format, validate, security)
- [ ] PR reviewed and merged

**Step 4: Deploy Infrastructure**

- [ ] Configured AWS credentials for new account
- [ ] Created `terraform.tfvars` from example
- [ ] Ran `terraform init`
- [ ] Ran `terraform plan` (reviewed 7 resources)
- [ ] Ran `terraform apply`
- [ ] Verified S3 bucket in Console
- [ ] Verified DynamoDB table in Console
- [ ] Captured backend configuration to file

**Step 5: Finalize**

- [ ] Committed deployed configuration
- [ ] Documented backend config location
- [ ] Shared `BACKEND_CONFIG_{ENV}.txt` with team
- [ ] Updated README (if listing all accounts)

---

## Common Patterns

### Multi-Region Accounts

**Question:** Should I create separate bootstrap for each region?

**Answer:** **No.** One bootstrap per account, regardless of regions.

**Why?**

- S3 bucket lives in primary region (us-east-1)
- Terraform projects in ALL regions use the same bucket
- State files differentiated by key path: `us-east-1/vpc/terraform.tfstate`

**Example:**

```hcl
# VPC in us-east-1
terraform {
  backend "s3" {
    bucket = "mycompany-terraform-state-staging"
    key    = "us-east-1/vpc/terraform.tfstate"
    region = "us-east-1"
    # ...
  }
}

# VPC in us-west-2
terraform {
  backend "s3" {
    bucket = "mycompany-terraform-state-staging"
    key    = "us-west-2/vpc/terraform.tfstate"  # Different key
    region = "us-east-1"  # Bucket region stays the same
    # ...
  }
}
```

---

### Shared Services Account

**Special Considerations:**

Shared services account often has:

- Centralized logging (CloudWatch, S3 logs)
- DNS (Route53 hosted zones)
- Secrets management (Secrets Manager, Parameter Store)
- CI/CD infrastructure (GitHub runners, Jenkins)

**Bootstrap the same way:**

```bash
# 1. Update CI/CD workflow
account: [dev, staging, shared-services, prod]

# 2. Create accounts/shared-services/ configuration
# 3. Deploy with terraform apply
```

**No special bootstrap config needed** - just another account.

---

### Sandbox/Developer Accounts

**Pattern 1: One Bootstrap Per Developer**

```
accounts/
├── dev/
├── staging/
├── prod/
├── sandbox-alice/
├── sandbox-bob/
└── sandbox-charlie/
```

**Pattern 2: Shared Sandbox Account**

```
accounts/
├── dev/
├── staging/
├── sandbox/  # Shared by all developers
└── prod/
```

**Recommendation:** Use Pattern 2 (shared sandbox) unless:

- Company policy requires isolated sandbox accounts
- Developers need admin access without affecting others
- Compliance requires per-user resource tagging

---

## Troubleshooting

### Issue: CI/CD Fails After Adding Account

**Error:**

```
Error: accounts/staging does not exist
```

**Cause:** Forgot to update CI/CD workflow before creating account config.

**Fix:**

```bash
# Option 1: Update workflow in same PR
git add .github/workflows/validate.yml accounts/staging/
git commit --amend
git push --force-with-lease

# Option 2: Close PR, update workflow first, re-open
git checkout main
vim .github/workflows/validate.yml
git add .github/workflows/validate.yml
git commit -m "Add staging to CI/CD matrix"
git push origin main

# Then re-create PR with account config
git checkout add-staging-account
git rebase main
git push origin add-staging-account --force-with-lease
```

---

### Issue: Terraform Init Fails with "Backend Not Found"

**Error:**

```
Error: Failed to get existing workspaces: S3 bucket does not exist
```

**Cause:** You added a `backend "s3"` block in `providers.tf` but haven't deployed the bucket yet.

**Fix:**

```hcl
# accounts/{env}/providers.tf
terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # NO backend block for initial bootstrap!
  # Backend is added AFTER the bucket is created
}
```

---

### Issue: Applied to Wrong Account

**Symptom:** Ran `terraform apply` and created resources in wrong AWS account.

**Prevention:**

```bash
# ALWAYS verify credentials before apply
aws sts get-caller-identity
# Double-check the Account ID matches your tfvars file

# Compare:
cat accounts/staging/terraform.tfvars | grep aws_account_id
# Should match output from get-caller-identity
```

**Recovery:**

```bash
# If caught immediately (resources just created):
terraform destroy

# Fix credentials:
export AWS_PROFILE=mycompany-staging  # Correct profile
aws sts get-caller-identity  # Verify

# Re-apply to correct account:
terraform apply
```

---

## Scaling Pattern

**Small Organization (1-5 accounts):**

- Manual process (this guide)
- Update CI/CD → Create config → Apply → Commit

**Medium Organization (5-20 accounts):**

- Use Terraform to create account configs:

```hcl
# generate-account-configs/main.tf
locals {
  accounts = {
    dev     = { account_id = "123456789012" }
    staging = { account_id = "111222333444" }
    prod    = { account_id = "987654321098" }
  }
}

resource "local_file" "account_config" {
  for_each = local.accounts

  filename = "../accounts/${each.key}/main.tf"
  content  = templatefile("templates/main.tf.tpl", {
    environment = each.key
  })
}
```

**Large Organization (20+ accounts):**

- Use AWS Control Tower or AWS Organizations
- Automate account creation with Terraform
- Bootstrap deployed automatically via CI/CD
- See: [Phase 7 - Downstream CI/CD](../phase/phase-7-downstream-cicd.md)

---

## Best Practices

### 1. Naming Consistency

**Do:**

```
accounts/dev/
accounts/staging/
accounts/prod/
```

**Don't:**

```
accounts/development/    # Inconsistent
accounts/stage/          # Abbreviated
accounts/production/     # Too long
```

### 2. Account ID Validation

Always use validation in `variables.tf`:

```hcl
validation {
  condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
  error_message = "AWS Account ID must be exactly 12 digits."
}
```

### 3. Environment Tagging

Tag ALL resources with environment:

```hcl
common_tags = {
  Environment = var.environment
  ManagedBy   = "Terraform"
  Repository  = "mycompany.infra-terraform-bootstrap"
}
```

### 4. Documentation

Update `README.md` when adding accounts:

```markdown
## AWS Accounts

| Environment | Account ID   | S3 Bucket                         | Region    |
| ----------- | ------------ | --------------------------------- | --------- |
| Dev         | 123456789012 | mycompany-terraform-state-dev     | us-east-1 |
| Staging     | 111222333444 | mycompany-terraform-state-staging | us-east-1 |
| Prod        | 987654321098 | mycompany-terraform-state-prod    | us-east-1 |
```

### 5. Backend Configuration

Save backend config for each account:

```
BACKEND_CONFIG_DEV.txt
BACKEND_CONFIG_STAGING.txt
BACKEND_CONFIG_PROD.txt
```

Share with teams deploying infrastructure.

---

## Summary

**Golden Rule:** Update CI/CD workflow BEFORE creating account configuration.

**Repeatable Pattern:**

1. Update `.github/workflows/validate.yml` matrix
2. Create `accounts/{env}/` configuration
3. Open PR (will be validated)
4. Merge PR
5. Deploy with `terraform apply`
6. Commit deployed configuration

**This pattern ensures:**

- ✅ All account configs are validated by CI/CD
- ✅ Security scanning catches issues early
- ✅ Clean Git history
- ✅ Consistent process across all accounts

---

## See Also

- [Phase 4 - Bootstrap CI/CD](../phase/phase-4-bootstrap-cicd.md) - Initial CI/CD setup
- [Phase 5 - Bootstrap Prod](../phase/phase-5-bootstrap-prod.md) - First time adding an account
- [Phase 7 - Downstream CI/CD](../phase/phase-7-downstream-cicd.md) - OIDC for infrastructure repos
- [Value-Driven Delivery](value-driven-delivery.md) - Why CI/CD first matters
