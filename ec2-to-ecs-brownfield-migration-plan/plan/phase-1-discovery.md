# ECS Fargate Migration Plan - Phase 0: Discovery & Prerequisites

## Overview

Before writing any code or Dockerfiles, you must audit your existing AWS infrastructure. Fargate has stricter requirements than traditional EC2 deployments. Missing prerequisites will cause tasks to get **stuck in PENDING** with cryptic error messages—or fail silently.

This phase identifies blockers and informs implementation decisions for Phase 1 (Application Readiness) and Phase 2 (Infrastructure Setup).

---

## Feature 1: VPC & Network Topology

**Business Value:** Prevents deployment failures and unplanned costs by validating network requirements upfront. Discovering VPC incompatibilities in Phase 0 (1 day) vs. during deployment (weeks of debugging) saves 2-3 weeks of engineering time and avoids production outages. Proper NAT/VPC Endpoint planning can save $200-500/month in data transfer costs.

### Story 1.1: Audit VPC for Fargate Compatibility

**Business Value:** Avoids the #1 cause of failed Fargate deployments—incorrect network configuration. Tasks stuck in PENDING due to missing NAT Gateway or VPC Endpoints can delay go-live by 1-2 weeks while engineers troubleshoot cryptic error messages.

- **Title:** Verify VPC Meets Fargate Networking Requirements
- **Persona:** As a **DevOps engineer**, I need to verify my existing VPC has the required subnets and routing so that Fargate tasks can start successfully and receive traffic.

- **Requirements:**
  - At least two public subnets (for ALB) across different Availability Zones
  - At least two private subnets (for Fargate tasks) across different Availability Zones
  - **Sufficient IP addresses in subnets to support task scaling**
  - Internet Gateway attached to VPC
  - NAT Gateway (or alternative) for private subnet internet access
  - Route tables configured correctly

- **Implementation Details:**
  - **Public Subnets (for ALB):**
    - Check: Subnets with route table pointing `0.0.0.0/0` → Internet Gateway
    - Why: ALB needs these to accept traffic from the internet
    - Verify: `aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=<subnet-id>"`
  - **Private Subnets (for Fargate Tasks):**
    - Check: Subnets with NO direct route to Internet Gateway
    - Why: Best practice—Fargate tasks should not have public IPs
    - Tasks here cannot be directly reached from the internet
  - **IP Address Requirements (The Hidden Capacity Trap):**
    - **The Problem:** Each Fargate task gets its own ENI (Elastic Network Interface) and consumes an IP address from the subnet
    - **The Symptom:** Tasks fail with "ResourceInitializationError: unable to pull secrets or registry auth" or stuck in PENDING even though everything else is configured correctly
    - **Root Cause:** Subnet ran out of available IPs
    - **AWS IP Reservations:** First 4 IPs and last IP in each subnet are reserved by AWS (unusable)
      - Example: `/28` subnet (16 IPs) → Only 11 IPs available for tasks
      - Example: `/24` subnet (256 IPs) → 251 IPs available for tasks
    - **Calculate Required IPs:**

      ```
      Required IPs = (Max tasks per service × Number of services) × 2

      Why ×2? Rolling deployments run new tasks BEFORE stopping old ones
      Example: Service with 10 tasks deploying new version = 20 IPs during rollout
      ```

    - **Common Subnet Sizing:**
      | CIDR Block | Total IPs | Usable IPs | Recommended For |
      |------------|-----------|------------|-----------------|
      | `/28` | 16 | 11 | ❌ Too small - avoid |
      | `/27` | 32 | 27 | ⚠️ Dev/test only (max ~10 tasks) |
      | `/26` | 64 | 59 | ⚠️ Small production (max ~25 tasks) |
      | `/25` | 128 | 123 | ✅ Medium production (max ~60 tasks) |
      | `/24` | 256 | 251 | ✅ Recommended for production |
      | `/23` | 512 | 507 | ✅ Large production with growth room |

    - **Check Current Subnet Size:**
      ```bash
      aws ec2 describe-subnets --subnet-ids subnet-xxx \
        --query 'Subnets[*].[SubnetId,CidrBlock,AvailableIpAddressCount]' \
        --output table
      ```
    - **If Subnet is Too Small:**
      - **Option 1:** Create new larger subnets, migrate gradually
      - **Option 2:** Use multiple subnets per AZ (ECS can use all subnets you specify)
      - **Option 3:** Reduce desired task count or consolidate services
    - **Best Practice:** Use `/24` or larger for private subnets running Fargate tasks

  - **NAT Gateway (The Hidden Cost Trap):**
    - The Problem: Private subnet tasks have no internet access—they cannot pull Docker images from ECR
    - The Symptom: Tasks stuck in `PENDING` forever, then fail with "CannotPullContainerError"
    - The Fix: NAT Gateway in public subnet, private subnet route table points `0.0.0.0/0` → NAT Gateway
    - Cost Warning: NAT Gateway costs ~$32/month base + $0.045/GB data processing
    - Budget Alternative: Run tasks in public subnet with `assignPublicIp: ENABLED` (less secure, but no NAT cost)
    - Better Alternative: Use VPC Endpoints for ECR, S3, CloudWatch Logs (no NAT needed for AWS services)

- **Acceptance Criteria:**
  - ✅ VPC has at least 2 public subnets in different AZs
  - ✅ VPC has at least 2 private subnets in different AZs
  - ✅ **Each subnet has sufficient IP addresses (at least /24 recommended for production)**
  - ✅ **Available IP count per subnet documented**
  - ✅ **Maximum task capacity calculated: (Available IPs ÷ 2) per subnet**
  - ✅ Private subnets can reach the internet (via NAT or public IP assignment)
  - ✅ Decision documented: NAT Gateway vs Public IP vs VPC Endpoints

---

### Story 1.2: Document AWS Service Dependencies

**Business Value:** Prevents deployment failures by identifying all AWS services the application depends on, ensuring network connectivity is planned correctly. Missing dependencies discovered during migration cause 30-40% of failed deployments and 2-4 hour rollback cycles. Documenting upfront enables proper VPC endpoint planning in Phase 2.

- **Title:** Inventory AWS Service Dependencies for Network Planning
- **Persona:** As a **cloud architect**, I need to identify all AWS services the application calls so that network connectivity (NAT Gateway, VPC Endpoints) can be configured correctly in Phase 2.

