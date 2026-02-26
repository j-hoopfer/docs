# Phase 3: Observability

**Goal:** Configure application logs to write to STDOUT/STDERR for centralized aggregation, instead of local log files.

## Context & Themes

Moving to ephemeral containers requires robust observability—you can't SSH into containers to check logs. This phase ensures you have visibility into application behavior through centralized logging and health checks.

**Business Value:** Improves incident detection time from 15-30 minutes (manual log checking) to real-time (automated alerts), reducing customer impact. CloudWatch Logs provides instant search across all containers and enables automated alerting on error patterns.

**Prerequisites:**

- [ ] [Stateless Application](2-stateless-application.md) completed

---

## Feature 3: Observability & Telemetry

**Business Value:** Improves incident detection time from 15-30 minutes to real-time, reducing customer impact.

### Story 3.1: Implement Console-Based Logging

- **Title:** Migrate Logs from Files to STDOUT/STDERR
- **Persona:** As an **operations engineer**, I need application logs written to STDOUT/STDERR so that Fargate's `awslogs` driver captures them and sends them to CloudWatch, giving me visibility without SSH access.

**Business Value:** Maintains troubleshooting capability in containerized environment while improving log accessibility. CloudWatch Logs provides instant search across all containers (vs. SSH to each server) and enables automated alerting on error patterns. This improves incident detection time from 15-30 minutes (manual log checking) to real-time (automated alerts), reducing customer impact of production issues.

- **Requirements:**
  - All application logs must go to console (STDOUT for info, STDERR for errors)
  - No logs written to local files (e.g., `/var/log/app.log`)
  - Logs must be structured (JSON preferred) for easier querying
  - **Change must work on both EC2 and ECS during migration period**

- **Implementation Details:**

  **Why stdout logging works in BOTH environments (backward-compatible):**

  The key insight: stdout logging works on EC2 too. The difference is what _captures_ it.

  | Environment   | App logs to... | Captured by... | Ends up in...         |
  | ------------- | -------------- | -------------- | --------------------- |
  | EC2 (systemd) | stdout         | journald       | `journalctl -u myapp` |
  | ECS/Fargate   | stdout         | Docker/awslogs | CloudWatch Logs       |

  **Your EC2 process manager already captures stdout.** You're just telling the app to write there instead of to a file.

  **Step 1: Update Logging Configuration**

  **Node.js (Winston):**

  ```javascript
  const winston = require("winston");

  // Before (file-based)
  const logger = winston.createLogger({
    transports: [new winston.transports.File({ filename: "/var/log/app.log" })],
  });

  // After (stdout - works on EC2 and ECS)
  const logger = winston.createLogger({
    format: winston.format.combine(
      winston.format.timestamp(),
      winston.format.json(), // JSON format for CloudWatch Logs Insights
    ),
    transports: [new winston.transports.Console()],
  });

  // Usage
  logger.info("User logged in", { userId: 123, ip: "1.2.3.4" });
  logger.error("Database connection failed", { error: err.message });
  ```

  **Step 2: Include Structured Metadata**

  **Good JSON log structure:**

  ```json
  {
    "timestamp": "2024-01-15T14:23:45.123Z",
    "level": "error",
    "message": "Failed to process payment",
    "requestId": "abc-123-def",
    "userId": 456,
    "error": {
      "type": "StripeError",
      "message": "Card declined",
      "code": "card_declined"
    },
    "context": {
      "amount": 9999,
      "currency": "USD"
    }
  }
  ```

  **Include:**
  - Timestamp (ISO 8601 format)
  - Log level (info, warn, error, debug)
  - Request ID (for tracing requests across services)
  - User ID (for debugging user-specific issues)
  - Error details (type, message, stack trace)
  - Business context (order ID, payment amount, etc.)

  **Step 3: Update Log Consumers**

  **If you have log shippers (Filebeat, Fluentd, CloudWatch Agent):**

  **Option A: Update shipper to read from journald/process manager**

  ```yaml
  # Filebeat: Switch from file input to journald
  filebeat.inputs:
    - type: journald
      id: my-app-logs
      include_matches:
        - _SYSTEMD_UNIT=myapp.service
  ```

  **Option B: Keep file output on EC2 (during transition)**

  ```ini
  # systemd unit file
  [Service]
  StandardOutput=append:/var/log/myapp.log
  StandardError=append:/var/log/myapp-error.log
  ```

  **Step 4: Test Locally**

  ```bash
  # Run container and see logs
  docker run my-app

  # Should see JSON logs in terminal:
  # {"timestamp":"2024-01-15T14:23:45.123Z","level":"info","message":"Server started on port 3000"}

  # Test log filtering
  docker logs my-app 2>&1 | jq 'select(.level == "error")'
  ```

  **Step 5: Remove Old Log Files**

  ```bash
  # Remove logrotate configs
  rm /etc/logrotate.d/myapp

  # Remove log file references from Dockerfile
  # Before:
  # RUN mkdir -p /var/log/app

  ```

