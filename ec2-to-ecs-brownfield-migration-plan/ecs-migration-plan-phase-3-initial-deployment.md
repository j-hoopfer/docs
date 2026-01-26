# ECS Fargate Migration Plan - Phase 3: Initial Deployment

## Overview

This phase deploys the first application to Fargate. The pattern established here will be repeated for each subsequent application. Focus on getting one app fully working before parallelizing.

**Key Principle:** Each application gets its own Task Definition, Target Group, ECS Service, and ALB Listener Rule—but shares the VPC, ALB, ECS Cluster, and ECR namespace.

**Security Group Strategy:** Use a baseline security group for common rules (ALB access, internet egress) shared by all services. Add service-specific security groups only when needed for resource isolation (e.g., database access). See Appendix for detailed guidance.

---

## Feature 1: Application Security Groups

> **Note:** Security groups should already be created in Phase 2 (Story 2.5). This section covers verification and any per-deployment updates needed. If SGs were not pre-created, create them now following the Phase 2 pattern.

### Story 1.1: Verify Security Groups

- **Title:** Verify Baseline and Service-Specific Security Groups
- **Persona:** As a **DevOps Engineer**, I want to verify security groups are correctly configured before deploying so that the ECS service can receive traffic from the ALB.

- **Requirements:**
  - Baseline security group exists with ALB access rules
  - Service-specific security groups exist if needed (for database/resource access)
  - Outbound rule allows internet access

- **Implementation Details:**
  - **Recommended Pattern: Baseline + Service-Specific**

    Use a **baseline security group** for common rules (shared by all Fargate services) and add **service-specific security groups** only when needed.

    **Baseline Security Group** (shared by all services):
    - Name: `fargate-baseline-sg` or `fargate-common-sg`
    - Inbound: ALB SG → Port 3000 (or your app port)
    - Outbound: All traffic to 0.0.0.0/0 (for ECR, internet, etc.)
    - Attached to: ALL Fargate services

    **Service-Specific Security Groups** (optional, for resource isolation):
    - Name: `[app-name]-database-sg` (e.g., `auth-api-database-sg`)
    - Inbound: None (exists only to be referenced by RDS/ElastiCache SGs)
    - Outbound: None needed
    - Attached to: Only services that need that specific resource access

  - **Verify Baseline SG exists:**
    ```bash
    aws ec2 describe-security-groups --filters "Name=group-name,Values=fargate-baseline-sg"
    ```
  - **Verify inbound rules:**
    - Should have: ALB SG → App Port (e.g., 3000)
    - Should have: Internal ALB SG → App Port (if using Internal ALB)
  - **If Baseline SG doesn't exist:**
    - Create now:
    - Name: `fargate-baseline-sg`
    - Inbound: ALB SG on app port 3000
    - Outbound: All traffic to 0.0.0.0/0
  - **Create Service-Specific SGs (only if needed):**
    - For services needing database access: Create `[app-name]-database-sg`
    - For POC with identical services: Skip this, just use baseline
  - **Why this is better than one-per-service:**
    - ✅ Don't duplicate ALB rules across 10 different service SGs
    - ✅ Baseline changes happen in one place
    - ✅ Service-specific access is still isolated
    - ✅ Can attach multiple SGs to one task (up to 5)

- **Acceptance Criteria:**
  - ✅ Baseline security group exists with ALB access rule
  - ✅ Inbound rule references ALB security group ID (not CIDR)
  - ✅ Application port matches the port your app listens on
  - ✅ Outbound allows internet access
  - ✅ Service-specific SGs created if services need different resource access

---

### Story 1.2: Verify Database Security Group Access (If Needed)

- **Title:** Configure Service-Specific Database Access
- **Persona:** As a **DevOps Engineer**, I want to grant specific services database access without granting it to all Fargate tasks.

- **Requirements:**
  - Only services that need database access can connect
  - Follows principle of least privilege
  - Same applies to ElastiCache, OpenSearch, or any data stores

- **Implementation Details:**
  - **Pattern: Use Service-Specific Security Groups**

    Instead of allowing the baseline SG to access databases (which would grant access to ALL services), create service-specific SGs that only the services needing database access attach.

    **Example:**
    - `auth-api` needs database → attach `fargate-baseline-sg` + `auth-api-database-sg`
    - `test-api-1` doesn't need database → attach only `fargate-baseline-sg`
    - `test-api-2` doesn't need database → attach only `fargate-baseline-sg`

  - **Create Service-Specific Database SG (if service needs DB):**

    ```bash
    aws ec2 create-security-group \
      --group-name auth-api-database-sg \
      --description "Auth API database access marker" \
      --vpc-id vpc-xxxxx
    ```

    - **No inbound/outbound rules needed** - this SG is just a "marker" referenced by RDS SG

  - **Update RDS Security Group:**

    Add inbound rule to RDS SG:
    | Type | Port | Source | Description |
    |------|------|--------|-------------|
    | PostgreSQL | 5432 | `sg-xxx` (auth-api-database-sg) | Allow only auth-api |

    ```bash
    aws ec2 authorize-security-group-ingress \
      --group-id sg-rds-xxx \
      --protocol tcp --port 5432 \
      --source-group sg-auth-api-database-sg
    ```

  - **Update ElastiCache SG (if needed):**
    | Type | Port | Source | Description |
    |------|------|--------|-------------|
    | Custom TCP | 6379 | `sg-xxx` (auth-api-database-sg) | Allow Redis from auth-api |
  - **For POC with identical services:**
    - If all services need same database access: Just use baseline SG and allow it in RDS SG
    - If no services need database yet: Skip this story entirely
  - **Test connectivity (after ECS service is running):**

    ```bash
    # Exec into a running task
    aws ecs execute-command --cluster production-cluster \
      --task <task-id> --container auth-api --interactive \
      --command "/bin/sh"

    # Test database connectivity
    nc -zv <rds-endpoint> 5432
    ```

