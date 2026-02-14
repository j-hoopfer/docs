# Appendix: Terraform Organization Guide

## Overview

This appendix provides guidance on organizing Terraform infrastructure for brownfield migrations and enterprise environments, including layered state architecture, repository structure, and team workflows.

**Use this appendix when:**

- Deciding between monolithic vs layered Terraform
- Organizing Terraform for brownfield migrations
- Setting up team workflows for infrastructure changes
- Understanding centralized vs distributed Terraform patterns
- Planning state backend configuration

---

## Table of Contents

1. [Layered vs Monolithic Architecture](#layered-vs-monolithic-architecture)
2. [Repository Structure for Brownfield Migrations](#repository-structure-for-brownfield-migrations)
3. [Resource Placement Guide](#resource-placement-guide)
4. [Centralized vs Distributed Terraform](#centralized-vs-distributed-terraform)
5. [State Backend Configuration](#state-backend-configuration)

---

## Layered vs Monolithic Architecture

### Quick Decision Guide

**Choose Monolithic if:**

- Team < 3 people
- Resources < 20
- Single application
- Deploying weekly or less
- Learning Terraform

**Choose Layered if:**

- Team ≥ 4 people
- Resources ≥ 50
- Multiple applications/services
- Deploying daily
- **Brownfield migration (recommended for this project)**
- Production workloads
- Need team separation

### Layered Architecture (Recommended)

**Structure:**

```
terraform/environments/dev/
├── 00-network/           # Network layer (stable)
│   ├── main.tf
│   ├── outputs.tf
│   └── terraform.tfstate
└── 10-application/       # Application layer (frequent changes)
    ├── main.tf
    ├── data.tf           # References 00-network
    └── terraform.tfstate
```

**Benefits:**

- ✅ Reduced blast radius: Network changes isolated from apps
- ✅ Team autonomy: App team deploys without touching network
- ✅ Faster operations: `terraform plan` only checks relevant layer
- ✅ Parallel work: Multiple teams work simultaneously
- ✅ Safer refactoring: Can rebuild app layer without network risk

**When to Use:**

This is the **recommended approach for this migration** because:

1. You're importing existing VPC infrastructure (stable, rarely changes)
2. You'll be deploying new Fargate services frequently
3. Network team and app teams can work independently
4. Minimizes risk of breaking existing infrastructure

---

## Repository Structure for Brownfield Migrations

```
fargate-migration-infrastructure/
├── README.md
├── .gitignore
├── docs/
│   └── IMPORT_COMMANDS.md          # Record of all imported resources
└── terraform/
    ├── bootstrap/                   # S3 + DynamoDB for state (one-time)
    ├── modules/                     # Reusable modules
    │   ├── networking/
    │   ├── security/
    │   ├── compute/
    │   └── database/
    └── environments/
        ├── dev/
        │   ├── 00-network/
        │   └── 10-application/
        ├── staging/
        │   ├── 00-network/
        │   └── 10-application/
        └── production/
            ├── 00-network/
            └── 10-application/
```

---

## Resource Placement Guide

### Network Layer (`00-network`)

**What belongs here:**

- VPCs and CIDR blocks
- Subnets (public and private)
- Internet Gateways
- NAT Gateways and Elastic IPs
- Route Tables and associations
- VPC Endpoints (S3, ECR, CloudWatch Logs, Secrets Manager)
- Route53 Private Hosted Zones
- Route53 Public Hosted Zones

**Who manages:** Infrastructure/Platform team

**Change frequency:** Infrequent (weeks to months)

**Example outputs:**

```hcl
output "vpc_id" {
  value = aws_vpc.main.id
}

output "private_subnet_ids" {
  value = [
    aws_subnet.private_1a.id,
    aws_subnet.private_1b.id,
  ]
}
```

### Application Layer (`10-application`)

**What belongs here:**

- ECS clusters, services, task definitions
- Application Load Balancers, Target Groups, Listener Rules
- RDS instances, ElastiCache clusters
- Security Groups (all types)
- IAM Roles (task execution, task roles)
- Secrets Manager secrets
- CloudWatch Log Groups

**Who manages:** Application teams (with infrastructure team oversight)

**Change frequency:** Frequent (daily deployments)

**Example data source:**

```hcl
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "your-terraform-state-bucket"
    key    = "dev/00-network/terraform.tfstate"
    region = "us-east-1"
  }
}

resource "aws_ecs_service" "app" {
  network_configuration {
    subnets = data.terraform_remote_state.network.outputs.private_subnet_ids
  }
}
```

---

## Centralized vs Distributed Terraform

### Centralized Infrastructure Repository (Recommended for This Project)

**Structure:**

```
mycompany-infrastructure/          # Single repo
└── terraform/
    └── environments/
        └── production/
            ├── 00-network/
            └── 10-application/
                ├── auth-api.tf
                ├── billing-api.tf
                └── user-api.tf

mycompany-auth-api/                # Separate app repo
└── src/
    └── index.js                   # Just application code
```

**When to use:**

- ✅ Brownfield migrations (like this project)
- ✅ Dedicated platform/infrastructure team
- ✅ Centralized change control
- ✅ Small teams (1-5 infrastructure engineers)
- ✅ Shared infrastructure (same VPC, same RDS)

**Benefits:**

- Complete visibility and control for platform team
- Easier to enforce standards
- Single source of truth
- Easier to audit

### Distributed (Terraform in App Repos)

**Structure:**

```
mycompany-auth-api/                # App repo
├── src/
│   └── index.js
└── terraform/                     # Infrastructure for THIS service
    ├── main.tf
    └── ecs.tf
```

**When to use:**

- ✅ Cloud-native organizations
- ✅ Microservices with service-specific infrastructure
- ✅ "You build it, you run it" culture
- ✅ 10+ autonomous teams

**Recommendation for this migration:**

Start with **centralized** approach because:

1. You're importing existing resources (easier to manage centrally)
2. Shared VPC and RDS infrastructure
3. Allows infrastructure team to own the migration
4. Can move to distributed later if needed

---

## State Backend Configuration

### Bootstrap (One-Time Setup)

```hcl
# terraform/bootstrap/main.tf
resource "aws_s3_bucket" "terraform_state" {
  bucket = "mycompany-terraform-state"
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_dynamodb_table" "terraform_locks" {
  name         = "terraform-state-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
```

### Reference in Each Layer

```hcl
# 00-network/main.tf
terraform {
  backend "s3" {
    bucket         = "mycompany-terraform-state"
    key            = "dev/00-network/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
}

# 10-application/main.tf
terraform {
  backend "s3" {
    bucket         = "mycompany-terraform-state"
    key            = "dev/10-application/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
}
```

---

## Team Workflows

### Infrastructure Team

**Responsibilities:**

- Owns `00-network` layer
- Reviews/approves `10-application` changes
- Manages state backends
- Defines reusable modules

**Workflow:**

1. Provision network layer once
2. Export outputs for app teams
3. Only modify for capacity planning
4. Act as enabler, not blocker

### Application Teams

**Responsibilities:**

- Work in `10-application` layer
- Add new ECS services
- Deploy and scale applications

**Workflow:**

1. Reference network outputs via `terraform_remote_state`
2. Add resources via pull requests
3. Infrastructure team reviews
4. Deploy via CI/CD after approval

---

## Migration Checklist

- [ ] Bootstrap S3 and DynamoDB for state backend
- [ ] Create layered folder structure (`00-network`, `10-application`)
- [ ] Import existing VPC resources into `00-network`
- [ ] Import existing EC2/RDS into `10-application`
- [ ] Verify `terraform plan` shows zero changes
- [ ] Document all import commands in `IMPORT_COMMANDS.md`
- [ ] Set up CI/CD for `terraform plan` on PRs
- [ ] Define team ownership and approval workflows
- [ ] Train teams on `terraform_remote_state` pattern
- [ ] Establish naming conventions for resources
- [ ] Create reusable modules for common patterns

---

## Additional Resources

- [Terraform Best Practices](https://www.terraform-best-practices.com/)
- [AWS Provider Documentation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [Terraform State Management](https://developer.hashicorp.com/terraform/language/state)
- [Terraform Import Documentation](https://developer.hashicorp.com/terraform/cli/import)

---

## Related Documentation

- See main migration plan for detailed Terraform implementation in Phase 4
- See [aws-authentication-and-security.md](aws-authentication-and-security.md) for IAM policies for Terraform
