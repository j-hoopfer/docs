# Out of Scope: Future Enhancements & Considerations

## Overview

This document captures important production concerns that are **out of scope** for the initial EC2-to-Fargate migration but should be addressed in separate workstreams or future phases.

These items are not required for a successful migration but are recommended for production-grade operation, compliance, and operational excellence.

---

## 1. Disaster Recovery & Backup Strategy

### Status

**Out of Scope** - To be addressed in a separate DR planning workstream

### Why This Matters

While the migration establishes infrastructure for running applications on Fargate, it doesn't establish comprehensive disaster recovery procedures for catastrophic failures (region outage, accidental deletion, data corruption).

### What's Missing

#### 1.1 RDS Backup and Recovery Strategy

**Current State:**

- RDS automated backups are enabled by default (1-day retention)
- Point-in-time recovery (PITR) available within backup window

**Gaps:**

- [ ] **Backup retention policy not defined** - How long to keep backups?
- [ ] **Cross-region backup strategy** - What if us-east-1 region fails?
- [ ] **Recovery Time Objective (RTO)** - How quickly can we restore?
- [ ] **Recovery Point Objective (RPO)** - How much data loss is acceptable?
- [ ] **Backup restoration testing** - Have we ever actually restored from backup?
- [ ] **Database snapshot export to S3** - For long-term archival

**Recommendations:**

```markdown
### Recommended DR Configuration

**RDS Backup Policy:**

- Automated backup retention: 30 days
- Manual snapshots: Monthly (retained 1 year for compliance)
- Cross-region snapshots: Weekly to us-west-2 (DR region)
- PITR enabled

**RDS Multi-Region Strategy:**

- Primary: us-east-1 (production writes)
- Read Replica: us-west-2 (DR region, promote on failover)
- Automated failover with Route 53 health checks

**Recovery Objectives:**

- RTO: 1 hour (time to promote read replica)
- RPO: 5 minutes (replication lag)

**Testing:**

- Quarterly DR drill: Promote us-west-2 read replica to standalone
- Document restoration procedure
```

**Priority:** High  
**Estimated Effort:** 2-3 days  
**Owner:** Database/SRE Team

---

#### 1.2 ECS Task Definition Version Control

**Current State:**

- Task definitions stored in AWS (each revision creates a new version)
- GitHub Actions creates new revisions on each deployment

**Gaps:**

- [ ] **No long-term storage of task definitions** - AWS may purge old revisions
- [ ] **No backup of task definition history** outside AWS
- [ ] **Dependency on AWS Console for rollback**

**Recommendations:**

````markdown
### Task Definition Backup Strategy

**Store in Git:**

- Export task definition JSON to infrastructure repo on each deployment
- Commit to Git: `infrastructure/task-definitions/auth-api/2024-01-25-abc123.json`
- Enables reconstruction if AWS account compromised

**Store in S3:**

- GitHub Actions uploads task definition to S3 after registration
- Bucket: `my-company-ecs-task-definitions`
- Versioning enabled
- Lifecycle: Retain for 1 year

**Implementation:**
Add to GitHub Actions workflow:

```yaml
- name: Backup task definition to S3
  run: |
    aws s3 cp task-definition.json \
      s3://my-company-ecs-task-definitions/\${{ env.ECS_SERVICE }}/$(date +%Y-%m-%d)-\${{ github.sha }}.json
```
````

````

**Priority:** Medium
**Estimated Effort:** 1 day
**Owner:** Platform Team

---

#### 1.3 ECR Image Disaster Recovery

**Current State:**
- ECR images stored in us-east-1 only
- Lifecycle policies delete old images

**Gaps:**
- [ ] **No cross-region replication** - Regional failure = no images
- [ ] **No long-term archive** of critical image versions
- [ ] **No plan for rebuilding images** if ECR data lost

**Recommendations:**
```markdown
### ECR Disaster Recovery

**Cross-Region Replication:**
- Enable ECR replication to us-west-2 (DR region)
- Replication rule: All repositories with tag prefix `release-*` or `stable-*`

**Configuration:**
```bash
aws ecr put-replication-configuration --replication-configuration '{
  "rules": [{
    "destinations": [{
      "region": "us-west-2",
      "registryId": "123456789012"
    }],
    "repositoryFilters": [{
      "filter": "legacy-migration/*",
      "filterType": "PREFIX_MATCH"
    }]
  }]
}'
````

**Long-Term Archive:**

- Tag production releases: `release-2024-01-25`, `stable-v1.2.3`
- Lifecycle policy: Never expire images with `release-*` or `stable-*` tags
- Export critical images to S3 (compressed tar.gz) for compliance

**Source Code as Backup:**

- All images rebuildable from Git commits
- Document build instructions in README
- Tag Git commits with deployed image SHA

````

**Priority:** Medium-High
**Estimated Effort:** 1-2 days
**Owner:** Platform Team

---

#### 1.4 Secrets Manager Disaster Recovery

**Current State:**
- Secrets stored in AWS Secrets Manager (us-east-1)
- Encrypted with AWS managed KMS key

**Gaps:**
- [ ] **No cross-region replication** - DR failover would require recreating secrets
- [ ] **No backup export** of secret values (for complete AWS failure scenario)
- [ ] **Secret restoration procedure not documented**

**Recommendations:**
```markdown
### Secrets Disaster Recovery

**Cross-Region Replication:**
- Enable Secrets Manager replication to us-west-2
- Automatic sync on secret value changes

**Configuration:**
```bash
aws secretsmanager replicate-secret-to-regions \
  --secret-id production/auth-api/database \
  --add-replica-regions Region=us-west-2
````

**Emergency Secret Backup (Controversial but Pragmatic):**

- Store encrypted backup of critical secrets in secure S3 bucket
- Encryption: GPG with key stored in hardware security module
- Use only for complete AWS failure scenario
- Rotate secrets after any use of backup

**Alternative (Preferred):**

- Source of truth for secrets in external vault (HashiCorp Vault, 1Password Secrets)
- Secrets Manager populated from external source
- DR = repopulate from vault

````

**Priority:** Medium
**Estimated Effort:** 2 days
**Owner:** Security Team

---

#### 1.5 Infrastructure as Code Recovery

**Current State:**
- VPC, ALB, ECS Cluster created manually or via Terraform (if implemented)
- Configuration not fully documented

