# AWS Identity Center Federation with Google Workspace

Complete migration plan for transitioning AWS authentication from internal directory to Google Workspace SSO.

## 📁 Repository Structure

```
aws-identity-center-provider-migration/
├── ARCHITECTURE_PLAN.md           # Strategic overview for leadership
├── IMPLEMENTATION_RUNBOOK.md      # Step-by-step guide for engineers
├── README.md                      # This file
├── scripts/
│   └── export_sso_assignments.py  # Pre-migration backup utility
├── terraform/
│   ├── backend.tf                 # S3 backend configuration
│   ├── versions.tf                # Provider version constraints
│   ├── variables.tf               # Customizable inputs
│   ├── main.tf                    # Core SSO assignment logic
│   └── outputs.tf                 # Useful output values
├── testing/
│   └── acceptance_tests.md        # Comprehensive test cases
└── backups/
    └── (CSV exports stored here)
```

## 🚀 Quick Start

### For Architects / Leadership

Read: [`ARCHITECTURE_PLAN.md`](ARCHITECTURE_PLAN.md)

- Strategic value proposition
- Risk mitigation strategy
- Scalability benefits

### For Implementation Team

Read: [`IMPLEMENTATION_RUNBOOK.md`](IMPLEMENTATION_RUNBOOK.md)

- Detailed step-by-step instructions
- Command-line examples
- Troubleshooting guides

### For QA / Validation

Read: [`testing/acceptance_tests.md`](testing/acceptance_tests.md)

- 20 comprehensive test cases
- Copy-paste verification commands
- Pass/fail criteria

## 📋 Prerequisites

Before starting, ensure you have:

- [ ] Google Workspace Business Standard or Enterprise
- [ ] AWS Organization with Identity Center enabled
- [ ] Management Account root access
- [ ] Terraform >= 1.0
- [ ] Python 3.8+ with boto3
- [ ] 1-hour maintenance window scheduled

## 🔧 Key Components

### 1. Pre-Migration Backup Script

```bash
cd scripts/
python3 export_sso_assignments.py > ../backups/backup_$(date +%Y%m%d).csv
```

### 2. Terraform Infrastructure

```bash
cd terraform/
terraform init
terraform plan
terraform apply
```

### 3. Testing Suite

```bash
# See testing/acceptance_tests.md for detailed test cases
```

## 🏗️ Architecture Highlights

### Dynamic Account-Centric Pattern

**Adding a new AWS account:**

```hcl
variable "member_accounts" {
  default = [
    "471112975126",  # Dev
    "637423317953",  # Prod
    "999888777666"   # NEW: Just add this line!
  ]
}
```

**That's it!** Terraform automatically:

1. Looks up Google group: `AWS-999888777666-Admin`
2. Creates permission set assignments
3. Configures access for all defined roles

### Google Group Naming Convention

**Format:** `AWS-<AccountID>-<Role>`

**Examples:**

- `AWS-471112975126-Admin` → Dev account with AdministratorAccess
- `AWS-637423317953-RO` → Prod account with ViewOnlyAccess
- `AWS-Finance-Billing` → Cross-account billing access

## 🛡️ Security Features

1. **MFA Enforcement:** Google Workspace 2SV required at login
2. **Root Account Lockdown:** SCPs deny root user in member accounts
3. **CloudWatch Alerts:** Immediate notification on root usage
4. **Terraform Audit Trail:** All permission changes in Git history
5. **SCIM Auto-Provisioning:** Real-time sync of Google groups to AWS

## ⏱️ Timeline

| Phase            | Duration    | Effort           |
| ---------------- | ----------- | ---------------- |
| Root Governance  | 2 hours     | 3 eng hours      |
| Migration Prep   | 4 hours     | 6 eng hours      |
| Google Config    | 2 days      | 12 eng hours     |
| Cutover          | 1 hour      | 2 eng hours      |
| Terraform Deploy | 30 mins     | 4 eng hours      |
| Validation       | 2 days      | 8 eng hours      |
| **TOTAL**        | **~1 week** | **35 eng hours** |

## 🆘 Emergency Contacts

| Issue            | Contact                     | Response Time |
| ---------------- | --------------------------- | ------------- |
| Google Workspace | workspace-admin@company.com | 1 hour        |
| AWS Access       | aws-admin@company.com       | 30 mins       |
| Terraform        | infra-team@company.com      | 2 hours       |
| **Emergency**    | oncall@company.com          | 15 mins       |

## 📊 Success Metrics

- ✅ 100% of users authenticate via Google SSO
- ✅ Zero manual IAM user credentials
- ✅ MFA enabled for all users
- ✅ All permission changes tracked in Git
- ✅ New account onboarding < 5 minutes

## 🔄 Rollback Plan

**If migration fails:**

1. Login as `migration-admin` (emergency IAM user)
2. IAM Identity Center → Change identity source → Identity Center directory
3. Restore assignments from CSV backup
4. Notify stakeholders

**RTO:** 15 minutes

## 📚 Additional Resources

- [AWS Identity Center Documentation](https://docs.aws.amazon.com/singlesignon/latest/userguide/)
- [Google Workspace SAML Configuration](https://support.google.com/a/answer/6087519)
- [Terraform AWS Provider Docs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)

## 📝 License

Internal use only - [Company Name]

---

**Last Updated:** 2026-02-04  
**Version:** 1.0  
**Maintained By:** DevOps Team
