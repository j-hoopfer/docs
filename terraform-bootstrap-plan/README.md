# Terraform Bootstrap Plan

**Purpose:** Initialize Terraform state management infrastructure across AWS accounts and regions for mycompany's cloud infrastructure.

**Repository:** `scale.infra-terraform-bootstrap` (replace `scale` with your company name)

**Scope:** One-time setup per AWS account to create S3 state buckets, DynamoDB lock tables, and IAM policies required for safe Terraform operations.

**Target Audience:** Junior engineers, contingent workers, and AI agents - includes detailed step-by-step instructions with personas, acceptance criteria, and validation steps.

**Estimated Time:** 2.5-5 hours total (all accounts, core phases)

- Phase 0: Prerequisites (30-60 minutes)
- Phase 1: Repository Setup (30-45 minutes)
- Phase 2: Create Terraform Module (30-45 minutes)
- Phase 3: Bootstrap Dev Account (30-60 minutes)
- Phase 4: Continuous Integration (30-45 minutes) - Validation workflows
- Phase 5: Bootstrap Prod Account (30-60 minutes)
- Phase 6: Migrate to Remote State - **Optional** (15-30 minutes per account)
- Phase 7: Continuous Deployment - **Optional** (60-90 minutes) - Automated deployment
- Phase 8: What's Next After Bootstrap (guidance)

---

## Overview

This bootstrap project solves the "chicken and egg" problem in Terraform state management:

**The Problem:**

- Terraform best practice is to store state in S3 (remote backend) for collaboration and safety
- But S3 buckets are created using Terraform
- If you configure Terraform to use an S3 backend that doesn't exist yet, `terraform init` will fail
- You can't create the S3 bucket with Terraform until you can run `terraform init`

**The Solution:**
This bootstrap project breaks the cycle by running **once** with **local state** (state stored as a file on your computer, not in S3). Here's how:

1. **Bootstrap runs with local state** - No backend configuration, so Terraform stores state in `terraform.tfstate` locally
2. **Bootstrap creates S3 bucket and DynamoDB table** - The infrastructure for remote state now exists
3. **All future projects use remote state** - Point their backend configs to the newly created S3 bucket
4. **Bootstrap itself can migrate to remote state** (optional) - After the bucket is proven working, the bootstrap project can migrate its own state to S3

**Why This Works:**

- Local state has no prerequisites - it just writes a file to disk
- You only need local state once per account to create the remote state infrastructure
- Once the S3 bucket exists, all other Terraform projects (including bootstrap itself) can use remote state
- This is a one-time operation - you never need to do this again for that AWS account

**Note:** Migrating the bootstrap project itself to remote state (Phase 6) is **optional**. See [Local vs Remote State](appendix/local-vs-remote-state.md) for guidance on understanding what state migration actually means and whether you should do it.

---

## What This Creates

Per AWS Account (in primary region):

- **S3 State Bucket** - Encrypted, versioned storage for `.tfstate` files
- **DynamoDB Lock Table** - Prevents concurrent Terraform runs from corrupting state
- **IAM Policies** - Least-privilege access to state resources
- **Bucket Policies** - Enforce encryption, block public access

---

## Multi-Region Strategy

### Key Principle: Resources are Regional, State is Centralized

**State Bucket Location:** Primary region only (e.g., `us-east-1`)  
**State Organization:** Use S3 key prefixes to separate regions

```
s3://scale-terraform-state-{account}/
├── us-east-1/
│   ├── 00-network/terraform.tfstate
│   └── 10-application/terraform.tfstate
├── us-west-2/
│   ├── 00-network/terraform.tfstate
│   └── 10-application/terraform.tfstate
└── global/
    └── iam/terraform.tfstate
```

**Why Centralized?**

- Single DynamoDB table for all locks (simpler management)
- Lower cost (no duplicate buckets per region)
- State bucket location is independent of resource location

**Why Regional Folders?**

- Blast radius isolation - `us-east-1` failures don't block `us-west-2` deployments
- Clear separation of regional infrastructure
- Terraform can still operate on one region if another region's AWS APIs are degraded

---