**Gaps:**
- [ ] **Complete infrastructure rebuild procedure not documented**
- [ ] **No tested "environment from scratch" process**
- [ ] **Manual dependencies not captured in IaC**

**Recommendations:**
```markdown
### Infrastructure Recovery

**Full Environment Rebuild:**
- Document complete rebuild from zero in runbook
- Include: VPC, subnets, NAT, ALB, ECS cluster, security groups, IAM roles
- Test quarterly in isolated AWS account

**Terraform State Backup:**
- Store Terraform state in S3 with versioning enabled
- Cross-region replication of state files to us-west-2
- State locking with DynamoDB (also replicated)

**Runbook Checklist:**
1. Provision VPC and networking (Terraform or manual)
2. Create ECS cluster
3. Create ALB and target groups
4. Restore RDS from snapshot
5. Replicate secrets from DR region
6. Deploy services from ECR images (replicated)
7. Update DNS cutover to DR region
8. Test application functionality
````

**Priority:** High  
**Estimated Effort:** 3-5 days (initial), 1 day quarterly (testing)  
**Owner:** SRE/Platform Team

---

#### 1.6 Complete DR Runbook

**Recommendations:**

```markdown
### Disaster Recovery Scenarios

**Scenario 1: Single AZ Failure**

- Impact: 50% capacity (if using 2 AZs)
- Auto-recovery: ECS launches tasks in healthy AZ
- Action required: None (verify monitoring)

**Scenario 2: Region Failure (us-east-1)**

- Impact: Complete outage
- Recovery steps:
  1. Promote RDS read replica in us-west-2
  2. Update Route 53 to point to DR ALB
  3. Scale up ECS services in DR region
  4. Verify application functionality
- Time to recovery: 30-60 minutes
- Prerequisites: DR environment pre-provisioned

**Scenario 3: Accidental Resource Deletion**

- Impact: Varies (task deletion = seconds, cluster deletion = minutes)
- Recovery: Redeploy from IaC or manually recreate
- Time to recovery: 5-30 minutes

**Scenario 4: Data Corruption**

- Impact: Database contains invalid data
- Recovery: Restore RDS from PITR or snapshot
- Time to recovery: 15-60 minutes
- Data loss: Depends on backup interval (up to 5 minutes with PITR)

**Scenario 5: Complete AWS Account Compromise**

- Impact: All resources potentially compromised
- Recovery: Rebuild in new AWS account from Git + backups
- Time to recovery: 4-8 hours
- Prerequisites: External backups, documented procedures
```

**Priority:** High  
**Estimated Effort:** 5 days (documentation + quarterly testing)  
**Owner:** SRE Team

---

## 2. Compliance & Audit Requirements

### Status

**Out of Scope** - To be addressed based on company compliance framework

### Why This Matters

Many industries require demonstrable compliance with security and privacy standards (SOC 2, HIPAA, PCI-DSS, GDPR, etc.). Without proper logging, monitoring, and controls, you cannot pass audits.

### What's Missing

#### 2.1 CloudTrail Logging

**Current State:**

- CloudTrail may be enabled by default (varies by AWS account setup)
- Logging configuration not verified or standardized

**Gaps:**

- [ ] **CloudTrail not explicitly enabled** for all regions
- [ ] **No centralized log storage** in tamper-proof S3 bucket
- [ ] **No log file integrity validation**
- [ ] **No alerting on suspicious API calls**

**Recommendations:**

```markdown
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
```

**Priority:** High (if compliance required)  
**Estimated Effort:** 1 day  
**Owner:** Security/Compliance Team

---

#### 2.2 VPC Flow Logs

**Current State:**

- VPC Flow Logs not enabled

**Gaps:**

- [ ] **No network traffic visibility** for security investigations
- [ ] **Cannot detect port scanning, DDoS, data exfiltration**
- [ ] **No compliance evidence** of network activity

**Recommendations:**

```markdown
### VPC Flow Logs Configuration

**Enable for All VPCs:**

- Log destination: CloudWatch Logs or S3 (S3 cheaper for long-term storage)
- Traffic type: ALL (accepted + rejected)
- Log format: Custom format with additional fields

**Custom Log Format:**
\`\`\`
${srcaddr} ${dstaddr} ${srcport} ${dstport} ${protocol} ${packets} ${bytes} ${start} ${end} ${action} ${log-status} ${vpc-id} ${subnet-id} ${instance-id} ${interface-id} ${pkt-srcaddr} ${pkt-dstaddr}
\`\`\`

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
```

**Priority:** Medium-High (if compliance required)  
**Estimated Effort:** 0.5 day  
**Owner:** Security Team

---

#### 2.3 AWS Config

**Current State:**

- AWS Config not enabled

**Gaps:**

- [ ] **No configuration change tracking** (who changed what security group?)
- [ ] **No compliance rule enforcement** (e.g., "all S3 buckets must have encryption")
- [ ] **Cannot answer audit questions** like "show all security group changes in Q4 2024"

**Recommendations:**

```markdown
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
```

**Priority:** Medium (if compliance required)  
**Estimated Effort:** 2 days  
**Owner:** Security/Compliance Team

---

#### 2.4 GuardDuty Threat Detection

**Current State:**

- GuardDuty not enabled

**Gaps:**

- [ ] **No threat detection** (compromised instances, malware, data exfiltration)
- [ ] **No alerting on suspicious activity**

**Recommendations:**

```markdown
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
```

**Priority:** Medium-High (if handling sensitive data)  
**Estimated Effort:** 0.5 day  
**Owner:** Security Team

---

#### 2.5 Compliance Framework Mapping

**Gaps:**

- [ ] **No mapping to compliance requirements** (SOC 2, HIPAA, PCI, GDPR)
- [ ] **No evidence collection** for auditors
- [ ] **No compliance dashboard**

**Recommendations:**

```markdown
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
```

**Priority:** High (if compliance required), Low (if not)  
**Estimated Effort:** 5-10 days (framework-dependent)  
**Owner:** Compliance Team

---

## 3. Circuit Breaker and Retry Strategies for Inter-Service Calls

### Status

**Out of Scope** - Application-level resilience patterns

### Why This Matters

When Service A calls Service B, transient failures will occur (network blips, Service B overloaded, etc.). Without retry logic and circuit breakers, cascading failures can bring down the entire system.

### What's Missing

#### 3.1 Circuit Breaker Pattern

**Current State:**

