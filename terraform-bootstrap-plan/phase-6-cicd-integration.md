# Phase 6: CI/CD Integration

**Purpose:** Configure IAM roles and permissions to allow CI/CD pipelines (GitHub Actions, GitLab CI, Jenkins, etc.) to run Terraform using the bootstrap state infrastructure.

**Estimated Time:** 30-60 minutes per account

**Prerequisites:**

- Phase 1, 2, and 3 completed (bootstrap infrastructure exists)
- CI/CD platform selected (GitHub Actions, GitLab CI, etc.)
- Understanding of OIDC authentication (recommended over long-term credentials)

---

## Overview

After bootstrapping your Terraform state infrastructure, you need to grant your CI/CD pipelines access to:

- **S3 state bucket** - Read/write state files
- **DynamoDB lock table** - Acquire/release locks during runs
- **AWS resources** - Create/modify infrastructure (beyond state access)

**Best Practice:** Use **IAM roles with OIDC** instead of long-term access keys. This eliminates the need to store AWS credentials in your CI/CD platform.

---

## Feature 1: GitHub Actions OIDC Integration

### User Story 1.1: Create GitHub OIDC Identity Provider

**As a:** Platform Engineer  
**I want to:** Configure AWS to trust GitHub Actions  
**So that:** GitHub workflows can assume IAM roles without storing credentials

**Acceptance Criteria:**

- OIDC provider created in AWS IAM
- Thumbprint configured correctly
- Provider limited to scale GitHub organization

#### Implementation

**Create OIDC Provider (One-time per account):**

```hcl
# Add to scale-cloud-infrastructure/environments/{env}/global/iam/github-oidc.tf
resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com"
  ]

  # GitHub's thumbprint - verify current value at:
  # https://github.blog/changelog/2022-01-13-github-actions-update-on-oidc-based-deployments-to-aws/
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd"
  ]

  tags = {
    Name        = "GitHubActions-OIDC"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}
```

**Verify OIDC Provider:**

```bash
aws iam list-open-id-connect-providers --profile scale-poc
```

**Expected Output:**

```json
{
  "OpenIDConnectProviderList": [
    {
      "Arn": "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    }
  ]
}
```

---

### User Story 1.2: Create IAM Role for GitHub Actions

**As a:** Platform Engineer  
**I want to:** Create an IAM role that GitHub Actions can assume  
**So that:** Workflows can run Terraform with proper permissions

**Acceptance Criteria:**

- IAM role created with trust policy for GitHub OIDC
- Role limited to specific repository or organization
- State access policy attached
- Resource creation permissions attached (as needed)

#### Implementation

**Create IAM Role:**

```hcl
# scale-cloud-infrastructure/environments/{env}/global/iam/github-terraform-role.tf
resource "aws_iam_role" "github_actions_terraform" {
  name        = "GitHubActions-Terraform-${var.environment}"
  description = "Role for GitHub Actions to run Terraform in ${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "arn:aws:iam::${var.account_id}:oidc-provider/token.actions.githubusercontent.com"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # Restrict to specific repos or organization
            "token.actions.githubusercontent.com:sub" = [
              "repo:scale/scale-cloud-infrastructure:*",
              "repo:scale/scale-application:*"
            ]
          }
        }
      }
    ]
  })

  tags = {
    Name        = "GitHubActions-Terraform-${var.environment}"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# Attach state access policy
resource "aws_iam_role_policy" "github_terraform_state_access" {
  name = "TerraformStateAccess"
  role = aws_iam_role.github_actions_terraform.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TerraformStateReadWrite"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = [
          "arn:aws:s3:::scale-terraform-state-${var.environment}",
          "arn:aws:s3:::scale-terraform-state-${var.environment}/*"
        ]
      },
      {
        Sid    = "TerraformStateLocking"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:DeleteItem"
        ]
        Resource = "arn:aws:dynamodb:${var.primary_region}:${var.account_id}:table/scale-terraform-locks"
      }
    ]
  })
}

# Attach resource creation permissions (example for EC2/VPC)
resource "aws_iam_role_policy_attachment" "github_terraform_ec2_full" {
  role       = aws_iam_role.github_actions_terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}

# NOTE: For production, create custom policies with least-privilege instead of AWS managed policies
```

**Output the Role ARN:**

```hcl
# outputs.tf
output "github_actions_terraform_role_arn" {
  description = "ARN of IAM role for GitHub Actions to assume"
  value       = aws_iam_role.github_actions_terraform.arn
}
```

