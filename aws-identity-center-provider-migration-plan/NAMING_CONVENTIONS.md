# Terraform Naming Conventions - Quick Reference

This project follows HashiCorp and AWS best practices.

---

## File Naming

✅ **Use:** snake_case

```
main.tf
variables.tf
outputs.tf
backend.tf
versions.tf
data_sources.tf
locals.tf
```

❌ **Avoid:** camelCase, kebab-case for `.tf` files

---

## Resource Names in Code

✅ **Use:** snake_case

```hcl
resource "aws_iam_role" "lambda_execution_role" {
  name = "LambdaExecutionRole"  # AWS resource name (different!)
}

resource "aws_s3_bucket" "terraform_state" {
  bucket = "terraform-state-dev-123456"  # Bucket name (kebab-case)
}

data "aws_caller_identity" "current" {}

locals {
  account_id    = data.aws_caller_identity.current.account_id
  project_name  = "identity-center"
}
```

---

## Variable Names

✅ **Use:** snake_case

```hcl
variable "member_accounts" {
  description = "List of AWS Account IDs"
  type        = set(string)
}

variable "session_duration" {
  description = "Session duration in ISO 8601 format"
  type        = string
  default     = "PT8H"
}

variable "google_group_prefix" {
  description = "Prefix for Google groups"
  type        = string
  default     = "AWS-"
}
```

---

## AWS Resource Names (Actual Resources in AWS)

**Depends on AWS service constraints:**

### S3 Buckets: kebab-case (lowercase, hyphens)

```hcl
resource "aws_s3_bucket" "state" {
  bucket = "terraform-state-dev-471112975126"  # ✅
  # bucket = "terraform_state_dev_471112975126"  # ❌ underscores not allowed
}
```

### IAM Roles: PascalCase or kebab-case

```hcl
resource "aws_iam_role" "lambda_role" {
  name = "LambdaExecutionRole"  # ✅ PascalCase (common for roles)
  # OR
  name = "lambda-execution-role"  # ✅ kebab-case (also acceptable)
}
```

### DynamoDB Tables: kebab-case or PascalCase

```hcl
resource "aws_dynamodb_table" "locks" {
  name = "terraform-state-locks"  # ✅ kebab-case
  # OR
  name = "TerraformStateLocks"    # ✅ PascalCase
}
```

### EC2 Instances / Tags: Any (use tags for naming)

```hcl
resource "aws_instance" "web_server" {
  # ...
  tags = {
    Name = "web-server-prod-01"  # ✅ kebab-case in tags
  }
}
```

---

## Module Names (Directories)

✅ **Use:** kebab-case

```
modules/
├── identity-center/      # ✅
├── vpc-networking/       # ✅
└── lambda-functions/     # ✅
```

---

## Repository Names

✅ **Use:** kebab-case

```
tf-aws-identity           # ✅ Your repo
terraform-aws-modules     # ✅ Official modules
aws-infrastructure        # ✅
```

---

## Backend Config Files

✅ **Use:** kebab-case with `.hcl` extension

```
backend-dev.hcl           # ✅
backend-prod.hcl          # ✅
backend-staging.hcl       # ✅
```

---

## Environment-Specific Files

✅ **Use:** kebab-case with environment suffix

```
terraform-dev.tfvars      # ✅
terraform-prod.tfvars     # ✅
```

---

## Quick Summary Table

| Element            | Convention          | Example                       |
| ------------------ | ------------------- | ----------------------------- |
| Terraform files    | snake_case          | `main.tf`, `variables.tf`     |
| Resource blocks    | snake_case          | `aws_iam_role.lambda_role`    |
| Variable names     | snake_case          | `member_accounts`             |
| Local values       | snake_case          | `local.account_id`            |
| Output names       | snake_case          | `output.instance_arn`         |
| Module calls       | snake_case          | `module.vpc_network`          |
| **AWS Resources:** |                     |                               |
| S3 buckets         | kebab-case          | `terraform-state-dev-123`     |
| IAM roles          | PascalCase or kebab | `LambdaRole` or `lambda-role` |
| DynamoDB tables    | kebab-case          | `terraform-locks`             |
| EC2 tags           | kebab-case          | `web-server-01`               |
| **Directories:**   |                     |                               |
| Module directories | kebab-case          | `identity-center/`            |
| Repo name          | kebab-case          | `tf-aws-identity`             |

---

## Why These Conventions?

1. **Terraform convention:** HCL (HashiCorp Configuration Language) uses snake_case
2. **AWS constraints:** Some services don't allow underscores (S3, Route53)
3. **Readability:** snake_case for code, kebab-case for DNS-like resources
4. **Consistency:** Follow established patterns in Terraform ecosystem

---

## Examples from This Project

✅ **Correct:**

```hcl
# File: identity-center/main.tf

resource "aws_ssoadmin_permission_set" "sets" {  # snake_case resource
  for_each = var.role_definition_mapper     # snake_case variable

  name             = each.value                  # PascalCase AWS resource name
  instance_arn     = local.instance_arn          # snake_case local
  session_duration = var.session_duration        # snake_case variable
}

resource "aws_s3_bucket" "state" {
  bucket = "terraform-state-dev-471112975126"    # kebab-case bucket name
}
```

---

## Tools for Enforcement

```bash
# Format all Terraform files
terraform fmt -recursive

# Validate configuration
terraform validate

# Linting (optional)
tflint
```

---

**Last Updated:** 2026-02-04  
**Your Project:** `tf-aws-identity` follows all these conventions ✅
