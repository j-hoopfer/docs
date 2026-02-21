# Services Repository Setup

**Goal:** Initialize the `infra-services` repository which will house the individual Service, Task Definition, and Target Group resources for each application.

## Context & Themes

Decoupling application lifecycles from platform lifecycles allows developers to iterate on ECS Task Definitions rapidly without risking stability of the underlying VPC or ALB network.

**Key Themes:**

- **Decoupling:** Separating app lifecycle from platform lifecycle.
- **Developer Autonomy:** Enabling rapid iteration on task definitions.
- **Service Isolation:** Ensuring services don't impact shared infrastructure.

### Prerequisites

- [ ] [Platform Repository Setup](1-platform-repository-setup.md) completed.
- [ ] Terraform State Bootstrap plan completed.
- [ ] GitHub permission to create repositories.

## Feature 2: Initialize Services Repository

### Story 2.1: Initialize Services Repository

- **Title:** Create `infra-services` Repository
- **Persona:** As a **Developer Experience Lead**, I need an application-specific infrastructure repository so that product teams can deploy services without touching core networking or cluster configurations.

**Business Value:** Decouples application lifecycles from platform lifecycles. This allows developers to iterate on ECS Task Definitions and Target Groups rapidly without risking stability of the underlying VPC or ALB network.

- **Requirements:**
  - `infra-services` repository created
  - `.gitignore` configured similar to platform repo
  - Structure initialized to support service-specific modules

- **Implementation Details:**

  #### 1) Create Local Service Repository

  ```bash
  mkdir -p ~/Projects/infra-services
  cd ~/Projects/infra-services
  git init

  # Create standard service-oriented structure
  # Pattern: environments/{env}/{region}/{service-name}
  mkdir -p environments/dev/us-east-1/auth-api
  mkdir -p modules/ecs-service

  # Create placeholder files to ensure directories are tracked by Git
  touch environments/dev/us-east-1/auth-api/.gitkeep
  touch modules/ecs-service/.gitkeep
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

### Story 2.2: Configure IaC Linting & Git Hooks

- **Title:** Setup TFLint and Pre-commit Hooks for Services Repo
- **Persona:** As a **DevOps Lead**, I want to enforce code quality standards on service infrastructure code so that developers don't accidentally commit invalid Terraform configurations.

**Business Value:** Prevents configuration errors in service definitions before they reach the main branch. TFLint catches issues like invalid instance types or missing required arguments early. Pre-commit hooks ensure consistent formatting across all service definitions, making code reviews faster and reducing "nitpick" comments.

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

  #### 2) Initialize TFLint

  ```bash
  tflint --init
  ```

  #### 3) Create Pre-commit Hook (Local Dev)

  Create `.git/hooks/pre-commit`:

  ```bash
  #!/bin/sh
  # Run terraform fmt
  if ! terraform fmt -check -recursive; then
    echo "Terraform code is not formatted. Run 'terraform fmt -recursive' to fix."
    exit 1
  fi

  # Run tflint (optional, can be slow on large repos)
  # tflint --recursive
  ```

  Make it executable:

  ```bash
  chmod +x .git/hooks/pre-commit
  ```

  #### 4) Create CI Workflows (Lint & Validate)

  ```bash
  mkdir -p .github/workflows/

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

  Add `.github/workflows/validate.yml` for syntax and formatting checks:

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
          # Verify service directory and modules
          directory: [environments/dev/us-east-1/auth-api, modules/ecs-service]
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

### Story 2.3: Configure Terraform Backend and Providers

- **Title:** Setup Terraform State Backend and AWS Provider
- **Persona:** As a **DevOps Lead**, I need to configure the repository to use the remote S3 state and AWS provider so that keeping infrastructure in sync is possible from the start.

**Business Value:** Connects the repository to the previously created state infrastructure (S3+DynamoDB), enabling team collaboration on the same state file immediately.

