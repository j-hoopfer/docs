# Appendix: State Storage Strategies

**Question:** Should Terraform state be stored in the same account as the resources, or centralized in a single account (typically Prod)?

**Answer:** Both approaches are valid. Choose based on your organization's priorities.

---

## Strategy 1: State in Same Account (Default Plan)

**Architecture:**

```
Dev Account                      Prod Account
├─ Dev Resources                 ├─ Prod Resources
└─ Dev State Bucket              └─ Prod State Bucket
   └─ Stores Dev resource state     └─ Stores Prod resource state
```

**How It Works:**

- Dev engineers deploy to Dev account using Dev state bucket
- Prod engineers deploy to Prod account using Prod state bucket
- Each account's state is isolated within that account

**Backend Configuration Example:**

```hcl
# Dev infrastructure project
terraform {
  backend "s3" {
    bucket         = "mycompany-terraform-state-dev"  # In Dev account
    key            = "us-east-1/vpc/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "mycompany-terraform-locks"
  }
}

# Prod infrastructure project
terraform {
  backend "s3" {
    bucket         = "mycompany-terraform-state-prod"  # In Prod account
    key            = "us-east-1/vpc/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "mycompany-terraform-locks"
  }
}
```

### Pros

✅ **Account Isolation**

- Dev account compromise doesn't expose Prod state
- Blast radius limited to single account
- Clear security boundary

✅ **Independent Operations**

- Dev team can deploy without Prod account access
- Prod bucket outage doesn't block Dev work
- No cross-account IAM complexity

✅ **Simpler IAM**

- Engineers only need permissions in accounts they manage
- No AssumeRole or cross-account policies required
- Easier to audit and troubleshoot

✅ **Faster Deployments**

- No cross-account API calls
- Lower latency for state operations
- Reduced AWS API throttling risk

### Cons

❌ **Multiple Buckets to Manage**

- Need to bootstrap each account
- Separate backup/DR procedures per account
- More infrastructure to maintain

❌ **State in Lower-Security Accounts**

- Dev state bucket has less strict controls than Prod
- Dev engineers have write access to Dev state
- Potential for accidental state corruption in Dev

❌ **Harder Cross-Account References**

- Can't easily use `terraform_remote_state` across accounts
- Need to use SSM Parameter Store or data sources instead

### When to Use

- **Small to medium teams** where simplicity matters
- **Strong account isolation** is a priority
- Dev and Prod managed by **different teams**
- You want **independent failure domains**
- Organization has **multiple AWS accounts** with different security postures

---

## Strategy 2: Centralized State in Prod

**Architecture:**

```
Dev Account                      Prod Account
├─ Dev Resources                 ├─ Prod Resources
└─ (No state bucket)             ├─ Prod State Bucket
                                 │  ├─ Prod resource state
                                 │  └─ Dev resource state ←─┐
                                 └────────────────────────────┘
                                       ↑
                                       │
                        Dev engineers use cross-account access
```

**How It Works:**

- Only Prod account has state infrastructure (S3 + DynamoDB)
- Dev engineers assume role to access Prod state bucket
- All state files stored centrally in the most secure account

**Backend Configuration Example:**

```hcl
# Dev infrastructure project
terraform {
  backend "s3" {
    bucket         = "mycompany-terraform-state-prod"  # In Prod account!
    key            = "dev/us-east-1/vpc/terraform.tfstate"  # Separate prefix
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "mycompany-terraform-locks"
    role_arn       = "arn:aws:iam::222222222222:role/dev-terraform-state-access"
  }
}

# Prod infrastructure project
terraform {
  backend "s3" {
    bucket         = "mycompany-terraform-state-prod"  # Same bucket
    key            = "prod/us-east-1/vpc/terraform.tfstate"  # Different prefix
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "mycompany-terraform-locks"
  }
}
```

**Required IAM Setup:**

```hcl
# In Prod account: Create assumable role for Dev engineers
resource "aws_iam_role" "dev_terraform_state_access" {
  name = "dev-terraform-state-access"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::333333333333:root"  # Dev account
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Attach policy allowing state bucket access
resource "aws_iam_role_policy_attachment" "dev_state_access" {
  role       = aws_iam_role.dev_terraform_state_access.name
  policy_arn = aws_iam_policy.terraform_state_access.arn
}

# Update bucket policy to allow cross-account access
resource "aws_s3_bucket_policy" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowDevAccountAccess"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.dev_terraform_state_access.arn
        }
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.terraform_state.arn}/dev/*"  # Limit to dev/ prefix
      }
    ]
  })
}
```