- Applications make HTTP calls to other services
- No circuit breaker logic (services retry indefinitely or fail immediately)

**Gaps:**

- [ ] **No protection against cascading failures**
- [ ] **Unhealthy services continue receiving traffic** (making them worse)
- [ ] **No graceful degradation** when dependencies fail

**Recommendations:**

```markdown
### Circuit Breaker Implementation

**Pattern Overview:**
\`\`\`
States:
CLOSED → Normal operation, requests pass through
OPEN → Too many failures, requests fail immediately (don't call service)
HALF-OPEN → Testing if service recovered, allow limited requests

Transitions:
CLOSED → OPEN: After X failures in Y seconds
OPEN → HALF-OPEN: After Z seconds (cooldown period)
HALF-OPEN → CLOSED: If test requests succeed
HALF-OPEN → OPEN: If test requests fail
\`\`\`

**Node.js Implementation (using opossum):**
\`\`\`javascript
const CircuitBreaker = require('opossum');

// Wrap HTTP client
const options = {
timeout: 3000, // If function takes >3s, trigger failure
errorThresholdPercentage: 50, // Open circuit if >50% fail
resetTimeout: 30000, // Try again after 30 seconds
volumeThreshold: 10 // Need at least 10 requests before calculating error rate
};

const breaker = new CircuitBreaker(callUserService, options);

// Fallback when circuit is open
breaker.fallback(() => {
console.log('Circuit open, using cached data');
return getCachedUserData();
});

// Events
breaker.on('open', () => console.log('Circuit opened - user-service unhealthy'));
breaker.on('halfOpen', () => console.log('Circuit half-open - testing user-service'));
breaker.on('close', () => console.log('Circuit closed - user-service healthy'));

// Usage
async function getUserProfile(userId) {
try {
return await breaker.fire(userId);
} catch (err) {
console.error('Failed to get user profile', err);
return null; // Or default value
}
}
\`\`\`

**Python Implementation (using pybreaker):**
\`\`\`python
import pybreaker
import requests

# Define circuit breaker

breaker = pybreaker.CircuitBreaker(
fail_max=5, # Open after 5 failures
reset_timeout=60, # Try again after 60 seconds
exclude=[requests.HTTPError] # Don't count 4xx errors
)

@breaker
def call_user_service(user_id):
response = requests.get(f'{USER_SERVICE_URL}/users/{user_id}', timeout=3)
response.raise_for_status()
return response.json()

# Usage with fallback

def get_user_profile(user_id):
try:
return call_user_service(user_id)
except pybreaker.CircuitBreakerError:
logger.warning("Circuit breaker open for user-service")
return get_cached_user_data(user_id)
except Exception as e:
logger.error(f"Error calling user-service: {e}")
return None
\`\`\`

**Java Implementation (using Resilience4j):**
\`\`\`java
import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import io.github.resilience4j.circuitbreaker.CircuitBreakerConfig;

CircuitBreakerConfig config = CircuitBreakerConfig.custom()
.failureRateThreshold(50) // Open at 50% failure rate
.waitDurationInOpenState(Duration.ofSeconds(30))
.slidingWindowSize(10)
.build();

CircuitBreaker circuitBreaker = CircuitBreaker.of("userService", config);

// Wrap service call
Supplier<UserProfile> decoratedSupplier = CircuitBreaker
.decorateSupplier(circuitBreaker, () -> callUserService(userId));

// Execute with fallback
Try<UserProfile> result = Try.ofSupplier(decoratedSupplier)
.recover(throwable -> getCachedUserData(userId));
\`\`\`

**Monitoring:**

- Emit metrics: circuit state, failure rate, call volume
- Dashboard: Track circuit breaker state per service
- Alert: Circuit open for >5 minutes (indicates downstream issue)
```

**Priority:** High (for production resilience)  
**Estimated Effort:** 2-3 days per application  
**Owner:** Application Development Team

---

#### 3.2 Retry Strategy with Exponential Backoff

**Current State:**

- HTTP clients may retry with default settings (often immediate retry)
- No jitter, no backoff

**Gaps:**

- [ ] **No exponential backoff** (retries at same rate, overwhelming failing service)
- [ ] **No jitter** (all clients retry at same time, thundering herd)
- [ ] **No distinction** between retryable errors (503) vs non-retryable (404)

**Recommendations:**

```markdown
### Retry Strategy

**Retryable vs Non-Retryable Errors:**
| Error | Retry? | Reason |
|-------|--------|--------|
| 500 Internal Server Error | Yes | Transient server issue |
| 502 Bad Gateway | Yes | Service temporarily down |
| 503 Service Unavailable | Yes | Service overloaded |
| 504 Gateway Timeout | Yes | Request took too long |
| 429 Too Many Requests | Yes (with backoff) | Rate limited |
| 408 Request Timeout | Yes | Network issue |
| 404 Not Found | No | Resource doesn't exist |
| 401 Unauthorized | No | Bad credentials |
| 400 Bad Request | No | Client error |

**Exponential Backoff with Jitter:**
\`\`\`
Attempt 1: Wait 0s (immediate)
Attempt 2: Wait 1s + jitter(0-1s) = 1-2s
Attempt 3: Wait 2s + jitter(0-2s) = 2-4s
Attempt 4: Wait 4s + jitter(0-4s) = 4-8s
Max retries: 3-5
\`\`\`

**Node.js Implementation (using axios-retry):**
\`\`\`javascript
const axios = require('axios');
const axiosRetry = require('axios-retry');

axiosRetry(axios, {
retries: 3,
retryDelay: axiosRetry.exponentialDelay, // 1s, 2s, 4s
retryCondition: (error) => {
// Retry on network errors or 5xx responses
return axiosRetry.isNetworkOrIdempotentRequestError(error) ||
(error.response?.status >= 500);
},
onRetry: (retryCount, error, requestConfig) => {
console.log(\`Retry attempt \${retryCount} for \${requestConfig.url}\`);
}
});

// Usage
try {
const response = await axios.get('http://user-api.internal/users/123');
return response.data;
} catch (error) {
console.error('Failed after retries', error);
throw error;
}
\`\`\`

**Python Implementation (using tenacity):**
\`\`\`python
from tenacity import retry, stop_after_attempt, wait_exponential, retry_if_exception_type
import requests

@retry(
stop=stop_after_attempt(3),
wait=wait_exponential(multiplier=1, min=1, max=10),
retry=retry_if_exception_type((requests.ConnectionError, requests.Timeout)),
reraise=True
)
def call_user_service(user_id):
response = requests.get(
f'{USER_SERVICE_URL}/users/{user_id}',
timeout=3
)

    # Retry on 5xx errors
    if response.status_code >= 500:
        raise requests.HTTPError(f"Server error: {response.status_code}")

    response.raise_for_status()
    return response.json()

\`\`\`

**Best Practices:**

- Max retries: 3-5 (don't retry forever)
- Max delay: 10-30 seconds (don't wait too long)
- Add jitter: Prevent thundering herd
- Idempotent operations only: Don't retry payment processing!
- Timeout per attempt: 3-5 seconds (shorter than overall timeout)
```

