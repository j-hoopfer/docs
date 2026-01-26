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

### Story 1.2: Eliminate Ephemeral Filesystem Dependencies

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
  - Health check should verify critical dependencies (DB, Redis) are reachable
  - Health check must not require authentication

- **Implementation Details:**
  - Create lightweight `/health` endpoint that returns `200 OK`
  - Optionally add `/health/ready` (readiness) vs `/health/live` (liveness) endpoints
  - Readiness check: verify DB connection, Redis connection, required services
  - Liveness check: simple ping (app process is running)
  - Configure ALB Target Group health check path, interval, and thresholds
  - Configure ECS health check in task definition if using `HEALTHCHECK` in Dockerfile

- **Acceptance Criteria:**
  - ✅ `/health` returns `200 OK` within 2 seconds
  - ✅ ALB marks task as healthy after deployment
  - ✅ Unhealthy tasks are automatically replaced by ECS
  - ✅ Health check failures visible in ALB metrics

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
  - Calculate max pool size: `RDS max_connections / expected max tasks` (leave headroom)
  - Configure connection pool in application:
    - **Node.js/Knex**: `pool: { min: 2, max: 10 }`
    - **Python/SQLAlchemy**: `pool_size=5, max_overflow=10`
    - **Java/HikariCP**: `maximumPoolSize=10`
  - Enable connection validation/keep-alive to handle RDS failovers
  - Implement retry logic for transient connection errors
  - Consider using RDS Proxy for connection pooling at the infrastructure level

- **Acceptance Criteria:**
  - ✅ Scaling from 1 to 10 tasks doesn't cause "too many connections" errors
  - ✅ RDS failover doesn't crash the application (reconnects automatically)
  - ✅ Connections are released on container shutdown
  - ✅ Database connection count visible in RDS CloudWatch metrics

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

---

## Appendix A: Secrets Security — EC2 vs ECS Comparison

This appendix explains **how secrets are stored and injected** in both environments, and why ECS + Secrets Manager is a security improvement.

### The Security Question

When your app reads `process.env.DB_PASSWORD`, the question isn't just "does it work?" — it's:

1. **Where is the secret stored at rest?** (On disk? Encrypted? Where?)
2. **Who can access the secret?** (Anyone with SSH? IAM-controlled?)
3. **Is there an audit trail?** (Who accessed what, when?)
4. **Can the secret be rotated?** (Without downtime?)

### EC2: Current State (Typical Patterns)

#### Pattern 1: `.env` File + dotenv Library

```
┌─────────────────────────────────────────────────────────────────┐
│ EC2 Instance                                                    │
│  ┌──────────────────┐      ┌──────────────────────────────────┐ │
│  │  .env file       │ ───▶ │  App (dotenv loads at startup)   │ │
│  │  DB_PASS=secret  │      │  process.env.DB_PASS = "secret"  │ │
│  │  (plaintext)     │      │                                  │ │
│  └──────────────────┘      └──────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

**Security Concerns:**

- ⚠️ Secret stored in **plaintext file on disk**
- ⚠️ Anyone with SSH access can `cat .env` and see all secrets
- ⚠️ If `.env` ends up in a backup, secrets are exposed
- ⚠️ No audit trail — you don't know who read the file
- ⚠️ Rotation requires editing the file and restarting the app

#### Pattern 2: Shell Export (Startup Script / PM2 / systemd)

```
┌───────────────────────────────────────────────────────────────────────┐
│ EC2 Instance                                                          │
│  ┌────────────────────────┐      ┌──────────────────────────────────┐ │
│  │  startup.sh            │      │  App                             │ │
│  │  export DB_PASS=secret │ ───▶ │  process.env.DB_PASS = "secret"  │ │
│  │  node app.js           │      │                                  │ │
│  └────────────────────────┘      └──────────────────────────────────┘ │
│                                                                       │
│  OR: PM2 ecosystem.config.js / systemd unit file                      │
└───────────────────────────────────────────────────────────────────────┘
```

**Security Concerns:**

- ⚠️ Secret still in **plaintext** (in script, PM2 config, or systemd unit)
- ⚠️ Anyone with SSH can read the startup script or `ps aux` might show it
- ⚠️ `/proc/<pid>/environ` exposes all env vars to anyone who can read it
- ⚠️ No audit trail
- ⚠️ Rotation requires editing config and restarting

**Slight improvement over `.env`:** Secret isn't in the application directory, so less likely to be accidentally committed or deployed.

#### Pattern 3: EC2 Parameter Store / Secrets Manager (Rare but Better)

Some EC2 setups fetch secrets at startup:

```bash
# startup.sh
export DB_PASS=$(aws secretsmanager get-secret-value --secret-id prod/db --query SecretString --output text)
node app.js
```

**Better, but:**

- ⚠️ Still ends up as plaintext env var on the instance
- ⚠️ `/proc/<pid>/environ` still exposes it
- ✅ At least the secret isn't in a file on disk
- ✅ IAM controls who can fetch (but anyone on the instance can read after fetch)

---

### ECS + Secrets Manager: The Target State

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                                                                                  │
│  ┌─────────────────────┐      ┌─────────────────┐      ┌────────────────────┐   │
│  │  Secrets Manager    │      │  ECS Service    │      │  Fargate Task      │   │
│  │                     │      │                 │      │                    │   │
│  │  production/auth/db │ ───▶ │  Task Def       │ ───▶ │  Container         │   │
│  │  (encrypted by KMS) │      │  secrets block  │      │  process.env.DB_*  │   │
│  │                     │      │                 │      │                    │   │
│  └─────────────────────┘      └─────────────────┘      └────────────────────┘   │
│                                                                                  │
│  IAM: Task Execution Role                                                        │
│       - secretsmanager:GetSecretValue                                            │
│       - Resource: arn:aws:secretsmanager:...:production/auth/*                   │
│                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────┘
```

