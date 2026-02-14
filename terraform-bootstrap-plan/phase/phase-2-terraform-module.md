# Terraform Bootstrap - Phase 2: Create Terraform Module

## Prerequisites

**Required Access:**

- Write access to bootstrap repository (from Phase 1)
- Local clone of the repository

**Required Tools:**

- Terraform >= 1.7.0 (verify with `terraform version`)
- Text editor with HCL syntax highlighting (VS Code recommended)
- Git CLI

**Required Knowledge:**

- Terraform module structure and syntax
- HCL (HashiCorp Configuration Language)
- AWS resource naming conventions
- Basic understanding of S3 and DynamoDB

**Previous Phase:** [Phase 1 - Repository Setup](phase-1-repository-setup.md) must be completed

---

## Overview

**With the repository initialized**, you now need to create a reusable Terraform module that defines the state backend infrastructure. This module will be used by each account to create their S3 bucket and DynamoDB table.

**Important Regional Notes:**

- This module creates **one S3 bucket** and **one DynamoDB table per account**
- You will deploy it **once per account**, not once per region
- The bucket will be created in your primary region (typically `us-east-1`)
- All Terraform projects across all regions in that account will use this bucket

**Duration:** 30-45 minutes

**Who Should Complete This:** Platform engineers with Terraform module development experience

---

## Feature 2: Terraform State Backend Module

### Story 2.1: Create Reusable Terraform State Backend Module

- **Title:** Build Terraform Module for S3 + DynamoDB State Backend
- **Persona:** As a **Platform Engineer**, I need a reusable Terraform module that creates state infrastructure so that I can apply it consistently across multiple AWS accounts.

- **Requirements:**
  - Module creates S3 bucket with versioning and encryption
  - Module creates DynamoDB table for state locking
  - Module creates IAM policy for state access
  - Module includes lifecycle policies for cost optimization
  - Module outputs backend configuration for downstream projects

- **Implementation Details:**

  #### 1) Create files

  ```bash
  touch modules/terraform-state-backend/variables.tf
  touch modules/terraform-state-backend/outputs.tf
  touch modules/terraform-state-backend/s3.tf
  touch modules/terraform-state-backend/dynamo.tf
  touch modules/terraform-state-backend/iam.tf
  ```

  #### 2) Create `modules/terraform-state-backend/variables.tf`

  ```hcl
  variable "bucket_name" {
    description = "Name of the S3 bucket for Terraform state"
    type        = string

    validation {
      condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.bucket_name))
      error_message = "Bucket name must be lowercase, alphanumeric, and hyphens only (3-63 chars)."
    }
  }

  variable "lock_table_name" {
    description = "Name of the DynamoDB table for state locking"
    type        = string
    default     = "mycompany-terraform-locks"
  }

  variable "environment" {
    description = "Environment name (dev, prod)"
    type        = string

    validation {
      condition     = contains(["dev", "prod"], var.environment)
      error_message = "Environment must be one of: dev, prod."
    }
  }

  variable "common_tags" {
    description = "Common tags to apply to all resources"
    type        = map(string)
    default     = {}
  }
  ```

  #### 3) Create `modules/terraform-state-backend/outputs.tf`

  ```hcl
  output "state_bucket_name" {
    description = "Name of the S3 bucket for Terraform state"
    value       = aws_s3_bucket.terraform_state.bucket
  }

  output "state_bucket_arn" {
    description = "ARN of the S3 bucket for Terraform state"
    value       = aws_s3_bucket.terraform_state.arn
  }

  output "lock_table_name" {
    description = "Name of the DynamoDB table for state locking"
    value       = aws_dynamodb_table.terraform_locks.name
  }

  output "lock_table_arn" {
    description = "ARN of the DynamoDB table for state locking"
    value       = aws_dynamodb_table.terraform_locks.arn
  }

  output "iam_policy_arn" {
    description = "ARN of the IAM policy for state access"
    value       = aws_iam_policy.terraform_state_access.arn
  }

  output "backend_config" {
    description = "Backend configuration for downstream projects"
    value = {
      bucket         = aws_s3_bucket.terraform_state.bucket
      region         = aws_s3_bucket.terraform_state.region
      dynamodb_table = aws_dynamodb_table.terraform_locks.name
      encrypt        = true
    }
  }
  ```

  #### 4) Create `modules/terraform-state-backend/s3.tf`

  ```hcl
  # S3 Bucket for Terraform State
  resource "aws_s3_bucket" "terraform_state" {
    bucket = var.bucket_name

    tags = merge(
      var.common_tags,
      {
        Name        = var.bucket_name
        Purpose     = "Terraform State Storage"
        Environment = var.environment
      }
    )
  }

  # Enable Versioning (Critical for state recovery)
  resource "aws_s3_bucket_versioning" "terraform_state" {
    bucket = aws_s3_bucket.terraform_state.id

    versioning_configuration {
      status = "Enabled"
    }
  }

  # Enable Encryption
  resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
    bucket = aws_s3_bucket.terraform_state.id

    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"  # Use "aws:kms" for KMS encryption
      }
    }
  }

  # Block Public Access
  resource "aws_s3_bucket_public_access_block" "terraform_state" {
    bucket = aws_s3_bucket.terraform_state.id

    block_public_acls       = true
    block_public_policy     = true
    ignore_public_acls      = true
    restrict_public_buckets = true
  }

  # Lifecycle Policy (Cleanup old versions after 90 days)
  resource "aws_s3_bucket_lifecycle_configuration" "terraform_state" {
    bucket = aws_s3_bucket.terraform_state.id

    rule {
      id     = "expire-old-versions"
      status = "Enabled"

      filter {} # Apply to all objects

      noncurrent_version_expiration {
        noncurrent_days = 90
      }
    }
  }

  ```

  #### 5) Create `modules/terraform-state-backend/dynamo.tf`

  ```hcl
  # DynamoDB Table for State Locking
  resource "aws_dynamodb_table" "terraform_locks" {
    name         = var.lock_table_name
    billing_mode = "PAY_PER_REQUEST"  # On-demand pricing
    hash_key     = "LockID"

    attribute {
      name = "LockID"
      type = "S"
    }

    tags = merge(
      var.common_tags,
      {
        Name        = var.lock_table_name
        Purpose     = "Terraform State Locking"
        Environment = var.environment
      }
    )
  }
  ```

  #### 6) Create `modules/terraform-state-backend/iam.tf`

  ```hcl

  # IAM Policy for Terraform State Access
  resource "aws_iam_policy" "terraform_state_access" {
    name        = "terraform-state-access-${var.environment}"
    description = "Allows read/write access to Terraform state bucket and lock table"

    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect = "Allow"
          Action = [
            "s3:ListBucket",
            "s3:GetObject",
            "s3:PutObject",
            "s3:DeleteObject"
          ]
          Resource = [
            aws_s3_bucket.terraform_state.arn,
            "${aws_s3_bucket.terraform_state.arn}/*"
          ]
        },
        {
          Effect = "Allow"
          Action = [
            "dynamodb:PutItem",
            "dynamodb:GetItem",
            "dynamodb:DeleteItem",
            "dynamodb:DescribeTable"
          ]
          Resource = aws_dynamodb_table.terraform_locks.arn
        }
      ]
    })

    tags = var.common_tags
  }
  ```

