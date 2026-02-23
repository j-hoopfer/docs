# Activity 4: Shared Infrastructure Setup (Workload Layer)

**Goal:** Establish the core application runtime services (ALB, ECS Cluster) in the Workload Account (`infra-services`), consuming the network foundation provided by the Platform Layer.

## Context & Themes

Now that the Network Foundation is remediated (private subnets exist), we build the **Shared Services** that multiple applications will use. This avoids creating a dedicated Load Balancer for every single microservice (saving money) and centralizes management.

**Key Themes:**

- **Shared Services:** Providing common ALB and Cluster resources.
- **Workload Layer:** Changes apply to `environments/dev/us-east-1` in `infra-services`.
- **Cost Efficiency:** Shared ALB ($16/mo) vs Per-App ALB ($N \* $16/mo).

### Prerequisites

- [ ] [Activity 2: Remediate Network Gaps](2-remediate-network-gaps.md) is complete (Network is ready).
- [ ] [Activity 3: Import Legacy EC2](3-import-application-resources.md) is complete.

---

## Feature 4: Shared Application Runtime Foundation

**Business Value:** Centralizing the ALB and ECS Cluster saves $200+/month per environment and provides a unified entry point for all future Fargate services.

### Story 4.1: Public HTTPS Traffic is Terminated at the ALB

- **Title:** Request Wildcard SSL Certificate
- **Target Layer:** `environments/dev/us-east-1/01-compute` (Workload Account, Platform Layer)
- **Persona:** As a **DevOps Engineer**, I want HTTPS termination on the ALB.

**Why:** The Public ALB HTTPS listener cannot be created without a valid, `ISSUED` certificate — this must be provisioned and validated before Story 4.2 can be completed.

> **Layer Note:**
> The certificate is an edge/ingress concern, tightly coupled to the public ALB listener. It lives in the same stack as the public ALB (`01-compute`). If the public ALB is ever promoted to its own `01-edge` stack,the certificate moves with it.

#### Prerequisites (Before You Write Any Terraform)

You must satisfy all of the following before this story can complete successfully:

1. You must own the domain.
2. The domain must have a public Route 53 hosted zone.
3. Any cross-account access must be configured.

- **Implementation Details:**
  - **Terraform Resources:** all four resources live in `acm.tf` — `aws_acm_certificate`, `data.aws_route53_zone`, `aws_route53_record`, `aws_acm_certificate_validation`. These form a single logical unit (request cert → prove ownership → wait for issuance) and keeping them together prevents the split-file confusion of tracing a dependency across two files.
  - **`route53.tf`** is reserved exclusively for the private hosted zone (service discovery). It does not contain anything related to ACM validation.
  - **Domain:** Replace `*.example.com` with your real domain.

> **File Attribution Note:** Earlier versions of this guide split the cert workflow across `acm.tf` (cert + waiter) and `route53.tf` (zone lookup + validation records). The current layout consolidates everything into `acm.tf`. See [Appendix: ACM Certificate Setup](appendix/acm-certificate-setup.md) for full rationale.

**Terraform Example:**

```hcl
# File: variables.tf

variable "domain_name" {
  description = "Apex domain name for ACM certificate and Route 53 hosted zone lookup (e.g. example.com). Set per environment in the corresponding .tfvars file."
  type        = string
}
```

```hcl
# File: acm.tf

# ── Certificate ────────────────────────────────────────────────────────────────
resource "aws_acm_certificate" "main" {
  domain_name               = "*.${var.domain_name}" # Covers all subdomains — set via variables.tf
  subject_alternative_names = [var.domain_name]      # Also cover the apex
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true # Required for safe cert rotation later
  }
}

# ── Validation DNS Records ─────────────────────────────────────────────────────
# Look up the public hosted zone so we can write the CNAME records ACM
# requires to prove domain ownership. Uses the dns provider alias because
# the hosted zone lives in the DNS account, not the workload account.
data "aws_route53_zone" "public" {
  provider = aws.dns

  name         = var.domain_name
  private_zone = false
}

resource "aws_route53_record" "cert_validation" {
  provider = aws.dns

  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  allow_overwrite = true # Prevents failure if the record already exists
  zone_id         = data.aws_route53_zone.public.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
}

# ── Validation Waiter ──────────────────────────────────────────────────────────
# Blocks apply until ACM confirms the cert is ISSUED before the HTTPS listener
# is created. Without this, the listener may be created against a PENDING cert.
resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}
```

> **Why `aws_acm_certificate_validation` instead of `aws_acm_certificate`?**
> Always use `aws_acm_certificate_validation.main.certificate_arn` in the listener. Terraform creates the listener immediately, even if the cert is still `PENDING_VALIDATION`. The apply may succeed but the listener will fail silently in AWS. Terraform waits until the cert reaches `ISSUED` before creating the listener. Safer — no partial failures.

