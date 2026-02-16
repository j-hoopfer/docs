# Platform Repository Setup

**Goal:** Initialize the `infra-platform` repository which will house the shared VPC, ALB, and ECS Cluster resources, providing an organized foundation for shared infrastructure.

## Context & Themes

Separating platform infrastructure from application services ensures that core networking components are isolated from frequent application deployments, reducing blast radius and complexity.

**Key Themes:**

- **Blast Radius Reduction:** Isolating critical networking from app changes.
- **Repository Structure:** Establishing a clean IaC foundation.
- **State Management:** Preparing for remote state usage.

### Prerequisites

- [ ] Terraform State Bootstrap plan completed (S3 Bucket + DynamoDB Table).
- [ ] GitHub Organization Access to create repositories.
- [ ] Decisions made on repository naming conventions.

## Feature 1: Initialize Platform Infrastructure Repository

### Story 1.1: Initialize Platform Infrastructure Repository

- **Title:** Create `infra-platform` Repository
- **Persona:** As a **DevOps lead**, I need a dedicated platform infrastructure repository so that shared resources are isolated from application-specific configurations.

**Business Value:** Establishes single source of truth for shared infrastructure. Repository setup in Phase 0 provides the necessary foundation for subsequent discovery and architecture phases.

- **Requirements:**
  - `infra-platform` repository created
  - `.gitignore` configured to exclude sensitive files
  - Directory structure initialized for multi-region/environment support

- **Implementation Details:**

  #### 1) Create Local Platform Repository

  ```bash
  mkdir -p ~/Projects/infra-platform
  cd ~/Projects/infra-platform
  git init

  # Create standard directory structure
  mkdir -p environments/dev/us-east-1
  mkdir -p environments/prod/us-east-1
  mkdir -p modules

  # Create placeholder files to ensure directories are tracked by Git
  touch environments/dev/us-east-1/.gitkeep
  touch environments/prod/us-east-1/.gitkeep
  touch modules/.gitkeep
  ```

  #### 2) Create `.gitignore`

  ```bash
  cat > .gitignore << 'EOF'
  # macOS
  .DS_Store

  # Terraform
  .terraform/
  .terraform.lock.hcl
  *.tfstate
  *.tfstate.*
  *.tfvars
  !*.tfvars.example
  crash.log
  override.tf
  override.tf.json
  *_override.tf
  *_override.tf.json

  # Secrets (double-check!)
  .env
  .env.*
  secrets.tfvars
  EOF
  ```

### Story 1.2: Configure IaC Linting & Git Hooks

- **Title:** Setup TFLint and Pre-commit Hooks
- **Persona:** As a **DevOps Lead**, I want to enforce code quality standards automatically so that invalid or insecure Terraform code is never committed to the repository.

**Business Value:** Detects configuration errors and best-practice violations before they cause deployment failures. TFLint catches AWS-specific issues (like invalid instance types) that `terraform validate` misses, saving hours of "apply-fail-fix" cycles. Pre-commit hooks ensure formatting is consistent across the team, eliminating "nitpick" comments in code reviews.

- **Requirements:**
  - `tflint` configured with AWS plugin
  - `terraform fmt` check enabled
  - GitHub Action (or Git Hook) created to run checks on PRs

