# Implementation Runbook: AWS Identity Center Migration

**Audience:** Junior Engineers executing the migration  
**Prerequisites:** Read ARCHITECTURE_PLAN.md first  
**Estimated Time:** 1 week

---

## Pre-Flight Checklist

Before starting, verify you have:

- [ ] Google Workspace Super Admin credentials
- [ ] AWS Management Account Root credentials (in vault)
- [ ] AWS CLI configured with admin permissions
- [ ] Terraform v1.0+ installed (`terraform --version`)
- [ ] Python 3.8+ installed (`python3 --version`)
- [ ] Boto3 installed (`pip3 install boto3`)
- [ ] Git access to infrastructure repository
- [ ] PagerDuty/Slack webhook for alerts configured
- [ ] 1-hour maintenance window scheduled with stakeholders
- [ ] Rollback decision-maker identified

---

## Phase 1: Root Account Security (Day 1)

### Step 1.1: Rotate Management Account Root Password

```bash
# 1. Navigate to AWS Console sign-in page
# 2. Click "Sign in to a different account"
# 3. Enter Management Account ID
# 4. Click "Forgot your password?"

# Generate strong password
openssl rand -base64 32

# 5. Follow email reset link
# 6. Set new password (copy from above)
# 7. Store in corporate vault immediately
```

**Verification:**

```bash
# Attempt to login with old password - should fail
# Attempt to login with new password - should succeed
```

### Step 1.2: Enable Root MFA with Hardware Key

```bash
# In AWS Console (logged in as Root):
# 1. Click account dropdown (top right) → Security credentials
# 2. Multi-factor authentication (MFA) → Activate MFA
# 3. Select "Security Key" (NOT Authenticator app)
# 4. Insert YubiKey and follow prompts
# 5. Test MFA by logging out and back in
```

**Verification:**

```bash
# Logout
# Login attempt without YubiKey should fail at MFA step
# Login with YubiKey should succeed
```

### Step 1.3: Configure Root Usage Alerts

Create CloudWatch alarm:

```bash
# Create SNS topic for alerts
aws sns create-topic \
  --name root-user-activity-alerts \
  --region us-east-1

# Subscribe PagerDuty/email to topic
aws sns subscribe \
  --topic-arn arn:aws:sns:us-east-1:<MGMT-ACCOUNT-ID>:root-user-activity-alerts \
  --protocol email \
  --notification-endpoint security-team@company.com

# Create metric filter
aws logs put-metric-filter \
  --log-group-name CloudTrail/DefaultLogGroup \
  --filter-name RootUserActivity \
  --filter-pattern '{ $.userIdentity.type = "Root" && $.userIdentity.invokedBy NOT EXISTS }' \
  --metric-transformations \
    metricName=RootUserEventCount,metricNamespace=CloudTrailMetrics,metricValue=1

# Create alarm
aws cloudwatch put-metric-alarm \
  --alarm-name RootUserActivityAlarm \
  --alarm-description "Alert on any Root user activity" \
  --metric-name RootUserEventCount \
  --namespace CloudTrailMetrics \
  --statistic Sum \
  --period 60 \
  --evaluation-periods 1 \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --alarm-actions arn:aws:sns:us-east-1:<MGMT-ACCOUNT-ID>:root-user-activity-alerts
```

**Verification:**

```bash
# Test the alarm by performing a harmless action as root
# (e.g., list S3 buckets)
aws s3 ls

# Check email/PagerDuty within 2 minutes for alert
```

### Step 1.4: Apply Root Lockdown SCP

**IMPORTANT:** Test in non-production OU first!

```bash
# Create test OU if not exists
aws organizations create-organizational-unit \
  --parent-id r-xxxx \
  --name "SCP-Testing"

# Create the policy
cat > root-lockdown-scp.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyRootAccountAccess",
      "Effect": "Deny",
      "Action": "*",
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "aws:PrincipalArn": "arn:aws:iam::*:root"
        }
      }
    }
  ]
}
EOF

# Create SCP
aws organizations create-policy \
  --content file://root-lockdown-scp.json \
  --description "Prevent root user access in member accounts" \
  --name RootAccountLockdown \
  --type SERVICE_CONTROL_POLICY

# Get the policy ID from output, then attach to test OU
aws organizations attach-policy \
  --policy-id p-xxxxxxxx \
  --target-id ou-xxxx-xxxxxxxx
```

