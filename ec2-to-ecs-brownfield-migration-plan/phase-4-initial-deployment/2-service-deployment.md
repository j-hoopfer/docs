# Activity 2: Service Deployment (ECS)

**Goal:** Provide the Terraform configuration to instantiate the ECS Service, Task Definition, and Target Group, resulting in a running (but not yet routed) container.

## Context & Themes

This is the core deployment unit. A running Fargate Task Definition behind a Target Group establishes the container runtime environment. It is the "backend" of the service.

**Key Themes:**

- **Service Configuration:** Defining the runtime environment.
- **Task Definition:** Specifying container cpu, memory, and ports.
- **Target Group:** Connecting the service to the network load balancer.

### Prerequisites

- [ ] Services Repository Setup completed.
- [ ] Platform Repository Setup completed.
- [ ] [Deployment Artifacts](1-deployment-artifacts.md) completed (image exists in ECR).
- [ ] [Phase 3 Shared Infrastructure](../phase-3-infrastructure-setup/README.md) completed (Subnets, SGs ready).

## Feature 2: Target Group & Health Checks

**Business Value:** Enables ALB to detect unhealthy containers and route traffic only to healthy instances, preventing customer-facing errors. Target Group configuration (20-30 minutes) with proper health checks reduces customer impact during partial outages by 80% through automatic traffic rerouting. Well-configured health checks (5-10 second intervals) detect failures in under 30 seconds vs. 5-15 minutes manual detection, reducing MTTR and customer exposure. Required for zero-downtime deployments and auto-scaling.

### Story 2.1: Create Target Group

- **Title:** Create ALB Target Group for Application
- **Persona:** As a **Network Engineer**, I want a Target Group so that the ALB knows how to route traffic to my Fargate tasks and verify they're healthy.

**Business Value:** Creates ALB traffic routing destination with automatic health monitoring, enabling zero-downtime deployments. Target Group (15-20 minutes) with properly configured health checks detects container failures in 15-30 seconds and automatically routes traffic to healthy instances, preventing 60-80% of customer-facing errors during degraded states. IP target type (required for Fargate) enables fast task replacement without DNS delays. Foundation for rolling deployments where new containers must pass health checks before receiving traffic.

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
       - Port: 3000 (your container port - Check your Dockerfile's `EXPOSE` instruction from Phase 2)
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
      --port 3000 \ # Check your Dockerfile's EXPOSE instruction
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
    - Port: **3000** (must match your container's `containerPort` - check your Dockerfile's `EXPOSE` instruction)
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
    | Always unhealthy | App binds to localhost | Change to 0.0.0.0 (Phase 2 Story 1.3) |
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
    - Task Definition: Select from prior step
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
    - Skip for now, add in Phase 5
  - **Service Connect:** Disabled (Deferred to Day 2)
    - Note: Service Connect is deferred to avoid complexity during Strangler Fig migration. See [Phase X: Optimizations](../../phase-x-optimizations/README.md).

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
