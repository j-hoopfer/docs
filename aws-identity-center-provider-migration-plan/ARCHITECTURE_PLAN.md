# Master Architecture Plan: AWS Identity Center Federation with Google Workspace

## 1. Executive Summary

This initiative transitions our AWS authentication model from a fragmented internal directory to a centralized **Single Sign-On (SSO)** architecture using **Google Workspace** as the authoritative Identity Provider (IdP).

### Strategic Value

- **Centralized Security:** Enforces Multi-Factor Authentication (MFA) at the Google ingress point, removing the need to manage AWS-specific credentials.
- **Scalability:** Implements a **"Dynamic Account-Centric"** Terraform pattern. Onboarding new accounts requires **zero** logic changes to infrastructure code.
- **Audit Compliance:** Shift from manual assignments ("Click-Ops") to Terraform-managed assignments, providing a Git-backed audit trail for every permission grant.
- **Operational Resilience:** Includes a "Brownfield Migration" strategy to ensure zero data loss during the transition from the legacy directory.

---

## 2. Prerequisites & Access Requirements

**Before Day 1, ensure the following are prepared:**

- **Access Levels:**
  - **Google Workspace:** Super Admin access (to configure SAML apps & SCIM).
  - **AWS:** Management Account **Root** credentials (for initial "Break-Glass" setup).
  - **Terraform:** `v1.0+` installed with AWS Provider `v5.0+`.

- **Tooling:**
  - Python 3.8+ & `boto3` (for the pre-migration audit script).

- **Maintenance Window:** Schedule a **1-hour downtime** for the Identity Source switch (existing SSO sessions will be terminated).

---

## Phase 1: Foundation & Root Governance

_Goal: Secure the "Keys to the Kingdom" and establish the blast radius controls._

### 1.1 Secure Management Root User

- **Credential Storage:** Rotate Root password to a generated 30+ character string; store in corporate vault (e.g., CyberArk/1Password).
- **MFA:** Enforce **Hardware YubiKey** protection. (Mobile app MFA is explicitly disallowed for Root).
- **Email Access:** Document who has access to the root email inbox. Implement email forwarding rules to security team distribution list.
- **Monitoring:** Configure CloudTrail and CloudWatch Alarms to trigger immediate paging (PagerDuty/Slack) on any usage of the Root user.
  - _Filter Pattern:_ `{ $.userIdentity.type = "Root" && $.userIdentity.invokedBy NOT EXISTS }`

### 1.2 Lock Down Member Account Roots

- **Strategy:** Prevent usage of the Root user in child accounts (Dev, Prod) entirely.
- **Testing:** Apply SCP to a test OU first, verify no business impact.
- **Implementation:** Apply a **Service Control Policy (SCP)** to the Organization Root.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyRootAccountAccess",
      "Effect": "Deny",
      "Action": "*",
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "aws:PrincipalArn": "arn:aws:iam::*:root"
        }
      }
    }
  ]
}
```

---

## Phase 2: Migration Prep (Brownfield Safety Net)

_Goal: Mitigate the risk of "The Wipe." Changing Identity Sources deletes all current assignments._

### 2.1 The Pre-Migration Audit

- **Risk:** New Google Groups will have different IDs than old AWS Groups. Mapping will be lost.
- **Mitigation:** Run the `export_sso_assignments.py` script (Python/Boto3) to generate a CSV snapshot of current permissions.
- **Output:** `sso_assignments_backup.csv` (Maps `Group` -> `PermissionSet` -> `Account`).
- **IAM Permissions Required:**
  - `sso:ListInstances`
  - `sso:ListAccountAssignments`
  - `sso:ListPermissionSets`
  - `identitystore:ListGroups`
  - `identitystore:DescribeGroup`

### 2.2 The "Break-Glass" Administrator

- **Risk:** Switching Identity Sources terminates the admin's own session.
- **Mitigation:** Create a temporary IAM User (`migration-admin`) in the Management Account.
  - **Policy:** `AdministratorAccess`
  - **MFA:** Enabled immediately.
  - **Test:** Verify login capability before starting Phase 3.
  - **Expiration:** Set calendar reminder to delete this user within 7 days post-migration.

---

## Phase 3: The Identity Bridge (Google Configuration)

_Goal: Configure Google as the Single Source of Truth._

### 3.1 Google Workspace Prerequisites

**Edition Required:** Google Workspace Business Standard or Enterprise (Free/Basic lacks SAML support)

**Licenses:** Minimum 1 license per AWS user

**API Access:**

1. Enable Admin SDK API in Google Cloud Console
2. Create service account with domain-wide delegation
3. Grant scopes: `https://www.googleapis.com/auth/admin.directory.group.readonly`

### 3.2 MFA Enforcement

- **Policy:** Google Workspace must enforce **2-Step Verification (2SV)** for all users in `AWS-*` groups.
- **Implementation:** Create Google Workspace security policy targeting organizational unit containing AWS users.
- **Constraint:** AWS will trust the SAML assertion; Google acts as the strict gatekeeper.

### 3.3 Group Architecture (The "Account-Centric" Pattern)

- **Naming Convention:** `AWS-<AccountID>-<Role>`
- **Action:** Create groups in Google Workspace matching the AWS Account structure.
  - _Example (Prod Account):_ `AWS-123456789012-Admin`, `AWS-123456789012-RO`
  - _Example (Dev Account):_ `AWS-471112975126-Admin`
  - _Example (Finance):_ `AWS-Finance-Billing`

### 3.4 SAML Attribute Mapping

