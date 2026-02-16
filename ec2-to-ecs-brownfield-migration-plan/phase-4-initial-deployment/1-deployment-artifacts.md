# Activity 1: Deployment Artifacts (ECR & Images)

**Goal:** Manual validation of the containerization process: Create the ECR repository and push the first Docker image to prove the artifact build pipeline works.

## Context & Themes

Before automating deployments, we must verify that the "golden path" (build -> push -> store) is functional. This isolates build issues from deployment issues.

**Key Themes:**

- **Build Verification:** Proving the Dockerfile works.
- **Pipeline Validation:** Ensuring the push path is clear.
- **Artifact Availability:** Making sure the image is ready for deployment.

### Prerequisites

- [ ] Services Repository Setup completed.
- [ ] Docker installed locally.
- [ ] Access to AWS ECR commands.

## Feature 1: Container Image & ECR

**Business Value:** Makes application code available for deployment while validating containerization work functions correctly. Image push to ECR (15-30 minutes first time) confirms Dockerfile builds successfully and authentication works, catching 50% of deployment blockers early. Local build validation ensures container starts and health checks pass before deploying to production, preventing failed deployments that block other work. Required prerequisite for creating ECS services.

### Story 1.1: Provision ECR Repository

- **Title:** Provision ECR Repository for Container Images
- **Persona:** As a **DevOps engineer**, I need a secure container registry so that I can store and deploy Docker images to ECS.

**Business Value:** Provides secure, managed Docker registry with encryption, vulnerability scanning, and lifecycle policies. ECR integration with AWS services (ECS, Lambda) simplifies deployments and reduces costs vs external registries.

- **Requirements:**
  - ECR repository with encryption enabled
  - Scan on push for vulnerabilities
  - Image tag immutability (prevent overwriting tags)
  - Lifecycle policy to remove old images
  - Repository per service/application

- **Implementation Details:**

  **Option A: Terraform (Recommended)**

  Create `terraform/modules/ecr/main.tf`:

  ```hcl
  resource "aws_ecr_repository" "main" {
    name                 = var.repository_name
    image_tag_mutability = "IMMUTABLE"

    image_scanning_configuration {
      scan_on_push = true
    }

    encryption_configuration {
      encryption_type = "AES256"
    }
  }

  resource "aws_ecr_lifecycle_policy" "main" {
    repository = aws_ecr_repository.main.name

    policy = jsonencode({
      rules = [
        {
          rulePriority = 1
          description  = "Keep last 30 images"
          selection = {
            tagStatus   = "any"
            countType   = "imageCountMoreThan"
            countNumber = 30
          }
          action = { type = "expire" }
        }
      ]
    })
  }
  ```

  **Option B: AWS CLI (Quick Start)**

  ```bash
  aws ecr create-repository \
    --repository-name legacy-migration/auth-api \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 \
    --region us-east-1
  ```

- **Acceptance Criteria:**
  - ✅ ECR repository created
  - ✅ Scan on push enabled
  - ✅ Lifecycle policy configured

### Story 2.1: Push Initial Image to ECR

- **Title:** Seed ECR Repository with Application Image
- **Persona:** As a **Developer**, I want to push my container image to ECR so that ECS can pull it when creating tasks.

**Business Value:** Validates complete build-to-deploy pipeline works before investing time in ECS configuration. Pushing image to ECR (15-30 minutes) confirms Docker build, authentication, and registry access work correctly, catching architecture mismatches (arm64 vs amd64) that cause 20% of deployment failures. Testing image locally first prevents deploying broken containers that fail health checks, which wastes 1-2 hours rolling back. Essential prerequisite for Phase 4 deployment steps.

- **Requirements:**
  - Docker image built and tested locally
  - Image pushed to correct ECR repository
  - Image available for ECS to pull

