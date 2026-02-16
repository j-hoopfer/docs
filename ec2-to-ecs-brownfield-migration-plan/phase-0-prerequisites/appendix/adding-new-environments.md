# Guide: Adding a New Environment

**Goal:** Learn how to extend the repository structure to support a new environment (e.g., `staging`, `demo`, or `qa`).

## Overview

Our repository structure is designed to be **multi-environment** and **multi-region**. Adding a new environment involves three main steps:

1.  Creating the directory structure.
2.  Configuring the Terraform backend.
3.  Updating the CI/CD pipeline to validate the new code.

---

## Step 1: Create Directory Structure

Navigate to the repository root (`infra-platform` or `infra-services`) and create the new environment folder.

**Example: Adding a `staging` environment in `us-east-1`**

```bash
mkdir -p environments/staging/us-east-1
```

_(For services repo, append the service name: `environments/staging/us-east-1/auth-api`)_

## Step 2: Configure Terraform Files

You can copy the configuration from an existing environment (like `dev`) and modify it.

### 1. Copy `versions.tf` and `provider.tf`

These files are usually identical across environments, except for tags.

```bash
cp environments/dev/us-east-1/versions.tf environments/staging/us-east-1/
cp environments/dev/us-east-1/provider.tf environments/staging/us-east-1/
```

**Update `provider.tf` tags:**
Change `Environment = "dev"` to `Environment = "staging"`.

### 2. Create `main.tf` (Backend Configuration)

This is the most critical step. You must ensure the **State Key** is unique so it doesn't overwrite other environments.

**`environments/staging/us-east-1/main.tf`**

```hcl
terraform {
  backend "s3" {
    bucket         = "YOUR_DEV_ACCOUNT_BUCKET_NAME" # Use the appropriate account's bucket
    key            = "platform/staging/us-east-1/terraform.tfstate" # <--- UNIQUE KEY
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "YOUR_DEV_ACCOUNT_LOCK_TABLE"
  }
}
```

_(Note: If `staging` lives in the Production AWS account, use the Prod bucket/table instead.)_

## Step 3: Update CI/CD Pipeline

To ensure the new environment is linted and validated, you must add it to the GitHub Actions matrix.

**File:** `.github/workflows/validate.yml`

```yaml
jobs:
  validate:
    strategy:
      matrix:
        directory:
          - environments/dev/us-east-1
          - environments/prod/us-east-1
          - environments/staging/us-east-1 # <--- Add this line
```

## Step 4: Commit and Push

```bash
git add environments/staging
git add .github/workflows/validate.yml
git commit -m "feat: add staging environment infrastructure"
git push origin feature/add-staging
```

## Step 5: Initialize

After merging to main, you can run Terraform locally or in CI:

```bash
cd environments/staging/us-east-1
terraform init
```

You are now ready to apply infrastructure changes to the new environment!
