# Epic 3: Compute & Orchestration

**Goal:** Create the runtime environment (ECS Fargate), configure traffic routing (ALB), and deploy the first "Skeleton" service to prove connectivity.

**Duration:** 3–5 days

**Prerequisites:** Epic 2 complete (VPC, RDS, ECR, Secrets, ACM).

---

## Story 3.1: Application Load Balancer (ALB)

As a Network Engineer
I want a public-facing load balancer
So that it can terminate SSL traffic and route requests to my private containers

### Technical Requirements

- Application Load Balancer (Internet-facing) in public subnets
- HTTP (80) listener redirects to HTTPS (443)
- HTTPS (443) listener terminates SSL with ACM certificate
- TLS policy: ELBSecurityPolicy-TLS13-1-2-2021-06 (modern)
- Default action: Fixed response 404 (no apps attached yet)
- Security group: sg_alb from Epic 2
- Deletion protection enabled for production

### Implementation Details

**Type:** Application Load Balancer (Internet-facing)

**Listeners:**

- Port 80: Redirect to 443 (HTTP → HTTPS)
- Port 443: Terminate SSL using ACM certificate from Epic 2. Default action: Return 404 (Fixed Response)

**Security Group:** Use `sg_alb` (created in Epic 2)

**Subnets:** Use `public_subnet_ids` (created in Epic 2)

### Terraform Module

Create `terraform/modules/compute/alb.tf`:

```hcl
variable "project" { type = string }
variable "environment" { type = string }
variable "alb_security_group_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "vpc_id" { type = string }
variable "acm_certificate_arn" { type = string }

resource "aws_lb" "main" {
  name               = "${var.project}-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids

  # Enable deletion protection in production
  enable_deletion_protection = var.environment == "prod" ? true : false

  # Enable access logs (optional but recommended for audit)
  # access_logs {
  #   bucket  = aws_s3_bucket.alb_logs.id
  #   enabled = true
  # }

  tags = {
    Name        = "${var.project}-${var.environment}-alb"
    Environment = var.environment
  }
}

# HTTP Redirect Listener (80 → 443)
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# HTTPS Listener
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"  # Modern TLS policy
  certificate_arn   = var.acm_certificate_arn

  # Default: Return 404 (prevents traffic to unknown routes)
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "404: Not Found"
      status_code  = "404"
    }
  }
}

output "alb_arn" { value = aws_lb.main.arn }
output "alb_listener_arn" { value = aws_lb_listener.https.arn }
output "alb_dns_name" { value = aws_lb.main.dns_name }
output "alb_zone_id" { value = aws_lb.main.zone_id }
```

### Acceptance Criteria

- [ ] ALB provisioned in public subnets.
- [ ] HTTP (80) redirects to HTTPS (443).
- [ ] HTTPS (443) uses valid ACM certificate with modern TLS policy.
- [ ] Visiting ALB DNS name returns "404: Not Found" (no apps attached yet).

---

## Story 3.2: ECS Cluster & IAM Roles

As a DevOps Engineer
I want an ECS cluster and standard IAM roles
So that Fargate has permission to pull images (ECR) and write logs (CloudWatch)

### Technical Requirements

- ECS Fargate cluster with Container Insights enabled
- Task Execution Role: ECR pull, CloudWatch logs, Secrets Manager/SSM read
- Task Role: Application-level AWS service access, ECS Exec permissions
- CloudWatch log group with retention (7 days dev, 30 days prod)
- IAM policies scoped to project/environment paths
- KMS decrypt permissions for encrypted secrets

### Implementation Details

**Cluster:** Enable Container Insights for monitoring.

**IAM Roles:**

- Task Execution Role: Used by the ECS agent (pull images, write logs, read secrets)
- Task Role: Used by the app (access AWS services like S3, DynamoDB)

### Terraform Module

Create `terraform/modules/compute/ecs.tf`:

```hcl
variable "project" { type = string }
variable "environment" { type = string }
variable "region" { type = string }

# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "${var.project}-${var.environment}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name        = "${var.project}-${var.environment}-cluster"
    Environment = var.environment
  }
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.project}-${var.environment}"
  retention_in_days = var.environment == "prod" ? 30 : 7

  tags = { Environment = var.environment }
}

# Task Execution Role (The "Agent" Role)
resource "aws_iam_role" "execution_role" {
  name = "${var.project}-${var.environment}-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = { Environment = var.environment }
}

# Attach AWS Managed Policy: Pull images & Write logs
resource "aws_iam_role_policy_attachment" "execution_role_policy" {
  role       = aws_iam_role.execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Custom Policy: Read Secrets (SSM + Secrets Manager)
resource "aws_iam_role_policy" "secrets_access" {
  name = "secrets-access"
  role = aws_iam_role.execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameters",
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          "arn:aws:ssm:${var.region}:*:parameter/${var.project}/${var.environment}/*",
          "arn:aws:secretsmanager:${var.region}:*:secret:/${var.project}/${var.environment}/*",
          "arn:aws:secretsmanager:${var.region}:*:secret:rds*"  # RDS auto-managed secrets
        ]
      },
      {
        Effect = "Allow"
        Action = ["kms:Decrypt"]
        Resource = ["*"]  # TODO: Scope to specific KMS key ARN in production
      }
    ]
  })
}

# Task Role (App-level permissions)
resource "aws_iam_role" "task_role" {
  name = "${var.project}-${var.environment}-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = { Environment = var.environment }
}

# Enable ECS Exec for debugging (optional but valuable)
resource "aws_iam_role_policy" "ecs_exec" {
  name = "ecs-exec"
  role = aws_iam_role.task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ]
      Resource = "*"
    }]
  })
}

output "ecs_cluster_id" { value = aws_ecs_cluster.main.id }
output "ecs_cluster_name" { value = aws_ecs_cluster.main.name }
output "execution_role_arn" { value = aws_iam_role.execution_role.arn }
output "task_role_arn" { value = aws_iam_role.task_role.arn }
output "log_group_name" { value = aws_cloudwatch_log_group.ecs.name }
```

### Acceptance Criteria

- [ ] ECS cluster created with Container Insights enabled.
- [ ] Execution role created with permissions to pull from ECR and read specific secrets.
- [ ] Task role created with ECS Exec permissions for debugging.
- [ ] CloudWatch log group created with appropriate retention.

---

## Story 3.3: Service Discovery (Cloud Map)

As a Developer
I want internal DNS names for my services (e.g., `auth.internal`)
So that microservices can talk to each other without using load balancers (saving cost and latency)

### Technical Requirements

- AWS Cloud Map private DNS namespace
- Namespace format: `{project}.internal` (e.g., `myapp.internal`)
- VPC association from Epic 2
- Enables service-to-service communication without ALB
- Foundation for future microservices architecture

### Implementation Details

**Namespace:** Private DNS namespace (e.g., `myapp.internal`)

**VPC:** Associated with the VPC from Epic 2

### Terraform Module

Create `terraform/modules/compute/discovery.tf`:

```hcl
variable "project" { type = string }
variable "vpc_id" { type = string }

resource "aws_service_discovery_private_dns_namespace" "internal" {
  name        = "${var.project}.internal"
  description = "Internal service discovery namespace"
  vpc         = var.vpc_id

  tags = { Name = "${var.project}.internal" }
}

output "service_discovery_namespace_id" {
  value = aws_service_discovery_private_dns_namespace.internal.id
}

output "service_discovery_namespace_name" {
  value = aws_service_discovery_private_dns_namespace.internal.name
}
```

### Acceptance Criteria

- [ ] Private DNS namespace created (e.g., `myapp.internal`).
- [ ] Namespace attached to VPC.

---

## Story 3.4: "Skeleton" Service & Secrets Injection

As a DevOps Engineer
I want to deploy a basic Task Definition that connects to the DB
So that I can verify the App → Secret → DB connection path works

### Technical Requirements

- Target group with /health endpoint checks (30s interval, 5s timeout)
- Task definition: 256 CPU, 512 MB memory (Fargate)
- Secrets injection: DB_PASSWORD from Secrets Manager (not in plaintext)
- Environment variables: DB_HOST, DB_USER, DB_NAME, DB_PORT, NODE_ENV
- Container health check using Node.js built-in http module
- ECS service with desired count 1, circuit breaker enabled
- ALB listener rule routing `api.{domain}` to target group
- Route53 A record (alias) pointing to ALB
- CloudWatch logs with awslogs driver

### Implementation Details

**Target Group:** Bridge between ALB and ECS

