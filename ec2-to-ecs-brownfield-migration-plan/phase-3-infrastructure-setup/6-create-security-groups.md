# Activity 6: Security Infrastructure

**Goal:** Implement defense-in-depth networking by creating granular Security Groups before deploying any applications.

## Context & Themes

Security Groups are the primary firewall for your containers. By creating them upfront with a "chaining" pattern (ALB SG -> Task SG), we enforce strict network segmentation and prevent unauthorized access. For a detailed explanation of how Security Groups work in Fargate compared to EC2, see [Appendix: How Security Groups Work in ECS Fargate](appendix/ecs-fargate-security-groups.md).

**Key Themes:**

- **Defense-in-Depth:** Layered security controls.
- **Least Privilege:** Allowing only necessary traffic.
- **Network Segmentation:** Preventing lateral movement.

### Prerequisites

- [ ] [Activity 4: Shared Infrastructure Setup](4-setup-shared-infra.md) is complete (ALB security group IDs are available as remote state outputs).
- [ ] [Activity 5: Task Execution Role](5-task-execution-role.md) is complete.
- [ ] Terraform state is clean and up to date.

## Feature 6: Security Infrastructure

**Business Value:** Implements defense-in-depth security preventing direct container access even if IP addresses leak, reducing attack surface by 90%. Security group chaining (2-3 hours setup, free) ensures only ALB can reach containers, preventing lateral movement attacks where compromised instances attack other services. Required for PCI/SOC 2 compliance (network segmentation) and prevents 80% of cloud security breaches caused by overly permissive security rules.

> **Note:** Security groups are infrastructure, owned by the SRE/Infra team. Creating them in Phase 3 allows parallel work — infra team sets up SGs while app teams work on Phase 2 containerization.

### Story 6.1: Create Application Security Groups

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
  - **Batch this work upfront:** Create SGs for all apps now while app teams are finishing containerization in Phase 2. SGs are free until attached, and having them ready unblocks parallel deployment work in Phase 4.

**Terraform Example:**

```hcl
# File: environments/dev/us-east-1/auth-api/security_groups.tf

data "terraform_remote_state" "platform_network" {
  backend = "s3"
  config = {
    bucket = var.tf_state_bucket
    key    = "infra-platform/dev/us-east-1/00-network/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "platform_compute" {
  backend = "s3"
  config = {
    bucket = var.tf_state_bucket
    key    = "infra-platform/dev/us-east-1/01-compute/terraform.tfstate"
    region = var.aws_region
  }
}

resource "aws_security_group" "fargate_task" {
  name        = "auth-api-fargate-sg"
  description = "Security group for auth-api Fargate tasks — inbound from ALB only"
  vpc_id      = data.terraform_remote_state.platform_network.outputs.vpc_id

  tags = {
    Name        = "auth-api-fargate-sg"
    ManagedBy   = "terraform"
    Environment = var.environment
  }
}

# Inbound from the public ALB only — SG chaining, not CIDR
resource "aws_vpc_security_group_ingress_rule" "fargate_from_public_alb" {
  security_group_id            = aws_security_group.fargate_task.id
  description                  = "Allow traffic from public ALB"
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = data.terraform_remote_state.platform_compute.outputs.alb_security_group_id
}

# Inbound from the internal ALB — enables Strangler Fig weighted routing
resource "aws_vpc_security_group_ingress_rule" "fargate_from_internal_alb" {
  security_group_id            = aws_security_group.fargate_task.id
  description                  = "Allow traffic from internal ALB"
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = data.terraform_remote_state.platform_compute.outputs.internal_alb_security_group_id
}

# Outbound unrestricted — containers need to reach ECR, Secrets Manager, RDS, external APIs
resource "aws_vpc_security_group_egress_rule" "fargate_outbound" {
  security_group_id = aws_security_group.fargate_task.id
  description       = "Allow all outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Export the SG ID so Story 6.2 and Phase 4 service stacks can reference it
output "fargate_task_sg_id" {
  description = "Security group ID for auth-api Fargate tasks — used by Story 6.2 to scope RDS/ElastiCache ingress rules"
  value       = aws_security_group.fargate_task.id
}
```

