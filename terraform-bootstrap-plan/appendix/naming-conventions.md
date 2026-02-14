# Appendix: Naming Conventions

Standardized naming patterns for Terraform state infrastructure resources.

## Resource Naming Patterns

| Resource     | Pattern                           | Example                         |
| ------------ | --------------------------------- | ------------------------------- |
| State Bucket | `mycompany-terraform-state-{env}` | `mycompany-terraform-state-dev` |
| Lock Table   | `mycompany-terraform-locks`       | `mycompany-terraform-locks`     |
| IAM Policy   | `terraform-state-access-{env}`    | `terraform-state-access-dev`    |

## Bucket Naming Best Practices

### Global Uniqueness

S3 bucket names must be **globally unique** across all AWS accounts worldwide. If you encounter a `BucketAlreadyExists` error, the name is taken.

**Strategies for uniqueness:**

1. **Company prefix**: `myawesomeco-terraform-state-dev`
2. **Domain-based**: `example-com-terraform-state-dev`
3. **Random suffix**: `mycompany-terraform-state-dev-a7x9m` (if deploying programmatically)

### DNS Compliance

Bucket names must follow DNS naming rules:

- 3-63 characters long
- Lowercase letters, numbers, and hyphens only
- Start and end with letter or number
- No consecutive periods
- Cannot be formatted as an IP address (e.g., `192.168.1.1`)

### Environment Indicators

Include the environment in the bucket name for clarity:

- `mycompany-terraform-state-dev`
- `mycompany-terraform-state-staging`
- `mycompany-terraform-state-prod`

This prevents accidental cross-environment state access.

## DynamoDB Table Naming

Unlike S3 buckets, DynamoDB table names only need to be unique **within an AWS account**.

**Convention:**

- Use the same name across all accounts: `mycompany-terraform-locks`
- Simplifies backend configuration (same table name in all environments)
- Clear purpose identification

**Alternative (if managing multiple state backends):**

- Environment-specific: `mycompany-terraform-locks-dev`, `mycompany-terraform-locks-prod`
- Project-specific: `project-a-terraform-locks`, `project-b-terraform-locks`

## IAM Policy Naming

IAM policies are account-scoped, so include the environment for clarity:

**Pattern:** `terraform-state-access-{env}`

**Examples:**

- `terraform-state-access-dev`
- `terraform-state-access-prod`
- `terraform-state-access-staging`

This makes it easy to identify which policy grants access to which environment's state.
