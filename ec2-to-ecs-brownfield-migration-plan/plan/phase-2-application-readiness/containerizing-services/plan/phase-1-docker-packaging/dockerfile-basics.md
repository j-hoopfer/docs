# Dockerfile Basics

## Story 1: Create Production-Ready Dockerfile

**Business Value:** Creates foundation for reliable, reproducible deployments. Docker images ensure development, staging, and production run identical code, eliminating environment-specific bugs that delay releases by days or weeks. One customer reduced deployment-related incidents from 8/month to 1/month after containerization, saving 40 hours/month of engineering time.

- **Title:** Package Application in Docker Image
- **Persona:** As a **DevOps engineer**, I need to package the application into a portable Docker image so that it can run identically in any environment without server-specific dependencies.

- **Requirements:**
  - Application builds successfully into Docker image
  - Image contains all OS-level dependencies
  - Image exposes correct port(s)
  - Proper `ENTRYPOINT` or `CMD` defined
  - No hardcoded filesystem paths assuming persistence

- **Implementation Details:**

  **Node.js Example:**

  ```dockerfile
  # Multi-stage build for smaller image
  FROM node:20-slim AS builder

  WORKDIR /app
  COPY package*.json ./
  RUN npm ci --production

  # Production stage
  FROM node:20-slim

  # Install tini for PID 1 handling
  RUN apt-get update && apt-get install -y tini && rm -rf /var/lib/apt/lists/*

  # Create non-root user
  RUN groupadd -g 1001 appgroup && \
      useradd -u 1001 -g appgroup -m appuser

  WORKDIR /app

  # Copy dependencies from builder
  COPY --from=builder /app/node_modules ./node_modules

  # Copy application code
  COPY --chown=appuser:appgroup . .

  # Switch to non-root
  USER appuser

  EXPOSE 3000

  # Use tini as PID 1
  ENTRYPOINT ["/usr/bin/tini", "--"]
  CMD ["node", "server.js"]
  ```

  **Python Example:**

  ```dockerfile
  FROM python:3.11-slim

  # Install tini
  RUN apt-get update && apt-get install -y tini && rm -rf /var/lib/apt/lists/*

  # Create non-root user
  RUN groupadd -g 1001 appgroup && \
      useradd -u 1001 -g appgroup -m appuser

  WORKDIR /app

  # Install dependencies
  COPY requirements.txt ./
  RUN pip install --no-cache-dir -r requirements.txt

  # Copy application
  COPY --chown=appuser:appgroup . .

  USER appuser
  EXPOSE 8000

  ENTRYPOINT ["/usr/bin/tini", "--"]
  CMD ["gunicorn", "-b", "0.0.0.0:8000", "-w", "4", "app:app"]
  ```

  **Create .dockerignore:**

  ```
  # .dockerignore
  node_modules
  npm-debug.log
  .git
  .gitignore
  .env
  .env.*
  *.md
  .vscode
  .idea
  __pycache__
  *.pyc
  .pytest_cache
  coverage
  dist
  build
  ```

  **Best Practices:**
  - Use official base images
  - Multi-stage builds to reduce size
  - Combine RUN commands to reduce layers
  - Remove package manager caches
  - Run as non-root user
  - Include tini for signal handling

- **Acceptance Criteria:**
  - ✅ `docker build -t my-app .` completes without errors
  - ✅ `docker run -p 3000:3000 my-app` starts application
  - ✅ Application responds to HTTP requests on localhost
  - ✅ Image size < 500MB (ideally < 200MB)
  - ✅ Container runs as non-root user
  - ✅ Application behavior matches EC2 behavior

---

## Story 2: Configure Network Binding

**Business Value:** Prevents #1 cause of failed containerized deployments: ALB health checks failing because app listens on localhost instead of all interfaces. This 5-minute configuration change prevents multi-hour debugging sessions and deployment rollbacks. Enables load balancer connectivity required for horizontal scaling.

- **Title:** Bind to 0.0.0.0 and Expose Container Port
- **Persona:** As a **DevOps engineer**, I need the application to listen on all network interfaces so that the ALB can reach the container and health checks pass.

- **Requirements:**
  - Application must bind to `0.0.0.0`, not `127.0.0.1` or `localhost`
  - Dockerfile must include `EXPOSE` directive
  - Port must match ECS Task Definition and ALB Target Group
  - Use non-privileged ports (>1024)

