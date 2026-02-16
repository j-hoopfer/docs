# Canary Deployments with Lambda@Edge or CloudFront

### Goal

Reduce blast radius by exposing new features to a small subset of users (e.g., 1%) before rolling out to the entire population.

### Context

While Strangler Fig handles service-level cutover, fine-grained user canarying allows testing new application logic on real users with minimal risk.

## Status

**Out of Scope** - Advanced traffic management for gradual rollouts

## Why This Matters

For user-facing applications where you want to expose a new version to a small percentage of **real users** (not just all traffic), you can use CloudFront + Lambda@Edge to route specific user segments to different versions.

## What's Missing

### 6.1 CloudFront-Based Canary Deployments

**Current State:**

- ALB routes all traffic to ECS tasks
- All users see the same version

**Gaps:**

- [ ] **No user-based routing** - Cannot send "beta users" to new version
- [ ] **No geography-based routing** - Cannot deploy to US first, EU later
- [ ] **No A/B testing capability**

**Recommendations:**

### CloudFront Canary Architecture

**Pattern:**

```
User Request → CloudFront → Lambda@Edge → [Blue ALB (90%) | Green ALB (10%)]
```

**Lambda@Edge Function:**

```javascript
// Triggered on Viewer Request
exports.handler = async (event) => {
  const request = event.Records[0].cf.request;

  // Get user ID from cookie or header
  const userId = request.headers["user-id"]?.[0]?.value;

  // Canary logic: 10% of users go to green
  const isCanary = hashUserId(userId) % 100 < 10;

  // Route to appropriate ALB
  if (isCanary) {
    request.origin = {
      custom: {
        domainName: "green-alb-123.us-east-1.elb.amazonaws.com",
        port: 443,
        protocol: "https",
      },
    };
  } else {
    request.origin = {
      custom: {
        domainName: "blue-alb-456.us-east-1.elb.amazonaws.com",
        port: 443,
        protocol: "https",
      },
    };
  }

  return request;
};

function hashUserId(userId) {
  // Simple hash for consistent routing
  let hash = 0;
  for (let i = 0; i < userId.length; i++) {
    hash = (hash << 5) - hash + userId.charCodeAt(i);
    hash = hash & hash; // Convert to 32bit integer
  }
  return Math.abs(hash);
}
```

**Priority:** Low (only if you need advanced traffic management)  
**Estimated Effort:** 5-7 days  
**Owner:** Platform Team + Application Team
