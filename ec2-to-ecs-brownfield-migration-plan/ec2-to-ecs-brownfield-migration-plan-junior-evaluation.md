# EC2 to ECS Fargate Brownfield Migration Plan - Junior Engineer Evaluation

**Prompt**
You are a junior enginner with basic coding and infrastructure knowledge. You're company hosts their node and apps in aws on ec2. There's been talk about migrating from ec2 to ecs farget and you're given a plan and are asked to evaluate it to make sure the details in the plan are sufficient for contingent workers or ai agents to execute. The plan is in the ec2-greenfield-mvp-plan/ in both the value driven plan and technical plan in the ecs greenfield plan

**Evaluator Perspective**: Junior engineer with basic coding and infrastructure knowledge  
**Evaluation Date**: January 26, 2026  
**Purpose**: Assess whether this plan is executable by contingent workers or AI agents without extensive AWS/ECS experience

---

## Executive Summary

**Overall Assessment**: ⭐⭐⭐⭐ (4/5 stars)

**Strengths**: Excellent strategic guidance, comprehensive discovery phase, clear acceptance criteria  
**Gaps**: Missing Infrastructure-as-Code artifacts, incomplete runbooks, limited testing procedures

**Verdict**: The plan is **80% ready** for execution. With Priority 1 additions (IaC templates, complete examples), it becomes **95% executable** by junior engineers or AI agents.

---

## ✅ What Works Really Well

### 1. Discovery Phase is Exceptionally Detailed

- **Phase 0** provides exact AWS CLI commands to audit infrastructure
- Clear explanations of what to look for: "Check: Subnets with route table pointing `0.0.0.0/0` → Internet Gateway"
- Cost implications explained upfront (NAT Gateway: ~$32/month)
- **Rating**: 5/5 - Can execute without prior knowledge

### 2. Acceptance Criteria Eliminate Ambiguity

- Every story has checkboxes: "✅ VPC has at least 2 public subnets in different AZs"
- Clear pass/fail conditions: "✅ Container stops gracefully within 10 seconds when sent SIGTERM"
- No vague requirements like "configure properly" or "set up correctly"
- **Rating**: 5/5 - Know exactly when I'm done

### 3. "Why" Context Prevents Blind Execution

- **PID 1 Problem**: Explains signal forwarding and zombie process reaping
- **NAT Gateway Cost Trap**: Explains why tasks get stuck in PENDING without it
- **Ephemeral Filesystem**: Explains why local file writes break in containers
- Helps troubleshoot when things don't work as expected
- **Rating**: 5/5 - Understand the system, not just following steps

### 4. Code Examples are Production-Ready

- Dockerfile examples with `tini`, multi-stage builds, security best practices
- AWS CLI commands with actual flags: `--platform linux/amd64`
- GitHub Actions workflows with OIDC authentication
- Node.js/Python/Go examples for each pattern
- **Rating**: 4/5 - Can copy-paste and adapt (not always complete)

### 5. Security Best Practices Built In

- Security groups designed with least privilege
- Secrets Manager integration from the start
- OIDC over access keys for GitHub Actions
- VPC endpoint recommendations
- **Rating**: 5/5 - Won't create insecure infrastructure

### 6. Cost Awareness Throughout

- NAT Gateway vs VPC Endpoints comparison tables
- Fargate pricing calculations
- Reserved Instance audit story (Phase 0, Story 8.2)
- CloudWatch Logs retention cost warnings
- **Rating**: 5/5 - Won't accidentally blow the budget

### 7. Appendix Consolidates Best Practices

- CI/CD fundamentals explained
- Security group patterns with examples
- ECS deployment sequence diagram
- Troubleshooting common issues
- **Rating**: 4/5 - Good reference material

### 8. Realistic Migration Approach

- Strangler Fig pattern for gradual cutover
- Rollback planning from the start
- Keeps EC2 running during validation
- Acknowledges complexity (cron jobs, logging consumers)
- **Rating**: 5/5 - Won't cause production outages

---

## 🔴 Critical Gaps That Block Execution

### Gap 1: Infrastructure-as-Code Templates Missing

**Problem**: Plan describes infrastructure but doesn't provide reusable code.

**Examples**:

- **Phase 2, Story 1.1**: "Provision VPC with Public and Private Subnets"
  - Lists CIDR blocks, subnet sizes, tags
  - Doesn't provide Terraform or CloudFormation
- **Phase 2, Story 2.1**: "Provision Shared Internet-Facing Load Balancer"
  - Describes ALB configuration
  - No `aws_lb` Terraform resource or CloudFormation template

**Impact on Execution**:

- ❌ Manual AWS Console clicking = high error rate
- ❌ Typos in CIDR blocks, subnet associations, security group IDs
- ❌ Inconsistent resource naming across team members
- ❌ No version control for infrastructure
- ❌ Can't easily replicate across environments (dev/staging/prod)

**What's Needed**:

