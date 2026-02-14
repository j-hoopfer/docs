# Appendix: AWS Authentication and Security

## Overview

This appendix provides comprehensive guidance on AWS authentication methods, security best practices, and IAM configuration for both human users and automated systems (CI/CD).

**Use this appendix when:**

- Setting up AWS CLI access for team members
- Choosing between access keys, session tokens, and SSO
- Configuring GitHub Actions OIDC authentication
- Understanding security tradeoffs of different authentication methods
- Implementing least-privilege IAM policies

---

## Table of Contents

1. [AWS CLI Authentication Methods](#aws-cli-authentication-methods)
2. [Authentication: GitHub Actions OIDC with AWS](#authentication-github-actions-oidc-with-aws)
3. [Security Hardening Checklist](#security-hardening-checklist)

---

## AWS CLI Authentication Methods

### Overview

The AWS CLI supports multiple authentication methods for human users. Understanding the tradeoffs is critical for security and compliance.

---

### Method 1: Long-Lived Access Keys (`aws configure`)

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

### Method 2: Temporary Session Tokens (`aws configure` with MFA)

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

### Method 3: IAM Identity Center (AWS SSO) - RECOMMENDED

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

### Method 4: EC2 Instance Profiles / ECS Task Roles

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

### Summary: Which Method to Use

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

### Migration Path from Access Keys to SSO

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

---

## Authentication: GitHub Actions OIDC with AWS

### Why OIDC Over Access Keys

| Aspect               | IAM Access Keys                 | OIDC (Recommended)                 |
| -------------------- | ------------------------------- | ---------------------------------- |
| **Rotation**         | Manual, painful                 | Automatic (token per run)          |
| **Exposure Risk**    | Key leak = permanent access     | Token expires in minutes           |
| **Audit Trail**      | Hard to trace which repo/branch | CloudTrail shows exact repo/branch |
| **Setup Complexity** | Easier initially                | More setup, better long-term       |
| **Compliance**       | Often prohibited                | Industry standard                  |

### Implementation Steps

#### Step 1: Create OIDC Identity Provider (One-Time Setup)

```bash
# Via AWS Console:
# IAM → Identity Providers → Add Provider
# - Provider Type: OpenID Connect
# - Provider URL: https://token.actions.githubusercontent.com
# - Audience: sts.amazonaws.com

# Via AWS CLI:
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

#### Step 2: Create IAM Role (Initial: Shared Role)

**For your first 1-3 services**, use a single shared role:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:my-org/*:ref:refs/heads/main"
        }
      }
    }
  ]
}
```

**Trust Policy Patterns:**

- Wildcard (any repo, main only): `repo:my-org/*:ref:refs/heads/main` ← Start here
- Single repo (any branch): `repo:my-org/auth-api:*`
- Single repo and branch: `repo:my-org/auth-api:ref:refs/heads/main`
- Multiple specific repos: `repo:my-org/auth-api:* OR repo:my-org/billing-api:*`

#### Step 3: Attach Permissions Policy (Wildcard for Speed)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRAuth",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "ECRPushToNamespace",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload"
      ],
      "Resource": "arn:aws:ecr:us-east-1:123456789012:repository/legacy-migration/*"
    },
    {
      "Sid": "ECSDeployToCluster",
      "Effect": "Allow",
      "Action": [
        "ecs:DescribeServices",
        "ecs:DescribeTaskDefinition",
        "ecs:DescribeTasks",
        "ecs:RegisterTaskDefinition",
        "ecs:UpdateService"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "ecs:cluster": "arn:aws:ecs:us-east-1:123456789012:cluster/production-cluster"
        }
      }
    },
    {
      "Sid": "PassRoleForTaskExecution",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": [
        "arn:aws:iam::123456789012:role/ecsTaskExecutionRole",
        "arn:aws:iam::123456789012:role/*-task-role"
      ],
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "ecs-tasks.amazonaws.com"
        }
      }
    }
  ]
}
```

**When to refactor to per-service roles:** See Phase 4, Story 1.4 (typically after 3+ services in production).

---

## Security Hardening Checklist

### GitHub Actions Security

- [ ] Use OIDC instead of access keys
- [ ] Pin action versions (`uses: actions/checkout@v4` not `@main`)
- [ ] Minimize IAM permissions (see Phase 4, Story 1.4 for per-service roles)
- [ ] Use environment protection rules for production
- [ ] Enable branch protection on main
- [ ] Require pull request reviews
- [ ] Use GitHub secret scanning (automatically enabled)
- [ ] Rotate secrets if compromised (OIDC tokens rotate automatically)

### AWS IAM Security

- [ ] Use `StringEquals` conditions in trust policies where possible
- [ ] Scope ECS permissions to specific cluster (see Condition in policy example)
- [ ] Use specific ECR repository ARNs (not wildcards)
- [ ] Add `iam:PassedToService` condition to PassRole (prevents privilege escalation)
- [ ] Enable CloudTrail for audit logging
- [ ] Review IAM policies quarterly

### Container Image Security

- [ ] Run vulnerability scanning (Trivy, Snyk, AWS ECR scanning)
- [ ] Use specific base image versions (not `latest`)
- [ ] Don't run containers as root (use `USER` in Dockerfile)
- [ ] Don't embed secrets in images (use Secrets Manager)
- [ ] Use multi-stage builds to reduce attack surface
- [ ] Sign images (Docker Content Trust or AWS Signer)

---

## Related Documentation

- See [github-actions-cicd.md](github-actions-cicd.md) for complete CI/CD workflow examples
- See [secrets-management.md](secrets-management.md) for secrets vs configuration guidance
- See [ecs-deployment-fundamentals.md](ecs-deployment-fundamentals.md) for IAM role usage in ECS tasks
