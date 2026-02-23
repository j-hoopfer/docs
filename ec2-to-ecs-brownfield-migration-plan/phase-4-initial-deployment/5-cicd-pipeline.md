# Activity 5: CI/CD Pipeline

**Goal:** Automate the entire "build-push-deploy" lifecycle with GitHub Actions, ensuring that every merge to `main` results in a deployed service.

## Context & Themes

This document details the setup of the automated build and deployment pipeline using GitHub Actions. It ensures that code changes are automatically tested, built into container images, and securely deployed to ECS Fargate, replacing manual deployments.

**Key Themes:**

- **Automated Delivery:** Consistent, repeatable deployments.
- **Security:** Using OIDC for temporary credentials instead of long-lived access keys.
- **Standardization:** Every deploy follows the same steps.
- **Auditability:** Logs of every build and deployment.

## Prerequisites

Before building the pipeline, ensure:

- [ ] Services Repository Setup completed.
- [ ] GitHub repository admin access (to configure OIDC trust and secrets).
- [ ] AWS IAM permissions to create Identity Providers and Roles.
- [ ] ECR Repository URL (created in previous phases).
- [ ] ECS Cluster and Service names (created in previous phases).

## Feature 5: GitHub Actions Workflow

**Business Value:** Automates build and deploy process, eliminating manual configuration drift and reducing risks. CI/CD automation enables continuous delivery, standardized builds (20-30 minutes setup), and consistent deployments across environments. OIDC authentication replaces risky long-lived keys with temporary credentials, improving security posture. Workflow triggers on merge/tag ensure only approved code reaches production.

### Story 5.1: IAM Role & OIDC

- **Title:** Configure AWS OIDC for GitHub Actions
- **Target Account:** Workload Account (`dev` / `prod`)
- **Persona:** As a **Security Engineer**, I want to provide secure, temporary access for GitHub Actions so that we don't need to manage static IAM user credentials.

**(Junior Engineer Context: If `aws-actions` fails with `sts:AssumeRoleWithWebIdentity`, check that your IAM Trust Policy `sub` claim matches your repo/branch exactly, and that your YAML workflow includes `permissions: id-token: write`.)**

**Business Value:** Secures pipeline access to AWS resources without permanent credentials, eliminating key rotation overhead. OIDC integration (15-20 minutes) provides secure, auditable, and temporary access for GitHub Actions workflows. Following security best practices (least privilege) protects infrastructure from compromised CI credentials. Setup required once per repository/account.

- **Requirements:**
  - Create OIDC Identity Provider in AWS IAM (in the Workload Account)
  - Create IAM Role referencing provider
  - Trust policy allows GitHub repo
  - Role has necessary permissions (Push ECR, Deploy ECS)

- **Implementation Details:**
  1. **Create Identity Provider:**
     - Log into the **Workload Account**.
     - Go to IAM -> Identity Providers.
     - Type: **OpenID Connect**
     - Provider URL: `https://token.actions.githubusercontent.com`
     - Audience: `sts.amazonaws.com`
     - Thumbprint: Get from GitHub docs (usually pre-filled)
  2. **Create IAM Role:**
     - Name: `GitHubActions-Role`
     - Trust Policy:
       ```json
       {
         "Version": "2012-10-17",
         "Statement": [
           {
             "Effect": "Allow",
             "Principal": {
               "Federated": "arn:aws:iam::<WORKLOAD_ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
             },
             "Action": "sts:AssumeRoleWithWebIdentity",
             "Condition": {
               "StringLike": {
                 "token.actions.githubusercontent.com:sub": "repo:<ORG>/<REPO>:*"
               }
             }
           }
         ]
       }
       ```
  3. **Attach Policies:**
     - **ECR Access:**
       - `ecr:GetAuthorizationToken`
       - `ecr:BatchCheckLayerAvailability`
       - `ecr:GetDownloadUrlForLayer`
       - `ecr:BatchGetImage`
       - `ecr:InitiateLayerUpload`
       - `ecr:UploadLayerPart`
       - `ecr:CompleteLayerUpload`
       - `ecr:PutImage`
     - **ECS Deployment:**
       - `ecs:RegisterTaskDefinition`
       - `ecs:UpdateService`
       - `ecs:DescribeServices`
       - `iam:PassRole` (for Task/Execution roles)

