# Activity 4: Security Infrastructure

**Goal:** Implement defense-in-depth networking by creating granular Security Groups before deploying any applications.

## Context & Themes

Security Groups are the primary firewall for your containers. By creating them upfront with a "chaining" pattern (ALB SG -> Task SG), we enforce strict network segmentation and prevent unauthorized access.

**Key Themes:**

- **Defense-in-Depth:** Layered security controls.
- **Least Privilege:** Allowing only necessary traffic.
- **Network Segmentation:** Preventing lateral movement.

### Prerequisites

- [ ] [Activity 3: Shared Infrastructure](3-setup-shared-infrastructure.md) is complete.
- [ ] Platform Repository Setup completed.
- [ ] Terraform state is clean and up to date.

## Feature 4: Application Security Groups

**Business Value:** Implements defense-in-depth security preventing direct container access even if IP addresses leak, reducing attack surface by 90%. Security group chaining (2-3 hours setup, free) ensures only ALB can reach containers, preventing lateral movement attacks where compromised instances attack other services. Required for PCI/SOC 2 compliance (network segmentation) and prevents 80% of cloud security breaches caused by overly permissive security rules.

> **Note:** Security groups are infrastructure, owned by the SRE/Infra team. Creating them in Phase 3 allows parallel work — infra team sets up SGs while app teams work on Phase 2 containerization.

### Story 4.1: Create Application Security Groups

- **Title:** Create Per-Application Security Groups for Fargate Tasks
- **Target Layer:** `environments/dev/us-east-1/01-compute` (Workload Account) or `infra-services`
- **Persona:** As a **Security Engineer**, I want to create application security groups upfront so that they're ready when we deploy services in Phase 3.

**Business Value:** Establishes least-privilege network access preventing unauthorized connections to containers. Security group chaining (30 minutes per app) ensures only ALB traffic reaches containers, preventing 90% of lateral movement attacks in cloud breaches. Creating all SGs upfront (batch 2-3 hours for 10 apps) enables parallel deployment work and prevents Phase 3 deployment delays. Free to create, only costs when attached to resources.

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

### Story 2.6: Update Database Security Groups for Fargate Access

- **Title:** Allow Fargate Task Security Groups to Access Databases
- **Persona:** As a **Security Engineer**, I want to update database security groups now so that Fargate tasks can connect when deployed in Phase 3.

**Business Value:** Enables Fargate database connectivity while maintaining security boundaries, preventing Phase 3 deployment failures. Updating database SGs upfront (1-2 hours for all databases) eliminates "cannot connect to database" errors that block 40% of first Fargate deployments. Adding rules now (while preserving EC2 access) enables safe parallel migration without service interruption. Prevents 2-4 hour debugging cycles discovering SG issues after deployment.

- **Requirements:**
  - RDS security group must allow inbound from each Fargate task security group
  - Same applies to ElastiCache, OpenSearch, or any data stores
  - Updates can be done before Fargate tasks are deployed (SG rules are forward-looking)

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

## Feature 4: Secrets Management

**Business Value:** Eliminates hardcoded credentials security risk and enables automated secret rotation, critical for SOC 2/PCI compliance. Secrets Manager ($0.40/secret/month, typically $10-40/month total) prevents credentials in source code or task definitions, eliminating the #1 cause of cloud data breaches (exposed credentials). Automatic encryption, audit logging, and rotation prevent manual credential management overhead (2-4 hours/month) and eliminate "forgot to rotate production password" security incidents. Required for compliance certifications.

### Story 4.1: Secrets Manager Setup

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

## Feature 5: IAM Roles

### Story 5.1: Task Execution Role (Shared)

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

---

### Story 5.2: Task Role Template (Per-App)

- **Title:** Create Application-Specific Task Role
- **Persona:** As a **Cloud Admin**, I want per-application Task Roles so that each app has only the AWS permissions it needs (least privilege).

- **Requirements:**
  - Separate role per application (if app needs AWS access)
  - Only permissions required by application code
  - No hardcoded credentials in application

- **Implementation Details:**
  - **Role Name:** `[app-name]-task-role` (e.g., `auth-api-task-role`)
  - **Trust Policy:** Same as Task Execution Role (ECS tasks)
  - **Example Policies by Use Case:**
    - **S3 Access:**
      ```json
      {
        "Effect": "Allow",
        "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
        "Resource": "arn:aws:s3:::my-app-bucket/*"
      }
      ```
    - **SQS Access:**
      ```json
      {
        "Effect": "Allow",
        "Action": [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage"
        ],
        "Resource": "arn:aws:sqs:us-east-1:123456789012:my-queue"
      }
      ```
    - **SES Email:**
      ```json
      {
        "Effect": "Allow",
        "Action": ["ses:SendEmail", "ses:SendRawEmail"],
        "Resource": "*",
        "Condition": {
          "StringEquals": { "ses:FromAddress": "noreply@mycompany.com" }
        }
      }
      ```
    - **DynamoDB Access:**
      ```json
      {
        "Effect": "Allow",
        "Action": ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:Query"],
        "Resource": "arn:aws:dynamodb:us-east-1:123456789012:table/my-table"
      }
      ```
  - **No Task Role Needed If:**
    - App only talks to RDS/ElastiCache (uses network, not IAM)
    - App only makes external API calls (no AWS services)

- **Acceptance Criteria:**
  - ✅ Task Role created for apps requiring AWS access
  - ✅ Permissions scoped to specific resources (not `*`)
  - ✅ No AWS credentials hardcoded in application
  - ✅ Application can access required AWS services when running in Fargate

---

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