```
terraform/
├── vpc.tf                    # VPC, subnets, IGW, NAT, route tables
├── security-groups.tf        # All security groups with rules
├── alb.tf                    # Public and internal ALBs
├── ecs-cluster.tf           # ECS cluster and capacity providers
├── ecr.tf                    # ECR repositories with lifecycle policies
├── iam.tf                    # Task execution roles, task roles
├── secrets.tf                # Secrets Manager resources
├── variables.tf              # Input variables
├── outputs.tf                # Useful outputs (ALB DNS, cluster name)
└── README.md                 # How to use these templates

OR

cloudformation/
├── 01-vpc.yaml
├── 02-security-groups.yaml
├── 03-alb.yaml
├── 04-ecs-cluster.yaml
└── README.md
```

**Severity**: 🔴 **Critical Blocker** - Without this, execution requires expert-level AWS knowledge

**Workaround**: Junior engineer manually creates resources → 3-5x longer, high error rate

---

### Gap 2: Complete Task Definition Templates Missing

**Problem**: Stories describe task definition parameters but don't show complete working JSON.

**Examples**:

- **Phase 3, Story 3.1**: "Create Task Definition"
  - Lists: "Container name, image URI, CPU, memory, port mappings, environment, secrets"
  - Doesn't show a complete JSON structure
- **Secrets injection**: Explained conceptually but not shown in context

**What's in the Plan**:

```
"Add environment variables for non-sensitive config"
"Add secrets from Secrets Manager for sensitive values"
"Configure awslogs for CloudWatch logging"
```

**What's Needed**:

```json
{
  "family": "REPLACE_APP_NAME",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "arn:aws:iam::ACCOUNT_ID:role/ecsTaskExecutionRole",
  "taskRoleArn": "arn:aws:iam::ACCOUNT_ID:role/REPLACE_APP_NAME-task-role",
  "containerDefinitions": [
    {
      "name": "REPLACE_APP_NAME",
      "image": "ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/REPLACE_APP_NAME:latest",
      "portMappings": [
        {
          "containerPort": 3000,
          "protocol": "tcp"
        }
      ],
      "environment": [
        {
          "name": "NODE_ENV",
          "value": "production"
        },
        {
          "name": "LOG_LEVEL",
          "value": "info"
        }
      ],
      "secrets": [
        {
          "name": "DB_PASSWORD",
          "valueFrom": "arn:aws:secretsmanager:REGION:ACCOUNT_ID:secret:REPLACE_APP_NAME/db-password"
        },
        {
          "name": "API_KEY",
          "valueFrom": "arn:aws:secretsmanager:REGION:ACCOUNT_ID:secret:REPLACE_APP_NAME/api-key"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/REPLACE_APP_NAME",
          "awslogs-region": "REGION",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "healthCheck": {
        "command": [
          "CMD-SHELL",
          "curl -f http://localhost:3000/health || exit 1"
        ],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 60
      },
      "linuxParameters": {
        "initProcessEnabled": true
      }
    }
  ]
}
```

**Additional Templates Needed**:

- `task-definitions/web-service-template.json` - Standard web app
- `task-definitions/worker-service-template.json` - Background worker
- `task-definitions/scheduled-task-template.json` - Cron job
- `task-definitions/sidecar-datadog-template.json` - With APM sidecar

**Severity**: 🔴 **Critical Blocker** - JSON syntax errors will cause cryptic ECS failures

**Workaround**: Junior engineer writes JSON from scratch → high error rate, missing required fields

---

### Gap 3: GitHub Actions Workflows Incomplete

**Problem**: Workflow examples are scattered and not production-complete.

**What's in the Plan**:

- **Phase 3, Story 6.1**: Workflow concept mentioned
- **Phase 4, Story 1.1**: Reusable workflow example (partial)
- **Appendix**: OIDC authentication explained (conceptual)

**Missing Pieces**:

- Error handling (what if Docker build fails?)
- Slack notifications on success/failure
- Manual approval for production deployments
- Rollback procedure
- Integration with secrets for API keys

**What's Needed**:

```yaml
# .github/workflows/deploy-production.yml
name: Deploy to Production ECS

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    name: Build and Deploy
    runs-on: ubuntu-latest
    environment: production

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Configure AWS credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: us-east-1

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build, tag, and push image
        id: build-image
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          ECR_REPOSITORY: legacy-migration/auth-api
          IMAGE_TAG: ${{ github.sha }}
        run: |
          docker build \
            --platform linux/amd64 \
            -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG \
            -t $ECR_REGISTRY/$ECR_REPOSITORY:latest \
            .
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:latest
          echo "image=$ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG" >> $GITHUB_OUTPUT

      - name: Download current task definition
        run: |
          aws ecs describe-task-definition \
            --task-definition auth-api \
            --query taskDefinition > task-definition.json

      - name: Update task definition with new image
        id: task-def
        uses: aws-actions/amazon-ecs-render-task-definition@v1
        with:
          task-definition: task-definition.json
          container-name: auth-api
          image: ${{ steps.build-image.outputs.image }}

      - name: Deploy to ECS
        uses: aws-actions/amazon-ecs-deploy-task-definition@v2
        with:
          task-definition: ${{ steps.task-def.outputs.task-definition }}
          service: auth-api-service
          cluster: production-cluster
          wait-for-service-stability: true

      - name: Notify Slack on Success
        if: success()
        uses: slackapi/slack-github-action@v1
        with:
          webhook-url: ${{ secrets.SLACK_WEBHOOK_URL }}
          payload: |
            {
              "text": "✅ Deployed auth-api to production",
              "blocks": [
                {
                  "type": "section",
                  "text": {
                    "type": "mrkdwn",
                    "text": "✅ *Production Deployment Successful*\n*Service:* auth-api\n*Commit:* <${{ github.event.head_commit.url }}|${{ github.sha }}>\n*Author:* ${{ github.actor }}"
                  }
                }
              ]
            }

      - name: Notify Slack on Failure
        if: failure()
        uses: slackapi/slack-github-action@v1
        with:
          webhook-url: ${{ secrets.SLACK_WEBHOOK_URL }}
          payload: |
            {
              "text": "❌ Failed to deploy auth-api to production",
              "blocks": [
                {
                  "type": "section",
                  "text": {
                    "type": "mrkdwn",
                    "text": "❌ *Production Deployment Failed*\n*Service:* auth-api\n*Commit:* <${{ github.event.head_commit.url }}|${{ github.sha }}>\n*Author:* ${{ github.actor }}\n*Logs:* <${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}|View Logs>"
                  }
                }
              ]
            }
```

**Also Need**:

- `.github/workflows/reusable-ecs-deploy.yml` - The template from Phase 4
- `.github/workflows/rollback.yml` - Emergency rollback workflow
- `.github/workflows/build-test.yml` - PR validation

**Severity**: 🔴 **Critical Blocker** - CI/CD is essential for repeatable deployments

**Workaround**: Manual deployments via AWS CLI → error-prone, not auditable

---

### Gap 4: Secrets Migration Procedure Incomplete

**Problem**: Conceptual guidance exists, but no step-by-step migration script.

**What's in the Plan**:

- **Phase 0, Story 5.1**: "Inventory secrets, categorize, plan storage"
- **Phase 1, Story 2.1**: "App reads from environment variables"
- **Phase 2, Story 4.1**: "Create secrets in Secrets Manager"

**What's Missing**:

1. How to extract secrets from current EC2 `.env` files
2. Exact AWS CLI commands to create each secret
3. Naming convention enforcement
4. Bulk import script

**What's Needed**:

```bash
#!/bin/bash
# scripts/migrate-secrets-to-aws.sh
#
# Purpose: Import secrets from .env file to AWS Secrets Manager
# Usage: ./migrate-secrets-to-aws.sh production auth-api /path/to/.env

set -euo pipefail

ENVIRONMENT=$1      # production, staging, dev
APP_NAME=$2         # auth-api, test-api-1, etc.
ENV_FILE=$3         # Path to .env file
AWS_REGION=${AWS_REGION:-us-east-1}

echo "🔐 Migrating secrets for $APP_NAME ($ENVIRONMENT) to AWS Secrets Manager"

# Parse .env file and create secrets
while IFS='=' read -r key value; do
  # Skip comments and empty lines
  [[ "$key" =~ ^#.*$ ]] && continue
  [[ -z "$key" ]] && continue

  # Remove quotes from value
  value=$(echo "$value" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")

  # Create secret in Secrets Manager
  SECRET_NAME="/$ENVIRONMENT/$APP_NAME/$key"

  echo "Creating secret: $SECRET_NAME"

  aws secretsmanager create-secret \
    --name "$SECRET_NAME" \
    --secret-string "$value" \
    --region "$AWS_REGION" \
    --tags Key=Environment,Value="$ENVIRONMENT" \
           Key=Application,Value="$APP_NAME" \
           Key=ManagedBy,Value=script \
    2>/dev/null || \
  aws secretsmanager update-secret \
    --secret-id "$SECRET_NAME" \
    --secret-string "$value" \
    --region "$AWS_REGION"

  echo "✅ Created/Updated: $SECRET_NAME"
done < "$ENV_FILE"

echo ""
echo "✅ All secrets migrated!"
echo ""
echo "📋 Next steps:"
echo "1. Update task definition to reference these secrets"
echo "2. Grant task execution role access:"
echo "   aws iam attach-role-policy \\"
echo "     --role-name ecsTaskExecutionRole \\"
echo "     --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite"
echo ""
echo "3. Test by running a task and checking env vars:"
echo "   aws ecs run-task --cluster production-cluster --task-definition $APP_NAME"
```

**Also Need**:

- `scripts/verify-secrets.sh` - Validate all secrets exist
- `scripts/rotate-secret.sh` - Secret rotation helper
- Documentation on naming conventions

**Severity**: 🟠 **High Priority** - Secrets are required; manual creation is error-prone

**Workaround**: Manually create secrets via Console → typos in secret names break deployments

---

### Gap 5: Database Migration Strategy Undefined

**Problem**: Plan mentions database considerations but no concrete migration procedure.

**What's in the Plan**:

- **Phase 0, Story 10.1**: "Avoid database migrations that break backward compatibility during cutover window"
- **Phase 1**: Application changes only
- **No dedicated story for database migrations**

**What's Missing**:

1. Where do database migrations run? (EC2, ECS, CI/CD pipeline?)
2. How to handle when both EC2 and ECS are running (during Strangler Fig)?
3. What if migration fails mid-execution?
4. How to test migrations safely?

**What's Needed**:

**Database Migration Playbook**:

````markdown
## Database Migration Strategy During ECS Transition

### Pre-Migration Phase (Before any ECS deployment)

1. **Audit Current Migration Tool**
   - Tool: [Flyway, Liquibase, Alembic, Rails migrations, etc.]
   - Current execution: [Cron on EC2, manual SSH, CI/CD?]

2. **Create Migration Task Definition**
   ```json
   {
     "family": "auth-api-migrations",
     "networkMode": "awsvpc",
     "requiresCompatibilities": ["FARGATE"],
     "cpu": "256",
     "memory": "512",
     "containerDefinitions": [
       {
         "name": "migrations",
         "image": "ECR_URI:latest",
         "command": ["npm", "run", "migrate"],
         "environment": [{ "name": "NODE_ENV", "value": "production" }],
         "secrets": [
           /* DB credentials */
         ],
         "logConfiguration": {
           /* CloudWatch logs */
         }
       }
     ]
   }
   ```
````

3. **Test Migration Task**

   ```bash
   # Run migration task manually
   aws ecs run-task \
     --cluster production-cluster \
     --task-definition auth-api-migrations \
     --launch-type FARGATE \
     --network-configuration "awsvpcConfiguration={
       subnets=[subnet-xxx],
       securityGroups=[sg-database-access],
       assignPublicIp=DISABLED
     }"

   # Check logs
   aws logs tail /ecs/auth-api-migrations --follow
   ```

### During Strangler Fig (EC2 + ECS Running Simultaneously)

**Rules**:

- ✅ Additive changes only (new columns, new tables)
- ✅ Use default values for new columns
- ❌ No column renames (breaks old code)
- ❌ No column deletions (breaks old code)
- ❌ No data type changes (breaks old code)

**Example Safe Migration**:

```sql
-- ✅ SAFE: Add new column with default
ALTER TABLE users ADD COLUMN email_verified BOOLEAN DEFAULT FALSE;

-- ❌ UNSAFE: Rename column (old code breaks)
ALTER TABLE users RENAME COLUMN name TO full_name;
```

**Migration Execution**:

1. Run migration from ECS task (not EC2)
2. EC2 code ignores new column (backward compatible)
3. ECS code uses new column
4. After EC2 decommissioned, run cleanup migrations

### Post-Migration (ECS Only)

**Now safe to do**:

- Column renames
- Column deletions
- Data type changes
- Non-backward-compatible schema changes

**Execution via GitHub Actions**:

```yaml
jobs:
  migrate:
    runs-on: ubuntu-latest
    steps:
      - name: Run Database Migrations
        run: |
          aws ecs run-task \
            --cluster production-cluster \
            --task-definition auth-api-migrations \
            --launch-type FARGATE \
            --network-configuration "..."

          # Wait for task to complete
          # Check exit code
          # Fail deployment if migration fails
```

### Emergency Rollback

**If migration breaks production**:

```bash
# 1. Revert DNS to EC2
aws route53 change-resource-record-sets --hosted-zone-id XXX --change-batch file://rollback-dns.json

# 2. Run rollback migration
aws ecs run-task \
  --task-definition auth-api-migrations-rollback \
  --overrides '{"containerOverrides":[{"name":"migrations","command":["npm","run","migrate:rollback"]}]}'

# 3. Verify EC2 application works
curl https://api.example.com/health
```

````

**Severity**: 🟠 **High Priority** - Database migrations are risky; need clear procedure

**Workaround**: Ad-hoc migrations → high risk of breaking production

---

### Gap 6: Testing Procedures Missing

**Problem**: No clear testing strategy for each phase.

**What's Missing**:
- **Phase 1**: How to validate Dockerized app works locally?
- **Phase 2**: How to test VPC/ALB setup before deploying apps?
- **Phase 3**: How to smoke-test ECS deployment before DNS cutover?
- **Phase 4**: Load testing before scaling to 100% traffic

**What's Needed**:

**Phase 1 Testing Checklist**:
```markdown
## Phase 1: Application Readiness Testing

### Local Docker Testing
- [ ] `docker build -t my-app .` succeeds without errors
- [ ] `docker run -p 3000:3000 my-app` starts successfully
- [ ] `curl http://localhost:3000/health` returns 200 OK
- [ ] App connects to local database in docker-compose
- [ ] Sessions persist across container restarts (Redis test)
- [ ] File uploads go to S3, not local filesystem
- [ ] `docker stop my-app` completes within 10 seconds (SIGTERM test)
- [ ] No zombie processes: `docker exec my-app ps aux | grep defunct`

### Environment Variable Testing
- [ ] App starts with minimal env vars
- [ ] Missing required env var shows clear error message
- [ ] Changing DB_HOST connects to different database
- [ ] `docker history my-app | grep PASSWORD` shows no secrets

### Multi-Architecture Testing (if using Graviton)
- [ ] Image builds for both amd64 and arm64
- [ ] App works on both architectures
````

**Phase 3 Testing Checklist**:

````markdown
## Phase 3: Initial Deployment Testing

### Pre-DNS Cutover Testing

1. **Direct ALB Access**

   ```bash
   # Get ALB DNS name
   ALB_DNS=$(aws elbv2 describe-load-balancers \
     --names fargate-shared-alb \
     --query 'LoadBalancers[0].DNSName' --output text)

   # Test health endpoint
   curl -H "Host: auth-api.example.com" http://$ALB_DNS/health

   # Expected: 200 OK
   ```
````

2. **Smoke Tests**

   ```bash
   # Login flow
   curl -X POST -H "Host: auth-api.example.com" \
     http://$ALB_DNS/api/login \
     -d '{"username":"test","password":"test"}'

   # Expected: Session token returned

   # Database connectivity
   curl -H "Host: auth-api.example.com" http://$ALB_DNS/api/users

   # Expected: Data from RDS
   ```

3. **Load Testing**

   ```bash
   # Install hey or ab
   go install github.com/rakyll/hey@latest

   # Run load test (1000 requests, 10 concurrent)
   hey -n 1000 -c 10 \
     -H "Host: auth-api.example.com" \
     http://$ALB_DNS/health

   # Monitor:
   # - CloudWatch Logs for errors
   # - ECS Service CPU/Memory metrics
   # - RDS connections
   ```

4. **Chaos Testing**

   ```bash
   # Kill a task, verify ECS restarts it
   TASK_ARN=$(aws ecs list-tasks --cluster production-cluster \
     --service auth-api-service --query 'taskArns[0]' --output text)

   aws ecs stop-task --cluster production-cluster --task $TASK_ARN

   # Expected: New task starts within 60 seconds, no downtime
   ```

### Post-DNS Cutover Validation

- [ ] DNS resolves to ALB: `dig auth-api.example.com`
- [ ] HTTPS works: `curl https://auth-api.example.com/health`
- [ ] User sessions maintained
- [ ] No errors in CloudWatch Logs
- [ ] Metrics show traffic on ECS, not EC2

````

**Severity**: 🟠 **High Priority** - Testing prevents production issues

**Workaround**: Deploy without testing → discover issues in production

---

### Gap 7: Strangler Fig Implementation Details Missing

**Problem**: Concept explained well but no concrete implementation steps.

**What's in the Plan**:
- **Phase 4, Feature 3**: Strangler Fig pattern described
- Weighted routing mentioned
- Rollback capability discussed

**What's Missing**:
- Exact CLI commands to set target group weights
- Monitoring during gradual cutover
- Automation script for weight changes
- Rollback procedure if error rate spikes

**What's Needed**:

```bash
#!/bin/bash
# scripts/gradual-cutover.sh
#
# Purpose: Gradually shift traffic from EC2 to ECS using weighted target groups
# Usage: ./gradual-cutover.sh auth-api

set -euo pipefail

APP_NAME=$1
INTERNAL_ALB_ARN="arn:aws:elasticloadbalancing:..."
EC2_TARGET_GROUP_ARN="arn:aws:elasticloadbalancing:.../targetgroup/auth-api-ec2-tg/..."
ECS_TARGET_GROUP_ARN="arn:aws:elasticloadbalancing:.../targetgroup/auth-api-ecs-tg/..."

# Weight stages: 5% -> 25% -> 50% -> 75% -> 100%
STAGES=(5 25 50 75 100)

set_weights() {
  local ecs_weight=$1
  local ec2_weight=$((100 - ecs_weight))

  echo "🔄 Setting weights: EC2=$ec2_weight%, ECS=$ecs_weight%"

  aws elbv2 modify-rule \
    --rule-arn "$LISTENER_RULE_ARN" \
    --actions \
      Type=forward,ForwardConfig="{
        TargetGroups=[
          {TargetGroupArn=$EC2_TARGET_GROUP_ARN,Weight=$ec2_weight},
          {TargetGroupArn=$ECS_TARGET_GROUP_ARN,Weight=$ecs_weight}
        ],
        TargetGroupStickinessConfig={Enabled=true,DurationSeconds=3600}
      }"
}

check_error_rate() {
  local threshold=5  # 5% error rate threshold

  # Query CloudWatch for 5xx errors in last 5 minutes
  local error_count=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/ApplicationELB \
    --metric-name HTTPCode_Target_5XX_Count \
    --dimensions Name=TargetGroup,Value="${ECS_TARGET_GROUP_ARN##*/}" \
    --start-time $(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%S) \
    --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
    --period 300 \
    --statistics Sum \
    --query 'Datapoints[0].Sum' --output text)

  local request_count=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/ApplicationELB \
    --metric-name RequestCount \
    --dimensions Name=TargetGroup,Value="${ECS_TARGET_GROUP_ARN##*/}" \
    --start-time $(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%S) \
    --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
    --period 300 \
    --statistics Sum \
    --query 'Datapoints[0].Sum' --output text)

  local error_rate=$(echo "scale=2; ($error_count / $request_count) * 100" | bc)

  echo "📊 Error rate: $error_rate%"

  if (( $(echo "$error_rate > $threshold" | bc -l) )); then
    echo "🚨 ERROR RATE EXCEEDED THRESHOLD! Rolling back..."
    return 1
  fi

  return 0
}

# Main cutover loop
for stage in "${STAGES[@]}"; do
  echo ""
  echo "========================================="
  echo "Stage: $stage% ECS traffic"
  echo "========================================="

  set_weights "$stage"

  echo "⏳ Waiting 5 minutes for metrics..."
  sleep 300

  if ! check_error_rate; then
    echo "❌ Cutover failed at $stage%. Rolling back to 0%..."
    set_weights 0
    exit 1
  fi

  echo "✅ Stage $stage% completed successfully"

  if [ "$stage" -eq 100 ]; then
    echo ""
    echo "🎉 Cutover complete! 100% traffic on ECS."
    echo "⚠️  Monitor for 24 hours before decommissioning EC2."
  else
    echo "   Proceeding to next stage in 30 seconds..."
    sleep 30
  fi
done
````

**Also Need**:

- `scripts/rollback-to-ec2.sh` - Emergency rollback
- CloudWatch dashboard showing both target groups
- Runbook for manual intervention

**Severity**: 🟡 **Medium Priority** - Can do manually but automation reduces risk

**Workaround**: Manual weight changes → slower, no safety checks

---

### Gap 8: Rollback Procedures are High-Level

**Problem**: Rollback strategy discussed but not step-by-step.

**What's in the Plan**:

- **Phase 0, Story 10.1**: "Keep EC2 running for 1-2 weeks post-migration"
- "Use DNS-based cutover (easy to revert)"
- "Rollback triggers: Error rate above X%, latency above X ms"

**What's Missing**:

- Exact commands to execute rollback
- Who executes (on-call engineer, junior engineer, automated?)
- Communication templates (Slack, email)
- Validation after rollback

**What's Needed**:

````markdown
## Emergency Rollback Runbook

### When to Execute Rollback

**Automatic Triggers** (if implemented):

- 5xx error rate > 5% for 5 minutes
- p95 latency > 2000ms for 5 minutes
- ECS task crash loop (3 failures in 5 minutes)

**Manual Decision**:

- Critical functionality broken (cannot login, checkout, etc.)
- Data integrity issues detected
- Unrecoverable application errors
- Stakeholder directive

### Rollback Procedure (DNS Cutover Method)

**Time to Complete**: ~5 minutes  
**Requires**: AWS CLI access, Route53 permissions

#### Step 1: Prepare Rollback DNS Change

```bash
# Get current DNS record
aws route53 list-resource-record-sets \
  --hosted-zone-id Z1234567890ABC \
  --query "ResourceRecordSets[?Name=='auth-api.example.com.']"

# Save as rollback-dns.json:
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "auth-api.example.com",
      "Type": "CNAME",
      "TTL": 60,
      "ResourceRecords": [{"Value": "ec2-instance-dns.amazonaws.com"}]
    }
  }]
}
```
````

#### Step 2: Execute Rollback

```bash
# Update DNS to point back to EC2
aws route53 change-resource-record-sets \
  --hosted-zone-id Z1234567890ABC \
  --change-batch file://rollback-dns.json

# Get change ID
CHANGE_ID=$(aws route53 list-resource-record-sets ...)

echo "✅ DNS updated. Change ID: $CHANGE_ID"
echo "⏳ Waiting 60 seconds for propagation..."
sleep 60
```

#### Step 3: Verify EC2 is Receiving Traffic

```bash
# Check EC2 instance
ssh ec2-user@ec2-instance "tail -f /var/log/nginx/access.log"

# Should see new requests appearing

# Test directly
curl https://auth-api.example.com/health

# Expected: 200 OK from EC2
```

#### Step 4: Scale Down ECS (Optional)

```bash
# Stop receiving new requests
aws ecs update-service \
  --cluster production-cluster \
  --service auth-api-service \
  --desired-count 0