- **Acceptance Criteria:**
  - ✅ Service-specific security groups created for services needing database access
  - ✅ RDS security group has inbound rule for service-specific SG (not baseline SG)
  - ✅ ElastiCache security group has inbound rule for service-specific SG (if needed)
  - ✅ Test connection from Fargate task succeeds (verified post-deployment)
  - ✅ Services without database access cannot connect (principle of least privilege)

---

## Feature 2: Container Image & ECR

### Story 2.1: Push Initial Image to ECR

- **Title:** Seed ECR Repository with Application Image
- **Persona:** As a **Developer**, I want to push my container image to ECR so that ECS can pull it when creating tasks.

- **Requirements:**
  - Docker image built and tested locally
  - Image pushed to correct ECR repository
  - Image available for ECS to pull

- **Implementation Details:**
  - **Prerequisites:**
    - Docker installed locally
    - AWS CLI configured
    - Application Dockerfile exists (from Phase 1)
    - ECR repository created (from Phase 2)

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

### Story 3.1: Create Task Definition

- **Title:** Define Application Blueprint (Task Definition)
- **Persona:** As a **Developer**, I want to define my application's resource requirements and configuration so that Fargate knows how to run my container.

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
    - Select: `ecsTaskExecutionRole` (created in Phase 2)
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

---

## Feature 3: Target Group & Health Checks

### Story 3.1: Create Target Group

- **Title:** Create ALB Target Group for Application
- **Persona:** As a **Network Engineer**, I want a Target Group so that the ALB knows how to route traffic to my Fargate tasks and verify they're healthy.

- **Requirements:**
  - Target type must be "IP" (required for Fargate awsvpc networking)
  - Health check must pass before receiving traffic
  - Health check path must return 200 status code

