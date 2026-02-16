# Appendix: AWS Identity Center (SSO) - Deep Dive

## Overview

**AWS Identity Center** (formerly AWS SSO) provides centralized access management for multiple AWS accounts. Instead of creating IAM users in each account, you authenticate once through an identity provider and get temporary credentials for all accounts you have access to.

**Key benefits:**

- ✅ Single sign-on to multiple AWS accounts
- ✅ Temporary credentials that auto-expire (enhanced security)
- ✅ Centralized permission management
- ✅ Integration with corporate identity providers (Azure AD, Okta, Google Workspace)
- ✅ MFA enforcement at the organization level

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    AWS Organization                          │
│  ┌────────────────────────────────────────────────────────┐ │
│  │          Management Account (Identity Center)          │ │
│  │                                                          │ │
│  │  • User Directory (or Azure AD sync)                   │ │
│  │  • Permission Sets (e.g., AdministratorAccess)         │ │
│  │  • Account Assignments (who gets what access)          │ │
│  └────────────────────────────────────────────────────────┘ │
│                          ↓ Grants Access                     │
│  ┌──────────────────┐   ┌──────────────────┐               │
│  │  Dev Account     │   │  Prod Account    │               │
│  │  111111111111    │   │  222222222222    │               │
│  │                  │   │                  │               │
│  │  IAM Roles:      │   │  IAM Roles:      │               │
│  │  • AWSAdministr  │   │  • AWSAdministr  │               │
│  │    atorAccess    │   │    atorAccess    │               │
│  │  • ReadOnlyAccess│   │  • ReadOnlyAccess│               │
│  └──────────────────┘   └──────────────────┘               │
└─────────────────────────────────────────────────────────────┘
                          ↓
                   User Authenticates
                          ↓
┌─────────────────────────────────────────────────────────────┐
│                  Developer's Laptop                          │
│                                                              │
│  1. User runs: aws sso login --profile {profile name}            │
│  2. Browser opens → User authenticates with IdP             │
│  3. AWS CLI caches credentials locally                      │
│  4. User can now access Dev account with temp credentials   │
└─────────────────────────────────────────────────────────────┘
```

---

## How SSO Authentication Works

### Step 1: Initial Configuration

When you run `aws configure sso`, the CLI guides you through setup:

```bash
$ aws configure sso
SSO session name (Recommended): mycompany
SSO start URL [None]: https://d-xxxxxxxxxx.awsapps.com/start
SSO region [None]: us-east-1
SSO registration scopes [sso:account:access]:
```

**What happens:**

1. **SSO Session Creation**: The CLI registers a new SSO session named "mycompany"
2. **Device Authorization**: The CLI contacts AWS to get a device authorization code
3. **Browser Authentication**: Opens your browser to authenticate with your identity provider
4. **Token Exchange**: After successful authentication, AWS returns an access token
5. **Account Discovery**: The CLI fetches the list of AWS accounts you can access
6. **Role Selection**: You choose which account and role to configure for this profile

**Files Created:**

```bash
~/.aws/config      # Profile configuration
~/.aws/sso/cache/  # SSO session tokens
```

### Step 2: Profile Configuration

After authentication, you configure the profile:

```bash
There are 2 AWS accounts available to you.
> 111111111111 (dev-account)
  222222222222 (prod-account)

There are 2 roles available to you.
> AWSAdministratorAccess
  ReadOnlyAccess

CLI default client Region [None]: us-east-1
CLI default output format [None]: json
CLI profile name [AWSAdministratorAccess-111111111111]: mycompany-dev
```

**Result in `~/.aws/config`:**

```ini
[profile mycompany-dev]
sso_session = mycompany
sso_account_id = 111111111111
sso_role_name = AWSAdministratorAccess
region = us-east-1
output = json

