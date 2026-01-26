# Appendix: CI/CD Best Practices & Implementation Details

## Overview

This appendix provides comprehensive guidance on implementing CI/CD for ECS Fargate deployments, consolidating best practices from Phase 3 (Story 6) and Phase 4 (Feature 1), plus foundational concepts for understanding ECS deployments.

**Use this appendix when:**

- Understanding how ECS components fit together
- Setting up GitHub Actions for the first time
- Deciding between shared vs per-service IAM roles
- Implementing reusable workflows at scale
- Troubleshooting deployment pipeline issues

---

## Table of Contents

1. [ECS Deployment Fundamentals](#1-ecs-deployment-fundamentals)
2. [Security Group Patterns](#2-security-group-patterns)
3. [Authentication: GitHub Actions OIDC with AWS](#3-authentication-github-actions-oidc-with-aws)
4. [Secrets vs Configuration](#4-secrets-vs-configuration-security-best-practices)
5. [Reusable Workflows for Scale](#5-reusable-workflows-for-scale)
6. [Common Deployment Patterns](#6-common-deployment-patterns)
7. [Troubleshooting Common Issues](#7-troubleshooting-common-issues)
8. [Security Hardening Checklist](#8-security-hardening-checklist)
9. [Cost Optimization](#9-cost-optimization)
10. [Additional Resources](#10-additional-resources)

---

## 1. ECS Deployment Fundamentals

### What is a Task Definition?

A **Task Definition** is a blueprint that tells ECS how to run your container. Think of it as a detailed `docker run` command saved as configuration.

**It specifies:**

- Which Docker image to use
- How much CPU and memory to allocate
- What environment variables to set
- Which secrets to inject from Secrets Manager
- Where to send logs (CloudWatch)
- Which ports to expose
- What IAM roles to use (execution role, task role)
- Health check configuration

**Example analogy:**

- Task Definition = Recipe
- ECS Service = Chef that follows the recipe
- Running Task = The actual dish being served

### The Complete Deployment Sequence

Here's the correct order to deploy a new service:

```
1. Push Image to ECR
   ↓
2. Create Task Definition (blueprint)
   ↓
3. Create Target Group (ALB routing destination)
   ↓
4. Create ECS Service (runs tasks using the blueprint)
   ↓
5. Add ALB Listener Rule (routes traffic to target group)
   ↓
6. Configure DNS (point domain to ALB)
```

**Why this order matters:**

- You need the image in ECR before creating the task definition (image URI required)
- You need the target group before creating the service (service connects to it)
- You need the service running before adding the listener rule (otherwise rule routes to nothing)

### Component Relationships

**Example:** This diagram shows the pattern using `your-service` as a placeholder. Replace with your actual service names (e.g., `test-api-1`, `test-api-2`, `auth-api`).

```
┌─────────────────────────────────────────────────────────────┐
│                         USER REQUEST                         │
└───────────────────────────────┬─────────────────────────────┘
                                ↓
                    ┌───────────────────────┐
                    │  Application Load     │
                    │  Balancer (ALB)       │
                    │  - SSL Termination    │
                    │  - Host-based routing │
                    └───────────┬───────────┘
                                ↓
                    ┌───────────────────────┐
                    │  Listener Rule        │
                    │  Priority: 100        │
                    │  Condition: Host      │
                    │  yourapp.mysite.com   │
                    └───────────┬───────────┘
                                ↓
                    ┌───────────────────────┐
                    │  Target Group         │
                    │  your-service-tg      │
                    │  Type: IP             │
                    │  Health: /health      │
                    └───────────┬───────────┘
                                ↓
    ┌───────────────────────────────────────────────────────────────┐
    │                  ECS CLUSTER: your-cluster                     │
    │                  (e.g., test, production)                      │
    │                                                                │
    │               ┌───────────────────────┐                        │
    │               │  ECS Service          │                        │
    │               │  your-service         │                        │
    │               │  Desired: 2           │                        │
    │               │  Uses: Task Def       │                        │
    │               └───────────┬───────────┘                        │
    │                           ↓                                    │
    │       ┌───────────────────┴───────────────────────┐           │
    │       ↓                                           ↓           │
    │ ┌───────────────────┐                   ┌───────────────────┐ │
    │ │  Fargate Task 1   │                   │  Fargate Task 2   │ │
    │ │  IP: 10.100.4.23  │                   │  IP: 10.100.6.45  │ │
    │ │  Port: 3000       │                   │  Port: 3000       │ │
    │ │  Status: Healthy  │                   │  Status: Healthy  │ │
    │ └─────────┬─────────┘                   └─────────┬─────────┘ │
    │           └─────────────────┬─────────────────────┘           │
    └─────────────────────────────┼─────────────────────────────────┘
                                  ↓
              ┌───────────────────────────────────────────┐
              │     Task Definition (Blueprint)            │
              │  Family: your-service                     │
              │  Container: your-service                  │
              │  - Image: ECR URI                         │
              │  - CPU: 256, Memory: 512                  │
              │  - Env vars, Secrets, Logs, Health check  │
              └───────────────────────────────────────────┘
```

**Key:** The **ECS Cluster** is a logical grouping that contains Services and Tasks. Multiple services (like `test-api-1`, `test-api-2`, `auth-api`) can run in the same cluster, sharing the same infrastructure pool.

### Naming Conventions

**Critical: Keep these names identical for simplicity.**

AWS doesn't technically require these names to match, but keeping them the same eliminates confusion and makes operations easier.

**Recommended Pattern:**

| Component                            | What to Name It         | Example 1               | Example 2             |
| ------------------------------------ | ----------------------- | ----------------------- | --------------------- |
| **Task Definition Family**           | `[app-name]`            | `test-api-1`            | `auth-api`            |
| **Container Name** (inside task def) | `[app-name]`            | `test-api-1`            | `auth-api`            |
| **ECS Service**                      | `[app-name]`            | `test-api-1`            | `auth-api`            |
| **Target Group**                     | `[app-name]-tg`         | `test-api-1-tg`         | `auth-api-tg`         |
| **Security Group**                   | `[app-name]-fargate-sg` | `test-api-1-fargate-sg` | `auth-api-fargate-sg` |

**Why This Matters:**

✅ **Easy Debugging:** When you see `test-api-1` in CloudWatch logs, you know exactly which service it is  
✅ **Simpler CI/CD:** Use one variable for Task Family, Container Name, and Service Name  
✅ **Team Clarity:** No mental mapping required - name = service  
✅ **Less Errors:** No chance of updating the wrong container in a multi-container task definition

**When to Use Different Names:**

- Multiple environments: `test-api-1-staging` vs `test-api-1-production`
- Version migrations: `auth-api-v2` (temporary during cutover)

**What Happens If You Don't Match?**

Nothing breaks, but you'll create unnecessary complexity:

- Task Family: `legacy-test-api-1-v2`
- Container: `test-api-1-container`
- Service: `production-test-api-1-service`

Now you need to remember this mapping everywhere - in CI/CD scripts, troubleshooting commands, documentation, team communication, etc.

**Example for Your Deployment:**

```bash
# test-api-1
Task Definition Family: test-api-1
Container Name: test-api-1
Service Name: test-api-1
Target Group: test-api-1-tg

# test-api-2
Task Definition Family: test-api-2
Container Name: test-api-2
Service Name: test-api-2
Target Group: test-api-2-tg

# auth-api
Task Definition Family: auth-api
Container Name: auth-api
Service Name: auth-api
Target Group: auth-api-tg
```

---

### Key Concepts Explained

#### Task Definition vs Task vs Service

| Component           | What It Is                        | Analogy                |
| ------------------- | --------------------------------- | ---------------------- |
| **Task Definition** | A JSON blueprint                  | Recipe card            |
| **Task**            | A running container instance      | Dish being served      |
| **Service**         | Maintains desired number of tasks | Chef who keeps cooking |

**Example:**

- Task Definition: "Run `auth-api:latest` with 512MB RAM on port 3000"
- Service: "Keep 2 copies of auth-api running at all times"
- Tasks: The actual 2 running containers

#### Why Do I Need All These Things?

**Q: Can't I just run a container like Docker Compose?**

A: ECS adds production capabilities:

- **Target Group**: Load balances across multiple containers, health checks
- **Service**: Auto-restarts failed containers, rolling deployments
- **ALB**: SSL termination, routing multiple apps on one load balancer
- **Task Definition**: Version control for infrastructure, rollback capability

### Task Definition Versions

Every time you update a task definition, AWS creates a new **revision**:

- `auth-api:1` (initial)
- `auth-api:2` (added environment variable)
- `auth-api:3` (updated image)

**Your ECS Service points to a specific revision:**

- Service runs `auth-api:3`
- If there's an issue, you can rollback to `auth-api:2`

### What Happens When You Deploy

```
1. GitHub Actions pushes new image to ECR
   - Tags it with git SHA: auth-api:abc123f

2. GitHub Actions creates new task definition revision
   - auth-api:4 with image auth-api:abc123f

3. GitHub Actions updates ECS Service
   - "Use task definition auth-api:4"

4. ECS Service starts rolling deployment
   - Starts 1 new task (auth-api:4)
   - Waits for it to be healthy
   - Stops 1 old task (auth-api:3)
   - Repeats until all tasks updated

5. Target Group health checks pass
   - ALB routes traffic to new tasks
   - Old tasks drained and terminated
```

### Quick Reference: When You Need Each Component

| You Need                 | To Do This                                      |
| ------------------------ | ----------------------------------------------- |
| **Task Definition**      | Always (defines what to run)                    |
| **ECR Repository**       | Always (stores your image)                      |
| **ECS Service**          | Run containers continuously (not one-off tasks) |
| **Target Group**         | Receive traffic from ALB                        |
| **ALB Listener Rule**    | Route traffic based on domain/path              |
| **Security Group**       | Control network access                          |
| **CloudWatch Log Group** | See application logs                            |

---

## 2. Security Group Patterns

### The Problem with One-Per-Service

The naive approach is to create a unique security group for every service:

- `test-api-1-sg` with ALB inbound rule
- `test-api-2-sg` with ALB inbound rule
- `auth-api-sg` with ALB inbound rule
- ... 10 more services, 10 more duplicate rules

**Problems:**

- ❌ Duplicate ALB access rules across every service SG
- ❌ Updating the ALB rule requires changing 10+ security groups
- ❌ Harder to audit ("which services can access the ALB?" = check 10 SGs)
- ❌ Doesn't scale well

### Recommended Pattern: Baseline + Service-Specific

**You can attach up to 5 security groups to a single ECS task.** Use this to create a scalable pattern:

#### 1. Baseline Security Group (Shared by ALL services)

**Name:** `fargate-baseline-sg` or `fargate-common-sg`

**Purpose:** Common rules that apply to every Fargate service

**Rules:**

```
Inbound:
- Source: ALB Security Group (sg-alb-xxx)
  Port: 3000 (or your app port)
  Description: "Allow ALB to reach all Fargate services"

Outbound:
- Destination: 0.0.0.0/0
  Port: All
  Description: "Allow internet access for ECR pulls, API calls, etc."
```

**Attached to:** Every single Fargate service

#### 2. Service-Specific Security Groups (Optional, for Resource Isolation)

**Pattern:** Create these ONLY for services that need specific resource access

**Example 1: Database Access**

**Name:** `auth-api-database-sg`

**Purpose:** Marker SG to grant auth-api (and only auth-api) database access

**Rules:**

```
Inbound: None
Outbound: None
```

**Why no rules?** This SG is just a "marker" - the RDS security group references it.

**RDS Security Group gets updated:**

```
Inbound:
- Source: auth-api-database-sg
  Port: 5432
  Description: "Allow auth-api to connect to database"
```

**Attached to:** Only `auth-api` service

**Example 2: S3 Access (Via VPC Endpoint)**

**Name:** `billing-api-s3-sg`

**Purpose:** Grant S3 VPC endpoint access to billing-api only

**VPC Endpoint SG gets updated:**

```
Inbound:
- Source: billing-api-s3-sg
  Port: 443
  Description: "Allow billing-api to reach S3 via VPC endpoint"
```

**Attached to:** Only `billing-api` service

### Complete Example

**Scenario:** 3 services, 1 needs database access

**Security Groups Created:**

1. `fargate-baseline-sg` (shared)
2. `auth-api-database-sg` (service-specific)

**Service Attachments:**

| Service      | Security Groups Attached                        | Result                                             |
| ------------ | ----------------------------------------------- | -------------------------------------------------- |
| `auth-api`   | `fargate-baseline-sg`<br>`auth-api-database-sg` | ✅ Can receive ALB traffic<br>✅ Can access RDS    |
| `test-api-1` | `fargate-baseline-sg`                           | ✅ Can receive ALB traffic<br>❌ Cannot access RDS |
| `test-api-2` | `fargate-baseline-sg`                           | ✅ Can receive ALB traffic<br>❌ Cannot access RDS |

**Database (RDS) Security Group:**

```
Inbound:
- Source: auth-api-database-sg
  Port: 5432
```

**Result:** Only auth-api can connect to the database (principle of least privilege)

### Implementation in ECS Service

**When creating ECS Service (Console):**

```
Networking:
  Security Groups:
    - fargate-baseline-sg        ← Always include
    - auth-api-database-sg       ← Add if service needs DB
```

**When creating ECS Service (CLI):**

```bash
aws ecs create-service \
  --cluster production-cluster \
  --service-name auth-api \
  --task-definition auth-api:1 \
  --network-configuration "awsvpcConfiguration={
    subnets=[subnet-xxx,subnet-yyy],
    securityGroups=[sg-baseline-xxx,sg-auth-api-database-yyy],
    assignPublicIp=DISABLED
  }"
```

### When to Use Each Pattern

| Scenario                                             | Pattern                     | Security Groups                                 |
| ---------------------------------------------------- | --------------------------- | ----------------------------------------------- |
| POC with identical services                          | Baseline only               | `fargate-baseline-sg`                           |
| Production with services needing different DB access | Baseline + Service-Specific | `fargate-baseline-sg` + `[app]-database-sg`     |
| Multi-tenant with strict isolation                   | One-per-service             | `[app]-sg` (not recommended at scale)           |
| Microservices accessing different external APIs      | Baseline + Service-Specific | `fargate-baseline-sg` + `[app]-external-api-sg` |

### Benefits Summary

✅ **Centralized Common Rules:** ALB access rule exists in one place  
✅ **Scalable:** Add 100 services, still just 1 baseline SG  
✅ **Principle of Least Privilege:** Only grant database access to services that need it  
✅ **Easy Auditing:** "Which services can access RDS?" = Check which services have the database SG attached  
✅ **Flexible:** Can mix and match up to 5 SGs per service  
✅ **Cost Effective:** Security groups are free (unlike NACLs or firewall appliances)

### Migration Path

**If you already have one-per-service SGs:**

1. Create `fargate-baseline-sg` with ALB access rule
2. Attach it to all existing services (in addition to their current SG)
3. Verify traffic still flows
4. Remove ALB rules from individual service SGs
5. For new services, only attach baseline + service-specific (if needed)
6. Eventually remove old per-service SGs if they're empty

---

## 3. Authentication: GitHub Actions OIDC with AWS

### Why OIDC Over Access Keys

| Aspect               | IAM Access Keys                 | OIDC (Recommended)                 |
| -------------------- | ------------------------------- | ---------------------------------- |
| **Rotation**         | Manual, painful                 | Automatic (token per run)          |
| **Exposure Risk**    | Key leak = permanent access     | Token expires in minutes           |
| **Audit Trail**      | Hard to trace which repo/branch | CloudTrail shows exact repo/branch |
| **Setup Complexity** | Easier initially                | More setup, better long-term       |
| **Compliance**       | Often prohibited                | Industry standard                  |

### Implementation Steps

#### Step 1: Create OIDC Identity Provider (One-Time Setup)

```bash
# Via AWS Console:
# IAM → Identity Providers → Add Provider
# - Provider Type: OpenID Connect
# - Provider URL: https://token.actions.githubusercontent.com
# - Audience: sts.amazonaws.com

# Via AWS CLI:
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

#### Step 2: Create IAM Role (Initial: Shared Role)

**For your first 1-3 services**, use a single shared role:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:my-org/*:ref:refs/heads/main"
        }
      }
    }
  ]
}
```

**Trust Policy Patterns:**

- Wildcard (any repo, main only): `repo:my-org/*:ref:refs/heads/main` ← Start here
- Single repo (any branch): `repo:my-org/auth-api:*`
- Single repo and branch: `repo:my-org/auth-api:ref:refs/heads/main`
- Multiple specific repos: `repo:my-org/auth-api:* OR repo:my-org/billing-api:*`

#### Step 3: Attach Permissions Policy (Wildcard for Speed)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRAuth",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "ECRPushToNamespace",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload"
      ],
      "Resource": "arn:aws:ecr:us-east-1:123456789012:repository/legacy-migration/*"
    },
    {
      "Sid": "ECSDeployToCluster",
      "Effect": "Allow",
      "Action": [
        "ecs:DescribeServices",
        "ecs:DescribeTaskDefinition",
        "ecs:DescribeTasks",
        "ecs:RegisterTaskDefinition",
        "ecs:UpdateService"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "ecs:cluster": "arn:aws:ecs:us-east-1:123456789012:cluster/production-cluster"
        }
      }
    },
    {
      "Sid": "PassRoleForTaskExecution",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": [
        "arn:aws:iam::123456789012:role/ecsTaskExecutionRole",
        "arn:aws:iam::123456789012:role/*-task-role"
      ],
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "ecs-tasks.amazonaws.com"
        }
      }
    }
  ]
}
```

**When to refactor to per-service roles:** See Phase 4, Story 1.4 (typically after 3+ services in production).

---

## 2. Secrets vs Configuration: Security Best Practices

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

## 3. Reusable Workflows for Scale

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

## 4. Common Deployment Patterns

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

## 5. Troubleshooting Common Issues

### Pipeline Failures

| Error                                                     | Cause                                 | Fix                                          |
| --------------------------------------------------------- | ------------------------------------- | -------------------------------------------- |
| "Not authorized to perform sts:AssumeRoleWithWebIdentity" | Trust policy `sub` doesn't match repo | Check repo name in trust policy              |
| "Could not assume role"                                   | Missing `id-token: write` permission  | Add `permissions` block to workflow          |
| "AccessDeniedException" on ECR                            | Role doesn't have ECR permissions     | Add ECR policy to role                       |
| "Service not stable" timeout                              | Deployment failing health checks      | Check ECS events, CloudWatch logs            |
| "exec format error"                                       | Built for wrong CPU architecture      | Add `--platform linux/amd64` to docker build |
| "Task failed to start"                                    | Image not found in ECR                | Check ECR repo name and region               |
| "Stopped reason: CannotPullContainerError"                | No NAT Gateway or VPC endpoints       | Add NAT or ECR VPC endpoints                 |

### Debugging Steps

1. **Check GitHub Actions logs** (most verbose, start here)
2. **Check ECS Service Events** (deployment progress)
   ```bash
   aws ecs describe-services --cluster production-cluster --services auth-api-service \
     --query 'services[0].events[0:10]'
   ```
3. **Check ECS Task Status** (why tasks fail)
   ```bash
   aws ecs describe-tasks --cluster production-cluster --tasks <task-id> \
     --query 'tasks[0].{Status:lastStatus,Reason:stoppedReason,Containers:containers[0].reason}'
   ```
4. **Check CloudWatch Logs** (application errors)
   ```bash
   aws logs tail /ecs/production-cluster/auth-api --follow
   ```
5. **Check Target Group Health** (ALB perspective)
   ```bash
   aws elbv2 describe-target-health --target-group-arn <arn>
   ```

---

## 6. Security Hardening Checklist

### GitHub Actions Security

- [ ] Use OIDC instead of access keys
- [ ] Pin action versions (`uses: actions/checkout@v4` not `@main`)
- [ ] Minimize IAM permissions (see Phase 4, Story 1.4 for per-service roles)
- [ ] Use environment protection rules for production
- [ ] Enable branch protection on main
- [ ] Require pull request reviews
- [ ] Use GitHub secret scanning (automatically enabled)
- [ ] Rotate secrets if compromised (OIDC tokens rotate automatically)

### AWS IAM Security

- [ ] Use `StringEquals` conditions in trust policies where possible
- [ ] Scope ECS permissions to specific cluster (see Condition in policy example)
- [ ] Use specific ECR repository ARNs (not wildcards)
- [ ] Add `iam:PassedToService` condition to PassRole (prevents privilege escalation)
- [ ] Enable CloudTrail for audit logging
- [ ] Review IAM policies quarterly

### Container Image Security

- [ ] Run vulnerability scanning (Trivy, Snyk, AWS ECR scanning)
- [ ] Use specific base image versions (not `latest`)
- [ ] Don't run containers as root (use `USER` in Dockerfile)
- [ ] Don't embed secrets in images (use Secrets Manager)
- [ ] Use multi-stage builds to reduce attack surface
- [ ] Sign images (Docker Content Trust or AWS Signer)

---

## 7. Cost Optimization

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

## 8. Additional Resources

### Official Documentation

- [GitHub Actions: Deploying to Amazon ECS](https://docs.github.com/en/actions/deployment/deploying-to-amazon-elastic-container-service)
- [AWS: IAM roles for service accounts](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html)
- [AWS ECS Developer Guide](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/)

### Community Resources

- [terraform-aws-modules/ecs](https://github.com/terraform-aws-modules/terraform-aws-ecs)
- [aws-actions GitHub org](https://github.com/aws-actions)
- [Awesome ECS](https://github.com/nathanpeck/awesome-ecs)

### Related Sections in This Plan

- **Phase 3, Story 6:** Initial CI/CD setup
- **Phase 4, Story 1.1-1.3:** Reusable workflows
- **Phase 4, Story 1.4:** Per-service IAM roles
- **Phase 4, Story 2:** Infrastructure as Code with Terraform

---

## Appendix A: Secrets Security — EC2 vs ECS Comparison

This appendix explains **how secrets are stored and injected** in both environments, and why ECS + Secrets Manager is a security improvement.

### The Security Question

When your app reads `process.env.DB_PASSWORD`, the question isn't just "does it work?" — it's:

1. **Where is the secret stored at rest?** (On disk? Encrypted? Where?)
2. **Who can access the secret?** (Anyone with SSH? IAM-controlled?)
3. **Is there an audit trail?** (Who accessed what, when?)
4. **Can the secret be rotated?** (Without downtime?)

### EC2: Current State (Typical Patterns)

#### Pattern 1: `.env` File + dotenv Library

```
┌─────────────────────────────────────────────────────────────────┐
│ EC2 Instance                                                    │
│  ┌──────────────────┐      ┌──────────────────────────────────┐ │
│  │  .env file       │ ───▶ │  App (dotenv loads at startup)   │ │
│  │  DB_PASS=secret  │      │  process.env.DB_PASS = "secret"  │ │
│  │  (plaintext)     │      │                                  │ │
│  └──────────────────┘      └──────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

**Security Concerns:**

- ⚠️ Secret stored in **plaintext file on disk**
- ⚠️ Anyone with SSH access can `cat .env` and see all secrets
- ⚠️ If `.env` ends up in a backup, secrets are exposed
- ⚠️ No audit trail — you don't know who read the file
- ⚠️ Rotation requires editing the file and restarting the app

#### Pattern 2: Shell Export (Startup Script / PM2 / systemd)

```
┌───────────────────────────────────────────────────────────────────────┐
│ EC2 Instance                                                          │
│  ┌────────────────────────┐      ┌──────────────────────────────────┐ │
│  │  startup.sh            │      │  App                             │ │
│  │  export DB_PASS=secret │ ───▶ │  process.env.DB_PASS = "secret"  │ │
│  │  node app.js           │      │                                  │ │
│  └────────────────────────┘      └──────────────────────────────────┘ │
│                                                                       │
│  OR: PM2 ecosystem.config.js / systemd unit file                      │
└───────────────────────────────────────────────────────────────────────┘
```

**Security Concerns:**

- ⚠️ Secret still in **plaintext** (in script, PM2 config, or systemd unit)
- ⚠️ Anyone with SSH can read the startup script or `ps aux` might show it
- ⚠️ `/proc/<pid>/environ` exposes all env vars to anyone who can read it
- ⚠️ No audit trail
- ⚠️ Rotation requires editing config and restarting

**Slight improvement over `.env`:** Secret isn't in the application directory, so less likely to be accidentally committed or deployed.

#### Pattern 3: EC2 Parameter Store / Secrets Manager (Rare but Better)

Some EC2 setups fetch secrets at startup:

```bash
# startup.sh
export DB_PASS=$(aws secretsmanager get-secret-value --secret-id prod/db --query SecretString --output text)
node app.js
```

**Better, but:**

- ⚠️ Still ends up as plaintext env var on the instance
- ⚠️ `/proc/<pid>/environ` still exposes it
- ✅ At least the secret isn't in a file on disk
- ✅ IAM controls who can fetch (but anyone on the instance can read after fetch)

---

### ECS + Secrets Manager: The Target State

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                                                                                  │
│  ┌─────────────────────┐      ┌─────────────────┐      ┌────────────────────┐   │
│  │  Secrets Manager    │      │  ECS Service    │      │  Fargate Task      │   │
│  │                     │      │                 │      │                    │   │
│  │  production/auth/db │ ───▶ │  Task Def       │ ───▶ │  Container         │   │
│  │  (encrypted by KMS) │      │  secrets block  │      │  process.env.DB_*  │   │
│  │                     │      │                 │      │                    │   │
│  └─────────────────────┘      └─────────────────┘      └────────────────────┘   │
│                                                                                  │
│  IAM: Task Execution Role                                                        │
│       - secretsmanager:GetSecretValue                                            │
│       - Resource: arn:aws:secretsmanager:...:production/auth/*                   │
│                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────┘
```

**How It Works:**

1. Secrets stored in **AWS Secrets Manager** (encrypted at rest with KMS)
2. ECS Task Definition references the secret ARN:
   ```json
   "secrets": [
     {
       "name": "DB_PASSWORD",
       "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789:secret:production/auth/db:password::"
     }
   ]
   ```
3. At container start, **ECS fetches the secret** (not your app) using the Task Execution Role
4. ECS injects the value as an environment variable
5. Your app reads `process.env.DB_PASSWORD` — it doesn't know about Secrets Manager

**Security Improvements:**

| Concern             | EC2 (.env / export)          | ECS + Secrets Manager                      |
| ------------------- | ---------------------------- | ------------------------------------------ |
| **Storage at rest** | Plaintext file on disk       | Encrypted with KMS                         |
| **Access control**  | Anyone with SSH              | IAM policies (least privilege)             |
| **Audit trail**     | None                         | CloudTrail logs every access               |
| **Rotation**        | Manual edit + restart        | Automatic rotation available               |
| **Exposure risk**   | In backups, logs, ps output  | Never written to disk                      |
| **Blast radius**    | Compromise EC2 = all secrets | Compromise task = only that task's secrets |

---

### What About `/proc/<pid>/environ`?

You might ask: "Doesn't ECS still inject secrets as env vars? Can't someone read `/proc`?"

**In Fargate:**

- There's no SSH access to the underlying host
- You can't `exec` into a container unless you explicitly enable ECS Exec
- Even with ECS Exec, IAM controls who can do it (and it's logged)
- The attack surface is dramatically smaller

**Contrast with EC2:**

- Anyone with SSH can read any process's environment
- Often multiple people/services share the same EC2 instance
- Less granular access control

---

### App Code: Identical in Both Environments

This is the key point — **your application code doesn't change:**

```javascript
// This works identically on EC2 and ECS
const dbPassword = process.env.DB_PASSWORD;

if (!dbPassword) {
  throw new Error("DB_PASSWORD environment variable is required");
}
```

What changes is **how the secret gets there**:

| Environment               | Who sets `process.env.DB_PASSWORD`? |
| ------------------------- | ----------------------------------- |
| EC2 + dotenv              | dotenv library reads `.env` file    |
| EC2 + shell export        | Bash `export` before starting app   |
| EC2 + PM2                 | PM2 ecosystem config `env` block    |
| **ECS + Secrets Manager** | **ECS injects at container start**  |

---

### Removing dotenv for Production

If your app currently uses dotenv, you have two options:

**Option A: Make dotenv Optional (Recommended)**

```javascript
// Only load .env if it exists (for local development)
require("dotenv").config({ silent: true });
// Or in newer versions:
require("dotenv").config(); // Doesn't throw if file missing

// App code works the same either way
const dbHost = process.env.DB_HOST;
```

**Option B: Remove dotenv Entirely**

```javascript
// Just read from process.env directly
const dbHost = process.env.DB_HOST;
```

For local development without dotenv, you can:

- Use `export` in your shell before running the app
- Use a `docker-compose.yml` with `environment:` block
- Use VS Code's `launch.json` with `"env"` configuration

---

### Security Best Practices Summary

1. **Never commit secrets to git** — use `.env.example` with placeholder values
2. **Never bake secrets into Docker images** — check with `docker history <image>`
3. **Use Secrets Manager** (not SSM Parameter Store) for truly sensitive values
   - SSM Parameter Store SecureString works but has lower API limits
4. **Scope IAM permissions** — each app should only access its own secrets
5. **Enable CloudTrail** — audit who accessed which secrets
6. **Consider rotation** — especially for database credentials
7. **Use VPC Endpoints** — so secrets never traverse the public internet

---

### Migration Path

| Phase          | Action                                                         | Owner         |
| -------------- | -------------------------------------------------------------- | ------------- |
| Phase 0        | Inventory all secrets (Story 5.1)                              | Dev team      |
| Phase 1        | Ensure app reads from `process.env`, not hardcoded (Story 2.1) | Dev team      |
| Phase 1        | Make dotenv optional or remove it                              | Dev team      |
| Phase 2        | Create secrets in Secrets Manager (Story 4.1)                  | Infra team    |
| Phase 3        | Reference secrets in Task Definition                           | Infra team    |
| Post-migration | Delete `.env` files from EC2 instances                         | Infra team    |
| Post-migration | Consider enabling secret rotation                              | Security team |
