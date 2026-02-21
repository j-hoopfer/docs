# Appendix: How Terraform Import Works

## Overview

Terraform import brings existing infrastructure under Terraform management without recreating it. This appendix explains how import works, common misconceptions, and best practices for brownfield migrations.

---

## What is Terraform Import?

**Terraform import** is a cli command that reads the current state of an existing resource from your cloud provider (AWS, Azure, GCP, etc.) and adds it to Terraform's state file.

**Key Concept:** Import only updates the **state file**, not your **configuration files**.

---

## The Two-Part Nature of Terraform

To understand import, you need to understand that Terraform has two separate components:

### 1. Configuration Files (`.tf` files)

Terraform is declarative, and these files describe the intended goal, rather than the steps to reach that goal. So the contents of these files are the **desired state** - what you want your infrastructure to look like.

```hcl
# vpc.tf - This is what you WANT
resource "aws_vpc" "existing" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "my-vpc"
  }
}
```

### 2. State File (`terraform.tfstate`)

This is the **known state** - what Terraform thinks currently exists in your cloud provider.

```json
{
  "resources": [
    {
      "type": "aws_vpc",
      "name": "existing",
      "instances": [
        {
          "attributes": {
            "id": "vpc-0abc123",
            "cidr_block": "10.0.0.0/16",
            "tags": {
              "Name": "my-vpc"
            }
          }
        }
      ]
    }
  ]
}
```

---

## What Import Does (and Doesn't Do)

### ✅ What Import DOES:

1. **Queries your cloud provider** - Asks AWS "what are the details of vpc-0abc123?"
2. **Writes to state file** - Stores those details in `terraform.tfstate`
3. **Associates state with config** - Links the real resource to your `resource "aws_vpc" "existing"` block

### ❌ What Import DOES NOT DO:

1. **Does NOT create the resource** - The resource must already exist in AWS
2. **Does NOT write configuration** - You must manually write the `.tf` file
3. **Does NOT modify the resource** - Leaves the actual infrastructure untouched
4. **Does NOT generate code** - You write the Terraform code yourself

---

## The Import Workflow

Here's the step-by-step process:

### Step 1: Resource Exists in AWS (Before Terraform)

```
AWS Console: VPC vpc-0abc123 exists
Terraform Config: (empty - no .tf files)
Terraform State: (empty - no state file)
```

### Step 2: Write Terraform Configuration

**You manually write the configuration:**

```hcl
# vpc.tf
resource "aws_vpc" "existing" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "my-vpc"
  }
}
```

```
AWS Console: VPC vpc-0abc123 exists
Terraform Config: vpc.tf (written by you)
Terraform State: (still empty)
```

### Step 3: Run `terraform import`

```bash
terraform import aws_vpc.existing vpc-0abc123
```

**What happens:**

1. Terraform connects to AWS API
2. Asks "what are the details of vpc-0abc123?"
3. AWS responds with all attributes (CIDR, DNS settings, tags, etc.)
4. Terraform writes these details to the state file
5. Links the state entry to your `aws_vpc.existing` resource

```
AWS Console: VPC vpc-0abc123 exists
Terraform Config: vpc.tf (written by you)
Terraform State: Contains details of vpc-0abc123
```

### Step 4: Run `terraform plan`

```bash
terraform plan
```

**What happens:**

1. Terraform reads your config file (`vpc.tf`)
2. Terraform reads the state file
3. Terraform queries AWS for current reality
4. Compares all three: config vs state vs AWS
5. Shows any differences

**Ideal outcome:** `No changes. Your infrastructure matches the configuration.`

**Common outcome:** Shows changes (tags, settings you forgot to include)

### Step 5: Refine Configuration

If `terraform plan` shows changes, you have two options:

**Option A: Update your config to match AWS**

```hcl
# vpc.tf - Add missing attributes
resource "aws_vpc" "existing" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true  # ⬅️ Was missing
  enable_dns_support   = true  # ⬅️ Was missing

  tags = {
    Name        = "my-vpc"
    Environment = "production"  # ⬅️ Was missing
  }
}
```

**Option B: Ignore unimportant differences**