- **Technical Requirements:**
  - Terraform >= 1.0
  - AWS Provider ~> 5.0
  - S3 bucket naming follows DNS-compliant rules
  - DynamoDB table uses `LockID` as partition key (required by Terraform)

- **Acceptance Criteria:**
  - ✅ `modules/terraform-state-backend/s3.tf` creates S3 bucket with versioning
  - ✅ `modules/terraform-state-backend/dynamo.tf` creates DynamoDB table with `LockID` key
  - ✅ `modules/terraform-state-backend/iam.tf` creates IAM policy
  - ✅ `variables.tf` includes validation for bucket name and environment
  - ✅ `outputs.tf` exports all necessary values
  - ✅ Root `README.md` includes module documentation

---

### Story 2.2: Commit Terraform Module

- **Title:** Version Control State Backend Module
- **Persona:** As a **Platform Engineer**, I need to commit the Terraform module to Git so that it's version-controlled and can be used by account configurations.

- **Requirements:**
  - Module files staged for commit
  - Descriptive commit message
  - Changes pushed to remote repository

- **Implementation Details:**

  #### 1) Stage and Commit

  ```bash
  git add modules/terraform-state-backend/
  git commit -m "Add Terraform state backend module"
  git push origin main
  ```

- **Acceptance Criteria:**
  - ✅ Module files committed to Git
  - ✅ Changes pushed to GitHub

---

## Phase 2 Checklist

Complete this checklist before proceeding to Phase 3:

- [ ] `modules/terraform-state-backend/main.tf` created with 7 resources
- [ ] S3 bucket resource includes versioning, encryption, public access block, lifecycle policy
- [ ] DynamoDB table resource configured with `LockID` partition key
- [ ] IAM policy resource grants S3 and DynamoDB access
- [ ] `variables.tf` includes validation for bucket name and environment
- [ ] `outputs.tf` exports bucket name, table name, policy ARN, and backend config
- [ ] Root `README.md` verified to include module documentation and example
- [ ] All module files committed and pushed to GitHub

**Estimated Time:** 30-45 minutes

---

**Previous Phase:** [Phase 1 - Repository Setup](phase-1-repository-setup.md)  
**Next Phase:** [Phase 3 - Bootstrap Dev Account](phase-3-bootstrap-dev.md)