- **Implementation Details:**

  > **Note:** Ensure TFLint is installed on your workstation (see [Developer Onboarding Guide](../../developer-onboarding-guide/workstation-setup.md)).

  #### 1) Add `.tflint.hcl` Configuration

  Create a `.tflint.hcl` file in the repository root:

  ```hcl
  plugin "aws" {
    enabled = true
    version = "0.28.0"
    source  = "github.com/terraform-linters/tflint-ruleset-aws"
  }

  config {
    module = true
  }
  ```

  #### 2) Create CI Workflows (Lint & Validate)

  Create `.github/workflows/lint.yml` for policy checks:

  ```bash
  mkdir -p .github/workflows

  cat > .github/workflows/lint.yml << 'EOF'
  name: Terraform Lint
  on:
    pull_request:
    workflow_dispatch:

  jobs:
    tflint:
      name: TFLint
      runs-on: ubuntu-latest
      env:
        TFLINT_VERSION: v0.50.0
      steps:
        - uses: actions/checkout@v4
        - uses: actions/cache@v4
          with:
            path: ~/.tflint.d/plugins
            # give unique cache name to prevent reuse of an incompatible cached plugin set
            key: tflint-${{ runner.os }}-${{ runner.arch }}-${{ env.TFLINT_VERSION }}-${{ hashFiles('.tflint.hcl') }}
        - uses: terraform-linters/setup-tflint@v4
          with:
            tflint_version: ${{ env.TFLINT_VERSION }}
        - name: Init TFLint
          run: tflint --init
        - name: Run TFLint
          # find all directories containing Terraform files and lint each one
          run: |
            set -euo pipefail
            find . -type f -name '*.tf' -printf '%h\n' | sort -u | while read -r dir; do
              echo "Running tflint in ${dir}"
              (cd "${dir}" && tflint -f compact)
            done
  EOF
  ```

  Create `.github/workflows/validate.yml` for syntax and formatting checks:

  ```bash
  cat > .github/workflows/validate.yml << 'EOF'
  name: Terraform Validate
  on:
    pull_request:
    workflow_dispatch:

  jobs:
    fmt:
      name: Terraform Fmt
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v4
        - uses: hashicorp/setup-terraform@v3
        - name: Terraform Fmt
          run: terraform fmt -check -recursive

    validate:
      name: Terraform Validate
      runs-on: ubuntu-latest
      strategy:
        matrix:
          # Verify all environment directories
          directory: [environments/dev/us-east-1, environments/prod/us-east-1]
      steps:
        - uses: actions/checkout@v4
        - uses: hashicorp/setup-terraform@v3
          with:
            terraform_version: 1.7.4

        - name: Terraform Init
          working-directory: ${{ matrix.directory }}
          run: terraform init -backend=false

        - name: Terraform Validate
          working-directory: ${{ matrix.directory }}
          run: terraform validate
  EOF
  ```

### Story 1.3: Configure Terraform Backend and Providers

- **Title:** Setup Terraform State Backend and AWS Provider
- **Persona:** As a **DevOps Lead**, I need to configure the repository to use the remote S3 state and AWS provider so that keeping infrastructure in sync is possible from the start.

**Business Value:** Connects the repository to the previously created state infrastructure (S3+DynamoDB), enabling team collaboration on the same state file immediately.

- **Requirements:**
  - `versions.tf` created with Terraform version constraints.
  - `main.tf` (or `backend.tf`) configured with S3 backend.
  - `provider.tf` configured with AWS provider.

- **Implementation Details:**

  #### 1) Retrieve State Bucket & Table Names

  Run these commands to find the values created in the Bootstrap phase:

  ```bash
  # Find the bucket name (look for 'terraform-state')
  aws s3 ls --profile scale-dev

  # Find the DynamoDB table (look for 'terraform-locks')
  aws dynamodb list-tables --profile scale-dev
  ```

  #### 2) Create `versions.tf`

  Create this file in `environments/dev/us-east-1/versions.tf` (and repeat for other environments):

  ```hcl
  terraform {
    required_version = ">= 1.0.0"

    required_providers {
      aws = {
        source  = "hashicorp/aws"
        version = "~> 5.0"
      }
    }
  }
  ```

  #### 3) Create `main.tf` (Backend Configuration)

  Create `environments/dev/us-east-1/main.tf`:

  _(Note: Replace `YOUR_BUCKET_NAME` and `YOUR_DYNAMODB_TABLE` with the values found above.)_

  ```hcl
  terraform {
    backend "s3" {
      bucket         = "YOUR_BUCKET_NAME"
      key            = "platform/dev/us-east-1/terraform.tfstate"
      region         = "us-east-1"
      encrypt        = true
      dynamodb_table = "YOUR_DYNAMODB_TABLE"
    }
  }
  ```

  #### 4) Create `provider.tf`

  Create `environments/dev/us-east-1/provider.tf`:

  ```hcl
  provider "aws" {
    region = "us-east-1"

    default_tags {
      tags = {
        Environment = "dev"
        Repository  = "infra-platform"
        ManagedBy   = "Terraform"
      }
    }
  }
  ```

