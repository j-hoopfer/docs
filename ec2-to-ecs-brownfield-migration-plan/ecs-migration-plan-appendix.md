# Appendix: CI/CD Best Practices & Implementation Details

## Overview

This appendix provides comprehensive guidance on implementing CI/CD for ECS Fargate deployments, consolidating best practices from Phase 3 (Story 6) and Phase 4 (Feature 1), plus foundational concepts for understanding ECS deployments.

**Use this appendix when:**

- Understanding how ECS components fit together
- Setting up GitHub Actions for the first time
- Deciding between shared vs per-service IAM roles
- Implementing reusable workflows at scale
- Troubleshooting deployment pipeline issues

---

## Table of Contents

1. [AWS CLI Authentication Methods](#1-aws-cli-authentication-methods)
2. [ECS Deployment Fundamentals](#2-ecs-deployment-fundamentals)
3. [Security Group Patterns](#3-security-group-patterns)
4. [Authentication: GitHub Actions OIDC with AWS](#4-authentication-github-actions-oidc-with-aws)
5. [Secrets vs Configuration](#5-secrets-vs-configuration-security-best-practices)
6. [Reusable Workflows for Scale](#6-reusable-workflows-for-scale)
7. [Common Deployment Patterns](#7-common-deployment-patterns)
8. [Troubleshooting Common Issues](#8-troubleshooting-common-issues)
9. [Security Hardening Checklist](#9-security-hardening-checklist)
10. [Cost Optimization](#10-cost-optimization)
11. [Base Image Strategy (Golden Images)](#11-base-image-strategy-golden-images)
12. [Additional Resources](#12-additional-resources)

---

## 1. AWS CLI Authentication Methods

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

## 2. ECS Deployment Fundamentals

### What is a Task Definition?

A **Task Definition** is a blueprint that tells ECS how to run your container. Think of it as a detailed `docker run` command saved as configuration.

**It specifies:**

- Which Docker image to use
- How much CPU and memory to allocate
- What environment variables to set
- Which secrets to inject from Secrets Manager
- Where to send logs (CloudWatch)
- Which ports to expose
- What IAM roles to use (execution role, task role)
- Health check configuration

**Example analogy:**

- Task Definition = Recipe
- ECS Service = Chef that follows the recipe
- Running Task = The actual dish being served

### The Complete Deployment Sequence

Here's the correct order to deploy a new service:

```
1. Push Image to ECR
   ↓
2. Create Task Definition (blueprint)
   ↓
3. Create Target Group (ALB routing destination)
   ↓
4. Create ECS Service (runs tasks using the blueprint)
   ↓
5. Add ALB Listener Rule (routes traffic to target group)
   ↓
6. Configure DNS (point domain to ALB)
```

**Why this order matters:**

- You need the image in ECR before creating the task definition (image URI required)
- You need the target group before creating the service (service connects to it)
- You need the service running before adding the listener rule (otherwise rule routes to nothing)

### Component Relationships

**Example:** This diagram shows the pattern using `your-service` as a placeholder. Replace with your actual service names (e.g., `test-api-1`, `test-api-2`, `auth-api`).

```
┌─────────────────────────────────────────────────────────────┐
│                         USER REQUEST                         │
└───────────────────────────────┬─────────────────────────────┘
                                ↓
                    ┌───────────────────────┐
                    │  Application Load     │
                    │  Balancer (ALB)       │
                    │  - SSL Termination    │
                    │  - Host-based routing │
                    └───────────┬───────────┘
                                ↓
                    ┌───────────────────────┐
                    │  Listener Rule        │
                    │  Priority: 100        │
                    │  Condition: Host      │
                    │  yourapp.mysite.com   │
                    └───────────┬───────────┘
                                ↓
                    ┌───────────────────────┐
                    │  Target Group         │
                    │  your-service-tg      │
                    │  Type: IP             │
                    │  Health: /health      │
                    └───────────┬───────────┘
                                ↓
    ┌───────────────────────────────────────────────────────────────┐
    │                  ECS CLUSTER: your-cluster                     │
    │                  (e.g., test, production)                      │
    │                                                                │
    │               ┌───────────────────────┐                        │
    │               │  ECS Service          │                        │
    │               │  your-service         │                        │
    │               │  Desired: 2           │                        │
    │               │  Uses: Task Def       │                        │
    │               └───────────┬───────────┘                        │
    │                           ↓                                    │
    │       ┌───────────────────┴───────────────────────┐           │
    │       ↓                                           ↓           │
    │ ┌───────────────────┐                   ┌───────────────────┐ │
    │ │  Fargate Task 1   │                   │  Fargate Task 2   │ │
    │ │  IP: 10.100.4.23  │                   │  IP: 10.100.6.45  │ │
    │ │  Port: 3000       │                   │  Port: 3000       │ │
    │ │  Status: Healthy  │                   │  Status: Healthy  │ │
    │ └─────────┬─────────┘                   └─────────┬─────────┘ │
    │           └─────────────────┬─────────────────────┘           │
    └─────────────────────────────┼─────────────────────────────────┘
                                  ↓
              ┌───────────────────────────────────────────┐
              │     Task Definition (Blueprint)            │
              │  Family: your-service                     │
              │  Container: your-service                  │
              │  - Image: ECR URI                         │
              │  - CPU: 256, Memory: 512                  │
              │  - Env vars, Secrets, Logs, Health check  │
              └───────────────────────────────────────────┘
```

**Key:** The **ECS Cluster** is a logical grouping that contains Services and Tasks. Multiple services (like `test-api-1`, `test-api-2`, `auth-api`) can run in the same cluster, sharing the same infrastructure pool.

### Naming Conventions

**Critical: Keep these names identical for simplicity.**

AWS doesn't technically require these names to match, but keeping them the same eliminates confusion and makes operations easier.

**Recommended Pattern:**

| Component                            | What to Name It         | Example 1               | Example 2             |
| ------------------------------------ | ----------------------- | ----------------------- | --------------------- |
| **Task Definition Family**           | `[app-name]`            | `test-api-1`            | `auth-api`            |
| **Container Name** (inside task def) | `[app-name]`            | `test-api-1`            | `auth-api`            |
| **ECS Service**                      | `[app-name]`            | `test-api-1`            | `auth-api`            |
| **Target Group**                     | `[app-name]-tg`         | `test-api-1-tg`         | `auth-api-tg`         |
| **Security Group**                   | `[app-name]-fargate-sg` | `test-api-1-fargate-sg` | `auth-api-fargate-sg` |

**Why This Matters:**

✅ **Easy Debugging:** When you see `test-api-1` in CloudWatch logs, you know exactly which service it is  
✅ **Simpler CI/CD:** Use one variable for Task Family, Container Name, and Service Name  
✅ **Team Clarity:** No mental mapping required - name = service  
✅ **Less Errors:** No chance of updating the wrong container in a multi-container task definition

**When to Use Different Names:**

- Multiple environments: `test-api-1-staging` vs `test-api-1-production`
- Version migrations: `auth-api-v2` (temporary during cutover)

**What Happens If You Don't Match?**

Nothing breaks, but you'll create unnecessary complexity:

- Task Family: `legacy-test-api-1-v2`
- Container: `test-api-1-container`
- Service: `production-test-api-1-service`

Now you need to remember this mapping everywhere - in CI/CD scripts, troubleshooting commands, documentation, team communication, etc.

**Example for Your Deployment:**

```bash
# test-api-1
Task Definition Family: test-api-1
Container Name: test-api-1
Service Name: test-api-1
Target Group: test-api-1-tg

# test-api-2
Task Definition Family: test-api-2
Container Name: test-api-2
Service Name: test-api-2
Target Group: test-api-2-tg

# auth-api
Task Definition Family: auth-api
Container Name: auth-api
Service Name: auth-api
Target Group: auth-api-tg
```

---

### Key Concepts Explained

#### Task Definition vs Task vs Service

| Component           | What It Is                        | Analogy                |
| ------------------- | --------------------------------- | ---------------------- |
| **Task Definition** | A JSON blueprint                  | Recipe card            |
| **Task**            | A running container instance      | Dish being served      |
| **Service**         | Maintains desired number of tasks | Chef who keeps cooking |

**Example:**

- Task Definition: "Run `auth-api:latest` with 512MB RAM on port 3000"
- Service: "Keep 2 copies of auth-api running at all times"
- Tasks: The actual 2 running containers

#### Why Do I Need All These Things?

**Q: Can't I just run a container like Docker Compose?**

A: ECS adds production capabilities:

- **Target Group**: Load balances across multiple containers, health checks
- **Service**: Auto-restarts failed containers, rolling deployments
- **ALB**: SSL termination, routing multiple apps on one load balancer
- **Task Definition**: Version control for infrastructure, rollback capability

### Task Definition Versions

Every time you update a task definition, AWS creates a new **revision**:

- `auth-api:1` (initial)
- `auth-api:2` (added environment variable)
- `auth-api:3` (updated image)

**Your ECS Service points to a specific revision:**

- Service runs `auth-api:3`
- If there's an issue, you can rollback to `auth-api:2`

### What Happens When You Deploy

```
1. GitHub Actions pushes new image to ECR
   - Tags it with git SHA: auth-api:abc123f

2. GitHub Actions creates new task definition revision
   - auth-api:4 with image auth-api:abc123f

3. GitHub Actions updates ECS Service
   - "Use task definition auth-api:4"

4. ECS Service starts rolling deployment
   - Starts 1 new task (auth-api:4)
   - Waits for it to be healthy
   - Stops 1 old task (auth-api:3)
   - Repeats until all tasks updated

5. Target Group health checks pass
   - ALB routes traffic to new tasks
   - Old tasks drained and terminated
```

### Quick Reference: When You Need Each Component

| You Need                 | To Do This                                      |
| ------------------------ | ----------------------------------------------- |
| **Task Definition**      | Always (defines what to run)                    |
| **ECR Repository**       | Always (stores your image)                      |
| **ECS Service**          | Run containers continuously (not one-off tasks) |
| **Target Group**         | Receive traffic from ALB                        |
| **ALB Listener Rule**    | Route traffic based on domain/path              |
| **Security Group**       | Control network access                          |
| **CloudWatch Log Group** | See application logs                            |

---

## 2. Security Group Patterns

### The Problem with One-Per-Service

The naive approach is to create a unique security group for every service:

- `test-api-1-sg` with ALB inbound rule
- `test-api-2-sg` with ALB inbound rule
- `auth-api-sg` with ALB inbound rule
- ... 10 more services, 10 more duplicate rules

**Problems:**

- ❌ Duplicate ALB access rules across every service SG
- ❌ Updating the ALB rule requires changing 10+ security groups
- ❌ Harder to audit ("which services can access the ALB?" = check 10 SGs)
- ❌ Doesn't scale well

### Recommended Pattern: Baseline + Service-Specific

**You can attach up to 5 security groups to a single ECS task.** Use this to create a scalable pattern:

#### 1. Baseline Security Group (Shared by ALL services)

**Name:** `fargate-baseline-sg` or `fargate-common-sg`

**Purpose:** Common rules that apply to every Fargate service

**Rules:**

```
Inbound:
- Source: ALB Security Group (sg-alb-xxx)
  Port: 3000 (or your app port)
  Description: "Allow ALB to reach all Fargate services"

Outbound:
- Destination: 0.0.0.0/0
  Port: All
  Description: "Allow internet access for ECR pulls, API calls, etc."
```

**Attached to:** Every single Fargate service

#### 2. Service-Specific Security Groups (Optional, for Resource Isolation)

**Pattern:** Create these ONLY for services that need specific resource access

**Example 1: Database Access**

**Name:** `auth-api-database-sg`

**Purpose:** Marker SG to grant auth-api (and only auth-api) database access

**Rules:**

```
Inbound: None
Outbound: None
```

**Why no rules?** This SG is just a "marker" - the RDS security group references it.

**RDS Security Group gets updated:**

```
Inbound:
- Source: auth-api-database-sg
  Port: 5432
  Description: "Allow auth-api to connect to database"
```

**Attached to:** Only `auth-api` service

**Example 2: S3 Access (Via VPC Endpoint)**

**Name:** `billing-api-s3-sg`

**Purpose:** Grant S3 VPC endpoint access to billing-api only

**VPC Endpoint SG gets updated:**

```
Inbound:
- Source: billing-api-s3-sg
  Port: 443
  Description: "Allow billing-api to reach S3 via VPC endpoint"
```

**Attached to:** Only `billing-api` service

### Complete Example

**Scenario:** 3 services, 1 needs database access

**Security Groups Created:**

1. `fargate-baseline-sg` (shared)
2. `auth-api-database-sg` (service-specific)

**Service Attachments:**

| Service      | Security Groups Attached                        | Result                                             |
| ------------ | ----------------------------------------------- | -------------------------------------------------- |
| `auth-api`   | `fargate-baseline-sg`<br>`auth-api-database-sg` | ✅ Can receive ALB traffic<br>✅ Can access RDS    |
| `test-api-1` | `fargate-baseline-sg`                           | ✅ Can receive ALB traffic<br>❌ Cannot access RDS |
| `test-api-2` | `fargate-baseline-sg`                           | ✅ Can receive ALB traffic<br>❌ Cannot access RDS |

**Database (RDS) Security Group:**

```
Inbound:
- Source: auth-api-database-sg
  Port: 5432
```

**Result:** Only auth-api can connect to the database (principle of least privilege)

### Implementation in ECS Service

**When creating ECS Service (Console):**

```
Networking:
  Security Groups:
    - fargate-baseline-sg        ← Always include
    - auth-api-database-sg       ← Add if service needs DB
```

**When creating ECS Service (CLI):**

```bash
aws ecs create-service \
  --cluster production-cluster \
  --service-name auth-api \
  --task-definition auth-api:1 \
  --network-configuration "awsvpcConfiguration={
    subnets=[subnet-xxx,subnet-yyy],
    securityGroups=[sg-baseline-xxx,sg-auth-api-database-yyy],
    assignPublicIp=DISABLED
  }"
```

### When to Use Each Pattern

| Scenario                                             | Pattern                     | Security Groups                                 |
| ---------------------------------------------------- | --------------------------- | ----------------------------------------------- |
| POC with identical services                          | Baseline only               | `fargate-baseline-sg`                           |
| Production with services needing different DB access | Baseline + Service-Specific | `fargate-baseline-sg` + `[app]-database-sg`     |
| Multi-tenant with strict isolation                   | One-per-service             | `[app]-sg` (not recommended at scale)           |
| Microservices accessing different external APIs      | Baseline + Service-Specific | `fargate-baseline-sg` + `[app]-external-api-sg` |

### Benefits Summary

✅ **Centralized Common Rules:** ALB access rule exists in one place  
✅ **Scalable:** Add 100 services, still just 1 baseline SG  
✅ **Principle of Least Privilege:** Only grant database access to services that need it  
✅ **Easy Auditing:** "Which services can access RDS?" = Check which services have the database SG attached  
✅ **Flexible:** Can mix and match up to 5 SGs per service  
✅ **Cost Effective:** Security groups are free (unlike NACLs or firewall appliances)

### Migration Path

**If you already have one-per-service SGs:**

1. Create `fargate-baseline-sg` with ALB access rule
2. Attach it to all existing services (in addition to their current SG)
3. Verify traffic still flows
4. Remove ALB rules from individual service SGs
5. For new services, only attach baseline + service-specific (if needed)
6. Eventually remove old per-service SGs if they're empty

---

## 3. Authentication: GitHub Actions OIDC with AWS

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

## 2. Secrets vs Configuration: Security Best Practices

### The Rule of Thumb

**Only store TRUE SECRETS in GitHub Secrets.**

Most deployment values are **configuration** (resource names), not **secrets** (sensitive credentials).

### What Goes Where

| Value                 | Type   | Where to Store             | Why                     |
| --------------------- | ------ | -------------------------- | ----------------------- |
| `AWS_ROLE_ARN`        | Secret | GitHub Secrets             | Contains AWS Account ID |
| `AWS_REGION`          | Config | Workflow file (`env`)      | Just "us-east-1"        |
| `ECR_REPOSITORY`      | Config | Workflow file (`env`)      | Just a repo name        |
| `ECS_CLUSTER`         | Config | Workflow file (`env`)      | Just a cluster name     |
| `ECS_SERVICE`         | Config | Workflow file (`env`)      | Just a service name     |
| `ECS_TASK_DEFINITION` | Config | Workflow file (`env`)      | Just a task family name |
| `CONTAINER_NAME`      | Config | Workflow file (`env`)      | Just a container name   |
| `SLACK_WEBHOOK_URL`   | Secret | GitHub Secrets (org level) | Allows posting to Slack |
| Database passwords    | Secret | AWS Secrets Manager        | Never in GitHub         |

### Why This Matters

**Problems with storing everything in Secrets:**

1. **Visibility:** Can't see what gets deployed without clicking through GitHub Settings
2. **Versioning:** Changes to cluster names aren't tracked in Git
3. **Effort:** Configuring 7 secrets per repo × 10 repos = 70 manual steps
4. **False security:** Knowing your service is named "auth-api" doesn't help hackers

**Benefits of using `env` block:**

1. **Transparency:** Anyone reading the file knows what gets deployed
2. **History:** Git tracks when you changed from staging to production cluster
3. **Simplicity:** No UI clicking required
4. **Reusability:** Copy file, update `env` block, done

### Implementation Pattern

```yaml
name: Deploy to Amazon ECS

on:
  push:
    branches:
      - main

# ✅ Configuration values here (NOT secrets)
env:
  AWS_REGION: us-east-1
  ECR_REPOSITORY: legacy-migration/auth-api
  ECS_SERVICE: auth-api-service
  ECS_CLUSTER: production-cluster
  ECS_TASK_DEFINITION: auth-api
  CONTAINER_NAME: auth-api

permissions:
  id-token: write # Required for OIDC
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-region: ${{ env.AWS_REGION }}
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }} # ✅ Only secret


      # ... rest of workflow uses ${{ env.X }}
```

---

## 3. Reusable Workflows for Scale

### When to Use Reusable Workflows

- ✅ **Do this when:** You have 3+ services with identical deployment patterns
- ✅ **Do this when:** You want centralized control over deployment logic
- ✅ **Do this when:** You plan to add features (security scanning, notifications) to all services
- ⏸️ **Skip for now if:** You only have 1-2 services
- ⏸️ **Skip for now if:** Each service has wildly different deployment needs

### Structure

```
my-org/infrastructure/               # Central repo
└── .github/workflows/
    └── ecs-deploy-template.yml      # Reusable workflow

my-org/auth-api/                     # App repo
└── .github/workflows/
    └── deploy.yml                   # Calls template (15 lines)

my-org/test-api-1/                   # App repo
└── .github/workflows/
    └── deploy.yml                   # Calls template (15 lines)
```

### Template Workflow (infrastructure repo)

```yaml
# infrastructure/.github/workflows/ecs-deploy-template.yml
name: Reusable ECS Deploy

on:
  workflow_call:
    inputs:
      ecr_repository:
        required: true
        type: string
      service_name:
        required: true
        type: string
      cluster_name:
        required: false
        type: string
        default: "production-cluster"
      task_definition:
        required: true
        type: string
      container_name:
        required: true
        type: string
      aws_region:
        required: false
        type: string
        default: "us-east-1"
    secrets:
      AWS_ROLE_ARN:
        required: true

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-region: ${{ inputs.aws_region }}
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}

      - name: Login to ECR
        uses: aws-actions/amazon-ecr-login@v2
        id: login-ecr

      - name: Build and push image
        id: build-image
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          ECR_REPOSITORY: ${{ inputs.ecr_repository }}
          IMAGE_TAG: ${{ github.sha }}
        run: |
          docker build \
            --platform linux/amd64 \
            -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG \
            -t $ECR_REGISTRY/$ECR_REPOSITORY:latest \
            .
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:latest
          echo "image=$ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG" >> $GITHUB_OUTPUT

      - name: Download task definition
        run: |
          aws ecs describe-task-definition \
            --task-definition ${{ inputs.task_definition }} \
            --query taskDefinition > task-definition.json

      - name: Render new task definition
        uses: aws-actions/amazon-ecs-render-task-definition@v1
        id: task-def
        with:
          task-definition: task-definition.json
          container-name: ${{ inputs.container_name }}
          image: ${{ steps.build-image.outputs.image }}

      - name: Deploy to ECS
        uses: aws-actions/amazon-ecs-deploy-task-definition@v2
        with:
          task-definition: ${{ steps.task-def.outputs.task-definition }}
          service: ${{ inputs.service_name }}
          cluster: ${{ inputs.cluster_name }}
          wait-for-service-stability: true
```

### Caller Workflow (app repo)

```yaml
# auth-api/.github/workflows/deploy.yml
name: Deploy to Production

on:
  push:
    branches:
      - main

jobs:
  deploy:
    uses: my-org/infrastructure/.github/workflows/ecs-deploy-template.yml@main
    with:
      ecr_repository: legacy-migration/auth-api
      service_name: auth-api-service
      task_definition: auth-api
      container_name: auth-api
    secrets:
      AWS_ROLE_ARN: ${{ secrets.AWS_ROLE_ARN }}
```

### Versioning Strategy

| Pattern   | Use Case                                 | Stability                           |
| --------- | ---------------------------------------- | ----------------------------------- |
| `@main`   | Active development, all services in sync | Changes propagate immediately       |
| `@v1`     | Production stability                     | Pin to stable version, opt-in to v2 |
| `@abc123` | Maximum control                          | Pin to specific commit              |

**Recommendation:** Start with `@main`, switch to `@v1` tags once template is stable.

---

## 4. Common Deployment Patterns

### Pattern 1: Single Environment (Production Only)

```yaml
env:
  AWS_REGION: us-east-1
  ECS_CLUSTER: production-cluster
  # ... other config

on:
  push:
    branches:
      - main # Deploys to production
```

### Pattern 2: Multi-Environment (Staging + Production)

```yaml
env:
  AWS_REGION: us-east-1

on:
  push:
    branches:
      - main
      - staging

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set environment
        id: set-env
        run: |
          if [[ "${{ github.ref }}" == "refs/heads/main" ]]; then
            echo "cluster=production-cluster" >> $GITHUB_OUTPUT
            echo "service=auth-api-production" >> $GITHUB_OUTPUT
          else
            echo "cluster=staging-cluster" >> $GITHUB_OUTPUT
            echo "service=auth-api-staging" >> $GITHUB_OUTPUT
          fi

      - name: Deploy
        uses: aws-actions/amazon-ecs-deploy-task-definition@v2
        with:
          cluster: ${{ steps.set-env.outputs.cluster }}
          service: ${{ steps.set-env.outputs.service }}
          # ...
```

### Pattern 3: Manual Approval for Production

```yaml
jobs:
  deploy-staging:
    # ... deploy to staging automatically

  approve-production:
    needs: deploy-staging
    runs-on: ubuntu-latest
    environment: production # Requires approval in GitHub Settings
    steps:
      - run: echo "Approved"

  deploy-production:
    needs: approve-production
    # ... deploy to production
```

---

## 5. Troubleshooting Common Issues

### Pipeline Failures

| Error                                                     | Cause                                 | Fix                                          |
| --------------------------------------------------------- | ------------------------------------- | -------------------------------------------- |
| "Not authorized to perform sts:AssumeRoleWithWebIdentity" | Trust policy `sub` doesn't match repo | Check repo name in trust policy              |
| "Could not assume role"                                   | Missing `id-token: write` permission  | Add `permissions` block to workflow          |
| "AccessDeniedException" on ECR                            | Role doesn't have ECR permissions     | Add ECR policy to role                       |
| "Service not stable" timeout                              | Deployment failing health checks      | Check ECS events, CloudWatch logs            |
| "exec format error"                                       | Built for wrong CPU architecture      | Add `--platform linux/amd64` to docker build |
| "Task failed to start"                                    | Image not found in ECR                | Check ECR repo name and region               |
| "Stopped reason: CannotPullContainerError"                | No NAT Gateway or VPC endpoints       | Add NAT or ECR VPC endpoints                 |

### Debugging Steps

1. **Check GitHub Actions logs** (most verbose, start here)
2. **Check ECS Service Events** (deployment progress)
   ```bash
   aws ecs describe-services --cluster production-cluster --services auth-api-service \
     --query 'services[0].events[0:10]'
   ```
3. **Check ECS Task Status** (why tasks fail)
   ```bash
   aws ecs describe-tasks --cluster production-cluster --tasks <task-id> \
     --query 'tasks[0].{Status:lastStatus,Reason:stoppedReason,Containers:containers[0].reason}'
   ```
4. **Check CloudWatch Logs** (application errors)
   ```bash
   aws logs tail /ecs/production-cluster/auth-api --follow
   ```
5. **Check Target Group Health** (ALB perspective)
   ```bash
   aws elbv2 describe-target-health --target-group-arn <arn>
   ```

---

## 6. Security Hardening Checklist

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

## 7. Cost Optimization

### GitHub Actions Minutes

- **Free tier:** 2,000 minutes/month for private repos
- **Optimization:** Use `on: push: paths:` to skip unnecessary runs
  ```yaml
  on:
    push:
      paths:
        - "src/**"
        - "Dockerfile"
        - ".github/workflows/**"
  ```

### ECR Storage

- **Lifecycle policies** to delete old images:
  ```json
  {
    "rules": [
      {
        "rulePriority": 1,
        "description": "Keep last 10 images",
        "selection": {
          "tagStatus": "any",
          "countType": "imageCountMoreThan",
          "countNumber": 10
        },
        "action": { "type": "expire" }
      }
    ]
  }
  ```

### ECS Task Size

Start small, scale up based on metrics:

- **Start:** 0.25 vCPU / 0.5 GB ($10/month)
- **Monitor:** CPU and memory utilization
- **Scale up if:** Consistently >70% utilization
- **Scale down if:** Consistently <30% utilization

---

## 8. Additional Resources

### Official Documentation

- [GitHub Actions: Deploying to Amazon ECS](https://docs.github.com/en/actions/deployment/deploying-to-amazon-elastic-container-service)
- [AWS: IAM roles for service accounts](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html)
- [AWS ECS Developer Guide](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/)

### Community Resources

- [terraform-aws-modules/ecs](https://github.com/terraform-aws-modules/terraform-aws-ecs)
- [aws-actions GitHub org](https://github.com/aws-actions)
- [Awesome ECS](https://github.com/nathanpeck/awesome-ecs)

### Related Sections in This Plan

- **Phase 3, Story 6:** Initial CI/CD setup
- **Phase 4, Story 1.1-1.3:** Reusable workflows
- **Phase 4, Story 1.4:** Per-service IAM roles
- **Phase 4, Story 2:** Infrastructure as Code with Terraform

---

## Appendix A: Secrets Security — EC2 vs ECS Comparison

This appendix explains **how secrets are stored and injected** in both environments, and why ECS + Secrets Manager is a security improvement.

### The Security Question

When your app reads `process.env.DB_PASSWORD`, the question isn't just "does it work?" — it's:

1. **Where is the secret stored at rest?** (On disk? Encrypted? Where?)
2. **Who can access the secret?** (Anyone with SSH? IAM-controlled?)
3. **Is there an audit trail?** (Who accessed what, when?)
4. **Can the secret be rotated?** (Without downtime?)

### EC2: Current State (Typical Patterns)

#### Pattern 1: `.env` File + dotenv Library

```
┌─────────────────────────────────────────────────────────────────┐
│ EC2 Instance                                                    │
│  ┌──────────────────┐      ┌──────────────────────────────────┐ │
│  │  .env file       │ ───▶ │  App (dotenv loads at startup)   │ │
│  │  DB_PASS=secret  │      │  process.env.DB_PASS = "secret"  │ │
│  │  (plaintext)     │      │                                  │ │
│  └──────────────────┘      └──────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

**Security Concerns:**

- ⚠️ Secret stored in **plaintext file on disk**
- ⚠️ Anyone with SSH access can `cat .env` and see all secrets
- ⚠️ If `.env` ends up in a backup, secrets are exposed
- ⚠️ No audit trail — you don't know who read the file
- ⚠️ Rotation requires editing the file and restarting the app

#### Pattern 2: Shell Export (Startup Script / PM2 / systemd)

```
┌───────────────────────────────────────────────────────────────────────┐
│ EC2 Instance                                                          │
│  ┌────────────────────────┐      ┌──────────────────────────────────┐ │
│  │  startup.sh            │      │  App                             │ │
│  │  export DB_PASS=secret │ ───▶ │  process.env.DB_PASS = "secret"  │ │
│  │  node app.js           │      │                                  │ │
│  └────────────────────────┘      └──────────────────────────────────┘ │
│                                                                       │
│  OR: PM2 ecosystem.config.js / systemd unit file                      │
└───────────────────────────────────────────────────────────────────────┘
```

**Security Concerns:**

- ⚠️ Secret still in **plaintext** (in script, PM2 config, or systemd unit)
- ⚠️ Anyone with SSH can read the startup script or `ps aux` might show it
- ⚠️ `/proc/<pid>/environ` exposes all env vars to anyone who can read it
- ⚠️ No audit trail
- ⚠️ Rotation requires editing config and restarting

**Slight improvement over `.env`:** Secret isn't in the application directory, so less likely to be accidentally committed or deployed.

#### Pattern 3: EC2 Parameter Store / Secrets Manager (Rare but Better)

Some EC2 setups fetch secrets at startup:

```bash
# startup.sh
export DB_PASS=$(aws secretsmanager get-secret-value --secret-id prod/db --query SecretString --output text)
node app.js
```

**Better, but:**

- ⚠️ Still ends up as plaintext env var on the instance
- ⚠️ `/proc/<pid>/environ` still exposes it
- ✅ At least the secret isn't in a file on disk
- ✅ IAM controls who can fetch (but anyone on the instance can read after fetch)

---

### ECS + Secrets Manager: The Target State

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                                                                                  │
│  ┌─────────────────────┐      ┌─────────────────┐      ┌────────────────────┐   │
│  │  Secrets Manager    │      │  ECS Service    │      │  Fargate Task      │   │
│  │                     │      │                 │      │                    │   │
│  │  production/auth/db │ ───▶ │  Task Def       │ ───▶ │  Container         │   │
│  │  (encrypted by KMS) │      │  secrets block  │      │  process.env.DB_*  │   │
│  │                     │      │                 │      │                    │   │
│  └─────────────────────┘      └─────────────────┘      └────────────────────┘   │
│                                                                                  │
│  IAM: Task Execution Role                                                        │
│       - secretsmanager:GetSecretValue                                            │
│       - Resource: arn:aws:secretsmanager:...:production/auth/*                   │
│                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────┘
```

**How It Works:**

1. Secrets stored in **AWS Secrets Manager** (encrypted at rest with KMS)
2. ECS Task Definition references the secret ARN:
   ```json
   "secrets": [
     {
       "name": "DB_PASSWORD",
       "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789:secret:production/auth/db:password::"
     }
   ]
   ```
3. At container start, **ECS fetches the secret** (not your app) using the Task Execution Role
4. ECS injects the value as an environment variable
5. Your app reads `process.env.DB_PASSWORD` — it doesn't know about Secrets Manager

**Security Improvements:**

| Concern             | EC2 (.env / export)          | ECS + Secrets Manager                      |
| ------------------- | ---------------------------- | ------------------------------------------ |
| **Storage at rest** | Plaintext file on disk       | Encrypted with KMS                         |
| **Access control**  | Anyone with SSH              | IAM policies (least privilege)             |
| **Audit trail**     | None                         | CloudTrail logs every access               |
| **Rotation**        | Manual edit + restart        | Automatic rotation available               |
| **Exposure risk**   | In backups, logs, ps output  | Never written to disk                      |
| **Blast radius**    | Compromise EC2 = all secrets | Compromise task = only that task's secrets |

---

### What About `/proc/<pid>/environ`?

You might ask: "Doesn't ECS still inject secrets as env vars? Can't someone read `/proc`?"

**In Fargate:**

- There's no SSH access to the underlying host
- You can't `exec` into a container unless you explicitly enable ECS Exec
- Even with ECS Exec, IAM controls who can do it (and it's logged)
- The attack surface is dramatically smaller

**Contrast with EC2:**

- Anyone with SSH can read any process's environment
- Often multiple people/services share the same EC2 instance
- Less granular access control

---

### App Code: Identical in Both Environments

This is the key point — **your application code doesn't change:**

```javascript
// This works identically on EC2 and ECS
const dbPassword = process.env.DB_PASSWORD;

if (!dbPassword) {
  throw new Error("DB_PASSWORD environment variable is required");
}
```

What changes is **how the secret gets there**:

| Environment               | Who sets `process.env.DB_PASSWORD`? |
| ------------------------- | ----------------------------------- |
| EC2 + dotenv              | dotenv library reads `.env` file    |
| EC2 + shell export        | Bash `export` before starting app   |
| EC2 + PM2                 | PM2 ecosystem config `env` block    |
| **ECS + Secrets Manager** | **ECS injects at container start**  |

---

### Removing dotenv for Production

If your app currently uses dotenv, you have two options:

**Option A: Make dotenv Optional (Recommended)**

```javascript
// Only load .env if it exists (for local development)
require("dotenv").config({ silent: true });
// Or in newer versions:
require("dotenv").config(); // Doesn't throw if file missing

// App code works the same either way
const dbHost = process.env.DB_HOST;
```

**Option B: Remove dotenv Entirely**

```javascript
// Just read from process.env directly
const dbHost = process.env.DB_HOST;
```

For local development without dotenv, you can:

- Use `export` in your shell before running the app
- Use a `docker-compose.yml` with `environment:` block
- Use VS Code's `launch.json` with `"env"` configuration

---

### Security Best Practices Summary

1. **Never commit secrets to git** — use `.env.example` with placeholder values
2. **Never bake secrets into Docker images** — check with `docker history <image>`
3. **Use Secrets Manager** (not SSM Parameter Store) for truly sensitive values
   - SSM Parameter Store SecureString works but has lower API limits
4. **Scope IAM permissions** — each app should only access its own secrets
5. **Enable CloudTrail** — audit who accessed which secrets
6. **Consider rotation** — especially for database credentials
7. **Use VPC Endpoints** — so secrets never traverse the public internet

---

### Migration Path

| Phase          | Action                                                         | Owner         |
| -------------- | -------------------------------------------------------------- | ------------- |
| Phase 0        | Inventory all secrets (Story 5.1)                              | Dev team      |
| Phase 1        | Ensure app reads from `process.env`, not hardcoded (Story 2.1) | Dev team      |
| Phase 1        | Make dotenv optional or remove it                              | Dev team      |
| Phase 2        | Create secrets in Secrets Manager (Story 4.1)                  | Infra team    |
| Phase 3        | Reference secrets in Task Definition                           | Infra team    |
| Post-migration | Delete `.env` files from EC2 instances                         | Infra team    |
| Post-migration | Consider enabling secret rotation                              | Security team |

---

## 11. Enterprise Terraform Organization & Repository Structure

### Overview

This section provides comprehensive guidance on organizing Terraform infrastructure for enterprise environments, including team workflows, resource placement, and when to create new projects.

### Layered State Architecture

**The Problem:**

In enterprise environments, putting all infrastructure in a single Terraform state file creates several issues:

- **Blast Radius**: A mistake in one area (e.g., security group) triggers state refresh of everything (VPCs, databases)
- **Team Bottlenecks**: Network team and app teams can't work independently
- **Slow Operations**: `terraform plan` takes minutes when state contains hundreds of resources
- **Risk**: Changing a load balancer shouldn't risk touching VPC peering connections

**The Solution: Layer Separation**

Split infrastructure into logical layers with separate state files:

1. **Network Layer (`00-network`)**: Foundation that rarely changes
2. **Application Layer (`10-application`)**: Workloads that change frequently

Layers communicate via `terraform_remote_state` data sources.

---

### Layered vs Monolithic: When to Use Which Approach

#### Monolithic Architecture

**Structure:**
All infrastructure in a single Terraform root module with one state file.

```
terraform/
├── main.tf           # Everything: VPC, EC2, RDS, ECS, ALB
├── variables.tf
├── outputs.tf
└── terraform.tfstate # Single state file
```

**When to Use Monolithic:**

✅ **Good for:**

- **Small projects**: < 20 resources, single application
- **Proof of concepts**: Testing ideas quickly
- **Personal projects**: No team collaboration needed
- **Single-team ownership**: One team owns everything
- **Tightly coupled resources**: Everything depends on everything
- **Learning Terraform**: Simpler mental model for beginners
- **Ephemeral environments**: Dev sandboxes that get destroyed daily

✅ **Example Scenarios:**

- Side project blog running on single EC2 + RDS
- Hackathon demo environment
- Personal learning lab
- Single landing page with CloudFront + S3
- Startup MVP with 2-3 engineers

**Advantages:**

- ✅ Simple: One `terraform apply` deploys everything
- ✅ No remote state data sources needed
- ✅ Easier to understand for beginners
- ✅ Fewer files to manage
- ✅ Fast iteration for small projects

**Disadvantages:**

- ❌ Blast radius: Any change refreshes entire state
- ❌ Slow: `terraform plan` takes longer as resources grow
- ❌ Team conflicts: Multiple engineers cause state locking
- ❌ Risk: Changing ALB rule refreshes VPC peering state
- ❌ Cannot parallelize: Single state = single operation at a time
- ❌ Hard to delegate: No separation of concerns

---

#### Layered Architecture

**Structure:**
Infrastructure split into logical layers with separate state files.

```
terraform/environments/dev/
├── 00-network/           # Network layer
│   ├── main.tf
│   └── terraform.tfstate
└── 10-application/       # Application layer
    ├── main.tf
    ├── data.tf           # References 00-network
    └── terraform.tfstate
```

**When to Use Layered:**

✅ **Good for:**

- **Multiple teams**: Platform team + App teams
- **Large infrastructure**: 50+ resources
- **Brownfield migrations**: Importing existing infrastructure
- **Production workloads**: Minimize blast radius
- **Frequent changes**: App deploys shouldn't touch network
- **Enterprise environments**: Compliance, audit trails
- **Microservices**: Multiple services, shared infrastructure
- **Long-lived infrastructure**: Resources with different lifecycles

✅ **Example Scenarios:**

- EC2 to Fargate migration (this project)
- Multi-tenant SaaS platform
- E-commerce platform with 10+ microservices
- Enterprise with separate network/security/app teams
- Financial services with compliance requirements

**Advantages:**

- ✅ Reduced blast radius: Network changes isolated from apps
- ✅ Team autonomy: App team deploys without touching network
- ✅ Faster operations: `terraform plan` only checks relevant layer
- ✅ Parallel work: Network and app teams work simultaneously
- ✅ Clear ownership: Different teams own different layers
- ✅ Safer refactoring: Can rebuild app layer without network
- ✅ Better for CI/CD: Deploy layers independently

**Disadvantages:**

- ❌ More complex: Need to understand `terraform_remote_state`
- ❌ More files: Multiple `main.tf` files to navigate
- ❌ Order dependency: Must deploy 00-network before 10-application
- ❌ Initial setup overhead: More planning required upfront
- ❌ Debugging across layers: Harder to trace cross-layer issues

---

#### Decision Matrix

| Factor                      | Monolithic                    | Layered                                  |
| --------------------------- | ----------------------------- | ---------------------------------------- |
| **Team size**               | 1-3 engineers                 | 4+ engineers                             |
| **Resource count**          | < 20 resources                | 50+ resources                            |
| **Deployment frequency**    | Weekly or less                | Daily or multiple times/day              |
| **Infrastructure maturity** | New/greenfield                | Mature/brownfield                        |
| **Change blast radius**     | Acceptable                    | Must minimize                            |
| **Team structure**          | Single team                   | Multiple teams (platform, app, security) |
| **Compliance requirements** | Minimal                       | SOC2, HIPAA, PCI-DSS                     |
| **Lifecycle variance**      | All resources change together | Network stable, apps change often        |
| **CI/CD maturity**          | Manual or basic               | Advanced pipelines, GitOps               |
| **Budget for complexity**   | Low                           | High                                     |

---

#### Hybrid Approach (Start Simple, Grow Complex)

**Recommendation for most teams:**

**Phase 1 (Months 1-3): Monolithic**

- Start with single state file
- Get comfortable with Terraform
- Understand resource dependencies
- Ship features quickly

**Phase 2 (Months 4-6): Two Layers**

- Split when team grows or resource count > 30
- Separate network from application
- Introduce `terraform_remote_state`

**Phase 3 (Months 7+): Multiple Layers**

- Add layers as complexity demands:
  - `00-network`
  - `10-data` (RDS, ElastiCache - if very stable)
  - `20-application` (ECS, EC2)
  - `30-monitoring` (CloudWatch, Datadog)

**Trigger Points to Split:**

- `terraform plan` takes > 30 seconds
- State locking conflicts happen weekly
- Team asks "why does my app deploy refresh the VPC?"
- More than 50 resources in state
- Multiple teams need to work simultaneously

---

#### Real-World Example: When We Chose Layered

**Scenario:**
Migrating 5 legacy monolithic applications from EC2 to Fargate. Existing VPC with 2 AZs, RDS Postgres, ElastiCache Redis.

**Why Monolithic Would Fail:**

1. **Import complexity**: Importing VPC + EC2 + RDS into single state = 80+ resources
2. **Blast radius**: Adding Fargate service would refresh state of production RDS
3. **Team conflict**: Network team manages VPC, app team deploys services
4. **Change velocity**: App deploys 3x/day, network changes monthly
5. **Risk**: `terraform apply` failure could affect production database state

**Why Layered Works:**

1. **Import isolation**: Import VPC into `00-network` (stable, 30 resources)
2. **Safe app iteration**: Deploy Fargate to `10-application` without touching network
3. **Team boundaries**: Network team owns layer 0, app team owns layer 1
4. **Fast deploys**: App layer `terraform plan` takes 5 seconds vs 60 seconds
5. **Safe rollbacks**: Can destroy/recreate app layer without VPC risk

**Architecture:**

```
00-network/       # Import once, rarely touch (VPC, subnets, NAT)
10-application/   # Frequent changes (ECS, ALB, target groups, RDS app schema)
```

**Result:**

- Network team approves layer 0 changes (1x/month)
- App team self-serves layer 1 changes (3x/day)
- Zero state conflicts
- App deploys don't risk network stability

---

#### Migration Path: Monolithic → Layered

**If you already have monolithic Terraform:**

**Option 1: Big Bang (Not Recommended)**

- Stop all Terraform changes
- Split state files using `terraform state mv`
- High risk, requires downtime

**Option 2: Gradual Migration (Recommended)**

1. **Freeze monolith**: No new resources in old state
2. **Create network layer**: Import VPC into new `00-network` state
3. **Verify parallel**: Both states exist, manage different resources
4. **Migrate apps**: One service at a time, move to `10-application`
5. **Deprecate monolith**: After all resources migrated

**Example Commands:**

```bash
# In old monolithic state
terraform state list

# Move VPC to new network layer
terraform state mv aws_vpc.main ../00-network/aws_vpc.main

# In new 00-network layer
terraform import aws_vpc.main vpc-abc123
terraform plan  # Should show: No changes
```

**Timeline:**

- Week 1: Create 00-network, import VPC resources
- Week 2-4: Import application resources to 10-application
- Week 5: Verify both layers work, deprecate old monolith

---

#### Summary: Quick Decision Guide

**Choose Monolithic if:**

- Team < 3 people
- Resources < 20
- Single application
- Deploying weekly or less
- Learning Terraform

**Choose Layered if:**

- Team ≥ 4 people
- Resources ≥ 50
- Multiple applications/services
- Deploying daily
- Brownfield migration (this project)
- Production workloads
- Need team separation

**Still unsure?**

- Start monolithic
- Split when you hit pain (state locking, slow plans, team conflicts)
- Use this migration as opportunity to adopt layered (we're importing anyway)

---

### Repository Structure for Brownfield Migrations

```
fargate-migration-infrastructure/
├── README.md
├── .gitignore
├── docs/
│   └── IMPORT_COMMANDS.md          # Record of all imported resources
└── terraform/
    ├── bootstrap/                   # S3 + DynamoDB for state (one-time)
    ├── modules/                     # Reusable modules
    │   ├── networking/
    │   ├── security/
    │   ├── compute/
    │   ├── database/
    │   └── secrets/
    └── environments/
        ├── dev/
        │   ├── 00-network/          # VPCs, subnets, routing
        │   │   ├── main.tf
        │   │   ├── outputs.tf
        │   │   └── variables.tf
        │   └── 10-application/      # EC2, ECS, RDS, ALB
        │       ├── main.tf
        │       ├── outputs.tf
        │       ├── variables.tf
        │       └── data.tf          # References 00-network outputs
        ├── staging/
        │   ├── 00-network/
        │   └── 10-application/
        └── production/
            ├── 00-network/
            └── 10-application/
```

---

### Resource Placement Guide

#### Network Layer (`00-network`)

**What belongs here:**

- VPCs and CIDR blocks
- Subnets (public and private)
- Internet Gateways
- NAT Gateways and Elastic IPs
- Route Tables and associations
- VPC Peering Connections
- Transit Gateways
- Network ACLs
- **VPC Endpoints** (S3, ECR, CloudWatch Logs, Secrets Manager, etc.)
- **Route53 Private Hosted Zones** (for internal DNS)
- **Route53 Public Hosted Zones** (if managing DNS in this account)

**Who manages:** Infrastructure/Platform team

**Change frequency:** Infrequent (weeks to months)

**Example `00-network/outputs.tf`:**

```hcl
output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = [
    aws_subnet.public_1a.id,
    aws_subnet.public_1b.id,
  ]
}

output "private_subnet_ids" {
  value = [
    aws_subnet.private_1a.id,
    aws_subnet.private_1b.id,
  ]
}

output "vpc_cidr_block" {
  value = aws_vpc.main.cidr_block
}
```

---

#### Application Layer (`10-application`)

**What belongs here:**

**Compute:**

- EC2 instances
- ECS clusters
- ECS services
- ECS task definitions
- Auto Scaling Groups
- Launch Templates

**Load Balancing:**

- Application Load Balancers (ALB)
- Network Load Balancers (NLB)
- Target Groups
- ALB/NLB Listeners
- Listener Rules

**Persistence:**

- RDS instances
- RDS subnet groups
- ElastiCache clusters
- ElastiCache subnet groups
- DynamoDB tables
- S3 buckets (application-specific)

**DNS & Certificates:**

- **ACM Certificates** (tied to specific ALB/domain)
- **Route53 A Records** (pointing to ALB)
- **Route53 CNAME Records** (application aliases)

**Security:**

- Security Groups (all types: ALB, ECS, RDS, ElastiCache)
- IAM Roles (task execution role, task role)
- IAM Policies
- IAM Instance Profiles

**Configuration & Secrets:**

- Secrets Manager secrets
- SSM Parameter Store parameters
- CloudWatch Log Groups
- CloudWatch Alarms

**Who manages:** Application teams (with infrastructure team oversight)

**Change frequency:** Frequent (daily deployments)

**Example `10-application/data.tf` (referencing network layer):**

```hcl
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "your-terraform-state-bucket"
    key    = "dev/00-network/terraform.tfstate"
    region = "us-east-1"
  }
}

# Use in resources:
resource "aws_lb" "app" {
  subnets = data.terraform_remote_state.network.outputs.public_subnet_ids
  # ...
}

resource "aws_ecs_service" "app" {
  network_configuration {
    subnets = data.terraform_remote_state.network.outputs.private_subnet_ids
    # ...
  }
}
```

---

### Team Workflow & Ownership Model

#### Infrastructure Team (Platform/DevOps)

**Responsibilities:**

- Owns `00-network` layer completely
- Provides stable network foundation for application teams
- Reviews/approves changes to shared resources in `10-application`
- Manages Terraform state backends (S3, DynamoDB)
- Defines reusable Terraform modules
- Establishes CI/CD pipeline standards

**Workflow:**

1. Provision network layer once
2. Export outputs for application teams to consume
3. Only modify network layer for capacity planning or new regions
4. Act as enabler, not blocker

#### Application Teams

**Responsibilities:**

- Work primarily in `10-application` layer
- Add new ECS services, task definitions, ALBs
- Manage application-specific security groups and IAM roles
- Deploy and scale applications
- Monitor and troubleshoot applications

**Workflow:**

1. Reference network outputs via `terraform_remote_state`
2. Add resources to `10-application` via pull requests
3. Infrastructure team reviews for security/compliance
4. Deploy via CI/CD after approval
5. Iterate rapidly without touching network layer

**Autonomy:**

- Can add new ECS services without network team involvement
- Can modify task definitions, scaling policies
- Can add/remove target groups and ALB rules
- **Cannot** modify VPCs, subnets, or network routing

---

### When to Create a New Terraform Project

#### Use Same Project (Add to `10-application`)

✅ **When:**

- Adding another microservice to the same VPC
- New application in the same AWS account
- Shared infrastructure (same RDS, same Redis)
- Same team or related teams
- Services need to communicate internally

✅ **Benefits:**

- All services can reference same network outputs
- Consistent security group patterns
- Shared RDS/ElastiCache resources
- Single state backend configuration
- Easier cross-service dependencies

✅ **Example:**

```
10-application/
├── auth-service.tf          # Auth API
├── user-service.tf          # User API
├── notification-service.tf  # Notifications
├── alb.tf                   # Shared ALB with multiple target groups
└── rds.tf                   # Shared database for all services
```

---

#### Create New Project (Separate Repository)

❌ **When:**

**Organizational Boundaries:**

- Different business unit or product line
- Completely separate team with different ownership
- Different AWS Organization or root account
- Different compliance requirements (PCI vs non-PCI)

**Infrastructure Isolation:**

- Shared platform services (central logging, monitoring)
- Multi-tenant SaaS where each tenant gets own VPC
- Different lifecycle (ephemeral environments vs long-lived)

**Technical Reasons:**

- Different AWS region (though you can use same repo with region folders)
- No shared infrastructure at all
- Different Terraform version requirements

❌ **Example Scenarios:**

| Scenario                                  | Decision                             | Reason                                |
| ----------------------------------------- | ------------------------------------ | ------------------------------------- |
| Marketing website + API backend           | Same project                         | Same product, same VPC                |
| Customer-facing app + Internal admin tool | Same project                         | Same team, can share resources        |
| E-commerce platform + Analytics platform  | **Separate projects**                | Different teams, different lifecycles |
| Production app + Staging app              | Same repo, different `environments/` | Same infrastructure, different stages |
| US-East region + EU-West region           | Same repo, different region folders  | Same app, different regions           |
| Payment processing + General app          | **Separate projects**                | Different compliance scope (PCI)      |

---

### Advanced Patterns

#### Multi-Region Deployment

```
terraform/environments/
├── us-east-1/
│   ├── 00-network/
│   └── 10-application/
└── eu-west-1/
    ├── 00-network/
    └── 10-application/
```

#### Multi-Tenant SaaS (Separate VPC per Tenant)

**Option 1: Workspaces**

```bash
# Create workspace per tenant
terraform workspace new tenant-acme
terraform apply -var="tenant_name=acme"
```

**Option 2: Separate State Files**

```
10-application/
├── tenant-acme.tf
├── tenant-globex.tf
└── tenant-initech.tf
```

#### Shared Services Platform

Separate project for centralized services:

```
shared-platform-infrastructure/
└── terraform/
    ├── logging/          # Central ELK/Loki
    ├── monitoring/       # Central Prometheus/Grafana
    └── ci-cd/           # Shared build infrastructure
```

---

### Centralized vs Distributed: Where Should Terraform Live?

#### The Two Dominant Patterns

There are two common approaches to organizing Terraform code in organizations:

1. **Centralized Infrastructure Repository** (what we've shown above)
2. **Distributed (Terraform in App Repos)** ← Increasingly popular

Both are valid. The choice depends on your team structure, deployment model, and organizational culture.

---

#### Pattern 1: Centralized Infrastructure Repository

**Structure:**

```
mycompany-infrastructure/          # Single repo
└── terraform/
    └── environments/
        └── production/
            ├── 00-network/
            └── 10-application/
                ├── auth-api.tf
                ├── billing-api.tf
                ├── user-api.tf
                └── notification-api.tf

mycompany-auth-api/                # Separate app repo
└── src/
    └── index.js                   # Just application code
```

**Who uses this:**

- Traditional enterprises
- Organizations with dedicated platform/infrastructure teams
- Companies with centralized change control
- Teams following "infrastructure as a platform" model

**Workflow:**

1. Developer wants to deploy new service
2. Opens PR in infrastructure repo
3. Platform team reviews and approves
4. Platform team (or CI/CD) applies Terraform
5. Developer deploys application code separately

**Key Characteristic:** Infrastructure and application code are **decoupled**.

---

#### Pattern 2: Distributed (Terraform in App Repos)

**Structure:**

```
mycompany-auth-api/                # App repo
├── src/
│   └── index.js                   # Application code
├── terraform/                     # Infrastructure for THIS service
│   ├── main.tf
│   ├── ecs.tf
│   ├── alb.tf
│   └── iam.tf
└── .github/workflows/
    └── deploy.yml                 # Deploys both infra and app

mycompany-billing-api/             # Another app repo
├── src/
│   └── server.py
└── terraform/                     # Different service, different infra
    ├── main.tf
    └── ecs.tf
```

**Who uses this:**

- Tech companies (Netflix, Spotify, AWS, etc.)
- Cloud-native startups
- Organizations practicing "you build it, you run it"
- Teams with strong DevOps culture
- Microservices architectures

**Workflow:**

1. Developer wants to deploy new service
2. Makes changes in **same repo** (both code and infrastructure)
3. CI/CD runs `terraform apply` + builds/deploys app
4. Everything deploys together atomically

**Key Characteristic:** Infrastructure and application code are **coupled**.

---

#### When to Use Centralized Repository

✅ **Good for:**

- **Traditional organizations**: Separate ops and dev teams
- **Strict change control**: All infrastructure changes require approval
- **Shared infrastructure**: Multiple apps use same RDS, same Redis
- **Brownfield migrations**: Importing existing infrastructure (like this project)
- **Small engineering teams**: 1-2 platform engineers managing infra for 10+ apps
- **Compliance requirements**: Centralized audit trail for all infrastructure
- **Learning curve**: Team still learning Terraform
- **Multi-tenant platforms**: One team manages infrastructure for multiple customers

✅ **Benefits:**

- Platform team has complete visibility and control
- Easier to enforce standards (all Terraform in one place)
- Can refactor shared resources without touching app repos
- Single source of truth for all infrastructure
- Easier to audit and comply with regulations
- Less duplication (shared modules, shared state backends)

❌ **Drawbacks:**

- Platform team becomes a bottleneck (every change needs their review)
- Slower iteration (can't deploy infra and app together)
- Less ownership for app teams (they don't control their infrastructure)
- Infrastructure changes lag behind app development
- Large blast radius (one Terraform state has many services)

---

#### When to Use Distributed (Terraform in App Repos)

✅ **Good for:**

- **Cloud-native organizations**: Teams own their entire stack
- **Microservices**: Each service is independent
- **Fast iteration**: Deploy 10x/day without waiting for infra team
- **Clear ownership**: Team owns code + infrastructure + operations
- **Greenfield projects**: Building new services from scratch
- **Service-specific resources**: Each service has its own DB, cache, ALB
- **Strong DevOps culture**: Engineers comfortable with infrastructure
- **Decentralized teams**: Multiple autonomous teams

✅ **Benefits:**

- Teams move faster (no waiting for platform team approval)
- Infrastructure and code evolve together (same PR)
- Clear ownership (team responsible for everything)
- Reduced blast radius (each app has its own Terraform state)
- Easier to delete services (delete repo = delete everything)
- Promotes "you build it, you run it" culture

❌ **Drawbacks:**

- Duplication across repos (every service has similar Terraform)
- Harder to enforce standards (need linting, policy as code)
- Harder to audit (infrastructure spread across 100 repos)
- Shared resources are challenging (who owns the VPC?)
- Requires mature engineering culture (trust teams with infra)
- More complex CI/CD (each repo needs Terraform pipeline)

---

#### Hybrid Approach (Most Common in Practice)

**Structure:**

```
mycompany-platform-infrastructure/  # Centralized
└── terraform/
    └── shared/
        ├── vpc/                    # Shared VPC
        ├── rds-shared/             # Shared database
        └── monitoring/             # Central monitoring

mycompany-auth-api/                 # App repo
├── src/
└── terraform/                      # Service-specific only
    ├── ecs.tf                      # ECS service
    ├── alb.tf                      # Dedicated ALB
    └── data.tf                     # References shared VPC
```

**What goes where:**

| Resource Type            | Centralized Repo | App Repos |
| ------------------------ | ---------------- | --------- |
| **VPCs, Subnets, NAT**   | ✅ Platform      | —         |
| **Shared RDS**           | ✅ Platform      | —         |
| **Shared ElastiCache**   | ✅ Platform      | —         |
| **Shared ALB**           | ✅ Platform      | —         |
| **Service-specific ECS** | —                | ✅ App    |
| **Service-specific RDS** | —                | ✅ App    |
| **Service-specific ALB** | —                | ✅ App    |
| **Security Groups**      | Both             | Both      |
| **IAM Roles**            | —                | ✅ App    |
| **Secrets Manager**      | —                | ✅ App    |

**This is the recommended pattern for most organizations.**

---

#### Real-World Example: Hybrid in Action

**Scenario:** E-commerce platform with 10 microservices

**Platform Infrastructure Repo:**

```
platform-infrastructure/
└── terraform/
    └── production/
        ├── vpc/
        │   └── main.tf              # VPC, subnets, NAT
        ├── shared-rds/
        │   └── main.tf              # Shared Postgres (product catalog)
        └── monitoring/
            └── main.tf              # Datadog, CloudWatch
```

**Auth Service Repo (owned by Identity team):**

```
auth-service/
├── src/
│   └── api/
├── terraform/
│   ├── main.tf
│   ├── ecs.tf                       # Dedicated ECS service
│   ├── rds.tf                       # Dedicated user DB
│   ├── alb.tf                       # auth.example.com ALB
│   └── data.tf                      # References shared VPC
└── .github/workflows/
    └── deploy.yml
```

**Checkout Service Repo (owned by Payments team):**

```
checkout-service/
├── src/
├── terraform/
│   ├── ecs.tf                       # Dedicated ECS service
│   ├── redis.tf                     # Dedicated cart cache
│   └── data.tf                      # References shared VPC + shared RDS
└── .github/workflows/
    └── deploy.yml
```

**Result:**

- Platform team manages VPC (changes monthly)
- Auth team deploys `auth-service` independently (10x/day)
- Payments team deploys `checkout-service` independently (5x/day)
- No blocking, no conflicts, clear ownership

---

#### How App Repos Reference Shared Infrastructure

**Option 1: `terraform_remote_state` (Explicit)**

```hcl
# auth-service/terraform/data.tf
data "terraform_remote_state" "vpc" {
  backend = "s3"
  config = {
    bucket = "mycompany-terraform-state"
    key    = "platform/vpc/terraform.tfstate"
    region = "us-east-1"
  }
}

resource "aws_ecs_service" "auth" {
  network_configuration {
    subnets = data.terraform_remote_state.vpc.outputs.private_subnet_ids
  }
}
```

**Option 2: SSM Parameter Store (Decoupled)**

Platform repo exports to SSM:

```hcl
# platform-infrastructure/vpc/outputs.tf
resource "aws_ssm_parameter" "vpc_id" {
  name  = "/platform/vpc/id"
  type  = "String"
  value = aws_vpc.main.id
}
```

App repo reads from SSM:

```hcl
# auth-service/terraform/data.tf
data "aws_ssm_parameter" "vpc_id" {
  name = "/platform/vpc/id"
}

resource "aws_security_group" "auth" {
  vpc_id = data.aws_ssm_parameter.vpc_id.value
}
```

**Option 3: Data Sources (AWS API)**

```hcl
# auth-service/terraform/data.tf
data "aws_vpc" "main" {
  tags = {
    Name = "production-vpc"
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  tags = {
    Tier = "private"
  }
}
```

**Recommendation:** Start with remote state, move to SSM if you need stronger decoupling.

---

#### Governance and Standards with Distributed Terraform

**Challenge:** How do you prevent chaos when 50 teams manage their own infrastructure?

**Solutions:**

**1. Terraform Modules (Enforce Patterns)**

Platform team provides reusable modules:

```hcl
# auth-service/terraform/main.tf
module "fargate_service" {
  source = "git::https://github.com/mycompany/terraform-modules.git//fargate-service?ref=v2.0.0"

  service_name = "auth-service"
  container_image = var.image_uri
  container_port = 3000

  # Module handles: ECS service, task def, target group, ALB rule, IAM, security groups
}
```

**2. Policy as Code (Validate Changes)**

Use tools like:

- **Terraform Sentinel** (HashiCorp Cloud)
- **Open Policy Agent (OPA)** with Conftest
- **Checkov** (security scanning)

```rego
# Example OPA policy
deny[msg] {
  resource := input.resource_changes[_]
  resource.type == "aws_security_group"

  rule := resource.change.after.ingress[_]
  rule.cidr_blocks[_] == "0.0.0.0/0"

  msg := sprintf("Security group %s has overly permissive ingress rule", [resource.name])
}
```

**3. CI/CD Enforcement**

```yaml
# Required checks before merge:
- terraform fmt -check
- terraform validate
- tflint
- checkov --framework terraform
- conftest test terraform-plan.json
- terraform plan (manual review)
```

**4. Self-Service Platform**

Platform team provides:

- Terraform module library
- Pre-approved patterns
- Documentation and examples
- Scaffolding tool (`create-new-service` CLI)

---

#### Common Pitfall: Code Ownership Conflicts

**The Problem:**

When you put Terraform in app repos, you often run into this organizational issue:

```
auth-service/
├── src/                    # App team owns and reviews
│   └── api/
├── terraform/              # Platform team needs to review
│   ├── ecs.tf
│   └── iam.tf
└── CODEOWNERS              # Who reviews what?
```

**What goes wrong:**

1. **App team are code owners** for their repo
2. **Platform team needs to review** infrastructure changes
3. **App team doesn't want to review** Terraform (not their expertise)
4. **PRs sit unreviewed** for days/weeks
5. **Platform team frustrated** they can't merge their own infrastructure changes
6. **App team annoyed** they're tagged on PRs they can't evaluate

**Real-world scenario:**

```
Platform engineer opens PR:
- Changes: terraform/ecs.tf (increase CPU from 512 to 1024)
- Required reviewers: App team (repo owners)
- App team response: "We don't know if this is safe, ask platform team"
- Platform team: "We ARE the platform team, we wrote this!"
- PR sits for 2 weeks unmerged
```

This defeats the purpose of distributed infrastructure!

---

#### Solution 1: CODEOWNERS with Path-Based Reviewers

Use GitHub's `CODEOWNERS` file to assign different reviewers based on file paths:

```
# auth-service/.github/CODEOWNERS

# App team owns application code
/src/**                    @mycompany/auth-team

# Platform team owns infrastructure code
/terraform/**              @mycompany/platform-team
/.github/workflows/**      @mycompany/platform-team

# Shared ownership for Dockerfile (needs both perspectives)
/Dockerfile                @mycompany/auth-team @mycompany/platform-team
```

**How it works:**

- PR touching `src/api/handler.js` → Auto-requests `@auth-team`
- PR touching `terraform/ecs.tf` → Auto-requests `@platform-team`
- PR touching both → Requests both teams (only need approval from relevant paths)

**Limitations:**

- Requires GitHub Teams (works in GitHub Enterprise, paid plans)
- GitLab equivalent: [`CODEOWNERS`](https://docs.gitlab.com/ee/user/project/codeowners/)
- Bitbucket equivalent: [Default Reviewers](https://confluence.atlassian.com/bitbucketserver/default-reviewers-776639802.html)

---

#### Solution 2: Separate PRs via Branching Strategy

Platform team uses dedicated infrastructure branches:

```bash
# Platform engineer workflow:
git checkout -b infra/increase-ecs-cpu
# Edit terraform/ecs.tf
git push origin infra/increase-ecs-cpu
# Open PR: infra/increase-ecs-cpu → main
```

Configure branch protection rules:

```yaml
# .github/workflows/require-platform-review.yml
name: Require Platform Review

on:
  pull_request:
    branches: [main]
    paths:
      - "terraform/**"

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - name: Check if platform team approved
        uses: dependabot/fetch-metadata@v1
        # Custom action that verifies @platform-team approval
```

**Benefits:**

- Visual cue (`infra/*` branch prefix)
- Can skip app team review entirely for infrastructure-only changes
- Works with any Git hosting platform

**Drawbacks:**

- Requires discipline (remembering to use branch prefix)
- Can't fully automate enforcement without custom tooling

---

#### Solution 3: Infrastructure in Separate Repo (Reverting to Hybrid)

Acknowledge the distributed model isn't working and move Terraform back to platform repo:

**Before (Distributed - causing conflicts):**

```
auth-service/
├── src/
└── terraform/          # ← Causing review bottleneck
```

**After (Hybrid - cleaner boundaries):**

```
platform-infrastructure/
└── terraform/
    └── services/
        └── auth-service/    # ← Moved here
            ├── ecs.tf
            └── iam.tf

auth-service/
└── src/                     # App team owns 100% of this repo
```

**What changes:**

- Platform team has full ownership of infrastructure repo
- App team never sees Terraform PRs
- Clearer separation of concerns
- Slight loss of "infrastructure as code alongside app code" benefit

**When to do this:**

- App team explicitly doesn't want infrastructure in their repo
- Code review friction is slowing down deployments
- Platform team is the bottleneck anyway (so centralization doesn't make it worse)
- App team prefers "you manage infra, we manage code" model

---

#### Solution 4: Auto-Merge for Platform Team PRs

Configure GitHub to auto-merge platform team PRs in app repos:

```yaml
# .github/workflows/auto-merge-platform-prs.yml
name: Auto-Merge Platform PRs

on:
  pull_request_target:
    types: [opened, synchronize]
    paths:
      - "terraform/**"

jobs:
  auto-merge:
    runs-on: ubuntu-latest
    if: github.actor == 'platform-team-bot' || contains(github.event.pull_request.labels.*.name, 'platform-managed')
    steps:
      - name: Run Terraform Plan
        run: terraform plan

      - name: Run Security Checks
        run: checkov --framework terraform

      - name: Auto-approve
        run: gh pr review --approve

      - name: Auto-merge
        run: gh pr merge --auto --squash
```

**Requirements:**

- High trust in platform team
- Robust automated testing (Terraform plan, security scanning, policy checks)
- Audit trail (all changes logged)

**Benefits:**

- Platform team self-services infrastructure changes
- App team not bothered with reviews
- Automation enforces safety checks

**Risks:**

- Less human oversight
- Requires mature CI/CD and policy-as-code

---

#### Solution 5: Dedicated Infrastructure Repos per Service

Extreme version: Every service gets TWO repos:

```
auth-service/                    # App team owns
└── src/

auth-service-infrastructure/     # Platform team owns
└── terraform/
```

**Workflow:**

1. Platform team manages `auth-service-infrastructure`
2. App team manages `auth-service`
3. CI/CD in `auth-service` references infrastructure outputs

**When this makes sense:**

- Very large services (100+ resources in Terraform)
- Different compliance requirements (infrastructure changes need SOC2 audit)
- Completely separate teams with zero overlap

**Drawbacks:**

- Lots of repos (2× the number of services)
- Harder to discover ("where's the Terraform for auth-service?")
- More complex to coordinate changes across repos

---

#### Comparison: Which Solution for Which Problem?

| Problem                                       | Solution                        | Complexity | Effectiveness |
| --------------------------------------------- | ------------------------------- | ---------- | ------------- |
| App team doesn't know how to review Terraform | CODEOWNERS                      | Low        | ✅ High       |
| Platform PRs sit unreviewed                   | CODEOWNERS                      | Low        | ✅ High       |
| App team explicitly rejects Terraform in repo | Move to Hybrid (Solution 3)     | Medium     | ✅ High       |
| Platform team trusted, mature CI/CD           | Auto-Merge (Solution 4)         | Medium     | ✅ High       |
| Need human review but faster turnaround       | Branching Strategy (Solution 2) | Low        | ⚠️ Medium     |
| Regulatory compliance, separate audit trails  | Separate Repos (Solution 5)     | High       | ✅ High       |

---

#### Recommended Approach for Your Situation

Based on your description ("app teams just didn't want to do it"), here's the progression:

**Immediate Fix (This Week):**

Implement `CODEOWNERS`:

```
# .github/CODEOWNERS
/terraform/**              @mycompany/platform-team
/src/**                    @mycompany/app-team
```

This solves 80% of the problem with minimal effort.

**If that doesn't work (Next Month):**

Move Terraform back to centralized infrastructure repo:

```
platform-infrastructure/
└── terraform/
    └── services/
        ├── auth-service/
        ├── billing-service/
        └── user-service/
```

Acknowledge that distributed model requires buy-in from app teams, and if they don't want it, forcing it creates friction.

**Long-term (3-6 Months):**

If you want to keep distributed model:

1. Build better tooling (Terraform modules that hide complexity)
2. Automate reviews (policy-as-code checks instead of human review)
3. Educate app teams (Terraform training, pair programming)
4. Create incentives (faster deployments if they own their infrastructure)

**But honestly:** If app teams don't want to own infrastructure, don't force it. The centralized hybrid model works great for many successful companies.

---

#### Migration Strategy: Centralized → Distributed

**If you're currently centralized and want to distribute:**

**Phase 1: Extract Modules**

Move common patterns to reusable modules:

```
terraform-modules/
├── fargate-service/
├── rds-postgres/
└── alb-target-group/
```

**Phase 2: Pilot with One Service**

1. Create `terraform/` folder in one app repo
2. Move that service's resources from central repo
3. Update CI/CD to apply from app repo
4. Validate for 2 weeks

**Phase 3: Scale to All Services**

1. Migrate one service per week
2. Eventually deprecate central `10-application` layer
3. Keep central `00-network` layer (shared foundation)

**Timeline:** 3-6 months for 10 services

---

#### Decision Matrix: Centralized vs Distributed

| Factor                   | Centralized   | Distributed   | Hybrid       |
| ------------------------ | ------------- | ------------- | ------------ |
| **Team maturity**        | Any           | High          | Medium-High  |
| **Org culture**          | Traditional   | DevOps        | Mixed        |
| **Change velocity**      | Slow (weekly) | Fast (daily)  | Medium       |
| **Team size**            | 1-5 platform  | 10+ engineers | 5+ engineers |
| **Service count**        | Any           | 10+           | 5+           |
| **Shared resources**     | Many          | Few           | Some         |
| **Compliance**           | Strict        | Moderate      | Moderate     |
| **Blast radius comfort** | Low           | High          | Medium       |

---

#### For This Migration Project

**Recommendation: Start Centralized, Evolve to Hybrid**

**Phase -1 to Phase 2 (Months 1-3):**

- Use centralized infrastructure repo (what we've documented)
- Reason: You're importing existing resources, easier to manage in one place

**Phase 4+ (Months 4-6):**

- Migrate to hybrid model as teams gain Terraform experience
- Platform repo: VPC, shared RDS, shared ElastiCache
- App repos: ECS services, service-specific ALBs

**Long-term (6+ months):**

- Fully distributed if team culture supports it
- Each microservice owns its complete stack

**Why this path?**

- Brownfield migrations are complex → centralized reduces moving parts
- Once stable, distribution increases team velocity
- Your team is learning Terraform → crawl before you run

---

### State Backend Configuration

**Bootstrap (One-Time Setup):**

```hcl
# terraform/bootstrap/main.tf
resource "aws_s3_bucket" "terraform_state" {
  bucket = "mycompany-terraform-state"
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_dynamodb_table" "terraform_locks" {
  name         = "terraform-state-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
```

**Reference in Each Layer:**

```hcl
# 00-network/main.tf
terraform {
  backend "s3" {
    bucket         = "mycompany-terraform-state"
    key            = "dev/00-network/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
}

# 10-application/main.tf
terraform {
  backend "s3" {
    bucket         = "mycompany-terraform-state"
    key            = "dev/10-application/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
}
```

---

### CI/CD Integration

#### GitHub Actions Workflow (Per Layer)

```yaml
# .github/workflows/terraform-application.yml
name: Terraform Application Layer

on:
  push:
    branches: [main]
    paths:
      - "terraform/environments/dev/10-application/**"

jobs:
  terraform:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: terraform/environments/dev/10-application

    steps:
      - uses: actions/checkout@v3

      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v2
        with:
          role-to-assume: arn:aws:iam::123456789012:role/GitHubActionsRole
          aws-region: us-east-1

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v2
        with:
          terraform_version: 1.7.0

      - name: Terraform Init
        run: terraform init

      - name: Terraform Plan
        run: terraform plan -out=tfplan

      - name: Terraform Apply
        if: github.ref == 'refs/heads/main'
        run: terraform apply -auto-approve tfplan
```

---

### Automation Strategy

#### Level 1: Manual (Phase -1 to Phase 2)

- Engineers run `terraform apply` locally
- PRs reviewed by infrastructure team
- Good for: Initial migration, learning Terraform

#### Level 2: CI/CD Plan (Phase 3)

- GitHub Actions runs `terraform plan` on PRs
- Engineers still apply manually
- Good for: Safety checks, preventing drift

#### Level 3: Auto-Apply (Phase 4+)

- GitHub Actions runs `terraform apply` on main branch
- App teams self-service new services
- Infrastructure team reviews via PR approval
- Good for: Scale, velocity, repeatability

**Recommended Progression:**

- **Months 1-2**: Manual (Level 1)
- **Months 3-4**: CI/CD Plan (Level 2)
- **Month 5+**: Auto-Apply for `10-application` (Level 3)
- **Always**: Manual for `00-network` (critical infrastructure)

---

### Security & Compliance

#### State File Protection

```hcl
resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
```

#### Least Privilege IAM for Terraform

**Network Layer Role:**

```json
{
  "Effect": "Allow",
  "Action": [
    "ec2:*Vpc*",
    "ec2:*Subnet*",
    "ec2:*InternetGateway*",
    "ec2:*NatGateway*",
    "ec2:*RouteTable*"
  ],
  "Resource": "*"
}
```

**Application Layer Role:**

```json
{
  "Effect": "Allow",
  "Action": [
    "ecs:*",
    "elasticloadbalancing:*",
    "rds:*",
    "elasticache:*",
    "secretsmanager:*",
    "iam:*Role*",
    "iam:*Policy*"
  ],
  "Resource": "*"
}
```

---

### Troubleshooting

#### Common Issues

**Issue: `terraform plan` shows unwanted changes after import**

**Solution:**

```bash
# Add to lifecycle block:
lifecycle {
  ignore_changes = [
    tags["CreatedBy"],
    user_data,
  ]
}
```

**Issue: Circular dependency between layers**

**Solution:**

- Network layer should NEVER reference application layer
- Flow: `00-network` outputs → `10-application` data sources

**Issue: State locking errors**

**Solution:**

```bash
# Force unlock (use with caution!)
terraform force-unlock <lock-id>

# Check DynamoDB for stuck locks
aws dynamodb scan --table-name terraform-state-lock
```

---

### Migration Checklist

- [ ] Bootstrap S3 and DynamoDB for state backend
- [ ] Create layered folder structure (`00-network`, `10-application`)
- [ ] Import existing VPC resources into `00-network`
- [ ] Import existing EC2/RDS into `10-application`
- [ ] Verify `terraform plan` shows zero changes
- [ ] Document all import commands in `IMPORT_COMMANDS.md`
- [ ] Set up CI/CD for `terraform plan` on PRs
- [ ] Define team ownership and approval workflows
- [ ] Train teams on `terraform_remote_state` pattern
- [ ] Establish naming conventions for resources
- [ ] Create reusable modules for common patterns

---

## 11. Base Image Strategy (Golden Images)

### Overview

Using a custom "Base Image" (often called a **"Golden Image"**) is a very common pattern in enterprise environments, but it is a **double-edged sword.**

For a brownfield migration, it often adds unnecessary friction. Here is the breakdown of whether you should do it, and if so, how.

**Common pattern:**

```
Your Base Image (mycompany/node-base:20)
  ├── Node.js 20
  ├── Common npm packages (lodash, express, etc.)
  ├── Security scanning tools
  ├── Monitoring agents (DataDog, New Relic)
  └── Standard hardening

Your App Images
  ├── app1:latest → FROM mycompany/node-base:20
  ├── app2:latest → FROM mycompany/node-base:20
  └── app3:latest → FROM mycompany/node-base:20
```

---

### Is it a Best Practice?

**Yes, for established enterprises.**  
**No, for early-stage migrations (usually).**

| **Pros (Why do it?)**                                                                                                                                                               | **Cons (Why avoid it?)**                                                                                                                                                          |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Security Governance:** You can ensure _every_ container has the latest OS patches, corporate SSL certificates, and security hardening (e.g., removing shell access) in one place. | **Maintenance Burden:** You now own an OS distribution. You must patch it weekly. If `node:20-alpine` updates, _you_ have to rebuild your base image before your apps can use it. |
| **Build Speed:** If your apps all need heavy tools (e.g., Python for `node-gyp`, specific C libraries), installing them once in the base image saves 2-3 minutes per build.         | **Coupling:** If you break the base image, you break the build pipeline for _all_ your applications instantly.                                                                    |
| **Standardization:** Forces every team to use the exact same Node version and OS configuration. Ensures consistency across all services.                                            | **"It works on my machine":** Developers might use standard Node locally but the custom Base Image in CI, causing subtle bugs.                                                    |
| **Compliance:** Embed required security agents (vulnerability scanners, log forwarders, SIEM integrations) that must be present in every container.                                 | **Versioning Complexity:** Must manage base image versions carefully. Breaking changes in the base image cascade to all services.                                                 |

---

### Recommendation for Brownfield Migration

**The Golden Rule:** Base images are a **scaling optimization**, not a starting point. Ship working containers first, optimize later.

**Don't do this for initial containerization (Phase 1-2).**  
Stick to standard multi-stage builds (e.g., `FROM node:20-alpine`) inside your application Dockerfiles.

**Move this to Phase 4+ (Optimization & Hardening).**  
Once you have 2+ services running in production and the Security team demands specific hardening (like "CIS Benchmarks"), _then_ extract the common layers into a Base Image.

**Migration Timeline:**

```
Phase 1-2: Use node:20-alpine (get to Fargate fast)
  ├── Focus: Containerization & initial deployment
  └── Goal: Working containers in production

Phase 3: Stabilize & Monitor
  ├── Focus: Observability, performance tuning
  └── Goal: Reliable production workloads

Phase 4+: Introduce Base Images (if needed)
  ├── Focus: Standardization & security hardening
  └── Goal: Enterprise-grade container governance
```

**Real-world adoption pattern:**

Most teams follow this sequence:

```
Migration Timeline:
├── Month 1: Use node:20-alpine (get to Fargate fast)
├── Month 2: Stabilize, monitor, tune
└── Month 3: Introduce base images if needed
```

---

### Benefits of Base Images

1. **Faster builds:** Common layers cached, only rebuild app code
2. **Consistency:** All apps use same Node version, same security patches
3. **Security:** Patch base image once, rebuild all apps to inherit fixes
4. **Compliance:** Embed required agents (vulnerability scanners, log forwarders)
5. **Smaller app Dockerfiles:** Less duplication

---

### Trade-offs

| Aspect               | Without Base Image                 | With Base Image                    |
| -------------------- | ---------------------------------- | ---------------------------------- |
| **Initial setup**    | Fast (use `node:20-alpine`)        | Slower (build base first)          |
| **Build time**       | Slower (reinstall everything)      | Faster (cached layers)             |
| **Consistency**      | Manual (each Dockerfile different) | Automatic (inherit from base)      |
| **Security patches** | Rebuild each app individually      | Rebuild base → rebuild apps        |
| **Complexity**       | Low                                | Medium (maintain base images)      |
| **Best for**         | 1-2 apps, rapid migration          | 3+ apps, long-term standardization |

---

### When Base Images Are Critical (Do First)

Only prioritize base images **before migration** if:

- ✅ Security/compliance requires pre-approved hardened images
- ✅ Corporate policy forbids pulling from Docker Hub
- ✅ You need embedded agents (vulnerability scanning, SIEM integration)
- ✅ Air-gapped environment (must use internal registry)

Otherwise, **containerize first with standard images**, then optimize with base images once you have working Fargate deployments.

---

### How to Implement a Custom Base Image (The "Golden Image" Workflow)

If you decide to proceed, here is the technical implementation. You treat the Base Image as its own software project with its own lifecycle.

#### Step 1: Create a Repository for the Base Image

Create a new repo (or folder) `infrastructure/base-images` or `docker-base-images`.

**Directory structure:**

```
infrastructure/base-images/
├── node-20/
│   ├── Dockerfile
│   └── README.md
├── python-311/
│   ├── Dockerfile
│   └── README.md
└── .github/
    └── workflows/
        └── build-base-images.yml
```

**Example `Dockerfile` for Node.js base image:**

```dockerfile
# infrastructure/base-images/node-20/Dockerfile
FROM node:20-alpine

# 1. OS Updates & Security Patches (The main reason to do this)
RUN apk update && apk upgrade --no-cache

# 2. Install global dependencies required by ALL your apps
# Example: 'tini' (init process), 'curl' (for healthchecks)
RUN apk add --no-cache \
    tini \
    curl \
    ca-certificates

# 3. Create the non-root user (Standardize across all apps)
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

# 4. Install common npm packages globally (optional)
# Only include packages used by MOST/ALL services
# RUN npm install -g pm2 dotenv

# 5. Security hardening (remove package manager to prevent runtime installs)
# RUN rm -rf /var/cache/apk/* /usr/bin/apk

# 6. Set global defaults
WORKDIR /app
RUN chown appuser:appgroup /app

# Use tini as init process (handles signals properly)
ENTRYPOINT ["/sbin/tini", "--"]

# Metadata
LABEL maintainer="devops@company.com"
LABEL org.opencontainers.image.source="https://github.com/your-org/base-images"
LABEL org.opencontainers.image.description="Node.js 20 base image with security hardening"
```

#### Step 2: Build & Push to ECR (The Pipeline)

You need a **separate** GitHub Action for this repository.

**Trigger:**

- On push to `main` OR
- On a schedule (e.g., weekly) to pick up security patches

**Tagging Strategy:**

- **Do NOT just use `latest`**
- Use Semantic Versioning: `v1.0.0`, `v1.0.1`, `v1.1.0`
- Include date for traceability: `v1.0.1-20260127`
- Tag both specific version AND latest: `v1.0.1` + `latest`

**Example GitHub Actions workflow:**

```yaml
# .github/workflows/build-base-images.yml
name: Build Base Images

on:
  push:
    branches: [main]
    paths:
      - "node-20/**"
  schedule:
    - cron: "0 2 * * 1" # Weekly on Monday at 2 AM UTC
  workflow_dispatch: # Manual trigger

permissions:
  id-token: write
  contents: read

jobs:
  build-node-base:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789012:role/GitHubActionsECRPush
          aws-region: us-east-1

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Generate version tag
        id: version
        run: |
          VERSION="v1.0.0"  # Update this manually or use git tags
          DATE=$(date +%Y%m%d)
          echo "tag=${VERSION}-${DATE}" >> $GITHUB_OUTPUT
          echo "version=${VERSION}" >> $GITHUB_OUTPUT

      - name: Build and push Node.js base image
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          ECR_REPOSITORY: base-images/node-20
          IMAGE_TAG: ${{ steps.version.outputs.tag }}
          VERSION_TAG: ${{ steps.version.outputs.version }}
        run: |
          docker build \
            -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG \
            -t $ECR_REGISTRY/$ECR_REPOSITORY:$VERSION_TAG \
            -t $ECR_REGISTRY/$ECR_REPOSITORY:latest \
            ./node-20/

          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$VERSION_TAG
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:latest

      - name: Scan image for vulnerabilities
        run: |
          # Use Trivy or AWS ECR scanning
          docker run --rm \
            -v /var/run/docker.sock:/var/run/docker.sock \
            aquasec/trivy image \
            ${{ steps.login-ecr.outputs.registry }}/base-images/node-20:${{ steps.version.outputs.tag }}
```

**Example ECR Repository URI:**

```
123456789012.dkr.ecr.us-east-1.amazonaws.com/base-images/node-20:v1.0.0-20260127
123456789012.dkr.ecr.us-east-1.amazonaws.com/base-images/node-20:v1.0.0
123456789012.dkr.ecr.us-east-1.amazonaws.com/base-images/node-20:latest
```

#### Step 3: Update Your Application Dockerfiles

Now, your application services consume this image instead of the public Docker Hub image.

**Before (using public image):**

```dockerfile
# services/auth-service/Dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production
COPY . .
USER node
CMD ["node", "src/server.js"]
```

**After (using golden image):**

```dockerfile
# services/auth-service/Dockerfile

# --- Builder Stage (Still uses public image for compilation tools) ---
FROM node:20-alpine AS builder
WORKDIR /build
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# --- Runner Stage (Uses YOUR Golden Image) ---
# ARG allows you to override the version in CI if needed
ARG BASE_IMAGE_VERSION=v1.0.0
FROM 123456789012.dkr.ecr.us-east-1.amazonaws.com/base-images/node-20:${BASE_IMAGE_VERSION}

WORKDIR /app

# The user 'appuser' already exists because you made it in the Base Image
# Copy built artifacts from builder stage
COPY --from=builder --chown=appuser:appgroup /build/dist ./dist
COPY --from=builder --chown=appuser:appgroup /build/node_modules ./node_modules

USER appuser
CMD ["node", "dist/index.js"]
```

**With build args in CI:**

```yaml
# .github/workflows/deploy-auth-service.yml
- name: Build application image
  run: |
    docker build \
      --build-arg BASE_IMAGE_VERSION=v1.0.0 \
      -t $ECR_REGISTRY/auth-service:$IMAGE_TAG \
      ./services/auth-service/
```

---

### Critical IAM Permissions for Private Base Images

If you use a **Private Base Image** (hosted in your own ECR), your ECS Fargate Task needs permission to pull it.

You must update your **Terraform IAM Code** for the "Task Execution Role":

```hcl
# terraform/modules/iam/ecs-task-execution-role.tf

# Create ECR repository for base images
resource "aws_ecr_repository" "base_image_node" {
  name                 = "base-images/node-20"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name        = "base-images-node-20"
    Environment = var.environment
  }
}

# Task Execution Role Policy
resource "aws_iam_role_policy" "ecr_pull_permissions" {
  name = "ecr-pull-permissions"
  role = aws_iam_role.ecs_task_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        # Allow pulling from BOTH the Base Image Repo AND the App Repo
        Resource = [
          aws_ecr_repository.auth_service.arn,
          aws_ecr_repository.crud_service.arn,
          aws_ecr_repository.base_image_node.arn  # <--- Don't forget this!
        ]
      }
    ]
  })
}
```

**Common mistake:** Forgetting to grant ECR permissions for the base image repository, causing Fargate tasks to fail with `CannotPullContainerError`.

---

### Maintenance Strategy

Once you have a base image, you **must** maintain it:

#### Weekly Security Patching

```bash
# Automated weekly rebuild (via GitHub Actions schedule)
# Picks up latest Alpine security patches
# Triggers rebuild of all application images that depend on it
```

#### Version Upgrade Path

1. **Base image update released:** `v1.0.0` → `v1.1.0`
2. **Test in dev environment:** Update one service's Dockerfile to use `v1.1.0`
3. **Validate compatibility:** Run integration tests
4. **Gradual rollout:** Update other services one-by-one
5. **Deprecate old version:** After 30 days, remove `v1.0.0` tag

#### Breaking Changes

If base image has breaking changes (e.g., removing a package):

```
v1.x.x → v2.0.0 (major version bump)
  ├── Maintain v1.x.x for 90 days (security patches only)
  ├── Communicate breaking changes to all teams
  └── Provide migration guide
```

---

### When to Use Base Images (Decision Matrix)

| **Scenario**                            | **Use Base Image?** | **Rationale**                             |
| --------------------------------------- | ------------------- | ----------------------------------------- |
| Single application, first migration     | ❌ No               | Unnecessary complexity                    |
| 2-3 applications, similar tech stack    | ⚠️ Maybe            | Consider if security requirements mandate |
| 5+ applications, standardization needed | ✅ Yes              | Economies of scale kick in                |
| Security/compliance requires hardening  | ✅ Yes              | Embed security controls once              |
| Air-gapped environment                  | ✅ Yes              | Cannot pull from Docker Hub               |
| Developer velocity is priority          | ❌ No               | Standard images are faster to iterate     |
| Production stability is priority        | ✅ Yes              | Control the entire stack                  |

---

### Alternatives to Base Images

If you want some benefits without the maintenance burden:

#### 1. **Copy-Paste Pattern** (Low-Tech)

Keep a `Dockerfile.template` with security hardening. Copy-paste into each service.

**Pros:** No dependencies, easy to customize per service  
**Cons:** No consistency enforcement, harder to patch

#### 2. **Docker Compose / Buildkit Inheritance**

Use `docker-compose.yml` with shared build context:

```yaml
# docker-compose.yml
x-node-base: &node-base
  build:
    context: ./base-images/node-20

services:
  auth-service:
    <<: *node-base
    build:
      context: ./services/auth-service
      dockerfile: Dockerfile
```

**Pros:** Share base config without ECR  
**Cons:** Doesn't work well in Fargate (local dev only)

#### 3. **Multi-Stage Builds with Shared Stage**

Keep hardening in each Dockerfile but use multi-stage to avoid duplication:

```dockerfile
# Common base stage (repeated in each Dockerfile)
FROM node:20-alpine AS hardened-base
RUN apk update && apk upgrade --no-cache
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

# Application stage
FROM hardened-base
COPY --chown=appuser:appgroup . /app
USER appuser
CMD ["node", "server.js"]
```

**Pros:** No external dependencies, still get layer caching  
**Cons:** Repeated code, harder to enforce standards

---

### Real-World Example: Migration Path

**Week 1-4:** Use standard images

```dockerfile
FROM node:20-alpine
# ... application code
```

**Week 5-8:** Add hardening inline (multi-stage)

```dockerfile
FROM node:20-alpine AS base
RUN apk update && apk upgrade
RUN adduser -D appuser

FROM base
COPY --chown=appuser . /app
USER appuser
CMD ["node", "server.js"]
```

**Week 9+:** Extract to base image (if 3+ services)

```dockerfile
FROM 123456789012.dkr.ecr.us-east-1.amazonaws.com/base-images/node-20:v1.0.0
COPY --chown=appuser . /app
USER appuser
CMD ["node", "server.js"]
```

---

### Summary for Migration Roadmap

- **Phase 1-2 (Containerization):** **Skip base images.** Use `FROM node:20-alpine`. It's faster and one less dependency to manage.
- **Phase 3 (Stabilization):** Monitor if you're copy-pasting complex security setups between Dockerfiles.
- **Phase 4+ (Optimization):** Introduce base images _if_ you have 3+ services and security/compliance requirements justify the maintenance overhead.

**Bottom line:** Base images are a best practice for production at scale, but they're an optimization, not a requirement. Get your apps containerized and running in Fargate first, then introduce base images as a refinement.

---

## 12. Additional Resources

- [Terraform Best Practices](https://www.terraform-best-practices.com/)
- [AWS Provider Documentation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [Terraform State Management](https://developer.hashicorp.com/terraform/language/state)
- [Terraform Import Documentation](https://developer.hashicorp.com/terraform/cli/import)