# Tasks will drain over next 5-10 minutes
```

#### Step 5: Notify Team

```bash
# Slack notification
curl -X POST $SLACK_WEBHOOK_URL \
  -H 'Content-Type: application/json' \
  -d '{
    "text": "🚨 ROLLBACK EXECUTED: auth-api reverted to EC2",
    "blocks": [{
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*Rollback Details*\n• Service: auth-api\n• Reason: [ERROR_RATE_THRESHOLD / MANUAL_DECISION]\n• Executed by: @oncall-engineer\n• Time: $(date)\n• Status: ✅ Complete - EC2 serving traffic"
      }
    }]
  }'
```

#### Step 6: Post-Rollback Validation

- [ ] Error rate returned to normal
- [ ] User logins working
- [ ] Critical transactions successful
- [ ] No database corruption
- [ ] CloudWatch Logs show EC2 traffic

### Post-Rollback Actions

1. Root cause analysis (why did ECS deployment fail?)
2. Fix issue in staging environment
3. Re-test before attempting migration again
4. Update runbook with lessons learned

````

**Severity**: 🟡 **Medium Priority** - Rollback is crucial but less urgent than initial deployment

**Workaround**: Manual rollback → slower, higher stress during incident

---

### Gap 9: KrakenD Gateway Migration Undefined

**Problem**: Architecture diagrams show KrakenD but no migration story.

**What's in the Plan**:
- **Overview**: Diagrams show KrakenD on both EC2 and ECS
- Mentioned as "API Gateway" but no dedicated migration story

**What's Missing**:
- How to containerize KrakenD
- Configuration file strategy (baked in vs. external?)
- Testing KrakenD routing before cutover
- Health check configuration
- Backward compatibility with EC2 backend

**What's Needed**:

```markdown
## Feature X: Migrate KrakenD API Gateway

### Story X.1: Containerize KrakenD

**Requirements**:
- KrakenD running in Docker container
- Configuration externalized
- Health check endpoint
- Supports both EC2 and ECS backends during migration

**Implementation**:

**Dockerfile**:
```dockerfile
FROM devopsfaith/krakend:2.5

# Copy configuration
COPY krakend.json /etc/krakend/krakend.json

# Expose port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:8080/__health || exit 1

# Start KrakenD
ENTRYPOINT ["/usr/bin/krakend"]
CMD ["run", "-c", "/etc/krakend/krakend.json"]
````

**Configuration Template** (`krakend.json`):

```json
{
  "version": 3,
  "port": 8080,
  "endpoints": [
    {
      "endpoint": "/auth-api/{path}",
      "method": "GET",
      "backend": [
        {
          "url_pattern": "/{path}",
          "host": ["{{ env "AUTH_API_BACKEND" }}"],
          "method": "GET"
        }
      ]
    }
  ]
}
```

**Environment-based backend switching**:

- EC2: `AUTH_API_BACKEND=http://10.100.5.23:3000`
- ECS: `AUTH_API_BACKEND=http://internal-alb.example.local/auth-api`

**Acceptance Criteria**:

- [ ] KrakenD starts in Docker
- [ ] Routes to EC2 backend successfully
- [ ] Routes to ECS backend successfully
- [ ] Health check passes
- [ ] Configuration reloads without restart

