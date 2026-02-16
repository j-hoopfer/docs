# Enable Security Guardrails

## Story 1.2: Enable Security Guardrails

- **Title:** Configure Foundational AWS Security Monitoring
- **Persona:** As a **security administrator** (or **cloud administrator**), I need to enable security monitoring and threat detection so that we identify and respond to security incidents before they cause breaches or compliance violations.

**Business Value:** Provides early warning system for security threats and compliance violations before they become incidents. GuardDuty catches cryptocurrency mining (avg cost: $10K-50K/incident) within 15 minutes, unauthorized access attempts, and data exfiltration. Security Hub identifies CIS Benchmark violations and misconfigurations that could fail SOC2/ISO27001 audits. IAM Access Analyzer prevents accidental public exposure of S3 buckets and databases that lead to data breaches.

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
