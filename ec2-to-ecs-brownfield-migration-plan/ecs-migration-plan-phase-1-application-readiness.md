# ECS Fargate Migration Plan - Phase 1: Application Readiness

## Overview

This migration represents a shift to the **12-Factor App** methodology—moving from persistent, mutable EC2 servers to immutable, ephemeral Fargate containers. The core principle: **your application must be self-contained, stateless, and environment-agnostic**.

---

## Feature 1: Container Packaging

### Story 1.1: Create Production-Ready Dockerfile

- **Title:** Create Production-Ready Dockerfile
- **Persona:** As a **DevOps engineer**, I need to package the application into a portable Docker image so that it can run identically in any environment (local, staging, production) without server-specific dependencies.

- **Requirements:**
  - Application must build successfully into a Docker image
  - Image must contain all OS-level dependencies (runtimes, libraries, tools)
  - Image must expose the correct port(s)
  - Image must define a proper `ENTRYPOINT` or `CMD`
  - No hardcoded filesystem paths that assume persistence

- **Implementation Details:**
  - Create a `Dockerfile` in the repository root
  - Use an official base image appropriate for the language/framework (e.g., `node:20-alpine`, `python:3.11-slim`)
  - Copy application code and install dependencies
  - Set working directory and expose application port
  - Define the startup command
  - Add a `.dockerignore` file to exclude `node_modules`, `.git`, `.env`, etc.

- **Acceptance Criteria:**
  - ✅ Running `docker build -t my-app .` completes without errors
  - ✅ Running `docker run -p 80:80 my-app` starts the application
  - ✅ Application responds to HTTP requests on localhost
  - ✅ Application behavior matches current EC2 behavior

---

### Story 1.2: Handle PID 1 and Zombie Processes

- **Title:** Configure Init Process for Proper Signal Handling
- **Persona:** As a **developer**, I need the container to properly handle signals and reap zombie processes so that graceful shutdown works correctly and the container doesn't accumulate zombie processes over time.

- **Requirements:**
  - Container must properly handle SIGTERM for graceful shutdown
  - Container must reap zombie child processes
  - Application runtime must not run as PID 1 (unless it handles signals natively)
  - Solution must work for Node.js, Python, Java, and other runtimes

- **Implementation Details:**
  - **The Problem:**
    - In Docker, the first process (PID 1) has special responsibilities:
      1. **Signal forwarding:** PID 1 must forward SIGTERM to child processes
      2. **Zombie reaping:** PID 1 must reap zombie (defunct) child processes
    - Most application runtimes (Node.js, Python, Java) do NOT handle these responsibilities
    - **What happens without proper init:**
      - App doesn't shut down gracefully on `docker stop` (waits 30s, then SIGKILL)
      - Zombie processes accumulate if app spawns child processes
      - Container becomes unstable over time
  - **Solution 1: Use `tini` in Dockerfile (Recommended for all apps)**

    `tini` is a lightweight init system that:
    - Forwards signals to child processes
    - Reaps zombie processes
    - Adds only ~100KB to image size

    **Update Dockerfile:**

    ```dockerfile
    FROM node:22-slim

    # Install tini
    RUN apt-get update && apt-get install -y tini && rm -rf /var/lib/apt/lists/*

    WORKDIR /app
    COPY package*.json ./
    RUN npm ci --production
    COPY . .

    EXPOSE 3000

    # Use tini as PID 1
    ENTRYPOINT ["/usr/bin/tini", "--"]
    CMD ["node", "server.js"]
    ```

    **For Alpine-based images:**

    ```dockerfile
    FROM node:22-alpine

    # tini is available in Alpine repos
    RUN apk add --no-cache tini

    ENTRYPOINT ["/sbin/tini", "--"]
    CMD ["node", "server.js"]
    ```

  - **Solution 2: Use ECS Task Definition `initProcessEnabled` (ECS-specific)**

    ECS can inject an init process without modifying the Dockerfile:

    ```json
    {
      "family": "my-app",
      "containerDefinitions": [
        {
          "name": "app",
          "image": "my-app:latest",
          "linuxParameters": {
            "initProcessEnabled": true
          }
        }
      ]
    }
    ```

    **Pros:**
    - No Dockerfile changes required
    - Works with existing images
    - ECS-native solution

    **Cons:**
    - Only works in ECS (not locally or in other orchestrators)
    - Less explicit than Dockerfile approach

  - **Solution 3: Use `dumb-init` (Alternative to tini)**

    Similar to tini but with different behavior:

    ```dockerfile
    RUN wget -O /usr/local/bin/dumb-init https://github.com/Yelp/dumb-init/releases/download/v1.2.5/dumb-init_1.2.5_amd64 \
        && chmod +x /usr/local/bin/dumb-init

    ENTRYPOINT ["/usr/local/bin/dumb-init", "--"]
    CMD ["node", "server.js"]
    ```

  - **Verify PID 1 handling:**

    **Test signal forwarding:**

    ```bash
    # Run container
    docker run -d --name test-app my-app:latest

    # Send SIGTERM
    docker stop test-app

    # Check logs - should see graceful shutdown message within 5 seconds
    docker logs test-app

    # If container takes 30 seconds to stop, signal forwarding is broken
    ```

    **Test zombie reaping:**

    ```bash
    # Exec into running container
    docker exec test-app ps aux

    # Look for <defunct> processes
    # Should NOT see lines like:
    # node      123  0.0  0.0      0     0 ?        Z    14:23   0:00 [node] <defunct>
    ```

  - **Application-specific notes:**

    | Runtime         | Native Signal Handling?                      | Recommendation                     |
    | --------------- | -------------------------------------------- | ---------------------------------- |
    | **Node.js**     | ❌ No (unless you manually handle SIGTERM)   | **Use tini or initProcessEnabled** |
    | **Python**      | ❌ No (unless using signal module)           | **Use tini or initProcessEnabled** |
    | **Java**        | ⚠️ Partial (handles SIGTERM but not zombies) | **Use tini or initProcessEnabled** |
    | **Go**          | ✅ Yes (if properly coded)                   | Optional (but tini adds safety)    |
    | **Nginx**       | ✅ Yes                                       | No init needed                     |
    | **Bash script** | ❌ No                                        | **Absolutely use tini**            |

