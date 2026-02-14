# Phase 3: Optimization

## Overview

Optimize container images for faster startup, smaller size, and efficient resource usage.

**Business Value:** Reduces deployment time and costs. Faster container startup enables quick auto-scaling and reduces deployment delays. Smaller images reduce ECR storage costs and image pull time.

**Prerequisites:** [Container Lifecycle](container-lifecycle.md) completed

**Next Phase:** [Security](security.md)

---

## Story 1: Optimize Container Startup Time

**Business Value:** Enables fast auto-scaling and deployment. Containers starting in < 30 seconds allow auto-scaling to respond to traffic spikes quickly and prevent deployment timeouts. Fast startup reduces time from code commit to production from 15 minutes to 5 minutes.

- **Title:** Reduce Container Cold Start Time
- **Persona:** As an **operations engineer**, I need containers to start quickly so that auto-scaling responds in time and deployments don't fail due to health check timeouts.

- **Requirements:**
  - Container passes health check before ALB timeout (60-90s)
  - Image size minimized for faster pulls
  - Application initialization optimized

- **Implementation Details:**

  **Multi-Stage Builds:**

  ```dockerfile
  # Build stage
  FROM node:20 AS builder
  WORKDIR /app
  COPY package*.json ./
  RUN npm ci
  COPY . .
  RUN npm run build

  # Production stage (smaller image)
  FROM node:20-slim
  RUN apt-get update && apt-get install -y tini && rm -rf /var/lib/apt/lists/*

  WORKDIR /app
  COPY --from=builder /app/dist ./dist
  COPY --from=builder /app/node_modules ./node_modules
  COPY package*.json ./

  RUN groupadd -g 1001 appgroup && \
      useradd -u 1001 -g appgroup -m appuser && \
      chown -R appuser:appgroup /app

  USER appuser
  EXPOSE 3000

  ENTRYPOINT ["/usr/bin/tini", "--"]
  CMD ["node", "dist/server.js"]
  ```

  **Reduce Image Size:**

  | Technique                    | Savings   |
  | ---------------------------- | --------- |
  | Use slim/alpine base         | 200-500MB |
  | Multi-stage builds           | 100-300MB |
  | Remove dev dependencies      | 50-150MB  |
  | Combine RUN commands         | 20-50MB   |
  | Remove package manager cache | 10-30MB   |

  **Example Optimizations:**

  ```dockerfile
  # Bad: Each RUN creates layer
  RUN apt-get update
  RUN apt-get install -y curl
  RUN apt-get install -y wget

  # Good: Single layer, clean cache
  RUN apt-get update && \
      apt-get install -y curl wget && \
      rm -rf /var/lib/apt/lists/*

  # Bad: Dev dependencies included
  RUN npm install

  # Good: Production only
  RUN npm ci --production
  ```

  **Optimize Application Startup:**

  ```javascript
  // Defer non-critical initialization
  const app = express();

  // Critical: Must complete before health check
  app.listen(3000, "0.0.0.0", () => {
    console.log("Server listening");
  });

  // Non-critical: Can happen after server starts
  setTimeout(() => {
    initializeAnalytics();
    warmCache();
    preloadData();
  }, 0);
  ```

  **Use ECR Pull-Through Cache:**

  ```bash
  # Create pull-through cache rule
  aws ecr create-pull-through-cache-rule \
    --ecr-repository-prefix docker-hub \
    --upstream-registry-url registry-1.docker.io

  # Update Dockerfile
  # FROM node:20-slim
  FROM public.ecr.aws/docker/library/node:20-slim
  ```

  **Configure VPC Endpoints (eliminates internet routing):**

  ```bash
  # Create ECR VPC endpoints
  aws ec2 create-vpc-endpoint \
    --vpc-id vpc-abc123 \
    --service-name com.amazonaws.us-east-1.ecr.api \
    --route-table-ids rtb-abc123

  aws ec2 create-vpc-endpoint \
    --vpc-id vpc-abc123 \
    --service-name com.amazonaws.us-east-1.ecr.dkr \
    --route-table-ids rtb-abc123
  ```

- **Acceptance Criteria:**
  - ✅ Container starts and passes health check within 30 seconds
  - ✅ Image size < 500MB (ideally < 200MB)
  - ✅ Auto-scaling new tasks serve traffic within 60 seconds
  - ✅ No health check failures during normal deployments
  - ✅ Image pull time < 15 seconds

---

## Story 2: Configure Resource Limits

**Business Value:** Prevents OOM kills and resource contention. Proper memory/CPU limits prevent containers from consuming all node resources and getting killed unexpectedly. Right-sizing resources optimizes costs by preventing over-provisioning.

- **Title:** Right-Size Container Memory and CPU
- **Persona:** As a **DevOps engineer**, I need appropriate resource limits so that containers don't get OOM-killed or starve other tasks.

- **Requirements:**
  - Memory limit accommodates peak usage
  - CPU allocation handles expected load
  - Application handles memory pressure gracefully
  - Resource usage monitored

- **Implementation Details:**

  **Profile Application:**

  ```bash
  # Run on EC2 and measure
  top -b -n 1 -p $(pgrep -f "node server.js")

  # Or use CloudWatch Agent
  # Monitor: MemoryUtilization, CPUUtilization
  ```

  **Configure ECS Task (Phase 3):**

  ```json
  {
    "family": "my-app",
    "cpu": "512", // 0.5 vCPU
    "memory": "1024", // 1 GB

    "containerDefinitions": [
      {
        "memory": 1024, // Hard limit (OOM kill if exceeded)
        "memoryReservation": 768, // Soft limit (can burst above)
        "cpu": 512
      }
    ]
  }
  ```

  **Node.js Memory Limit:**

  ```dockerfile
  # Set max heap to 75% of container memory
  CMD ["node", "--max-old-space-size=768", "server.js"]
  ```

  **JVM Memory:**

  ```dockerfile
  # Set heap to 75% of container memory
  CMD ["java", "-Xmx768m", "-jar", "app.jar"]
  ```

  **Monitor Resource Usage:**

  ```bash
  # CloudWatch Alarms
  aws cloudwatch put-metric-alarm \
    --alarm-name my-app-high-memory \
    --metric-name MemoryUtilization \
    --namespace AWS/ECS \
    --statistic Average \
    --period 300 \
    --evaluation-periods 2 \
    --threshold 80 \
    --comparison-operator GreaterThanThreshold
  ```

  **Fargate CPU/Memory Combinations:**

  | CPU  | Memory Options (MB)         |
  | ---- | --------------------------- |
  | 256  | 512, 1024, 2048             |
  | 512  | 1024-4096 (1GB increments)  |
  | 1024 | 2048-8192 (1GB increments)  |
  | 2048 | 4096-16384 (1GB increments) |

- **Acceptance Criteria:**
  - ✅ Container runs 24+ hours without OOM kill
  - ✅ Memory utilization stays below 80%
  - ✅ No out-of-memory errors in logs
  - ✅ CloudWatch metrics show stable resource usage
  - ✅ Load tests pass without resource issues

---

## Phase Completion Checklist

Before proceeding to [Security](security.md):

- [ ] Image size optimized (< 500MB)
- [ ] Multi-stage build implemented
- [ ] Startup time < 30 seconds
- [ ] Memory and CPU limits configured
- [ ] Resource usage monitored in CloudWatch
- [ ] No OOM kills during load testing

---

## Rollback Plan

- **Slow startup:** Increase health check grace period, reduce initialization work
- **OOM kills:** Increase memory limit, fix memory leaks, optimize memory usage
- **Large images:** Review layers, remove dev dependencies, use slim base images
