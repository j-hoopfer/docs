# ECS Brownfield Migration Plan - Implementation Guide for Feedback

**Purpose:** This document contains all the specific changes to incorporate the consolidated feedback into the migration plan. Each change includes the exact location, story format, and content to add or modify.

---

## Phase 0: Discovery & Prerequisites Updates

### 🔴 CRITICAL: Add Story 9.3 - Audit Host Agents & APM

**Location:** After Story 9.2 in `ecs-migration-plan-phase-0-discovery.md`

````markdown
### Story 9.3: Audit Host-Level Agents and APM Tools

- **Title:** Inventory OS-Level Monitoring and Security Agents
- **Persona:** As a **DevOps engineer**, I need to audit all host-level agents running on EC2 so that I can plan their migration to sidecar containers or AWS-native alternatives, avoiding blind spots in observability and security after moving to Fargate.

- **Requirements:**
  - Identify all running agents on EC2 instances (APM, monitoring, security)
  - Determine which agents are compatible with Fargate
  - Plan migration strategy for each agent (sidecar, AWS native, or discontinue)
  - Update

application architecture to include sidecars where needed

- **Implementation Details:**
  - **SSH to EC2 and audit running processes:**
    ```bash
    ps aux | grep -E 'datadog|newrelic|dynatrace|splunk|crowdstrike|falcon|qualys'
    systemctl list-units --type=service | grep -E 'datadog|newrelic|dynatrace'
    dpkg -l | grep -E 'datadog|newrelic'  # Debian/Ubuntu
    rpm -qa | grep -E 'datadog|newrelic'  # RHEL/Amazon Linux
    ```
  - **Common agents and their Fargate strategies:**

    | Agent Type       | EC2 Agent                | Fargate Strategy                                             |
    | ---------------- | ------------------------ | ------------------------------------------------------------ |
    | **APM**          | Datadog Agent            | Sidecar container OR Datadog Lambda extension                |
    |                  | New Relic Infrastructure | Not supported - use New Relic APM library                    |
    |                  | Dynatrace OneAgent       | Sidecar container with proper configuration                  |
    | **Log Shipping** | Filebeat, Fluentd        | **Not needed** - use awslogs driver instead                  |
    |                  | Splunk Forwarder         | **Not needed** - ship logs via Firehose or Lambda            |
    |                  | CloudWatch Agent         | **Not needed** - use awslogs driver                          |
    | **Security**     | CrowdStrike Falcon       | **Not supported on Fargate** - use AWS GuardDuty + Inspector |
    |                  | Qualys, Tenable          | **Not supported** - scan container images in ECR instead     |
    | **Service Mesh** | Consul Agent             | Not recommended - use AWS App Mesh or Service Connect        |

  - **Decision tree for each agent:**
    1. **Is there an AWS-native alternative?**
       - **Monitoring:** CloudWatch Container Insights (built-in)
       - **Logs:** CloudWatch Logs (awslogs driver)
       - **Security:** GuardDuty, Inspector, Security Hub
       - → **Preferred:** Use AWS native tools
    2. **Does the vendor support Fargate sidecar?**
       - **Datadog:** Yes ([docs](https://docs.datadoghq.com/integrations/ecs_fargate/))
       - **New Relic:** Yes, via sidecar
       - **Dynatrace:** Yes ([docs](https://www.dynatrace.com/support/help/setup-and-configuration/setup-on-container-platforms/amazon-web-services/amazon-ecs/deploy-oneagent-as-ecs-fargate-sidecar))
       - → **Acceptable:** Deploy as sidecar container
    3. **Can we instrument the app instead of using a host agent?**
       - **APM:** Use application-level SDK (Datadog Tracer, New Relic APM library, X-Ray SDK)
       - → **Good:** Less infrastructure overhead
    4. **Is this agent still needed?**
       - Legacy agents from previous vendors
       - Duplicate monitoring (e.g., both Datadog and CloudWatch)
       - → **Best:** Simplify and consolidate

  - **Sidecar container example (Datadog):**

    ```json
    {
      "containerDefinitions": [
        {
          "name": "app",
          "image": "my-app:latest",
          "portMappings": [{ "containerPort": 3000 }],
          "environment": [
            { "name": "DD_AGENT_HOST", "value": "localhost" },
            { "name": "DD_TRACE_AGENT_PORT", "value": "8126" }
          ]
        },
        {
          "name": "datadog-agent",
          "image": "public.ecr.aws/datadog/agent:latest",
          "environment": [
            { "name": "DD_API_KEY", "valueFrom": "arn:aws:secretsmanager:..." },
            { "name": "ECS_FARGATE", "value": "true" },
            { "name": "DD_APM_ENABLED", "value": "true" }
          ]
        }
      ]
    }
    ```

  - **Cost implications:**
    - Sidecar containers consume additional vCPU/memory (e.g., Datadog agent ~128MB)
    - Calculate: (Number of tasks) × (Agent memory) × $0.004445/GB/hour
    - Example: 10 tasks × 128MB × 730 hours = ~$4/month extra

  - **Migration planning:**
    - **Phase 0 (Discovery):** Audit and plan (this story)
    - **Phase 1 (App Readiness):** Update task definitions to include sidecars
    - **Phase 3 (Deployment):** Deploy with sidecars and verify metrics/logs flow

- **Acceptance Criteria:**
  - ✅ All host-level agents identified and categorized
  - ✅ Migration strategy documented for each agent (AWS native, sidecar, discontinue)
  - ✅ Sidecar container task definitions drafted for required agents
  - ✅ Cost impact of sidecars calculated
  - ✅ Team trained on sidecar deployment pattern
  - ✅ Dashboards and alerts verified to work with new agent architecture

---
````

### 🔴 CRITICAL: Add Story 8.2 - Audit Financial Lock-in

**Location:** After Story 8.1 in `ecs-migration-plan-phase-0-discovery.md`

````markdown
### Story 8.2: Audit EC2 Reserved Instances and Savings Plans

- **Title:** Identify Active EC2 Financial Commitments
- **Persona:** As a **finance/cloud admin**, I need to audit existing EC2 Reserved Instances and Savings Plans so that I can avoid paying double (for both unused EC2 commitments and new Fargate usage) during migration.

- **Requirements:**
  - Identify all active EC2 Reserved Instances (RIs)
  - Identify all active EC2 Instance Savings Plans
  - Calculate financial impact of migrating before commitments expire
  - Plan migration timing or mitigation strategies

- **Implementation Details:**
  - **The Problem:**
    - EC2 Reserved Instances and EC2 Instance Savings Plans do **NOT** apply to Fargate
    - Compute Savings Plans can apply to Fargate, but EC2-specific commitments cannot
    - If you migrate while still paying for unused RIs, you'll pay double:
      - **Wasted:** Unused EC2 RI commitment ($X/month)
      - **New:** Fargate on-demand usage ($Y/month)
      - **Total waste:** Migration delay or breakage fees

  - **Audit active commitments:**

    **Check Reserved Instances:**

    ```bash
    aws ec2 describe-reserved-instances \
      --filters "Name=state,Values=active" \
      --query 'ReservedInstances[*].[ReservedInstancesId,InstanceType,InstanceCount,End,OfferingType]' \
      --output table
    ```

    **Check Savings Plans:**

    ```bash
    aws savingsplans describe-savings-plans \
      --filters "Name=state,Values=active" \
      --query 'savingsPlans[*].[savingsPlanId,savingsPlanType,commitment,end]' \
      --output table
    ```

    Or use AWS Cost Management Console:
    - Go to **AWS Cost Management** > **Savings Plans** or **Reserved Instances**
    - Filter by: **Active** status
    - Note: Instance type, commitment amount, expiration date

  - **Calculate financial impact:**

    | Scenario                                    | Financial Impact                                                                            |
    | ------------------------------------------- | ------------------------------------------------------------------------------------------- |
    | **RI expires before migration**             | ✅ Zero waste - proceed with migration                                                      |
    | **RI expires 1-3 months after migration**   | ⚠️ Minor waste - acceptable if migration value justifies it                                 |
    | **RI expires 6-12 months after migration**  | 🔴 Major waste - consider delaying migration or selling RI on Reserved Instance Marketplace |
    | **Compute Savings Plan (not EC2-specific)** | ✅ Commitment applies to Fargate - no issue                                                 |

  - **Mitigation strategies:**
    1. **Wait for expiration** (if timeline allows)
       - Delay Fargate migration until RIs expire
       - Pros: Zero wasted commitment
       - Cons: Delayed business value from migration
    2. **Sell on Reserved Instance Marketplace** (Standard RIs only)
       - List unused RIs for sale to other AWS customers
       - Recovery rate: typically 20-40% of remaining value
       - Requirements: US bank account, must be Standard RI (not Convertible)
       - [AWS RI Marketplace docs](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ri-market-general.html)
    3. **Convert EC2 RI to Convertible RI** (if possible)
       - Exchange for different instance types that you still use
       - Not applicable if you're shutting down all EC2
    4. **Modify RI to smaller instance size**
       - If migrating only some apps, modify RI to cover remaining EC2 workload
       - [Modifying RIs docs](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ri-modifying.html)
    5. **Accept the waste** (if business case is strong)
       - Calculate NPV of migration benefits vs. wasted RI cost
       - Example: If Fargate saves $500/month in ops cost but wastes $200/month in RI for 6 months, total savings = $500×6 - $200×6 = $1800
    6. **Hybrid approach** (recommended for large fleets)
       - Migrate apps NOT covered by RIs first
       - Keep EC2 apps that match RI instance types running until expiration
       - Gradually shift remaining apps as RIs expire

  - **Check commitment type:**

    | Commitment Type               | Applies to Fargate? | Action           |
    | ----------------------------- | ------------------- | ---------------- |
    | **EC2 Reserved Instance**     | ❌ No               | Plan mitigation  |
    | **EC2 Instance Savings Plan** | ❌ No               | Plan mitigation  |
    | **Compute Savings Plan**      | ✅ Yes              | No action needed |

  - **Example financial calculation:**

    ```
    Current state:
    - 10× t3.medium EC2 instances
    - 3-year Standard RI (1 year remaining)
    - RI commitment: $15/month each = $150/month total
    - On-demand cost would be: $30/month each = $300/month total
    - Savings from RI: $150/month

    Migration scenario:
    - Fargate cost (same workload): $210/month
    - Wasted RI cost (unused): $150/month
    - **Total cost during overlap: $360/month** (vs. $150/month today)
    - **Extra cost for 12 months: $210/month × 12 = $2,520**

    Decision:
    - If migration saves $300/month in ops cost, ROI = 8.4 months
    - If can't wait 12 months, proceed but budget for overlap cost
    ```

- **Acceptance Criteria:**
  - ✅ All active RIs and Savings Plans identified with expiration dates
  - ✅ Financial impact calculated for each commitment
  - ✅ Mitigation strategy selected and documented
  - ✅ Migration timeline adjusted if necessary to minimize waste
  - ✅ Finance team informed of potential double-billing period
  - ✅ Cost anomaly alerts configured to catch unexpected charges

---
````

### 🟡 OPTIMIZATION: Refine Story 9.1 - Cron Job Context

**Location:** Update Story 9.1 in `ecs-migration-plan-phase-0-discovery.md`

Add to the "Implementation Details" section and "Acceptance Criteria":

````markdown
- **Critical for cron jobs: Check for stateful dependencies**
  - **The Risk:** Cron jobs on EC2 often rely on local file history from previous runs
  - **Example problematic patterns:**
    - Script reads `/tmp/last_run_id.txt` to determine what to process next
    - Incremental backup script checks local state file
    - ETL job tracks last processed record in local database
  - **Fargate impact:** Each ECS task starts fresh - no local state persists between runs
  - **Check for:**
    ```bash
    # Search cron scripts for file reads that might be state
    grep -r "/tmp/" /path/to/cron/scripts
    grep -r "\.txt\|\.json\|\.db" /path/to/cron/scripts
    # Look for any file I/O that isn't logging
    ```
  - **Migration strategies for stateful cron jobs:**
    1. **Use S3 for state files:** Store `last_run_id.txt` in S3, read/write on each run
    2. **Use DynamoDB for state:** Track processing state in DynamoDB table
    3. **Use RDS/database:** Store "last processed" timestamp in database
    4. **Make idempotent:** Design job to process full dataset each time (with deduplication)
````

And update **Acceptance Criteria**:

```markdown
- ✅ All cron jobs documented with schedules
- ✅ **Cron jobs verified as stateless or refactored to use external state (S3/DynamoDB/RDS)**
- ✅ **Cron jobs tested to run successfully multiple times without side effects**
```

### 🟡 OPTIMIZATION: Update Story 1.2 - S3 Gateway Endpoint

**Location:** Update Story 1.2 in `ecs-migration-plan-phase-0-discovery.md`

Update the bullet about S3 endpoint:

```markdown
    - `com.amazonaws.<region>.s3` (ECR stores layers in S3) - **Gateway endpoint (FREE, zero cost)**
```

And add a note in Implementation Details:

```markdown
- **Critical: S3 Gateway Endpoint is FREE and prevents massive NAT costs:**
  - ECR Docker image layers are stored in S3
  - Without S3 Gateway Endpoint, image pulls route through NAT Gateway
  - Large images pulling through NAT can cost $10-50+/month per service
  - S3 Gateway Endpoint has **zero** endpoint cost and **zero** data processing cost
  - **Always create S3 Gateway Endpoint, even if you choose NAT Gateway for other traffic**
```

### 🟡 OPTIMIZATION: Update Story 2.3 - Self-Referencing Security Groups

**Location:** Find Story 2.3 and add to requirements and implementation:

```markdown
- **Requirements:**
  ...existing requirements...
  - Verify security groups allow self-referencing traffic (task-to-task communication)
```

````markdown
- **Implementation Details:**
  ...existing details...
  - **Self-referencing rules (critical for service-to-service communication):**
    - Tasks in the same ECS service may need to communicate (e.g., clustering, leader election)
    - Security group must allow inbound traffic from itself
    - **Example rule:**
      ```bash
      # Allow all traffic from the same security group
      aws ec2 authorize-security-group-ingress \
        --group-id sg-app \
        --source-group sg-app \
        --protocol -1 \
        --port -1
      ```
    - Without this, tasks cannot reach each other even though they're in the same service
````

### 🟡 OPTIMIZATION: Update Story 7.1 - Rate Limits

**Location:** Find Feature 7 / Story 7.1 and update:

```markdown
- **Requirements:**
  ...existing requirements...
  - Check AWS API rate limits (not just resource quotas)
```

````markdown
- **Implementation Details:**
  ...existing details...
  - **Check API rate limits in addition to resource quotas:**
    - AWS APIs have **rate limits** (requests per second) in addition to resource quotas
    - Common bottlenecks during deployment:
      - `ecs:DescribeServices` - 40 requests/second
      - `ecs:UpdateService` - 20 requests/second
      - `ecr:GetAuthorizationToken` - 20 requests/second (shared across account)
    - **Risk:** CI/CD deploying 10 services simultaneously can hit rate limits
    - **Mitigation:**
      - Serialize deployments in CI/CD (deploy one service at a time)
      - Use exponential backoff in deployment scripts
      - Request rate limit increase for high-throughput accounts
    - **Check current limits:**
      ```bash
      # Use Service Quotas console or CLI
      aws service-quotas list-service-quotas \
        --service-code ecs \
        --query 'Quotas[?QuotaName contains `Rate`]'
      ```
````

---

## Phase 1: Application Readiness Updates

### 🔴 CRITICAL: Add PID 1 / Zombie Process Handling

**Location:** Add as new story after Story 1.1 OR update Story 7.1 in `ecs-migration-plan-phase-1-application-readiness.md`

````markdown
### Story 1.2: Handle PID 1 and Zombie Processes

- **Title:** Configure Init Process for Proper Signal Handling
- **Persona:** As a **developer**, I need the container to properly handle signals and reap zombie processes so that graceful shutdown works correctly and the container doesn't accumulate zombie processes over time.

- **Requirements:**
  - Container must properly handle SIGTERM for graceful shutdown
  - Container must reap zombie child processes
  - Application runtime must not run as PID 1 (unless it handles signals natively)
  - Solution must work for Node.js, Python, Java, and other runtimes

- **Implementation Details:**
  - **The Problem:**
    - In Docker, the first process (PID 1) has special responsibilities:
      1. **Signal forwarding:** PID 1 must forward SIGTERM to child processes
      2. **Zombie reaping:** PID 1 must reap zombie (defunct) child processes
    - Most application runtimes (Node.js, Python, Java) do NOT handle these responsibilities
    - **What happens without proper init:**
      - App doesn't shut down gracefully on `docker stop` (waits 30s, then SIGKILL)
      - Zombie processes accumulate if app spawns child processes
      - Container becomes unstable over time

  - **Solution 1: Use `tini` in Dockerfile (Recommended for all apps)**

    `tini` is a lightweight init system that:
    - Forwards signals to child processes
    - Reaps zombie processes
    - Adds only ~100KB to image size

    **Update Dockerfile:**

    ```dockerfile
    FROM node:22-slim

    # Install tini
    RUN apt-get update && apt-get install -y tini && rm -rf /var/lib/apt/lists/*

    WORKDIR /app
    COPY package*.json ./
    RUN npm ci --production
    COPY . .

    EXPOSE 3000

    # Use tini as PID 1
    ENTRYPOINT ["/usr/bin/tini", "--"]
    CMD ["node", "server.js"]
    ```

    **For Alpine-based images:**

    ```dockerfile
    FROM node:22-alpine

    # tini is available in Alpine repos
    RUN apk add --no-cache tini

    ENTRYPOINT ["/sbin/tini", "--"]
    CMD ["node", "server.js"]
    ```

  - **Solution 2: Use ECS Task Definition `initProcessEnabled` (ECS-specific)**

    ECS can inject an init process without modifying the Dockerfile:

    ```json
    {
      "family": "my-app",
      "containerDefinitions": [
        {
          "name": "app",
          "image": "my-app:latest",
          "linuxParameters": {
            "initProcessEnabled": true
          }
        }
      ]
    }
    ```

    **Pros:**
    - No Dockerfile changes required
    - Works with existing images
    - ECS-native solution

    **Cons:**
    - Only works in ECS (not locally or in other orchestrators)
    - Less explicit than Dockerfile approach

  - **Solution 3: Use `dumb-init` (Alternative to tini)**

    Similar to tini but with different behavior:

    ```dockerfile
    RUN wget -O /usr/local/bin/dumb-init https://github.com/Yelp/dumb-init/releases/download/v1.2.5/dumb-init_1.2.5_amd64 \
        && chmod +x /usr/local/bin/dumb-init

    ENTRYPOINT ["/usr/local/bin/dumb-init", "--"]
    CMD ["node", "server.js"]
    ```

  - **Verify PID 1 handling:**

    **Test signal forwarding:**

    ```bash
    # Run container
    docker run -d --name test-app my-app:latest

    # Send SIGTERM
    docker stop test-app

    # Check logs - should see graceful shutdown message within 5 seconds
    docker logs test-app

    # If container takes 30 seconds to stop, signal forwarding is broken
    ```

    **Test zombie reaping:**

    ```bash
    # Exec into running container
    docker exec test-app ps aux

    # Look for <defunct> processes
    # Should NOT see lines like:
    # node      123  0.0  0.0      0     0 ?        Z    14:23   0:00 [node] <defunct>
    ```

  - **Application-specific notes:**

    | Runtime         | Native Signal Handling?                      | Recommendation                     |
    | --------------- | -------------------------------------------- | ---------------------------------- |
    | **Node.js**     | ❌ No (unless you manually handle SIGTERM)   | **Use tini or initProcessEnabled** |
    | **Python**      | ❌ No (unless using signal module)           | **Use tini or initProcessEnabled** |
    | **Java**        | ⚠️ Partial (handles SIGTERM but not zombies) | **Use tini or initProcessEnabled** |
    | **Go**          | ✅ Yes (if properly coded)                   | Optional (but tini adds safety)    |
    | **Nginx**       | ✅ Yes                                       | No init needed                     |
    | **Bash script** | ❌ No                                        | **Absolutely use tini**            |

- **Acceptance Criteria:**
  - ✅ `tini` or `dumb-init` added to Dockerfile, OR `initProcessEnabled: true` set in task definition
  - ✅ Container stops gracefully within 10 seconds when sent SIGTERM
  - ✅ No zombie (`<defunct>`) processes accumulate during 24-hour run test
  - ✅ Application logs show graceful shutdown message
  - ✅ Load test with process spawning (if applicable) shows no zombie accumulation

---
````

### 🔴 CRITICAL: Fix Story 9.2 - Deep Health Check Strategy

**Location:** Update Story 9.2 in `ecs-migration-plan-phase-1-application-readiness.md`

Replace the "ECS Configuration" section with:

````markdown
**Critical: Avoid the "Health Check Suicide Pact"**

- **The Problem:**
  - If ALL tasks check database/Redis in their health check
  - And the database has a brief outage (10 seconds)
  - ALL tasks fail health check simultaneously
  - ECS kills the entire fleet
  - Even when the database recovers, you have zero running tasks

- **The Solution: Separate Liveness from Readiness**

  | Endpoint        | Purpose       | Checks                  | Used By                    | Failure Impact                 |
  | --------------- | ------------- | ----------------------- | -------------------------- | ------------------------------ |
  | `/health`       | **Liveness**  | Process alive?          | ALB Target Group           | ALB stops routing to THIS task |
  | `/health/ready` | **Readiness** | Dependencies reachable? | ECS Container Health Check | ECS replaces THIS task         |

- **Configuration:**

  **ALB Target Group (LIVENESS - Fast, Shallow):**

  ```hcl
  resource "aws_lb_target_group" "app" {
    health_check {
      enabled             = true
      path                = "/health"        # Shallow check
      healthy_threshold   = 2
      unhealthy_threshold = 2
      timeout             = 5
      interval            = 30
      matcher             = "200"
    }
  }
  ```

  **ECS Task Definition (READINESS - Deep, with high retry tolerance):**

  ```json
  {
    "healthCheck": {
      "command": [
        "CMD-SHELL",
        "curl -f http://localhost:3000/health/ready || exit 1"
      ],
      "interval": 30,
      "timeout": 5,
      "retries": 5, // High retries to tolerate brief DB blips
      "startPeriod": 60
    }
  }
  ```

- **Why this works:**
  - **Database blips:** Tasks fail readiness check, but ALB keeps routing (liveness still passes)
  - **Task-specific issues:** If one task's DB connection is bad, only that task is replaced
  - **Fleet protection:** Database outage doesn't kill all tasks simultaneously
  - **High retry count (5):** Task survives 5 consecutive failures = 2.5 minutes of DB downtime before being replaced
````

Update **Acceptance Criteria:**

```markdown
- ✅ `/health` returns 200 when all dependencies are available
- ✅ `/health/ready` returns 200 when all dependencies are available
- ✅ `/health/ready` returns 503 when database is down
- ✅ **ALB health check points to `/health` (liveness), NOT `/health/ready`**
- ✅ **ECS container health check points to `/health/ready` with retries >= 5**
- ✅ Response includes individual check status in JSON
- ✅ Health check completes within 5 seconds
- ✅ Failed dependency checks log error messages
- ✅ **Tested: Database outage for 30 seconds does NOT kill all tasks**
- ✅ Container survives temporary dependency failures (doesn't crash)
```

### 🔴 CRITICAL: Update Story 11.1 - RDS Proxy Recommendation

**Location:** Update Story 11.1 in `ecs-migration-plan-phase-1-application-readiness.md`

Change "Consider using RDS Proxy" to a strong recommendation:

````markdown
- **Strongly Recommended: Use RDS Proxy for Connection Management**

  **The Problem with Direct Connections:**
  - Auto-scaling can spike task count unexpectedly (e.g., 2 tasks → 20 tasks in 60 seconds)
  - Each task opens `pool_size` connections immediately
  - **Risk:** 20 tasks × 10 connections = 200 connections, exceeding RDS `max_connections` (150)
  - Result: New tasks fail to start, deployment fails, alert storm

  **RDS Proxy Solution:**
  - **Connection multiplexing:** 100 app connections → 10 actual database connections
  - **Automatic scaling:** Proxy handles connection management, not your app
  - **Built-in retry logic:** Transient connection failures are retried automatically
  - **Zero code changes:** Just change connection string

  **Setup:**

  ```bash
  aws rds create-db-proxy \
    --db-proxy-name my-app-proxy \
    --engine-family MYSQL \
    --auth [{
      "AuthScheme": "SECRETS",
      "SecretArn": "arn:aws:secretsmanager:..."
    }] \
    --role-arn arn:aws:iam::ACCOUNT:role/RDSProxyRole \
    --vpc-subnet-ids subnet-xxx subnet-yyy \
    --require-tls true
  ```

  **Update connection string:**

  ```javascript
  // Before (direct RDS connection)
  const pool = mysql.createPool({
    host: 'mydb.abc123.us-east-1.rds.amazonaws.com',
    ...
  });

  // After (via RDS Proxy)
  const pool = mysql.createPool({
    host: 'my-app-proxy.proxy-abc123.us-east-1.rds.amazonaws.com',
    ...
  });
  ```

  **Cost:**
  - $0.015 per vCPU-hour (~$11/month for 1 vCPU proxy)
  - $0.0000027 per connection per hour (~$2/month for 100 connections)
  - **Total:** ~$13/month for peace of mind

  **When you can skip RDS Proxy:**
  - You have a fixed, small number of tasks (e.g., always exactly 2 tasks)
  - You're NOT using auto-scaling
  - Your max possible connections are well below RDS limit
    - Example: `max_tasks = 5`, `pool_size = 10`, `total = 50` << `RDS max_connections = 150`
````

Update **Acceptance Criteria:**

```markdown
- ✅ **RDS Proxy provisioned and tested, OR justification documented for not using it**
- ✅ Scaling from 1 to 10 tasks doesn't cause "too many connections" errors
- ✅ RDS failover doesn't crash the application (reconnects automatically)
- ✅ Connections are released on container shutdown
- ✅ Database connection count visible in RDS CloudWatch metrics
- ✅ **Load test at 2× expected max scale shows stable connection count**
```

### 🟡 OPTIMIZATION: Add Story 1.4 - Multi-Architecture Builds

**Location:** Add after Story 1.3 in `ecs-migration-plan-phase-1-application-readiness.md`

````markdown
### Story 1.4: Build Multi-Architecture Container Images

- **Title:** Support ARM64 (Graviton) for Cost Savings
- **Persona:** As a **DevOps engineer**, I want to build multi-architecture (amd64 + arm64) container images so that I can optionally run on AWS Graviton processors for 20% cost savings.

- **Requirements:**
  - Build images for both amd64 (Intel/AMD) and arm64 (Graviton) architectures
  - Publish multi-architecture manifest to ECR
  - Verify application works on both architectures

- **Implementation Details:**
  - **Why multi-architecture:**
    - **AWS Graviton (ARM64) Fargate pricing is ~20% cheaper** than x86_64
    - Example: 1 vCPU + 2GB Fargate task
      - x86_64: $0.04856/hour
      - ARM64 (Graviton): $0.03885/hour
      - **Savings: $0.00971/hour = $7.09/month per task**
    - For 10 tasks running 24/7: **$70/month savings**
  - **Use Docker Buildx for multi-architecture builds:**

    **Create builder (one-time setup):**

    ```bash
    docker buildx create --name multi-arch --use
    docker buildx inspect --bootstrap
    ```

    **Update Dockerfile to be ARM-compatible:**
    - Most base images support multi-arch: `node:22-slim`, `python:3.11-slim`, `openjdk:17-slim`
    - Check for native dependencies (e.g., compiled Python packages)
    - Use `apt-get` or `apk` for dependencies (not pre-compiled binaries)

    **Build and push multi-architecture image:**

    ```bash
    # Login to ECR
    aws ecr get-login-password --region us-east-1 | \
      docker login --username AWS --password-stdin 123456789012.dkr.ecr.us-east-1.amazonaws.com

    # Build for both architectures
    docker buildx build \
      --platform linux/amd64,linux/arm64 \
      -t 123456789012.dkr.ecr.us-east-1.amazonaws.com/my-app:latest \
      --push \
      .
    ```

  - **Update ECS Task Definition to use ARM64:**

    ```json
    {
      "family": "my-app",
      "cpu": "256",
      "memory": "512",
      "runtimePlatform": {
        "cpuArchitecture": "ARM64",
        "operatingSystemFamily": "LINUX"
      },
      "containerDefinitions": [...]
    }
    ```

    Or stick with x86_64 (Fargate auto-selects based on runtimePlatform):

    ```json
    "runtimePlatform": {
      "cpuArchitecture": "X86_64",
      "operatingSystemFamily": "LINUX"
    }
    ```

  - **Verify multi-arch manifest:**

    ```bash
    docker buildx imagetools inspect \
      123456789012.dkr.ecr.us-east-1.amazonaws.com/my-app:latest

    # Should see:
    # MediaType: application/vnd.docker.distribution.manifest.list.v2+json
    # Manifests:
    #   - linux/amd64
    #   - linux/arm64
    ```

  - **Common ARM64 compatibility issues:**

    | Issue                                       | Solution                                                  |
    | ------------------------------------------- | --------------------------------------------------------- |
    | **Native npm packages** (e.g., `node-sass`) | Use pure JS alternatives or ensure package supports ARM64 |
    | **Pre-compiled binaries** in Dockerfile     | Use `apt-get` or compile from source                      |
    | **Alpine Linux musl issues**                | Use Debian-based images (`-slim`) instead                 |
    | **Java JIT performance**                    | Graviton performs very well with Java - no issues         |

- **Acceptance Criteria:**
  - ✅ Multi-architecture image built for amd64 and arm64
  - ✅ Image pushed to ECR with multi-arch manifest
  - ✅ Application tested on both x86_64 and ARM64 Fargate
  - ✅ CI/CD pipeline updated to build multi-arch images
  - ✅ Team trained on switching between architectures via `runtimePlatform`
  - ✅ Cost savings documented and tracked

---
````

### 🟡 OPTIMIZATION: Add Story 1.5 - Local Dev Parity

**Location:** Add after Story 1.4 in `ecs-migration-plan-phase-1-application-readiness.md`

````markdown
### Story 1.5: Establish Local Development Parity with docker-compose

- **Title:** Ensure Local Environment Matches ECS Production
- **Persona:** As a **developer**, I want a local Docker Compose environment that matches ECS so that I can test integrations (database, Redis, secrets) before deployment.

- **Requirements:**
  - Developers can run full stack locally with `docker-compose up`
  - Local environment uses the same container images as ECS
  - Local environment includes database, Redis, and application
  - Configuration matches ECS as closely as possible

- **Implementation Details:**
  - **Create `docker-compose.yml` for local development:**

    ```yaml
    version: "3.8"

    services:
      # Application
      app:
        build: .
        ports:
          - "3000:3000"
        environment:
          NODE_ENV: development
          DB_HOST: db
          DB_PORT: 3306
          DB_NAME: myapp
          DB_USER: root
          DB_PASSWORD: localpassword
          REDIS_HOST: redis
          REDIS_PORT: 6379
        depends_on:
          db:
            condition: service_healthy
          redis:
            condition: service_started
        healthcheck:
          test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
          interval: 10s
          timeout: 5s
          retries: 3

      # MySQL (matches RDS version)
      db:
        image: mysql:8.0
        environment:
          MYSQL_ROOT_PASSWORD: localpassword
          MYSQL_DATABASE: myapp
        ports:
          - "3306:3306"
        volumes:
          - mysql_data:/var/lib/mysql
        healthcheck:
          test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
          interval: 5s
          timeout: 3s
          retries: 5

      # Redis (matches ElastiCache version)
      redis:
        image: redis:7-alpine
        ports:
          - "6379:6379"

    volumes:
      mysql_data:
    ```

  - **Developer workflow:**

    ```bash
    # Start full stack
    docker-compose up -d

    # View logs
    docker-compose logs -f app

    # Run migrations
    docker-compose exec app npm run migrate

    # Stop stack
    docker-compose down
    ```

  - **Match ECS environment variables:**
    - Use `.env` file for local overrides:
      ```bash
      # .env (gitignored)
      DB_PASSWORD=localpassword
      AWS_REGION=us-east-1
      ```
    - Document which env vars differ between local and ECS
    - Use same secret names where possible
  - **Local vs ECS differences to document:**

    | Aspect                | Local (docker-compose)          | ECS Production             |
    | --------------------- | ------------------------------- | -------------------------- |
    | **Database**          | MySQL container                 | RDS MySQL                  |
    | **Secrets**           | Environment variables           | Secrets Manager            |
    | **Networking**        | Bridge network                  | VPC with subnets           |
    | **Service Discovery** | Container names (`db`, `redis`) | RDS/ElastiCache endpoints  |
    | **IAM**               | No IAM                          | Task Role + Execution Role |

- **Acceptance Criteria:**
  - ✅ `docker-compose up` starts full stack (app + database + Redis)
  - ✅ Application connects to local database and Redis
  - ✅ Health checks pass locally
  - ✅ Migrations run successfully via docker-compose
  - ✅ New developers can onboard with README instructions
  - ✅ Local environment documented in `README.md`
  - ✅ `.env.example` file provided with all required variables

---
````

---

## Phase 2: Infrastructure Setup Updates

### 🔴 CRITICAL: Remove Service Connect from Story 2.3

**Location:** Find Story 2.3 (ECS Cluster/Service Connect) in `ecs-migration-plan-phase-2-infrastructure-setup.md`

Add a warning section:

```markdown
**⚠️ CRITICAL: Do NOT use Service Connect for Strangler Fig Migration**

- **The Problem:**
  - Service Connect creates service mesh networking with its own load balancing
  - Strangler Fig pattern requires weighted routing at the ALB level
  - Service Connect + ALB weighted routing **do not work together**
  - You cannot gradually shift traffic from EC2 to Fargate using Service Connect

- **For this migration: Use Internal ALB instead**
  - ✅ Phase 2: Deploy Internal ALB with Target Groups for EC2 and Fargate
  - ✅ Phase 3: Use ALB listener rules to weight traffic (90% EC2 → 10% Fargate)
  - ✅ Phase 4: Gradually shift weights (50/50 → 10/90 → 0/100)
  - ❌ DO NOT enable Service Connect until migration is complete

- **After migration is complete:**
  - Service Connect can be enabled for new greenfield services
  - Service Connect is excellent for service-to-service communication
  - Not suitable for brownfield migration with weighted routing
```

Update **Acceptance Criteria:**

```markdown
- ✅ ECS cluster created with Container Insights enabled
- ✅ **Service Connect namespace created but NOT enabled on services yet**
- ✅ CloudWatch log group for cluster created
- ✅ **Internal ALB created for Strangler Fig pattern (see Infrastructure Setup phase)**
- ✅ Cluster capacity providers configured (FARGATE, FARGATE_SPOT)
```

### 🔴 CRITICAL: Update Story 3.2 - Seed Image Port Matching

**Location:** Find Story 3.2 (Seed Service) in `ecs-migration-plan-phase-2-infrastructure-setup.md`

Update the task definition port mapping to match the actual application:

````markdown
- **Task definition (seed-service):**

  ```json
  {
    "family": "seed-service",
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "256",
    "memory": "512",
    "containerDefinitions": [
      {
        "name": "nginx",
        "image": "nginx:alpine",
        "portMappings": [
          {
            "containerPort": 80, // ⚠️ CHANGE THIS TO MATCH YOUR APP
            "protocol": "tcp"
          }
        ],
        "logConfiguration": {
          "logDriver": "awslogs",
          "options": {
            "awslogs-group": "/ecs/seed-service",
            "awslogs-region": "us-east-1",
            "awslogs-stream-prefix": "ecs"
          }
        }
      }
    ]
  }
  ```

  **⚠️ CRITICAL: Match your application's port**
  - If your app runs on port 3000, change `containerPort: 80` → `containerPort: 3000`
  - If your app runs on port 8080, change `containerPort: 80` → `containerPort: 8080`
  - The seed service port must match your real application's port
  - Otherwise, when you swap to the real app, health checks will fail
````

### 🟡 OPTIMIZATION: Add Story 5.3 - Deployer Permissions (iam:PassRole)

**Location:** Add after Story 5.2 in `ecs-migration-plan-phase-2-infrastructure-setup.md`

````markdown
### Story 5.3: Configure Deployer IAM Permissions

- **Title:** Grant CI/CD Pipeline Permission to Deploy ECS Services
- **Persona:** As a **DevOps engineer**, I need the CI/CD deployer role to have `iam:PassRole` permission so that GitHub Actions can deploy ECS services with the correct Task and Execution Roles.

- **Requirements:**
  - CI/CD deployer can register task definitions
  - CI/CD deployer can update ECS services
  - CI/CD deployer can pass Task Role and Execution Role to ECS
  - Permissions follow least-privilege principle

- **Implementation Details:**
  - **The Problem:**
    - When GitHub Actions runs `aws ecs register-task-definition`, it needs to specify:
      - `taskRoleArn` (role the application uses)
      - `executionRoleArn` (role ECS uses to pull image and fetch secrets)
    - **Without `iam:PassRole`, deployment fails with:**
      ```
      User: arn:aws:sts::123456789012:assumed-role/GitHubActionsDeployerRole/...
      is not authorized to perform: iam:PassRole on resource: arn:aws:iam::123456789012:role/ECSTaskRole
      ```
  - **Create Deployer Role Policy:**

    ```hcl
    # terraform/iam-deployer.tf

    resource "aws_iam_role" "github_actions_deployer" {
      name = "GitHubActionsDeployerRole"

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
              "token.actions.githubusercontent.com:sub" = "repo:my-org/my-repo:*"
            }
          }
        }]
      })
    }

    resource "aws_iam_role_policy" "deployer_ecs" {
      name = "ECSDeploymentPolicy"
      role = aws_iam_role.github_actions_deployer.id

      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid = "ECSDeployment"
            Effect = "Allow"
            Action = [
              "ecs:RegisterTaskDefinition",
              "ecs:DeregisterTaskDefinition",
              "ecs:DescribeTaskDefinition",
              "ecs:DescribeServices",
              "ecs:UpdateService",
              "ecs:ListTasks",
              "ecs:DescribeTasks"
            ]
            Resource = "*"
          },
          {
            Sid = "PassRoleToECS"
            Effect = "Allow"
            Action = "iam:PassRole"
            Resource = [
              aws_iam_role.ecs_task_role.arn,
              aws_iam_role.ecs_execution_role.arn
            ]
            Condition = {
              StringEquals = {
                "iam:PassedToService": "ecs-tasks.amazonaws.com"
              }
            }
          },
          {
            Sid = "ECRAccess"
            Effect = "Allow"
            Action = [
              "ecr:GetAuthorizationToken",
              "ecr:BatchCheckLayerAvailability",
              "ecr:GetDownloadUrlForLayer",
              "ecr:BatchGetImage"
            ]
            Resource = "*"
          }
        ]
      })
    }
    ```

  - **Least-privilege PassRole:**
    - **Restrict to specific roles:** Only allow passing the Task and Execution roles (not all roles)
    - **Restrict to ECS service:** `Condition: iam:PassedToService = ecs-tasks.amazonaws.com`
    - This prevents deployer from passing arbitrary roles to other services
  - **Test deployment:**

    ```bash
    # Assume deployer role
    aws sts assume-role --role-arn arn:aws:iam::123456789012:role/GitHubActionsDeployerRole

    # Try registering task definition
    aws ecs register-task-definition \
      --family my-app \
      --task-role-arn arn:aws:iam::123456789012:role/ECSTaskRole \
      --execution-role-arn arn:aws:iam::123456789012:role/ECSExecutionRole \
      --container-definitions '[...]'

    # Should succeed with iam:PassRole permission
    ```

- **Acceptance Criteria:**
  - ✅ Deployer role created with OIDC trust for GitHub Actions
  - ✅ `iam:PassRole` permission granted for Task and Execution roles only
  - ✅ Condition restricts PassRole to `ecs-tasks.amazonaws.com`
  - ✅ CI/CD pipeline can register task definitions
  - ✅ CI/CD pipeline can update ECS services
  - ✅ Attempting to pass other IAM roles fails (security test)

---
````

### 🟡 OPTIMIZATION: Update Internal ALB Security Group

**Location:** Find the Internal ALB story and update the security group configuration:

````markdown
- **Security Group for Internal ALB:**

  ```hcl
  resource "aws_security_group" "internal_alb" {
    name        = "internal-alb-sg"
    description = "Allow traffic from VPC CIDR to internal ALB"
    vpc_id      = aws_vpc.main.id

    ingress {
      description = "Allow HTTP from entire VPC CIDR"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = [aws_vpc.main.cidr_block]  // Allow entire VPC, not just private subnets
    }

    ingress {
      description = "Allow HTTPS from entire VPC CIDR"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = [aws_vpc.main.cidr_block]
    }

    egress {
      description = "Allow all outbound"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }

    tags = {
      Name = "internal-alb-sg"
    }
  }
  ```

  **⚠️ Note: Allow full VPC CIDR, not just private subnets**
  - Internal ALB may receive traffic from:
    - Other ECS tasks (private subnets)
    - Lambda functions (could be in public or private subnets)
    - EC2 instances in public subnets
    - VPN/Direct Connect connections
  - Safest approach: Allow entire VPC CIDR (`10.0.0.0/16`)
  - Still internal-only (not exposed to internet)
````

---

## Phase 3: Initial Deployment Updates

### 🔴 CRITICAL: Add initProcessEnabled to Story 3.1

**Location:** Update Story 3.1 (Task Definition) in `ecs-migration-plan-phase-3-initial-deployment.md`

Update the task definition JSON to include:

````markdown
```json
{
  "family": "my-app-v1",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "taskRoleArn": "arn:aws:iam::ACCOUNT:role/ECSTaskRole",
  "executionRoleArn": "arn:aws:iam::ACCOUNT:role/ECSExecutionRole",
  "containerDefinitions": [
    {
      "name": "app",
      "image": "ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/my-app:v1.0.0",
      "portMappings": [
        {
          "containerPort": 3000,
          "protocol": "tcp"
        }
      ],
      "linuxParameters": {
        "initProcessEnabled": true // ⚠️ CRITICAL: Fixes PID 1 zombie process issue
      },
      "environment": [
        { "name": "NODE_ENV", "value": "production" },
        { "name": "PORT", "value": "3000" }
      ],
      "secrets": [
        {
          "name": "DB_PASSWORD",
          "valueFrom": "arn:aws:secretsmanager:us-east-1:ACCOUNT:secret:prod/db-password"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/my-app",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "healthCheck": {
        "command": [
          "CMD-SHELL",
          "curl -f http://localhost:3000/health/ready || exit 1"
        ],
        "interval": 30,
        "timeout": 5,
        "retries": 5,
        "startPeriod": 60
      }
    }
  ]
}
```
````

**Why `initProcessEnabled: true` is critical:**

- Fixes PID 1 zombie process accumulation
- Ensures proper signal handling for graceful shutdown
- ECS-native solution (no Dockerfile changes required)
- Alternative to adding `tini` to Dockerfile (see Phase 1, Story 1.2)

````

### 🟡 OPTIMIZATION: Update Story 4.1 - Disable Circuit Breaker on First Run

**Location:** Update Story 4.1 (Circuit Breaker) in `ecs-migration-plan-phase-3-initial-deployment.md`

Add a note about first deployment:

```markdown
  - **Circuit Breaker Configuration:**
    ```hcl
    resource "aws_ecs_service" "app" {
      name            = "my-app-service"
      cluster         = aws_ecs_cluster.main.id
      task_definition = aws_ecs_task_definition.app.arn
      desired_count   = 2

      deployment_circuit_breaker {
        enable   = true    // ⚠️ Set to FALSE for first deployment
        rollback = true
      }

      deployment_configuration {
        maximum_percent         = 200
        minimum_healthy_percent = 100
      }
    }
    ```

    **⚠️ CRITICAL: Disable circuit breaker for first deployment**

    - **The Problem:**
      - On first deployment, there are zero existing healthy tasks
      - Circuit breaker compares new tasks to existing (healthy) tasks
      - If new tasks fail health check, circuit breaker triggers rollback
      - **But there's nothing to roll back to!**
      - Result: Deployment fails immediately, you can't debug

    - **Solution: Two-phase deployment**

      **Phase 1 - First Deployment (circuit breaker OFF):**
      ```hcl
      deployment_circuit_breaker {
        enable   = false
        rollback = false
      }
      ```
      - Deploy service manually
      - Debug health check failures
      - Fix issues iteratively
      - Verify tasks reach RUNNING state

      **Phase 2 - Enable Circuit Breaker (after first successful deploy):**
      ```hcl
      deployment_circuit_breaker {
        enable   = true
        rollback = true
      }
      ```
      - Now circuit breaker has a healthy baseline
      - Failed deployments automatically roll back
      - Production safety enabled

    - **Why this matters:**
      - First deployment always has issues (wrong env vars, bad health check, etc.)
      - You need time to debug and iterate
      - Circuit breaker prevents iteration by immediately failing
````

### 🟡 OPTIMIZATION: Add Bootstrap Dependency Note to Story 6.3

**Location:** Update Story 6.3 (CI/CD Workflow) in `ecs-migration-plan-phase-3-initial-deployment.md`

Add a note about bootstrap order:

````markdown
**⚠️ Bootstrap Dependency: Infrastructure Must Exist First**

- **The Problem:**
  - CI/CD workflow assumes infrastructure is already deployed (ECR, ECS cluster, task definition)
  - If you run the workflow before infrastructure exists, deployment fails
  - Chicken-and-egg: You need ECR to push images, but CI/CD creates the first image

- **Correct Order:**
  1. **Manual Terraform Apply (one-time bootstrap):**
     ```bash
     cd terraform/
     terraform init
     terraform apply
     # Creates: VPC, subnets, RDS, ECR, ECS cluster, ALB, etc.
     ```
  2. **Manual First Image Push (one-time):**
     ```bash
     # Build and push initial image
     aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin ACCOUNT.dkr.ecr.us-east-1.amazonaws.com
     docker build -t my-app:v1.0.0 .
     docker tag my-app:v1.0.0 ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/my-app:v1.0.0
     docker push ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/my-app:v1.0.0
     ```
  3. **Enable CI/CD Workflow:**
     - Now workflow can pull base image, build, push, and deploy
     - Infrastructure exists for deployments to target

- **Alternative: Self-Bootstrapping Workflow (Advanced)**
  - Use Terraform to create a "seed" ECR repository first
  - Workflow checks if infrastructure exists before deploying
  - See Phase 4, Story 1.1 for handling this automatically
````

---

## Phase 4: Scaling the Migration Updates

### 🔴 CRITICAL: Add DynamoDB Locking to Story 2.1

**Location:** Update Story 2.1 (Terraform Backend) in `ecs-migration-plan-phase-4-scaling-the-migration.md`

Update the S3 backend configuration:

````markdown
- **Configure S3 backend with DynamoDB locking:**

  **⚠️ CRITICAL: Always use DynamoDB locking to prevent state corruption**

  ```hcl
  # terraform/backend.tf

  terraform {
    backend "s3" {
      bucket         = "my-company-terraform-state"
      key            = "ecs-migration/terraform.tfstate"
      region         = "us-east-1"
      encrypt        = true
      kms_key_id     = "arn:aws:kms:us-east-1:ACCOUNT:key/..."  # Optional but recommended
      dynamodb_table = "terraform-state-lock"                    # ⚠️ REQUIRED for locking
    }
  }
  ```

  **Why DynamoDB locking is critical:**
  - **Without locking:** Two people run `terraform apply` simultaneously
  - Both read the same state file
  - Both make changes
  - Both write state back
  - **Result:** Second write overwrites first, state is corrupted, resources are orphaned

  **With DynamoDB locking:**
  - First `terraform apply` acquires lock in DynamoDB
  - Second `terraform apply` waits for lock to be released
  - Operations are serialized
  - State remains consistent

- **Create DynamoDB lock table:**

  ```hcl
  # terraform/dynamodb-lock.tf

  resource "aws_dynamodb_table" "terraform_lock" {
    name         = "terraform-state-lock"
    billing_mode = "PAY_PER_REQUEST"  # No capacity planning needed
    hash_key     = "LockID"

    attribute {
      name = "LockID"
      type = "S"
    }

    tags = {
      Name        = "Terraform State Lock"
      Environment = "shared"
    }
  }
  ```

  **Cost:** Negligible (~$0.25/month for low-frequency applies)

- **Test locking:**

  ```bash
  # Terminal 1
  terraform apply
  # Acquires lock, starts applying

  # Terminal 2 (while Terminal 1 is still running)
  terraform apply
  # Output: Error acquiring the state lock
  # Lock Info:
  #   ID:        abc-123-def-456
  #   Path:      my-company-terraform-state/ecs-migration/terraform.tfstate
  #   Operation: OperationTypeApply
  #   Who:       user@hostname
  #   Created:   2024-01-15 10:30:00
  ```
````

### 🟡 OPTIMIZATION: Update Story 1.1 - CI/CD Bootstrap Paradox

**Location:** Update Story 1.1 (Reusable Workflows) in `ecs-migration-plan-phase-4-scaling-the-migration.md`

Add handling for first-time deployments:

````markdown
**Handle Bootstrap Case (First Deployment):**

- **The Problem:**
  - Reusable workflow assumes ECS service exists
  - On first deployment for a new app, service doesn't exist yet
  - `aws ecs update-service` fails with "Service not found"

- **Solution: Check if service exists first**

  ```yaml
  - name: Check if ECS service exists
    id: check_service
    run: |
      if aws ecs describe-services \
        --cluster ${{ inputs.cluster-name }} \
        --services ${{ inputs.service-name }} \
        --query 'services[0].status' \
        --output text | grep -q ACTIVE; then
        echo "exists=true" >> $GITHUB_OUTPUT
      else
        echo "exists=false" >> $GITHUB_OUTPUT
      fi

  - name: Create ECS service (first time only)
    if: steps.check_service.outputs.exists == 'false'
    run: |
      aws ecs create-service \
        --cluster ${{ inputs.cluster-name }} \
        --service-name ${{ inputs.service-name }} \
        --task-definition ${{ inputs.service-name }}:${{ steps.register.outputs.revision }} \
        --desired-count 2 \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[${{ inputs.subnet-ids }}],securityGroups=[${{ inputs.security-group-id }}],assignPublicIp=DISABLED}" \
        --load-balancers "targetGroupArn=${{ inputs.target-group-arn }},containerName=app,containerPort=3000" \
        --deployment-configuration "maximumPercent=200,minimumHealthyPercent=100"

  - name: Update ECS service (existing service)
    if: steps.check_service.outputs.exists == 'true'
    run: |
      aws ecs update-service \
        --cluster ${{ inputs.cluster-name }} \
        --service ${{ inputs.service-name }} \
        --task-definition ${{ inputs.service-name }}:${{ steps.register.outputs.revision }} \
        --force-new-deployment
  ```
````

### 🟡 OPTIMIZATION: Update Story 1.4 - IAM Trust Policy Security

**Location:** Update Story 1.4 (OIDC IAM) in `ecs-migration-plan-phase-4-scaling-the-migration.md`

Restrict trust policy to main branch only:

````markdown
- **Restrict trust policy to main branch only (recommended):**

  **⚠️ Security Best Practice: Only allow production deployments from `main` branch**

  ```hcl
  resource "aws_iam_role" "github_actions_deployer" {
    name = "GitHubActionsDeployerRole"

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
            "token.actions.githubusercontent.com:sub" = "repo:my-org/my-repo:ref:refs/heads/main"  # ⚠️ Only main branch
          }
        }
      }]
    })
  }
  ```

  **Why restrict to main branch:**
  - Prevents feature branches from deploying to production
  - Forces deployments through PR review process
  - Limits blast radius of compromised developer accounts
  - Aligns with GitOps best practices

  **Allow multiple branches (if needed):**

  ```hcl
  StringLike = {
    "token.actions.githubusercontent.com:sub" = [
      "repo:my-org/my-repo:ref:refs/heads/main",
      "repo:my-org/my-repo:ref:refs/heads/staging"
    ]
  }
  ```

  **Allow tags (for release deployments):**

  ```hcl
  StringLike = {
    "token.actions.githubusercontent.com:sub" = "repo:my-org/my-repo:ref:refs/tags/v*"
  }
  ```
````

### 🟡 OPTIMIZATION: Update Story 4.1 - Auto-Scaling Tuning

**Location:** Update Story 4.1 (Auto-Scaling) in `ecs-migration-plan-phase-4-scaling-the-migration.md`

Update evaluation periods to prevent GC-induced thrashing:

````markdown
- **Target Tracking Scaling (CPU-based):**

  **⚠️ Use 3-minute evaluation periods to avoid JVM/Node.js GC thrashing**

  ```hcl
  resource "aws_appautoscaling_policy" "ecs_cpu" {
    name               = "cpu-target-tracking"
    policy_type        = "TargetTrackingScaling"
    resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
    scalable_dimension = "ecs:service:DesiredCount"
    service_namespace  = "ecs"

    target_tracking_scaling_policy_configuration {
      predefined_metric_specification {
        predefined_metric_type = "ECSServiceAverageCPUUtilization"
      }

      target_value       = 70.0        # Scale when CPU > 70%
      scale_in_cooldown  = 300         # Wait 5 min before scaling down
      scale_out_cooldown = 60          # Wait 1 min before scaling up again
    }
  }
  ```

  **Why 3-minute evaluation (default) instead of 1-minute:**
  - **JVM Garbage Collection:** Full GC can spike CPU to 100% for 10-30 seconds
  - **Node.js Garbage Collection:** V8 GC can spike CPU to 90% for 5-10 seconds
  - **1-minute evaluation:** Triggers scale-out on every GC cycle → thrashing
  - **3-minute evaluation:** Averages out GC spikes → stable scaling

  **CloudWatch Alarm equivalent (if using alarms instead of target tracking):**

  ```hcl
  resource "aws_cloudwatch_metric_alarm" "cpu_high" {
    alarm_name          = "ecs-cpu-high"
    comparison_operator = "GreaterThanThreshold"
    evaluation_periods  = "3"          # ⚠️ 3 periods of 1 minute = 3 minutes total
    metric_name         = "CPUUtilization"
    namespace           = "AWS/ECS"
    period              = "60"         # 1-minute data points
    statistic           = "Average"
    threshold           = "70"

    dimensions = {
      ClusterName = aws_ecs_cluster.main.name
      ServiceName = aws_ecs_service.app.name
    }
  }
  ```

  **Tuning guide:**

  | App Type                       | GC Behavior                        | Evaluation Periods | Cooldown                        |
  | ------------------------------ | ---------------------------------- | ------------------ | ------------------------------- |
  | **Node.js (Express, Nest.js)** | Frequent minor GC (5-10s spikes)   | 3 periods × 1 min  | 5 min scale-in, 1 min scale-out |
  | **Java (Spring Boot)**         | Infrequent full GC (30-60s spikes) | 3 periods × 1 min  | 5 min scale-in, 1 min scale-out |
  | **Python (Django, Flask)**     | No GC pauses (ref counting)        | 2 periods × 1 min  | 3 min scale-in, 1 min scale-out |
  | **Go**                         | Very fast GC (<10ms pauses)        | 2 periods × 1 min  | 3 min scale-in, 1 min scale-out |
````

---

## Summary of Changes

### Phase 0: Discovery (6 updates)

- ✅ Added Story 9.3: Audit Host Agents & APM
- ✅ Added Story 8.2: Audit Financial Lock-in (EC2 RIs/Savings Plans)
- ✅ Refined Story 9.1: Cron statelessness verification
- ✅ Updated Story 1.2: S3 Gateway Endpoint prominence
- ✅ Updated Story 2.3: Self-referencing security group rules
- ✅ Updated Story 7.1: API rate limits (not just quotas)

### Phase 1: Application Readiness (5 updates)

- ✅ Added Story 1.2: PID 1 / Zombie Process Handling (tini or initProcessEnabled)
- ✅ Updated Story 9.2: Health check suicide pact fix (separate liveness/readiness)
- ✅ Updated Story 11.1: Stronger RDS Proxy recommendation with math
- ✅ Added Story 1.4: Multi-Architecture Builds (Graviton support)
- ✅ Added Story 1.5: Local Dev Parity (docker-compose)

### Phase 2: Infrastructure Setup (4 updates)

- ✅ Updated Story 2.3: Removed Service Connect (conflicts with Strangler Fig)
- ✅ Updated Story 3.2: Seed image port matching application port
- ✅ Added Story 5.3: Deployer Permissions (iam:PassRole)
- ✅ Updated Internal ALB: Allow full VPC CIDR in security group

### Phase 3: Initial Deployment (3 updates)

- ✅ Updated Story 3.1: Added `initProcessEnabled: true` to task definition
- ✅ Updated Story 4.1: Disable circuit breaker on first deployment
- ✅ Updated Story 6.3: Bootstrap dependency handling

### Phase 4: Scaling (4 updates)

- ✅ Updated Story 2.1: DynamoDB locking for Terraform state
- ✅ Updated Story 1.1: CI/CD bootstrap paradox (create vs update service)
- ✅ Updated Story 1.4: IAM trust policy restricted to main branch
- ✅ Updated Story 4.1: Auto-scaling tuned for GC behavior (3-min evaluation)

---

## Next Steps

1. **Review this implementation guide** to ensure accuracy and completeness
2. **Apply changes to actual phase documents** using the content above as a reference
3. **Validate story numbers** - some new stories may shift existing story numbers
4. **Update table of contents** in each phase document if story numbers changed
5. **Cross-reference dependencies** - ensure Phase 1 references (e.g., Story 1.2 PID 1) match Phase 3 implementation (initProcessEnabled)
