# Appendix: Secrets Management for 12-Factor Applications

## Overview

Moving from a non-12-factor to a 12-factor app involves transitioning from stateful, coupled, and manually configured applications to stateless, container-friendly, cloud-native services. Key steps include externalizing configurations, treating logs as event streams, eliminating local file storage, and using strict environment parity for continuous deployment

This appendix covers how secrets are stored and injected across all environments, why ECS + Secrets Manager is a security improvement over EC2 patterns, the correct sequencing of secrets work across migration phases, and the architectural decision for how secrets are handled in local development.

**Use this appendix when:**

- Understanding the security difference between EC2 and ECS secret handling
- Migrating from dotenv or environment files
- Deciding whether to use SSM Parameter Store or Secrets Manager
- Planning secrets migration sequencing across phases
- Understanding why dotenv is kept for local development
- Troubleshooting secret injection issues

---

## Moving from a non 12 factor app to a 12 factor app

Moving to environment variables ensures our built artifacts (e.g., Docker images) remain generic and immutable. The application becomes a blank slate, fully configured by the environment it is deployed into.
The migration is not a single cutover. It is four discrete steps across multiple phases, each with a different owner. The correct ordering is:

### Step 1 — Audit

Before any code or infrastructure changes:

- Inventory every secret per app: DB passwords, API keys, tokens, Redis passwords, third-party service credentials, etc.
- Identify shared secrets (e.g., multiple apps hitting the same database or Redis cluster)
- Agree on a naming convention upfront — changing it later requires updating all task definitions and IAM policies:

  ```
  {environment}/{app-name}/{secret-type}

  Examples:
    dev/auth-api/database
    dev/auth-api/api-keys
    dev/shared/redis
  ```

- Document the port and protocol each secret is used for (needed for Story 5.2 database SG updates)

### Step 2 — Externalize

This is where most teams underestimate effort. The app must already read all config from environment variables. Specifically:

- No hardcoded credentials anywhere in application code
- No reading directly from `.env` files in paths that assume the file exists in production
- All secret references go through `process.env.SECRET_NAME` (or equivalent in your language)
- `dotenv` must be made optional so the app doesn't crash when `.env` is absent in ECS (see ADR below)
- `.env.example` must be kept up to date as the canonical list of required secrets — this becomes the secrets inventory for new developers and a checklist for Secrets Manager population

If an app has hardcoded secrets or tightly couples to a `.env` file, it **cannot be containerized safely** until this is resolved.

### Step 3 — Create Secrets in Secrets Manager (Before Phase 2 Ends)

Secrets Manager secrets must exist **before task definitions are finalized** so that:

- ARNs are known and can be referenced in the `secrets` block
- The Task Execution Role policy can scope to specific ARNs (least privilege)
- App teams can test the wiring during Phase 4 initial deployment without a delay

This is primarily an infra team action that should be batched and completed while app teams are mid-containerization.

> **Watch for the anti-pattern**
> Refactor the application to read configuration exclusively from the system environment. Relying on conditional logic to load different files (e.g., if env == 'prod': load('prod.json')) is an anti-pattern:
> The 12-Factor Pattern: The application simply asks the OS for the value: os.environ.get('DATABASE_URL'). The underlying platform is responsible for ensuring that variable exists.

### Step 4 — Task Definition Wiring (Phase 3/4)

Once secrets exist in Secrets Manager and app code reads from env vars:

- Replace `environment` blocks with `secrets` blocks in task definitions:
  ```json
  "secrets": [
    {
      "name": "DB_PASSWORD",
      "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789012:secret:dev/auth-api/database:password::"
    }
  ]
  ```
- Task Execution Role needs `secretsmanager:GetSecretValue` scoped to the app's secret path
- At container start, ECS fetches secrets and injects them as environment variables — app code is unaware
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

