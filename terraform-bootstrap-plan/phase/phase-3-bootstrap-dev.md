# Terraform Bootstrap - Phase 3: Bootstrap Dev Account

## Prerequisites

**Required Access:**

- AWS Dev account admin/PowerUser access
- AWS SSO configured for Dev account (see Phase 0)
- Write access to bootstrap repository

**Required Tools:**

- Terraform >= 1.7.0 installed locally
- AWS CLI v2 installed and configured
- `jq` (for optional JSON parsing)
- Git CLI
- Text editor

**Required Credentials:**

- AWS SSO profile configured: `mycompany-dev`
- Ability to run `aws sso login --profile mycompany-dev`
- Verified with `aws sts get-caller-identity`

**Required Information:**

- Dev AWS account ID (12-digit number)
- Primary region (e.g., `us-east-1`)

**Previous Phase:** [Phase 2 - Create Terraform Module](phase-2-terraform-module.md) must be completed

---

## Overview

**Now that the repository structure and module exist**, deploy Terraform state infrastructure (S3 + DynamoDB) to the Dev AWS account. This phase creates the foundation for remote state management in your development environment.

**Important Regional Notes:**

- This bootstrap process runs **once per account**
- Run it in your **primary region** (typically `us-east-1`)
- The S3 bucket will be created in the region specified in your provider configuration
- All Terraform projects across all regions in this account will use this bucket
- State files will be organized by key paths: `global/`, `us-east-1/`, `us-west-2/`, etc.

**Duration:** 30-60 minutes

**Who Should Complete This:** Platform engineers with admin access to Dev AWS account

---

## Feature 3: Bootstrap Dev Account

### Story 3.1: Create Dev Account Configuration Files

- **Title:** Configure Terraform for Dev Account Bootstrap
- **Persona:** As a **Platform Engineer**, I need account-specific Terraform files for the Dev environment so that I can create state infrastructure in the Dev AWS account.

- **Requirements:**
  - `main.tf` calls state backend module
  - `variables.tf` defines Dev-specific variables
  - `providers.tf` configures AWS provider (no backend yet)
  - `outputs.tf` displays backend configuration
  - `terraform.tfvars.example` provides template

- **Implementation Details:**

```bash
touch accounts/dev/main.tf
touch accounts/dev/variables.tf
touch accounts/dev/providers.tf
touch accounts/dev/outputs.tf
touch accounts/dev/terraform.tfvars.example
```

#### 1) Create `accounts/dev/variables.tf`

```hcl
variable "aws_account_id" {
  description = "AWS Account ID for Dev environment"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "AWS Account ID must be exactly 12 digits."
  }
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "primary_region" {
  description = "Primary AWS region for state storage"
  type        = string
  default     = "us-east-1"
}
```

#### 2) Create `accounts/dev/main.tf`

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

#### 3) Create `accounts/dev/providers.tf`

```hcl
terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # NOTE: No backend configured - uses local state for bootstrap
  # After creation, you can optionally migrate this to use the remote backend
}

provider "aws" {
  region = var.primary_region

  # Uncomment if using AWS SSO profile
  # profile = "mycompany-dev"
}
```

#### 4) Create `accounts/dev/outputs.tf`

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

#### 5) Create `accounts/dev/terraform.tfvars.example`

```hcl
# Copy this to terraform.tfvars and update with actual values

aws_account_id = "123456789012"  # Replace with Dev account ID
environment    = "dev"
primary_region = "us-east-1"
```

- **Acceptance Criteria:**
  - ✅ `accounts/dev/main.tf` calls terraform-state-backend module
  - ✅ `accounts/dev/variables.tf` includes validation for account ID
  - ✅ `accounts/dev/providers.tf` has NO backend block
  - ✅ `accounts/dev/outputs.tf` displays backend configuration
  - ✅ `accounts/dev/terraform.tfvars.example` exists (not ignored by Git)

---

### Story 3.2: Commit Dev Configuration

- **Title:** Version Control Dev Account Configuration
- **Persona:** As a **Platform Engineer**, I need to commit the Dev account configuration to Git so that the configuration is version-controlled before infrastructure deployment.

- **Requirements:**
  - Dev configuration files staged for commit
  - Descriptive commit message
  - Changes pushed to remote repository

- **Implementation Details:**

  #### 1) Stage and Commit

  ```bash
  # Stage the new files
  git add accounts/dev/

  # Commit to version control
  git commit -m "Add Dev account Terraform configuration for state backend bootstrap"

  # Push to remote
  git push origin main
  ```

- **Acceptance Criteria:**
  - ✅ Dev configuration files committed to Git
  - ✅ Changes pushed to GitHub

---

### Story 3.3: Initialize and Apply Dev Bootstrap

- **Title:** Deploy Terraform State Infrastructure in Dev Account
- **Persona:** As a **Platform Engineer**, I need to run Terraform to create the S3 bucket and DynamoDB table so that the Dev account has state infrastructure ready.

- **Requirements:**
  - AWS credentials configured for Dev account
  - `terraform.tfvars` created from example
  - Terraform initialized with local backend
  - Resources created successfully
  - Backend configuration output captured