## Multi-Account Structure

| Account | Purpose              | State Bucket Name            | Lock Table Name        |
| ------- | -------------------- | ---------------------------- | ---------------------- |
| Dev     | Development/Testing  | `scale-terraform-state-dev`  | `terraform-locks-dev`  |
| Prod    | Production/Workloads | `scale-terraform-state-prod` | `terraform-locks-prod` |

---

## Quick Execution Guide

Once the repository is set up and the modules are created, follow these high-level steps to bootstrap an account (refer to Phase 3/5 for Dev/Prod details):

### 1. Configure the Account

```bash
cd accounts/dev # or prod
cp terraform.tfvars.example terraform.tfvars
# Update terraform.tfvars with the correct AWS Account ID
```

### 2. Deploy Local State

```bash
terraform init
terraform plan
terraform apply
```

### 3. Use the Output

Copy the `backend_configuration` output and use it in your infrastructure repositories (e.g., `mycompany.infra-network`).

---

## Roadmap

| `mycompany-dev` | Active development | `mycompany-terraform-state-dev` |
| `mycompany-prod` | Production workloads | `mycompany-terraform-state-prod` |

### Architecture Diagram

```
┌────────────────────────────────────────────────────────────────────────┐
│                        AWS Organization                                │
│                                                                        │
│  ┌────────────────────────────────┐  ┌──────────────────────────────┐  │
│  │      Dev Account               │  │     Prod Account             │  │
│  │      (111111111111)            │  │     (222222222222)           │  │
│  │                                │  │                              │  │
│  │  ┌──────────────────────────┐  │  │  ┌────────────────────────┐  │  │
│  │  │ S3: mycompany-terraform- │  │  │  │ S3: mycompany-         │  │  │
│  │  │     state-dev            │  │  │  │     terraform-state-   │  │  │
│  │  │                          │  │  │  │     prod               │  │  │
│  │  │ ├─ us-east-1/            │  │  │  │ ├─ us-east-1/          │  │  │
│  │  │ │  ├─ 00-network/        │  │  │  │ │  ├─ 00-network/      │  │  │
│  │  │ │  └─ 10-application/    │  │  │  │ │  └─ 10-application/  │  │  │
│  │  │ ├─ us-west-2/            │  │  │  │ ├─ us-west-2/          │  │  │
│  │  │ └─ global/               │  │  │  │ └─ global/             │  │  │
│  │  │                          │  │  │  │                        │  │  │
│  │  │ Versioning: ✓            │  │  │  │ Versioning: ✓          │  │  │
│  │  │ Encryption: SSE-S3       │  │  │  │ Encryption: SSE-S3     │  │  │
│  │  └──────────────────────────┘  │  │  │ MFA Delete: ✓ (opt)    │  │  │
│  │                                │  │  └────────────────────────┘  │  │
│  │  ┌──────────────────────────┐  │  │                              │  │
│  │  │ DynamoDB:                │  │  │  ┌────────────────────────┐  │  │
│  │  │ mycompany-terraform-locks│  │  │  │ DynamoDB:              │  │  │
│  │  │                          │  │  │  │ mycompany-terraform    │  │  │
│  │  │ Partition Key: LockID    │  │  │  │ -locks                 │  │  │
│  │  │ Billing: On-Demand       │  │  │  │ Partition Key: LockID  │  │  │
│  │  └──────────────────────────┘  │  │  │ Billing: On-Demand     │  │  │
│  │                                │  │  └────────────────────────┘  │  │
│  │  ┌──────────────────────────┐  │  │                              │  │
│  │  │ IAM Policy:              │  │  │  ┌────────────────────────┐  │  │
│  │  │ terraform-state-         │  │  │  │ IAM Policy:            │  │  │
│  │  │ access-dev               │  │  │  │ terraform-state-       │  │  │
│  │  └──────────────────────────┘  │  │  │ access-prod            │  │  │
│  │                                │  │  └────────────────────────┘  │  │
│  └────────────────────────────────┘  └──────────────────────────────┘  │
│                                                                        │
│  Engineers deploy Dev resources     Engineers deploy Prod resources    │
│         ↓                                      ↓                       │
│  State stored in Dev S3 bucket      State stored in Prod S3 bucket     │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘

Key Principles:
• Account Isolation: Each account has independent state infrastructure
• State Locality: Dev state in Dev account, Prod state in Prod account
• No Cross-Account Dependencies: Dev and Prod can operate independently
• Same Architecture: Consistent setup across all accounts
```

