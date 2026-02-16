# Appendix: Terraform tfvars Best Practices

Guidelines for when to commit `.tfvars` files to Git vs keeping them out of version control.

---

## Quick Decision Guide

| Content in tfvars                  | Commit to Git? | Alternative                     |
| ---------------------------------- | -------------- | ------------------------------- |
| AWS Account IDs                    | ✅ Yes         | N/A - Not sensitive             |
| Environment names (dev, prod)      | ✅ Yes         | N/A - Not sensitive             |
| Region names (us-east-1)           | ✅ Yes         | N/A - Not sensitive             |
| VPC CIDR blocks                    | ✅ Yes         | N/A - Not sensitive             |
| Resource counts (instance count)   | ✅ Yes         | N/A - Configuration, not secret |
| Database passwords                 | ❌ No          | AWS Secrets Manager             |
| API keys                           | ❌ No          | AWS Secrets Manager             |
| Private keys / certificates        | ❌ No          | AWS Certificate Manager         |
| Personally Identifiable Info (PII) | ❌ No          | Never in IaC                    |

---

## Bootstrap Project: Commit tfvars ✅

**For the bootstrap project specifically, always commit `terraform.tfvars`.**

**Contents are not secrets:**

```hcl
# terraform.tfvars - SAFE to commit
aws_account_id = "123456789012"  # Visible in AWS Console
environment    = "dev"           # Just a label
primary_region = "us-east-1"     # Public information
name           = "mycompany"     # Public company name
```

**Why commit:**

- **Team collaboration** - Everyone needs identical values
- **No onboarding friction** - New engineers just clone and run
- **Audit trail** - Changes tracked in Git history
- **No secrets** - All values already visible in AWS Console

**Exceptions:** None for bootstrap. It only creates infrastructure, doesn't contain application secrets.

---

## Application Infrastructure: Usually Exclude tfvars ❌

**For application projects, typically exclude `*.tfvars` and use `.tfvars.example` instead.**

### Example: Application with Secrets

```hcl
# terraform.tfvars - DO NOT COMMIT
database_password = "super-secret-password"  # SECRET
api_key          = "sk-1234567890abcdef"     # SECRET
instance_count   = 3                         # Safe, but mixed with secrets
```

**.gitignore:**

```gitignore
*.tfvars         # Exclude all tfvars
!*.tfvars.example # Allow example files
```

**terraform.tfvars.example (committed):**

```hcl
# Copy to terraform.tfvars and fill in actual values
database_password = "CHANGE_ME"  # Get from AWS Secrets Manager
api_key          = "CHANGE_ME"   # Get from team lead
instance_count   = 3             # Safe default
```

**Engineers must:**

1. Copy example: `cp terraform.tfvars.example terraform.tfvars`
2. Fill in actual values from Secrets Manager
3. Never commit `terraform.tfvars`

---

## Best Practice: Separate Secrets from Configuration

**Instead of mixing secrets in tfvars, use AWS Secrets Manager:**

### ❌ Bad: Secrets in tfvars

```hcl
# terraform.tfvars
db_password = "my-secret-password"  # Committed by accident = security breach
```

```hcl
# main.tf
resource "aws_db_instance" "main" {
  password = var.db_password  # From tfvars
}
```

### ✅ Good: Secrets Manager Reference

```hcl
# terraform.tfvars - SAFE to commit
db_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:prod/db/password"
```

```hcl
# main.tf
data "aws_secretsmanager_secret_version" "db_password" {
  secret_id = var.db_secret_arn
}

resource "aws_db_instance" "main" {
  password = data.aws_secretsmanager_secret_version.db_password.secret_string
}
```

**Benefits:**

- ✅ Secrets never in Git
- ✅ Secrets rotated independently of infrastructure code
- ✅ IAM controls who can access secrets
- ✅ Audit log of secret access

---

## Configuration vs Secrets: Examples

### Safe to Commit (Configuration)

```hcl
# terraform.tfvars - Configuration, not secrets
aws_account_id     = "123456789012"
environment        = "production"
region             = "us-east-1"
vpc_cidr           = "10.0.0.0/16"
instance_type      = "t3.medium"
instance_count     = 5
enable_monitoring  = true
backup_retention   = 30
allowed_cidr_blocks = ["10.0.0.0/8", "172.16.0.0/12"]

tags = {
  Team       = "Platform"
  CostCenter = "Engineering"
  ManagedBy  = "Terraform"
}
```

**Why safe?**

- All values are infrastructure configuration decisions
- Nothing grants unauthorized access
- Already visible to anyone with AWS Console access

### Must Exclude (Secrets)

```hcl
# terraform.tfvars - DO NOT COMMIT
database_master_password   = "MyS3cr3tP@ssw0rd!"      # NEVER COMMIT
rds_admin_password        = "AnotherSecret123"        # NEVER COMMIT
api_key                   = "sk-proj-abc123xyz"       # NEVER COMMIT
ssh_private_key           = "-----BEGIN RSA PRIVATE KEY-----\n..." # NEVER COMMIT
service_account_key_json  = "{\"type\": \"service_account\"...}"  # NEVER COMMIT
encryption_key            = "AQICAHi...base64..."     # NEVER COMMIT
```

