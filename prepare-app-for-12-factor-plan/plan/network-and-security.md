# Phase 5: Network & Security

## Overview

Configure application to work correctly behind load balancers and implement security best practices for containerized deployments.

**Business Value:** Prevents production failures from incorrect proxy configuration and closes security gaps. Proper proxy headers ensure rate limiting, audit logs, and geo-blocking work correctly. Security hardening prevents container escape vulnerabilities and credential leaks.

**Prerequisites:** [Backing Services](backing-services.md) completed

**Next Phase:** Ready for [Containerization](../../containerizing-services-plan/README.md)

---

## Story 1: Configure Trusted Proxy Headers

**Business Value:** Restores critical security and audit functionality when moving behind load balancers. Without trusted proxy configuration, rate limiting sees all requests from same IP (ALB), blocking legitimate traffic after 100 requests total instead of 100/user. Audit logs show useless internal IPs, failing compliance audits. This 30-minute fix prevents production security gaps and ensures rate limiting, geo-blocking, and audit logging work correctly behind ALB.

- **Title:** Trust X-Forwarded-For Headers from ALB
- **Persona:** As a **security engineer**, I need the application to correctly identify client IP addresses so that rate limiting, geo-blocking, and audit logs contain accurate user information instead of the ALB's internal IP.

- **Requirements:**
  - Application must read client IP from `X-Forwarded-For` header
  - Application must only trust proxy headers from known sources (ALB)
  - HTTPS detection must use `X-Forwarded-Proto` header
  - Rate limiting must use real client IP
  - Audit logs must show real client IP

