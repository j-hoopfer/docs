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

### Story 2.0: Capture Network Topology Snapshot

- **Title:** Run the Topology Audit Script and Produce the Inventory Table
- **Persona:** As a **DevOps engineer**, I need a single, complete snapshot of the existing network — VPCs, Subnets, Route Tables, NAT Gateways, and Security Groups — so that Story 2.2 can perform a structured gap analysis against it.
- **Output Artifact:** A filled-in version of the Topology Inventory Table below. This table is the direct input to Phase 3, Activity 2 (Gap Remediation).

**Business Value:** Without this snapshot, the gap analysis is guesswork. Engineers end up SSH'ing into boxes during a deployment to answer questions that should have been answered in week 1.

- **Implementation Details:**

  Run the `get-import-ids.sh` script from any machine with AWS CLI access and `jq` installed. Replace `<VPC_ID>` with your VPC ID.

- **Topology Inventory Table** — fill in from script output and commit to the repo:

  | Resource Type | ID         | AZ         | CIDR / Notes | Route Target (0.0.0.0/0) | Available IPs |
  | :------------ | :--------- | :--------- | :----------- | :----------------------- | :------------ |
  | VPC           | vpc-xxx    | —          | 10.x.x.x/16  | —                        | —             |
  | Subnet A      | subnet-xxx | us-east-1a | 10.x.1.0/24  | igw-xxx → **Public**     | 250           |
  | Subnet B      | subnet-xxx | us-east-1b | 10.x.2.0/24  | (none) → **Isolated**    | 250           |
  | NAT GW        | nat-xxx    | us-east-1a | EIP: 1.2.3.4 | —                        | —             |

- **Acceptance Criteria:**
  - ✅ Topology Inventory Table is filled in and committed.
  - ✅ Each subnet is classified: `Public`, `Private`, or `Isolated`.
  - ✅ Available IP count per subnet is recorded.
  - ✅ VPC `DNS_Support` and `DNS_Hostnames` values are recorded.
  - ✅ NAT Gateway state (exists / missing / multiple AZs) is documented.

---

### Story 2.1: Identify Resource Ownership (Layered State)

- **Title:** Map Resources to Terraform Layers (Network vs Workload)
- **Persona:** As a **Cloud Engineer**, I need to classify the resources discovered in Story 2.0 into Terraform layers to support our multi-account strategy.

**Business Value:** Prevents "Monolith State" issues where a change to an application Security Group accidentally destroys a VPC Subnet.

- **The Separation:**
  1. **Network Layer (`00-network` in Network Account):**
     - VPC, Subnets, Route Tables, Internet Gateways, NAT Gateways, VPC Endpoints.
  2. **Workload Layer (`01-compute` in Workload Account):**
     - Security Groups (application-specific), ALBs, Target Groups, ECS Clusters.

- **Requirements:**
  - Using the Topology Inventory Table from Story 2.0, tag each resource as `Network Layer` or `Workload Layer`.
  - **Critical:** Identify if the current EC2 instances are in a "Shared VPC" (managed centrally by a platform team) or an "App VPC" (managed by the app team). This determines which Terraform state file owns the VPC.

- **Acceptance Criteria:**
  - ✅ Every resource from the Story 2.0 inventory is labelled with its owning Terraform layer.
  - ✅ Shared VPC vs App VPC determination documented.

---

### Story 2.2: VPC Gap Analysis (Fargate Hard Requirements)

**Title:** Compare Topology Snapshot Against Fargate's Non-Negotiable Requirements
**Persona:** As a **DevOps engineer**, I need to cross-reference the Topology Inventory from Story 2.0 against the hard constraints of the Fargate runtime so I produce a precise list of what must be fixed before Phase 3.

- **Output Artifact:** A **Gap Report** — each gap in the format: `GAP: <resource> is missing/misconfigured | Fix: <action> | Owner: Phase 3 Activity 2`.

**Business Value:** Fargate has specific, non-obvious networking requirements. Missing any one of them causes silent deployment failure (tasks stuck in `PENDING` with cryptic errors). This story prevents deploying first, debugging second.

#### Fargate Hard Requirements Checklist:

