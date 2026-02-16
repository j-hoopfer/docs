# Compliance & Audit Requirements

### Goal

Ensure the new containerized architecture meets all SOC 2, HIPAA, or internal audit requirements by implementing necessary logging, encryption, and access controls.

### Context

Moving from EC2 to Fargate changes the compliance posture. We must prove that containers are scanned, secrets are encrypted, and access is logged via CloudTrail.

## Status

**Out of Scope** - To be addressed based on company compliance framework

## Why This Matters

Many industries require demonstrable compliance with security and privacy standards (SOC 2, HIPAA, PCI-DSS, GDPR, etc.). Without proper logging, monitoring, and controls, you cannot pass audits.

## What's Missing

### 2.1 CloudTrail Logging

**Current State:**

- CloudTrail may be enabled by default (varies by AWS account setup)
- Logging configuration not verified or standardized

**Gaps:**

- [ ] **CloudTrail not explicitly enabled** for all regions
- [ ] **No centralized log storage** in tamper-proof S3 bucket
- [ ] **No log file integrity validation**
- [ ] **No alerting on suspicious API calls**

**Recommendations:**

### CloudTrail Configuration

**Enable Organization Trail:**

- Trail name: `organization-audit-trail`
- Log all regions: Yes
- Management events: All (read + write)
- Data events: S3 bucket access, Lambda execution (if needed)
- Insights events: Yes (detects unusual API activity)

**S3 Bucket Configuration:**

- Bucket: `my-company-cloudtrail-logs`
- Encryption: AWS KMS
- Versioning: Enabled
- Object lock: Enabled (compliance mode, 7 years retention)
- Cross-region replication: To DR region

**Monitoring:**

- CloudWatch Logs integration for real-time alerting
- Alerts for:
  - Root account usage
  - IAM policy changes
  - Security group modifications
  - Failed console logins (>5 attempts)
  - Unauthorized API calls

**Cost:** ~$2-5/month per account (small workload)

**Priority:** High (if compliance required)  
**Estimated Effort:** 1 day  
**Owner:** Security/Compliance Team

---

### 2.2 VPC Flow Logs

**Current State:**

- VPC Flow Logs not enabled

**Gaps:**

- [ ] **No network traffic visibility** for security investigations
- [ ] **Cannot detect port scanning, DDoS, data exfiltration**
- [ ] **No compliance evidence** of network activity

**Recommendations:**

### VPC Flow Logs Configuration

**Enable for All VPCs:**

- Log destination: CloudWatch Logs or S3 (S3 cheaper for long-term storage)
- Traffic type: ALL (accepted + rejected)
- Log format: Custom format with additional fields

**Custom Log Format:**

```
${srcaddr} ${dstaddr} ${srcport} ${dstport} ${protocol} ${packets} ${bytes} ${start} ${end} ${action} ${log-status} ${vpc-id} ${subnet-id} ${instance-id} ${interface-id} ${pkt-srcaddr} ${pkt-dstaddr}
```

**S3 Configuration (if using S3):**

- Bucket: `my-company-vpc-flow-logs`
- Lifecycle: Transition to Glacier after 90 days, delete after 7 years
- Partitioning: By date (enables efficient querying)

**Analysis:**

- Use Amazon Athena to query flow logs
- Common queries:
  - Top talkers (highest traffic volume)
  - Rejected connections (potential attacks)
  - Traffic to unexpected destinations

**Cost:** ~$0.50 per GB ingested + storage (~$5-20/month for typical workload)

**Priority:** Medium-High (if compliance required)  
**Estimated Effort:** 0.5 day  
**Owner:** Security Team

---

### 2.3 AWS Config

**Current State:**

- AWS Config not enabled

**Gaps:**

- [ ] **No configuration change tracking** (who changed what security group?)
- [ ] **No compliance rule enforcement** (e.g., "all S3 buckets must have encryption")
- [ ] **Cannot answer audit questions** like "show all security group changes in Q4 2024"

**Recommendations:**

### AWS Config Setup

**Enable AWS Config:**