---

## Real-World Workflow Patterns

### Pattern 1: Bootstrap Project (This Repo)

```bash
# .gitignore - ALLOW tfvars for bootstrap
# (No *.tfvars exclusion for bootstrap project)

# Repository structure
accounts/dev/terraform.tfvars      # ✅ Committed
accounts/prod/terraform.tfvars     # ✅ Committed
```

**Clone and run:**

```bash
git clone git@github.com:mycompany/infra-terraform-bootstrap.git
cd infra-terraform-bootstrap/accounts/dev
terraform init
terraform apply  # Values already there, no manual setup
```

### Pattern 2: Application Infrastructure

```bash
# .gitignore - EXCLUDE tfvars
*.tfvars
!*.tfvars.example
```

```bash
# Repository structure
terraform.tfvars.example  # ✅ Committed (template)
terraform.tfvars          # ❌ Excluded (actual values)
```

**Clone and setup:**

```bash
git clone git@github.com:mycompany/app-infrastructure.git
cd app-infrastructure

# Copy template
cp terraform.tfvars.example terraform.tfvars

# Get secrets from Secrets Manager
aws secretsmanager get-secret-value \
  --secret-id prod/app/db-password \
  --query SecretString \
  --output text

# Edit terraform.tfvars with actual secret
vim terraform.tfvars  # Add password from Secrets Manager

terraform init
terraform apply
```

### Pattern 3: Hybrid (Some Safe, Some Secret)

**Split files:**

```bash
# terraform.tfvars - Safe config (committed)
instance_count = 3
region        = "us-east-1"

# secrets.tfvars - Secrets only (excluded)
db_password = "secret123"
api_key     = "sk-abc123"
```

**Run Terraform:**

```bash
terraform plan \
  -var-file="terraform.tfvars" \
  -var-file="secrets.tfvars"
```

---

## Team Guidelines

### For Bootstrap Projects

**Always commit `terraform.tfvars`:**

- Contains only account IDs, regions, environment names
- No secrets possible (bootstrap creates empty infrastructure)
- Team needs consistency

### For Application Projects

**Exclude `terraform.tfvars` if ANY of these are true:**

- Contains database passwords
- Contains API keys or tokens
- Contains private keys or certificates
- Contains any credential that grants access
- Contains PII or sensitive customer data

**Commit `terraform.tfvars` if ALL of these are true:**

- Only infrastructure configuration (CIDR blocks, instance counts, etc.)
- No credentials or secrets
- Values already visible in AWS Console
- Team benefits from consistency

### When In Doubt

**If you're not 100% sure, exclude it:**

```gitignore
*.tfvars
!*.tfvars.example
```

**Then provide a template:**

```hcl
# terraform.tfvars.example
# Copy to terraform.tfvars and fill in actual values

# Safe configuration
region         = "us-east-1"
instance_count = 3

# Secrets - get from AWS Secrets Manager
database_password = "REPLACE_ME"  # aws secretsmanager get-secret-value --secret-id prod/db/password
api_key          = "REPLACE_ME"   # Contact platform team
```

---

## Common Mistakes

### ❌ Mistake 1: Committing Secrets Accidentally

```bash
# Someone adds secret to terraform.tfvars
echo 'api_key = "sk-secret123"' >> terraform.tfvars

# Forgets it's committed in this repo
git add terraform.tfvars
git commit -m "Update instance count"
git push

# SECRET IS NOW IN GIT HISTORY FOREVER
```

**Prevention:**

- Use pre-commit hooks to scan for secrets
- Regular `git log` audits for sensitive data
- When in doubt, exclude `*.tfvars`

### ❌ Mistake 2: Hardcoding Secrets in .tf Files

```hcl
# main.tf - WRONG
resource "aws_db_instance" "main" {
  password = "hardcoded-secret"  # Even worse than tfvars!
}
```

**Fix:** Use Secrets Manager (shown above)

### ❌ Mistake 3: Example Files with Real Secrets

```hcl
# terraform.tfvars.example - WRONG
database_password = "MyS3cr3tP@ss!"  # Actual secret in example!
```

```hcl
# terraform.tfvars.example - CORRECT
database_password = "CHANGE_ME"  # Placeholder only
```

---

## Summary

| Project Type                | Commit tfvars? | Reason                                |
| --------------------------- | -------------- | ------------------------------------- |
| **Bootstrap (this repo)**   | ✅ Yes         | No secrets, team needs consistency    |
| **Platform Infrastructure** | ✅ Usually     | If no secrets, commit for consistency |
| **Application with DB**     | ❌ No          | Contains passwords, API keys          |
| **CI/CD pipelines**         | ❌ No          | Contains tokens, credentials          |

**Golden Rule:** If it grants access or could cause a security breach if leaked, keep it out of Git.