| AWS Attribute   | Google Attribute | Example Value    |
| --------------- | ---------------- | ---------------- |
| Subject         | Primary Email    | user@company.com |
| RoleSessionName | Username         | jsmith           |
| Email           | Primary Email    | user@company.com |

---

## Phase 4: The Cutover (Maintenance Window)

_Goal: The Manual "Handshake" & Sync._

**Pre-Cutover Checklist:**

- [ ] CloudFormation export of current SSO configuration created
- [ ] `migration-admin` IAM user tested and verified
- [ ] All stakeholders notified of maintenance window
- [ ] Rollback procedure reviewed

**Cutover Steps:**

1. **Log in** as `migration-admin`.
2. **AWS Console:** Identity Center > Settings > **Change Identity Source** -> **External Identity Provider**.
   - _Action:_ Accept warning (Assignments deleted).

3. **SAML Exchange:**
   - Upload AWS Metadata to Google (App: "Amazon Web Services").
   - Upload Google Metadata to AWS.

4. **SCIM Configuration:**
   - Enable **Automatic Provisioning** in AWS.
   - **Secret Handling:** Capture SCIM Endpoint & Token immediately (store in vault).
   - Configure Google Autoprovisioning with these credentials.

5. **Sync Verification:** Wait ~15 minutes. Confirm Google Groups appear in the AWS Identity Center Console.

**Rollback Criteria:**

- If SCIM sync fails after 30 minutes, revert to AWS Managed Directory
- If test user cannot login after 45 minutes, revert
- Recovery Time Objective (RTO): 15 minutes

---

## Phase 5: Terraform Implementation

_Goal: Re-apply permissions using the Scalable Matrix Pattern._

See detailed Terraform configuration in `terraform/` directory.

**Execution Steps:**

```bash
# Initialize
cd terraform/
terraform init

# Preview (CRITICAL: Review before applying)
terraform plan -out=tfplan

# Execute
terraform apply tfplan
```

---

## Phase 6: Acceptance Criteria

| Criteria                | Verification Method                                       |
| ----------------------- | --------------------------------------------------------- |
| **Authentication Flow** | AWS Login redirects to Google Workspace.                  |
| **MFA Gate**            | Users without 2SV enabled in Google are blocked from AWS. |
| **Authorization Check** | Engineering user has `Admin` in Dev, `ViewOnly` in Prod.  |
| **Root Governance**     | Login as Root triggers Critical Alert (< 2 mins).         |
| **Cleanup**             | `migration-admin` IAM user is disabled/deleted.           |

_See detailed test cases in `testing/acceptance_tests.md`_

---

## Phase 7: Monitoring & Alerting

### CloudWatch Alarms

1. **Failed SSO Logins** (> 5 in 5 minutes)
2. **Permission Set Changes** (any modification)
3. **Identity Store Sync Failures**

### CloudTrail Events to Monitor

- `CreateAccountAssignment`
- `DeleteAccountAssignment`
- `AttachManagedPolicyToPermissionSet`
- `UpdatePermissionSet`

### Weekly Review

- Audit CloudTrail logs for `sso:*` API calls
- Verify group membership matches HR system
- Review orphaned access (users in AWS but not in Google)

---

## Phase 8: Disaster Recovery

### Break-Glass Scenarios

| Scenario                        | Detection                | Response                                                                      | RTO    |
| ------------------------------- | ------------------------ | ----------------------------------------------------------------------------- | ------ |
| Google Workspace Outage         | AWS login fails globally | Use emergency IAM users in vault                                              | 15 min |
| SCIM Sync Failure               | Groups not updating      | Manual assignment via console                                                 | 30 min |
| Terraform State Corruption      | `terraform plan` errors  | Restore from S3 versioning                                                    | 10 min |
| Rogue Admin Deletes Assignments | Users lose access        | Revert Terraform from Git history: `git revert <commit>` && `terraform apply` | 5 min  |

### Break-Glass IAM Users

- Create 2 IAM users in Management Account (`emergency-admin-1`, `emergency-admin-2`)
- Store credentials in vault with approval workflow
- Quarterly rotation requirement
- Test quarterly to ensure credentials work

---

## Phase 9: Timeline & Effort

| Phase              | Duration | Effort (Eng Hours)                 | Dependencies                      |
| ------------------ | -------- | ---------------------------------- | --------------------------------- |
| 1: Root Governance | 2 hours  | 3 hours                            | Root credentials available        |
| 2: Migration Prep  | 4 hours  | 6 hours                            | Python env setup, IAM permissions |
| 3: Google Config   | 2 days   | 12 hours                           | Google Workspace Super Admin      |
| 4: Cutover         | 1 hour   | 2 hours (+ 2 engineers on standby) | Maintenance window approved       |
| 5: Terraform Apply | 30 mins  | 4 hours (including testing)        | State bucket created              |
| 6: Validation      | 2 days   | 8 hours                            | Test users created                |

**Total: ~1 week elapsed, 35 engineering hours**

---

## Appendix A: Why This Architecture is Scalable

### 1. The "N+1" Solution

In traditional Terraform setups, adding an account requires copying multiple resource blocks (linear complexity). In this architecture, adding an account requires adding **one line** (the Account ID) to a variable list. Terraform mathematically calculates the rest.

**Example:**

```hcl
# Adding a new account is this simple:
variable "member_accounts" {
  default = [
    "471112975126", # Dev Account
    "637423317953", # Prod Account
    "999888777666"  # NEW: Staging Account - ONE LINE CHANGE
  ]
}
```

### 2. Identity as an API

