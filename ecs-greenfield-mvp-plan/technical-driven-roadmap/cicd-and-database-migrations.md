# Epic 4: CI/CD & Database Migrations

**Goal:** Build a robust, automated deployment pipeline that handles database migrations safely and validates code in Dev before touching Production.

**Duration:** 3–5 days

**Prerequisites:** Epic 3 complete (ECS cluster active, RDS running, ECR repository ready).

---

## Story 4.1: Configure OIDC & IAM Permissions

As a Security Engineer
I want to authorize GitHub Actions to deploy to AWS without using static keys
So that my pipeline is secure and I don't have to rotate credentials

### Technical Requirements

- OIDC provider for GitHub Actions (no long-lived credentials)
- IAM role with web identity trust policy scoped to specific repo
- ECR permissions: push images, scan vulnerabilities, describe images
- ECS permissions: update services, register task definitions, run one-off tasks
- IAM PassRole permission for execution and task roles
- GitHub repository secrets configured (role ARN, region, resources)
- OIDC thumbprints for token.actions.githubusercontent.com

### Implementation Details

**OIDC Provider:** Connect GitHub to AWS IAM (modern best practice).

**IAM Role Permissions (Updated for Migrations):**

- ECR: Push images, scan vulnerabilities
- ECS: Update services, register task definitions, **run one-off tasks** (for migrations)
- IAM: PassRole to allow ECS to assume execution/task roles

### Terraform Module

Create `terraform/modules/cicd/github-oidc.tf`:

```hcl
variable "project" { type = string }
variable "environment" { type = string }
variable "github_org" { type = string }
variable "github_repo" { type = string }

# OIDC Provider for GitHub Actions
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd"
  ]

  tags = { Name = "github-actions-oidc" }
}

# IAM Role for GitHub Actions
resource "aws_iam_role" "github_actions" {
  name = "${var.project}-${var.environment}-github-actions-role"

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
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:*"
        }
      }
    }]
  })

  tags = { Environment = var.environment }
}

# IAM Policy for CI/CD operations
resource "aws_iam_role_policy" "github_actions" {
  name = "cicd-permissions"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAccess"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages"
        ]
        Resource = "*"
      },
      {
        Sid    = "ECSDeployment"
        Effect = "Allow"
        Action = [
          "ecs:UpdateService",
          "ecs:DescribeServices",
          "ecs:RegisterTaskDefinition",
          "ecs:DescribeTaskDefinition",
          "ecs:RunTask",
          "ecs:DescribeTasks",
          "ecs:StopTask"
        ]
        Resource = "*"
      },
      {
        Sid    = "PassRoleForECS"
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = [
          "arn:aws:iam::*:role/${var.project}-${var.environment}-execution-role",
          "arn:aws:iam::*:role/${var.project}-${var.environment}-task-role"
        ]
      }
    ]
  })
}

output "github_actions_role_arn" {
  value       = aws_iam_role.github_actions.arn
  description = "ARN of the IAM role for GitHub Actions"
}
```

### GitHub Secrets Configuration

Add these secrets to your GitHub repository (Settings → Secrets and variables → Actions):

| Secret Name             | Value                                                        | Description                              |
| ----------------------- | ------------------------------------------------------------ | ---------------------------------------- |
| `AWS_ROLE_ARN`          | `arn:aws:iam::ACCOUNT_ID:role/myapp-dev-github-actions-role` | From Terraform output                    |
| `AWS_REGION`            | `us-east-1`                                                  | Your deployment region                   |
| `ECR_REPOSITORY`        | `ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/myapp/auth-api`  | From Epic 2                              |
| `ECS_CLUSTER`           | `myapp-dev-cluster`                                          | From Epic 3                              |
| `ECS_SERVICE`           | `myapp-dev-service`                                          | From Epic 3                              |
| `PRIVATE_SUBNET_ID`     | `subnet-xxxxx`                                               | A private app subnet for migration tasks |
| `APP_SECURITY_GROUP_ID` | `sg-xxxxx`                                                   | App security group (has DB access)       |

### Acceptance Criteria

- [ ] OIDC provider configured in AWS.
- [ ] IAM role created with `RunTask` and `PassRole` permissions.
- [ ] GitHub secrets configured.
- [ ] Test OIDC connection with a simple workflow.

---

## Story 4.2: Build & Push Workflow

As a Developer
I want to build the Docker image once and promote it through environments
So that I'm deploying the exact same binary to Dev and Production

### Technical Requirements

- Trigger on push to main branch (deploys to dev first, then prod after approval)
- Docker image tagged with commit SHA (immutable)
- Additional tags (dev-latest, prod-latest)
- ECR login via AWS credentials from OIDC
- Docker layer caching for faster builds
- Automatic vulnerability scanning on push (ECR feature)
- Job outputs: image URI and tag for downstream jobs
- Workflow runs on ubuntu-latest with id-token permissions