- **Acceptance Criteria:**
  - ✅ App logs to stdout (verify: `docker run my-app` prints to terminal)
  - ✅ No log files created inside container
  - ✅ **EC2 still works:** Logs visible via `journalctl -u myapp -f` or process manager
  - ✅ **Log consumers updated:** Shippers, dashboards, and alerts still receive logs
  - ✅ Logs are JSON-formatted for easier CloudWatch Logs Insights queries
  - ✅ Logs include request ID, user ID, and relevant business context
  - ✅ Error logs include stack traces
  - ✅ Log level can be changed via environment variable

- **EC2 Testing:**
  - Deploy stdout logging code to EC2
  - Verify logs appear in journald or process manager
  - Update any log shippers to read from new location
  - Test log searching and filtering
  - Verify dashboards and alerts still work

---

## Story 2: Implement Health Check Endpoints

- **Title:** Create Liveness and Readiness Health Checks
- **Persona:** As an **operations engineer**, I need the application to respond to health checks quickly so that the ALB routes traffic only to healthy tasks and ECS doesn't kill healthy containers due to slow responses.

**Business Value:** Enables automatic detection and replacement of unhealthy containers, reducing manual intervention and improving availability. ALB health checks automatically route traffic away from failing containers and trigger replacements, reducing MTTR from 15-60 minutes (manual detection and restart) to under 2 minutes (automated). Well-designed health checks prevent cascading failures where unhealthy containers continue receiving traffic, causing customer errors. Critical for 99.9% uptime SLA.

- **Requirements:**
  - Dedicated health check endpoint (e.g., `/health` or `/healthz`)
  - Health check must respond within ALB timeout (default 5 seconds)
  - Liveness check should be lightweight (basic process health)
  - Readiness check should verify dependencies are available
  - Health checks must not require authentication