- **Requirements:**
  - Identify all AWS SDK calls in application code
  - Document external AWS services accessed (S3, SES, DynamoDB, etc.)
  - List required services for Fargate runtime (ECR, CloudWatch Logs, Secrets Manager)
  - Understand outbound dependencies for third-party APIs

- **Implementation Details:**
  - **Search codebase for AWS SDK usage:**

    ```bash
    # Node.js
    grep -r "require.*aws-sdk" .
    grep -r "from.*@aws-sdk" .

    # Python
    grep -r "import boto3" .
    grep -r "from boto" .

    # Check which services are used
    grep -r "\.s3\." .
    grep -r "\.ses\." .
    grep -r "\.dynamodb\." .
    ```

  - **Fargate Runtime Requirements (always needed):**
    - ECR (Docker image pulls) - uses S3 for layer storage
    - CloudWatch Logs (application logging)
    - Secrets Manager or SSM Parameter Store (if using for secrets)
  - **Common Application Dependencies:**
    - **S3** - File storage, uploads, static assets
    - **SES** - Email sending
    - **DynamoDB** - NoSQL database
    - **SNS/SQS** - Messaging/queues
    - **Lambda** - Serverless function invocations
    - **Step Functions** - Workflow orchestration
  - **Third-Party/External APIs:**
    - Payment processors (Stripe, PayPal)
    - Monitoring (Datadog, New Relic, Honeycomb)
    - Analytics (Segment, Mixpanel)
    - Authentication (Auth0, Okta)
    - Note: These require outbound internet access via NAT Gateway or Proxy
  - **Document findings:**
    Create a simple table:

    | Service         | Purpose        | Required? | Network Path        |
    | --------------- | -------------- | --------- | ------------------- |
    | ECR             | Docker images  | Yes       | VPC Endpoint or NAT |
    | S3              | File uploads   | Yes       | VPC Endpoint (free) |
    | CloudWatch Logs | Logging        | Yes       | VPC Endpoint or NAT |
    | Secrets Manager | DB credentials | Yes       | VPC Endpoint or NAT |
    | SES             | Email sending  | Yes       | NAT or VPC Endpoint |
    | Stripe API      | Payments       | Yes       | NAT (internet)      |
    | Honeycomb       | Monitoring     | Yes       | NAT (internet)      |

- **Acceptance Criteria:**
  - ✅ All AWS SDK calls identified in codebase
  - ✅ Fargate runtime dependencies documented (ECR, Logs, Secrets)
  - ✅ Application AWS service usage documented
  - ✅ External/third-party API dependencies listed
  - ✅ Findings documented for Phase 2 network planning

---

## Feature 2: Security Group Planning

**Business Value:** Prevents database connection failures on day one of migration, avoiding emergency troubleshooting during critical cutover windows. Planning security groups correctly upfront (2-3 hours) vs. debugging connection failures in production (4-8 hours downtime) protects revenue and customer trust. Proper least-privilege design also reduces security audit findings.

### Story 2.0: Discover and Inventory Data Stores

- **Title:** Identify All RDS, ElastiCache, and Other Data Stores
- **Persona:** As a **DevOps engineer**, I need to discover all databases and caches in the AWS account so that I understand what data stores the application depends on and can plan network/security configurations.

- **Requirements:**
  - Discover all RDS instances in the account/region
  - Discover all ElastiCache clusters in the account/region
  - Determine which data stores are used by the application being migrated
  - Document connection details and VPC placement
  - Identify any other data stores (DocumentDB, DynamoDB, OpenSearch, etc.)

- **Implementation Details:**
  - **Discover RDS instances:**

    ```bash
    # List all RDS instances
    aws rds describe-db-instances \
      --query 'DBInstances[*].[DBInstanceIdentifier,Engine,EngineVersion,DBInstanceClass,Endpoint.Address,DBSubnetGroup.VpcId,DBInstanceStatus]' \
      --output table

    # Get detailed info for specific instance
    aws rds describe-db-instances \
      --db-instance-identifier <your-db-name>
    ```

  - **Discover ElastiCache clusters:**

    ```bash
    # List Redis clusters
    aws elasticache describe-cache-clusters \
      --query 'CacheClusters[*].[CacheClusterId,Engine,EngineVersion,CacheNodeType,ConfigurationEndpoint.Address,CacheSubnetGroupName]' \
      --output table

    # Get subnet group details (shows VPC)
    aws elasticache describe-cache-subnet-groups \
      --cache-subnet-group-name <subnet-group-name>
    ```

  - **For each data store, document:**
    - **Resource ID/Name**: What it's called in AWS
    - **Type**: RDS (Postgres/MySQL/etc.), ElastiCache (Redis/Memcached), etc.
    - **VPC ID**: Which VPC is it in?
    - **Subnet Group**: Which subnets does it span?
    - **Endpoint**: Connection string/hostname
    - **Port**: Default or custom port
    - **Used by which app(s)**: Which application(s) connect to it?
    - **Purpose**: What's it used for? (user data, sessions, cache, etc.)
  - **Determine if the data store will be used by Fargate:**
    - Check application code/config for database connections
    - Check `.env` files or environment variables for `DATABASE_URL`, `REDIS_URL`, etc.
    - SSH to EC2 and check: `netstat -tn | grep :5432` (Postgres), `grep :6379` (Redis)
  - **Cross-VPC scenarios:**
    - If data store is in a different VPC than where Fargate will run:
      - **Option 1:** Use VPC Peering to connect the VPCs
      - **Option 2:** Migrate data store to same VPC (complex, requires downtime planning)
      - **Option 3:** Use AWS PrivateLink (if applicable)
    - Document this as a blocker requiring resolution in Phase 2
  - **Other data stores to check:**
    - **DynamoDB**: `aws dynamodb list-tables` (VPC endpoints may be needed for private subnets)
    - **DocumentDB**: `aws docdb describe-db-clusters`
    - **OpenSearch**: `aws opensearch list-domain-names`
    - **S3**: `aws s3 ls` (check if app reads/writes to specific buckets)