### Implementation Details

**Trigger:** Push to `main` branch (single branch deploys to both environments)

**Output:** Docker image tagged with commit SHA

**Caching:** Use Docker layer caching to speed up builds

### GitHub Workflow

Create `.github/workflows/build-push.yml`:

```yaml
name: Build and Push

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

env:
  AWS_REGION: us-east-1

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read

    outputs:
      image: ${{ steps.build-image.outputs.image }}
      image-tag: ${{ steps.build-image.outputs.image-tag }}

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build, tag, and push image
        id: build-image
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          ECR_REPOSITORY: ${{ secrets.ECR_REPOSITORY }}
          IMAGE_TAG: ${{ github.sha }}
        run: |
          # Build image
          docker build -t $ECR_REPOSITORY:$IMAGE_TAG .

          # Push image
          docker push $ECR_REPOSITORY:$IMAGE_TAG

          # Tag as latest for the branch
          docker tag $ECR_REPOSITORY:$IMAGE_TAG $ECR_REPOSITORY:${{ github.ref_name }}-latest
          docker push $ECR_REPOSITORY:${{ github.ref_name }}-latest

          # Output for downstream jobs
          echo "image=$ECR_REPOSITORY:$IMAGE_TAG" >> $GITHUB_OUTPUT
          echo "image-tag=$IMAGE_TAG" >> $GITHUB_OUTPUT

      - name: Scan image for vulnerabilities
        run: |
          # ECR scans automatically on push (configured in Epic 2)
          echo "Image scanning initiated by ECR"
```

### Acceptance Criteria

- [ ] Image built and pushed with commit SHA tag.
- [ ] Image also tagged as `latest` for the branch.
- [ ] ECR vulnerability scan runs automatically.
- [ ] Job outputs image URI for downstream jobs.

---

## Story 4.3: Database Migrations (The "Chicken & Egg" Fix)

As a Backend Engineer
I want to run database migrations _before_ the new code deploys
So that the application doesn't crash due to missing columns or schema changes

### Technical Requirements

- One-off ECS task runs migration using new image before deployment
- Command override: `npm run migration:run` (or ORM-specific command)
- Task runs in private subnet with app security group (DB access)
- Migration task timeout: 10 minutes maximum
- Exit code validation: 0 = success (proceed), non-zero = halt pipeline
- CloudWatch logs capture migration output for debugging
- Rollback command documented: `migration:revert`
- Migration job dependency: runs after build, before deploy
- Task definition registered before migration runs

### Implementation Details

**Strategy:** Run a one-off ECS task using the new image with a migration command override.

**Migration Flow:**

1. Register new task definition (with new image)
2. Run task with migration command override
3. Wait for task to complete
4. Check exit code:
   - **Exit 0:** Success → Proceed to deployment
   - **Exit > 0:** Failure → Halt pipeline, alert team

**Network:** Task runs in private subnet with NAT access (for npm packages if needed during migration)

### Migration Script Setup

First, add migration commands to `package.json`:

```json
{
  "scripts": {
    "migration:generate": "typeorm migration:generate",
    "migration:run": "typeorm migration:run",
    "migration:revert": "typeorm migration:revert"
  }
}
```

> Note: Adjust for your ORM (TypeORM, Prisma, Knex, etc.)

### GitHub Workflow (Migration Job)

Create `.github/workflows/deploy.yml`:

```yaml
name: Deploy

on:
  push:
    branches: [main]

env:
  AWS_REGION: us-east-1

jobs:
  migrate-dev:
    needs: build # Assumes build job from build-push.yml or merged workflow
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read

    # Deploy to dev environment first (auto-deploy)
    environment: dev

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Download task definition
        run: |
          aws ecs describe-task-definition \
            --task-definition ${{ secrets.ECS_TASK_FAMILY }} \
            --query taskDefinition > task-definition.json

      - name: Update task definition with new image
        id: task-def
        uses: aws-actions/amazon-ecs-render-task-definition@v1
        with:
          task-definition: task-definition.json
          container-name: app
          image: ${{ needs.build.outputs.image }}

      - name: Register new task definition
        id: register-task-def
        run: |
          # Remove fields not allowed in register
          jq 'del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)' \
            ${{ steps.task-def.outputs.task-definition }} > clean-task-def.json

          # Register and capture ARN
          TASK_DEF_ARN=$(aws ecs register-task-definition \
            --cli-input-json file://clean-task-def.json \
            --query 'taskDefinition.taskDefinitionArn' \
            --output text)

          echo "task-def-arn=$TASK_DEF_ARN" >> $GITHUB_OUTPUT

      - name: Run database migrations
        id: migrate
        run: |
          echo "Starting migration task..."

          # Run migration task
          TASK_ARN=$(aws ecs run-task \
            --cluster ${{ secrets.ECS_CLUSTER }} \
            --task-definition ${{ steps.register-task-def.outputs.task-def-arn }} \
            --launch-type FARGATE \
            --network-configuration "awsvpcConfiguration={subnets=[${{ secrets.PRIVATE_SUBNET_ID }}],securityGroups=[${{ secrets.APP_SECURITY_GROUP_ID }}],assignPublicIp=DISABLED}" \
            --overrides '{"containerOverrides":[{"name":"app","command":["npm","run","migration:run"]}]}' \
            --query 'tasks[0].taskArn' \
            --output text)

          echo "Migration task: $TASK_ARN"

          # Wait for task to stop (timeout after 10 minutes)
          echo "Waiting for migration to complete..."
          aws ecs wait tasks-stopped \
            --cluster ${{ secrets.ECS_CLUSTER }} \
            --tasks $TASK_ARN \
            --cli-read-timeout 600

          # Check exit code
          EXIT_CODE=$(aws ecs describe-tasks \
            --cluster ${{ secrets.ECS_CLUSTER }} \
            --tasks $TASK_ARN \
            --query 'tasks[0].containers[0].exitCode' \
            --output text)

          echo "Migration exit code: $EXIT_CODE"

          if [ "$EXIT_CODE" == "0" ]; then
            echo "✅ Migration succeeded"
            exit 0
          else
            echo "❌ Migration failed with exit code $EXIT_CODE"
            
            # Fetch logs for debugging
            LOG_STREAM=$(aws ecs describe-tasks \
              --cluster ${{ secrets.ECS_CLUSTER }} \
              --tasks $TASK_ARN \
              --query 'tasks[0].containers[0].name' \
              --output text)
            
            echo "Check CloudWatch Logs: /ecs/${{ secrets.ECS_CLUSTER }}/$LOG_STREAM"
            exit 1
          fi

    outputs:
      task-def-arn: ${{ steps.register-task-def.outputs.task-def-arn }}

  deploy:
    needs: migrate
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read

    environment: production # Requires manual approval

    steps:
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Deploy to ECS
        run: |
          echo "Updating ECS service to new task definition..."

          aws ecs update-service \
            --cluster ${{ secrets.ECS_CLUSTER }} \
            --service ${{ secrets.ECS_SERVICE }} \
            --task-definition ${{ needs.migrate.outputs.task-def-arn }} \
            --force-new-deployment

      - name: Wait for service stability
        run: |
          echo "Waiting for service to stabilize..."

          aws ecs wait services-stable \
            --cluster ${{ secrets.ECS_CLUSTER }} \
            --services ${{ secrets.ECS_SERVICE }}

          echo "✅ Deployment complete!"
```

### Rollback Strategy

If a migration fails in production:

```bash
# 1. Revert migration (run manually via ECS Exec or one-off task)
aws ecs run-task \
  --cluster myapp-prod-cluster \
  --task-definition <previous-task-def> \
  --launch-type FARGATE \
  --overrides '{"containerOverrides":[{"name":"app","command":["npm","run","migration:revert"]}]}'

# 2. Rollback service to previous task definition
aws ecs update-service \
  --cluster myapp-prod-cluster \
  --service myapp-prod-service \
  --task-definition myapp-prod-task:<previous-revision>
```

### Acceptance Criteria

- [ ] Migration job runs _after_ build but _before_ deploy.
- [ ] Job uses new image with migration command override.
- [ ] Pipeline halts if migration exits with non-zero code.
- [ ] CloudWatch logs show migration output for debugging.
- [ ] Migration timeout prevents hanging (10-minute max).

---

## Story 4.4: Dev vs Production Pipeline

As a Product Manager
I want a dev environment to validate changes before production
So that we catch bugs before they hit real users

### Technical Requirements

- Single branch strategy: main branch deploys to dev (auto), then prod (after approval)
- GitHub Environments configured with protection rules
- Dev environment: auto-deploy, no approvals required
- Production environment: 1-2 required reviewers, prevent self-review
- Environment-specific secrets (cluster, service, subnets, security groups)
- Infrastructure parity: identical network topology, different instance sizes
- Both environments use same migration → deploy workflow
- Secrets isolation: dev cannot access production resources

### Implementation Details

**Branch Strategy:**

- `main` branch → Deploys to `dev` environment (auto) → Then to `production` (after approval)

**GitHub Environments:** Configure in repository settings (Settings → Environments)

- **dev:** No protection rules, auto-deploy
- **production:** Required reviewers (1-2 people), prevent self-review

