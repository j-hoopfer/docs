# ECS Fargate Migration Plan - Phase -1: Prerequisites & Local Setup

## Overview

**Before you can audit infrastructure or run any migration commands**, your team needs properly configured workstations and AWS access. This phase establishes the foundational tools and access required for all subsequent phases.

**Duration:** 1-2 days (varies by team size and existing AWS setup)

**Who Should Complete This:** All team members (DevOps, developers, architects) participating in the migration.

---

## Feature 1: AWS Account Access Setup

**Business Value:** Establishes secure, auditable team access while eliminating shared credentials and security vulnerabilities. Proper SSO setup (2-3 hours) prevents credential leaks, enables instant access revocation, and meets SOC2/ISO27001 compliance requirements. Organizations without SSO experience 3x higher security incident rates and spend 5-10 hours/month manually managing access keys.

### Story 1.1: Secure AWS Account & Enable IAM Identity Center (SSO)

**Business Value:** Prevents the #1 cause of AWS account compromises—leaked root credentials or shared access keys. Root MFA and SSO (1 hour setup) protect against unauthorized access that could result in $50K-500K+ in fraudulent charges, data breaches, or ransomware. Enables audit trails showing who accessed what and when, critical for compliance and incident response.

- **Title:** Configure Secure AWS Access for Migration Team
- **Persona:** As a **cloud administrator**, I need to set up secure AWS access for the migration team so that everyone can access AWS resources without sharing root credentials or long-lived access keys.

- **Requirements:**
  - Root user secured with MFA (multi-factor authentication)
  - IAM Identity Center (AWS SSO) enabled
  - Admin group and users created
  - Permission sets assigned
  - No long-lived access keys for team members

- **Implementation Details:**

  #### 1) Secure Root User (Critical First Step)
  - Log in to AWS Console as Root user
  - Navigate to: IAM → Security Credentials
  - **Enable MFA:**
    - Click "Activate MFA"
    - Choose "Authenticator app" (use 1Password, Google Authenticator, Authy, etc.)
    - Scan QR code and enter two consecutive MFA codes
  - **Verify no access keys exist:**
    - Under "Access keys" section, delete any existing keys
    - Root should NEVER have programmatic access keys
  - **Log out and store root password securely** (password manager, vault)
  - **Use root only for break-glass scenarios:** Billing issues, account recovery, IAM lockout

  #### 2) Enable IAM Identity Center (AWS SSO)
  - Navigate to: IAM Identity Center (search in AWS Console)
  - Click **Enable**
  - Note your **AWS access portal URL** (e.g., `https://d-abc123xyz.awsapps.com/start`)
  - Save this URL—your team will use it for daily login

  #### 3) Create Admin Group and Users

  **Create Admin Group:**
  - In IAM Identity Center → Groups → Create group
  - Group name: `Admins`
  - Description: "Migration team with full administrative access"

  **Add Users:**
  - Users → Add user
  - For each team member:
    - Username: Use email address format (e.g., `jane.doe@company.com`)
    - Email: Same as username
    - First name, Last name
    - Send invitation email: Yes
  - Users will receive an email to set their password

  **Assign Permission Set:**
  - AWS accounts → Select your account → Assign users or groups
  - Select: Groups → `Admins`
  - Permission set: `AdministratorAccess` (AWS managed)
  - Click Assign

  #### 4) Team Members: Complete SSO Setup

  Each team member should:
  1. Check email for "Invitation to join AWS IAM Identity Center"
  2. Click "Accept invitation"
  3. Set a strong password
  4. Enable MFA for their SSO user (highly recommended)
  5. Bookmark the AWS access portal URL
  6. Log in and verify access works

- **Acceptance Criteria:**
  - ✅ Root user has MFA enabled
  - ✅ Root user has zero access keys
  - ✅ IAM Identity Center enabled
  - ✅ `Admins` group created with AdministratorAccess permission set
  - ✅ All team members added as users and can log in via SSO portal
  - ✅ Team members can access AWS Console via SSO

---

### Story 1.2: Enable Security Guardrails

**Business Value:** Provides early warning system for security threats and compliance violations before they become incidents. GuardDuty catches cryptocurrency mining (avg cost: $10K-50K/incident) within 15 minutes, unauthorized access attempts, and data exfiltration. Security Hub identifies CIS Benchmark violations and misconfigurations that could fail SOC2/ISO27001 audits. IAM Access Analyzer prevents accidental public exposure of S3 buckets and databases that lead to data breaches.

- **Title:** Configure Foundational AWS Security Monitoring
- **Persona:** As a **security administrator** (or **cloud administrator**), I need to enable security monitoring and threat detection so that we identify and respond to security incidents before they cause breaches or compliance violations.

- **Requirements:**
  - GuardDuty enabled (threat detection)
  - Security Hub enabled (security posture)
  - IAM Access Analyzer enabled (public access detection)
  - Delete default VPC (security best practice)

