# Prerequisites

**Target Audience:** Junior engineers setting up their local development environment to run Terraform and deploy AWS infrastructure.

**Estimated Time:** 30-60 minutes (first-time setup)

---

## Overview

Before running the bootstrap project, you need to install required tools and configure AWS access. This guide covers:

1. Installing command-line tools (Terraform, AWS CLI, GitHub CLI)
2. Configuring AWS SSO (IAM Identity Center) for authentication
3. Verifying your setup works correctly

---

## Operating System Requirements

This guide provides instructions for:

- **macOS** (Intel or Apple Silicon) - With and without Homebrew
- **Windows** - Native Windows with PowerShell or WSL2
- **Linux** (Debian/Ubuntu) - apt-based distributions

---

## 1. Install Terraform

Terraform is the Infrastructure-as-Code tool we use to manage AWS resources.

### macOS - Option 1: With Homebrew (Recommended)

**Install Homebrew first** (if not already installed):

```bash
# Check if Homebrew is already installed
brew --version

# If not installed, run:
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

**Add Homebrew to PATH** (if prompted after installation):

```bash
# For Apple Silicon Macs (M1/M2/M3/M4)
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"

# For Intel Macs
echo 'eval "$(/usr/local/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/usr/local/bin/brew shellenv)"
```

**Install Terraform**:

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
```

### macOS - Option 2: Without Homebrew (Manual Installation)

```bash
# Download the latest Terraform for macOS
# Check https://www.terraform.io/downloads for the latest version
TERRAFORM_VERSION="1.7.4"

# For Apple Silicon (M1/M2/M3/M4)
curl -LO "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_darwin_arm64.zip"
unzip "terraform_${TERRAFORM_VERSION}_darwin_arm64.zip"

# For Intel Macs
# curl -LO "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_darwin_amd64.zip"
# unzip "terraform_${TERRAFORM_VERSION}_darwin_amd64.zip"

# Move to system PATH
sudo mv terraform /usr/local/bin/
sudo chmod +x /usr/local/bin/terraform

# Clean up
rm "terraform_${TERRAFORM_VERSION}_darwin_arm64.zip"
```

### Windows - Option 1: Native Installation with Chocolatey

**Install Chocolatey** (Windows package manager):

Open PowerShell as Administrator and run:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
```

**Install Terraform**:

```powershell
choco install terraform
```

### Windows - Option 2: Manual Installation

1. Download Terraform from https://www.terraform.io/downloads
2. Choose the Windows AMD64 zip file
3. Extract the zip file
4. Move `terraform.exe` to a directory in your PATH (e.g., `C:\Program Files\Terraform\`)
5. Add that directory to your System PATH:
   - Right-click "This PC" → Properties → Advanced System Settings
   - Environment Variables → System Variables → Path → Edit
   - Add `C:\Program Files\Terraform\`
   - Click OK on all dialogs
6. Open a new PowerShell/Command Prompt window

### Windows - Option 3: Using WSL2 (Windows Subsystem for Linux)

**Install WSL2** (if not already installed):

```powershell
# In PowerShell as Administrator
wsl --install
# Restart your computer when prompted
```

**After restart**, open WSL and follow the **Linux (Debian/Ubuntu)** instructions below.

### Linux (Debian/Ubuntu)

```bash
# Add HashiCorp GPG key
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

# Add HashiCorp repository
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list

# Update and install
sudo apt update && sudo apt install terraform
```

### Verify Terraform Installation (All Platforms)

```bash
terraform version
# Expected output:
# Terraform v1.7.0 (or higher)
```

### Enable Auto-Completion (Optional but Recommended)

```bash
# macOS/Linux (zsh)
terraform -install-autocomplete
source ~/.zshrc

# macOS/Linux (bash)
terraform -install-autocomplete
source ~/.bashrc

# Windows - Not available in PowerShell
```

---

## 2. Install AWS CLI v2

The AWS CLI is required for authenticating with AWS SSO and running AWS commands.

### macOS - Option 1: With Homebrew (Recommended)

```bash
brew install awscli
```

### macOS - Option 2: Official Installer (Without Homebrew)

```bash
# Download and install AWS CLI
curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
sudo installer -pkg AWSCLIV2.pkg -target /
rm AWSCLIV2.pkg

