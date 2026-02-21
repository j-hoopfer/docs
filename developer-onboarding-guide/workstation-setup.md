# Local Developer Workstation Setup

**Business Value:** Eliminates environment inconsistencies and "works on my machine" problems, accelerating team velocity. Standardized tooling (3-4 hours per developer) prevents deployment failures from version mismatches and reduces onboarding time from days to hours. Teams with consistent environments ship 40% faster and have 60% fewer production incidents.

---

## Story 2.1: Install AWS CLI v2 and Configure SSO

- **Title:** Install and Configure AWS Command Line Interface
- **Persona:** As a **DevOps engineer / developer**, I need the AWS CLI installed and configured so that I can run infrastructure audits, deploy resources, and troubleshoot issues from my terminal.

**Business Value:** Enables command-line infrastructure management while eliminating hardcoded credentials. CLI access (30 minutes setup) allows automation of repetitive tasks, saving 5-10 hours/week per engineer. SSO integration prevents access key leaks that average $45K per incident in detection/remediation costs.

- **Requirements:**
  - AWS CLI version 2 installed (not v1)
  - SSO profile configured for team's AWS account
  - Ability to authenticate via ` loginaws sso`
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

  You will need to run this **once for each account** (Network, Dev, Prod) to set up separate profiles.

  **First Run (Network Account):**

  ```
  SSO session name (Recommended): fargate-migration
  SSO start URL [None]: https://d-abc123xyz.awsapps.com/start
  SSO region [None]: us-east-1
  SSO registration scopes [sso:account:access]: [Enter]
  ```

  _Browser auth..._

  ```
  Select Account: Network-Account
  Select Role: NetworkAdmin
  CLI default client Region: us-east-1
  CLI default output format: json
  CLI profile name: network-admin
  ```

  **Second Run (Dev Account):**

  ```
  aws configure sso
  ...
  Select Account: Dev-Account
  Select Role: AdministratorAccess
  CLI profile name: dev-admin
  ```

  #### 3) Test SSO Login

  ```bash
  # Logging into the session authorizes ALL profiles in that session
  aws sso login --profile network-admin

  # Verify identity for Network
  aws sts get-caller-identity --profile network-admin

  # Verify identity for Dev
  aws sts get-caller-identity --profile dev-admin
  ```

  Expected output shows distinct Account IDs for each profile.

  #### 4) Set Default Profile (Optional)

  To avoid typing `--profile` on every command (defaults to Dev):

  ```bash
  export AWS_PROFILE=dev-admin

  # Add to ~/.zshrc or ~/.bashrc to persist
  echo 'export AWS_PROFILE=dev-admin' >> ~/.zshrc
  source ~/.zshrc
  ```

  #### 5) SSO Session Management
  - **SSO tokens expire after 8 hours** (by default)
  - When expired, run: `aws sso login --profile dev-admin`
  - Browser will open again for re-authentication

- **Acceptance Criteria:**
  - ✅ `aws --version` shows version 2.x.x
  - ✅ `aws configure sso` completed for **Network, Dev, and Prod** profiles
  - ✅ `aws sso login` works for all profiles
  - ✅ `aws sts get-caller-identity` returns correct Account IDs for `network-admin` vs `dev-admin`
  - ✅ Team members can run AWS CLI commands against correct accounts

---

## Story 2.2: Install Terraform with Version Management (tfenv)

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
  terraform --version
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

## Story 2.3: Install Docker and Verify Functionality

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

## Story 2.4: Install AWS Session Manager Plugin (for ECS Exec)

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

## Story 2.5: Install Git and Configure for Collaboration

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

## Story 2.6: Install Infrastructure Validation Tools

**Business Value:** Shift-left testing enables engineers to catch errors and security issues on their local machine before pushing code. Running `tflint` and `tfsec` locally (5 minutes setup) prevents "CI feedback loops" where developers wait 5-10 minutes just to find out they missed a required field, improving individual efficiency by 15-20%.

- **Title:** Install TFLint and tfsec
- **Persona:** As a **developer**, I need linting and security tools installed so that I can validate my Terraform code before committing it to the repository.

- **Requirements:**
  - `tflint` installed (Terraform linter)
  - `tfsec` installed (Security scanner)
  - Verification that tools run

- **Implementation Details:**

  #### 1) Install TFLint (Terraform Linter)

  **macOS (Homebrew - Recommended):**

  ```bash
  brew install tflint

  # Verify
  tflint --version
  ```

  **macOS / Linux (Manual Binary):**

  ```bash
  # Download
  curl -L "$(curl -s https://api.github.com/repos/terraform-linters/tflint/releases/latest | grep -o -E "https://.+?_$(uname -s | tr '[:upper:]' '[:lower:]')_amd64.zip")" -o tflint.zip

  # Install
  unzip tflint.zip
  sudo mv tflint /usr/local/bin/
  rm tflint.zip

  # Verify
  tflint --version
  ```

  **Windows (Chocolatey):**

  ```powershell
  choco install tflint
  ```

  #### 2) Install tfsec (Security Scanner)

  **macOS (Homebrew - Recommended):**

  ```bash
  brew install tfsec

  # Verify
  tfsec --version
  ```

  **Linux:**

  ```bash
  curl -s https://raw.githubusercontent.com/aquasecurity/tfsec/master/scripts/install_linux.sh | bash
  ```

  #### 3) Initialize TFLint (AWS Plugin)

  TFLint requires plugins to be initialized. In your project root (once you clone the repo):

  ```bash
  # Run this inside any repo with a .tflint.hcl file
  tflint --init
  ```

- **Acceptance Criteria:**
  - ✅ `tflint --version` shows TFLint installed
  - ✅ `tfsec --version` shows tfsec installed
  - ✅ Developers can run `tflint` in their terminal
