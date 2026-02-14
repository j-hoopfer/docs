# Terraform Bootstrap - Phase 0: Repository Setup

## Overview

**Before deploying state infrastructure**, you need to create the repository structure and reusable Terraform module. This phase establishes the foundation for bootstrapping POC, Dev, and Prod accounts.

**Duration:** 1-2 hours

**Who Should Complete This:** Platform engineers with GitHub access and Terraform experience

---

## Feature 1: Repository Structure and Module Creation

### Story 1.1: Initialize Bootstrap Repository

- **Title:** Create GitHub Repository and Base Directory Structure
- **Persona:** As a **Platform Engineer**, I need to create the bootstrap repository with proper structure so that the team has a consistent workspace for state backend code.

- **Requirements:**
  - Private GitHub repository created
  - Base directory structure initialized
  - Repository cloned locally
  - Initial commit pushed to `main` branch

- **Implementation Details:**

  #### 1) Create GitHub Repository

  ```bash
  # Using GitHub CLI
  gh repo create scale/scale.infra-terraform-bootstrap \
    --private \
    --description "Terraform state backend bootstrap for POC/Dev/Prod accounts"

  # Or create via GitHub web UI:
  # - Navigate to github.com/scale
  # - New repository → scale.infra-terraform-bootstrap
  # - Private
  # - Do NOT initialize with README
  ```

  #### 2) Clone Locally

  ```bash
  git clone git@github.com:scale/scale.infra-terraform-bootstrap.git
  cd scale.infra-terraform-bootstrap
  ```

  #### 3) Create Directory Structure

  ```bash
  mkdir -p modules/terraform-state-backend
  mkdir -p accounts/{poc,dev,prod}

  # Verify structure
  tree -L 2
  ```

  **Expected structure:**

  ```
  scale.infra-terraform-bootstrap/
  ├── modules/
  │   └── terraform-state-backend/
  └── accounts/
      ├── poc/
      ├── dev/
      └── prod/
  ```

  #### 4) Initialize Git

  ```bash
  git init
  git branch -M main
  ```

- **Acceptance Criteria:**
  - ✅ Repository exists at `github.com/scale/scale.infra-terraform-bootstrap`
  - ✅ Repository is private
  - ✅ `modules/` and `accounts/` directories created
  - ✅ Local clone exists and is on `main` branch

---

### Story 1.2: Create Reusable Terraform State Backend Module

- **Title:** Build Terraform Module for S3 + DynamoDB State Backend
- **Persona:** As a **Platform Engineer**, I need a reusable Terraform module that creates state infrastructure so that I can apply it consistently across multiple AWS accounts.

- **Requirements:**
  - Module creates S3 bucket with versioning and encryption
  - Module creates DynamoDB table for state locking
  - Module creates IAM policy for state access
  - Module includes lifecycle policies for cost optimization
  - Module outputs backend configuration for downstream projects