# Verify it's in PATH
which aws
# Expected: /usr/local/bin/aws
```

### Windows - Native Installation

1. Download the AWS CLI MSI installer from: https://awscli.amazonaws.com/AWSCLIV2.msi
2. Run the downloaded MSI installer
3. Follow the on-screen instructions
4. Close and reopen PowerShell/Command Prompt

**Or via PowerShell**:

```powershell
# Download installer
$url = "https://awscli.amazonaws.com/AWSCLIV2.msi"
$output = "$env:TEMP\AWSCLIV2.msi"
Invoke-WebRequest -Uri $url -OutFile $output

# Run installer
Start-Process msiexec.exe -ArgumentList "/i $output /quiet" -Wait

# Clean up
Remove-Item $output
```

### Windows - Using WSL2

If using WSL2, open your WSL terminal and follow the **Linux** instructions below.

### Linux (Debian/Ubuntu)

```bash
# Download AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"

# Unzip (install unzip if needed)
sudo apt install unzip -y
unzip awscliv2.zip

# Install
sudo ./aws/install

# Clean up
rm -rf aws awscliv2.zip
```

### Verify Installation (All Platforms)

```bash
aws --version
# Expected output:
# aws-cli/2.15.0 Python/3.11.6 Darwin/23.3.0 source/arm64
# (version numbers and platform may vary)
```

---

## 3. Install GitHub CLI (Optional but Recommended)

The GitHub CLI makes it easier to create repositories and manage GitHub operations from the command line.

### macOS - With Homebrew

```bash
brew install gh
```

### macOS - Without Homebrew

```bash
# Download the latest release
GH_VERSION="2.42.0"
curl -LO "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_macOS_amd64.zip"

# For Apple Silicon
# curl -LO "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_macOS_arm64.zip"

# Unzip
unzip "gh_${GH_VERSION}_macOS_amd64.zip"

# Move to PATH
sudo mv gh_${GH_VERSION}_macOS_amd64/bin/gh /usr/local/bin/

# Clean up
rm -rf gh_${GH_VERSION}_macOS_amd64*
```

### Windows - Using winget

```powershell
winget install --id GitHub.cli
```

### Windows - Manual Installation

1. Download the MSI installer from: https://github.com/cli/cli/releases/latest
2. Choose `gh_*_windows_amd64.msi`
3. Run the installer
4. Restart PowerShell/Command Prompt

### Windows - Using WSL2

Open WSL terminal and follow the **Linux** instructions below.

### Linux (Debian/Ubuntu)

```bash
# Add GitHub CLI repository
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null

# Install
sudo apt update
sudo apt install gh
```

### Authenticate with GitHub (All Platforms)

```bash
gh auth login
```

Follow the prompts:

- **What account do you want to log into?** → GitHub.com
- **What is your preferred protocol?** → SSH (or HTTPS if SSH not configured)
- **Upload your SSH public key?** → Yes (or skip if already configured)
- **How would you like to authenticate?** → Login with a web browser

### Verify Authentication (All Platforms)

```bash
gh auth status
# Expected output:
# ✓ Logged in to github.com as <your-username> (...)
```

```bash
gh auth status
# Expected output:
# ✓ Logged in to github.com as <your-username> (...)
```

---

## 4. Install Additional Utilities

These tools aren't required but make working with Terraform and AWS easier.

### jq (JSON processor)

Useful for parsing AWS CLI output.

**macOS - With Homebrew:**

```bash
brew install jq
```

**macOS - Without Homebrew:**

```bash
# Download jq binary
curl -LO "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-amd64"

# For Apple Silicon
# curl -LO "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-arm64"

# Make executable and move to PATH
chmod +x jq-macos-amd64
sudo mv jq-macos-amd64 /usr/local/bin/jq
```

**Windows - Using Chocolatey:**

```powershell
choco install jq
```

**Windows - Manual Installation:**

1. Download from: https://jqlang.github.io/jq/download/
2. Download `jq-win64.exe`
3. Rename to `jq.exe`
4. Move to a directory in your PATH (e.g., `C:\Program Files\jq\`)
5. Add that directory to System PATH

**Linux (Debian/Ubuntu):**

```bash
sudo apt install jq
```

### tree (Directory visualization)

Useful for visualizing project structure.

**macOS - With Homebrew:**

```bash
brew install tree
```

**macOS - Without Homebrew:**

```bash
# Install via Homebrew is recommended for tree
# Manual compilation is complex - use Homebrew or skip this tool
```

**Windows:**

```powershell
# Windows doesn't have tree, but has a built-in alternative:
tree /?