By standardizing the Google Group name (`AWS-<AccountID>-<Role>`), we create a strict contract. If a group is misnamed in Google, Terraform fails safely (it won't find the group) rather than granting permissions incorrectly.

---

## Appendix B: The Lifecycle of a User & Permission

1. **Create (Google):** Admin creates group & adds user. _Status: Identity Defined._
2. **Sync (SCIM):** Google pushes group/user to AWS. _Status: Identity Present in AWS, Access Zero._
3. **Assign (Terraform):** `terraform apply` links the Group to the Permission Set. _Status: Authorization Active._

**Revocation Flow:**

1. **Remove (Google):** Admin removes user from group.
2. **Sync (SCIM):** Google removes group membership in AWS.
3. **Effect:** User loses access within 15 minutes (SCIM sync interval).

---

## Appendix C: Safe Testing Strategy

Since Identity Center is a Global Service, we cannot deploy a "Dev" instance. We use **Target-Based Testing**:

1. **Beta:** Create a new Permission Set via Terraform variable `beta_assignments` targeting **only** the Sandbox Account.
2. **Verify:** Validate permissions in Sandbox.
3. **Promote:** Move the Role configuration to the main `role_definition_mapper` variable to deploy to all accounts.

**Example Beta Configuration:**

```hcl
variable "beta_assignments" {
  description = "Test assignments for sandbox only"
  type = map(object({
    account_id     = string
    permission_set = string
    group_name     = string
  }))
  default = {
    "sandbox-datascience" = {
      account_id     = "111222333444"  # Sandbox Account
      permission_set = "DataScientistAccess"
      group_name     = "AWS-111222333444-DataScience"
    }
  }
}
```

---

## Appendix D: Terraform Backend Strategy for Identity Center

### D.1 Architecture Decision

**Critical Understanding: Identity Center is a Global Service**

AWS Identity Center is **NOT deployed per-account** - there is exactly **ONE instance per AWS Organization**, and it resides in the **Management Account**.

```
AWS Organization
├── Management Account (Identity Center lives here)
│   ├── S3 Bucket: terraform-state-identity-center-MGMT-ACCT-ID
│   ├── DynamoDB Table: terraform-state-locks
│   └── Identity Center Instance (GLOBAL - manages ALL accounts)
│
├── Dev Account (471112975126)
│   └── Receives SSO access managed by Identity Center
│
└── Prod Account (637423317953)
    └── Receives SSO access managed by Identity Center
```

**Selected Strategy: Single Backend in Management Account**

Since Identity Center is global and not duplicated per environment, we use:

- ✅ **One Terraform State File:** `identity-center/terraform.tfstate` in management account
- ✅ **One Backend Configuration:** `backend.hcl` pointing to management account
- ✅ **No Environment Switching:** All changes affect production Identity Center
- ✅ **State Lives with Infrastructure:** Backend is in the same account as Identity Center

**Why NOT Separate Backends Per Environment?**

Some teams consider creating separate AWS Organizations with separate Identity Center instances for dev/prod isolation. **This is almost never the right choice:**

❌ **Doubled Management Overhead:**

- Two separate Google Workspace SAML configurations
- Two SCIM integrations to maintain
- Duplicate permission sets and assignments
- Users confused by which login portal to use

❌ **Cannot Test Realistically:**

- "Testing" in a separate org doesn't validate changes to production org structure
- Different Organization IDs, account IDs, and Identity Center instance IDs
- Separate SCPs, OUs, and account structures
- Test results don't guarantee production success

❌ **Expensive at Scale:**

- Requires duplicate AWS accounts for every environment (2× infrastructure cost)
- Additional Google Workspace licenses if using separate directories
- Double the CloudTrail, Config, GuardDuty costs

❌ **When It MIGHT Make Sense (Rare Cases):**

- Regulatory requirements mandating physical separation (e.g., FedRAMP vs commercial)
- Very large enterprises (1000+ AWS accounts) where blast radius is unacceptable
- Testing AWS Organizations control tower migrations or SCP policy changes
- Multi-tenant SaaS providing isolated Identity Center per customer

**For most organizations:** Use ONE Identity Center instance and rely on:

- Careful code review
- Thorough `terraform plan` inspection
- Manual approval gates for production changes
- Terraform state file protection

### D.2 Implementation Pattern: Partial Backend Configuration

**File Structure:**

```
identity-center/
├── backend.tf              # Empty backend block (partial config)
├── backend.hcl             # Management account backend configuration
├── main.tf                 # Identity Center resources
├── variables.tf            # Input variables
└── outputs.tf              # Outputs (e.g., Identity Center ARN)
```

**backend.tf (Partial Configuration):**

```hcl
terraform {
  required_version = ">= 1.0"

  backend "s3" {
    # EMPTY - values provided at runtime via -backend-config flag
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

**backend.hcl (Management Account):**

```hcl
bucket         = "terraform-state-identity-center-MGMT-ACCT-ID"
key            = "identity-center/terraform.tfstate"
region         = "us-east-1"
encrypt        = true
dynamodb_table = "terraform-state-locks"
```

### D.3 Daily Workflow

**Deploying Identity Center Changes:**

```bash
# Set AWS credentials for MANAGEMENT account
export AWS_PROFILE=management  # Or whatever you named your mgmt account profile

# Verify you're in the correct account
aws sts get-caller-identity
# Expected output should show Management Account ID

# Initialize Terraform
terraform init -backend-config=backend.hcl

# Review changes CAREFULLY (affects production)
terraform plan

# Apply changes (consider using -out flag for safety)
terraform plan -out=tfplan
terraform apply tfplan
```

**Safety Reminder:** Since Identity Center is global and manages access to ALL accounts (Dev, Prod, etc.), every `terraform apply` affects production. There is no "test environment" for Identity Center changes.

### D.4 State Backend Setup (Management Account Only)

One-time setup in the **Management Account**:

```bash
# Set AWS credentials for management account
export AWS_PROFILE=management
export MGMT_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# 1. Create S3 bucket for Identity Center state
aws s3 mb s3://terraform-state-identity-center-${MGMT_ACCOUNT_ID} --region us-east-1

# 2. Enable versioning (allows state rollback)
aws s3api put-bucket-versioning \
  --bucket terraform-state-identity-center-${MGMT_ACCOUNT_ID} \
  --versioning-configuration Status=Enabled

# 3. Enable encryption
aws s3api put-bucket-encryption \
  --bucket terraform-state-identity-center-${MGMT_ACCOUNT_ID} \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

# 4. Block public access
aws s3api put-public-access-block \
  --bucket terraform-state-identity-center-${MGMT_ACCOUNT_ID} \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# 5. Create DynamoDB table for state locking
aws dynamodb create-table \
  --table-name terraform-state-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

### D.5 State File Structure

The management account's S3 bucket can organize state for multiple infrastructure projects:

```
s3://terraform-state-identity-center-MGMT-ACCT-ID/
├── identity-center/terraform.tfstate          # This project (Identity Center config)
├── organization/scp-policies/terraform.tfstate # Future: Service Control Policies
├── organization/accounts/terraform.tfstate     # Future: AWS account provisioning
└── security/cloudtrail/terraform.tfstate       # Future: Organization-wide CloudTrail
```

All organization-level projects share the same S3 bucket (different keys) and DynamoDB table.

### D.6 Disaster Recovery

**Restore Previous State Version:**

```bash
# List all versions of state file
aws s3api list-object-versions \
  --bucket terraform-state-identity-center-MGMT-ACCT-ID \
  --prefix identity-center/terraform.tfstate

# Download specific version
aws s3api get-object \
  --bucket terraform-state-identity-center-MGMT-ACCT-ID \
  --key identity-center/terraform.tfstate \
  --version-id <VERSION-ID> \
  restored-state.tfstate

# Restore by uploading as current version
aws s3 cp restored-state.tfstate \
  s3://terraform-state-identity-center-MGMT-ACCT-ID/identity-center/terraform.tfstate
```

**Unlock Stuck State:**

If Terraform crashes during execution, it may leave a lock:

```bash
terraform force-unlock <LOCK-ID>
```

### D.7 Security Best Practices

**IAM Permissions Required (Management Account):**

The AWS user/role executing Terraform needs these permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformStateAccess",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetObject", "s3:PutObject"],
      "Resource": [
        "arn:aws:s3:::terraform-state-identity-center-MGMT-ACCT-ID",
        "arn:aws:s3:::terraform-state-identity-center-MGMT-ACCT-ID/*"
      ]
    },
    {
      "Sid": "TerraformStateLocking",
      "Effect": "Allow",
      "Action": ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"],
      "Resource": "arn:aws:dynamodb:us-east-1:MGMT-ACCT-ID:table/terraform-state-locks"
    },
    {
      "Sid": "IdentityCenterManagement",
      "Effect": "Allow",
      "Action": ["sso:*", "sso-admin:*", "identitystore:*"],
      "Resource": "*"
    }
  ]
}
```

**Pre-Deployment Checklist:**

Before running `terraform apply` (remember: this affects PRODUCTION):

- [ ] Verified AWS credentials point to **Management Account**: `aws sts get-caller-identity`
- [ ] Ran `terraform plan` and reviewed **ALL** changes carefully
- [ ] Tested code changes in feature branch, reviewed in PR
- [ ] Have rollback plan documented (state file versioning enabled)
- [ ] Maintenance window communicated if making breaking changes
- [ ] Team notified of Identity Center changes (affects everyone's SSO access)

### D.8 Testing Strategy for Global Services

**The Challenge:** Identity Center is global - you can't test changes in a "dev" Identity Center because there isn't one.

**Safe Deployment Practices:**

1. **Thorough Code Review:**
   - All changes go through GitHub Pull Requests
   - Require at least one approval from team member
   - Use branch protection rules to enforce review

2. **Terraform Plan Inspection:**
   - Always run `terraform plan` before `apply`
   - Save plan output: `terraform plan -out=tfplan`
   - Review every resource to be created/modified/destroyed
   - Use `terraform show tfplan` for detailed inspection

3. **Manual Approval Gates:**
   - Use GitHub Actions environments with required reviewers
   - Production deploys require explicit human approval
   - Include plan output in approval request

4. **Incremental Rollouts:**
   - Add new permission sets without assigning them first
   - Test permission sets with small pilot group
   - Gradually expand assignments after validation
   - Remove old assignments only after new ones are confirmed working

5. **Rollback Capability:**
   - S3 versioning enabled on state bucket
   - Keep previous Terraform code in Git history
   - Document rollback procedure before major changes
   - Test state restoration process in advance

**When Separate AWS Organizations Make Sense (Almost Never):**

Creating a separate test AWS Organization with its own Identity Center is expensive and complex. Only consider if:

- **Regulatory Mandate:** Compliance framework requires physical separation (e.g., FedRAMP vs commercial workloads)
- **Very Large Scale:** 1000+ AWS accounts where blast radius is unacceptable
- **Testing Organization Structure:** Need to test AWS Control Tower migrations, complex OU restructuring, or risky SCP policies
- **Multi-Tenant SaaS:** Each customer gets isolated Identity Center instance

**Why It's Usually Overkill:**

- **2× Management Work:** Maintain two SAML configs, two SCIM integrations, duplicate permission sets
- **Testing Doesn't Prove Production:** Different Org IDs, different account structures, different users
- **Expensive:** Double all AWS accounts (Dev-Dev, Dev-Prod, Prod-Dev, Prod-Prod), double monitoring costs
- **User Confusion:** Which SSO portal do I use? Which Google Workspace directory?

**Recommended Approach:** Use rigorous code review, detailed plan inspection, and manual approval gates. Reserve separate organizations for genuine regulatory requirements, not general testing.

### D.9 Cost Analysis

**Monthly Cost (Management Account Only):**

| Resource               | Usage                | Cost             |
| ---------------------- | -------------------- | ---------------- |
| S3 Bucket              | ~1 MB state files    | $0.02            |
| S3 Versioning          | 100 versions × 10 KB | $0.002           |
| DynamoDB Table         | PAY_PER_REQUEST      | $0.01            |
| **Total Monthly Cost** |                      | **~$0.03/month** |

State management cost is negligible. Identity Center itself is free (no additional charge beyond AWS accounts).

### D.10 Migration from Multi-Backend Setup (If Applicable)

If you previously used a shared backend and need to migrate:

```bash
# 1. Export current state
terraform state pull > backup-state.json

