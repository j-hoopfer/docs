# Infrastructure Tagging Strategy

This document outlines the standard tagging strategy for our infrastructure, ensuring consistency, cost allocation, and resource management across our AWS environment.

## Overview

We use **Terraform Provider Default Tags** to apply a consistent set of tags to all resources within a specific environment and region. This ensures that every resource, regardless of how it's defined, carries the necessary metadata for governance.

## Implementation: Provider-Level Tags

We utilize the `default_tags` block in the AWS provider configuration (`provider.tf`). This is the **recommended approach** for applying global tags.

### Example Configuration

```hcl
# provider.tf

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      # Identity & Governance
      ManagedBy   = "Terraform"
      Environment = "dev"          # e.g., dev, staging, prod
      Owner       = "PlatformTeam" # Team responsible for this stack

      # Cost Allocation
      CostCenter  = "CC-1234"      # Finance code for billing
      Project     = "migration-alpha"
    }
  }
}
```

### Resource-Level Overrides

You can still add resource-specific tags in your `.tf` files. These will be **merged** with the default tags. If a key matches a default tag, the resource-level tag takes precedence.

```hcl
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name        = "main-vpc"       # Specific to this resource
    Description = "Primary network"
  }
}
```

## Standard Tags Reference

| Tag Key | Description | Example Values |
| :--- | :--- | :--- |
| `ManagedBy` | Tool used to deploy the resource | `Terraform`, `Ansible`, `Manual` |
| `Environment` | The deployment environment | `dev`, `qa`, `prod`, `dr` |
| `Owner` | Team or individual responsible | `PlatformEngineering`, `DataTeam` |
| `CostCenter` | Accounting code for chargebacks | `1001-Eng`, `2002-Marketing` |
| `Project` | Specific initiative or application | `legacy-migration`, `api-gateway` |
| `Repository` | Source code repository URL or name | `infra-platform`, `backend-api` |
| `DataClassification` | Sensitivity of data handled | `Public`, `Internal`, `Confidential`, `PII` |

## FAQ: Why `provider` vs. `variables`?

A common question is whether to use `default_tags` or pass a `var.tags` map to every resource.

### 1. The "Old" Way (Variables)
Before Terraform AWS Provider v3.38.0, you had to define a variable and merge it manually on every resource:

```hcl
# variables.tf
variable "common_tags" {
  type = map(string)
  default = { ManagedBy = "Terraform" }
}

# main.tf
resource "aws_vpc" "example" {
  # ...
  tags = merge(var.common_tags, { Name = "example" }) # Easy to forget!
}
```

**Downsides:**
*   **Repetitive:** You must remember to add `merge(var.tags, ...)` to *every single resource*.
*   **Error-Prone:** Missing a resource breaks your cost tracking compliance.
*   **Module Complexity:** You have to pass the `tags` variable into every module you call.

### 2. The "New" Way (Provider Default Tags)
With `default_tags` in the provider block:

*   **Global Application:** Terraform automatically applies these tags to **all** resources created by that provider instance.
*   **Module Inheritance:** Resources created inside child modules *automatically inherit* these tags without you needing to pass a `tags` variable.
*   **Cleaner Code:** Your resource definitions focus only on resource-specific configuration.
*   **Drift Detection:** Terraform ignores changes to these tags if they are modified outside of Terraform (unless they conflict with the provider configuration), simplifying state management.