- **Implementation Details:**

  #### 1) Configure AWS Credentials

  ```bash
  # Option A: AWS SSO
  aws sso login --profile mycompany-dev
  export AWS_PROFILE=mycompany-dev

  # Option B: Set profile in providers.tf
  # Uncomment the profile line in providers.tf

  # Verify credentials
  aws sts get-caller-identity
  # Should show Dev account ID
  ```

  #### 2) Create `terraform.tfvars`

  ```bash
  cd accounts/dev
  cp terraform.tfvars.example terraform.tfvars
  vim terraform.tfvars
  ```

  **Update with actual Dev account ID:**

  ```hcl
  aws_account_id = "123456789012"  # Your actual Dev account ID
  environment    = "dev"
  primary_region = "us-east-1"
  ```

  #### 3) Initialize Terraform

  NOTE: make sure you're in account/dev

  ```bash
  terraform init
  ```

  **Expected output:**

  ```
  Initializing modules...
  - terraform_backend in ../../modules/terraform-state-backend

  Initializing the backend...

  Initializing provider plugins...
  - Finding hashicorp/aws versions matching "~> 5.0"...
  - Installing hashicorp/aws v5.x.x...

  Terraform has been successfully initialized!
  ```

  #### 4) Review Plan

  ```bash
  terraform plan
  ```

  **Should show:**
  - `+` Create `aws_s3_bucket.terraform_state`
  - `+` Create `aws_s3_bucket_versioning.terraform_state`
  - `+` Create `aws_s3_bucket_server_side_encryption_configuration.terraform_state`
  - `+` Create `aws_s3_bucket_public_access_block.terraform_state`
  - `+` Create `aws_s3_bucket_lifecycle_configuration.terraform_state`
  - `+` Create `aws_dynamodb_table.terraform_locks`
  - `+` Create `aws_iam_policy.terraform_state_access`

  **Total: 7 resources to create**

  #### 5) Apply Configuration

  ```bash
  terraform apply
  ```

  Type `yes` when prompted.

  **Expected output:**

  ```
  module.terraform_backend.aws_s3_bucket.terraform_state: Creating...
  module.terraform_backend.aws_dynamodb_table.terraform_locks: Creating...
  ...
  Apply complete! Resources: 7 added, 0 changed, 0 destroyed.

  Outputs:

  backend_configuration = <<EOT
  # Add this to your Terraform configuration:

  terraform {
    backend "s3" {
      bucket         = "mycompany-terraform-state-dev"
      key            = "{region}/{layer}/terraform.tfstate"
      region         = "us-east-1"
      encrypt        = true
      dynamodb_table = "mycompany-terraform-locks"
    }
  }
  EOT
  iam_policy_arn = "arn:aws:iam::123456789012:policy/terraform-state-access-dev"
  lock_table = "mycompany-terraform-locks"
  state_bucket = "mycompany-terraform-state-dev"
  ```

  #### 6) Capture Backend Configuration

  ```bash
  terraform output backend_configuration > ../../BACKEND_CONFIG_DEV.txt
  ```

  #### 7) Verify Resources in AWS Console

  **S3 Bucket:**
  - Navigate to S3 → Buckets
  - Find `{company}-terraform-state-dev`
  - Properties → Versioning: **Enabled**
  - Properties → Encryption: **Enabled (AES-256)**

  **DynamoDB Table:**
  - Navigate to DynamoDB → Tables
  - Find `{company}-terraform-locks`
  - Billing mode: **On-demand**
  - Partition key: **LockID (String)**

- **Technical Requirements:**
  - AWS CLI configured with admin access to Dev account
  - Terraform 1.7.0+
  - Internet connectivity for provider downloads

- **Acceptance Criteria:**
  - ✅ `terraform apply` completes without errors
  - ✅ S3 bucket `{company}-terraform-state-dev` exists
  - ✅ Bucket has versioning enabled
  - ✅ Bucket has encryption enabled
  - ✅ DynamoDB table `{company}-terraform-locks` exists with `LockID` key
  - ✅ IAM policy created for state access
  - ✅ Backend configuration output saved

---

### Story 3.4: Validate Backend with Test Project

- **Title:** Test Remote Backend with Sample Terraform Project
- **Persona:** As a **Platform Engineer**, I need to verify the state backend works correctly so that I can confidently deploy real infrastructure using it.

- **Requirements:**
  - Create test Terraform project
  - Configure backend to use new S3 bucket
  - Deploy test resource
  - Verify state stored in S3
  - Verify DynamoDB lock created during apply
  - Clean up test resources