- **Implementation Details:**

  **Update Application Code:**

  ```javascript
  // Node.js/Express
  const PORT = process.env.PORT || 3000;
  const HOST = process.env.HOST || "0.0.0.0";

  app.listen(PORT, HOST, () => {
    console.log(`Server listening on ${HOST}:${PORT}`);
  });
  ```

  ```python
  # Python/Flask
  if __name__ == '__main__':
      app.run(
          host=os.environ.get('HOST', '0.0.0.0'),
          port=int(os.environ.get('PORT', 8000))
      )

  # Gunicorn (production)
  # gunicorn -b 0.0.0.0:8000 app:app
  ```

  **Verify:**

  ```bash
  # Run container
  docker run -d -p 3000:3000 --name test-app my-app

  # Check what app is listening on
  docker exec test-app netstat -tlnp

  # Should show:
  # tcp   0.0.0.0:3000   0.0.0.0:*   LISTEN   1/node
  # NOT 127.0.0.1:3000

  # Test from host
  curl http://localhost:3000/health
  ```

- **Acceptance Criteria:**
  - ✅ Application listens on 0.0.0.0
  - ✅ `docker run -p 8080:8080 my-app` responds from host
  - ✅ `netstat` shows `0.0.0.0:PORT`, not `127.0.0.1:PORT`
  - ✅ Another container can reach app
  - ✅ ALB health checks pass (in later phases)

---

## Story 3: Build Multi-Architecture Container Images

**Business Value:** Reduces infrastructure costs by 20% through ARM64 Graviton support while maintaining x86_64 compatibility. Multi-arch images future-proof deployments and enable platform flexibility without maintaining separate Dockerfiles. AWS Graviton offers equal or better performance at lower cost for most workloads.

- **Title:** Build for Multiple CPU Architectures (ARM64 + AMD64)
- **Persona:** As a **DevOps engineer**, I need to build multi-architecture images so that I can deploy to cost-effective ARM64 Graviton instances while maintaining x86_64 compatibility.

- **Requirements:**
  - Single Dockerfile works on both architectures
  - Build process creates multi-arch manifest
  - Images tagged appropriately for each platform
  - CI/CD pipeline supports multi-arch builds
  - Application code is platform-agnostic

- **Implementation Details:**

  **1. Verify Application Compatibility:**

  Most modern languages are architecture-agnostic, but check:
  - **Node.js:** ✅ Works on both
  - **Python:** ✅ Works on both (check native dependencies)
  - **Go:** ✅ Cross-compiles easily
  - **Java:** ✅ JVM handles architecture
  - **Native modules:** ⚠️ May need recompilation

  **2. Update Dockerfile (if needed):**

  ```dockerfile
  # Use platform-specific base image
  FROM --platform=$BUILDPLATFORM node:20-slim AS builder

  WORKDIR /app
  COPY package*.json ./
  RUN npm ci --production

  # Production stage
  FROM node:20-slim

  RUN apt-get update && apt-get install -y tini && rm -rf /var/lib/apt/lists/*

  RUN groupadd -g 1001 appgroup && \
      useradd -u 1001 -g appgroup -m appuser

  WORKDIR /app
  COPY --from=builder /app/node_modules ./node_modules
  COPY --chown=appuser:appgroup . .

  USER appuser
  EXPOSE 3000

  ENTRYPOINT ["/usr/bin/tini", "--"]
  CMD ["node", "server.js"]
  ```

  **3. Build Multi-Arch Locally (for testing):**

  ```bash
  # Enable Docker Buildx
  docker buildx create --name multiarch --use
  docker buildx inspect --bootstrap

  # Build for both architectures
  docker buildx build \
    --platform linux/amd64,linux/arm64 \
    -t my-app:latest \
    --load \
    .

  # Or build and push to registry
  docker buildx build \
    --platform linux/amd64,linux/arm64 \
    -t 123456789012.dkr.ecr.us-east-1.amazonaws.com/my-app:latest \
    --push \
    .
  ```

  **4. GitHub Actions (CI/CD):**

  ```yaml
  name: Build Multi-Arch Image

  on:
    push:
      branches: [main]

  jobs:
    build:
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v4

        - name: Set up QEMU
          uses: docker/setup-qemu-action@v3

        - name: Set up Docker Buildx
          uses: docker/setup-buildx-action@v3

        - name: Configure AWS credentials
          uses: aws-actions/configure-aws-credentials@v4
          with:
            role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
            aws-region: us-east-1

        - name: Login to Amazon ECR
          id: login-ecr
          uses: aws-actions/amazon-ecr-login@v2

        - name: Build and push multi-arch image
          env:
            ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
            ECR_REPOSITORY: my-app
            IMAGE_TAG: ${{ github.sha }}
          run: |
            docker buildx build \
              --platform linux/amd64,linux/arm64 \
              -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG \
              -t $ECR_REGISTRY/$ECR_REPOSITORY:latest \
              --push \
              .
  ```

  **5. Verify Multi-Arch Image:**

  ```bash
  # Check manifest
  docker buildx imagetools inspect my-app:latest

  # Output shows both architectures:
  # MediaType: application/vnd.docker.distribution.manifest.list.v2+json
  # Manifests:
  #   Name: my-app:latest@sha256:abc...
  #   Platform: linux/amd64
  #   Name: my-app:latest@sha256:def...
  #   Platform: linux/arm64
  ```

  **6. Test on Both Platforms:**

  ```bash
  # Test AMD64
  docker run --platform linux/amd64 my-app:latest

  # Test ARM64 (requires ARM machine or emulation)
  docker run --platform linux/arm64 my-app:latest

  # Check current platform
  docker run my-app:latest uname -m
  # x86_64 (AMD64) or aarch64 (ARM64)
  ```

  **ECS Task Definition:**

  ```json
  {
    "family": "my-app",
    "runtimePlatform": {
      "cpuArchitecture": "ARM64", // or "X86_64"
      "operatingSystemFamily": "LINUX"
    },
    "containerDefinitions": [
      {
        "name": "app",
        "image": "123456789012.dkr.ecr.us-east-1.amazonaws.com/my-app:latest"
      }
    ]
  }
  ```

  **Cost Comparison:**

  | Instance Type      | vCPU | Memory | Price/Hour | Savings with ARM64 |
  | ------------------ | ---- | ------ | ---------- | ------------------ |
  | t4g.medium (ARM64) | 2    | 4GB    | $0.0336    | Baseline           |
  | t3.medium (x86)    | 2    | 4GB    | $0.0416    | +24% cost          |
  | c6g.large (ARM64)  | 2    | 4GB    | $0.068     | Baseline           |
  | c5.large (x86)     | 2    | 4GB    | $0.085     | +25% cost          |

  **Best Practices:**
  - Start with ARM64 for new deployments (20% savings)
  - Keep x86_64 as fallback for compatibility issues
  - Test performance on both platforms before production
  - Use multi-arch images for flexibility
  - Don't assume x86-specific optimizations

  **Troubleshooting:**

  **Native dependencies fail on ARM64:**

  ```bash
  # Rebuild native modules for ARM64
  RUN npm rebuild --arch=arm64

  # Or use pre-compiled binaries
  RUN npm ci --prefer-offline
  ```

  **Different behavior on ARM64:**

  ```bash
  # Add platform-specific logic
  ARG TARGETARCH
  RUN if [ "$TARGETARCH" = "arm64" ]; then \
        echo "ARM64-specific setup"; \
      else \
        echo "AMD64-specific setup"; \
      fi
  ```

