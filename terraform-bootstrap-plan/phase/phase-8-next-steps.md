# Phase 8: What's Next After Bootstrap

## Prerequisites

**Completed Phases:**

- All previous phases (0-7) should be completed
- Or at minimum: Phases 1, 2, 3, and 5 (core bootstrap)

**No Additional Tools Required** - This is a guidance document

**Helpful to Have:**

- Access to AWS Console (to review created resources)
- Access to your bootstrap repository (to reference configurations)
- Backend configuration files (`BACKEND_CONFIG_DEV.txt`, `BACKEND_CONFIG_PROD.txt`)

---

## Overview

**With your Terraform state backend infrastructure deployed**, you're now ready to build actual platform and application infrastructure. This guide explains the recommended project structure and next steps.

**Key Principle:** The bootstrap project is **special** - it creates the foundation for state management but is not where you build your actual infrastructure.

---

## Understanding Your Infrastructure Landscape

### What You Just Created (Bootstrap Project)

```
mycompany.infra-terraform-bootstrap/
├── modules/terraform-state-backend/   # Reusable module
└── accounts/
    ├── dev/                           # Dev state backend (S3 + DynamoDB)
    └── prod/                          # Prod state backend (S3 + DynamoDB)
```

**Purpose:**

- Creates S3 buckets and DynamoDB tables for state storage
- Runs **once per account** during initial setup
- Rarely changes after initial deployment

**Where state is stored:**

- Bootstrap itself uses **local state** (terraform.tfstate committed to Git)
- All other projects use the **remote state** (S3 + DynamoDB) you just created

---

## Recommended Project Structure

### Separate Repositories by Concern

```
Organization: mycompany
├── mycompany.infra-terraform-bootstrap    # ✅ You are here
├── mycompany.infra-terraform-platform     # ⬅️ Create this next
├── mycompany.infra-terraform-applications # ⬅️ Then this
└── mycompany-app-xyz                      # Application code
```

---

## Project 1: Platform Infrastructure (Core Shared Resources)

**Repository:** `mycompany.infra-terraform-platform`

**Purpose:** Shared infrastructure used by multiple applications/teams

### Recommended Directory Structure

```
mycompany.infra-terraform-platform/
├── global/                              # Global (region-independent) resources
│   ├── iam/
│   │   ├── main.tf                      # IAM roles, policies, groups
│   │   ├── backend.tf                   # Points to: s3://mycompany-terraform-state-dev/global/iam/
│   │   └── terraform.tfvars
│   ├── route53/
│   │   ├── main.tf                      # DNS zones (mycompany.com)
│   │   ├── backend.tf                   # Points to: s3://mycompany-terraform-state-dev/global/route53/
│   │   └── terraform.tfvars
│   └── cloudfront/                      # CDN distributions (if needed)
│       ├── main.tf
│       └── backend.tf
├── regional/
│   ├── us-east-1/                       # Primary region
│   │   ├── vpc/
│   │   │   ├── main.tf                  # VPC, subnets, NAT gateways
│   │   │   ├── backend.tf               # Points to: s3://mycompany-terraform-state-dev/us-east-1/vpc/
│   │   │   └── terraform.tfvars
│   │   ├── eks/                         # Kubernetes cluster (if using EKS)
│   │   │   ├── main.tf
│   │   │   ├── backend.tf               # Points to: s3://mycompany-terraform-state-dev/us-east-1/eks/
│   │   │   └── terraform.tfvars
│   │   ├── monitoring/                  # CloudWatch dashboards, alarms
│   │   │   ├── main.tf
│   │   │   └── backend.tf
│   │   └── security/                    # Security groups, NACLs
│   │       ├── main.tf
│   │       └── backend.tf
│   └── us-west-2/                       # Secondary region (disaster recovery)
│       ├── vpc/
│       │   ├── main.tf
│       │   ├── backend.tf               # Points to: s3://mycompany-terraform-state-dev/us-west-2/vpc/
│       │   └── terraform.tfvars
│       └── monitoring/
└── modules/                             # Shared platform modules
    ├── vpc/
    ├── eks-cluster/
    └── monitoring-baseline/
```