# 2. Re-initialize with new backend
terraform init -backend-config=backend-dev.hcl -reconfigure

# 3. Verify state migration
terraform plan  # Should show no changes

# 4. Test a trivial apply
terraform apply -auto-approve
```

### D.10 Reference Implementation

The complete reference implementation is available in the `tf-aws-identity` repository:

```
tf-aws-identity/
├── backend.hcl             # Management account backend configuration
├── identity-center/
│   ├── backend.tf          # Partial configuration block
│   ├── main.tf             # Identity Center resources
│   ├── variables.tf        # Input variables
│   └── outputs.tf          # Outputs
├── docs/
│   ├── backend-setup.md    # Backend setup guide
│   ├── daily-workflow.md   # Daily procedures
│   └── github-actions-cicd.md  # CI/CD automation
└── common/
    └── locals.tf           # Account registry and shared configs
```

See these files for production-ready configuration examples and complete setup instructions.

---

## Appendix E: Repository Structure and Multi-Module Scalability

### E.1 Current Structure (Single Module)

The current `tf-aws-identity` repository is organized for managing AWS Identity Center:

```
tf-aws-identity/
├── backend.hcl              # Management account backend config (root-level)
├── common/                  # Shared constants (account IDs, regions, tags)
├── docs/                    # Documentation
├── tools/                   # Helper scripts (SSO export, etc.)
└── identity-center/         # Identity Center module
    ├── backend.tf           # Partial backend configuration
    ├── versions.tf          # Terraform and provider versions
    ├── main.tf              # Resource definitions
    ├── variables.tf         # Input variables
    └── outputs.tf           # Output values