- **Implementation Details:**

  #### 1) Enable GuardDuty (Threat Detection)

  ```bash
  aws guardduty create-detector \
    --enable \
    --finding-publishing-frequency FIFTEEN_MINUTES \
    --region us-east-1
  ```

  Or via Console: GuardDuty → Get Started → Enable GuardDuty

  **What it does:** Monitors VPC Flow Logs, CloudTrail, and DNS logs for suspicious activity (compromised instances, reconnaissance, cryptocurrency mining, etc.)

  #### 2) Enable Security Hub (Centralized Security Findings)

  ```bash
  aws securityhub enable-security-hub --region us-east-1
  aws securityhub batch-enable-standards \
    --standards-subscription-requests '[{"StandardsArn":"arn:aws:securityhub:us-east-1::standards/aws-foundational-security-best-practices/v/1.0.0"}]'
  ```

  Or via Console: Security Hub → Go to Security Hub → Enable Security Hub → Enable AWS Foundational Security Best Practices

  **What it does:** Aggregates findings from GuardDuty, Inspector, IAM Access Analyzer, and runs automated compliance checks

  #### 3) Enable IAM Access Analyzer

  ```bash
  aws accessanalyzer create-analyzer \
    --type ACCOUNT \
    --name account-analyzer \
    --region us-east-1
  ```

  Or via Console: IAM → Access Analyzer → Create analyzer

  **What it does:** Alerts when S3 buckets, IAM roles, KMS keys, etc. are accessible outside your account

  #### 4) Delete Default VPC (Security Best Practice)

  **Why:** AWS creates a default VPC in each region with public subnets and an Internet Gateway. This is a security risk—resources accidentally launched here are internet-accessible by default.

  **How to delete:**

  ```bash
  # Find default VPC
  aws ec2 describe-vpcs \
    --filters Name=isDefault,Values=true \
    --query 'Vpcs[].VpcId' \
    --region us-east-1

  # Output: vpc-abc123 (example)

  # Delete dependencies first (in order):
  # 1. Delete instances in default subnets (if any)
  # 2. Delete subnets
  aws ec2 describe-subnets --filters Name=vpc-id,Values=vpc-abc123 \
    --query 'Subnets[].SubnetId' --output text | \
    xargs -n1 aws ec2 delete-subnet --subnet-id

  # 3. Detach and delete Internet Gateway
  aws ec2 describe-internet-gateways \
    --filters Name=attachment.vpc-id,Values=vpc-abc123 \
    --query 'InternetGateways[].InternetGatewayId' --output text | \
    xargs -I {} sh -c 'aws ec2 detach-internet-gateway --internet-gateway-id {} --vpc-id vpc-abc123 && aws ec2 delete-internet-gateway --internet-gateway-id {}'

  # 4. Delete VPC
  aws ec2 delete-vpc --vpc-id vpc-abc123
  ```

  Or via Console: VPC → Your VPCs → Select default VPC → Actions → Delete VPC

- **Acceptance Criteria:**
  - ✅ GuardDuty enabled and showing "Active" status
  - ✅ Security Hub enabled with AWS Foundational Security Best Practices standard
  - ✅ IAM Access Analyzer created
  - ✅ Default VPC deleted in primary region (e.g., us-east-1)

---

### Story 1.3: Enable Cost Guardrails

**Business Value:** Prevents surprise AWS bills and provides early warning of cost overruns during migration. Billing alarms (15 minutes setup) catch misconfigured resources or forgotten instances before they generate $5K-20K surprise bills. AWS Budgets provide forecasting and alerts when spending exceeds thresholds, essential for migration projects where new resources are constantly being created. Organizations without cost monitoring average 30-40% higher cloud spend due to undetected waste.

- **Title:** Configure AWS Cost Monitoring and Billing Alerts
- **Persona:** As a **FinOps engineer** (or **cloud administrator**), I need to configure cost monitoring and budget alerts so that we track migration spending and prevent budget overruns.

- **Requirements:**
  - CloudWatch billing alarms configured
  - AWS Budgets configured
  - Email notifications enabled
  - SNS topic created for cost alerts

- **Implementation Details:**

  #### 1) Enable Billing Alerts

  **Enable Billing Alerts (Console):**
  - Navigate to: Billing Dashboard → Billing Preferences
  - Check ✅ "Receive Billing Alerts"
  - Save preferences

  **Why this is required:** Without this setting, CloudWatch cannot access billing metrics.

  #### 2) Create SNS Topic for Cost Alerts

  ```bash
  # Create SNS topic for cost notifications
  aws sns create-topic --name billing-alerts --region us-east-1

  # Subscribe your email (replace YOUR_EMAIL)
  aws sns subscribe \
    --topic-arn arn:aws:sns:us-east-1:YOUR_ACCOUNT_ID:billing-alerts \
    --protocol email \
    --notification-endpoint YOUR_EMAIL@company.com \
    --region us-east-1

  # Check email and confirm subscription
  ```

  Or via Console: SNS → Topics → Create topic → Standard → Subscribe email

  #### 3) Configure CloudWatch Billing Alarm

  ```bash
  # Create billing alarm (adjust threshold as needed)
  aws cloudwatch put-metric-alarm \
    --alarm-name "EstimatedCharges-USD-100" \
    --alarm-description "Bill estimate exceeds $100" \
    --metric-name EstimatedCharges \
    --namespace AWS/Billing \
    --statistic Maximum \
    --period 21600 \
    --threshold 100 \
    --comparison-operator GreaterThanThreshold \
    --dimensions Name=Currency,Value=USD \
    --evaluation-periods 1 \
    --alarm-actions arn:aws:sns:us-east-1:YOUR_ACCOUNT_ID:billing-alerts \
    --region us-east-1
  ```

  Or via Console: CloudWatch → Alarms → Billing → Create alarm

  **What it does:** Sends email when estimated monthly charges exceed threshold (adjust $100 to your needs).

  #### 4) Create AWS Budget

  ```bash
  aws budgets create-budget \
    --account-id YOUR_ACCOUNT_ID \
    --budget '{
      "BudgetName":"MigrationMonthlyBudget",
      "BudgetLimit":{"Amount":"500","Unit":"USD"},
      "TimeUnit":"MONTHLY",
      "BudgetType":"COST",
      "CostTypes":{"IncludeCredit":false,"IncludeRefund":false}
    }' \
    --notifications-with-subscribers '[
      {
        "Notification":{
          "NotificationType":"ACTUAL",
          "ComparisonOperator":"GREATER_THAN",
          "Threshold":80,
          "ThresholdType":"PERCENTAGE"
        },
        "Subscribers":[{"SubscriptionType":"EMAIL","Address":"YOUR_EMAIL@company.com"}]
      }
    ]'
  ```

  Or via Console: AWS Budgets → Create budget → Cost budget

  **What it does:**
  - Tracks monthly spending against $500 budget (adjust to your needs)
  - Sends alert when 80% of budget consumed
  - Provides forecasting to predict end-of-month costs

  #### 5) Create Additional Budget Alerts (Recommended)

  **Multiple threshold alerts:**
  - 50% threshold: Early warning
  - 80% threshold: Action needed
  - 100% threshold: Budget exceeded
  - 110% threshold: Emergency escalation

  You can create multiple budgets or add multiple notifications to one budget via Console.

  #### 6) Test Notifications

  **Verify SNS subscription:**

  ```bash
  aws sns list-subscriptions-by-topic \
    --topic-arn arn:aws:sns:us-east-1:YOUR_ACCOUNT_ID:billing-alerts
  ```

  Expected output should show your email subscription with `"SubscriptionArn"` (not `"PendingConfirmation"`).

