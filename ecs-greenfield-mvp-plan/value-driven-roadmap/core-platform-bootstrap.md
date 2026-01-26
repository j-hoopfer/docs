# Enabler Epic A: Core Platform Bootstrap (The Walking Skeleton)

**Goal:** Deploy a "Hello World" app running in ECS Fargate, deployed via GitHub Actions, reachable via HTTPS. This establishes the critical path for continuous delivery from Day 1.

**Duration:** Days 1–10

**Business Value:** Enables the development team to start coding business features immediately. Proves that the deployment pipeline works before building complex infrastructure.

**Prerequisites:** Credit card for AWS account, domain registrar access, GitHub organization ready.

**SAFe Principle:** "Build the minimum viable platform that enables teams to deliver working software."

---

## Environment Strategy Overview

This project uses a **two-environment model** with local development:

| Environment    | Purpose                                                  | Who Uses It                    | Infrastructure             |
| -------------- | -------------------------------------------------------- | ------------------------------ | -------------------------- |
| **Local**      | Fast iteration, individual development                   | Engineers on their machines    | Docker Compose             |
| **Dev (AWS)**  | Integration testing, CI/CD validation, team verification | All engineers, CI/CD pipelines | Terraform `dev` workspace  |
| **Prod (AWS)** | Live users, production traffic                           | End users                      | Terraform `prod` workspace |

### CI/CD Flow

```
Local Development → Push to main → Build Image → Deploy to Dev (auto) → Manual Approval → Deploy to Prod
```

### Environment Parity Principles

1. **Same Docker image** deployed to both AWS environments (tagged by Git SHA)
2. **Same Terraform modules** with environment-specific `tfvars`
3. **Configuration via environment variables** (not code changes)
4. **Database schema identical** (migrations run in both environments)

### Key Differences Between Environments

| Aspect                  | Local              | Dev (AWS)                  | Prod (AWS)                  |
| ----------------------- | ------------------ | -------------------------- | --------------------------- |
| **Database**            | Docker PostgreSQL  | RDS db.t3.micro, single-AZ | RDS db.t3.medium+, Multi-AZ |
| **Compute**             | Local Node process | Fargate 0.25 vCPU, 1 task  | Fargate 1+ vCPU, 2+ tasks   |
| **HTTPS**               | HTTP localhost     | Yes (dev.example.com)      | Yes (example.com)           |
| **Secrets**             | `.env.local` file  | AWS Secrets Manager        | AWS Secrets Manager         |
| **Deploy approval**     | N/A                | Automatic                  | 1 reviewer required         |
| **Backups**             | None               | 7 days                     | 30 days                     |
| **WAF**                 | None               | Optional                   | Enabled                     |
| **Deletion protection** | N/A                | Off                        | On                          |
| **Est. cost/month**     | $0                 | ~$50-100                   | ~$200+                      |

### Terraform Structure

```
terraform/
├── bootstrap/                    # State bucket (run once)
│   └── main.tf
├── modules/                      # Reusable modules
│   ├── networking/
│   ├── database/
│   ├── compute/
│   └── cicd/
└── environments/
    ├── dev/
    │   ├── main.tf              # Calls modules
    │   ├── variables.tf
    │   ├── terraform.tfvars     # Dev-specific values
    │   └── backend.tf           # S3 key: dev/terraform.tfstate
    └── prod/
        ├── main.tf
        ├── variables.tf
        ├── terraform.tfvars     # Prod values (HA, Multi-AZ)
        └── backend.tf           # S3 key: prod/terraform.tfstate
```

---

## Story 1.1: AWS Account Setup & Terraform State Bootstrap

As a Cloud Admin
I want a secure AWS account with foundational services enabled
So that we have a safe, auditable environment for development

### Technical Requirements

- Secure Root User with MFA enabled, zero access keys
- IAM Identity Center (SSO) with admin user and group
- Financial guardrails: CloudWatch billing alarms + AWS Budgets
- Security guardrails: GuardDuty, Security Hub, IAM Access Analyzer
- Default VPC removed in target region
- Terraform S3 backend + DynamoDB lock table configured
- GitHub repository initialized with `.gitignore` and initial README

### Implementation Details

#### 1) Create & Secure AWS Account

- Navigate to https://aws.amazon.com and create account
- The email used becomes the Root User
- Complete account verification and billing setup

**Secure Root User (Critical):**

- Log in as Root
- Enable MFA: Console → IAM → Security Credentials → Activate MFA (TOTP app like 1Password or Google Authenticator)
- Ensure Root has zero access keys
- Log out; use only for break-glass scenarios (e.g., billing)

#### 2) Enable IAM Identity Center (SSO)

