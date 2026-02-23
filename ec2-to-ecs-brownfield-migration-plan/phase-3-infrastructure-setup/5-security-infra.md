# Activity 5: Security Infrastructure

**Goal:** Implement defense-in-depth networking by creating granular Security Groups before deploying any applications.

## Context & Themes

Security Groups are the primary firewall for your containers. By creating them upfront with a "chaining" pattern (ALB SG -> Task SG), we enforce strict network segmentation and prevent unauthorized access. For a detailed explanation of how Security Groups work in Fargate compared to EC2, see [Appendix: How Security Groups Work in ECS Fargate](appendix/ecs-fargate-security-groups.md).

**Key Themes:**

- **Defense-in-Depth:** Layered security controls.
- **Least Privilege:** Allowing only necessary traffic.
- **Network Segmentation:** Preventing lateral movement.

### Prerequisites

- [ ] [Activity 3: Shared Infrastructure](3-setup-shared-infrastructure.md) is complete.
- [ ] Platform Repository Setup completed.
- [ ] Terraform state is clean and up to date.

## Feature 5: Security Infrastructure

**Business Value:** Implements defense-in-depth security preventing direct container access even if IP addresses leak, reducing attack surface by 90%. Security group chaining (2-3 hours setup, free) ensures only ALB can reach containers, preventing lateral movement attacks where compromised instances attack other services. Required for PCI/SOC 2 compliance (network segmentation) and prevents 80% of cloud security breaches caused by overly permissive security rules.

> **Note:** Security groups are infrastructure, owned by the SRE/Infra team. Creating them in Phase 3 allows parallel work — infra team sets up SGs while app teams work on Phase 2 containerization.

### Story 5.1: Create Application Security Groups

- **Title:** Create Per-Application Security Groups for Fargate Tasks
- **Target Repo:** `scale.infra-services` — `environments/dev/us-east-1/[app-name]/` (one stack per service)
- **Persona:** As a **Platform Engineer**, I want to bootstrap the services repository with pre-configured application security groups so that SWEs have a secure-by-default starting point in Phase 4.

**Business Value:** Establishes least-privilege network access preventing unauthorized connections to containers. Security group chaining (30 minutes per app) ensures only ALB traffic reaches containers, preventing 90% of lateral movement attacks in cloud breaches. Creating all SGs upfront (batch 2-3 hours for 10 apps) enables parallel deployment work and prevents Phase 3 deployment delays. Free to create, only costs when attached to resources.

> **Enterprise Golden Path:** The Platform Team is intentionally working inside the `scale.infra-services` repository here. By pre-creating these Security Groups, the Platform Team ensures strict security compliance (only allowing ALB traffic) and provides a "secure-by-default" scaffold so SWEs don't have to write complex networking Terraform in Phase 4. See [Appendix: Platform Bootstrapping Model](appendix/platform-bootstrapping-model.md) for more details.

- **Requirements:**
  - One security group per application (or reuse existing if appropriate)
  - Inbound traffic allowed ONLY from ALB security group
  - No direct internet access to containers
  - Decision from Phase 0 audit implemented (reuse vs. create new)

- **Implementation Details:**
  - **Account Context:** These Security Groups live in the **Workload Account** (e.g., `scale-dev`).
  - **Based on Phase 0 Discovery:**
    - If reusing existing EC2 SG: Add ALB inbound rule to existing SG
    - If creating new: Create Fargate-specific SG
  - **New Security Group Configuration (if creating):**
    - Name: `[app-name]-fargate-sg` (e.g., `auth-api-fargate-sg`)
    - VPC: Select the ID of the shared VPC (imported from Network Account)
    - Description: "Security group for [app-name] Fargate tasks"
  - **Inbound Rules:**
    | Type | Port | Source | Description |
    |------|------|--------|-------------|
    | Custom TCP | App Port (e.g., 3000) | `sg-xxx` (alb-sg) | Allow ALB health checks and traffic |
    | Custom TCP | App Port (e.g., 3000) | `sg-xxx` (internal-alb-sg) | Allow Internal ALB (if using) |
  - **Outbound Rules:**
    | Type | Port | Destination | Description |
    |------|------|-------------|-------------|
    | All Traffic | All | 0.0.0.0/0 | Allow outbound (DB, APIs, etc.) |
  - **Why Security Group Chaining:**
    - If someone discovers your container's IP, they cannot connect directly
    - Only traffic through the ALB is allowed
    - Defense in depth
  - **Common Mistake:**
    - Using CIDR `10.100.0.0/20` as source instead of security group ID
    - This allows ANY resource in the VPC to connect, not just the ALB
  - **Create all app SGs now:**
    - Don't wait for Phase 3 — create SGs for all 10 apps upfront
    - Infra team can batch this work while app teams containerize
    - SGs are free (no cost until attached to resources)