```hcl
# vpc.tf - Ignore attributes you don't care about
resource "aws_vpc" "existing" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "my-vpc"
  }

  lifecycle {
    ignore_changes = [
      tags["CreatedBy"],  # Let AWS auto-tag this
      tags["CreatedAt"],
    ]
  }
}
```

### Step 6: Verify Zero Changes

```bash
terraform plan
# No changes. Your infrastructure matches the configuration.
```

Now Terraform fully manages the resource!

---

## Common Misconceptions

### ❌ Misconception 1: "Import will write my .tf files for me"

**Reality:** You must write the configuration files yourself. Import only updates the state.

**Why?** Terraform can't decide how to organize your code, what to name resources, or what comments to include.

### ❌ Misconception 2: "Import will create the resource"

**Reality:** The resource must already exist. Import is for brownfield (existing) infrastructure.

**Why?** Import is specifically designed to avoid recreating resources that already exist.

### ❌ Misconception 3: "After import, my config must match AWS perfectly"

**Reality:** Your config only needs to specify the attributes you care about managing.

**Why?** Many AWS resources have dozens of optional attributes. You can ignore ones you don't need.

### ❌ Misconception 4: "Import is a one-time command per resource"

**Reality:** If import fails or you remove resources from state, you can re-import.

**Why?** Import is idempotent - running it multiple times with correct IDs is safe.

---

## Import Command Syntax

### Basic Format

```bash
terraform import <resource_type>.<resource_name> <resource_id>
```

**Example:**

```bash
terraform import aws_vpc.existing vpc-0abc123def456
```

**Parts:**

- `aws_vpc.existing` - The address in your `.tf` file (must match exactly)
- `vpc-0abc123def456` - The AWS resource ID (find via CLI or Console)

### Resource-Specific ID Formats

Different resources use different ID formats:

| Resource Type                    | Import ID Format                  | Example                                         |
| -------------------------------- | --------------------------------- | ----------------------------------------------- |
| `aws_vpc`                        | VPC ID                            | `vpc-0abc123`                                   |
| `aws_subnet`                     | Subnet ID                         | `subnet-0abc111`                                |
| `aws_security_group`             | Security Group ID                 | `sg-0abc123`                                    |
| `aws_route_table_association`    | `subnet-id/route-table-id`        | `subnet-0abc111/rtb-0abc222`                    |
| `aws_lb_target_group_attachment` | `target-group-arn/target-id/port` | `arn:aws:elasticloadbalancing:.../i-0abc123/80` |

**Pro tip:** Check Terraform docs for each resource type - import ID format is documented.

---

## The Import-Plan-Refine Loop

Importing infrastructure is an iterative process:

```
1. Write config (best guess)
   ↓
2. Import resource
   ↓
3. Run terraform plan
   ↓
4. See differences?
   ↓
   YES → Update config → Go back to step 3
   ↓
   NO → Done! Move to next resource
```

**This is normal and expected!** Even experienced engineers iterate 3-5 times per resource.

---

## Practical Example: Importing a VPC

### Starting Point

**AWS Reality:** VPC exists with ID `vpc-0abc123`

**Your State:** Empty

### Step 1: Write Initial Config

```hcl
# vpc.tf - First attempt
resource "aws_vpc" "existing" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "production-vpc"
  }
}
```

### Step 2: Import

```bash
terraform import aws_vpc.existing vpc-0abc123
```

Output:

```
Import successful!

The resources that were imported are shown above. These resources are now in
your Terraform state and will henceforth be managed by Terraform.
```

### Step 3: Plan

```bash
terraform plan
```

Output:

```
Terraform will perform the following actions:

  # aws_vpc.existing will be updated in-place
  ~ resource "aws_vpc" "existing" {
        id                       = "vpc-0abc123"
      ~ enable_dns_hostnames     = true -> false  # ⬅️ Difference!
      ~ enable_dns_support       = true -> false  # ⬅️ Difference!
      ~ tags                     = {
          + "Environment" = "production"  # ⬅️ Difference!
            "Name"        = "production-vpc"
        }
        # (other attributes unchanged)
    }

Plan: 0 to add, 1 to change, 0 to destroy.
```

**Translation:** Your config is missing `enable_dns_*` settings and the `Environment` tag.

