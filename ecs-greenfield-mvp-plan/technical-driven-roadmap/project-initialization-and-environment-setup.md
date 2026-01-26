# Epic 0: Project Initialization & Environment Setup

**Goal:** Configure the AWS environment, local developer tools, and Git repository structure so the team can start Epic 1 immediately.

**Duration:** 1–2 days

**Prerequisites:** Credit card for AWS account, domain registrar access, GitHub organization ready.

---

## Story 0.1: AWS Account Setup & Security

As a Cloud Admin
I want a secure AWS account with no legacy network baggage
So that we avoid accidental public deployments and tighten the blast radius

### Technical Requirements

- Secure Root User with MFA enabled, zero access keys
- IAM Identity Center (SSO) with admin user and group
- Financial guardrails: CloudWatch billing alarms + AWS Budgets
- Security guardrails: GuardDuty, Security Hub, IAM Access Analyzer
- Default VPC removed in target region

### Implementation Details

#### 1) Create AWS Account

- Navigate to https://aws.amazon.com.
- The email used here is the Root User.
- Complete account verification and billing setup.

#### 2) Secure Root User (Critical)

- Log in as Root.
- Enable MFA: Console → IAM → Security Credentials → Activate MFA (TOTP app like 1Password or Google Authenticator).
- Ensure Root has zero access keys.
- Log out; use only for break-glass scenarios (e.g., billing).

#### 3) Enable IAM Identity Center (SSO)

- Open IAM Identity Center and click Enable.
- Create User: Add your admin user (email + name).
- Create Group: `Admins`.
- Create Permission Set: `AdministratorAccess` (predefined policy).
- Assign `Admins` group to your AWS Account using the permission set.
- Note the SSO access portal URL (e.g., `https://d-12345.awsapps.com/start`).

#### 4) Financial Guardrails

- Billing alerts: Billing Dashboard → Billing Preferences → enable "Receive Billing Alerts".
- Create CloudWatch Alarm (EstimatedCharges) in `us-east-1`:

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "EstimatedCharges-USD-50" \
  --alarm-description "Bill estimate exceeds $50" \
  --metric-name EstimatedCharges \
  --namespace AWS/Billing \
  --statistic Maximum \
  --period 21600 \
  --threshold 50 \
  --comparison-operator GreaterThanThreshold \
  --dimensions Name=Currency,Value=USD \
  --evaluation-periods 1 \
  --alarm-actions arn:aws:sns:us-east-1:YOUR_ACCOUNT_ID:billing-alerts \
  --region us-east-1
```

- Create AWS Budgets (belt-and-suspenders):

```bash
aws budgets create-budget \
  --account-id YOUR_ACCOUNT_ID \
  --budget '{
    "BudgetName":"Monthly-Overall",
    "BudgetLimit":{"Amount":"100","Unit":"USD"},
    "TimeUnit":"MONTHLY",
    "BudgetType":"COST",
    "CostTypes":{"IncludeCredit":false,"IncludeRefund":false}
  }' \
  --notifications-with-subscribers '[
    {
      "Notification":{
        "NotificationType":"ACTUAL",
        "ComparisonOperator":"GREATER_THAN",
        "Threshold":50,
        "ThresholdType":"PERCENTAGE"
      },
      "Subscribers":[{"SubscriptionType":"EMAIL","Address":"you@example.com"}]
    }
  ]'
```

#### 5) Security Guardrails (Enable Foundational Services)

- GuardDuty:

```bash
aws guardduty create-detector \
  --enable \
  --finding-publishing-frequency FIFTEEN_MINUTES \
  --region us-east-1
```

- Security Hub (AWS Foundational Security Best Practices):

```bash
aws securityhub enable-security-hub --region us-east-1
aws securityhub batch-enable-standards \
  --standards-subscription-requests '[{"StandardsArn":"arn:aws:securityhub:us-east-1::standards/aws-foundational-security-best-practices/v/1.0.0"}]'
```

- IAM Access Analyzer:

```bash
aws accessanalyzer create-analyzer \
  --type ACCOUNT \
  --name account-analyzer \
  --region us-east-1