- Record all resource types
- Store configuration history in S3
- Deliver configuration snapshots: Every 6 hours
- SNS topic: Notify on configuration changes

**Compliance Rules:**

- `encrypted-volumes` - All EBS volumes must be encrypted
- `s3-bucket-server-side-encryption-enabled` - All S3 buckets encrypted
- `rds-storage-encrypted` - All RDS instances encrypted
- `iam-password-policy` - Enforce strong password policy
- `restricted-ssh` - Security groups should not allow 0.0.0.0/0 on port 22
- `restricted-common-ports` - Block unrestricted access to common ports

**Custom Rules (via Lambda):**

- All ECS tasks must have logging enabled
- All Fargate tasks must use non-root user
- All secrets must be in Secrets Manager (not environment variables)

**Remediation:**

- Automatic: Fix non-compliant resources (e.g., enable S3 encryption)
- Manual: Alert security team for review

**Cost:** ~$2/month per region (for recorded resources) + rule evaluations (~$0.001 each)

**Priority:** Medium (if compliance required)  
**Estimated Effort:** 2 days  
**Owner:** Security/Compliance Team

---

### 2.4 GuardDuty Threat Detection

**Current State:**

- GuardDuty not enabled

**Gaps:**

- [ ] **No threat detection** (compromised instances, malware, data exfiltration)
- [ ] **No alerting on suspicious activity**

**Recommendations:**

### GuardDuty Configuration

**Enable GuardDuty:**

- All regions (or at least production regions)
- EKS Protection: No (not using EKS)
- S3 Protection: Yes (if storing sensitive data)
- Malware Protection: Yes (scans EBS volumes)

**Alert Routing:**

- High/Critical findings → PagerDuty (immediate response)
- Medium findings → Slack channel (review within 24 hours)
- Low findings → Weekly summary email

**Common Findings:**

- Cryptocurrency mining (compromised instance)
- Unusual API calls (stolen credentials)
- Backdoor communication (malware)
- Data exfiltration (large data transfer to unknown IP)

**Response Playbook:**

1. Isolate compromised resource (change security group, stop instance)
2. Capture forensic snapshot (EBS snapshot, memory dump)
3. Rotate credentials
4. Investigate root cause
5. Implement preventive controls

**Cost:** ~$5-10/month (varies by traffic volume)

**Priority:** Medium-High (if handling sensitive data)  
**Estimated Effort:** 0.5 day  
**Owner:** Security Team

---

### 2.5 Compliance Framework Mapping

**Gaps:**

- [ ] **No mapping to compliance requirements** (SOC 2, HIPAA, PCI, GDPR)
- [ ] **No evidence collection** for auditors
- [ ] **No compliance dashboard**

**Recommendations:**

### Compliance Evidence Collection

**SOC 2 Type II (Example):**
| Control | Evidence | AWS Service |
|---------|----------|-------------|
| CC6.1: Logical access controls | IAM policies, MFA enforcement | IAM Access Analyzer |
| CC6.6: Encryption at rest | All data encrypted | AWS Config rule |
| CC6.7: Encryption in transit | HTTPS only, TLS 1.2+ | ALB config |
| CC7.2: System monitoring | Logs, metrics, alerts | CloudWatch, GuardDuty |
| CC8.1: Change management | All changes tracked | CloudTrail, GitHub |

**HIPAA (if applicable):**

- BAA signed with AWS
- All PHI encrypted (at rest and in transit)
- Access logs maintained for 6 years
- Audit controls (who accessed what PHI data)

**GDPR (if applicable):**

- Data residency controls (eu-west-1 for EU customers)
- Data deletion procedures (right to be forgotten)
- Data breach notification process (<72 hours)
- Data processing agreements with third parties

**Tooling:**

- AWS Audit Manager: Continuous compliance assessment
- Drata / Vanta: Compliance automation platform
- Custom compliance dashboard: Real-time compliance posture

**Priority:** High (if compliance required), Low (if not)  
**Estimated Effort:** 5-10 days (framework-dependent)  
**Owner:** Compliance Team