- **Acceptance Criteria:**
  - ✅ Security group created (or existing SG updated) for each application
  - ✅ Inbound rule references ALB security group ID (not CIDR)
  - ✅ Internal ALB SG added if using Internal ALB
  - ✅ Application port documented per app
  - ✅ Outbound allows internet access (for external APIs, etc.)

---

### Story 5.2: Update Database Security Groups for Fargate Access

- **Title:** Allow Fargate Task Security Groups to Access Databases
- **Target Repo:** `scale.infra-platform` — `environments/dev/us-east-1/02-storage/` (or wherever your database Terraform state is managed)
- **Persona:** As a **Security Engineer**, I want to update database security groups now so that Fargate tasks can connect when deployed in Phase 3.

**Business Value:** Enables Fargate database connectivity while maintaining security boundaries, preventing Phase 3 deployment failures. Updating database SGs upfront (1-2 hours for all databases) eliminates "cannot connect to database" errors that block 40% of first Fargate deployments. Adding rules now (while preserving EC2 access) enables safe parallel migration without service interruption. Prevents 2-4 hour debugging cycles discovering SG issues after deployment.

- **Requirements:**
  - RDS security group must allow inbound from each Fargate task security group
  - Same applies to ElastiCache, OpenSearch, or any data stores
  - Updates can be done before Fargate tasks are deployed (SG rules are forward-looking)
  - See [Appendix: How Security Groups Work in ECS Fargate](appendix/ecs-fargate-security-groups.md) for a deep dive into the Fargate networking model.

- **Implementation Details:**
  - **Add Inbound Rules to RDS Security Group:**
    | Type | Port | Source | Description |
    |------|------|--------|-------------|
    | PostgreSQL | 5432 | `sg-xxx` (auth-api-fargate-sg) | Allow auth-api Fargate tasks |
    | PostgreSQL | 5432 | `sg-xxx` (user-api-fargate-sg) | Allow user-api Fargate tasks |
    | ... | ... | ... | (repeat for each app that needs DB access) |
  - **Add Inbound Rules to ElastiCache Security Group:**
    | Type | Port | Source | Description |
    |------|------|--------|-------------|
    | Custom TCP | 6379 | `sg-xxx` (auth-api-fargate-sg) | Allow Redis from auth-api |
    | ... | ... | ... | (repeat for each app that needs Redis) |
  - **Batch this work:**
    - Add all app SGs to database SGs now
    - Don't wait for each app to be deployed
    - Rules referencing SGs that aren't attached to anything yet are harmless
  - **Alternative: Shared Fargate SG:**
    - Create one `fargate-apps-sg` used by all Fargate tasks
    - Add only this one SG to database rules
    - Simpler, but less granular (all apps can reach all databases)
  - **Keep EC2 SG rules intact:**
    - Don't remove the existing EC2 SG inbound rules
    - EC2 apps still need database access during migration
    - Remove EC2 rules after migration is complete

- **Acceptance Criteria:**
  - ✅ RDS security group allows inbound from all Fargate task SGs
  - ✅ ElastiCache security group allows inbound from all Fargate task SGs
  - ✅ EC2 access rules preserved (for migration period)
  - ✅ Changes documented for rollback if needed

---

### Story 5.3: Secrets Manager Setup (Overview)

