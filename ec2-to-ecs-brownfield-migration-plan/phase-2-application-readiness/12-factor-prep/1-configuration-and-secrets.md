# Phase 1: Configuration & Secrets

**Goal:** Decouple configuration from code and secure sensitive credentials by moving them to environment variables.

## Context & Themes

This document details the transition from hardcoded configuration to environment-based configuration, a core tenet of the 12-Factor App methodology. It ensures that the application can be deployed to any environment (dev, staging, prod) without code changes and that sensitive secrets are securely managed.

**Key Themes:**

- **Security:** Removing hardcoded secrets to prevent exposure.
- **Immutability:** enabling the same container image to run anywhere.
- **12-Factor Compliance:** Strict separation of config from code.

## Prerequisites

Before starting the configuration updates, ensure:

- [ ] Access to the full application source code and git history.
- [ ] `gitleaks` installed locally (or via CI).
- [ ] Values for all secrets for each environment (dev, staging, prod).
- [ ] Decisions on where secrets will be stored (e.g., AWS Secrets Manager, SSM Parameter Store).

## Overview

This phase establishes the foundation for 12-Factor App compliance by externalizing all configuration and eliminating hardcoded secrets. **This is the most critical phase**—all other changes depend on proper configuration management.

**Business Value:** Prevents security incidents, enables deployment across environments without rebuilds, and satisfies compliance requirements (SOC 2, PCI).

---

## Feature 1: Externalized Configuration & Secrets

**Business Value:** Prevents security incidents, enables deployment across environments without rebuilds, and satisfies compliance requirements (SOC 2, PCI).

### Story 1.1: Find and Eliminate Hardcoded Secrets

- **Title:** Scan Code for Hardcoded Secrets and Remove Them
- **Persona:** As a **security engineer**, I need to find and eliminate all hardcoded secrets in the codebase so that credentials aren't exposed in Docker images or source control.

**Business Value:** Prevents catastrophic security incidents and compliance violations. Finding hardcoded API keys during development (1-2 hours effort) vs. discovering them in a security breach (average cost: $50K-200K) protects company reputation and prevents regulatory fines. Eliminating hardcoded secrets is required for SOC 2/PCI compliance and blocks enterprise sales until resolved.

- **Requirements:**
  - Scan entire codebase for hardcoded secrets (API keys, passwords, tokens)
  - Search git history for accidentally committed secrets
  - Rotate or purge any secrets found before proceeding to Story 2

