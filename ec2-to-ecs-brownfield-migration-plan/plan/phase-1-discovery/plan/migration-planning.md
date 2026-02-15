# Migration Planning

**Goal:** Transform audit findings into concrete architectural decisions (IAM policies, ECR strategy, Cutover, Rollback) that will guide the Phase 2 implementation.

---

## Feature 1: IAM Role Discovery

**Business Value:** Prevents service disruptions from permission errors. Applications failing due to missing IAM permissions (common in Fargate migrations) result in 100% error rates and immediate rollback requirements. Planning IAM correctly (1-2 hours) vs. emergency troubleshooting (4-6 hours downtime) protects SLAs and customer experience.

### Story 1.1: Identify Required IAM Roles

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

## Feature 2: Container Registry Planning

**Business Value:** Controls storage costs and establishes deployment traceability. Unmanaged ECR repositories can accumulate hundreds of unused images, costing $10-50/month unnecessarily. Proper lifecycle policies (30 minutes to configure) prevent cost creep and enable instant rollback to previous image versions, reducing MTTR (Mean Time To Recovery) from hours to minutes.

### Story 2.1: Plan ECR Repository Strategy

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

## Feature 3: Domain & Certificate Planning

**Business Value:** Enables zero-downtime cutover to Fargate infrastructure. Proper DNS and SSL planning (2-3 hours) allows gradual traffic shifting with instant rollback capability, minimizing risk to revenue. ACM certificates eliminate $50-500/year SSL renewal costs and prevent certificate expiration outages (which cause 100% service downtime).

### Story 3.1: Audit DNS and SSL Certificates

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

## Feature 4: Rollback & Cutover Planning

**Business Value:** Provides insurance policy for migration, dramatically reducing risk. Clear rollback procedures (2 hours to document) mean migration failures result in 5-10 minute rollbacks vs. hours of panic troubleshooting. This confidence enables aggressive migration timelines and protects customer SLAs. Knowing you can instantly revert means stakeholders approve migration even for critical systems.

### Story 4.1: Define Rollback Strategy

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