### Pattern 2: Shell Export

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
│  ┌─────────────────────┐      ┌─────────────────┐      ┌────────────────────┐    │
│  │  Secrets Manager    │      │  ECS Service    │      │  Fargate Task      │    │
│  │                     │      │                 │      │                    │    │
│  │  production/auth/db │ ───▶ │  Task Def       │ ───▶ │  Container         │    │
│  │  (encrypted by KMS) │      │  secrets block  │      │  process.env.DB_*  │    │
│  │                     │      │                 │      │                    │    │
│  └─────────────────────┘      └─────────────────┘      └────────────────────┘    │
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
| Local + dotenv            | dotenv library reads `.env` file    |
| EC2 + shell export        | Bash `export` before starting app   |
| EC2 + PM2                 | PM2 ecosystem config `env` block    |
| **ECS + Secrets Manager** | **ECS injects at container start**  |

---
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
- Use a `docker-compose.yml` with `env_file: .env` block
- Use VS Code's `launch.json` with `"env"` configuration

---

## Retrieving Secrets and the Direct-SDK Anti-Pattern

### How Secrets Reach Your App

ECS is the only actor that should fetch secrets from Secrets Manager at runtime. The flow is:

1. ECS reads the `secrets` block in the task definition
2. ECS calls `secretsmanager:GetSecretValue` using the **Task Execution Role** (not your app's role)
3. ECS injects the value as an environment variable before your container process starts
4. Your app reads `process.env.DB_PASSWORD` — it has no knowledge of Secrets Manager

This means your application code needs zero AWS SDK calls, zero AWS credentials beyond what ECS already manages, and zero awareness of where secrets are stored.

### When Engineers Need to Retrieve a Secret Value

The only legitimate case is debugging — verifying what value is actually stored:

```bash
# Requires IAM permission secretsmanager:GetSecretValue — access is logged in CloudTrail
aws secretsmanager get-secret-value \
  --secret-id dev/auth-api/database \
  --query SecretString \
  --output text
```

This is an operational action, not a development pattern. It should be rare and is always audited.

### The Anti-Pattern: App Code Calling `getSecretValue()` Directly

Do not write application code that retrieves its own secrets from Secrets Manager:

```javascript
// ❌ ANTI-PATTERN — never do this
const {
  SecretsManagerClient,
  GetSecretValueCommand,
} = require("@aws-sdk/client-secrets-manager");
const client = new SecretsManagerClient({ region: "us-east-1" });
const response = await client.send(
  new GetSecretValueCommand({ SecretId: "dev/auth-api/database" }),
);
const secret = JSON.parse(response.SecretString);
const dbPassword = secret.password;
```

**Why this is wrong:**

- **Breaks local development** — every developer now needs AWS credentials configured to start the app locally, even when running against a local database
- **Requires wider IAM permissions** — the Task Role (your app's role) would need `secretsmanager:GetSecretValue`, expanding the blast radius if the container is compromised
- **Adds AWS SDK dependency to app code** — your app now has an AWS coupling that has nothing to do with its business logic
- **Adds startup latency** — every cold start makes a synchronous API call before the app can serve traffic
- **Defeats the 12-factor contract** — Factor III says config comes from the environment; fetching it inside the app re-couples config to the implementation

**The correct pattern:**

```javascript
// ✅ CORRECT — ECS injected this before your process started
const dbPassword = process.env.DB_PASSWORD;
```

The source of `DB_PASSWORD` is invisible to the app. Locally it comes from `.env` via dotenv. In ECS it comes from Secrets Manager via the Task Execution Role. App code is identical in both cases.

---

## Moving from a non 12 factor app to a 12 factor app

Most EC2 applications are not 12-factor compliant out of the box. They read secrets from `.env` files on disk, hardcode values in startup scripts, or couple tightly to the filesystem. Moving to Fargate forces the issue — containers are ephemeral, have no persistent disk, and are managed by ECS, not SSH'd into. This is the opportunity to make apps fully 12-factor compliant.

The migration is not a single cutover. It is four discrete steps across multiple phases, each with a different owner. The correct ordering is:

### Step 1 — Audit

Before any code or infrastructure changes:

- Inventory every secret per app: DB passwords, API keys, tokens, Redis passwords, third-party service credentials, etc.
- Identify shared secrets (e.g., multiple apps hitting the same database or Redis cluster)
- Agree on a naming convention upfront — changing it later requires updating all task definitions and IAM policies:

  ```
  {environment}/{app-name}/{secret-type}

  Examples:
    dev/auth-api/database
    dev/auth-api/api-keys
    dev/shared/redis
  ```

- Document the port and protocol each secret is used for (needed for Story 5.2 database SG updates)

### Step 2 — Externalize

This is where most teams underestimate effort. The app must already read all config from environment variables. Specifically:

- No hardcoded credentials anywhere in application code
- No reading directly from `.env` files in paths that assume the file exists in production
- All secret references go through `process.env.SECRET_NAME` (or equivalent in your language)
- `dotenv` must be made optional so the app doesn't crash when `.env` is absent in ECS (see ADR below)
- `.env.example` must be kept up to date as the canonical list of required secrets — this becomes the secrets inventory for new developers and a checklist for Secrets Manager population

If an app has hardcoded secrets or tightly couples to a `.env` file, it **cannot be containerized safely** until this is resolved.

### Step 3 — Create Secrets in Secrets Manager (Before Phase 2 Ends)

Secrets Manager secrets must exist **before task definitions are finalized** so that:

- ARNs are known and can be referenced in the `secrets` block
- The Task Execution Role policy can scope to specific ARNs (least privilege)
- App teams can test the wiring during Phase 4 initial deployment without a delay

This is primarily an infra team action that should be batched and completed while app teams are mid-containerization.

### Step 4 — Task Definition Wiring (Phase 3/4)

Once secrets exist in Secrets Manager and app code reads from env vars:

- Replace `environment` blocks with `secrets` blocks in task definitions:
  ```json
  "secrets": [
    {
      "name": "DB_PASSWORD",
      "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789012:secret:dev/auth-api/database:password::"
    }
  ]
  ```
- Task Execution Role needs `secretsmanager:GetSecretValue` scoped to the app's secret path
- At container start, ECS fetches secrets and injects them as environment variables — app code is unaware

---

## ADR-002: Local Development Secret Strategy

### Use dotenv for Local Development, Secrets Manager for All Cloud Environments

| Field                   | Detail                                               |
| ----------------------- | ---------------------------------------------------- |
| **Status**              | Accepted                                             |
| **Date**                | Phase 2                                              |
| **Deciders**            | Platform Engineering, Security Engineering           |
| **12-Factor Reference** | Factor III — Config: Store config in the environment |

### Context

During the EC2-to-Fargate migration, we're adopting AWS Secrets Manager as the canonical secret store for all ECS workloads. The question is whether local development environments should also pull from Secrets Manager or continue using the dotenv pattern.

Developers need to run services locally for day-to-day feature work, debugging, and testing. The secret injection mechanism must not create friction in the local development loop or introduce hard dependencies on AWS infrastructure.

### Decision

**Use `.env` files with dotenv for local development. Use AWS Secrets Manager for all cloud environments (dev, staging, prod).**

The interface contract is identical in both cases: the application reads secrets exclusively from `process.env`. The source of those environment variable values differs by environment but is invisible to app code.

### Options Considered

#### Option A: dotenv for local, Secrets Manager for cloud (Selected)

- Local: secrets contained in `.env` file loaded by dotenv at process startup
- ECS: ECS injects Secrets Manager values as env vars at container start
- App code: `process.env.DB_PASSWORD` in both cases — no branching, no SDK calls

#### Option B: Secrets Manager everywhere, including local

- Local dev would call the Secrets Manager API on every app start
- Requires every developer to have AWS credentials configured
- Requires network connectivity to AWS at startup
- Breaks local development if AWS is unreachable or credentials expire
- Significantly slower inner dev loop (API call adds latency to `npm run dev`)
- Developers may inadvertently use production or shared dev secrets

#### Option C: SSM Parameter Store for local

- Similar problems to Option B — still requires AWS credentials and network
- Less expressive than Secrets Manager (no structured JSON secrets, lower API rate limits)
- Would require a different code path than the ECS Secrets Manager pattern

#### Option D: Docker Compose `.env` injection only (no dotenv in app)

- Consistent with 12-factor but requires developers to always use Docker Compose to run services locally
- Increases friction for debugging (can't run `node server.js` directly)
- Doesn't prevent `.env` files from existing — just moves where they're loaded

### Rationale for Option A

**1. Developer experience must not require AWS**
Developers should be able to clone a repo and run a service with `npm install && npm run dev` without configuring AWS credentials, assuming a VPN, or having an active internet connection. Secrets Manager as a hard local dependency breaks this.

**2. The 12-factor contract is satisfied at the interface, not the implementation**
12-factor Factor III says config should come from the environment. It does not prescribe _how_ env vars get populated. Using dotenv locally and Secrets Manager in ECS both satisfy the contract — the app always reads `process.env.SECRET_NAME`.

**3. Credential isolation**
Developers using local `.env` files work against local services (local Postgres, local Redis via Docker Compose). They are not touching shared or production infrastructure. Connecting local dev to Secrets Manager increases the risk of a developer accidentally using a real secret or making unintended AWS API calls.

**4. dotenv must be made optional**
The dotenv library's `config()` call must not crash if `.env` is absent (which it won't be in ECS). Use:

```javascript
// Node.js
require("dotenv").config(); // silently no-ops if .env is missing

// Or conditionally:
if (process.env.NODE_ENV !== "production") {
  require("dotenv").config();
}
```

**5. `.env.example` becomes the secrets contract**
The `.env.example` file (committed, no real values) becomes the authoritative list of every env var the application requires. This serves as:

- Onboarding documentation for new developers
- The checklist for what must be created in Secrets Manager
- A validation surface for deployment verification

### Consequences

**Positive:**

- Fast, offline-capable local development
- No AWS credentials required to run services locally
- App code has no awareness of the secret source — no branching logic
- New developers can be productive without AWS access
- `.env.example` creates a natural secrets inventory

**Negative / Mitigations:**

- Local secrets are in plaintext `.env` files — mitigated by gitignore and developer education
- Possible drift between `.env.example` and Secrets Manager — mitigated by treating `.env.example` updates as a required step in the Definition of Done for any work that adds/changes secrets
- Developers may test against different values than ECS uses — acceptable and expected; use integration/staging environments for parity testing

### Implementation Rules

1. `.env` must be in `.gitignore` — enforced, no exceptions
2. `.env.example` must exist in every service repo with all required keys and placeholder values
3. dotenv must be configured to not throw if `.env` is missing (ECS containers won't have one)
4. No secret value may appear in application source code, Dockerfile, or CI pipeline logs
5. When a new secret is added, `.env.example`, Secrets Manager, and the Task Definition `secrets` block are all updated in the same pull request or change set

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

| Phase          | Action                                                      | Owner         |
| -------------- | ----------------------------------------------------------- | ------------- |
| Phase 0        | Inventory all secrets, agree naming convention              | Dev + Infra   |
| Phase 2        | Ensure app reads from `process.env`, make dotenv optional   | Dev team      |
| Phase 2        | Update `.env.example` as secrets contract                   | Dev team      |
| Phase 2 (late) | Create secrets in Secrets Manager, populate values          | Infra team    |
| Phase 3        | Create Task Execution Role with Secrets Manager permissions | Infra team    |
| Phase 4        | Reference secrets in Task Definition `secrets` block        | Infra team    |
| Post-migration | Delete `.env` files from EC2 instances                      | Infra team    |
| Post-migration | Consider enabling secret rotation                           | Security team |

---

## Related Documentation

- See [aws-authentication-and-security.md](../../phase-3-infrastructure-setup/appendix/aws-authentication-and-security.md) for IAM security best practices
- See [ecs-deployment-fundamentals.md](../../phase-4-initial-deployment/appendix/ecs-deployment-fundamentals.md) for understanding task definitions
- See [github-actions-cicd.md](../../phase-4-initial-deployment/appendix/github-actions-cicd.md) for secrets vs configuration in pipelines