**Apply the configuration:**

```bash
cd scale-cloud-infrastructure/environments/poc/global/iam
terraform init
terraform apply
```

**Copy the role ARN from outputs** - you'll need it for the GitHub Actions workflow.

---

### User Story 1.3: Configure GitHub Actions Workflow

**As a:** Platform Engineer  
**I want to:** Create a GitHub Actions workflow that uses OIDC  
**So that:** Terraform runs automatically on pull requests and merges

**Acceptance Criteria:**

- Workflow runs on pull requests (plan only)
- Workflow runs on main branch merge (plan + apply)
- Uses OIDC to assume IAM role (no stored credentials)
- Terraform state operations work correctly

#### Implementation

**Create GitHub Actions Workflow:**

```yaml
# .github/workflows/terraform.yml
name: Terraform

on:
  pull_request:
    branches: [main]
    paths:
      - "environments/**/*.tf"
      - "modules/**/*.tf"
  push:
    branches: [main]
    paths:
      - "environments/**/*.tf"
      - "modules/**/*.tf"

# Required for OIDC authentication
permissions:
  id-token: write # Required to request OIDC token
  contents: read # Required to checkout code
  pull-requests: write # Required to comment on PRs

env:
  AWS_REGION: us-east-1
  TERRAFORM_VERSION: 1.7.4

jobs:
  terraform-plan:
    name: Terraform Plan
    runs-on: ubuntu-latest
    strategy:
      matrix:
        environment: [poc] # Add dev, prod later
        region: [us-east-1]
        layer: [00-network, 10-application]

    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789012:role/GitHubActions-Terraform-poc
          aws-region: ${{ env.AWS_REGION }}
          role-session-name: GitHubActions-${{ github.run_id }}

      - name: Verify AWS Identity
        run: |
          aws sts get-caller-identity
          echo "Assumed role successfully"

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TERRAFORM_VERSION }}

      - name: Terraform Init
        working-directory: environments/${{ matrix.environment }}/${{ matrix.region }}/${{ matrix.layer }}
        run: terraform init

      - name: Terraform Format Check
        working-directory: environments/${{ matrix.environment }}/${{ matrix.region }}/${{ matrix.layer }}
        run: terraform fmt -check

      - name: Terraform Validate
        working-directory: environments/${{ matrix.environment }}/${{ matrix.region }}/${{ matrix.layer }}
        run: terraform validate

      - name: Terraform Plan
        working-directory: environments/${{ matrix.environment }}/${{ matrix.region }}/${{ matrix.layer }}
        run: |
          terraform plan -out=tfplan -no-color | tee plan.txt

      - name: Comment Plan on PR
        if: github.event_name == 'pull_request'
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const plan = fs.readFileSync('environments/${{ matrix.environment }}/${{ matrix.region }}/${{ matrix.layer }}/plan.txt', 'utf8');
            const output = `#### Terraform Plan 📖 \`${{ matrix.environment }}-${{ matrix.region }}-${{ matrix.layer }}\`
            <details><summary>Show Plan</summary>

            \`\`\`terraform
            ${plan}
            \`\`\`

            </details>`;

            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: output
            });

  terraform-apply:
    name: Terraform Apply
    runs-on: ubuntu-latest
    needs: terraform-plan
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    strategy:
      matrix:
        environment: [poc]
        region: [us-east-1]
        layer: [00-network, 10-application]

    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789012:role/GitHubActions-Terraform-poc
          aws-region: ${{ env.AWS_REGION }}

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TERRAFORM_VERSION }}

      - name: Terraform Init
        working-directory: environments/${{ matrix.environment }}/${{ matrix.region }}/${{ matrix.layer }}
        run: terraform init

      - name: Terraform Apply
        working-directory: environments/${{ matrix.environment }}/${{ matrix.region }}/${{ matrix.layer }}
        run: terraform apply -auto-approve