- **Acceptance Criteria:**
  - ✅ All RDS instances discovered and documented
  - ✅ All ElastiCache clusters discovered and documented
  - ✅ Each data store's VPC placement verified
  - ✅ Application dependencies on each data store documented
  - ✅ Cross-VPC scenarios identified with resolution plan
  - ✅ Other data stores (DynamoDB, S3, OpenSearch, etc.) inventoried
  - ✅ Connection endpoints and ports documented for Phase 1 app configuration

---

### Story 2.1: Audit Database Security Groups

**Business Value:** Eliminates the most common post-deployment failure: "application can't connect to database." This single issue causes 60% of failed ECS migrations to rollback within the first hour. Planning this correctly prevents emergency rollbacks and associated revenue loss.

- **Title:** Verify RDS/Database Allows Fargate Task Connections
- **Persona:** As a **DevOps engineer**, I need to verify that database security groups will allow connections from Fargate tasks so that the application can connect after migration.

- **Requirements:**
  - Identify the security group(s) attached to RDS/databases
  - Understand current inbound rules (likely allows EC2 instance SG or IP)
  - Plan new rules to allow Fargate task security group

- **Implementation Details:**
  - Current state: RDS probably allows inbound from EC2 instance's security group or specific IP
  - Problem: Fargate tasks will have a NEW security group—RDS won't allow connections
  - Check current rules: `aws ec2 describe-security-groups --group-ids <rds-sg-id>`
  - Plan: Create Fargate task security group, add inbound rule to RDS SG allowing that group
  - Same applies to: ElastiCache (Redis), OpenSearch, any other data stores

- **Acceptance Criteria:**
  - ✅ All database/cache security groups identified
  - ✅ Current inbound rules documented
  - ✅ Plan created for adding Fargate task SG to allowed sources

---

### Story 2.2: Audit ElastiCache Security Groups

**Business Value:** Protects user experience by ensuring session storage works correctly. Failed Redis connections cause users to be logged out unexpectedly, resulting in support tickets, abandoned transactions, and negative reviews. Planning this correctly prevents customer churn during migration.

- **Title:** Verify ElastiCache Allows Fargate Task Connections
- **Persona:** As a **DevOps engineer**, I need to verify that ElastiCache security groups will allow connections from Fargate tasks so that session storage and caching work after migration.

- **Requirements:**
  - Identify ElastiCache clusters and their security groups
  - Verify subnet groups are in the same VPC as Fargate tasks
  - Plan security group updates

- **Implementation Details:**
  - Check: Is ElastiCache in the same VPC as your planned Fargate deployment?
  - Check: What security group is attached? What are the inbound rules?
  - ElastiCache Subnet Group must include subnets where Fargate tasks will run
  - If ElastiCache is in a different VPC: requires VPC Peering or migration

- **Acceptance Criteria:**
  - ✅ ElastiCache clusters identified and VPC confirmed
  - ✅ Security group inbound rules documented
  - ✅ Subnet group includes Fargate task subnets (or plan to update)

---

### Story 2.3: Audit Application Security Groups

**Business Value:** Enables safe, reversible migration by isolating EC2 and Fargate infrastructure. Creating separate security groups (30 minutes) vs. sharing SGs allows instant rollback to EC2 if issues arise, protecting business continuity. Also simplifies troubleshooting and reduces blast radius of security changes.

- **Title:** Inventory Existing Application Security Groups
- **Persona:** As a **DevOps engineer**, I need to audit existing security groups for each application so that I can decide whether to reuse them for Fargate or create new ones.

- **Requirements:**
  - Identify security groups currently attached to EC2 application instances
  - Document inbound/outbound rules for each
  - Determine if existing SGs can be reused for Fargate tasks
  - Plan security group strategy for migration
  - Verify security groups allow self-referencing traffic (task-to-task communication)

- **Implementation Details:**
  - **For each application, document:**
    - Security group ID and name
    - Inbound rules (ports, sources)
    - Outbound rules
    - What other resources reference this SG (databases, caches, etc.)
  - **Check existing SGs:**

    ```bash
    # List security groups for an EC2 instance
    aws ec2 describe-instances --instance-ids i-xxx \
      --query 'Reservations[].Instances[].SecurityGroups[]'

    # Get details of a security group
    aws ec2 describe-security-groups --group-ids sg-xxx
    ```

  - **Decision: Reuse existing SG or create new?**
    | Factor | Reuse Existing | Create New |
    |--------|---------------|------------|
    | **Migration safety** | Risk: changes might break EC2 | Safe: EC2 and Fargate isolated |
    | **Simplicity** | Fewer SGs to manage | More SGs, but cleaner separation |
    | **Rollback** | Harder to isolate issues | Easy to isolate Fargate issues |
    | **Post-migration cleanup** | Already in place | Delete old EC2 SG after migration |
  - **Recommendation:** Create new Fargate-specific SGs during migration. This isolates EC2 and Fargate, making troubleshooting and rollback easier. After migration, delete the old EC2 SGs.
  - **If reusing existing SG:**
    - Add inbound rule: Allow ALB security group on app port
    - Verify outbound rules allow necessary traffic
    - Both EC2 and Fargate tasks will use the same SG
  - **If creating new SG:**
    - Name: `[app-name]-fargate-sg` (e.g., `auth-api-fargate-sg`)
    - Update database/cache SGs to allow the NEW Fargate SG
    - Keep EC2 SG intact until migration complete
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

- **Acceptance Criteria:**
  - ✅ All application EC2 security groups documented
  - ✅ Inbound/outbound rules documented for each
  - ✅ Decision made per app: reuse existing or create new
  - ✅ List of new security groups to create documented for Phase 2

---

## Feature 3: IAM Role Discovery

**Business Value:** Prevents service disruptions from permission errors. Applications failing due to missing IAM permissions (common in Fargate migrations) result in 100% error rates and immediate rollback requirements. Planning IAM correctly (1-2 hours) vs. emergency troubleshooting (4-6 hours downtime) protects SLAs and customer experience.

### Story 3.1: Identify Required IAM Roles

**Business Value:** Ensures application functionality isn't lost during migration. Services that work on EC2 with broad permissions often fail on Fargate with minimal roles, breaking features like file uploads (S3), emails (SES), or background jobs (SQS). Identifying requirements upfront prevents feature regression.