**Priority:** High (for production resilience)  
**Estimated Effort:** 1-2 days per application  
**Owner:** Application Development Team

---

#### 3.3 Timeout Configuration

**Current State:**

- HTTP client timeouts may be using defaults (often 60+ seconds)

**Gaps:**

- [ ] **No consistent timeout strategy** across services
- [ ] **Timeouts too long** (user waits forever for error)
- [ ] **No distinction** between connection timeout vs read timeout

**Recommendations:**

```markdown
### Timeout Strategy

**Timeout Types:**
| Timeout | Purpose | Recommended Value |
|---------|---------|-------------------|
| Connection Timeout | Time to establish TCP connection | 2-5 seconds |
| Read Timeout | Time to receive response after connection | 5-30 seconds |
| Overall Request Timeout | Total time for entire request | 10-60 seconds |

**Example Configuration:**
\`\`\`javascript
// Node.js (axios)
const axios = require('axios');

const client = axios.create({
timeout: 10000, // Overall timeout: 10 seconds
httpAgent: new http.Agent({
timeout: 5000, // Read timeout: 5 seconds
keepAlive: true // Reuse connections
})
});
\`\`\`

\`\`\`python

# Python (requests)

import requests

response = requests.get(
url,
timeout=(2, 5) # (connect timeout, read timeout) in seconds
)
\`\`\`

**Guidelines:**

- Internal service calls: 5-10 second timeout
- External API calls: 30-60 second timeout (third parties are slower)
- Database queries: 5-15 second timeout (depends on complexity)
- Fast endpoints (/health): 1-2 second timeout

**Propagation:**
If Service A → Service B → Service C:

- Service A timeout: 10 seconds
- Service B timeout (calling C): 5 seconds
- Service C timeout: 2 seconds
  Ensures outer timeouts don't fire before inner timeouts
```

**Priority:** Medium-High  
**Estimated Effort:** 1 day per application  
**Owner:** Application Development Team

---

#### 3.4 Bulkhead Pattern (Optional)

**Recommendations:**

```markdown
### Bulkhead Pattern

**Concept:**
Isolate resources to prevent one failing dependency from exhausting all resources.

**Example:**
Instead of 1 shared connection pool for all services:

- User Service: 10 connections
- Auth Service: 5 connections
- Notification Service: 3 connections

If Notification Service is slow/down, it only consumes its 3 connections, not all 18.

**Implementation (Node.js):**
\`\`\`javascript
const { default: PQueue } = require('p-queue');

// Separate queue per dependency
const userServiceQueue = new PQueue({ concurrency: 10 });
const authServiceQueue = new PQueue({ concurrency: 5 });

// Usage
async function callUserService(userId) {
return userServiceQueue.add(() =>
axios.get(\`\${USER_SERVICE_URL}/users/\${userId}\`)
);
}
\`\`\`

**When to Use:**

- High-traffic systems
- Dependencies with varying reliability
- Risk of cascading failures
```

**Priority:** Low (nice-to-have)  
**Estimated Effort:** 2-3 days  
**Owner:** Application Development Team

---

## 4. Certificate Renewal & Expiration Monitoring

### Status

**Out of Scope** - Operational monitoring enhancement

### Why This Matters

SSL/TLS certificates expire. If your ALB certificate expires, your site goes down. While ACM auto-renews DNS-validated certificates, renewal can fail if DNS validation records are accidentally deleted.

### What's Missing

#### 4.1 ACM Certificate Expiration Monitoring

**Current State:**

- ACM certificates requested and attached to ALB
- DNS validation configured in Route 53
- ACM auto-renewal enabled

**Gaps:**

- [ ] **No proactive monitoring** of certificate expiration dates
- [ ] **No alerting** if auto-renewal fails
- [ ] **No notification** when certificates are close to expiry
- [ ] **No tracking** of certificate rotation in logs

**Recommendations:**

```markdown
### Certificate Monitoring Setup

**CloudWatch Alarm for Expiration:**
\`\`\`bash

# ACM publishes DaysToExpiry metric

aws cloudwatch put-metric-alarm \
 --alarm-name "ACM-Certificate-Expiring-Soon" \
 --alarm-description "ACM certificate expires in <30 days" \
 --metric-name DaysToExpiry \
 --namespace AWS/CertificateManager \
 --statistic Minimum \
 --period 86400 \
 --evaluation-periods 1 \
 --threshold 30 \
 --comparison-operator LessThanThreshold \
 --alarm-actions arn:aws:sns:us-east-1:123456789012:critical-alerts
\`\`\`

**Lambda Function for Certificate Inventory:**
\`\`\`python
import boto3
from datetime import datetime, timedelta

def lambda_handler(event, context):
acm = boto3.client('acm')

    # List all certificates
    response = acm.list_certificates(CertificateStatuses=['ISSUED'])

    alerts = []
    for cert_summary in response['CertificateSummaryList']:
        cert_arn = cert_summary['CertificateArn']

        # Get certificate details
        cert = acm.describe_certificate(CertificateArn=cert_arn)['Certificate']

        domain = cert['DomainName']
        expires_at = cert['NotAfter']
        days_remaining = (expires_at - datetime.now(expires_at.tzinfo)).days

        if days_remaining < 30:
            alerts.append(f"⚠️  {domain} expires in {days_remaining} days")

    if alerts:
        # Send to SNS
        sns = boto3.client('sns')
        sns.publish(
            TopicArn='arn:aws:sns:us-east-1:123456789012:certificate-alerts',
            Subject='Certificate Expiration Alert',
            Message='\n'.join(alerts)
        )

    return {'statusCode': 200, 'body': 'Certificate check complete'}

\`\`\`

**EventBridge Schedule:**

- Run Lambda daily
- Check all certificates
- Alert if <30 days to expiration

**Dashboard:**

- CloudWatch dashboard widget showing certificate expiration dates
- Visual indicator: Green (>90 days), Yellow (30-90 days), Red (<30 days)
```

