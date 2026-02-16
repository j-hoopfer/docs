# GitHub Actions OIDC Authentication with AWS

## Overview

This guide explains how to set up OpenID Connect (OIDC) authentication between GitHub Actions and your AWS account.

**Why OIDC?**

- **No Long-Lived Keys:** You never create an IAM User with access keys.
- **Automatic Rotation:** Credentials are temporary and expire automatically.
- **Granular Access:** You can restrict which GitHub repo, branch, or environment can assume the role.

---

## 1. Create OIDC Provider in AWS

This is a one-time setup per AWS account.

**Console:**

1. IAM > Identity providers > Add provider
2. Provider type: `OpenID Connect`
3. Provider URL: `https://token.actions.githubusercontent.com`
4. Audience: `sts.amazonaws.com`

**Terraform:**

```hcl
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"] # GitHub's thumbprint
}
```

---

## 2. Create IAM Role for GitHub Actions

Create a role that trusts the OIDC provider.

**Trust Policy:**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:my-org/my-repo:*"
        }
      }
    }
  ]
}
```

_Note: The `sub` condition restricts access. Use `repo:my-org/_`for all repos in org, or`repo:my-org/my-repo:ref:refs/heads/main` for specific branch.\*

**Permissions Policy:**
Attach policies needed for deployment (e.g., `AmazonECS_FullAccess`, `AmazonEC2ContainerRegistryPowerUser`).

---

## 3. Configure GitHub Action

Update your workflow file to request the token.

```yaml
# .github/workflows/deploy.yml
permissions:
  id-token: write # Required for requesting the JWT
  contents: read # Required for actions/checkout

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-region: us-east-1
          role-to-assume: arn:aws:iam::123456789012:role/GitHubActionsDeployRole
```

---

## Troubleshooting OIDC

**Error: "Not authorized to perform sts:AssumeRoleWithWebIdentity"**

- Check the `sub` claim in the Trust Policy. It must match the repo/branch exactly.
- Check if `id-token: write` permission is in the workflow YAML.

**Error: "OpenIDConnect provider not found"**

- Ensure you created the Provider in the correct AWS account and region (though IAM is global).
- Verify the Provider ARN in the Trust Policy matches your account ID.
