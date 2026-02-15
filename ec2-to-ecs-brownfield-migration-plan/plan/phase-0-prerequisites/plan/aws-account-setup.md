# AWS Account Access Setup

**Business Value:** Establishes secure, auditable team access while eliminating shared credentials and security vulnerabilities. Proper SSO setup (2-3 hours) prevents credential leaks, enables instant access revocation, and meets SOC2/ISO27001 compliance requirements. Organizations without SSO experience 3x higher security incident rates and spend 5-10 hours/month manually managing access keys.

---

## Story 1.1: Secure AWS Account & Enable IAM Identity Center (SSO)

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

## Story 1.2: Enable Security Guardrails

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

## Story 1.3: Enable Cost Guardrails

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