- **Implementation Details:**

  **Step 1: Install and Run Gitleaks**

  ```bash
  # Install gitleaks (finds secrets in code and git history)
  brew install gitleaks
  # or: https://github.com/gitleaks/gitleaks/releases

  # Scan current code
  gitleaks detect --source . --verbose

  # Scan git history (finds committed secrets even if deleted)
  gitleaks detect --source . --log-opts="--all" --verbose
  ```

  Alternative tools:
  - **truffleHog**: `docker run --rm -v "$PWD:/repo" trufflesecurity/trufflehog:latest github --repo file:///repo`
  - **detect-secrets**: `pip install detect-secrets && detect-secrets scan`

  **Step 2: Manual Pattern Search**

  These `grep` patterns catch the things automated scanners commonly miss — hardcoded values that don't match known secret formats but are still dangerous.

  ```bash
  # ── Database credentials ──────────────────────────────────────────────────────
  grep -rn "password\s*=\s*['\"][^'\"]\+['\"]" . --exclude-dir={node_modules,.git,vendor}
  grep -rn "DB_PASSWORD\s*=\s*['\"][^'\"]\+['\"]" .
  grep -rn "db_pass\|dbpassword\|database_password" . -i
  # Connection strings (postgres://, mysql://, mongodb://, redis://:password@)
  grep -rEn "(postgres|mysql|mongodb|redis|amqp)://[^:]+:[^@]+@" .
  # JDBC-style
  grep -rn "jdbc:.*password=" . -i

  # ── Generic secret/token/key assignments ──────────────────────────────────────
  grep -rEn "(secret|token|api.?key|private.?key)\s*[:=]\s*['\"][^'\"]{8,}" . -i \
    --exclude-dir={node_modules,.git,vendor,dist,build}
  grep -rEn "['\"][a-zA-Z0-9+/]{40,}={0,2}['\"]" .    # Base64-encoded blobs
  grep -rEn "['\"][a-zA-Z0-9]{32,}['\"]" .              # Long random strings

  # ── AWS credentials ───────────────────────────────────────────────────────────
  grep -rn "AKIA[0-9A-Z]\{16\}" .                       # AWS Access Key ID
  grep -rn "aws_secret_access_key\s*=" . -i
  grep -rn "aws_session_token\s*=" . -i

  # ── Private keys & certificates ───────────────────────────────────────────────
  grep -rn "BEGIN RSA PRIVATE KEY\|BEGIN EC PRIVATE KEY\|BEGIN OPENSSH PRIVATE KEY\|BEGIN PRIVATE KEY" .
  grep -rn "BEGIN CERTIFICATE" .                         # Likely fine, but worth auditing

  # ── JWT secrets ───────────────────────────────────────────────────────────────
  grep -rn "jwt.?secret\|jwt.?key\|JWT_SECRET" . -i
  # Encoded JWTs committed by accident (starts with eyJ)
  grep -rEn "eyJ[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+" .

  # ── OAuth / auth tokens ───────────────────────────────────────────────────────
  grep -rn "client_secret\|client.secret\|CLIENT_SECRET" . -i
  grep -rn "oauth.?token\|access.?token\|refresh.?token" . -i
  grep -rEn "Bearer\s+[a-zA-Z0-9\-_\.]{20,}" .          # Hardcoded Bearer tokens

  # ── SSH / deploy keys ─────────────────────────────────────────────────────────
  grep -rn "-----BEGIN.*KEY-----" .
  find . -name "id_rsa" -o -name "id_ed25519" -o -name "*.pem" -o -name "*.key" \
    | grep -v node_modules | grep -v .git

  # ── SaaS service credentials ──────────────────────────────────────────────────
  # Stripe
  grep -rn "sk_live_\|rk_live_" .
  # Sendgrid
  grep -rEn "SG\.[a-zA-Z0-9_-]{22}\.[a-zA-Z0-9_-]{43}" .
  # Twilio
  grep -rEn "SK[a-f0-9]{32}" .
  # Slack webhooks
  grep -rn "hooks.slack.com/services" .
  # GitHub / GitLab tokens
  grep -rEn "ghp_[a-zA-Z0-9]{36}|ghs_[a-zA-Z0-9]{36}|glpat-[a-zA-Z0-9_-]{20}" .
  # Datadog / New Relic
  grep -rn "DD_API_KEY\|NEW_RELIC_LICENSE_KEY\|NEWRELIC" . -i
  # Sentry DSN (contains a secret in the URL)
  grep -rEn "https://[a-f0-9]{32}@o[0-9]+\.ingest\.sentry\.io" .
  # PagerDuty
  grep -rEn "pdl_[a-zA-Z0-9]{32}" .
  # Mailgun
  grep -rEn "key-[a-z0-9]{32}" .

  # ── Hardcoded IPs / internal hostnames ───────────────────────────────────────
  # These arent secrets but expose infrastructure — flag for review
  grep -rEn "10\.[0-9]+\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+" . \
    --exclude-dir={node_modules,.git}
  grep -rEn "[a-z0-9-]+\.(internal|corp|local)(:[0-9]+)?" . -i \
    --exclude-dir={node_modules,.git}

  # ── .env files that may have been committed ───────────────────────────────────
  git ls-files | grep "\.env"
  git log --all --full-history -- "**/.env" "**/.env.*"
  ```

  **Step 3: Remediate if Secrets Found**

  ⚠️ **WARNING:** Rotation is almost always faster and safer than rewriting history — do that first.

  # Option A: Rotate immediately (fastest, safest)

  # Log in to the provider (AWS Console, Stripe Dashboard, GitHub, etc.) and

  # revoke the exposed key. Generate a new one and update it everywhere it's used.

  # Do this BEFORE anything else — a revoked key can't be exploited.

  # Option B: Remove from git history

  # Only needed when rotation alone isn't sufficient (e.g., internal passwords

  # that can't be "rotated" via a dashboard, or compliance requires clean history)

  # git filter-repo is the current standard (replaces the older BFG tool — faster,

  # safer, and maintained by the Git project itself)

  ```bash
  pip install git-filter-repo
  # or: brew install git-filter-repo
  ```

