# Appendix: backend.tf Best Practices

## Overview

This document explains the best practice of separating backend configuration into a dedicated `backend.tf` file rather than embedding it in `main.tf`.

## The Pattern

### ✅ Recommended: Separate backend.tf

```
my-terraform-project/
├── backend.tf       # Backend configuration ONLY
├── main.tf          # Resource definitions
├── variables.tf     # Input variables
├── outputs.tf       # Output values
└── terraform.tfvars # Variable values
```

**backend.tf:**

```hcl
terraform {
  # Note: Version constraints can also live in versions.tf
  # required_version = ">= 1.7.0"

  backend "s3" {
    # Network Account State
    bucket         = "mycompany-terraform-state-network"
    key            = "platform/network/us-east-1/00-network/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks-network"
    encrypt        = true
  }
}
```

**main.tf:**

```hcl
# Provider configuration (separate from backend)
provider "aws" {
  region = "us-east-1"
}

# Resource definitions
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  # ...
}
```

### ❌ Not Recommended: Backend in main.tf

```hcl
# main.tf - Everything mixed together
terraform {
  required_version = ">= 1.7.0"

  backend "s3" {
    bucket = "mycompany-terraform-state-dev"
    key    = "..."
    # ...
  }
}

provider "aws" {
  region = "us-east-1"
}

resource "aws_vpc" "main" {
  # ...
}
```

## Why Separate backend.tf?

### 1. **Clarity and Organization**

**Problem:** Mixing backend configuration with resources makes files harder to scan.

**Solution:** Dedicated `backend.tf` makes it immediately clear where the state is stored.

```bash
# Quick check: Where is this project's state stored?
cat backend.tf  # Clear, single-purpose file

# vs.
grep -A 10 'backend "s3"' main.tf  # Have to search through resource definitions
```

### 2. **Reusability and Templates**

**Problem:** When creating new environments/layers, copying `main.tf` brings resource definitions you don't want.

**Solution:** `backend.tf` can be templated and copied independently.

```bash
# Create new layer from template
cp templates/backend.tf.template environments/dev/us-east-1/new-layer/backend.tf
sed -i 's/LAYER_NAME/new-layer/g' environments/dev/us-east-1/new-layer/backend.tf

# main.tf can be created fresh without bringing backend config along
```

### 3. **Backend Migration Simplicity**

**Problem:** Migrating from local to remote state (or changing bucket names) requires editing large files.

**Solution:** Change only `backend.tf`, leave `main.tf` untouched.

```bash
# Migrate from local to remote state
# OLD: Delete backend block from main.tf
# NEW: Just create backend.tf

# Change bucket name
# OLD: Search through main.tf to find backend block
# NEW: Edit only backend.tf
```

### 4. **Code Review Focus**

**Problem:** Backend changes mixed with resource changes in PRs make review harder.

**Solution:** Separate files = clearer diffs.

```diff
# PR adding a new VPC resource
# Files changed:
# - main.tf (new resource - needs review)
# - backend.tf (unchanged - can ignore)

# vs. everything in main.tf:
# - main.tf (backend + resources mixed - harder to review)
```

### 5. **Automation and CI/CD**

**Problem:** Scripts that need to modify backend configuration have to parse resource definitions.

**Solution:** Scripts can operate on `backend.tf` without touching resources.

```bash
# Automated backend reconfiguration
# Example: Change from dev bucket to prod bucket
sed -i 's/terraform-state-dev/terraform-state-prod/g' backend.tf

# If backend is in main.tf, this might accidentally change resource names
```

### 6. **Terraform Best Practices Alignment**

**Official Recommendation:** HashiCorp's [Style Guide](https://www.terraform.io/language/syntax/style) suggests organizing files by purpose:

- `versions.tf` or `terraform.tf` - Terraform and provider versions
- `backend.tf` - Backend configuration (extension of this pattern)
- `main.tf` - Primary resource definitions
- `variables.tf` - Input variable declarations
- `outputs.tf` - Output declarations

Separating backend follows this single-responsibility principle.

## When to Use backend.tf

### ✅ Use Separate backend.tf For:

- **Multi-environment projects** - Dev/staging/prod with different backends
- **Multi-layer architecture** - Network/compute/storage with separate state files
- **Team collaboration** - Makes backend configuration explicit and discoverable
- **Projects with frequent backend changes** - Easier to migrate or reconfigure
- **Any project using remote state** - Clarity outweighs any minor overhead

### ⚠️ Acceptable to Skip For:

- **Bootstrap projects with local state** - If state is local forever, less critical
- **Proof-of-concept experiments** - Throwaway infrastructure
- **Single-file projects** - If entire project is < 50 lines in one file

## Migration Guide

### From main.tf to backend.tf

If you have existing projects with backend in `main.tf`:

