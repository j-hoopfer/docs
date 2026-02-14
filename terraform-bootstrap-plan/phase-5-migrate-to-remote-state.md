# Terraform Bootstrap - Phase 3: Migrate to Remote State (Optional)

## Overview

**Bootstrap is complete for all accounts**, but the bootstrap Terraform state itself is still stored locally. This optional phase migrates the bootstrap state to S3 for team collaboration and disaster recovery.

**Duration:** 15-30 minutes (per account)

**Who Should Complete This:** Platform engineers familiar with Terraform state migration

**When to Skip This Phase:**

- Bootstrap is managed by a single person
- Team doesn't plan to modify bootstrap infrastructure frequently
- Local state backups are sufficient for your use case

**When to Complete This Phase:**

- Multiple engineers need to manage state infrastructure
- You want centralized state for disaster recovery
- Compliance requires all state in S3

---

## Feature 4: Migrate Bootstrap to Remote State

### Story 4.1: Migrate Bootstrap State to S3

- **Title:** Move Bootstrap State from Local to Remote Backend
- **Persona:** As a **Platform Engineer**, I want to migrate the bootstrap project itself to use remote state so that the team can collaborate on state infrastructure changes.

- **Requirements:**
  - Backend block added to `providers.tf`
  - State migrated from local to S3
  - Local state file deleted
  - Migration verified

- **Implementation Details:**

  #### 1) Update `accounts/poc/providers.tf`

  **Add backend block:**

  ```hcl
  terraform {
    required_version = ">= 1.7.0"

    required_providers {
      aws = {
        source  = "hashicorp/aws"
        version = "~> 5.0"
      }
    }

    # Backend configuration (uncommented after initial bootstrap)
    backend "s3" {
      bucket         = "scale-terraform-state-poc"
      key            = "bootstrap/terraform.tfstate"
      region         = "us-east-1"
      encrypt        = true
      dynamodb_table = "scale-terraform-locks"
    }
  }

  provider "aws" {
    region = var.primary_region

    # Uncomment if using AWS SSO profile
    # profile = "scale-poc"
  }
  ```

  #### 2) Migrate State

  ```bash
  cd accounts/poc

  # Ensure correct AWS credentials
  export AWS_PROFILE=scale-poc
  aws sts get-caller-identity

  # Migrate state
  terraform init -migrate-state
  ```

  **Terraform will prompt:**

  ```
  Initializing the backend...
  Terraform detected that the backend type changed from "local" to "s3".

  Do you want to copy existing state to the new backend?
    Pre-existing state was found while migrating the previous "local" backend to the
    newly configured "s3" backend. No existing state was found in the newly
    configured "s3" backend. Do you want to copy this state to the new "s3"
    backend? Enter "yes" to copy and "no" to start with an empty state.

    Enter a value: yes
  ```

  Type `yes`.

  **Expected output:**

  ```
  Successfully configured the backend "s3"! Terraform will automatically
  use this backend unless the backend configuration changes.

  Terraform has been successfully initialized!
  ```

  #### 3) Verify State in S3

  ```bash
  aws s3 ls s3://scale-terraform-state-poc/bootstrap/
  # Should show: terraform.tfstate
  ```

  #### 4) Verify State Content

  ```bash
  # Download state file
  aws s3 cp s3://scale-terraform-state-poc/bootstrap/terraform.tfstate /tmp/bootstrap-state.json

  # Check for resources
  cat /tmp/bootstrap-state.json | jq '.resources[].type'
  # Should show: aws_s3_bucket, aws_dynamodb_table, aws_iam_policy, etc.
  ```

  #### 5) Delete Local State Files

  ```bash
  rm -f terraform.tfstate*
  ls -la
  # Should NOT show any .tfstate files
  ```

  #### 6) Test State Backend

  ```bash
  terraform plan
  # Should show: "No changes. Your infrastructure matches the configuration."
  ```

- **Technical Requirements:**
  - AWS credentials for the account being migrated
  - Existing bootstrap infrastructure (S3 bucket + DynamoDB table)
  - Local state file exists before migration