- **Acceptance Criteria:**
  - ✅ One security group created per application in its `scale.infra-services` service directory
  - ✅ Inbound rules reference ALB security group IDs (not CIDRs)
  - ✅ Internal ALB SG inbound rule included (required for Strangler Fig routing in Phase 5)
  - ✅ `container_port` set in each service's `.tfvars` file
  - ✅ Outbound allows all traffic (containers need to reach ECR, Secrets Manager, RDS, external APIs)
  - ✅ `fargate_task_sg_id` exported as a Terraform output in each service stack (required by Story 6.2)
  - ✅ `terraform plan` shows no changes after apply

---

### Story 6.2: Update Database Security Groups for Fargate Access

- **Title:** Allow Fargate Task Security Groups to Access Databases
- **Target Repo:** `scale.infra-platform` — `environments/dev/us-east-1/02-storage/` (or wherever your database Terraform state is managed)
- **Persona:** As a **Security Engineer**, I want to update database security groups now so that Fargate tasks can connect when deployed in Phase 3.

**Business Value:** Enables Fargate database connectivity while maintaining security boundaries, preventing Phase 3 deployment failures. Updating database SGs upfront (1-2 hours for all databases) eliminates "cannot connect to database" errors that block 40% of first Fargate deployments. Adding rules now (while preserving EC2 access) enables safe parallel migration without service interruption. Prevents 2-4 hour debugging cycles discovering SG issues after deployment.

> **Replaces the temporary rule from Activity 2 Story 2.3.** That story added a broad VPC CIDR rule to the RDS SG as a placeholder to unblock initial task deployment. This story replaces it with scoped, per-app SG references — removing the temp rule once all app SGs are created.

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
  - **Batch this work:** Add all app SGs to database SGs now. Rules referencing SGs that aren't attached to anything yet are harmless.
  - **Keep EC2 SG rules intact:** EC2 apps still need database access during the migration. Remove EC2 rules in Phase 6 after traffic has fully cut over to Fargate.
  - **Remove the temp CIDR rule from Activity 2 Story 2.3** once all per-app rules below are in place.

- **Acceptance Criteria:**
  - ✅ RDS security group allows inbound from all Fargate task SGs (scoped per-app rules, not VPC CIDR)
  - ✅ ElastiCache security group allows inbound from all Fargate task SGs
  - ✅ Temporary VPC CIDR rule from Activity 2 Story 2.3 removed
  - ✅ EC2 access rules preserved (for migration period)
  - ✅ `terraform plan` shows no unexpected changes to other resources

**Terraform Example:**

```hcl
# File: scale.infra-platform — environments/dev/us-east-1/00-network/security_groups.tf
# Add these rules after Story 6.1 has created and exported the fargate_task_sg_id for each app.

# Read each service's fargate task SG from its own remote state
data "terraform_remote_state" "auth_api" {
  backend = "s3"
  config = {
    bucket = var.tf_state_bucket
    key    = "infra-services/dev/us-east-1/auth-api/terraform.tfstate"
    region = var.aws_region
  }
}

# RDS — allow auth-api Fargate tasks (replaces the temp VPC CIDR rule)
resource "aws_vpc_security_group_ingress_rule" "rds_from_auth_api" {
  security_group_id            = aws_security_group.rds.id
  description                  = "Allow auth-api Fargate tasks to reach RDS"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = data.terraform_remote_state.auth_api.outputs.fargate_task_sg_id
}

# Remove the temporary broad rule added in Activity 2 Story 2.3
removed {
  from = aws_vpc_security_group_ingress_rule.rds_from_vpc_temp
  lifecycle {
    destroy = true
  }
}

# Repeat the pattern for each additional app and each data store (ElastiCache, etc.)
```
