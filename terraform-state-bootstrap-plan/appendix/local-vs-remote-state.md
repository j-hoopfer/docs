# Appendix: Local vs Remote State for Bootstrap

## Understanding What "State Migration" Actually Means

**Common Confusion:** "I thought state was already in S3?"

This is a frequent source of confusion because there are **two different things** both called "state":

1. **The S3 bucket resource that contains state across the estate** (created in Phase 3/5) - This IS in AWS
2. **The state file tracking the bucket that contains the state** (created by Terraform) - This is LOCAL until Phase 6

### What You Created in Phase 3/5

When you ran `terraform apply`, you created real AWS resources:

```bash
cd accounts/dev
terraform apply
# Creates in AWS:
# ✅ S3 bucket: mycompany-terraform-state-dev
# ✅ DynamoDB table: mycompany-terraform-locks
# ✅ IAM policy: terraform-state-access-dev
```

These resources exist in AWS. You can see them in the console.

### What's Still on Your Laptop

But Terraform also created a **state file** to track those resources:

```
accounts/dev/terraform.tfstate  ← LOCAL file on your laptop
```

This file contains the tracking data about the S3 bucket. The bucket is in AWS, but the **tracking data** is local.

### The Warehouse Analogy

- **S3 bucket** = A warehouse building (physical infrastructure in AWS)
- **State file** = An inventory list of what's in the warehouse (tracking data)

You built the warehouse in Phase 3. It's real, it exists in AWS. But your inventory list is still on a clipboard in your hand (local state).

**Phase 6 moves the inventory list INTO the warehouse** (remote state).

### Before and After

**Before Phase 6:**

```
Your Laptop: terraform.tfstate (local)
AWS: S3 bucket exists but is EMPTY (waiting for projects to use it)
```

**After Phase 6:**

```
Your Laptop: No state file
AWS: S3 bucket contains bootstrap/terraform.tfstate (self-hosted)
```

The S3 bucket was always in AWS. Phase 6 migrates **the file that TRACKS that bucket** from your laptop to S3.

---

## Should You Migrate? (Phase 6 Decision)

**Question:** Do I need to migrate the bootstrap project itself to remote state (Phase 6)?

**Answer:** It depends on your team structure and maintenance expectations.

## Option 1: Keep Bootstrap State Local (Simpler)

**How it works:**

- Bootstrap runs once per account with local `terraform.tfstate` files
- State files committed to Git (or stored securely by single admin)
- Infrastructure projects use remote state, but bootstrap uses local

**Workflow if you need to modify bootstrap resources:**

```bash
# 1. Clone repository
git clone git@github.com:mycompany/mycompany-terraform-bootstrap.git
cd mycompany-terraform-bootstrap/accounts/dev

# 2. Pull latest state from Git
git pull origin main
# Local terraform.tfstate file is now current

# 3. Configure AWS credentials
export AWS_PROFILE=mycompany-dev
aws sts get-caller-identity

# 4. Make changes
vim main.tf  # Example: Increase lifecycle retention to 180 days

# 5. Apply
terraform plan
terraform apply

# 6. Commit updated state to Git
git add terraform.tfstate
git commit -m "Increase state file retention to 180 days"
git push origin main
```

**Pros:**

- ✅ Simpler - no backend migration needed
- ✅ No circular dependency (bootstrap doesn't depend on itself)
- ✅ Fast - no S3 state downloads
- ✅ Works offline (state is local)

**Cons:**

- ❌ State in Git (though bootstrap state contains no secrets)
- ❌ No state locking - only one person can modify at a time
- ❌ Manual coordination if multiple engineers need to modify

**When to use:**

- Single platform engineer manages bootstrap
- Bootstrap infrastructure rarely changes
- Team is comfortable with state in Git

---

## Option 2: Migrate Bootstrap to Remote State (Phase 3)

**How it works:**

- Bootstrap runs once, then migrated to S3
- State stored in `s3://mycompany-terraform-state-{env}/bootstrap/terraform.tfstate`
- Same workflow as infrastructure projects

**Workflow if you need to modify bootstrap resources:**

```bash
# 1. Clone repository
git clone git@github.com:mycompany/mycompany-terraform-bootstrap.git
cd mycompany-terraform-bootstrap/accounts/dev

# 2. Configure AWS credentials
export AWS_PROFILE=mycompany-dev
aws sts get-caller-identity

# 3. Initialize (downloads state from S3)
terraform init

# 4. Make changes
vim main.tf  # Example: Increase lifecycle retention to 180 days

# 5. Apply (with DynamoDB locking)
terraform plan
terraform apply
# State automatically uploaded to S3

# 6. Commit code changes (NOT state)
git add main.tf
git commit -m "Increase state file retention to 180 days"
git push origin main
```

**Pros:**

- ✅ State locking prevents concurrent modifications
- ✅ State versioning in S3 (disaster recovery)
- ✅ Consistent workflow with infrastructure projects
- ✅ Multiple engineers can collaborate

**Cons:**

- ❌ More complex - requires migration step
- ❌ Circular dependency (bootstrap manages its own state storage)
- ❌ Requires AWS connectivity to work
- ❌ Additional 15-30 minutes per account

**When to use:**

- Multiple platform engineers manage bootstrap
- Bootstrap changes frequently
- Need audit trail and state history
- Team prefers consistency (everything in S3)

---

## Comparison Table

| Factor                | Local State         | Remote State       |
| --------------------- | ------------------- | ------------------ |
| **Setup Time**        | 2-3 hours           | 3-4 hours          |
| **Collaboration**     | Manual coordination | Automatic locking  |
| **State Location**    | Git repository      | S3 bucket          |
| **State History**     | Git commits         | S3 versioning      |
| **Disaster Recovery** | Git restore         | S3 version restore |
| **Offline Work**      | ✅ Yes              | ❌ No              |
| **State Locking**     | ❌ No               | ✅ Yes             |
| **Complexity**        | Low                 | Medium             |

---

## Recommendation

**For most teams:** Start with **local state** (skip Phase 3).

- Bootstrap infrastructure is stable (rarely changes)
- Simpler to understand and maintain
- If collaboration becomes an issue later, migrate then

**For large teams:** Use **remote state** (complete Phase 3).

- Multiple platform engineers
- Frequent bootstrap infrastructure changes
- Need compliance audit trail

**You can always migrate later** - Phase 3 can be completed months after initial bootstrap if needs change.