- **Acceptance Criteria:**
  - ✅ Image builds for both linux/amd64 and linux/arm64
  - ✅ Multi-arch manifest created and pushed to ECR
  - ✅ Application works correctly on both platforms
  - ✅ CI/CD pipeline builds multi-arch images automatically
  - ✅ No performance regressions on either platform
  - ✅ Cost analysis shows expected 20% savings with Graviton

---

## Story 4: Add Native Health Check to Dockerfile

**Business Value:** Enables Docker and orchestration platforms to detect unhealthy containers automatically, triggering restarts before application becomes unresponsive. Native HEALTHCHECK complements ALB health checks, providing local container-level health verification that catches issues faster (5-10 seconds vs 60+ seconds for ALB).

- **Title:** Implement Dockerfile HEALTHCHECK Directive
- **Persona:** As a **DevOps engineer**, I need containers to self-report health status so that orchestrators can automatically restart failing containers before users are impacted.

- **Requirements:**
  - HEALTHCHECK directive in Dockerfile
  - Health endpoint returns quickly (< 1 second)
  - Check validates critical dependencies
  - Appropriate interval and timeout settings
  - Works with both Docker and ECS

- **Implementation Details:**

  **1. Add HEALTHCHECK to Dockerfile:**

  ```dockerfile
  FROM node:20-slim

  RUN apt-get update && apt-get install -y tini curl && rm -rf /var/lib/apt/lists/*

  RUN groupadd -g 1001 appgroup && \
      useradd -u 1001 -g appgroup -m appuser

  WORKDIR /app

  COPY package*.json ./
  RUN npm ci --production

  COPY --chown=appuser:appgroup . .

  USER appuser

  EXPOSE 3000

  # Native health check
  HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1

  ENTRYPOINT ["/usr/bin/tini", "--"]
  CMD ["node", "server.js"]
  ```

  **2. Implement Health Endpoint:**

  ```javascript
  // Node.js/Express
  app.get("/health", async (req, res) => {
    try {
      // Check database connection
      await db.query("SELECT 1");

      // Check Redis connection
      await redis.ping();

      // Optional: Check critical dependencies
      // const apiHealthy = await checkExternalAPI();

      res.status(200).json({
        status: "healthy",
        timestamp: new Date().toISOString(),
        uptime: process.uptime(),
        dependencies: {
          database: "ok",
          redis: "ok",
        },
      });
    } catch (error) {
      res.status(503).json({
        status: "unhealthy",
        error: error.message,
      });
    }
  });
  ```

  ```python
  # Python/Flask
  @app.route('/health')
  def health():
      try:
          # Check database
          db.session.execute('SELECT 1')

          # Check Redis
          redis_client.ping()

          return jsonify({
              'status': 'healthy',
              'timestamp': datetime.utcnow().isoformat(),
              'dependencies': {
                  'database': 'ok',
                  'redis': 'ok'
              }
          }), 200
      except Exception as e:
          return jsonify({
              'status': 'unhealthy',
              'error': str(e)
          }), 503
  ```

  **3. HEALTHCHECK Configuration:**

  ```dockerfile
  # Explanation of flags:
  # --interval=30s     Check every 30 seconds
  # --timeout=3s       Fail if check takes > 3 seconds
  # --start-period=40s Don't mark unhealthy during startup
  # --retries=3        Mark unhealthy after 3 consecutive failures

  HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1
  ```

  **4. Without curl (minimal images):**

  ```dockerfile
  # Use wget (usually available)
  HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:3000/health || exit 1

  # Or use programming language
  HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
    CMD node -e "require('http').get('http://localhost:3000/health', (r) => process.exit(r.statusCode === 200 ? 0 : 1))"

  # Python
  HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:3000/health')"
  ```

  **5. Test Health Check:**

  ```bash
  # Build image
  docker build -t my-app:latest .

  # Run container
  docker run -d --name test-app my-app:latest

  # Check health status
  docker ps
  # STATUS column shows: "Up X seconds (healthy)"

  # View health check logs
  docker inspect test-app --format='{{json .State.Health}}' | jq

  # Output:
  # {
  #   "Status": "healthy",
  #   "FailingStreak": 0,
  #   "Log": [
  #     {
  #       "Start": "2024-02-14T10:00:00Z",
  #       "End": "2024-02-14T10:00:01Z",
  #       "ExitCode": 0,
  #       "Output": ""
  #     }
  #   ]
  # }

  # Trigger unhealthy state (for testing)
  docker exec test-app kill -STOP 1  # Freeze application

  # Wait 90 seconds (3 failures * 30s interval)
  docker ps
  # STATUS: "Up X seconds (unhealthy)"
  ```

  **6. ECS Integration:**

  ECS supports native Docker HEALTHCHECK but also has its own health check:

  ```json
  {
    "containerDefinitions": [
      {
        "healthCheck": {
          "command": [
            "CMD-SHELL",
            "curl -f http://localhost:3000/health || exit 1"
          ],
          "interval": 30,
          "timeout": 5,
          "retries": 3,
          "startPeriod": 60
        }
      }
    ]
  }
  ```

  **Note:** ECS task definition health check overrides Dockerfile HEALTHCHECK.

  **7. Docker Compose:**

  ```yaml
  services:
    app:
      build: .
      # HEALTHCHECK from Dockerfile is automatically used
      # Or override:
      healthcheck:
        test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
        interval: 30s
        timeout: 3s
        retries: 3
        start_period: 40s
  ```

  **Best Practices:**
  - **Keep it fast:** < 1 second response time
  - **Check critical dependencies:** Database, Redis, required APIs
  - **Don't check external services:** May cause false positives
  - **Use appropriate start-period:** Long enough for app initialization
  - **Return 200 for healthy, 503 for unhealthy**
  - **Include timestamp for debugging**

  **Troubleshooting:**

  **Health check always failing:**

  ```bash
  # Check what the health check sees
  docker exec test-app curl -v http://localhost:3000/health

  # Check if curl is installed
  docker exec test-app which curl

  # View health check command output
  docker inspect test-app | jq '.[0].State.Health.Log[-1].Output'
  ```

  **Application slow to start:**

  ```dockerfile
  # Increase start-period
  HEALTHCHECK --interval=30s --timeout=3s --start-period=120s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1
  ```

  **Health endpoint too slow:**

  ```javascript
  // Don't do heavy checks in health endpoint
  app.get("/health", async (req, res) => {
    // Quick check only
    if (server.listening) {
      res.status(200).send("OK");
    } else {
      res.status(503).send("NOT_READY");
    }
  });

  // Separate detailed check endpoint
  app.get("/health/detailed", async (req, res) => {
    // Full dependency checks
  });
  ```

- **Acceptance Criteria:**
  - ✅ Dockerfile contains HEALTHCHECK directive
  - ✅ Health endpoint responds in < 1 second
  - ✅ `docker ps` shows "(healthy)" status after startup
  - ✅ Unhealthy container triggers restart in docker-compose
  - ✅ Health check validates database and Redis connectivity
  - ✅ Appropriate start-period prevents false failures during startup
  - ✅ docker inspect shows health check history
