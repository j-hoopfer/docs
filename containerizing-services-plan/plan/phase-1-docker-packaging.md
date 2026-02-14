# Phase 1: Docker Packaging

## Overview

Create production-ready Docker images that package your application with all dependencies, expose correct ports, and follow container best practices.

**Business Value:** Enables consistent deployments across all environments, eliminating "works on my machine" issues. Docker images ensure dev, staging, and production run identical code.

**Prerequisites:** [12-Factor App Preparation](../../prepare-app-for-12-factor-plan/README.md) completed

**Next Phase:** [Container Lifecycle](container-lifecycle.md)

---

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
  - ✅ ALB health checks pass (in Phase 3)

---

## Story 3: Build Multi-Architecture Images

**Business Value:** Delivers immediate 20% cost savings on Fargate compute. Graviton (ARM64) Fargate costs 20% less than x86_64, saving $200-2,000/month. For company spending $10K/month on Fargate, this 2-hour effort delivers $2K/month savings ($24K/year ROI).

- **Title:** Support ARM64 (Graviton) for Cost Savings
- **Persona:** As a **DevOps engineer**, I want to build multi-architecture images so that I can run on AWS Graviton processors for 20% cost savings.

- **Requirements:**
  - Build images for amd64 and arm64
  - Publish multi-arch manifest to ECR
  - Verify application works on both architectures

- **Implementation Details:**

  **Setup Buildx:**

  ```bash
  # Create builder
  docker buildx create --name multi-arch --use
  docker buildx inspect --bootstrap
  ```

  **Build Multi-Arch Image:**

  ```bash
  # Login to ECR
  aws ecr get-login-password --region us-east-1 | \
    docker login --username AWS --password-stdin \
    123456789012.dkr.ecr.us-east-1.amazonaws.com

  # Build and push for both architectures
  docker buildx build \
    --platform linux/amd64,linux/arm64 \
    -t 123456789012.dkr.ecr.us-east-1.amazonaws.com/my-app:latest \
    --push \
    .
  ```

  **Verify Multi-Arch:**

  ```bash
  docker buildx imagetools inspect \
    123456789012.dkr.ecr.us-east-1.amazonaws.com/my-app:latest

  # Should show:
  # MediaType: application/vnd.docker.distribution.manifest.list.v2+json
  # Manifests:
  #   Platform: linux/amd64
  #   Platform: linux/arm64
  ```

  **Common ARM64 Issues:**

  | Issue                 | Solution                           |
  | --------------------- | ---------------------------------- |
  | Native npm packages   | Use pure JS alternatives           |
  | Pre-compiled binaries | Use apt-get or compile from source |
  | Alpine musl issues    | Use Debian-based images (-slim)    |

- **Acceptance Criteria:**
  - ✅ Multi-arch manifest published to ECR
  - ✅ Application tested on both x86_64 and ARM64 Fargate
  - ✅ CI/CD builds multi-arch images
  - ✅ Cost savings documented

---

## Story 4: Local Development Parity

**Business Value:** Accelerates developer productivity 30-50% through faster feedback loops. Running full stack locally via `docker-compose up` enables testing in seconds vs 5-10 minutes deploying to dev environment. Reduces development cycle time from 15-20 minutes to 2-3 minutes per iteration.

- **Title:** Create docker-compose for Local Development
- **Persona:** As a **developer**, I want to run full stack locally so that I can test integrations before deployment.

- **Requirements:**
  - `docker-compose up` starts full stack
  - Local environment matches ECS closely
  - Includes database, Redis, application
  - Easy onboarding for new developers

- **Implementation Details:**

  ```yaml
  # docker-compose.yml
  version: "3.8"

  services:
    app:
      build: .
      ports:
        - "3000:3000"
      environment:
        NODE_ENV: development
        DB_HOST: db
        DB_PORT: 3306
        DB_USER: root
        DB_PASSWORD: localpassword
        DB_NAME: myapp
        REDIS_HOST: redis
        REDIS_PORT: 6379
      depends_on:
        db:
          condition: service_healthy
        redis:
          condition: service_started
      volumes:
        - ./src:/app/src # Live reload
      healthcheck:
        test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
        interval: 10s
        timeout: 5s
        retries: 3

    db:
      image: mysql:8.0
      environment:
        MYSQL_ROOT_PASSWORD: localpassword
        MYSQL_DATABASE: myapp
      ports:
        - "3306:3306"
      volumes:
        - mysql_data:/var/lib/mysql
      healthcheck:
        test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
        interval: 5s
        timeout: 3s
        retries: 5

    redis:
      image: redis:7-alpine
      ports:
        - "6379:6379"

  volumes:
    mysql_data:
  ```

  **Developer Workflow:**

  ```bash
  # Start stack
  docker-compose up -d

  # View logs
  docker-compose logs -f app

  # Run migrations
  docker-compose exec app npm run migrate

  # Stop
  docker-compose down
  ```

- **Acceptance Criteria:**
  - ✅ `docker-compose up` starts full stack
  - ✅ App connects to local database and Redis
  - ✅ Health checks pass
  - ✅ New developers can onboard with README
  - ✅ Live reload works for development

---

## Phase Completion Checklist

Before proceeding to [Container Lifecycle](container-lifecycle.md):

- [ ] Production Dockerfile created
- [ ] Image builds without errors
- [ ] Application binds to 0.0.0.0
- [ ] Multi-architecture images built
- [ ] docker-compose.yml created for local development
- [ ] .dockerignore configured
- [ ] Image size optimized (< 500MB)
- [ ] Container runs as non-root user
- [ ] Application tested in container locally

---

## Rollback Plan

- **Build failures:** Check base image availability, verify dependency installation
- **Network issues:** Verify HOST=0.0.0.0, check EXPOSE directive
- **ARM64 failures:** Fall back to x86_64, investigate native dependencies
- **Local dev issues:** Check service dependencies, verify environment variables
