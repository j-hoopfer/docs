# Troubleshooting Common ECS Issues

## Overview

This guide provides steps to diagnose and fix common issues encountered during ECS Fargate deployments.

---

## 1. Application Not Starting (CrashLoopBackOff)

**Symptoms:**

- Task status quickly changes from `RUNNING` to `STOPPED`.
- Task logs in "Stopped Tasks" tab show "Essential container in task exited".
- Exit code: 1, 137, 139 (non-zero).

**Diagnosis:**

1. Check CloudWatch Logs for application errors (tracebacks, missing env vars).
2. Check Task Definition > Container Definition > Environment Variables.
3. Check Exit Code:
   - `1`: Application threw an error.
   - `137`: Out of Memory (OOMKilled). Increase Memory.
   - `139`: Segmentation Fault. Binary issue.
   - `0`: Application finished and exited (it should not finish, it must run forever).

**Fixes:**

- Ensure the ENTRYPOINT/CMD runs a long-lived process (web server), not a script that exits immediately.
- Fix application errors shown in logs.
- Increase Task Memory if exit code is 137.

---

## 2. Health Check Failures (Unhealthy Targets)

**Symptoms:**

- Deployment starts, new tasks launch.
- Target Group shows targets as `Initial` -> `Unhealthy`.
- Tasks drain and stop repeatedly.
- Deployment never completes (stuck or rolls back).

**Diagnosis:**

1. Check Security Groups: Can ALB reach Task on container port?
   - Is Inbound rule on Task SG from ALB SG correct?
   - Is Port correct (e.g., container listens on 8080, but TG checks 80)?
2. Check Application Path:
   - Does `/health` exist?
   - Does it return 200 OK?
   - Does it take >5 seconds to respond? (Timeout issue).
3. Check Network Mode:
   - For Fargate (awsvpc), target type must be `ip`, not `instance`.

**Fixes:**

- Fix Security Group rules.
- Update Target Group Health Check path/port.
- Extend `HealthCheckGracePeriodSeconds` in Service definition (give app time to start).

---

## 3. Pulling Image Errors

**Symptoms:**

- Task fails to start.
- Essential container in task exited with reason: `CannotPullContainerError`.

**Diagnosis:**

1. Check ECR Permissions: Does Task Execution Role have `AmazonECSTaskExecutionRolePolicy`?
2. Check Image URI: Is `123456789012.dkr.ecr.us-east-1.amazonaws.com/my-repo:tag` correct?
3. Check Network Access:
   - If in private subnet, do you have NAT Gateway or VPC Endpoints for ECR (dkr, api)?
   - If public subnet, is "Auto-assign public IP" enabled? (Fargate needs public IP to pull image via IGW).

**Fixes:**

- Attach policy to Execution Role.
- Verify NAT Gateway or VPC Endpoints in private subnets.

---

## 4. Resource Not Found (Secrets/SSM)

**Symptoms:**

- Task fails to start.
- `ResourceInitializationError: unable to pull secrets or registry auth: execution resource retrieval failed`.

**Diagnosis:**

1. Check IAM Permissions: Does Task Execution Role have `secretsmanager:GetSecretValue` or `ssm:GetParameter`?
2. Check Network: Can task reach Secrets Manager/SSM endpoint (via NAT or VPC Endpoint)?
3. Check Secret Name: Does the ARN match exactly?

**Fixes:**

- Update IAM Policy on Task Execution Role.
- Fix typo in Task Definition secret ARN.

---

## 5. Deployment Stuck

**Symptoms:**

- `primary` deployment is in progress for 30+ minutes.
- `active` deployment is still serving traffic.

**Diagnosis:**

- ECS is waiting for new tasks to become healthy.
- Old tasks cannot stop because new ones fail health checks.

**Fixes:**

- Check "Events" tab in ECS Service console.
- If repeated failures, stop deployment and investigate using above steps.
- Use Circuit Breaker to automate rollback.