[sso-session mycompany]
sso_start_url = https://d-xxxxxxxxxx.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access
```

### Step 3: Daily Login

Each day (or when your session expires), you run:

```bash
$ aws sso login --profile mycompany-dev
```

**What happens:**

1. **Check Cached Token**: CLI checks `~/.aws/sso/cache/` for valid token
2. **If Expired**: Opens browser for re-authentication
3. **OIDC Flow**: Completes OpenID Connect authentication with Identity Center
4. **Token Caching**: Stores new access token in cache directory
5. **Ready**: You can now use AWS CLI with this profile

**The CLI does NOT use username/password** - it uses OAuth2/OIDC tokens.

---

## Understanding Sessions vs Profiles

This is a critical concept that often confuses newcomers to AWS SSO.

### What is an SSO Session?

An **SSO session** represents your **authentication** with AWS Identity Center.

- **Purpose**: Handles the browser login and stores the OAuth token
- **Scope**: Organization-wide (all AWS accounts you have access to)
- **Name**: You choose this name (e.g., `mycompany`, `my-company`, `work`)
- **Lifetime**: 8 hours after browser authentication
- **Storage**: `~/.aws/sso/cache/<hash>.json`

**Think of it as:** Your "login" to the AWS organization.

### What is a Profile?

A **profile** is a **configuration** that specifies which AWS account and role to use.

- **Purpose**: Defines which account + role to access when you run AWS commands
- **Scope**: Specific to one AWS account + one IAM role
- **Name**: You choose this name (e.g., `mycompany-dev`, `mycompany-prod`, `my-project`)
- **Lifetime**: Permanent (stored in config file)
- **Storage**: `~/.aws/config`

**Think of it as:** A "bookmark" to a specific AWS account with specific permissions.

### The "mycompany-dev" Name

**`mycompany-dev` is just a label you choose** when setting up the profile. It has NO special meaning to AWS.

When you run `aws configure sso`, you're asked:

```bash
CLI profile name [AWSAdministratorAccess-111111111111]: mycompany-dev
                                                         ^^^^^^^^^^
                                                         You type this!
```

**You could name it anything:**

- `my-dev-account`
- `company-development`
- `jerry-dev`
- `foobar`

**Best practice:** Use a descriptive name that tells you:

- Which company/organization (`mycompany`)
- Which environment (`dev`, `prod`, `staging`)

### Relationship: One Session, Many Profiles

**The key insight:** Multiple profiles can share ONE SSO session.

```ini
# ~/.aws/config

# ONE session for the entire organization
[sso-session mycompany]                           # ← Login happens here
sso_start_url = https://d-xxxxxxxxxx.awsapps.com/start
sso_region = us-east-1

# MULTIPLE profiles using the same session
[profile mycompany-dev]                           # ← References the session
sso_session = mycompany                           # Points to [sso-session mycompany]
sso_account_id = 111111111111                 # Dev account
sso_role_name = AWSAdministratorAccess

[profile mycompany-prod]                          # ← Also references the session
sso_session = mycompany                           # Points to same [sso-session mycompany]
sso_account_id = 222222222222                 # Prod account (different)
sso_role_name = AWSAdministratorAccess

[profile mycompany-dev-readonly]                  # ← Also references the session
sso_session = mycompany                           # Points to same [sso-session mycompany]
sso_account_id = 111111111111                 # Dev account (same as mycompany-dev)
sso_role_name = ReadOnlyAccess                # Different role
```

### Visual Representation

```
┌──────────────────────────────────────────────────────────────┐
│  Developer's Laptop: ~/.aws/config                           │
├──────────────────────────────────────────────────────────────┤
│                                                               │
│  [sso-session mycompany]  ←──── ONE authentication session       │
│    • sso_start_url                                           │
│    • Stores OAuth token in ~/.aws/sso/cache/                │
│                                                               │
│         ↑              ↑              ↑                       │
│         │              │              │                       │
│         │              │              │                       │
│   [profile       [profile       [profile                     │
│    mycompany-dev]     mycompany-prod]    mycompany-dev-readonly]         │
│    • Account:     • Account:     • Account:                  │
│      975050...      987654...      975050...                 │
│    • Role:        • Role:        • Role:                     │
│      Admin          Admin          ReadOnly                  │
│                                                               │
│  THREE different "bookmarks" to different accounts/roles     │
└──────────────────────────────────────────────────────────────┘

When you run: aws s3 ls --profile mycompany-dev
              └─> Uses session "mycompany" to get credentials for
                  account 111111111111 with Admin role
