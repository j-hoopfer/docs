# Activity 8: VPC Endpoints

**Goal:** Ensure that ECS Fargate tasks and other workloads communicate with AWS service APIs (Secrets Manager, ECR, CloudWatch Logs, S3) over the private AWS network rather than routing through the public internet via a NAT Gateway.

## Context & Themes

By default, resources in a private subnet reach AWS service APIs via a NAT Gateway — traffic leaves your VPC, traverses the public internet, and returns. VPC Endpoints create a private, high-bandwidth connection directly between your VPC and the AWS service, eliminating the NAT Gateway as a bottleneck and removing the public internet from the data path entirely.

This is a required prerequisite for ECS Fargate deployments that use Secrets Manager, ECR, or CloudWatch Logs — all of which are called at container startup. In high-scale environments, NAT Gateway bandwidth and data processing charges can become significant; Interface Endpoints bypass this completely.

**Key Themes:**

- **Security:** Secrets never traverse the public internet.
- **Cost:** Reduces NAT Gateway data processing charges at scale.
- **Reliability:** Removes a potential point of failure (NAT) from the container startup path.

### Prerequisites

- [ ] [Activity 2: Remediate Network Gaps](2-remediate-infra-gaps.md) complete (private subnets and route tables exist).
- [ ] VPC ID available from Activity 1 outputs.
- [ ] Private subnet IDs available from Activity 2 outputs.

---

## Feature 8: VPC Interface Endpoints

**Business Value:** Removes the public internet from the path between ECS tasks and AWS service APIs. Secrets Manager calls, ECR image pulls, and CloudWatch log writes all happen over the private AWS backbone. Eliminates NAT Gateway as a bottleneck and cost center at scale, and satisfies network security requirements for PCI/SOC 2 (data must not traverse public internet).

> **Why this matters at container startup:** When a Fargate task starts, ECS makes three sequential API calls before your app code runs: pull image from ECR, fetch secrets from Secrets Manager, create log stream in CloudWatch Logs. If these calls route through a NAT Gateway and the NAT is overloaded or unavailable, task startup fails. Interface Endpoints make these calls private and independent of NAT.

---

All three stories deploy resources into `scale.infra-platform` — `environments/dev/us-east-1/00-network/`. The Terraform examples reference values via `local.*`. Add the following `locals` block to `00-network` (e.g. in `vpc_endpoints.tf`) before applying any endpoint resources:

```hcl
# File: vpc_endpoints.tf  (inside environments/dev/us-east-1/00-network/)
# Locals surface the values already in this layer's state so endpoint resources
# don't need a separate variables.tf — the VPC, subnets, and route tables were
# all imported in Activity 1 and exist here already.

locals {
  vpc_id                  = aws_vpc.existing.id
  vpc_cidr                = aws_vpc.existing.cidr_block
  private_subnet_ids      = [aws_subnet.private_1a.id, aws_subnet.private_1b.id]
  private_route_table_ids = [aws_route_table.private.id]
  aws_region              = "us-east-1"
  environment             = "dev"
  tags = {
    ManagedBy   = "terraform"
    Environment = "dev"
  }
}
```

---

### Story 8.1: Secrets Manager VPC Endpoint

- **Title:** Create Interface Endpoint for AWS Secrets Manager
- **Target Repo:** `scale.infra-platform` — `environments/dev/us-east-1/00-network/`
- **Persona:** As a **Platform Engineer**, I want a VPC endpoint for Secrets Manager so that ECS tasks fetch secrets over the private AWS network without routing through a NAT Gateway.

**Business Value:** Required for any deployment that uses Secrets Manager for secret injection. Without this endpoint, every container startup routes a secrets API call through NAT — adding latency, cost, and a public internet dependency to the most critical part of the container lifecycle.

- **Requirements:**
  - Interface endpoint for `com.amazonaws.{region}.secretsmanager`
  - Deployed into private subnets (same subnets as ECS tasks)
  - Security group allows HTTPS (443) inbound from ECS task security groups
  - DNS resolution enabled (so `secretsmanager.{region}.amazonaws.com` resolves to the private endpoint)

- **Terraform:**

  ```hcl
  # Security group for the endpoint itself
  resource "aws_security_group" "vpc_endpoints" {
    name        = "vpc-endpoints-sg"
    description = "Allow HTTPS from private subnets to VPC Interface Endpoints"
    vpc_id      = local.vpc_id

    ingress {
      description = "HTTPS from VPC"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = [local.vpc_cidr]
    }

    egress {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }

    tags = local.tags
  }

  # Secrets Manager endpoint
  resource "aws_vpc_endpoint" "secretsmanager" {
    vpc_id              = local.vpc_id
    service_name        = "com.amazonaws.${local.aws_region}.secretsmanager"
    vpc_endpoint_type   = "Interface"
    subnet_ids          = local.private_subnet_ids
    security_group_ids  = [aws_security_group.vpc_endpoints.id]
    private_dns_enabled = true

    tags = merge(local.tags, {
      Name = "${local.environment}-secretsmanager-endpoint"
    })
  }
  ```

  > **`private_dns_enabled = true` is critical.** This overrides the public DNS for `secretsmanager.{region}.amazonaws.com` to resolve to the private endpoint IP inside your VPC. Without it, the SDK still routes to the public endpoint even though the VPC endpoint exists.

