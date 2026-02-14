# Appendix: GitHub Actions CI/CD for ECS

## Overview

This appendix provides comprehensive guidance on implementing CI/CD pipelines for ECS Fargate deployments using GitHub Actions, including reusable workflows, deployment patterns, and best practices.

**Use this appendix when:**

- Setting up GitHub Actions for the first time
- Implementing reusable workflows at scale
- Deciding between shared vs per-service IAM roles
- Understanding secrets vs configuration values
- Troubleshooting deployment pipeline issues

---

## Table of Contents

1. [Secrets vs Configuration](#secrets-vs-configuration)
2. [Reusable Workflows for Scale](#reusable-workflows-for-scale)
3. [Common Deployment Patterns](#common-deployment-patterns)
4. [Cost Optimization](#cost-optimization)

---

## Secrets vs Configuration

### The Rule of Thumb

**Only store TRUE SECRETS in GitHub Secrets.**

Most deployment values are **configuration** (resource names), not **secrets** (sensitive credentials).

### What Goes Where

| Value                 | Type   | Where to Store             | Why                     |
| --------------------- | ------ | -------------------------- | ----------------------- |
| `AWS_ROLE_ARN`        | Secret | GitHub Secrets             | Contains AWS Account ID |
| `AWS_REGION`          | Config | Workflow file (`env`)      | Just "us-east-1"        |
| `ECR_REPOSITORY`      | Config | Workflow file (`env`)      | Just a repo name        |
| `ECS_CLUSTER`         | Config | Workflow file (`env`)      | Just a cluster name     |
| `ECS_SERVICE`         | Config | Workflow file (`env`)      | Just a service name     |
| `ECS_TASK_DEFINITION` | Config | Workflow file (`env`)      | Just a task family name |
| `CONTAINER_NAME`      | Config | Workflow file (`env`)      | Just a container name   |
| `SLACK_WEBHOOK_URL`   | Secret | GitHub Secrets (org level) | Allows posting to Slack |
| Database passwords    | Secret | AWS Secrets Manager        | Never in GitHub         |

### Why This Matters

**Problems with storing everything in Secrets:**

1. **Visibility:** Can't see what gets deployed without clicking through GitHub Settings
2. **Versioning:** Changes to cluster names aren't tracked in Git
3. **Effort:** Configuring 7 secrets per repo × 10 repos = 70 manual steps
4. **False security:** Knowing your service is named "auth-api" doesn't help hackers

**Benefits of using `env` block:**

1. **Transparency:** Anyone reading the file knows what gets deployed
2. **History:** Git tracks when you changed from staging to production cluster
3. **Simplicity:** No UI clicking required
4. **Reusability:** Copy file, update `env` block, done

### Implementation Pattern

```yaml
name: Deploy to Amazon ECS

on:
  push:
    branches:
      - main

# ✅ Configuration values here (NOT secrets)
env:
  AWS_REGION: us-east-1
  ECR_REPOSITORY: legacy-migration/auth-api
  ECS_SERVICE: auth-api-service
  ECS_CLUSTER: production-cluster
  ECS_TASK_DEFINITION: auth-api
  CONTAINER_NAME: auth-api

permissions:
  id-token: write # Required for OIDC
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-region: ${{ env.AWS_REGION }}
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }} # ✅ Only secret

      # ... rest of workflow uses ${{ env.X }}
```

---

## Reusable Workflows for Scale

### When to Use Reusable Workflows

- ✅ **Do this when:** You have 3+ services with identical deployment patterns
- ✅ **Do this when:** You want centralized control over deployment logic
- ✅ **Do this when:** You plan to add features (security scanning, notifications) to all services
- ⏸️ **Skip for now if:** You only have 1-2 services
- ⏸️ **Skip for now if:** Each service has wildly different deployment needs

### Structure

```
my-org/infrastructure/               # Central repo
└── .github/workflows/
    └── ecs-deploy-template.yml      # Reusable workflow

my-org/auth-api/                     # App repo
└── .github/workflows/
    └── deploy.yml                   # Calls template (15 lines)

my-org/test-api-1/                   # App repo
└── .github/workflows/
    └── deploy.yml                   # Calls template (15 lines)
```

### Template Workflow (infrastructure repo)

```yaml
# infrastructure/.github/workflows/ecs-deploy-template.yml
name: Reusable ECS Deploy

on:
  workflow_call:
    inputs:
      ecr_repository:
        required: true
        type: string
      service_name:
        required: true
        type: string
      cluster_name:
        required: false
        type: string
        default: "production-cluster"
      task_definition:
        required: true
        type: string
      container_name:
        required: true
        type: string
      aws_region:
        required: false
        type: string
        default: "us-east-1"
    secrets:
      AWS_ROLE_ARN:
        required: true

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-region: ${{ inputs.aws_region }}
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}

      - name: Login to ECR
        uses: aws-actions/amazon-ecr-login@v2
        id: login-ecr

      - name: Build and push image
        id: build-image
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          ECR_REPOSITORY: ${{ inputs.ecr_repository }}
          IMAGE_TAG: ${{ github.sha }}
        run: |
          docker build \
            --platform linux/amd64 \
            -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG \
            -t $ECR_REGISTRY/$ECR_REPOSITORY:latest \
            .
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:latest
          echo "image=$ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG" >> $GITHUB_OUTPUT

      - name: Download task definition
        run: |
          aws ecs describe-task-definition \
            --task-definition ${{ inputs.task_definition }} \
            --query taskDefinition > task-definition.json

      - name: Render new task definition
        uses: aws-actions/amazon-ecs-render-task-definition@v1
        id: task-def
        with:
          task-definition: task-definition.json
          container-name: ${{ inputs.container_name }}
          image: ${{ steps.build-image.outputs.image }}

      - name: Deploy to ECS
        uses: aws-actions/amazon-ecs-deploy-task-definition@v2
        with:
          task-definition: ${{ steps.task-def.outputs.task-definition }}
          service: ${{ inputs.service_name }}
          cluster: ${{ inputs.cluster_name }}
          wait-for-service-stability: true
```

### Caller Workflow (app repo)

```yaml
# auth-api/.github/workflows/deploy.yml
name: Deploy to Production

on:
  push:
    branches:
      - main

jobs:
  deploy:
    uses: my-org/infrastructure/.github/workflows/ecs-deploy-template.yml@main
    with:
      ecr_repository: legacy-migration/auth-api
      service_name: auth-api-service
      task_definition: auth-api
      container_name: auth-api
    secrets:
      AWS_ROLE_ARN: ${{ secrets.AWS_ROLE_ARN }}
```

### Versioning Strategy

| Pattern   | Use Case                                 | Stability                           |
| --------- | ---------------------------------------- | ----------------------------------- |
| `@main`   | Active development, all services in sync | Changes propagate immediately       |
| `@v1`     | Production stability                     | Pin to stable version, opt-in to v2 |
| `@abc123` | Maximum control                          | Pin to specific commit              |

**Recommendation:** Start with `@main`, switch to `@v1` tags once template is stable.

---

## Common Deployment Patterns

### Pattern 1: Single Environment (Production Only)

```yaml
env:
  AWS_REGION: us-east-1
  ECS_CLUSTER: production-cluster
  # ... other config

on:
  push:
    branches:
      - main # Deploys to production
```

### Pattern 2: Multi-Environment (Staging + Production)

```yaml
env:
  AWS_REGION: us-east-1

on:
  push:
    branches:
      - main
      - staging

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set environment
        id: set-env
        run: |
          if [[ "${{ github.ref }}" == "refs/heads/main" ]]; then
            echo "cluster=production-cluster" >> $GITHUB_OUTPUT
            echo "service=auth-api-production" >> $GITHUB_OUTPUT
          else
            echo "cluster=staging-cluster" >> $GITHUB_OUTPUT
            echo "service=auth-api-staging" >> $GITHUB_OUTPUT
          fi

      - name: Deploy
        uses: aws-actions/amazon-ecs-deploy-task-definition@v2
        with:
          cluster: ${{ steps.set-env.outputs.cluster }}
          service: ${{ steps.set-env.outputs.service }}
          # ...
```

### Pattern 3: Manual Approval for Production

```yaml
jobs:
  deploy-staging:
    # ... deploy to staging automatically

  approve-production:
    needs: deploy-staging
    runs-on: ubuntu-latest
    environment: production # Requires approval in GitHub Settings
    steps:
      - run: echo "Approved"

  deploy-production:
    needs: approve-production
    # ... deploy to production
```

---

## Cost Optimization

### GitHub Actions Minutes

- **Free tier:** 2,000 minutes/month for private repos
- **Optimization:** Use `on: push: paths:` to skip unnecessary runs
  ```yaml
  on:
    push:
      paths:
        - "src/**"
        - "Dockerfile"
        - ".github/workflows/**"
  ```

### ECR Storage

- **Lifecycle policies** to delete old images:
  ```json
  {
    "rules": [
      {
        "rulePriority": 1,
        "description": "Keep last 10 images",
        "selection": {
          "tagStatus": "any",
          "countType": "imageCountMoreThan",
          "countNumber": 10
        },
        "action": { "type": "expire" }
      }
    ]
  }
  ```

### ECS Task Size

Start small, scale up based on metrics:

- **Start:** 0.25 vCPU / 0.5 GB ($10/month)
- **Monitor:** CPU and memory utilization
- **Scale up if:** Consistently >70% utilization
- **Scale down if:** Consistently <30% utilization

---

## Additional Resources

### Official Documentation

- [GitHub Actions: Deploying to Amazon ECS](https://docs.github.com/en/actions/deployment/deploying-to-amazon-elastic-container-service)
- [AWS: IAM roles for service accounts](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html)
- [AWS ECS Developer Guide](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/)

### Community Resources

- [terraform-aws-modules/ecs](https://github.com/terraform-aws-modules/terraform-aws-ecs)
- [aws-actions GitHub org](https://github.com/aws-actions)
- [Awesome ECS](https://github.com/nathanpeck/awesome-ecs)

---

## Related Documentation

- See [aws-authentication-and-security.md](aws-authentication-and-security.md) for OIDC setup
- See [ecs-deployment-fundamentals.md](ecs-deployment-fundamentals.md) for understanding ECS concepts
- See [troubleshooting-and-operations.md](troubleshooting-and-operations.md) for debugging pipelines