```

### How This Works in Practice

**Step 1: Login ONCE to the session**

```bash
aws sso login --profile mycompany-dev
# OR
aws sso login --profile mycompany-prod
# OR
aws sso login  # If AWS_PROFILE is set
```

All of these do the **same thing** because they all use the `mycompany` session:

1. Open browser
2. Authenticate with Identity Center
3. Store OAuth token in `~/.aws/sso/cache/<hash>.json`

**Step 2: Use ANY profile**

```bash
# No need to login again - session is already valid!
aws s3 ls --profile mycompany-dev       # Uses Dev account
aws s3 ls --profile mycompany-prod      # Uses Prod account
aws s3 ls --profile mycompany-dev-readonly  # Uses Dev account with ReadOnly role
```

Each profile:

1. Reads the shared SSO token from cache
2. Requests temporary credentials for its specific account + role
3. Caches those credentials in `~/.aws/cli/cache/<profile>--<role>--<account>.json`

### File Mapping

```
Concept          Config File                Cache Files
────────────────────────────────────────────────────────────────
Session          [sso-session mycompany]        ~/.aws/sso/cache/abc123.json
"mycompany"          in ~/.aws/config           (OAuth token, 8hr lifetime)

Profile          [profile mycompany-dev]        ~/.aws/cli/cache/
"mycompany-dev"      in ~/.aws/config           mycompany-dev--AWSAdmin--975050.json
                                            (AWS credentials, 1hr lifetime)

Profile          [profile mycompany-prod]       ~/.aws/cli/cache/
"mycompany-prod"     in ~/.aws/config           mycompany-prod--AWSAdmin--987654.json
                                            (AWS credentials, 1hr lifetime)
```

### Common Confusion Points

**Q: If I login with `mycompany-dev`, can I use `mycompany-prod`?**  
A: **Yes!** You're logging into the **session** (`mycompany`), not the profile. Both profiles use the same session.

**Q: Do I need to run `aws sso login` for each profile?**  
A: **No!** Login once with any profile that uses the `mycompany` session. All profiles sharing that session will work.

**Q: What if I have multiple companies/organizations?**  
A: Create **multiple sessions**:

```ini
[sso-session mycompany]
sso_start_url = https://d-xxxxxxxxxx.awsapps.com/start
sso_region = us-east-1

[sso-session other-company]
sso_start_url = https://d-xyz987.awsapps.com/start  # Different URL!
sso_region = us-east-1

[profile mycompany-dev]
sso_session = mycompany                    # Uses MyCompany's Identity Center

[profile other-dev]
sso_session = other-company            # Uses different Identity Center
```

Now you need to login to **both sessions** separately:

```bash
aws sso login --profile mycompany-dev      # Opens MyCompany's login page
aws sso login --profile other-dev      # Opens Other Company's login page
```

### Summary Table

| Aspect                   | SSO Session                       | Profile                           |
| ------------------------ | --------------------------------- | --------------------------------- |
| **What it represents**   | Authentication to Identity Center | Configuration for account + role  |
| **Name example**         | `mycompany`                       | `mycompany-dev`, `mycompany-prod` |
| **Defined in**           | `[sso-session mycompany]`         | `[profile mycompany-dev]`         |
| **How many?**            | One per organization              | Many (one per account/role combo) |
| **Browser login?**       | Yes (every 8 hours)               | No (uses session's token)         |
| **Cache location**       | `~/.aws/sso/cache/`               | `~/.aws/cli/cache/`               |
| **Can be shared?**       | Yes (by multiple profiles)        | No (each is independent)          |
| **You choose the name?** | Yes                               | Yes                               |

---

## Local File Structure

AWS SSO uses several directories on your local machine to cache authentication data.

### Directory Structure

```bash
~/.aws/
├── config                           # Profile and SSO session configuration
├── credentials                      # [Usually empty with SSO - legacy IAM keys only]
├── sso/
│   └── cache/
│       └── abc123def456.json       # SSO access token (8-hour validity)
└── cli/
    └── cache/
        └── mycompany-dev--AWSAdministratorAccess--111111111111.json  # Temp credentials (1-hour validity)
```

---

### File 1: `~/.aws/config`

**Purpose**: Stores profile configuration and SSO session metadata.

**Example:**

```ini
[profile mycompany-dev]
sso_session = mycompany                             # Links to [sso-session mycompany]
sso_account_id = 111111111111                   # Target AWS account
sso_role_name = AWSAdministratorAccess          # IAM role to assume in that account
region = us-east-1                              # Default region for this profile
output = json                                   # Default output format

[profile mycompany-prod]
sso_session = mycompany                             # Uses same SSO session
sso_account_id = 222222222222                   # Different account
sso_role_name = AWSAdministratorAccess
region = us-east-1
output = json