- **Acceptance Criteria:**
  - ✅ Billing alerts enabled in Billing Preferences
  - ✅ SNS topic created and email subscription confirmed
  - ✅ CloudWatch billing alarm created with appropriate threshold
  - ✅ AWS Budget created with 80% threshold notification
  - ✅ Email notifications received and tested
  - ✅ FinOps team has access to Cost Explorer and Budgets console

---

## Feature 2: Local Developer Workstation Setup

**Business Value:** Eliminates environment inconsistencies and "works on my machine" problems, accelerating team velocity. Standardized tooling (3-4 hours per developer) prevents deployment failures from version mismatches and reduces onboarding time from days to hours. Teams with consistent environments ship 40% faster and have 60% fewer production incidents.

### Story 2.1: Install AWS CLI v2 and Configure SSO

**Business Value:** Enables command-line infrastructure management while eliminating hardcoded credentials. CLI access (30 minutes setup) allows automation of repetitive tasks, saving 5-10 hours/week per engineer. SSO integration prevents access key leaks that average $45K per incident in detection/remediation costs.

- **Title:** Install and Configure AWS Command Line Interface
- **Persona:** As a **DevOps engineer / developer**, I need the AWS CLI installed and configured so that I can run infrastructure audits, deploy resources, and troubleshoot issues from my terminal.

- **Requirements:**
  - AWS CLI version 2 installed (not v1)
  - SSO profile configured for team's AWS account
  - Ability to authenticate via `aws sso login`
  - Verification that CLI commands work

- **Implementation Details:**

  #### 1) Install AWS CLI v2

  **macOS (Option 1: Homebrew - Recommended):**

  ```bash
  brew install awscli

  # Verify installation
  aws --version
  # Expected: aws-cli/2.x.x Python/3.x.x Darwin/...
  ```

  **macOS (Option 2: Native Installer):**

  ```bash
  # Download and install
  curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
  sudo installer -pkg AWSCLIV2.pkg -target /

  # Verify installation
  aws --version
  # Expected: aws-cli/2.x.x Python/3.x.x Darwin/...
  ```

  > **Note:** Homebrew is recommended for easier updates (`brew upgrade awscli`), but native installer works if you don't use Homebrew.

  **Linux (Ubuntu/Debian):**

  ```bash
  curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
  unzip awscliv2.zip
  sudo ./aws/install

  # Verify installation
  aws --version
  ```

  **Windows:**
  - Download installer from: https://awscli.amazonaws.com/AWSCLIV2.msi
  - Run installer
  - Open PowerShell and run: `aws --version`

  #### 2) Configure AWS SSO Profile

  **📖 Why SSO instead of `aws configure`?**
  SSO provides temporary credentials that expire automatically, instant revocation, full audit trails, and meets compliance requirements—unlike long-lived access keys which are the #1 cause of AWS security breaches.

  ```bash
  aws configure sso
  ```

  You'll be prompted for:

  ```
  SSO session name (Recommended): fargate-migration
  SSO start URL [None]: https://d-abc123xyz.awsapps.com/start
  SSO region [None]: us-east-1
  SSO registration scopes [sso:account:access]:  [press Enter]
  ```

  Browser will open → Log in with your IAM Identity Center credentials → Approve access

  Back in terminal:

  ```
  There are N AWS accounts available to you.
  > YourAccountName, your-email@company.com (123456789012)

  Using the account ID 123456789012
  There are N role(s) available to you.
  > AdministratorAccess

  CLI default client Region [None]: us-east-1
  CLI default output format [None]: json
  CLI profile name [AdministratorAccess-123456789012]: fargate-migration
  ```

  #### 3) Test SSO Login

  ```bash
  aws sso login --profile fargate-migration

  # Verify identity
  aws sts get-caller-identity --profile fargate-migration
  ```

  Expected output:

  ```json
  {
    "UserId": "AROA...:your-email@company.com",
    "Account": "123456789012",
    "Arn": "arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_AdministratorAccess_.../your-email@company.com"
  }
  ```

  #### 4) Set Default Profile (Optional)

  To avoid typing `--profile` on every command:

  ```bash
  export AWS_PROFILE=fargate-migration

  # Add to ~/.zshrc or ~/.bashrc to persist
  echo 'export AWS_PROFILE=fargate-migration' >> ~/.zshrc
  source ~/.zshrc
  ```

  #### 5) SSO Session Management
  - **SSO tokens expire after 8 hours** (by default)
  - When expired, run: `aws sso login --profile fargate-migration`
  - Browser will open again for re-authentication

