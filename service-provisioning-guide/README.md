# Service Provisioning Guide

This guide details the process for deploying a new service to an ECS cluster using Terraform.

## Prerequisites

- A functioning VPC and ECS Cluster (see `scale.infra-platform/environments/...`).
- A Docker image pushed to ECR or a public registry.
- Terraform installed.
- The `ecs-service` module initialized in `modules/ecs-service` (or similar).

## Directory Structure

We follow the standard "Tiered" directory structure where services typically start with `02-`:

`scale.infra-services/environments/<environment>/<region>/02-<service-name>/`

Example: `scale.infra-services/environments/prod/us-east-1/02-payment-service/`

## Step-by-Step Implementation

### 1. Create Directory

Create a directory for your service:

```bash
mkdir -p scale.infra-services/environments/<env>/<region>/02-<service-name>
cd scale.infra-services/environments/<env>/<region>/02-<service-name>
```

### 2. Configure Backend (`backend.tf`)

Point the backend to the service-specific path in the state bucket.

```hcl
terraform {
  backend "s3" {
    bucket         = "scale-solutions-terraform-state-<env>" # e.g., prod
    key            = "services/<env>/<region>/02-<service-name>/terraform.tfstate"
    region         = "<region>"
    encrypt        = true
    dynamodb_table = "terraform-locks-<env>"
  }
}
```

### 3. Configure Provider (`provider.tf`)

Ensure standard tags are applied to all service resources.

```hcl
provider "aws" {
  region = "<region>"

  default_tags {
    tags = {
      Environment = "<env>"
      Repository  = "infra-services"
      Service     = "<service-name>"
      ManagedBy   = "Terraform"
    }
  }
}
```

### 4. Define Service Resources (`main.tf`)

Call the `ecs-service` module to create the task definition and service.

> **Note:** Ensure your module at `../../modules/ecs-service` supports these inputs.

```hcl
module "service" {
  source = "../../../modules/ecs-service"

  service_name   = "<service-name>"
  container_image = "<ecr-repo-url>:<tag>"
  container_port = 8080
  cpu            = 256
  memory         = 512
  desired_count  = 2

  environment_variables = [
    { name = "DB_HOST", value = "db.example.com" },
    { name = "LOG_LEVEL", value = "info" }
  ]

  vpc_id          = "<vpc-id>" # Or reference remote state from network
  subnet_ids      = ["<subnet-1>", "<subnet-2>"]
  security_groups = ["<sg-id>"]
}
```

### 5. Deployment

1.  **Initialize:** `terraform init`
2.  **Review:** `terraform plan -out=tfplan`
3.  **Apply:** `terraform apply tfplan`

## Verification

After applying, verify:

1.  **ECS Service:** Status is `ACTIVE` and `RUNNING` tasks match desired count.
2.  **Task Definition:** Correct image URI and environment variables.
3.  **ALB Target Group:** Healthy targets registered (if load balanced).
4.  **Logs:** Check CloudWatch Logs for application startup.