| #      | Requirement                                       | Why It Matters                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | How to Check                                                                                                     | Validate                                                                                                            |
| :----- | :------------------------------------------------ | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :--------------------------------------------------------------------------------------------------------------- | :------------------------------------------------------------------------------------------------------------------ |
| **R1** | VPC `enableDnsSupport = true`                     | Fargate tasks use the AWS VPC DNS resolver (169.254.169.253) to resolve ECR, CloudWatch, Secrets Manager endpoints. If `false`, tasks cannot reach any AWS service by hostname.                                                                                                                                                                                                                                                                                                   | Story 2.0 script output, field `DNS_Support`                                                                     | DNS Support → `true`                                                                                                |
| **R2** | VPC `enableDnsHostnames = true`                   | Required for ENIs created in `awsvpc` mode to receive DNS hostnames. Also required for ECS Service Discovery. If `false`, inter-service name resolution breaks.                                                                                                                                                                                                                                                                                                                   | Story 2.0 script output, field `DNS_Hostnames`                                                                   | DNS Hostnames → `true`                                                                                              |
| **R3** | VPC `instanceTenancy = default` (not `dedicated`) | Fargate does not support VPCs with dedicated tenancy. Tasks cannot be launched. **Hard blocker.**                                                                                                                                                                                                                                                                                                                                                                                 | Story 2.0 script output, field `Tenancy` — must be `default`                                                     | Tenancy → "default"                                                                                                 |
| **R4** | At least 2 private subnets in different AZs       | Each Fargate task consumes **1 IP from its subnet** via a dedicated ENI (`awsvpc` mode). During rolling deployments, new tasks start before old ones stop — you temporarily need **2× desired task count** in available IPs. Multi-AZ is required for HA; a single-AZ failure drops the service. Note: `bridge` and `host` network modes are **not supported** on Fargate.                                                                                                        | Story 2.0 table: count subnets classified `Private`; check AZs; check `AvailableIPs`                             | `AutoPublicIP=false` + route `Target` starts with `nat-` → need ≥2 rows with different `AZ` values                  |
| **R5** | No public subnets for tasks                       | Tasks in public subnets require `assignPublicIp: ENABLED`, which attaches a public IP directly to the task ENI. This bypasses the NAT and directly exposes the task. Do not use public subnets for production tasks.                                                                                                                                                                                                                                                              | Story 2.0 table: flag any subnet with `AutoPublicIP = true` or Route Target = `igw`                              | Task subnet rows → `AutoPublicIP` must be `false`; no task subnet route should have `Target` = `igw-*`              |
| **R6** | Private subnets have outbound internet access     | Fargate pulls images from **ECR** (via HTTPS to `ecr.aws`), image layers from **S3** (via HTTPS), ships logs to **CloudWatch Logs** (HTTPS), and reads secrets from **Secrets Manager** (HTTPS). Without outbound 443, the task is permanently stuck in `PENDING` with `CannotPullContainerError`. Options: (a) **NAT Gateway** — default path, ~$32/mo per AZ for the gateway + data transfer costs; (b) **VPC Interface Endpoints** — eliminates NAT cost, deferred to Phase X. | Story 2.0 table: private subnet route tables must have `0.0.0.0/0 → nat-xxx`; verify NAT GW state is `available` | Private route table → `Dest=0.0.0.0/0` with `Target` starting `nat-`; `State` → `available`                         |
| **R7** | At least 1 Security Group on every task           | Fargate requires exactly 1–5 SGs on each task. The SG must allow: **outbound TCP 443** (to ECR/S3/CloudWatch/SecretsManager) and **inbound TCP `<app_port>`** from the ALB security group. Do not use `0.0.0.0/0` inbound.                                                                                                                                                                                                                                                        | Story 2.0 SG output — confirm a candidate SG exists; full SG rule audit is in Feature 3                          | `SGs` column → non-empty for each instance; outbound rules audited in Feature 3 (Stories 3.2–3.4)                   |
| **R8** | Subnet IP capacity for projected scale            | Formula: `available_IPs_per_subnet ≥ desired_task_count × 2`. A `/28` has 11 usable IPs = max 5 healthy + 5 deploying simultaneously. A `/24` has 251 usable IPs = comfortable for most services.                                                                                                                                                                                                                                                                                 | Story 2.0 table `AvailableIPs` column                                                                            | `AvailableIPs` column → each private subnet value must satisfy `AvailableIPs ≥ desired_task_count × 2`              |
| **R9** | Multi-AZ coverage (≥ 2 AZs)                       | Not enforced by Fargate itself, but the ECS scheduler will fail to maintain `desiredCount` if the single AZ it has becomes unavailable. Treat as a hard requirement.                                                                                                                                                                                                                                                                                                              | Story 2.0 table: count distinct AZ values for `Private` subnets                                                  | Count distinct `AZ` values for rows where `AutoPublicIP=false` and route is `nat-` (confirmed via §3) → must be ≥ 2 |