# For Unix-style tree, use WSL2 or install via:
choco install tree
```

**Linux (Debian/Ubuntu):**

```bash
sudo apt install tree
```

### Verify Installations (All Platforms)

```bash
jq --version
# Expected: jq-1.7 (or higher)

tree --version
# Expected: tree v2.x.x (or Windows built-in tree command)
```

---

## 5. Configure AWS SSO (IAM Identity Center)

AWS SSO allows you to authenticate once and access multiple AWS accounts without managing long-term credentials.

### Prerequisites

Before continuing, you need:

- Your **AWS SSO start URL** (e.g., `https://scale.awsapps.com/start`)
- Your **AWS region** where Identity Center is configured (e.g., `us-east-1`)
- Access to the AWS accounts you'll be deploying to (POC, Dev, Prod)

**Where to find this information:**

- Ask your AWS administrator for the SSO start URL
- Check your email for an AWS SSO invitation

### Configure SSO Profile for POC Account (All Platforms)

Open your terminal (macOS/Linux) or PowerShell (Windows) and run:

```bash
aws configure sso
```

**Answer the prompts:**

```
SSO session name (Recommended): scale
SSO start URL [None]: https://scale-solutions.awsapps.com/start
SSO region [None]: us-east-1
SSO registration scopes [None]: sso:account:access
```

**The browser will open** - Log in with your SSO credentials (e.g., Google Workspace).

**After successful login, select the POC account:**

```

There are 3 AWS accounts available to you.

> scale-poc (123456789012)
> scale-dev (234567890123)
> scale-prod (345678901234)

```

**Select the role:**

```

> AdministratorAccess
> PowerUserAccess

```

**Configure CLI profile:**

```

CLI default client Region [None]: us-east-1
CLI default output format [None]: json
CLI profile name [AdministratorAccess-123456789012]: scale-poc

````

### Configure Additional Profiles (Dev, Prod)

Repeat for each account:

```bash
aws configure sso --profile scale-dev
# Use the same SSO session: scale
# Select scale-dev account
# Profile name: scale-dev

aws configure sso --profile scale-prod
# Use the same SSO session: scale
# Select scale-prod account
# Profile name: scale-prod
````

### Verify SSO Configuration

```bash
# List configured profiles
cat ~/.aws/config
```

**Expected output:**

```ini
[profile scale-poc]
sso_session = scale
sso_account_id = 123456789012
sso_role_name = AdministratorAccess
region = us-east-1
output = json

[profile scale-dev]
sso_session = scale
sso_account_id = 234567890123
sso_role_name = AdministratorAccess
region = us-east-1
output = json

[profile scale-prod]
sso_session = scale
sso_account_id = 345678901234
sso_role_name = AdministratorAccess
region = us-east-1
output = json

[sso-session scale]
sso_start_url = https://scale.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access
```

---

## 6. Test AWS Access

### Login to AWS SSO (All Platforms)

```bash
aws sso login --profile scale-poc
```

**Expected behavior:**

- Browser opens to AWS SSO login
- You authenticate with your credentials
- Terminal shows: `Successfully logged into Start URL: https://scale.awsapps.com/start`

**Note for Windows users:** If the browser doesn't open automatically, copy the URL from the terminal and paste it into your browser.

### Verify Account Access (All Platforms)

```bash
# Test POC account
aws sts get-caller-identity --profile scale-poc
```

**Expected output:**

```json
{
  "UserId": "AROAXXXXXXXXXXXXXXXXX:user@scale.com",
  "Account": "123456789012",
  "Arn": "arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_AdministratorAccess_xxxxx/user@scale.com"
}
```

### Test All Profiles

```bash
# Test each profile
for profile in scale-poc scale-dev scale-prod; do
  echo "Testing $profile..."
  aws sts get-caller-identity --profile $profile --query 'Account' --output text
done
```