### Story 1.4: Push Initial Repository to GitHub

- **Title:** Commit and Push Initial Code
- **Persona:** As a **DevOps Lead**, I need to push the local repository to GitHub so that the remote repository is initialized and CI workflows can run for the first time.

**Business Value:** Establishes the existence of the codebase on the shared platform, triggering the first set of validation checks.

- **Requirements:**
  - Remote origin configured
  - Initial commit created
  - Code pushed to `main` branch

- **Implementation Details:**

  #### 1) Create Remote Repository (GitHub UI or CLI)

  **Option A: GitHub CLI (Recommended)**

  ```bash
  # Private repository within an organization (replace my-org)
  gh repo create my-org/infra-platform --private
  ```

  **Option B: GitHub UI**
  1. Go to https://github.com/new
  2. Select Owner (Organization).
  3. Repository name: `infra-platform`
  4. Privacy: Private.
  5. **Do not** initialize with README, .gitignore, or license (we did this locally).
  6. Click "Create repository".

  #### 2) Commit and Push Code

  ```bash
  # Ensure you are at the root of the infra-platform directory
  git add .
  git commit -m "feat: initial repository structure and CI workflows"

  # Configure remote (Replace with your actual organization URL)
  # If you used 'gh repo create' above, the remote 'origin' might already be set.
  if ! git remote | grep -q origin; then
    git remote add origin git@github.com:my-org/infra-platform.git
  fi

  git branch -M main
  git push -u origin main
  ```

### Story 1.5: Configure Branch Protection Policies

- **Title:** Enforce Branch Protection on `main`
- **Persona:** As a **DevOps Lead**, I need to prevent direct changes to the production branch so that all infrastructure changes are peer-reviewed and validated by CI.

**Business Value:** Prevents "configuration drift" caused by unreviewed manual changes. Ensures that every change to infrastructure passes the automated checks defined in Story 1.2 before it can be merged, significantly reducing the risk of breaking production.

- **Requirements:**
  - `main` branch protected from direct pushes
  - Pull Request required for merging
  - 1 approvals required
  - Status checks (Lint, Validate) required to pass before merging

- **Implementation Details:**

  #### 1) Configure GitHub Branch Protection Rule
  1.  Navigate to your repository on GitHub.
  2.  Go to **Settings** -> **Branches**.
  3.  Click **Add branch protection rule**.
  4.  **Branch name pattern:** `main`
  5.  Check **Require a pull request before merging**.
      - Check **Require approvals** (Default: 1).
  6.  Check **Require status checks to pass before merging**.
      - Search for and select: `TFLint` (from the lint workflow).
      - Search for and select: `Terraform Fmt` (from the validate workflow).
      - Search for and select: `Terraform Validate` (from the validate workflow).
  7.  Check **Do not allow bypassing the above settings**.
  8.  Click **Create**.

---

## Acceptance Criteria

**Verify the setup by simulating a typical developer workflow:**

1.  **Direct Push Blocked:**
    - Make a small local change on `main` (e.g., `touch test_protection && git add test_protection && git commit -m "test protection"`).
    - Attempt to push directly: `git push origin main`.
    - **Pass:** Output should say `error: failed to push some refs... protected branch hook declined`.
    - _Cleanup:_ `git reset --hard HEAD~1` (undo the test commit).

2.  **Pull Request Validation:**
    - Create a new branch: `git checkout -b chore/test-ci-pipeline`.
    - Make a small change (e.g., add `// trigger ci` to `environments/dev/us-east-1/main.tf`).
    - Commit and push: `git commit -am "chore: trigger ci" && git push origin chore/test-ci-pipeline`.
    - Open a Pull Request on GitHub.
    - **Pass:** The "Checks" section shows `TFLint`, `Terraform Fmt`, and `Terraform Validate` running.
    - **Pass:** Checks must succeed (turn green) before the "Merge" button is enabled.

3.  **Peer Review:**
    - **Pass:** The PR requires at least one approval from another user.

4.  **Merge:**
    - After approval and checks pass, merge the PR.
    - **Pass:** The `main` branch is updated with your change.
