# Management Account Access Strategy

Best practices for managing access to the AWS Management Account where Identity Center resides.

---

## TL;DR

**Recommended Approach:**

- ✅ Include Management Account in `member_accounts` variable
- ✅ Use Identity Center for regular access (even to Management Account)
- ✅ Keep 1 break-glass IAM user for emergencies only
- ✅ Minimize long-lived credentials

---

## Understanding the Bootstrap Problem

Since Identity Center lives in the Management Account, there's a chicken-and-egg problem:

```
Question: How do you use Identity Center to access the account
          that hosts Identity Center itself?

Answer: Bootstrap with temporary credentials, then switch to SSO.
```

---

## Recommended Strategy: Hybrid Approach

### Phase 1: Initial Setup (Temporary IAM Credentials)

**Use IAM credentials ONLY for initial Terraform deployment:**

1. Create temporary IAM user with admin permissions
2. Run Terraform to create Identity Center configuration
3. Terraform creates SSO access to ALL accounts (including Management Account)
4. Delete temporary IAM user

```terraform
# variables.tf - Include Management Account
variable "member_accounts" {
  default = [
    "123456789012",  # Management Account ← Include this!
    "471112975126",  # Dev Account
    "637423317953"   # Prod Account
  ]
}
```

### Phase 2: Ongoing Operations (Identity Center)

**Switch to SSO for all access:**

```bash
# Engineers use SSO to access Management Account
aws sso login --profile management-sso

# Run Terraform using SSO credentials
cd identity-center/
terraform plan
terraform apply
```

### Phase 3: Emergency Access (Break-Glass IAM User)

**Keep 1 IAM user for true emergencies:**

- Stored in password vault (1Password, CyberArk, etc.)
- MFA enabled
- Only used if Identity Center is completely broken
- Credentials rotated annually
- Never used for daily operations

**IAM User Policy:**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "*",
      "Resource": "*",
      "Condition": {
        "Bool": {
          "aws:MultiFactorAuthPresent": "true"
        }
      }
    }
  ]
}
```

---

## Configuration Example

### Include Management Account in Variables

```terraform
# identity-center/variables.tf
variable "member_accounts" {
  description = "List of AWS Account IDs to manage SSO access for (include Management Account)"
  type        = set(string)

  default = [
    "123456789012",  # Management Account - recommended to include
    "471112975126",  # Dev Account
    "637423317953"   # Prod Account
  ]
}
```

### Restrict Management Account Access

Only allow a small admin group access to the Management Account:

```terraform
# Create Google groups:
# - AWS-123456789012-Admin (5 people max)
# - AWS-471112975126-Admin (dev team)
# - AWS-637423317953-Admin (ops team)
```

---

## Security Best Practices

### ✅ Do This

- Include Management Account in Identity Center
- Use SSO for all regular access
- Keep 1 break-glass IAM user in secure vault
- Require MFA on break-glass IAM user
- Rotate break-glass credentials annually
- Audit break-glass usage immediately
- Limit Management Account SSO group to 3-5 people

### ❌ Don't Do This

- ❌ Keep multiple IAM users for "convenience"
- ❌ Use IAM access keys for daily operations
- ❌ Store IAM credentials in plain text
- ❌ Give everyone access to Management Account
- ❌ Skip MFA on break-glass accounts
- ❌ Leave temporary bootstrap IAM users active

---

## Bootstrap Process (Step-by-Step)

### Step 1: Initial Setup with Temporary IAM User

```bash
# Create temporary IAM user in Management Account (via AWS Console)
# User: terraform-bootstrap
# Permissions: AdministratorAccess (temporary)
# MFA: Enabled

# Configure temporary credentials
aws configure --profile terraform-bootstrap
# Enter Access Key ID
# Enter Secret Access Key

# Verify you're in Management Account
aws sts get-caller-identity --profile terraform-bootstrap
```

### Step 2: Deploy Identity Center via Terraform

```bash
cd identity-center/

# Ensure Management Account is included in variables.tf
# member_accounts = ["123456789012", "471112975126", "637423317953"]

# Initialize and deploy
export AWS_PROFILE=terraform-bootstrap
terraform init
terraform plan
terraform apply
```

### Step 3: Verify SSO Access

```bash
# Configure SSO in AWS CLI
aws configure sso
# SSO start URL: https://your-org.awsapps.com/start
# SSO region: us-east-1
# Select Management Account
# Select AdministratorAccess role
# CLI profile name: management-sso

