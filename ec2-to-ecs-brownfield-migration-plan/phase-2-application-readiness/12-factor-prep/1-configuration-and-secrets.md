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

**Prerequisites:** None—start here

**Next Phase:** [Stateless Application](2-stateless-application.md)

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
  - Remove secrets from code and replace with environment variable references
  - Verify no secrets in Docker image layers

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

  ```bash
  # Database credentials
  grep -r "password.*=.*['\"]" . --exclude-dir=node_modules
  grep -r "DB_PASSWORD.*=.*['\"]" .

  # API keys
  grep -r "api[_-]key.*=.*['\"]" . -i
  grep -r "['\"][a-zA-Z0-9]{32,}['\"]" .  # Long random strings

  # AWS credentials
  grep -r "AKIA[0-9A-Z]{16}" .  # AWS Access Keys
  grep -r "aws_secret_access_key" .

  # Common SaaS patterns
  grep -r "stripe.*sk_live" . -i
  grep -r "sendgrid.*SG\." . -i
  grep -r "twilio.*SK" . -i
  ```

  **Step 3: Replace Hardcoded Values**

  **Before (hardcoded - BAD):**

  ```javascript
  const stripe = require("stripe")("sk_live_abc123def456...");
  const dbPassword = "mySecretPassword123";
  const apiKey = "1234567890abcdef";
  ```

  **After (externalized - GOOD):**

  ```javascript
  const stripe = require("stripe")(process.env.STRIPE_API_KEY);
  const dbPassword = process.env.DB_PASSWORD;
  const apiKey = process.env.API_KEY;
  ```

  **Step 4: Check Docker Images (if building containers already)**

  ```bash
  # Build image
  docker build -t my-app .

  # Check each layer for secrets
  docker history my-app --no-trunc
  docker save my-app -o my-app.tar
  tar -xf my-app.tar
  grep -r "api_key\|password\|secret" .
  ```

  **Step 5: Clean Git History (if secrets found)**

  ⚠️ **WARNING:** Removing from git history requires force-push and coordination with team

  ```bash
  # Use BFG Repo-Cleaner (easier than git-filter-branch)
  brew install bfg

  # Create a file with patterns to remove
  echo "sk_live_" > secrets.txt
  echo "api_key_123" >> secrets.txt

  # Remove secrets from history
  bfg --replace-text secrets.txt .

  # Force push (COORDINATE WITH TEAM FIRST)
  git push --force
  ```

  **Alternative:** Rotate the exposed credentials immediately (safer, faster)

  **Step 6: Prevent Future Secret Commits**

  ```bash
  # Install pre-commit
  pip install pre-commit

  # Create .pre-commit-config.yaml
  cat > .pre-commit-config.yaml <<EOF
  repos:
    - repo: https://github.com/gitleaks/gitleaks
      rev: v8.18.0
      hooks:
        - id: gitleaks
  EOF

  # Install hooks
  pre-commit install
  ```

- **Acceptance Criteria:**
  - ✅ Gitleaks scan shows zero secrets in current code
  - ✅ Gitleaks scan shows zero secrets in git history (or exposed secrets rotated)
  - ✅ All secrets replaced with `process.env.*` or equivalent
  - ✅ `.env.example` file created with dummy values for all required secrets
  - ✅ Pre-commit hooks installed to prevent future secret commits
  - ✅ Team trained on never committing secrets to git

- **EC2 Testing:**
  - Deploy with secrets in `.env` file (PM2/systemd loads it)
  - Verify application starts and functions correctly
  - Confirm no secrets in application logs

---

## Story 2: Migrate Configuration to Environment Variables

- **Title:** Migrate Configuration to Environment Variables
- **Persona:** As a **developer**, I need the application to read all configuration from environment variables so that I can deploy the same image to different environments (dev, staging, prod) without rebuilding.

**Business Value:** Eliminates deployment errors from hardcoded configurations and enables rapid environment promotion. Deploying the same image from dev to production (no rebuild) reduces deployment time from 30 minutes to 5 minutes and eliminates "forgot to update config" bugs that cause 20-30% of deployment failures.

- **Requirements:**
  - No `.env` files baked into application code
  - No hardcoded configuration in source code
  - All configuration (DB hosts, API URLs, feature flags) injected at runtime
  - Application must fail gracefully with clear errors if required variables are missing

