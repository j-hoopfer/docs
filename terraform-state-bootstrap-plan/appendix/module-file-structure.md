# Appendix: Module File Structure

Best practices for organizing Terraform module files for maintainability and clarity.

## When to Split `main.tf`

As a Terraform module grows, splitting a single large `main.tf` file into smaller, resource-specific files improves readability and maintainability.

**General guideline:**

- **< 200 lines**: Keep everything in `main.tf`
- **200-500 lines**: Consider splitting by resource type
- **> 500 lines**: Definitely split into multiple files

## Benefits of File Organization

### 1. Easier Navigation

```
# Before: Everything in main.tf (150 lines)
modules/terraform-state-backend/
├── main.tf           # All resources mixed together
├── variables.tf
└── outputs.tf

# After: Split by resource type
modules/terraform-state-backend/
├── s3.tf             # S3 bucket and related resources
├── dynamodb.tf       # DynamoDB table
├── iam.tf            # IAM policy
├── variables.tf
└── outputs.tf
```

**Result:**

- Team members can quickly find relevant code
- `git blame` shows clearer history per resource type
- Merge conflicts less likely (different team members work on different files)

### 2. Clear Resource Grouping

Group related resources together:

**Example: `s3.tf`**

```hcl
# S3 Bucket for Terraform State
resource "aws_s3_bucket" "terraform_state" {
  # ...
}

# Enable Versioning
resource "aws_s3_bucket_versioning" "terraform_state" {
  # ...
}

# Enable Encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  # ...
}

# Block Public Access
resource "aws_s3_bucket_public_access_block" "terraform_state" {
  # ...
}

# Lifecycle Policy
resource "aws_s3_bucket_lifecycle_configuration" "terraform_state" {
  # ...
}
```

All S3-related configuration in one place makes it easy to understand the complete bucket setup.

### 3. Reduced Cognitive Load

When reviewing code, you only need to understand one type of resource at a time:

```
# Reviewing IAM changes? Open iam.tf
# Checking S3 configuration? Open s3.tf
# Understanding state locking? Open dynamodb.tf
```

No need to scroll through unrelated resources.

## Recommended File Structure

### Small Modules (< 5 resources)

```
module-name/
├── main.tf        # All resources
├── variables.tf   # Input variables
├── outputs.tf     # Output values
└── README.md      # Usage documentation
```

**When to use:**

- Simple, focused modules
- Few resource types
- Limited configuration options

### Medium Modules (5-15 resources)

```
module-name/
├── main.tf        # Primary resource(s)
├── security.tf    # Security groups, IAM policies
├── networking.tf  # VPC, subnets, route tables (if applicable)
├── variables.tf
├── outputs.tf
└── README.md
```

**When to use:**

- Multiple related resource types
- Clear logical groupings exist
- Some complexity, but not overwhelming

### Large Modules (> 15 resources)

```
module-name/
├── compute.tf     # EC2 instances, Auto Scaling Groups
├── networking.tf  # VPC, subnets, NAT gateways
├── security.tf    # Security groups, NACLs
├── iam.tf         # IAM roles, policies, instance profiles
├── monitoring.tf  # CloudWatch alarms, dashboards
├── storage.tf     # EBS volumes, S3 buckets
├── variables.tf
├── outputs.tf
├── locals.tf      # Local values (if complex)
└── README.md
```

**When to use:**

- Complex infrastructure
- Multiple AWS services
- Many configuration options
- Team collaboration on module

## File Naming Conventions

### By Resource Type

Most common and recommended:

```
s3.tf          # S3 buckets and bucket configurations
dynamodb.tf    # DynamoDB tables
iam.tf         # IAM policies, roles
ec2.tf         # EC2 instances
vpc.tf         # VPC and networking
rds.tf         # RDS databases
```

### By Function

Alternative for infrastructure layers:

```
storage.tf     # All storage resources (S3, EBS, EFS)
compute.tf     # All compute resources (EC2, Lambda, ECS)
data.tf        # All data sources
security.tf    # All security-related resources
```

### By Lifecycle

For complex deployments:

```
core.tf        # Resources that rarely change
variables.tf   # Dynamic resources
```

## Bootstrap Module Example

For the `terraform-state-backend` module specifically:

### Before (Single File)

```
modules/terraform-state-backend/
├── main.tf (120 lines)
│   ├── S3 bucket
│   ├── S3 versioning
│   ├── S3 encryption
│   ├── S3 public access block
│   ├── S3 lifecycle policy
│   ├── DynamoDB table
│   └── IAM policy
├── variables.tf
└── outputs.tf
```

### After (Split by Resource)

```
modules/terraform-state-backend/
├── s3.tf (60 lines)
│   ├── S3 bucket
│   ├── S3 versioning
│   ├── S3 encryption
│   ├── S3 public access block
│   └── S3 lifecycle policy
├── dynamodb.tf (20 lines)
│   └── DynamoDB table
├── iam.tf (40 lines)
│   └── IAM policy
├── variables.tf
└── outputs.tf
```

**Benefits for this module:**

- Easier to review S3 security configuration (all in `s3.tf`)
- Simpler to add S3 features (bucket policies, replication)
- Clear separation between state storage (S3) and locking (DynamoDB)
- IAM policy changes don't require scrolling past S3 config

## When NOT to Split

**Don't over-split small modules:**

```
# ❌ Too granular for a 3-resource module
s3-bucket.tf
s3-versioning.tf
s3-encryption.tf
```

**Instead:**

```
# ✅ Keep related configs together
s3.tf  # Contains bucket, versioning, encryption
```

## Standard Files (Always Separate)

These should **always** be separate files, regardless of module size:

```
variables.tf   # Input variables
outputs.tf     # Output values
versions.tf    # Terraform and provider version constraints (optional)
README.md      # Module documentation
```

**Why:**

- **`variables.tf`**: Auto-generated documentation tools expect this
- **`outputs.tf`**: Clear interface definition
- **`versions.tf`**: Dependency management
- **`README.md`**: Essential for module reuse

## File Order Convention

Terraform loads files in alphabetical order. Use this to your advantage:

```
00-versions.tf    # Terraform and provider versions (loaded first)
data.tf           # Data sources
locals.tf         # Local values
main.tf           # Primary resources
[resource].tf     # Additional resource files
outputs.tf        # Outputs (loaded last, after all resources)
variables.tf      # Variables
```

**Note:** File order doesn't affect dependency resolution (Terraform handles that), but it helps humans reading the code.

## Summary

**Split `main.tf` when:**

- File exceeds 200 lines
- Multiple resource types exist
- Team collaboration requires clear ownership
- Code reviews are becoming difficult

**Organize by:**

- Resource type (most common): `s3.tf`, `dynamodb.tf`, `iam.tf`
- Functional area: `storage.tf`, `networking.tf`, `security.tf`
- Lifecycle: `core.tf`, `dynamic.tf`

**Always separate:**

- `variables.tf`
- `outputs.tf`
- `README.md`
- `versions.tf` (if version constraints exist)

**Keep together:**

- Tightly coupled resources (e.g., S3 bucket + bucket policy)
- Small modules (< 5 resources)
