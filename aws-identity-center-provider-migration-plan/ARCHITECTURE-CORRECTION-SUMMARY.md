# Architecture Correction Summary

## Critical Understanding

**AWS Identity Center is a GLOBAL service** - there is exactly ONE instance per AWS Organization.

### What Was Wrong

Previous documentation incorrectly implied:

- Separate Identity Center instances for Dev and Prod accounts
- Multiple backend configurations (`backend-dev.hcl`, `backend-prod.hcl`)
- "Deploy to Dev" and "Deploy to Prod" workflows
- Testing changes in a "dev Identity Center"

### What Is Correct

**Reality:**

- ONE Identity Center instance in the AWS Organization Management Account
- Identity Center manages SSO access to ALL accounts:
  - **Management** (Billing/SSO)
  - **Network** (VPC/TGW)
  - **Dev** (Workloads)
  - **Prod** (Workloads)
- ONE Terraform backend in the Management Account
- ONE `backend.hcl` configuration file
- ALL changes affect production (no separate test instance)

### Architecture Diagram

```
AWS Organization
├── Management Account (MGMT-ACCT-ID)
│   ├── Identity Center Instance ← GLOBAL (only one)
│   │   ├── Manages SSO to Network Account
│   │   ├── Manages SSO to Dev Account
│   │   └── Manages SSO to Prod Account
│   │
│   ├── S3: terraform-state-identity-center-MGMT-ACCT-ID
│   └── DynamoDB: terraform-state-locks
│
├── Network Account (NET-ACCT-ID)
│   └── Receives SSO access from Identity Center (NetworkAdmin)
│
├── Dev Account (471112975126)
│   └── Receives SSO access from Identity Center
│
└── Prod Account (637423317953)
    └── Receives SSO access from Identity Center
```

## Files Updated

### 1. Backend Configuration

- **Deleted:** `backend-dev.hcl`, `backend-prod.hcl`
- **Created:** `backend.hcl` (points to management account)
- **Location:** `/tf-aws-identity/backend.hcl`

### 2. Documentation Updates

- `aws-identity-center-provider-migration/ARCHITECTURE_PLAN.md`
  - **Appendix D:** Complete rewrite for single backend strategy
  - **Added D.8:** Testing strategy for global services
  - **Updated D.9-D.10:** Cost and migration guidance

- `tf-aws-identity/docs/backend-setup.md`
  - Complete rewrite for management account only
  - Removed dev/prod account setup sections
  - Updated IAM permissions and verification steps

### 3. Files Still Requiring Updates

- `tf-aws-identity/docs/daily-workflow.md` - Remove environment switching
- `tf-aws-identity/docs/github-actions-cicd.md` - Fix workflows for single backend
- `tf-aws-identity/docs/tools-guide.md` - Update examples
- `aws-identity-center-provider-migration/BACKEND_SETUP.md` - Align with tf-aws-identity docs
- `tf-aws-identity/docs/what-goes-where.md` - Update backend file references

## Testing Strategy

Since Identity Center is global, testing strategies include:

1. **Code Review:** All changes through PRs with required approvals
2. **Terraform Plan:** Detailed inspection of `terraform plan` output
3. **Manual Approval:** GitHub Actions environments with human gates
4. **Incremental Rollout:** Add new resources, test with pilot group, remove old
5. **State Versioning:** S3 versioning enabled for rollback capability

## When Separate AWS Organizations Make Sense

Almost never. Only consider if:

- Regulatory mandate (e.g., FedRAMP vs commercial)
- 1000+ AWS accounts (unacceptable blast radius)
- Testing AWS Organizations structure changes
- Multi-tenant SaaS (isolated Identity Center per customer)

**Why it's usually wrong:**

- 2× management overhead (SAML, SCIM, permission sets)
- Can't test realistically (different Org/Account IDs)
- Expensive (double all AWS accounts and monitoring)
- User confusion (which SSO portal?)

## Migration Path

If you have existing `backend-dev.hcl` and `backend-prod.hcl`:

1. Identify which state file is authoritative (likely the most recently updated)
2. Export state: `terraform state pull > backup.json`
3. Create management account backend resources
4. Update `backend.hcl` with management account details
5. Re-initialize: `terraform init -backend-config=backend.hcl -reconfigure`
6. Verify: `terraform plan` should show no changes