### Step 4: Refine Config

```hcl
# vpc.tf - Updated to match AWS
resource "aws_vpc" "existing" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true   # ⬅️ Added
  enable_dns_support   = true   # ⬅️ Added

  tags = {
    Name        = "production-vpc"
    Environment = "production"   # ⬅️ Added
  }
}
```

### Step 5: Plan Again

```bash
terraform plan
```

Output:

```
No changes. Your infrastructure matches the configuration.
```

✅ **Success!** The VPC is now fully managed by Terraform.

---

## Advanced Import Scenarios

### Importing Resources with Dependencies

**Problem:** VPC and subnets have a dependency - subnets reference the VPC.

**Solution:** Import in dependency order:

```bash
# 1. Import VPC first
terraform import aws_vpc.existing vpc-0abc123

# 2. Import subnets (they reference aws_vpc.existing.id)
terraform import aws_subnet.public_1a subnet-0abc111
terraform import aws_subnet.public_1b subnet-0abc222
```

**Config:**

```hcl
resource "aws_vpc" "existing" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "public_1a" {
  vpc_id     = aws_vpc.existing.id  # ⬅️ References imported VPC
  cidr_block = "10.0.1.0/24"
}
```

### Importing Resources with Complex IDs

Some resources require composite IDs:

```bash
# Route table association: subnet-id/route-table-id
terraform import aws_route_table_association.public_1a subnet-0abc111/rtb-0abc222

# Target group attachment: target-group-arn/instance-id/port
terraform import aws_lb_target_group_attachment.app \
  arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/app/abc123/i-0abc111/80
```

**How to find the format:** Check Terraform docs for that resource type.

### Handling Import Failures

**Error: "Resource not found"**

```
Error: Cannot import non-existent remote object

While attempting to import an existing object to aws_vpc.existing, the provider
detected that no object exists with the given id.
```

**Solutions:**

1. Verify resource ID is correct (typo in ID?)
2. Check AWS region (resource in different region?)
3. Verify AWS credentials (access to account?)
4. Confirm resource still exists (was it deleted?)

**Error: "Resource already managed by Terraform"**

```
Error: Resource already managed by Terraform

Terraform is already managing a remote object for aws_vpc.existing.
```

**Solutions:**

1. Resource already imported - check `terraform state list`
2. Remove from state first: `terraform state rm aws_vpc.existing`
3. Then re-import

---

## Import vs. Other Approaches

### Alternative 1: Recreate Resources

**When to use:**

- Non-production environments
- Resources that can tolerate downtime
- Simple resources (S3 buckets, IAM roles)

**Pros:**

- Simpler (no import needed)
- Config guaranteed to match reality
- Fresh start, no legacy cruft

**Cons:**

- Causes downtime
- New resource IDs (breaks references)
- May lose data

### Alternative 2: Use `terraform plan -generate-config-out` (Terraform 1.5+)

**Available in Terraform 1.5+:**

```bash
# Import AND generate config in one step
terraform plan -generate-config-out=generated.tf
```

This generates Terraform code from imported resources, reducing manual work.

**Pros:**

- Less manual config writing
- Faster for large imports

**Cons:**

- Generated code may be messy
- Still requires refinement
- Not available in Terraform 1.4 and earlier

### Alternative 3: Use Tools (Terraformer, former2, etc.)

**Third-party tools** can scan AWS and generate both config and state.

**Pros:**

- Automates bulk imports
- Good for large migrations

**Cons:**

- Extra tooling to learn
- Generated code needs cleanup
- May have bugs or limitations

---

## Best Practices

### 1. Start Small

Import one resource at a time, verify it works, then move to the next.

### 2. Use Descriptive Resource Names

```hcl
# ❌ Bad
resource "aws_subnet" "subnet1" { }

# ✅ Good
resource "aws_subnet" "public_1a" { }
```

### 3. Document Resource IDs

Keep a reference file mapping Terraform names to AWS IDs:

```
# network-ids.txt
VPC: vpc-0abc123 → aws_vpc.existing
Public Subnet 1a: subnet-0abc111 → aws_subnet.public_1a
Public Subnet 1b: subnet-0abc222 → aws_subnet.public_1b
```

