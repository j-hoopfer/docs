# Appendix: Adding Prod Account After Starting with Dev

**Scenario:** You bootstrapped the Dev account first and now have approval to create a Prod account.

**Good News:** The migration path is straightforward because each AWS account's bootstrap infrastructure is completely independent.

## Key Principles

- **Account Isolation:** Each AWS account has its own S3 bucket and DynamoDB table
- **No Dependencies:** Prod bootstrap doesn't depend on Dev infrastructure existing
- **Same Process:** Use the exact same bootstrap process you used for Dev
- **Zero Downtime:** Dev infrastructure continues working while you bootstrap Prod

## Migration Steps

1. **Ensure Dev is stable** - Verify Dev bootstrap is complete and working

   ```bash
   # In Dev account
   aws s3 ls s3://mycompany-terraform-state-dev/
   aws dynamodb describe-table --table-name mycompany-terraform-locks
   ```

2. **Bootstrap Prod account** - Follow [Phase 3: Bootstrap Prod Account](../phase/phase-3-bootstrap-prod.md)

   ```bash
   cd mycompany-terraform-bootstrap/accounts
   cp -r dev prod
   cd prod
   # Update terraform.tfvars with Prod account ID
   # Switch to Prod AWS credentials
   terraform init
   terraform apply
   ```

3. **Verify isolation** - Confirm resources created in correct account

   ```bash
   # Check Prod resources
   export AWS_PROFILE=mycompany-prod
   aws s3 ls | grep mycompany-terraform-state-prod
   aws dynamodb list-tables | grep mycompany-terraform-locks

   # Verify Dev still intact
   export AWS_PROFILE=mycompany-dev
   aws s3 ls | grep mycompany-terraform-state-dev
   ```

4. **Update documentation** - Add Prod backend config to your runbooks
   ```bash
   cd mycompany-terraform-bootstrap
   terraform output backend_configuration > BACKEND_CONFIG_PROD.txt
   ```

## What About Existing Dev Infrastructure?

**Nothing changes in Dev.** Your Dev infrastructure continues using:

```hcl
# Dev projects continue using this backend
terraform {
  backend "s3" {
    bucket         = "mycompany-terraform-state-dev"  # Dev bucket unchanged
    key            = "us-east-1/00-network/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "mycompany-terraform-locks"  # Dev lock table unchanged
  }
}
```

**New Prod projects use:**

```hcl
# New Prod projects use separate Prod bucket
terraform {
  backend "s3" {
    bucket         = "mycompany-terraform-state-prod"  # Different bucket
    key            = "us-east-1/00-network/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "mycompany-terraform-locks"  # Different table, same name
  }
}
```

## Common Questions

**Q: Do I need to migrate Dev state somewhere?**  
A: No. Dev state stays in the Dev account's S3 bucket. Prod will have its own separate bucket in the Prod account.

**Q: Will bootstrapping Prod affect Dev workloads?**  
A: No. The accounts are completely isolated. Prod bootstrap creates resources only in the Prod AWS account.

**Q: Can I use the same repository?**  
A: Yes! The `mycompany-terraform-bootstrap` repository supports multiple accounts via the `accounts/` folder structure:

```
mycompany-terraform-bootstrap/
├── accounts/
│   ├── dev/       # Dev account config (already exists)
│   └── prod/      # Prod account config (create this)
```

**Q: What if we add more environments later (staging, qa, etc.)?**  
A: Same process. Just copy the account folder structure, update the environment name and account ID, and bootstrap the new account. Each is independent.

**Q: Do both accounts need the same S3 bucket configuration?**  
A: Generally yes (versioning, encryption, lifecycle rules should match), but you can customize Prod with additional security controls like MFA delete or object lock if compliance requires.

## Timeline

| Activity                         | Duration    | When  |
| -------------------------------- | ----------- | ----- |
| Prod account approved            | -           | Day 0 |
| Bootstrap Prod account           | 30-60 min   | Day 0 |
| Verify Prod infrastructure       | 15 min      | Day 0 |
| Begin using Prod for deployments | Immediately | Day 0 |

**Total migration time:** ~1 hour, with no Dev downtime

## Checklist

Before bootstrapping Prod:

- [ ] Dev bootstrap is complete and stable
- [ ] Prod AWS account exists and you have admin access
- [ ] AWS SSO profile configured for Prod account (`mycompany-prod`)
- [ ] Repository has space for `accounts/prod/` folder

After bootstrapping Prod:

- [ ] S3 bucket `mycompany-terraform-state-prod` exists in Prod account
- [ ] DynamoDB table `mycompany-terraform-locks` exists in Prod account
- [ ] `BACKEND_CONFIG_PROD.txt` saved and shared with team
- [ ] Verified no resources leaked into Dev account
- [ ] Dev infrastructure still working normally