- **Acceptance Criteria:**
  - ✅ OIDC Provider exists in IAM
  - ✅ Role assumes successfully
  - ✅ Trust policy limited to correct repo(s)
  - ✅ Role has only necessary permissions

---

### Story 5.3: Configure Deployer IAM Permissions

- **Title:** Grant CI/CD Pipeline Permission to Deploy ECS Services
- **Persona:** As a **DevOps engineer**, I need the CI/CD deployer role to have `iam:PassRole` permission so that GitHub Actions can deploy ECS services with the correct Task and Execution Roles.

- **Requirements:**
  - CI/CD deployer can register task definitions
  - CI/CD deployer can update ECS services
  - CI/CD deployer can pass Task Role and Execution Role to ECS
  - Permissions follow least-privilege principle

- **Implementation Details:**
  - **The Problem:**
    - When GitHub Actions runs `aws ecs register-task-definition`, it needs to specify:
      - `taskRoleArn` (role the application uses)
      - `executionRoleArn` (role ECS uses to pull image and fetch secrets)
    - **Without `iam:PassRole`, deployment fails with:**
      ```
      User: arn:aws:sts::123456789012:assumed-role/GitHubActionsDeployerRole/...
      is not authorized to perform: iam:PassRole on resource: arn:aws:iam::123456789012:role/ECSTaskRole
      ```
  - **Create Deployer Role Policy:**

    ```hcl
    # terraform/iam-deployer.tf

    resource "aws_iam_role" "github_actions_deployer" {
      name = "GitHubActionsDeployerRole"

      assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Effect = "Allow"
          Principal = {
            Federated = aws_iam_openid_connect_provider.github.arn
          }
          Action = "sts:AssumeRoleWithWebIdentity"
          Condition = {
            StringEquals = {
              "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            }
            StringLike = {
              "token.actions.githubusercontent.com:sub" = "repo:my-org/my-repo:*"
            }
          }
        }]
      })
    }

    resource "aws_iam_role_policy" "deployer_ecs" {
      name = "ECSDeploymentPolicy"
      role = aws_iam_role.github_actions_deployer.id

      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid = "ECSDeployment"
            Effect = "Allow"
            Action = [
              "ecs:RegisterTaskDefinition",
              "ecs:DeregisterTaskDefinition",
              "ecs:DescribeTaskDefinition",
              "ecs:DescribeServices",
              "ecs:UpdateService",
              "ecs:ListTasks",
              "ecs:DescribeTasks"
            ]
            Resource = "*"
          },
          {
            Sid = "PassRoleToECS"
            Effect = "Allow"
            Action = "iam:PassRole"
            Resource = [
              aws_iam_role.ecs_task_role.arn,
              aws_iam_role.ecs_execution_role.arn
            ]
            Condition = {
              StringEquals = {
                "iam:PassedToService": "ecs-tasks.amazonaws.com"
              }
            }
          },
          {
            Sid = "ECRAccess"
            Effect = "Allow"
            Action = [
              "ecr:GetAuthorizationToken",
              "ecr:BatchCheckLayerAvailability",
              "ecr:GetDownloadUrlForLayer",
              "ecr:BatchGetImage"
            ]
            Resource = "*"
          }
        ]
      })
    }
    ```

  - **Least-privilege PassRole:**
    - **Restrict to specific roles:** Only allow passing the Task and Execution roles (not all roles)
    - **Restrict to ECS service:** `Condition: iam:PassedToService = ecs-tasks.amazonaws.com`
    - This prevents deployer from passing arbitrary roles to other services
  - **Test deployment:**

    ```bash
    # Assume deployer role
    aws sts assume-role --role-arn arn:aws:iam::123456789012:role/GitHubActionsDeployerRole

    # Try registering task definition
    aws ecs register-task-definition \
      --family my-app \
      --task-role-arn arn:aws:iam::123456789012:role/ECSTaskRole \
      --execution-role-arn arn:aws:iam::123456789012:role/ECSExecutionRole \
      --container-definitions '[...]'

    # Should succeed with iam:PassRole permission
    ```

