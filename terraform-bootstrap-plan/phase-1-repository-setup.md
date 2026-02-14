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
  gh repo create mycompany/mycompany.infra-terraform-bootstrap \
    --private \
    --description "Terraform state backend bootstrap for Dev/Prod accounts"

  # Or create via GitHub web UI:
  # - Navigate to github.com/mycompany
  # - New repository → mycompany.infra-terraform-bootstrap
  # - Private
  # - Do NOT initialize with README
  ```

  #### 2) Clone Locally

  ```bash
  git clone git@github.com:mycompany/mycompany.infra-terraform-bootstrap.git
  cd mycompany.infra-terraform-bootstrap
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
  mycompany.infra-terraform-bootstrap/
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
  - ✅ Repository exists at `github.com/mycompany/mycompany.infra-terraform-bootstrap`
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

  ````bash
  cat > README.md << 'EOF'
  # Terraform Bootstrap

  **Purpose:** One-time setup to create Terraform state infrastructure (S3 + DynamoDB) for Dev and Prod AWS accounts.

  ## Overview

  This repository solves the "chicken and egg" problem:
  - **Problem:** You need an S3 bucket to store Terraform state
  - **Solution:** Run this bootstrap project with local state once per account

  After bootstrap, all other infrastructure projects use the remote S3 backend.

  ## Repository Structure

  mycompany.infra-terraform-bootstrap/
  ├── modules/terraform-state-backend/ # Reusable module
  └── accounts/ # Account-specific configs
  ├── dev/
  └── prod/
  ```

  #### 3) Commit Files

  ```bash
  git add .
  git commit -m "Add Terraform state backend module and documentation"
  git push -u origin main
  ````

- **Acceptance Criteria:**
  - ✅ `.gitignore` excludes `*.tfstate`, `*.tfvars`, `.terraform/`
  - ✅ `.gitignore` allows `*.tfvars.example`
  - ✅ Root `README.md` documents purpose, structure, and quick start
  - ✅ Files committed and pushed to GitHub
  - ✅ No sensitive files in Git history

---

## Phase 1 Checklist

Complete this checklist before proceeding to Phase 2:

- [ ] GitHub repository `mycompany/mycompany.infra-terraform-bootstrap` created
- [ ] Repository is private
- [ ] Directory structure created (`modules/`, `accounts/`)
- [ ] `.gitignore` configured properly
- [ ] Root `README.md` created
- [ ] All files committed and pushed to GitHub

**Estimated Time:** 30-45 minutes

---

**Previous Phase:** [Phase 0 - Prerequisites](phase-0-prerequisites.md)  
**Next Phase:** [Phase 2 - Create Terraform Module](phase-2-terraform-module.md)