**How It Works:**

1. Secrets stored in **AWS Secrets Manager** (encrypted at rest with KMS)
2. ECS Task Definition references the secret ARN:
   ```json
   "secrets": [
     {
       "name": "DB_PASSWORD",
       "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789:secret:production/auth/db:password::"
     }
   ]
   ```
3. At container start, **ECS fetches the secret** (not your app) using the Task Execution Role
4. ECS injects the value as an environment variable
5. Your app reads `process.env.DB_PASSWORD` — it doesn't know about Secrets Manager

**Security Improvements:**

| Concern             | EC2 (.env / export)          | ECS + Secrets Manager                      |
| ------------------- | ---------------------------- | ------------------------------------------ |
| **Storage at rest** | Plaintext file on disk       | Encrypted with KMS                         |
| **Access control**  | Anyone with SSH              | IAM policies (least privilege)             |
| **Audit trail**     | None                         | CloudTrail logs every access               |
| **Rotation**        | Manual edit + restart        | Automatic rotation available               |
| **Exposure risk**   | In backups, logs, ps output  | Never written to disk                      |
| **Blast radius**    | Compromise EC2 = all secrets | Compromise task = only that task's secrets |

---

### What About `/proc/<pid>/environ`?

You might ask: "Doesn't ECS still inject secrets as env vars? Can't someone read `/proc`?"

**In Fargate:**

- There's no SSH access to the underlying host
- You can't `exec` into a container unless you explicitly enable ECS Exec
- Even with ECS Exec, IAM controls who can do it (and it's logged)
- The attack surface is dramatically smaller

**Contrast with EC2:**

- Anyone with SSH can read any process's environment
- Often multiple people/services share the same EC2 instance
- Less granular access control

---

### App Code: Identical in Both Environments

This is the key point — **your application code doesn't change:**

```javascript
// This works identically on EC2 and ECS
const dbPassword = process.env.DB_PASSWORD;

if (!dbPassword) {
  throw new Error("DB_PASSWORD environment variable is required");
}
```

What changes is **how the secret gets there**:

| Environment               | Who sets `process.env.DB_PASSWORD`? |
| ------------------------- | ----------------------------------- |
| EC2 + dotenv              | dotenv library reads `.env` file    |
| EC2 + shell export        | Bash `export` before starting app   |
| EC2 + PM2                 | PM2 ecosystem config `env` block    |
| **ECS + Secrets Manager** | **ECS injects at container start**  |

---

### Removing dotenv for Production

If your app currently uses dotenv, you have two options:

**Option A: Make dotenv Optional (Recommended)**

```javascript
// Only load .env if it exists (for local development)
require("dotenv").config({ silent: true });
// Or in newer versions:
require("dotenv").config(); // Doesn't throw if file missing

// App code works the same either way
const dbHost = process.env.DB_HOST;
```

**Option B: Remove dotenv Entirely**

```javascript
// Just read from process.env directly
const dbHost = process.env.DB_HOST;
```

For local development without dotenv, you can:

- Use `export` in your shell before running the app
- Use a `docker-compose.yml` with `environment:` block
- Use VS Code's `launch.json` with `"env"` configuration

---

### Security Best Practices Summary

1. **Never commit secrets to git** — use `.env.example` with placeholder values
2. **Never bake secrets into Docker images** — check with `docker history <image>`
3. **Use Secrets Manager** (not SSM Parameter Store) for truly sensitive values
   - SSM Parameter Store SecureString works but has lower API limits
4. **Scope IAM permissions** — each app should only access its own secrets
5. **Enable CloudTrail** — audit who accessed which secrets
6. **Consider rotation** — especially for database credentials
7. **Use VPC Endpoints** — so secrets never traverse the public internet

---

### Migration Path

| Phase          | Action                                                         | Owner         |
| -------------- | -------------------------------------------------------------- | ------------- |
| Phase 0        | Inventory all secrets (Story 5.1)                              | Dev team      |
| Phase 1        | Ensure app reads from `process.env`, not hardcoded (Story 2.1) | Dev team      |
| Phase 1        | Make dotenv optional or remove it                              | Dev team      |
| Phase 2        | Create secrets in Secrets Manager (Story 4.1)                  | Infra team    |
| Phase 3        | Reference secrets in Task Definition                           | Infra team    |
| Post-migration | Delete `.env` files from EC2 instances                         | Infra team    |
| Post-migration | Consider enabling secret rotation                              | Security team |