```

**Why backend.hcl is at root:**

- Backend configuration is a repository-level concern
- Single file since Identity Center only exists in management account
- Easier to locate and manage

**Deployment workflow:**

```bash
cd identity-center/
terraform init -backend-config=../backend.hcl
terraform plan
terraform apply
```

### E.2 Scaling to Multiple Modules

**Scenario:** You want to add IAM policies, VPC peering, or other AWS resources to the same repository.

**Recommended Structure: Flat Multi-Module**

```
tf-aws-identity/
├── backend-dev.hcl
├── backend-prod.hcl
├── BACKEND_SETUP.md
├── WORKFLOW.md
├── identity-center/          # Module 1
│   ├── backend.tf
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
├── iam-policies/             # Module 2
│   ├── backend.tf
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
└── boundary-policies/        # Module 3
    ├── backend.tf
    ├── main.tf
    ├── variables.tf
    └── outputs.tf
```

**Each module manages its own state file:**

```
Dev Account S3 Bucket (terraform-state-dev-471112975126):
├── identity-center/terraform.tfstate       # Separate state
├── iam-policies/terraform.tfstate          # Separate state
└── boundary-policies/terraform.tfstate     # Separate state
```

**Deployment workflow (deploy modules independently):**

```bash
# Deploy Identity Center
cd identity-center/
terraform init -backend-config=../backend-dev.hcl
terraform apply

# Deploy IAM Policies (separate state, can deploy in parallel)
cd ../iam-policies/
terraform init -backend-config=../backend-dev.hcl
terraform apply
```

**Advantages:**

- ✅ Blast radius isolation (bug in iam-policies doesn't affect identity-center)
- ✅ Independent deployment cycles
- ✅ Smaller state files (faster terraform plan)
- ✅ Team ownership (different teams can own different modules)

**Disadvantages:**

- ❌ Can't use `terraform output` from one module in another (need data sources)
- ❌ Must manage dependencies manually (deploy identity-center before iam-policies if there's a dependency)

### E.3 Alternative: Environments-First Structure

**When you have complex cross-module dependencies or want to deploy all modules together:**

```
tf-aws-identity/
├── environments/
│   ├── dev/
│   │   ├── backend.hcl
│   │   ├── terraform.tfvars       # Dev-specific variable values
│   │   └── main.tf                # Calls all modules
│   └── prod/
│       ├── backend.hcl
│       ├── terraform.tfvars       # Prod-specific variable values
│       └── main.tf                # Calls all modules
├── modules/
│   ├── identity-center/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── iam-policies/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── boundary-policies/
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
└── common/
    └── variables.tf              # Shared variables (account IDs, regions, etc.)
