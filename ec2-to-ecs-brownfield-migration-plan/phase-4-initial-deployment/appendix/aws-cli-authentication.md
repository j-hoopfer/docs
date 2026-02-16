# AWS CLI Authentication Methods

## Overview

The AWS CLI supports multiple authentication methods for human users. Understanding the tradeoffs is critical for security and compliance.

---

## Method 1: Long-Lived Access Keys (`aws configure`)

**How it works:**

```bash
aws configure
AWS Access Key ID [None]: AKIAIOSFODNN7EXAMPLE
AWS Secret Access Key [None]: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
Default region name [None]: us-east-1
Default output format [None]: json
```

This creates `~/.aws/credentials`:

```ini
[default]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
```

**Security risks:**

| Risk                      | Impact                                                              |
| ------------------------- | ------------------------------------------------------------------- |
| **Never expire**          | Keys work forever unless manually rotated                           |
| **Leakage**               | Often committed to Git, exposed in logs, screenshots, .bash_history |
| **Laptop theft**          | Stolen laptop = full AWS account access                             |
| **Shared keys**           | Team shares one key = impossible to audit individual actions        |
| **Former employees**      | Keys still work months after employee leaves                        |
| **Compliance violations** | Fails SOC2, ISO27001, PCI-DSS for long-lived credentials            |

**Real-world incidents:**

- **GitHub leak**: Developer commits AWS keys to public repo → $50K bill from crypto miners within 4 hours
- **Laptop theft**: Stolen MacBook with `.aws/credentials` → attacker spins up 200 EC2 instances for Bitcoin mining
- **Former employee**: Person leaves company, access key still works 6 months later, used to exfiltrate customer data
- **Log exposure**: Access key printed in application logs, scraped by automated scanners

**When to use:** **NEVER for human users.** Only for CI/CD systems (GitHub Actions, CircleCI) or Lambda functions where temporary credentials aren't available.

**Recommendation:** 🚫 **Do not use for team access.**

---

## Method 2: Temporary Session Tokens (`aws configure` with MFA)

**How it works:**

You can generate temporary credentials (valid for 12 hours) using your access keys + MFA device:

```bash
# Step 1: Get session token with MFA
aws sts get-session-token \
  --serial-number arn:aws:iam::123456789012:mfa/your-username \
  --token-code 123456

# Output:
{
  "Credentials": {
    "AccessKeyId": "ASIAIOSFODNN7EXAMPLE",
    "SecretAccessKey": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    "SessionToken": "FwoGZXIvYXdzEBYaDH...",
    "Expiration": "2024-01-27T10:30:00Z"
  }
}

# Step 2: Configure temporary credentials
aws configure set aws_access_key_id ASIAIOSFODNN7EXAMPLE --profile temp
aws configure set aws_secret_access_key wJalrXUtnFEMI/K7MDENG/... --profile temp
aws configure set aws_session_token FwoGZXIvYXdzEBYaDH... --profile temp

# Step 3: Use temporary profile
aws sts get-caller-identity --profile temp
```

**This creates in `~/.aws/credentials`:**

```ini
[temp]
aws_access_key_id = ASIAIOSFODNN7EXAMPLE
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
aws_session_token = FwoGZXIvYXdzEBYaDH...
```

**Improvements over long-lived keys:**

| Aspect           | Long-Lived Keys              | Temporary Session Tokens              |
| ---------------- | ---------------------------- | ------------------------------------- |
| **Expiration**   | ⚠️ Never                     | ✅ 12 hours (configurable 1-36 hours) |
| **MFA Required** | ⚠️ No                        | ✅ Yes (enforces second factor)       |
| **Leakage Risk** | ⚠️ HIGH - keys valid forever | ⚠️ MEDIUM - tokens expire in hours    |

**Remaining problems:**

- Still requires managing base IAM user with long-lived access keys
- Manual process every 12 hours (not automated like SSO)
- Still stores credentials in `~/.aws/credentials` file (can be leaked)
- Harder to revoke instantly (must disable base IAM user)
- No centralized audit trail of which specific person took actions (IAM user name ≠ person name)

**When to use:** Better than long-lived keys, but still not recommended. Use SSO instead.

**Recommendation:** ⚠️ **Use only if SSO is not available** (e.g., AWS GovCloud regions without SSO support, legacy accounts).

---

## Method 3: IAM Identity Center (AWS SSO) - RECOMMENDED

**How it works:**

```bash
# One-time setup
aws configure sso
SSO session name: fargate-migration
SSO start URL: https://d-abc123xyz.awsapps.com/start
SSO region: us-east-1

# Daily usage
aws sso login --profile fargate-migration
# Browser opens → Enter SSO credentials → MFA → Done

# Token auto-refreshes every 8 hours
```

This creates `~/.aws/config`:

```ini
[profile fargate-migration]
sso_session = fargate-migration
sso_account_id = 123456789012
sso_role_name = AdministratorAccess
region = us-east-1

[sso-session fargate-migration]
sso_start_url = https://d-abc123xyz.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access
```

**Comparison to other methods:**

