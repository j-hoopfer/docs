# What Goes Where - Directory Guide

Quick reference for where to put your code and what each directory does.

---

## Root Directory (`/`)

**What it's for:** Repository-level configuration and entry points

**What goes here:**

- `README.md` - Start here! Explains the whole project
- `.gitignore` - Tells Git what files to ignore

**Don't put here:**

- ❌ Terraform resource definitions (goes in module directories)
- ❌ Python scripts (goes in `tools/`)
- ❌ Documentation (goes in `docs/`)

---

## `common/` - Shared Values

**What it's for:** Numbers and values used by all modules (account IDs, regions, tags)

**What goes here:**

- `locals.tf` - AWS account IDs, regions, standard tags

**Why it exists:**  
Instead of typing "471112975126" in 20 different files, type it once here. When account IDs change, update one file instead of searching through everything.

**Example:**

```hcl
# common/locals.tf
locals {
  accounts = {
    dev = {
      id = "471112975126"
      name = "Development"
    }
  }
}
```

**Don't put here:**

- ❌ Terraform resources (goes in module directories)
- ❌ Module-specific variables

---

## `tools/` - Helper Scripts

**What it's for:** Python/Bash scripts that help with deployments or migrations

**What goes here:**

- `export_sso_assignments.py` - Backs up existing SSO config before migration
- Future: validation scripts, cost estimators, automation helpers

**When to add a script here:**

- You find yourself running the same AWS CLI commands repeatedly
- You need to export/import data before Terraform runs
- You want to validate something before deploying

**Don't put here:**

- ❌ Terraform code
- ❌ Application code
- ❌ Infrastructure definitions

---

## `identity-center/` - Identity Center Module

**What it's for:** AWS Identity Center (SSO) configuration - who can access which AWS accounts

**What goes here:**

- `main.tf` - Module documentation and overview
- `locals.tf` - Local value transformations (assignment matrix, instance details)
- `data.tf` - Data sources (Identity Center instance, group lookups)
- `permission_sets.tf` - Permission set definitions (standard and custom)
- `policies.tf` - IAM policy documents for custom permission sets
- `assignments.tf` - Account assignments (standard and beta)
- `variables.tf` - Inputs you can customize (account IDs, role names)
- `outputs.tf` - Values this module exports (SSO instance ARN, permission set IDs)
- `backend.tf` - Backend configuration (tells Terraform to use S3)
- `versions.tf` - Provider version constraints

**When to edit:**

- Adding a new AWS account to the organization
- Creating new permission sets (like "Developer", "ReadOnly")
- Assigning Google groups to AWS accounts
- Defining custom IAM policies for permission sets

**Don't put here:**

- ❌ IAM roles or policies (goes in `iam/`)
- ❌ Account IDs (goes in `common/locals.tf`)

---

## `iam/` - IAM Resources Module

**What it's for:** AWS IAM roles, policies, and groups (separate from Identity Center)

**Structure:**

```
iam/
├── roles/          # Cross-account roles, service roles (EC2, Lambda, etc.)
├── policies/       # Custom IAM policies (not AWS managed)
└── groups/         # IAM groups (if not using SSO exclusively)
```

**When to use:**

- Creating service roles for EC2, Lambda, ECS
- Writing custom IAM policies for least-privilege access
- Setting up cross-account roles for automation

**Don't put here:**

- ❌ SSO permission sets (goes in `identity-center/`)
- ❌ S3 bucket policies (goes in a future `s3/` module)

---

## `docs/` - Documentation

**What it's for:** All the guides and explanations (this file!)

**What goes here:**

- `what-goes-where.md` - This file (directory guide)
- `backend-setup.md` - How to create S3 buckets and DynamoDB tables
- `daily-workflow.md` - How to deploy to Dev/Prod
- `common-config.md` - How to use the `common/` directory
- `tools-guide.md` - How to use helper scripts

**Why centralized:**  
All documentation in one place makes it easy to find. No hunting through 10 different directories for README files.

---

## Decision Tree: Where Does My Code Go?

**I want to add a new AWS account:**

1. Edit `common/locals.tf` (add account ID)
2. Create `backend-ENVNAME.hcl` at root
3. Run backend setup in new account
4. Deploy `identity-center/` module to it

**I want to create a new IAM role:**

1. Add file to `iam/roles/`
2. Follow same backend pattern as other modules

**I want to add a Python automation script:**

1. Add to `tools/`
2. Document it in `docs/tools-guide.md`

**I want to add a totally new AWS service (like VPC, RDS):**

1. Create new module directory at root (e.g., `networking/`)
2. Copy `backend.tf` and `versions.tf` from `identity-center/`
3. Update backend key to match module name
4. Deploy independently from other modules

---

## Quick Reference

| I'm working on...      | Go to directory...       |
| ---------------------- | ------------------------ |
| Adding AWS accounts    | `common/locals.tf`       |
| SSO permission sets    | `identity-center/`       |
| IAM roles for services | `iam/roles/`             |
| Custom IAM policies    | `iam/policies/`          |
| Helper scripts         | `tools/`                 |
| Reading how to deploy  | `docs/daily-workflow.md` |
| Setting up backends    | `docs/backend-setup.md`  |

---

## Anti-Patterns (Don't Do This)

❌ **Hardcoding account IDs in modules**  
✅ Use `module.common.accounts["dev"].id`

❌ **Putting everything in one giant main.tf**  
✅ Split into logical modules (identity-center, iam, etc.)

❌ **Creating backend configs inside module directories**  
✅ Keep backend configs at repository root

❌ **Mixing SSO and IAM in the same module**  
✅ Separate concerns (identity-center vs. iam)

❌ **Documentation scattered across README files**  
✅ Centralize in `docs/` directory
