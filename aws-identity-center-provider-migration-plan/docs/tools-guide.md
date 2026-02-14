# Helper Scripts Guide

The `tools/` directory contains Python and Bash scripts that help with deployments, migrations, and automation.

---

## Available Scripts

### `export_sso_assignments.py`

**What it does:**  
Backs up your existing AWS Identity Center (SSO) configuration before you migrate to Terraform.

**Why you need it:**  
Before letting Terraform manage SSO, save a backup so you can restore if something goes wrong.

**How to use:**

```bash
# 1. Install Python dependencies
pip3 install boto3

# 2. Set AWS credentials (account where Identity Center is configured)
export AWS_PROFILE=management-account

# 3. Run the script
cd tools/
python3 export_sso_assignments.py

# 4. Check output file
ls -lh sso_assignments_backup_*.json
```

**Output:**  
Creates a JSON file with all your current SSO assignments:

```json
{
  "export_timestamp": "2026-02-04T10:30:00Z",
  "instance_arn": "arn:aws:sso:::instance/ssoins-1234",
  "assignments": [
    {
      "account_id": "471112975126",
      "permission_set_name": "AdministratorAccess",
      "principal_type": "GROUP",
      "principal_name": "AWS-471112975126-Admins"
    }
  ]
}
```

**Required AWS Permissions:**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "sso:ListInstances",
        "sso-admin:ListPermissionSets",
        "sso-admin:DescribePermissionSet",
        "sso-admin:ListAccountAssignments",
        "identitystore:ListUsers",
        "identitystore:ListGroups"
      ],
      "Resource": "*"
    }
  ]
}
```

**Common errors:**

**Error: `boto3` not found**

```bash
# Fix: Install boto3
pip3 install boto3
```

**Error: Access denied**

```bash
# Fix: Verify you're using the right AWS profile
aws sts get-caller-identity
# Should show the Management Account where Identity Center lives
```

**Error: No SSO instance found**

```bash
# Fix: Ensure Identity Center is enabled in this account
aws sso-admin list-instances
```

---

## Adding New Scripts

### When to add a script to `tools/`

Add a script when you find yourself:

- Running the same AWS CLI commands multiple times
- Manually exporting/importing data
- Validating configurations before deployment
- Generating reports or cost estimates

### Naming conventions

Use `verb_noun.py` or `verb_noun.sh`:

**Good:**

- `export_sso_assignments.py`
- `validate_iam_policies.sh`
- `estimate_costs.py`
- `rotate_state_backups.sh`

**Bad:**

- `script.py` (what does it do?)
- `tool.sh` (too vague)
- `fix.py` (fix what?)

### Template for new Python scripts

```python
#!/usr/bin/env python3
"""
Brief description of what this script does.

Usage:
    python3 script_name.py [options]

Requirements:
    - boto3
    - AWS credentials configured

Example:
    export AWS_PROFILE=dev
    python3 script_name.py --account 471112975126
"""

import argparse
import boto3
import json
import sys
from datetime import datetime

def main():
    parser = argparse.ArgumentParser(description='What this script does')
    parser.add_argument('--account', required=True, help='AWS Account ID')
    args = parser.parse_args()

    try:
        # Your logic here
        print(f"Processing account: {args.account}")

    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
```

### Template for new Bash scripts

```bash
#!/bin/bash
# Description: What this script does
#
# Usage: ./script_name.sh [environment]
#
# Example:
#   ./script_name.sh dev

set -euo pipefail  # Exit on error, undefined vars, pipe failures

ENV="${1:-dev}"  # Default to dev if not provided

echo "Running for environment: $ENV"

# Your logic here

echo "✅ Done!"
```

---

## Common Use Cases

### Validate all modules before deployment

```bash
#!/bin/bash
# tools/validate_all_modules.sh

for module in identity-center iam; do
  echo "Validating $module..."
  cd "$module"
  terraform validate || exit 1
  cd ..
done

echo "✅ All modules valid"
```

### Check Terraform state health

```bash
#!/bin/bash
# tools/check_state.sh

BUCKET="terraform-state-dev-471112975126"
KEY="identity-center/terraform.tfstate"

# Check if state file exists
aws s3 ls "s3://$BUCKET/$KEY" || {
  echo "❌ State file not found"
  exit 1
}

echo "✅ State file exists"

# Check for drift
cd identity-center/
terraform plan -detailed-exitcode
```

### Export all IAM roles

```python
#!/usr/bin/env python3
# tools/export_iam_roles.py

import boto3
import json

iam = boto3.client('iam')

roles = iam.list_roles()
output = []

for role in roles['Roles']:
    output.append({
        'name': role['RoleName'],
        'arn': role['Arn'],
        'created': role['CreateDate'].isoformat()
    })

with open('iam_roles_backup.json', 'w') as f:
    json.dump(output, f, indent=2)

print(f"✅ Exported {len(output)} roles")
```

### Cost estimation

```bash
#!/bin/bash
# tools/estimate_costs.sh

terraform plan -out=plan.tfplan
terraform show -json plan.tfplan > plan.json

# Use Infracost or AWS Pricing API
infracost breakdown --path plan.json
```

---

## Best Practices

### ✅ DO:

- Add shebang line: `#!/usr/bin/env python3` or `#!/bin/bash`
- Make scripts executable: `chmod +x script_name.py`
- Include usage documentation at the top
- Handle errors gracefully (try/except, set -e)
- Validate inputs before processing
- Output success/failure messages clearly
- Document required AWS permissions

### ❌ DON'T:

- Hardcode AWS credentials (use environment variables or profiles)
- Skip error handling
- Mix script logic with Terraform code
- Commit sensitive data to Git
- Use vague script names

---

## Running Scripts Safely

**Before running any script:**

1. **Read the code** - Understand what it does
2. **Check AWS credentials** - Verify you're in the right account
   ```bash
   aws sts get-caller-identity
   ```
3. **Test in Dev first** - Never run untested scripts in Prod
4. **Have a backup** - Know how to undo changes
5. **Document results** - Save output to a file

**Example safe workflow:**

```bash
# 1. Verify account
aws sts get-caller-identity
# Confirm: "Account": "471112975126" (Dev)

# 2. Dry-run (if script supports it)
python3 export_sso_assignments.py --dry-run

# 3. Run for real, save output
python3 export_sso_assignments.py 2>&1 | tee export.log

# 4. Verify output
ls -lh sso_assignments_backup_*.json
```

---

## Troubleshooting

**Script won't run: Permission denied**

```bash
# Fix: Make executable
chmod +x tools/script_name.py
```

**AWS credentials not found**

```bash
# Fix: Set AWS profile
export AWS_PROFILE=dev
# Or configure default credentials
aws configure
```

**Module import errors (Python)**

```bash
# Fix: Install requirements
pip3 install boto3 requests
```

**Script crashes with unclear error**

```bash
# Debug: Run with more verbose output
python3 -u script_name.py --debug
# Or for Bash:
bash -x script_name.sh
```

---

## Getting Help

**Script documentation:**

```bash
python3 script_name.py --help
./script_name.sh --help
```

**Test script behavior:**

```bash
# Python: Use ipython for interactive testing
ipython
>>> import boto3
>>> # Test commands interactively
```

**AWS CLI reference:**

```bash
aws <service> help
aws sso-admin list-instances help
```