| Aspect                 | Long-Lived Keys                   | Session Tokens                    | SSO (RECOMMENDED)                              |
| ---------------------- | --------------------------------- | --------------------------------- | ---------------------------------------------- |
| **Credential Type**    | Permanent access keys             | Temporary session tokens          | Temporary OIDC tokens                          |
| **Expiration**         | ⚠️ Never                          | ⚠️ 12 hours (manual renewal)      | ✅ 8 hours (auto-renewal)                      |
| **Credential Storage** | ⚠️ `~/.aws/credentials` file      | ⚠️ `~/.aws/credentials` file      | ✅ Encrypted cache (no plaintext keys)         |
| **MFA Required**       | ⚠️ No                             | ⚠️ Yes (manual)                   | ✅ Yes (integrated)                            |
| **Revocation Speed**   | ⚠️ Slow (find and delete key)     | ⚠️ Medium (disable IAM user)      | ✅ Instant (disable SSO user)                  |
| **Audit Trail**        | ⚠️ Limited (IAM user name)        | ⚠️ Limited (IAM user name)        | ✅ Full (CloudTrail shows real person's email) |
| **Laptop Theft Risk**  | ⚠️ CRITICAL - permanent access    | ⚠️ HIGH - 12 hour window          | ✅ LOW - tokens expire automatically           |
| **GitHub Leak Risk**   | ⚠️ CRITICAL - keys valid forever  | ⚠️ MEDIUM - tokens expire         | ✅ LOW - no keys to leak                       |
| **Compliance**         | ❌ Fails SOC2/ISO27001/PCI-DSS    | ⚠️ Partial compliance             | ✅ Meets compliance standards                  |
| **Former Employee**    | ⚠️ Keys work until manually found | ⚠️ Base IAM user must be disabled | ✅ Disable SSO = all sessions end              |
| **Team Sharing**       | ⚠️ Common (security nightmare)    | ⚠️ Possible (still bad)           | ✅ Impossible (tied to individual)             |
| **Setup Complexity**   | ✅ Simple (2 minutes)             | ⚠️ Medium (5 minutes + scripting) | ⚠️ Medium (10 minutes one-time)                |
| **Daily UX**           | ✅ No action needed               | ⚠️ Manual every 12 hours          | ✅ Browser popup every 8 hours                 |

**Why SSO is superior:**

1. **No plaintext credentials** - Tokens stored in encrypted cache, not `~/.aws/credentials`
2. **Automatic expiration** - Tokens expire every 8 hours, forcing re-auth
3. **MFA built-in** - Can't bypass, no manual token generation
4. **Instant revocation** - Disable user in SSO portal → all sessions end immediately
5. **Real-person audit trails** - CloudTrail logs show `jane.doe@company.com`, not generic `deploy-user`
6. **Zero standing privileges** - Users only have access while actively logged in
7. **Centralized management** - Add/remove users, change permissions in one place

**When to use:** **Always for human team access.** This is AWS's recommended best practice.

**Recommendation:** ✅ **Use SSO for all team members.**

---

## Method 4: EC2 Instance Profiles / ECS Task Roles

**How it works:**

For applications running on AWS (EC2, ECS, Lambda), use **IAM roles** instead of any credential method above.

```bash
# No configuration needed!
# AWS SDK automatically discovers role from instance metadata

# Python example
import boto3
s3 = boto3.client('s3')  # Automatically uses task role
s3.list_buckets()
```

**How it works under the hood:**

1. ECS task starts with `taskRoleArn` specified in task definition
2. AWS injects temporary credentials into task environment
3. AWS SDK reads credentials from task metadata endpoint
4. Credentials auto-rotate every hour (invisible to application)

**Benefits:**

- ✅ Zero credential management
- ✅ Automatic rotation (hourly)
- ✅ Scoped permissions per service
- ✅ No keys to leak
- ✅ Works seamlessly in containers

**When to use:** **Always for applications running in AWS.**

**Recommendation:** ✅ **Use IAM roles for ECS tasks, Lambda functions, EC2 instances.**

---

## Summary: Which Method to Use

| Scenario                            | Recommended Method              | Why                                       |
| ----------------------------------- | ------------------------------- | ----------------------------------------- |
| **Team developer workstation**      | ✅ IAM Identity Center (SSO)    | Security, compliance, instant revocation  |
| **CI/CD pipeline (GitHub Actions)** | ✅ OIDC (federated identity)    | No long-lived keys, automatic rotation    |
| **ECS Fargate task**                | ✅ Task Role (IAM role)         | Zero credential management, auto-rotation |
| **EC2 instance**                    | ✅ Instance Profile (IAM role)  | Zero credential management, auto-rotation |
| **Lambda function**                 | ✅ Execution Role (IAM role)    | Zero credential management, auto-rotation |
| **Legacy CI/CD without OIDC**       | ⚠️ Access keys in secrets vault | Last resort - rotate every 90 days        |
| **GovCloud without SSO**            | ⚠️ Temporary session tokens     | Better than permanent keys                |
| **Root user**                       | 🚫 NEVER use access keys        | MFA only, emergency use only              |

---

## Migration Path from Access Keys to SSO

If your team currently uses access keys:

**Week 1: Prepare**

1. Enable IAM Identity Center
2. Create SSO users for team
3. Assign appropriate permission sets

**Week 2: Parallel Run**

1. Team configures SSO profiles alongside existing keys
2. Test SSO access works
3. Document any issues

**Week 3: Cutover**

1. Team switches to using SSO for all operations
2. Monitor for issues

**Week 4: Cleanup**

1. Delete all IAM user access keys
2. Disable IAM users (keep for emergency)
3. Update documentation

**Emergency Rollback:**

- Keep IAM users disabled but not deleted for 30 days
- If SSO has issues, re-enable IAM user temporarily
