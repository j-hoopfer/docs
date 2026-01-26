# ECS Fargate Migration Plan - Phase 4: Scaling the Migration

## Overview

Phase 3 established the pattern for deploying ONE application. Now you need to repeat this for 9 more apps efficiently. This phase covers:

1. **Reusable Workflows** — Don't copy-paste `deploy.yml` 10 times
2. **Service Discovery** — Internal service-to-service communication
3. **Strangler Fig Pattern** — Gradual traffic migration with weighted routing
4. **Operational Excellence** — Auto-scaling, monitoring, alerting

**Key Principle:** Optimize for maintainability. A change to deployment logic should propagate to all apps automatically.

---

## Feature 1: Reusable CI/CD Workflows

### Story 1.1: Create Centralized Workflow Template

- **Title:** Build Reusable Deployment Workflow
- **Persona:** As a **Platform Engineer**, I want a single deployment template so that improvements to CI/CD propagate to all 10 applications without editing 10 files.
- **Requirements:**
  - Single source of truth for deployment logic
  - Apps pass configuration as inputs
  - Shared logic for build, push, deploy
  - Easy to add features (Slack notifications, security scanning)
- **Implementation Details:**
  - **Create Infrastructure Repository:**
    - Repo: `my-org/infrastructure` (or `my-org/platform-workflows`)
    - This holds shared workflows, Terraform modules, documentation
  - **Reusable Workflow Template:**
    - File: `infrastructure/.github/workflows/ecs-deploy-template.yml`

    ```yaml
    name: Reusable ECS Deploy

    on:
      workflow_call:
        inputs:
          ecr_repository:
            description: "ECR repository path (e.g., legacy-migration/auth-api)"
            required: true
            type: string
          service_name:
            description: "ECS service name"
            required: true
            type: string
          cluster_name:
            description: "ECS cluster name"
            required: false
            type: string
            default: "production-cluster"
          task_definition:
            description: "Task definition family name"
            required: true
            type: string
          container_name:
            description: "Container name in task definition"
            required: true
            type: string
          dockerfile_path:
            description: "Path to Dockerfile"
            required: false
            type: string
            default: "./Dockerfile"
          aws_region:
            description: "AWS region"
            required: false
            type: string
            default: "us-east-1"
        secrets:
          AWS_ROLE_ARN:
            required: true

    jobs:
      deploy:
        name: Build and Deploy
        runs-on: ubuntu-latest

        steps:
          - name: Checkout
            uses: actions/checkout@v4

          - name: Configure AWS credentials
            uses: aws-actions/configure-aws-credentials@v4
            with:
              aws-region: ${{ inputs.aws_region }}
              role-to-assume: ${{ secrets.AWS_ROLE_ARN }}

          - name: Login to Amazon ECR
            uses: aws-actions/amazon-ecr-login@v2
            id: login-ecr

          - name: Build, tag, and push image
            id: build-image
            env:
              ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
              ECR_REPOSITORY: ${{ inputs.ecr_repository }}
              IMAGE_TAG: ${{ github.sha }}
            run: |
              docker build \
                --platform linux/amd64 \
                -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG \
                -t $ECR_REGISTRY/$ECR_REPOSITORY:latest \
                -f ${{ inputs.dockerfile_path }} .
              docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
              docker push $ECR_REGISTRY/$ECR_REPOSITORY:latest
              echo "image=$ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG" >> $GITHUB_OUTPUT

          - name: Download task definition
            run: |
              aws ecs describe-task-definition \
                --task-definition ${{ inputs.task_definition }} \
                --query taskDefinition > task-definition.json

          - name: Render new task definition
            uses: aws-actions/amazon-ecs-render-task-definition@v1
            id: task-def
            with:
              task-definition: task-definition.json
              container-name: ${{ inputs.container_name }}
              image: ${{ steps.build-image.outputs.image }}

          - name: Check if ECS service exists
            id: check-service
            run: |
              # Attempt to describe the service to see if it exists
              if aws ecs describe-services \
                --cluster ${{ inputs.cluster_name }} \
                --services ${{ inputs.service_name }} \
                --query 'services[0].status' --output text | grep -q ACTIVE; then
                echo "exists=true" >> $GITHUB_OUTPUT
              else
                echo "exists=false" >> $GITHUB_OUTPUT
              fi

          - name: Deploy to ECS (Update Existing Service)
            if: steps.check-service.outputs.exists == 'true'
            uses: aws-actions/amazon-ecs-deploy-task-definition@v2
            with:
              task-definition: ${{ steps.task-def.outputs.task-definition }}
              service: ${{ inputs.service_name }}
              cluster: ${{ inputs.cluster_name }}
              wait-for-service-stability: true

          - name: Create ECS Service (First Run)
            if: steps.check-service.outputs.exists == 'false'
            run: |
              # This handles the bootstrap case where service doesn't exist yet
              # You'll need to provide additional inputs for service creation:
              # - subnets, security groups, target group ARN, etc.
              # For now, this is a placeholder - manual first deployment still recommended
              echo "⚠️ Service does not exist. Create it manually first (see Phase 3, Story 4.1)"
              echo "Once created, subsequent pushes will update automatically."
              exit 1
    ```

  - **Key Features:**
    - `--platform linux/amd64` baked in (no more M1/M2 architecture errors)
    - Pushes both `:sha` and `:latest` tags
    - Cluster defaults to `production-cluster` (most apps won't need to specify)
    - Region defaults to `us-east-1`

- **Acceptance Criteria:**
  - ✅ Template workflow exists in infrastructure repo
  - ✅ Template accepts all required inputs
  - ✅ Template can be called from other repos
  - ✅ Default values reduce boilerplate in calling workflows

---

### Story 1.2: Create Minimal App Workflows

- **Title:** Implement Lightweight Caller Workflows in App Repos
- **Persona:** As a **Developer**, I want my app's deployment config to be minimal so that I don't have to understand the full CI/CD pipeline to deploy.

- **Requirements:**
  - App workflow is < 20 lines
  - Only app-specific values are configured
  - References centralized template

- **Implementation Details:**
  - **App Workflow:** `.github/workflows/deploy.yml` in each app repo

    ```yaml
    name: Deploy to Production

    on:
      push:
        branches:
          - main

    jobs:
      deploy:
        uses: my-org/infrastructure/.github/workflows/ecs-deploy-template.yml@main
        with:
          ecr_repository: legacy-migration/auth-api
          service_name: auth-api-service
          task_definition: auth-api
          container_name: auth-api
        secrets:
          AWS_ROLE_ARN: ${{ secrets.AWS_ROLE_ARN }}
    ```

  - **Example for Other Apps:**
    | App | ecr_repository | service_name | task_definition | container_name |
    |-----|----------------|--------------|-----------------|----------------|
    | auth-api | legacy-migration/auth-api | auth-api-service | auth-api | auth-api |
    | user-api | legacy-migration/user-api | user-api-service | user-api | user-api |
    | admin-panel | legacy-migration/admin-panel | admin-panel-service | admin-panel | admin-panel |
    | notification-service | legacy-migration/notifications | notifications-service | notifications | notifications |
  - **Versioning Strategy:**
    - `@main` — Always use latest template (good for active development)
    - `@v1` — Pin to stable version (good for production stability)
    - `@abc123` — Pin to specific commit (maximum stability)

- **Acceptance Criteria:**
  - ✅ App workflow is under 25 lines
  - ✅ Push to main triggers deployment
  - ✅ No duplicate deployment logic across repos
  - ✅ Template changes propagate to all apps

---

### Story 1.3: Add Workflow Enhancements

- **Title:** Enhance Reusable Workflow with Notifications and Security
- **Persona:** As a **Platform Engineer**, I want to add features to the deployment pipeline so that all apps get Slack notifications and security scanning without individual configuration.

- **Requirements:**
  - Slack notification on deploy success/failure
  - Container image security scanning
  - Optional staging environment support

- **Implementation Details:**
  - **Add to Template (optional steps):**

    ```yaml
    # Add after build step
    - name: Run Trivy vulnerability scanner
      uses: aquasecurity/trivy-action@master
      with:
        image-ref: ${{ steps.build-image.outputs.image }}
        format: "table"
        exit-code: "1"
        ignore-unfixed: true
        severity: "CRITICAL,HIGH"

    # Add at end of job
    - name: Notify Slack on success
      if: success()
      uses: slackapi/slack-github-action@v1
      with:
        payload: |
          {
            "text": "✅ Deployed ${{ inputs.service_name }} to ECS",
            "blocks": [
              {
                "type": "section",
                "text": {
                  "type": "mrkdwn",
                  "text": "*Deployment Successful*\n• Service: `${{ inputs.service_name }}`\n• Image: `${{ github.sha }}`\n• Actor: ${{ github.actor }}"
                }
              }
            ]
          }
      env:
        SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}

    - name: Notify Slack on failure
      if: failure()
      uses: slackapi/slack-github-action@v1
      with:
        payload: |
          {
            "text": "❌ Failed to deploy ${{ inputs.service_name }}",
            "blocks": [
              {
                "type": "section",
                "text": {
                  "type": "mrkdwn",
                  "text": "*Deployment Failed*\n• Service: `${{ inputs.service_name }}`\n• Actor: ${{ github.actor }}\n• <${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}|View Logs>"
                }
              }
            ]
          }
      env:
        SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}
    ```

  - **Benefits of Centralized Enhancements:**
    - Add Trivy scanning → All 10 apps now scan for CVEs
    - Add Slack notifications → All 10 apps notify on deploy
    - No changes needed in individual app repos

- **Acceptance Criteria:**
  - ✅ Security scanning runs on all deployments
  - ✅ Slack notifications sent on success/failure
  - ✅ App repos don't need to change to get new features

---

### Story 1.4: Operationalize IAM Role Security (Per-Service Roles)

- **Title:** Split Shared GitHub Deployer Role into Per-Service Roles
- **Persona:** As a **Security Engineer**, I want each service to have its own dedicated IAM role so that a compromised repository cannot access other services (blast radius containment).

- **Requirements:**
  - Each GitHub repository can only deploy its own service
  - Compromised repo cannot affect other services
  - Minimal manual work (automated with IaC)
  - Easy to add new services

- **When to Implement:**
  - ✅ **Do this when:** You have 3+ distinct services in production
  - ✅ **Do this when:** Services handle different sensitivity levels (e.g., public blog vs. financial data)
  - ✅ **Do this when:** Multiple teams/developers have access to different repos
  - ⏸️ **Skip for now if:** You're solo, all services are similar sensitivity, moving fast

- **Implementation Details:**
  - **The Security Problem (Why Shared Roles Are Risky):**

    With a shared `github-deployer` role:
    - `recipe-blog` repo gets compromised (attacker pushes malicious code)
    - Attacker uses the shared role to:
      - Deploy malicious code to `banking-api` service
      - Delete production database
      - Exfiltrate customer data
    - **Blast radius:** One compromised repo = entire infrastructure at risk

  - **The Solution (Per-Service Roles):**

    Each service gets a dedicated role:
    - `auth-api` repo → `auth-api-deployer` role (can ONLY touch auth-api resources)
    - `billing-api` repo → `billing-api-deployer` role (can ONLY touch billing-api resources)
    - `recipe-blog` repo → `recipe-blog-deployer` role (can ONLY touch recipe-blog resources)

    If `recipe-blog` is compromised:
    - Attacker can only affect the recipe blog
    - **Cannot** touch banking, auth, or billing services
    - **Blast radius:** Limited to one service

  - **How Large Orgs Avoid Manual Work:**

    They use **Infrastructure as Code (IaC)** to automate this:

    ```hcl
    # Terraform example (pseudo-code)
    module "ecs_service" {
      source = "./modules/ecs-service"

      service_name     = "auth-api"
      github_repo      = "my-org/auth-api"
      ecr_repository   = "legacy-migration/auth-api"
      cluster_name     = "production-cluster"
      database_arn     = aws_db_instance.auth_db.arn
    }

    # This module automatically creates:
    # 1. ECR repository
    # 2. IAM role: auth-api-deployer
    # 3. Trust policy: Only my-org/auth-api can assume
    # 4. Permissions: Only auth-api ECR, ECS service, and database
    # 5. GitHub secret: Pushes AWS_ROLE_ARN to repo
    ```

    When developer adds a new service:
    1. Add 5 lines to Terraform
    2. Run `terraform apply`
    3. Everything provisioned automatically
    4. No manual console clicking

  - **Manual Implementation Steps (If Not Using IaC Yet):**

    For each service:
    1. **Create Per-Service IAM Role:**
       - Role Name: `[service-name]-deployer` (e.g., `auth-api-deployer`)
       - Trust Policy (SPECIFIC to one repo):
         ```json
         {
           "Version": "2012-10-17",
           "Statement": [
             {
               "Effect": "Allow",
               "Principal": {
                 "Federated": "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
               },
               "Action": "sts:AssumeRoleWithWebIdentity",
               "Condition": {
                 "StringEquals": {
                   "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
                 },
                 "StringLike": {
                   "token.actions.githubusercontent.com:sub": "repo:my-org/auth-api:ref:refs/heads/main"
                 }
               }
             }
           ]
         }
         ```
       - **Key Changes:**
         1. `repo:my-org/auth-api:ref:refs/heads/main` instead of `repo:my-org/auth-api:*` (restricts to main branch only)
         2. Specific repo (not `repo:my-org/*:*`)
       - **Why restrict to main branch?**
         - Prevents feature branches from deploying to production
         - Developer can't deploy from their fork
         - Must go through pull request → merge → main → deploy workflow
    2. **Create Scoped Permissions Policy:**

       ```json
       {
         "Version": "2012-10-17",
         "Statement": [
           {
             "Sid": "ECRAuth",
             "Effect": "Allow",
             "Action": "ecr:GetAuthorizationToken",
             "Resource": "*"
           },
           {
             "Sid": "ECRPushAuthApiOnly",
             "Effect": "Allow",
             "Action": [
               "ecr:BatchCheckLayerAvailability",
               "ecr:PutImage",
               "ecr:InitiateLayerUpload",
               "ecr:UploadLayerPart",
               "ecr:CompleteLayerUpload"
             ],
             "Resource": "arn:aws:ecr:us-east-1:123456789012:repository/legacy-migration/auth-api"
           },
           {
             "Sid": "ECSDeployAuthApiOnly",
             "Effect": "Allow",
             "Action": [
               "ecs:DescribeServices",
               "ecs:DescribeTaskDefinition",
               "ecs:RegisterTaskDefinition",
               "ecs:UpdateService"
             ],
             "Resource": [
               "arn:aws:ecs:us-east-1:123456789012:service/production-cluster/auth-api-service",
               "arn:aws:ecs:us-east-1:123456789012:task-definition/auth-api:*"
             ]
           },
           {
             "Sid": "PassRoleAuthApi",
             "Effect": "Allow",
             "Action": "iam:PassRole",
             "Resource": [
               "arn:aws:iam::123456789012:role/ecsTaskExecutionRole",
               "arn:aws:iam::123456789012:role/auth-api-task-role"
             ]
           }
         ]
       }
       ```

       - **Key Change:** Specific ECR repo, specific ECS service (no wildcards)

    3. **Update GitHub Secret in auth-api repo:**
       - Old: `AWS_ROLE_ARN = arn:aws:iam::123456789012:role/github-deployer` (shared)
       - New: `AWS_ROLE_ARN = arn:aws:iam::123456789012:role/auth-api-deployer` (dedicated)
    4. **Repeat for each service**

  - **Migration Strategy (Gradual Rollout):**
    1. **Keep shared role active** (don't delete yet)
    2. **Create first per-service role** (e.g., for auth-api)
    3. **Update auth-api's AWS_ROLE_ARN secret**
    4. **Test deployment** (verify auth-api still deploys)
    5. **Verify isolation:** Try deploying to billing-api using auth-api-deployer role (should fail)
    6. **Roll out to remaining services** one at a time
    7. **Delete shared role** once all services migrated

  - **IaC Recommendation (Future):**

    After proving the pattern manually, consider automating with:
    - **Terraform:** `terraform-aws-modules/ecs/aws` + custom module
    - **AWS CDK:** `aws-cdk-lib/aws-ecs` patterns
    - **Pulumi:** `@pulumi/aws/ecs`

    Benefits:
    - New service = 10 lines of code
    - Consistent security policies
    - No manual console clicking
    - Changes tracked in Git

- **Acceptance Criteria:**
  - ✅ Each service has dedicated IAM role
  - ✅ Trust policy scoped to single GitHub repo
  - ✅ Permissions scoped to specific ECR repo and ECS service
  - ✅ Test: Attempt to deploy Service A using Service B's role (should fail)
  - ✅ Shared `github-deployer` role deleted
  - ✅ Documentation updated with pattern for adding new services

---

## Feature 2: Infrastructure as Code for Service Provisioning

> **Note:** This feature automates the AWS infrastructure setup (Target Groups, ECS Services, Listener Rules) that you currently create manually in the console. This is optional but highly recommended once you have 2-3 services and understand the pattern.

### Story 2.1: Set Up Terraform Structure

- **Title:** Establish Infrastructure as Code Repository
- **Persona:** As a **Platform Engineer**, I want to manage all AWS infrastructure as code so that creating a new service is as simple as adding a few lines of configuration instead of clicking through the console 15 times.

- **Requirements:**
  - Shared infrastructure (VPC, ALB, Cluster) defined once
  - Per-service resources (Target Group, ECS Service, Listener Rule) are reusable modules
  - Adding a new service requires minimal code
  - All infrastructure changes tracked in Git

- **When to Implement:**
  - ✅ **Do this when:** You have 2+ services deployed manually and understand the pattern
  - ✅ **Do this when:** You're tired of clicking through the console
  - ✅ **Do this when:** You want consistency and reproducibility
  - ⏸️ **Skip for now if:** You've only deployed 1 service and are still learning
  - ⏸️ **Skip for now if:** Your team has zero Terraform experience

- **Implementation Details:**
  - **Repository Structure:**

    ```
    infrastructure/
    ├── README.md
    ├── shared/                    # Created once, rarely changed
    │   ├── main.tf               # Provider config
    │   ├── vpc.tf                # VPC, subnets, NAT
    │   ├── alb.tf                # Shared ALB
    │   ├── cluster.tf            # ECS cluster
    │   ├── ecr.tf                # ECR repositories
    │   ├── outputs.tf            # Export ARNs for services to use
    │   └── variables.tf
    ├── services/                  # One directory per service
    │   ├── auth-api/
    │   │   └── main.tf           # Instantiates service module
    │   ├── test-api-1/
    │   │   └── main.tf
    │   └── test-api-2/
    │       └── main.tf
    └── modules/
        └── ecs-service/           # Reusable service module
            ├── main.tf            # Target Group, Service, Listener Rule
            ├── variables.tf       # service_name, port, domain, etc.
            └── outputs.tf
    ```

  - **Shared Infrastructure (infrastructure/shared/outputs.tf):**

    **⚠️ Important: Configure DynamoDB State Locking**

    Before applying any Terraform, configure state locking to prevent concurrent modifications:

    ```hcl
    # infrastructure/shared/main.tf
    terraform {
      required_version = ">= 1.0"

      backend "s3" {
        bucket         = "my-company-terraform-state"
        key            = "ecs-migration/shared/terraform.tfstate"
        region         = "us-east-1"
        encrypt        = true
        dynamodb_table = "terraform-state-lock"  # Critical for preventing corruption
      }

      required_providers {
        aws = {
          source  = "hashicorp/aws"
          version = "~> 5.0"
        }
      }
    }
    ```

    **Create DynamoDB lock table (one-time setup):**

    ```bash
    aws dynamodb create-table \
      --table-name terraform-state-lock \
      --attribute-definitions AttributeName=LockID,AttributeType=S \
      --key-schema AttributeName=LockID,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST \
      --region us-east-1
    ```

    **Why this matters:**
    - Without locking: Two people run `terraform apply` → state corruption
    - With DynamoDB locking: Second person waits or gets blocked
    - DynamoDB cost: ~$0.25/month (essentially free)

    ```hcl
    # These outputs are used by service modules
    output "vpc_id" {
      value = aws_vpc.main.id
    }

    output "private_subnet_ids" {
      value = aws_subnet.private[*].id
    }

    output "alb_arn" {
      value = aws_lb.shared_alb.arn
    }

    output "alb_listener_arn" {
      value = aws_lb_listener.https.arn
    }

    output "alb_security_group_id" {
      value = aws_security_group.alb_sg.id
    }

    output "cluster_name" {
      value = aws_ecs_cluster.main.name
    }

    output "cluster_id" {
      value = aws_ecs_cluster.main.id
    }
    ```

  - **Service Module (infrastructure/modules/ecs-service/main.tf):**

    ```hcl
    # This module creates everything needed for one service

    # 1. Target Group
    resource "aws_lb_target_group" "this" {
      name        = "${var.service_name}-tg"
      port        = var.container_port
      protocol    = "HTTP"
      vpc_id      = var.vpc_id
      target_type = "ip"

      health_check {
        enabled             = true
        healthy_threshold   = 2
        unhealthy_threshold = 3
        timeout             = 5
        interval            = 30
        path                = var.health_check_path
        matcher             = "200"
      }

      deregistration_delay = 30
    }

    # 2. ALB Listener Rule
    resource "aws_lb_listener_rule" "this" {
      listener_arn = var.alb_listener_arn
      priority     = var.listener_priority

      action {
        type             = "forward"
        target_group_arn = aws_lb_target_group.this.arn
      }

      condition {
        host_header {
          values = [var.host_header]
        }
      }
    }

    # 3. Security Group for ECS Tasks
    resource "aws_security_group" "this" {
      name        = "${var.service_name}-sg"
      description = "Security group for ${var.service_name} ECS tasks"
      vpc_id      = var.vpc_id

      ingress {
        description     = "Allow traffic from ALB"
        from_port       = var.container_port
        to_port         = var.container_port
        protocol        = "tcp"
        security_groups = [var.alb_security_group_id]
      }

      egress {
        description = "Allow all outbound"
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
      }
    }

    # 4. ECS Task Definition
    resource "aws_ecs_task_definition" "this" {
      family                   = var.service_name
      network_mode             = "awsvpc"
      requires_compatibilities = ["FARGATE"]
      cpu                      = var.cpu
      memory                   = var.memory
      execution_role_arn       = var.task_execution_role_arn
      task_role_arn            = var.task_role_arn

      container_definitions = jsonencode([
        {
          name      = var.service_name
          image     = "${var.ecr_registry}/${var.ecr_repository}:latest"
          essential = true

          portMappings = [
            {
              containerPort = var.container_port
              protocol      = "tcp"
            }
          ]

          environment = var.environment_variables

          secrets = var.secrets

          logConfiguration = {
            logDriver = "awslogs"
            options = {
              "awslogs-group"         = "/ecs/${var.cluster_name}/${var.service_name}"
              "awslogs-region"        = var.aws_region
              "awslogs-stream-prefix" = "ecs"
            }
          }

          healthCheck = {
            command     = ["CMD-SHELL", "curl -f http://localhost:${var.container_port}${var.health_check_path} || exit 1"]
            interval    = 30
            timeout     = 5
            retries     = 3
            startPeriod = 60
          }
        }
      ])
    }

    # 5. ECS Service
    resource "aws_ecs_service" "this" {
      name            = "${var.service_name}-service"
      cluster         = var.cluster_id
      task_definition = aws_ecs_task_definition.this.arn
      desired_count   = var.desired_count
      launch_type     = "FARGATE"

      network_configuration {
        subnets          = var.private_subnet_ids
        security_groups  = [aws_security_group.this.id]
        assign_public_ip = false
      }

      load_balancer {
        target_group_arn = aws_lb_target_group.this.arn
        container_name   = var.service_name
        container_port   = var.container_port
      }

      deployment_configuration {
        minimum_healthy_percent = 100
        maximum_percent         = 200
      }

      deployment_circuit_breaker {
        enable   = true
        rollback = true
      }

      depends_on = [aws_lb_listener_rule.this]
    }
    ```

  - **Using the Module (infrastructure/services/auth-api/main.tf):**

    ```hcl
    terraform {
      backend "s3" {
        bucket = "my-terraform-state"
        key    = "services/auth-api/terraform.tfstate"
        region = "us-east-1"
      }
    }

    # Reference shared infrastructure outputs
    data "terraform_remote_state" "shared" {
      backend = "s3"
      config = {
        bucket = "my-terraform-state"
        key    = "shared/terraform.tfstate"
        region = "us-east-1"
      }
    }

    module "auth_api" {
      source = "../../modules/ecs-service"

      # Service config
      service_name      = "auth-api"
      container_port    = 3000
      host_header       = "auth.mysite.com"
      health_check_path = "/health"
      listener_priority = 100

      # Resource sizing
      cpu           = "256"   # 0.25 vCPU
      memory        = "512"   # 0.5 GB
      desired_count = 1

      # ECR
      ecr_registry   = data.terraform_remote_state.shared.outputs.ecr_registry
      ecr_repository = "legacy-migration/auth-api"

      # Reference shared infrastructure
      vpc_id                   = data.terraform_remote_state.shared.outputs.vpc_id
      private_subnet_ids       = data.terraform_remote_state.shared.outputs.private_subnet_ids
      alb_listener_arn         = data.terraform_remote_state.shared.outputs.alb_listener_arn
      alb_security_group_id    = data.terraform_remote_state.shared.outputs.alb_security_group_id
      cluster_name             = data.terraform_remote_state.shared.outputs.cluster_name
      cluster_id               = data.terraform_remote_state.shared.outputs.cluster_id
      task_execution_role_arn  = data.terraform_remote_state.shared.outputs.ecs_task_execution_role_arn
      task_role_arn            = aws_iam_role.auth_api_task_role.arn  # Per-service role

      # Environment variables
      environment_variables = [
        { name = "NODE_ENV", value = "production" },
        { name = "PORT", value = "3000" }
      ]

      # Secrets from Secrets Manager
      secrets = [
        {
          name      = "DB_PASSWORD"
          valueFrom = "arn:aws:secretsmanager:us-east-1:123456789012:secret:auth-api/db-password"
        }
      ]
    }
    ```

  - **How This Answers "Which ALB? Which Cluster?":**

    The service modules **reference the shared infrastructure outputs**:
    - `alb_listener_arn` comes from `data.terraform_remote_state.shared.outputs.alb_listener_arn`
    - `cluster_id` comes from `data.terraform_remote_state.shared.outputs.cluster_id`

    This way:
    - Shared resources are defined ONCE
    - All services automatically use the same ALB and cluster
    - If you change ALB or cluster, just update the shared config
    - No duplication, no manual copy-paste

  - **Adding a New Service (2 minutes of work):**
    1. Copy `services/auth-api/main.tf` to `services/new-service/main.tf`
    2. Change 5 values:
       - `service_name = "new-service"`
       - `host_header = "new.mysite.com"`
       - `listener_priority = 110` (unique per service)
       - `ecr_repository = "legacy-migration/new-service"`
       - Any environment variables/secrets
    3. Run:
       ```bash
       cd services/new-service
       terraform init
       terraform plan
       terraform apply
       ```
    4. Done! Target Group, ECS Service, Listener Rule, Security Group all created

- **Acceptance Criteria:**
  - ✅ Terraform repository structure created
  - ✅ Shared infrastructure module exports outputs
  - ✅ Service module is reusable and parameterized
  - ✅ At least one service successfully deployed via Terraform
  - ✅ Team understands how to add new services

---

### Story 2.2: Migrate Existing Services to Terraform

- **Title:** Import Manually-Created Resources into Terraform
- **Persona:** As a **Platform Engineer**, I want to bring my existing services under Terraform management so that I have a consistent workflow for all services.

- **Requirements:**
  - Existing services continue running without disruption
  - Terraform state reflects actual AWS resources
  - No manual recreation of resources

- **Implementation Details:**
  - **Strategy: Import vs Recreate:**
    - **Option A: Import (Zero downtime, more work):**
      - Use `terraform import` to bring existing resources into Terraform state
      - Write Terraform config to match existing resources exactly
      - Good for production services that can't tolerate downtime
    - **Option B: Recreate (Simpler, brief downtime):**
      - Destroy manually-created resources
      - Let Terraform create them fresh
      - Good for dev/test environments
      - Use this if you're still in migration phase with blue/green DNS

  - **Import Example (for auth-api service):**

    ```bash
    # 1. Write Terraform config that matches current setup
    # (Use the service module from Story 2.1)

    # 2. Initialize Terraform
    cd infrastructure/services/auth-api
    terraform init

    # 3. Import existing resources one by one
    terraform import module.auth_api.aws_lb_target_group.this arn:aws:elasticloadbalancing:...
    terraform import module.auth_api.aws_lb_listener_rule.this arn:aws:elasticloadbalancing:...
    terraform import module.auth_api.aws_security_group.this sg-xxxxx
    terraform import module.auth_api.aws_ecs_task_definition.this auth-api
    terraform import module.auth_api.aws_ecs_service.this production-cluster/auth-api-service

    # 4. Verify state matches reality
    terraform plan  # Should show "No changes"

    # 5. Now Terraform manages these resources
    ```

  - **Get ARNs for Import:**

    ```bash
    # Target Group ARN
    aws elbv2 describe-target-groups --names auth-api-tg --query 'TargetGroups[0].TargetGroupArn'

    # Listener Rule ARN
    aws elbv2 describe-rules --listener-arn <listener-arn> \
      --query 'Rules[?Conditions[?HostHeaderConfig.Values[?contains(@, `auth.mysite.com`)]]].RuleArn'

    # Security Group ID
    aws ec2 describe-security-groups --filters Name=group-name,Values=auth-api-sg \
      --query 'SecurityGroups[0].GroupId'

    # ECS Service (format: cluster/service-name)
    echo "production-cluster/auth-api-service"
    ```

  - **Common Import Issues:**

    | Issue                                  | Cause                                       | Fix                                           |
    | -------------------------------------- | ------------------------------------------- | --------------------------------------------- |
    | "Resource already exists"              | Terraform tried to create instead of import | Run terraform import first                    |
    | "No changes" not showing               | Config doesn't match reality                | Inspect AWS resource and update .tf file      |
    | Import succeeds but plan shows changes | Computed values differ                      | Apply changes or use lifecycle ignore_changes |

  - **Simpler Alternative (If downtime OK):**
    1. Ensure GitHub Actions workflow deploys successfully
    2. Delete manually-created Target Group, Listener Rule, ECS Service from console
    3. Run `terraform apply` to recreate everything
    4. Verify service comes back up
    5. Total downtime: ~2-5 minutes

- **Acceptance Criteria:**
  - ✅ All services under Terraform management
  - ✅ `terraform plan` shows no unexpected changes
  - ✅ Team can make changes via code instead of console
  - ✅ Infrastructure changes tracked in Git

---

### Story 2.3: Automate Service Provisioning

- **Title:** Use Terraform in CI/CD to Auto-Provision New Services
- **Persona:** As a **Developer**, I want infrastructure to be created automatically when I add a new service config file so that I don't have to manually run Terraform commands.

- **Requirements:**
  - Terraform runs in CI/CD
  - Changes to infrastructure repo trigger Terraform apply
  - Safe approval workflow for production changes

- **Implementation Details:**
  - **GitHub Actions Workflow (infrastructure/.github/workflows/terraform.yml):**

    ```yaml
    name: Terraform Apply

    on:
      push:
        branches:
          - main
        paths:
          - "services/**"
          - "shared/**"
          - "modules/**"
      pull_request:
        paths:
          - "services/**"
          - "shared/**"
          - "modules/**"

    jobs:
      terraform:
        runs-on: ubuntu-latest
        strategy:
          matrix:
            service:
              - auth-api
              - test-api-1
              - test-api-2

        steps:
          - uses: actions/checkout@v4

          - name: Configure AWS credentials
            uses: aws-actions/configure-aws-credentials@v4
            with:
              role-to-assume: ${{ secrets.TERRAFORM_ROLE_ARN }}
              aws-region: us-east-1

          - name: Setup Terraform
            uses: hashicorp/setup-terraform@v3

          - name: Terraform Init
            working-directory: ./services/${{ matrix.service }}
            run: terraform init

          - name: Terraform Plan
            working-directory: ./services/${{ matrix.service }}
            run: terraform plan -out=tfplan

          - name: Terraform Apply
            if: github.ref == 'refs/heads/main'
            working-directory: ./services/${{ matrix.service }}
            run: terraform apply -auto-approve tfplan
    ```

  - **Workflow for Adding a New Service:**
    1. Developer creates `services/new-service/main.tf`
    2. Commits and pushes to branch
    3. CI runs `terraform plan` (shows what will be created)
    4. Team reviews PR
    5. Merge to main
    6. CI runs `terraform apply` automatically
    7. Service infrastructure created
    8. Developer deploys application code via existing GitHub Actions

  - **Safety: Use Terraform Cloud or Atlantis (Optional):**
    - **Problem:** Auto-apply on merge can be dangerous
    - **Solution:** Require manual approval for Terraform changes

    **Option A: Terraform Cloud (Recommended):**
    - Free tier: 500 resources
    - PR shows plan as comment
    - Requires manual "Approve & Apply" in UI
    - State stored securely

    **Option B: Atlantis (Self-hosted):**
    - Open source Terraform automation
    - Comment `atlantis apply` on PR to run
    - Runs in your AWS account

- **Acceptance Criteria:**
  - ✅ Terraform runs in CI/CD
  - ✅ Pull requests show infrastructure changes
  - ✅ Production changes require approval
  - ✅ State stored securely (S3 backend)

---

## Feature 3: Service Discovery (Internal Communication)

> **⚠️ IMPORTANT: This feature is a FUTURE OPTIMIZATION, not required for migration.**
>
> During migration, you will use the **Internal ALB** (set up in Phase 2) for all internal service-to-service communication. The Internal ALB is required for the Strangler Fig cutover pattern.
>
> Cloud Map Service Discovery is an **optional optimization** to consider 3-6 months after migration is complete. It removes the ALB hop for slightly lower latency and cost savings, but adds complexity.
>
> **Migration phases:**
>
> 1. **During migration:** KrakenD and services → Internal ALB → EC2/ECS (weighted routing)
> 2. **Post-migration (optional):** Services → Cloud Map DNS → ECS directly (no ALB hop)

### Story 2.1: Enable AWS Cloud Map Service Discovery

- **Title:** Configure Direct Service-to-Service Communication (Post-Migration Optimization)
- **Persona:** As a **Developer**, I want services to communicate directly via DNS so that we eliminate the Internal ALB hop for lower latency.

- **Requirements:**
  - Internal DNS names for each service
  - No public internet routing for internal calls
  - Automatic registration/deregistration of tasks

- **Prerequisites:**
  - All services fully migrated to ECS (100% traffic, EC2 decommissioned)
  - Internal ALB no longer needed for weighted routing
  - Team comfortable with ECS operations

- **Implementation Details:**
  - **Context: Why This is Optional**
    - The Internal ALB already solves the "keep traffic in VPC" problem
    - Cloud Map removes the ALB hop: Service A → DNS → Service B task IP directly
    - Trade-off: Slightly lower latency vs. losing ALB's health checks and load balancing
    - If your internal traffic volume is low, the ALB cost (~$16/month) may not be worth optimizing away
  - **The Problem Cloud Map Solves:**
    - With Internal ALB: App A → Internal ALB → App B (extra network hop)
    - With Cloud Map: App A → App B directly (DNS resolves to task IP)
    - Latency improvement: ~1-5ms (usually negligible unless high-volume internal calls)
  - **The Solution (Cloud Map):**
    - With Service Discovery: App A calls `http://app-b.production.local:3000`
    - Traffic flow: App A → VPC internal network → App B (direct)
    - Benefits:
      - Slightly lower latency (no ALB hop)
      - No ALB cost for internal traffic
      - No TLS needed (internal traffic)
  - **Setup Steps:**
    1. **Create Cloud Map Namespace:**
       - AWS Console → Cloud Map → Create namespace
       - Name: `production.local` (or `internal.yourcompany`)
       - Type: Private DNS namespace
       - VPC: Select your Fargate VPC
    2. **Enable Service Discovery on ECS Service:**
       - When creating ECS Service, expand "Service discovery"
       - Enable service discovery integration
       - Namespace: Select `production.local`
       - Service discovery name: `auth-api` (becomes `auth-api.production.local`)
       - DNS record type: A (for IP-based routing)
       - TTL: 60 seconds
    3. **Update Application Configuration:**
       - Old: `API_URL=https://api.yoursite.com`
       - New: `AUTH_SERVICE_URL=http://auth-api.production.local:3000`
       - Note: Use HTTP (not HTTPS) for internal traffic
  - **Service Discovery DNS Names:**
    | Service | Internal DNS | Port |
    |---------|-------------|------|
    | auth-api | auth-api.production.local | 3000 |
    | user-api | user-api.production.local | 3000 |
    | notification-service | notifications.production.local | 3000 |
    | admin-panel | admin-panel.production.local | 3000 |
  - **Security Group Updates:**
    - Services that receive internal traffic need SG rules:
    - Add inbound rule: Port 3000 from `[calling-service]-sg`
    - Or create a shared `internal-services-sg` that all internal services use

- **Acceptance Criteria:**
  - ✅ Cloud Map namespace created
  - ✅ ECS services register with service discovery
  - ✅ `dig auth-api.production.local` resolves inside VPC
  - ✅ Internal service calls work without public internet
  - ✅ No NAT Gateway charges for internal traffic

---

### Story 2.2: Update Application Configurations for Internal Routing

- **Title:** Refactor Service URLs to Use Internal DNS
- **Persona:** As a **Developer**, I want to update service configurations so that internal calls use the private network.

- **Requirements:**
  - Identify all inter-service communication
  - Update URLs to use internal DNS names
  - Maintain external URLs for client-facing endpoints

- **Implementation Details:**
  - **Audit Current Service Communication:**
    - Map which services call which other services
    - Example dependency map:
      ```
      frontend → auth-api (login, token validation)
      frontend → user-api (profile, settings)
      admin-panel → user-api (user management)
      admin-panel → notification-service (send alerts)
      user-api → notification-service (welcome emails)
      ```
  - **Configuration Pattern:**

    ```javascript
    // config.js
    module.exports = {
      // External (client-facing) - keep public URLs
      publicUrl: process.env.PUBLIC_URL || "https://api.yoursite.com",

      // Internal (server-to-server) - use service discovery
      services: {
        auth:
          process.env.AUTH_SERVICE_URL ||
          "http://auth-api.production.local:3000",
        user:
          process.env.USER_SERVICE_URL ||
          "http://user-api.production.local:3000",
        notifications:
          process.env.NOTIFICATION_SERVICE_URL ||
          "http://notifications.production.local:3000",
      },
    };
    ```

  - **Environment Variables (Task Definition):**
    ```json
    "environment": [
      { "name": "AUTH_SERVICE_URL", "value": "http://auth-api.production.local:3000" },
      { "name": "USER_SERVICE_URL", "value": "http://user-api.production.local:3000" },
      { "name": "PUBLIC_URL", "value": "https://api.yoursite.com" }
    ]
    ```
  - **Testing Internal Connectivity:**

    ```bash
    # Exec into a running task
    aws ecs execute-command --cluster production-cluster \
      --task <task-id> --container auth-api --interactive \
      --command "/bin/sh"

    # Test DNS resolution
    nslookup user-api.production.local

    # Test connectivity
    curl http://user-api.production.local:3000/health
    ```

- **Acceptance Criteria:**
  - ✅ Service dependency map documented
  - ✅ Internal URLs configured in task definitions
  - ✅ Services can reach each other via internal DNS
  - ✅ External client traffic still uses public ALB URLs

---

## Feature 3: Strangler Fig Migration Pattern

### Story 3.1: Create Internal ALB for Traffic Mixing

- **Title:** Set Up Internal Load Balancer for Gradual Cutover
- **Persona:** As a **Operations Engineer**, I want to gradually shift traffic from EC2 to Fargate so that we can validate the new platform with real traffic before full cutover.

- **Requirements:**
  - Route percentage of traffic to Fargate (canary)
  - Ability to quickly rollback to EC2
  - No application code changes for traffic shifting
  - Works with existing API Gateway/KrakenD architecture

- **Implementation Details:**
  - **Architecture Overview:**

    ```
    Current:
    Public ALB → KrakenD (EC2) → Apps (EC2) → DB

    With Internal ALB (Traffic Mixer):
    Public ALB → KrakenD (EC2) → Internal ALB → [EC2 (90%) | Fargate (10%)] → DB
    ```

  - **Why Internal ALB:**
    - KrakenD doesn't have native weighted routing
    - ALB has built-in weighted target group routing
    - Single config change in KrakenD (point to Internal ALB)
    - Traffic split controlled via AWS Console (no redeploy needed)
  - **Step 1: Create Internal ALB**
    - AWS Console → EC2 → Load Balancers → Create
    - Name: `internal-traffic-mixer`
    - Scheme: **Internal** (not internet-facing)
    - VPC: Same as Fargate tasks
    - Subnets: Private subnets
    - Security Group: Allow traffic from KrakenD SG
  - **Step 2: Create Target Groups**
    - **Legacy Target Group (EC2):**
      - Name: `legacy-auth-api-tg`
      - Target Type: **Instance**
      - Register: Existing EC2 instances running auth-api
      - Health Check: `/health`
    - **Fargate Target Group:**
      - Name: `fargate-auth-api-tg`
      - Target Type: **IP**
      - Auto-registered by ECS Service
      - Health Check: `/health`
  - **Step 3: Configure Weighted Routing**
    - Create HTTPS listener on Internal ALB (or HTTP if internal traffic doesn't need encryption)
    - Listener Rule:
      - Forward to target groups:
        - `legacy-auth-api-tg`: Weight **100**
        - `fargate-auth-api-tg`: Weight **0**
    - This starts with 100% traffic to EC2
  - **Step 4: Update KrakenD**
    - Change backend URL from EC2 direct IP to Internal ALB DNS:

    ```json
    {
      "endpoint": "/api/auth",
      "backend": [
        {
          "host": ["http://internal-traffic-mixer.production.local"],
          "url_pattern": "/auth"
        }
      ]
    }
    ```

    - Deploy KrakenD once. All future traffic shifts happen via ALB weights.

- **Acceptance Criteria:**
  - ✅ Internal ALB created in private subnets
  - ✅ Both target groups (EC2 and Fargate) created
  - ✅ KrakenD updated to point to Internal ALB
  - ✅ 100% traffic flowing through Internal ALB to EC2 (baseline)

---

### Story 3.2: Execute Canary Release

- **Title:** Gradually Shift Traffic to Fargate
- **Persona:** As a **Operations Engineer**, I want to incrementally shift traffic so that I can monitor for errors before committing to full migration.

- **Requirements:**
  - Start with 0% Fargate, end with 100%
  - Monitor error rates at each increment
  - Ability to instant rollback
  - No downtime during shifts

- **Implementation Details:**
  - **Traffic Shifting Schedule:**
    | Day | EC2 Weight | Fargate Weight | Duration | Action |
    |-----|------------|----------------|----------|--------|
    | 1 | 100% | 0% | Baseline | Verify ALB routing works |
    | 2 | 95% | 5% | 4 hours | Monitor error rates |
    | 2 | 90% | 10% | 24 hours | Extended monitoring |
    | 3 | 75% | 25% | 24 hours | Increase if stable |
    | 4 | 50% | 50% | 24 hours | Half traffic |
    | 5 | 25% | 75% | 24 hours | Majority on Fargate |
    | 6 | 0% | 100% | Ongoing | Full migration |
  - **How to Shift Traffic:**
    - AWS Console → EC2 → Target Groups
    - Select Internal ALB listener
    - Edit rule → Modify weights
    - No deployment, no KrakenD changes—instant effect
  - **Monitoring During Canary:**
    - **CloudWatch Metrics to Watch:**
      - `HTTPCode_Target_5XX_Count` (both target groups)
      - `TargetResponseTime` (compare EC2 vs Fargate)
      - `HealthyHostCount` (both target groups)
      - `UnHealthyHostCount` (should be 0)
    - **CloudWatch Logs:**
      - Search for `error` or `exception` in Fargate logs
      - Compare error patterns to EC2 logs
    - **Application Metrics (if APM in place):**
      - Response time percentiles (p50, p95, p99)
      - Error rates by endpoint
      - Database query times
  - **Rollback Trigger Criteria:**
    | Metric | Threshold | Action |
    |--------|-----------|--------|
    | 5XX Error Rate | > 1% increase | Rollback to previous weight |
    | Response Time | > 50% increase | Investigate, consider rollback |
    | Healthy Hosts | < desired count | Immediate rollback |
    | User Reports | Critical bug reports | Immediate rollback |
  - **Rollback Procedure:**
    1. Go to EC2 → Load Balancers → Internal ALB → Listeners
    2. Edit rule weights: EC2 = 100%, Fargate = 0%
    3. Changes take effect within seconds
    4. Monitor traffic shift in Target Group metrics
    5. Investigate Fargate issues before next attempt
- **Acceptance Criteria:**
  - ✅ Traffic successfully shifted through all stages
  - ✅ No increase in error rates during migration
  - ✅ Fargate response times comparable to EC2
  - ✅ 100% traffic on Fargate with stable metrics

---

### Story 3.3: Decommission Legacy Infrastructure

- **Title:** Clean Up EC2 Resources After Migration
- **Persona:** As a **Cloud Engineer**, I want to decommission old infrastructure so that we stop paying for unused resources.

- **Requirements:**
  - Confirm Fargate is handling 100% traffic successfully
  - Remove EC2 from target group
  - Terminate EC2 instances (after retention period)
  - Clean up associated resources

- **Implementation Details:**
  - **Decommission Checklist (Per Application):**
    - [ ] Fargate handling 100% traffic for 7+ days
    - [ ] No error rate increase
    - [ ] No user complaints
    - [ ] Rollback not needed in past week
  - **Step 1: Remove EC2 from Target Group**
    - AWS Console → EC2 → Target Groups → `legacy-auth-api-tg`
    - Deregister instances
    - Wait for connection draining (default 300s)
  - **Step 2: Stop EC2 Instance (Don't Terminate Yet)**
    - Stop instance (keeps EBS volumes)
    - Retention period: 7-14 days
    - Why: Easy restart if critical issue discovered
  - **Step 3: Create AMI Backup**
    - AWS Console → EC2 → Instances → Create Image
    - Name: `auth-api-ec2-backup-YYYYMMDD`
    - Store in case of disaster recovery need
  - **Step 4: Terminate EC2 Instance**
    - After retention period with no issues
    - Terminate instance
    - Delete associated EBS volumes (if not needed)
  - **Step 5: Clean Up Associated Resources**
    - [ ] Delete legacy target group
    - [ ] Remove old security group rules referencing EC2
    - [ ] Delete EC2 security group (if app-specific)
    - [ ] Remove old CloudWatch log groups
    - [ ] Update monitoring dashboards
    - [ ] Update documentation
  - **Cost Savings Calculation:**
    | Resource | Monthly Cost | Notes |
    |----------|-------------|-------|
    | EC2 t3.medium | ~$30 | Per instance |
    | EBS 50GB | ~$5 | Per instance |
    | Old ELB (if exists) | ~$18 | If migrating to shared ALB |
    | **Potential Savings** | ~$53/app | Times 10 apps = $530/month |

- **Acceptance Criteria:**
  - ✅ EC2 instances terminated
  - ✅ AMI backups created
  - ✅ Legacy target groups deleted
  - ✅ No orphaned resources
  - ✅ Cost reduction visible in billing

---

## Feature 4: Operational Excellence

### Story 4.1: Configure Auto-Scaling

- **Title:** Implement Target Tracking Auto-Scaling
- **Persona:** As a **Operations Engineer**, I want services to scale automatically so that we handle traffic spikes without manual intervention.

- **Requirements:**
  - Scale based on CPU utilization
  - Minimum tasks for high availability
  - Maximum tasks for cost control
  - Scale-in protection during deployments

- **Implementation Details:**
  - **Auto-Scaling Configuration:**
    - AWS Console → ECS → Clusters → Services → Service auto scaling
    - Or via AWS CLI/Terraform
  - **Recommended Settings:**

    ```
    Minimum tasks: 2 (for high availability)
    Desired tasks: 2 (starting point)
    Maximum tasks: 10 (cost ceiling)

    Scaling Policy: Target Tracking
    Target metric: ECSServiceAverageCPUUtilization
    Target value: 70%
    Scale-out cooldown: 60 seconds
    Scale-in cooldown: 300 seconds
    Datapoints to alarm: 3 out of 3 (3-minute evaluation window)
    ```

  - **Why These Settings:**
    - Min 2: If one task dies, service stays up
    - Target 70% CPU: Room for traffic spikes before scaling
    - Scale-out 60s: React quickly to load
    - Scale-in 300s: Avoid thrashing (wait before removing capacity)
    - **3-minute evaluation (3 datapoints):** Prevents scaling on JVM garbage collection spikes
      - **Problem:** JVM GC can cause 30-second CPU spike → triggers scale-out → wastes money
      - **Solution:** Require 3 consecutive high readings (3 minutes) before scaling
      - Applies to Node.js, Python, Ruby (any runtime with GC)
  - **Alternative Metrics:**
    - `ECSServiceAverageMemoryUtilization` — For memory-bound apps
    - `ALBRequestCountPerTarget` — For request-based scaling
    - Custom CloudWatch metrics — For business-specific scaling

- **Acceptance Criteria:**
  - ✅ Auto-scaling policy configured
  - ✅ Service scales out when CPU > 70%
  - ✅ Service scales in when load decreases
  - ✅ Never goes below minimum tasks

---

### Story 4.2: Create Monitoring Dashboard

- **Title:** Build CloudWatch Dashboard for ECS Services
- **Persona:** As a **Operations Engineer**, I want a unified dashboard so that I can monitor all services at a glance.

- **Requirements:**
  - Single dashboard for all ECS services
  - Key metrics: CPU, Memory, Request count, Error rate
  - Easy to spot anomalies

- **Implementation Details:**
  - **Dashboard Widgets:**
    | Widget | Metric | Source |
    |--------|--------|--------|
    | ECS CPU | CPUUtilization | Container Insights |
    | ECS Memory | MemoryUtilization | Container Insights |
    | ALB Requests | RequestCount | ALB metrics |
    | ALB 5XX Errors | HTTPCode_Target_5XX_Count | ALB metrics |
    | ALB Response Time | TargetResponseTime | ALB metrics |
    | Healthy Tasks | HealthyHostCount | Target Group |
    | Running Tasks | RunningTaskCount | ECS metrics |
  - **CloudWatch Dashboard JSON:**
    ```json
    {
      "widgets": [
        {
          "type": "metric",
          "properties": {
            "title": "ECS CPU Utilization",
            "metrics": [
              [
                "ECS/ContainerInsights",
                "CpuUtilized",
                "ClusterName",
                "production-cluster",
                "ServiceName",
                "auth-api-service"
              ],
              ["...", "user-api-service"],
              ["...", "admin-panel-service"]
            ],
            "period": 60,
            "stat": "Average"
          }
        }
      ]
    }
    ```
- **Acceptance Criteria:**
  - ✅ Dashboard created with key metrics
  - ✅ All ECS services visible
  - ✅ Team can access dashboard

---

### Story 4.3: Configure CloudWatch Alarms

- **Title:** Set Up Alerting for Critical Issues
- **Persona:** As a **Operations Engineer**, I want automated alerts so that we're notified of issues before users report them.

- **Requirements:**
  - Alert on high error rates
  - Alert on service degradation
  - Alert on task failures
  - Notifications via Slack/PagerDuty/Email

- **Implementation Details:**
  - **Critical Alarms:**
    | Alarm | Metric | Threshold | Action |
    |-------|--------|-----------|--------|
    | High 5XX Rate | HTTPCode_Target_5XX_Count | > 10 in 5 min | Alert team |
    | No Healthy Tasks | HealthyHostCount | < 1 for 1 min | Page on-call |
    | High CPU | CPUUtilization | > 90% for 5 min | Alert team |
    | High Memory | MemoryUtilization | > 90% for 5 min | Alert team |
    | Service Deployment Failed | ECS events | Task stopped reason | Alert team |
  - **SNS Topic for Alerts:**
    ```bash
    aws sns create-topic --name ecs-alerts
    aws sns subscribe --topic-arn arn:aws:sns:us-east-1:123456789012:ecs-alerts \
      --protocol email --notification-endpoint ops-team@yourcompany.com
    ```
  - **Example Alarm (High Error Rate):**
    ```bash
    aws cloudwatch put-metric-alarm \
      --alarm-name "auth-api-high-5xx" \
      --alarm-description "High 5XX error rate on auth-api" \
      --metric-name HTTPCode_Target_5XX_Count \
      --namespace AWS/ApplicationELB \
      --statistic Sum \
      --period 300 \
      --threshold 10 \
      --comparison-operator GreaterThanThreshold \
      --evaluation-periods 1 \
      --alarm-actions arn:aws:sns:us-east-1:123456789012:ecs-alerts \
      --dimensions Name=TargetGroup,Value=targetgroup/auth-api-tg/abc123 \
                   Name=LoadBalancer,Value=app/fargate-shared-alb/xyz789
    ```

- **Acceptance Criteria:**
  - ✅ Alarms configured for all services
  - ✅ Notifications reaching team
  - ✅ No alert fatigue (thresholds tuned)

---

## Phase 4 Checklist

### Reusable Workflows

- [ ] Infrastructure repo created
- [ ] Reusable workflow template created
- [ ] App repos updated to use template
- [ ] Template versioning strategy defined

### Service Discovery

- [ ] Cloud Map namespace created
- [ ] ECS services registered with service discovery
- [ ] Internal DNS resolves correctly
- [ ] Applications updated to use internal URLs
- [ ] Security groups allow internal traffic

### Strangler Fig Migration

- [ ] Internal ALB created
- [ ] Legacy and Fargate target groups created
- [ ] KrakenD/API Gateway updated
- [ ] Traffic successfully shifted in stages
- [ ] EC2 instances decommissioned
- [ ] Cleanup completed

### Operational Excellence

- [ ] Auto-scaling configured for all services
- [ ] CloudWatch dashboard created
- [ ] Alarms configured
- [ ] Notification channels tested
- [ ] Runbooks documented

---

## Appendix A: Strangler Fig Pattern — Deep Dive

This appendix explains how the Strangler Fig pattern works for both **external traffic** (users → API Gateway → services) and **internal traffic** (service-to-service calls), including the role of the Internal ALB.

### A.1: The Problem — Why Strangler Fig?

**Big Bang Migration Risks:**

- Deploy everything to Fargate at once
- Flip DNS from EC2 to Fargate
- If something breaks: rollback is complex, potential extended downtime

**Strangler Fig Approach:**

- Run EC2 and Fargate in parallel
- Gradually shift traffic: 5% → 25% → 50% → 100%
- Monitor at each stage
- Instant rollback: just change weights back

### A.2: Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              EXTERNAL TRAFFIC                                │
│                           (Users → Your APIs)                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│    Internet                                                                  │
│       │                                                                      │
│       ▼                                                                      │
│  ┌─────────────┐                                                            │
│  │ Public ALB  │  ← HTTPS termination, host-based routing                   │
│  │ (External)  │                                                            │
│  └──────┬──────┘                                                            │
│         │                                                                    │
│         ▼                                                                    │
│  ┌─────────────┐                                                            │
│  │  KrakenD    │  ← API Gateway (still on EC2 during migration)             │
│  │   (EC2)     │                                                            │
│  └──────┬──────┘                                                            │
│         │                                                                    │
│         │  All backend calls go through Internal ALB                         │
│         ▼                                                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                              INTERNAL TRAFFIC                                │
│                         (Service-to-Service)                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│         │                                                                    │
│         ▼                                                                    │
│  ┌──────────────────┐                                                       │
│  │   Internal ALB   │  ← Traffic Mixer (weighted routing)                   │
│  │  (Private Only)  │                                                       │
│  └────────┬─────────┘                                                       │
│           │                                                                  │
│     ┌─────┴─────┐                                                           │
│     │  Weights  │                                                           │
│     ▼           ▼                                                           │
│  ┌──────┐   ┌──────┐                                                        │
│  │ EC2  │   │ ECS  │                                                        │
│  │ 70%  │   │ 30%  │  ← Adjust weights to shift traffic                     │
│  └──┬───┘   └──┬───┘                                                        │
│     │         │                                                              │
│     └────┬────┘                                                              │
│          ▼                                                                   │
│     ┌─────────┐                                                             │
│     │   RDS   │  ← Same database, both EC2 and ECS connect                  │
│     └─────────┘                                                             │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### A.3: Internal ALB — The Traffic Mixer

The Internal ALB is the key component that enables gradual migration. It sits between callers (KrakenD, other services) and backends (EC2 and ECS).

**Why not just use DNS switching?**

- DNS TTLs cause inconsistent cutover (some clients cache longer)
- No weighted routing capability
- Rollback requires waiting for TTL expiry

**Why Internal ALB works:**

- Instant traffic shifting (weight changes apply immediately)
- Same ALB serves both EC2 and ECS backends
- Callers only know one endpoint (`http://internal.yourcompany.local`)
- Health checks automatically remove unhealthy targets

### A.4: Step-by-Step Migration Flow

#### Phase A: Baseline (Before Migration)

```
KrakenD → EC2 instances directly (or via existing internal routing)
Service A → Service B (via private IPs or existing DNS)
```

**Action:** Update all internal callers to use Internal ALB

- KrakenD config: Point to `http://internal.yourcompany.local/auth-api`
- Service env vars: `AUTH_API_URL=http://internal.yourcompany.local/auth-api`

**Internal ALB State:**
| Service | EC2 Target Group | ECS Target Group |
|---------|-----------------|------------------|
| auth-api | 100% | 0% |
| user-api | 100% | 0% |

**Validation:** All traffic flows through Internal ALB to EC2. Nothing has changed functionally.

---

#### Phase B: Deploy ECS (0% Traffic)

**Action:** Deploy service to ECS Fargate

- ECS Service created, tasks running
- Health checks passing
- Added to Internal ALB target group with weight 0%

**Internal ALB State:**
| Service | EC2 Target Group | ECS Target Group |
|---------|-----------------|------------------|
| auth-api | 100% | 0% (deployed, ready) |

**Validation:**

- ECS tasks are healthy
- Can test directly: `curl http://<task-private-ip>:3000/health`
- No production traffic yet

---

#### Phase C: Canary (5-10% Traffic)

**Action:** Shift small percentage to ECS

**Internal ALB State:**
| Service | EC2 Target Group | ECS Target Group |
|---------|-----------------|------------------|
| auth-api | 95% | 5% |

**How to change weights:**

```
AWS Console → EC2 → Load Balancers → internal-services-alb
→ Listeners → View/edit rules → Edit rule
→ Forward to:
   - legacy-auth-api-tg: Weight 95
   - fargate-auth-api-tg: Weight 5
→ Save
```

**Monitoring (critical):**

- Compare error rates: EC2 target group vs ECS target group
- Compare latency: `TargetResponseTime` for both groups
- Watch CloudWatch Logs for new errors in ECS
- Monitor for 2-4 hours minimum

**Rollback trigger:**

- ECS error rate > EC2 error rate + 1%
- ECS latency > EC2 latency + 50ms
- Any critical functionality broken

**Rollback action:** Set ECS weight back to 0%

---

#### Phase D: Gradual Increase

**Action:** If canary is healthy, increase traffic

**Progression:**
| Stage | EC2 Weight | ECS Weight | Duration | Notes |
|-------|-----------|-----------|----------|-------|
| Canary | 95% | 5% | 4 hours | Initial validation |
| Early | 90% | 10% | 24 hours | Extended monitoring |
| Mid | 75% | 25% | 24 hours | Quarter traffic |
| Half | 50% | 50% | 24 hours | Equal split |
| Majority | 25% | 75% | 24 hours | ECS handling most |
| Full | 0% | 100% | Ongoing | Migration complete |

**Key insight:** At each stage, if issues occur, you can instantly revert to the previous stage by changing weights.

---

#### Phase E: Full Migration (100% ECS)

**Internal ALB State:**
| Service | EC2 Target Group | ECS Target Group |
|---------|-----------------|------------------|
| auth-api | 0% | 100% |

**Validation:**

- All traffic on ECS for 7+ days
- No error rate increase
- No latency increase
- No user complaints

---

#### Phase F: Decommission EC2

**Action:** Remove EC2 from the equation

1. **Deregister EC2 from target group**
   - Allows connection draining (300 seconds default)
2. **Stop EC2 instance (don't terminate yet)**
   - Keep for 7-14 days as safety net
   - Easy to restart if critical issue found

3. **Delete legacy target group**
   - Clean up unused resources

4. **Terminate EC2 instance**
   - After retention period passes
   - Create AMI backup first

5. **Update Internal ALB rules**
   - Remove weighted routing, simplify to single target group
   - Optional: Now you can consider Cloud Map for direct routing

### A.5: Internal Service-to-Service Calls

The same pattern applies when **Service A calls Service B**:

```
┌───────────────────────────────────────────────────────────────┐
│                     Service A (ECS Task)                       │
│                                                                │
│   Code: axios.get(process.env.USER_API_URL + '/users/123')    │
│                                                                │
│   Env: USER_API_URL=http://internal.yourcompany.local/user-api│
└───────────────────────────────┬───────────────────────────────┘
                                │
                                ▼
┌───────────────────────────────────────────────────────────────┐
│                      Internal ALB                              │
│                                                                │
│   Rule: Path /user-api/* → Forward to:                        │
│         - legacy-user-api-tg (70%)                            │
│         - fargate-user-api-tg (30%)                           │
└───────────────────────────────┬───────────────────────────────┘
                                │
                    ┌───────────┴───────────┐
                    ▼                       ▼
          ┌─────────────────┐     ┌─────────────────┐
          │  User API (EC2) │     │  User API (ECS) │
          │      70%        │     │      30%        │
          └─────────────────┘     └─────────────────┘
```

**Key points:**

- Service A doesn't know or care if User API runs on EC2 or ECS
- Traffic split is controlled at the ALB level
- Both EC2 and ECS talk to the same database
- You can migrate services independently

### A.6: Migration Sequencing with Dependencies

When services depend on each other, migrate in dependency order:

```
Example dependency chain:
  frontend → auth-api → user-api → notification-service
                                         ↓
                                   (external SMTP)
```

**Recommended order:**

1. **Leaf services first** (notification-service) — no internal dependencies
2. **Work backward** (user-api → auth-api)
3. **Frontend last** — depends on everything

**Why this order:**

- When you migrate auth-api, user-api is already stable on ECS
- Internal calls (auth-api → user-api) go through Internal ALB
- If auth-api has issues, you can isolate the problem

**Alternative: Migrate independently**

- Because Internal ALB handles routing, you can actually migrate in any order
- EC2 auth-api can call ECS user-api through Internal ALB
- ECS auth-api can call EC2 user-api through Internal ALB
- The Internal ALB abstracts the backend location

### A.7: Routing Rules on Internal ALB

**Option 1: Path-based routing (recommended)**

- Single DNS: `internal.yourcompany.local`
- Rules route by path prefix

```
Rule 1: Path = /auth-api/*    → auth-api target groups
Rule 2: Path = /user-api/*    → user-api target groups
Rule 3: Path = /notifications/* → notifications target groups
Default: Return 404
```

**Service configuration:**

```bash
AUTH_API_URL=http://internal.yourcompany.local/auth-api
USER_API_URL=http://internal.yourcompany.local/user-api
```

**Option 2: Host-based routing**

- Multiple DNS records, all pointing to same ALB
- Rules route by Host header

```
auth-api.internal.yourcompany.local → auth-api target groups
user-api.internal.yourcompany.local → user-api target groups
```

**Service configuration:**

```bash
AUTH_API_URL=http://auth-api.internal.yourcompany.local
USER_API_URL=http://user-api.internal.yourcompany.local
```

**Recommendation:** Start with path-based (simpler DNS setup), switch to host-based if you need cleaner URLs.

### A.8: Comparison — External vs Internal Strangler Fig

| Aspect             | External Traffic                  | Internal Traffic                    |
| ------------------ | --------------------------------- | ----------------------------------- |
| **Entry Point**    | Public ALB                        | Internal ALB                        |
| **Caller**         | Internet users, mobile apps       | KrakenD, other services             |
| **TLS**            | Required (HTTPS)                  | Optional (HTTP OK in VPC)           |
| **DNS**            | Public DNS (Route 53 public zone) | Private DNS (Route 53 private zone) |
| **Traffic Mixer**  | Public ALB or Route 53 weighted   | Internal ALB weighted target groups |
| **Rollback Speed** | Instant (ALB weights)             | Instant (ALB weights)               |
| **Security**       | Security group: 0.0.0.0/0 on 443  | Security group: VPC CIDR only       |

### A.9: After Full Migration — Simplification Options

Once all services are 100% on ECS, you can simplify:

**Option A: Keep Internal ALB (recommended initially)**

- Pros: Familiar, debuggable, health checks
- Cons: Extra hop, ALB cost (~$16/month)

**Option B: Switch to Cloud Map (Service Discovery)**

- Direct task-to-task communication
- Lower latency (no ALB hop)
- Requires updating service URLs to Cloud Map DNS
- Example: `http://auth-api.production.local:3000`

**Option C: ECS Service Connect**

- AWS-managed service mesh
- Automatic DNS, load balancing, observability
- Newer feature, more abstraction

**Recommendation:** Keep Internal ALB for 3-6 months post-migration. It's simpler to operate and debug. Consider Cloud Map later if you need lower latency or want to reduce costs.
