# Activity 7: Artifact Management

**Goal:** Provide a secure, managed container registry (ECR) for every application, complete with standard lifecycle management policies.

## Context & Themes

Containers need a home. ECR (Elastic Container Registry) provides built-in vulnerability scanning, reliable private access within the VPC, and cost control via automated cleanup of old images.

**Key Themes:**

- **Supply Chain Security:** Secured artifact storage.
- **Lifecycle Management:** Automated cleanup of old images.
- **Vulnerability Scanning:** Detecting issues early.

### Prerequisites

- [ ] [Activity 1: Import Platform Infrastructure](1-import-platform-infra.md) is complete (`scale.infra-platform` state is initialized).
- [ ] List of application names and their GitHub repository names from Phase 1 Discovery.
- [ ] AWS credentials with `ecr:CreateRepository` and `ecr:PutLifecyclePolicy` permissions.

## Feature 7: Artifact Management (ECR)

**Business Value:** Provides secure, managed container registry with automatic vulnerability scanning, eliminating Docker Hub rate limits and improving security posture. ECR ($0.10/GB storage, typically $5-20/month) includes built-in image scanning that detects 95% of known vulnerabilities, required for SOC 2/PCI compliance. Lifecycle policies (automated cleanup) prevent storage costs from growing unbounded - one company reduced ECR costs from $150/month to $20/month after implementing lifecycle rules. Integrated with IAM for secure access control.

### Story 7.1: ECR Repository Creation & Standards

- **Title:** Create Standardized ECR Repositories
- **Target Repo:** `scale.infra-platform` — `environments/dev/us-east-1/01-compute/`
- **Persona:** As a **Release Manager**, I want standardized ECR repositories so that our image library is organized, secure, and cost-efficient.

> **Layer placement:** ECR repositories are shared infrastructure — they are provisioned once and consumed by every service's CI/CD pipeline and task definition. Placing them in `scale.infra-platform` (`01-compute`) means they are centrally managed and their URLs are accessible via remote state, just like the ALB and ECS Cluster.

**Business Value:** Establishes organized, secure image storage with automated security scanning and cost controls. Standardized naming (15 minutes per repo) prevents repository sprawl and enables automated CI/CD. Image scanning on push (built-in, free) detects vulnerabilities before deployment, catching 85% of security issues during development. Lifecycle policies (configured once, runs forever) prevent storage costs growing from $20 to $200/month over time by auto-deleting old images.

- **Requirements:**
  - One repository per application
  - Consistent naming convention
  - Image scanning enabled
  - Lifecycle policy to clean up old images

- **Implementation Details:**
  - **Naming Convention:**
    - Pattern: `[namespace]/[repo-name]`
    - Example: `legacy-migration/auth-api`
    - Namespace: Project group or team name
    - Repo Name: Match GitHub repository name exactly
  - **Repository Settings:**
    - Visibility: Private
    - Tag Mutability: **Mutable** (allow overwriting `latest` during migration)
      - Post-migration: Consider switching to Immutable for production safety
    - Encryption: **AES-256** (AWS managed)
      - Why: Avoids KMS permission complexity and cross-account issues
      - Alternative: KMS CMK if compliance requires customer-managed keys
  - **Image Scanning:**
    - Scan on Push: Enabled
    - Why: Automatically scans for CVEs; results visible in console
  - **Lifecycle Policy (Cost Control):**
    ```json
    {
      "rules": [
        {
          "rulePriority": 1,
          "description": "Keep last 10 tagged images",
          "selection": {
            "tagStatus": "tagged",
            "tagPrefixList": ["v", "release"],
            "countType": "imageCountMoreThan",
            "countNumber": 10
          },
          "action": { "type": "expire" }
        },
        {
          "rulePriority": 2,
          "description": "Delete untagged images older than 7 days",
          "selection": {
            "tagStatus": "untagged",
            "countType": "sinceImagePushed",
            "countUnit": "days",
            "countNumber": 7
          },
          "action": { "type": "expire" }
        },
        {
          "rulePriority": 3,
          "description": "Keep only last 20 images total",
          "selection": {
            "tagStatus": "any",
            "countType": "imageCountMoreThan",
            "countNumber": 20
          },
          "action": { "type": "expire" }
        }
      ]
    }
    ```

