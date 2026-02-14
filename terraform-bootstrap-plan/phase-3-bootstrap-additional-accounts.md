# Terraform Bootstrap - Phase 2: Bootstrap Additional Accounts

## Overview

**POC account bootstrap is complete**, now deploy Terraform state infrastructure to Dev and Prod AWS accounts. This phase replicates the POC setup across remaining environments.

**Duration:** 30-60 minutes (per account)

**Who Should Complete This:** Platform engineers with admin access to Dev and Prod AWS accounts

---

## Feature 3: Bootstrap Additional Accounts

### Story 3.1: Bootstrap Dev Account

- **Title:** Deploy Terraform State Infrastructure in Dev Account
- **Persona:** As a **Platform Engineer**, I need to create state infrastructure in the Dev account so that development teams can manage infrastructure with Terraform.

- **Requirements:**
  - Dev account Terraform files created
  - AWS credentials configured for Dev account
  - S3 bucket and DynamoDB table created
  - Backend configuration documented

- **Implementation Details:**

  #### 1) Create Dev Configuration

  ```bash
  cd scale.infra-terraform-bootstrap/accounts

  # Copy POC structure
  cp -r poc dev

  cd dev
  ```

  #### 2) Update `variables.tf`

  ```hcl
  variable "environment" {
    description = "Environment name"
    type        = string
    default     = "dev"  # Changed from "poc"
  }

  # Keep other variables the same
  ```

  #### 3) Update `terraform.tfvars.example`

  ```hcl
  aws_account_id = "987654321098"  # Dev account ID
  environment    = "dev"
  primary_region = "us-east-1"
  ```

  #### 4) Create `terraform.tfvars`

  ```bash
  cp terraform.tfvars.example terraform.tfvars
  vim terraform.tfvars
  # Set actual Dev account ID
  ```

  #### 5) Switch AWS Credentials

  ```bash
  aws sso login --profile scale-dev
  export AWS_PROFILE=scale-dev

  # Verify
  aws sts get-caller-identity
  # Should show Dev account ID
  ```

  #### 6) Apply Bootstrap

  ```bash
  terraform init
  terraform plan
  terraform apply
  ```

  **Expected output:**

  ```
  Apply complete! Resources: 7 added, 0 changed, 0 destroyed.

  Outputs:

  backend_configuration = <<EOT
  # Add this to your Terraform configuration:

  terraform {
    backend "s3" {
      bucket         = "scale-terraform-state-dev"
      key            = "{region}/{layer}/terraform.tfstate"
      region         = "us-east-1"
      encrypt        = true
      dynamodb_table = "scale-terraform-locks"
    }
  }
  EOT
  iam_policy_arn = "arn:aws:iam::987654321098:policy/terraform-state-access-dev"
  lock_table = "scale-terraform-locks"
  state_bucket = "scale-terraform-state-dev"
  ```

  #### 7) Save Backend Config

  ```bash
  terraform output backend_configuration > ../../BACKEND_CONFIG_DEV.txt
  ```

  #### 8) Verify in AWS Console

  **S3 Bucket:**
  - Navigate to S3 in Dev account
  - Find `scale-terraform-state-dev`
  - Verify versioning and encryption enabled

  **DynamoDB Table:**
  - Navigate to DynamoDB in Dev account
  - Find `scale-terraform-locks`
  - Verify `LockID` partition key

- **Acceptance Criteria:**
  - ✅ S3 bucket `scale-terraform-state-dev` created
  - ✅ DynamoDB table `scale-terraform-locks` created in Dev account
  - ✅ Backend configuration saved to `BACKEND_CONFIG_DEV.txt`
  - ✅ No resources created in POC account (verified credentials)

---

### Story 3.2: Bootstrap Prod Account

- **Title:** Deploy Terraform State Infrastructure in Prod Account
- **Persona:** As a **Platform Engineer**, I need to create state infrastructure in the Prod account so that production workloads can be managed with Terraform under strict controls.

- **Requirements:**
  - Prod account Terraform files created
  - AWS credentials configured for Prod account
  - S3 bucket and DynamoDB table created with enhanced security
  - Object lock enabled (optional for compliance)
  - Backend configuration documented