```

**environments/dev/main.tf:**

```hcl
module "identity_center" {
  source = "../../modules/identity-center"

  member_accounts = var.member_accounts
  role_definition_mapper = var.role_definition_mapper
}

module "iam_policies" {
  source = "../../modules/iam-policies"

  sso_instance_arn = module.identity_center.sso_instance_arn  # Cross-module reference
}

module "boundary_policies" {
  source = "../../modules/boundary-policies"

  member_accounts = var.member_accounts
}
```

**environments/dev/terraform.tfvars:**

```hcl
member_accounts = [
  "471112975126"  # Dev
]

role_definition_mapper = {
  Developer    = "arn:aws:iam::aws:policy/PowerUserAccess"
  ReadOnly     = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}
```

**Deployment workflow:**

```bash
cd environments/dev/
terraform init -backend-config=backend.hcl
terraform apply  # Deploys ALL modules together
```

**Advantages:**

- ✅ Single deployment command for all infrastructure
- ✅ Cross-module references with `module.X.output`
- ✅ Environment-specific variables in one file
- ✅ Clear separation of code (modules/) vs. config (environments/)

**Disadvantages:**

- ❌ Large blast radius (one `terraform apply` affects everything)
- ❌ Slower plan/apply times (must process all modules)
- ❌ Harder to give teams ownership of specific modules
- ❌ More complex directory structure

### E.4 Shared Variables Pattern

**Problem:** Account IDs, regions, and other constants are duplicated across modules.

**Solution 1: Root-level variables.tf (Simple)**

```
tf-aws-identity/
├── variables.tf              # Shared variables
├── identity-center/
│   └── main.tf               # Uses var.member_accounts from root
└── iam-policies/
    └── main.tf               # Uses var.member_accounts from root
```

**Root variables.tf:**

```hcl
variable "member_accounts" {
  description = "All AWS accounts in the organization"
  type = map(object({
    id     = string
    name   = string
    env    = string
  }))
  default = {
    dev = {
      id   = "471112975126"
      name = "Development"
      env  = "dev"
    }
    prod = {
      id   = "637423317953"
      name = "Production"
      env  = "prod"
    }
  }
}
```

**Modules reference:** `var.member_accounts["dev"].id`

**Solution 2: common/ directory (Enterprise)**

```
tf-aws-identity/
├── common/
│   ├── variables.tf          # Shared variable definitions
│   └── locals.tf             # Computed shared values
├── identity-center/
│   └── main.tf
└── iam-policies/
    └── main.tf
```

**common/locals.tf:**

```hcl
locals {
  # Organization-wide constants
  aws_region = "us-east-1"

  accounts = {
    dev = {
      id               = "471112975126"
      name             = "Development"
      terraform_bucket = "terraform-state-dev-471112975126"
    }
    prod = {
      id               = "637423317953"
      name             = "Production"
      terraform_bucket = "terraform-state-prod-637423317953"
    }
  }

  # Tags applied to all resources
  common_tags = {
    ManagedBy   = "Terraform"
    Repository  = "tf-aws-identity"
    CostCenter  = "Platform-Engineering"
  }
}
```

**Modules reference:**

```hcl
# In identity-center/main.tf
module "common" {
  source = "../common"
}

resource "aws_ssoadmin_permission_set" "example" {
  # ...

  tags = module.common.common_tags
}
```

**Solution 3: Environment-specific .tfvars files (Most Flexible)**

```
tf-aws-identity/
├── identity-center/
│   ├── main.tf
│   ├── variables.tf
│   ├── dev.tfvars           # Dev values
│   └── prod.tfvars          # Prod values
```

**dev.tfvars:**

```hcl
member_accounts = ["471112975126"]
environment     = "dev"
terraform_bucket = "terraform-state-dev-471112975126"
```

**Deployment:**

```bash
terraform apply -var-file=dev.tfvars
```

### E.5 Recommended Structure for Your Use Case

**For Identity Center + IAM policies in same repo:**

```
tf-aws-identity/
├── backend-dev.hcl
├── backend-prod.hcl
├── BACKEND_SETUP.md
├── WORKFLOW.md
├── NAMING_CONVENTIONS.md
├── common/
│   └── locals.tf             # Account IDs, regions, tags
├── identity-center/          # Module 1
│   ├── backend.tf
│   ├── versions.tf
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── dev.tfvars            # Dev-specific values
│   └── prod.tfvars           # Prod-specific values
└── iam-policies/             # Module 2
    ├── backend.tf
    ├── versions.tf
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    ├── dev.tfvars
    └── prod.tfvars
```

**Deployment workflow:**

```bash
# Deploy Identity Center to Dev
cd identity-center/
terraform init -backend-config=../backend-dev.hcl
terraform apply -var-file=dev.tfvars

