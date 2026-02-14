# Quick Reference: Multi-Account Terraform Workflow

## Daily Workflow

### Working in Dev

```bash
# Set credentials
export AWS_PROFILE=dev

# Initialize (first time or after changing backend)
terraform init -backend-config=backend-dev.hcl

# Deploy
terraform plan
terraform apply
```

### Working in Prod

```bash
# Set credentials
export AWS_PROFILE=prod

# Initialize with prod backend
terraform init -backend-config=backend-prod.hcl -reconfigure

# Deploy (always review plan carefully!)
terraform plan
terraform apply
```

## Switching Between Environments

**Important:** You MUST reconfigure the backend when switching:

```bash
# Switch from Dev to Prod
export AWS_PROFILE=prod
terraform init -backend-config=backend-prod.hcl -reconfigure

# Switch from Prod to Dev
export AWS_PROFILE=dev
terraform init -backend-config=backend-dev.hcl -reconfigure
```

The `-reconfigure` flag tells Terraform to forget the old backend and configure a new one.

## Safety Checklist

Before running `terraform apply` in **PROD**:

- [ ] Verified AWS_PROFILE=prod (`aws sts get-caller-identity`)
- [ ] Ran `terraform plan` and reviewed all changes
- [ ] Tested identical changes in Dev first
- [ ] Have rollback plan ready
- [ ] Notified team of deployment window

## File Structure

```
identity-center/
├── backend.tf              # Empty backend block
├── backend.hcl             # Management account config
├── backend-prod.hcl        # Prod account config
├── main.tf                 # Resources (same for all envs)
├── variables.tf            # Variables (same for all envs)
└── terraform.tfvars        # Environment-specific values (optional)
```

## Alternative: Workspaces (Not Recommended for Multi-Account)

Terraform workspaces are **not ideal** for separate AWS accounts because:

- ❌ State still in one bucket (defeats security isolation)
- ❌ Easy to accidentally apply to wrong workspace
- ❌ Doesn't scale well with IAM permissions

Stick with backend config files for multi-account setups.

## Environment-Specific Variables

If you need different variable values per environment:

```hcl
# terraform-dev.tfvars
member_accounts = ["471112975126"]  # Dev account only
environment     = "dev"

# terraform-prod.tfvars
member_accounts = ["637423317953"]  # Prod account only
environment     = "prod"
```

Usage:

```bash
# Dev
terraform apply -var-file=terraform-dev.tfvars

# Prod
terraform apply -var-file=terraform-prod.tfvars
```

## Useful Commands

```bash
# Check which backend you're using
terraform show -json | jq '.values.root_module.resources[0].provider_config'

# List state files in bucket
aws s3 ls s3://terraform-state-dev-471112975126/ --recursive

# Download state for backup/inspection
aws s3 cp s3://terraform-state-dev-471112975126/identity-center/terraform.tfstate ./backup.tfstate

# Check DynamoDB locks
aws dynamodb scan --table-name terraform-state-locks
```