- **Implementation Details:**
  - **Via AWS Console:**
    1. Go to **EC2 → Target Groups → Create target group**
    2. Choose target type: **IP addresses** ⚠️ (Critical - not "Instances")
    3. Configure:
       - Name: `auth-api-tg` (or `test-api-1-tg`, etc.)
       - Protocol: HTTP
       - Port: 3000 (your container port)
       - VPC: Select your Fargate VPC
    4. Health checks:
       - Protocol: HTTP
       - Path: `/health`
       - Port: traffic port
       - Healthy threshold: 2
       - Unhealthy threshold: 3
       - Timeout: 5 seconds
       - Interval: 30 seconds
       - Success codes: 200
    5. Click **Next**
    6. **Skip** registering targets (ECS will do this automatically)
    7. Click **Create target group**
  - **Via AWS CLI:**
    ```bash
    aws elbv2 create-target-group \
      --name auth-api-tg \
      --protocol HTTP \
      --port 3000 \
      --vpc-id vpc-xxxxx \
      --target-type ip \
      --health-check-protocol HTTP \
      --health-check-path /health \
      --health-check-interval-seconds 30 \
      --health-check-timeout-seconds 5 \
      --healthy-threshold-count 2 \
      --unhealthy-threshold-count 3 \
      --matcher HttpCode=200
    ```
  - **Target Group Settings:**
    - Name: `[app-name]-tg` (e.g., `auth-api-tg`)
    - Target Type: **IP** (Critical—not "Instance")
    - Protocol: HTTP
    - Port: **3000** (must match your container's `containerPort` - the port your app actually listens on)
    - VPC: Select Fargate VPC

    **Port Matching:** The Target Group port MUST match the `containerPort` in your Task Definition. If your app listens on port 3000, both should be 3000. The ALB listener (port 443 or 80) is separate and handles the public-facing port.

  - **Health Check Settings:**
    | Setting | Value | Notes |
    |---------|-------|-------|
    | Protocol | HTTP | |
    | Path | `/health` or `/` | Must return 200 |
    | Port | traffic-port | Uses container port |
    | Healthy threshold | 2 | Checks before healthy |
    | Unhealthy threshold | 3 | Checks before unhealthy |
    | Timeout | 5 seconds | Max wait for response |
    | Interval | 30 seconds | Time between checks |
    | Success codes | 200 | Or 200-299 |
  - **Common Health Check Issues:**
    | Symptom | Cause | Fix |
    |---------|-------|-----|
    | Always unhealthy | Wrong port | Verify container listens on specified port |
    | Always unhealthy | App binds to localhost | Change to 0.0.0.0 (Phase 1 Story 1.3) |
    | Always unhealthy | Health path returns 404 | Create /health endpoint or use / |
    | Always unhealthy | Security group blocks ALB | Add ALB SG to inbound rules |
    | Flapping healthy/unhealthy | Slow response | Increase timeout |
    | Unhealthy during deploy | Slow startup | Increase startPeriod in task def |
  - **Advanced Settings:**
    - Deregistration delay: 30 seconds (time to drain connections)
    - Stickiness: Disabled (unless required—breaks horizontal scaling)
    - Slow start: 0 seconds (or 30-60s if app needs warmup)

- **Acceptance Criteria:**
  - ✅ Target Group created with IP target type
  - ✅ Health check path returns 200
  - ✅ Protocol and port match application
  - ✅ VPC matches Fargate VPC

---

## Feature 4: ECS Service

### Story 4.1: Create ECS Service

- **Title:** Deploy Application as ECS Service
- **Persona:** As a **DevOps Engineer**, I want to create an ECS Service so that Fargate maintains the desired number of running tasks and integrates with the load balancer.

- **Requirements:**
  - Service maintains desired task count
  - Service registers tasks with Target Group
  - Service uses correct security group and subnets
  - Deployments use rolling updates
- **Implementation Details:**
  - **Via AWS Console:**
    1. Go to **ECS → Clusters → production-cluster → Services → Create**
    2. Compute options:
       - Launch type: **Fargate**
    3. Deployment configuration:
       - Application type: Service
       - Task definition: Select `auth-api` (latest revision)
       - Service name: `auth-api-service`
       - Desired tasks: 1
    4. Deployment options:
       - Deployment type: Rolling update
       - Min healthy percent: 100
       - Max percent: 200
       - **Enable deployment circuit breaker** ✅
       - **Enable rollback on failure** ✅
    5. Networking:
       - VPC: Select your Fargate VPC
       - Subnets: Select **PRIVATE subnets only** (both AZs)
       - Security group: Select `auth-api-sg`
       - Public IP: **TURNED OFF** (critical - use NAT Gateway)
    6. Load balancing:
       - Load balancer type: Application Load Balancer
       - Load balancer: Select your existing ALB
       - Listener: HTTPS:443
       - Target group: Select `auth-api-tg` (from Story 3.1)
       - Health check grace period: 60 seconds
    7. Click **Create**
  - **Verify Service Creation:**

    ```bash
    # Check service status
    aws ecs describe-services \
      --cluster production-cluster \
      --services auth-api-service \
      --query 'services[0].{Status:status,Running:runningCount,Desired:desiredCount}'

    # Check tasks are running
    aws ecs list-tasks --cluster production-cluster --service-name auth-api-service

    # Get task details
    aws ecs describe-tasks \
      --cluster production-cluster \
      --tasks <task-id-from-above> \
      --query 'tasks[0].{Status:lastStatus,Health:healthStatus}'

    # Check target health
    aws elbv2 describe-target-health --target-group-arn <target-group-arn>
    ```

  - **Service Settings:**
    - Name: `[app-name]-service` (e.g., `auth-api-service`)
    - Cluster: `production-cluster`
    - Launch Type: Fargate
    - Platform Version: LATEST (or specific version like 1.4.0)
    - Task Definition: Select from Story 2.1
    - Desired Tasks: 1 (start with 1, scale later)
  - **Deployment Configuration:**
    - Type: Rolling update
    - Minimum healthy percent: 100 (no downtime)
    - Maximum percent: 200 (allows 2x tasks during deploy)
    - **⚠️ Deployment circuit breaker: DISABLE for first deployment, then enable afterward**
      - **Why disable initially?** On first deployment with 0 running tasks, there's no "healthy" baseline
      - Circuit breaker can trigger false positives during initial spin-up
      - **Two-phase approach:**
        1. **Phase 1 (Initial Deployment):** Create service with circuit breaker **disabled**
        2. **Phase 2 (After first deployment succeeds):** Update service to **enable** circuit breaker with rollback
      - **After enabling:** Automatically rolls back if deployment fails
      - Prevents stuck deployments that would otherwise require manual intervention
  - **Network Configuration:**
    - VPC: Fargate VPC
    - Subnets: **Private subnets** (both AZs)
    - Security Group: `[app-name]-sg`
    - Auto-assign public IP: **Disabled** (tasks in private subnet use NAT)
  - **Load Balancer Configuration:**
    - Type: Application Load Balancer
    - Load Balancer: `fargate-shared-alb`
    - Container to load balance: `[app-name]:3000`
    - Target Group: `[app-name]-tg` (from Story 3.1)
    - Health check grace period: 60 seconds
      - Why: Gives container time to start before health checks fail
      - Increase for slow-starting apps
  - **Service Auto Scaling (Configure After Initial Deploy):**
    - Skip for now, add in Phase 4
  - **Service Connect (Optional):**
    - Enable if services need to call each other
    - Creates DNS name like `auth-api.production.local`

- **Acceptance Criteria:**
  - ✅ Service created and status is "Active"
  - ✅ Desired count matches running count (1/1)
  - ✅ Tasks registered as healthy in Target Group
  - ✅ No tasks stuck in PENDING or repeatedly failing
  - ✅ CloudWatch Logs show application startup logs

---

### Story 4.2: Troubleshoot Common Service Issues

- **Title:** Debug ECS Service Deployment Failures
- **Persona:** As a **DevOps Engineer**, I need to know how to troubleshoot common issues so that I can quickly resolve deployment failures.

- **Requirements:**
  - Understand common failure modes
  - Know where to look for logs and errors
  - Have systematic debugging approach

- **Implementation Details:**
  - **Tasks Stuck in PENDING:**
    | Cause | Diagnosis | Fix |
    |-------|-----------|-----|
    | No private subnet route to NAT | Check route table | Add 0.0.0.0/0 → NAT Gateway |
    | ECR pull fails (no internet) | Check NAT Gateway exists | Create NAT or use VPC Endpoints |
    | Insufficient CPU/memory quota | Check Service Quotas | Request quota increase |
    | No available IPs in subnet | Check subnet CIDR usage | Use larger subnet or different AZ |
  - **Tasks Start Then Fail Immediately:**
    | Cause | Diagnosis | Fix |
    |-------|-----------|-----|
    | Application crash | Check CloudWatch Logs | Fix application error |
    | Missing env vars | Check container logs for config errors | Add to task definition |
    | Wrong architecture | "exec format error" in logs | Rebuild with `--platform linux/amd64` |
    | Secret not found | Check task execution role | Add secretsmanager:GetSecretValue |
  - **Tasks Running But Unhealthy:**
    | Cause | Diagnosis | Fix |
    |-------|-----------|-----|
    | App binds to localhost | Check with `netstat` in container | Bind to 0.0.0.0 |
    | Wrong health check path | Test path manually | Update Target Group health check |
    | Security group blocks ALB | Check inbound rules | Add ALB SG as source |
    | App too slow to respond | Check response time | Increase health check timeout |
  - **Where to Look for Errors:**
    1. ECS Console → Service → Events tab (deployment events)
    2. ECS Console → Service → Tasks → Stopped tasks → Stopped reason
    3. CloudWatch Logs → Log group → Recent log streams
    4. EC2 Console → Target Groups → Targets tab (health status)
    5. EC2 Console → Load Balancers → Monitoring tab (5xx errors)
  - **Useful AWS CLI Commands:**

    ```bash
    # View service events
    aws ecs describe-services --cluster production-cluster --services auth-api-service \
      --query 'services[0].events[0:5]'

    # View stopped task reason
    aws ecs describe-tasks --cluster production-cluster --tasks <task-id> \
      --query 'tasks[0].stoppedReason'

    # View recent logs
    aws logs tail /ecs/production-cluster/auth-api --since 10m
    ```

- **Acceptance Criteria:**
  - ✅ Team knows where to find error information
  - ✅ Common issues documented with fixes
  - ✅ Debugging runbook available

---

## Feature 5: ALB Routing

### Story 5.1: Configure Host-Based Routing

- **Title:** Create ALB Listener Rule for Application
- **Persona:** As a **Network Engineer**, I want to configure routing rules so that requests for `auth.mysite.com` go to the auth-api service while `admin.mysite.com` goes to a different service.

- **Requirements:**
  - Each application has unique domain or path
  - ALB routes based on Host header
  - HTTPS listener handles all routing

- **Implementation Details:**
  - **Via AWS Console:**
    1. Go to **EC2 → Load Balancers → [Your ALB] → Listeners**
    2. Select **HTTPS:443** listener
    3. Click **Manage rules** (or **View/edit rules**)
    4. Click **Insert rule** (the + icon)
    5. Add condition:
       - Type: **Host header**
       - Value: `auth.mysite.com` (or your domain)
    6. Add action:
       - Type: **Forward to**
       - Target group: `auth-api-tg`
    7. Set priority:
       - Priority: **100** (increment by 10 for each service)
    8. Click **Save**
  - **Via AWS CLI:**

    ```bash
    # Get listener ARN
    LISTENER_ARN=$(aws elbv2 describe-listeners \
      --load-balancer-arn <alb-arn> \
      --query 'Listeners[?Port==`443`].ListenerArn' \
      --output text)

    # Create listener rule
    aws elbv2 create-rule \
      --listener-arn $LISTENER_ARN \
      --priority 100 \
      --conditions Field=host-header,Values=auth.mysite.com \
      --actions Type=forward,TargetGroupArn=<target-group-arn>

    # Verify rule
    aws elbv2 describe-rules --listener-arn $LISTENER_ARN
    ```

  - **Listener Rule Configuration:**
    - Listener: HTTPS:443 on `fargate-shared-alb`
    - Priority: Lower number = higher priority (start at 100, increment by 10)
  - **Condition (Host Header):**
    - Type: Host header
    - Value: `auth.mysite.com`
    - Can include wildcards: `*.api.mysite.com`
  - **Action:**
    - Type: Forward to target group
    - Target group: `auth-api-tg`
  - **Alternative: Path-Based Routing:**
    - Condition: Path pattern `/api/auth/*`
    - Useful when all apps share one domain
    - Requires app to handle path prefix
  - **Rule Priority Strategy:**
    | Priority | Host/Path | Target |
    |----------|-----------|--------|
    | 100 | auth.mysite.com | auth-api-tg |
    | 110 | admin.mysite.com | admin-tg |
    | 120 | api.mysite.com/v1/_ | api-v1-tg |
    | 200 | _.mysite.com | default-tg |
    | Default | \* | Return 404 |
  - **How It Works:**
    1. Request arrives at ALB for `auth.mysite.com`
    2. ALB evaluates rules in priority order
    3. Rule 100 matches: Host header = `auth.mysite.com`
    4. ALB forwards to `auth-api-tg`
    5. Target Group routes to healthy Fargate task
    6. Response returns through ALB to client

- **Acceptance Criteria:**
  - ✅ Listener rule created with correct priority
  - ✅ Host header condition matches application domain
  - ✅ Action forwards to correct target group
  - ✅ Request to domain returns application response (not 404)

---

### Story 5.2: Configure DNS

- **Title:** Point Domain to ALB
- **Persona:** As a **DevOps Engineer**, I want DNS configured so that users can access the application via a friendly domain name.

- **Requirements:**
  - DNS record points application domain to ALB
  - Record type appropriate for ALB (CNAME or Alias)
  - TTL allows for reasonable failover time

- **Implementation Details:**
  - **Option A: Route 53 (Recommended):**
    - Record type: A (Alias)
    - Alias target: Select ALB from dropdown
    - Why Alias: Works at zone apex (mysite.com), no extra DNS lookup
  - **Option B: External DNS (GoDaddy, Cloudflare, etc.):**
    - Record type: CNAME
    - Value: ALB DNS name (e.g., `fargate-shared-alb-123.us-east-1.elb.amazonaws.com`)
    - TTL: 300 seconds (5 minutes)
    - Note: CNAME cannot be used for zone apex
  - **For Migration (Blue/Green):**
    1. Keep old DNS pointing to EC2
    2. Add new subdomain pointing to ALB for testing (e.g., `auth-new.mysite.com`)
    3. Test thoroughly
    4. Update production DNS to point to ALB
    5. Keep EC2 running for rollback (1-2 weeks)
  - **Verify DNS Propagation:**

    ```bash
    # Check DNS resolution
    dig auth.mysite.com

    # Check HTTPS works
    curl -I https://auth.mysite.com/health

    # Check from different locations
    # Use: https://www.whatsmydns.net/
    ```

- **Acceptance Criteria:**
  - ✅ DNS record created pointing to ALB
  - ✅ `dig` or `nslookup` resolves to ALB IP
  - ✅ `https://[domain]/health` returns 200
  - ✅ HTTP redirects to HTTPS

---

## Feature 6: CI/CD Pipeline

### Story 6.1: Configure OIDC Authentication (AWS IAM Trust)

- **Title:** Set Up GitHub Actions OIDC Trust with AWS
- **Persona:** As a **Security Engineer**, I want GitHub Actions to authenticate via OIDC so that we avoid long-lived AWS access keys and follow security best practices.
- **Requirements:**
  - No IAM User access keys stored in GitHub
  - GitHub Actions can assume IAM role via OIDC
  - Role has minimal permissions for deployment
- **Implementation Details:**
  - **Step 1: Create OIDC Identity Provider in AWS**
    - AWS Console → IAM → Identity Providers → Add Provider
    - Provider Type: OpenID Connect
    - Provider URL: `https://token.actions.githubusercontent.com`
    - Audience: `sts.amazonaws.com`
    - Click "Get thumbprint" then "Add provider"
  - **Step 2: Create IAM Role for GitHub Actions**
    - Role Name: `github-deployer` (or `github-actions-ecs-deploy`)
    - Trusted Entity: Web Identity
    - Identity Provider: Select the OIDC provider created above
    - Audience: `sts.amazonaws.com`
    - **🚀 Initial Approach (Fast, Shared Role):**
      - For your first 1-3 services, use a single shared role that all repos can assume
      - This prioritizes speed over perfect security
      - **Security Trade-off:** If one repo is compromised, the attacker could access other services
      - **When to refactor:** Once you have 3+ distinct services in production (see Phase 4, Story 1.4)
    - **🔒 Production Approach (Least Privilege, Per-Service Roles):**
      - Each service gets its own dedicated IAM role (e.g., `auth-api-deployer`, `billing-api-deployer`)
      - Blast radius limited: Compromised "Recipe Blog" repo can't touch "Production Banking" database
      - Large orgs automate this with Infrastructure as Code (Terraform/CDK)
      - Covered in Phase 4, Story 1.4

  - **Step 3: Configure Trust Policy (Shared Role for Initial Deployment)**

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

    - **Trust Policy Options:**
      - Wildcard (any repo in org, main branch only): `repo:my-org/*:ref:refs/heads/main` ✅ Use this initially
      - Single repo (most secure): `repo:my-org/auth-api:*` — Use when splitting roles in Phase 4
      - Specific branch: `repo:my-org/auth-api:ref:refs/heads/main`

  - **Step 4: Attach Permissions Policies (Wildcard for Initial Deployment)**
    - **Initial Approach:** Use wildcard permissions to deploy all services
      - This allows any repo in your org to deploy any service
      - Trade-off: Speed and simplicity over perfect isolation
      - **Refactor in Phase 4:** Split into per-service policies
    - Option A: AWS Managed Policies (broader, simpler) — ⚠️ Very permissive
      - `AmazonEC2ContainerRegistryPowerUser`
      - `AmazonECS_FullAccess`
    - **Option B: Custom Wildcard Policy (Better than Option A, still permissive)** ✅ Recommended for initial deployment
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
            "Sid": "ECRPushWildcard",
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
            "Sid": "ECSDeploymentWildcard",
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
            "Sid": "PassRole",
            "Effect": "Allow",
            "Action": "iam:PassRole",
            "Resource": [
              "arn:aws:iam::123456789012:role/ecsTaskExecutionRole",
              "arn:aws:iam::123456789012:role/*-task-role"
            ]
          }
        ]
      }
      ```
    - **Note:** See Phase 4, Story 1.4 for how to split this into per-service roles with least privilege

  - **Why OIDC over Access Keys:**
    | Aspect | Access Keys | OIDC |
    |--------|-------------|------|
    | Rotation | Manual, painful | Automatic (token per run) |
    | Exposure risk | Key leak = permanent access | Token expires in minutes |
    | Audit | Hard to trace | CloudTrail shows GitHub repo/branch |
    | Setup | Easier initially | More setup, better long-term |

- **Acceptance Criteria:**
  - ✅ OIDC Identity Provider exists in IAM
  - ✅ IAM Role created with wildcard trust policy (allows all repos in org)
  - ✅ Role has ECR and ECS permissions for all services
  - ✅ No IAM User access keys in GitHub secrets
  - ✅ Team aware this is a shared role to be refactored in Phase 4

---

### Story 6.2: Configure GitHub Secrets

- **Title:** Configure Secure Credentials and Deployment Values
- **Persona:** As a **DevOps Engineer**, I want to store only true secrets in GitHub Secrets and keep configuration in version control so that deployments are secure, transparent, and easy to maintain.
- **Requirements:**
  - True secrets stored securely in GitHub Secrets
  - Configuration values in version-controlled workflow file
  - Workflow file remains reusable across projects
- **Implementation Details:**
  - **Security Best Practice: Secrets vs Configuration**

    Most deployment values are **configuration**, not **secrets**. Knowing your service is named "auth-api" doesn't help anyone hack you. Only truly sensitive values belong in GitHub Secrets.

    **The ONE True Secret:**
    - `AWS_ROLE_ARN` — Contains your AWS Account ID and IAM role name. While not a password, you generally don't want to broadcast your internal account IDs and security architecture publicly (especially if repo is public).

    **Configuration (NOT secrets — put these in workflow file):**
    - `AWS_REGION` — Just "us-east-1"
    - `ECR_REPOSITORY` — Just the repo name
    - `ECS_CLUSTER` — Just the cluster name
    - `ECS_SERVICE` — Just the service name
    - `ECS_TASK_DEFINITION` — Just the task family name
    - `CONTAINER_NAME` — Just the container name

    **Why put config in the workflow file instead of Secrets?**
    1. **Visibility:** You can read the file and know exactly what gets deployed without digging through GitHub Settings
    2. **Versioning:** Changes to config (like cluster name) are tracked in Git history
    3. **Simplicity:** No need to click through GitHub UI to configure multiple values
    4. **Reusability:** The workflow file remains generic—just update the `env` block at the top for different projects

  - **Required GitHub Secret:**

    | Secret Name  | Example Value                                    | Purpose                                 |
    | ------------ | ------------------------------------------------ | --------------------------------------- |
    | AWS_ROLE_ARN | `arn:aws:iam::123456789012:role/github-deployer` | IAM role for OIDC (contains account ID) |

  - **How to Add the Secret:**
    - GitHub Repo → Settings → Secrets and variables → Actions → New repository secret
    - Name: `AWS_ROLE_ARN`
    - Value: `arn:aws:iam::<your-account-id>:role/github-deployer`
  - **Organization-Level Secret (Optional):**
    - If deploying multiple apps and they ALL use the same IAM role:
      - Set `AWS_ROLE_ARN` at organization level
      - All repos inherit it automatically
    - If different apps use different roles:
      - Set `AWS_ROLE_ARN` per repository

- **Acceptance Criteria:**
  - ✅ `AWS_ROLE_ARN` secret configured in GitHub
  - ✅ All other values defined in workflow file (see Story 6.3)
  - ✅ No sensitive data visible in repository code

---

### Story 6.3: Create Deployment Workflow

- **Title:** Implement GitHub Actions Deployment Workflow
- **Persona:** As a **Developer**, I want an automated deployment pipeline so that pushing to main branch deploys to Fargate without manual steps.
- **Requirements:**
  - Pipeline triggers on push to main
  - Pipeline builds Docker image for linux/amd64
  - Pipeline pushes to ECR with git SHA tag
  - Pipeline updates ECS service
  - Pipeline waits for deployment stability
  - Configuration values in file (not secrets) for visibility and version control
- **Implementation Details:**
  - **Workflow File:** `.github/workflows/deploy.yml`

    ```yaml
    name: Deploy to Amazon ECS

    on:
      push:
        branches:
          - main

    # Configuration values - customize these per project
    # These are NOT secrets - they're just resource names
    env:
      AWS_REGION: us-east-1
      ECR_REPOSITORY: legacy-migration/auth-api
      ECS_SERVICE: auth-api-service
      ECS_CLUSTER: production-cluster
      ECS_TASK_DEFINITION: auth-api
      CONTAINER_NAME: auth-api

    permissions:
      id-token: write # Required for OIDC
      contents: read # Required for checkout

    jobs:
      deploy:
        name: Deploy
        runs-on: ubuntu-latest

        steps:
          - name: Checkout
            uses: actions/checkout@v4

          - name: Configure AWS credentials
            uses: aws-actions/configure-aws-credentials@v4
            with:
              aws-region: ${{ env.AWS_REGION }}
              role-to-assume: ${{ secrets.AWS_ROLE_ARN }}

          - name: Login to Amazon ECR
            uses: aws-actions/amazon-ecr-login@v2
            id: login-ecr

          - name: Build, tag, and push image to ECR
            id: build-image
            env:
              ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
              IMAGE_TAG: ${{ github.sha }}
            run: |
              docker build -t $ECR_REGISTRY/${{ env.ECR_REPOSITORY }}:$IMAGE_TAG .
              docker push $ECR_REGISTRY/${{ env.ECR_REPOSITORY }}:$IMAGE_TAG
              echo "image=$ECR_REGISTRY/${{ env.ECR_REPOSITORY }}:$IMAGE_TAG" >> $GITHUB_OUTPUT

          - name: Download task definition
            run: |
              aws ecs describe-task-definition \
                --task-definition ${{ env.ECS_TASK_DEFINITION }} \
                --query taskDefinition > task-definition.json

          - name: Render new task definition
            uses: aws-actions/amazon-ecs-render-task-definition@v1
            id: task-def
            with:
              task-definition: task-definition.json
              container-name: ${{ env.CONTAINER_NAME }}
              image: ${{ steps.build-image.outputs.image }}

          - name: Deploy to ECS
            uses: aws-actions/amazon-ecs-deploy-task-definition@v2
            with:
              task-definition: ${{ steps.task-def.outputs.task-definition }}
              service: ${{ env.ECS_SERVICE }}
              cluster: ${{ env.ECS_CLUSTER }}
              wait-for-service-stability: true
    ```

  - **Critical Notes:**
    - **⚠️ Bootstrap Dependency:** This workflow assumes the ECS service already exists (created in Story 4.1)
      - **First-run problem:** You can't use this workflow to create the service for the first time
      - **Manual first deployment required:**
        1. Create service manually via Console/CLI (Story 4.1)
        2. Once service exists, this workflow can update it
      - **See Phase 4, Story 1.1** for bootstrap solution using reusable workflows
    - **Reusability:** This workflow is fully reusable. To use it for a different project:
      1. Copy the entire file to the new repo
      2. Update ONLY the `env` block at the top with your project's values
      3. Configure `AWS_ROLE_ARN` secret in GitHub (one time)
      4. Done—no need to edit the workflow steps
    - **Why this approach is better than using all secrets:**
      - Configuration changes are tracked in Git
      - No clicking through GitHub UI multiple times
      - Anyone can see deployment config by reading the file
      - Still secure (only `AWS_ROLE_ARN` is sensitive)
    - `permissions.id-token: write` is REQUIRED for OIDC
    - `wait-for-service-stability: true` blocks until deployment completes or fails
    - Image tag uses git SHA for traceability (not `latest`)
  - **Workflow Verification Steps:**
    1. Push a small change to main branch
    2. Go to GitHub → Actions tab → Watch workflow run
    3. Verify each step passes (green checkmarks)
    4. Check ECR for new image with git SHA tag
    5. Check ECS service for new task definition revision
    6. Test application responds correctly
  - **Common Pipeline Failures:**
    | Error | Cause | Fix |
    |-------|-------|-----|
    | "Not authorized to perform sts:AssumeRoleWithWebIdentity" | OIDC trust policy wrong | Check `sub` condition matches repo/branch |
    | "Could not assume role" | Missing `id-token: write` permission | Add permissions block to workflow |
    | "AccessDeniedException" on ECR | Missing ECR permissions | Update IAM role policy |
    | "Service not stable" timeout | Deployment failing | Check ECS events and CloudWatch logs |
    | "exec format error" | Built for wrong architecture | Add `--platform linux/amd64` to docker build |

- **Acceptance Criteria:**
  - ✅ Push to main triggers workflow
  - ✅ All workflow steps pass (green)
  - ✅ New image appears in ECR with git SHA tag
  - ✅ ECS service updates to new task definition
  - ✅ Application reflects code changes
  - ✅ `wait-for-service-stability` passes
  - ✅ Only `AWS_ROLE_ARN` stored in GitHub Secrets
  - ✅ All config values in `env` block are correct for the project

---

## Feature 7: Validation & Cutover

### Story 7.1: Pre-Cutover Validation

- **Title:** Validate Application Before Production Cutover
- **Persona:** As a **QA Engineer**, I want to thoroughly test the Fargate deployment so that we catch issues before directing production traffic.

- **Requirements:**
  - All critical functionality works
  - Performance is acceptable
  - Logging and monitoring work
  - Rollback plan is ready

- **Implementation Details:**
  - **Functional Testing Checklist:**
    - [ ] Health endpoint responds: `curl https://auth-new.mysite.com/health`
    - [ ] Authentication works (login, logout, token refresh)
    - [ ] Database operations work (read, write, transactions)
    - [ ] External API calls work (third-party integrations)
    - [ ] Session persistence works (Redis)
    - [ ] File uploads work (S3)
    - [ ] Email sending works (SES/SMTP)
    - [ ] Background jobs work (if applicable)
  - **Performance Validation:**
    - [ ] Response time acceptable (compare to EC2 baseline)
    - [ ] No memory leaks (monitor over hours)
    - [ ] Connection pooling works under load
    - [ ] Auto-scaling triggers correctly (if configured)
  - **Observability Validation:**
    - [ ] Logs appear in CloudWatch
    - [ ] Logs are structured and searchable
    - [ ] Error logs capture stack traces
    - [ ] Container Insights metrics visible
    - [ ] ALB metrics show request counts
  - **Security Validation:**
    - [ ] HTTPS enforced (HTTP redirects)
    - [ ] Direct container access blocked (only ALB)
    - [ ] Secrets not logged
    - [ ] IAM permissions minimal (no errors, no excess)
  - **Load Testing (Optional but Recommended):**

    ```bash
    # Simple load test with hey
    hey -n 1000 -c 50 https://auth-new.mysite.com/health

    # Or use k6, Artillery, etc.
    ```