- **Acceptance Criteria:**
  - ✅ Deployer role created with OIDC trust for GitHub Actions
  - ✅ `iam:PassRole` permission granted for Task and Execution roles only
  - ✅ Condition restricts PassRole to `ecs-tasks.amazonaws.com`
  - ✅ CI/CD pipeline can register task definitions
  - ✅ CI/CD pipeline can update ECS services
  - ✅ Attempting to pass other IAM roles fails (security test)

---

### Story 6.2: Workflow Deployment

**Business Value:** Automates the complete deployment pipeline from code commit to production release. Standardized workflow (20-30 minutes setup) ensures every deployment is built, tested, and deployed identically, reducing human error. Automated builds trigger on git push/tag, ensuring production reflects the source of truth. Version tagging strategy enables rollback capability and clear release tracking.

- **Title:** Create `deploy.yml` Workflow
- **Persona:** As a **DevOps Engineer**, I want a reusable GitHub Actions workflow that builds, pushes, and deploys my application automatically.

- **Requirements:**
  - Trigger on push to `main` (or tag)
  - Checkout code
  - Authenticate via OIDC
  - Login to ECR
  - Build & Tag Docker image (Sha + Latest)
  - Push to ECR
  - Update ECS Service (Force deployment)

- **Implementation Details:**
  - **Create `.github/workflows/deploy.yml`:**

    ```yaml
    name: Deploy to ECS

    on:
      push:
        branches: ["main"]

    permissions:
      id-token: write
      contents: read

    env:
      AWS_REGION: us-east-1
      ECR_REPOSITORY: my-app-repo
      ECS_SERVICE: my-app-service
      ECS_CLUSTER: fargate-cluster
      CONTAINER_NAME: my-app-container

    jobs:
      deploy:
        runs-on: ubuntu-latest
        steps:
          - name: Checkout
            uses: actions/checkout@v3

          - name: Configure AWS Credentials
            uses: aws-actions/configure-aws-credentials@v2
            with:
              role-to-assume: arn:aws:iam::<ACCOUNT_ID>:role/GitHubActions-Role
              aws-region: ${{ env.AWS_REGION }}

          - name: Login to Amazon ECR
            id: login-ecr
            uses: aws-actions/amazon-ecr-login@v1

          - name: Build, tag, and push image to Amazon ECR
            id: build-image
            env:
              ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
              IMAGE_TAG: ${{ github.sha }}
            run: |
              docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG .
              docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
              echo "image=$ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG" >> $GITHUB_OUTPUT

          - name: Download Task Definition
            run: |
              aws ecs describe-task-definition --task-definition my-app-task --query taskDefinition > task-definition.json

          - name: Fill in new image ID in the Amazon ECS task definition
            id: task-def
            uses: aws-actions/amazon-ecs-render-task-definition@v1
            with:
              task-definition: task-definition.json
              container-name: ${{ env.CONTAINER_NAME }}
              image: ${{ steps.build-image.outputs.image }}

          - name: Deploy Amazon ECS task definition
            uses: aws-actions/amazon-ecs-deploy-task-definition@v1
            with:
              task-definition: ${{ steps.task-def.outputs.task-definition }}
              service: ${{ env.ECS_SERVICE }}
              cluster: ${{ env.ECS_CLUSTER }}
              wait-for-service-stability: true
    ```

- **Acceptance Criteria:**
  - ✅ Workflow triggers on push to main
  - ✅ Authentication succeeds (OIDC)
  - ✅ Docker image built and pushed to ECR
  - ✅ ECS Service updates with new image
  - ✅ Deployment verifies service stability (wait-for-service-stability: true)

---

### Story 5.3: Pull Request Checks (Linting & Validating)