1. **Extract the backend block:**

   ```bash
   # Create backend.tf with just the backend configuration
   cat > backend.tf << 'EOF'
   terraform {
     required_version = ">= 1.7.0"

     backend "s3" {
       bucket         = "mycompany-terraform-state-dev"
       key            = "current/path/terraform.tfstate"
       region         = "us-east-1"
       dynamodb_table = "terraform-locks-dev"
       encrypt        = true
     }
   }
   EOF
   ```

2. **Remove backend block from main.tf:**

   Edit `main.tf` and delete the `backend "s3" { ... }` block.

   **Keep** the `terraform { required_version = "..." }` block in `main.tf` if it contains other settings like `required_providers`.

3. **Re-initialize (no state changes):**

   ```bash
   terraform init -reconfigure
   ```

   This tells Terraform to re-read the backend configuration from the new file location. **No state data is moved** - it's just a configuration reorganization.

4. **Verify:**

   ```bash
   terraform plan
   # Should show: No changes. Your infrastructure matches the configuration.
   ```

## Real-World Example: Multi-Layer Platform

```
infra-platform/
├── environments/
│   ├── dev/
│   │   └── us-east-1/
│   │       ├── 00-network/
│   │       │   ├── backend.tf    # Unique state key: 00-network
│   │       │   ├── main.tf       # VPC resources
│   │       │   └── outputs.tf
│   │       ├── 01-compute/
│   │       │   ├── backend.tf    # Unique state key: 01-compute
│   │       │   ├── main.tf       # ECS cluster resources
│   │       │   └── outputs.tf
│   │       └── 02-storage/
│   │           ├── backend.tf    # Unique state key: 02-storage
│   │           ├── main.tf       # ECR, S3 resources
│   │           └── outputs.tf
│   └── prod/
│       └── [same structure]
```

**Each layer's backend.tf:**

```hcl
# environments/dev/us-east-1/00-network/backend.tf
terraform {
  backend "s3" {
    bucket = "mycompany-terraform-state-dev"
    key    = "infra-platform/dev/us-east-1/00-network/terraform.tfstate"
    # ...
  }
}

# environments/dev/us-east-1/01-compute/backend.tf
terraform {
  backend "s3" {
    bucket = "mycompany-terraform-state-dev"
    key    = "infra-platform/dev/us-east-1/01-compute/terraform.tfstate"  # Different key
    # ...
  }
}
```

**Benefits:**

- **Clear state isolation:** Each layer's state location is explicit
- **Easy to clone layers:** Copy directory, update only `backend.tf` key
- **Safe parallel work:** Backend separation makes it obvious layers are independent
- **Audit trail:** Git history shows exactly when/why backend configuration changed

## State Organization Strategies

Beyond the question of _where_ to put your backend configuration (separate file vs. embedded), you must also decide _how many state files_ to use. There are two common approaches:

### Option A: Per-Layer State Files (Granular Isolation)

**Structure:**

```
environments/dev/us-east-1/
├── 00-network/
│   ├── backend.tf    # State: s3://...state-dev/platform/dev/us-east-1/00-network/terraform.tfstate
│   ├── provider.tf
│   ├── versions.tf
│   └── vpc.tf
├── 01-compute/
│   ├── backend.tf    # State: s3://...state-dev/platform/dev/us-east-1/01-compute/terraform.tfstate
│   ├── provider.tf
│   ├── versions.tf
│   └── ecs.tf
├── 02-storage/
│   ├── backend.tf    # State: s3://...state-dev/platform/dev/us-east-1/02-storage/terraform.tfstate
│   └── ...
```

**Characteristics:**

- ✅ **Granular blast radius** - Network changes don't affect compute state
- ✅ **Independent layer modifications** - Teams can work on different layers simultaneously
- ✅ **Better for large teams** - State locking only affects the layer being modified
- ✅ **Safer deploys** - Can't accidentally destroy compute resources when changing network
- ⚠️ **More state files to manage** - Each layer needs its own backend configuration
- ⚠️ **Requires data sources** - Layers must use `terraform_remote_state` to reference outputs from other layers

**Example: Referencing network from compute layer**

```hcl
# 01-compute/main.tf
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "mycompany-terraform-state-dev"
    key    = "platform/dev/us-east-1/00-network/terraform.tfstate"
    region = "us-east-1"
  }
}

resource "aws_ecs_cluster" "main" {
  # Reference network layer outputs
  vpc_id = data.terraform_remote_state.network.outputs.vpc_id
}
```

**Best for:**

- Large organizations with multiple teams
- Critical production infrastructure
- Environments where layers change at different frequencies
- Projects requiring fine-grained access control (different teams own different layers)

---

### Option B: Single State Per Environment (Unified Simplicity)

**Structure:**

```
environments/dev/us-east-1/
├── backend.tf    # Single state: s3://...state-dev/platform/dev/us-east-1/terraform.tfstate
├── provider.tf
├── versions.tf
├── 00-network/
│   └── vpc.tf           # Just resources, no backend
├── 01-compute/
│   └── ecs.tf           # Just resources, no backend
├── 02-storage/
│   └── ecr.tf           # Just resources, no backend
└── outputs.tf
```

