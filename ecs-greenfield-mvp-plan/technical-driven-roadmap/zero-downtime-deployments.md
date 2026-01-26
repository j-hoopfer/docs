# Epic 9: Zero-Downtime Deployments (Blue/Green)

**Goal:** Implement automated traffic shifting and rollback capabilities using AWS CodeDeploy.
**Duration:** 2–3 Days
**Prerequisites:** Epic 3 (ECS/ALB) & Epic 4 (CI/CD) complete.

---

## Story 9.1: Configure CodeDeploy Resources

As a DevOps Engineer
I want infrastructure for Blue/Green deployments
So that I can deploy safely with automated rollbacks

### ⚠️ Critical Warning: The "Destructive" Change

Switching an ECS Service from `ECS` (Rolling) to `CODE_DEPLOY` (Blue/Green) is **immutable**.

- **Terraform Behavior:** It will force **destroy and re-create** the ECS Service.
- **Impact:** Brief downtime during the Terraform apply.
- **Strategy:** Plan a maintenance window for this specific apply.

### Technical Requirements

- **Two Target Groups:**
  - **Blue:** The currently live traffic.
  - **Green:** The new replacement tasks.
- **Two Listeners:**
  - **Prod:** Port 443 (HTTPS).
  - **Test:** Port 8080 (HTTP) – Used by CodeDeploy to verify the "Green" tasks before shifting traffic.
- **Terraform Lifecycle Hooks:** You **must** ignore changes to the `load_balancer` block in the ECS Service, or Terraform will fight CodeDeploy for control.

### Terraform Configuration (`modules/compute/codedeploy.tf`)

```hcl
# 1. The Green Target Group (Blue already exists from Epic 3)
resource "aws_lb_target_group" "green" {
  name        = "${var.project}-${var.environment}-green-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"
  health_check { path = "/health" }
}

# 2. Test Listener (Port 8080)
resource "aws_lb_listener" "test" {
  load_balancer_arn = var.alb_arn
  port              = "8080"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.green.arn
  }
}

# 3. CodeDeploy Application & Group
resource "aws_codedeploy_app" "main" {
  compute_platform = "ECS"
  name             = "${var.project}-${var.environment}-deploy"
}

resource "aws_codedeploy_deployment_group" "main" {
  app_name               = aws_codedeploy_app.main.name
  deployment_group_name  = "${var.project}-${var.environment}-group"
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = "CodeDeployDefault.ECSCanary10Percent5Minutes"

  ecs_service {
    cluster_name = var.ecs_cluster_name
    service_name = aws_ecs_service.app.name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route { listener_arns = [var.prod_listener_arn] }
      test_traffic_route { listener_arns = [aws_lb_listener.test.arn] }
      target_group { name = var.blue_tg_name }
      target_group { name = aws_lb_target_group.green.name }
    }
  }

  blue_green_deployment_config {
    deployment_ready_option { action_on_timeout = "CONTINUE_DEPLOYMENT" }
    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 5
    }
  }
}

```

### Update to ECS Service (`modules/compute/main.tf`)

```hcl
resource "aws_ecs_service" "app" {
  # ... existing config ...

  deployment_controller {
    type = "CODE_DEPLOY" # <--- The destructive change
  }

  # CRITICAL: Prevent Terraform from resetting CodeDeploy's changes
  lifecycle {
    ignore_changes = [
      load_balancer,
      task_definition,
    ]
  }
}

```

### Acceptance Criteria

- [ ] ECS Service recreated with `CODE_DEPLOY` controller.
- [ ] Green Target Group and Test Listener (8080) exist.
- [ ] CodeDeploy Application and Deployment Group visible in console.
- [ ] `lifecycle { ignore_changes }` applied to ECS Service.

---

## Story 9.2: Pipeline Integration (AppSpec)

As a DevOps Engineer
I want GitHub Actions to trigger CodeDeploy
So that I don't have to manually click buttons in the AWS Console

### Technical Requirements

- **AppSpec File:** `appspec.yaml` in the root.
- **Action:** Use `aws-actions/amazon-ecs-deploy-task-definition` which abstracts the complexity of filling in the Task Def ARN.

### `appspec.yaml`

```yaml
version: 0.0
Resources:
  - TargetService:
      Type: AWS::ECS::Service
      Properties:
        TaskDefinition: <TASK_DEFINITION>
        LoadBalancerInfo:
          ContainerName: "auth-api"
          ContainerPort: 3000
```

### GitHub Action Update (`deploy.yml`)

```yaml
- name: Deploy to ECS (Blue/Green)
  uses: aws-actions/amazon-ecs-deploy-task-definition@v1
  with:
    task-definition: ${{ steps.task-def.outputs.task-definition }}
    service: auth-api-service
    cluster: monorepo-starter-cluster
    wait-for-service-stability: false # CodeDeploy handles the wait
    codedeploy-appspec: appspec.yaml
    codedeploy-application: monorepo-starter-dev-deploy
    codedeploy-deployment-group: monorepo-starter-dev-group
```

### Acceptance Criteria

- [ ] `appspec.yaml` committed to repo.
- [ ] Workflow updated to use CodeDeploy inputs.
- [ ] Merge to main triggers a "Canary" deployment (10% shift).

---

## Story 9.3: Automated Rollback

As a SRE
I want deployments to rollback automatically on errors
So that bad code doesn't stay in production for more than 5 minutes

### Technical Requirements

- **Triggers:**
  1. **Deployment Failure:** Task fails to start.
  2. **Alarm Threshold:** `5XX Error Rate` (from Epic 5) spikes during the 10% Canary phase.

### Terraform Update (`codedeploy.tf`)

```hcl
resource "aws_codedeploy_deployment_group" "main" {
  # ... existing config ...

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }

  alarm_configuration {
    enabled = true
    alarms  = [var.high_error_rate_alarm_name]
  }
}

```

### Acceptance Criteria

- [ ] Auto Rollback enabled in CodeDeploy.
- [ ] **Test:** Deploy code that throws 500 errors on `/health`.
  - CodeDeploy shifts 10%.
  - Alarm fires.
  - CodeDeploy rolls back to Blue.
  - Deployment marked as "Failed".

---

## ✅ Epic 9 Definition of Done

1. **Infrastructure:** Blue/Green resources (Test Listener, Green TG) are active.
2. **Pipeline:** GitHub Actions successfully triggers a CodeDeploy.
3. **Safety:** Terraform `ignore_changes` prevents state conflicts.
4. **Rollback:** System auto-reverts when an alarm trips.