- **Acceptance Criteria:**
  - ✅ `tini` or `dumb-init` added to Dockerfile, OR `initProcessEnabled: true` set in task definition
  - ✅ Container stops gracefully within 10 seconds when sent SIGTERM
  - ✅ No zombie (`<defunct>`) processes accumulate during 24-hour run test
  - ✅ Application logs show graceful shutdown message
  - ✅ Load test with process spawning (if applicable) shows no zombie accumulation

---

### Story 1.3: Eliminate Ephemeral Filesystem Dependencies

- **Title:** Eliminate Ephemeral Filesystem Dependencies
- **Persona:** As a **developer**, I need to remove all reliance on local filesystem storage so that the application continues to function when containers are destroyed and recreated.
- **Requirements:**
  - Identify all file upload/download paths (e.g., `/var/www/uploads`, `/tmp/cache`)
  - Refactor file storage to use AWS S3 or EFS
  - Ensure no application state is stored on local disk

- **Implementation Details:**
  - Audit codebase for filesystem operations (`fs.writeFile`, `file_put_contents`, `open()`, etc.)
  - Replace local file writes with S3 SDK calls (`PutObject`, `GetObject`)
  - For high-frequency file access, consider mounting an EFS volume to the Fargate task
  - Update any file URL generation to return S3 pre-signed URLs or CloudFront URLs

- **Acceptance Criteria:**
  - ✅ File uploads persist after container restart
  - ✅ No application errors when `/var/www/uploads` (or similar) doesn't exist
  - ✅ Files are accessible from any running task instance

---

### Story 1.3: Configure Network Binding and Port Exposure

- **Title:** Bind to 0.0.0.0 and Expose Container Port
- **Persona:** As a **DevOps engineer**, I need the application to listen on all network interfaces and expose the correct port so that the ALB can reach the container and health checks pass.
- **Requirements:**
  - Application must bind to `0.0.0.0`, not `127.0.0.1` or `localhost`
  - Dockerfile must include `EXPOSE` directive for documentation and tooling
  - Application port must match the port configured in ECS Task Definition and ALB Target Group

- **Implementation Details:**
  - Update application startup to bind to `0.0.0.0`:
    - **Node.js/Express**: `app.listen(PORT, '0.0.0.0')` (not `app.listen(PORT)`—some frameworks default to localhost)
    - **Python/Flask**: `app.run(host='0.0.0.0', port=PORT)`
    - **Python/Gunicorn**: `gunicorn -b 0.0.0.0:8000`
    - **Go**: `http.ListenAndServe(":8080", handler)` (colon prefix binds all interfaces)
    - **Nginx**: `listen 0.0.0.0:80;`
  - Add `EXPOSE` directive in Dockerfile:
    ```dockerfile
    EXPOSE 8080
    ```
  - Ensure `HOST` environment variable is configurable (default to `0.0.0.0`)
  - Use non-privileged ports (>1024) like 3000, 8080—let ALB handle 80/443

- **Acceptance Criteria:**
  - ✅ `docker run -p 8080:8080 my-app` responds to requests from host machine
  - ✅ `netstat` inside container shows app listening on `0.0.0.0:PORT`, not `127.0.0.1:PORT`
  - ✅ ALB health checks pass after deployment
  - ✅ Another container on the same Docker network can reach the app

---

### Story 1.5: Build Multi-Architecture Container Images

- **Title:** Support ARM64 (Graviton) for Cost Savings
- **Persona:** As a **DevOps engineer**, I want to build multi-architecture (amd64 + arm64) container images so that I can optionally run on AWS Graviton processors for 20% cost savings.

- **Requirements:**
  - Build images for both amd64 (Intel/AMD) and arm64 (Graviton) architectures
  - Publish multi-architecture manifest to ECR
  - Verify application works on both architectures

- **Implementation Details:**
  - **Why multi-architecture:**
    - **AWS Graviton (ARM64) Fargate pricing is ~20% cheaper** than x86_64
    - Example: 1 vCPU + 2GB Fargate task
      - x86_64: $0.04856/hour
      - ARM64 (Graviton): $0.03885/hour
      - **Savings: $0.00971/hour = $7.09/month per task**
    - For 10 tasks running 24/7: **$70/month savings**
  - **Use Docker Buildx for multi-architecture builds:**

    **Create builder (one-time setup):**

    ```bash
    docker buildx create --name multi-arch --use
    docker buildx inspect --bootstrap
    ```

    **Update Dockerfile to be ARM-compatible:**
    - Most base images support multi-arch: `node:22-slim`, `python:3.11-slim`, `openjdk:17-slim`
    - Check for native dependencies (e.g., compiled Python packages)
    - Use `apt-get` or `apk` for dependencies (not pre-compiled binaries)

    **Build and push multi-architecture image:**

    ```bash
    # Login to ECR
    aws ecr get-login-password --region us-east-1 | \
      docker login --username AWS --password-stdin 123456789012.dkr.ecr.us-east-1.amazonaws.com

    # Build for both architectures
    docker buildx build \
      --platform linux/amd64,linux/arm64 \
      -t 123456789012.dkr.ecr.us-east-1.amazonaws.com/my-app:latest \
      --push \
      .
    ```

  - **Update ECS Task Definition to use ARM64:**

    ```json
    {
      "family": "my-app",
      "cpu": "256",
      "memory": "512",
      "runtimePlatform": {
        "cpuArchitecture": "ARM64",
        "operatingSystemFamily": "LINUX"
      },
      "containerDefinitions": [...]
    }
    ```

    Or stick with x86_64 (Fargate auto-selects based on runtimePlatform):

    ```json
    "runtimePlatform": {
      "cpuArchitecture": "X86_64",
      "operatingSystemFamily": "LINUX"
    }
    ```

  - **Verify multi-arch manifest:**

    ```bash
    docker buildx imagetools inspect \
      123456789012.dkr.ecr.us-east-1.amazonaws.com/my-app:latest

    # Should see:
    # MediaType: application/vnd.docker.distribution.manifest.list.v2+json
    # Manifests:
    #   - linux/amd64
    #   - linux/arm64
    ```

  - **Common ARM64 compatibility issues:**

    | Issue                                       | Solution                                                  |
    | ------------------------------------------- | --------------------------------------------------------- |
    | **Native npm packages** (e.g., `node-sass`) | Use pure JS alternatives or ensure package supports ARM64 |
    | **Pre-compiled binaries** in Dockerfile     | Use `apt-get` or compile from source                      |
    | **Alpine Linux musl issues**                | Use Debian-based images (`-slim`) instead                 |
    | **Java JIT performance**                    | Graviton performs very well with Java - no issues         |