**Testing in Test OU:**

```bash
# 1. Move a sandbox account to the test OU
# 2. Attempt to login as root user to that account
# 3. Expected: All actions blocked with "Access Denied"
# 4. Verify IAM user access still works
# 5. If successful, attach SCP to production OUs
```

**Production Deployment:**

```bash
# Attach to root of organization (affects all member accounts)
aws organizations attach-policy \
  --policy-id p-xxxxxxxx \
  --target-id r-xxxx  # Your organization root ID
```

---

## Phase 2: Pre-Migration Backup (Day 1-2)

### Step 2.1: Set Up Python Environment

```bash
# Create virtual environment
cd ~/Desktop/projects-working/ec2-to-fargate-migration-docs/aws-identity-center-provider-migration/scripts
python3 -m venv venv
source venv/bin/activate

# Install dependencies
pip install boto3

# Verify
python3 -c "import boto3; print(boto3.__version__)"
```

### Step 2.2: Configure AWS CLI Profile

```bash
# Create a profile for the migration admin (you'll create this IAM user next)
aws configure --profile migration-admin
# AWS Access Key ID: <will get in next step>
# AWS Secret Access Key: <will get in next step>
# Default region name: us-east-1
# Default output format: json
```

### Step 2.3: Create Break-Glass IAM User

**Purpose:** This IAM user serves two purposes:

1. **Bootstrap**: Initial Terraform deployment before SSO is configured
2. **Emergency Access**: Permanent break-glass access if Identity Center fails

**IMPORTANT:** This user should be kept permanently (not deleted after migration) for emergency access.

```bash
# Create the IAM user
aws iam create-user --user-name break-glass-admin

# Attach AdministratorAccess policy
aws iam attach-user-policy \
  --user-name break-glass-admin \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

# Create access key (for bootstrap only - delete after SSO setup)
aws iam create-access-key --user-name break-glass-admin > break-glass-keys.json

# IMPORTANT: Store keys in vault immediately
cat break-glass-keys.json
# Copy AccessKeyId and SecretAccessKey to vault
# NOTE: These access keys will be deleted after SSO is configured
#       Only password + MFA will remain for emergency access

# Enable MFA requirement
cat > require-mfa-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyAllExceptMFASetup",
      "Effect": "Deny",
      "NotAction": [
        "iam:CreateVirtualMFADevice",
        "iam:EnableMFADevice",
        "iam:GetUser",
        "iam:ListMFADevices",
        "iam:ListVirtualMFADevices",
        "iam:ResyncMFADevice",
        "sts:GetSessionToken"
      ],
      "Resource": "*",
      "Condition": {
        "BoolIfExists": {
          "aws:MultiFactorAuthPresent": "false"
        }
      }
    }
  ]
}
EOF

aws iam put-user-policy \
  --user-name migration-admin \
  --policy-name RequireMFA \
  --policy-document file://require-mfa-policy.json

# Create virtual MFA device for the user
aws iam create-virtual-mfa-device \
  --virtual-mfa-device-name migration-admin-mfa \
  --outfile migration-admin-qr.png \
  --bootstrap-method QRCodePNG

# Scan QR code with Google Authenticator
# Get two consecutive codes, then:
aws iam enable-mfa-device \
  --user-name migration-admin \
  --serial-number arn:aws:iam::<ACCOUNT-ID>:mfa/migration-admin-mfa \
  --authentication-code-1 <CODE1> \
  --authentication-code-2 <CODE2>
```

**Test the migration-admin user:**

