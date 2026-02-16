# AWS Account Access Setup

**Business Value:** Establishes secure, auditable team access while eliminating shared credentials and security vulnerabilities. Proper SSO setup (2-3 hours) prevents credential leaks, enables instant access revocation, and meets SOC2/ISO27001 compliance requirements. Organizations without SSO experience 3x higher security incident rates and spend 5-10 hours/month manually managing access keys.

---

## Story 1.1: Secure AWS Account & Enable IAM Identity Center (SSO)

- **Title:** Configure Secure AWS Access for Migration Team
- **Persona:** As a **cloud administrator**, I need to set up secure AWS access for the migration team so that everyone can access AWS resources without sharing root credentials or long-lived access keys.

**Business Value:** Prevents the #1 cause of AWS account compromises—leaked root credentials or shared access keys. Root MFA and SSO (1 hour setup) protect against unauthorized access that could result in $50K-500K+ in fraudulent charges, data breaches, or ransomware. Enables audit trails showing who accessed what and when, critical for compliance and incident response.

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