- **Title:** Plan ECS Task Execution Role and Task Role
- **Persona:** As a **DevOps engineer**, I need to understand the IAM roles required for Fargate so that tasks can pull images, write logs, and access AWS services.

- **Requirements:**
  - Understand the difference between Task Execution Role and Task Role
  - Inventory AWS services the application currently uses
  - Plan IAM policies for each role

- **Implementation Details:**
  - **Task Execution Role** (used by ECS agent, not your app):
    - Required permissions: Pull images from ECR, write to CloudWatch Logs
    - If using Secrets Manager: `secretsmanager:GetSecretValue`
    - If using SSM Parameter Store: `ssm:GetParameters`
    - AWS provides managed policy: `AmazonECSTaskExecutionRolePolicy`
  - **Task Role** (used by your application code):
    - Whatever your app needs: S3 access, SES sending, DynamoDB, etc.
    - Audit current EC2 instance role or hardcoded credentials
    - Check for: S3 buckets, SQS queues, SNS topics, DynamoDB tables, SES, etc.
  - Common trap: App works on EC2 with broad permissions, fails on Fargate with minimal role

- **Acceptance Criteria:**
  - ✅ List of AWS services used by application documented
  - ✅ Task Execution Role permissions planned
  - ✅ Task Role permissions planned
  - ✅ No hardcoded AWS credentials in application (use IAM roles)

---

## Feature 4: Container Registry Planning

**Business Value:** Controls storage costs and establishes deployment traceability. Unmanaged ECR repositories can accumulate hundreds of unused images, costing $10-50/month unnecessarily. Proper lifecycle policies (30 minutes to configure) prevent cost creep and enable instant rollback to previous image versions, reducing MTTR (Mean Time To Recovery) from hours to minutes.

### Story 4.1: Plan ECR Repository Strategy

**Business Value:** Enables fast, safe deployments with audit trails. Consistent naming and tagging strategy (SHA-based) allows teams to trace exactly which code is running in production, critical for compliance, debugging, and incident response. Reduces incident resolution time by 50% by eliminating "what version is deployed?" questions.

- **Title:** Define ECR Repository Naming and Lifecycle Strategy
- **Persona:** As a **DevOps engineer**, I need to plan the ECR repository structure so that the infrastructure team knows what to create in Phase 2.

- **Requirements:**
  - Decide on repository naming convention
  - Decide on image tagging strategy
  - Plan lifecycle policies to control storage costs
  - Determine if image scanning is required