- **Run the Gap Analysis:**

  For each requirement, mark PASS or GAP using Story 2.1's output:

  ```
  R1: enableDnsSupport   → ✅ PASS  / 🚩 GAP: must enable before Phase 3
  R2: enableDnsHostnames → ✅ PASS  / 🚩 GAP: must enable before Phase 3
  R3: instanceTenancy    → ✅ PASS  / 🚩 GAP (dedicated) — HARD BLOCKER, escalate immediately
  R4: private subnets    → ✅ PASS  / 🚩 GAP: no private subnets exist → Phase 3 Activity 2
  R5: no public tasks    → ✅ N/A   / 🚩 RISK: only public subnets available → architecture decision needed
  R6: outbound access    → ✅ PASS (nat-xxx is available, routes confirmed)
                         / 🚩 GAP: no NAT, add NAT Gateway in Phase 3 Activity 2 ($32/mo)
  R7: security groups    → ✅ PASS  / 🚩 GAP: no outbound-443 SG exists → Phase 3 Activity 5
  R8: IP capacity        → ✅ PASS (250 IPs available, max projected tasks = 20, need 40)
                         / 🚩 GAP: /28 subnet too small for projected scale
  R9: multi-AZ           → ✅ PASS (1a + 1b) / 🚩 GAP: single AZ only → HA risk
  ```

- **Acceptance Criteria:**
  - ✅ All 9 requirements checked and marked `PASS` or `GAP`.
  - ✅ Every `GAP` item has a named owner (`Phase 3 Activity 2` or escalation).
  - ✅ IP capacity formula verified: `available_IPs ≥ desired_task_count × 2`.
  - ✅ Gap Report committed to the repo (as a section in this file or a separate `GAPS.md`).

---

### Story 2.3: DNS & Route 53 Readiness

- **Title:** Discover Public Hosted Zone Ownership and Account Location
- **Persona:** As a **Cloud Engineer**, I need to determine whether a public Route 53 hosted zone exists for the application domain, and whether it lives in the same AWS account as the workload, so that Phase 3 can provision ACM certificates without surprises.

**Business Value:** ACM DNS validation is the most common silent blocker in Phase 3. If the hosted zone is in a different account and no cross-account access is established, `terraform apply` will fail after requesting the certificate — with an opaque `no hosted zones found` error. Discovering this in Phase 1 (30 minutes) vs. mid-Phase 3 (hours of debugging + waiting for another team) keeps the project on schedule.

- **Requirements:**
  - Confirm a **public** Route 53 hosted zone exists for the application domain.
  - Identify which AWS account owns that hosted zone.
  - Flag whether cross-account IAM access will be needed to create DNS validation records.

- **Implementation Details:**

  **Check for an existing public hosted zone (run in the workload account first):**

  ```bash
  # List all hosted zones — look for your domain with PrivateZone: false
  aws route53 list-hosted-zones \
    --query 'HostedZones[*].[Name,Id,Config.PrivateZone]' \
    --output table
  ```

  If the zone is not found here, run the same command in the **DNS / Shared Services account** (if your org has one). A zone named `example.com.` with `PrivateZone = false` is what you need.

  **Get the zone ID (needed for Terraform):**

  ```bash
  aws route53 list-hosted-zones-by-name \
    --dns-name example.com \
    --query 'HostedZones[?Config.PrivateZone==`false`].[Name,Id]' \
    --output table
  ```

  **Record in the Gap Report:**

  | Question                                     | Answer                                   | Gap?                                                  |
  | :------------------------------------------- | :--------------------------------------- | :---------------------------------------------------- |
  | Public hosted zone exists for `example.com`? | ✅ Yes / 🚩 No                           | If No → register domain or create zone before Phase 3 |
  | Hosted zone is in the workload account?      | ✅ Yes / 🚩 No — lives in account `<ID>` | If No → Phase 3 Activity 2 Story 2.4                  |
  | Zone is resolvable from the internet?        | ✅ Yes / 🚩 Unknown                      | Verify with `dig example.com NS` from a local machine |

- **Acceptance Criteria:**
  - ✅ Public hosted zone confirmed to exist (or creation planned as a blocker before Phase 3).
  - ✅ AWS account ID that owns the zone is documented.
  - ✅ If zone is in a different account: flagged as `GAP → Phase 3 Activity 2 Story 2.4`.
  - ✅ Zone ID recorded (used directly in Terraform `data.aws_route53_zone.public`).

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