**Priority:** Medium  
**Estimated Effort:** 1 day  
**Owner:** Platform/SRE Team

---

#### 4.2 Certificate Renewal Validation

**Gaps:**

- [ ] **No verification** that DNS validation records remain in place
- [ ] **No testing** of renewal process
- [ ] **No alerting** on renewal failures

**Recommendations:**

```markdown
### Certificate Renewal Validation

**DNS Validation Record Monitoring:**

- ACM requires CNAME records for validation
- If deleted, renewal fails
- Monitor that validation records exist

**Validation Check Script:**
\`\`\`bash
#!/bin/bash

# Check that ACM validation CNAME exists in Route 53

ACM_CERT_ARN="arn:aws:acm:us-east-1:123456789012:certificate/abc-123"
HOSTED_ZONE_ID="Z1234567890ABC"

# Get validation CNAME from ACM

VALIDATION_RECORD=$(aws acm describe-certificate \
 --certificate-arn $ACM_CERT_ARN \
 --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Name' \
 --output text)

# Check if it exists in Route 53

RECORD_EXISTS=$(aws route53 list-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --query "ResourceRecordSets[?Name=='$VALIDATION_RECORD'].Name" \
 --output text)

if [ -z "$RECORD_EXISTS" ]; then
echo "❌ ACM validation record missing! Auto-renewal will fail!"

# Send alert

else
echo "✅ ACM validation record exists"
fi
\`\`\`

**EventBridge Rule:**

- Trigger on ACM Certificate Renewal Failure
- Send to SNS topic → PagerDuty

**Event Pattern:**
\`\`\`json
{
"source": ["aws.acm"],
"detail-type": ["ACM Certificate Approaching Expiration"],
"detail": {
"DaysToExpiry": [30, 15, 7, 1]
}
}
\`\`\`
```

**Priority:** Low-Medium  
**Estimated Effort:** 0.5 day  
**Owner:** Platform Team

---

#### 4.3 External Certificate Monitoring (if applicable)

**Gaps:**

- If using external certificates (not ACM), monitoring is even more critical

**Recommendations:**

```markdown
### External Certificate Monitoring

**For Non-ACM Certificates:**

- Use external monitoring service (SSL Labs, Uptime Robot, Pingdom)
- Check certificate daily
- Alert 30 days before expiration

**Manual Renewal Process:**

1. Request new certificate from CA
2. Upload to AWS Certificate Manager or IAM
3. Update ALB listener to use new certificate
4. Verify HTTPS works
5. Delete old certificate after grace period

**Automation (Let's Encrypt):**

- Use certbot with DNS plugin
- Store certificate in Secrets Manager
- Lambda function to update ALB listener
- Run monthly via EventBridge
```

**Priority:** High (if using external certs), N/A (if using ACM)  
**Estimated Effort:** 2-3 days  
**Owner:** Platform Team

---

## 5. Blue/Green Deployment Strategy

### Status

**Out of Scope** - Alternative deployment pattern for zero-downtime releases

### Why This Matters

While the migration plan uses **rolling updates** (default ECS deployment), some teams prefer **blue/green deployments** for instant rollback capability and zero-downtime releases with complete environment validation before cutover.

### What's Missing

#### 5.1 Blue/Green Deployment Pattern

**Current State:**

- ECS rolling updates (default)
- New tasks start, old tasks drain, gradual replacement

**Gaps:**

- [ ] **No instant rollback** - Rolling back requires new deployment
- [ ] **No full environment testing** before cutover - New version immediately receives traffic
- [ ] **Cannot compare** blue and green side-by-side

**Recommendations:**

```markdown
### Blue/Green Deployment Architecture

**Concept:**

- Maintain TWO complete environments (blue = current, green = new)
- Deploy new version to green environment
- Test green environment thoroughly
- Switch traffic from blue to green instantly
- Keep blue as instant rollback

**Implementation Option 1: ALB Target Group Swap**
\`\`\`
Blue Environment:

- ECS Service: auth-api-blue
- Target Group: auth-api-blue-tg (weight 100%)
- Tasks: Current version (v1.2.0)

Green Environment:

- ECS Service: auth-api-green
- Target Group: auth-api-green-tg (weight 0%)
- Tasks: New version (v1.3.0)

Cutover:

1. Deploy v1.3.0 to green service
2. Test green via direct target group
3. Flip ALB listener rule weights:
   - Blue: 100% → 0%
   - Green: 0% → 100%
4. Monitor green under load
5. If issues: Flip back to blue (instant)
   \`\`\`

**Implementation Option 2: AWS CodeDeploy Blue/Green**
\`\`\`bash

# Create CodeDeploy application

aws deploy create-application \
 --application-name auth-api \
 --compute-platform ECS

# Create deployment group

aws deploy create-deployment-group \
 --application-name auth-api \
 --deployment-group-name production \
 --deployment-config-name CodeDeployDefault.ECSAllAtOnce \
 --service-role-arn arn:aws:iam::123456789012:role/CodeDeployServiceRole \
 --ecs-services clusterName=production-cluster,serviceName=auth-api \
 --load-balancer-info targetGroupPairInfoList=[{
targetGroups=[
{name=auth-api-blue-tg},
{name=auth-api-green-tg}
],
prodTrafficRoute={listenerArns=[arn:aws:elasticloadbalancing:...]}
}]

# Deploy with automated rollback

aws deploy create-deployment \
 --application-name auth-api \
 --deployment-group-name production \
 --revision '{"revisionType":"AppSpecContent","appSpecContent":{"content":"..."}}'
\`\`\`

**AppSpec File for CodeDeploy:**
\`\`\`yaml
version: 0.0
Resources:

- TargetService:
  Type: AWS::ECS::Service
  Properties:
  TaskDefinition: "arn:aws:ecs:us-east-1:123456789012:task-definition/auth-api:5"
  LoadBalancerInfo:
  ContainerName: "auth-api"
  ContainerPort: 3000
  PlatformVersion: "LATEST"

Hooks:

- BeforeInstall: "LambdaFunctionToValidatePrerequisites"
- AfterInstall: "LambdaFunctionToTestGreenEnvironment"
- AfterAllowTestTraffic: "LambdaFunctionToRunIntegrationTests"
- BeforeAllowTraffic: "LambdaFunctionToWarmUpGreen"
- AfterAllowTraffic: "LambdaFunctionToValidateProduction"
  \`\`\`

**Traffic Shifting Options:**

- **AllAtOnce:** Instant cutover (100% blue → 100% green)
- **Canary:** 10% for 5 minutes, then 100%
- **Linear:** 10% every 5 minutes (10 steps)

**Automated Rollback:**

- Monitor CloudWatch alarms during deployment
- Auto-rollback if alarm fires (5xx errors, high latency)
- Rollback = route traffic back to blue instantly
```