```bash
# Update AWS CLI profile with keys from migration-admin-keys.json
aws configure set aws_access_key_id <KEY> --profile migration-admin
aws configure set aws_secret_access_key <SECRET> --profile migration-admin

# Test without MFA (should fail)
aws sts get-caller-identity --profile migration-admin

# Get session token with MFA
aws sts get-session-token \
  --serial-number arn:aws:iam::<ACCOUNT-ID>:mfa/migration-admin-mfa \
  --token-code <6-DIGIT-CODE> \
  --profile migration-admin

# Use returned temporary credentials to test
export AWS_ACCESS_KEY_ID=<from output>
export AWS_SECRET_ACCESS_KEY=<from output>
export AWS_SESSION_TOKEN=<from output>

# Now this should work
aws sts get-caller-identity
```

### Step 2.4: Export Current SSO Assignments

```bash
# Ensure you're using proper credentials
export AWS_PROFILE=migration-admin  # or use your current admin profile

# Run the export script
cd ~/Desktop/projects-working/ec2-to-fargate-migration-docs/aws-identity-center-provider-migration/scripts
python3 export_sso_assignments.py > ../backups/sso_assignments_backup_$(date +%Y%m%d_%H%M%S).csv

# Verify the output
head ../backups/sso_assignments_backup_*.csv
```

**Expected Output:**

```
Group Name,Group ID,Permission Set,Permission Set ARN,Account ID,Account Name
Engineering-Admins,12345678-1234-1234-1234-123456789012,AdministratorAccess,arn:aws:sso:::permissionSet/...,471112975126,Dev-Account
```

**Store backup in version control:**

```bash
cd ../backups
git add sso_assignments_backup_*.csv
git commit -m "Pre-migration SSO backup - $(date +%Y-%m-%d)"
git push
```

---

## Phase 3: Google Workspace Configuration (Day 3-4)

### Step 3.1: Verify Google Workspace Edition

```bash
# Login to Google Workspace Admin Console: admin.google.com
# 1. Click "Billing" in left menu
# 2. Verify edition is "Business Standard" or "Enterprise"
# 3. If "Business Starter" or "Free", STOP - upgrade required
```

### Step 3.2: Enable 2-Step Verification

```bash
# In Google Admin Console:
# 1. Security → Authentication → 2-Step Verification
# 2. Click "Get started"
# 3. Select "Allow users to turn on 2-Step Verification"
# 4. IMPORTANT: Check "Enforcement" → "On"
# 5. Set "Enforcement date" to TODAY
# 6. Click "Save"
```

**Create Organizational Unit for AWS Users:**

```bash
# 1. Directory → Organizational units
# 2. Click "+" to create new OU
# 3. Name: "AWS-Enabled-Users"
# 4. Click "Create"

# 5. Apply 2SV Policy to this OU:
#    Security → Authentication → 2-Step Verification
#    Select "AWS-Enabled-Users" OU
#    Set to "Enforcement: On"
```

### Step 3.3: Create Google Groups

Create groups following the naming convention `AWS-<AccountID>-<Role>`:

```bash
# Install Google Directory API client (optional - for automation)
pip install google-api-python-client google-auth-httplib2 google-auth-oauthlib

# Manual creation via console:
# 1. Groups → Create group
# 2. Name: AWS-471112975126-Admin (example for Dev account)
# 3. Group email: aws-471112975126-admin@company.com
# 4. Description: "AWS Dev Account - Administrator Access"
# 5. Access type: "Restricted" (only members can view, post)
# 6. Click "Next" → "Create group"
```

**Required Groups (customize for your accounts):**

```
AWS-471112975126-Admin          # Dev - Administrator
AWS-471112975126-RO             # Dev - Read Only
AWS-637423317953-Admin          # Prod - Administrator
AWS-637423317953-RO             # Prod - Read Only
AWS-Finance-Billing             # Billing access
```

**Add test users to groups:**

```bash
# For each group:
# 1. Click group name
# 2. Members → Add members
# 3. Enter email addresses
# 4. Role: "Member"
# 5. Click "Add to group"

# CRITICAL: Verify users are in the "AWS-Enabled-Users" OU
# or have 2SV enforced
```

### Step 3.4: Configure SAML Application