- **Acceptance Criteria:**
  - ✅ Endpoint in `available` state in the AWS console
  - ✅ `private_dns_enabled = true`
  - ✅ Deployed into private subnets used by ECS tasks
  - ✅ Security group allows 443 from VPC CIDR
  - ✅ Validate: from an ECS task or EC2 in a private subnet, `curl https://secretsmanager.{region}.amazonaws.com` resolves to a private IP (`10.x.x.x`)

---

### Story 8.2: ECR VPC Endpoints

- **Title:** Create Interface Endpoints for ECR (API + Docker)
- **Target Repo:** `scale.infra-platform` — `environments/dev/us-east-1/00-network/`
- **Persona:** As a **Platform Engineer**, I want VPC endpoints for ECR so that Fargate image pulls stay on the private AWS network.

**Business Value:** ECR image pulls are the largest data transfer at container startup. Routing through NAT Gateway generates per-GB data processing charges and is bandwidth-constrained. ECR Interface Endpoints eliminate both.

- **Requirements:**
  - Two endpoints required: `ecr.api` (control plane) and `ecr.dkr` (image layer pulls)
  - S3 Gateway Endpoint also required — ECR stores image layers in S3
  - Same security group as other endpoints (HTTPS from VPC CIDR)

- **Terraform:**

  ```hcl
  # ECR API endpoint
  resource "aws_vpc_endpoint" "ecr_api" {
    vpc_id              = local.vpc_id
    service_name        = "com.amazonaws.${local.aws_region}.ecr.api"
    vpc_endpoint_type   = "Interface"
    subnet_ids          = local.private_subnet_ids
    security_group_ids  = [aws_security_group.vpc_endpoints.id]
    private_dns_enabled = true

    tags = merge(local.tags, {
      Name = "${local.environment}-ecr-api-endpoint"
    })
  }

  # ECR Docker endpoint (image layer pulls)
  resource "aws_vpc_endpoint" "ecr_dkr" {
    vpc_id              = local.vpc_id
    service_name        = "com.amazonaws.${local.aws_region}.ecr.dkr"
    vpc_endpoint_type   = "Interface"
    subnet_ids          = local.private_subnet_ids
    security_group_ids  = [aws_security_group.vpc_endpoints.id]
    private_dns_enabled = true

    tags = merge(local.tags, {
      Name = "${local.environment}-ecr-dkr-endpoint"
    })
  }

  # S3 Gateway Endpoint — required for ECR image layer pulls (free)
  resource "aws_vpc_endpoint" "s3" {
    vpc_id            = local.vpc_id
    service_name      = "com.amazonaws.${local.aws_region}.s3"
    vpc_endpoint_type = "Gateway"
    route_table_ids   = local.private_route_table_ids

    tags = merge(local.tags, {
      Name = "${local.environment}-s3-gateway-endpoint"
    })
  }
  ```

  > **S3 Gateway Endpoint is free** and must be added to the private route tables. Without it, ECR image layers (stored in S3) still traverse NAT even when the ECR Interface Endpoints are in place.

- **Acceptance Criteria:**
  - ✅ `ecr.api` and `ecr.dkr` Interface Endpoints in `available` state
  - ✅ S3 Gateway Endpoint added to private route tables
  - ✅ Fargate task can pull an image without NAT Gateway traffic (validate via VPC Flow Logs)

---

### Story 8.3: CloudWatch Logs VPC Endpoint

- **Title:** Create Interface Endpoint for CloudWatch Logs
- **Target Repo:** `scale.infra-platform` — `environments/dev/us-east-1/00-network/`
- **Persona:** As a **Platform Engineer**, I want a VPC endpoint for CloudWatch Logs so that container log writes don't traverse NAT.

- **Terraform:**

  ```hcl
  resource "aws_vpc_endpoint" "cloudwatch_logs" {
    vpc_id              = local.vpc_id
    service_name        = "com.amazonaws.${local.aws_region}.logs"
    vpc_endpoint_type   = "Interface"
    subnet_ids          = local.private_subnet_ids
    security_group_ids  = [aws_security_group.vpc_endpoints.id]
    private_dns_enabled = true

    tags = merge(local.tags, {
      Name = "${local.environment}-cloudwatch-logs-endpoint"
    })
  }
  ```

- **Acceptance Criteria:**
  - ✅ Endpoint in `available` state
  - ✅ Fargate container logs appear in CloudWatch without NAT traffic

---

## Endpoint Summary

| Service          | Endpoint Type | Required For                   | Free?            |
| ---------------- | ------------- | ------------------------------ | ---------------- |
| `secretsmanager` | Interface     | Secret injection at task start | No ($0.01/hr/AZ) |
| `ecr.api`        | Interface     | ECR authentication             | No ($0.01/hr/AZ) |
| `ecr.dkr`        | Interface     | Image layer pulls              | No ($0.01/hr/AZ) |
| `s3`             | Gateway       | ECR layer storage, S3 access   | **Yes**          |
| `logs`           | Interface     | CloudWatch log writes          | No ($0.01/hr/AZ) |

> **Cost note:** Interface Endpoints cost ~$0.01/hr per AZ. For 2 AZs and 4 endpoints that's ~$5.76/month — far less than NAT Gateway data processing at any meaningful traffic volume.
