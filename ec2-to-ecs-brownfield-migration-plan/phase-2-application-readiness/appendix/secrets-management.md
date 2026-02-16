# Appendix: Secrets Management - EC2 vs ECS

## Overview

This appendix explains how secrets are stored and injected in both EC2 and ECS environments, and why ECS + Secrets Manager is a security improvement over traditional approaches.

**Use this appendix when:**

- Understanding the security difference between EC2 and ECS secret handling
- Migrating from dotenv or environment files
- Deciding whether to use SSM Parameter Store or Secrets Manager
- Planning secrets migration strategy
- Troubleshooting secret injection issues

---

## Table of Contents

1. [The Security Question](#the-security-question)
2. [EC2: Current State (Typical Patterns)](#ec2-current-state-typical-patterns)
3. [ECS + Secrets Manager: The Target State](#ecs--secrets-manager-the-target-state)
4. [App Code: Identical in Both Environments](#app-code-identical-in-both-environments)
5. [Removing dotenv for Production](#removing-dotenv-for-production)
6. [Security Best Practices Summary](#security-best-practices-summary)
7. [Migration Path](#migration-path)

---

## The Security Question

When your app reads `process.env.DB_PASSWORD`, the question isn't just "does it work?" — it's:

1. **Where is the secret stored at rest?** (On disk? Encrypted? Where?)
2. **Who can access the secret?** (Anyone with SSH? IAM-controlled?)
3. **Is there an audit trail?** (Who accessed what, when?)
4. **Can the secret be rotated?** (Without downtime?)

---

## EC2: Current State (Typical Patterns)

### Pattern 1: `.env` File + dotenv Library

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

### Pattern 2: Shell Export (Startup Script / PM2 / systemd)

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

### Pattern 3: EC2 Parameter Store / Secrets Manager (Rare but Better)

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

## ECS + Secrets Manager: The Target State

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

## What About `/proc/<pid>/environ`?

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

## App Code: Identical in Both Environments

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

## Removing dotenv for Production

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

## Security Best Practices Summary

1. **Never commit secrets to git** — use `.env.example` with placeholder values
2. **Never bake secrets into Docker images** — check with `docker history <image>`
3. **Use Secrets Manager** (not SSM Parameter Store) for truly sensitive values
   - SSM Parameter Store SecureString works but has lower API limits
4. **Scope IAM permissions** — each app should only access its own secrets
5. **Enable CloudTrail** — audit who accessed which secrets
6. **Consider rotation** — especially for database credentials
7. **Use VPC Endpoints** — so secrets never traverse the public internet

---

## Migration Path

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

## Related Documentation

- See [aws-authentication-and-security.md](../../phase-3-infrastructure-setup/appendix/aws-authentication-and-security.md) for IAM security best practices
- See [ecs-deployment-fundamentals.md](../../phase-4-initial-deployment/appendix/ecs-deployment-fundamentals.md) for understanding task definitions
- See [github-actions-cicd.md](../../phase-4-initial-deployment/appendix/github-actions-cicd.md) for secrets vs configuration in pipelines