```bash
# In Google Admin Console:
# 1. Apps → Web and mobile apps
# 2. Click "Add app" → "Add custom SAML app"
# 3. App name: "Amazon Web Services"
# 4. Click "Continue"

# 5. Download Google IdP metadata:
#    Click "Download Metadata"
#    Save as: google-workspace-metadata.xml

# 6. Click "Continue"
# 7. Fill in AWS details (we'll get these from AWS console next)
```

**Get AWS SAML details:**

```bash
# Login to AWS Console as migration-admin
# 1. Navigate to: IAM Identity Center
# 2. Settings → Identity source
# 3. Actions → Change identity source
# 4. Select "External identity provider"
# 5. Download service provider metadata file
#    Save as: aws-sso-metadata.xml
# 6. DO NOT CLICK "Next" YET - we'll come back
```

**Back in Google Admin Console:**

```bash
# In the "Service provider details" section:
# 1. ACS URL: (from aws-sso-metadata.xml: <md:AssertionConsumerService Location>)
#    Example: https://us-east-1.signin.aws.amazon.com/platform/saml/acs/xxxxx
# 2. Entity ID: (from aws-sso-metadata.xml: <md:entityID>)
#    Example: https://us-east-1.signin.aws.amazon.com/platform/saml/metadata/xxxxx
# 3. Name ID format: EMAIL
# 4. Name ID: Basic Information > Primary email
# 5. Click "Continue"
```

**Attribute Mapping:**

```bash
# In "Attribute mapping" section, add:
# Google Directory attributes → App attributes

Primary email               →  Subject
Primary email               →  Email
Username (first part of email) →  RoleSessionName

# Click "Finish"
```

**Enable the application:**

```bash
# 1. Click "Amazon Web Services" app
# 2. User access → "ON for everyone" (or specific OU)
# 3. Click "Save"
```

### Step 3.5: Configure SCIM Provisioning

```bash
# We'll do this AFTER switching identity source in AWS
# (AWS will provide SCIM endpoint and token)
```

---

## Phase 4: The Cutover (Day 5 - Maintenance Window)

### ⚠️ PRE-CUTOVER CHECKLIST

**30 Minutes Before:**

- [ ] All stakeholders notified
- [ ] migration-admin user tested and working
- [ ] Google groups created and populated
- [ ] Google SAML app configured
- [ ] Backup CSV created and committed to Git
- [ ] Rollback decision-maker on standby
- [ ] PagerDuty silenced for maintenance window

### Step 4.1: Switch Identity Source

```bash
# Login to AWS Console as migration-admin
# 1. IAM Identity Center → Settings → Identity source
# 2. Actions → Change identity source
# 3. Select "External identity provider"

# ⚠️ WARNING MESSAGE WILL APPEAR:
# "All existing user and group assignments will be deleted"
# Review, then check "I understand" → Click "Next"

# 4. Upload google-workspace-metadata.xml (from Step 3.4)
# 5. Click "Next"
# 6. Review configuration
# 7. Type "CONFIRM" in the box
# 8. Click "Change identity source"
```

**Immediate Verification:**

```bash
# You should see:
# "Identity source successfully changed to External identity provider"

# Note: You are now LOGGED OUT of Identity Center
# (This is expected - your old assignments are deleted)
```

### Step 4.2: Enable Automatic Provisioning (SCIM)

```bash
# Still in AWS Console as migration-admin:
# 1. IAM Identity Center → Settings → Identity source
# 2. Actions → Enable provisioning
# 3. "Automatic provisioning" section appears

# 4. CRITICAL: Copy these immediately:
#    - SCIM endpoint: https://scim.us-east-1.amazonaws.com/xxxxx/scim/v2
#    - Access token: (very long string - click "Show" to copy)
#
# ⚠️ STORE IN VAULT NOW - token shown only once!

# 5. Click "Save"
```

### Step 4.3: Configure Google SCIM Client