- **Acceptance Criteria:**
  - ✅ Multi-architecture image built for amd64 and arm64
  - ✅ Image pushed to ECR with multi-arch manifest
  - ✅ Application tested on both x86_64 and ARM64 Fargate
  - ✅ CI/CD pipeline updated to build multi-arch images
  - ✅ Team trained on switching between architectures via `runtimePlatform`
  - ✅ Cost savings documented and tracked

---

### Story 1.6: Establish Local Development Parity with docker-compose

- **Title:** Ensure Local Environment Matches ECS Production
- **Persona:** As a **developer**, I want a local Docker Compose environment that matches ECS so that I can test integrations (database, Redis, secrets) before deployment.

- **Requirements:**
  - Developers can run full stack locally with `docker-compose up`
  - Local environment uses the same container images as ECS
  - Local environment includes database, Redis, and application
  - Configuration matches ECS as closely as possible

- **Implementation Details:**
  - **Create `docker-compose.yml` for local development:**

    ```yaml
    version: "3.8"

    services:
      # Application
      app:
        build: .
        ports:
          - "3000:3000"
        environment:
          NODE_ENV: development
          DB_HOST: db
          DB_PORT: 3306
          DB_NAME: myapp
          DB_USER: root
          DB_PASSWORD: localpassword
          REDIS_HOST: redis
          REDIS_PORT: 6379
        depends_on:
          db:
            condition: service_healthy
          redis:
            condition: service_started
        healthcheck:
          test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
          interval: 10s
          timeout: 5s
          retries: 3

      # MySQL (matches RDS version)
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

      # Redis (matches ElastiCache version)
      redis:
        image: redis:7-alpine
        ports:
          - "6379:6379"

    volumes:
      mysql_data:
    ```

  - **Developer workflow:**

    ```bash
    # Start full stack
    docker-compose up -d

    # View logs
    docker-compose logs -f app

    # Run migrations
    docker-compose exec app npm run migrate

    # Stop stack
    docker-compose down
    ```

  - **Match ECS environment variables:**
    - Use `.env` file for local overrides:
      ```bash
      # .env (gitignored)
      DB_PASSWORD=localpassword
      AWS_REGION=us-east-1
      ```
    - Document which env vars differ between local and ECS
    - Use same secret names where possible
  - **Local vs ECS differences to document:**

    | Aspect                | Local (docker-compose)          | ECS Production             |
    | --------------------- | ------------------------------- | -------------------------- |
    | **Database**          | MySQL container                 | RDS MySQL                  |
    | **Secrets**           | Environment variables           | Secrets Manager            |
    | **Networking**        | Bridge network                  | VPC with subnets           |
    | **Service Discovery** | Container names (`db`, `redis`) | RDS/ElastiCache endpoints  |
    | **IAM**               | No IAM                          | Task Role + Execution Role |

- **Acceptance Criteria:**
  - ✅ `docker-compose up` starts full stack (app + database + Redis)
  - ✅ Application connects to local database and Redis
  - ✅ Health checks pass locally
  - ✅ Migrations run successfully via docker-compose
  - ✅ New developers can onboard with README instructions
  - ✅ Local environment documented in `README.md`
  - ✅ `.env.example` file provided with all required variables

---

## Feature 2: Externalized Configuration

### Story 2.1: Migrate Configuration to Environment Variables

- **Title:** Migrate Configuration to Environment Variables
- **Persona:** As a **developer**, I need the application to read all configuration from environment variables so that I can deploy the same image to different environments (dev, staging, prod) without rebuilding.

- **Requirements:**
  - No `.env` files baked into the Docker image
  - No hardcoded secrets in source code
  - All secrets (DB passwords, API keys) injected at runtime
  - Application must fail gracefully with clear errors if required variables are missing

- **Implementation Details:**
  - Inventory all configuration values currently in `.env` files or hardcoded
  - Refactor application to read from `process.env` / `os.environ` / `$_ENV`
  - Create a config validation layer that checks for required variables at startup
  - Document all required environment variables in a `README` or `.env.example`
  - **How secrets will flow (for context):**

    ```
    ┌─────────────────────┐      ┌─────────────────────┐      ┌─────────────────────┐
    │  Secrets Manager    │ ───▶ │  ECS Task Def       │ ───▶ │  Your App           │
    │  (Phase 2 creates)  │      │  (secrets block)    │      │  (reads from        │
    │                     │      │                     │      │   process.env)      │
    └─────────────────────┘      └─────────────────────┘      └─────────────────────┘
    ```

    - **Phase 1 (this story):** App reads secrets from environment variables (e.g., `process.env.DB_PASSWORD`)
    - **Phase 2 (Story 4.1):** Infra team creates secrets in AWS Secrets Manager
    - **Phase 3 (Task Definition):** ECS injects Secrets Manager values as environment variables
    - **Your app doesn't need to know about Secrets Manager** — it just reads env vars like normal

  - **Backward compatibility during migration:**
    - On EC2: Secrets come from `.env` file loaded by PM2/supervisor
    - On ECS: Secrets come from Secrets Manager injected as env vars
    - App code is identical — both appear as `process.env.DB_PASSWORD`

- **Acceptance Criteria:**
  - ✅ `docker run -e DB_HOST=localhost -e DB_PASS=secret my-app` starts successfully
  - ✅ Changing `DB_HOST` env var connects to a different database without rebuilding
  - ✅ Missing required env vars produce a clear startup error message
  - ✅ No secrets visible in Docker image layers (`docker history`)
  - ✅ App works on both EC2 (`.env` file) and ECS (injected env vars) without code changes

---

## Feature 3: Centralized Logging

### Story 3.1: Implement Console-Based Logging

- **Title:** Implement Console-Based Logging
- **Persona:** As an **operations engineer**, I need application logs written to STDOUT/STDERR so that Fargate's `awslogs` driver captures them and sends them to CloudWatch, giving me visibility without SSH access.

- **Requirements:**
  - All application logs must go to console (STDOUT for info, STDERR for errors)
  - No logs written to local files (e.g., `/var/log/app.log`)
  - Logs must be structured (JSON preferred) for easier querying
  - **Change must work on both EC2 and ECS during migration period**