**Task Definition:**

- Secrets: Inject `DB_PASSWORD` from Secrets Manager (Epic 2 output)
- Env Vars: Inject `DB_HOST` from RDS endpoint (Epic 2 output)

**Service:** Launches task in `private_app_subnets`

**DNS:** Create Route53 record pointing `api.myapp.com` to ALB

### Terraform Module

Create `terraform/modules/compute/service-skeleton.tf`:

```hcl
variable "project" { type = string }
variable "environment" { type = string }
variable "region" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "app_security_group_id" { type = string }
variable "alb_listener_arn" { type = string }
variable "execution_role_arn" { type = string }
variable "task_role_arn" { type = string }
variable "log_group_name" { type = string }
variable "ecs_cluster_id" { type = string }
variable "ecr_repo_url" { type = string }
variable "db_address" { type = string }
variable "db_name" { type = string }
variable "db_secret_arn" { type = string }
variable "domain_name" { type = string }

# 1. Target Group
resource "aws_lb_target_group" "app" {
  name        = "${var.project}-${var.environment}-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  deregistration_delay = 30

  tags = {
    Name        = "${var.project}-${var.environment}-tg"
    Environment = var.environment
  }
}

# 2. ALB Listener Rule (Route traffic to this TG)
resource "aws_lb_listener_rule" "app" {
  listener_arn = var.alb_listener_arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  condition {
    host_header {
      values = ["api.${var.domain_name}"]
    }
  }
}

# 3. Task Definition (With Secrets!)
resource "aws_ecs_task_definition" "app" {
  family                   = "${var.project}-${var.environment}-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([{
    name  = "app"
    image = "${var.ecr_repo_url}:latest"  # Placeholder until CI/CD pushes real image

    portMappings = [{
      containerPort = 3000
      protocol      = "tcp"
    }]

    # Environment Variables (Plain text)
    environment = [
      { name = "NODE_ENV", value = "production" },
      { name = "PORT", value = "3000" },
      { name = "DB_HOST", value = var.db_address },
      { name = "DB_USER", value = "dbadmin" },
      { name = "DB_NAME", value = var.db_name },
      { name = "DB_PORT", value = "3306" }
    ]

    # Secrets (Injected from Secrets Manager - never in plaintext)
    secrets = [
      {
        name      = "DB_PASSWORD"
        valueFrom = "${var.db_secret_arn}:password::"  # JSON key path
      }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = var.log_group_name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "app"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "node -e \"require('http').get('http://localhost:3000/health', (r) => process.exit(r.statusCode === 200 ? 0 : 1))\""]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }
  }])

  tags = {
    Name        = "${var.project}-${var.environment}-task"
    Environment = var.environment
  }
}

# 4. ECS Service
resource "aws_ecs_service" "app" {
  name            = "${var.project}-${var.environment}-service"
  cluster         = var.ecs_cluster_id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  # Enable ECS Exec for debugging
  enable_execute_command = true

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.app_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = 3000
  }

  # Deployment configuration
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  # Wait for steady state before marking complete
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  tags = {
    Name        = "${var.project}-${var.environment}-service"
    Environment = var.environment
  }

  # Ignore changes to desired_count (allows auto-scaling later)
  lifecycle {
    ignore_changes = [desired_count]
  }
}

output "service_name" { value = aws_ecs_service.app.name }
output "target_group_arn" { value = aws_lb_target_group.app.arn }
```

### DNS Configuration

Create `terraform/modules/compute/dns.tf`:

```hcl
variable "zone_id" { type = string }
variable "domain_name" { type = string }
variable "alb_dns_name" { type = string }
variable "alb_zone_id" { type = string }

# DNS Record: api.myapp.com → ALB
resource "aws_route53_record" "api" {
  zone_id = var.zone_id
  name    = "api.${var.domain_name}"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

output "api_fqdn" { value = aws_route53_record.api.fqdn }
```

### Acceptance Criteria

