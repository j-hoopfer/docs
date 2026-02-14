# Using Shared Configuration

The `common/` directory stores values that are used across all modules - like AWS account IDs, regions, and standard tags.

---

## Why This Exists

**The Problem:**  
Without `common/`, you'd type the same account ID in 10 different files. When the account ID changes, you'd have to update 10 files (and probably miss a few).

**The Solution:**  
Type the account ID once in `common/locals.tf`. All modules reference it. Update once, change everywhere.

---

## What's Inside

**File:** `common/locals.tf`

**Contains:**

1. **Account Registry** - All AWS account IDs and metadata
2. **AWS Region** - Default region for all resources
3. **Standard Tags** - Tags applied to every resource

**Example:**

```hcl
locals {
  # Account registry
  accounts = {
    dev = {
      id               = "471112975126"
      name             = "Development"
      environment      = "dev"
      terraform_bucket = "terraform-state-dev-471112975126"
    }
    prod = {
      id               = "637423317953"
      name             = "Production"
      environment      = "prod"
      terraform_bucket = "terraform-state-prod-637423317953"
    }
  }

  # Default region
  aws_region = "us-east-1"

  # Tags for every resource
  common_tags = {
    ManagedBy    = "Terraform"
    Repository   = "tf-aws-identity"
    CostCenter   = "Platform-Engineering"
    Compliance   = "SOC2"
  }
}
```

---

## How to Use in Your Module

**Step 1:** Import the common module

```hcl
# In your module's locals.tf or permission_sets.tf
module "common" {
  source = "../common"
}
```

**Step 2:** Reference the values

```hcl
locals {
  # Get specific account ID
  dev_account_id  = module.common.accounts["dev"].id
  prod_account_id = module.common.accounts["prod"].id

  # Get all account IDs as a list
  all_accounts = module.common.all_account_ids
}

resource "aws_ssoadmin_permission_set" "admin" {
  name             = "AdministratorAccess"
  instance_arn     = data.aws_ssoadmin_instances.main.arns[0]

  # Use common tags
  tags = module.common.common_tags
}
```

---

## Common Tasks

### Add a New AWS Account

**Scenario:** Your company creates a new "Staging" environment

**Steps:**

1. Edit `common/locals.tf`
2. Add new entry:

```hcl
locals {
  accounts = {
    dev = { ... }
    prod = { ... }
    staging = {
      id               = "123456789012"
      name             = "Staging"
      environment      = "staging"
      terraform_bucket = "terraform-state-staging-123456789012"
    }
  }
}
```

3. Create `backend-staging.hcl` at repository root:

```hcl
bucket         = "terraform-state-staging-123456789012"
key            = "identity-center/terraform.tfstate"
region         = "us-east-1"
encrypt        = true
dynamodb_table = "terraform-state-locks"
```

4. Deploy to staging:

```bash
cd identity-center/
terraform init -backend-config=../backend-staging.hcl
terraform apply
```

### Update Standard Tags

**Scenario:** New compliance requirement needs "DataClassification" tag

**Steps:**

1. Edit `common/locals.tf`:

```hcl
common_tags = {
  ManagedBy         = "Terraform"
  Repository        = "tf-aws-identity"
  CostCenter        = "Platform-Engineering"
  Compliance        = "SOC2"
  DataClassification = "Internal"  # NEW
}
```

2. Deploy each module to apply new tag:

```bash
cd identity-center/
terraform apply  # Resources will be updated with new tag
```

### Change Default Region

**Scenario:** Company moves to `us-west-2`

**Steps:**

1. Edit `common/locals.tf`:

```hcl
aws_region = "us-west-2"  # Changed from us-east-1
```

2. Update backend configs:

```hcl
# backend.hcl
region = "us-west-2"  # Changed
```

3. Migrate resources (requires advanced Terraform knowledge - ask for help!)

---

## Available Outputs

The `common/` module exports these values for use in other modules:

| Output            | Type   | Description           | Example Usage                      |
| ----------------- | ------ | --------------------- | ---------------------------------- |
| `accounts`        | map    | All account metadata  | `module.common.accounts["dev"].id` |
| `aws_region`      | string | Default AWS region    | `module.common.aws_region`         |
| `common_tags`     | map    | Standard tags         | `module.common.common_tags`        |
| `all_account_ids` | list   | All account IDs       | `module.common.all_account_ids`    |
| `dev_accounts`    | list   | Dev account IDs only  | `module.common.dev_accounts`       |
| `prod_accounts`   | list   | Prod account IDs only | `module.common.prod_accounts`      |

---

## Real-World Example

**Before (hardcoded values):**

```hcl
# identity-center/main.tf
resource "aws_ssoadmin_permission_set" "admin" {
  name = "AdministratorAccess"
  tags = {
    ManagedBy = "Terraform"
    Repository = "tf-aws-identity"
  }
}

# iam/roles/main.tf
resource "aws_iam_role" "example" {
  name = "MyRole"
  tags = {
    ManagedBy = "Terraform"
    Repository = "tf-aws-identity"
  }
}
```

**Problem:** Tags duplicated. If we need to add a tag, update 2 files.

**After (using common):**

```hcl
# identity-center/main.tf
module "common" {
  source = "../common"
}

resource "aws_ssoadmin_permission_set" "admin" {
  name = "AdministratorAccess"
  tags = module.common.common_tags  # ← Shared tags
}

# iam/roles/main.tf
module "common" {
  source = "../common"
}

resource "aws_iam_role" "example" {
  name = "MyRole"
  tags = module.common.common_tags  # ← Same tags!
}
```

**Benefit:** Add a tag to `common/locals.tf`, both modules get it automatically.

---

## When NOT to Use Common

**Don't put here:**

- ❌ Module-specific variables (goes in module's `variables.tf`)
- ❌ Resource definitions (goes in module's `main.tf`)
- ❌ Secrets or passwords (use AWS Secrets Manager)
- ❌ Environment-specific overrides (use tfvars files)

**DO put here:**

- ✅ Account IDs that don't change often
- ✅ AWS regions used organization-wide
- ✅ Standard tags required by all resources
- ✅ Naming conventions or prefixes

---

## Troubleshooting

**Error: Module not found**

```
Error: Module not found: ../common
```

**Fix:** Verify relative path from your module to common/

```bash
# From identity-center/
ls ../common/locals.tf  # Should exist
```

**Error: No outputs declared**

```
Error: Unsupported attribute: module.common has no output "accounts"
```

**Fix:** Ensure `common/locals.tf` has output blocks (it should already have them).

**Tags not updating**

```
Terraform says "No changes" but I edited common/locals.tf
```

**Fix:** Run `terraform refresh` first, then `terraform apply`.