# Deploy IAM Policies to Dev
cd ../iam-policies/
terraform init -backend-config=../backend-dev.hcl
terraform apply -var-file=dev.tfvars
```

**Why this structure:**

- ✅ Simple and clear
- ✅ Scales to 3-5 modules easily
- ✅ Shared constants in `common/`
- ✅ Independent module deployments
- ✅ Environment-specific values kept separate

### E.6 Migration Path

**Current state → Multi-module:**

1. Create `common/locals.tf`:

   ```bash
   mkdir common
   # Move shared constants there
   ```

2. Add new module directory:

   ```bash
   mkdir iam-policies
   cp identity-center/backend.tf iam-policies/
   cp identity-center/versions.tf iam-policies/
   # Create iam-policies/main.tf with new resources
   ```

3. Update backend key in new module's `backend.tf`:

   ```hcl
   # iam-policies/backend.tf
   backend "s3" {
     key = "iam-policies/terraform.tfstate"  # Different key!
   }
   ```

4. Deploy new module:
   ```bash
   cd iam-policies/
   terraform init -backend-config=../backend-dev.hcl
   terraform apply
   ```

**No downtime or state migration required** - each module manages its own state independently.

---

## Appendix F: ADR - Terraform Repository Directory Structure

### Status

**Proposed** - For implementation in `tf-aws-identity` repository

### Context

**Problem Statement:**  
As the `tf-aws-identity` repository grows beyond the initial Identity Center module to include IAM policies, boundary policies, and other AWS identity resources, we need a directory structure that:

1. Supports multiple related Terraform modules (Identity Center, IAM, etc.)
2. Provides a home for shared configuration (account IDs, regions, tags)
3. Organizes helper scripts and automation tools
4. Scales from 2 modules to 5+ modules without major refactoring
5. Remains simple enough for engineers unfamiliar with the codebase to navigate
6. Follows Terraform community best practices

**Current State:**  
Single module (`identity-center/`) with backend configs at root level. Works well for one module but doesn't provide organization for shared values or additional modules.

**Constraints:**

- Dev and Prod environments are structurally identical (same resources, different account IDs)
- Each environment deploys to a separate AWS account (471112975126 for Dev, 637423317953 for Prod)
- Team size is small (<5 engineers) - complex structures provide minimal value
- Modules have minimal interdependencies (can be deployed independently)

### Decision

**Selected Structure: Flat Multi-Module with Common Directory**

```
tf-aws-identity/
├── README.md                     # Repository overview and usage
├── backend-dev.hcl               # Dev backend configuration (root-level)
├── backend-prod.hcl              # Prod backend configuration (root-level)
├── BACKEND_SETUP.md              # Backend setup instructions
├── WORKFLOW.md                   # Daily operational procedures
├── NAMING_CONVENTIONS.md         # Coding standards
├── common/                       # Shared configuration
│   ├── locals.tf                 # Account IDs, regions, tags
│   └── README.md                 # Usage instructions
├── tools/                        # Helper scripts
│   ├── export_sso_assignments.py
│   └── README.md
├── identity-center/              # Module: Identity Center
│   ├── backend.tf
│   ├── versions.tf
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── README.md
└── iam-policies/                 # Module: IAM Policies (future)
    ├── backend.tf
    ├── versions.tf
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    └── README.md
```

**Directory Purposes:**

- **`common/`** - Organization-wide constants shared across all modules (account IDs, AWS regions, standard tags). Prevents duplication and provides single source of truth.

- **`tools/`** - Python scripts, shell utilities, and automation helpers that support Terraform operations (e.g., SSO assignment export, validation scripts).

- **`identity-center/`, `iam-policies/`, etc.** - Self-contained Terraform modules, each managing its own state file. Deploy independently, can be owned by different teams.

- **Root-level backend HCL files** - Environment-specific backend configurations apply repository-wide, not module-specific, so kept at root for visibility.

### Rationale

**Why Flat Multi-Module (not environments-first):**

Our Dev and Prod environments are structurally identical - they deploy the same resources with different account IDs. An `environments/` directory would create duplication:

```hcl
# environments/dev/main.tf and environments/prod/main.tf would be identical
module "identity_center" {
  source = "../../modules/identity-center"
  # ... identical configuration
}
```

With flat structure, we deploy the same module code with different backend configs:

```bash
# Dev
terraform init -backend-config=../backend-dev.hcl
terraform apply -var="account_id=471112975126"

# Prod
terraform init -backend-config=../backend-prod.hcl
terraform apply -var="account_id=637423317953"
```

**Why `common/` directory:**

Shared values (account IDs, regions, tags) need a canonical location. Alternatives:

- ❌ Duplicate in each module → maintenance burden, drift risk
- ❌ Root-level `variables.tf` → clutters root, doesn't scale
- ✅ `common/` directory → clear purpose, scales well, follows Terraform Registry convention

**Example `common/locals.tf`:**

```hcl
locals {
  # AWS Account Registry
  accounts = {
    dev = {
      id               = "471112975126"
      name             = "Development"
      environment      = "dev"
      terraform_bucket = "terraform-state-dev-471112975126"
    }
    prod = {
      id               = "637423317953"
      name             = "Production"
      environment      = "prod"
      terraform_bucket = "terraform-state-prod-637423317953"
    }
  }

  # Default AWS Region
  aws_region = "us-east-1"

  # Standard Resource Tags
  common_tags = {
    ManagedBy    = "Terraform"
    Repository   = "tf-aws-identity"
    CostCenter   = "Platform-Engineering"
    Compliance   = "SOC2"
  }
}
```

**Usage in modules:**

```hcl
# identity-center/main.tf
module "common" {
  source = "../common"
}

locals {
  dev_account_id = module.common.accounts["dev"].id
}

resource "aws_ssoadmin_permission_set" "example" {
  # ...
  tags = module.common.common_tags
}
```

### Alternatives Considered

#### Alternative 1: Environments-First Structure

```
tf-aws-identity/
├── environments/
│   ├── dev/
│   │   ├── backend.hcl
│   │   ├── terraform.tfvars
│   │   └── main.tf              # Calls ../modules/*
│   └── prod/
│       ├── backend.hcl
│       ├── terraform.tfvars
│       └── main.tf
└── modules/
    ├── identity-center/
    └── iam-policies/