- [ ] Task Definition contains a `secrets` block referencing the DB secret ARN.
- [ ] ECS service launches 1 task.
- [ ] Task status reaches `RUNNING` (doesn't crash on startup).
- [ ] Route53 record `api.myapp.com` points to ALB.
- [ ] Verification steps:
  - Push a placeholder image to ECR (if not done):

    ```bash
    # Build and tag (from monorepo root)
    docker build -t my-app:latest .

    # Authenticate to ECR
    aws ecr get-login-password --region us-east-1 | \
      docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-east-1.amazonaws.com

    # Tag and push
    docker tag my-app:latest <ecr-url>:latest
    docker push <ecr-url>:latest
    ```

  - Run `terraform apply`
  - Check ECS Console → Tasks → Logs
  - Verify app logs show DB connection details (or at minimum, env vars are present)
  - Test health endpoint:
    ```bash
    curl https://api.myapp.com/health
    ```

---

## Terraform Directory Structure (Updated)

```text
infrastructure-core/
├── terraform/
│   ├── bootstrap/
│   ├── modules/
│   │   ├── networking/
│   │   ├── database/
│   │   ├── ecr/
│   │   ├── secrets/
│   │   ├── acm/
│   │   └── compute/              # NEW
│   │       ├── alb.tf
│   │       ├── ecs.tf
│   │       ├── discovery.tf
│   │       ├── service-skeleton.tf
│   │       ├── dns.tf
│   │       └── outputs.tf
│   └── environments/
│       └── dev/
│           └── main.tf           # Updated to include compute module
```

### Example `environments/dev/main.tf` (Updated)

```hcl
terraform {
  required_version = ">= 1.7.0"
}

provider "aws" {
  region = "us-east-1"
}

variable "project" { default = "myapp" }
variable "environment" { default = "dev" }
variable "domain_name" { default = "myapp.com" }
variable "zone_id" { default = "Z1234567890ABC" }  # Route53 Hosted Zone ID

# Epic 2 modules
module "networking" {
  source      = "../../modules/networking"
  project     = var.project
  environment = var.environment
  vpc_cidr    = "10.0.0.0/20"
  azs         = ["us-east-1a", "us-east-1b"]
}

module "database" {
  source                = "../../modules/database"
  project               = var.project
  environment           = var.environment
  vpc_id                = module.networking.vpc_id
  db_subnet_ids         = module.networking.private_db_subnet_ids
  db_security_group_id  = module.networking.sg_db_id
  instance_class        = "db.t4g.micro"
}

module "ecr" {
  source           = "../../modules/ecr"
  project          = var.project
  environment      = var.environment
  repository_names = ["auth-api"]
}

module "secrets" {
  source      = "../../modules/secrets"
  project     = var.project
  environment = var.environment
}

module "acm" {
  source      = "../../modules/acm"
  domain_name = var.domain_name
  zone_id     = var.zone_id
}

# Epic 3 module (NEW)
module "compute" {
  source = "../../modules/compute"

  project     = var.project
  environment = var.environment
  region      = "us-east-1"
  domain_name = var.domain_name
  zone_id     = var.zone_id

  # Networking inputs
  vpc_id                = module.networking.vpc_id
  public_subnet_ids     = module.networking.public_subnet_ids
  private_subnet_ids    = module.networking.private_app_subnet_ids
  alb_security_group_id = module.networking.sg_alb_id
  app_security_group_id = module.networking.sg_app_id

  # Database inputs
  db_address    = module.database.db_instance_address
  db_name       = module.database.db_name
  db_secret_arn = module.database.db_secret_arn

  # ACM input
  acm_certificate_arn = module.acm.certificate_arn

  # ECR input
  ecr_repo_url = module.ecr.repository_urls["auth-api"]
}

# Outputs
output "alb_dns_name" { value = module.compute.alb_dns_name }
output "api_url" { value = "https://api.${var.domain_name}" }
output "ecs_cluster_name" { value = module.compute.ecs_cluster_name }
```

---

## ✅ Epic 3 Definition of Done

1. **Cluster:** ECS cluster active with Container Insights enabled.
2. **Routing:** ALB listening on HTTPS; DNS `api.myapp.com` points to ALB via Route53.
3. **Security:** Task execution role has permissions to decrypt the specific DB secret.
4. **Injection:** `DB_PASSWORD` is injected into the container as an environment variable from Secrets Manager (not baked into image or visible in Task Definition console).
5. **Health:** Task reaches `RUNNING` state; health check passes at `/health`.
6. **Logs:** CloudWatch logs show container output; no startup errors.
7. **Debugging:** ECS Exec enabled for troubleshooting running tasks.
