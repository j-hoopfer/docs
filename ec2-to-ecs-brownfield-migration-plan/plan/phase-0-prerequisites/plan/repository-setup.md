# Repository Structure Setup

**Business Value:** Creates organized foundation that scales with team growth and prevents Terraform state corruption. Proper repository structure (2-3 hours) with layered state files enables parallel work by multiple engineers without conflicts, increasing team throughput by 200-300%. Well-organized infrastructure code reduces onboarding time from weeks to days and prevents costly state file corruption incidents.

---

## Story 3.1: Initialize Infrastructure Repository

**Business Value:** Establishes single source of truth for infrastructure that enables collaboration and prevents drift. Repository setup (1-2 hours) with proper structure allows team to track changes, review code, and rollback mistakes instantly. Organizations with infrastructure-as-code reduce manual provisioning errors by 90% and accelerate new environment creation from weeks to hours.

- **Title:** Create and Structure Infrastructure Code Repository
- **Persona:** As a **DevOps lead**, I need a well-structured infrastructure repository so that the team has a consistent workspace for Terraform code, modules, and documentation.

- **Requirements:**
  - Infrastructure repository created (separate from application code)
  - Terraform folder structure **layered to support multiple VPCs**
  - **Structure supports both existing (EC2) and new (Fargate) infrastructure**
  - `.gitignore` configured to exclude sensitive files
  - Branch protection enabled on `main` branch