````
  # Create a file mapping literal secrets to a safe replacement string (one per line).
  # Format: literal:replacement  (the replacement is what will appear in history)

  ```bash
  cat > secrets-to-remove.txt << 'EOF'
  sk_live_abc123==>REMOVED
  mySecretPassword123==>REMOVED
  EOF
````

# Work on a fresh clone — NEVER run this on your primary working copy

git clone --mirror https://github.com/your-org/your-repo.git repo-mirror
cd repo-mirror

git filter-repo --replace-text ../secrets-to-remove.txt

# Force push all refs — COORDINATE WITH THE TEAM FIRST so nobody loses work

git push --force --all
git push --force --tags

```

```

- **Acceptance Criteria:**
  - ✅ Gitleaks scan shows zero secrets in current code
  - ✅ Gitleaks scan shows zero secrets in git history (or all exposed secrets have been rotated)
  - ✅ Any secrets found have been revoked at the provider before proceeding
  - ✅ Team notified of any secrets that were found and rotated

---

## Story 1.2: Migrate Configuration Items and Secrets to Environment Variables

- **Title:** Migrate Configuration to Environment Variables
- **Persona:** As a **developer**, I need the application to read all configuration items and Secrets from environment variables so that I can deploy the same image to different environments (dev, staging, prod) without rebuilding.

**Business Value:** Eliminates deployment errors from hardcoded configurations and enables rapid environment promotion. This story covers the full remediation pass — replacing both hardcoded secrets (API keys, passwords, tokens found in Story 1.1) and non-secret configuration (DB hosts, service URLs, feature flags) with environment variable references. Deploying the same image from dev to production (no rebuild) reduces deployment time from 30 minutes to 5 minutes and eliminates "forgot to update config" bugs that cause 20-30% of deployment failures.

- **Requirements:**
  - No `.env` files copied into Docker images (they must stay off the server and out of git)
  - No hardcoded configuration items in source code
  - All configuration and secrets (DB hosts, API URLs, feature flags, ports) read from environment variables at runtime
  - Application must refuse to start with a clear error message if a required variable is missing

- **Implementation Details:**

  **Step 1: Add values `.env` to `.gitignore` and `.dockerignore` so it is never copied**

  ```bash
  # .dockerignore — create this file in the repo root if it doesn't exist
  .env
  .env.*
  !.env.example    # .env.example is safe to include — it only has dummy values
  ```

  **Step 2: Set Up dotenv and `.env.example` for Local Development**

  On EC2 and in ECS, environment variables are injected by the process manager (systemd) or the container orchestrator (ECS task definition). The application code just reads `process.env.*` and those values are already there.

  On a developer's laptop, nothing injects those variables automatically — so we use `dotenv` to load them from a local `.env` file during development only. Install it as a dev dependency and load it conditionally so it never runs in production:

  **Create `.env.example` and verify `.gitignore`**

  Do this now, as part of dotenv setup. `.env.example` is the file committed to git — it lists every variable the application needs with placeholder values so a new developer can clone the repo, copy it to `.env`, fill in real values, and run the app immediately.

  ```bash
  # .env.example — commit this to git
  # Copy to .env and fill in real values. Never commit .env.

  # ── Database ──────────────────────────────────────────────────────────────────
  DB_HOST=localhost
  DB_PORT=5432
  DB_USER=appuser
  DB_PASSWORD=changeme           # replace with real password, never commit .env

  # ── Redis ──────────────────────────────────────────────────────────────────────
  REDIS_HOST=localhost
  REDIS_PORT=6379

  # ── External Services ─────────────────────────────────────────────────────────
  STRIPE_API_KEY=sk_test_replaceme    # use a test key for local dev
  SENDGRID_API_KEY=SG.replaceme

  # ── Application ───────────────────────────────────────────────────────────────
  API_URL=https://api.example.com
  NODE_ENV=development
  LOG_LEVEL=info
  PORT=3000
  ```

  Confirm `.env` is in `.gitignore` (`.env.example` must be explicitly allowed back in):

  ```bash
  # Check whether .env is already ignored
  cat .gitignore | grep "\.env"

  # If not present, add it
  echo ".env" >> .gitignore
  echo ".env.*" >> .gitignore
  echo "!.env.example" >> .gitignore

  # Verify the actual .env file is now ignored (should print nothing)
  git status --short | grep "\.env$"
  ```

  **Step 3: Replace Hardcoded Values with Environment Variable References**

  Using the values surfaced in Story 1.1, go through the codebase and replace every hardcoded value with a direct `process.env.*` / `os.environ.*` read. Before you start editing, compile your findings into a quick reference table — you'll need it when writing the startup validation list and `.env.example` in the steps below:

  | Variable Name    | Example Value         | Secret? | Notes                                   |
  | ---------------- | --------------------- | ------- | --------------------------------------- |
  | `DB_HOST`        | `prod-db.example.com` | No      | RDS endpoint                            |
  | `DB_PORT`        | `5432`                | No      |                                         |
  | `DB_USER`        | `app_user`            | No      |                                         |
  | `DB_PASSWORD`    | `hunter2`             | **Yes** | Will move to Secrets Manager in Story 3 |
  | `REDIS_HOST`     | `redis.example.com`   | No      |                                         |
  | `STRIPE_API_KEY` | `sk_live_...`         | **Yes** |                                         |
  | `PORT`           | `3000`                | No      | HTTP port the app listens on            |

  > **Watch for gaps:** Developers often add variables without telling anyone. If you find a value in the code that isn't in your Story 1.1 notes, add it to the table now — a missing entry means a silent `undefined` in production.

  **Step 4: Add Startup Validation**

  The application must crash immediately on startup if a required variable is missing — with a clear message listing exactly which ones. A silent `undefined` or `None` will cause confusing failures deep in the application later and are very hard to debug.

  **Recommended approach — use a schema validation library (Node.js)**

  A library like `Zod` or `Joi` is better than a hand-rolled required-variable check because it also validates _types and formats_ (e.g., `PORT` must be a number, `DATABASE_URL` must be a valid URL). This catches misconfiguration before the app tries to use the value.

  ```bash
  # Zod is the current standard for TypeScript/JS projects
  npm install zod
  ```

  Create a dedicated `src/env.ts` (or `src/config/env.js`) file — do not scatter `process.env` reads throughout the codebase:

  ```typescript
  // src/env.ts — import this at the very top of your entry point
  import { z } from "zod";

  const envSchema = z.object({
    DB_HOST: z.string().min(1),
    DB_PORT: z.coerce.number().default(5432),
    DB_USER: z.string().min(1),
    DB_PASSWORD: z.string().min(1),
    REDIS_HOST: z.string().min(1),
    REDIS_PORT: z.coerce.number().default(6379),
    API_URL: z.string().url(),
    STRIPE_API_KEY: z.string().startsWith("sk_"),
    PORT: z.coerce.number().default(3000),
    NODE_ENV: z
      .enum(["development", "production", "test"])
      .default("development"),
  });

  const result = envSchema.safeParse(process.env);

  if (!result.success) {
    console.error("ERROR: Invalid or missing environment variables:");
    console.error(result.error.flatten().fieldErrors);
    console.error("\nSee .env.example for the full list with descriptions.");
    process.exit(1);
  }

  export const env = result.data;
  // Now import `env` everywhere instead of reading process.env directly:
  // import { env } from "./env";
  // const db = connect(env.DB_HOST, env.DB_PORT);
  ```

  > **TypeScript users:** In addition to Zod, create an `env.d.ts` (or `src/types/env.d.ts`) to give `process.env` proper types everywhere in the codebase. Without it, `process.env.DB_HOST` is `string | undefined` even after you've validated it.
  >
  > ```typescript
  > // env.d.ts
  > declare namespace NodeJS {
  >   interface ProcessEnv {
  >     DB_HOST: string;
  >     DB_PORT: string;
  >     DB_USER: string;
  >     DB_PASSWORD: string;
  >     REDIS_HOST: string;
  >     REDIS_PORT: string;
  >     API_URL: string;
  >     STRIPE_API_KEY: string;
  >     PORT?: string;
  >     NODE_ENV: "development" | "production" | "test";
  >   }
  > }
  > ```
  >
  > The exported `env` object from the Zod approach is still preferred for accessing values — this declaration just prevents `string | undefined` noise in raw `process.env` access.

  **Plain JS alternative (no library)**

  If you prefer not to add a dependency, a manual check still beats nothing:

  ```javascript
  // Put this at the very top of your entry point
  const REQUIRED = [
    "DB_HOST",
    "DB_USER",
    "DB_PASSWORD",
    "REDIS_HOST",
    "API_URL",
    "STRIPE_API_KEY",
  ];
  const missing = REQUIRED.filter((k) => !process.env[k]);
  if (missing.length) {
    console.error(
      "ERROR: Missing required environment variables:\n" +
        missing.map((k) => `  - ${k}`).join("\n"),
    );
    console.error("\nSee .env.example for the full list with descriptions.");
    process.exit(1);
  }
  ```

  When this is working correctly, starting the application without setting variables should look like:

  ```
  ERROR: Missing required environment variables:
    - DB_PASSWORD
    - STRIPE_API_KEY

  Set these variables before starting the application.
  See .env.example for the full list with descriptions.
  ```

---

## Story 1.3: Create Secrets in AWS Secrets Manager

- **Title:** Create Application Secrets in AWS Secrets Manager
- **Persona:** As a **Platform Engineer**, I want all application secrets stored in Secrets Manager so there is one authoritative source of truth used by both EC2 and ECS.

**Business Value:** Centralizing secrets in Secrets Manager eliminates the risk of secrets drifting out of sync across environments and removes plaintext secrets from server filesystems. EC2 apps pull values from Secrets Manager to populate their `.env` file; ECS tasks have secrets injected automatically at startup. Both use the same secret — one place to rotate, one place to audit.

- **Requirements:**
  - Naming convention agreed upon before creating any secrets
  - One secret per logical group (e.g., all DB connection fields in one JSON secret)
  - Secret ARNs documented so they can be referenced by both EC2 and ECS

- **Implementation Details:**

  **Secret Naming Convention**

  Agree on this before creating anything — changing it later requires updating IAM policies and anywhere the ARN is referenced:

  ```
  {environment}/{app-name}/{secret-type}

  Examples:
    dev/auth-api/database
    dev/auth-api/api-keys
    dev/shared/redis
  ```

  **Secret Structure (JSON)**

  Group related fields into a single secret to minimize API calls and IAM policy complexity:

  > **Cost:** Secrets Manager charges **$0.40 per secret per month** plus **$0.05 per 10,000 API calls**. One secret with five fields costs $0.40/month. Five separate secrets with one field each costs $2.00/month — 5× more for the same data, with 5× the IAM policy complexity. Group by rotation boundary (database credentials together, API keys together) not by field.

  ```json
  {
    "username": "app_user",
    "password": "super-secret-password",
    "host": "mydb.cluster-abc123.us-east-1.rds.amazonaws.com",
    "port": "5432",
    "database": "auth_db"
  }
  ```

  **Create the Secret Shell via Terraform**

  The secret _shell_ (name, description) lives in Terraform and is code-reviewed. The actual _value_ is never stored in git — it is populated separately through a secure channel.

  **Which repo and where:**
  Secrets are platform infrastructure, so they live in `mycompany.infra-platform` — not in the application repo. The `02-storage` layer is the right home for Secrets Manager resources. The directory currently has only a `.gitkeep` — you'll be adding the Terraform files to bootstrap it as a working layer.

  ```
  mycompany.infra-platform/
  └── environments/
      └── dev/
          └── us-east-1/
              └── 02-storage/       ← add files here
                  ├── backend.tf    ← state config (follow pattern from 00-network / 01-compute)
                  ├── versions.tf   ← required_providers block
                  ├── providers.tf  ← aws provider config
                  └── secrets.tf    ← one resource per secret
  ```

  **`backend.tf`** — follows the same pattern as the other layers:

  ```hcl
  terraform {
    backend "s3" {
      bucket         = "mycompany-solutions-terraform-state-dev"
      key            = "platform/dev/us-east-1/02-storage/terraform.tfstate"
      region         = "us-east-1"
      encrypt        = true
      dynamodb_table = "terraform-locks-dev"
      use_lockfile   = true
    }
  }
  ```

  > **Preventing secret values from accidentally end up in git**
  > `aws_secretsmanager_secret` creates the named container — it has no `secret_string` argument. There is literally no field in this resource to put a value in. The secret value lives in a separate resource, `aws_secretsmanager_secret_version`, which is intentionally absent here.

  **`secrets.tf`** — one `aws_secretsmanager_secret` resource per logical secret group, with an output for each ARN:

  ```hcl
  # secrets.tf

  # ── auth-api ──────────────────────────────────────────────────────────────────

  resource "aws_secretsmanager_secret" "auth_api_database" {
    name        = "dev/auth-api/database"
    description = "auth-api RDS credentials (username, password, host, port, database)"
    tags        = var.tags
  }

  resource "aws_secretsmanager_secret" "auth_api_keys" {
    name        = "dev/auth-api/api-keys"
    description = "auth-api third-party API keys (Stripe, SendGrid, etc.)"
    tags        = var.tags
  }

  # ── shared ───────────────────────────────────────────────────────────────────

  resource "aws_secretsmanager_secret" "shared_redis" {
    name        = "dev/shared/redis"
    description = "Shared Redis credentials (host, port, password)"
    tags        = var.tags
  }

  # ── outputs (ARNs only — not sensitive) ──────────────────────────────────────

  output "auth_api_database_secret_arn" {
    value = aws_secretsmanager_secret.auth_api_database.arn
  }

  output "auth_api_keys_secret_arn" {
    value = aws_secretsmanager_secret.auth_api_keys.arn
  }

  output "shared_redis_secret_arn" {
    value = aws_secretsmanager_secret.shared_redis.arn
  }
  ```

  **Initialize and apply:**

  ```bash
  cd mycompany.infra-platform/environments/dev/us-east-1/02-storage

  terraform init    # downloads provider, connects to S3 backend
  terraform plan    # confirm only secret shells are being created — no values
  terraform apply
  ```

  After `apply`, the secrets exist in AWS with no value set yet. The next step populates the values.

  **Populate the Secret Value**

  After `terraform apply` creates the shell, populate the value through the AWS console.

  **Grant Access via IAM**

  Creating the secret is not enough — the consumer (EC2 instance or ECS task) must have explicit permission to read it. Add `secretsmanager:GetSecretValue` to the appropriate IAM role:

  ```hcl
  # Add this policy to the EC2 instance profile role or ECS task execution role
  # (typically in the IAM Terraform layer that manages those roles)

  data "aws_iam_policy_document" "secrets_read" {
    statement {
      sid       = "AllowReadApplicationSecrets"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [
        aws_secretsmanager_secret.auth_api_database.arn,
        aws_secretsmanager_secret.auth_api_keys.arn,
        aws_secretsmanager_secret.shared_redis.arn,
      ]
    }
  }

  resource "aws_iam_policy" "secrets_read" {
    name   = "dev-auth-api-secrets-read"
    policy = data.aws_iam_policy_document.secrets_read.json
  }

  # Attach to EC2 instance profile role:
  resource "aws_iam_role_policy_attachment" "ec2_secrets_read" {
    role       = aws_iam_role.ec2_instance_role.name
    policy_arn = aws_iam_policy.secrets_read.arn
  }

  # Attach to ECS task execution role:
  resource "aws_iam_role_policy_attachment" "ecs_task_secrets_read" {
    role       = aws_iam_role.ecs_task_execution_role.name
    policy_arn = aws_iam_policy.secrets_read.arn
  }
  ```

  > Without this policy, both EC2 (`aws secretsmanager get-secret-value`) and ECS (task definition `secrets` injection) will fail with `AccessDeniedException`. Restrict `resources` to the specific ARNs — never use `"*"`.

- **Acceptance Criteria:**
  - ✅ Naming convention agreed upon and documented
  - ✅ All secrets created in Secrets Manager with values populated
  - ✅ Secret ARNs documented (e.g., in a shared doc or repo outputs)
  - ✅ No plaintext secrets in any file committed to git

---

## Phase Completion Checklist

- [ ] Zero secrets found in codebase (gitleaks scan passes)
- [ ] All configuration externalized to environment variables
- [ ] `.env.example` file created and documented
- [ ] Application tested on EC2 with environment variable configuration
- [ ] Team trained on secret management and environment variable usage
- [ ] README updated with required environment variables
- [ ] Secrets naming convention agreed upon and documented
- [ ] All secrets created in AWS Secrets Manager with ARNs recorded

---

## Rollback Plan

If issues are discovered after deployment:

1. **Secrets exposed in git history:** Rotate credentials immediately, continue with git filter-repo cleanup
2. **Missing environment variables:** Add to `.env` file on EC2, restart application
3. **Wrong configuration values:** Update `.env` file, restart application (no code deploy needed)