### State Key Convention

Each subdirectory has its own state file:

```
s3://mycompany-terraform-state-dev/
├── global/
│   ├── iam/terraform.tfstate
│   ├── route53/terraform.tfstate
│   └── cloudfront/terraform.tfstate
├── us-east-1/
│   ├── vpc/terraform.tfstate
│   ├── eks/terraform.tfstate
│   ├── monitoring/terraform.tfstate
│   └── security/terraform.tfstate
└── us-west-2/
    ├── vpc/terraform.tfstate
    └── monitoring/terraform.tfstate
```

### Example Backend Configuration

**For global resources** (e.g., `global/iam/backend.tf`):

```hcl
terraform {
  backend "s3" {
    bucket         = "mycompany-terraform-state-dev"
    key            = "global/iam/terraform.tfstate"        # ⬅️ Global path
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "mycompany-terraform-locks"
  }
}
```

**For regional resources** (e.g., `regional/us-east-1/vpc/backend.tf`):

```hcl
terraform {
  backend "s3" {
    bucket         = "mycompany-terraform-state-dev"
    key            = "us-east-1/vpc/terraform.tfstate"    # ⬅️ Regional path
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "mycompany-terraform-locks"
  }
}
```

---

## Project 2: Application Infrastructure

**Repository:** `mycompany.infra-terraform-applications`

**Purpose:** Application-specific infrastructure (load balancers, databases, ECS services, etc.)

### Recommended Directory Structure

```
mycompany.infra-terraform-applications/
├── app-web-frontend/
│   ├── us-east-1/
│   │   ├── main.tf                      # ALB, ECS service, RDS
│   │   ├── backend.tf                   # Points to: s3://mycompany-terraform-state-dev/apps/web-frontend/us-east-1/
│   │   └── terraform.tfvars
│   └── us-west-2/                       # Multi-region deployment
│       ├── main.tf
│       └── backend.tf
├── app-api-backend/
│   ├── us-east-1/
│   │   ├── main.tf                      # API Gateway, Lambda, DynamoDB
│   │   ├── backend.tf                   # Points to: s3://mycompany-terraform-state-dev/apps/api-backend/us-east-1/
│   │   └── terraform.tfvars
│   └── modules/
│       └── lambda-function/
└── shared-modules/                      # Application-specific modules
    ├── alb-ecs-service/
    └── rds-postgresql/
```

### State Key Convention

```
s3://mycompany-terraform-state-dev/
└── apps/
    ├── web-frontend/
    │   ├── us-east-1/terraform.tfstate
    │   └── us-west-2/terraform.tfstate
    └── api-backend/
        └── us-east-1/terraform.tfstate
```

---

## Regional vs Global Resources: Decision Guide

### Global Resources (Use `global/` directory)

Resources that are **region-independent** or managed from one region:

- **IAM**: Roles, policies, users, groups
- **Route53**: DNS zones and records
- **CloudFront**: CDN distributions
- **S3**: Buckets with global DNS (though they exist in one region)
- **AWS Identity Center**: SSO configuration (Management account only)
- **AWS Organizations**: Account structure (Management account only)

**Why global?**

- These resources don't have a region in their ARN or are accessible from all regions
- Prevents confusion about which region "owns" them
- Simplifies cross-region references

### Regional Resources (Use `us-east-1/`, `us-west-2/`, etc.)

Resources that exist **within a specific region**:

- **VPC**: Virtual networks and subnets
- **EC2**: Instances, AMIs, security groups
- **RDS**: Databases
- **ECS/EKS**: Container orchestration
- **Lambda**: Functions (deployed per-region)
- **ALB/NLB**: Load balancers
- **ElastiCache**: Redis/Memcached clusters