- **Implementation Details:**
  - **Why stdout logging works in BOTH environments (backward-compatible):**
    - The key insight: stdout logging works on EC2 too. The difference is what _captures_ it.
      | Environment | App logs to... | Captured by... | Ends up in... |
      |-------------|----------------|----------------|---------------|
      | EC2 (systemd) | stdout | journald | `journalctl -u myapp` |
      | EC2 (PM2) | stdout | PM2 | `~/.pm2/logs/myapp-out.log` |
      | EC2 (supervisor) | stdout | supervisor | configured `stdout_logfile` |
      | ECS/Fargate | stdout | Docker/awslogs | CloudWatch Logs |
    - **Your EC2 process manager already captures stdout.** You're just telling the app to write there instead of to a file.
    - This change can be deployed to EC2 first, validated, then the same code runs in ECS.
  - **Update logging configuration:**
    - **Node.js (Winston):**

      ```javascript
      // Before (file-based)
      const logger = winston.createLogger({
        transports: [
          new winston.transports.File({ filename: "/var/log/app.log" }),
        ],
      });

      // After (stdout - works on EC2 and ECS)
      const logger = winston.createLogger({
        transports: [
          new winston.transports.Console({ format: winston.format.json() }),
        ],
      });
      ```

    - **Python:**
      ```python
      import logging, sys
      logging.basicConfig(stream=sys.stdout, level=logging.INFO)
      ```
    - **PHP/Laravel**: Set `LOG_CHANNEL=stderr` in `.env`
    - **Nginx**: Use `access_log /dev/stdout` and `error_log /dev/stderr`

  - **Enable JSON log format** for structured logging (easier CloudWatch queries)
  - **Include correlation IDs/request IDs** in log entries for tracing
  - **On EC2 during migration (if you need file output):**
    - systemd can redirect stdout to file if needed:
      ```ini
      # In systemd unit file
      StandardOutput=append:/var/log/myapp.log
      StandardError=append:/var/log/myapp-error.log
      ```
    - Or continue viewing via: `journalctl -u <service> -f`
  - **Update log consumers (critical — from Phase 0 audit):**
    - If a log shipper (Filebeat, Fluentd) watches `/var/log/app.log`:
      - Update it to watch journald: `journalctl -u myapp -f -o json`
      - Or configure systemd to redirect stdout to the old file path
    - If using CloudWatch Agent on EC2: Configure to read from journald
    - Update any dashboards/alerts that depend on the old log location
  - **Remove logrotate configs** for old log files (no longer needed after migration)
  - **Configure ECS Task Definition** with `awslogs` log driver (Phase 3)

- **Acceptance Criteria:**
  - ✅ App logs to stdout (verify: `docker run my-app` prints to terminal)
  - ✅ No log files created inside container
  - ✅ **EC2 still works:** Logs visible via `journalctl` or process manager
  - ✅ **Log consumers updated:** Shippers, dashboards, and alerts still receive logs
  - ✅ Logs appear in CloudWatch after ECS deployment
  - ✅ Logs are JSON-formatted and queryable in CloudWatch Logs Insights

---

## Feature 4: Distributed Session Management

### Story 4.1: Externalize Session Storage

- **Title:** Migrate Sessions to Redis/Database
- **Persona:** As a **user**, I need my login session to persist across requests so that I am not randomly logged out when my requests hit different Fargate tasks behind the load balancer.

- **Requirements:**
  - Sessions must not be stored in local RAM or filesystem
  - Sessions must be accessible by all running task instances
  - Session store must be highly available and low-latency

- **Implementation Details:**
  - Provision an AWS ElastiCache Redis cluster (or use existing RDS)
  - Update session configuration:
    - **Node.js/Express**: Use `connect-redis` with `express-session`
    - **PHP/Laravel**: Set `SESSION_DRIVER=redis`
    - **Python/Django**: Configure `SESSION_ENGINE` to use Redis/DB backend
    - **Ruby/Rails**: Use `redis-session-store` gem
  - Add Redis connection string as environment variable
  - Configure session TTL appropriately

- **Acceptance Criteria:**
  - ✅ User logs in on Task A, next request routed to Task B—user remains logged in
  - ✅ Scaling from 1 to N tasks does not cause session loss
  - ✅ Container restart does not log out active users
  - ✅ Sessions visible in Redis (`redis-cli KEYS *`)

---

## Feature 5: Scheduled Tasks & Background Jobs

### Story 5.1: Replace Local Crontab with AWS EventBridge Scheduler

- **Title:** Replace Local Crontab with AWS EventBridge Scheduler
- **Persona:** As a **system administrator**, I need scheduled tasks to run exactly once at the specified time so that batch jobs (reports, cleanup, notifications) execute reliably without duplication across multiple tasks.

- **Requirements:**
  - No `crontab` entries inside Docker container
  - Scheduled jobs must run exactly once, regardless of task count
  - Job execution must be logged and auditable
  - Failed jobs must be retryable

- **Implementation Details:**
  - Inventory all current crontab entries on EC2
  - Create dedicated ECS Task Definitions for each scheduled job (or a single "worker" task with command overrides)
  - Create EventBridge Scheduler rules:
    - Define schedule expression (cron or rate)
    - Target: ECS `RunTask` API
    - Pass command override to run specific job
  - Configure CloudWatch Alarms for failed task executions
  - Remove crontab from Dockerfile

- **Acceptance Criteria:**
  - ✅ Scheduled job runs at configured time
  - ✅ Scaling web service to 5 tasks does not cause 5x job execution
  - ✅ Job execution visible in ECS Task history and CloudWatch Logs
  - ✅ Failed jobs trigger CloudWatch Alarm notification

---

### Story 5.2: Deploy Queue Workers as Dedicated ECS Service

- **Title:** Deploy Queue Workers as Dedicated ECS Service
- **Persona:** As a **developer**, I need background job workers (Sidekiq, Celery, Bull) to run as a separate service so that queue processing is decoupled from web request handling and can scale independently.

- **Requirements:**
  - Queue workers must not run inside the web container
  - Workers must be independently scalable
  - Workers must connect to same queue backend (Redis, SQS)

- **Implementation Details:**
  - Create separate ECS Service for workers using the same Docker image
  - Override the container command to run worker process instead of web server:
    - Web: `CMD ["node", "server.js"]`
    - Worker: command override `["node", "worker.js"]`
  - Configure worker service desired count based on queue depth
  - Optionally configure auto-scaling based on SQS queue length or custom metrics

- **Acceptance Criteria:**
  - ✅ Web service and worker service run as separate ECS Services
  - ✅ Stopping web service does not stop job processing
  - ✅ Worker service can scale independently of web service
  - ✅ Jobs enqueued by web service are processed by worker service