**Expected output:**

```
Testing scale-poc...
123456789012
Testing scale-dev...
234567890123
Testing scale-prod...
345678901234
```

---

## 7. Set Default AWS Profile (Optional)

To avoid typing `--profile` on every command, set a default.

**macOS/Linux:**

```bash
# Add to ~/.zshrc (macOS default) or ~/.bashrc (Linux)
echo 'export AWS_PROFILE=scale-poc' >> ~/.zshrc

# Reload shell
source ~/.zshrc  # or source ~/.bashrc
```

**Windows (PowerShell):**

```powershell
# Add to PowerShell profile
Add-Content $PROFILE "`n`$env:AWS_PROFILE='scale-poc'"

# Reload profile (or restart PowerShell)
. $PROFILE
```

**Windows (Command Prompt):**

```cmd
# Set for current session only
set AWS_PROFILE=scale-poc

# Set permanently
setx AWS_PROFILE scale-poc
```

**Verify default profile (All Platforms):**

```bash
aws sts get-caller-identity
# Should use scale-poc without --profile flag
```

---

## 8. Configure Git (If Not Already Done)

Terraform configuration files will be committed to Git, so ensure Git is configured.

### Check Current Configuration (All Platforms)

```bash
git config --global user.name
git config --global user.email
```

### Configure Git (If Not Already Set)

```bash
git config --global user.name "Your Name"
git config --global user.email "your.email@scale.com"
```

### Configure SSH Keys for GitHub

#### macOS/Linux

```bash
# Check for existing SSH keys
ls -la ~/.ssh
# Look for id_rsa.pub or id_ed25519.pub

# If no keys exist, create one:
ssh-keygen -t ed25519 -C "your.email@scale.com"
# Press Enter to accept defaults

# Add SSH key to ssh-agent
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519

# Copy public key to clipboard (macOS)
pbcopy < ~/.ssh/id_ed25519.pub

# Copy public key to clipboard (Linux with xclip)
# sudo apt install xclip
# xclip -selection clipboard < ~/.ssh/id_ed25519.pub

# Or just display it and copy manually
cat ~/.ssh/id_ed25519.pub
```

#### Windows (PowerShell)

```powershell
# Check for existing SSH keys
ls ~\.ssh

# If no keys exist, create one:
ssh-keygen -t ed25519 -C "your.email@scale.com"
# Press Enter to accept defaults

# Start ssh-agent
Start-Service ssh-agent

# Add SSH key
ssh-add ~\.ssh\id_ed25519

# Display public key (copy manually)
Get-Content ~\.ssh\id_ed25519.pub | clip
# Or display with:
cat ~\.ssh\id_ed25519.pub
```

### Add SSH Key to GitHub (All Platforms)

1. Go to https://github.com/settings/keys
2. Click "New SSH key"
3. Paste your public key
4. Click "Add SSH key"

**Test SSH connection:**

```bash
ssh -T git@github.com
# Expected: Hi <username>! You've successfully authenticated...
```

---

## 9. Verification Checklist

Before proceeding to Phase 1, verify all prerequisites are met.

### Tool Installations (All Platforms)

Run this verification script:

**macOS/Linux/WSL:**

````bash
```bash
# Run this verification script
echo "=== Terraform ==="
terraform version

echo -e "\n=== AWS CLI ==="
aws --version

echo -e "\n=== GitHub CLI ==="
gh --version

echo -e "\n=== jq ==="
jq --version

echo -e "\n=== tree ==="
tree --version

echo -e "\n=== Git ==="
git --version
git config --global user.name
git config --global user.email
````

**Windows (PowerShell):**

```powershell
# Run this verification script
Write-Host "=== Terraform ==="
terraform version

Write-Host "`n=== AWS CLI ==="
aws --version

Write-Host "`n=== GitHub CLI ==="
gh --version

Write-Host "`n=== jq ==="
jq --version

Write-Host "`n=== tree ==="
tree /?  # Windows built-in

Write-Host "`n=== Git ==="
git --version
git config --global user.name
git config --global user.email
```

**Expected:** All commands should return version information without errors.

### AWS Access (All Platforms)

```bash
# Verify SSO login
aws sso login --profile scale-poc