- **Implementation Details:**

  #### 1) Create `modules/terraform-state-backend/main.tf`

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

      noncurrent_version_expiration {
        noncurrent_days = 90
      }
    }
  }

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
    default     = "scale-terraform-locks"
  }

  variable "environment" {
    description = "Environment name (poc, dev, prod)"
    type        = string

    validation {
      condition     = contains(["poc", "dev", "prod"], var.environment)
      error_message = "Environment must be one of: poc, dev, prod."
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

  #### 4) Create `modules/terraform-state-backend/README.md`

  ```markdown
  # Terraform State Backend Module

  Creates S3 bucket and DynamoDB table for Terraform remote state storage.

  ## Features

  - S3 bucket with versioning enabled
  - Server-side encryption (AES256 or KMS)
  - Public access blocked
  - Lifecycle policy (deletes old versions after 90 days)
  - DynamoDB table for state locking (on-demand billing)
  - IAM policy for CI/CD access

  ## Usage

  \`\`\`hcl
  module "terraform_backend" {
  source = "../../modules/terraform-state-backend"

  bucket_name = "scale-terraform-state-poc"
  lock_table_name = "scale-terraform-locks"
  environment = "poc"

  common_tags = {
  ManagedBy = "Terraform"
  Repository = "scale.infra-terraform-bootstrap"
  }
  }
  \`\`\`

  ## Outputs

  - `state_bucket_name` - S3 bucket name
  - `lock_table_name` - DynamoDB table name
  - `iam_policy_arn` - IAM policy ARN for CI/CD
  - `backend_config` - Complete backend configuration
  ```

- **Technical Requirements:**
  - Terraform >= 1.0
  - AWS Provider ~> 5.0
  - S3 bucket naming follows DNS-compliant rules
  - DynamoDB table uses `LockID` as partition key (required by Terraform)

- **Acceptance Criteria:**
  - ✅ `modules/terraform-state-backend/main.tf` creates S3 bucket with versioning
  - ✅ `modules/terraform-state-backend/main.tf` creates DynamoDB table with `LockID` key
  - ✅ `modules/terraform-state-backend/main.tf` creates IAM policy
  - ✅ `variables.tf` includes validation for bucket name and environment
  - ✅ `outputs.tf` exports all necessary values
  - ✅ `README.md` documents module usage

---

### Story 1.3: Create .gitignore and Repository Documentation

- **Title:** Configure Git Ignore Rules and Repository README
- **Persona:** As a **Platform Engineer**, I need proper `.gitignore` rules and documentation so that sensitive state files are never committed and the team understands the repository purpose.

- **Requirements:**
  - `.gitignore` excludes Terraform state files
  - `.gitignore` excludes `*.tfvars` but includes `*.tfvars.example`
  - Root `README.md` documents repository purpose and usage
  - Files committed to Git

- **Implementation Details:**

  #### 1) Create `.gitignore`

  ```bash
  cat > .gitignore << 'EOF'
  # Terraform State (Local)
  *.tfstate
  *.tfstate.*
  *.tfstate.backup

  # Terraform directories
  .terraform/
  .terraform.lock.hcl

  # Variable files (contain account IDs)
  *.tfvars
  !*.tfvars.example

  # Logs
  *.log

  # macOS
  .DS_Store

  # Editors
  .vscode/
  .idea/
  *.swp
  *.swo
  *~
  EOF
  ```

  #### 2) Create Root `README.md`

  ```bash
  cat > README.md << 'EOF'
  # Scale Terraform Bootstrap

  **Purpose:** One-time setup to create Terraform state infrastructure (S3 + DynamoDB) for POC, Dev, and Prod AWS accounts.

  ## Overview

  This repository solves the "chicken and egg" problem:
  - **Problem:** You need an S3 bucket to store Terraform state
  - **Solution:** Run this bootstrap project with local state once per account

  After bootstrap, all other infrastructure projects use the remote S3 backend.

  ## Repository Structure

  ```

  scale.infra-terraform-bootstrap/
  ├── modules/terraform-state-backend/ # Reusable module
  └── accounts/ # Account-specific configs
  ├── poc/
  ├── dev/
  └── prod/

  ````

  ## Quick Start

  ### 1. Bootstrap POC Account

  ```bash
  cd accounts/poc
  cp terraform.tfvars.example terraform.tfvars
  vim terraform.tfvars  # Set aws_account_id

  terraform init
  terraform plan
  terraform apply
  ````

  ### 2. Copy Backend Config

  ```bash
  terraform output backend_configuration
  # Copy output to downstream projects
  ```

  ### 3. Repeat for Dev and Prod

  ```bash
  cd ../dev
  # Same steps...
  ```

  ## Outputs

  Each account outputs backend configuration for use in other repositories:

  ```hcl
  terraform {
    backend "s3" {
      bucket         = "scale-terraform-state-poc"
      key            = "{region}/{layer}/terraform.tfstate"
      region         = "us-east-1"
      encrypt        = true
      dynamodb_table = "scale-terraform-locks"
    }
  }
  ```

  ## Documentation
  - [Phase 0: Repository Setup](phase-0-repository-setup.md)
  - [Phase 1: Bootstrap POC Account](phase-1-bootstrap-poc.md)
  - [Phase 2: Bootstrap Additional Accounts](phase-2-bootstrap-additional-accounts.md)
  - [Phase 3: Migrate to Remote State](phase-3-migrate-to-remote-state.md)

  ## Cost
  - S3: ~$0.023/GB + $0.005/1000 requests (< $1/month)
  - DynamoDB: $0.25/month (on-demand, ~100 locks/month)
  - **Total: < $2/month per account**

  ## Prerequisites
  - AWS CLI v2 with SSO configured
  - Terraform >= 1.7.0
  - Admin access to target AWS account

  #### 3) Commit Files

  ```bash
  git add .
  git commit -m "Add Terraform state backend module and documentation"
  git push -u origin main
  ```

- **Acceptance Criteria:**
  - ✅ `.gitignore` excludes `*.tfstate`, `*.tfvars`, `.terraform/`
  - ✅ `.gitignore` allows `*.tfvars.example`
  - ✅ Root `README.md` documents purpose, structure, and quick start
  - ✅ Files committed and pushed to GitHub
  - ✅ No sensitive files in Git history

---

## Phase 0 Checklist

Complete this checklist before proceeding to Phase 1:

- [ ] GitHub repository `scale/scale.infra-terraform-bootstrap` created
- [ ] Repository is private
- [ ] Directory structure created (`modules/`, `accounts/`)
- [ ] `modules/terraform-state-backend/main.tf` creates 7 resources
- [ ] Module variables include validation rules
- [ ] Module outputs include `backend_config`
- [ ] `.gitignore` configured properly
- [ ] Root `README.md` created
- [ ] All files committed and pushed to GitHub

**Estimated Time:** 1-2 hours
