# Disaster Recovery & Backup Strategy

### Goal

Define RTO (Recovery Time Objective) and RPO (Recovery Point Objective) for the new containerized stack, ensuring business continuity in the event of a catastrophic regional failure.

### Context

Moving compute to Fargate changes the disaster recovery landscape. We no longer back up AMIs; instead, we must ensure ECR image replication and RDS snapshot availability across regions.

## Status

**Out of Scope** - To be addressed in a separate DR planning workstream

## Why This Matters

While the migration establishes infrastructure for running applications on Fargate, it doesn't establish comprehensive disaster recovery procedures for catastrophic failures (region outage, accidental deletion, data corruption).

## What's Missing

### 1.1 RDS Backup and Recovery Strategy

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

**Priority:** High  
**Estimated Effort:** 2-3 days  
**Owner:** Database/SRE Team

---

### 1.2 ECS Task Definition Version Control

**Current State:**

- Task definitions stored in AWS (each revision creates a new version)
- GitHub Actions creates new revisions on each deployment

**Gaps:**

- [ ] **No long-term storage of task definitions** - AWS may purge old revisions
- [ ] **No backup of task definition history** outside AWS
- [ ] **Dependency on AWS Console for rollback**

**Recommendations:**

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
      s3://my-company-ecs-task-definitions/${{ env.ECS_SERVICE }}/$(date +%Y-%m-%d)-${{ github.sha }}.json
```

**Priority:** Medium
**Estimated Effort:** 1 day
**Owner:** Platform Team

---

### 1.3 ECR Image Disaster Recovery

**Current State:**

- ECR images stored in us-east-1 only
- Lifecycle policies delete old images

**Gaps:**

- [ ] **No cross-region replication** - Regional failure = no images
- [ ] **No long-term archive** of critical image versions
- [ ] **No plan for rebuilding images** if ECR data lost

**Recommendations:**

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
```

**Long-Term Archive:**

- Tag production releases: `release-2024-01-25`, `stable-v1.2.3`
- Lifecycle policy: Never expire images with `release-*` or `stable-*` tags
- Export critical images to S3 (compressed tar.gz) for compliance

**Source Code as Backup:**

- All images rebuildable from Git commits
- Document build instructions in README
- Tag Git commits with deployed image SHA

**Priority:** Medium-High
**Estimated Effort:** 1-2 days
**Owner:** Platform Team

---

### 1.4 Secrets Manager Disaster Recovery

**Current State:**

- Secrets stored in AWS Secrets Manager (us-east-1)
- Encrypted with AWS managed KMS key

**Gaps:**

- [ ] **No cross-region replication** - DR failover would require recreating secrets
- [ ] **No backup export** of secret values (for complete AWS failure scenario)
- [ ] **Secret restoration procedure not documented**

**Recommendations:**

### Secrets Disaster Recovery

**Cross-Region Replication:**

- Enable Secrets Manager replication to us-west-2
- Automatic sync on secret value changes

**Configuration:**

```bash
aws secretsmanager replicate-secret-to-regions \
  --secret-id production/auth-api/database \
  --add-replica-regions Region=us-west-2
```

**Emergency Secret Backup (Controversial but Pragmatic):**

- Store encrypted backup of critical secrets in secure S3 bucket
- Encryption: GPG with key stored in hardware security module
- Use only for complete AWS failure scenario
- Rotate secrets after any use of backup

**Alternative (Preferred):**

- Source of truth for secrets in external vault (HashiCorp Vault, 1Password Secrets)
- Secrets Manager populated from external source
- DR = repopulate from vault

**Priority:** Medium
**Estimated Effort:** 2 days
**Owner:** Security Team

---

### 1.5 Infrastructure as Code Recovery

**Current State:**

- VPC, ALB, ECS Cluster created manually or via Terraform (if implemented)
- Configuration not fully documented

**Gaps:**

- [ ] **Complete infrastructure rebuild procedure not documented**
- [ ] **No tested "environment from scratch" process**
- [ ] **Manual dependencies not captured in IaC**

**Recommendations:**

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

**Priority:** High  
**Estimated Effort:** 3-5 days (initial), 1 day quarterly (testing)  
**Owner:** SRE/Platform Team

---

### 1.6 Complete DR Runbook

**Recommendations:**

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

**Priority:** High  
**Estimated Effort:** 5 days (documentation + quarterly testing)  
**Owner:** SRE Team
