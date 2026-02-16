# Activity 6: Security Verification

**Goal:** Perform a final security audit (Security Groups, IAM Roles) to ensure the service is not over-privileged or exposed incorrectly before it becomes the primary production endpoint.

## Context & Themes

Mistakes in IAM or SGs can expose data or take down services. A final verification step ensures "least privilege" is real, not just a goal.

**Key Themes:**

- **Least Privilege:** Validating minimal access policies.
- **Exposure Check:** Ensuring only ALB can talk to tasks.
- **Configuration Audit:** Reviewing drift from best practices.

### Prerequisites

- [ ] Service deployed and accessible.
- [ ] AWS Console access for IAM and Security Groups.

## Feature 6: Application Security Groups

**Business Value:** Validates security foundation is ready before deployment, preventing 40% of initial deployment failures caused by network connectivity issues. Pre-created security groups (verified in 15-30 minutes) ensure containers can receive ALB traffic and access databases on first deployment attempt. Using baseline + service-specific pattern reduces SG rules from 50+ (one-per-service) to 10-15 total, simplifying management and reducing configuration errors. Prevents 2-4 hour deployment delays from "traffic not reaching containers" debugging.

> **Note:** Security groups should already be created in Phase 3 (Activity 4). This section covers verification and any per-deployment updates needed. If SGs were not pre-created, create them now following the Phase 3 pattern.

### Story 6.1: Verify Security Groups

- **Title:** Verify Baseline and Service-Specific Security Groups
- **Persona:** As a **DevOps Engineer**, I want to verify security groups are correctly configured before deploying so that the ECS service can receive traffic from the ALB.

**Business Value:** Confirms network connectivity will work before spending time on deployment, preventing wasted effort. Security group verification (10-15 minutes) catches misconfigured ALB access rules that block 30-40% of first deployments. Baseline + service-specific pattern reduces management overhead by 60% (one set of ALB rules vs. duplicated across 10 services) while maintaining security isolation. Prevents multi-hour debugging cycles discovering SG issues after failed deployment.

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

**Business Value:** Implements least-privilege database access preventing unauthorized services from reaching sensitive data, critical for PCI/SOC 2 compliance. Service-specific database SGs (30 minutes per service) ensure only services needing database access can connect, preventing lateral movement in security breaches (80% reduction in blast radius). Prevents "cannot connect to database" errors (40% of first deployment failures) while maintaining security boundaries. Satisfies compliance requirement for network-level data access controls.

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