**Infrastructure:** Terraform environments already separated (`environments/dev/`, `environments/prod/`)

### Environment-Specific Secrets

**Dev Environment Secrets:**

```
AWS_ROLE_ARN: arn:aws:iam::ACCOUNT:role/myapp-dev-github-actions-role
ECS_CLUSTER: myapp-dev-cluster
ECS_SERVICE: myapp-dev-service
ECS_TASK_FAMILY: myapp-dev-task
PRIVATE_SUBNET_ID: subnet-dev-xxxxx
APP_SECURITY_GROUP_ID: sg-dev-xxxxx
```

**Production Environment Secrets:**

```
AWS_ROLE_ARN: arn:aws:iam::ACCOUNT:role/myapp-prod-github-actions-role
ECS_CLUSTER: myapp-prod-cluster
ECS_SERVICE: myapp-prod-service
ECS_TASK_FAMILY: myapp-prod-task
PRIVATE_SUBNET_ID: subnet-prod-xxxxx
APP_SECURITY_GROUP_ID: sg-prod-xxxxx
```

### Workflow Updates

The workflow uses GitHub Environments with a sequential deployment strategy:

```yaml
jobs:
  deploy-dev:
    environment: dev # Auto-deploys
    # ... deploy steps

  deploy-prod:
    needs: deploy-dev
    environment: production # Requires approval
    # ... deploy steps
```

This deploys to dev automatically, then waits for approval before deploying to production.

### Acceptance Criteria

- [ ] Pushing to `main` deploys to dev cluster automatically.
- [ ] After dev deployment succeeds, production deployment requires manual approval.
- [ ] Secrets are isolated (dev cannot access production resources).
- [ ] Both environments use the same migration → deploy flow.

---

## Story 4.5: Observability & Notifications

As a DevOps Engineer
I want to be notified when deployments fail
So that I can respond quickly to production issues

### Technical Requirements

- Slack webhook integration for deployment notifications
- Success notifications: environment, commit SHA, service name
- Failure notifications: error details, link to GitHub Actions logs
- Failed migration alerts trigger immediately (before deploy)
- Deployment duration tracked via GitHub Actions metrics
- CloudWatch logs accessible for debugging
- Notification payload uses Slack Block Kit for formatting

### Implementation Details

**Slack Notifications:** Add to workflow for critical steps

### Slack Integration (Optional)

Add to end of deploy job:

```yaml
- name: Notify on success
  if: success()
  uses: slackapi/slack-github-action@v1
  with:
    webhook-url: ${{ secrets.SLACK_WEBHOOK_URL }}
    payload: |
      {
        "text": "✅ Deployment to ${{ github.ref_name }} succeeded",
        "blocks": [
          {
            "type": "section",
            "text": {
              "type": "mrkdwn",
              "text": "*Deployment Successful*\n• Environment: `${{ github.ref_name }}`\n• Commit: `${{ github.sha }}`\n• Service: `${{ secrets.ECS_SERVICE }}`"
            }
          }
        ]
      }

- name: Notify on failure
  if: failure()
  uses: slackapi/slack-github-action@v1
  with:
    webhook-url: ${{ secrets.SLACK_WEBHOOK_URL }}
    payload: |
      {
        "text": "❌ Deployment to ${{ github.ref_name }} failed",
        "blocks": [
          {
            "type": "section",
            "text": {
              "type": "mrkdwn",
              "text": "*Deployment Failed*\n• Environment: `${{ github.ref_name }}`\n• Commit: `${{ github.sha }}`\n• Check logs: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"
            }
          }
        ]
      }
```

### Acceptance Criteria

- [ ] Slack notifications on deployment success/failure.
- [ ] Failed migrations trigger immediate alerts.
- [ ] Deployment duration tracked (GitHub Actions metrics).

---

## ✅ Epic 4 Definition of Done

1. **Pipeline Flow:** Build → Migrate → Deploy (migrations always run first).
2. **Security:** OIDC authentication; no long-lived access keys in GitHub.
3. **Reliability:** Pipeline halts if DB migration fails; rollback strategy documented.
4. **Environments:** Staging and production separated by branch + GitHub Environments.
5. **Observability:** Failed deployments trigger Slack alerts; CloudWatch logs available.
6. **Safety:** Production deployments require manual approval.

### Environment Parity

- [ ] **Staging:** Exists. Has a smaller DB (t4g.micro) but identical network topology to Prod.

### Migrations

- [ ] **Automation:** Migrations run automatically on deploy.
- [ ] **Safety:** Migration script has a "Lock" mechanism to prevent two deployments running it simultaneously.
- [ ] **Rollback:** You have a documented command to "Undo" the last migration if the app crashes.