```

> Optional (later with Organizations): Add SCPs to block public S3, enforce TLS, and require encryption for EBS/Snapshots.

#### 6) Pre-Flight Clean-Up (Default VPC Deletion)

- AWS creates a Default VPC per region; delete it in the target region to avoid accidental public deployments.
- Switch to target region (e.g., `us-east-1`).
- Use CLI to find and remove dependencies before VPC deletion:

```bash
# Identify default VPC
aws ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --query 'Vpcs[].VpcId' \
  --region us-east-1

# Then detach/delete IGW, subnets, route tables, endpoints as needed before deleting the VPC.
# (Document any blockers; retry after removing dependent resources.)
```

### Acceptance Criteria

- [ ] Root user MFA enabled; root has zero access keys (console verification).
- [ ] IAM Identity Center (SSO) enabled with `Admins` group + `AdministratorAccess` permission set assigned.
- [ ] `aws sso login --profile my-project` works and `aws sts get-caller-identity --profile my-project` returns a ReservedSSO role ARN.
- [ ] CloudWatch billing alarm active in `us-east-1` and AWS Budgets created.
- [ ] GuardDuty, Security Hub, and Access Analyzer enabled.
- [ ] Default VPC deleted in target region; verified via console and CLI.

---

## Story 0.2: Local Developer Tooling

As a Developer
I want a standardized toolchain
So that local work translates cleanly to CI/CD and production

### Technical Requirements

- AWS CLI v2 configured with SSO
- Terraform 1.7.0 managed via tfenv
- Docker (Docker Desktop on macOS, Docker Engine on Linux)
- AWS Session Manager plugin for ECS Exec

### Implementation Details

#### 1) Install AWS CLI v2

- macOS:

```bash
brew install awscli
```

- Linux:

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```

#### 2) Configure AWS SSO (Modern Way)

```bash
aws configure sso
# SSO Start URL: from IAM Identity Center
# SSO Region: us-east-1
# Profile Name: my-project

aws sso login --profile my-project
aws sts get-caller-identity --profile my-project
```

#### 3) Install Terraform via tfenv

```bash
tfenv install 1.7.0
tfenv use 1.7.0
echo "1.7.0" > .terraform-version
terraform version
```

#### 4) Install Docker

- macOS: Install Docker Desktop.
- Linux: Install Docker Engine and add user to docker group.

```bash
sudo apt-get update && sudo apt-get install -y docker.io
sudo usermod -aG docker "$USER"
newgrp docker
systemctl status docker

docker run hello-world
```

#### 5) Install Session Manager Plugin

- macOS:

```bash
brew install --cask session-manager-plugin
session-manager-plugin --version
```

- Linux: Install from AWS docs (`.deb`/`.rpm`), then verify with `session-manager-plugin --version`.

> Note: ECS Exec will later require cluster `ExecuteCommandConfiguration` and task role permissions (Epic 3).

### Acceptance Criteria

- [ ] `aws sts get-caller-identity --profile my-project` shows a ReservedSSO role.
- [ ] `terraform version` returns `1.7.0` (managed by tfenv).
- [ ] `docker run hello-world` works without `sudo` on Linux; Docker Desktop running on macOS.
- [ ] `session-manager-plugin --version` returns a valid version.

---

## Story 0.3: Domain & DNS Preparation

As a Network Admin
I want a Route 53 Hosted Zone
So that we can validate SSL certificates automatically in Epic 3

### Technical Requirements

- Domain registered (Route 53 or external registrar)
- Route 53 Public Hosted Zone created
- NS records propagated to registrar

### Implementation Details

1. Register domain (Route 53 Registrar or external).
2. Create Public Hosted Zone in Route 53 if registrar is external.
3. Update nameservers at the registrar with Route 53 NS records.
4. Wait for DNS propagation (2–48 hours).

### Acceptance Criteria

- [ ] `nslookup -type=NS myapp.com` returns AWS NS records.

---

## Story 0.4: Repository Strategy (Infra vs App)

As a Tech Lead
I want to isolate infrastructure from application code
So that infra changes remain controlled and auditable

### Technical Requirements