---

## Feature 6: Network & Proxy Configuration

### Story 6.1: Configure Trusted Proxy Headers

- **Title:** Trust X-Forwarded-For Headers from ALB
- **Persona:** As a **security engineer**, I need the application to correctly identify client IP addresses so that rate limiting, geo-blocking, and audit logs contain accurate user information instead of the ALB's internal IP.

- **Requirements:**
  - Application must read client IP from `X-Forwarded-For` header
  - Application must only trust proxy headers from known sources (ALB)
  - HTTPS detection must use `X-Forwarded-Proto` header

- **Implementation Details:**
  - Configure framework trust proxy settings:
    - **Express.js**: `app.set('trust proxy', true)`
    - **Laravel**: Set `TrustProxies` middleware with `*` or ALB CIDR
    - **Django**: Configure `SECURE_PROXY_SSL_HEADER` and `USE_X_FORWARDED_HOST`
    - **Rails**: Set `config.action_dispatch.trusted_proxies`
    - **Nginx**: Use `real_ip_header X-Forwarded-For` directive
  - Verify HTTPS redirect logic uses forwarded proto
  - Update any IP-based rate limiting to use forwarded IP

- **Acceptance Criteria:**
  - ✅ `request.ip` / `$_SERVER['REMOTE_ADDR']` returns actual client IP, not `10.x.x.x`
  - ✅ HTTPS detection works correctly behind ALB (no redirect loops)
  - ✅ Audit logs show real client IP addresses
  - ✅ Rate limiting applies per real client, not per ALB

---

## Feature 7: Graceful Shutdown Handling

### Story 7.1: Implement SIGTERM Handler

- **Title:** Handle Container Shutdown Signals Gracefully
- **Persona:** As a **user**, I need the application to finish processing my request before shutting down so that my transaction is not interrupted mid-process during deployments.

- **Requirements:**
  - Application must listen for `SIGTERM` signal
  - On `SIGTERM`, stop accepting new connections
  - Drain existing requests (complete in-flight work)
  - Exit cleanly before `SIGKILL` timeout (default 30s)

- **Implementation Details:**
  - Add signal handler to application entry point:
    - **Node.js**: `process.on('SIGTERM', () => server.close())`
    - **Python**: `signal.signal(signal.SIGTERM, handler)`
    - **Go**: Listen on `os.Signal` channel
  - Configure HTTP server to stop accepting new connections on signal
  - Wait for in-flight requests to complete (with timeout)
  - Close database connections and cleanup resources
  - Set ECS `stopTimeout` appropriately in task definition

- **Acceptance Criteria:**
  - ✅ `docker stop my-app` exits within 10 seconds (not 30s timeout)
  - ✅ In-flight HTTP requests complete successfully during shutdown
  - ✅ No `SIGKILL` in container logs during normal deployments
  - ✅ Zero dropped requests during rolling deployment

---

## Feature 8: Email Delivery

### Story 8.1: Replace Local Mail Agent with Cloud Email Service

- **Title:** Replace Local Mail Agent with Cloud Email Service
- **Persona:** As a **developer**, I need the application to send emails via an external service so that email delivery works without `sendmail` or `postfix` installed in the container.

- **Requirements:**
  - No reliance on local mail transfer agents (`sendmail`, `postfix`)
  - Email delivery via SMTP or API
  - Email credentials stored securely (not in code)
  - Delivery status trackable

- **Implementation Details:**
  - Choose email provider: AWS SES, SendGrid, Mailgun, Postmark
  - Update application email configuration:
    - Set SMTP host, port, username, password as env vars
    - Or use provider SDK for API-based sending
  - Verify sender domain/email in provider dashboard
  - Test email delivery in staging environment
  - Remove any `sendmail_path` or local MTA configuration

- **Acceptance Criteria:**
  - ✅ Application sends email successfully from Fargate container
  - ✅ No `sendmail` binary required in Docker image
  - ✅ Email delivery logs visible in provider dashboard (SES/SendGrid)
  - ✅ Bounces and complaints trackable

---

## Feature 9: Health Check Configuration

### Story 9.1: Implement ALB and ECS Health Check Endpoints

- **Title:** Implement Health Check Endpoints
- **Persona:** As an **operations engineer**, I need the application to respond to health checks quickly so that the ALB routes traffic only to healthy tasks and ECS doesn't kill healthy containers due to slow responses.

- **Requirements:**
  - Dedicated health check endpoint (e.g., `/health` or `/healthz`)
  - Health check must respond within ALB timeout (default 5 seconds)
  - Health check should be lightweight (basic process health)
  - Health check must not require authentication

- **Implementation Details:**
  - Create lightweight `/health` endpoint that returns `200 OK`
  - Keep this endpoint simple—just verify the process is running
  - Response should be fast (< 100ms) and not check dependencies yet
  - Configure ALB Target Group health check path, interval, and thresholds
  - Configure ECS health check in task definition if using `HEALTHCHECK` in Dockerfile

- **Acceptance Criteria:**
  - ✅ `/health` returns `200 OK` within 100ms
  - ✅ ALB marks task as healthy after deployment
  - ✅ Unhealthy tasks are automatically replaced by ECS
  - ✅ Health check failures visible in ALB metrics

---

### Story 9.2: Implement Dependency Health Checks

- **Title:** Add Deep Health Checks for Downstream Dependencies
- **Persona:** As a **DevOps engineer**, I need the application to verify that critical dependencies (database, Redis, external APIs) are reachable before accepting traffic so that users don't get 500 errors from a running container that can't actually serve requests.

- **Requirements:**
  - Separate health check endpoint for readiness (e.g., `/health/ready`)
  - Must verify database connectivity
  - Must verify Redis/cache connectivity (if used)
  - Must verify critical external API availability (if required)
  - Must fail fast if dependencies are unavailable
  - Must not impact basic liveness check (`/health`)