[sso-session mycompany]
sso_start_url = https://d-xxxxxxxxxx.awsapps.com/start  # Identity Center portal URL
sso_region = us-east-1                                   # Region where Identity Center is hosted
sso_registration_scopes = sso:account:access             # OAuth scopes requested
```

**Key Fields:**

| Field                     | Purpose                                                     |
| ------------------------- | ----------------------------------------------------------- |
| `sso_session`             | Name of the SSO session (allows multiple profiles to share) |
| `sso_account_id`          | AWS account ID to access                                    |
| `sso_role_name`           | IAM role to assume in the account                           |
| `sso_start_url`           | Identity Center portal URL                                  |
| `sso_region`              | Region where Identity Center is configured                  |
| `sso_registration_scopes` | OAuth scopes (always `sso:account:access` for AWS SSO)      |

---

### File 2: `~/.aws/sso/cache/*.json`

**Purpose**: Caches the SSO access token after successful browser authentication.

**Filename Pattern:**

```
<sha1_hash_of_sso_start_url>.json
```

**Example:**

```bash
$ ls -la ~/.aws/sso/cache/
-rw-------  1 user  staff  1234 Feb 14 09:30 abc123def456789.json
```

**Contents:**

```json
{
  "startUrl": "https://d-xxxxxxxxxx.awsapps.com/start",
  "region": "us-east-1",
  "accessToken": "eyJraWQiOiJ0cC1zaWduaW5nLTEiLCJhbGciOiJSUzI1NiJ9...",
  "expiresAt": "2026-02-14T17:30:00Z",
  "clientId": "aws-cli-v2",
  "clientSecret": "...",
  "registrationExpiresAt": "2027-02-14T09:30:00Z"
}
```

**Key Fields:**

| Field                   | Purpose                                                            | Lifetime  |
| ----------------------- | ------------------------------------------------------------------ | --------- |
| `accessToken`           | OAuth2 access token used to request AWS credentials                | 8 hours   |
| `expiresAt`             | When the access token expires (triggers browser re-authentication) | 8 hours   |
| `clientId`              | OAuth2 client ID (always `aws-cli-v2`)                             | Permanent |
| `clientSecret`          | OAuth2 client secret (used for token refresh)                      | 90 days   |
| `registrationExpiresAt` | When you need to re-run `aws configure sso`                        | 90 days   |

**When This File Is Used:**

- Every time you run an AWS CLI command with an SSO profile
- CLI checks if `expiresAt` is in the future
- If expired, prompts you to run `aws sso login` again

**Security:**

- File permissions: `600` (read/write for owner only)
- Contains sensitive OAuth token - do NOT commit to Git
- Automatically deleted when you run `aws sso logout`

---

### File 3: `~/.aws/cli/cache/*.json`

**Purpose**: Caches temporary AWS credentials obtained using the SSO access token.

**Filename Pattern:**

```
<profile_name>--<role_name>--<account_id>.json
```

**Example:**

```bash
$ ls -la ~/.aws/cli/cache/
-rw-------  1 user  staff  800 Feb 14 09:31 mycompany-dev--AWSAdministratorAccess--111111111111.json
```

**Contents:**

```json
{
  "Credentials": {
    "AccessKeyId": "ASIAXAMPLE123456",
    "SecretAccessKey": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    "SessionToken": "IQoJb3JpZ2luX2VjEHk...",
    "Expiration": "2026-02-14T10:31:00Z"
  },
  "AssumedRoleUser": {
    "AssumedRoleId": "AROAEXAMPLE:aws-sso-session",
    "Arn": "arn:aws:sts::111111111111:assumed-role/AWSAdministratorAccess/aws-sso-session"
  }
}
```

**Key Fields:**

| Field             | Purpose                                                     | Lifetime |
| ----------------- | ----------------------------------------------------------- | -------- |
| `AccessKeyId`     | Temporary access key (starts with `ASIA`)                   | 1 hour   |
| `SecretAccessKey` | Secret key for this session                                 | 1 hour   |
| `SessionToken`    | Session token (required for all API calls)                  | 1 hour   |
| `Expiration`      | When credentials expire (auto-refreshed if SSO token valid) | 1 hour   |

**When This File Is Used:**

- AWS CLI checks this cache before every API call
- If credentials are still valid (not expired), uses them directly
- If expired but SSO token is valid, automatically requests new credentials
- If SSO token also expired, prompts for `aws sso login`

**Auto-Refresh Behavior:**

```
Time 09:00 → User runs: aws sso login
         ↓
         SSO token cached (expires 17:00)
         Temp credentials cached (expires 10:00)

Time 09:30 → User runs: aws s3 ls
         ↓
         Uses cached credentials (still valid)

Time 10:30 → User runs: aws s3 ls
         ↓
         Credentials expired, but SSO token still valid
         CLI automatically requests new credentials
         New credentials cached (expires 11:30)
         Command succeeds!

Time 17:30 → User runs: aws s3 ls
         ↓
         Both SSO token and credentials expired
         Error: "SSO session has expired. Run: aws sso login"
```

---

### File 4: `~/.aws/credentials` (Usually Empty with SSO)

**Purpose**: Stores static IAM user access keys (legacy authentication).

**With SSO**: This file is typically **empty** or **should be empty**.

**Why:**

- SSO uses temporary credentials stored in `~/.aws/cli/cache/`
- Static keys in `~/.aws/credentials` are a security anti-pattern
- If a `[default]` profile exists here, it takes precedence and causes confusion

**Example of INCORRECT usage (legacy):**

```ini
[default]
aws_access_key_id=AKIAIOSFODNN7EXAMPLE
aws_secret_access_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
```

**Best Practice with SSO:**

```bash
# Delete or comment out [default] section
# Use SSO profiles exclusively
```

If you see errors like "InvalidToken" but `aws sso login` succeeds, check this file for expired credentials.

---

## Troubleshooting Commands

```bash
# 1. Check which profile is active
echo $AWS_PROFILE
# Output: mycompany-dev

# 2. Verify current identity
aws sts get-caller-identity
# Should show SSO role ARN

# 3. List available SSO cache files
ls -lh ~/.aws/sso/cache/

# 4. Check SSO token expiration
cat ~/.aws/sso/cache/*.json | jq -r '.expiresAt'

# 5. List credential cache files
ls -lh ~/.aws/cli/cache/

# 6. Check credential expiration
cat ~/.aws/cli/cache/*.json | jq -r '.Credentials.Expiration'

# 7. Test profile access
aws s3 ls --profile mycompany-dev

# 8. List all configured profiles
aws configure list-profiles

# 9. Clear all cache (forces fresh login)
rm -rf ~/.aws/sso/cache/* ~/.aws/cli/cache/*
aws sso login --profile mycompany-dev

# 10. Check for conflicting credentials
cat ~/.aws/credentials | grep -E '^\[' | head -5
# Should be empty or only contain non-SSO profiles
```

---

## Best Practices

✅ **DO:**

- Use SSO sessions to share authentication across multiple profiles
- Set `AWS_PROFILE` environment variable instead of `--profile` flag
- Run `aws sso logout` when done working (especially on shared machines)
- Configure MFA enforcement in AWS Identity Center
- Monitor CloudTrail for unusual SSO activity
- Use separate SSO roles for different permission levels (admin vs. readonly)

❌ **DON'T:**

- Don't commit `~/.aws/sso/cache/*` or `~/.aws/cli/cache/*` to Git
- Don't share SSO cache files with colleagues (each person should authenticate)
- Don't use `[default]` profile with static credentials if using SSO
- Don't store long-term IAM access keys in `~/.aws/credentials` when SSO is available
- Don't manually edit SSO cache files (let AWS CLI manage them)

# Appendix: AWS CLI Authentication Issues

## Common Error: InvalidToken / InvalidClientTokenId

**Error Messages:**

```
An error occurred (InvalidToken) when calling the ListBuckets operation:
The provided token is malformed or otherwise invalid.

An error occurred (InvalidClientTokenId) when calling the GetCallerIdentity operation:
The security token included in the request is invalid
```

## Root Cause

This error typically occurs when you have **expired credentials** in your `~/.aws/credentials` file, even if you've recently run `aws sso login`.

**What happens:**

1. You run `aws sso login --profile mycompany-dev` → ✅ Caches valid SSO credentials for `mycompany-dev` profile
2. You run `aws s3 ls` (without specifying profile) → ❌ Uses `[default]` profile with expired credentials
3. Result: InvalidToken error

## Why SSO Login Doesn't Fix Default Profile

AWS SSO login **does NOT** update the `[default]` profile in your `~/.aws/credentials` file. It stores credentials separately for named SSO profiles.

**Example of the problem:**

```ini
# ~/.aws/credentials
[default]
aws_access_key_id=ASIA6GBMCTXL6BCHIN6N
aws_secret_access_key=acgJh+O3KZXMyXlxiZjtw5/vS1teEy1C/k9KZvI4
aws_session_token=IQoJb3JpZ2luX2VjEG... (EXPIRED - causes the error!)

# ~/.aws/config
[profile mycompany-dev]
sso_session = mycompany
sso_account_id = 111111111111
sso_role_name = AWSAdministratorAccess
region = us-east-1
```

Even after running `aws sso login --profile mycompany-dev`, the `[default]` profile still has expired credentials.

## Diagnosis Steps

**1. Check your AWS credentials:**

```bash
cat ~/.aws/credentials
```

Look for temporary credentials in the `[default]` profile:

- Keys starting with `ASIA` (temporary) vs `AKIA` (permanent)
- `aws_session_token` field (indicates temporary credentials)

**2. Check your AWS identity:**

```bash
aws sts get-caller-identity
# If this fails, your default credentials are invalid

aws sts get-caller-identity --profile mycompany-dev
# If this works, your SSO profile is valid
```

**3. Check environment variables:**

```bash
env | grep -E '^AWS_' | sort
```

If `AWS_ACCESS_KEY_ID` or `AWS_SESSION_TOKEN` are set, they override your credentials file.

## Solution Options

### Option 1: Use SSO Profile (Recommended)

**Set profile in your terminal session:**

```bash
export AWS_PROFILE=mycompany-dev
aws s3 ls  # Now works!
```

**Or specify profile on each command:**

```bash
aws s3 ls --profile mycompany-dev
aws sts get-caller-identity --profile mycompany-dev
```

**Make permanent (add to `~/.zshrc` or `~/.bashrc`):**

```bash
echo 'export AWS_PROFILE=mycompany-dev' >> ~/.zshrc
source ~/.zshrc
```

### Option 2: Remove Expired Default Credentials

**Edit `~/.aws/credentials`:**

```bash
nano ~/.aws/credentials
# or
code ~/.aws/credentials
```

**Remove the `[default]` section entirely:**

```ini
# Before:
[default]
aws_access_key_id=ASIA6GBMCTXL6BCHIN6N
aws_secret_access_key=acgJh+O3KZXMyXlxiZjtw5/vS1teEy1C/k9KZvI4
aws_session_token=IQoJb3JpZ2luX2VjEG...

# After: (delete the entire [default] section)
```

**Then use profiles explicitly:**

```bash
aws s3 ls --profile mycompany-dev
```

### Option 3: Clear Environment Variables

If environment variables are set, they override everything:

```bash
unset AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY
unset AWS_SESSION_TOKEN
unset AWS_SECURITY_TOKEN
```

## SSO Login Workflow

**Correct workflow when using AWS SSO:**

```bash
# 1. Login to SSO profile
aws sso login --profile mycompany-dev

# 2. Either set profile as default:
export AWS_PROFILE=mycompany-dev

# Or specify profile on every command:
aws s3 ls --profile mycompany-dev
aws dynamodb list-tables --profile mycompany-dev
terraform init  # Reads AWS_PROFILE automatically
```

## Terraform Configuration

When using SSO profiles with Terraform, you have two options:

**Option 1: Environment Variable**

```bash
export AWS_PROFILE=mycompany-dev
terraform plan  # Uses mycompany-dev profile automatically
```

**Option 2: Provider Configuration**

```hcl
# In your Terraform code
provider "aws" {
  region  = "us-east-1"
  profile = "mycompany-dev"
}
```

## Prevention for Teams

**If multiple team members encounter this:**

**1. Document SSO setup in README:**

```markdown
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
```

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

## Debugging Commands Reference

```bash
# View credentials file (safely - only first 20 lines, suppress errors)
cat ~/.aws/credentials 2>/dev/null | head -20

# View config file
cat ~/.aws/config 2>/dev/null | head -20

# Check active identity
aws sts get-caller-identity

# Check identity for specific profile
aws sts get-caller-identity --profile mycompany-dev

# Check environment variables
env | grep -E '^AWS_'

# Test S3 access
aws s3 ls --profile mycompany-dev

# List available profiles
aws configure list-profiles
```

## Why This Happens to Teams Migrating to SSO

Many teams initially used IAM users with static access keys stored in the `[default]` profile:

```ini
# Old approach (before SSO)
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