**Characteristics:**

- ✅ **Simpler** - One state file per environment, easier to understand
- ✅ **Easier cross-layer references** - No data sources needed, direct resource references
- ✅ **Fewer backend.tf files** - Only one backend configuration per environment
- ✅ **Faster initial setup** - Less configuration overhead
- ⚠️ **Everything locks together** - Can't modify layers independently
- ⚠️ **Larger blast radius** - State corruption or errors affect all layers
- ⚠️ **Team coordination required** - Only one person can run Terraform at a time per environment

**Example: Direct resource references**

```hcl
# 00-network/vpc.tf
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

# 01-compute/ecs.tf (same state file, same terraform run)
resource "aws_ecs_cluster" "main" {
  # Direct reference - no data source needed
  vpc_id = aws_vpc.main.id
}
```

**Best for:**

- Small teams (1-3 engineers)
- Development/sandbox environments
- Organizations just starting with Terraform
- Environments where all infrastructure changes together
- Projects with tight coupling between layers

---

### Decision Matrix

| Factor                    | Per-Layer State             | Single State               |
| ------------------------- | --------------------------- | -------------------------- |
| **Team size**             | > 5 engineers               | < 5 engineers              |
| **Change frequency**      | Layers change independently | All layers change together |
| **Risk tolerance**        | Low (production)            | Higher (dev/test)          |
| **Complexity tolerance**  | Can handle data sources     | Want simplicity            |
| **Parallel work**         | Multiple teams/layers       | One team                   |
| **State lock contention** | Low                         | Can be high                |
| **Setup time**            | Longer (more configs)       | Shorter                    |
| **Blast radius**          | Minimal                     | Larger                     |

### Migration Path

**Start simple, evolve as needed:**

1. **Phase 0-1:** Single state per environment (easier to learn)
2. **Phase 2:** As team grows, split into per-layer states
3. **Phase 3:** Mature - per-layer with remote state data sources

**Migration is straightforward:**

```bash
# Split single state into layers
terraform state mv aws_vpc.main ...  # Move resources to new state files
terraform import ...                  # Rebuild state in new locations
```

### Our Recommendation

**For this migration guide:**

- **Development environment:** Start with single state per environment (Option B)
- **Production environment:** Use per-layer state (Option A) for safety

**Why this hybrid approach?**

- Dev environment benefits from simplicity while learning Terraform
- Production environment benefits from blast radius reduction and team parallelization
- Teams gain experience with simple approach before adopting complex pattern

## Common Questions

### Q: Should required_version go in backend.tf or main.tf?

**A:** Either works, but **main.tf is more common**:

```hcl
# backend.tf - Backend configuration only
terraform {
  backend "s3" {
    bucket = "..."
    key    = "..."
  }
}

# main.tf - Terraform settings and providers
terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}
```

Alternatively, use `versions.tf` for all Terraform-level configuration:

```hcl
# versions.tf
terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# backend.tf
terraform {
  backend "s3" {
    # ...
  }
}
```

### Q: Can I have two terraform {} blocks?

**A:** Yes! Terraform merges all `terraform {}` blocks across all `.tf` files in a directory.

```hcl
# backend.tf
terraform {
  backend "s3" { ... }
}

# main.tf
terraform {
  required_version = ">= 1.7.0"
  required_providers { ... }
}

# These are merged into a single configuration
```

### Q: My organization wants all backend in main.tf. What do I do?

**A:** Follow your organization's standards, but document this decision. Consistency matters more than individual preference.

Consider proposing `backend.tf` as a new standard with evidence:

- Easier code reviews
- Better separation of concerns
- Cleaner diffs
- Aligns with HashiCorp file organization guidance

## Summary

| Aspect            | backend.tf Approach                          | main.tf Approach                   |
| ----------------- | -------------------------------------------- | ---------------------------------- |
| **Clarity**       | ✅ Immediately obvious where state is stored | ❌ Must search through resources   |
| **Reusability**   | ✅ Can template/copy independently           | ❌ Copies bring unwanted resources |
| **Code Review**   | ✅ Backend changes isolated in diffs         | ❌ Mixed with resource changes     |
| **Migration**     | ✅ Edit one file                             | ❌ Navigate through large file     |
| **Best Practice** | ✅ Aligns with HashiCorp style guide         | ⚠️ Functional but less organized   |

**Recommendation:** Use separate `backend.tf` for all projects using remote state. The minimal overhead (one extra file) provides significant long-term benefits in maintainability and clarity.

## References

- [Terraform Backend Configuration](https://www.terraform.io/language/settings/backends/configuration)
- [Terraform Style Guide](https://www.terraform.io/language/syntax/style)
- [S3 Backend Documentation](https://www.terraform.io/language/settings/backends/s3)