### Pros

✅ **Single Source of Truth**

- All state in one highly-secured location
- Simplified backup and disaster recovery
- Easier to implement organization-wide state retention policies

✅ **Enhanced Security**

- State stored in the most secure account (Prod)
- Dev account compromise doesn't expose state files
- Prod security controls apply to all state

✅ **Easier Cross-Account References**

- Can use `terraform_remote_state` data source across environments
- Simplified output sharing between Dev and Prod
- Single bucket for state locking

✅ **Simplified Infrastructure**

- Only one state bucket to manage
- Reduced bootstrap complexity (bootstrap Prod only)
- Lower cost (one bucket vs multiple)

### Cons

❌ **Complex IAM Setup**

- Need cross-account AssumeRole policies
- Bucket policies must allow cross-account access
- More complex to troubleshoot permissions issues

❌ **Prod Becomes Dependency**

- Prod state bucket outage blocks all deployments
- Dev engineers need (limited) access to Prod account
- Creates coupling between environments

❌ **Potential Security Concerns**

- Dev engineers have IAM path to Prod account
- Risk of misconfigured bucket policies exposing Prod state
- Need careful IAM boundary management

❌ **Slower Dev Deployments**

- Cross-account API calls add latency
- AssumeRole token expiration issues
- Potential AWS API throttling

### When to Use

- **Large enterprises** with dedicated security teams
- **Strict compliance requirements** (SOC2, PCI-DSS, HIPAA)
- You need **centralized audit logs** for all state changes
- **Mature DevOps practice** comfortable with cross-account IAM
- Organization prioritizes **security over independence**
- Limited number of environments (2-3 max)

---

## Comparison Matrix

| Factor                             | Same Account              | Centralized in Prod    |
| ---------------------------------- | ------------------------- | ---------------------- |
| **Setup Complexity**               | Low                       | Medium-High            |
| **IAM Complexity**                 | Low                       | High                   |
| **Security Posture**               | Account-isolated          | Centrally secured      |
| **Blast Radius**                   | Limited to account        | All environments       |
| **Dev Independence**               | ✅ Full                   | ❌ Depends on Prod     |
| **Backup Strategy**                | Per-account               | Centralized            |
| **Cross-Account State References** | ❌ Difficult              | ✅ Easy                |
| **Troubleshooting**                | Easy                      | Complex (IAM paths)    |
| **Cost**                           | Higher (multiple buckets) | Lower (single bucket)  |
| **Deployment Speed**               | Fast                      | Slower (cross-account) |
| **Best For**                       | Small-medium teams        | Large enterprises      |

---

## Decision Guide

**Choose Same-Account Strategy (Default) if:**

- ✅ Dev and Prod are managed by different teams
- ✅ You want strong environment isolation
- ✅ Your team is small-to-medium size (<20 engineers)
- ✅ Simplicity and maintainability are priorities
- ✅ Dev outages shouldn't affect Prod operations

**Choose Centralized Strategy if:**

- ✅ You have strict security/compliance requirements
- ✅ You have a mature DevOps team comfortable with complex IAM
- ✅ You need cross-environment state references
- ✅ You want centralized state governance
- ✅ You have dedicated security/compliance team

---

## Migration Between Strategies

You can change strategies later if needs evolve:

**Same-Account → Centralized:**

1. Bootstrap Prod account
2. Copy Dev state files from Dev bucket to Prod bucket (under `dev/` prefix)
3. Update Dev backend configs to point to Prod bucket with `role_arn`
4. Run `terraform init -migrate-state` in all Dev projects
5. Verify state migration successful
6. Delete Dev account state bucket

**Centralized → Same-Account:**

1. Bootstrap Dev account
2. Copy Dev state files from Prod bucket to Dev bucket
3. Update Dev backend configs to remove `role_arn` and use Dev bucket
4. Run `terraform init -migrate-state` in all Dev projects
5. Verify state migration successful
6. Clean up cross-account IAM roles

**Migration Time:** 2-4 hours per environment

---

## Recommendation

**For MyCompany:** Start with **same-account strategy** (the current plan).

**Rationale:**

- Simpler to implement and understand
- Easier for team to learn Terraform without IAM complexity
- Provides strong isolation between Dev and Prod
- Can migrate to centralized approach later if compliance requires it

**Re-evaluate if:**

- You achieve SOC2 or similar compliance certification
- Team grows beyond 20 engineers
- You need extensive cross-environment state references
- Security team mandates centralized state governance
