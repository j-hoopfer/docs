# Infrastructure Audit

**Goal:** Systematically review the existing AWS environment (VPC, Security Groups, IAM) to identify network barriers and permission gaps that must be addressed before Fargate deployment can succeed.

## Context & Themes

Understanding the current network topology is critical to prevent deployment failures. Fargate tasks require specific VPC configurations (subnets, NAT Gateways, Endpoints) that may differ from a standard EC2 setup.

**Key Themes:**

- **Network Readiness:** Validating VPC subnets, NAT gateways, and connectivity for Fargate.
- **Security Posture:** Auditing Security Groups and NACLs to ensure least privilege.
- **Cost Awareness:** Identifying potential NAT Gateway or VPC Endpoint costs early.

## Prerequisites

- [ ] Read-only access to AWS VPC, IAM, and Security Group consoles.
- [ ] Network diagram (if available).

## Feature 2: VPC & Network Topology

**Business Value:** Prevents deployment failures and unplanned costs by validating network requirements upfront. Discovering VPC incompatibilities in Phase 0 (1 day) vs. during deployment (weeks of debugging) saves 2-3 weeks of engineering time and avoids production outages. Proper NAT/VPC Endpoint planning can save $200-500/month in data transfer costs.

### Story 2.1: Audit VPC for Fargate Compatibility

- **Title:** Verify VPC Meets Fargate Networking Requirements
- **Persona:** As a **DevOps engineer**, I need to verify my existing VPC has the required subnets and routing so that Fargate tasks can start successfully and receive traffic.

**Business Value:** Avoids the #1 cause of failed Fargate deployments—incorrect network configuration. Tasks stuck in PENDING due to missing NAT Gateway or VPC Endpoints can delay go-live by 1-2 weeks while engineers troubleshoot cryptic error messages.

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

### Story 2.2: Document AWS Service Dependencies

- **Title:** Inventory AWS Service Dependencies for Network Planning
- **Persona:** As a **cloud architect**, I need to identify all AWS services the application calls so that network connectivity (NAT Gateway, VPC Endpoints) can be configured correctly in Phase 2.

**Business Value:** Prevents deployment failures by identifying all AWS services the application depends on, ensuring network connectivity is planned correctly. Missing dependencies discovered during migration cause 30-40% of failed deployments and 2-4 hour rollback cycles. Documenting upfront enables proper VPC endpoint planning in Phase 2.

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

## Feature 3: Security Group Planning & Data Stores

**Business Value:** Prevents database connection failures on day one of migration, avoiding emergency troubleshooting during critical cutover windows. Planning security groups correctly upfront (2-3 hours) vs. debugging connection failures in production (4-8 hours downtime) protects revenue and customer trust. Proper least-privilege design also reduces security audit findings.

### Story 3.1: Discover and Inventory Data Stores

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

### Story 3.2: Audit Database Security Groups

- **Title:** Verify RDS/Database Allows Fargate Task Connections
- **Persona:** As a **DevOps engineer**, I need to verify that database security groups will allow connections from Fargate tasks so that the application can connect after migration.

**Business Value:** Eliminates the most common post-deployment failure: "application can't connect to database." This single issue causes 60% of failed ECS migrations to rollback within the first hour. Planning this correctly prevents emergency rollbacks and associated revenue loss.

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

### Story 3.3: Audit ElastiCache Security Groups

- **Title:** Verify ElastiCache Allows Fargate Task Connections
- **Persona:** As a **DevOps engineer**, I need to verify that ElastiCache security groups will allow connections from Fargate tasks so that session storage and caching work after migration.

**Business Value:** Protects user experience by ensuring session storage works correctly. Failed Redis connections cause users to be logged out unexpectedly, resulting in support tickets, abandoned transactions, and negative reviews. Planning this correctly prevents customer churn during migration.

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

### Story 3.4: Audit Application Security Groups

- **Title:** Inventory Existing Application Security Groups
- **Persona:** As a **DevOps engineer**, I need to audit existing security groups for each application so that I can decide whether to reuse them for Fargate or create new ones.

**Business Value:** Enables safe, reversible migration by isolating EC2 and Fargate infrastructure. Creating separate security groups (30 minutes) vs. sharing SGs allows instant rollback to EC2 if issues arise, protecting business continuity. Also simplifies troubleshooting and reduces blast radius of security changes.

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

## Feature 4: Service Quotas & Limits

**Business Value:** Prevents blocked deployments and scaling failures. AWS quota increases require 1-3 business days to process. Discovering quota limits during deployment (blocked launch) vs. Phase 0 planning (proactive request) is the difference between on-time delivery and multi-day delays. Protects project timelines and prevents emergency escalations.

### Story 4.1: Check AWS Service Quotas

- **Title:** Verify Fargate Service Quotas
- **Persona:** As a **DevOps engineer**, I need to verify AWS service quotas so that I don't hit limits when deploying or scaling.

**Business Value:** Avoids deployment day surprises that halt production launches. Running out of Fargate vCPU quota or hitting ECS service limits during Black Friday or product launch would result in lost revenue and reputational damage. 15 minutes of quota checking prevents catastrophic scaling failures during peak traffic.

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

## Feature 5: Cost Estimation

**Business Value:** Secures budget approval and prevents cost overruns. Accurate cost estimates (2-3 hours) enable CFO/stakeholder buy-in for migration investment. Underestimating costs leads to mid-project budget freezes or forced rollbacks. Typical Fargate migrations show 10-30% cost increase vs. EC2, but operational savings (no patching, auto-scaling, faster deployments) deliver 200-300% ROI within 12 months.

### Story 5.1: Estimate Fargate Migration Costs

- **Title:** Calculate Expected Fargate Costs
- **Persona:** As a **project stakeholder**, I need to understand the cost implications of migrating to Fargate so that I can budget appropriately and avoid surprises.

**Business Value:** Prevents sticker shock and enables informed decision-making. Comparing total cost of ownership (Fargate compute + operational savings from automation) vs. current EC2 costs justifies migration investment to finance stakeholders. Accurate forecasts prevent budget overruns that could halt the project mid-flight.

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

### Story 5.2: Audit EC2 Reserved Instances and Savings Plans

- **Title:** Identify Active EC2 Financial Commitments
- **Persona:** As a **finance/cloud admin**, I need to audit existing EC2 Reserved Instances and Savings Plans so that I can avoid paying double (for both unused EC2 commitments and new Fargate usage) during migration.

**Business Value:** Prevents paying for unused infrastructure commitments, saving $5K-50K+ during migration overlap period. Identifying active RIs with 12+ months remaining allows strategic timing (wait for expiration) or mitigation (sell on RI Marketplace), optimizing financial efficiency. Failure to audit RIs results in double-spend: paying for idle EC2 RIs PLUS new Fargate costs.

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