- **Implementation Details:**

  #### 1) Create Prod Configuration

  ```bash
  cd scale.infra-terraform-bootstrap/accounts

  # Copy Dev structure
  cp -r dev prod

  cd prod
  ```

  #### 2) Update `variables.tf`

  ```hcl
  variable "environment" {
    description = "Environment name"
    type        = string
    default     = "prod"  # Changed from "dev"
  }
  ```

  #### 3) Update `terraform.tfvars.example`

  ```hcl
  aws_account_id = "111222333444"  # Prod account ID
  environment    = "prod"
  primary_region = "us-east-1"
  ```

  #### 4) Create `terraform.tfvars`

  ```bash
  cp terraform.tfvars.example terraform.tfvars
  vim terraform.tfvars
  # Set actual Prod account ID
  ```

  #### 5) Switch AWS Credentials

  ```bash
  aws sso login --profile scale-prod
  export AWS_PROFILE=scale-prod

  # Verify
  aws sts get-caller-identity
  # Should show Prod account ID
  ```

  #### 6) Apply Bootstrap

  ```bash
  terraform init
  terraform plan
  terraform apply
  ```

  **Expected output:**

  ```
  Apply complete! Resources: 7 added, 0 changed, 0 destroyed.

  Outputs:

  backend_configuration = <<EOT
  # Add this to your Terraform configuration:

  terraform {
    backend "s3" {
      bucket         = "scale-terraform-state-prod"
      key            = "{region}/{layer}/terraform.tfstate"
      region         = "us-east-1"
      encrypt        = true
      dynamodb_table = "scale-terraform-locks"
    }
  }
  EOT
  iam_policy_arn = "arn:aws:iam::111222333444:policy/terraform-state-access-prod"
  lock_table = "scale-terraform-locks"
  state_bucket = "scale-terraform-state-prod"
  ```

  #### 7) Enable MFA Delete (Prod Only - Optional)

  **Why:** Require MFA to delete state file versions (compliance requirement)

  **Note:** MFA delete can only be enabled by the root user via AWS CLI.

  ```bash
  # Switch to root credentials (use with extreme caution)
  # This requires root user access keys (temporary) and root MFA device

  aws s3api put-bucket-versioning \
    --bucket scale-terraform-state-prod \
    --versioning-configuration Status=Enabled,MFADelete=Enabled \
    --mfa "arn:aws:iam::111222333444:mfa/root-account-mfa-device XXXXXX"
    # Replace XXXXXX with current MFA code
  ```

  **Best Practice:** After enabling MFA delete, immediately delete root access keys.

  #### 8) Save Backend Config

  ```bash
  terraform output backend_configuration > ../../BACKEND_CONFIG_PROD.txt
  ```

  #### 9) Verify in AWS Console

  **S3 Bucket:**
  - Navigate to S3 in Prod account
  - Find `scale-terraform-state-prod`
  - Verify versioning and encryption enabled
  - Verify MFA delete enabled (if applicable)

  **DynamoDB Table:**
  - Navigate to DynamoDB in Prod account
  - Find `scale-terraform-locks`

- **Acceptance Criteria:**
  - ✅ S3 bucket `scale-terraform-state-prod` created
  - ✅ DynamoDB table `scale-terraform-locks` created in Prod account
  - ✅ MFA delete enabled (optional, if compliance requires)
  - ✅ Backend configuration saved to `BACKEND_CONFIG_PROD.txt`
  - ✅ No resources created in POC or Dev accounts

---

## Phase 2 Checklist

Complete this checklist before proceeding to Phase 3 (optional):

### Dev Account

- [ ] `accounts/dev/` configuration created
- [ ] `terraform.tfvars` updated with Dev account ID
- [ ] AWS credentials verified for Dev account
- [ ] `terraform apply` completed successfully
- [ ] S3 bucket `scale-terraform-state-dev` exists
- [ ] DynamoDB table created in Dev account (not POC)
- [ ] Backend configuration saved to `BACKEND_CONFIG_DEV.txt`

### Prod Account

- [ ] `accounts/prod/` configuration created
- [ ] `terraform.tfvars` updated with Prod account ID
- [ ] AWS credentials verified for Prod account
- [ ] `terraform apply` completed successfully
- [ ] S3 bucket `scale-terraform-state-prod` exists
- [ ] DynamoDB table created in Prod account
- [ ] MFA delete enabled (if required for compliance)
- [ ] Backend configuration saved to `BACKEND_CONFIG_PROD.txt`

### Verification

- [ ] Three separate S3 buckets exist (one per account)
- [ ] Three separate DynamoDB tables exist (one per account)
- [ ] Backend configs documented for all environments
- [ ] No cross-account resource contamination

---

## Common Issues and Solutions

### Issue: Bucket Already Exists

**Error:**

```
Error: creating Amazon S3 Bucket (scale-terraform-state-dev): BucketAlreadyOwnedByYou
```

**Solution:**

Bucket already exists in your account. Either:

1. Delete the bucket: `aws s3 rb s3://scale-terraform-state-dev --force`
2. Import existing bucket: `terraform import module.terraform_backend.aws_s3_bucket.terraform_state scale-terraform-state-dev`

### Issue: Wrong Account Credentials

**Symptom:** Resources created in POC account when bootstrapping Dev

**Solution:**

```bash
# Verify current credentials
aws sts get-caller-identity

# If wrong account, switch profile
export AWS_PROFILE=scale-dev
aws sso login --profile scale-dev

# Verify again
aws sts get-caller-identity
```

### Issue: Access Denied for MFA Delete

**Error:**

```
Error: AccessDenied: Access Denied
```

**Solution:**

MFA delete requires root user credentials. This is a security feature. Options:

1. Use root credentials temporarily (delete access keys immediately after)
2. Skip MFA delete if not required for compliance
3. Enable via AWS Console as root user (not supported - must use CLI)

---

## Next Steps

After completing Phase 2:

1. **Document Backend Configs:** Share `BACKEND_CONFIG_*.txt` files with infrastructure teams
2. **Update CI/CD:** Attach IAM policies to CI/CD service accounts in each environment
3. **Begin Migration:** Start moving existing projects to use remote backends
4. **Optional:** Proceed to Phase 3 to migrate bootstrap state itself to remote backend

---

**Previous Phase:** [Phase 2 - Bootstrap POC Account](phase-1-bootstrap-poc.md)  
**Next Phase:** [Phase 4 - Migrate to Remote State (Optional)](phase-3-migrate-to-remote-state.md)

**Estimated Time:** 30-60 minutes per account (1-2 hours total)
