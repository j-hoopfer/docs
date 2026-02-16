# Appendix: Troubleshooting and Operations

## Overview

This appendix provides debugging guidance, common error patterns, and operational procedures for ECS Fargate deployments.

**Use this appendix when:**

- Troubleshooting deployment pipeline failures
- Debugging ECS service issues
- Understanding common error messages
- Investigating networking problems
- Resolving task startup failures

---

## Table of Contents

1. [Troubleshooting Common Issues](#troubleshooting-common-issues)
2. [Debugging Steps](#debugging-steps)
3. [Pipeline Failures](#pipeline-failures)
4. [ECS Service Issues](#ecs-service-issues)
5. [Network Connectivity](#network-connectivity)

---

## Troubleshooting Common Issues

### Pipeline Failures

| Error                                                     | Cause                                 | Fix                                          |
| --------------------------------------------------------- | ------------------------------------- | -------------------------------------------- |
| "Not authorized to perform sts:AssumeRoleWithWebIdentity" | Trust policy `sub` doesn't match repo | Check repo name in trust policy              |
| "Could not assume role"                                   | Missing `id-token: write` permission  | Add `permissions` block to workflow          |
| "AccessDeniedException" on ECR                            | Role doesn't have ECR permissions     | Add ECR policy to role                       |
| "Service not stable" timeout                              | Deployment failing health checks      | Check ECS events, CloudWatch logs            |
| "exec format error"                                       | Built for wrong CPU architecture      | Add `--platform linux/amd64` to docker build |
| "Task failed to start"                                    | Image not found in ECR                | Check ECR repo name and region               |
| "Stopped reason: CannotPullContainerError"                | No NAT Gateway or VPC endpoints       | Add NAT or ECR VPC endpoints                 |

---

## Debugging Steps

### 1. Check GitHub Actions Logs (Start Here)

Most verbose, start here for pipeline failures.

**Where:** GitHub repo → Actions tab → Select failed workflow run

**What to look for:**

- Build errors
- Docker push failures
- AWS authentication errors
- Task definition registration errors

### 2. Check ECS Service Events

Shows deployment progress and recent errors.

```bash
aws ecs describe-services \
  --cluster production-cluster \
  --services auth-api-service \
  --query 'services[0].events[0:10]'
```

**Common messages:**

- "service auth-api has reached a steady state" ✅ Good
- "service auth-api was unable to place a task" ❌ Check capacity/subnets
- "service auth-api failed ELB health checks" ❌ Check target group health

### 3. Check ECS Task Status

Why tasks fail to start or keep stopping.

```bash
aws ecs describe-tasks \
  --cluster production-cluster \
  --tasks <task-id> \
  --query 'tasks[0].{Status:lastStatus,Reason:stoppedReason,Containers:containers[0].reason}'
```

**Common stopped reasons:**

- "Essential container in task exited" → Application crashed
- "CannotPullContainerError" → ECR permissions or image missing
- "ResourceInitializationError" → Secrets Manager permission issue
- "OutOfMemoryError" → Task definition memory too low

### 4. Check CloudWatch Logs

Application errors and runtime issues.

```bash
# Follow logs in real-time
aws logs tail /ecs/production-cluster/auth-api --follow

# Get last 100 lines
aws logs tail /ecs/production-cluster/auth-api --since 5m
```

**What to look for:**

- Application startup errors
- Runtime exceptions
- Database connection failures
- Missing environment variables

### 5. Check Target Group Health

ALB perspective on task health.

```bash
aws elbv2 describe-target-health \
  --target-group-arn <target-group-arn>
```

**Health statuses:**

- `healthy` ✅ Target is responding correctly
- `unhealthy` ❌ Failing health checks
- `initial` ⏳ Still warming up
- `draining` ⏳ Being removed from service

**Common unhealthy reasons:**

- "Target.FailedHealthChecks" → Health check path returning errors
- "Target.Timeout" → Health check timeout (increase timeout)
- "Target.ResponseCodeMismatch" → Expecting 200, got 404

---

## ECS Service Issues

### Task Keeps Restarting

**Symptoms:** Service shows tasks starting and stopping repeatedly

**Causes & Solutions:**

1. **Application crash**

   ```bash
   # Check CloudWatch logs for errors
   aws logs tail /ecs/production-cluster/auth-api --since 10m
   ```

2. **Health check failure**

   ```bash
   # Verify health check endpoint works
   curl http://<task-ip>:3000/health

   # Update task definition with correct health check path
   ```

3. **Out of memory**

   ```bash
   # Check stopped reason
   aws ecs describe-tasks --cluster production-cluster --tasks <task-id>

   # If "OutOfMemoryError", increase memory in task definition
   ```

### Task Won't Start

**Symptoms:** Service desired count is 2, running count is 0

**Causes & Solutions:**

1. **No capacity in subnets**

   ```bash
   # Check service events
   aws ecs describe-services --cluster production-cluster --services auth-api
   # Look for "unable to place a task"

   # Fix: Add more subnets or use different AZs
   ```

2. **Cannot pull image**

   ```bash
   # Check task stopped reason
   aws ecs describe-tasks --cluster production-cluster --tasks <task-id>
   # Look for "CannotPullContainerError"

   # Fix: Check ECR permissions on task execution role
   ```

3. **Secrets permission issue**

   ```bash
   # Check task stopped reason
   # Look for "ResourceInitializationError"

   # Fix: Add Secrets Manager permissions to task execution role
   ```

### Deployment Stuck

**Symptoms:** Deployment says "1 running" but won't complete

**Causes & Solutions:**

1. **Health checks failing**

   ```bash
   # Check target group health
   aws elbv2 describe-target-health --target-group-arn <arn>

   # Fix: Check application health check endpoint
   ```

2. **Wrong health check configuration**
   - Health check path doesn't exist (404)
   - Health check timeout too short
   - Health check interval too short

3. **Deployment circuit breaker triggered**

   ```bash
   # Check service events for "deployment circuit breaker"
   # ECS rolled back because new tasks kept failing

   # Fix: Resolve the underlying task failure, then redeploy
   ```

---

## Network Connectivity

### Can't Pull from ECR

**Symptoms:** "CannotPullContainerError"

**Diagnosis:**

```bash
# Check if tasks have public IP (if in public subnet)
aws ecs describe-tasks --cluster production-cluster --tasks <task-id> \
  --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value'

# Check subnet routing
aws ec2 describe-route-tables --filters Name=association.subnet-id,Values=<subnet-id>
```

**Solutions:**

1. **Private subnet without NAT:**
   - Add NAT Gateway to subnet route table, OR
   - Create VPC endpoints for ECR:
     - `com.amazonaws.us-east-1.ecr.api`
     - `com.amazonaws.us-east-1.ecr.dkr`
     - `com.amazonaws.us-east-1.s3` (for ECR layers)

2. **Security group blocking**
   - Ensure outbound rules allow HTTPS (443) to 0.0.0.0/0

### Can't Connect to Database

**Symptoms:** Application logs show "ECONNREFUSED" or timeout

**Diagnosis:**

```bash
# Check security groups on both task and RDS
aws ec2 describe-security-groups --group-ids <fargate-sg> <rds-sg>
```

**Solutions:**

1. **Security group not allowing traffic:**
   - RDS SG must allow inbound 5432 from Fargate SG
   - Fargate SG must allow outbound to RDS

2. **Wrong subnet:**
   - Ensure Fargate tasks in same VPC as RDS
   - Use private subnets for both

3. **Wrong connection string:**
   - Verify RDS endpoint in Secrets Manager
   - Check database name, username

### ALB Can't Reach Tasks

**Symptoms:** Target group shows all targets unhealthy

**Diagnosis:**

```bash
# Check security group on Fargate tasks
aws ecs describe-services --cluster production-cluster --services auth-api \
  --query 'services[0].networkConfiguration.awsvpcConfiguration.securityGroups'

# Check ALB security group
aws elbv2 describe-load-balancers --load-balancer-arns <alb-arn> \
  --query 'LoadBalancers[0].SecurityGroups'
```

**Solutions:**

1. **Security group blocking:**
   - Fargate SG must allow inbound on container port from ALB SG
   - ALB SG must allow outbound to Fargate SG

2. **Wrong target group port:**
   - Target group port must match container port in task definition

3. **Wrong health check:**
   - Health check path must return 200 OK
   - Verify: `curl http://<task-ip>:<port><health-path>`

---

## Quick Diagnostic Commands

### Get Task IPs

```bash
aws ecs list-tasks --cluster production-cluster --service-name auth-api | \
  xargs -I {} aws ecs describe-tasks --cluster production-cluster --tasks {} \
  --query 'tasks[0].attachments[0].details[?name==`privateIPv4Address`].value'
```

### Get Recent Task Failures

```bash
aws ecs list-tasks --cluster production-cluster --desired-status STOPPED | \
  head -n 5 | \
  xargs -I {} aws ecs describe-tasks --cluster production-cluster --tasks {} \
  --query 'tasks[*].{ID:taskArn,Reason:stoppedReason,Exit:containers[0].exitCode}'
```

### Follow All Logs for a Service

```bash
for task in $(aws ecs list-tasks --cluster production-cluster --service-name auth-api --query 'taskArns[*]' --output text); do
  echo "=== Task: $task ==="
  aws logs tail /ecs/production-cluster/auth-api --since 1h --filter-pattern "$task"
done
```

---

## Related Documentation

- See [ecs-deployment-fundamentals.md](../../phase-4-initial-deployment/appendix/ecs-deployment-fundamentals.md) for understanding ECS components
- See [networking-and-security-groups.md](../../phase-3-infrastructure-setup/appendix/networking-and-security-groups.md) for security group configuration
- See [github-actions-cicd.md](../../phase-4-initial-deployment/appendix/github-actions-cicd.md) for pipeline troubleshooting
