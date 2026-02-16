# Activity 2: Infrastructure Modules & Automation

**Goal:** Develop Terraform modules (the "Service Factory") to automate the creation of ECS Services, Target Groups, and Listener Rules.

## Context & Themes

Manual resource creation in the AWS Console is prone to drift and error. By codifying the infrastructure patterns established in Phase 3, we can stamp out new service environments in minutes rather than hours. This builds the automation layer on top of the foundation from Phase 3.

**Key Themes:**

- **Configuration Management:** Stamping out identical environments.
- **Drift Detection:** Preventing manual changes.
- **Efficiency:** Reducing time-to-market for new services.

### Prerequisites

- [ ] Platform Repository Setup completed.
- [ ] AWS Credentials configured.
- [ ] Terraform installed.

## Feature 2: Infrastructure as Code for Service Provisioning

**Business Value:** Automates infrastructure setup reducing new service deployment from 2-3 hours (manual console clicking) to 10-15 minutes (code + terraform apply). IaC (4-6 hours initial investment) eliminates configuration drift, enables peer review of infrastructure changes via Git, and provides disaster recovery capability (rebuild entire infrastructure from code). For 10 services, saves 20-25 hours in initial setup and enables adding future services in under 15 minutes. Critical for consistent, auditable, reproducible infrastructure at scale.

> **Note:** This feature automates the AWS infrastructure setup (Target Groups, ECS Services, Listener Rules) that you currently create manually in the console. This is optional but highly recommended once you have 2-3 services and understand the pattern.

### Story 2.1: Implement Reusable Service Module

- **Title:** Implement Service Factory Module
- **Persona:** As a **Platform Engineer**, I want to create a standardized module for all ECS services so that developers can deploy faster and with consistent configuration.

- **Requirements:**
  - Create `modules/ecs-service` within the existing `infra-services` repository
  - Define standard inputs (CPU, Memory, Port, Health Check)
  - Output necessary resources (Target Group ARN)
  - Hide complexity of listeners and security groups

- **Implementation Details:**
  - **Prerequisite:** Ensure you have completed the [Services Repository Setup](../../phase-0-prerequisites/services-repository-setup.md).

  - **Module Structure (`infra-services` repo):**

    You will add the `modules/` directory to your existing repository.

    ```
    infra-services/
    ├── README.md
    ├── modules/
    │   └── ecs-service/           # Reusable service module (NEW)
    │       ├── main.tf
    │       ├── variables.tf
    │       └── outputs.tf
    └── environments/
        └── dev/
            └── us-east-1/
                ├── auth-api/
                │   └── main.tf    # Instantiates service module
                ├── test-api-1/
                │   └── main.tf
                └── test-api-2/
                    └── main.tf
    ```

  - **Service Configuration (infra-services/environments/dev/us-east-1/auth-api/main.tf):**

    **⚠️ Important: Configure State Storage**

    ```hcl
    terraform {
      required_version = ">= 1.0"

      backend "s3" {
        bucket         = "mycompany-terraform-state-dev"
        key            = "infra-services/dev/us-east-1/auth-api/terraform.tfstate"
        region         = "us-east-1"
        encrypt        = true
        dynamodb_table = "terraform-locks-dev"
      }
    # ... providers ...
    }
    ```

    **Note on Shared Infrastructure:**
    The shared components (VPC, ALB, Cluster) are managed in the separate `infra-platform` repository. You will query their details using `terraform_remote_state` or `data` sources.

    ```hcl
    # These outputs are from infra-platform (example via data source)
    # in reality, you might use terraform_remote_state to fetch these

    output "service_url" {
      value = "https://${var.service_name}.example.com"
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

  - **Service Module (infra-services/modules/ecs-service/main.tf):**

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

  - **Using the Module (infra-services/environments/dev/us-east-1/auth-api/main.tf):**

    ```hcl
    terraform {
      backend "s3" {
        bucket = "mycompany-terraform-state-dev"
        key    = "infra-services/dev/us-east-1/auth-api/terraform.tfstate"
        region = "us-east-1"
      }
    }

    # Reference shared infrastructure outputs from infra-platform
    data "terraform_remote_state" "platform" {
      backend = "s3"
      config = {
        bucket = "mycompany-terraform-state-dev"
        key    = "infra-platform/dev/us-east-1/00-network/terraform.tfstate" # Adjust key as needed
        region = "us-east-1"
      }
    }

    module "auth_api" {
      source = "../../../../../modules/ecs-service"

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
      ecr_registry   = data.terraform_remote_state.platform.outputs.ecr_registry
      ecr_repository = "legacy-migration/auth-api"

      # Reference shared infrastructure
      vpc_id                   = data.terraform_remote_state.platform.outputs.vpc_id
      private_subnet_ids       = data.terraform_remote_state.platform.outputs.private_subnet_ids
      alb_listener_arn         = data.terraform_remote_state.platform.outputs.alb_listener_arn
      alb_security_group_id    = data.terraform_remote_state.platform.outputs.alb_security_group_id
      cluster_name             = data.terraform_remote_state.platform.outputs.cluster_name
      cluster_id               = data.terraform_remote_state.platform.outputs.cluster_id
      task_execution_role_arn  = data.terraform_remote_state.platform.outputs.ecs_task_execution_role_arn
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

    The service modules **reference the infra-platform outputs**:
    - `alb_listener_arn` comes from `data.terraform_remote_state.platform.outputs.alb_listener_arn`
    - `cluster_id` comes from `data.terraform_remote_state.platform.outputs.cluster_id`

    This way:
    - Shared resources are defined ONCE
    - All services automatically use the same ALB and cluster
    - If you change ALB or cluster, just update the shared config
    - No duplication, no manual copy-paste

  - **Adding a New Service (2 minutes of work):**
    1. Copy `infra-services/environments/dev/us-east-1/auth-api/main.tf` to `infra-services/environments/dev/us-east-1/new-service/main.tf`
    2. Change 5 values:
       - `service_name = "new-service"`
       - `host_header = "new.mysite.com"`
       - `listener_priority = 110` (unique per service)
       - `ecr_repository = "legacy-migration/new-service"`
       - Any environment variables/secrets
    3. Run:
       ```bash
       cd infra-services/environments/dev/us-east-1/new-service
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
    cd infra-services/environments/dev/us-east-1/auth-api
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
  - **GitHub Actions Workflow (infra-services/.github/workflows/terraform.yml):**

    ```yaml
    name: Terraform Apply

    on:
      push:
        branches:
          - main
        paths:
          - "environments/**"
          - "modules/**"
      pull_request:
        paths:
          - "environments/**"
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
            working-directory: ./infra-services/environments/dev/us-east-1/${{ matrix.service }}
            run: terraform init

          - name: Terraform Plan
            working-directory: ./infra-services/environments/dev/us-east-1/${{ matrix.service }}
            run: terraform plan -out=tfplan

          - name: Terraform Apply
            if: github.ref == 'refs/heads/main'
            working-directory: ./infra-services/environments/dev/us-east-1/${{ matrix.service }}
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