```

**Test the Workflow:**

1. Create a new branch:

   ```bash
   git checkout -b test-cicd
   ```

2. Make a small Terraform change (e.g., add a tag to a resource)

3. Commit and push:

   ```bash
   git add .
   git commit -m "Test: GitHub Actions OIDC integration"
   git push origin test-cicd
   ```

4. Open a pull request on GitHub

5. Verify workflow runs and posts plan comment

6. Merge PR and verify apply runs

**Validation:**

- ✅ Workflow runs without credential errors
- ✅ Terraform plan shows in PR comments
- ✅ Terraform apply runs on merge to main
- ✅ State is successfully read/written to S3
- ✅ DynamoDB lock is acquired/released

---

## Feature 2: GitLab CI Integration

### User Story 2.1: Create GitLab OIDC Identity Provider

**As a:** Platform Engineer  
**I want to:** Configure AWS to trust GitLab CI  
**So that:** GitLab pipelines can assume IAM roles

**Implementation:**

```hcl
# For GitLab SaaS (gitlab.com)
resource "aws_iam_openid_connect_provider" "gitlab_ci" {
  url = "https://gitlab.com"

  client_id_list = [
    "https://gitlab.com"
  ]

  thumbprint_list = [
    # Get current thumbprint with:
    # echo | openssl s_client -servername gitlab.com -showcerts -connect gitlab.com:443 2>/dev/null | openssl x509 -fingerprint -sha1 -noout | cut -d'=' -f2 | tr -d ':'
    "b3dd7606d2b5a8b4a13771dbecc9ee1cecafa38a"
  ]
}

# For self-hosted GitLab, replace URL with your GitLab instance
```

**Create IAM Role for GitLab:**

```hcl
resource "aws_iam_role" "gitlab_ci_terraform" {
  name = "GitLabCI-Terraform-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.gitlab_ci.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "gitlab.com:aud" = "https://gitlab.com"
          }
          StringLike = {
            "gitlab.com:sub" = "project_path:scale/*:ref_type:branch:ref:main"
          }
        }
      }
    ]
  })
}

# Attach state access policy (same as GitHub Actions example above)
```

**GitLab CI Pipeline Example:**

```yaml
# .gitlab-ci.yml
variables:
  AWS_REGION: us-east-1
  TERRAFORM_VERSION: "1.7.4"

default:
  image: hashicorp/terraform:$TERRAFORM_VERSION

stages:
  - validate
  - plan
  - apply

terraform-plan:
  stage: plan
  id_tokens:
    GITLAB_OIDC_TOKEN:
      aud: https://gitlab.com
  before_script:
    - apk add --no-cache python3 py3-pip
    - pip3 install awscli
    - |
      export $(printf "AWS_ACCESS_KEY_ID=%s AWS_SECRET_ACCESS_KEY=%s AWS_SESSION_TOKEN=%s" \
      $(aws sts assume-role-with-web-identity \
      --role-arn arn:aws:iam::123456789012:role/GitLabCI-Terraform-poc \
      --role-session-name "GitLabRunner-${CI_PIPELINE_ID}" \
      --web-identity-token $GITLAB_OIDC_TOKEN \
      --duration-seconds 3600 \
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
      --output text))
  script:
    - cd environments/poc/us-east-1/00-network
    - terraform init
    - terraform plan
  only:
    - merge_requests
    - main
```

---

## Feature 3: Jenkins Integration

### User Story 3.1: Configure Jenkins IAM User (Alternative to OIDC)

**Note:** Jenkins doesn't natively support OIDC. Options:

1. Use IAM user with long-term credentials (less secure, requires rotation)
2. Use EC2 instance profile if Jenkins runs on EC2
3. Use third-party plugins for OIDC

**Option 1: IAM User with Credentials Stored in Jenkins:**

```hcl
resource "aws_iam_user" "jenkins_terraform" {
  name = "jenkins-terraform-${var.environment}"

  tags = {
    Name        = "Jenkins Terraform User"
    Environment = var.environment
  }
}

resource "aws_iam_user_policy" "jenkins_state_access" {
  name = "TerraformStateAccess"
  user = aws_iam_user.jenkins_terraform.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TerraformStateReadWrite"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = [
          "arn:aws:s3:::scale-terraform-state-${var.environment}",
          "arn:aws:s3:::scale-terraform-state-${var.environment}/*"
        ]
      },
      {
        Sid    = "TerraformStateLocking"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:DeleteItem"
        ]
        Resource = "arn:aws:dynamodb:${var.primary_region}:${var.account_id}:table/scale-terraform-locks"
      }
    ]
  })
}

# Create access key (store in Jenkins credentials securely)
resource "aws_iam_access_key" "jenkins" {
  user = aws_iam_user.jenkins_terraform.name
}

# Store these in Jenkins securely and rotate every 90 days
output "jenkins_access_key_id" {
  value     = aws_iam_access_key.jenkins.id
  sensitive = true
}