- **Implementation Details:**
  - **Prerequisites:**
    - Docker installed locally
    - AWS CLI configured
    - Application Dockerfile exists (from Phase 2)
    - ECR repository created (from Phase 3)

  - **Step-by-Step Process:**

    ```bash
    # 1. Set variables (adjust for your environment)
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    AWS_REGION="us-east-1"  # or your region
    ECR_REPO="legacy-migration/auth-api"  # your ECR repo path
    APP_NAME="auth-api"  # your app name

    # 2. Login to ECR
    aws ecr get-login-password --region $AWS_REGION | \
      docker login --username AWS --password-stdin \
      $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

    # 3. Build the Docker image (from your app directory)
    cd ~/Desktop/projects-working/scale.auth-api  # adjust path
    docker build --platform linux/amd64 -t $APP_NAME .

    # 4. Tag the image for ECR
    docker tag $APP_NAME:latest \
      $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:latest

    # 5. Push to ECR
    docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:latest

    # 6. Verify image is in ECR
    aws ecr describe-images --repository-name $ECR_REPO
    ```

  - **For Multiple Services:**

    ```bash
    # Repeat for each service
    for SERVICE in auth-api test-api-1 test-api-2; do
      echo "Building and pushing $SERVICE..."
      cd ~/Desktop/projects-working/scale.$SERVICE

      docker build --platform linux/amd64 -t $SERVICE .

      docker tag $SERVICE:latest \
        $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/legacy-migration/$SERVICE:latest

      docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/legacy-migration/$SERVICE:latest
    done
    ```

  - **Common Issues:**

    | Issue                                          | Cause                                        | Fix                                      |
    | ---------------------------------------------- | -------------------------------------------- | ---------------------------------------- |
    | "no basic auth credentials"                    | Not logged into ECR                          | Run `aws ecr get-login-password` command |
    | "repository does not exist"                    | ECR repo not created                         | Create repo in ECR first                 |
    | "denied: Your authorization token has expired" | ECR login expired (12 hours)                 | Run login command again                  |
    | Image shows as "linux/arm64"                   | Built on Apple Silicon without platform flag | Add `--platform linux/amd64`             |

  - **Image Tagging Strategy:**

    For initial deployment:
    - Use `latest` tag for simplicity
    - Later (in CI/CD): use git SHA for traceability
      ```bash
      docker tag $APP_NAME:latest \
        $ECR_REGISTRY/$ECR_REPO:$(git rev-parse --short HEAD)
      ```

- **Acceptance Criteria:**
  - ✅ Image built successfully
  - ✅ Image pushed to ECR
  - ✅ `aws ecr describe-images` shows the image
  - ✅ Image platform is `linux/amd64`

---

## Feature 3: Task Definition

**Business Value:** Creates reusable deployment blueprint reducing subsequent deployments from 2-3 hours to 15-30 minutes via copy-paste. Task Definition (30-60 minutes first time) codifies all container configuration (resources, secrets, logging) enabling consistent deployments and preventing configuration drift. Right-sized resource allocation (start 0.5 vCPU/1GB) prevents over-provisioning waste ($20-40/month per service) while ensuring performance. Secrets integration eliminates hardcoded credentials security risk. Template approach enables deploying 10 services in parallel after first one succeeds.

### Story 3.1: Create Task Definition

- **Title:** Define Application Blueprint (Task Definition)
- **Persona:** As a **Developer**, I want to define my application's resource requirements and configuration so that Fargate knows how to run my container.

**Business Value:** Standardizes deployment configuration enabling fast replication across multiple services. Task Definition (30-60 minutes first time, 10 minutes for subsequent services via copy) prevents configuration errors through consistent templating. Proper resource allocation (start conservative 0.5 vCPU/1GB, scale up as needed) optimizes costs saving $20-40/month per over-provisioned service. Secrets Manager integration eliminates hardcoded credentials (required for SOC 2). Creates reusable pattern enabling parallel team deployment once template proven.

- **Requirements:**
  - Specifies CPU, memory, and container image
  - Configures environment variables and secrets
  - Sets up logging to CloudWatch
  - Defines health check