- **Acceptance Criteria:**
  - ✅ `aws --version` shows version 2.x.x
  - ✅ `aws configure sso` completed successfully
  - ✅ `aws sso login --profile fargate-migration` opens browser and completes auth
  - ✅ `aws sts get-caller-identity --profile fargate-migration` returns account details
  - ✅ Team members can run AWS CLI commands

---

### Story 2.2: Install Terraform with Version Management (tfenv)

**Business Value:** Provides infrastructure-as-code consistency across team and prevents version-related breakage. Version management (20 minutes setup) ensures everyone deploys identical infrastructure, eliminating "works on my laptop" failures that cause 2-4 hour emergency rollbacks. Terraform reduces infrastructure provisioning time from hours to minutes, enabling rapid iteration.

- **Title:** Install Terraform for Infrastructure Provisioning
- **Persona:** As a **DevOps engineer**, I need Terraform installed with version management so that I can provision AWS infrastructure and switch between Terraform versions if needed.

- **Requirements:**
  - tfenv installed (Terraform version manager)
  - Terraform 1.7.0+ installed
  - Verification that Terraform works
  - `.terraform-version` file in repo (future)

- **Implementation Details:**

  #### 1) Install tfenv (Terraform Version Manager)

  **macOS (Option 1: Homebrew - Recommended):**

  ```bash
  brew install tfenv
  ```

  **macOS (Option 2: Manual Installation):**

  ```bash
  # Clone tfenv repository
  git clone --depth=1 https://github.com/tfutils/tfenv.git ~/.tfenv

  # Add to PATH

  # Add to shell configuration file
  echo 'export PATH="$HOME/.tfenv/bin:$PATH"' >> ~/.zshrc
  source ~/.zshrc

  # For bash:
  echo 'export PATH="$HOME/.tfenv/bin:$PATH"' >> ~/.bash_profile
  source ~/.bash_profile

  # Verify installation
  tfenv --version
  ```

  > **Note:** Homebrew is recommended for easier updates, but manual installation works without Homebrew.

  **Linux:**

  ```bash
  git clone --depth=1 https://github.com/tfutils/tfenv.git ~/.tfenv
  echo 'export PATH="$HOME/.tfenv/bin:$PATH"' >> ~/.bashrc
  source ~/.bashrc
  ```

  **Windows:**
  - Use Chocolatey: `choco install tfenv`
  - Or download Terraform directly from https://www.terraform.io/downloads

  #### 2) Install Terraform 1.7.0

  ```bash
  # List available versions
  tfenv list-remote

  # Install specific version
  tfenv install 1.7.0

  # Set as active version
  tfenv use 1.7.0

  # Verify
  terraform version
  # Expected: Terraform v1.7.0
  ```

  #### 3) Create `.terraform-version` File (For Future Use)

  When you clone the infrastructure repo, create this file at the root:

  ```bash
  echo "1.7.0" > .terraform-version
  ```

  This ensures everyone uses the same Terraform version automatically.

  #### 4) Test Terraform

  ```bash
  # Verify Terraform can connect to AWS
  terraform version
  terraform --help
  ```

  **Why tfenv?**
  - Different projects may require different Terraform versions
  - Upgrading Terraform can break existing infrastructure code
  - tfenv lets you switch versions per project with `.terraform-version`

- **Acceptance Criteria:**
  - ✅ `tfenv --version` shows tfenv is installed
  - ✅ `terraform version` shows Terraform v1.7.0 (or later)
  - ✅ Team members can run `terraform init` and `terraform plan`

---

### Story 2.3: Install Docker and Verify Functionality

**Business Value:** Enables local testing that prevents Fargate deployment failures and reduces debugging cycles. Docker (15 minutes setup) allows developers to catch container issues on laptops before $500/hour outages in production. Local testing reduces deployment iteration time from 15-20 minutes (deploy to AWS) to 30 seconds (local build), accelerating development velocity by 3-5x.

- **Title:** Install Docker for Local Container Testing
- **Persona:** As a **developer**, I need Docker installed so that I can build container images locally, test applications in containers, and troubleshoot Dockerfile issues before deploying to Fargate.

- **Requirements:**
  - Docker installed (Docker Desktop for macOS/Windows, Docker Engine for Linux)
  - Docker daemon running
  - Verification that container can be run
  - Current user has permission to run Docker (Linux)

- **Implementation Details:**

  #### 1) Install Docker

  **macOS:**
  - Download Docker Desktop from https://www.docker.com/products/docker-desktop
  - Install .dmg file
  - Start Docker Desktop from Applications
  - Wait for Docker icon in menu bar to show "Docker Desktop is running"

  **Linux (Ubuntu/Debian):**

  ```bash
  # Install Docker Engine
  sudo apt-get update
  sudo apt-get install -y docker.io

  # Add current user to docker group (avoid sudo)
  sudo usermod -aG docker "$USER"

  # Log out and log back in, or run:
  newgrp docker

  # Start Docker service
  sudo systemctl start docker
  sudo systemctl enable docker

  # Verify
  systemctl status docker
  ```

  **Windows:**
  - Download Docker Desktop from https://www.docker.com/products/docker-desktop
  - Install .exe file
  - Start Docker Desktop
  - Enable WSL 2 integration if using Windows Subsystem for Linux

  #### 2) Test Docker Installation

  ```bash
  # Test with hello-world image
  docker run hello-world
  ```

  Expected output:

  ```
  Unable to find image 'hello-world:latest' locally
  latest: Pulling from library/hello-world
  ...
  Hello from Docker!
  This message shows that your installation appears to be working correctly.
  ```

  #### 3) Verify Docker Compose (Included with Docker Desktop)

  ```bash
  docker compose version
  # Expected: Docker Compose version v2.x.x
  ```

  #### 4) Clean Up Test Container

  ```bash
  docker ps -a  # List all containers
  docker rm <container-id>  # Remove hello-world container
  docker images  # List images
  docker rmi hello-world  # Remove hello-world image
  ```

  **Common Issues:**
  - **macOS:** "Cannot connect to Docker daemon" → Start Docker Desktop
  - **Linux:** "Permission denied" → Add user to docker group (step 1) and re-login
  - **Windows:** WSL 2 not enabled → Follow Docker Desktop prompts to install WSL 2