- **Acceptance Criteria:**
  - ✅ Backend block added to `providers.tf`
  - ✅ `terraform init -migrate-state` completes successfully
  - ✅ State file exists at `s3://scale-terraform-state-poc/bootstrap/terraform.tfstate`
  - ✅ Local `terraform.tfstate` files deleted
  - ✅ `terraform plan` works with remote state
  - ✅ No local state files remain in directory

---

### Story 4.2: Repeat Migration for Dev and Prod (Optional)

- **Title:** Migrate Dev and Prod Bootstrap State to S3
- **Persona:** As a **Platform Engineer**, I want to ensure all bootstrap state is centralized so that the team can manage infrastructure consistently across all accounts.

- **Requirements:**
  - Dev account bootstrap state migrated
  - Prod account bootstrap state migrated
  - Local state files deleted for all accounts

- **Implementation Details:**

  #### 1) Migrate Dev Account

  ```bash
  cd scale.infra-terraform-bootstrap/accounts/dev
  ```

  **Update `providers.tf`:**

  ```hcl
  terraform {
    required_version = ">= 1.7.0"

    required_providers {
      aws = {
        source  = "hashicorp/aws"
        version = "~> 5.0"
      }
    }

    backend "s3" {
      bucket         = "scale-terraform-state-dev"
      key            = "bootstrap/terraform.tfstate"
      region         = "us-east-1"
      encrypt        = true
      dynamodb_table = "scale-terraform-locks"
    }
  }

  provider "aws" {
    region = var.primary_region
  }
  ```

  **Migrate:**

  ```bash
  export AWS_PROFILE=scale-dev
  terraform init -migrate-state
  # Type "yes" when prompted

  # Verify
  aws s3 ls s3://scale-terraform-state-dev/bootstrap/

  # Clean up
  rm -f terraform.tfstate*
  ```

  #### 2) Migrate Prod Account

  ```bash
  cd scale.infra-terraform-bootstrap/accounts/prod
  ```

  **Update `providers.tf`:**

  ```hcl
  terraform {
    required_version = ">= 1.7.0"

    required_providers {
      aws = {
        source  = "hashicorp/aws"
        version = "~> 5.0"
      }
    }

    backend "s3" {
      bucket         = "scale-terraform-state-prod"
      key            = "bootstrap/terraform.tfstate"
      region         = "us-east-1"
      encrypt        = true
      dynamodb_table = "scale-terraform-locks"
    }
  }

  provider "aws" {
    region = var.primary_region
  }
  ```

  **Migrate:**

  ```bash
  export AWS_PROFILE=scale-prod
  terraform init -migrate-state
  # Type "yes" when prompted

  # Verify
  aws s3 ls s3://scale-terraform-state-prod/bootstrap/

  # Clean up
  rm -f terraform.tfstate*
  ```

- **Acceptance Criteria:**
  - ✅ Dev bootstrap state migrated to S3
  - ✅ Prod bootstrap state migrated to S3
  - ✅ All local state files deleted
  - ✅ `terraform plan` works in all accounts with remote state

---

### Story 4.3: Commit Backend Configuration Changes

- **Title:** Update Git Repository with Remote Backend Configuration
- **Persona:** As a **Platform Engineer**, I need to commit the backend configuration changes so that the team uses remote state when working on bootstrap infrastructure.

- **Requirements:**
  - `providers.tf` files updated in all account directories
  - Changes committed to Git
  - Documentation updated