output "jenkins_secret_access_key" {
  value     = aws_iam_access_key.jenkins.secret
  sensitive = true
}
```

**Jenkinsfile Example:**

```groovy
pipeline {
    agent any

    environment {
        AWS_REGION = 'us-east-1'
        TERRAFORM_VERSION = '1.7.4'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Terraform Plan') {
            steps {
                withCredentials([
                    string(credentialsId: 'aws-access-key-id', variable: 'AWS_ACCESS_KEY_ID'),
                    string(credentialsId: 'aws-secret-access-key', variable: 'AWS_SECRET_ACCESS_KEY')
                ]) {
                    dir('environments/poc/us-east-1/00-network') {
                        sh '''
                            terraform init
                            terraform plan -out=tfplan
                        '''
                    }
                }
            }
        }

        stage('Terraform Apply') {
            when {
                branch 'main'
            }
            steps {
                withCredentials([
                    string(credentialsId: 'aws-access-key-id', variable: 'AWS_ACCESS_KEY_ID'),
                    string(credentialsId: 'aws-secret-access-key', variable: 'AWS_SECRET_ACCESS_KEY')
                ]) {
                    dir('environments/poc/us-east-1/00-network') {
                        sh 'terraform apply tfplan'
                    }
                }
            }
        }
    }
}
```

---

## Security Best Practices

### Principle of Least Privilege

**For Production:**

- Create custom IAM policies instead of using AWS managed policies
- Grant only specific resource permissions needed
- Use resource-level permissions with conditions

**Example Custom Policy (EC2 limited to specific regions/tags):**

```hcl
resource "aws_iam_policy" "terraform_custom" {
  name        = "TerraformCustom-${var.environment}"
  description = "Custom least-privilege policy for Terraform"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2ReadWrite"
        Effect = "Allow"
        Action = [
          "ec2:Describe*",
          "ec2:CreateTags",
          "ec2:RunInstances",
          "ec2:TerminateInstances"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = ["us-east-1", "us-west-2"]
          }
        }
      },
      {
        Sid    = "VPCManagement"
        Effect = "Allow"
        Action = [
          "ec2:CreateVpc",
          "ec2:DeleteVpc",
          "ec2:CreateSubnet",
          "ec2:DeleteSubnet",
          "ec2:CreateRouteTable",
          "ec2:DeleteRouteTable"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = ["us-east-1", "us-west-2"]
          }
        }
      }
    ]
  })
}
```

### Audit and Monitoring

**Enable CloudTrail logging for state bucket access:**

```hcl
resource "aws_cloudtrail" "state_bucket_audit" {
  name                          = "terraform-state-audit-${var.environment}"
  s3_bucket_name                = aws_s3_bucket.cloudtrail_logs.id
  include_global_service_events = true
  is_multi_region_trail         = true

  event_selector {
    read_write_type           = "All"
    include_management_events = true

    data_resource {
      type = "AWS::S3::Object"

      values = [
        "${aws_s3_bucket.terraform_state.arn}/*"
      ]
    }
  }
}
```

### Credential Rotation

**For IAM Users (Jenkins example):**

- Rotate access keys every 90 days
- Use AWS Secrets Manager to automate rotation
- Monitor for unused credentials with AWS Access Analyzer

---

## Success Criteria

After completing Phase 6:

- [ ] OIDC provider created for CI/CD platform
- [ ] IAM role created with state access permissions
- [ ] CI/CD workflow configured and tested
- [ ] Terraform plan runs successfully on pull requests
- [ ] Terraform apply runs successfully on main branch merges
- [ ] No AWS credentials stored in CI/CD platform
- [ ] CloudTrail logging enabled for state bucket access
- [ ] Credential rotation policy documented (if using IAM users)

---

## Next Steps

1. Implement automated testing in CI/CD pipeline (terraform validate, tflint, checkov)
2. Add approval gates for production deployments
3. Implement drift detection (scheduled terraform plan)
4. Configure notifications (Slack, email) for Terraform failures

---

## Additional Resources

- [GitHub Actions OIDC Documentation](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
- [GitLab CI OIDC Documentation](https://docs.gitlab.com/ee/ci/cloud_services/aws/)
- [AWS IAM Best Practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)
- [Terraform Cloud/Enterprise Alternative](https://www.terraform.io/cloud-docs) (managed state and CI/CD)
