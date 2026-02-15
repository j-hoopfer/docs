# Adding AWS Accounts to Bootstrap

This guide covers adding new AWS accounts to your bootstrap infrastructure, whether it's adding Prod after Dev, or adding additional environments like Staging, QA, or Shared Services.

---

## Quick Start: Adding Prod After Dev

**Scenario:** You bootstrapped Dev first and now have approval to create Prod.

**Good News:** Each AWS account's bootstrap infrastructure is completely independent.

### Key Principles

- **Account Isolation:** Each AWS account has its own S3 bucket and DynamoDB table
- **No Dependencies:** Prod bootstrap doesn't depend on Dev infrastructure
- **Same Process:** Use the exact same bootstrap process you used for Dev
- **Zero Downtime:** Dev infrastructure continues working while you bootstrap Prod

### Quick Steps

1. **Verify Dev is stable:**

   ```bash
   aws s3 ls s3://scale-terraform-state-dev/
   aws dynamodb describe-table --table-name terraform-locks-dev
   ```

2. **Create Prod configuration:**

   ```bash
   cd accounts
   cp -r dev prod
   # Update prod/terraform.tfvars with Prod account ID
   ```

3. **Bootstrap Prod:**

   ```bash
   cd prod
   export AWS_PROFILE=scale-prod
   terraform init
   terraform apply
   ```

4. **Verify isolation:**

   ```bash
   # Check Prod resources exist
   aws s3 ls | grep scale-terraform-state-prod

   # Verify Dev unchanged
   export AWS_PROFILE=scale-dev
   aws s3 ls | grep scale-terraform-state-dev
   ```

**Timeline:** ~1 hour, zero Dev downtime

---

## Adding Additional Accounts (Staging, QA, etc.)

After bootstrapping Dev and Prod, you may need additional accounts:

- **Staging** - Pre-production testing
- **Shared Services** - Centralized logging, monitoring, DNS
- **Sandbox** - Developer experimentation
- **DR** - Disaster recovery replica

---

## Critical Pattern: CI/CD First, Then Configuration

**Correct Order:**

1. ✅ Update CI/CD workflow to include new account in validation matrix
2. ✅ Create account configuration files
3. ✅ Create PR - validated automatically
4. ✅ Deploy after merge

**Why This Order?**

If you create config files BEFORE updating CI/CD:

- ❌ PR validation fails (workflow doesn't know about new account)
- ❌ Need to update workflow, commit again, force-push
- ❌ Messy Git history

Correct approach:

- ✅ Update workflow first
- ✅ Then create account config
- ✅ Clean workflow, smooth PR

---

## Step-by-Step: Adding Staging Account

### Step 1: Update CI/CD Workflow

**Edit `.github/workflows/validate.yml`:**

```yaml
terraform-validate:
  name: Terraform Validate
  runs-on: ubuntu-latest
  strategy:
    matrix:
      account: [dev, staging, prod] # Add staging
  steps:
    - name: Checkout
      uses: actions/checkout@v4

    - name: Validate ${{ matrix.account }}
      working-directory: accounts/${{ matrix.account }}
      run: |
        terraform init -backend=false
        terraform validate
```

**Commit separately:**

```bash
git add .github/workflows/validate.yml
git commit -m "Add staging to CI/CD validation matrix"
git push origin main
```

### Step 2: Create Account Configuration

**Create directory:**

```bash
mkdir -p accounts/staging
```

**Create `accounts/staging/variables.tf`:**

```hcl
variable "aws_account_id" {
  description = "AWS Account ID for Staging"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "AWS Account ID must be 12 digits."
  }
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "staging"
}

variable "name" {
  description = "Company/project name prefix"
  type        = string
  default     = "scale"
}

variable "primary_region" {
  description = "Primary AWS region"
  type        = string
  default     = "us-east-1"
}
```

**Create `accounts/staging/main.tf`:**

```hcl
module "terraform_backend" {
  source = "../../modules/terraform-state-backend"

  bucket_name     = "${var.name}-terraform-state-${var.environment}"
  lock_table_name = "terraform-locks-${var.environment}"
  environment     = var.environment

  common_tags = {
    ManagedBy   = "Terraform"
    Repository  = "scale.infra-terraform-bootstrap"
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

  # No backend - uses local state for bootstrap
}

provider "aws" {
  region = var.primary_region
}
```

**Create `accounts/staging/outputs.tf`:**

```hcl
output "state_bucket_name" {
  description = "S3 bucket for Terraform state"
  value       = module.terraform_backend.state_bucket_name
}

output "lock_table_name" {
  description = "DynamoDB table for state locking"
  value       = module.terraform_backend.lock_table_name
}

output "backend_config" {
  description = "Backend configuration for downstream projects"
  value       = module.terraform_backend.backend_config
}
```

**Create `accounts/staging/terraform.tfvars`:**

```hcl
aws_account_id = "123456789012"  # Replace with actual staging account ID
environment    = "staging"
name           = "scale"         # Your company name
primary_region = "us-east-1"
```

### Step 3: Create Pull Request

```bash
git checkout -b add-staging-account
git add accounts/staging/
git commit -m "Add staging account configuration"
git push origin add-staging-account
```

**Create PR on GitHub.** CI will automatically validate the new staging configuration.

### Step 4: Deploy After Merge

```bash
git checkout main
git pull origin main

cd accounts/staging
export AWS_PROFILE=scale-staging
terraform init
terraform plan
terraform apply
```

---

## Common Questions

**Q: Do I need to migrate Dev state somewhere?**  
A: No. Dev state stays in Dev's S3 bucket. Each account is independent.

**Q: Will bootstrapping a new account affect existing accounts?**  
A: No. Accounts are completely isolated. New bootstrap only creates resources in the new account.

**Q: Can I use the same repository for all accounts?**  
A: Yes! The `accounts/` folder structure supports unlimited accounts:

```
scale.infra-terraform-bootstrap/
├── accounts/
│   ├── dev/
│   ├── staging/
│   ├── prod/
│   ├── shared-services/
│   └── sandbox/
```

**Q: What if we need different configurations per account?**  
A: Customize via `terraform.tfvars`. For example, Prod might have:

- Stricter lifecycle rules (longer retention)
- MFA delete enabled
- Object lock for compliance
- Different encryption (SSE-KMS instead of SSE-S3)

**Q: Should lock table names be the same across accounts?**  
A: They can be. Since each table is in a separate AWS account, the names don't conflict. We use `terraform-locks-{env}` for clarity, but `terraform-locks` in all accounts works too.

---

## What About Existing Infrastructure?

**Nothing changes in existing accounts.** Each account's infrastructure continues using its own backend:

**Dev projects (unchanged):**

```hcl
terraform {
  backend "s3" {
    bucket         = "scale-terraform-state-dev"
    key            = "my-project/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-locks-dev"
  }
}
```

**New Staging projects:**

```hcl
terraform {
  backend "s3" {
    bucket         = "scale-terraform-state-staging"  # Different bucket
    key            = "my-project/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-locks-staging"        # Different table
  }
}
```

---

## Checklist: Adding a New Account

**Before Bootstrap:**

- [ ] New AWS account exists
- [ ] You have admin access to the account
- [ ] AWS SSO profile configured (`scale-{env}`)
- [ ] CI/CD workflow updated with new account
- [ ] Account configuration created (`accounts/{env}/`)

**After Bootstrap:**

- [ ] S3 bucket `scale-terraform-state-{env}` exists
- [ ] DynamoDB table `terraform-locks-{env}` exists
- [ ] Backend config saved and shared with team
- [ ] Verified no resources leaked into other accounts
- [ ] Existing accounts still working normally

---

## Timeline Example: Adding Staging

| Activity                     | Duration  | When  |
| ---------------------------- | --------- | ----- |
| Update CI/CD workflow        | 5 min     | Day 0 |
| Create account configuration | 15 min    | Day 0 |
| Create PR and get review     | 30 min    | Day 0 |
| Merge and deploy to staging  | 30-60 min | Day 0 |
| Verify and document          | 15 min    | Day 0 |

**Total:** ~2 hours from start to finish

---

## Advanced: Bulk Account Creation

If you need to create many accounts (10+ environments), consider:

1. **Template the configuration:**

   ```bash
   # Script to generate new account from template
   ./scripts/create-account.sh sandbox 987654321098
   ```

2. **Use Terragrunt** for DRY configurations
3. **AWS Organizations** + **Account Factory** for automated account provisioning

See [Phase 8: Next Steps](../phase/phase-8-next-steps.md) for enterprise-scale patterns.