- **Title:** Create `pr-check.yml` Workflow
- **Persona:** As a **Developer**, I want my code (both application and infrastructure) to be automatically linted and validated on every Pull Request so that I catch errors before merging to main.

**Business Value:** Enforces code quality and security standards before code reaches the main branch. Automated PR checks (linting, testing, formatting) prevent broken builds and ensure that best practices (like 12-factor config) are followed. Catching syntax errors or security issues (via tfsec/tflint) during the PR stage is 100x cheaper than fixing them after a failed deployment.

- **Requirements:**
  - Triggers on Pull Request to `main`
  - Runs Terraform fmt/validate (if infra changes)
  - Runs TFLint (if infra changes)
  - Runs application linter (ESLint, Pylint, etc.)
  - Runs unit tests

- **Implementation Details:**
  - **Create `.github/workflows/pr-check.yml`:**

    ```yaml
    name: PR Checks

    on:
      pull_request:
        branches: ["main"]

    jobs:
      infra-lint:
        name: Infrastructure Linting
        runs-on: ubuntu-latest
        steps:
          - uses: actions/checkout@v3
          - uses: hashicorp/setup-terraform@v2

          - name: Terraform Format
            run: terraform fmt -check -recursive
            continue-on-error: true

          - name: Install TFLint
            uses: terraform-linters/setup-tflint@v3

          - name: Run TFLint
            run: tflint --recursive

      app-lint-test:
        name: App Test & Lint
        runs-on: ubuntu-latest
        steps:
          - uses: actions/checkout@v3
          - uses: actions/setup-node@v3
            with:
              node-version: "20"

          - name: Install Dependencies
            run: npm ci

          - name: Lint
            run: npm run lint

          - name: Test
            run: npm test
    ```

- **Acceptance Criteria:**
  - ✅ Workflow triggers on PR open/update
  - ✅ Terraform formatting and linting checks run
  - ✅ Application linting and tests run
  - ✅ PR is blocked if checks fail (requires GitHub branch protection rule)

---

## Appendix: Alternative CI/CD Tools

If you are not using GitHub Actions, adapt these patterns for your tool of choice.

### GitLab CI

```yaml
# .gitlab-ci.yml
build:
  image: docker:latest
  services:
    - docker:dind
  before_script:
    - apk add --no-cache aws-cli
    - aws ecr get-login-password | docker login --username AWS --password-stdin $ECR_REGISTRY
  script:
    - docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$CI_COMMIT_SHA .
    - docker push $ECR_REGISTRY/$ECR_REPOSITORY:$CI_COMMIT_SHA

deploy:
  image: registry.gitlab.com/gitlab-org/cloud-deploy/aws-base:latest
  script:
    - aws ecs update-service --cluster $ECS_CLUSTER --service $ECS_SERVICE --force-new-deployment
```

### Jenkins

```groovy
pipeline {
  agent any
  environment {
    ECR_REGISTRY = credentials('ecr-registry-url')
    ECR_REPOSITORY = 'myapp/auth-api'
  }
  stages {
    stage('Build') {
      steps {
        sh 'docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$GIT_COMMIT .'
      }
    }
    stage('Push') {
      steps {
        sh '''
          aws ecr get-login-password | docker login --username AWS --password-stdin $ECR_REGISTRY
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$GIT_COMMIT
        '''
      }
    }
    stage('Deploy') {
      steps {
        sh 'aws ecs update-service --cluster production --service auth-api --force-new-deployment'
      }
    }
  }
}
```

### CircleCI

```yaml
# .circleci/config.yml
version: 2.1
jobs:
  build:
    docker:
      - image: cimg/aws:2024.03
    steps:
      - checkout
      - setup_remote_docker
      - run:
          name: Build and push
          command: |
            aws ecr get-login-password | docker login --username AWS --password-stdin $ECR_REGISTRY
            docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$CIRCLE_SHA1 .
            docker push $ECR_REGISTRY/$ECR_REPOSITORY:$CIRCLE_SHA1
```