**Note:** This diagram shows the default "state-in-same-account" approach. See [Appendix F: State Storage Strategies](APPENDIX.md#appendix-f-state-storage-strategies) for alternative approaches like centralized state in Prod.

---

## Directory Structure

```
mycompany.infra-terraform-bootstrap/
├── README.md
├── accounts/
│   ├── dev/
│   │   ├── main.tf           # S3 bucket, DynamoDB table
│   │   ├── variables.tf      # Account-specific variables
│   │   ├── outputs.tf        # Backend config reference
│   │   └── terraform.tfvars  # Account ID, region
│   └── prod/
│       └── ...
└── modules/
    └── terraform-state-backend/
        ├── main.tf           # Reusable module
        ├── variables.tf
        └── outputs.tf
```

---

## Implementation Steps

### Phase 3: Bootstrap Dev Account

**Step 3.1: Clone Repository**

```bash
git clone git@github.com:mycompany/mycompany.infra-terraform-bootstrap.git
cd mycompany.infra-terraform-bootstrap/accounts/dev
```

**Step 3.2: Configure Variables**

```hcl
# accounts/dev/terraform.tfvars
aws_account_id = "123456789012"
environment    = "dev"
primary_region = "us-east-1"
```

**Step 3.3: Initialize with Local State**

```bash
terraform init  # No backend configured - uses local state
terraform plan
terraform apply
```

**Step 3.4: Verify Resources Created**

- S3 Bucket: `{company}-terraform-state-dev`
- DynamoDB Table: `{company}-terraform-locks`
- Bucket versioning enabled
- Encryption enabled (SSE-S3)

**Step 3.5: Commit Backend Config**
Output will provide backend configuration for downstream projects:

```hcl
# Copy this to infrastructure projects' backend.tf
terraform {
  backend "s3" {
    bucket         = "scale-terraform-state-dev"
    key            = "{region}/{layer}/terraform.tfstate"  # Replace per layer
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-locks-dev"
  }
}
```

**Step 3.6: Migrate Bootstrap to Remote State** (Optional)
After verifying the bucket works with other projects, you can migrate the bootstrap itself to use remote state:

```bash
# Add backend block to main.tf
terraform init -migrate-state
```

---

### Phase 4: Bootstrap Prod Account

```bash
cd ../prod
# Update terraform.tfvars with prod account ID
terraform init
terraform apply
```

---

## Security Hardening

### Bucket Security

- **Encryption:** SSE-S3 (or SSE-KMS for compliance requirements)
- **Versioning:** Enabled (recover from accidental deletions)
- **Public Access:** Blocked entirely
- **Object Lock:** Consider enabling for compliance (prevents state deletion)

### Access Control

**Who Needs Access?**

- **Engineers** - Need read/write access to run Terraform locally
- **CI/CD Pipelines** - Need read/write access to run Terraform in automation (GitHub Actions, Jenkins, etc.)
- **Auditors/Readers** - May need read-only access to review state without modifying

**Best Practices:**

- **Use IAM Roles for CI/CD** - Never use long-term access keys in pipelines
- **Use AWS SSO for Engineers** - Temporary credentials that expire
- **Separate Read/Write Policies** - Grant read-only access where possible
- **Bucket Policy:** Enforce SSL/TLS for all access

### IAM Policy for Engineers (Read/Write Access)

Attach this policy to your IAM Identity Center permission sets or IAM groups:

```hcl
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformStateReadWrite",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::{company}-terraform-state-${var.environment}",
        "arn:aws:s3:::{company}-terraform-state-${var.environment}/*"
      ]
    },
    {
      "Sid": "TerraformStateLocking",
      "Effect": "Allow",
      "Action": [
        "dynamodb:PutItem",
        "dynamodb:GetItem",
        "dynamodb:DeleteItem"
      ],
      "Resource": "arn:aws:dynamodb:us-east-1:${var.account_id}:table/{company}-terraform-locks"
    }
  ]
}
```

**For Bootstrap CI (Validation):** See [phase-4-bootstrap-ci.md](phase/phase-4-bootstrap-ci.md) for automated validation workflows (format, security, linting).

**For Bootstrap CD (Deployment):** See [phase-7-continuous-deployment.md](phase/phase-7-continuous-deployment.md) for OIDC setup and automated deployment workflows.

**For Downstream Project CI/CD:** See [phase-8-downstream-cicd.md](phase/phase-8-downstream-cicd.md) for GitHub Actions, GitLab CI, and Jenkins setup in infrastructure projects that use this bootstrap.

### Read-Only Access Policy (For Auditors)

```hcl
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformStateReadOnly",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetObject",
        "s3:GetObjectVersion"
      ],
      "Resource": [
        "arn:aws:s3:::{company}-terraform-state-${var.environment}",
        "arn:aws:s3:::{company}-terraform-state-${var.environment}/*"
      ]
    },
    {
      "Sid": "TerraformLockTableReadOnly",
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:Scan"
      ],
      "Resource": "arn:aws:dynamodb:us-east-1:${var.account_id}:table/{company}-terraform-locks"
    }
  ]
}
```

### Additional IAM Considerations

**For Production Accounts:**

- Enable **MFA Delete** on S3 bucket to require MFA for destructive operations
- Use **s3:DeleteObject** with caution - consider removing for prod
- Implement **IAM conditions** to restrict access by source IP or time of day
- Enable **CloudTrail logging** for all state bucket access

**Permissions NOT Granted:**

- `s3:DeleteBucket` - Prevents accidental bucket deletion
- `dynamodb:DeleteTable` - Prevents accidental table deletion
- `s3:PutBucketPolicy` - Prevents policy modification

**Security Reminders:**

- Never commit AWS credentials to Git
- Use temporary credentials (AWS SSO, IAM roles) instead of long-term access keys
- Rotate any leaked credentials immediately
- Review CloudTrail logs regularly for unauthorized access attempts

---

## Cost Considerations

**Monthly Cost (per account):**

- S3 Bucket: ~$0.023/GB + $0.005/1000 requests (negligible for state files)
- DynamoDB Table: $0.25/month (on-demand pricing, ~100 locks/month)
- **Total:** < $1/month per account

**Cost Optimization:**

- Use S3 Lifecycle policies to delete old state versions after 90 days
- DynamoDB on-demand pricing (no provisioned capacity needed)

---

## Downstream Project Integration

Once bootstrap is complete, reference the backend in all infrastructure projects. The **same S3 bucket** is used for all layers - organization happens via the `key` path.

### Network Layer Example

```hcl
# infrastructure/environments/dev/us-east-1/00-network/backend.tf
terraform {
  backend "s3" {
    bucket         = "scale-terraform-state-dev"
    key            = "us-east-1/00-network/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-locks-dev"
  }
}
```

### Application Layer Example

```hcl
# infrastructure/environments/dev/us-east-1/10-application/backend.tf
terraform {
  backend "s3" {
    bucket         = "scale-terraform-state-dev"
    key            = "us-east-1/10-application/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-locks-dev"
  }
}
```

### Database Layer Example

```hcl
# infrastructure/environments/dev/us-east-1/20-database/backend.tf
terraform {
  backend "s3" {
    bucket         = "scale-terraform-state-dev"
    key            = "us-east-1/20-database/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-locks-dev"
  }
}
```

### Multi-Region Application Example

```hcl
# infrastructure/environments/dev/us-west-2/10-application/backend.tf
terraform {
  backend "s3" {
    bucket         = "scale-terraform-state-dev"
    key            = "us-west-2/10-application/terraform.tfstate"  # Different region in key
    region         = "us-east-1"  # Bucket location stays the same
    encrypt        = true
    dynamodb_table = "terraform-locks-dev"
  }
}
```

**Key Points:**

- **One bucket per account** (`scale-terraform-state-dev` for all Dev account infrastructure)
- **Organization via S3 key paths** (region/layer pattern)
- **Separate lock tables per account** (`terraform-locks-dev`, `terraform-locks-prod`)
- **Bucket region** is always the primary region (us-east-1), regardless of where resources are deployed

---

## Disaster Recovery

**State File Loss Scenarios:**

1. **Accidental `terraform destroy` on bootstrap:**
   - S3 versioning allows recovery of deleted bucket/state
   - DynamoDB table can be recreated (no data loss if bucket survives)

2. **S3 bucket corruption:**
   - S3 replication to secondary region (optional for production)
   - Regular state backups to separate storage (S3 Glacier)

3. **Region failure:**
   - State bucket in `us-east-1` failing doesn't prevent managing resources in `us-west-2`
   - Can temporarily switch to local state in emergency

**Recovery Procedure:**

```bash
# Restore from S3 version
aws s3api list-object-versions --bucket {company}-terraform-state-prod \
  --prefix us-east-1/00-network/terraform.tfstate

# Download specific version
aws s3api get-object --bucket {company}-terraform-state-prod \
  --key us-east-1/00-network/terraform.tfstate \
  --version-id {VERSION_ID} terraform.tfstate
```

---

## Validation Checklist

After bootstrap:

- [ ] S3 bucket exists and is encrypted
- [ ] Bucket versioning is enabled
- [ ] Public access is blocked
- [ ] DynamoDB table exists with `LockID` partition key
- [ ] IAM policies allow Terraform operations
- [ ] Backend config documented in outputs
- [ ] Tested with a simple Terraform project (create a test VPC)

---

## Maintenance

**Annual Tasks:**

- Review S3 lifecycle policies (adjust retention as needed)
- Audit IAM access to state resources
- Validate bucket encryption compliance

**Quarterly Tasks:**

- Review DynamoDB lock table costs (should be < $1/month)
- Check for stuck locks (orphaned items in DynamoDB)

**As Needed:**

- Add new accounts: Run bootstrap for each new AWS account
- Update encryption: Migrate from SSE-S3 to SSE-KMS if compliance requires

---

## Next Steps

1. Create `mycompany.infra-terraform-bootstrap` repository
2. Run bootstrap for Dev account
3. Integrate backend config into `{company}-cloud-infrastructure`
4. Run bootstrap for Prod account when approved

---

## Additional Resources

- **[phase-0-prerequisites.md](phase/phase-0-prerequisites.md)** - Install Terraform, AWS CLI, configure AWS SSO (macOS/Windows/Linux)
- **[phase-1-repository-setup.md](phase/phase-1-repository-setup.md)** - Repository initialization and Git configuration
- **[phase-2-terraform-module.md](phase/phase-2-terraform-module.md)** - Terraform state backend module creation
- **[phase-3-bootstrap-dev.md](phase/phase-3-bootstrap-dev.md)** - Dev account bootstrap
- **[phase-4-bootstrap-ci.md](phase/phase-4-bootstrap-ci.md)** - Continuous Integration (validation workflows)
- **[phase-5-bootstrap-prod.md](phase/phase-5-bootstrap-prod.md)** - Prod account bootstrap
- **[phase-6-migrate-to-remote-state.md](phase/phase-6-migrate-to-remote-state.md)** - Optional state migration (flexible ordering - dev before prod is OK)
- **[phase-7-continuous-deployment.md](phase/phase-7-continuous-deployment.md)** - Optional: Automated deployment with OIDC
- **[phase-8-next-steps.md](phase/phase-8-next-steps.md)** - What to do after bootstrap completion
- **[appendix/](appendix/)** - Additional guides (naming, state migration concepts, AWS SSO, adding accounts, etc.)

---

## References

- [Terraform Backend Configuration](https://developer.hashicorp.com/terraform/language/settings/backends/s3)
- [S3 Bucket Security Best Practices](https://docs.aws.amazon.com/AmazonS3/latest/userguide/security-best-practices.html)
- [DynamoDB Pricing](https://aws.amazon.com/dynamodb/pricing/)