**Priority:** Low-Medium (nice-to-have, rolling updates work fine)  
**Estimated Effort:** 3-5 days (initial setup), then automatic  
**Owner:** Platform/DevOps Team

---

## 6. Canary Deployments with Lambda@Edge or CloudFront

### Status

**Out of Scope** - Advanced traffic management for gradual rollouts

### Why This Matters

For user-facing applications where you want to expose a new version to a small percentage of **real users** (not just all traffic), you can use CloudFront + Lambda@Edge to route specific user segments to different versions.

### What's Missing

#### 6.1 CloudFront-Based Canary Deployments

**Current State:**

- ALB routes all traffic to ECS tasks
- All users see the same version

**Gaps:**

- [ ] **No user-based routing** - Cannot send "beta users" to new version
- [ ] **No geography-based routing** - Cannot deploy to US first, EU later
- [ ] **No A/B testing capability**

**Recommendations:**

```markdown
### CloudFront Canary Architecture

**Pattern:**
\`\`\`
User Request → CloudFront → Lambda@Edge → [Blue ALB (90%) | Green ALB (10%)]
\`\`\`

**Lambda@Edge Function:**
\`\`\`javascript
// Triggered on Viewer Request
exports.handler = async (event) => {
const request = event.Records[0].cf.request;

// Get user ID from cookie or header
const userId = request.headers['user-id']?.[0]?.value;

// Canary logic: 10% of users go to green
const isCanary = hashUserId(userId) % 100 < 10;

// Route to appropriate ALB
if (isCanary) {
request.origin = {
custom: {
domainName: 'green-alb-123.us-east-1.elb.amazonaws.com',
port: 443,
protocol: 'https'
}
};
} else {
request.origin = {
custom: {
domainName: 'blue-alb-456.us-east-1.elb.amazonaws.com',
port: 443,
protocol: 'https'
}
};
}

return request;
};

function hashUserId(userId) {
// Simple hash for consistent routing
let hash = 0;
for (let i = 0; i < userId.length; i++) {
hash = ((hash << 5) - hash) + userId.charCodeAt(i);
hash = hash & hash; // Convert to 32bit integer
}
return Math.abs(hash);
}
\`\`\`

**Advanced Patterns:**

- **Geography-based:** Deploy to US-East first, then EU, then Asia
- **User-segment:** Beta users → new version, regular users → stable
- **Device-based:** Mobile app v2.0 → new API, web → stable API
- **Time-based:** Gradually increase canary percentage over days

**Monitoring:**

- Track metrics by version (blue vs green)
- Compare error rates, latency, conversion rates
- Auto-rollback if green metrics degrade

**Alternative: Feature Flags (LaunchDarkly, Split.io):**

- Control features at application level (not infrastructure)
- More granular than infrastructure routing
- Easier for A/B testing
```

**Priority:** Low (only if you need advanced traffic management)  
**Estimated Effort:** 5-7 days  
**Owner:** Platform Team + Application Team

---

## 7. Multi-Region Failover Strategy

### Status

**Out of Scope** - High-availability architecture for mission-critical applications

### Why This Matters

If your application requires 99.99% uptime (43 minutes downtime/year) or needs to survive a regional AWS outage, you need active-active or active-passive multi-region deployment.

### What's Missing

#### 7.1 Active-Passive Multi-Region Architecture

**Current State:**

- Single region deployment (us-east-1)
- No disaster recovery region

**Gaps:**

- [ ] **No regional redundancy** - AWS region failure = complete outage
- [ ] **No automatic failover** to backup region
- [ ] **RTO measured in hours** (manual rebuild)

**Recommendations:**

```markdown
### Active-Passive Multi-Region Setup

**Architecture:**
\`\`\`
Primary Region (us-east-1):

- Production traffic (100%)
- ECS Fargate services (active)
- RDS Primary (writes + reads)
- ElastiCache (active)

DR Region (us-west-2):

- No traffic (standby)
- ECS Fargate services (pre-deployed, scaled to 0)
- RDS Read Replica (reads only, promote on failover)
- ElastiCache (standby or none)

Route 53:

- Health check on us-east-1 ALB
- Failover routing: us-east-1 primary, us-west-2 secondary
  \`\`\`

**Infrastructure Requirements:**

**1. Route 53 Failover:**
\`\`\`bash

# Primary record (us-east-1)

aws route53 change-resource-record-sets \
 --hosted-zone-id Z123456 \
 --change-batch '{
"Changes": [{
"Action": "CREATE",
"ResourceRecordSet": {
"Name": "api.mysite.com",
"Type": "A",
"SetIdentifier": "Primary",
"Failover": "PRIMARY",
"AliasTarget": {
"HostedZoneId": "Z35SXDO...",
"DNSName": "us-east-1-alb.elb.amazonaws.com",
"EvaluateTargetHealth": true
},
"HealthCheckId": "abc123"
}
}]
}'

# Secondary record (us-west-2)

# Similar, but Failover: "SECONDARY"

\`\`\`

**2. RDS Cross-Region Read Replica:**
\`\`\`bash
aws rds create-db-instance-read-replica \
 --db-instance-identifier mydb-replica-us-west-2 \
 --source-db-instance-identifier arn:aws:rds:us-east-1:123456789012:db:mydb \
 --db-instance-class db.r5.large \
 --region us-west-2
\`\`\`

**3. ECR Cross-Region Replication:**

- Already covered in Section 1.3
- All images automatically replicated to DR region

**4. ECS Services (Pre-Deployed):**
\`\`\`bash

# In us-west-2, create identical ECS infrastructure

# But set desired count to 0 (standby)

aws ecs update-service \
 --cluster production-cluster \
 --service auth-api-service \
 --desired-count 0 \
 --region us-west-2
\`\`\`

**Failover Procedure:**
\`\`\`markdown

1. Detect us-east-1 failure (Route 53 health check fails)
2. Route 53 automatically routes traffic to us-west-2 (DNS TTL delay)
3. Promote RDS read replica to standalone in us-west-2
4. Scale up ECS services in us-west-2 to production capacity
5. Verify application health
6. Update secrets (if DB endpoint changed)

Time to recovery: 5-15 minutes (mostly DNS propagation)
\`\`\`

**Cost Implications:**

- RDS read replica: ~$200-500/month (depending on instance size)
- ECR replication: Free (storage billed normally)
- ECS services at 0 tasks: $0
- Route 53 health checks: $0.50/month per check
- **Total DR overhead:** ~$200-500/month

**Testing:**

- Quarterly failover drill
- Verify RDS promotion works
- Verify application connects to promoted database
- Measure actual RTO/RPO
```