- **Implementation Details:**

  **Step 1: Inventory Current Configuration**

  Create a list of all configuration values currently in:
  - `.env` files
  - `config.js` / `settings.py` / etc.
  - Hardcoded in application code

  **Step 2: Refactor Application Code**

  **Node.js Example:**

  ```javascript
  // Before (hardcoded)
  const config = {
    db: {
      host: "localhost",
      port: 3306,
      user: "app",
      password: "secret",
    },
    redis: {
      host: "localhost",
      port: 6379,
    },
    apiUrl: "https://api.example.com",
  };

  // After (from environment)
  const config = {
    db: {
      host: process.env.DB_HOST || "localhost",
      port: parseInt(process.env.DB_PORT || "3306"),
      user: process.env.DB_USER,
      password: process.env.DB_PASSWORD,
    },
    redis: {
      host: process.env.REDIS_HOST,
      port: parseInt(process.env.REDIS_PORT || "6379"),
    },
    apiUrl: process.env.API_URL,
  };

  // Add validation
  const required = ["DB_HOST", "DB_USER", "DB_PASSWORD", "REDIS_HOST"];
  const missing = required.filter((key) => !process.env[key]);
  if (missing.length > 0) {
    console.error(
      `Missing required environment variables: ${missing.join(", ")}`,
    );
    process.exit(1);
  }
  ```

  **Python Example:**

  ```python
  import os
  import sys

  # Before (hardcoded)
  # DB_HOST = 'localhost'
  # DB_PORT = 3306

  # After (from environment)
  DB_HOST = os.environ.get('DB_HOST')
  DB_PORT = int(os.environ.get('DB_PORT', '3306'))
  DB_USER = os.environ.get('DB_USER')
  DB_PASSWORD = os.environ.get('DB_PASSWORD')

  # Validation
  required = ['DB_HOST', 'DB_USER', 'DB_PASSWORD']
  missing = [k for k in required if not os.environ.get(k)]
  if missing:
      print(f"Missing required environment variables: {', '.join(missing)}", file=sys.stderr)
      sys.exit(1)
  ```

  **Step 3: Create `.env.example` File**

  ```bash
  # Database Configuration
  DB_HOST=localhost
  DB_PORT=3306
  DB_USER=appuser
  DB_PASSWORD=changeme

  # Redis Configuration
  REDIS_HOST=localhost
  REDIS_PORT=6379

  # External Services
  STRIPE_API_KEY=sk_test_replaceme
  SENDGRID_API_KEY=SG.replaceme

  # Application Settings
  NODE_ENV=production
  LOG_LEVEL=info
  PORT=3000
  ```

  **Step 4: Update Deployment Documentation**

  Document how secrets flow in different environments:

  ```
  ┌─────────────────────┐      ┌─────────────────────┐      ┌─────────────────────┐
  │  Secrets Manager    │ ───▶ │  ECS Task Def       │ ───▶ │  Your App           │
  │  (Future: Phase 3)  │      │  (secrets block)    │      │  (reads from        │
  │                     │      │                     │      │   process.env)      │
  └─────────────────────┘      └─────────────────────┘      └─────────────────────┘
  ```

  - **Current (EC2):** App reads from `.env` file loaded by PM2/systemd
  - **Future (ECS):** App reads from environment variables injected by ECS
  - **App code:** Identical in both cases—just reads `process.env.*`

  **Step 5: Test Backward Compatibility on EC2**

  ```bash
  # On EC2, create .env file (NOT in git)
  cat > .env <<EOF
  DB_HOST=prod-db.example.com
  DB_USER=appuser
  DB_PASSWORD=actual_secret_here
  EOF

  # PM2 loads .env automatically
  pm2 start app.js

  # Or with systemd
  # Add EnvironmentFile=/path/to/.env in unit file
  ```

- **Acceptance Criteria:**
  - ✅ Application reads all config from `process.env.*` / `os.environ.*`
  - ✅ Missing required env vars produce clear startup error with variable names
  - ✅ `.env.example` file created and documented
  - ✅ Application works on EC2 with `.env` file
  - ✅ Application works with only `-e` flags (no `.env` file): `docker run -e DB_HOST=... my-app`
  - ✅ README documents all required environment variables

- **EC2 Testing:**
  - Deploy to EC2 dev/staging with `.env` file
  - Verify application starts correctly
  - Test missing required variable (should fail with clear error)
  - Test changing configuration (should work without code redeploy)

---

## Phase Completion Checklist

Before proceeding to [Stateless Application](2-stateless-application.md) phase:

- [ ] Zero secrets found in codebase (gitleaks scan passes)
- [ ] All configuration externalized to environment variables
- [ ] `.env.example` file created and documented
- [ ] Pre-commit hooks prevent future secret commits
- [ ] Application tested on EC2 with environment variable configuration
- [ ] Team trained on secret management and environment variable usage
- [ ] README updated with required environment variables

---

## Rollback Plan

If issues are discovered after deployment:

1. **Secrets exposed in git history:** Rotate credentials immediately, continue with BFG cleanup
2. **Missing environment variables:** Add to `.env` file on EC2, restart application
3. **Wrong configuration values:** Update `.env` file, restart application (no code deploy needed)
