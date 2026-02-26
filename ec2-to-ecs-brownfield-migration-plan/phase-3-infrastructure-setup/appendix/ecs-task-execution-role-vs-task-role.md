# Appendix: Task Execution Role vs. Task Role

Every ECS Fargate task definition accepts two separate IAM role fields. They look similar, are often confused with each other, and failing to understand the distinction is one of the most common sources of Fargate permission errors.

## The Short Version

|                  | Task Execution Role (`execution_role_arn`)                                   | Task Role(`task_role_arn`)                            |
| ---------------- | ---------------------------------------------------------------------------- | ----------------------------------------------------- |
| **Used by**      | AWS / ECS control plane                                                      | Your container code                                   |
| **When**         | At task launch time, before your app starts                                  | While your app is running                             |
| **What it does** | Pulls the image, creates the log stream, fetches secrets                     | Lets your app call AWS APIs (S3, SQS, DynamoDB, etc.) |
| **Who owns it**  | Platform team (`infra-platform`)                                             | Application team (`infra-services`)                   |
| **Scope**        | Shared — one per environment (not per cluster; clusters have no IAM surface) | Per-application — one per service                     |
| **Required?**    | Yes, always                                                                  | Only if your app calls AWS APIs                       |

---

## The Task Execution Role

The Task Execution Role is assumed by the **ECS agent** (the AWS-managed process that boots your task), not by your code. By the time your container's entrypoint runs, this role has already done its job and is no longer in use.

**What it needs access to:**

1. **ECR** — to authenticate and pull your container image.
2. **CloudWatch Logs** — to create the log group and stream and deliver log output.
3. **Secrets Manager / SSM Parameter Store** — to fetch secret values and inject them as environment variables before your container starts. If this permission is missing, the task fails to start with a cryptic `ResourceInitializationError`.

**Where it lives:** `scale.infra-platform` — `environments/dev/us-east-1/01-compute/iam.tf`

This is shared infrastructure. One role covers every Fargate task in the environment. Application teams reference it via remote state output; they never touch it directly.

**AWS managed policy:** `AmazonECSTaskExecutionRolePolicy` covers the ECR and CloudWatch permissions. The Secrets Manager / SSM grants must be added as inline policies, scoped to your environment's secret path prefix.

---

## The Task Role

The Task Role is assumed by **your container process** at runtime, using the standard AWS credential chain (the metadata endpoint at `169.254.170.2`). It is the equivalent of the EC2 Instance Profile your EC2 apps used before.

**What it needs access to:**

Whatever your application code calls — for example:

- `s3:GetObject` / `s3:PutObject` if the app reads or writes files to S3
- `sqs:SendMessage` / `sqs:ReceiveMessage` if the app uses a queue
- `dynamodb:GetItem` if the app reads from DynamoDB
- `ses:SendEmail` if the app sends email
- Nothing, if the app only talks to external HTTP APIs and its own database

**Where it lives:** `scale.infra-services` — `environments/dev/us-east-1/[app-name]/iam.tf`

Each service owns its own Task Role. An `auth-api` Task Role should only have the permissions `auth-api` actually needs — not a blanket role shared with every other service.

---

## Why the Split?

The separation enforces two important principles:

**1. Least Privilege by design.** If there were a single combined role, every permission your app needs at runtime would also be granted to the AWS control plane, and vice versa. The split means a bug or compromise in your app code cannot be used to pull a different image or write to a different log stream.

**2. Different owners, different change velocity.** The execution role is stable — it rarely changes once Fargate is running. The task role changes frequently as application teams add features that integrate new AWS services. Keeping them separate means the Platform team isn't a bottleneck for every app-level IAM change, and application teams can't accidentally break the shared execution role.

---

## Common Mistakes

**Putting application permissions in the Execution Role**

```hcl
# ❌ Wrong — S3 access has nothing to do with task launch
resource "aws_iam_role_policy" "ecs_task_execution_s3" {
  name = "S3Access"
  role = aws_iam_role.ecs_task_execution.id   # <-- execution role
  policy = data.aws_iam_policy_document.s3_read.json
}
```

This works but violates least privilege. The ECS agent doesn't need S3 access. Put it in the Task Role instead.

**Omitting `execution_role_arn` entirely**

If `execution_role_arn` is missing from the task definition, Fargate uses no execution role. The task will fail immediately at image pull with an authorization error, and the CloudWatch log stream will never be created (making it hard to debug because there are no logs).

**Using `task_role_arn` for secret injection**

Secrets injected via the `secrets` field in a task definition container spec are fetched by the **ECS agent** before your container starts. This means the permission must be on the **execution role**, not the task role. A common mistake is granting `secretsmanager:GetSecretValue` on the task role and wondering why the task still fails to start.

```hcl
# ❌ Wrong — secret injection happens at launch time, not runtime
resource "aws_iam_role_policy" "task_role_secrets" {
  role   = aws_iam_role.auth_api_task.id        # <-- task role
  policy = data.aws_iam_policy_document.secrets.json
}

# ✅ Correct — execution role fetches secrets before your container starts
resource "aws_iam_role_policy" "execution_role_secrets" {
  role   = aws_iam_role.ecs_task_execution.id   # <-- execution role
  policy = data.aws_iam_policy_document.secrets.json
}
```

> **Exception:** If your application code calls `secretsmanager:GetSecretValue` directly at runtime (using the AWS SDK, not the ECS `secrets` injection mechanism), that permission belongs on the Task Role. The determining factor is _who_ is making the API call — the ECS agent (execution role) or your code (task role).

---

## How They Appear in a Task Definition

```hcl
resource "aws_ecs_task_definition" "auth_api" {
  family                   = "auth-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512

  # ── Execution Role ──────────────────────────────────────────────────────────
  # Used by the ECS agent: image pull, log stream creation, secret injection.
  # Shared across all services. Comes from infra-platform remote state.
  execution_role_arn = data.terraform_remote_state.platform_compute.outputs.ecs_task_execution_role_arn

  # ── Task Role ────────────────────────────────────────────────────────────────
  # Used by your container code: S3, SQS, DynamoDB, etc.
  # Defined in this service stack. Omit entirely if the app makes no AWS API calls.
  task_role_arn = aws_iam_role.auth_api_task.arn

  container_definitions = jsonencode([
    {
      name  = "auth-api"
      image = "${aws_ecr_repository.auth_api.repository_url}:latest"

      # These secrets are fetched by the ECS agent using the EXECUTION role.
      secrets = [
        {
          name      = "DB_PASSWORD"
          valueFrom = "arn:aws:secretsmanager:us-east-1:123456789012:secret:dev/auth-api/db-password"
        }
      ]
    }
  ])
}
```
