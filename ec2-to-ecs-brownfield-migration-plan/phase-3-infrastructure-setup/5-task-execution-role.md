# Activity 5: Task Execution Role (Shared)

**Goal:** Create a single, shared IAM Task Execution Role that grants the ECS control plane the permissions it needs to launch every Fargate task — pulling container images from ECR, shipping logs to CloudWatch, and injecting secrets at startup.

## Context & Themes

Every Fargate task requires two distinct IAM roles, both found in the `aws_ecs_task_definition`:

| Role                                       | Who uses it             | Purpose                                               |
| ------------------------------------------ | ----------------------- | ----------------------------------------------------- |
| Task Execution Role (`execution_role_arn`) | ECS control plane (AWS) | Pull images, write logs, fetch secrets at launch time |
| Task Role (`task_role_arn`)                | Your container code     | Call AWS APIs (S3, DynamoDB, SQS…) at runtime         |

The Task Execution Role is a shared, environment-level resource — one role is sufficient for all services in an environment. Creating it here, in the Platform layer, means application teams never have to think about it. They reference the role ARN as a Terraform remote state output and move on.

> **NOTE** This activity covers only the **Task Execution Role**. The Task Role is application-specific and belongs in each service's own Terraform stack.
> For a full breakdown of the difference, see [Appendix: Task Execution Role vs. Task Role](appendix/ecs-task-execution-role-vs-task-role.md).

**Key Themes:**

- **Shared Infrastructure:** One role serves all Fargate tasks in the environment — no per-service IAM sprawl.
- **Principle of Least Privilege:** The managed policy covers ECR and CloudWatch. Secrets Manager access is scoped to specific secret paths, not `*`.
- **Platform Layer Ownership:** This role lives in `scale.infra-platform` (`01-compute`), not in `scale.infra-services`. Application teams consume it; they do not own it.
- **Secret Injection:** Fargate reads `secretsmanager` or `ssm` values during container startup (before your code runs). This only works if the execution role has permission — a missing grant here is a silent launch failure.

### Prerequisites

- [ ] [Activity 2: Remediate Network Gaps](2-remediate-infra-gaps.md) is complete (private subnets and NAT Gateway exist).
- [ ] [Activity 4: Shared Infrastructure Setup](4-setup-shared-infra.md) is complete (ECS Cluster is active).
- [ ] Terraform is authenticated to the **Platform Account** with IAM write permissions.
- [ ] The `01-compute` Terraform stack has been initialized and its state is clean (`terraform plan` shows no changes for existing resources).
- [ ] Secrets Manager secrets (or SSM parameters) have been created for at least one application so the resource ARN path pattern is known.

---

## Feature 5: Shared Task Execution Role

**Business Value:** Centralizing the Task Execution Role in the Platform layer eliminates repeated IAM boilerplate across every service stack and prevents the most common Fargate launch failure — a missing or misconfigured execution role. One-time setup (30–60 minutes) unblocks every application deployment in Phase 4, and the scoped Secrets Manager policy satisfies SOC 2 / PCI audit requirements for least-privilege secret access.

### Story 5.1: Create ECS Task Execution Role

- **Title:** Create Shared ECS Task Execution Role
- **Target Repo:** `scale.infra-platform` — `environments/dev/us-east-1/01-compute/`
- **Persona:** As a **Cloud Admin**, I want a shared Task Execution Role so that Fargate can pull images and write logs without requiring per-application IAM setup.

**Why this lives in the Platform layer:** The execution role is infrastructure — not application logic. Placing it in `infra-platform` means it is provisioned once, centrally audited, and referenced by all services via remote state. If it lived in `infra-services`, each service team would have to duplicate or re-import it, creating drift risk.

- **Requirements:**
  - ECS control plane (`ecs-tasks.amazonaws.com`) can assume the role.
  - Role allows Fargate to pull images from ECR.
  - Role allows Fargate to write logs to CloudWatch Logs.
  - Role allows Fargate to read secrets from Secrets Manager at task launch time.
  - Secrets Manager access is scoped to environment-specific paths (not `*`).
  - Role ARN is exported as a Terraform output for consumption by service stacks.

- **Implementation Details:**
  - **Role Name:** `ecsTaskExecutionRole`
    - This is the AWS conventional name; the console wizard auto-looks for it. Using the convention reduces confusion.
  - **Trust Policy:** Allows only the ECS tasks service to assume the role. No humans, no other services.
  - **Managed Policy:** `AmazonECSTaskExecutionRolePolicy` — AWS-managed, covers ECR image pull and CloudWatch Logs delivery. Do not replicate this manually; AWS updates it as services evolve.
  - **Inline Policy:** Scoped `secretsmanager:GetSecretValue` grant. Scope the `Resource` to your environment's secret path prefix — never use `*`.
  - **Optional Inline Policy:** `ssm:GetParameters` if any application injects config from SSM Parameter Store instead of Secrets Manager.

**Terraform:**

```hcl
# File: variables.tf

variable "aws_region" {
  description = "AWS region for this environment (e.g. us-east-1)."
  type        = string
}

variable "environment" {
  description = "Environment name used to scope secret ARN paths (e.g. dev, staging, prod)."
  type        = string
}
```