- **Implementation Details:**

  #### 1) Create Local Repository

  ```bash
  mkdir -p ~/Projects/fargate-migration-infrastructure
  cd ~/Projects/fargate-migration-infrastructure
  git init
  ```

  #### 2) Create Terraform Folder Structure (Layered)

  _Note: We are splitting environments into `00-network` and `10-application` to isolate the VPC state from the Fargate/EC2 state._

  ```bash
  # Core folders
  mkdir -p terraform/{bootstrap,modules,environments}

  # Module categories
  mkdir -p terraform/modules/{networking,security,compute,database,secrets}

  # Layered Environments
  # 00-network: VPCs, Peering, Transit Gateway
  # 10-application: ECS Clusters, EC2 Instances, Load Balancers
  mkdir -p terraform/environments/{dev,staging,production}/{00-network,10-application}
  ```

  **Final structure:**

  ```
  fargate-migration-infrastructure/
  ├── README.md
  ├── .gitignore
  └── terraform/
      ├── bootstrap/                # S3 + DynamoDB for state (one-time setup)
      ├── modules/                  # Reusable Terraform modules
      │   ├── networking/           # VPC, subnets, NAT, etc.
      │   ├── security/             # Security groups, IAM roles
      │   ├── compute/              # ECS cluster, services, task definitions
      │   ├── database/             # RDS, ElastiCache (if needed)
      │   └── secrets/              # Secrets Manager, SSM parameters
      └── environments/
          ├── dev/
          │   ├── 00-network/       # Network layer: VPCs, subnets, routing
          │   └── 10-application/   # App layer: EC2, ECS, RDS, ALB
          ├── staging/
          │   ├── 00-network/
          │   └── 10-application/
          └── production/
              ├── 00-network/
              └── 10-application/
  ```

  > **📖 For detailed resource placement guide, team workflows, and when to create new projects, see [Appendix: Enterprise Terraform Organization](../../appendix/terraform-organization-guide.md)**

  #### 3) Create `.gitignore`

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
  *.pem
  *.key
  .env
  .env.local

  # IDE
  .vscode/
  .idea/
  *.swp
  *.swo
  *~
  EOF
  ```

  #### 4) Create README

  ```bash
  cat > README.md << 'EOF'
  # Fargate Migration Infrastructure

  Infrastructure-as-code for EC2 to ECS Fargate migration project.

  ## Repository Structure

  This repository uses a **Layered State** approach to separate Networking from Applications.

  - `terraform/bootstrap/` - One-time S3 + DynamoDB setup for Terraform state
  - `terraform/modules/` - Reusable Terraform modules
  - `terraform/environments/` - Environment configs
      - `00-network`: Network foundation (VPCs, subnets, routing)
      - `10-application`: Application resources (EC2, ECS, RDS, ALB)

  ## Prerequisites

  - AWS CLI v2 with SSO configured
  - Terraform 1.7.0+ (managed via tfenv)
  - Docker

  ## Getting Started

  ### For Brownfield Migration (Existing Infrastructure):

  1. **Bootstrap**: `cd terraform/bootstrap && terraform apply`
  2. **Import Network**: Navigate to `environments/dev/00-network`, write Terraform code, import resources
  3. **Import Apps**: Navigate to `environments/dev/10-application`, write Terraform code, import resources
  4. **Verify**: Run `terraform plan` - should show zero changes
  5. **Add Fargate**: Create new ECS resources in `10-application`

  See [Appendix: Terraform Organization Guide](../docs/appendix/terraform-organization-guide.md) for detailed guidance.

  ## Team Access

  - AWS SSO Portal: https://d-abc123xyz.awsapps.com/start
  - Profile: `fargate-migration`
  - Login: `aws sso login --profile fargate-migration`
  EOF
  ```

  #### 5) Initial Commit

  ```bash
  git add .
  git commit -m "Initial repository structure with layered architecture"
  ```

  #### 6) Push to GitHub (Private Repository)

  ```bash
  # Create repo on GitHub (via web UI or gh CLI)
  # Then:
  git remote add origin git@github.com:your-org/fargate-migration-infrastructure.git
  git branch -M main
  git push -u origin main
  ```

  #### 7) Configure Branch Protection

  On GitHub:
  - Go to repo → Settings → Branches → Add rule
  - Branch name pattern: `main`
  - ✅ Require pull request reviews before merging (1 approval)
  - ✅ Require status checks to pass before merging (if CI/CD configured)
  - ✅ Include administrators
  - Save

- **Acceptance Criteria:**
  - ✅ Infrastructure repository created with **layered** folder structure (Network/App separation)
  - ✅ `.gitignore` configured to exclude Terraform state and secrets
  - ✅ README documents repository purpose, structure, and **deployment order**
  - ✅ Repository pushed to GitHub/GitLab as private repo
  - ✅ Branch protection enabled on `main` branch

---

## Story 3.2: Bootstrap Terraform State Backend

**Business Value:** Enables team collaboration on infrastructure without state conflicts or data loss. Remote state backend (30 minutes setup) prevents simultaneous edits that corrupt state files, a critical failure that can cause hours of recovery work or data loss. S3 encryption and DynamoDB locking provide compliance-ready infrastructure management. Organizations using local state files average 2-3 state corruption incidents per year, each requiring 4-8 hours to resolve.

- **Title:** Configure S3 Backend for Terraform State Management
- **Persona:** As a **DevOps lead**, I need a remote Terraform state backend so that multiple team members can safely collaborate on infrastructure code without state file conflicts.

- **Requirements:**
  - S3 bucket created for Terraform state storage
  - Bucket versioning enabled (disaster recovery)
  - Bucket encryption enabled (security compliance)
  - DynamoDB table created for state locking
  - Bootstrap Terraform code documented

- **Implementation Reference:**

  **This story is covered in detail in a separate plan:**

  📖 **See: [Terraform Bootstrap Plan](../../../../terraform-bootstrap-plan/README.md)**

  The Terraform Bootstrap Plan provides:
  - Complete infrastructure state backend setup
  - S3 bucket with versioning, encryption, and lifecycle policies
  - DynamoDB table for state locking
  - Multi-environment support (dev, staging, production)
  - IAM policies and access patterns
  - State migration strategies
  - Disaster recovery procedures

  **Quick Start (Summary):**
  1. Navigate to the terraform-bootstrap-plan project
  2. Follow the phase-by-phase implementation
  3. Bootstrap creates:
     - S3 bucket: `yourcompany-terraform-state-{account-id}`
     - DynamoDB table: `terraform-state-lock`
     - Encrypted, versioned, compliance-ready backend
  4. Document bucket/table names in this repository's README
  5. Configure all environments to use the remote backend

  **Once bootstrap is complete**, all Terraform configurations in this migration will use:

  ```hcl
  terraform {
    backend "s3" {
      bucket         = "yourcompany-terraform-state-123456789012"
      key            = "dev/00-network/terraform.tfstate"  # Different per layer
      region         = "us-east-1"
      dynamodb_table = "terraform-state-lock"
      encrypt        = true
    }
  }
  ```

- **Acceptance Criteria:**
  - ✅ Terraform Bootstrap Plan completed (separate project)
  - ✅ S3 bucket created with versioning and encryption enabled
  - ✅ DynamoDB table created for state locking
  - ✅ Bootstrap state migrated to S3 (self-hosting)
  - ✅ Bucket name and table name documented in this repository's README
  - ✅ Team members can configure backend for environment layers (00-network, 10-application)
