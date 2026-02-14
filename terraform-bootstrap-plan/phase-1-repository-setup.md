# Terraform Bootstrap - Phase 1: Repository Setup

## Overview

**Before deploying state infrastructure**, you need to create the repository structure with proper Git configuration. This phase establishes the foundation for the bootstrap project.

**Duration:** 30-45 minutes

**Who Should Complete This:** Platform engineers with GitHub access

---

## Feature 1: Repository Structure and Module Creation

### Story 1.1: Initialize Bootstrap Repository

- **Title:** Create GitHub Repository and Base Directory Structure
- **Persona:** As a **Platform Engineer**, I need to create the bootstrap repository with proper structure so that the team has a consistent workspace for state backend code.

- **Requirements:**
  - Private GitHub repository created
  - Base directory structure initialized
  - Repository cloned locally
  - Initial commit pushed to `main` branch

- **Implementation Details:**

  #### 1) Create GitHub Repository

  ```bash
  # Using GitHub CLI
  gh repo create scale/scale.infra-terraform-bootstrap \
    --private \
    --description "Terraform state backend bootstrap for Dev/Prod accounts"

  # Or create via GitHub web UI:
  # - Navigate to github.com/scale
  # - New repository → scale.infra-terraform-bootstrap
  # - Private
  # - Do NOT initialize with README
  ```

  #### 2) Clone Locally

  ```bash
  git clone git@github.com:scale/scale.infra-terraform-bootstrap.git
  cd scale.infra-terraform-bootstrap
  ```

  #### 3) Create Directory Structure

  ```bash
  mkdir -p modules/terraform-state-backend
  mkdir -p accounts/{dev,prod}

  # Verify structure
  tree -L 2
  ```

  **Expected structure:**

  ```
  scale.infra-terraform-bootstrap/
  ├── modules/
  │   └── terraform-state-backend/
  └── accounts/
      ├── dev/
      └── prod/
  ```

  #### 4) Initialize Git

  ```bash
  git init
  git branch -M main
  ```

- **Acceptance Criteria:**
  - ✅ Repository exists at `github.com/scale/scale.infra-terraform-bootstrap`
  - ✅ Repository is private
  - ✅ `modules/` and `accounts/` directories created
  - ✅ Local clone exists and is on `main` branch

---

### Story 1.2: Create .gitignore and Repository Documentation

- **Title:** Configure Git Ignore Rules and Repository README
- **Persona:** As a **Platform Engineer**, I need proper `.gitignore` rules and documentation so that sensitive state files are never committed and the team understands the repository purpose.

- **Requirements:**
  - `.gitignore` excludes Terraform state files
  - `.gitignore` excludes `*.tfvars` but includes `*.tfvars.example`
  - Root `README.md` documents repository purpose and usage
  - Files committed to Git

- **Implementation Details:**

  #### 1) Create `.gitignore`

  ```bash
  cat > .gitignore << 'EOF'
  # Terraform State (Local)
  *.tfstate
  *.tfstate.*
  *.tfstate.backup

  # Terraform directories
  .terraform/
  .terraform.lock.hcl

  # Variable files (contain account IDs)
  *.tfvars
  !*.tfvars.example

  # Logs
  *.log

  # macOS
  .DS_Store

  # Editors
  .vscode/
  .idea/
  *.swp
  *.swo
  *~
  EOF
  ```

  #### 2) Create Root `README.md`

  ```bash
  cat > README.md << 'EOF'
  # Scale Terraform Bootstrap

  **Purpose:** One-time setup to create Terraform state infrastructure (S3 + DynamoDB) for Dev and Prod AWS accounts.

  ## Overview

  This repository solves the "chicken and egg" problem:
  - **Problem:** You need an S3 bucket to store Terraform state
  - **Solution:** Run this bootstrap project with local state once per account

  After bootstrap, all other infrastructure projects use the remote S3 backend.

  ## Repository Structure

  ```

  scale.infra-terraform-bootstrap/
  ├── modules/terraform-state-backend/ # Reusable module
  └── accounts/ # Account-specific configs
  ├── poc/
  ├── dev/
  └── prod/

  ````

  ## Quick Start

  ### 2. Bootstrap Dev Account

  ```bash
  cd accounts/dev
  cp terraform.tfvars.example terraform.tfvars
  vim terraform.tfvars  # Set aws_account_id

  terraform init
  terraform plan
  terraform apply
  ````

  ### 2. Copy Backend Config

  ```bash
  terraform output backend_configuration
  # Copy output to downstream projects
  ```

  ### 3. Repeat for Dev and Prod

  ```bash
  cd ../dev
  # Same steps...
  ```

  ## Outputs

  Each account outputs backend configuration for use in other repositories:

  ```hcl
  terraform {
    backend "s3" {
      bucket         = "scale-terraform-state-dev"
      key            = "{region}/{layer}/terraform.tfstate"
      region         = "us-east-1"
      encrypt        = true
      dynamodb_table = "scale-terraform-locks"
    }
  }
  ```

  ## Documentation
  - [Phase 0: Repository Setup](phase-0-repository-setup.md)
  - [Phase 2: Bootstrap Dev Account](phase-2-bootstrap-dev.md)
  - [Phase 3: Bootstrap Prod Account](phase-3-bootstrap-prod.md)
  - [Phase 3: Migrate to Remote State](phase-3-migrate-to-remote-state.md)

  ## Cost
  - S3: ~$0.023/GB + $0.005/1000 requests (< $1/month)
  - DynamoDB: $0.25/month (on-demand, ~100 locks/month)
  - **Total: < $2/month per account**

  ## Prerequisites
  - AWS CLI v2 with SSO configured
  - Terraform >= 1.7.0
  - Admin access to target AWS account

  #### 3) Commit Files

  ```bash
  git add .
  git commit -m "Add Terraform state backend module and documentation"
  git push -u origin main
  ```

- **Acceptance Criteria:**
  - ✅ `.gitignore` excludes `*.tfstate`, `*.tfvars`, `.terraform/`
  - ✅ `.gitignore` allows `*.tfvars.example`
  - ✅ Root `README.md` documents purpose, structure, and quick start
  - ✅ Files committed and pushed to GitHub
  - ✅ No sensitive files in Git history

---

## Phase 1 Checklist

Complete this checklist before proceeding to Phase 2:

- [ ] GitHub repository `scale/scale.infra-terraform-bootstrap` created
- [ ] Repository is private
- [ ] Directory structure created (`modules/`, `accounts/`)
- [ ] `.gitignore` configured properly
- [ ] Root `README.md` created
- [ ] All files committed and pushed to GitHub

**Estimated Time:** 30-45 minutes

---

**Previous Phase:** [Phase 0 - Prerequisites](phase-0-prerequisites.md)  
**Next Phase:** [Phase 2 - Create Terraform Module](phase-2-terraform-module.md)