- **Acceptance Criteria:**
  - ✅ ECR repository created for each application in `scale.infra-platform` (`01-compute`)
  - ✅ Image scanning on push enabled for all repositories
  - ✅ Lifecycle policies applied to all repositories
  - ✅ `repository_url` exported as a Terraform output for each repository (consumed by CI/CD and task definitions)
  - ✅ `terraform plan` shows no changes after apply

**Terraform Example:**

```hcl
# File: ecr.tf  (inside environments/dev/us-east-1/01-compute/)

locals {
  # Add one entry per application — name must match the GitHub repo name exactly
  ecr_repositories = [
    "auth-api",
    "user-api",
    # ... add remaining apps
  ]
}

resource "aws_ecr_repository" "app" {
  for_each = toset(local.ecr_repositories)

  name                 = "${var.environment}/${each.key}" # e.g. dev/auth-api
  image_tag_mutability = "MUTABLE"                        # Allow overwriting 'latest' during migration
                                                          # Switch to IMMUTABLE post-migration for production safety

  image_scanning_configuration {
    scan_on_push = true # Automatically scans for CVEs on every push
  }

  encryption_configuration {
    encryption_type = "AES256" # AWS-managed — avoids KMS permission complexity
  }

  tags = {
    ManagedBy   = "terraform"
    Environment = var.environment
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = aws_ecr_repository.app
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 tagged release images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "release"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Delete untagged images older than 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 3
        description  = "Keep only last 20 images total"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 20
        }
        action = { type = "expire" }
      }
    ]
  })
}
```

```hcl
# File: outputs.tf  (add to existing outputs)

# Map of app name → ECR repository URL, e.g. { "auth-api" = "123456789.dkr.ecr.us-east-1.amazonaws.com/dev/auth-api" }
# Consumed by CI/CD pipelines (docker push) and service task definitions (image = ...).
output "ecr_repository_urls" {
  description = "Map of application name to ECR repository URL"
  value       = { for k, v in aws_ecr_repository.app : k => v.repository_url }
}
```

---

### Story 7.2: Push Seed Images to ECR

- **Title:** Push an Initial Seed Image to Each ECR Repository
- **Target:** Local workstation or CI/CD pipeline — runs against `scale.infra-platform` ECR
- **Persona:** As a **DevOps Engineer**, I want a placeholder image in each ECR repository so that ECS task definitions can reference a valid image URI before the real CI/CD pipeline is wired up in Phase 4.

**Why:** ECS will refuse to register a task definition that points to an image URI that doesn't exist. Pushing a seed image (a plain `public.ecr.aws/amazonlinux/amazonlinux:latest` or any small image) unblocks Phase 4 task definition creation without waiting for the full CI/CD pipeline to be built.

- **Implementation Details:**

  #### 1) Authenticate Docker to ECR

  ```bash
  aws ecr get-login-password --region us-east-1 \
    | docker login --username AWS \
        --password-stdin <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com
  ```

  #### 2) Pull a small public base image

  ```bash
  docker pull public.ecr.aws/amazonlinux/amazonlinux:latest
  ```

  #### 3) Tag and push to each ECR repository

  ```bash
  # Repeat for each application
  docker tag public.ecr.aws/amazonlinux/amazonlinux:latest \
    <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/dev/auth-api:seed

  docker push <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/dev/auth-api:seed
  ```

  > **`seed` tag** makes it obvious this is a placeholder. The real CI/CD pipeline will push `latest` and versioned tags in Phase 4, at which point the seed image will be expired by the lifecycle policy.

- **Acceptance Criteria:**
  - ✅ At least one image tagged `seed` exists in each ECR repository
  - ✅ Image is visible in the AWS Console under ECR → Repositories
  - ✅ Phase 4 task definitions can reference `<repo_url>:seed` as a valid, pullable image URI