```

**Rejected because:**

- ❌ Creates duplication (`dev/main.tf` ≈ `prod/main.tf`)
- ❌ More complex directory navigation (`cd environments/dev/` workflow)
- ❌ Larger blast radius (single `terraform apply` affects multiple modules)
- ❌ Overkill for our use case (structurally identical environments)

**Use environments-first when:** Dev and Prod have significantly different resource compositions (e.g., Prod has WAF, Dev doesn't).

#### Alternative 2: Multi-Account Directory Structure

```
tf-aws-identity/
├── accounts/
│   ├── 471112975126-dev/
│   │   └── identity-center/
│   └── 637423317953-prod/
│       └── identity-center/
└── modules/
    └── identity-center/
```

**Rejected because:**

- ❌ Account IDs in directory names are opaque (what is "471112975126"?)
- ❌ Implies different resources per account, but we deploy identical resources
- ❌ Harder to deploy same code to both accounts (different paths)
- ❌ Doesn't match our mental model (we think in modules, not accounts)

**Use accounts/ when:** Different AWS accounts deploy fundamentally different resources (e.g., Identity Center in Management Account, GuardDuty in Security Account).

#### Alternative 3: Monorepo with No Organization

```
tf-aws-identity/
├── identity-center.tf
├── iam-policies.tf
├── boundary-policies.tf
└── backend.tf
```

**Rejected because:**

- ❌ Doesn't scale beyond 2-3 resources
- ❌ Single giant state file (slow plan/apply, large blast radius)
- ❌ Can't give teams ownership of specific areas
- ❌ No place for shared configuration or tools

#### Alternative 4: Tool-Specific Directories (accounts, tools, modules, envs)

```
tf-aws-identity/
├── accounts/          # Per-account deployments
├── tools/             # Helper scripts
├── modules/           # Reusable modules
└── envs/              # Environment configs
```

**Partially accepted:**

- ✅ `tools/` - Yes, needed for scripts
- ✅ `common/` - Yes, for shared config (renamed from generic name)
- ❌ `accounts/` - No, we deploy same resources to both accounts
- ❌ `modules/` + `envs/` - No, adds complexity without benefit for identical environments

### Consequences

**Positive:**

✅ **Simple mental model** - Each directory is a deployable module  
✅ **Independent deployments** - Can deploy `identity-center` without affecting `iam-policies`  
✅ **Small blast radius** - Bug in one module doesn't affect others  
✅ **Clear ownership** - Different teams can own different modules  
✅ **Scales to 5-10 modules** - Add new directory without restructuring  
✅ **Shared constants** - `common/` prevents duplication and drift  
✅ **Tool organization** - `tools/` provides clear home for scripts  
✅ **Faster Terraform operations** - Smaller state files per module  
✅ **Easy to understand** - New engineers can navigate repository intuitively

**Negative:**

❌ **Cross-module references require data sources** - Can't use `module.X.output` directly  
❌ **Must manage deployment order manually** - If `iam-policies` depends on `identity-center`, must deploy in sequence  
❌ **Shared values in separate directory** - Requires `module "common"` import pattern  
❌ **Backend configs must specify different keys** - Each module needs unique `key` in `backend.tf`

**Neutral:**

⚪ **Module-level deployment** - `cd identity-center/ && terraform apply` (some teams prefer root-level)  
⚪ **No environment isolation at directory level** - Same code deployed to dev/prod via backend config flag  
⚪ **Requires discipline** - Team must remember to update `common/` when adding accounts

### Implementation Plan

**Phase 1: Create Core Structure**

1. Create `common/` directory with `locals.tf`
2. Create `tools/` directory and move `export_sso_assignments.py`
3. Update root README.md with new structure documentation

**Phase 2: Update Existing Module**

1. Update `identity-center/main.tf` to reference `module.common.accounts`
2. Replace hardcoded account IDs with `var.account_id`
3. Add `common/` module import

**Phase 3: Add Second Module (Future)**

1. Create `iam-policies/` directory
2. Copy boilerplate from `identity-center/` (backend.tf, versions.tf)
3. Update backend key to `iam-policies/terraform.tfstate`
4. Implement IAM-specific resources

**Phase 4: Documentation**

1. Add README.md to each directory explaining purpose
2. Update WORKFLOW.md with multi-module deployment examples
3. Create CONTRIBUTING.md with structure conventions

### Validation Criteria

This decision is successful if:

- [ ] New engineer can add a module without asking for structure guidance
- [ ] Adding a new AWS account requires changing only `common/locals.tf`
- [ ] Each module can be deployed independently in <5 minutes
- [ ] Cross-team ownership of modules is clear and documented
- [ ] Repository scales to 5+ modules without restructuring
- [ ] Shared configuration changes propagate to all modules automatically
- [ ] Helper scripts are discoverable in `tools/` directory

### References

- [Terraform Style Guide - Module Structure](https://developer.hashicorp.com/terraform/language/modules/develop/structure)
- [Gruntwork Terraform Best Practices](https://docs.gruntwork.io/guides/style/terraform-style-guide/)
- [Azure Landing Zones - Terraform Structure](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/design-area/terraform-code-structure)

### Review Date

**6 months post-implementation** - Evaluate if structure scales as expected or if migration to environments-first is needed.