- **Acceptance Criteria:**
  - ✅ Docker installed and daemon running
  - ✅ `docker --version` shows version 20.x+ or 24.x+
  - ✅ `docker run hello-world` completes successfully
  - ✅ `docker compose version` shows version 2.x+
  - ✅ Team members can build and run containers locally

---

### Story 2.4: Install AWS Session Manager Plugin (for ECS Exec)

**Business Value:** Provides emergency access to troubleshoot failing containers without SSH keys or bastion hosts. Session Manager (10 minutes setup) enables exec into Fargate tasks during incidents, reducing MTTR (Mean Time To Resolution) from 2-4 hours (waiting for logs/metrics) to 15-30 minutes (direct container inspection). Eliminates security risk of SSH keys and jump boxes.

- **Title:** Install Session Manager Plugin for ECS Container Access
- **Persona:** As a **DevOps engineer**, I need the Session Manager plugin installed so that I can debug running ECS tasks by executing commands inside containers (ECS Exec).

- **Requirements:**
  - Session Manager plugin installed
  - Verification that plugin is accessible
  - Understanding of when to use it (troubleshooting ECS tasks)

- **Implementation Details:**

  #### 1) Install Session Manager Plugin

  **macOS (Option 1: Homebrew - Recommended):**

  ```bash
  brew install --cask session-manager-plugin

  # Verify installation
  session-manager-plugin --version
  ```

  **macOS (Option 2: Native Installer):**

  ```bash
  # Download and install
  curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/mac/sessionmanager-bundle.zip" -o "sessionmanager-bundle.zip"
  unzip sessionmanager-bundle.zip
  sudo ./sessionmanager-bundle/install -i /usr/local/sessionmanagerplugin -b /usr/local/bin/session-manager-plugin

  # Verify installation
  session-manager-plugin --version
  ```

  > **Note:** Homebrew is recommended for automatic updates, but native installer works without Homebrew.

  **Linux (Ubuntu/Debian):**

  ```bash
  curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o "session-manager-plugin.deb"
  sudo dpkg -i session-manager-plugin.deb

  # Verify installation
  session-manager-plugin --version
  ```

  **Windows:**
  - Download installer from: https://s3.amazonaws.com/session-manager-downloads/plugin/latest/windows/SessionManagerPluginSetup.exe
  - Run installer
  - Open PowerShell and run: `session-manager-plugin`

  #### 2) What is Session Manager Plugin?
  - Required for **ECS Exec** (SSH-like access to running Fargate containers)
  - Allows running commands inside containers for debugging:
    ```bash
    aws ecs execute-command \
      --cluster my-cluster \
      --task <task-id> \
      --container app \
      --interactive \
      --command "/bin/sh"
    ```
  - **Not needed for daily operations**, but critical for troubleshooting
  - Works via AWS Systems Manager Session Manager (no SSH keys, no open ports)

  #### 3) Test (Optional - Requires ECS Task)

  You won't be able to test this until you have running ECS tasks in later phases. For now, just verify installation:

  ```bash
  session-manager-plugin --version
  # Expected: 1.2.x or later
  ```

- **Acceptance Criteria:**
  - ✅ `session-manager-plugin --version` shows plugin is installed
  - ✅ Team knows Session Manager is for ECS Exec troubleshooting (later phases)

---

### Story 2.5: Install Git and Configure for Collaboration

**Business Value:** Enables version control, collaboration, and disaster recovery for infrastructure code. Git setup (15 minutes) provides audit trail of who changed what and when, critical for compliance and rollback. Teams using Git for infrastructure recover from mistakes in minutes vs. hours of manual restoration. Branch protection prevents accidental production changes that cause outages.

- **Title:** Install Git and Configure User Identity
- **Persona:** As a **developer**, I need Git installed and configured so that I can clone repositories, commit infrastructure code, and collaborate with the team.

- **Requirements:**
  - Git installed
  - Git user.name and user.email configured
  - SSH key or personal access token for GitHub/GitLab (if using private repos)

- **Implementation Details:**

  #### 1) Install Git

  **macOS:**

  ```bash
  # Git is included with Xcode Command Line Tools
  xcode-select --install

  # Or install via Homebrew
  brew install git

  # Verify
  git --version
  ```

  **Linux:**

  ```bash
  sudo apt-get install -y git

  # Verify
  git --version
  ```

  **Windows:**
  - Download from https://git-scm.com/download/win
  - Install with default settings
  - Open Git Bash and run: `git --version`

  #### 2) Configure Git Identity

  ```bash
  git config --global user.name "Your Name"
  git config --global user.email "your.email@company.com"

  # Verify
  git config --global --list
  ```

  #### 3) Set Default Branch Name (Optional)

  ```bash
  git config --global init.defaultBranch main
  ```

  #### 4) Set Up SSH Key for GitHub/GitLab (If Using Private Repos)

  **Generate SSH Key:**

  ```bash
  ssh-keygen -t ed25519 -C "your.email@company.com"
  # Press Enter to accept default location (~/.ssh/id_ed25519)
  # Enter passphrase (optional but recommended)
  ```

  **Add SSH Key to SSH Agent:**

  ```bash
  eval "$(ssh-agent -s)"
  ssh-add ~/.ssh/id_ed25519
  ```

  **Copy Public Key:**

  ```bash
  cat ~/.ssh/id_ed25519.pub
  # Copy the output
  ```

  **Add to GitHub:**
  - Go to GitHub → Settings → SSH and GPG keys → New SSH key
  - Paste public key
  - Test: `ssh -T git@github.com`

  **Or Use Personal Access Token (PAT):**
  - GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)
  - Generate new token with `repo` scope
  - Use token as password when cloning/pushing