```bash
# In Google Admin Console:
# 1. Apps → Web and mobile apps
# 2. Click "Amazon Web Services"
# 3. Provisioning → Configure
# 4. Paste SCIM endpoint URL from AWS
# 5. Paste Access token from AWS
# 6. Authorization type: "OAuth 2.0"
# 7. Click "Authorize"
# 8. In "Provision" section:
#    - Enable "Create users"
#    - Enable "Update users"
#    - Enable "Delete users"
#    - Enable "Sync group memberships"
# 9. Click "Save"
```

### Step 4.4: Trigger Initial Sync

```bash
# In Google Admin Console (still in AWS app provisioning):
# 1. Click "Apply changes"
# 2. Select scope: "All AWS-* groups" or "Entire domain"
# 3. Click "Apply"

# Monitor sync status:
# Provisioning → "View details"
# Wait for status: "Last sync: X minutes ago (Success)"
```

**Verification (15 minutes after sync):**

```bash
# In AWS Console (as migration-admin):
# 1. IAM Identity Center → Groups
# 2. Verify Google groups appear:
#    AWS-471112975126-Admin
#    AWS-471112975126-RO
#    etc.

# 3. Click a group → view members
# 4. Verify users from Google appear
```

**If sync fails after 30 minutes → ROLLBACK**

```bash
# See "Rollback Procedure" section below
```

---

## Phase 5: Terraform Deployment (Day 5-6)

### Step 5.1: Prepare Terraform Backend

```bash
cd ~/Desktop/projects-working/ec2-to-fargate-migration-docs/aws-identity-center-provider-migration/terraform

# Create S3 bucket for state
aws s3 mb s3://terraform-state-identitycenter-$(date +%s) --region us-east-1

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket terraform-state-identitycenter-<TIMESTAMP> \
  --versioning-configuration Status=Enabled

# Create DynamoDB table for state locking
aws dynamodb create-table \
  --table-name terraform-state-lock-identitycenter \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1

# Update backend.tf with your bucket name
```

### Step 5.2: Configure Variables

```bash
# Edit terraform/variables.tf
# Update account IDs to match your environment:

variable "member_accounts" {
  default = [
    "123456789012",  # RECOMMENDED: Include Management Account for SSO access
    "471112975126",  # Replace with your Dev account
    "637423317953"   # Replace with your Prod account
  ]
}

# IMPORTANT: Including Management Account in member_accounts is RECOMMENDED
# This allows you to:
# - Use SSO for all access (including to Management Account)
# - Minimize long-lived IAM credentials
# - Keep only 1 break-glass IAM user for true emergencies
#
# Security: Only allow a small admin group access to Management Account
# Example: AWS-123456789012-Admin (3-5 senior engineers only)

# Verify Google groups exist for each combination:
# AWS-123456789012-Admin (small group - platform team only)
# AWS-471112975126-Admin
# AWS-471112975126-RO
# AWS-637423317953-Admin
# AWS-637423317953-RO
```

### Step 5.3: Initialize Terraform

```bash
terraform init

# Expected output:
# Terraform has been successfully initialized!
```

### Step 5.4: Plan

```bash
terraform plan -out=tfplan

# Review output carefully:
# - Should create permission sets (AdministratorAccess, ViewOnlyAccess)
# - Should create account assignments for each group
# - Verify resource count matches:
#   (Number of accounts) × (Number of roles) = assignments

# Example for 2 accounts × 2 roles = 4 assignments
```

**Sample expected output:**

```
Plan: 8 to add, 0 to change, 0 to destroy.

# 2 permission sets
+ aws_ssoadmin_permission_set.standard["Admin"]
+ aws_ssoadmin_permission_set.standard["RO"]

# 2 managed policy attachments
+ aws_ssoadmin_managed_policy_attachment.policies["Admin"]
+ aws_ssoadmin_managed_policy_attachment.policies["RO"]

# 4 account assignments (2 accounts × 2 roles)
+ aws_ssoadmin_account_assignment.standard["471112975126-Admin"]
+ aws_ssoadmin_account_assignment.standard["471112975126-RO"]
+ aws_ssoadmin_account_assignment.standard["637423317953-Admin"]
+ aws_ssoadmin_account_assignment.standard["637423317953-RO"]
```