- **Implementation Details:**

  **Understand Two Types of Health Checks:**

  | Type          | Endpoint        | Purpose                 | Checks                  | Used By              |
  | ------------- | --------------- | ----------------------- | ----------------------- | -------------------- |
  | **Liveness**  | `/health`       | Is process alive?       | Process running?        | ALB Target Group     |
  | **Readiness** | `/health/ready` | Can app handle traffic? | Dependencies reachable? | ECS Container Health |

  **Step 1: Implement Liveness Check (Lightweight)**

  ```javascript
  // Node.js/Express
  app.get("/health", (req, res) => {
    res.status(200).json({ status: "ok", timestamp: new Date().toISOString() });
  });
  ```

  **Requirements:**
  - Must respond in < 100ms
  - No database/Redis calls
  - No external API calls
  - Just verifies process is running

  **Step 2: Implement Readiness Check (Deep)**

  ```javascript
  const mysql = require("mysql2/promise");
  const Redis = require("ioredis");

  app.get("/health/ready", async (req, res) => {
    const checks = {
      database: false,
      redis: false,
    };

    // Check database
    try {
      const connection = await mysql.createConnection({
        host: process.env.DB_HOST,
        user: process.env.DB_USER,
        password: process.env.DB_PASSWORD,
        database: process.env.DB_NAME,
        connectTimeout: 3000,
      });
      await connection.ping();
      await connection.end();
      checks.database = true;
    } catch (err) {
      console.error("Database health check failed:", err.message);
    }

    // Check Redis
    try {
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

    // Overall status
    const healthy = Object.values(checks).every((status) => status === true);

    if (healthy) {
      res.status(200).json({ status: "ready", checks });
    } else {
      res.status(503).json({ status: "not ready", checks });
    }
  });
  ```

  **Step 3: Connection Pooling Strategy**

  If you use connection pools, test pool health instead of creating new connections:

  ```javascript
  // Use existing pool
  try {
    await dbPool.query("SELECT 1");
    checks.database = true;
  } catch (err) {
    console.error("Database health check failed:", err.message);
  }
  ```

  **Step 4: Caching Health Checks (High Traffic)**

  For high-traffic apps, cache health check results:

  ```javascript
  let cachedStatus = { healthy: false, timestamp: 0 };
  const CACHE_TTL = 5000; // 5 seconds

  app.get("/health/ready", async (req, res) => {
    if (Date.now() - cachedStatus.timestamp < CACHE_TTL) {
      return res
        .status(cachedStatus.healthy ? 200 : 503)
        .json(cachedStatus.result);
    }

    // Run checks and update cache
    const checks = await runHealthChecks();
    cachedStatus = {
      healthy: checks.allHealthy,
      result: checks,
      timestamp: Date.now(),
    };

    res.status(cachedStatus.healthy ? 200 : 503).json(cachedStatus.result);
  });
  ```

  **Step 5: Avoid the "Health Check Suicide Pact"**

  **The Problem:**
  - If ALL tasks check database/Redis in health check
  - And the database has a brief outage (10 seconds)
  - ALL tasks fail health check simultaneously
  - ECS kills the entire fleet
  - Even when database recovers, you have zero running tasks

  **The Solution:**
  - **ALB health check** → `/health` (liveness only, doesn't check DB)
  - **ECS health check** → `/health/ready` (checks DB, but high retry count)

  The actual `healthCheck` block in the ECS task definition — including `retries` and `startPeriod` — is configured in [Phase 4: Deployment Artifacts](../../../../phase-4-initial-deployment/1-deployment-artifacts.md).

- **Acceptance Criteria:**
  - ✅ `/health` returns 200 OK within 100ms
  - ✅ `/health/ready` returns 200 when all dependencies are available
  - ✅ `/health/ready` returns 503 when database is down
  - ✅ **ALB health check uses `/health` (liveness), not `/health/ready`**
  - ✅ Response includes individual check status in JSON
  - ✅ Failed dependency checks log error messages
  - ✅ **Tested: Database outage for 30 seconds does NOT kill all tasks**
  - ✅ Health checks don't require authentication
  - ✅ Health check response time monitored in CloudWatch

- **EC2 Testing:**
  - Deploy health check endpoints to EC2
  - Test `/health` returns quickly
  - Test `/health/ready` with database/Redis running
  - Test `/health/ready` with database stopped (should return 503)
  - Verify health checks don't impact application performance

## Phase Completion Checklist

Before proceeding to [Backing Services](4-backing-services.md) phase:

- [ ] Application logs to STDOUT/STDERR (no file logging)
- [ ] Logs are JSON-formatted with structured metadata
- [ ] Log consumers updated to read from new location (EC2)
- [ ] `/health` endpoint responds quickly (< 100ms)
- [ ] `/health/ready` endpoint verifies dependencies
- [ ] Health checks tested with dependency failures
- [ ] ALB health check configuration planned (liveness only)
- [ ] ECS health check configuration planned (readiness with high retries)
- [ ] Application tested on EC2 with new logging and health checks

---

## Rollback Plan

If issues are discovered after deployment:

1. **CloudWatch Logs not appearing:** Check awslogs driver configuration and IAM permissions
2. **Health checks failing:** Increase timeout, reduce dependency check depth, verify `/health` vs `/health/ready` usage
3. **Log volume too high:** Adjust log level via environment variable, implement sampling
4. **Missing logs from EC2:** Verify journald/process manager capturing stdout