### 4. Use Scripts for Batch Imports

```bash
# import-network.sh
terraform import aws_vpc.existing vpc-0abc123
terraform import aws_subnet.public_1a subnet-0abc111
terraform import aws_subnet.public_1b subnet-0abc222
# ... etc
```

### 5. Commit After Each Successful Import

```bash
# After VPC import works
git add vpc.tf
git commit -m "feat: import existing VPC"

# After subnet import works
git add subnets.tf
git commit -m "feat: import existing subnets"
```

### 6. Use `lifecycle.ignore_changes` Strategically

```hcl
resource "aws_instance" "app" {
  # ... other config

  lifecycle {
    ignore_changes = [
      ami,              # OS updates happen outside Terraform
      tags["UpdatedBy"], # Auto-updated by scripts
    ]
  }
}
```

### 7. Validate Imports Before Moving On

```bash
# After every import
terraform plan  # Should show "No changes"
terraform fmt   # Format code
terraform validate  # Check syntax
```

---

## Troubleshooting Guide

### Issue: Plan Shows Many Changes After Import

**Cause:** Your config doesn't match AWS reality.

**Solution:**

1. Run `terraform show` to see what's in state
2. Compare with your config
3. Add missing attributes to your config
4. Use `ignore_changes` for attributes you don't care about

### Issue: Import Succeeds But Plan Shows Resource Will Be Destroyed

**Cause:** Resource name or address mismatch.

**Example:**

```hcl
# Config says:
resource "aws_vpc" "main" { }

# But you imported to:
terraform import aws_vpc.existing vpc-123

# These don't match!
```

**Solution:** Make sure resource address matches exactly:

```bash
terraform import aws_vpc.main vpc-123  # Matches config
```

### Issue: Can't Find Resource ID

**Solution:** Use AWS CLI:

```bash
# List all VPCs
aws ec2 describe-vpcs --query 'Vpcs[].[VpcId,Tags[?Key==`Name`].Value|[0]]'

# List all subnets in a VPC
aws ec2 describe-subnets --filters "Name=vpc-id,Values=vpc-123" \
  --query 'Subnets[].[SubnetId,CidrBlock,AvailabilityZone]'
```

### Issue: State Out of Sync After Manual Changes

**Cause:** Someone changed AWS resources outside Terraform.

**Solution:**

```bash
# Refresh state from AWS
terraform apply -refresh-only

# Review what changed
terraform plan
```

---

## Security Considerations

### State Files Contain Sensitive Data

After import, your state file may contain:

- Resource IDs
- IP addresses
- Secrets (if you import resources with embedded secrets)

**Best practices:**

1. Store state in S3 with encryption enabled
2. Enable S3 bucket versioning (for recovery)
3. Use DynamoDB for state locking
4. Restrict IAM access to state bucket
5. Never commit `terraform.tfstate` to Git

### Import Doesn't Validate Credentials

Import uses whatever AWS credentials are configured:

```bash
# Make sure you're in the right account!
aws sts get-caller-identity

# Use correct profile
export AWS_PROFILE=production
terraform import aws_vpc.existing vpc-123
```

---

## Summary

**Terraform import** brings existing infrastructure under Terraform management by:

1. Reading current state from cloud provider (AWS, etc.)
2. Writing that state to `terraform.tfstate`
3. Linking state to your configuration file

**Remember:**

- ✅ Import updates state, not config (you write the `.tf` files)
- ✅ Import is for existing resources (doesn't create new ones)
- ✅ Import is iterative (plan, refine, repeat)
- ✅ Import is safe (doesn't modify actual infrastructure)

**The import workflow:**

```
Write config → Import → Plan → Refine config → Plan → Done
```

**Pro tips:**

- Start with one resource, verify it works
- Use scripts for batch imports
- Commit after each successful import
- Use `ignore_changes` for unimportant attributes
- Check Terraform docs for resource-specific import ID formats

---

## Further Reading

- [Terraform Import Documentation](https://www.terraform.io/cli/import)
- [Terraform State Management](https://www.terraform.io/language/state)
- [Import Block (Terraform 1.5+)](https://www.terraform.io/language/import)
- [AWS Provider Import Guides](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