- **Implementation Details:**

  **Readiness vs Liveness Pattern:**

  ```
  /health        → Liveness  (Is the process alive?)
  /health/ready  → Readiness (Can the app handle traffic?)
  ```

  - **Liveness** (`/health`): Already implemented in Story 9.1
    - Quick check (< 100ms)
    - Returns 200 if process is running
    - Used by: ALB health checks, Docker HEALTHCHECK

  - **Readiness** (`/health/ready`): This story
    - Deep check (< 5s timeout)
    - Verifies all dependencies are reachable
    - Returns 503 if any dependency is down
    - Used by: ECS readiness checks, pre-traffic validation

  **Implementation Example (Node.js/Express):**

  ```javascript
  import express from "express";
  import mysql from "mysql2/promise";
  import Redis from "ioredis";

  const app = express();

  // Liveness (fast)
  app.get("/health", (req, res) => {
    res.status(200).json({ status: "ok" });
  });

  // Readiness (deep)
  app.get("/health/ready", async (req, res) => {
    const checks = {
      database: false,
      redis: false,
      externalApi: false,
    };

    try {
      // Check database
      const dbConnection = await mysql.createConnection({
        host: process.env.DB_HOST,
        user: process.env.DB_USER,
        password: process.env.DB_PASSWORD,
        database: process.env.DB_NAME,
        connectTimeout: 3000,
      });
      await dbConnection.ping();
      await dbConnection.end();
      checks.database = true;
    } catch (err) {
      console.error("Database health check failed:", err.message);
    }

    try {
      // Check Redis
      const redisClient = new Redis({
        host: process.env.REDIS_HOST,
        port: process.env.REDIS_PORT,
        password: process.env.REDIS_AUTH_TOKEN,
        connectTimeout: 3000,
        lazyConnect: true,
      });
      await redisClient.connect();
      await redisClient.ping();
      redisClient.disconnect();
      checks.redis = true;
    } catch (err) {
      console.error("Redis health check failed:", err.message);
    }

    try {
      // Check external API (optional)
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 3000);
      const response = await fetch(process.env.EXTERNAL_API_URL + "/status", {
        signal: controller.signal,
      });
      clearTimeout(timeoutId);
      checks.externalApi = response.ok;
    } catch (err) {
      console.error("External API health check failed:", err.message);
    }

    // Determine overall status
    const allHealthy = Object.values(checks).every((status) => status === true);

    if (allHealthy) {
      res.status(200).json({ status: "ready", checks });
    } else {
      res.status(503).json({ status: "not ready", checks });
    }
  });
  ```

  **Connection Pooling Consideration:**
  - If using connection pooling, test pool health instead of creating new connections
  - Example:
    ```javascript
    // Use existing pool
    await dbPool.query("SELECT 1");
    ```

  **Caching Strategy:**
  - For high-traffic apps, cache health check results for 5-10 seconds
  - Prevents overwhelming dependencies with health check requests
  - Example:

    ```javascript
    let cachedStatus = { healthy: false, timestamp: 0 };
    const CACHE_TTL = 5000; // 5 seconds

    if (Date.now() - cachedStatus.timestamp > CACHE_TTL) {
      // Run checks and update cache
      cachedStatus = { healthy: runChecks(), timestamp: Date.now() };
    }
    return cachedStatus.healthy ? 200 : 503;
    ```

  **Critical: Avoid the "Health Check Suicide Pact"**
  - **The Problem:**
    - If ALL tasks check database/Redis in their health check
    - And the database has a brief outage (10 seconds)
    - ALL tasks fail health check simultaneously
    - ECS kills the entire fleet
    - Even when the database recovers, you have zero running tasks
  - **The Solution: Separate Liveness from Readiness**

    | Endpoint        | Purpose       | Checks                  | Used By                    | Failure Impact                 |
    | --------------- | ------------- | ----------------------- | -------------------------- | ------------------------------ |
    | `/health`       | **Liveness**  | Process alive?          | ALB Target Group           | ALB stops routing to THIS task |
    | `/health/ready` | **Readiness** | Dependencies reachable? | ECS Container Health Check | ECS replaces THIS task         |

  - **Configuration:**

    **ALB Target Group (LIVENESS - Fast, Shallow):**

    ```hcl
    resource "aws_lb_target_group" "app" {
      health_check {
        enabled             = true
        path                = "/health"        # Shallow check
        healthy_threshold   = 2
        unhealthy_threshold = 2
        timeout             = 5
        interval            = 30
        matcher             = "200"
      }
    }
    ```

    **ECS Task Definition (READINESS - Deep, with high retry tolerance):**

    ```json
    {
      "healthCheck": {
        "command": [
          "CMD-SHELL",
          "curl -f http://localhost:3000/health/ready || exit 1"
        ],
        "interval": 30,
        "timeout": 5,
        "retries": 5, // High retries to tolerate brief DB blips
        "startPeriod": 60
      }
    }
    ```

  - **Why this works:**
    - **Database blips:** Tasks fail readiness check, but ALB keeps routing (liveness still passes)
    - **Task-specific issues:** If one task's DB connection is bad, only that task is replaced
    - **Fleet protection:** Database outage doesn't kill all tasks simultaneously
    - **High retry count (5):** Task survives 5 consecutive failures = 2.5 minutes of DB downtime before being replaced

  **Startup Behavior:**
  - `/health` should return 200 immediately
  - `/health/ready` may return 503 until connection pools are initialized
  - Configure `startPeriod` in ECS to allow warm-up time