- Application code in current monorepo (`packages/*`, `apps/*`)
- Infrastructure code in separate private `infrastructure-core` repository
- Terraform folder structure: `bootstrap/`, `modules/`, `environments/`
- Branch protection on `main` (PR required, 1 approval)

- Keep application code in the current monorepo (shared libraries under `packages/*`, services under `apps/*`).
- Create a separate private repo `infrastructure-core` for Terraform (networking, security, compute, database).

### Implementation Details

#- Create a separate private repo `infrastructure-core` for Terraform (networking, security, compute, database).

### Steps

```bash
# Initialize infra repo locally
mkdir -p ~/Projects/infrastructure-core && cd ~/Projects/infrastructure-core
git init

# Structure
mkdir -p terraform/{bootstrap,modules,environments}
mkdir -p terraform/modules/{networking,security,compute,database}
mkdir -p terraform/environments/{dev,prod}

# .gitignore
cat > .gitignore << 'EOF'
.DS_Store
.terraform/
.terraform.lock.hcl
*.tfstate
*.tfstate.*
*.tfvars
!*.tfvars.example
EOF
```

- Push to GitHub (Private repo) and configure branch protection on `main` (PR required, 1 approval, include administrators).

### Acceptance Criteria

- [ ] `infrastructure-core` repo exists (Private) with Terraform skeleton folders.
- [ ] Branch protection enabled on `main`.

## Story 0.5: Terraform Workspace & Bootstrap

As a DevOps Engineer
I want remote Terraform state
So that state is durable, encrypted, and team-accessible

### Technical Requirements

- S3 bucket with versioning, encryption, public access block
- Bucket policy enforcing TLS
- DynamoDB table for state locking
- S3 backend configured for `dev` and `prod` environments

### Implementation Details

#### 1) Bootstrap (Local State Only for this step)

Create `terraform/bootstrap/main.tf`:

```hcl
provider "aws" {
  region = "us-east-1"
}

# S3 Bucket for Remote State
resource "aws_s3_bucket" "terraform_state" {
  bucket = "infrastructure-core-state-YOUR-ACCOUNT-ID" # Must be globally unique

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "enabled" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "default" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Public Access Block
resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket                  = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enforce TLS
resource "aws_s3_bucket_policy" "enforce_tls" {
  bucket = aws_s3_bucket.terraform_state.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid       = "DenyRequestsWithoutTLS",
      Effect    = "Deny",
      Principal = "*",
      Action    = "s3:*",
      Resource  = [
        aws_s3_bucket.terraform_state.arn,
        "${aws_s3_bucket.terraform_state.arn}/*"
      ],
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

# DynamoDB for State Locking
resource "aws_dynamodb_table" "terraform_locks" {
  name         = "terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
```

Deploy bootstrap:

```bash
cd terraform/bootstrap
terraform init
terraform apply
```

#### 2) Configure Dev Backend

Create `terraform/environments/dev/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.7.0"

  backend "s3" {
    bucket         = "infrastructure-core-state-YOUR-ACCOUNT-ID"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

Initialize the environment:

```bash
cd terraform/environments/dev
terraform init
```

### Acceptance Criteria

- [ ] Bootstrap `terraform apply` succeeds; S3 bucket is versioned/encrypted, public access blocked; TLS enforced via bucket policy.
- [ ] DynamoDB `terraform-locks` table exists.
- [ ] `terraform init` in `environments/dev` uses the S3/DynamoDB backend.

---

## ✅ Epic 0 Definition of Done

1. **Security:** SSO enabled; Root locked down with MFA; foundational guardrails (GuardDuty, Security Hub, Access Analyzer) enabled; Default VPC deleted in target region.
2. **Tooling:** AWS CLI v2, tfenv-managed Terraform 1.7.0, Docker, and Session Manager plugin installed and verified.
3. **Repo:** Private `infrastructure-core` repo created with Terraform skeleton and branch protections on `main`.
4. **State:** Remote Terraform state (S3 + DynamoDB) bootstrapped and dev backend configured.

**Ready to start:** Epic 1 — Containerization & App Security.