- **Acceptance Criteria:**
  - ✅ Public hosted zone exists for the domain in Route 53.
  - ✅ Certificate Status: `ISSUED` (visible in ACM console).
  - ✅ `aws_acm_certificate_validation` completes without timeout.
  - ✅ Attached to Public ALB HTTPS Listener in Story 4.2.

### Story 4.2: All External Traffic Enters Through a Single Load Balancer

- **Title:** Provision Shared Internet-Facing Load Balancer
- **Target Layer:** `environments/dev/us-east-1/01-compute` (Workload Account)
- **Persona:** As a **System Architect**, I want a single Internet-Facing Load Balancer so that I can route traffic to multiple services using a single entry point and SSL certificate.

A shared ALB allows us to route `api.example.com/auth` to one service and `api.example.com/users` to another, all on port 443 with one certificate.

#### Prerequisites (Before You Write Any Terraform)

You must satisfy all of the following before this story can complete successfully:

1. The certificate must reach `ISSUED` before Story 4.2 can be applied.
2. The cert must be in the same region as the ALB

- **Implementation Details:**
  - **Terraform Resource:** `aws_lb` (Application).
  - **Remote State:** Declare `data "terraform_remote_state" "network"` in `data.tf` to consume `00-network` outputs — `terraform validate` will fail without it.
  - **Subnets:** Reference the **Public Subnets** from the Network Layer (via `data.terraform_remote_state`).
  - **Security Group:** Allow 80/443 from `0.0.0.0/0`.
  - **Listeners:**
    - HTTP (80) -> Redirect to HTTPS (301).
    - HTTPS (443) -> Default action: Fixed Response 404 (until apps claim paths).

**Terraform Example:**

```hcl
# File: data.tf
# Required before any resource can reference data.terraform_remote_state.network.outputs.*
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "scale-solutions-terraform-state-dev"
    key    = "platform/dev/us-east-1/00-network/terraform.tfstate"
    region = "us-east-1"
  }
}

```

```hcl
# File: load_balancer_public.tf
resource "aws_security_group" "alb_public" {
  name        = "alb-public-sg"
  description = "Allow 80/443 from anywhere"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

```hcl
# File: load_balancer_public.tf
resource "aws_lb" "public" {
  name               = "edge-public-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = data.terraform_remote_state.network.outputs.public_subnet_ids
  security_groups    = [aws_security_group.alb_public.id]
}
```

```hcl
# File: load_balancer_public.tf
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.public.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
```

```hcl
# File: load_balancer_public.tf
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.public.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06" # Current recommended — supports TLS 1.3
  certificate_arn   = aws_acm_certificate_validation.main.certificate_arn # Waits for ISSUED status
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}
```

- **Acceptance Criteria:**
  - ✅ ALB active and reachable via DNS.
  - ✅ HTTPS Listener returns 404 (default).
  - ✅ HTTP Redirects to HTTPS.

### Story 4.3: Internal Services Can Route Traffic Without Leaving the VPC

- **Title:** Provision Shared Internal Load Balancer
- **Target Layer:** `environments/dev/us-east-1/01-compute` (Workload Account)
- **Persona:** As a **System Architect**, I want an Internal Load Balancer so that services can talk privately (within VPC) and use weighted routing for zero-downtime deployments.

**Why:**

1. **Strangler Fig:** Internal ALB allows weighted traffic shifting between Legacy EC2 and New Fargate.
2. **Security:** Internal traffic never leaves the VPC.

- **Scheme:** `internal` (Critical!).
- **Subnets:** Reference the **Private Subnets** from Network Layer.
- **Security Group:** Allow 80/443 from within the VPC CIDR (sourced from `data.terraform_remote_state.network.outputs.vpc_cidr_block` — avoids hardcoding and automatically stays in sync with the `00-network` layer). See Story 1.1 for the required `vpc_cidr_block` output on the network layer.

**Terraform Example:**

```hcl
# File: load_balancer_internal.tf
# Security group is declared first — ALB depends on it, so dependency order matches read order.
resource "aws_security_group" "alb_internal" {
  name        = "alb-internal-sg"
  description = "Allow 80/443 from VPC"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [data.terraform_remote_state.network.outputs.vpc_cidr_block]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.terraform_remote_state.network.outputs.vpc_cidr_block]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "internal" {
  name               = "shared-internal-alb"
  internal           = true
  load_balancer_type = "application"
  subnets            = data.terraform_remote_state.network.outputs.private_subnet_ids
  security_groups    = [aws_security_group.alb_internal.id]
}