### Story 3.2: Gap Analysis: Database Security Groups (Pets vs. Cattle)

- **Title:** Identify "Static IP" or "Shared SG" Blockers in Database Security
- **Persona:** As a **DevOps engineer**, I need to audit the existing RDS and ElastiCache Security Groups to see if they rely on "Legacy Patterns" (Specific IP addresses or the EC2 Instance SG) that will break when we move to Fargate (Dynamic IPs and a new Task SG).

**Business Value:** This is the #1 cause of "It works in Dev, fails in Prod." Legacy setups often whitelist specific EC2 IPs. Fargate tasks have dynamic IPs. If we don't catch this gap now, the application will fail to connect to the database immediately upon deployment.

- **Requirements:**
  1.  **Inspect RDS/ElastiCache Inbound Rules:**
      - Look for **CIDR Rules** (e.g., `10.0.1.50/32` or `1.2.3.4/32`). **Gap:** These will break on Fargate.
      - Look for **SG References** (e.g., `sg-12345`). **Question:** Is this the "App SG" or something else?
  2.  **Define the "Target State" Rule:**
      - The Database _must_ allow traffic from a **Security Group Reference** (not an IP).
      - Specifically, it must allow the _future_ `fargate-task-sg`.

- **Implementation Details:**
  - **Step 1: Get the Database SG ID:**
    ```bash
    aws rds describe-db-instances --query 'DBInstances[*].[DBInstanceIdentifier,VpcSecurityGroups[*].VpcSecurityGroupId]' --output table
    ```
  - **Step 2: Audit the Inbound Rules:**
    - For each SG ID found above:
    ```bash
    aws ec2 describe-security-groups --group-ids <sg-id> \
      --query 'SecurityGroups[*].IpPermissions[*].{Protocol:IpProtocol,Port:FromPort,SourceIP:IpRanges[*].CidrIp,SourceSG:UserIdGroupPairs[*].GroupId}'
    ```
  - **Step 3: flag the Gaps:**
    - 🚩 **Critical Gap:** Rule allows specific private IP (e.g., `10.100.1.5/32`). _Remediation: Must switch to SG-based logic._
    - 🚩 **Critical Gap:** Rule allows `0.0.0.0/0` (Danger!). _Remediation: Lock down immediately._
    - ⚠️ **Action Item:** We will need to create a new `fargate-task-sg` in Phase 3 and add it to this list.

- **Acceptance Criteria:**
  - ✅ **Dependencies Mapped:** "Auth Service DB (sg-xxx) allows traffic from Auth EC2 SG (sg-yyy)".
  - ✅ **IP Hardcoding Identified:** List of any hardcoded IP rules that need to be removed/migrated.
  - ✅ **Migration Plan:** "In Phase 3, we will add `fargate-task-sg` to `rds-sg` inbound rules."

### Story 3.3: Gap Analysis: Application Security Groups allow Load Balancer Traffic?

- **Title:** Verify App SG allows traffic from Load Balancer (not just Public Internet)
- **Persona:** As a **DevOps engineer**, I need to confirm if the current EC2 instances allow traffic directly from the internet (Public API) or only from a Load Balancer (ALB), as Fargate must be private.

**Business Value:** Fargate tasks in Private Subnets _cannot_ receive traffic from the internet directly. They _must_ receive traffic from an ALB. If the current application expects direct public traffic, we have an architecture gap to close.

- **Requirements:**
  - Audit existing EC2 Security Groups (`sg-app`).
  - **Gap Check:**
    - Does it allow port 80/443 from `0.0.0.0/0`? (Legacy Public App).
    - Does it allow port 80/443 from `sg-alb`? (Modern/Correct).
  - **Impact:** If `0.0.0.0/0`, we _must_ introduce an ALB in Phase 3 if one doesn't exist.

- **Implementation Details:**
  - **Check EC2 SG Rules:**
    ```bash
    aws ec2 describe-security-groups --group-ids <app-sg-id> ...
    ```
  - **Compare with ALB SG:**
    - If an ALB exists, get its SG ID.
    - Does the App SG allow traffic from the ALB SG?

- **Acceptance Criteria:**
  - ✅ Documented whether current app is "Direct to Internet" or "Behind ALB".
  - ✅ If "Direct to Internet", marked as **Gap: Need shared ALB in Phase 3**.
  - ✅ If "Behind ALB", marked as **Compatible**.

### Story 3.4: Inventory Existing Application Security Groups

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
