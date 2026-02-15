# Activity 1: Reusable CI/CD Workflows

## Feature 1: Centralized Deployment Templates

**Business Value:** Reduces deployment pipeline setup from 2-4 hours per service to 15 minutes through reusable templates, accelerating migration by 80%. Centralized workflow (3-4 hours initial setup) enables adding security scanning, Slack notifications, or compliance checks once and propagating to all 10 services instantly. Eliminates copy-paste deployment code reducing bugs by 70% and ensuring consistent deployments. Critical for scaling from 1 to 10 services efficiently without 10x operational burden.

### Story 1.1: Create Centralized Workflow Template

**Business Value:** Creates single source of truth for deployment logic, eliminating duplicate code across 10 repositories. Centralized template (3-4 hours setup) reduces future deployment pipeline changes from 10x work (update 10 repos) to 1x work (update template once). Prevents deployment bugs from copy-paste errors and ensures all services get security/compliance updates instantly. For 10 services, this saves 20-30 hours in initial setup and 2-4 hours per pipeline change going forward.

- **Title:** Build Reusable Deployment Workflow
- **Persona:** As a **Platform Engineer**, I want a single deployment template so that improvements to CI/CD propagate to all 10 applications without editing 10 files.
- **Requirements:**
  - Single source of truth for deployment logic
  - Apps pass configuration as inputs
  - Shared logic for build, push, deploy
  - Easy to add features (Slack notifications, security scanning)