# Test SSO access
aws sts get-caller-identity --profile management-sso
```

### Step 4: Switch to SSO for Terraform

```bash
# Use SSO credentials for future Terraform runs
export AWS_PROFILE=management-sso

cd identity-center/
terraform plan
terraform apply
```

### Step 5: Clean Up Bootstrap User

```bash
# In AWS Console:
# 1. Delete IAM access keys for terraform-bootstrap user
# 2. Delete terraform-bootstrap IAM user
# 3. Create break-glass IAM user (stored in vault, emergency only)
```

---

## Break-Glass IAM User Setup

**Create ONE emergency-only IAM user:**

```bash
# In Management Account AWS Console:
# 1. IAM → Users → Create User
#    Name: break-glass-admin
#    AWS credential type: Password only (no access keys)
#
# 2. Attach policy: AdministratorAccess
#
# 3. Security:
#    - Enable MFA (virtual MFA device)
#    - Set strong password (20+ characters)
#
# 4. Store in vault:
#    - Password → 1Password/CyberArk
#    - MFA seed → Vault (separate entry)
#
# 5. Document usage policy:
#    - Only use if Identity Center is broken
#    - Log all usage
#    - Rotate credentials after use
```

**Break-Glass Usage Policy:**

1. Identity Center must be completely unavailable
2. At least 2 team members aware of usage
3. Create incident ticket documenting reason
4. Rotate credentials immediately after use
5. Review all actions taken during break-glass access

---

## Alternative: External Identity Provider

If you have Okta, Azure AD, or another enterprise IdP, you can:

1. Federate Management Account IAM directly to your IdP
2. Skip IAM users entirely (except break-glass)
3. Use SAML federation for emergency access

This eliminates long-lived credentials completely.

---

## FAQ

**Q: Can I exclude the Management Account from member_accounts?**

A: Yes, but not recommended. You'd need IAM users for all Management Account access, which increases long-lived credential exposure.

**Q: How many people should have Management Account access?**

A: 3-5 senior engineers maximum. Use a restrictive Google Group like `AWS-Admins` (not tied to account ID).

**Q: What if Identity Center breaks during deployment?**

A: Use break-glass IAM user to access console and fix. This is the only scenario it should be used.

**Q: Should I give developers access to Management Account?**

A: No. Management Account should be restricted to platform/infrastructure team only.

**Q: Can I use AWS CLI with SSO?**

A: Yes! `aws configure sso` sets up SSO profiles. All aws commands work with `--profile` flag.

**Q: What about CI/CD pipelines?**

A: Use OIDC federation (GitHub Actions, GitLab CI) or short-lived credentials via STS AssumeRole. Never use IAM access keys.

---

## Monitoring and Auditing

### CloudTrail Alerts

Set up alerts for:

- Break-glass IAM user login
- Any IAM access key usage in Management Account
- Identity Center configuration changes
- Permission set modifications

### Sample CloudWatch Alarm

```bash
# Alert on break-glass IAM user usage
aws cloudwatch put-metric-alarm \
  --alarm-name BreakGlassUserLogin \
  --alarm-description "Alert when break-glass IAM user logs in" \
  --metric-name UserLogin \
  --namespace AWS/IAM \
  --statistic Sum \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold
```

---

## Summary

**Best Practice Architecture:**

```
Management Account Access Strategy
│
├── Regular Access (99% of time)
│   └── Identity Center SSO
│       ├── aws-admins@company.com → AdministratorAccess
│       └── Limited to 3-5 senior engineers
│
├── Bootstrap Access (one-time only)
│   └── Temporary IAM user
│       ├── Created for initial Terraform deployment
│       └── Deleted after SSO is configured
│
└── Emergency Access (break-glass only)
    └── 1 IAM user
        ├── Stored in password vault
        ├── MFA enabled
        ├── Rotated annually
        └── Audited immediately on usage
```

**Security Principles:**

1. **Minimize long-lived credentials** - SSO provides temporary credentials
2. **Least privilege** - Restrict Management Account access to essential personnel
3. **Defense in depth** - Break-glass exists but is rarely (ideally never) used
4. **Audit everything** - CloudTrail logs all access, alert on IAM usage

---

## Related Documentation

- [Backend Setup](backend-setup.md) - One-time S3/DynamoDB setup
- [Daily Workflow](daily-workflow.md) - How to deploy changes safely
- [GitHub Actions CI/CD](github-actions-cicd.md) - OIDC federation for pipelines
