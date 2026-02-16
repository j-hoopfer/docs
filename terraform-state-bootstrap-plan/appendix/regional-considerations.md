# Appendix: Regional Considerations

Strategies for managing Terraform state across multiple AWS regions.

## Multi-Region State Strategy

### Key Principle: Resources are Regional, State is Centralized

**State Bucket Location:** Primary region only (e.g., `us-east-1`)  
**State Organization:** Use S3 key prefixes to separate regions

```
s3://mycompany-terraform-state-prod/
├── us-east-1/
│   ├── 00-network/terraform.tfstate
│   └── 10-application/terraform.tfstate
├── us-west-2/
│   ├── 00-network/terraform.tfstate
│   └── 10-application/terraform.tfstate
└── global/
    └── iam/terraform.tfstate
```

## Why Centralized State?

**Benefits:**

- ✅ **Single DynamoDB table** for all locks (simpler management)
- ✅ **Lower cost** (no duplicate buckets per region)
- ✅ **State bucket location is independent** of resource location
- ✅ **Simplified backup** and disaster recovery

**Trade-offs:**

- ❌ State bucket outage in primary region blocks all deployments
- ❌ Cross-region latency for state operations (typically minimal)

## Why Regional Folders?

**Isolation Benefits:**

- **Blast radius isolation**: `us-east-1` failures don't block `us-west-2` deployments
- **Clear separation** of regional infrastructure
- **Terraform can still operate** on one region if another region's AWS APIs are degraded
- **Easier troubleshooting** (clear which state file manages which region)

## Global Resources

**IAM, Route53, CloudFront** are global AWS services.

**Best Practice:** Store state in `global/` folder (not region-specific).

**Example:**

```
s3://mycompany-terraform-state-prod/
├── global/
│   ├── iam/terraform.tfstate          # IAM roles, policies, users
│   ├── route53/terraform.tfstate      # DNS zones and records
│   └── cloudfront/terraform.tfstate   # CDN distributions
├── us-east-1/
│   └── ...
└── us-west-2/
    └── ...
```

**Manage from primary region only** to avoid conflicting updates.

## Backend Configuration Example

### Regional Resource (VPC in us-east-1)

```hcl
terraform {
  backend "s3" {
    bucket         = "mycompany-terraform-state-prod"
    key            = "us-east-1/00-network/terraform.tfstate"  # Region prefix
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "mycompany-terraform-locks"
  }
}
```

### Regional Resource (VPC in us-west-2)

```hcl
terraform {
  backend "s3" {
    bucket         = "mycompany-terraform-state-prod"
    key            = "us-west-2/00-network/terraform.tfstate"  # Different region prefix
    region         = "us-east-1"  # State bucket region (stays the same)
    encrypt        = true
    dynamodb_table = "mycompany-terraform-locks"
  }
}
```

### Global Resource (IAM)

```hcl
terraform {
  backend "s3" {
    bucket         = "mycompany-terraform-state-prod"
    key            = "global/iam/terraform.tfstate"  # Global prefix
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "mycompany-terraform-locks"
  }
}
```

## Alternative: Regional State Buckets

Some organizations prefer separate state buckets per region for **complete regional isolation**.

```
Account: mycompany-prod
├── S3 Bucket: mycompany-terraform-state-us-east-1 (in us-east-1)
│   └── network/terraform.tfstate
└── S3 Bucket: mycompany-terraform-state-us-west-2 (in us-west-2)
    └── network/terraform.tfstate
```

**When to use:**

- Strict regional compliance requirements
- Need to survive complete region outage
- Organization prioritizes blast radius minimization over simplicity

**Trade-offs:**

- More buckets to manage
- Higher cost
- Separate DynamoDB lock tables per region
- More complex bootstrap process
