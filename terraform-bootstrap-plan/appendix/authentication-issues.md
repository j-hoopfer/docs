# Appendix: Authentication Issues

Common authentication problems when working with Terraform and AWS SSO.

## Problem: InvalidToken Error

**Symptom:**

```
Error: error configuring Terraform AWS Provider: error validating provider credentials:
retrieving caller identity from STS: operation error STS: GetCallerIdentity, https response
error StatusCode: 403, InvalidClientTokenId: The security token included in the request is invalid
```

**Root Cause:**

Terraform is using expired or incorrect AWS credentials from the `[default]` profile instead of your active SSO profile.

## Why This Happens

When you run Terraform without specifying a profile, it looks for credentials in this order:

1. Environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`)
2. Credentials file `~/.aws/credentials` under `[default]`
3. IAM instance profile (if running on EC2)

**The Problem:** If you have old, expired credentials in `[default]`, Terraform uses those instead of your SSO profile.

## Solution 1: Set AWS_PROFILE Environment Variable (Recommended)

```bash
export AWS_PROFILE=mycompany-dev
aws sso login
terraform plan
```

**Make it permanent** (add to `~/.zshrc` or `~/.bash_profile`):

```bash
echo 'export AWS_PROFILE=mycompany-dev' >> ~/.zshrc
source ~/.zshrc
```

## Solution 2: Remove [default] Credentials

```bash
# Backup first
cp ~/.aws/credentials ~/.aws/credentials.backup

# Edit file to remove [default] section
vim ~/.aws/credentials
# Or delete the entire file if you only use SSO
rm ~/.aws/credentials
```

## Solution 3: Configure Profile in providers.tf

```hcl
provider "aws" {
  region  = var.primary_region
  profile = "mycompany-dev"  # Explicit profile
}
```

**Downside:** Hardcoded profile makes it harder to switch accounts.

## Verification

```bash
# Check which credentials are active
aws sts get-caller-identity

# Should show your SSO user/role, not old IAM user
```

**Expected output:**

```json
{
  "UserId": "AROAEXAMPLE:user@company.com",
  "Account": "123456789012",
  "Arn": "arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_AdministratorAccess_abc123/user@company.com"
}
```

**Bad output (expired default credentials):**

```
An error occurred (InvalidClientTokenId) when calling the GetCallerIdentity operation:
The security token included in the request is invalid.
```

## Complete Troubleshooting Workflow

```bash
# 1. Check current credentials
aws sts get-caller-identity

# 2. If error, check what's in credentials file
cat ~/.aws/credentials

# 3. Set SSO profile
export AWS_PROFILE=mycompany-dev

# 4. Login to SSO
aws sso login

# 5. Verify correct identity
aws sts get-caller-identity

# 6. Now run Terraform
terraform plan
```

## Prevention for Teams

**If multiple team members encounter this:**

**1. Document SSO setup in README:**

````markdown
## AWS Authentication

This project uses AWS SSO. **Do not** use `[default]` credentials.

### Initial Setup

```bash
# Configure SSO
aws configure sso

# Set default profile
echo 'export AWS_PROFILE=mycompany-dev' >> ~/.zshrc
source ~/.zshrc
```
````

### Daily Workflow

```bash
# Login when session expires (typically every 8-12 hours)
aws sso login

# Verify authentication
aws sts get-caller-identity
```

**2. Add to onboarding checklist:**

- [ ] Install AWS CLI v2
- [ ] Run `aws configure sso` with MyCompany SSO URL
- [ ] Add `export AWS_PROFILE=mycompany-dev` to shell profile
- [ ] Remove any `[default]` credentials from `~/.aws/credentials`
- [ ] Test: `aws sts get-caller-identity` should show your identity

**3. Common troubleshooting:**

| Symptom                                        | Cause                           | Solution                             |
| ---------------------------------------------- | ------------------------------- | ------------------------------------ |
| `InvalidToken` error                           | Expired `[default]` credentials | Set `AWS_PROFILE=mycompany-dev`      |
| `ExpiredToken` error                           | SSO session expired             | Run `aws sso login`                  |
| `AccessDenied` error                           | Using wrong profile/account     | Verify `aws sts get-caller-identity` |
| Commands work with `--profile` but not without | `AWS_PROFILE` not set           | `export AWS_PROFILE=mycompany-dev`   |

## Why This Happens to Teams Migrating to SSO

Many teams initially used IAM users with static access keys stored in the `[default]` profile:

```ini
[default]
aws_access_key_id=AKIA...
aws_secret_access_key=...
```

When migrating to AWS SSO:

1. SSO profiles are configured (`mycompany-dev`, `mycompany-prod`, etc.)
2. Old `[default]` credentials remain in the file
3. Those credentials eventually expire (especially if they were temporary)
4. Commands without `--profile` flag still try to use expired `[default]`

**Solution:** Clean up old credentials and standardize on SSO profiles across the team.