- **Acceptance Criteria:**
  - ✅ `/health` returns 200 when all dependencies are available
  - ✅ `/health/ready` returns 200 when all dependencies are available
  - ✅ `/health/ready` returns 503 when database is down
  - ✅ **ALB health check points to `/health` (liveness), NOT `/health/ready`**
  - ✅ **ECS container health check points to `/health/ready` with retries >= 5**
  - ✅ Response includes individual check status in JSON
  - ✅ Health check completes within 5 seconds
  - ✅ Failed dependency checks log error messages
  - ✅ **Tested: Database outage for 30 seconds does NOT kill all tasks**
  - ✅ Container survives temporary dependency failures (doesn't crash)

---

## Feature 10: Resource Management

### Story 10.1: Configure Container Memory and CPU Limits

- **Title:** Right-Size Container Resources
- **Persona:** As a **DevOps engineer**, I need to set appropriate memory and CPU limits so that containers don't get OOM-killed unexpectedly or starve other tasks of resources.

- **Requirements:**
  - Memory limit must accommodate peak application usage
  - CPU allocation must handle expected request load
  - Application must handle memory pressure gracefully
  - Resource usage must be monitored

- **Implementation Details:**
  - Profile application memory usage under load on EC2 (use `top`, `htop`, or CloudWatch agent)
  - Set Fargate task memory slightly higher than observed peak (buffer for spikes)
  - Configure memory reservation (soft limit) vs memory limit (hard limit)
  - For Node.js: set `--max-old-space-size` to ~75% of container memory
  - For JVM: set `-Xmx` heap size appropriately
  - Set up CloudWatch alarms for memory utilization > 80%

- **Acceptance Criteria:**
  - ✅ Container runs for 24+ hours without OOM kill
  - ✅ Memory utilization stays below 80% under normal load
  - ✅ Application logs show no out-of-memory errors
  - ✅ CloudWatch metrics show stable memory usage pattern

---

## Feature 11: Database Connection Management

### Story 11.1: Implement Connection Pooling and Resilience

- **Title:** Configure Database Connection Pooling
- **Persona:** As a **developer**, I need the application to manage database connections efficiently so that scaling up tasks doesn't exhaust the database connection limit and cause outages.

- **Requirements:**
  - Connection pool size must be bounded
  - Total connections across all tasks must not exceed RDS `max_connections`
  - Application must handle connection failures gracefully
  - Connections must be released properly on shutdown

- **Implementation Details:**
  - **Strongly Recommended: Use RDS Proxy for Connection Management**

    **The Problem with Direct Connections:**
    - Auto-scaling can spike task count unexpectedly (e.g., 2 tasks → 20 tasks in 60 seconds)
    - Each task opens `pool_size` connections immediately
    - **Risk:** 20 tasks × 10 connections = 200 connections, exceeding RDS `max_connections` (150)
    - Result: New tasks fail to start, deployment fails, alert storm

    **RDS Proxy Solution:**
    - **Connection multiplexing:** 100 app connections → 10 actual database connections
    - **Automatic scaling:** Proxy handles connection management, not your app
    - **Built-in retry logic:** Transient connection failures are retried automatically
    - **Zero code changes:** Just change connection string

    **Setup:**

    ```bash
    aws rds create-db-proxy \
      --db-proxy-name my-app-proxy \
      --engine-family MYSQL \
      --auth [{
        "AuthScheme": "SECRETS",
        "SecretArn": "arn:aws:secretsmanager:..."
      }] \
      --role-arn arn:aws:iam::ACCOUNT:role/RDSProxyRole \
      --vpc-subnet-ids subnet-xxx subnet-yyy \
      --require-tls true
    ```

    **Update connection string:**

    ```javascript
    // Before (direct RDS connection)
    const pool = mysql.createPool({
      host: 'mydb.abc123.us-east-1.rds.amazonaws.com',
      ...
    });

    // After (via RDS Proxy)
    const pool = mysql.createPool({
      host: 'my-app-proxy.proxy-abc123.us-east-1.rds.amazonaws.com',
      ...
    });
    ```

    **Cost:**
    - $0.015 per vCPU-hour (~$11/month for 1 vCPU proxy)
    - $0.0000027 per connection per hour (~$2/month for 100 connections)
    - **Total:** ~$13/month for peace of mind

    **When you can skip RDS Proxy:**
    - You have a fixed, small number of tasks (e.g., always exactly 2 tasks)
    - You're NOT using auto-scaling
    - Your max possible connections are well below RDS limit
      - Example: `max_tasks = 5`, `pool_size = 10`, `total = 50` << `RDS max_connections = 150`

  - **Calculate max pool size:** `RDS max_connections / expected max tasks` (leave headroom)
  - **Configure connection pool in application:**
    - **Node.js/Knex**: `pool: { min: 2, max: 10 }`
    - **Python/SQLAlchemy**: `pool_size=5, max_overflow=10`
    - **Java/HikariCP**: `maximumPoolSize=10`
  - Enable connection validation/keep-alive to handle RDS failovers
  - Implement retry logic for transient connection errors

- **Acceptance Criteria:**
  - ✅ **RDS Proxy provisioned and tested, OR justification documented for not using it**
  - ✅ Scaling from 1 to 10 tasks doesn't cause "too many connections" errors
  - ✅ RDS failover doesn't crash the application (reconnects automatically)
  - ✅ Connections are released on container shutdown
  - ✅ Database connection count visible in RDS CloudWatch metrics
  - ✅ **Load test at 2× expected max scale shows stable connection count**

---

## Feature 12: Timezone Handling

### Story 12.1: Standardize Application Timezone

- **Title:** Handle Timezone Differences in Containers
- **Persona:** As a **developer**, I need the application to handle timezones consistently so that scheduled jobs, timestamps, and date displays work correctly when moving from a server set to local time to a UTC container.

- **Requirements:**
  - Understand current EC2 server timezone setting
  - Application must handle UTC-based container time
  - User-facing times must display in correct timezone
  - Database timestamps must be consistent

- **Implementation Details:**
  - Check current EC2 timezone: `timedatectl` or `cat /etc/timezone`
  - Option A: Set container timezone via `TZ` environment variable
  - Option B (Recommended): Keep containers in UTC, handle timezone conversion in application
  - Store all database timestamps in UTC
  - Convert to user's timezone only at display/API response layer
  - Update any hardcoded timezone assumptions in code
  - Test scheduled jobs trigger at expected real-world times

- **Acceptance Criteria:**
  - ✅ Timestamps in database are consistent before and after migration
  - ✅ User-facing times display correctly in their timezone
  - ✅ Scheduled jobs run at expected wall-clock time
  - ✅ Logs use consistent timestamp format (ISO 8601 with timezone)

---

## Feature 13: Startup Performance

### Story 13.1: Optimize Container Startup Time

- **Title:** Reduce Container Cold Start Time
- **Persona:** As an **operations engineer**, I need containers to start quickly so that auto-scaling responds to traffic spikes in time and deployments don't fail due to health check timeouts.

- **Requirements:**
  - Container must pass health check before ALB timeout (typically 60-90s)
  - Image size should be minimized for faster pulls
  - Application initialization should be optimized

- **Implementation Details:**
  - Use multi-stage Docker builds to reduce image size
  - Use slim/alpine base images where possible
  - Defer non-critical initialization (lazy loading)
  - Pre-warm database connection pools in health check
  - Avoid synchronous network calls during startup
  - Consider using ECR pull-through cache or VPC endpoints to speed up image pulls
  - Set appropriate ALB health check `HealthyThresholdCount` and `Interval`

- **Acceptance Criteria:**
  - ✅ Container starts and passes health check within 30 seconds
  - ✅ Docker image size under 500MB (ideally under 200MB)
  - ✅ Auto-scaling new tasks can serve traffic within 60 seconds
  - ✅ No health check failures during normal deployments

---

## Feature 14: DNS and Service Discovery

### Story 14.1: Handle DNS Caching and Resolution

- **Title:** Configure DNS TTL for Failover Scenarios
- **Persona:** As an **operations engineer**, I need the application to respect DNS TTL so that RDS failovers and service endpoint changes are detected without requiring container restarts.

- **Requirements:**
  - Application must not cache DNS indefinitely
  - DNS resolution must honor TTL from response
  - RDS Multi-AZ failover must work without intervention

- **Implementation Details:**
  - **JVM**: Set `-Dsun.net.inetaddr.ttl=60` (default is infinite caching)
  - **Node.js**: DNS caching depends on OS; consider `dns.setDefaultResultOrder('ipv4first')`
  - **Go**: Uses OS resolver, generally handles TTL correctly
  - Use RDS endpoint hostname, never hardcode IP addresses
  - Test failover behavior: trigger RDS failover and verify app reconnects
  - Consider using RDS Proxy which handles failover transparently

- **Acceptance Criteria:**
  - ✅ RDS Multi-AZ failover completes without manual intervention
  - ✅ Application reconnects to new primary within 60 seconds
  - ✅ No hardcoded IP addresses in configuration
  - ✅ Service discovery (if used) updates propagate correctly

---

## Feature 15: Security Hardening

### Story 15.1: Run Containers as Non-Root User

- **Title:** Implement Non-Root Container Execution
- **Persona:** As a **security engineer**, I need containers to run as a non-root user so that a container escape vulnerability has limited blast radius.

- **Requirements:**
  - Container process must not run as UID 0 (root)
  - Application files must have appropriate permissions
  - No `sudo` or privilege escalation in container

- **Implementation Details:**
  - Add non-root user in Dockerfile:
    ```dockerfile
    RUN addgroup -g 1001 appgroup && adduser -u 1001 -G appgroup -D appuser
    USER appuser
    ```
  - Ensure application files are owned by/readable by the app user
  - Verify application doesn't try to bind to privileged ports (< 1024)
  - Use port 3000/8080 internally, let ALB handle port 80/443
  - Test that application starts successfully as non-root

- **Acceptance Criteria:**
  - ✅ `docker exec my-app whoami` returns non-root user
  - ✅ Application starts and runs successfully
  - ✅ No permission denied errors in logs
  - ✅ Container doesn't require `--privileged` flag

---

## Feature 16: Secrets Rotation

### Story 16.1: Handle Dynamic Secret Updates

- **Title:** Support Secrets Rotation Without Redeployment
- **Persona:** As a **security engineer**, I need the application to handle rotating secrets so that credentials can be updated without causing downtime or requiring redeployments.

- **Requirements:**
  - Application must handle credential changes gracefully
  - Database password rotation must not cause outages
  - API key rotation must be seamless

- **Implementation Details:**
  - Use AWS Secrets Manager with automatic rotation enabled
  - Option A: Restart containers on secret rotation (ECS can detect Secrets Manager changes)
  - Option B: Implement in-app secret refresh (poll Secrets Manager periodically)
  - For database: use IAM authentication instead of passwords where possible
  - Configure Secrets Manager rotation Lambda with appropriate timing
  - Test rotation in staging environment

- **Acceptance Criteria:**
  - ✅ Secret rotation in Secrets Manager doesn't cause application errors
  - ✅ Old credentials continue working during rotation grace period
  - ✅ Application picks up new credentials automatically
  - ✅ Rotation events logged in CloudTrail

---

## Migration Hazards Summary

| Feature             | EC2 Behavior (Old)              | Fargate Behavior (New)           | Story Reference |
| ------------------- | ------------------------------- | -------------------------------- | --------------- |
| **File Storage**    | Local disk (`/var/www/uploads`) | Ephemeral filesystem             | Story 1.2       |
| **Network Binding** | Binds to localhost or 0.0.0.0   | Must bind to 0.0.0.0 for ALB     | Story 1.3       |
| **Configuration**   | `.env` files on server          | Environment variables at runtime | Story 2.1       |
| **Logs**            | File-based (`app.log`)          | STDOUT → CloudWatch              | Story 3.1       |
| **Sessions**        | Local disk/RAM                  | Distributed (Redis/DB)           | Story 4.1       |
| **Cron**            | Local `crontab`                 | EventBridge Scheduler            | Story 5.1       |
| **Background Jobs** | Same process/server             | Separate ECS Service             | Story 5.2       |
| **Client IPs**      | Direct connection               | Behind ALB (X-Forwarded-For)     | Story 6.1       |
| **Shutdown**        | Rarely restarted                | SIGTERM on every deploy          | Story 7.1       |
| **Email**           | Local `sendmail`                | External SMTP/API                | Story 8.1       |
| **Health Checks**   | Optional/manual                 | Required for ALB/ECS             | Story 9.1       |
| **Memory**          | Server has lots of RAM          | Hard container limits            | Story 10.1      |
| **DB Connections**  | One server = one pool           | N tasks = N pools                | Story 11.1      |
| **Timezone**        | Often local time                | Default UTC                      | Story 12.1      |
| **Startup**         | Server always running           | Cold starts on scale/deploy      | Story 13.1      |
| **DNS Caching**     | Long-lived process              | Must handle failovers            | Story 14.1      |
| **Root User**       | Often runs as root              | Should run as non-root           | Story 15.1      |
| **Secrets**         | Static in `.env`                | Dynamic, rotatable               | Story 16.1      |

---

## Pre-Migration Checklist

Before deploying to Fargate, verify each item:

- [ ] Application builds into Docker image successfully
- [ ] `docker run` works locally with only environment variables
- [ ] Application binds to `0.0.0.0` (not localhost/127.0.0.1)
- [ ] Dockerfile includes `EXPOSE` directive for application port
- [ ] No local filesystem dependencies for persistent data
- [ ] Logs output to STDOUT/STDERR
- [ ] Sessions stored externally (Redis/DB)
- [ ] Cron jobs identified and migration plan created
- [ ] Background workers separated from web process
- [ ] Trust proxy configured for X-Forwarded-For
- [ ] SIGTERM handler implemented
- [ ] Email uses external SMTP/API
- [ ] Health check endpoint exists and responds quickly
- [ ] Memory/CPU requirements profiled
- [ ] Database connection pool sized appropriately
- [ ] Timezone handling verified
- [ ] Container runs as non-root user
- [ ] Secrets externalized to Secrets Manager/SSM