- **Requirements:**
  - `versions.tf` created with Terraform version constraints.
  - **`backend.tf` configured with S3 backend (separate from main.tf).**
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

  ```bash
  touch environments/dev/us-east-1/auth-api/{versions,backend,provider}.tf
  ```

  #### 2) Create `versions.tf`

  Create this file in `environments/dev/us-east-1/auth-api/versions.tf` (and repeat for other services):

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

  #### 3) Create `backend.tf` (Backend Configuration)

  Create `environments/dev/us-east-1/auth-api/backend.tf`:

  _(Note: Replace `YOUR_BUCKET_NAME` and `YOUR_DYNAMODB_TABLE` with the values found above.)_

  ```hcl
  terraform {
    backend "s3" {
      bucket         = "YOUR_BUCKET_NAME"
      key            = "services/dev/us-east-1/auth-api/terraform.tfstate"
      region         = "us-east-1"
      encrypt        = true
      dynamodb_table = "YOUR_DYNAMODB_TABLE"
    }
  }
  ```

  #### 4) Create `provider.tf`

  Create `environments/dev/us-east-1/auth-api/provider.tf`:

  ```hcl
  provider "aws" {
    region = "us-east-1"

    default_tags {
      tags = {
        Environment = "dev"
        Repository  = "infra-services"
        Service     = "auth-api"
        ManagedBy   = "Terraform"
      }
    }
  }
  ```

### Story 2.4: Push Initial Repository to GitHub

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
  gh repo create my-org/infra-services --private
  ```

  **Option B: GitHub UI**
  1. Go to https://github.com/new
  2. Select Owner (Organization).
  3. Repository name: `infra-services`
  4. Privacy: Private.
  5. **Do not** initialize with README, .gitignore, or license (we did this locally).
  6. Click "Create repository".

  #### 2) Commit and Push Code

  ```bash
  # Ensure you are at the root of the infra-services directory
  git add .
  git commit -m "feat: initial repository structure and CI workflows"

  # Configure remote (Replace with your actual organization URL)
  # If you used 'gh repo create' above, the remote 'origin' might already be set.
  if ! git remote | grep -q origin; then
    git remote add origin git@github.com:my-org/infra-services.git
  fi

  git branch -M main
  git push -u origin main
  ```

### Story 2.4: Configure Branch Protection Policies

- **Title:** Enforce Branch Protection on `main`
- **Persona:** As a **DevOps Lead**, I need to prevent direct changes to the services branch so that developers follow the peer-review process and pass CI checks.

**Business Value:** Ensures that application infrastructure changes are reviewed by peers and validated by automation. This prevents "broken" service definitions from being merged, which could otherwise block deployments for all teams.

- **Requirements:**
  - `main` branch protected from direct pushes
  - Pull Request required for merging
  - 1 approvals required (Code Owner review recommended)
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

**Verify the setup by simulating a developer adding a new service:**

1.  **Direct Push Blocked:**
    - Make a small local change on `main` (e.g., `touch test_protection && git add test_protection && git commit -m "test protection"`).
    - Attempt to push directly: `git push origin main`.
    - **Pass:** Output should say `error: failed to push some refs... protected branch hook declined`.
    - _Cleanup:_ `git reset --hard HEAD~1` (undo the test commit).

2.  **Pull Request Validation:**
    - Create a new branch: `git checkout -b feature/auth-service-tweak`.
    - Make a small change (e.g., add `// trigger ci` to `environments/dev/us-east-1/auth-api/main.tf`).
    - Commit and push: `git commit -am "feat: trigger ci" && git push origin feature/auth-service-tweak`.
    - Open a Pull Request on GitHub.
    - **Pass:** The "Checks" section shows `TFLint`, `Terraform Fmt`, and `Terraform Validate` running.
    - **Pass:** Checks must succeed (turn green) before the "Merge" button is enabled.

3.  **Peer Review:**
    - **Pass:** The PR requires at least one approval from another user.

4.  **Merge:**
    - After approval and checks pass, merge the PR.
    - **Pass:** The `main` branch is updated with your change.