```hcl
# File: iam.tf  (inside environments/dev/us-east-1/01-compute/)

# ── Data Sources ───────────────────────────────────────────────────────────────

# Required to resolve the current account ID for ARN construction in inline policies.
# Without this, the secretsmanager and ssm policy documents will fail at plan time.
data "aws_caller_identity" "current" {}

# Trust policy — allows the ECS control plane to assume this role on behalf of any Fargate task.
data "aws_iam_policy_document" "ecs_task_execution_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Secrets Manager — fetched by the ECS agent at launch time, before the container starts.
# Scope Resource to your environment's secret path prefix — do NOT use "*".
data "aws_iam_policy_document" "ecs_task_execution_secrets" {
  statement {
    sid     = "AllowSecretsManagerRead"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]

    resources = [
      "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.environment}/*",
    ]
  }
}

# SSM Parameter Store (optional) — include only if any app uses SSM-backed secrets injection.
# Remove this block entirely if all secrets are in Secrets Manager.
data "aws_iam_policy_document" "ecs_task_execution_ssm" {
  statement {
    sid     = "AllowSSMParameterRead"
    effect  = "Allow"
    actions = ["ssm:GetParameters"]

    resources = [
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.environment}/*",
    ]
  }
}

# ── Role ───────────────────────────────────────────────────────────────────────
resource "aws_iam_role" "ecs_task_execution" {
  name               = "ecsTaskExecutionRole"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_execution_assume_role.json

  tags = {
    ManagedBy   = "terraform"
    Environment = var.environment
    Purpose     = "ECS Fargate task execution — ECR pull, CloudWatch Logs, Secrets injection"
  }
}

# ── Managed Policy ─────────────────────────────────────────────────────────────
# Grants: ECR image pull, ECR auth token, CloudWatch Logs PutLogEvents/CreateLogStream/CreateLogGroup.
resource "aws_iam_role_policy_attachment" "ecs_task_execution_managed" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ── Inline Policies ────────────────────────────────────────────────────────────
resource "aws_iam_role_policy" "ecs_task_execution_secrets" {
  name   = "SecretsManagerRead"
  role   = aws_iam_role.ecs_task_execution.id
  policy = data.aws_iam_policy_document.ecs_task_execution_secrets.json
}

resource "aws_iam_role_policy" "ecs_task_execution_ssm" {
  name   = "SSMParameterRead"
  role   = aws_iam_role.ecs_task_execution.id
  policy = data.aws_iam_policy_document.ecs_task_execution_ssm.json
}
```

> **NOTE** Difference between `aws_iam_policy_document` (data) and inline JSON:
> Using the `aws_iam_policy_document` data source is strongly preferred over embedding raw JSON strings. Terraform validates the policy at plan time, and the ARN interpolation (`${data.aws_caller_identity.current.account_id}`) is resolved automatically — no hardcoded account IDs.

**Export the Role ARN for downstream consumption:**

```hcl
# File: outputs.tf

output "ecs_task_execution_role_arn" {
  description = "ARN of the shared ECS Task Execution Role. Reference this in all service task definitions."
  value       = aws_iam_role.ecs_task_execution.arn
}
```

Service stacks in `scale.infra-services` then consume this via remote state:

```hcl
# In a service stack (e.g., environments/dev/us-east-1/auth-api/ecs.tf)

data "terraform_remote_state" "platform_compute" {
  backend = "s3"
  config = {
    bucket = var.tf_state_bucket
    key    = "infra-platform/dev/us-east-1/01-compute/terraform.tfstate"
    region = var.aws_region
  }
}

resource "aws_ecs_task_definition" "main" {
  family                   = "auth-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512

  # ↓ Reference the shared execution role from Platform state
  execution_role_arn = data.terraform_remote_state.platform_compute.outputs.ecs_task_execution_role_arn

  # task_role_arn = aws_iam_role.auth_api_task.arn  ← app-specific, defined in the service stack
}
```

---

- **Acceptance Criteria:**
  - ✅ `ecsTaskExecutionRole` exists in IAM with the correct trust policy (`ecs-tasks.amazonaws.com`).
  - ✅ `AmazonECSTaskExecutionRolePolicy` is attached to the role.
  - ✅ Inline Secrets Manager policy is scoped to `${environment}/*` — no wildcard `Resource: "*"` present.
  - ✅ Role ARN is exported as `ecs_task_execution_role_arn` in `outputs.tf`.
  - ✅ `terraform plan` for `01-compute` shows no unexpected changes after apply.
  - ✅ At least one test task definition in a service stack references this role ARN via remote state (not a hardcoded string).

---

> **What about the Task Role?**
> The Task Role (`task_role_arn`) is the IAM role your container code uses at runtime — S3 GetObject, DynamoDB Query, SQS SendMessage, etc. Unlike the Task Execution Role, it is application-specific and belongs in each service's own Terraform stack in `scale.infra-services`.
>
> Creating per-service Task Roles is covered in [Phase 4](../phase-4-initial-deployment/) as part of deploying each individual service. At that point, the service stack will define the role, attach scoped policies, and reference it alongside the shared Execution Role ARN from this activity:
>
> ```hcl
> resource "aws_ecs_task_definition" "main" {
>   execution_role_arn = data.terraform_remote_state.platform_compute.outputs.ecs_task_execution_role_arn  # ← from this activity
>   task_role_arn      = aws_iam_role.auth_api_task.arn  # ← defined in the service stack
> }
> ```
