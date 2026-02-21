# Enterprise Pattern: The "Data Source" Contract

**Category:** Architecture / Governance  
**Goal:** Decouple Platform and Service layers in large-scale or multi-account environments.

In the standard migration plan, we use `terraform_remote_state` to read outputs from the Platform layer. While simple, this creates a tight coupling: the Service layer must know the exact S3 bucket, key, and region of the Platform state file.

For enterprise environments (especially those with 50+ services or multi-account structures), we recommend the **SSM Parameter Store Pattern**.

## The Pattern

Instead of reading state files directly, the Platform layer publishes its "Public API" to AWS SSM Parameter Store. The Service layers strictly read from SSM.

### 1. Platform Layer (Producer)

In `infra-platform/environments/dev/us-east-1/00-network/outputs.tf`, instead of just `output "vpc_id"`, you create SSM resources:

```hcl
resource "aws_ssm_parameter" "vpc_id" {
  name  = "/platform/dev/network/vpc_id"
  type  = "String"
  value = aws_vpc.main.id
}

resource "aws_ssm_parameter" "private_subnets" {
  name  = "/platform/dev/network/private_subnet_ids"
  type  = "StringList"
  value = join(",", aws_subnet.private[*].id)
}
```

### 2. Service Layer (Consumer)

In `infra-services/environments/dev/us-east-1/auth-api/data.tf`, you read from SSM:

```hcl
data "aws_ssm_parameter" "vpc_id" {
  name = "/platform/dev/network/vpc_id"
}

data "aws_ssm_parameter" "private_subnets" {
  name = "/platform/dev/network/private_subnet_ids"
}

# Usage
resource "aws_lb" "main" {
  subnets = split(",", data.aws_ssm_parameter.private_subnets.value)
  vpc_id  = data.aws_ssm_parameter.vpc_id.value
}
```

## Benefits

1.  **Loose Coupling:** You can move, refactor, or split the Platform state files without breaking the Service layer, as long as the SSM parameter names remain constant.
2.  **Cross-Account Access:** Sharing SSM parameters across accounts (e.g., Shared Services -> Dev) is often simpler and more standard than cross-account S3 state access.
3.  **Auditability:** You can see exactly what values are being "exported" by looking at the AWS Console, whereas Terraform State files are opaque blobs.
4.  **Language Agnostic:** If some services are deployed via CDK or Pulumi, they can easily read SSM parameters, whereas reading Terraform State is difficult for non-Terraform tools.

## Implementation Guide

**When to adopt:**

- If you have >3 distinct teams deploying services.
- If you are using a multi-account strategy (e.g., networking in a separate account from applications).

**Migration Path:**

1. Implement the standard `terraform_remote_state` first to get moving.
2. Add `aws_ssm_parameter` resources to the Platform layer.
3. Gradually switch Service layer `data` sources to read from SSM.