- **Acceptance Criteria:**
  - ✅ All functional tests pass
  - ✅ Performance meets baseline
  - ✅ Logs flowing to CloudWatch
  - ✅ Team confident in deployment

---

### Story 7.2: Production Cutover

- **Title:** Switch Production Traffic to Fargate
- **Persona:** As a **Operations Engineer**, I want a controlled cutover process so that we can switch to Fargate with minimal risk and quick rollback capability.

- **Requirements:**
  - Zero or minimal downtime
  - Rollback plan tested
  - Monitoring in place during cutover
  - Communication plan ready

- **Implementation Details:**
  - **Pre-Cutover (1 day before):**
    - [ ] Notify stakeholders of maintenance window
    - [ ] Verify EC2 is running as fallback
    - [ ] Verify Fargate health checks passing
    - [ ] Document rollback steps
    - [ ] Verify DNS TTL is low (300s or less)
  - **Cutover Steps:**
    1. **Verify Fargate Ready:**
       ```bash
       curl -I https://auth-new.mysite.com/health
       # Should return 200
       ```
    2. **Scale Fargate (if needed):**
       - Increase desired count if expecting traffic spike
    3. **Update DNS:**
       - Change `auth.mysite.com` to point to ALB
       - Old: EC2 IP or old ELB
       - New: ALB DNS name
    4. **Monitor (first 15 minutes):**
       - Watch ALB request count increase
       - Watch ECS task CPU/memory
       - Watch CloudWatch Logs for errors
       - Watch application metrics (if APM in place)
    5. **Verify Production:**
       ```bash
       curl -I https://auth.mysite.com/health
       dig auth.mysite.com  # Verify resolves to ALB
       ```
    6. **Extended Monitoring (first 24-48 hours):**
       - Keep EC2 running but not receiving traffic
       - Monitor error rates
       - Check user reports
  - **Rollback Procedure (if needed):**
    1. Revert DNS to point to EC2
    2. Wait for DNS propagation (up to TTL)
    3. Verify traffic returning to EC2
    4. Investigate Fargate issues
    5. Do NOT terminate EC2 until issues resolved
  - **Post-Cutover Cleanup (after 1-2 weeks):**
    - [ ] Stop EC2 instance (keep AMI for disaster recovery)
    - [ ] Remove old DNS records
    - [ ] Update documentation
    - [ ] Close migration ticket