**Priority:** Medium-High (if 99.99% uptime required), Low (otherwise)  
**Estimated Effort:** 1-2 weeks (initial setup), 1 day quarterly (testing)  
**Owner:** SRE/Platform Team

---

#### 7.2 Active-Active Multi-Region (Advanced)

**Recommendations:**

```markdown
### Active-Active Multi-Region

**When to Use:**

- Global user base (low latency required everywhere)
- 99.999% uptime requirement
- Can handle eventual consistency

**Architecture:**
\`\`\`
Both Regions Active:

- us-east-1: Serves North America traffic
- eu-west-1: Serves Europe traffic
- ap-southeast-1: Serves Asia traffic

Route 53 Geolocation Routing:

- North America → us-east-1
- Europe → eu-west-1
- Asia → ap-southeast-1

Database: Aurora Global Database

- Primary: us-east-1 (writes)
- Read Replicas: eu-west-1, ap-southeast-1
- Cross-region replication: <1 second lag
- Automatic failover to closest region
  \`\`\`

**Challenges:**

- Database writes must go to primary (latency for distant users)
- Data consistency across regions
- Significantly higher cost (3x infrastructure)

**Cost:** 3-5x single-region deployment
```

**Priority:** Low (only for global, mission-critical applications)  
**Estimated Effort:** 3-4 weeks  
**Owner:** Platform Architecture Team

---

## 8. Zero-Downtime Database Migration Strategy

### Status

**Out of Scope** - Database schema evolution during migration

### Why This Matters

If you need to make **breaking schema changes** during the migration (add/remove columns, change data types, refactor tables), you need a strategy to keep both EC2 and Fargate apps working against the same database.

### What's Missing

#### 8.1 Schema Changes During Migration

**Current State:**

- EC2 and Fargate both connect to the same RDS instance
- Schema must be compatible with both versions

**Gaps:**

- [ ] **No strategy for incompatible schema changes**
- [ ] **No rollback plan for failed migrations**
- [ ] **No testing of schema changes under load**

**Recommendations:**

```markdown
### Zero-Downtime Schema Migration Patterns

**Pattern 1: Expand-Contract (Multi-Phase Migration)**

**Phase 1 - Expand (Add New Schema):**
\`\`\`sql
-- Old schema has: users.name (VARCHAR)
-- New schema needs: users.first_name, users.last_name

-- Step 1: Add new columns (nullable)
ALTER TABLE users ADD COLUMN first_name VARCHAR(255);
ALTER TABLE users ADD COLUMN last_name VARCHAR(255);

-- Step 2: Backfill new columns from old column
UPDATE users SET
first_name = SPLIT_PART(name, ' ', 1),
last_name = SPLIT_PART(name, ' ', 2)
WHERE first_name IS NULL;

-- Step 3: Add trigger to keep both in sync during migration
CREATE TRIGGER sync_user_names
BEFORE INSERT OR UPDATE ON users
FOR EACH ROW
EXECUTE FUNCTION sync_name_fields();
\`\`\`

**Phase 2 - Migrate Application:**
\`\`\`javascript
// Old code (EC2) - still works
const user = await db.query('SELECT name FROM users WHERE id = ?', [userId]);

// New code (Fargate) - uses new columns
const user = await db.query(
'SELECT first_name, last_name FROM users WHERE id = ?',
[userId]
);
\`\`\`

**Phase 3 - Contract (Remove Old Schema):**
\`\`\`sql
-- After ALL applications migrated to Fargate:

-- Step 1: Drop trigger
DROP TRIGGER sync_user_names;

-- Step 2: Drop old column
ALTER TABLE users DROP COLUMN name;

-- Step 3: Make new columns NOT NULL
ALTER TABLE users ALTER COLUMN first_name SET NOT NULL;
ALTER TABLE users ALTER COLUMN last_name SET NOT NULL;
\`\`\`

**Pattern 2: Feature Flags for Schema Changes**
\`\`\`javascript
// Application code checks which schema to use
if (process.env.USE_NEW_SCHEMA === 'true') {
// Use first_name, last_name
} else {
// Use name
}

// During migration:
// - EC2: USE_NEW_SCHEMA=false
// - Fargate: USE_NEW_SCHEMA=true
// - After full migration: Remove flag and old code
\`\`\`

**Pattern 3: Database Views (Abstraction Layer)**
\`\`\`sql
-- Create view that works with both old and new schemas
CREATE VIEW users_compat AS
SELECT
id,
COALESCE(name, first_name || ' ' || last_name) AS name,
first_name,
last_name
FROM users;

-- Applications query the view instead of table
-- Works during transition period
-- Drop view after migration complete
\`\`\`

**Pattern 4: Dual Writes (for Critical Changes)**
\`\`\`javascript
// Write to both old and new schema during migration
await db.transaction(async (trx) => {
// Old schema write (for EC2)
await trx('users').update({ name: fullName });

// New schema write (for Fargate)
await trx('users').update({
first_name: firstName,
last_name: lastName
});
});

// After migration: Remove dual writes
\`\`\`

**Testing Schema Migrations:**
\`\`\`bash

# 1. Test in staging with production data clone

pg_dump production_db | psql staging_db

# 2. Run migration scripts

psql staging_db < migration.sql

# 3. Verify data integrity

SELECT COUNT(\*) FROM users WHERE first_name IS NULL;

# 4. Performance test migration on large tables

EXPLAIN ANALYZE UPDATE users SET ...;

# 5. Test rollback procedure

# Always have a rollback script ready!

\`\`\`

**Migration Checklist:**

- [ ] Migration tested in staging
- [ ] Rollback script prepared and tested
- [ ] Database backup taken before migration
- [ ] Migration runs during low-traffic window
- [ ] Monitor query performance during migration
- [ ] Verify application works with new schema
- [ ] Schedule contract phase (remove old columns) for later
```