- **Implementation Details:**
  - **Check if repositories already exist:**
    - `aws ecr describe-repositories`
    - If migrating from another registry, note current image locations
  - **Naming convention decision:**
    - Option A: `<app-name>` (e.g., `auth-api`)
    - Option B: `<namespace>/<app-name>` (e.g., `legacy-migration/auth-api`)
    - Recommendation: Use namespace to group related apps
  - **Tagging strategy decision:**
    - `latest` — Simple but risky (can't rollback easily)
    - Git SHA — Traceable to exact commit
    - Semantic version — Good for releases
    - Recommendation: Use git SHA for deployments, `latest` for convenience
  - **Lifecycle policy planning:**
    - Keep last N tagged images (e.g., 10-20)
    - Delete untagged images after N days (e.g., 7)
    - Why: ECR storage costs add up; old images rarely needed
  - **Image scanning decision:**
    - Enable scan-on-push? (Recommended: Yes)
    - Block deployment on critical CVEs? (Decide based on security policy)

- **Acceptance Criteria:**
  - ✅ Repository naming convention decided
  - ✅ Image tagging strategy decided
  - ✅ Lifecycle policy parameters defined
  - ✅ Image scanning requirements documented
  - ✅ List of repositories to create documented for Phase 2

---

## Feature 5: Secrets & Configuration Audit

**Business Value:** Eliminates security vulnerabilities and prevents compliance violations. Hardcoded secrets in code or Docker images create audit findings and security incidents (average cost: $50K-200K per breach). Moving to Secrets Manager (1 day effort) achieves SOC2/HIPAA compliance requirements and prevents credential leaks. Also enables secure secret rotation without application restarts.

### Story 5.1: Document Secret Requirements

**Business Value:** Creates high-level inventory of what secrets and configuration types are needed, enabling proper Secrets Manager planning in Phase 2. This 30-minute exercise prevents discovering missing secrets during deployment (causing rollback delays) and ensures Phase 1 developers know what to externalize.

- **Title:** Document Secret Types and Configuration Needs
- **Persona:** As a **cloud architect**, I need to understand what types of secrets the application uses so that I can plan Secrets Manager structure and IAM permissions in Phase 2.

- **Requirements:**
  - Identify secret categories (database, API keys, tokens, certificates)
  - Document where secrets currently live (EC2 files, environment variables)
  - List third-party integrations requiring credentials
  - Plan secret storage strategy (Secrets Manager vs SSM Parameter Store)

- **Implementation Details:**
  - **High-level inventory (no code diving yet):**
    - SSH to EC2 and list `.env` files and config directories
    - Check systemd/supervisor configs for environment variable usage
    - Document known integrations (Stripe, SendGrid, etc.)
  - **Categorize secret types:**
    - **Secrets** (DB passwords, API keys, tokens) → Secrets Manager
    - **Sensitive config** (internal URLs, feature flags) → SSM Parameter Store
    - **Non-sensitive config** (log levels, timeouts) → ECS Task Definition environment
  - **Create simple inventory table:**

    | Secret Type      | Current Location | Destination     | Notes              |
    | ---------------- | ---------------- | --------------- | ------------------ |
    | DB Password      | `/app/.env`      | Secrets Manager | RDS credentials    |
    | Stripe API Key   | `/app/.env`      | Secrets Manager | Payment processing |
    | Redis Password   | Systemd config   | Secrets Manager | ElastiCache        |
    | SendGrid API Key | `/app/.env`      | Secrets Manager | Email service      |
    | Log Level        | `.env`           | Task Definition | Non-sensitive      |

  - **Note:** Actual code scanning for hardcoded secrets happens in Phase 1, Story 2.1

- **Acceptance Criteria:**
  - ✅ Secret types documented (database, API keys, integrations)
  - ✅ Current storage locations identified (files, configs)
  - ✅ Planned destination documented (Secrets Manager, SSM, Task Def)
  - ✅ Inventory shared with Phase 1 team for implementation

---

## Feature 6: Domain & Certificate Planning

**Business Value:** Enables zero-downtime cutover to Fargate infrastructure. Proper DNS and SSL planning (2-3 hours) allows gradual traffic shifting with instant rollback capability, minimizing risk to revenue. ACM certificates eliminate $50-500/year SSL renewal costs and prevent certificate expiration outages (which cause 100% service downtime).

### Story 6.1: Audit DNS and SSL Certificates

**Business Value:** Prevents website downtime and browser security warnings. Expired or misconfigured SSL certificates cause immediate loss of customer trust and can result in 100% traffic loss (browsers block access). Planning ACM certificates correctly ensures automatic renewal and eliminates manual certificate management overhead (4-8 hours/year).

- **Title:** Plan Domain and Certificate Migration
- **Persona:** As a **DevOps engineer**, I need to understand the current DNS and SSL setup so that I can plan the cutover to ALB without downtime.

- **Requirements:**
  - Identify current domain(s) pointing to EC2
  - Identify current SSL certificate (where is it? how is it managed?)
  - Plan ACM certificate for ALB
  - Plan DNS cutover strategy

- **Implementation Details:**
  - **Current state audit:**
    - Where does DNS point? (EC2 public IP, Elastic IP, existing ELB?)
    - Where is SSL terminated? (EC2 nginx, existing ELB?)
    - Who manages the certificate? (Let's Encrypt, manual, ACM?)
  - **For ALB, you need:**
    - ACM certificate in the same region as ALB
    - If using existing domain: request ACM cert, validate via DNS
    - ACM certs are free and auto-renew
  - **DNS cutover options:**
    - Blue/green: Point to ALB, keep EC2 as fallback
    - Weighted routing: Gradually shift traffic (requires Route 53)
    - Hard cutover: Update DNS, accept brief propagation delay

- **Acceptance Criteria:**
  - ✅ Current DNS configuration documented
  - ✅ Current SSL certificate source documented
  - ✅ ACM certificate requested (or plan to request)
  - ✅ DNS cutover strategy selected

---

## Feature 7: Service Quotas & Limits

**Business Value:** Prevents blocked deployments and scaling failures. AWS quota increases require 1-3 business days to process. Discovering quota limits during deployment (blocked launch) vs. Phase 0 planning (proactive request) is the difference between on-time delivery and multi-day delays. Protects project timelines and prevents emergency escalations.

### Story 7.1: Check AWS Service Quotas

**Business Value:** Avoids deployment day surprises that halt production launches. Running out of Fargate vCPU quota or hitting ECS service limits during Black Friday or product launch would result in lost revenue and reputational damage. 15 minutes of quota checking prevents catastrophic scaling failures during peak traffic.

- **Title:** Verify Fargate Service Quotas
- **Persona:** As a **DevOps engineer**, I need to verify AWS service quotas so that I don't hit limits when deploying or scaling.

- **Requirements:**
  - Check Fargate vCPU quota for the region
  - Check ECS service/cluster limits
  - Check ALB limits if creating new load balancers
  - Request increases if needed (can take days)
  - Check AWS API rate limits (not just resource quotas)

- **Implementation Details:**
  - Key quotas to check:
    - `Fargate On-Demand vCPU resource count` (default: 1000 per region)
    - `Services per cluster` (default: 5000)
    - `Tasks per service` (default: 5000)
    - `Application Load Balancers per region` (default: 50)
    - `Target Groups per ALB` (default: 100)
  - Check via: AWS Console → Service Quotas → Amazon ECS
  - Or: `aws service-quotas list-service-quotas --service-code ecs`
  - Request increase: Console or `aws service-quotas request-service-quota-increase`
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

- **Acceptance Criteria:**
  - ✅ Current quota usage documented
  - ✅ Projected usage calculated (tasks × vCPU per task)
  - ✅ Quota increase requested if needed (allow 1-3 days)

---

## Feature 8: Cost Estimation

**Business Value:** Secures budget approval and prevents cost overruns. Accurate cost estimates (2-3 hours) enable CFO/stakeholder buy-in for migration investment. Underestimating costs leads to mid-project budget freezes or forced rollbacks. Typical Fargate migrations show 10-30% cost increase vs. EC2, but operational savings (no patching, auto-scaling, faster deployments) deliver 200-300% ROI within 12 months.

### Story 8.1: Estimate Fargate Migration Costs

**Business Value:** Prevents sticker shock and enables informed decision-making. Comparing total cost of ownership (Fargate compute + operational savings from automation) vs. current EC2 costs justifies migration investment to finance stakeholders. Accurate forecasts prevent budget overruns that could halt the project mid-flight.

- **Title:** Calculate Expected Fargate Costs
- **Persona:** As a **project stakeholder**, I need to understand the cost implications of migrating to Fargate so that I can budget appropriately and avoid surprises.

- **Requirements:**
  - Estimate Fargate task costs (vCPU + memory)
  - Estimate NAT Gateway or VPC Endpoint costs
  - Estimate ALB costs
  - Compare to current EC2 costs

- **Implementation Details:**
  - **Fargate pricing (us-east-1, as of 2024):**
    - vCPU: $0.04048 per vCPU per hour
    - Memory: $0.004445 per GB per hour
    - Example: 0.5 vCPU + 1GB RAM = ~$21/month running 24/7
  - **ALB pricing:**
    - $0.0225 per hour (~$16/month)
    - $0.008 per LCU-hour (usage-based)
  - **NAT Gateway:**
    - $0.045 per hour (~$32/month)
    - $0.045 per GB processed
  - **Compare to current EC2:**
    - t3.small: ~$15/month
    - t3.medium: ~$30/month
    - But: EC2 doesn't include load balancer, auto-scaling complexity, etc.
  - **Hidden costs to consider:**
    - CloudWatch Logs storage and ingestion
    - ECR storage (usually minimal)
    - Secrets Manager: $0.40 per secret per month
    - Data transfer between AZs

- **Acceptance Criteria:**
  - ✅ Monthly Fargate cost estimated
  - ✅ NAT Gateway vs VPC Endpoint cost decision documented
  - ✅ Total migration cost compared to current EC2 cost
  - ✅ Stakeholder approval on budget

---

### Story 8.2: Audit EC2 Reserved Instances and Savings Plans

**Business Value:** Prevents paying for unused infrastructure commitments, saving $5K-50K+ during migration overlap period. Identifying active RIs with 12+ months remaining allows strategic timing (wait for expiration) or mitigation (sell on RI Marketplace), optimizing financial efficiency. Failure to audit RIs results in double-spend: paying for idle EC2 RIs PLUS new Fargate costs.

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

## Feature 9: Inventory Existing Infrastructure

**Business Value:** Prevents forgotten services from breaking during migration, protecting uptime and user experience. Cron jobs, background workers, and monitoring agents often run on EC2 but aren't documented—migrating without accounting for them causes silent failures (reports don't generate, alerts don't fire, jobs don't run). 3-4 hours of inventory prevents weeks of "why isn't X working?" troubleshooting post-migration.

### Story 9.1: Document Current EC2 Application Architecture

**Business Value:** Creates the migration blueprint and risk assessment. Knowing exactly what runs on EC2 (web servers, cron jobs, workers, agents) prevents scope creep and forgotten components. This inventory becomes the checklist that ensures 100% migration coverage, eliminating "surprise" services discovered post-cutover that require emergency migrations.

- **Title:** Inventory Current EC2 Deployment
- **Persona:** As a **DevOps engineer**, I need to fully document the current EC2 setup so that nothing is missed during migration.

- **Requirements:**
  - Document all processes running on EC2
  - Document all cron jobs
  - Document all open ports and services
  - Document any local state or files

- **Implementation Details:**
  - **SSH to EC2 and run:**
    - `systemctl list-units --type=service --state=running` (running services)
    - `crontab -l` and `cat /etc/crontab` (scheduled jobs)
    - `netstat -tlnp` or `ss -tlnp` (open ports)
    - `df -h` (disk usage, identify data directories)
    - `ls -la /var/www/` or application directory
    - `cat /etc/nginx/sites-enabled/*` (nginx config)
    - `cat /etc/supervisor/conf.d/*` (if using supervisor)
  - **Document for each process:**
    - What it does
    - How it starts
    - What ports it uses
    - What it depends on
    - Whether it needs to be a separate ECS service

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

- **Acceptance Criteria:**
  - ✅ All running services documented
  - ✅ All cron jobs documented with schedules
  - ✅ **Cron jobs verified as stateless or refactored to use external state (S3/DynamoDB/RDS)**
  - ✅ **Cron jobs tested to run successfully multiple times without side effects**
  - ✅ All open ports documented
  - ✅ Local data directories identified and migration plan created

---

### Story 9.2: Audit Current Logging Setup and Consumers

**Business Value:** Protects observability and compliance during migration. Log shippers, SIEM integrations, and compliance tools often read directly from log files on EC2—switching to stdout logging without updating consumers breaks dashboards, alerts, and audit trails. Identifying log consumers upfront (1 hour) prevents blindness during the most critical migration window when monitoring is essential.

- **Title:** Document Current Logging Configuration and Downstream Dependencies
- **Persona:** As a **DevOps engineer**, I need to understand how logs are currently written, stored, and consumed so that I can ensure logging continues to work on both EC2 and ECS during migration.

- **Requirements:**
  - Document where application logs are written today
  - Identify any systems that read/scrape/ship these logs
  - Understand log retention and rotation policies
  - Plan backward-compatible logging changes

- **Implementation Details:**
  - **Audit current log destinations:**
    - Where does the app write logs? (file path, stdout, syslog?)
    - `ls -la /var/log/` — check for app-specific log files
    - Check app config for logging settings (winston, log4j, monolog, etc.)
    - Check nginx/apache access and error log locations
  - **Audit log consumers (critical!):**
    - Is there a log shipper? (Filebeat, Fluentd, CloudWatch Agent, Datadog Agent?)
    - What files is it watching?
    - Where does it ship logs to? (ELK, Splunk, CloudWatch, Datadog?)
    - Are there any dashboards or alerts built on these logs?
    - Are there any scripts or tools that parse log files directly?
  - **Audit log rotation:**
    - Check `/etc/logrotate.d/` for app log rotation configs
    - How long are logs retained?
    - Any compliance requirements for log retention?
  - **Audit process manager log handling:**
    - If using systemd: `journalctl -u <service>` — stdout already captured
    - If using PM2: `~/.pm2/logs/` — stdout already captured
    - If using supervisor: check `stdout_logfile` in config
  - **Key questions to answer:**
    - If we switch to stdout logging, will log consumers still work?
    - Do we need to update log shipper configs?
    - Are there any file-path-dependent integrations that will break?

- **Acceptance Criteria:**
  - ✅ Current log file locations documented
  - ✅ All log consumers/shippers identified
  - ✅ Log shipping destinations documented (ELK, Splunk, CloudWatch, etc.)
  - ✅ Impact assessment: what breaks if we switch to stdout?
  - ✅ Migration plan for log consumers documented

---

### Story 9.3: Audit Host-Level Agents and APM Tools

**Business Value:** Preserves security posture and operational visibility during migration. Security agents (CrowdStrike, Qualys), APM tools (Datadog, New Relic), and monitoring agents provide critical protection and insights—losing them during migration creates security gaps and blind spots. Planning agent migration (2-3 hours) vs. discovering monitoring gaps in production (high-severity incidents with no visibility) protects compliance and incident response capabilities.

- **Title:** Inventory OS-Level Monitoring and Security Agents
- **Persona:** As a **DevOps engineer**, I need to audit all host-level agents running on EC2 so that I can plan their migration to sidecar containers or AWS-native alternatives, avoiding blind spots in observability and security after moving to Fargate.

- **Requirements:**
  - Identify all running agents on EC2 instances (APM, monitoring, security)
  - Determine which agents are compatible with Fargate
  - Plan migration strategy for each agent (sidecar, AWS native, or discontinue)
  - Update application architecture to include sidecars where needed

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

## Feature 10: Rollback & Cutover Planning

**Business Value:** Provides insurance policy for migration, dramatically reducing risk. Clear rollback procedures (2 hours to document) mean migration failures result in 5-10 minute rollbacks vs. hours of panic troubleshooting. This confidence enables aggressive migration timelines and protects customer SLAs. Knowing you can instantly revert means stakeholders approve migration even for critical systems.

### Story 10.1: Define Rollback Strategy

**Business Value:** Turns high-risk migration into low-risk deployment. With documented rollback (DNS revert, EC2 standby), migration failures cost 10 minutes of downtime instead of hours of emergency troubleshooting. This safety net enables migrations during business hours instead of requiring expensive weekend/night deployments, saving operational costs and improving team morale.

- **Title:** Plan Migration Rollback Procedure
- **Persona:** As an **operations engineer**, I need a documented rollback plan so that if Fargate deployment fails, we can quickly revert to EC2 with minimal downtime.

- **Requirements:**
  - EC2 instance must remain running during initial Fargate deployment
  - DNS cutover must be reversible
  - Database must not have breaking schema changes
  - Clear criteria for when to rollback

- **Implementation Details:**
  - **Rollback strategy:**
    - Keep EC2 instance running (but not receiving traffic) for 1-2 weeks post-migration
    - Use DNS-based cutover (easy to revert)
    - Avoid database migrations that break backward compatibility during cutover window
  - **Cutover steps:**
    1. Deploy to Fargate, verify health checks pass
    2. Test via ALB DNS name directly
    3. Update DNS to point to ALB
    4. Monitor for 24-48 hours
    5. If issues: revert DNS to EC2
    6. After stability period: terminate EC2 instance
  - **Rollback triggers:**
    - Error rate above X%
    - Latency above X ms
    - Critical functionality broken
    - Data integrity issues

- **Acceptance Criteria:**
  - ✅ Rollback procedure documented
  - ✅ Rollback triggers defined with thresholds
  - ✅ EC2 retention period agreed (e.g., 2 weeks)
  - ✅ Team knows how to execute rollback

---

## Feature 11: Service-to-Service Communication Audit

**Business Value:** Prevents performance degradation and unnecessary costs from inefficient traffic routing. Internal service calls that hairpin through the internet (service → NAT → ALB → service) add 100-500ms latency and incur NAT data transfer fees ($50-200/month). Planning internal communication correctly (2-3 hours) improves response times by 40-60% and reduces infrastructure costs, directly impacting user experience and margins.

### Story 11.1: Inventory Internal Service Calls

**Business Value:** Identifies hidden performance bottlenecks before they impact users. Services calling each other via public URLs instead of internal DNS add unnecessary latency (100-500ms per request) and create NAT data transfer costs. Discovering this pattern in Phase 0 allows architecture improvements that enhance user experience and reduce monthly costs by $100-300.

- **Title:** Audit How Applications Communicate Internally
- **Persona:** As a **DevOps engineer**, I need to understand how our applications call each other today so that I can ensure internal traffic stays in the VPC after migration and doesn't accidentally hairpin through the internet.

- **Requirements:**
  - Identify all service-to-service communication patterns
  - Document the URLs/endpoints each app uses to call other internal services
  - Determine if calls use public URLs or private IPs/hostnames
  - Plan internal communication strategy for ECS

- **Implementation Details:**
  - **Audit current state:**
    - Search codebase for HTTP client calls to other internal services
    - Check environment variables for service URLs (e.g., `AUTH_API_URL`, `USER_SERVICE_URL`)
    - Review nginx/proxy configs for upstream definitions
    - Check `/etc/hosts` for any hostname mappings
  - **Common patterns to look for:**
    - `http://10.x.x.x:3000/...` (private IP — good, but won't work with dynamic ECS tasks)
    - `http://auth-api.internal:3000/...` (private DNS — ideal)
    - `https://api.example.com/auth/...` (public URL — BAD for internal calls)
  - **The trap:**
    - If services call each other via the public ALB URL, traffic goes: Task → NAT Gateway → Internet → ALB → Target task
    - This is slow, costly (NAT data transfer fees), and breaks if NAT/internet has issues
    - Traffic should stay inside the VPC
  - **Document for each service:**
    - What other internal services does it call?
    - What URL pattern does it use?
    - Is it configurable via environment variable?

- **Acceptance Criteria:**
  - ✅ All internal service-to-service calls documented
  - ✅ Current URL patterns identified (public vs private)
  - ✅ Services with public URL patterns flagged for update
  - ✅ Internal communication strategy selected for ECS

---

### Story 11.2: Plan Internal Communication Strategy

**Business Value:** Optimizes internal traffic for speed and cost-efficiency. Internal ALB costs $16/month but saves $100-300/month in NAT fees while improving latency by 40-60%. This decision (1 hour of planning) pays for itself immediately and scales with service growth. Proper service discovery also enables modern microservices architecture, supporting future business agility.

- **Title:** Select ECS Internal Communication Pattern
- **Persona:** As a **cloud architect**, I need to select the internal communication strategy for ECS so that service-to-service calls are fast, reliable, and stay within the VPC.

- **Requirements:**
  - Evaluate options for internal service discovery
  - Select approach based on complexity and requirements
  - Plan implementation for Phase 2 (infrastructure) and Phase 3 (deployment)

- **Implementation Details:**
  - **Option 1: Internal Application Load Balancer (Recommended)**
    - Create a second ALB, internal-facing only (not internet-facing)
    - Use same host-based routing pattern as external ALB
    - Services call: `http://internal-alb.yourcompany.local/service-name/endpoint`
    - Pros:
      - Familiar pattern (same as external ALB)
      - Single stable DNS name
      - Health checks built-in
      - Easy to implement — just add another ALB
      - Apps only need env var change (`SERVICE_URL=http://internal-alb/...`)
    - Cons:
      - Extra ALB cost (~$16/month + LCU charges)
      - Extra hop (task → ALB → task)
    - Security: Internal ALB only accessible from within VPC (security group restricts to VPC CIDR)
  - **Option 2: AWS Cloud Map (Service Discovery)**
    - Register services with Cloud Map namespace (e.g., `services.local`)
    - Services call: `http://auth-api.services.local:3000/endpoint`
    - DNS resolves directly to task private IP
    - Pros:
      - No extra ALB hop (direct task-to-task)
      - Lower latency
      - No additional ALB cost
    - Cons:
      - More complex setup
      - No built-in load balancing (relies on DNS round-robin or client-side)
      - Requires ECS Service Discovery configuration
    - Best for: High-volume internal traffic, latency-sensitive calls
    - Consider as Phase 4 optimization after Internal ALB is working
  - **Option 3: Environment Variables with Task IPs**
    - Not recommended — ECS tasks get dynamic IPs, would need constant updates

- **Recommendation:**
  - Start with Internal ALB (Option 1) — simpler, familiar, works reliably
  - If internal traffic volume is high and latency matters, add Cloud Map (Option 2) in Phase 4
  - Both options keep traffic inside the VPC

- **Infrastructure impact:**
  - Phase 2: Create Internal ALB, internal target groups, private hosted zone for DNS
  - Phase 3: Add internal ALB target group per service, configure internal DNS
  - Phase 1 (App): Update env vars to use internal URL pattern

- **Acceptance Criteria:**
  - ✅ Internal communication strategy selected and documented
  - ✅ Decision rationale documented
  - ✅ Infrastructure requirements identified for Phase 2
  - ✅ App configuration changes identified for Phase 1

---

### Story 11.3: Evaluate Internal TLS Requirements

**Business Value:** Balances compliance requirements with operational complexity. For regulated industries (healthcare, finance), internal TLS is mandatory for compliance (HIPAA, PCI-DSS) and avoids audit findings that block enterprise sales. For non-regulated companies, documenting the "VPC as trust boundary" decision (30 minutes) satisfies security reviews and avoids over-engineering that slows velocity. Right-sizing security prevents both compliance violations and analysis paralysis.

- **Title:** Assess Need for TLS on Internal Service-to-Service Traffic
- **Persona:** As a **security engineer**, I need to evaluate whether internal service-to-service traffic requires TLS encryption so that we make an informed decision and document the rationale.

- **Requirements:**
  - Review current internal communication security model
  - Assess compliance/regulatory requirements for encryption in transit
  - Evaluate options if internal TLS is required
  - Document decision and rationale

- **Implementation Details:**
  - **Questions to answer:**
    - Does our compliance framework (SOC2, HIPAA, PCI-DSS, etc.) require encryption for internal traffic?
    - Is "VPC as trust boundary" acceptable per our security policy?
    - What sensitive data flows between internal services?
    - Are there any regulatory audit findings requiring internal TLS?
  - **Current state:**
    - Document: Do internal calls use TLS today? (likely no)
    - Document: What is the current security justification? (likely: private network, perimeter auth)
  - **Options if internal TLS is required:**
    - **Option A: Internal ALB with HTTPS** (simplest)
      - Internal ALB terminates TLS using ACM private certificate
      - Traffic: Task → HTTPS → Internal ALB → HTTP → Target Task
      - Pros: Easy setup, ACM handles cert rotation
      - Cons: Last hop (ALB to task) is unencrypted
    - **Option B: End-to-End TLS** (complex)
      - Each application terminates TLS with its own certificate
      - Requires certificate management solution (HashiCorp Vault, cert-manager, etc.)
      - Significant app changes required
    - **Option C: Service Mesh with mTLS** (most complex)
      - AWS App Mesh with Envoy sidecars
      - Automatic mutual TLS between all services
      - Pros: Automatic cert rotation, zero app changes for TLS
      - Cons: Significant infrastructure complexity, operational overhead
  - **Recommendation:**
    - If internal TLS is not required today: Document decision, proceed with migration, revisit later
    - If internal TLS is required: Start with Option A (Internal ALB + HTTPS), defer mesh to future project
    - Do not add internal TLS complexity during migration unless mandated

- **Acceptance Criteria:**
  - ✅ Compliance/regulatory requirements for internal TLS documented
  - ✅ Current internal TLS state documented
  - ✅ Decision made: internal TLS required (yes/no)
  - ✅ If yes: implementation approach selected
  - ✅ If no: rationale documented for audit trail

---

## Discovery Checklist

Complete this checklist before starting Phase 1:

### Networking

- [ ] VPC identified for Fargate deployment
- [ ] At least 2 public subnets exist (for ALB)
- [ ] At least 2 private subnets exist (for tasks) OR decision to use public subnets
- [ ] NAT Gateway exists OR VPC Endpoints planned OR public IP strategy chosen
- [ ] Decision documented with cost implications

### Security Groups

- [ ] RDS security group identified, Fargate access planned
- [ ] ElastiCache security group identified, Fargate access planned
- [ ] Any other data stores audited
- [ ] Existing application EC2 security groups documented
- [ ] Decision made per app: reuse existing SG or create new Fargate-specific SG
- [ ] List of security groups to create/update documented for Phase 2

### IAM

- [ ] AWS services used by application inventoried
- [ ] Task Execution Role permissions planned
- [ ] Task Role permissions planned

### Container Registry

- [ ] Existing ECR repositories audited
- [ ] Repository naming convention decided
- [ ] Image tagging strategy decided
- [ ] Lifecycle policy parameters defined
- [ ] List of repositories to create documented

### Secrets & Config

- [ ] All secrets and config values inventoried
- [ ] Storage destination decided for each (Secrets Manager / SSM / env var)

### Domain & SSL

- [ ] Current DNS configuration documented
- [ ] ACM certificate requested or planned
- [ ] Cutover strategy selected

### Quotas & Costs

- [ ] Service quotas checked
- [ ] Monthly cost estimated and approved

### Current State

- [ ] All EC2 services/processes documented
- [ ] All cron jobs documented
- [ ] All open ports documented
- [ ] Local data/files identified

### Logging

- [ ] Current log file locations documented
- [ ] Log consumers/shippers identified (Filebeat, Fluentd, CloudWatch Agent, etc.)
- [ ] Log shipping destinations documented (ELK, Splunk, CloudWatch, etc.)
- [ ] Impact assessment completed: what breaks if we switch to stdout?
- [ ] Migration plan for log consumers documented

### Rollback

- [ ] Rollback procedure documented
- [ ] EC2 retention period agreed

### Internal Service Communication

- [ ] All service-to-service calls documented
- [ ] Current URL patterns audited (public vs private)
- [ ] Services using public URLs flagged for update
- [ ] Internal communication strategy selected (Internal ALB recommended)
- [ ] Internal TLS requirement evaluated with security/compliance
- [ ] Internal TLS decision documented with rationale