- **Implementation Details:**

  **Step 1: Understand ALB Header Behavior**

  When ALB receives request, it adds:
  - `X-Forwarded-For: <client-ip>, <alb-ip>` (client's real IP)
  - `X-Forwarded-Proto: https` (original protocol)
  - `X-Forwarded-Port: 443` (original port)

  Without configuration, application sees `request.ip = 10.x.x.x` (ALB's private IP)

  **Step 2: Configure Framework Trust Proxy**

  **Express.js (Node.js):**

  ```javascript
  const express = require("express");
  const app = express();

  // Trust first proxy (ALB)
  app.set("trust proxy", 1);
  // Or trust all proxies in VPC CIDR
  app.set("trust proxy", "10.0.0.0/8");

  // Now req.ip will contain real client IP
  app.get("/api/test", (req, res) => {
    res.json({
      ip: req.ip, // Real client IP (from X-Forwarded-For)
      protocol: req.protocol, // https (from X-Forwarded-Proto)
    });
  });
  ```

  **Laravel (PHP):**

  ```php
  // app/Http/Middleware/TrustProxies.php
  namespace App\Http\Middleware;

  use Illuminate\Http\Middleware\TrustProxies as Middleware;
  use Illuminate\Http\Request;

  class TrustProxies extends Middleware
  {
      // Trust all proxies in VPC
      protected $proxies = '*'; // Or specific CIDR: '10.0.0.0/8'

      protected $headers =
          Request::HEADER_X_FORWARDED_FOR |
          Request::HEADER_X_FORWARDED_HOST |
          Request::HEADER_X_FORWARDED_PORT |
          Request::HEADER_X_FORWARDED_PROTO;
  }
  ```

  **Django (Python):**

  ```python
  # settings.py
  USE_X_FORWARDED_HOST = True
  SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')

  # For client IP
  # Use django-ipware
  from ipware import get_client_ip

  def my_view(request):
      client_ip, is_routable = get_client_ip(request)
      # client_ip contains real IP from X-Forwarded-For
  ```

  **Nginx (if reverse proxy in container):**

  ```nginx
  server {
      listen 8080;

      real_ip_header X-Forwarded-For;
      set_real_ip_from 10.0.0.0/8;  # Trust VPC CIDR

      location / {
          proxy_pass http://app:3000;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      }
  }
  ```

  **Step 3: Update Rate Limiting**

  **Before (rate limits ALB, not users):**

  ```javascript
  const rateLimit = require("express-rate-limit");

  const limiter = rateLimit({
    windowMs: 15 * 60 * 1000,
    max: 100,
    // Without trust proxy, all requests have same IP (ALB)
  });
  ```

  **After (rate limits per real client IP):**

  ```javascript
  app.set("trust proxy", 1); // Enable trust proxy

  const limiter = rateLimit({
    windowMs: 15 * 60 * 1000,
    max: 100,
    // Now correctly limits per client IP
  });
  ```

  **Step 4: Update Audit Logging**

  ```javascript
  app.use((req, res, next) => {
    logger.info("Request received", {
      ip: req.ip, // Real client IP (not ALB IP)
      method: req.method,
      path: req.path,
      userAgent: req.get("user-agent"),
    });
    next();
  });
  ```

  **Step 5: Test Proxy Header Handling**

  ```bash
  # Test locally with proxy headers
  curl -H "X-Forwarded-For: 1.2.3.4" \
       -H "X-Forwarded-Proto: https" \
       http://localhost:3000/api/test

  # Should return:
  # {"ip": "1.2.3.4", "protocol": "https"}
  ```

  **Step 6: Prevent HTTPS Redirect Loops**

  ```javascript
  // Bad: Creates redirect loop behind ALB
  if (req.protocol !== "https") {
    return res.redirect(`https://${req.hostname}${req.url}`);
  }

  // Good: Checks X-Forwarded-Proto
  app.set("trust proxy", 1);
  if (req.protocol !== "https") {
    // This now correctly checks X-Forwarded-Proto
    return res.redirect(`https://${req.hostname}${req.url}`);
  }
  ```

- **Acceptance Criteria:**
  - ✅ `request.ip` returns actual client IP, not `10.x.x.x` (ALB IP)
  - ✅ HTTPS detection works correctly behind ALB (no redirect loops)
  - ✅ Audit logs show real client IP addresses
  - ✅ Rate limiting applies per real client, not per ALB
  - ✅ Geo-blocking works based on real client IP (if applicable)
  - ✅ Tested with X-Forwarded headers locally
  - ✅ Tested behind ALB in staging environment

- **EC2 Testing:**
  - Can be tested on EC2 behind ALB
  - Verify client IPs are correct
  - Test rate limiting behavior
  - Validate audit logs show real IPs

---

## Story 2: Implement Database Connection Pooling

**Business Value:** Prevents database connection exhaustion when scaling containers. Without proper connection pooling, scaling from 2 to 20 containers during traffic spikes can exhaust RDS connection limits, causing total outage. Proper pooling (1 hour configuration) prevents this scenario and enables safe horizontal scaling to handle traffic spikes without database failures.

- **Title:** Configure Database Connection Pooling for Horizontal Scaling
- **Persona:** As a **developer**, I need the application to manage database connections efficiently so that scaling up tasks doesn't exhaust the database connection limit and cause outages.

- **Requirements:**
  - Connection pool size must be bounded
  - Total connections across all tasks must not exceed RDS `max_connections`
  - Application must handle connection failures gracefully
  - Connections must be released properly on shutdown
  - Connection validation before use

- **Implementation Details:**

  **Step 1: Calculate Pool Size**

  ```
  Formula: pool_size = (RDS max_connections × 0.7) / expected_max_tasks

  Example:
  - RDS max_connections: 150 (default for db.t3.small)
  - Expected max tasks: 10
  - pool_size = (150 × 0.7) / 10 = 10.5 → Use max: 10
  ```

  **CRITICAL:** Auto-scaling can spike task count quickly!
  - 2 → 20 tasks in 60 seconds
  - 20 tasks × 10 connections = 200 connections
  - Exceeds RDS limit (150) → CONNECTION DENIED errors

  **Mitigation:**
  - Set conservative pool sizes (e.g., max: 5)
  - Limit max task count in auto-scaling
  - Monitor RDS connection count in CloudWatch

  **Step 2: Configure Connection Pool**

  **Node.js (Knex.js):**

  ```javascript
  const knex = require("knex")({
    client: "mysql2",
    connection: {
      host: process.env.DB_HOST,
      user: process.env.DB_USER,
      password: process.env.DB_PASSWORD,
      database: process.env.DB_NAME,
    },
    pool: {
      min: 2, // Minimum connections to keep open
      max: 10, // Maximum connections per task
      acquireTimeoutMillis: 30000, // Timeout waiting for connection
      idleTimeoutMillis: 30000, // Close idle connections
      reapIntervalMillis: 1000, // Check for idle connections every 1s
    },
  });
  ```

  **Python (SQLAlchemy):**

  ```python
  from sqlalchemy import create_engine
  import os

  engine = create_engine(
      f"mysql+pymysql://{os.environ['DB_USER']}:{os.environ['DB_PASSWORD']}@{os.environ['DB_HOST']}/{os.environ['DB_NAME']}",
      pool_size=5,          # Normal pool size
      max_overflow=10,      # Additional connections under load
      pool_pre_ping=True,   # Validate connections before use
      pool_recycle=3600     # Recycle connections every hour
  )
  ```

  **PHP (Laravel):**

  ```php
  // config/database.php
  'connections' => [
      'mysql' => [
          'driver' => 'mysql',
          'host' => env('DB_HOST'),
          'database' => env('DB_DATABASE'),
          'username' => env('DB_USERNAME'),
          'password' => env('DB_PASSWORD'),
          'options' => [
              PDO::ATTR_PERSISTENT => false,
          ],
          // Laravel doesn't have explicit pool settings
          // Use connection pooling at infrastructure level (RDS Proxy)
      ],
  ],
  ```

  **Step 3: Implement Retry Logic**

  ```javascript
  async function queryWithRetry(sql, retries = 3) {
    for (let i = 0; i < retries; i++) {
      try {
        return await knex.raw(sql);
      } catch (err) {
        // Retry on transient errors
        if (
          err.code === "ECONNREFUSED" ||
          err.code === "ETIMEDOUT" ||
          err.code === "ER_LOCK_WAIT_TIMEOUT"
        ) {
          if (i === retries - 1) throw err;
          await sleep(Math.pow(2, i) * 100); // Exponential backoff
          continue;
        }
        throw err; // Don't retry auth errors, syntax errors, etc.
      }
    }
  }
  ```

  **Step 4: Monitor Connection Usage**

  ```javascript
  // Log pool statistics
  setInterval(() => {
    const pool = knex.client.pool;
    console.log("Database pool stats:", {
      used: pool.numUsed(),
      free: pool.numFree(),
      pending: pool.numPendingAcquires(),
      max: pool.max,
    });
  }, 60000);
  ```

  **Step 5: Graceful Shutdown**

  ```javascript
  process.on("SIGTERM", async () => {
    console.log("SIGTERM received, closing database connections...");
    await knex.destroy(); // Close all connections
    process.exit(0);
  });
  ```

  **Step 6: CloudWatch Alarms**

  ```bash
  # Alert when connection count exceeds 70%
  aws cloudwatch put-metric-alarm \
    --alarm-name rds-high-connections \
    --metric-name DatabaseConnections \
    --namespace AWS/RDS \
    --statistic Average \
    --period 300 \
    --evaluation-periods 2 \
    --threshold 105 \  # 70% of 150
    --comparison-operator GreaterThanThreshold \
    --dimensions Name=DBInstanceIdentifier,Value=my-db
  ```

- **Acceptance Criteria:**
  - ✅ Connection pool configured with min/max values
  - ✅ Scaling from 1 to 10 tasks doesn't cause "too many connections" errors
  - ✅ RDS failover doesn't crash application (reconnects automatically)
  - ✅ Connections released on container shutdown
  - ✅ Database connection count visible in RDS CloudWatch metrics
  - ✅ Load test at 2× expected max scale shows stable connection count
  - ✅ Transient errors retried with exponential backoff
  - ✅ Total connections stay below 70% of RDS `max_connections`

- **EC2 Testing:**
  - Configure connection pooling on EC2
  - Verify connections are reused
  - Test failover behavior
  - Monitor connection count in RDS

---

## Story 3: Handle Dynamic Secrets Rotation

**Business Value:** Enables credential rotation without downtime or redeployment. Secrets Manager automatic rotation (30-90 days) improves security posture without operational overhead. Prevents outages from expired credentials and satisfies compliance requirements for regular credential rotation.

- **Title:** Support Secrets Rotation Without Redeployment
- **Persona:** As a **security engineer**, I need the application to handle rotating secrets so that credentials can be updated without causing downtime or requiring redeployments.

- **Requirements:**
  - Application handles credential changes gracefully
  - Database password rotation doesn't cause outages
  - API key rotation is seamless
  - Rotation events are logged

- **Implementation Details:**

  **Step 1: Use AWS Secrets Manager with Auto-Rotation**

  ```bash
  # Create secret with rotation
  aws secretsmanager create-secret \
    --name prod/db/password \
    --secret-string '{"username":"admin","password":"current_password"}' \
    --tags Key=Environment,Value=production

  # Enable automatic rotation (every 30 days)
  aws secretsmanager rotate-secret \
    --secret-id prod/db/password \
    --rotation-lambda-arn arn:aws:lambda:us-east-1:123456789012:function:SecretsManagerRDSMySQLRotationSingleUser \
    --rotation-rules AutomaticallyAfterDays=30
  ```

  **Step 2: ECS Task Definition with Secrets**

  ```json
  {
    "containerDefinitions": [
      {
        "name": "app",
        "secrets": [
          {
            "name": "DB_PASSWORD",
            "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789012:secret:prod/db/password:password::"
          }
        ]
      }
    ]
  }
  ```

  **Option A: Restart Containers on Rotation (Simplest)**

  When secret rotates, ECS can automatically restart tasks to pick up new value.

  **Option B: In-App Secret Refresh (Advanced)**

  ```javascript
  const {
    SecretsManagerClient,
    GetSecretValueCommand,
  } = require("@aws-sdk/client-secrets-manager");

  const client = new SecretsManagerClient({ region: process.env.AWS_REGION });
  let cachedSecret = null;
  let cacheExpiry = 0;

  async function getSecret() {
    if (cachedSecret && Date.now() < cacheExpiry) {
      return cachedSecret;
    }

    const response = await client.send(
      new GetSecretValueCommand({ SecretId: "prod/db/password" }),
    );
    cachedSecret = JSON.parse(response.SecretString);
    cacheExpiry = Date.now() + 5 * 60 * 1000; // Cache 5 minutes

    return cachedSecret;
  }

  // Refresh connection pool on secret rotation
  async function refreshDatabaseCredentials() {
    const secret = await getSecret();

    // Close existing connections
    await knex.destroy();

    // Recreate with new credentials
    knex = require("knex")({
      client: "mysql2",
      connection: {
        host: process.env.DB_HOST,
        user: secret.username,
        password: secret.password,
        database: process.env.DB_NAME,
      },
    });
  }

  // Refresh every 5 minutes
  setInterval(refreshDatabaseCredentials, 5 * 60 * 1000);
  ```

  **Step 3: Alternative - IAM Database Authentication (No passwords!)**

  ```javascript
  const AWS = require("aws-sdk");
  const mysql = require("mysql2/promise");

  async function createConnection() {
    const signer = new AWS.RDS.Signer({
      region: process.env.AWS_REGION,
      hostname: process.env.DB_HOST,
      port: 3306,
      username: process.env.DB_USER,
    });

    const token = await signer.getAuthToken();

    return mysql.createConnection({
      host: process.env.DB_HOST,
      user: process.env.DB_USER,
      password: token,
      database: process.env.DB_NAME,
      ssl: "Amazon RDS",
      authPlugins: { mysql_clear_password: () => () => token },
    });
  }
  ```

  **Benefits of IAM Authentication:**
  - No passwords to rotate
  - Tokens auto-expire (15 minutes)
  - Centralized access control via IAM

- **Acceptance Criteria:**
  - ✅ Secret rotation doesn't cause application errors
  - ✅ Old credentials work during grace period
  - ✅ Application picks up new credentials automatically
  - ✅ Rotation events logged in CloudTrail
  - ✅ Tested rotation in staging environment
  - ✅ Fallback plan documented if rotation fails

- **EC2 Testing:**
  - Test secret rotation on EC2
  - Verify application handles rotation gracefully
  - Validate monitoring and alerts

---

## Story 4: Standardize Timezone Handling

**Business Value:** Prevents timestamp bugs and scheduling errors when moving from local-time EC2 to UTC containers. Standardizing on UTC (1 day) prevents "batch job ran at wrong time" incidents and ensures consistent timestamps across distributed systems.

- **Title:** Handle Timezone Differences in Containers
- **Persona:** As a **developer**, I need the application to handle timezones consistently so that scheduled jobs, timestamps, and date displays work correctly when moving from a server set to local time to a UTC container.

- **Requirements:**
  - Application handles UTC container time correctly
  - Database timestamps are consistent
  - User-facing times display in correct timezone
  - Scheduled jobs run at expected times

- **Implementation Details:**

  **Best Practice: UTC Everywhere**
  1. **Containers:** Always UTC (default)
  2. **Database:** Store timestamps in UTC
  3. **Application:** Convert to user timezone only at display layer
  4. **Scheduled Jobs:** Use UTC, document local time equivalents

  **Configuration:**

  ```javascript
  // Server always uses UTC (no TZ env var needed in container)

  // Store in UTC
  await db.insert({
    created_at: new Date(), // JavaScript Date is UTC internally
  });

  // Display in user timezone
  app.get("/api/orders/:id", async (req, res) => {
    const order = await db.getOrder(req.params.id);

    res.json({
      id: order.id,
      created_at: order.created_at.toISOString(), // 2024-01-15T14:23:45.123Z
      created_at_local: formatInTimezone(order.created_at, req.user.timezone), // 2024-01-15 09:23:45 EST
    });
  });
  ```

  **Alternative: Set Container Timezone (Not Recommended)**

  ```dockerfile
  # Dockerfile
  ENV TZ=America/New_York
  RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone
  ```

  **Why UTC is better:**
  - Consistent across all environments
  - No daylight saving time bugs
  - Easier distributed system debugging

- **Acceptance Criteria:**
  - ✅ Database timestamps consistent before/after migration
  - ✅ User-facing times display correctly in their timezone
  - ✅ Scheduled jobs run at expected wall-clock time
  - ✅ Logs use ISO 8601 with timezone (2024-01-15T14:23:45.123Z)

---

## Story 5: Run as Non-Root User

**Business Value:** Limits blast radius of container escape vulnerabilities. Running as non-root (30 minutes) prevents escalated privileges if container is compromised. Required for many compliance frameworks and enterprise security policies.

- **Title:** Implement Non-Root Container Execution
- **Persona:** As a **security engineer**, I need containers to run as a non-root user so that a container escape vulnerability has limited blast radius.

- **Requirements:**
  - Container process must not run as UID 0 (root)
  - Application files must have appropriate permissions
  - No privilege escalation in container
  - Application works correctly as non-root

- **Implementation Details:**

  ```dockerfile
  FROM node:20-slim

  # Create non-root user
  RUN groupadd -g 1001 appgroup && \
      useradd -u 1001 -g appgroup -m -s /bin/bash appuser

  WORKDIR /app

  # Install dependencies as root
  COPY package*.json ./
  RUN npm ci --production

  # Copy application code
  COPY . .

  # Change ownership to app user
  RUN chown -R appuser:appgroup /app

  # Switch to non-root user
  USER appuser

  EXPOSE 3000
  CMD ["node", "server.js"]
  ```

  **Verify:**

  ```bash
  docker run my-app whoami
  # Should output: appuser (not root)

  docker run my-app id
  # Should output: uid=1001(appuser) gid=1001(appgroup)
  ```

- **Acceptance Criteria:**
  - ✅ Container runs as non-root user (UID 1001)
  - ✅ Application starts successfully
  - ✅ No permission denied errors
  - ✅ Doesn't require `--privileged` flag

---

## Phase Completion Checklist

Before proceeding to [Containerization Plan](../../containerizing-services-plan/README.md):

- [ ] Trust proxy configured for ALB headers
- [ ] Rate limiting uses real client IPs
- [ ] Audit logs show real client IPs
- [ ] Database connection pooling configured
- [ ] Connection count monitored in CloudWatch
- [ ] Secrets rotation strategy implemented
- [ ] Timezone handling standardized (UTC preferred)
- [ ] Non-root user configured in Dockerfile
- [ ] All changes tested on EC2 first

**You are now ready to containerize your application!**

Proceed to the [Containerizing Services Plan](../../containerizing-services-plan/README.md) to package your application in Docker with proper process management, graceful shutdown, and container best practices.

---

## Rollback Plan

If issues are discovered:

1. **Proxy header issues:** Temporarily disable trust proxy, verify ALB configuration
2. **Connection pool exhaustion:** Reduce pool size, limit max task count
3. **Secrets rotation failures:** Disable auto-rotation, manually update secrets
4. **Timezone bugs:** Add TZ environment variable to match EC2 timezone temporarily
5. **Permission errors:** Run as root temporarily (USER root), fix permissions, switch back