- Open IAM Identity Center and click Enable
- Create User: Add your admin user (email + name)
- Create Group: `Admins`
- Create Permission Set: `AdministratorAccess` (predefined policy)
- Assign `Admins` group to your AWS Account using the permission set
- Note the SSO access portal URL (e.g., `https://d-12345.awsapps.com/start`)

#### 3) Financial Guardrails

Enable billing alerts in Billing Dashboard → Billing Preferences.

Create CloudWatch Alarm (EstimatedCharges) in `us-east-1`:

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "EstimatedCharges-USD-50" \
  --alarm-description "Bill estimate exceeds $50" \
  --metric-name EstimatedCharges \
  --namespace AWS/Billing \
  --statistic Maximum \
  --period 21600 \
  --threshold 50 \
  --comparison-operator GreaterThanThreshold \
  --dimensions Name=Currency,Value=USD \
  --evaluation-periods 1 \
  --alarm-actions arn:aws:sns:us-east-1:YOUR_ACCOUNT_ID:billing-alerts \
  --region us-east-1
```

Create AWS Budgets:

```bash
aws budgets create-budget \
  --account-id YOUR_ACCOUNT_ID \
  --budget '{
    "BudgetName":"Monthly-Overall",
    "BudgetLimit":{"Amount":"100","Unit":"USD"},
    "TimeUnit":"MONTHLY",
    "BudgetType":"COST",
    "CostTypes":{"IncludeCredit":false,"IncludeRefund":false}
  }' \
  --notifications-with-subscribers '[
    {
      "Notification":{
        "NotificationType":"ACTUAL",
        "ComparisonOperator":"GREATER_THAN",
        "Threshold":50,
        "ThresholdType":"PERCENTAGE"
      },
      "Subscribers":[{"SubscriptionType":"EMAIL","Address":"you@example.com"}]
    }
  ]'
```

#### 4) Security Guardrails

Enable GuardDuty:

```bash
aws guardduty create-detector \
  --enable \
  --finding-publishing-frequency FIFTEEN_MINUTES \
  --region us-east-1
```

Enable Security Hub:

```bash
aws securityhub enable-security-hub --region us-east-1
aws securityhub batch-enable-standards \
  --standards-subscription-requests '[{"StandardsArn":"arn:aws:securityhub:us-east-1::standards/aws-foundational-security-best-practices/v/1.0.0"}]'
```

Enable IAM Access Analyzer:

```bash
aws accessanalyzer create-analyzer \
  --type ACCOUNT \
  --name account-analyzer \
  --region us-east-1
```

#### 5) Delete Default VPC

AWS creates a Default VPC per region; delete it in the target region to avoid accidental public deployments:

```bash
# Identify default VPC
aws ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --query 'Vpcs[].VpcId' \
  --region us-east-1

# Then detach/delete IGW, subnets, route tables, endpoints as needed before deleting the VPC
```

#### 6) Install Local Developer Tools

**AWS CLI v2:**

```bash
# macOS
brew install awscli

# Linux
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install
```

**Configure AWS SSO:**

```bash
aws configure sso
# SSO Start URL: from IAM Identity Center
# SSO Region: us-east-1
# Profile Name: my-project

aws sso login --profile my-project
aws sts get-caller-identity --profile my-project
```

**Terraform via tfenv:**

```bash
brew install tfenv  # or follow tfenv install instructions
tfenv install 1.7.0
tfenv use 1.7.0
echo "1.7.0" > .terraform-version
```

**Docker:**

- macOS: Install Docker Desktop
- Linux: `sudo apt-get install -y docker.io && sudo usermod -aG docker "$USER"`

**Session Manager Plugin:**

```bash
# macOS
brew install --cask session-manager-plugin

# Verify
session-manager-plugin --version
```

#### 7) Domain & DNS Setup

- Register domain (Route 53 Registrar or external)
- Create Public Hosted Zone in Route 53 if registrar is external
- Update nameservers at the registrar with Route 53 NS records
- Wait for DNS propagation (2–48 hours)

Verify: `nslookup -type=NS yourdomain.com`

#### 8) Infrastructure Repository Setup

```bash
# Initialize infra repo locally
mkdir -p ~/Projects/infrastructure-core && cd ~/Projects/infrastructure-core
git init

# Create structure
mkdir -p terraform/{bootstrap,modules,environments}
mkdir -p terraform/modules/{networking,security,compute,database}
mkdir -p terraform/environments/{dev,prod}

# .gitignore
cat > .gitignore << 'EOF'
.DS_Store
.terraform/
.terraform.lock.hcl
*.tfstate
*.tfstate.*
*.tfvars
!*.tfvars.example
EOF
```

Push to GitHub (Private repo) and configure branch protection on `main`.

#### 9) Bootstrap Terraform State

Create `terraform/bootstrap/main.tf`:

```hcl
provider "aws" {
  region = "us-east-1"
}