# Default action returns 404. Service stacks attach weighted routing rules here
# to enable Strangler Fig traffic shifting between EC2 and Fargate.
resource "aws_lb_listener" "internal_http" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}
```

- **Acceptance Criteria:**
  - ✅ SG allows VPC traffic only.
  - ✅ HTTP listener active on port 80 with default 404 response.
  - ✅ `aws_lb_listener.internal_http.arn` is resolvable (required by `outputs.tf`).

### Story 4.4: Services Are Reachable by Name, Not by ALB DNS

- **Title:** Configure Internal Private DNS Hosted Zone (Route 53)
- **Target Layer:** `environments/dev/us-east-1/01-compute` (Workload Account)
- **Persona:** As a **Developer**, I want to call `http://auth.internal` instead of a long ALB DNS name.

**Why:** Decouples code from infrastructure. Apps just call `auth.internal`.

- **Terraform Resource:** `aws_route53_zone` (Private).
- **VPC Association:** Associate with the VPC ID.
- **Type:** Private Hosted Zone (e.g., `corp.internal`).

**Terraform Example:**

```hcl
# File: route53.tf
resource "aws_route53_zone" "internal" {
  name = "services.internal"
  vpc {
    vpc_id = data.terraform_remote_state.network.outputs.vpc_id
  }
  comment = "Private hosted zone for service discovery"
}
```

- **Acceptance Criteria:**
  - ✅ Resolution works from inside the VPC (test via EC2).

### Story 4.5: Container Workloads Have a Managed Runtime

- **Title:** Create Shared ECS Cluster
- **Target Layer:** `environments/dev/us-east-1/01-compute` (Workload Account)
- **Persona:** As a **DevOps Engineer**, I want a consolidated ECS Cluster to run all my Fargate tasks.

**Why:** Provides the management plane for containers. One cluster supports unlimited services.

- **Implementation Details:**
  - **Terraform Resources:** `aws_ecs_cluster` + `aws_ecs_cluster_capacity_providers` (separate resource — see note below).
  - **Capacity Providers:** `FARGATE` (reliable baseline) + `FARGATE_SPOT` (cost optimized).
  - **Container Insights:** `enabled` (for CPU/memory/network metrics in CloudWatch).
  - **ECS Exec:** `enabled` via `execute_command_configuration` — allows SSM-based shell access into running containers for debugging without a bastion host.

> **Provider Version Note:** The `capacity_providers` attribute was removed from `aws_ecs_cluster` in recent versions of the AWS provider. Capacity providers must now be managed exclusively via the separate `aws_ecs_cluster_capacity_providers` resource. Mixing both will cause a compilation error.

> **See Also:** [Appendix: ECS Cluster Best Practices](appendix/ecs-terraform-best-practices.md) for a detailed rationale on every setting.

**Terraform Example:**

```hcl
# File: ecs.tf

resource "aws_ecs_cluster" "main" {
  name = "shared-ecs-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  configuration {
    execute_command_configuration {
      logging = "OVERRIDE"

      log_configuration {
        cloud_watch_encryption_enabled = true
        cloud_watch_log_group_name     = aws_cloudwatch_log_group.ecs_exec.name
      }
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = aws_ecs_cluster.main.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 60
    capacity_provider = "FARGATE"
  }

  default_capacity_provider_strategy {
    weight            = 40
    capacity_provider = "FARGATE_SPOT"
  }
}
```

- **Acceptance Criteria:**
  - ✅ Cluster created and active.
  - ✅ Capacity Providers `FARGATE` and `FARGATE_SPOT` configured via `aws_ecs_cluster_capacity_providers`.
  - ✅ Container Insights visible in CloudWatch.
  - ✅ ECS Exec audit logs flowing to `/ecs/exec` log group.

### Story 4.6: Container Logs Are Centralized and Retention-Bounded

- **Title:** Create Centralized Log Groups
- **Target Layer:** `environments/dev/us-east-1/01-compute` (Workload Account)
- **Persona:** As an **Ops Engineer**, I want organized logs (not scattered).

**Why:** Centralized logging is essential for debugging distributed systems. Explicit retention prevents unbounded CloudWatch storage costs (the default is "Never Expire").

- **Implementation Details:**
  - **Terraform Resource:** `aws_cloudwatch_log_group`.
  - **Retention:** Set to 30 days (saves money vs default "Never Expire").
  - **Log Groups:**
    - `/ecs/shared` — application container logs, consumed by task definitions via `awslogs` driver.
    - `/ecs/exec` — ECS Exec audit trail (which user ran which command in which container). Required by the `execute_command_configuration` block in Story 4.5.

**Terraform Example:**

```hcl
# File: cloudwatch.tf

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/shared"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "ecs_exec" {
  name              = "/ecs/exec"
  retention_in_days = 30
}
```

