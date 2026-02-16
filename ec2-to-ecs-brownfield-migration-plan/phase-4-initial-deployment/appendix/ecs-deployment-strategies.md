# ECS Deployment Strategies

## 1. Rolling Updates (Default)

The standard deployment method for ECS services.

**How it works**:

1. New task set (v2) starts alongside old task set (v1).
2. Load balancer registers v2 tasks as healthy.
3. Load balancer starts draining connections from v1 tasks.
4. Old tasks (v1) stop after draining is complete.

**Key Parameters**:

- **Minimum Healthy Percent**: ensuring availability during deployment (default: 100%).
- **Maximum Percent**: controlling resource usage surge (default: 200%).

**Example Configuration**:

```hcl
deployment_minimum_healthy_percent = 100
deployment_maximum_percent         = 200
```

**Pros**:

- Simple, built-in.
- No extra infrastructure cost (short-term surge).

**Cons**:

- No automated rollback on application errors (only health check failures).
- Difficult to test v2 with live traffic before full switch.

---

## 2. Blue/Green Deployment (CodeDeploy)

Use AWS CodeDeploy to control traffic shifting.

**How it works**:

1. **Blue (v1)** environment is running live traffic.
2. **Green (v2)** environment is provisioned with new code.
3. Automated tests run against Green.
4. Traffic shifts from Blue to Green according to strategy.

**Traffic Shifting Strategies**:

- **Canary**: Shift X% of traffic, wait Y minutes, then shift remainder. `CodeDeployDefault.ECSCanary10Percent5Minutes`
- **Linear**: Shift X% every Y minutes until 100%. `CodeDeployDefault.ECSLinear10PercentEvery1Minute`
- **All-at-Once**: Instant switch. Good for dev/test. `CodeDeployDefault.ECSAllAtOnce`

**Pros**:

- Automated rollback on alarm/hook failure.
- Testing in production before full rollout.
- Granular control.

**Cons**:

- Complex setup (requires CodeDeploy, multiple Target Groups).
- Slower deployment times.

---

## 3. Circuit Breakers

Built-in ECS feature to stop bad deployments early.

**Mechanism**:

- ECS monitors tasks for stability.
- If tasks fail to stabilize (e.g., crash loops), deployment is marked failed.
- ECS automatically rolls back to previous known good version.

**Configuration**:

```hcl
deployment_circuit_breaker {
  enable   = true
  rollback = true
}
```

**Recommendation**: **ALWAYS ENABLE** for production services.

---

## 4. Forced Deployments

Sometimes you need to redeploy without code changes (e.g., pick up new SSM secrets or base image updates).

**Command**:

```bash
aws ecs update-service --cluster my-cluster --service my-service --force-new-deployment
```

**Common Use Case**:

- Rotating database credentials.
- Applying OS patches from updated base image.
- Refreshing cached configuration.

---

## Summary Recommendation

| Environment               | Strategy                      | Rationale                                                   |
| :------------------------ | :---------------------------- | :---------------------------------------------------------- |
| **Dev/Staging**           | **Rolling Update**            | Fast, simple, failures are acceptable.                      |
| **Production (Standard)** | **Rolling + Circuit Breaker** | Good balance of safety and speed.                           |
| **Production (Critical)** | **Blue/Green (Canary)**       | Highest safety, zero downtime guarantee, automated testing. |
