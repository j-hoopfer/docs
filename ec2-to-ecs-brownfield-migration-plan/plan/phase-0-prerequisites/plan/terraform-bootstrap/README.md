# Terraform Bootstrap Plan

**Purpose:** Initialize Terraform state management infrastructure across AWS accounts and regions for mycompany's cloud infrastructure.

**Repository:** `infra-terraform-bootstrap`

**Scope:** One-time setup per AWS account to create S3 state buckets, DynamoDB lock tables, and IAM policies required for safe Terraform operations.

**Target Audience:** Junior engineers, contingent workers, and AI agents - includes detailed step-by-step instructions with personas, acceptance criteria, and validation steps.

**Estimated Time:** 2.5-5 hours total (all accounts, core phases)

## Phases Overview

| Phase                                             | Theme                                 | What It Means                                                                                                                                                                                            | Time      |
| ------------------------------------------------- | ------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- |
| **Phase 0: Prerequisites**                        | Environment Setup & Tool Installation | Install and configure all required tools (Terraform, AWS CLI, Git) and set up AWS SSO authentication. This phase ensures you have everything needed before starting infrastructure work.                 | 30-60 min |
| **Phase 1: Repository Setup**                     | Version Control Foundation            | Create the Git repository, configure branch protection, and establish the directory structure. This sets up the collaboration foundation for team-based infrastructure management.                       | 30-45 min |
| **Phase 2: Terraform Module**                     | Reusable Infrastructure Components    | Build the core Terraform module that creates S3 buckets and DynamoDB tables. This module will be reused for both dev and prod accounts, ensuring consistency.                                            | 30-45 min |
| **Phase 3: Bootstrap Dev Account**                | First Deployment & Validation         | Deploy the state infrastructure to your dev AWS account using local state. This creates the S3 bucket and DynamoDB table that all future dev projects will use for remote state storage.                 | 30-60 min |
| **Phase 4: Continuous Integration**               | Automated Quality Gates               | Set up GitHub Actions workflows to automatically validate code formatting, security (tfsec), and quality (tflint) on every pull request. This catches issues before they reach production.               | 30-45 min |
| **Phase 5: Bootstrap Prod Account**               | Production Infrastructure Deployment  | Deploy the same state infrastructure to your production AWS account. CI validation from Phase 4 gives you confidence that the prod deployment will succeed.                                              | 30-60 min |
| **Phase 6: Migrate to Remote State** _(Optional)_ | Self-Hosting & Team Collaboration     | Move the bootstrap project's own state file from your laptop to the S3 bucket it created. This enables team collaboration on the bootstrap infrastructure itself and demonstrates the migration process. | 15-30 min |
| **Phase 7: Continuous Deployment** _(Optional)_   | Automated Infrastructure Deployment   | Set up OIDC authentication and GitHub Actions workflows to automatically deploy infrastructure changes. This enables automated terraform apply with approval gates for production.                       | 60-90 min |
| **Phase 8: Next Steps**                           | Post-Bootstrap Roadmap                | Guidance on what to build next after bootstrap is complete - networking, compute, databases, and how to structure downstream infrastructure projects.                                                    | -         |

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

## Multi-Account Structure

| Account | Purpose              | State Bucket Name                | Lock Table Name        |
| ------- | -------------------- | -------------------------------- | ---------------------- |
| Dev     | Development/Testing  | `mycompany-terraform-state-dev`  | `terraform-locks-dev`  |
| Prod    | Production/Workloads | `mycompany-terraform-state-prod` | `terraform-locks-prod` |

---

## Directory Structure

```
mycompany.infra-terraform-bootstrap/
├── .github/
│   └── workflows/
│       ├── validate.yml      # Terraform format & validation
│       ├── security.yml      # tfsec security scanning
│       └── lint.yml          # tflint code quality
├── .gitignore
├── README.md
├── accounts/
│   ├── dev/
│   │   ├── main.tf           # Module invocation
│   │   ├── providers.tf      # AWS provider config
│   │   ├── variables.tf      # Input variables
│   │   ├── outputs.tf        # Backend config outputs
│   │   └── terraform.tfvars  # Account-specific values
│   └── prod/
│       ├── main.tf
│       ├── providers.tf
│       ├── variables.tf
│       ├── outputs.tf
│       └── terraform.tfvars
└── modules/
    └── terraform-state-backend/
        ├── s3.tf             # S3 bucket for state storage
        ├── dynamo.tf         # DynamoDB lock table
        ├── iam.tf            # IAM policies
        ├── variables.tf      # Module inputs
        └── outputs.tf        # Module outputs
```

---

## Security

The bootstrap creates secure infrastructure by default:

- ✅ **Encryption:** All state files encrypted at rest (SSE-S3)
- ✅ **Versioning:** Enabled on S3 bucket (recover from mistakes)
- ✅ **Public Access:** Blocked completely
- ✅ **State Locking:** DynamoDB prevents concurrent modifications

**Access Control:**

- Engineers use AWS SSO (temporary credentials)
- CI/CD uses IAM roles (no long-term keys)
- Never commit credentials to Git

For detailed IAM policies and advanced security configurations, see the [State File Security](appendix/state-file-security.md) appendix

---

## Cost

**~$1/month per account** (S3 + DynamoDB on-demand pricing)

---

## Using the Bootstrap in Other Projects

Once bootstrap is complete, all infrastructure projects use the S3 bucket for state storage:

```hcl
# Example: infrastructure/backend.tf
terraform {
  backend "s3" {
    bucket         = "scale-terraform-state-dev"
    key            = "my-project/terraform.tfstate"  # Unique per project
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-locks-dev"
  }
}
```

**Key Point:** One S3 bucket per account, organized by the `key` path. See [Phase 8: Next Steps](phase/phase-8-next-steps.md) for detailed downstream project setup

---

## Getting Started

Ready to begin? Start with [Phase 0: Prerequisites](phase/phase-0-prerequisites.md) and follow the phases in order

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