### Step 5.5: Apply

```bash
# ⚠️ FINAL CONFIRMATION
# Have you reviewed the plan output? (yes/no): yes

terraform apply tfplan

# Monitor progress
# This takes ~2-3 minutes per assignment
```

**Verification:**

```bash
# In AWS Console:
# 1. IAM Identity Center → AWS accounts
# 2. Click an account → Assigned users and groups
# 3. Verify assignments appear with correct permission sets

# Test via AWS Access Portal:
# 1. Navigate to: https://<your-subdomain>.awsapps.com/start
# 2. Login as test user (from Google)
# 3. Verify accounts appear with correct roles
```

---

## Phase 6: Acceptance Testing (Day 6-7)

See detailed test cases in `testing/acceptance_tests.md`

**Quick Verification Tests:**

```bash
# Test 1: Login flow
# 1. Navigate to AWS Access Portal
# 2. Should redirect to Google
# 3. Should require 2SV
# 4. Should show AWS accounts after login

# Test 2: Permission verification
# Login as user in AWS-<AccountID>-Admin group
aws sts get-caller-identity
# Should show role: AWSReservedSSO_AdministratorAccess_xxxxx

# Try creating resource
aws s3 mb s3://test-bucket-$(date +%s)
# Should succeed

# Test 3: Read-only verification
# Login as user in AWS-<AccountID>-RO group
aws s3 mb s3://should-fail-$(date +%s)
# Should fail with AccessDenied

# Test 4: Root alert
# Login to Management Account as root
# Check PagerDuty/Slack within 2 minutes
# Should receive alert
```

---

## Phase 7: Cleanup

### Step 7.1: Secure Break-Glass User (After Migration Complete)

**IMPORTANT:** Do NOT delete the break-glass user. Keep it for emergencies.

```bash
# After verifying SSO works for all access (including Management Account):

# 1. Delete access keys (no longer needed - use console password only)
aws iam list-access-keys --user-name break-glass-admin

aws iam delete-access-key \
  --user-name break-glass-admin \
  --access-key-id <KEY-ID>

# 2. Verify console password + MFA still works
#    (Try logging in via AWS Console)

# 3. Document break-glass procedures:
#    - When to use: Only if Identity Center is completely broken
#    - How to use: Console login with password + MFA
#    - After use: Rotate password, audit all actions, create incident report

# 4. Store break-glass credentials securely:
#    - Password → Corporate vault (1Password, CyberArk, etc.)
#    - MFA seed → Vault (separate entry)
#    - Document: "Emergency use only - audit immediately after use"

# 5. Set calendar reminder to rotate password annually
```

### Step 7.2: Audit and Remove Unnecessary IAM Users

**Goal:** Minimize long-lived credentials now that SSO is primary access method.

```bash
# 1. List all IAM users in Management Account
aws iam list-users --query 'Users[*].[UserName,CreateDate]' --output table

# 2. For each user (except break-glass-admin), determine:
#    - Is this user still needed?
#    - Can this access be provided via Identity Center instead?
#    - Is this a service account that needs programmatic access?

# 3. Recommended retention criteria:
#    KEEP:
#    - break-glass-admin (emergency access)
#    - Service accounts for automation (if using access keys with rotation)
#
#    DELETE:
#    - Personal user accounts (use SSO instead)
#    - Unused/dormant accounts
#    - Temporary test accounts

# 4. For each user to delete:
USER_NAME="old-user-account"

# Delete access keys
aws iam list-access-keys --user-name $USER_NAME
aws iam delete-access-key --user-name $USER_NAME --access-key-id <KEY-ID>

# Delete MFA devices
aws iam list-mfa-devices --user-name $USER_NAME
aws iam deactivate-mfa-device --user-name $USER_NAME --serial-number <MFA-ARN>
aws iam delete-virtual-mfa-device --serial-number <MFA-ARN>

# Detach policies
aws iam list-attached-user-policies --user-name $USER_NAME
aws iam detach-user-policy --user-name $USER_NAME --policy-arn <POLICY-ARN>

# Delete inline policies
aws iam list-user-policies --user-name $USER_NAME
aws iam delete-user-policy --user-name $USER_NAME --policy-name <POLICY-NAME>

# Remove from groups
aws iam list-groups-for-user --user-name $USER_NAME
aws iam remove-user-from-group --user-name $USER_NAME --group-name <GROUP-NAME>

# Delete user
aws iam delete-user --user-name $USER_NAME

# 5. Document remaining IAM users and their purpose
echo "Remaining IAM users:"
aws iam list-users --query 'Users[*].UserName' --output table

# Expected output:
# - break-glass-admin (emergency access)
# - (Optional) service accounts with documented business need
```