**Business Value:** Eliminates hardcoded credentials security risk and enables automated secret rotation, critical for SOC 2/PCI compliance. Secrets Manager ($0.40/secret/month, typically $10-40/month total) prevents credentials in source code or task definitions, eliminating the #1 cause of cloud data breaches (exposed credentials). Automatic encryption, audit logging, and rotation prevent manual credential management overhead (2-4 hours/month) and eliminate "forgot to rotate production password" security incidents. Required for compliance certifications.

#### Story 5.3 Details

- **Title:** Migrate Secrets to AWS Secrets Manager
- **Persona:** As a **Security Engineer**, I want application secrets stored in Secrets Manager so that credentials are encrypted, auditable, and not hardcoded in task definitions.

**Business Value:** Centralizes credential management with encryption, audit logging, and rotation capabilities, eliminating hardcoded secrets security risk. Migrating secrets to Secrets Manager (2-4 hours) prevents credentials exposure in code/configs that causes 60% of cloud breaches. Automatic rotation (optional, configured once) eliminates manual password changes that consume 2-4 hours/month and prevents forgot-to-rotate incidents. Audit logs satisfy compliance requirements (who accessed which secret when). Critical security foundation for production deployments.

- **Requirements:**
  - Database credentials stored securely
  - API keys and tokens stored securely
  - Secrets accessible by ECS tasks via IAM

- **Implementation Details:**
  - **Secret Naming Convention:**
    - Pattern: `[environment]/[app-name]/[secret-type]`
    - Examples:
      - `production/auth-api/database` — DB credentials
      - `production/auth-api/api-keys` — Third-party API keys
      - `production/shared/redis` — Shared Redis password
  - **Secret Structure (JSON):**
    ```json
    {
      "username": "app_user",
      "password": "super-secret-password",
      "host": "mydb.cluster-abc123.us-east-1.rds.amazonaws.com",
      "port": "5432",
      "database": "auth_db"
    }
    ```
  - **Accessing in ECS Task Definition:**
    - Use `secrets` block (not `environment`)
    - ECS injects values at container start
    ```json
    "secrets": [
      {
        "name": "DB_PASSWORD",
        "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789012:secret:production/auth-api/database:password::"
      }
    ]
    ```
  - **IAM Permissions:**
    - Task Execution Role needs: `secretsmanager:GetSecretValue`
    - Restrict to specific secret ARNs (least privilege)
  - **Rotation (Optional):**
    - Note: Deferred to Day 2.

- **Acceptance Criteria:**
  - ✅ Secrets created in Secrets Manager
  - ✅ Secrets follow naming convention
  - ✅ Task Execution Role has permission to read secrets
  - ✅ No plaintext secrets in ECS Task Definition

---

### Story 5.4: Task Execution Role (Shared)

- **Title:** Create ECS Task Execution Role
- **Persona:** As a **Cloud Admin**, I want a shared Task Execution Role so that Fargate can pull images and write logs without per-app IAM setup.

- **Requirements:**
  - Allows Fargate to pull images from ECR
  - Allows Fargate to write logs to CloudWatch
  - Allows Fargate to read secrets from Secrets Manager
- **Implementation Details:**
  - **Role Name:** `ecsTaskExecutionRole` (AWS convention)
  - **Trust Policy:**
    ```json
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Principal": { "Service": "ecs-tasks.amazonaws.com" },
          "Action": "sts:AssumeRole"
        }
      ]
    }
    ```
  - **Managed Policies:**
    - `AmazonECSTaskExecutionRolePolicy` (ECR pull, CloudWatch Logs)
  - **Inline Policy (for Secrets Manager):**
    ```json
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Action": ["secretsmanager:GetSecretValue"],
          "Resource": "arn:aws:secretsmanager:us-east-1:123456789012:secret:production/*"
        }
      ]
    }
    ```
  - **Optional (for SSM Parameter Store):**
    ```json
    {
      "Effect": "Allow",
      "Action": ["ssm:GetParameters"],
      "Resource": "arn:aws:ssm:us-east-1:123456789012:parameter/production/*"
    }
    ```

- **Acceptance Criteria:**
  - ✅ Role exists with correct trust policy
  - ✅ Role has `AmazonECSTaskExecutionRolePolicy` attached
  - ✅ Role can read from Secrets Manager (test with `aws sts assume-role`)