- **Implementation Details:**

  #### 1) Create Test Directory and Set Credentials

  ```bash
  mkdir -p ~/test-terraform-backend
  cd ~/test-terraform-backend

  # Ensure AWS credentials are set
  export AWS_PROFILE=mycompany-dev
  aws sts get-caller-identity  # Verify correct account
  ```

  #### 2) Create Test Configuration

  ```hcl
  # main.tf
  terraform {
    backend "s3" {
      bucket         = "mycompany-terraform-state-dev"
      key            = "test/vpc/terraform.tfstate"
      region         = "us-east-1"
      encrypt        = true
      dynamodb_table = "terraform-locks-dev"  # Use actual table name from bootstrap
      use_lockfile   = true
    }

    required_providers {
      aws = {
        source  = "hashicorp/aws"
        version = "~> 5.0"
      }
    }
  }

  provider "aws" {
    region = "us-east-1"
  }

  resource "aws_vpc" "test" {
    cidr_block = "10.99.0.0/16"

    tags = {
      Name = "test-backend-vpc"
    }
  }

  output "vpc_id" {
    value = aws_vpc.test.id
  }
  ```

  #### 3) Initialize with Remote Backend

  ```bash
  terraform init
  ```

  **Expected output:**

  ```
  Initializing the backend...

  Successfully configured the backend "s3"! Terraform will automatically
  use this backend unless the backend configuration changes.

  Initializing provider plugins...
  ...
  Terraform has been successfully initialized!
  ```

  #### 4) Apply Test Resource

  ```bash
  terraform apply -auto-approve
  ```

  **Expected output:**

  ```
  aws_vpc.test: Creating...
  aws_vpc.test: Creation complete after 3s [id=vpc-0abc123]

  Apply complete! Resources: 1 added, 0 changed, 0 destroyed.

  Outputs:

  vpc_id = "vpc-0abc123"
  ```

  #### 5) Verify State in S3

  ```bash
  aws s3 ls s3://mycompany-terraform-state-dev/test/vpc/
  # Should show: terraform.tfstate

  # Download and inspect (optional)
  aws s3 cp s3://mycompany-terraform-state-dev/test/vpc/terraform.tfstate /tmp/state.json
  cat /tmp/state.json | jq '.resources[] | select(.type=="aws_vpc")'
  ```

  #### 6) Verify DynamoDB Lock Behavior

  **Option A: Using terraform console (recommended)**

  ```bash
  # In Terminal 1, open terraform console (this acquires and holds a lock)
  terraform console
  # Leave this running (you'll see a > prompt)
  ```

  ```bash
  # In Terminal 2, try to run a plan (should fail with lock error)
  terraform plan
  ```

  **Expected error:**

  ```
  Error: Error acquiring the state lock

  Error message: ConditionalCheckFailedException: The conditional request failed
  Lock Info:
    ID:        abc-123-xyz
    Path:      mycompany-terraform-state-dev/test/vpc/terraform.tfstate
    Operation: OperationTypeApply
    Who:       your-username@your-hostname
    Created:   2026-02-14 12:34:56.789 UTC

  Terraform acquires a state lock to protect the state from being written
  by multiple users at the same time. Please resolve the issue above and try
  again. For most commands, you can disable locking with the "-lock=false"
  flag, but this is not recommended.
  ```

  **After verifying:** Type `exit` in Terminal 1 to close terraform console and release the lock.

  **Option B: Check DynamoDB table directly**

  ```bash
  # While terraform console is running in Terminal 1, check DynamoDB
  aws dynamodb scan \
    --table-name mycompany-terraform-locks \
    --profile mycompany-dev

  # Should show a lock item with LockID matching your state path
  ```

  **Expected output:**

  ```json
  {
    "Items": [
      {
        "LockID": {
          "S": "mycompany-terraform-state-dev/test/vpc/terraform.tfstate-md5"
        },
        "Info": {
          "S": "{...lock information...}"
        }
      }
    ],
    "Count": 1
  }
  ```

  After exiting terraform console, run the scan again - the table should be empty.

  #### 7) Clean Up Test Resources

  ```bash
  terraform destroy -auto-approve

  # Delete state file from S3
  aws s3 rm s3://mycompany-terraform-state-dev/test/vpc/terraform.tfstate

  # Remove test directory
  cd ~
  rm -rf test-terraform-backend
  ```

- **Acceptance Criteria:**
  - ✅ Test project initializes with S3 backend
  - ✅ `terraform apply` creates VPC
  - ✅ State file appears in S3 at `test/vpc/terraform.tfstate`
  - ✅ Concurrent operations trigger lock error
  - ✅ `terraform destroy` cleans up resources
  - ✅ State backend proven to work correctly

---

## Phase 3 Checklist

Complete this checklist before proceeding to Phase 4:

- [ ] Dev account configuration files created (`main.tf`, `providers.tf`, etc.)
- [ ] Dev configuration committed and pushed to Git
- [ ] `terraform.tfvars` created with actual Dev account ID
- [ ] Terraform initialized without errors
- [ ] `terraform apply` succeeded and created S3 bucket + DynamoDB table
- [ ] S3 bucket visible in AWS Console
- [ ] DynamoDB table visible in AWS Console
- [ ] Test project successfully uses remote state with locking

---

**Previous Phase:** [Phase 2 - Create Terraform Module](phase-2-terraform-module.md)  
**Next Phase:** [Phase 4 - Bootstrap CI/CD](phase-4-bootstrap-cicd.md)

**Estimated Time:** 30-60 minutes