**Priority:** Medium-High (if schema changes needed), N/A (if schema stable)  
**Estimated Effort:** Variable (depends on complexity)  
**Owner:** Database Team + Application Team

---

#### 8.2 Large Table Migrations (Millions of Rows)

**Recommendations:**

```markdown
### Strategies for Large Tables

**Problem:**

- Table has 100M rows
- ALTER TABLE locks the entire table (downtime)
- Backfill takes hours

**Solution 1: pt-online-schema-change (Percona Toolkit)**
\`\`\`bash

# Non-blocking ALTER for MySQL/MariaDB

pt-online-schema-change \
 --alter "ADD COLUMN first_name VARCHAR(255)" \
 D=mydb,t=users \
 --execute

# How it works:

# 1. Creates new table with new schema

# 2. Copies rows in chunks (non-blocking)

# 3. Uses triggers to keep tables in sync

# 4. Swaps tables atomically

\`\`\`

**Solution 2: Batched Updates (PostgreSQL)**
\`\`\`sql
-- Instead of:
UPDATE users SET first_name = SPLIT_PART(name, ' ', 1); -- Locks entire table

-- Do:
DO $$
DECLARE
batch_size INT := 10000;
offset_val INT := 0;
BEGIN
LOOP
UPDATE users
SET first_name = SPLIT_PART(name, ' ', 1)
WHERE id IN (
SELECT id FROM users
WHERE first_name IS NULL
LIMIT batch_size
);

    IF NOT FOUND THEN
      EXIT;
    END IF;

    COMMIT; -- Release locks between batches
    PERFORM pg_sleep(0.1); -- Throttle to avoid overload

END LOOP;
END $$;
\`\`\`

**Solution 3: Background Job Migration**
\`\`\`javascript
// Queue-based migration for very large tables
async function migrateUsersInBackground() {
const batchSize = 1000;
let offset = 0;

while (true) {
const users = await db('users')
.whereNull('first_name')
.limit(batchSize)
.offset(offset);

    if (users.length === 0) break;

    for (const user of users) {
      await queue.enqueue('migrate-user', { userId: user.id });
    }

    offset += batchSize;
    await sleep(1000); // Rate limit

}
}

// Worker processes queue
queue.process('migrate-user', async (job) => {
const { userId } = job.data;
await db('users')
.where({ id: userId })
.update({
first_name: db.raw("SPLIT_PART(name, ' ', 1)"),
last_name: db.raw("SPLIT_PART(name, ' ', 2)")
});
});
\`\`\`
```

**Priority:** High (if large tables need migration), N/A (if small tables)  
**Estimated Effort:** 3-7 days (planning + execution + validation)  
**Owner:** Database Team

---

## Summary & Prioritization

### Critical (Address Before Production)

- None required for migration (all out of scope)

### High Priority (Address within 3 months)

1. **Disaster Recovery Strategy** - RDS backups, cross-region replication
2. **Compliance Logging** - CloudTrail, VPC Flow Logs (if required)
3. **Circuit Breaker & Retry Logic** - Application resilience

### Medium Priority (Address within 6 months)

1. **AWS Config & GuardDuty** - Security posture management
2. **Certificate Monitoring** - Proactive expiration alerts
3. **Task Definition Backups** - Long-term version control
4. **ECR Cross-Region Replication** - Image disaster recovery

### Low Priority (Nice to Have)

1. **Bulkhead Pattern** - Advanced isolation
2. **Complete DR Runbook** - Annual drill

---

## Next Steps

1. **Review with stakeholders** - Determine which items are required for your use case
2. **Create separate workstreams** - Don't delay migration for these
3. **Schedule post-migration** - Address high-priority items within 3 months of migration
4. **Document decisions** - If skipping an item, document why

---

**Document Version:** 1.0  
**Last Updated:** January 25, 2026  
**Owner:** Platform Engineering Team  
**Review Cycle:** Quarterly

---

### Story 1.2: Plan VPC Endpoints (Optional Cost Optimization)

- **Title:** Evaluate VPC Endpoints to Reduce NAT Gateway Costs
- **Persona:** As a **cloud architect**, I need to understand VPC Endpoint options so that I can reduce data transfer costs and avoid NAT Gateway dependency for AWS service traffic.

- **Requirements:**
  - Identify AWS services the application will call
  - Evaluate cost/benefit of VPC Endpoints vs NAT Gateway
  - Document decision for implementation phase
- **Implementation Details:**
  - **Critical: S3 Gateway Endpoint is FREE and prevents massive NAT costs:**
    - ECR Docker image layers are stored in S3
    - Without S3 Gateway Endpoint, image pulls route through NAT Gateway
    - Large images pulling through NAT can cost $10-50+/month per service
    - S3 Gateway Endpoint has **zero** endpoint cost and **zero** data processing cost
    - **Always create S3 Gateway Endpoint, even if you choose NAT Gateway for other traffic**
  - **Required for Fargate without NAT:**
    - `com.amazonaws.<region>.ecr.api` (ECR API calls)
    - `com.amazonaws.<region>.ecr.dkr` (Docker image pulls)
    - `com.amazonaws.<region>.s3` (ECR stores layers in S3) - Gateway endpoint, free
    - `com.amazonaws.<region>.logs` (CloudWatch Logs)
  - **Commonly needed:**
    - `com.amazonaws.<region>.secretsmanager` (if using Secrets Manager)
    - `com.amazonaws.<region>.ssm` (if using SSM Parameter Store)
  - **Cost comparison:**
    - NAT Gateway: $32/month + $0.045/GB processed
    - Interface Endpoint: ~$7.30/month per endpoint per AZ + $0.01/GB processed
    - For low-traffic apps, VPC Endpoints may be cheaper; for high-traffic, NAT may be simpler

- **Acceptance Criteria:**
  - ✅ List of required AWS services documented
  - ✅ Cost comparison completed for your expected traffic
  - ✅ Decision documented: NAT Gateway vs VPC Endpoints vs hybrid approach

---