# S3 Bucket for Remote State
resource "aws_s3_bucket" "terraform_state" {
  bucket = "infrastructure-core-state-YOUR-ACCOUNT-ID"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "enabled" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "default" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket                  = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "enforce_tls" {
  bucket = aws_s3_bucket.terraform_state.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid       = "DenyRequestsWithoutTLS",
      Effect    = "Deny",
      Principal = "*",
      Action    = "s3:*",
      Resource  = [
        aws_s3_bucket.terraform_state.arn,
        "${aws_s3_bucket.terraform_state.arn}/*"
      ],
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

resource "aws_dynamodb_table" "terraform_locks" {
  name         = "terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
```

Deploy bootstrap:

```bash
cd terraform/bootstrap
terraform init
terraform apply
```

#### 10) Configure Dev Backend

Create `terraform/environments/dev/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.7.0"

  backend "s3" {
    bucket         = "infrastructure-core-state-YOUR-ACCOUNT-ID"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

Initialize:

```bash
cd terraform/environments/dev
terraform init
```

### Acceptance Criteria

- [ ] Root user MFA enabled; root has zero access keys
- [ ] IAM Identity Center (SSO) enabled with `Admins` group
- [ ] `aws sso login --profile my-project` works
- [ ] CloudWatch billing alarm active and AWS Budgets created
- [ ] GuardDuty, Security Hub, and Access Analyzer enabled
- [ ] Default VPC deleted in target region
- [ ] Local tools installed: AWS CLI v2, Terraform 1.7.0, Docker, Session Manager plugin
- [ ] Domain purchased and NS records configured
- [ ] `infrastructure-core` repo created with Terraform skeleton
- [ ] Terraform state bucket (S3) and lock table (DynamoDB) created
- [ ] `terraform init` in `environments/dev` uses the S3/DynamoDB backend

### Estimated Duration: 1–2 days

---

## Story 1.2: Pipeline First - GitHub Actions Setup

As a DevOps Engineer
I want a working deployment pipeline before building complex infrastructure
So that we validate the CI/CD path works on Day 1

### Technical Requirements

- Simple "Hello World" Express.js app in `apps/hello-world/`
- GitHub Actions workflow: lint, test, build
- OIDC provider for GitHub Actions (no long-lived credentials)
- IAM role with web identity trust policy scoped to specific repo
- Workflow validates on every push to `main`

### Implementation Details

#### 1. Create Hello World App

```typescript
// apps/hello-world/src/main.ts
import express from "express";

const app = express();
const PORT = process.env.PORT || 3000;

app.get("/health", (req, res) => {
  res.status(200).json({ status: "ok", service: "hello-world" });
});

app.get("/", (req, res) => {
  res.status(200).json({
    message: "Hello from ECS!",
    version: process.env.APP_VERSION || "local",
    timestamp: new Date().toISOString(),
  });
});

app.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});
```

#### 2. GitHub Actions Workflow (Initial)

Create `.github/workflows/ci.yml`:

```yaml
name: CI - Validate Build
on:
  push:
    branches: [main, develop]
  pull_request:

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: "22"
          cache: "npm"

      - name: Install dependencies
        run: npm ci

      - name: Lint
        run: npm run lint

      - name: Build
        run: npm run build
```

#### 3. Configure OIDC Provider (Terraform)

Create `terraform/modules/cicd/github-oidc.tf`:

```hcl
variable "project" { type = string }
variable "environment" { type = string }
variable "github_org" { type = string }
variable "github_repo" { type = string }

# OIDC Provider for GitHub Actions
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd"
  ]

  tags = { Name = "github-actions-oidc" }
}

# IAM Role for GitHub Actions
resource "aws_iam_role" "github_actions" {
  name = "${var.project}-${var.environment}-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:*"
        }
      }
    }]
  })

  tags = { Environment = var.environment }
}

# IAM Policy for CI/CD operations
resource "aws_iam_role_policy" "github_actions" {
  name = "cicd-permissions"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAccess"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages"
        ]
        Resource = "*"
      },
      {
        Sid    = "ECSDeployment"
        Effect = "Allow"
        Action = [
          "ecs:UpdateService",
          "ecs:DescribeServices",
          "ecs:RegisterTaskDefinition",
          "ecs:DescribeTaskDefinition",
          "ecs:RunTask",
          "ecs:DescribeTasks",
          "ecs:StopTask"
        ]
        Resource = "*"
      },
      {
        Sid    = "PassRoleForECS"
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = [
          "arn:aws:iam::*:role/${var.project}-${var.environment}-execution-role",
          "arn:aws:iam::*:role/${var.project}-${var.environment}-task-role"
        ]
      }
    ]
  })
}

output "github_actions_role_arn" {
  value       = aws_iam_role.github_actions.arn
  description = "ARN of the IAM role for GitHub Actions"
}
```

#### 4. Configure GitHub Secrets

Add these secrets to your GitHub repository (Settings → Secrets and variables → Actions):

| Secret Name             | Value                                                        | Description                              |
| ----------------------- | ------------------------------------------------------------ | ---------------------------------------- |
| `AWS_ROLE_ARN`          | `arn:aws:iam::ACCOUNT_ID:role/myapp-dev-github-actions-role` | From Terraform output                    |
| `AWS_REGION`            | `us-east-1`                                                  | Your deployment region                   |
| `ECR_REPOSITORY`        | `ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/myapp/auth-api`  | From ECR setup                           |
| `ECS_CLUSTER`           | `myapp-dev-cluster`                                          | From ECS setup                           |
| `ECS_SERVICE`           | `myapp-dev-service`                                          | From ECS setup                           |
| `PRIVATE_SUBNET_ID`     | `subnet-xxxxx`                                               | A private app subnet for migration tasks |
| `APP_SECURITY_GROUP_ID` | `sg-xxxxx`                                                   | App security group (has DB access)       |

#### 5. Test OIDC Connection

Create a test workflow `.github/workflows/test-oidc.yml`:

```yaml
name: Test OIDC
on: workflow_dispatch

jobs:
  test:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    steps:
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ secrets.AWS_REGION }}

      - name: Verify AWS identity
        run: aws sts get-caller-identity
```

### Acceptance Criteria

- [ ] Hello World app created with `/health` and `/` endpoints
- [ ] GitHub Actions workflow runs successfully on push
- [ ] OIDC provider configured in AWS
- [ ] IAM role created for GitHub Actions with ECR/ECS permissions
- [ ] GitHub secrets configured
- [ ] Workflow can assume AWS role (test with `aws sts get-caller-identity`)

### Estimated Duration: 1 day

---

## Story 1.2.5: Local Development Environment

As a Developer
I want to run the full application stack locally
So that I can develop and test without deploying to AWS

### Technical Requirements

- Docker Compose for local services (PostgreSQL, Redis when needed)
- Environment variable management (`.env.local`, `.env.example`)
- Hot-reload development server (tsx watch)
- Local database seeding/migrations
- Consistent Node.js version (via `.nvmrc` or `package.json` engines)

### Implementation Details

**1. Docker Compose for Local Services**

Create `docker-compose.local.yml` at the repository root:

```yaml
version: "3.8"

services:
  postgres:
    image: postgres:16-alpine
    container_name: local-postgres
    ports:
      - "5432:5432"
    environment:
      POSTGRES_USER: localdev
      POSTGRES_PASSWORD: localdev
      POSTGRES_DB: app_dev
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U localdev -d app_dev"]
      interval: 5s
      timeout: 5s
      retries: 5

  # Uncomment when VALUE_EPIC_3 introduces Redis
  # redis:
  #   image: redis:7-alpine
  #   container_name: local-redis
  #   ports:
  #     - "6379:6379"

volumes:
  postgres_data:
```

**2. Environment Configuration**

Create `.env.example` (committed to repo):

```bash
# Application
NODE_ENV=development
PORT=3000
LOG_LEVEL=debug

# Database (local Docker)
DATABASE_HOST=localhost
DATABASE_PORT=5432
DATABASE_USER=localdev
DATABASE_PASSWORD=localdev
DATABASE_NAME=app_dev
DATABASE_URL=postgresql://localdev:localdev@localhost:5432/app_dev

# Auth (use different secrets in production)
JWT_SECRET=local-dev-secret-change-in-production
JWT_EXPIRES_IN=1h
```

Engineers copy this to `.env.local` (gitignored) and customize as needed.

**3. Package.json Scripts**

Add to root `package.json`:

```json
{
  "scripts": {
    "dev": "tsx watch apps/auth-api/src/main.ts",
    "dev:docker": "docker-compose -f docker-compose.local.yml up -d",
    "dev:docker:down": "docker-compose -f docker-compose.local.yml down",
    "dev:docker:logs": "docker-compose -f docker-compose.local.yml logs -f",
    "dev:db:migrate": "npm run migration:run",
    "dev:db:seed": "tsx scripts/seed-local.ts",
    "dev:setup": "npm run dev:docker && sleep 3 && npm run dev:db:migrate"
  }
}
```

**4. Node.js Version**

Create `.nvmrc` at repo root:

```
22
```

**5. Update .gitignore**

Ensure these are ignored:

```gitignore
# Local environment
.env.local
.env.*.local

# Docker volumes (if using bind mounts)
postgres_data/
```

**6. README - Getting Started Section**

Add to project README:

````markdown
## Local Development

### Prerequisites

- Node.js 22+ (use `nvm install` to match `.nvmrc`)
- Docker and Docker Compose
- npm 10+

### First-Time Setup

1. Clone the repository
2. Copy environment file: `cp .env.example .env.local`
3. Install dependencies: `npm install`
4. Start local services and run migrations: `npm run dev:setup`
5. Start the development server: `npm run dev`

### Daily Development

```bash
npm run dev:docker   # Start PostgreSQL (if not running)
npm run dev          # Start API with hot-reload
```
````

### Useful Commands

| Command                   | Description               |
| ------------------------- | ------------------------- |
| `npm run dev`             | Start API with hot-reload |
| `npm run dev:docker`      | Start local PostgreSQL    |
| `npm run dev:docker:down` | Stop local PostgreSQL     |
| `npm run dev:db:migrate`  | Run database migrations   |
| `npm run build`           | Build for production      |
| `npm run lint`            | Run ESLint                |
| `npm test`                | Run tests                 |

````

### Acceptance Criteria

- [ ] `docker-compose.local.yml` created with PostgreSQL service
- [ ] `.env.example` documents all required environment variables
- [ ] `.env.local` is gitignored
- [ ] `npm run dev:setup` starts PostgreSQL and runs migrations
- [ ] `npm run dev` starts the API with hot-reload
- [ ] `.nvmrc` specifies Node.js 22
- [ ] README includes "Local Development" getting started guide

### Estimated Duration: 0.5 days

---

## Story 1.3: Containerization - Docker + ECR Push

As a Developer
I want to build production-ready Docker images and push to ECR
So that I can deploy containers to ECS

### Technical Requirements

- Multi-stage Dockerfile with non-root user
- Base image: `node:22-slim`
- ECR repository with encryption, scan on push, immutability
- GitHub Actions workflow extended to build and push images
- Image tagged with Git SHA for traceability

### Implementation Details

#### 1. Create .dockerignore

```gitignore
# dependencies
node_modules

# vcs
.git

# env & secrets
.env
.env.*

# build outputs
**/dist
**/.tsbuildinfo

# misc
.DS_Store
npm-debug.log*
```

#### 2. Multi-Stage Dockerfile

Create `Dockerfile` at repository root:

```dockerfile
# Stage 1: Builder
FROM node:22-slim AS builder
WORKDIR /app

# Install dependencies
COPY package*.json ./
RUN npm ci

# Copy source (limit to relevant dirs for smaller context)
COPY apps/auth-api ./apps/auth-api
COPY packages/core-utils ./packages/core-utils
COPY tsconfig*.json ./

# Build all (composite projects)
RUN npm run build

# Stage 2: Runner
FROM node:22-slim AS runner
WORKDIR /app
ENV NODE_ENV=production

# Create non-root user
RUN groupadd -r appuser && useradd -r -g appuser appuser

# Bring compiled outputs and manifests for runtime packages
COPY --from=builder /app/apps/auth-api/dist ./apps/auth-api/dist
COPY --from=builder /app/apps/auth-api/package.json ./apps/auth-api/package.json
COPY --from=builder /app/packages/core-utils/dist ./packages/core-utils/dist
COPY --from=builder /app/packages/core-utils/package.json ./packages/core-utils/package.json

# Copy the pruned node_modules (contains only prod deps)
COPY --from=builder /app/node_modules ./node_modules

# Switch to non-root user
USER appuser

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "require('http').get('http://localhost:3000/health', (r) => process.exit(r.statusCode === 200 ? 0 : 1))"

CMD ["node", "apps/auth-api/dist/main.js"]
```

#### 3. ECR Repository (Terraform)

Create `terraform/modules/ecr/main.tf`:

```hcl
variable "project" { type = string }
variable "environment" { type = string }
variable "repository_names" { type = list(string) }

resource "aws_ecr_repository" "main" {
  for_each = toset(var.repository_names)

  name                 = "${var.project}/${each.value}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name        = "${var.project}-${each.value}"
    Environment = var.environment
  }
}

resource "aws_ecr_lifecycle_policy" "main" {
  for_each   = toset(var.repository_names)
  repository = aws_ecr_repository.main[each.key].name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

output "repository_urls" {
  value = { for k, v in aws_ecr_repository.main : k => v.repository_url }
}
```

#### 4. GitHub Actions - Build & Push Workflow

Create `.github/workflows/build-push.yml`:

```yaml
name: Build and Push

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

env:
  AWS_REGION: us-east-1

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read

    outputs:
      image: ${{ steps.build-image.outputs.image }}
      image-tag: ${{ steps.build-image.outputs.image-tag }}

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build, tag, and push image
        id: build-image
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          ECR_REPOSITORY: ${{ secrets.ECR_REPOSITORY }}
          IMAGE_TAG: ${{ github.sha }}
        run: |
          # Build image
          docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG .

          # Push image
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG

          # Tag as latest
          docker tag $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG $ECR_REGISTRY/$ECR_REPOSITORY:latest
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:latest

          # Output for downstream jobs
          echo "image=$ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG" >> $GITHUB_OUTPUT
          echo "image-tag=$IMAGE_TAG" >> $GITHUB_OUTPUT
```

#### 5. Verify Build

```bash
# Build and check size
docker build -t my-app:optimized .
docker images | grep my-app

# Check for TS files (should be 0)
docker run --rm my-app:optimized sh -c 'find . -name "*.ts" | wc -l'

# Verify non-root user
docker run --rm my-app:optimized whoami  # Should output: appuser

# Run the app
docker run --rm -p 3000:3000 my-app:optimized
curl http://localhost:3000/health
```

### Acceptance Criteria

- [ ] `.dockerignore` excludes `node_modules` and `.git`
- [ ] Multi-stage Dockerfile builds successfully
- [ ] Final image size is < 200MB
- [ ] No `*.ts` files in final image
- [ ] Non-root user (`appuser`) configured in container
- [ ] ECR repository created with encryption and scan-on-push enabled
- [ ] GitHub Actions pushes image to ECR
- [ ] Image tagged with Git SHA and `latest`

### Estimated Duration: 1–2 days

---

## Story 1.4: Infrastructure - VPC & ECS Cluster

As a Network Engineer
I want a basic network and compute foundation
So that I can deploy containers to a private subnet

### Technical Requirements

- VPC with dual-mode NAT Gateway for private egress
- 6 subnets across 2 AZs: 2 public (ALB), 2 private app (ECS), 2 private DB
- Security Groups: ALB (80/443 from internet), App (3000 from ALB)
- ECS Cluster (Fargate-only) with Container Insights enabled
- IAM execution role and task role with minimal permissions

### Implementation Details

#### 1. VPC and Networking Module

Create `terraform/modules/networking/main.tf`:

```hcl
variable "project" { type = string }
variable "environment" { type = string }
variable "vpc_cidr" { type = string }
variable "azs" { type = list(string) }

# VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "${var.project}-${var.environment}-vpc"
    Environment = var.environment
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags = { Name = "${var.project}-${var.environment}-igw" }
}

# Public Subnets (ALB)
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project}-${var.environment}-public-${count.index + 1}"
    Tier = "Public"
  }
}

# Private Subnets (App)
resource "aws_subnet" "private_app" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 2)
  availability_zone = var.azs[count.index]

  tags = {
    Name = "${var.project}-${var.environment}-private-app-${count.index + 1}"
    Tier = "PrivateApp"
  }
}

# Private Subnets (Database)
resource "aws_subnet" "private_db" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 4)
  availability_zone = var.azs[count.index]

  tags = {
    Name = "${var.project}-${var.environment}-private-db-${count.index + 1}"
    Tier = "PrivateDB"
  }
}

# NAT Gateway (single for dev, multi-AZ for prod)
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.project}-${var.environment}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${var.project}-${var.environment}-nat" }
}

# Route Tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project}-${var.environment}-public-rt" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${var.project}-${var.environment}-private-rt" }
}

# Database Route Table (Isolated - No Internet Access)
resource "aws_route_table" "database" {
  vpc_id = aws_vpc.main.id
  # No route to internet - only implicit local VPC route
  tags = { Name = "${var.project}-${var.environment}-db-rt" }
}

# Route Table Associations
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_app" {
  count          = 2
  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_db" {
  count          = 2
  subnet_id      = aws_subnet.private_db[count.index].id
  route_table_id = aws_route_table.database.id
}
```

#### 2. Security Groups

Add to `terraform/modules/networking/security-groups.tf`:

```hcl
# ALB Security Group
resource "aws_security_group" "alb" {
  name        = "${var.project}-${var.environment}-alb-sg"
  description = "Allow HTTP/HTTPS from internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-${var.environment}-alb-sg" }
}

# App Security Group
resource "aws_security_group" "app" {
  name        = "${var.project}-${var.environment}-app-sg"
  description = "Allow traffic from ALB only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP from ALB"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-${var.environment}-app-sg" }
}

# Database Security Group
resource "aws_security_group" "db" {
  name        = "${var.project}-${var.environment}-db-sg"
  description = "Allow traffic from app only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from App"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  # No egress - database doesn't need internet
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]  # Local VPC only
  }

  tags = { Name = "${var.project}-${var.environment}-db-sg" }
}

output "vpc_id" { value = aws_vpc.main.id }
output "public_subnet_ids" { value = aws_subnet.public[*].id }
output "private_app_subnet_ids" { value = aws_subnet.private_app[*].id }
output "private_db_subnet_ids" { value = aws_subnet.private_db[*].id }
output "sg_alb_id" { value = aws_security_group.alb.id }
output "sg_app_id" { value = aws_security_group.app.id }
output "sg_db_id" { value = aws_security_group.db.id }
```

#### 3. ECS Cluster & IAM Roles

Create `terraform/modules/compute/ecs.tf`:

```hcl
variable "project" { type = string }
variable "environment" { type = string }
variable "region" { type = string }

# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "${var.project}-${var.environment}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name        = "${var.project}-${var.environment}-cluster"
    Environment = var.environment
  }
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.project}-${var.environment}"
  retention_in_days = var.environment == "prod" ? 30 : 7

  tags = { Environment = var.environment }
}

# Task Execution Role (pulls images, writes logs)
resource "aws_iam_role" "execution_role" {
  name = "${var.project}-${var.environment}-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = { Environment = var.environment }
}

resource "aws_iam_role_policy_attachment" "execution_role_policy" {
  role       = aws_iam_role.execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Task Role (application-level AWS access)
resource "aws_iam_role" "task_role" {
  name = "${var.project}-${var.environment}-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = { Environment = var.environment }
}

# ECS Exec permissions (for debugging)
resource "aws_iam_role_policy" "task_role_ecs_exec" {
  name = "ecs-exec"
  role = aws_iam_role.task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ]
      Resource = "*"
    }]
  })
}

output "cluster_id" { value = aws_ecs_cluster.main.id }
output "cluster_name" { value = aws_ecs_cluster.main.name }
output "execution_role_arn" { value = aws_iam_role.execution_role.arn }
output "task_role_arn" { value = aws_iam_role.task_role.arn }
output "log_group_name" { value = aws_cloudwatch_log_group.ecs.name }
```

### Acceptance Criteria

- [ ] VPC created with CIDR `10.0.0.0/16` (or configured value)
- [ ] 6 subnets created across 2 AZs (2 public, 2 private-app, 2 private-db)
- [ ] Internet Gateway attached to VPC
- [ ] NAT Gateway in public subnet with Elastic IP
- [ ] Route tables configured: public → IGW, private-app → NAT, private-db → isolated
- [ ] Security groups created with strict rules (ALB → App → DB chain)
- [ ] ECS Cluster created with Container Insights enabled
- [ ] Task Execution Role has ECR pull and CloudWatch logs permissions
- [ ] Task Role has ECS Exec permissions for debugging

### Estimated Duration: 2–3 days

---

## Story 1.5: The Connection - Deploy Hello World to ECS

As a Platform Engineer
I want to deploy the Hello World app to ECS and access it via HTTPS
So that I prove the entire deployment path works end-to-end

### Technical Requirements

- Application Load Balancer (Internet-facing) in public subnets
- HTTP (80) → HTTPS (443) redirect
- HTTPS listener with ACM certificate
- ECS Fargate service with 2 tasks (minimum)
- Health checks configured on `/health` endpoint
- Service accessible via `https://api.yourdomain.com`

### Implementation Details

#### 1. ACM Certificate

Create `terraform/modules/compute/acm.tf`:

```hcl
variable "domain_name" { type = string }
variable "route53_zone_id" { type = string }

resource "aws_acm_certificate" "main" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  subject_alternative_names = [
    "*.${var.domain_name}"
  ]

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name        = "${var.project}-${var.environment}-cert"
    Environment = var.environment
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = var.route53_zone_id
}

resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

output "certificate_arn" { value = aws_acm_certificate.main.arn }
```

#### 2. Application Load Balancer

Create `terraform/modules/compute/alb.tf`:

```hcl
variable "project" { type = string }
variable "environment" { type = string }
variable "alb_security_group_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "vpc_id" { type = string }
variable "acm_certificate_arn" { type = string }

resource "aws_lb" "main" {
  name               = "${var.project}-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = var.environment == "prod" ? true : false

  tags = {
    Name        = "${var.project}-${var.environment}-alb"
    Environment = var.environment
  }
}

# HTTP Redirect Listener (80 → 443)
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# HTTPS Listener
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "404: Not Found"
      status_code  = "404"
    }
  }
}

# Target Group for Hello World
resource "aws_lb_target_group" "hello_world" {
  name        = "${var.project}-${var.environment}-hello-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    path                = "/health"
    matcher             = "200"
  }

  tags = { Environment = var.environment }
}

# Listener Rule for Hello World
resource "aws_lb_listener_rule" "hello_world" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.hello_world.arn
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }
}

# DNS Record
resource "aws_route53_record" "api" {
  zone_id = var.route53_zone_id
  name    = "api.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

output "alb_arn" { value = aws_lb.main.arn }
output "alb_dns_name" { value = aws_lb.main.dns_name }
output "target_group_arn" { value = aws_lb_target_group.hello_world.arn }
```

#### 3. ECS Service & Task Definition

Add to `terraform/modules/compute/ecs-service.tf`:

```hcl
resource "aws_ecs_task_definition" "hello_world" {
  family                   = "${var.project}-${var.environment}-hello-world"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution_role.arn
  task_role_arn            = aws_iam_role.task_role.arn

  container_definitions = jsonencode([{
    name      = "hello-world"
    image     = "${var.ecr_repository_url}:latest"
    essential = true

    portMappings = [{
      containerPort = 3000
      protocol      = "tcp"
    }]

    healthCheck = {
      command     = ["CMD-SHELL", "curl -f http://localhost:3000/health || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }

    environment = [
      { name = "NODE_ENV", value = "production" },
      { name = "PORT", value = "3000" }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "hello-world"
      }
    }
  }])
}

resource "aws_ecs_service" "hello_world" {
  name            = "hello-world"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.hello_world.arn
  desired_count   = 2
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_app_subnet_ids
    security_groups  = [var.sg_app_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.hello_world.arn
    container_name   = "hello-world"
    container_port   = 3000
  }

  # Enable ECS Exec for debugging
  enable_execute_command = true

  depends_on = [aws_lb_listener.https]
}
```

#### 4. GitHub Actions Deploy Workflow

Create `.github/workflows/deploy.yml`:

```yaml
name: Deploy

on:
  push:
    branches: [main]

env:
  AWS_REGION: us-east-1

jobs:
  build:
    # ... (from Story 1.3)
    outputs:
      image: ${{ steps.build-image.outputs.image }}

  deploy-dev:
    needs: build
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    environment: dev

    steps:
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Deploy to ECS
        run: |
          aws ecs update-service \
            --cluster ${{ secrets.ECS_CLUSTER }} \
            --service ${{ secrets.ECS_SERVICE }} \
            --force-new-deployment

      - name: Wait for service stability
        run: |
          aws ecs wait services-stable \
            --cluster ${{ secrets.ECS_CLUSTER }} \
            --services ${{ secrets.ECS_SERVICE }}

          echo "✅ Deployment complete!"

  deploy-prod:
    needs: deploy-dev
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    environment: production  # Requires approval

    steps:
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Deploy to ECS
        run: |
          aws ecs update-service \
            --cluster ${{ secrets.ECS_CLUSTER }} \
            --service ${{ secrets.ECS_SERVICE }} \
            --force-new-deployment

      - name: Wait for service stability
        run: |
          aws ecs wait services-stable \
            --cluster ${{ secrets.ECS_CLUSTER }} \
            --services ${{ secrets.ECS_SERVICE }}

          echo "✅ Production deployment complete!"
```

### Acceptance Criteria

- [ ] ACM certificate created and validated via DNS
- [ ] ALB created in public subnets
- [ ] HTTP (80) redirects to HTTPS (443)
- [ ] HTTPS listener uses ACM certificate with TLS 1.3 policy
- [ ] Target group health checks pass on `/health`
- [ ] ECS service running with 2 healthy tasks
- [ ] DNS record points `api.yourdomain.com` to ALB
- [ ] `curl https://api.yourdomain.com/` returns Hello World response
- [ ] `curl https://api.yourdomain.com/health` returns 200 OK
- [ ] GitHub Actions deploys to dev automatically, prod requires approval

### Estimated Duration: 2–3 days

---

## Outcome

**You are now live.** The "Walking Skeleton" is deployed:

- ✅ Secure AWS account with auditing enabled
- ✅ Working CI/CD pipeline (GitHub Actions → ECR → ECS)
- ✅ Containerized application running in production
- ✅ HTTPS endpoint accessible to the internet
- ✅ Infrastructure as Code (100% Terraform)

**Next Step:** The Business Team can now start coding real features (Auth, CRUD) while the infrastructure continues to evolve.

**Total Duration:** 7–10 days

**Risk Reduction:** Integration failures are discovered on Day 5, not Day 30.
````