- **Implementation Details:**
  - **Naming Convention (Important!):**

    **Best Practice:** Keep Task Definition Family, Container Name, and Service Name identical for simplicity.

    | Component                          | Name         | Example      |
    | ---------------------------------- | ------------ | ------------ |
    | Task Definition Family             | `[app-name]` | `test-api-1` |
    | Container Name (inside task def)   | `[app-name]` | `test-api-1` |
    | ECS Service (created in Feature 4) | `[app-name]` | `test-api-1` |

    **Why?** This makes debugging easier—when you see `test-api-1` in logs, ECS console, or CLI output, you immediately know which service/task it belongs to. AWS doesn't require these names to match, but keeping them the same eliminates confusion.

    **When to use different names?** Only if you have multiple environments (e.g., `test-api-1-staging` vs `test-api-1-production`).

  - **Task Definition Settings:**
    - Family: `[app-name]` (e.g., `test-api-1`, `auth-api`)
    - Launch Type: Fargate
    - Operating System: Linux
    - CPU Architecture: x86_64
    - Network Mode: awsvpc (required for Fargate)
  - **Task Size (Start Conservative, Scale Up if Needed):**
    | Workload | CPU | Memory | Monthly Cost (24/7) |
    |----------|-----|--------|---------------------|
    | Light | 0.25 vCPU | 0.5 GB | ~$10 |
    | Standard | 0.5 vCPU | 1 GB | ~$21 |
    | Medium | 1 vCPU | 2 GB | ~$42 |
    | Heavy | 2 vCPU | 4 GB | ~$84 |
  - **Task Execution Role:**
    - Select: `ecsTaskExecutionRole` (created in Phase 3)
  - **Task Role:**
    - Select: `[app-name]-task-role` (if app needs AWS access)
    - Leave blank if app only uses RDS/Redis (network-based access)
  - **Container Definition:**

    **Note:** The `"name"` field below should match your Task Definition Family name (e.g., `test-api-1`, `test-api-2`, `auth-api`).

    ```json
    {
      "name": "auth-api",
      "image": "123456789012.dkr.ecr.us-east-1.amazonaws.com/legacy-migration/auth-api:latest",
      "portMappings": [
        {
          "containerPort": 3000,
          "protocol": "tcp"
        }
      ],
      "essential": true,
      "environment": [
        { "name": "NODE_ENV", "value": "production" },
        { "name": "PORT", "value": "3000" },
        { "name": "LOG_LEVEL", "value": "info" }
      ],
      "secrets": [
        {
          "name": "DB_HOST",
          "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789012:secret:production/auth-api/database:host::"
        },
        {
          "name": "DB_PASSWORD",
          "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789012:secret:production/auth-api/database:password::"
        },
        {
          "name": "REDIS_URL",
          "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789012:secret:production/shared/redis:url::"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/production-cluster/auth-api",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "linuxParameters": {
        "initProcessEnabled": true
      },
      "healthCheck": {
        "command": [
          "CMD-SHELL",
          "curl -f http://localhost:3000/health || exit 1"
        ],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 60
      }
    }
    ```

  - **Port Configuration Details:**

    **Important:** Set `containerPort` to match the port your application listens on (e.g., 3000).
    - **Do NOT specify `hostPort`** - In Fargate with `awsvpc` networking, it defaults to match `containerPort`
    - Your app should listen on `0.0.0.0:3000` (not `localhost:3000`)
    - The ALB handles port translation (users hit port 443/80, ALB forwards to your container on 3000)

    **Traffic Flow:**

    ```
    User Request (https://yourapp.com)
         ↓
    ALB Listener:443 (HTTPS with SSL termination)
         ↓
    Target Group:3000 (configured to forward to port 3000)
         ↓
    Fargate Task IP:3000 (your container)
         ↓
    Your App listening on 0.0.0.0:3000
    ```

    **Common Questions:**
    - ❌ "Do I need to change my app to listen on port 80 or 443?" → No, keep it on 3000
    - ❌ "Do I need to handle SSL in my app?" → No, ALB does SSL termination
    - ✅ "My app listens on 3000" → Perfect, set `containerPort: 3000` and Target Group port to 3000

  - **Health Check Notes:**
    - `startPeriod`: Grace period for container startup (increase if app is slow to start)
    - `interval`: How often to check (30s is reasonable)
    - `retries`: Failed checks before marking unhealthy
    - Alternative: Use ALB health checks only (simpler, but less granular)
  - **Stop Timeout:**
    - Default: 30 seconds
    - Increase if app needs more time for graceful shutdown
    - Decrease for faster deployments (if app handles SIGTERM quickly)

- **Acceptance Criteria:**
  - ✅ Task Definition created and Active
  - ✅ Container image URI is correct
  - ✅ Port mapping matches application port
  - ✅ Secrets reference correct Secrets Manager ARNs
  - ✅ Log configuration points to correct log group