- **Acceptance Criteria:**
  - ✅ `git --version` shows Git is installed
  - ✅ `git config --global user.name` shows your name
  - ✅ `git config --global user.email` shows your email
  - ✅ Team members can clone private repositories (SSH or PAT configured)

---

## Feature 3: Repository Structure Setup (Enhanced for Network Segmentation)

**Business Value:** Creates organized foundation that scales with team growth and prevents Terraform state corruption. Proper repository structure (2-3 hours) with layered state files enables parallel work by multiple engineers without conflicts, increasing team throughput by 200-300%. Well-organized infrastructure code reduces onboarding time from weeks to days and prevents costly state file corruption incidents.

### Story 3.1: Initialize Infrastructure Repository

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

  > **📖 For detailed resource placement guide, team workflows, and when to create new projects, see [Appendix: Enterprise Terraform Organization](ecs-migration-plan-appendix.md#11-enterprise-terraform-organization--repository-structure)**

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

  See [Migration Appendix](../docs/ecs-migration-plan-appendix.md#11-enterprise-terraform-organization--repository-structure) for detailed guidance.

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

- **Requirements:**
  - Existing VPC and network resources imported into `00-network` layer
  - Existing EC2 instances and data stores imported into `10-application` layer
  - Terraform code accurately represents current infrastructure state
  - `terraform plan` shows no changes (state matches reality)
  - Existing resources can be managed via Terraform without disruption

- **Implementation Details:**

  #### Why Import Existing Infrastructure?

  **This is a brownfield migration**, not greenfield. You have:
  - Existing VPC with subnets, route tables, NAT gateways
  - Running EC2 instances serving production traffic
  - RDS databases and ElastiCache clusters in use
  - Security groups already configured

  **You cannot use `terraform apply` to create these** — they already exist. If you try, Terraform will error with "resource already exists."

  **The workflow is:**
  1. Write Terraform code that describes existing resources
  2. Import resources into Terraform state (`terraform import`)
  3. Verify state matches reality (`terraform plan` shows no changes)
  4. Now you can manage existing infrastructure via Terraform
  5. Add new Fargate resources alongside existing EC2 resources
  6. Eventually migrate traffic and decommission EC2

  #### Prerequisites
  - Phase 0 (Discovery) completed — you have documented all resource IDs
  - Repository structure from Story 3.1 created
  - Terraform and AWS CLI configured

  #### 1) Import Network Layer (00-network)

  **Navigate to network layer:**

  ```bash
  cd terraform/environments/dev/00-network
  ```

  **Create `main.tf` to describe existing VPC:**

  ```hcl
  terraform {
    required_version = ">= 1.7.0"

    backend "s3" {
      bucket         = "your-terraform-state-bucket"
      key            = "dev/00-network/terraform.tfstate"
      region         = "us-east-1"
      dynamodb_table = "terraform-state-lock"
      encrypt        = true
    }
  }

  provider "aws" {
    region = "us-east-1"
  }

  # Import existing VPC
  resource "aws_vpc" "existing" {
    cidr_block           = "10.0.0.0/16"  # Use actual CIDR from Phase 0 discovery
    enable_dns_hostnames = true
    enable_dns_support   = true

    tags = {
      Name = "existing-vpc"  # Use actual tag from discovery
    }
  }

  # Import existing public subnets (for ALB)
  resource "aws_subnet" "public_1a" {
    vpc_id            = aws_vpc.existing.id
    cidr_block        = "10.0.1.0/24"  # Actual CIDR from discovery
    availability_zone = "us-east-1a"

    tags = {
      Name = "public-subnet-1a"
    }
  }

  resource "aws_subnet" "public_1b" {
    vpc_id            = aws_vpc.existing.id
    cidr_block        = "10.0.2.0/24"  # Actual CIDR from discovery
    availability_zone = "us-east-1b"

    tags = {
      Name = "public-subnet-1b"
    }
  }

  # Import existing private subnets (for EC2 instances)
  resource "aws_subnet" "private_1a" {
    vpc_id            = aws_vpc.existing.id
    cidr_block        = "10.0.10.0/24"  # Actual CIDR from discovery
    availability_zone = "us-east-1a"

    tags = {
      Name = "private-subnet-1a"
    }
  }

  resource "aws_subnet" "private_1b" {
    vpc_id            = aws_vpc.existing.id
    cidr_block        = "10.0.11.0/24"  # Actual CIDR from discovery
    availability_zone = "us-east-1b"

    tags = {
      Name = "private-subnet-1b"
    }
  }

  # Import Internet Gateway
  resource "aws_internet_gateway" "existing" {
    vpc_id = aws_vpc.existing.id

    tags = {
      Name = "existing-igw"
    }
  }

  # Import NAT Gateway (if exists)
  resource "aws_eip" "nat" {
    domain = "vpc"

    tags = {
      Name = "nat-eip"
    }
  }

  resource "aws_nat_gateway" "existing" {
    allocation_id = aws_eip.nat.id
    subnet_id     = aws_subnet.public_1a.id

    tags = {
      Name = "existing-nat"
    }
  }

  # Import route tables
  resource "aws_route_table" "public" {
    vpc_id = aws_vpc.existing.id

    route {
      cidr_block = "0.0.0.0/0"
      gateway_id = aws_internet_gateway.existing.id
    }

    tags = {
      Name = "public-rt"
    }
  }

  resource "aws_route_table" "private" {
    vpc_id = aws_vpc.existing.id

    route {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.existing.id
    }

    tags = {
      Name = "private-rt"
    }
  }

  # Route table associations
  resource "aws_route_table_association" "public_1a" {
    subnet_id      = aws_subnet.public_1a.id
    route_table_id = aws_route_table.public.id
  }

  resource "aws_route_table_association" "public_1b" {
    subnet_id      = aws_subnet.public_1b.id
    route_table_id = aws_route_table.public.id
  }

  resource "aws_route_table_association" "private_1a" {
    subnet_id      = aws_subnet.private_1a.id
    route_table_id = aws_route_table.private.id
  }

  resource "aws_route_table_association" "private_1b" {
    subnet_id      = aws_subnet.private_1b.id
    route_table_id = aws_route_table.private.id
  }

  # Outputs for application layer to consume
  output "vpc_id" {
    value = aws_vpc.existing.id
  }

  output "public_subnet_ids" {
    value = [aws_subnet.public_1a.id, aws_subnet.public_1b.id]
  }

  output "private_subnet_ids" {
    value = [aws_subnet.private_1a.id, aws_subnet.private_1b.id]
  }
  ```

  **Initialize Terraform:**

  ```bash
  terraform init
  ```

  **Import VPC resources (use actual IDs from Phase 0 discovery):**

  ```bash
  # Import VPC
  terraform import aws_vpc.existing vpc-0abc123def456

  # Import subnets
  terraform import aws_subnet.public_1a subnet-0abc111
  terraform import aws_subnet.public_1b subnet-0abc222
  terraform import aws_subnet.private_1a subnet-0abc333
  terraform import aws_subnet.private_1b subnet-0abc444

  # Import Internet Gateway
  terraform import aws_internet_gateway.existing igw-0abc123

  # Import NAT Gateway resources
  terraform import aws_eip.nat eipalloc-0abc123
  terraform import aws_nat_gateway.existing nat-0abc123

  # Import route tables
  terraform import aws_route_table.public rtb-0abc111
  terraform import aws_route_table.private rtb-0abc222

  # Import route table associations
  terraform import aws_route_table_association.public_1a subnet-0abc111/rtb-0abc111
  terraform import aws_route_table_association.public_1b subnet-0abc222/rtb-0abc111
  terraform import aws_route_table_association.private_1a subnet-0abc333/rtb-0abc222
  terraform import aws_route_table_association.private_1b subnet-0abc444/rtb-0abc222
  ```

  **Verify import:**

  ```bash
  terraform plan
  # Should show: "No changes. Your infrastructure matches the configuration."
  # If it shows changes, adjust your Terraform code to match AWS reality
  ```

  #### 2) Import Application Layer (10-application)

  **Navigate to application layer:**

  ```bash
  cd ../10-application
  ```

  **Create `main.tf` for existing EC2, RDS, ElastiCache:**

  ```hcl
  terraform {
    required_version = ">= 1.7.0"

    backend "s3" {
      bucket         = "your-terraform-state-bucket"
      key            = "dev/10-application/terraform.tfstate"
      region         = "us-east-1"
      dynamodb_table = "terraform-state-lock"
      encrypt        = true
    }
  }

  provider "aws" {
    region = "us-east-1"
  }

  # Reference network layer outputs
  data "terraform_remote_state" "network" {
    backend = "s3"
    config = {
      bucket = "your-terraform-state-bucket"
      key    = "dev/00-network/terraform.tfstate"
      region = "us-east-1"
    }
  }

  # Import existing security groups
  resource "aws_security_group" "ec2_app" {
    name        = "ec2-app-sg"  # Actual name from discovery
    description = "Security group for EC2 application"
    vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

    # Add actual ingress/egress rules from Phase 0 discovery
    ingress {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }

    egress {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }

    tags = {
      Name = "ec2-app-sg"
    }
  }

  resource "aws_security_group" "rds" {
    name        = "rds-sg"
    description = "RDS security group"
    vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

    ingress {
      from_port       = 5432  # Postgres port
      to_port         = 5432
      protocol        = "tcp"
      security_groups = [aws_security_group.ec2_app.id]
    }

    tags = {
      Name = "rds-sg"
    }
  }

  # Import existing EC2 instance
  resource "aws_instance" "app_server" {
    ami           = "ami-0abc123def456"  # Actual AMI from discovery
    instance_type = "t3.medium"          # Actual instance type

    subnet_id              = data.terraform_remote_state.network.outputs.private_subnet_ids[0]
    vpc_security_group_ids = [aws_security_group.ec2_app.id]

    tags = {
      Name = "legacy-app-server"
    }

    # Prevent accidental replacement during import
    lifecycle {
      ignore_changes = [ami, user_data]
    }
  }

  # Import RDS instance
  resource "aws_db_instance" "main" {
    identifier     = "app-database"  # Actual DB identifier
    engine         = "postgres"
    engine_version = "14.7"          # Actual version from discovery
    instance_class = "db.t3.medium"  # Actual instance class

    allocated_storage = 100
    storage_type      = "gp3"

    db_name  = "appdb"
    username = "dbadmin"
    password = "PLACEHOLDER"  # Use Secrets Manager after import

    vpc_security_group_ids = [aws_security_group.rds.id]
    db_subnet_group_name   = aws_db_subnet_group.main.name

    backup_retention_period = 7
    skip_final_snapshot     = false
    final_snapshot_identifier = "app-database-final-snapshot"

    lifecycle {
      ignore_changes = [password]
    }

    tags = {
      Name = "app-database"
    }
  }

  resource "aws_db_subnet_group" "main" {
    name       = "app-db-subnet-group"
    subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids

    tags = {
      Name = "app-db-subnet-group"
    }
  }
  ```

  **Import application resources:**

  ```bash
  terraform init

  # Import security groups
  terraform import aws_security_group.ec2_app sg-0abc111
  terraform import aws_security_group.rds sg-0abc222

  # Import EC2 instance
  terraform import aws_instance.app_server i-0abc123def456

  # Import RDS resources
  terraform import aws_db_subnet_group.main app-db-subnet-group
  terraform import aws_db_instance.main app-database

  # Verify
  terraform plan
  # Should show minimal or no changes
  ```

  #### 3) Handling Import Drift

  **Common issues after import:**
  - **Plan shows changes to tags**: Update Terraform code to match actual tags
  - **Plan shows changes to minor attributes**: Add to `lifecycle { ignore_changes = [...] }`
  - **Password attributes**: Use `lifecycle { ignore_changes = [password] }` for RDS
  - **User data**: Use `lifecycle { ignore_changes = [user_data] }` for EC2

  **Iterative process:**

  ```bash
  # 1. Run plan
  terraform plan

  # 2. If changes shown, either:
  #    a) Update Terraform code to match AWS reality, OR
  #    b) Add to ignore_changes if attribute not important

  # 3. Repeat until plan shows zero changes
  ```

  #### 4) Document Import Commands

  **Create `IMPORT_COMMANDS.md` in repository:**

  ```markdown
  # Terraform Import Commands

  ## Network Layer (00-network)

  terraform import aws_vpc.existing vpc-0abc123def456
  terraform import aws_subnet.public_1a subnet-0abc111

  # ... (all import commands)

  ## Application Layer (10-application)

  terraform import aws_security_group.ec2_app sg-0abc111
  terraform import aws_instance.app_server i-0abc123def456

  # ... (all import commands)
  ```

  This serves as documentation and disaster recovery (if state is lost).

- **Acceptance Criteria:**
  - ✅ All existing network resources imported into `00-network` Terraform state
  - ✅ All existing application resources (EC2, RDS, ElastiCache) imported into `10-application` state
  - ✅ `terraform plan` in both layers shows zero changes (state matches reality)
  - ✅ Import commands documented in repository
  - ✅ Team can run `terraform plan` without breaking existing infrastructure
  - ✅ **Existing EC2 and databases continue running normally — nothing disrupted**

- **Next Steps After Import:**

  Once existing infrastructure is in Terraform:
  1. **Phase 2**: Create new Fargate-specific resources (ECS cluster, task definitions) in the same `10-application` layer
  2. **Phase 3**: Deploy Fargate tasks alongside existing EC2
  3. **Phase 4**: Migrate traffic gradually from EC2 to Fargate
  4. **Phase 5**: Decommission EC2 instances via Terraform (`terraform destroy` for EC2 resources only)

---

## Prerequisites Checklist

Complete this checklist before starting Phase 0 (Discovery):

### AWS Account & Access

- [ ] Root user MFA enabled; root has zero access keys
- [ ] IAM Identity Center (SSO) enabled
- [ ] `Admins` group created with AdministratorAccess permission set
- [ ] All team members added as SSO users and can log in
- [ ] GuardDuty, Security Hub, IAM Access Analyzer enabled (Story 1.2)
- [ ] Default VPC deleted in target region (Story 1.2)
- [ ] CloudWatch billing alarm configured (Story 1.3)
- [ ] AWS Budget configured (Story 1.3)

### Local Workstation Setup (All Team Members)

- [ ] AWS CLI v2 installed (`aws --version` shows v2.x.x)
- [ ] AWS SSO profile configured (`aws sso login --profile fargate-migration` works)
- [ ] `aws sts get-caller-identity` returns correct account
- [ ] Terraform 1.7.0+ installed via tfenv (`terraform version`)
- [ ] Docker installed and running (`docker run hello-world` succeeds)
- [ ] Session Manager plugin installed (`session-manager-plugin --version`)
- [ ] Git installed and configured (user.name and user.email set)
- [ ] Access to private repositories configured (SSH key or PAT)

### Repository Setup (Infrastructure Team)

- [ ] Infrastructure repository created with Terraform folder structure
- [ ] `.gitignore` configured
- [ ] README.md documents setup and access
- [ ] Repository pushed to GitHub/GitLab (private)
- [ ] Branch protection enabled on `main` branch

---

## Next Steps

Once all prerequisites are complete:

**➡️ Proceed to [Phase 0: Discovery & Prerequisites](ecs-migration-plan-phase-0-discovery.md)**

In Phase 0, you'll use these tools to audit your existing AWS infrastructure and identify migration blockers.

---

## Troubleshooting

### AWS SSO Issues

**Problem:** `aws sso login` fails with "Error loading SSO Token"

**Solution:**

```bash
rm -rf ~/.aws/sso/cache
aws sso login --profile fargate-migration
```

### Terraform Version Issues

**Problem:** Terraform version mismatch errors

**Solution:**

```bash
# Check active version
terraform version

# Switch to correct version
tfenv use 1.7.0

# Or install if not present
tfenv install 1.7.0
```

### Docker Permission Issues (Linux)

**Problem:** "Permission denied" when running Docker commands

**Solution:**

```bash
# Add user to docker group
sudo usermod -aG docker "$USER"

# Log out and log back in, or run:
newgrp docker

# Test
docker run hello-world
```

### Session Manager Plugin Not Found

**Problem:** AWS CLI can't find session-manager-plugin

**Solution:**

```bash
# Verify installation
which session-manager-plugin

# If not found, reinstall:
# macOS:
brew reinstall --cask session-manager-plugin

# Linux:
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o "session-manager-plugin.deb"
sudo dpkg -i session-manager-plugin.deb
```

---

**Estimated Time:** 1-2 days for full team setup

**Previous Phase:** N/A (This is the starting point)  
**Next Phase:** [Phase 0 - Discovery & Prerequisites](ecs-migration-plan-phase-0-discovery.md)
