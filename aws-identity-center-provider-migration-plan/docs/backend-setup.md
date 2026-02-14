# Terraform Backend Setup Guide

**One-time setup in the AWS Management Account** to create S3 bucket and DynamoDB table for Identity Center Terraform state.

> **Note:** For architectural overview and backend strategy, see the [README](../README.md#critical-understanding).

---

## Setup Steps

Run these commands **once** in your **AWS Management Account**:

### Step 1: Configure AWS Credentials

```bash
# Set AWS credentials for MANAGEMENT account
export AWS_PROFILE=management  # Or whatever you named your management account profile

# Verify you're in the correct account
aws sts get-caller-identity
# Expected output should show your Management Account ID

# Set variables
export MGMT_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET_NAME="terraform-state-identity-center-${MGMT_ACCOUNT_ID}"
export TABLE_NAME="terraform-state-locks"
export AWS_REGION="us-east-1"

echo "Creating backend in Management Account: ${MGMT_ACCOUNT_ID}"
```

### Step 2: Create S3 Bucket

```bash

# 1. Create S3 bucket
aws s3 mb s3://${BUCKET_NAME} --region ${AWS_REGION}

# 2. Enable versioning (allows state rollback)
aws s3api put-bucket-versioning \
  --bucket ${BUCKET_NAME} \
  --versioning-configuration Status=Enabled

# 3. Enable encryption
aws s3api put-bucket-encryption \
  --bucket ${BUCKET_NAME} \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

# 4. Block all public access
aws s3api put-public-access-block \
  --bucket ${BUCKET_NAME} \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# 5. Add bucket policy (enforce encryption and HTTPS)
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
```

### Step 3: Create DynamoDB Table

```bash
# Create DynamoDB table for state locking
aws dynamodb create-table \
  --table-name ${TABLE_NAME} \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ${AWS_REGION} \
  --tags Key=ManagedBy,Value=Terraform Key=Purpose,Value=IdentityCenterStateLocking

# Enable point-in-time recovery for DynamoDB
aws dynamodb update-continuous-backups \
  --table-name ${TABLE_NAME} \
  --point-in-time-recovery-specification PointInTimeRecoveryEnabled=true

echo "✅ Management account backend setup complete!"
echo "   Bucket: ${BUCKET_NAME}"
echo "   Table: ${TABLE_NAME}"
echo "   Region: ${AWS_REGION}"
```

---

## Update Backend Configuration

After creating the resources, update `identity-center/backend.tf` with your Management Account ID:

```terraform
terraform {
  backend "s3" {
    bucket         = "terraform-state-identity-center-123456789012"  # Replace with your MGMT account ID
    key            = "identity-center/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-locks"
  }
}
```

---

## Verification

Test that the backend resources work:

```bash
# Verify S3 bucket exists and is accessible
aws s3 ls s3://${BUCKET_NAME}

# Verify DynamoDB table exists
aws dynamodb describe-table --table-name ${TABLE_NAME} --query 'Table.TableStatus'

# Test writing to bucket
echo "test" > /tmp/test.txt
aws s3 cp /tmp/test.txt s3://${BUCKET_NAME}/test.txt
aws s3 rm s3://${BUCKET_NAME}/test.txt

echo "✅ Backend verification complete!"
```

---

## State File Organization

The S3 bucket can organize state for multiple organization-level projects:

```
s3://terraform-state-identity-center-MGMT-ACCT-ID/
├── identity-center/terraform.tfstate           # This project
├── organization/scp-policies/terraform.tfstate # Future: Service Control Policies
├── organization/accounts/terraform.tfstate     # Future: AWS account provisioning
└── security/cloudtrail/terraform.tfstate       # Future: Organization-wide CloudTrail
```

All organization-level projects share:

- Same S3 bucket (different keys)
- Same DynamoDB table (different lock IDs)

---

## Cost Estimate

**Management account backend costs:**

| Resource       | Usage                | Cost             |
| -------------- | -------------------- | ---------------- |
| S3 Bucket      | ~1 MB state files    | $0.02            |
| S3 Versioning  | 100 versions × 10 KB | $0.002           |
| DynamoDB Table | PAY_PER_REQUEST      | $0.01            |
| **Total**      |                      | **~$0.03/month** |

**Identity Center itself is free** (no additional charge beyond AWS accounts managed).

---

## Disaster Recovery

### Restore Previous State Version

```bash
# List all versions of state file
aws s3api list-object-versions \
  --bucket terraform-state-identity-center-${MGMT_ACCOUNT_ID} \
  --prefix identity-center/terraform.tfstate

# Download specific version
aws s3api get-object \
  --bucket terraform-state-identity-center-${MGMT_ACCOUNT_ID} \
  --key identity-center/terraform.tfstate \
  --version-id <VERSION-ID> \
  restored-state.tfstate

# Restore by uploading as current version
aws s3 cp restored-state.tfstate \
  s3://terraform-state-identity-center-${MGMT_ACCOUNT_ID}/identity-center/terraform.tfstate
```

If Terraform crashes during execution:

```bash
terraform force-unlock <LOCK-ID>
```

---

## IAM Permissions Required

Engineers deploying Identity Center Terraform need these permissions **in the Management Account**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformStateAccess",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetObject", "s3:PutObject"],
      "Resource": [
        "arn:aws:s3:::terraform-state-identity-center-MGMT-ACCT-ID",
        "arn:aws:s3:::terraform-state-identity-center-MGMT-ACCT-ID/*"
      ]
    },
    {
      "Sid": "TerraformStateLocking",
      "Effect": "Allow",
      "Action": ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"],
      "Resource": "arn:aws:dynamodb:us-east-1:MGMT-ACCT-ID:table/terraform-state-locks"
    },
    {
      "Sid": "IdentityCenterManagement",
      "Effect": "Allow",
      "Action": ["sso:*", "sso-admin:*", "identitystore:*"],
      "Resource": "*"
    }
  ]
}
```

Replace `MGMT-ACCT-ID` with your Management Account ID.

---

## Next St`identity-center/backend.tf` with your Management Account ID

2. Initialize Terraform: `terraform init
   After backend setup:

1. Update [backend.hcl](../backend.hcl) with your Management Account ID
1. Initialize Terraform: `terraform init -backend-config=../backend.hcl`
1. Review [daily-workflow.md](daily-workflow.md) for deployment procedures
1. Set up CI/CD: [github-actions-cicd.md](github-actions-cicd.md)

---

## Troubleshooting

**"Bucket already exists" error:**

- Check if bucket was created previously
- Bucket names are globally unique - try different name pattern

**"Access Denied" when creating bucket:**

- Verify AWS credentials: `aws sts get-caller-identity`
- Check IAM permissions in `backend.tf` matches bucket name
- Check `terraform init` was run successfully
  **State file not found:**

- Verify backend config matches bucket name
- Check `terraform init` was run with correct `-backend-config` flag
- Ensure backend key path matches module directory

**Lock timeout:**

- Another user is running Terraform
- Or previous run crashed - use `terraform force-unlock`
