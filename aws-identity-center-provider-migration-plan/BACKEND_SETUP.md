# Terraform State Backend Setup Guide

This guide helps you create **shared** S3 and DynamoDB resources for **all** your Terraform projects.

---

## Quick Setup (Run Once)

```bash
# Replace these values
export AWS_ACCOUNT_ID="123456789012"
export COMPANY_NAME="mycompany"
export AWS_REGION="us-east-1"

# Bucket name following best practice
export BUCKET_NAME="terraform-state-${COMPANY_NAME}-${AWS_ACCOUNT_ID}"
export TABLE_NAME="terraform-state-locks"

# 1. Create S3 bucket
aws s3 mb s3://${BUCKET_NAME} --region ${AWS_REGION}

# 2. Enable versioning (allows rollback of state changes)
aws s3api put-bucket-versioning \
  --bucket ${BUCKET_NAME} \
  --versioning-configuration Status=Enabled

# 3. Enable encryption (security best practice)
aws s3api put-bucket-encryption \
  --bucket ${BUCKET_NAME} \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

# 4. Block all public access (critical security)
aws s3api put-public-access-block \
  --bucket ${BUCKET_NAME} \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# 5. Add bucket policy (restrict to your AWS account only)
cat > /tmp/bucket-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyUnencryptedObjectUploads",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::${BUCKET_NAME}/*",
      "Condition": {
        "StringNotEquals": {
          "s3:x-amz-server-side-encryption": "AES256"
        }
      }
    },
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::${BUCKET_NAME}",
        "arn:aws:s3:::${BUCKET_NAME}/*"
      ],
      "Condition": {
        "Bool": {
          "aws:SecureTransport": "false"
        }
      }
    }
  ]
}
EOF

aws s3api put-bucket-policy \
  --bucket ${BUCKET_NAME} \
  --policy file:///tmp/bucket-policy.json

# 6. Enable lifecycle policy (retain old versions for 90 days)
cat > /tmp/lifecycle.json <<EOF
{
  "Rules": [
    {
      "Id": "RetainOldStateVersions",
      "Status": "Enabled",
      "NoncurrentVersionExpiration": {
        "NoncurrentDays": 90
      }
    },
    {
      "Id": "CleanupIncompleteUploads",
      "Status": "Enabled",
      "AbortIncompleteMultipartUpload": {
        "DaysAfterInitiation": 7
      }
    }
  ]
}
EOF

aws s3api put-bucket-lifecycle-configuration \
  --bucket ${BUCKET_NAME} \
  --lifecycle-configuration file:///tmp/lifecycle.json

# 7. Create DynamoDB table for state locking (shared across all projects)
aws dynamodb create-table \
  --table-name ${TABLE_NAME} \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ${AWS_REGION} \
  --tags Key=ManagedBy,Value=Terraform Key=Purpose,Value=StateLocking

# 8. Enable point-in-time recovery for DynamoDB (optional but recommended)
aws dynamodb update-continuous-backups \
  --table-name ${TABLE_NAME} \
  --point-in-time-recovery-specification PointInTimeRecoveryEnabled=true

echo "✅ Setup complete!"
echo "Bucket: ${BUCKET_NAME}"
echo "Table:  ${TABLE_NAME}"
echo ""
echo "Update your backend.tf files:"
echo "  bucket         = \"${BUCKET_NAME}\""
echo "  dynamodb_table = \"${TABLE_NAME}\""
```

---

## Verification

```bash
# Check bucket
aws s3api get-bucket-versioning --bucket ${BUCKET_NAME}
aws s3api get-bucket-encryption --bucket ${BUCKET_NAME}
aws s3api get-public-access-block --bucket ${BUCKET_NAME}

# Check DynamoDB table
aws dynamodb describe-table --table-name ${TABLE_NAME}
```

---

## Project Structure in S3

After running Terraform in multiple projects, your bucket will look like:

```
s3://terraform-state-mycompany-123456789012/
├── identity-center/
│   └── terraform.tfstate                    # This project
├── networking/
│   ├── vpc/terraform.tfstate                # VPC project
│   └── security-groups/terraform.tfstate    # Security groups project
├── compute/
│   ├── ecs/terraform.tfstate                # ECS project
│   └── lambda/terraform.tfstate             # Lambda project
└── security/
    └── guardduty/terraform.tfstate          # GuardDuty project
```

Each project uses a **unique key path** but the **same bucket and DynamoDB table**.

---

## IAM Permissions Required

The AWS user/role running Terraform needs these permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::terraform-state-COMPANY-ACCOUNT-ID",
        "arn:aws:s3:::terraform-state-COMPANY-ACCOUNT-ID/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"],
      "Resource": "arn:aws:dynamodb:us-east-1:ACCOUNT-ID:table/terraform-state-locks"
    }
  ]
}
```

---

## Using the Backend in Other Projects

When you create new Terraform projects, use the same backend config:

```hcl
# Any new project's backend.tf
terraform {
  backend "s3" {
    bucket         = "terraform-state-mycompany-123456789012"  # SAME bucket
    key            = "new-project/terraform.tfstate"           # DIFFERENT key
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-locks"                   # SAME table
  }
}
```

---

## Disaster Recovery

### Restore Previous State Version

```bash
# List all versions
aws s3api list-object-versions \
  --bucket terraform-state-mycompany-123456789012 \
  --prefix identity-center/terraform.tfstate

# Download specific version
aws s3api get-object \
  --bucket terraform-state-mycompany-123456789012 \
  --key identity-center/terraform.tfstate \
  --version-id <VERSION-ID> \
  restored-state.tfstate

# Restore it
mv restored-state.tfstate terraform.tfstate
terraform init -reconfigure
```

### Unlock Stuck State

```bash
# If Terraform crashes and leaves a lock
terraform force-unlock <LOCK-ID>
```

---

## Cost Estimation

**Typical monthly cost for shared resources:**

| Resource       | Usage                   | Cost             |
| -------------- | ----------------------- | ---------------- |
| S3 Bucket      | ~1 MB total state files | $0.02/month      |
| S3 Versioning  | 100 versions × 10 KB    | $0.002/month     |
| DynamoDB Table | PAY_PER_REQUEST mode    | $0.01/month      |
| **Total**      |                         | **~$0.03/month** |

Sharing resources across 10+ projects = same cost as one project.

---

## Security Checklist

- [x] Versioning enabled (recovery from mistakes)
- [x] Encryption enabled (data at rest)
- [x] Public access blocked (no internet exposure)
- [x] Bucket policy enforces HTTPS (data in transit)
- [x] Lifecycle policy (automatic cleanup)
- [x] DynamoDB PITR enabled (backup)
- [ ] CloudTrail logging state file access
- [ ] AWS Backup for additional protection

---

## Troubleshooting

### Error: "bucket does not exist"

```bash
# Check if bucket exists
aws s3 ls s3://terraform-state-mycompany-123456789012

# If not, run setup script above
```

### Error: "table does not exist"

```bash
# Check if table exists
aws dynamodb describe-table --table-name terraform-state-locks

# If not, create it:
aws dynamodb create-table \
  --table-name terraform-state-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

### Error: "Error acquiring the state lock"

```bash
# Someone else is running Terraform, or previous run crashed
# Wait for their run to finish, or force unlock:
terraform force-unlock <LOCK-ID>
```

---

## Questions?

Contact: infra-team@company.com