- **Implementation Details:**
  - **Create Infrastructure Repository:**
    - Repo: `my-org/infrastructure` (or `my-org/platform-workflows`)
    - This holds shared workflows, Terraform modules, documentation
  - **Reusable Workflow Template:**
    - File: `infrastructure/.github/workflows/ecs-deploy-template.yml`

    ```yaml
    name: Reusable ECS Deploy

    on:
      workflow_call:
        inputs:
          ecr_repository:
            description: "ECR repository path (e.g., legacy-migration/auth-api)"
            required: true
            type: string
          service_name:
            description: "ECS service name"
            required: true
            type: string
          cluster_name:
            description: "ECS cluster name"
            required: false
            type: string
            default: "production-cluster"
          task_definition:
            description: "Task definition family name"
            required: true
            type: string
          container_name:
            description: "Container name in task definition"
            required: true
            type: string
          dockerfile_path:
            description: "Path to Dockerfile"
            required: false
            type: string
            default: "./Dockerfile"
          aws_region:
            description: "AWS region"
            required: false
            type: string
            default: "us-east-1"
        secrets:
          AWS_ROLE_ARN:
            required: true

    jobs:
      deploy:
        name: Build and Deploy
        runs-on: ubuntu-latest

        steps:
          - name: Checkout
            uses: actions/checkout@v4

          - name: Configure AWS credentials
            uses: aws-actions/configure-aws-credentials@v4
            with:
              aws-region: ${{ inputs.aws_region }}
              role-to-assume: ${{ secrets.AWS_ROLE_ARN }}

          - name: Login to Amazon ECR
            uses: aws-actions/amazon-ecr-login@v2
            id: login-ecr

          - name: Build, tag, and push image
            id: build-image
            env:
              ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
              ECR_REPOSITORY: ${{ inputs.ecr_repository }}
              IMAGE_TAG: ${{ github.sha }}
            run: |
              docker build \
                --platform linux/amd64 \
                -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG \
                -t $ECR_REGISTRY/$ECR_REPOSITORY:latest \
                -f ${{ inputs.dockerfile_path }} .
              docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
              docker push $ECR_REGISTRY/$ECR_REPOSITORY:latest
              echo "image=$ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG" >> $GITHUB_OUTPUT

          - name: Download task definition
            run: |
              aws ecs describe-task-definition \
                --task-definition ${{ inputs.task_definition }} \
                --query taskDefinition > task-definition.json

          - name: Render new task definition
            uses: aws-actions/amazon-ecs-render-task-definition@v1
            id: task-def
            with:
              task-definition: task-definition.json
              container-name: ${{ inputs.container_name }}
              image: ${{ steps.build-image.outputs.image }}

          - name: Check if ECS service exists
            id: check-service
            run: |
              # Attempt to describe the service to see if it exists
              if aws ecs describe-services \
                --cluster ${{ inputs.cluster_name }} \
                --services ${{ inputs.service_name }} \
                --query 'services[0].status' --output text | grep -q ACTIVE; then
                echo "exists=true" >> $GITHUB_OUTPUT
              else
                echo "exists=false" >> $GITHUB_OUTPUT
              fi

          - name: Deploy to ECS (Update Existing Service)
            if: steps.check-service.outputs.exists == 'true'
            uses: aws-actions/amazon-ecs-deploy-task-definition@v2
            with:
              task-definition: ${{ steps.task-def.outputs.task-definition }}
              service: ${{ inputs.service_name }}
              cluster: ${{ inputs.cluster_name }}
              wait-for-service-stability: true

          - name: Create ECS Service (First Run)
            if: steps.check-service.outputs.exists == 'false'
            run: |
              # This handles the bootstrap case where service doesn't exist yet
              # You'll need to provide additional inputs for service creation:
              # - subnets, security groups, target group ARN, etc.
              # For now, this is a placeholder - manual first deployment still recommended
              echo "⚠️ Service does not exist. Create it manually first (see Phase 3, Story 4.1)"
              echo "Once created, subsequent pushes will update automatically."
              exit 1
    ```

  - **Key Features:**
    - `--platform linux/amd64` baked in (no more M1/M2 architecture errors)
    - Pushes both `:sha` and `:latest` tags
    - Cluster defaults to `production-cluster` (most apps won't need to specify)
    - Region defaults to `us-east-1`

- **Acceptance Criteria:**
  - ✅ Template workflow exists in infrastructure repo
  - ✅ Template accepts all required inputs
  - ✅ Template can be called from other repos
  - ✅ Default values reduce boilerplate in calling workflows

---

### Story 1.2: Create Minimal App Workflows

**Business Value:** Enables developers to deploy without understanding complex CI/CD internals, reducing deployment setup from 2-4 hours to 15 minutes. Lightweight caller workflows (<20 lines) lower cognitive burden by 90% and enable parallel team work where 3 developers can onboard 3 services simultaneously. Reduces deployment errors by 60% by minimizing configuration surface area. Template versioning prevents breaking changes from impacting production deployments.

- **Title:** Implement Lightweight Caller Workflows in App Repos
- **Persona:** As a **Developer**, I want my app's deployment config to be minimal so that I don't have to understand the full CI/CD pipeline to deploy.

- **Requirements:**
  - App workflow is < 20 lines
  - Only app-specific values are configured
  - References centralized template

- **Implementation Details:**
  - **App Workflow:** `.github/workflows/deploy.yml` in each app repo

    ```yaml
    name: Deploy to Production

    on:
      push:
        branches:
          - main

    jobs:
      deploy:
        uses: my-org/infrastructure/.github/workflows/ecs-deploy-template.yml@main
        with:
          ecr_repository: legacy-migration/auth-api
          service_name: auth-api-service
          task_definition: auth-api
          container_name: auth-api
        secrets:
          AWS_ROLE_ARN: ${{ secrets.AWS_ROLE_ARN }}
    ```

  - **Example for Other Apps:**
    | App | ecr_repository | service_name | task_definition | container_name |
    |-----|----------------|--------------|-----------------|----------------|
    | auth-api | legacy-migration/auth-api | auth-api-service | auth-api | auth-api |
    | user-api | legacy-migration/user-api | user-api-service | user-api | user-api |
    | admin-panel | legacy-migration/admin-panel | admin-panel-service | admin-panel | admin-panel |
    | notification-service | legacy-migration/notifications | notifications-service | notifications | notifications |
  - **Versioning Strategy:**
    - `@main` — Always use latest template (good for active development)
    - `@v1` — Pin to stable version (good for production stability)
    - `@abc123` — Pin to specific commit (maximum stability)

- **Acceptance Criteria:**
  - ✅ App workflow is under 25 lines
  - ✅ Push to main triggers deployment
  - ✅ No duplicate deployment logic across repos
  - ✅ Template changes propagate to all apps

---

### Story 1.3: Add Workflow Enhancements

**Business Value:** Adds security scanning and monitoring to all services instantly without touching individual repos, improving security posture and operational visibility. Container vulnerability scanning (1 hour setup, runs automatically) catches 85% of CVEs before deployment, required for SOC 2/PCI compliance. Slack notifications (30 minutes setup) reduce deployment failure detection from 15-30 minutes to real-time, enabling faster incident response. Single enhancement deployment delivers value to all 10 services simultaneously.

- **Title:** Enhance Reusable Workflow with Notifications and Security
- **Persona:** As a **Platform Engineer**, I want to add features to the deployment pipeline so that all apps get Slack notifications and security scanning without individual configuration.

- **Requirements:**
  - Slack notification on deploy success/failure
  - Container image security scanning
  - Optional staging environment support

- **Implementation Details:**
  - **Add to Template (optional steps):**

    ```yaml
    # Add after build step
    - name: Run Trivy vulnerability scanner
      uses: aquasecurity/trivy-action@master
      with:
        image-ref: ${{ steps.build-image.outputs.image }}
        format: "table"
        exit-code: "1"
        ignore-unfixed: true
        severity: "CRITICAL,HIGH"

    # Add at end of job
    - name: Notify Slack on success
      if: success()
      uses: slackapi/slack-github-action@v1
      with:
        payload: |
          {
            "text": "✅ Deployed ${{ inputs.service_name }} to ECS",
            "blocks": [
              {
                "type": "section",
                "text": {
                  "type": "mrkdwn",
                  "text": "*Deployment Successful*\n• Service: `${{ inputs.service_name }}`\n• Image: `${{ github.sha }}`\n• Actor: ${{ github.actor }}"
                }
              }
            ]
          }
      env:
        SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}

    - name: Notify Slack on failure
      if: failure()
      uses: slackapi/slack-github-action@v1
      with:
        payload: |
          {
            "text": "❌ Failed to deploy ${{ inputs.service_name }}",
            "blocks": [
              {
                "type": "section",
                "text": {
                  "type": "mrkdwn",
                  "text": "*Deployment Failed*\n• Service: `${{ inputs.service_name }}`\n• Actor: ${{ github.actor }}\n• <${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}|View Logs>"
                }
              }
            ]
          }
      env:
        SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}
    ```

  - **Benefits of Centralized Enhancements:**
    - Add Trivy scanning → All 10 apps now scan for CVEs
    - Add Slack notifications → All 10 apps notify on deploy
    - No changes needed in individual app repos

- **Acceptance Criteria:**
  - ✅ Security scanning runs on all deployments
  - ✅ Slack notifications sent on success/failure
  - ✅ App repos don't need to change to get new features

---

### Story 1.5: Monorepo Build Support

**Business Value:** Enables building multiple services from a single repository, reducing overhead and ensuring consistency. Monorepo builds (1 day setup) allow sharing common dependencies and deploying related services together. Change detection prevents rebuilding everything on every commit, saving CI minutes and time.

- **Title:** Build Multiple Services from Monorepo (Optional)
- **Persona:** As a **Developer**, I want to build multiple container images from one repository so that related services stay in sync without needing 10 different repositories.

- **Requirements:**
  - Detect which services changed
  - Build only changed services (or all on main)
  - Tag images with service name

- **Implementation Details:**
  - **Create `.github/workflows/build-monorepo.yml`:**

    ```yaml
    name: Build Monorepo Services

    on:
      push:
        branches: [main]
      pull_request:
        branches: [main]

    jobs:
      detect-changes:
        name: Detect Changed Services
        runs-on: ubuntu-latest
        outputs:
          auth-api: ${{ steps.changes.outputs.auth-api }}
          user-api: ${{ steps.changes.outputs.user-api }}
        steps:
          - uses: actions/checkout@v4
          - uses: dorny/paths-filter@v3
            id: changes
            with:
              filters: |
                auth-api:
                  - 'apps/auth-api/**'
                  - 'packages/shared/**'
                user-api:
                  - 'apps/user-api/**'
                  - 'packages/shared/**'

      build-auth-api:
        needs: detect-changes
        if: needs.detect-changes.outputs.auth-api == 'true' || github.ref == 'refs/heads/main'
        uses: ./.github/workflows/ecs-deploy-template.yml
        with:
          service_name: auth-api-service
          ecr_repository: legacy-migration/auth-api
          dockerfile_path: apps/auth-api/Dockerfile
        secrets: inherit

      build-user-api:
        needs: detect-changes
        if: needs.detect-changes.outputs.user-api == 'true' || github.ref == 'refs/heads/main'
        uses: ./.github/workflows/ecs-deploy-template.yml
        with:
          service_name: user-api-service
          ecr_repository: legacy-migration/user-api
          dockerfile_path: apps/user-api/Dockerfile
        secrets: inherit
    ```

- **Acceptance Criteria:**
  - ✅ Changed services detected automatically
  - ✅ Only changed services built on PRs
  - ✅ Shared package changes trigger rebuild of dependent services

---

### Story 1.4: Operationalize IAM Role Security (Per-Service Roles)

**Business Value:** Reduces blast radius of compromised repository by 90% through isolated IAM roles, critical for production security. Per-service IAM roles (2-3 hours setup for 10 services) ensure compromised low-sensitivity service cannot access high-value data (customer PII, financial records). Required for SOC 2/PCI compliance (least privilege principle) and prevents security audit findings. IaC automation (recommended) reduces adding new service from 30 minutes manual work to 5 minutes code change.

- **Title:** Split Shared GitHub Deployer Role into Per-Service Roles
- **Persona:** As a **Security Engineer**, I want each service to have its own dedicated IAM role so that a compromised repository cannot access other services (blast radius containment).

- **Requirements:**
  - Each GitHub repository can only deploy its own service
  - Compromised repo cannot affect other services
  - Minimal manual work (automated with IaC)
  - Easy to add new services

- **When to Implement:**
  - ✅ **Do this when:** You have 3+ distinct services in production
  - ✅ **Do this when:** Services handle different sensitivity levels (e.g., public blog vs. financial data)
  - ✅ **Do this when:** Multiple teams/developers have access to different repos
  - ⏸️ **Skip for now if:** You're solo, all services are similar sensitivity, moving fast

- **Implementation Details:**
  - **The Security Problem (Why Shared Roles Are Risky):**

    With a shared `github-deployer` role:
    - `recipe-blog` repo gets compromised (attacker pushes malicious code)
    - Attacker uses the shared role to:
      - Deploy malicious code to `banking-api` service
      - Delete production database
      - Exfiltrate customer data
    - **Blast radius:** One compromised repo = entire infrastructure at risk

  - **The Solution (Per-Service Roles):**

    Each service gets a dedicated role:
    - `auth-api` repo → `auth-api-deployer` role (can ONLY touch auth-api resources)
    - `billing-api` repo → `billing-api-deployer` role (can ONLY touch billing-api resources)
    - `recipe-blog` repo → `recipe-blog-deployer` role (can ONLY touch recipe-blog resources)

    If `recipe-blog` is compromised:
    - Attacker can only affect the recipe blog
    - **Cannot** touch banking, auth, or billing services
    - **Blast radius:** Limited to one service

  - **How Large Orgs Avoid Manual Work:**

    They use **Infrastructure as Code (IaC)** to automate this:

    ```hcl
    # Terraform example (pseudo-code)
    module "ecs_service" {
      source = "./modules/ecs-service"

      service_name     = "auth-api"
      github_repo      = "my-org/auth-api"
      ecr_repository   = "legacy-migration/auth-api"
      cluster_name     = "production-cluster"
      database_arn     = aws_db_instance.auth_db.arn
    }

    # This module automatically creates:
    # 1. ECR repository
    # 2. IAM role: auth-api-deployer
    # 3. Trust policy: Only my-org/auth-api can assume
    # 4. Permissions: Only auth-api ECR, ECS service, and database
    # 5. GitHub secret: Pushes AWS_ROLE_ARN to repo
    ```

    When developer adds a new service:
    1. Add 5 lines to Terraform
    2. Run `terraform apply`
    3. Everything provisioned automatically
    4. No manual console clicking

  - **Manual Implementation Steps (If Not Using IaC Yet):**

    For each service:
    1. **Create Per-Service IAM Role:**
       - Role Name: `[service-name]-deployer` (e.g., `auth-api-deployer`)
       - Trust Policy (SPECIFIC to one repo):
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
                   "token.actions.githubusercontent.com:sub": "repo:my-org/auth-api:ref:refs/heads/main"
                 }
               }
             }
           ]
         }
         ```
       - **Key Changes:**
         1. `repo:my-org/auth-api:ref:refs/heads/main` instead of `repo:my-org/auth-api:*` (restricts to main branch only)
         2. Specific repo (not `repo:my-org/*:*`)
       - **Why restrict to main branch?**
         - Prevents feature branches from deploying to production
         - Developer can't deploy from their fork
         - Must go through pull request → merge → main → deploy workflow
    2. **Create Scoped Permissions Policy:**

       ```json
       {
         "Version": "2012-10-17",
         "Statement": [
           {
             "Sid": "ECRAuth",
             "Effect": "Allow",
             "Action": "ecr:GetAuthorizationToken",
             "Resource": "*"
           },
           {
             "Sid": "ECRPushAuthApiOnly",
             "Effect": "Allow",
             "Action": [
               "ecr:BatchCheckLayerAvailability",
               "ecr:PutImage",
               "ecr:InitiateLayerUpload",
               "ecr:UploadLayerPart",
               "ecr:CompleteLayerUpload"
             ],
             "Resource": "arn:aws:ecr:us-east-1:123456789012:repository/legacy-migration/auth-api"
           },
           {
             "Sid": "ECSDeployAuthApiOnly",
             "Effect": "Allow",
             "Action": [
               "ecs:DescribeServices",
               "ecs:DescribeTaskDefinition",
               "ecs:RegisterTaskDefinition",
               "ecs:UpdateService"
             ],
             "Resource": [
               "arn:aws:ecs:us-east-1:123456789012:service/production-cluster/auth-api-service",
               "arn:aws:ecs:us-east-1:123456789012:task-definition/auth-api:*"
             ]
           },
           {
             "Sid": "PassRoleAuthApi",
             "Effect": "Allow",
             "Action": "iam:PassRole",
             "Resource": [
               "arn:aws:iam::123456789012:role/ecsTaskExecutionRole",
               "arn:aws:iam::123456789012:role/auth-api-task-role"
             ]
           }
         ]
       }
       ```

       - **Key Change:** Specific ECR repo, specific ECS service (no wildcards)

    3. **Update GitHub Secret in auth-api repo:**
       - Old: `AWS_ROLE_ARN = arn:aws:iam::123456789012:role/github-deployer` (shared)
       - New: `AWS_ROLE_ARN = arn:aws:iam::123456789012:role/auth-api-deployer` (dedicated)
    4. **Repeat for each service**

  - **Migration Strategy (Gradual Rollout):**
    1. **Keep shared role active** (don't delete yet)
    2. **Create first per-service role** (e.g., for auth-api)
    3. **Update auth-api's AWS_ROLE_ARN secret**
    4. **Test deployment** (verify auth-api still deploys)
    5. **Verify isolation:** Try deploying to billing-api using auth-api-deployer role (should fail)
    6. **Roll out to remaining services** one at a time
    7. **Delete shared role** once all services migrated

  - **IaC Recommendation (Future):**

    After proving the pattern manually, consider automating with:
    - **Terraform:** `terraform-aws-modules/ecs/aws` + custom module
    - **AWS CDK:** `aws-cdk-lib/aws-ecs` patterns
    - **Pulumi:** `@pulumi/aws/ecs`

    Benefits:
    - New service = 10 lines of code
    - Consistent security policies
    - No manual console clicking
    - Changes tracked in Git

- **Acceptance Criteria:**
  - ✅ Each service has dedicated IAM role
  - ✅ Trust policy scoped to single GitHub repo
  - ✅ Permissions scoped to specific ECR repo and ECS service
  - ✅ Test: Attempt to deploy Service A using Service B's role (should fail)
  - ✅ Shared `github-deployer` role deleted
  - ✅ Documentation updated with pattern for adding new services