**Why regional?**

- These resources are tied to a specific AWS region
- Each region needs its own instance of these resources
- Enables multi-region deployments

---

## AWS Identity Center Management

### Recommended Approach: Manual Configuration

**AWS Identity Center (formerly AWS SSO) should be configured manually**, not with Terraform:

**Why manual?**

- Identity Center lives in the **Management Account** (not Dev/Prod)
- It's an organization-wide service that controls access to all accounts
- Configuration changes are infrequent
- Manual changes via AWS Console provide better visibility and audit trail

**What to configure manually:**

1. **Identity Source**: Connect to Azure AD, Okta, Google Workspace, or use AWS's directory
2. **Permission Sets**: Create roles like `AdministratorAccess`, `DeveloperAccess`, `ReadOnlyAccess`
3. **Account Assignments**: Grant users/groups access to specific accounts with specific permission sets

### Optional: Terraform for Permission Sets

If you have **many permission sets** or **frequent changes**, you can use Terraform to manage them:

```
mycompany.infra-terraform-platform/
└── global/
    └── identity-center/
        ├── main.tf                      # aws_ssoadmin_permission_set resources
        ├── backend.tf
        └── terraform.tfvars
```

**Example:**

```hcl
resource "aws_ssoadmin_permission_set" "developer_access" {
  name             = "DeveloperAccess"
  description      = "Allows developers to manage resources in Dev account"
  instance_arn     = data.aws_ssoadmin_instances.main.arns[0]
  session_duration = "PT8H"  # 8 hours
}

resource "aws_ssoadmin_managed_policy_attachment" "developer_policies" {
  instance_arn       = data.aws_ssoadmin_instances.main.arns[0]
  permission_set_arn = aws_ssoadmin_permission_set.developer_access.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}
```

**Important:** This Terraform code runs in the **Management Account**, not Dev/Prod.

---

## How Bootstrap Infrastructure Is Used

### One Bootstrap Per Account

The bootstrap project creates **one S3 bucket** and **one DynamoDB table per account**:

- **Dev Account**: `mycompany-terraform-state-dev` (in `us-east-1`)
- **Prod Account**: `mycompany-terraform-state-prod` (in `us-east-1`)

### All Regions Use the Same State Bucket

You **do not** create separate buckets per region. All regions in an account use the same S3 bucket:

```
# ✅ CORRECT: One bucket per account
s3://mycompany-terraform-state-dev/
├── global/...
├── us-east-1/...
└── us-west-2/...

# ❌ WRONG: Don't create separate buckets per region
s3://mycompany-terraform-state-dev-us-east-1/
s3://mycompany-terraform-state-dev-us-west-2/
```

**Why one bucket?**

- Simpler management (fewer buckets to monitor)
- Easier cross-region state references
- S3 buckets are globally accessible from any region

### Where to Create the State Bucket

The S3 bucket should be created in your **primary region** (typically `us-east-1`):

- This is the region where the bucket physically resides
- Terraform in **all regions** can access it
- DynamoDB table is also in the primary region

**Example:** Running bootstrap in Dev account creates:

- S3 bucket: `mycompany-terraform-state-dev` (in `us-east-1`)
- DynamoDB table: `mycompany-terraform-locks` (in `us-east-1`)

Infrastructure in `us-west-2` still uses these resources (cross-region access is fine).

---

## Checklist: Starting Your Platform Project

### Step 1: Create Platform Repository

```bash
gh repo create mycompany/mycompany.infra-terraform-platform \
  --private \
  --description "Shared platform infrastructure (VPC, IAM, monitoring)"

git clone git@github.com:mycompany/mycompany.infra-terraform-platform.git
cd mycompany.infra-terraform-platform
```

### Step 2: Create Directory Structure

```bash
mkdir -p global/{iam,route53}
mkdir -p regional/us-east-1/{vpc,monitoring,security}
mkdir -p modules
```

### Step 3: Start with Global IAM

