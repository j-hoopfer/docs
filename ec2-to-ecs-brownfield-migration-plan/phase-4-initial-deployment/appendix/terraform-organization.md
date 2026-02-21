# Enterprise Terraform Organization & Repository Structure

## Overview

A robust Terraform structure is critical for scaling beyond a single application. We recommend a multi-repo strategy to separate concerns and limit blast radius.

---

## 1. Repository Strategy

| Repo Type               | Content                                            | Responsibility | Frequency of Change      |
| :---------------------- | :------------------------------------------------- | :------------- | :----------------------- |
| **Modules Repo**        | Reusable Terraform modules (vpc, ecs-service, rds) | Platform Team  | Low (Versioning is key)  |
| **Infrastructure Repo** | Shared resources (VPC, ECS Cluster, ALB, ECR)      | Platform Team  | Medium                   |
| **Application Repo**    | Application code + `service.tf` (Task Definition)  | App Team       | High (Daily deployments) |

---

## 2. Directory Structure (Infrastructure Repo)

```
infrastructure/
├── modules/ (local modules or submodules)
├── environments/
│   ├── dev/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── terraform.tfvars
│   ├── staging/
│   └── prod/
└── global/ (IAM, S3 for state, ECR repos)
    ├── main.tf
    └── ecr.tf
```

**Key Principle:** Separate state files for each environment (dev/stage/prod) and distinct layers (networking vs apps).

---

## 3. Remote State Management

**Backend Configuration:**
Use S3 + DynamoDB for state locking.

```hcl
# backend.tf
terraform {
  backend "s3" {
    bucket         = "my-company-terraform-state"
    key            = "infrastructure/prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-lock"
    encrypt        = true
  }
}
```

**Workspace vs Directory:**
We recommend **Directory separation** (dev/stage/prod folders) over Terraform Workspaces for better clarity and variable management.

### State Organization: Per-Layer vs Single State

There are two valid approaches to organizing state files within an environment:

#### Option A: Per-Layer State Files (Granular Isolation)

```
environments/prod/us-east-1/
├── 00-network/
│   ├── backend.tf    # Separate state file
│   ├── vpc.tf
├── 01-compute/
│   ├── backend.tf    # Separate state file
│   └── ecs.tf
```

**Tradeoffs:**

- ✅ Granular blast radius (network changes don't affect compute state)
- ✅ Layers can be modified independently
- ✅ Better for large teams (lock only what you're changing)
- ⚠️ More state files to manage
- ⚠️ Need data sources to reference outputs between layers

#### Option B: Single State Per Environment (Unified Simplicity)

```
environments/prod/us-east-1/
├── backend.tf       # Single state for all layers
├── provider.tf
├── 00-network/
│   └── vpc.tf       # Just resources
├── 01-compute/
│   └── ecs.tf       # Just resources
```

**Tradeoffs:**

- ✅ Simpler - one state file per environment
- ✅ Easier cross-layer references (no data sources needed)
- ✅ Fewer backend.tf files to maintain
- ⚠️ Everything locks together (can't modify layers independently)
- ⚠️ Larger blast radius

**Recommendation:**

- **Small teams (< 5)** or **Dev environments**: Use single state (Option B)
- **Large teams** or **Production**: Use per-layer state (Option A)
- See [Backend.tf Best Practices](../../phase-0-prerequisites/appendix/backend-tf-best-practices.md#state-organization-strategies) for detailed comparison

---

## 4. Module Versioning

Always pin module versions in your `main.tf`:

```hcl
module "ecs_cluster" {
  source  = "git::https://github.com/my-org/terraform-modules.git//ecs-cluster?ref=v1.2.0"

  cluster_name = "production-cluster"
  # ...
}
```

**Why?**

- Prevents breaking changes from automatically propagating.
- Allows `dev` to test `v1.3.0` while `prod` stays on `v1.2.0`.
- Immutability for audits.

---

## 5. Application Repo Integration

The application repo should include a `terraform/` directory if the app owns its infrastructure (e.g., specific SQS queues or weird IAM roles), OR it should rely on the central pipelines.

**Pattern A: App owns nothing (Pure GitOps)**

- App repo only contains code + Dockerfile.
- Infra repo defines `ecs_service` pointing to the image tag.
- CI updates Infra repo with new tag.

**Pattern B: App owns Service (Preferred for autonomy)**

- App repo contains `terraform/service.tf`.
- CI runs `terraform apply` on app repo deployment.
- Reads `remote_state` from Infrastructure repo (VPC ID, Cluster ID).

```hcl
# app-repo/terraform/main.tf
data "terraform_remote_state" "infra" {
  backend = "s3"
  config = {
    bucket = "my-company-terraform-state"
    key    = "infrastructure/prod/terraform.tfstate"
    region = "us-east-1"
  }
}

module "service" {
  source          = "../../modules/ecs-service"
  cluster_id      = data.terraform_remote_state.infra.outputs.ecs_cluster_id
  vpc_id          = data.terraform_remote_state.infra.outputs.vpc_id
  # ...
}
```