# Verify API access
aws sts get-caller-identity --profile scale-poc

# Verify S3 access (should list buckets or return empty array)
aws s3 ls --profile scale-poc
```

**Expected:** No authentication errors, account ID matches your POC account.

### GitHub Access (All Platforms)

```bash
# Verify GitHub CLI authentication
gh auth status

# Verify you can access the Scale organization
gh repo list scale
```

**Expected:** Successfully authenticated, can list repositories (or appropriate error if org doesn't exist yet).

---

## 10. Common Issues

### Issue: `aws sso login` fails with "Invalid grant"

**Solution (macOS/Linux):**

```bash
# Clear SSO cache
rm -rf ~/.aws/sso/cache/
rm -rf ~/.aws/cli/cache/

# Re-login
aws sso login --profile scale-poc
```

**Solution (Windows):**

```powershell
# Clear SSO cache
Remove-Item -Recurse -Force "$env:USERPROFILE\.aws\sso\cache\"
Remove-Item -Recurse -Force "$env:USERPROFILE\.aws\cli\cache\"

# Re-login
aws sso login --profile scale-poc
```

### Issue: Terraform command not found after installation

**Solution (macOS/Linux):**

```bash
# Reload shell configuration
source ~/.zshrc  # macOS
source ~/.bashrc  # Linux

# Verify PATH includes Terraform location
echo $PATH | grep -o '/opt/homebrew/bin\|/usr/local/bin'

# If manually installed, check:
which terraform
# Should return: /usr/local/bin/terraform
```

**Solution (Windows):**

```powershell
# Restart PowerShell/Command Prompt to reload PATH

# Verify PATH includes Terraform
$env:PATH -split ';' | Select-String terraform

# Or check directly:
where.exe terraform
```

### Issue: AWS CLI returns "The config profile (scale-poc) could not be found"

**Solution (macOS/Linux):**

```bash
# Verify profile exists
cat ~/.aws/config | grep scale-poc

# If missing, reconfigure:
aws configure sso --profile scale-poc
```

**Solution (Windows):**

```powershell
# Verify profile exists
Get-Content "$env:USERPROFILE\.aws\config" | Select-String scale-poc

# If missing, reconfigure:
aws configure sso --profile scale-poc
```

### Issue: SSO session expires frequently

**Solution (All Platforms):**

```bash
# Sessions expire after 8 hours by default
# Just re-login when prompted:
aws sso login --profile scale-poc

# Or extend session duration (if your org allows):
# Edit ~/.aws/config (macOS/Linux) or %USERPROFILE%\.aws\config (Windows)
# Add under [sso-session scale]:
# sso_max_session_duration = 28800  # 8 hours (default)
```

### Issue: Git/SSH not working on Windows

**Solution (Windows):**

```powershell
# Ensure OpenSSH is installed
Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH*'

# If not installed:
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0

# Ensure ssh-agent service is running
Get-Service ssh-agent
Start-Service ssh-agent
Set-Service -Name ssh-agent -StartupType Automatic
```

---

## 11. Session Duration and Re-authentication

**SSO sessions expire** - You'll need to re-authenticate periodically (applies to all platforms):

```bash
# If you see: "The SSO session associated with this profile has expired..."
aws sso login --profile scale-poc
```

**How often?**

- Default: 8 hours
- Your organization may configure longer sessions
- You only need to login once per session for all accounts (they share the SSO session)

---

## 12. Next Steps

Once all prerequisites are verified:

1. ✅ All tools installed and working (Terraform, AWS CLI, GitHub CLI, Git)
2. ✅ AWS SSO configured for POC/Dev/Prod accounts
3. ✅ GitHub CLI authenticated (optional)
4. ✅ Git configured with your identity

---

## 13. Additional Resources

- [Terraform Installation Guide](https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli)
- [AWS CLI v2 Installation Guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- [AWS SSO Configuration Guide](https://docs.aws.amazon.com/cli/latest/userguide/sso-configure-profile-token.html)
- [GitHub CLI Manual](https://cli.github.com/manual/)
- [Terraform AWS Provider Documentation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [Windows Terminal (recommended for Windows users)](https://aka.ms/terminal)
- [WSL2 Installation Guide](https://learn.microsoft.com/en-us/windows/wsl/install)