**Create `global/iam/backend.tf`:**

```hcl
terraform {
  backend "s3" {
    bucket         = "mycompany-terraform-state-dev"
    key            = "global/iam/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "mycompany-terraform-locks"
  }
}
```

**Create `global/iam/providers.tf`:**

```hcl
terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"  # IAM is global, but provider needs a region

  default_tags {
    tags = {
      ManagedBy   = "Terraform"
      Repository  = "mycompany.infra-terraform-platform"
      Project     = "IAM"
      Environment = "dev"
    }
  }
}
```

**Create `global/iam/main.tf`:**

```hcl
# Example: ECS task execution role
resource "aws_iam_role" "ecs_task_execution" {
  name = "mycompany-ecs-task-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
```

**Deploy:**

```bash
cd global/iam
terraform init   # Connects to your bootstrap-created S3 bucket!
terraform plan
terraform apply
```

### Step 4: Create VPC in Primary Region

**Create `regional/us-east-1/vpc/backend.tf`:**

```hcl
terraform {
  backend "s3" {
    bucket         = "mycompany-terraform-state-dev"
    key            = "us-east-1/vpc/terraform.tfstate"  # ⬅️ Regional path
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "mycompany-terraform-locks"
  }
}
```

**Create `regional/us-east-1/vpc/main.tf`:**

```hcl
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "mycompany-dev-vpc"
  }
}

resource "aws_subnet" "private" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 1}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "mycompany-dev-private-${count.index + 1}"
  }
}
```

### Step 5: Reference Outputs Across Projects

Use `terraform_remote_state` data source to reference outputs:

**In your ECS application project:**

```hcl
data "terraform_remote_state" "vpc" {
  backend = "s3"
  config = {
    bucket = "mycompany-terraform-state-dev"
    key    = "us-east-1/vpc/terraform.tfstate"
    region = "us-east-1"
  }
}

resource "aws_ecs_service" "app" {
  # ...
  network_configuration {
    subnets = data.terraform_remote_state.vpc.outputs.private_subnet_ids
  }
}
```

---

## Common Questions

### Q: Do I need to bootstrap each region?

**No.** Bootstrap runs **once per account** in the primary region (`us-east-1`). All other regions use the same S3 bucket via cross-region access.

### Q: Should platform and application infrastructure be in the same repository?

**Recommendation: Separate repositories.**

- **Platform**: Changes infrequently, managed by platform team, affects all apps
- **Applications**: Changes frequently, managed by app teams, isolated blast radius

This allows different teams to own their domains without blocking each other.

### Q: What if I only have one region?

Still use the regional directory structure:

```
mycompany.infra-terraform-platform/
├── global/
│   └── iam/
└── regional/
    └── us-east-1/
        ├── vpc/
        └── monitoring/
```

This makes it easier to expand to multiple regions later without refactoring.

### Q: Can I manage Identity Center with Terraform?

**Yes, but it's complex.** Consider:

- **Manual setup** (recommended for most teams): Simpler, better visibility
- **Terraform** (for large teams): Use `aws_ssoadmin_*` resources in Management Account

If using Terraform, create a separate project:

```
mycompany.infra-terraform-organization/
└── identity-center/
    ├── permission-sets.tf
    └── account-assignments.tf
```

This runs in the **Management Account**, not Dev/Prod.

---

## Summary

**You've completed the bootstrap!** Now you have:

✅ S3 buckets for state storage (one per account)  
✅ DynamoDB tables for state locking  
✅ IAM policies for state access

**Next steps:**

1. Create `mycompany.infra-terraform-platform` repository
2. Set up global resources (IAM, Route53)
3. Set up regional resources (VPC, monitoring)
4. Create `mycompany.infra-terraform-applications` repository for app-specific infrastructure
5. Reference platform outputs in application projects

**Key principle:** Every Terraform project directory has its own `backend.tf` pointing to a unique state file path in your bootstrap-created S3 bucket.