- **Implementation Details:**

  #### 1) Review Changes

  ```bash
  cd scale.infra-terraform-bootstrap

  git status
  # Should show modified: accounts/poc/providers.tf
  # Should show modified: accounts/dev/providers.tf
  # Should show modified: accounts/prod/providers.tf
  ```

  #### 2) Review Diffs

  ```bash
  git diff accounts/poc/providers.tf
  # Should show added backend "s3" block
  ```

  #### 3) Commit Changes

  ```bash
  git add accounts/*/providers.tf
  git commit -m "Migrate bootstrap state to remote S3 backend for all accounts"
  ```

  #### 4) Update README (Optional)

  Add note to root `README.md`:

  ```markdown
  ## State Storage

  - **Bootstrap State:** Stored in S3 (migrated from local)
    - POC: `s3://scale-terraform-state-poc/bootstrap/terraform.tfstate`
    - Dev: `s3://scale-terraform-state-dev/bootstrap/terraform.tfstate`
    - Prod: `s3://scale-terraform-state-prod/bootstrap/terraform.tfstate`

  - **Infrastructure State:** Managed by downstream projects using backend configs from bootstrap outputs
  ```

  #### 5) Push to GitHub

  ```bash
  git push origin main
  ```

- **Acceptance Criteria:**
  - ✅ All `providers.tf` changes committed
  - ✅ Commit message clearly explains migration
  - ✅ Changes pushed to remote repository
  - ✅ Team members can now clone and work with remote state

---

## Phase 3 Checklist

Complete this checklist to finish bootstrap migration:

- [ ] POC account bootstrap state migrated to S3
- [ ] Dev account bootstrap state migrated to S3
- [ ] Prod account bootstrap state migrated to S3
- [ ] All local `terraform.tfstate` files deleted
- [ ] `terraform plan` works in all accounts with remote state
- [ ] Backend configuration changes committed to Git
- [ ] Changes pushed to GitHub
- [ ] README updated with state locations (optional)

---

## Verification

### Verify Remote State Works

Test in each account:

```bash
# POC
cd accounts/poc
export AWS_PROFILE=scale-poc
terraform plan
# Should show: "No changes"

# Dev
cd ../dev
export AWS_PROFILE=scale-dev
terraform plan
# Should show: "No changes"

# Prod
cd ../prod
export AWS_PROFILE=scale-prod
terraform plan
# Should show: "No changes"
```

### Verify No Local State

```bash
cd scale.infra-terraform-bootstrap

# Should find NO .tfstate files
find . -name "*.tfstate" -o -name "*.tfstate.*"
# Output should be empty
```

### Verify State in S3

```bash
# POC
aws s3 ls s3://scale-terraform-state-poc/bootstrap/ --profile scale-poc

# Dev
aws s3 ls s3://scale-terraform-state-dev/bootstrap/ --profile scale-dev

# Prod
aws s3 ls s3://scale-terraform-state-prod/bootstrap/ --profile scale-prod
```

All should show `terraform.tfstate`.

---

## Common Issues and Solutions

### Issue: State Migration Failed

**Error:**

```
Error: Failed to save state: NoSuchBucket: The specified bucket does not exist
```

**Solution:**

S3 bucket doesn't exist. Verify:

```bash
aws s3 ls | grep terraform-state
```

If missing, you skipped Phase 1/2. Go back and run `terraform apply` first.

### Issue: State Lock During Migration

**Error:**

```
Error: Error acquiring the state lock
```

**Solution:**

Another Terraform process is running or crashed. Delete the lock:

```bash
aws dynamodb delete-item \
  --table-name scale-terraform-locks \
  --key '{"LockID": {"S": "scale-terraform-state-poc/bootstrap/terraform.tfstate"}}'
```

### Issue: Local State Not Found

**Error:**

```
No existing state was found to migrate
```

**Solution:**

You already migrated or deleted local state. Check S3:

```bash
aws s3 ls s3://scale-terraform-state-poc/bootstrap/
```

If state exists in S3, you're done. If not, you may need to import resources.

---

## Rollback Procedure

If migration causes issues, roll back to local state:

```bash
# 1. Remove backend block from providers.tf
vim providers.tf
# Comment out or delete backend "s3" block

# 2. Re-initialize with local backend
terraform init -migrate-state
# Type "yes" to migrate back to local

# 3. Verify
ls -la
# Should show terraform.tfstate file
```

---

## Benefits of Remote State

Now that bootstrap state is remote:

✅ **Team Collaboration:** Multiple engineers can work on bootstrap infrastructure  
✅ **Disaster Recovery:** State backed up in S3 with versioning  
✅ **Consistency:** Same workflow for bootstrap and infrastructure projects  
✅ **Locking:** DynamoDB prevents concurrent modifications  
✅ **Audit Trail:** S3 versioning tracks all state changes

---

**Previous Phase:** [Phase 3 - Bootstrap Additional Accounts](phase-2-bootstrap-additional-accounts.md)  
**Next Steps:** Document backend configs and integrate with infrastructure projects

**Estimated Time:** 15-30 minutes per account (45-90 minutes total)