- **Acceptance Criteria:**
  - ✅ `/ecs/shared` log group created with 30-day retention.
  - ✅ `/ecs/exec` log group created with 30-day retention.
  - ✅ Retention policy verified in CloudWatch console.
  - ✅ ECS Exec commands produce entries in `/ecs/exec` (verifiable after first `aws ecs execute-command` invocation).

### Story 4.7: Downstream Stacks Can Consume Shared Resources Without Hardcoding

- **Title:** Publish `01-compute` Remote State Outputs
- **Target Layer:** `environments/dev/us-east-1/01-compute` (Workload Account)
- **Persona:** As a **DevOps Engineer**, I want downstream per-service Terraform stacks to reference shared ALB, ECS, and logging resources without hardcoding ARNs or names.

**Why:** Every per-service Fargate stack needs to attach to the shared ALB, scope its task security group ingress to the ALB SG, register itself with the ECS cluster, and write logs to the shared log group. Without `outputs.tf`, each service stack has no way to read these values from remote state — defeating the entire point of making this infrastructure shared.

The resource groups that must be exported and why:

| Resource     | Outputs Needed                                                                                                  | Consumed By                                                     |
| ------------ | --------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| Public ALB   | `https_listener_arn`, `alb_dns_name`, `alb_zone_id`, `alb_security_group_id`                                    | Service listener rules, Route 53 alias records, task SG ingress |
| Internal ALB | `internal_http_listener_arn`, `internal_alb_dns_name`, `internal_alb_zone_id`, `internal_alb_security_group_id` | Strangler Fig weighted routing, service-to-service calls        |
| ECS Cluster  | `ecs_cluster_arn`, `ecs_cluster_name`                                                                           | `aws_ecs_service` resource in each service stack                |
| CloudWatch   | `ecs_log_group_name`                                                                                            | `awslogs-group` in each task definition's log configuration     |
| Private DNS  | `private_zone_id`                                                                                               | Service stacks that register `*.corp.internal` alias records    |

**Terraform Example:**

```hcl
# File: outputs.tf

# ── Public ALB ─────────────────────────────────────────────────────────────────
output "https_listener_arn" {
  description = "ARN of the public HTTPS listener — service stacks attach listener rules here"
  value       = aws_lb_listener.https.arn
}

output "alb_dns_name" {
  description = "DNS name of the public ALB — used for Route 53 alias records per service"
  value       = aws_lb.public.dns_name
}

output "alb_zone_id" {
  description = "Hosted zone ID of the public ALB — required alongside dns_name for Route 53 alias records"
  value       = aws_lb.public.zone_id
}

output "alb_security_group_id" {
  description = "Security group ID of the public ALB — task SGs must allow inbound from this SG only"
  value       = aws_security_group.alb_public.id
}

# ── Internal ALB ───────────────────────────────────────────────────────────────
output "internal_http_listener_arn" {
  description = "ARN of the internal HTTP listener — used for strangler fig weighted target group rules"
  value       = aws_lb_listener.internal_http.arn
}

output "internal_alb_dns_name" {
  description = "DNS name of the internal ALB — used for service-to-service Route 53 alias records"
  value       = aws_lb.internal.dns_name
}

output "internal_alb_zone_id" {
  description = "Hosted zone ID of the internal ALB — required for Route 53 alias records"
  value       = aws_lb.internal.zone_id
}

output "internal_alb_security_group_id" {
  description = "Security group ID of the internal ALB — task SGs allow inbound from this SG for internal traffic"
  value       = aws_security_group.alb_internal.id
}

# ── ECS Cluster ────────────────────────────────────────────────────────────────
output "ecs_cluster_arn" {
  description = "ARN of the shared ECS cluster — referenced in aws_ecs_service resources"
  value       = aws_ecs_cluster.main.arn
}

output "ecs_cluster_name" {
  description = "Name of the shared ECS cluster — used in CloudWatch dashboards and CLI targeting"
  value       = aws_ecs_cluster.main.name
}

# ── CloudWatch ─────────────────────────────────────────────────────────────────
output "ecs_log_group_name" {
  description = "CloudWatch log group name — set as awslogs-group in each task definition log configuration"
  value       = aws_cloudwatch_log_group.ecs.name
}

# ── Private DNS ────────────────────────────────────────────────────────────────
output "private_zone_id" {
  description = "Route 53 private hosted zone ID — service stacks register corp.internal alias records here"
  value       = aws_route53_zone.internal.zone_id
}
```

- **Acceptance Criteria:**
  - ✅ `terraform output` in `01-compute` returns all values above without errors.
  - ✅ A test `data.terraform_remote_state.compute` block in a scratch module can read `https_listener_arn`, `ecs_cluster_arn`, and `alb_security_group_id`.
  - ✅ No output references a resource that has not yet been applied (all Stories 4.1–4.6 complete first).
