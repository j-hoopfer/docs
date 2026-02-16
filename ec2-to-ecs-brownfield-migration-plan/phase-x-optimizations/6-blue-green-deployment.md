# Blue/Green Deployment Strategy

### Goal

Achieve zero-downtime deployments with instant rollback capabilities by running two environments (Blue and Green) concurrently.

### Context

Unlike rolling updates, Blue/Green eliminates the risk of deploying broken code to a live environment by validating the new version (Green) before shifting any traffic.

## Status

**Out of Scope** - Alternative deployment pattern for zero-downtime releases

## Why This Matters

While the migration plan uses **rolling updates** (default ECS deployment), some teams prefer **blue/green deployments** for instant rollback capability and zero-downtime releases with complete environment validation before cutover.

## What's Missing

### 5.1 Blue/Green Deployment Pattern

**Current State:**

- ECS rolling updates (default)
- New tasks start, old tasks drain, gradual replacement

**Gaps:**

- [ ] **No instant rollback** - Rolling back requires new deployment
- [ ] **No full environment testing** before cutover - New version immediately receives traffic
- [ ] **Cannot compare** blue and green side-by-side

**Recommendations:**

### Blue/Green Deployment Architecture

**Concept:**

- Maintain TWO complete environments (blue = current, green = new)
- Deploy new version to green environment
- Test green environment thoroughly
- Switch traffic from blue to green instantly
- Keep blue as instant rollback

**Implementation Option 1: ALB Target Group Swap**

```
Blue Environment:
- ECS Service: auth-api-blue
- Target Group: auth-api-blue-tg (weight 100%)
- Tasks: Current version (v1.2.0)

Green Environment:
- ECS Service: auth-api-green
- Target Group: auth-api-green-tg (weight 0%)
- Tasks: New version (v1.3.0)

Cutover:
1. Deploy v1.3.0 to green service
2. Test green via direct target group
3. Flip ALB listener rule weights:
   - Blue: 100% → 0%
   - Green: 0% → 100%
4. Monitor green under load
5. If issues: Flip back to blue (instant)
```

**Implementation Option 2: AWS CodeDeploy Blue/Green**

```bash
# Create CodeDeploy application
aws deploy create-application \
 --application-name auth-api \
 --compute-platform ECS

# Create deployment group
aws deploy create-deployment-group \
 --application-name auth-api \
 --deployment-group-name production \
 --deployment-config-name CodeDeployDefault.ECSAllAtOnce \
 --service-role-arn arn:aws:iam::123456789012:role/CodeDeployServiceRole \
 --ecs-services clusterName=production-cluster,serviceName=auth-api \
 --load-balancer-info targetGroupPairInfoList=[{
targetGroups=[
{name=auth-api-blue-tg},
{name=auth-api-green-tg}
],
prodTrafficRoute={listenerArns=[arn:aws:elasticloadbalancing:...]}
}]
```

**Priority:** Low-Medium (nice-to-have, rolling updates work fine)  
**Estimated Effort:** 3-5 days (initial setup), then automatic  
**Owner:** Platform/DevOps Team
