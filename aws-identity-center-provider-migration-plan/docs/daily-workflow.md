# Daily Terraform Workflow Guide

Quick reference for managing AWS Identity Center with Terraform.

---

## Critical Understanding

**AWS Identity Center is a GLOBAL service** - there is only ONE instance per AWS Organization in your Management Account.

- No "Dev Identity Center" or "Prod Identity Center"
- All changes affect production
- Identity Center manages SSO access to ALL accounts (Dev, Prod, etc.)

---

## Project Structure

```
tf-aws-identity/
├── backend.hcl              # Management account backend config
├── common/                  # Shared constants (account IDs, regions, tags)
├── docs/                    # Documentation
├── tools/                   # Helper scripts (SSO export, etc.)
└── identity-center/         # Identity Center Terraform module
```

---

## Daily Workflow

### Deploying Identity Center Changes

```bash
# 1. Navigate to module directory
cd identity-center/

# 2. Set AWS credentials for MANAGEMENT account
export AWS_PROFILE=management  # Or your management account profile name

# 3. CRITICAL: Verify you're in the correct account
aws sts get-caller-identity
# Expected output should show Management Account ID

# 4. Initialize Terraform (first time or after backend changes)
terraform init -backend-config=../backend.hcl

# 5. Plan changes (review CAREFULLY - affects production)
terraform plan

# 6. Save plan for approval (recommended)
terraform plan -out=tfplan

# 7. Apply changes
terraform apply tfplan
```

**Important:** Since Identity Center is global, every `terraform apply` affects production SSO access for ALL AWS accounts.

---

## Pre-Deployment Safety Checklist

Before running `terraform apply` (remember: affects PRODUCTION Identity Center):

- [ ] ✅ Verified AWS credentials point to **Management Account**: `aws sts get-caller-identity`
- [ ] ✅ Ran `terraform plan` and reviewed **ALL** changes carefully
- [ ] ✅ Changes reviewed in GitHub Pull Request with approval
- [ ] ✅ Saved plan output: `terraform plan -out=tfplan`
- [ ] ✅ Team notified (affects everyone's SSO access)
- [ ] ✅ Have rollback plan (state versioning enabled)
- [ ] ✅ Maintenance window communicated if making breaking changes

---

## Common Commands

**Initialize module (first time):**

```bash
terraform init
```

**Validate syntax:**

```bash
terraform validate
```

**Format code:**

```bash
terraform fmt -recursive
```

**View current state:**

```bash
terraform show
```

**List resources:**

```bash
terraform state list
```

**Refresh state (sync with AWS):**

```bash
terraform refresh
```

**Destroy all resources (DANGEROUS):**

```bash
terraform destroy  # Asks for confirmation
```

---

## Working with State

**View specific resource:**

```bash
terraform state show aws_ssoadmin_permission_set.admin
```

**Move resource to different module:**

```bash
terraform state mv aws_iam_role.example module.iam.aws_iam_role.example
```

**Remove resource from state (doesn't delete from AWS):**

```bash
terraform state rm aws_iam_role.old_role
```

**Import existing AWS resource:**

```bash
terraform import aws_iam_role.example arn:aws:iam::123456789012:role/MyRole
```

---

## Troubleshooting

**Error: Backend initialization required**

```bash
# Run init with backend config
terraform init -backend-config=../backend-dev.hcl
```

**Error: Lock timeout**

```bash
# Someone else is running Terraform, or previous run crashed
# Check with team first, then:
terraform force-unlock <LOCK-ID>
```

**Error: Backend configuration changed**

```bash
# Use -reconfigure to switch backends
terraform init -backend-config=../backend-prod.hcl -reconfigure
```

**Error: State file not found**

```bash
# Verify backend bucket exists
aws s3 ls s3://terraform-state-dev-471112975126

# Verify key path in backend HCL file
cat ../backend-dev.hcl
```

**Error: Access denied to S3 bucket**

```bash
# Verify AWS credentials
aws sts get-caller-identity

# Check IAM permissions (see BACKEND_SETUP.md)
```

---

## Environment-Specific Variables (Optional)

If modules need different values per environment:

**Create tfvars files in each module:**

---

## Using Common Configuration

All modules can reference shared values from `common/`:

```hcl
# In locals.tf or permission_sets.tf
module "common" {
  source = "../common"
}

locals {
  dev_account_id  = module.common.accounts["dev"].id
  prod_account_id = module.common.accounts["prod"].id
}

resource "aws_ssoadmin_permission_set" "example" {
  # ...
  tags = module.common.common_tags
}
```

**To update shared values:**

```bash
# Edit common/locals.tf
vim ../common/locals.tf

# Changes propagate on next apply in any module
cd identity-center/
terraform apply  # Will update tags, account IDs, etc.
```

---

## Best Practices

✅ **DO:**

- Always run `terraform plan` before `apply`
- Get PR approval before merging (no "dev environment" to test in)
- Use version control (Git) for all Terraform code
- Document changes thoroughly in commit messages
- Review `terraform plan` output carefully - affects production
- Use incremental rollouts (pilot groups before full deployment)
- Save plan output: `terraform plan -out=tfplan`

❌ **DON'T:**

- Edit state files manually (use `terraform state` commands)
- Share AWS credentials between team members
- Run `terraform destroy` without team approval
- Skip PR reviews (every change affects production SSO)
- Make large changes without rollback plan
- Hardcode sensitive values (use AWS Secrets Manager)

---

## Getting Help

**Terraform docs:**

```bash
terraform -help
terraform plan -help
```

**AWS Provider docs:**

- https://registry.terraform.io/providers/hashicorp/aws/latest/docs

**Team escalation:**

- Slack: #platform-engineering
- On-call: Check PagerDuty