```

**Severity**: 🟡 **Medium Priority** - Needed if KrakenD is in your architecture

**Workaround**: Keep KrakenD on EC2 → Single point of failure remains

---

## ⚠️ Minor Issues

### 1. Version Numbers Missing
- "Use Node 20" → Should be "Node 20.11.0 LTS"
- "Python 3.11" → Should be "Python 3.11.7"
- Could lead to inconsistencies across team

### 2. Region Hardcoded
- Plan assumes `us-east-1` throughout
- What if company uses `eu-west-1` or `ap-southeast-1`?
- Should parameterize region

### 3. Team Size Assumptions Unclear
- Some stories say "for POC" vs "for production"
- Which applies to our migration?
- Should clarify at the start

### 4. Monitoring Dashboards Not Provided
- CloudWatch dashboards mentioned but no JSON exports
- Datadog dashboards mentioned but no templates
- Would help with observability

### 5. Cost Calculator Missing
- Pricing mentioned throughout
- No spreadsheet to estimate total costs
- Would help with budget approval

### 6. No Terraform State Management Guidance
- If using Terraform, need backend configuration
- S3 + DynamoDB for state locking
- Multi-environment strategy

---

## 📊 Priority Matrix for Making Plan Executable

### Priority 1: Critical Blockers (Must Have)
These prevent execution entirely. Add these first.

| Gap | Artifact Needed | Estimated LOE | Impact |
|-----|----------------|---------------|---------|
| **Infrastructure-as-Code** | Complete Terraform/CloudFormation modules | 2-3 days | 🔴 Critical |
| **Task Definition Templates** | JSON templates for web/worker/cron | 4-8 hours | 🔴 Critical |
| **GitHub Actions Workflows** | Complete, tested workflow files | 1 day | 🔴 Critical |
| **Secrets Migration Script** | Bash script with validation | 4 hours | 🔴 Critical |

**If you add Priority 1 items**: Plan becomes 80% executable by junior engineers

---

### Priority 2: High Value (Should Have)
These significantly reduce risk and time-to-completion.

| Gap | Artifact Needed | Estimated LOE | Impact |
|-----|----------------|---------------|---------|
| **Testing Procedures** | Checklists for each phase | 4-6 hours | 🟠 High |
| **Database Migration Playbook** | Runbook with examples | 6-8 hours | 🟠 High |
| **Rollback Runbooks** | Step-by-step emergency procedures | 4 hours | 🟠 High |
| **Strangler Fig Script** | Automated weight shifting with safety | 6-8 hours | 🟠 High |

**If you add Priority 2 items**: Plan becomes 95% executable with minimal support

---

### Priority 3: Nice to Have (Could Have)
These improve quality of life but aren't blockers.

| Gap | Artifact Needed | Estimated LOE | Impact |
|-----|----------------|---------------|---------|
| **KrakenD Migration** | Dockerfile + config examples | 4 hours | 🟡 Medium |
| **Cost Calculator** | Spreadsheet with formulas | 2 hours | 🟡 Medium |
| **Monitoring Dashboards** | CloudWatch/Datadog JSON exports | 4 hours | 🟡 Medium |
| **Architecture Decision Records** | ADRs for key decisions | 2-3 hours | 🟡 Medium |

---

## ✅ What Makes This Plan Usable

### Current State: Comprehensive Guide
- **Strengths**: Strategy, discovery, best practices, explanations
- **Weaknesses**: Missing executable artifacts
- **Analogy**: Detailed recipe book without ingredient measurements

### With Priority 1 Additions: Executable Playbook
- **Changes**: Add IaC templates, task definitions, workflows, scripts
- **Result**: Junior engineer can execute with 80% confidence
- **Analogy**: Recipe book with exact measurements and photos

### With Priority 1 + 2 Additions: Production-Ready Playbook
- **Changes**: Add testing procedures, runbooks, safety checks
- **Result**: Junior engineer or AI agent can execute with 95% confidence
- **Analogy**: Professional cookbook with step-by-step photos, timing, troubleshooting

---

## 🎯 Bottom Line Assessment

### For a Junior Engineer:
**Without artifacts**: "I understand *what* to do but not *how* to do it. I'll spend 50% of my time Googling syntax and debugging typos."

**With Priority 1 artifacts**: "I can follow these templates and get 80% of the way. I'll need help with edge cases."

**With Priority 1 + 2 artifacts**: "I can execute this migration with minimal supervision. Clear what to do, how to test, and how to rollback."

### For an AI Agent:
**Without artifacts**: "Cannot execute. Too many ambiguous steps requiring human judgment."

**With Priority 1 artifacts**: "Can execute basic steps (infrastructure, deployments) but will fail at edge cases and testing."

**With Priority 1 + 2 artifacts**: "Can execute end-to-end with high success rate. Clear inputs, outputs, and validation criteria."

---

## 📝 Recommendations

### Immediate Actions (Before Starting Migration)
1. ✅ Create Terraform modules for Phase 2 infrastructure
2. ✅ Write task definition templates with complete examples
3. ✅ Build GitHub Actions workflows with error handling
4. ✅ Write secrets migration script with validation

### Short-Term (During Phase 1-2)
5. ✅ Document testing procedures for each phase
6. ✅ Create database migration playbook
7. ✅ Write emergency rollback runbooks
8. ✅ Build automated Strangler Fig cutover script

### Nice-to-Have (Ongoing Improvements)
9. Create cost calculator spreadsheet
10. Export monitoring dashboards
11. Document KrakenD migration if applicable
12. Write architecture decision records

---

## 🏆 Final Verdict

**Plan Quality**: ⭐⭐⭐⭐⭐ (5/5 stars) - Excellent strategy, comprehensive, well-researched

**Execution Readiness**: ⭐⭐⭐ (3/5 stars) - Good guidance, needs artifacts

**With Priority 1 Artifacts**: ⭐⭐⭐⭐ (4/5 stars) - Executable with minor gaps

**With Priority 1 + 2 Artifacts**: ⭐⭐⭐⭐⭐ (5/5 stars) - Production-ready playbook

**Recommendation**: **Invest 4-5 days creating Priority 1 artifacts before starting execution**. This upfront investment will save 2-3 weeks of trial-and-error during migration.

This is a really solid plan. It just needs to cross the bridge from "comprehensive guide" to "executable playbook" by adding concrete code artifacts. Once that's done, it's ready for junior engineers or AI agents to execute with high confidence.
```
