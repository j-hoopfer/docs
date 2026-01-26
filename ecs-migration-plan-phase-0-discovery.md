# ECS Fargate Migration Plan - Phase 0: Discovery & Prerequisites

## Overview

Before writing any code or Dockerfiles, you must audit your existing AWS infrastructure. Fargate has stricter requirements than traditional EC2 deployments. Missing prerequisites will cause tasks to get **stuck in PENDING** with cryptic error messages—or fail silently.

This phase identifies blockers and informs implementation decisions for Phase 1 (Application Readiness) and Phase 2 (Infrastructure Setup).

---

## Feature 1: VPC & Network Topology

### Story 1.1: Audit VPC for Fargate Compatibility

- **Title:** Verify VPC Meets Fargate Networking Requirements
- **Persona:** As a **DevOps engineer**, I need to verify my existing VPC has the required subnets and routing so that Fargate tasks can start successfully and receive traffic.

- **Requirements:**
  - At least two public subnets (for ALB) across different Availability Zones
  - At least two private subnets (for Fargate tasks) across different Availability Zones
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
  - ✅ Private subnets can reach the internet (via NAT or public IP assignment)
  - ✅ Decision documented: NAT Gateway vs Public IP vs VPC Endpoints

---

### Story 1.2: Plan VPC Endpoints (Optional Cost Optimization)

- **Title:** Evaluate VPC Endpoints to Reduce NAT Gateway Costs
- **Persona:** As a **cloud architect**, I need to understand VPC Endpoint options so that I can reduce data transfer costs and avoid NAT Gateway dependency for AWS service traffic.

- **Requirements:**
  - Identify AWS services the application will call
  - Evaluate cost/benefit of VPC Endpoints vs NAT Gateway
  - Document decision for implementation phase
- **Implementation Details:**
  - **Required for Fargate without NAT:**
    - `com.amazonaws.<region>.ecr.api` (ECR API calls)
    - `com.amazonaws.<region>.ecr.dkr` (Docker image pulls)
    - `com.amazonaws.<region>.s3` (ECR stores layers in S3) - Gateway endpoint, free
    - `com.amazonaws.<region>.logs` (CloudWatch Logs)
  - **Commonly needed:**
    - `com.amazonaws.<region>.secretsmanager` (if using Secrets Manager)
    - `com.amazonaws.<region>.ssm` (if using SSM Parameter Store)
  - **Cost comparison:**
    - NAT Gateway: $32/month + $0.045/GB processed
    - Interface Endpoint: ~$7.30/month per endpoint per AZ + $0.01/GB processed
    - For low-traffic apps, VPC Endpoints may be cheaper; for high-traffic, NAT may be simpler

- **Acceptance Criteria:**
  - ✅ List of required AWS services documented
  - ✅ Cost comparison completed for your expected traffic
  - ✅ Decision documented: NAT Gateway vs VPC Endpoints vs hybrid approach

---

## Feature 2: Security Group Planning

### Story 2.1: Audit Database Security Groups

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

### Story 2.2: Audit Redis/ElastiCache Security Groups

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

- **Title:** Inventory Existing Application Security Groups
- **Persona:** As a **DevOps engineer**, I need to audit existing security groups for each application so that I can decide whether to reuse them for Fargate or create new ones.

- **Requirements:**
  - Identify security groups currently attached to EC2 application instances
  - Document inbound/outbound rules for each
  - Determine if existing SGs can be reused for Fargate tasks
  - Plan security group strategy for migration

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

- **Acceptance Criteria:**
  - ✅ All application EC2 security groups documented
  - ✅ Inbound/outbound rules documented for each
  - ✅ Decision made per app: reuse existing or create new
  - ✅ List of new security groups to create documented for Phase 2

---

## Feature 3: IAM Role Discovery

### Story 3.1: Identify Required IAM Roles

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

### Story 4.1: Plan ECR Repository Strategy

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

### Story 5.1: Inventory Application Secrets

- **Title:** Catalog All Secrets and Configuration Values
- **Persona:** As a **developer**, I need to inventory all secrets and configuration so that I know what to migrate to Secrets Manager/SSM and what to pass as environment variables.

- **Requirements:**
  - Identify all `.env` files on EC2 instances
  - Identify any secrets in application config files
  - Categorize as: secret (sensitive) vs config (non-sensitive)
  - Decide storage location for each

- **Implementation Details:**
  - SSH to EC2 and inventory:
    - `.env` files
    - Application config files
    - Environment variables in systemd/supervisor configs
    - Crontab entries (may contain credentials)
  - Categorize each value:
    - **Secrets** (DB passwords, API keys, tokens) → Secrets Manager
    - **Sensitive config** (internal URLs, feature flags) → SSM Parameter Store
    - **Non-sensitive config** (log levels, timeouts) → ECS Task Definition environment
  - Check for secrets in:
    - Code repository (search for hardcoded values)
    - CI/CD pipeline variables
    - Third-party integrations

- **Acceptance Criteria:**
  - ✅ Complete list of all configuration values documented
  - ✅ Each value categorized (secret/config) with storage destination
  - ✅ No secrets committed to git repository
  - ✅ Plan for migrating secrets to Secrets Manager/SSM

---

## Feature 6: Domain & Certificate Planning

### Story 6.1: Audit DNS and SSL Certificates

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

### Story 7.1: Check AWS Service Quotas

- **Title:** Verify Fargate Service Quotas
- **Persona:** As a **DevOps engineer**, I need to verify AWS service quotas so that I don't hit limits when deploying or scaling.

- **Requirements:**
  - Check Fargate vCPU quota for the region
  - Check ECS service/cluster limits
  - Check ALB limits if creating new load balancers
  - Request increases if needed (can take days)

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

- **Acceptance Criteria:**
  - ✅ Current quota usage documented
  - ✅ Projected usage calculated (tasks × vCPU per task)
  - ✅ Quota increase requested if needed (allow 1-3 days)

---

## Feature 8: Cost Estimation

### Story 8.1: Estimate Fargate Migration Costs

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

## Feature 9: Existing Infrastructure Inventory

### Story 9.1: Document Current EC2 Application Architecture

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

- **Acceptance Criteria:**
  - ✅ All running services documented
  - ✅ All cron jobs documented with schedules
  - ✅ All open ports documented
  - ✅ Local data directories identified and migration plan created

---

### Story 9.2: Audit Current Logging Setup and Consumers

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

## Feature 10: Rollback & Cutover Planning

### Story 10.1: Define Rollback Strategy

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

### Story 11.1: Inventory Internal Service Calls

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