- **Acceptance Criteria:**
  - ✅ DNS updated to point to ALB
  - ✅ Production traffic flowing through Fargate
  - ✅ No increase in error rates
  - ✅ Performance comparable to EC2
  - ✅ Rollback tested or documented

---

## Initial Deployment Checklist

### Per-Application Setup (Verify from Phase 2)

- [ ] Application security group exists (created in Phase 2)
- [ ] ALB SG is source for inbound rule (configured in Phase 2)
- [ ] Internal ALB SG is source for inbound rule (if using, configured in Phase 2)
- [ ] Database SG allows Fargate SG (configured in Phase 2)
- [ ] ElastiCache SG allows Fargate SG (configured in Phase 2)

### Task Definition

- [ ] Task Definition created
- [ ] CPU/Memory appropriate for workload
- [ ] Environment variables configured
- [ ] Secrets reference Secrets Manager
- [ ] Logging configured (awslogs)
- [ ] Health check configured

### Target Group

- [ ] Target Group created with IP type
- [ ] Health check path correct
- [ ] Health check returns 200

### ECS Service

- [ ] Service created in correct cluster
- [ ] Desired count set (start with 1)
- [ ] Private subnets selected
- [ ] Correct security group selected
- [ ] Load balancer attached
- [ ] Circuit breaker enabled
- [ ] Tasks running and healthy

### Routing

- [ ] ALB listener rule created
- [ ] Host header condition correct
- [ ] Forwards to correct target group
- [ ] DNS record created/updated

### CI/CD

- [ ] GitHub secrets configured
- [ ] Pipeline runs successfully
- [ ] Deployment updates ECS service

### Validation

- [ ] Functional testing complete
- [ ] Logs appearing in CloudWatch
- [ ] Performance acceptable

### Cutover

- [ ] DNS switched to ALB
- [ ] Production traffic confirmed
- [ ] Monitoring in place
- [ ] EC2 retained for rollback period

---

**Previous Phase:** [Phase 2 - Infrastructure Setup](ecs-migration-plan-phase-2-infrastructure-setup.md)
**Next Phase:** [Phase 4 - Scaling the Migration](ecs-migration-plan-phase-4-scaling-the-migration.md)