---

## Rollback Procedure

**If issues occur during Phase 4 (Cutover):**

### Immediate Rollback (< 30 minutes from cutover)

```bash
# 1. Login as migration-admin
# 2. IAM Identity Center → Settings → Identity source
# 3. Actions → Change identity source
# 4. Select "Identity Center directory" (back to AWS managed)
# 5. Type "CONFIRM"
# 6. Click "Change identity source"

# 7. Manually recreate assignments from backup CSV
#    (Use AWS Console or write script to parse CSV)

# 8. Notify stakeholders of rollback
# 9. Schedule post-mortem
```

**Recovery Time Objective:** 15 minutes

---

## Troubleshooting

### Issue: Google groups not appearing in AWS after 15 minutes

**Diagnosis:**

```bash
# Check SCIM logs in Google:
# Admin Console → Apps → Amazon Web Services
# Provisioning → View details → Errors tab
```

**Common causes:**

1. Wrong SCIM endpoint URL
2. Expired access token
3. Groups not in sync scope
4. Network/firewall blocking SCIM

**Fix:**

```bash
# Regenerate SCIM token:
# In AWS: Identity Center → Settings → Identity source
# Actions → Manage provisioning
# Generate new token
# Update in Google Admin Console
```

### Issue: User can login but no AWS accounts appear

**Diagnosis:**

```bash
# Verify group membership
# Google Admin: Directory → Groups → <group name> → Members

# Verify Terraform assignments
terraform state list
terraform state show aws_ssoadmin_account_assignment.standard[\"<account>-<role>\"]
```

**Fix:**

```bash
# Re-run Terraform
terraform plan
terraform apply
```

### Issue: Terraform data source can't find group

**Error message:**

```
Error: no identity store group found matching criteria
```

**Diagnosis:**

```bash
# Check if group exists in AWS
aws identitystore list-groups \
  --identity-store-id d-xxxxxxxxxx \
  --filters AttributePath=DisplayName,AttributeValue=AWS-471112975126-Admin
```

**Fix:**

```bash
# If group doesn't exist, SCIM sync issue
# Check Google provisioning logs

# If group exists but name mismatch:
# Fix group name in Google (must match exactly: AWS-<AccountID>-<Role>)
# Wait 15 mins for sync
# Re-run terraform
```

---

## Post-Migration Monitoring

### Daily Tasks (First Week)

```bash
# Check CloudTrail for SSO events
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=CreateAccountAssignment \
  --max-results 50 \
  --region us-east-1

# Verify SCIM sync status
# Google Admin: Apps → AWS → Provisioning → View details

# Check for failed logins
# AWS Console: IAM Identity Center → Dashboard → Sign-ins
```

### Weekly Tasks (First Month)

```bash
# Review group memberships match HR system
# Audit Terraform state for drift
terraform plan  # Should show "No changes"

# Verify MFA compliance
# Google Admin: Reporting → Audit → 2-Step Verification
```

---

## Support Contacts

| Issue Type         | Contact                     | Response Time |
| ------------------ | --------------------------- | ------------- |
| Google Workspace   | workspace-admin@company.com | 1 hour        |
| AWS Console Access | aws-admin@company.com       | 30 mins       |
| Terraform          | infra-team@company.com      | 2 hours       |
| Emergency          | oncall@company.com          | 15 mins       |
