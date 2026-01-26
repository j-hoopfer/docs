# Business Epic B: User Authentication (The MVP - Auth Service)

**Goal:** Real users can securely register, login, and authenticate. Security is hardened with WAF and SSL.

**Duration:** Days 11–20

**Business Value:** Delivers the first revenue-enabling feature. Users can create accounts and access protected resources.

**Prerequisites:** Enabler Epic A complete (Walking Skeleton deployed).

**SAFe Principle:** "Integrate infrastructure work with business features. Database provisioning is driven by Auth requirements, not standalone phases."

---

## Story 2.1: Database Infrastructure for Auth

**From:** Original Epic 2, Story 2.2 (RDS Provisioning)

As a Backend Engineer
I want a managed MySQL database to store user credentials
So that the Auth service can persist user data reliably

### Technical Requirements

- RDS MySQL 8.0 in Multi-AZ configuration
- Provisioned in private DB subnets (no internet access)
- Security group: Allow port 3306 **ONLY** from `sg_app`
- Secrets Manager for database credentials (auto-rotation enabled)
- Automated backups enabled (7-day retention)
- Encryption at rest enabled
- Initial database: `auth_db`

### Implementation Details

Create `terraform/modules/database/rds.tf`:

```hcl
variable "project" { type = string }
variable "environment" { type = string }
variable "vpc_id" { type = string }
variable "private_db_subnet_ids" { type = list(string) }
variable "sg_db_id" { type = string }
variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}

# Random credentials
resource "random_password" "db_master_password" {
  length  = 32
  special = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_password" "db_master_username" {
  length  = 16
  special = false
}

# DB Subnet Group
resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-${var.environment}-db-subnet-group"
  subnet_ids = var.private_db_subnet_ids

  tags = {
    Name        = "${var.project}-${var.environment}-db-subnet-group"
    Environment = var.environment
  }
}

# RDS Instance
resource "aws_db_instance" "main" {
  identifier     = "${var.project}-${var.environment}-mysql"
  engine         = "mysql"
  engine_version = "8.0.35"
  instance_class = var.instance_class

  allocated_storage     = 20
  max_allocated_storage = 100  # Auto-scaling storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "auth_db"
  username = random_password.db_master_username.result
  password = random_password.db_master_password.result

  multi_az               = true
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.sg_db_id]

  backup_retention_period = 7
  backup_window          = "03:00-04:00"
  maintenance_window     = "mon:04:00-mon:05:00"

  skip_final_snapshot       = var.environment != "prod"
  final_snapshot_identifier = var.environment == "prod" ? "${var.project}-${var.environment}-final-snapshot" : null
  deletion_protection       = var.environment == "prod"

  performance_insights_enabled = true
  monitoring_interval          = 60
  monitoring_role_arn          = aws_iam_role.rds_monitoring.arn

  enabled_cloudwatch_logs_exports = ["error", "general", "slowquery"]

  tags = {
    Name        = "${var.project}-${var.environment}-mysql"
    Environment = var.environment
  }
}

# Enhanced Monitoring IAM Role
resource "aws_iam_role" "rds_monitoring" {
  name = "${var.project}-${var.environment}-rds-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "monitoring.rds.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# Secrets Manager for DB Credentials
resource "aws_secretsmanager_secret" "db_credentials" {
  name = "${var.project}/${var.environment}/db-credentials"

  tags = {
    Environment = var.environment
  }
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = random_password.db_master_username.result
    password = random_password.db_master_password.result
    host     = aws_db_instance.main.address
    port     = aws_db_instance.main.port
    database = aws_db_instance.main.db_name
  })
}

# Outputs
output "db_endpoint" { value = aws_db_instance.main.address }
output "db_port" { value = aws_db_instance.main.port }
output "db_name" { value = aws_db_instance.main.db_name }
output "db_secret_arn" { value = aws_secretsmanager_secret.db_credentials.arn }
```

### Acceptance Criteria

- [ ] RDS instance running in Multi-AZ mode
- [ ] Database credentials stored in Secrets Manager
- [ ] Security group allows access only from app security group
- [ ] Automated backups configured
- [ ] CloudWatch Logs enabled for error/slow query logging
- [ ] Connection test successful from ECS task

### Estimated Duration: 1 day

---

## Story 2.2: Users Table & Migration Script

**From:** Original Epic 4, Story 4.2 (Database Migrations)

As a Database Engineer
I want a versioned schema migration system
So that database changes are tracked and reversible

### Technical Requirements

- `users` table schema with: id (UUID), email (unique), password_hash, created_at, updated_at
- Migration tool: node-pg-migrate or Knex.js or Prisma
- Migrations stored in version control (`migrations/` folder)
- ECS task to run migrations on deployment
- IAM permissions for migration task to access RDS

### Implementation Details

**1. Users Table Schema (SQL)**

```sql
-- migrations/001_create_users_table.sql
CREATE TABLE users (
  id CHAR(36) PRIMARY KEY,
  email VARCHAR(255) NOT NULL UNIQUE,
  password_hash VARCHAR(255) NOT NULL,
  first_name VARCHAR(100),
  last_name VARCHAR(100),
  is_active BOOLEAN DEFAULT TRUE,
  email_verified BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  INDEX idx_email (email),
  INDEX idx_created_at (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

**2. Migration Runner (TypeScript)**

```typescript
// apps/auth-api/src/migrations/runner.ts
import mysql from "mysql2/promise";
import fs from "fs/promises";
import path from "path";

const DB_CONFIG = {
  host: process.env.DB_HOST,
  port: Number(process.env.DB_PORT || 3306),
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME,
  multipleStatements: true,
};

async function runMigrations() {
  const connection = await mysql.createConnection(DB_CONFIG);

  try {
    // Create migrations table if not exists
    await connection.execute(`
      CREATE TABLE IF NOT EXISTS schema_migrations (
        id INT AUTO_INCREMENT PRIMARY KEY,
        migration_name VARCHAR(255) NOT NULL UNIQUE,
        executed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    `);

    // Get executed migrations
    const [executed] = await connection.execute("SELECT migration_name FROM schema_migrations");
    const executedSet = new Set(executed.map((r: any) => r.migration_name));

    // Read migration files
    const migrationsDir = path.join(__dirname, "../../../migrations");
    const files = (await fs.readdir(migrationsDir)).filter((f) => f.endsWith(".sql")).sort();

    // Execute pending migrations
    for (const file of files) {
      if (!executedSet.has(file)) {
        console.log(`Running migration: ${file}`);
        const sql = await fs.readFile(path.join(migrationsDir, file), "utf-8");
        await connection.query(sql);
        await connection.execute("INSERT INTO schema_migrations (migration_name) VALUES (?)", [
          file,
        ]);
        console.log(`✓ Completed: ${file}`);
      }
    }

    console.log("All migrations completed successfully");
  } finally {
    await connection.end();
  }
}

runMigrations().catch(console.error);
```

**3. ECS Task for Migrations**

Create `terraform/modules/compute/ecs-migration-task.tf`:

```hcl
resource "aws_ecs_task_definition" "migrations" {
  family                   = "${var.project}-${var.environment}-migrations"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "migrations"
    image     = "${var.ecr_repository_url}:latest"
    essential = true

    command = ["npm", "run", "migrate"]

    environment = [
      { name = "NODE_ENV", value = var.environment }
    ]

    secrets = [
      {
        name      = "DB_HOST"
        valueFrom = "${var.db_secret_arn}:host::"
      },
      {
        name      = "DB_PORT"
        valueFrom = "${var.db_secret_arn}:port::"
      },
      {
        name      = "DB_USER"
        valueFrom = "${var.db_secret_arn}:username::"
      },
      {
        name      = "DB_PASSWORD"
        valueFrom = "${var.db_secret_arn}:password::"
      },
      {
        name      = "DB_NAME"
        valueFrom = "${var.db_secret_arn}:database::"
      }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.migrations.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "migrations"
      }
    }
  }])
}

resource "aws_cloudwatch_log_group" "migrations" {
  name              = "/ecs/${var.project}-${var.environment}/migrations"
  retention_in_days = 14
}
```

**4. GitHub Actions Migration Step**

Add to `.github/workflows/deploy.yml`:

```yaml
- name: Run database migrations
  run: |
    TASK_ARN=$(aws ecs run-task \
      --cluster ${{ secrets.ECS_CLUSTER }} \
      --task-definition ${{ secrets.MIGRATION_TASK_DEF }} \
      --launch-type FARGATE \
      --network-configuration "awsvpcConfiguration={subnets=[${{ secrets.PRIVATE_SUBNETS }}],securityGroups=[${{ secrets.APP_SG }}],assignPublicIp=DISABLED}" \
      --query 'tasks[0].taskArn' \
      --output text)

    echo "Migration task started: $TASK_ARN"

    # Wait for task to complete
    aws ecs wait tasks-stopped \
      --cluster ${{ secrets.ECS_CLUSTER }} \
      --tasks $TASK_ARN

    # Check exit code
    EXIT_CODE=$(aws ecs describe-tasks \
      --cluster ${{ secrets.ECS_CLUSTER }} \
      --tasks $TASK_ARN \
      --query 'tasks[0].containers[0].exitCode' \
      --output text)

    if [ "$EXIT_CODE" != "0" ]; then
      echo "Migration failed with exit code: $EXIT_CODE"
      exit 1
    fi

    echo "✅ Migrations completed successfully"
```

### Acceptance Criteria

- [ ] Migration script creates `users` table successfully
- [ ] `schema_migrations` table tracks executed migrations
- [ ] ECS task runs migrations before deployment
- [ ] Idempotent: Running migrations multiple times is safe
- [ ] Migration logs visible in CloudWatch

### Estimated Duration: 1 day

---

## Story 2.3: Implement Auth API Endpoints

**New:** Core business feature

As a User
I want to register an account and login
So that I can access protected features of the application

### Technical Requirements

- POST `/auth/register`: Create new user account
- POST `/auth/login`: Authenticate and return JWT token
- GET `/auth/me`: Get current user profile (requires valid JWT)
- Password hashing: bcrypt (work factor: 12)
- JWT signing: RS256 with key rotation support
- Input validation: email format, password strength (min 8 chars)
- Rate limiting: 5 login attempts per minute per IP

### Implementation Details

**1. Auth Controller**

```typescript
// apps/auth-api/src/auth-controller.ts
import { Router, Request, Response } from "express";
import bcrypt from "bcrypt";
import jwt from "jsonwebtoken";
import { v4 as uuidv4 } from "uuid";
import { query } from "./database";

const router = Router();
const SALT_ROUNDS = 12;
const JWT_SECRET = process.env.JWT_SECRET!; // From Secrets Manager
const JWT_EXPIRES_IN = "24h";

// Register endpoint
router.post("/register", async (req: Request, res: Response) => {
  try {
    const { email, password, firstName, lastName } = req.body;

    // Validation
    if (!email || !password) {
      return res.status(400).json({ error: "Email and password required" });
    }

    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(email)) {
      return res.status(400).json({ error: "Invalid email format" });
    }

    if (password.length < 8) {
      return res.status(400).json({ error: "Password must be at least 8 characters" });
    }

    // Check if user exists
    const existing = await query("SELECT id FROM users WHERE email = ?", [email.toLowerCase()]);

    if (existing.length > 0) {
      return res.status(409).json({ error: "Email already registered" });
    }

    // Hash password
    const passwordHash = await bcrypt.hash(password, SALT_ROUNDS);

    // Create user
    const userId = uuidv4();
    await query(
      `INSERT INTO users (id, email, password_hash, first_name, last_name) 
       VALUES (?, ?, ?, ?, ?)`,
      [userId, email.toLowerCase(), passwordHash, firstName, lastName],
    );

    // Generate token
    const token = jwt.sign({ userId, email: email.toLowerCase() }, JWT_SECRET, {
      expiresIn: JWT_EXPIRES_IN,
      algorithm: "HS256",
    });

    res.status(201).json({
      message: "User created successfully",
      token,
      user: { id: userId, email: email.toLowerCase(), firstName, lastName },
    });
  } catch (error) {
    console.error("Register error:", error);
    res.status(500).json({ error: "Internal server error" });
  }
});

// Login endpoint
router.post("/login", async (req: Request, res: Response) => {
  try {
    const { email, password } = req.body;

    if (!email || !password) {
      return res.status(400).json({ error: "Email and password required" });
    }

    // Find user
    const users = await query(
      "SELECT id, email, password_hash, first_name, last_name FROM users WHERE email = ? AND is_active = TRUE",
      [email.toLowerCase()],
    );

    if (users.length === 0) {
      return res.status(401).json({ error: "Invalid credentials" });
    }

    const user = users[0];

    // Verify password
    const isValid = await bcrypt.compare(password, user.password_hash);
    if (!isValid) {
      return res.status(401).json({ error: "Invalid credentials" });
    }

    // Generate token
    const token = jwt.sign({ userId: user.id, email: user.email }, JWT_SECRET, {
      expiresIn: JWT_EXPIRES_IN,
      algorithm: "HS256",
    });

    res.status(200).json({
      token,
      user: {
        id: user.id,
        email: user.email,
        firstName: user.first_name,
        lastName: user.last_name,
      },
    });
  } catch (error) {
    console.error("Login error:", error);
    res.status(500).json({ error: "Internal server error" });
  }
});

// Get current user
router.get("/me", authenticateToken, async (req: Request, res: Response) => {
  try {
    const userId = (req as any).user.userId;

    const users = await query(
      "SELECT id, email, first_name, last_name, created_at FROM users WHERE id = ?",
      [userId],
    );

    if (users.length === 0) {
      return res.status(404).json({ error: "User not found" });
    }

    res.status(200).json({ user: users[0] });
  } catch (error) {
    console.error("Get user error:", error);
    res.status(500).json({ error: "Internal server error" });
  }
});

// Authentication middleware
function authenticateToken(req: Request, res: Response, next: Function) {
  const authHeader = req.headers["authorization"];
  const token = authHeader && authHeader.split(" ")[1];

  if (!token) {
    return res.status(401).json({ error: "Access token required" });
  }

  jwt.verify(token, JWT_SECRET, (err: any, user: any) => {
    if (err) {
      return res.status(403).json({ error: "Invalid or expired token" });
    }
    (req as any).user = user;
    next();
  });
}

export { router as authRouter, authenticateToken };
```

**2. Database Connection Pool**

Create `apps/auth-api/src/database.ts`:

```typescript
import mysql from "mysql2/promise";
import { SecretsManagerClient, GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";

interface DBCredentials {
  host: string;
  port: number;
  username: string;
  password: string;
  database: string;
}

let pool: mysql.Pool | null = null;

async function getDBCredentials(): Promise<DBCredentials> {
  // In local development, use environment variables
  if (process.env.NODE_ENV === "development") {
    return {
      host: process.env.DB_HOST!,
      port: Number(process.env.DB_PORT || 3306),
      username: process.env.DB_USER!,
      password: process.env.DB_PASSWORD!,
      database: process.env.DB_NAME!,
    };
  }

  // In production, fetch from Secrets Manager
  const client = new SecretsManagerClient({});
  const command = new GetSecretValueCommand({
    SecretId: process.env.DB_SECRET_ARN!,
  });

  const response = await client.send(command);
  return JSON.parse(response.SecretString!);
}

export async function initializePool(): Promise<mysql.Pool> {
  if (pool) return pool;

  const credentials = await getDBCredentials();

  pool = mysql.createPool({
    host: credentials.host,
    port: credentials.port,
    user: credentials.username,
    password: credentials.password,
    database: credentials.database,
    waitForConnections: true,
    connectionLimit: 10,
    maxIdle: 5,
    idleTimeout: 60000,
    queueLimit: 0,
    enableKeepAlive: true,
    keepAliveInitialDelay: 0,
  });

  // Test connection
  const connection = await pool.getConnection();
  console.log("Database connection established");
  connection.release();

  return pool;
}

export async function query<T = any>(sql: string, params?: any[]): Promise<T[]> {
  if (!pool) {
    pool = await initializePool();
  }
  const [rows] = await pool.execute(sql, params);
  return rows as T[];
}

export async function closePool(): Promise<void> {
  if (pool) {
    await pool.end();
    pool = null;
  }
}

// Graceful shutdown
process.on("SIGTERM", async () => {
  console.log("SIGTERM received, closing database pool");
  await closePool();
});
```

### Acceptance Criteria

- [ ] POST `/auth/register` creates new user and returns JWT
- [ ] POST `/auth/login` validates credentials and returns JWT
- [ ] GET `/auth/me` returns user profile with valid JWT
- [ ] Invalid credentials return 401 Unauthorized
- [ ] Duplicate email registration returns 409 Conflict
- [ ] Passwords are hashed with bcrypt
- [ ] JWT tokens expire after 24 hours
- [ ] Input validation prevents malformed requests

### Estimated Duration: 2–3 days

---

## Story 2.4: Security Hardening - WAF & SSL

**From:** Original Epic 2 Story 2.5 (ACM) + Epic 8 Story 8.3 (WAF)

As a Security Engineer
I want to protect the Auth API with WAF and enforce HTTPS
So that we block common attacks and encrypt traffic

### Technical Requirements

- WAF v2 with managed rule sets (OWASP Top 10, Known Bad Inputs)
- Rate limiting: 2000 requests per 5 minutes per IP
- AWS Shield Standard (enabled by default)
- ACM certificate with auto-renewal
- Security headers: HSTS, X-Content-Type-Options, X-Frame-Options
- Geo-blocking (optional): Block traffic from high-risk countries

### Implementation Details

**1. WAF Configuration**

Create `terraform/modules/security/waf.tf`:

```hcl
resource "aws_wafv2_web_acl" "main" {
  name  = "${var.project}-${var.environment}-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  # Rate limiting for auth endpoints
  rule {
    name     = "RateLimitAuth"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"

        scope_down_statement {
          byte_match_statement {
            search_string = "/auth/"
            positional_constraint = "CONTAINS"

            field_to_match {
              uri_path {}
            }

            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitAuth"
      sampled_requests_enabled   = true
    }
  }

  # OWASP Top 10
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project}-${var.environment}-waf"
    sampled_requests_enabled   = true
  }
}

# Associate WAF with ALB
resource "aws_wafv2_web_acl_association" "main" {
  resource_arn = var.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.main.arn
}
```

**2. Security Headers Middleware**

```typescript
// apps/auth-api/src/middleware/security-headers.ts
import { Request, Response, NextFunction } from "express";

export function securityHeaders(req: Request, res: Response, next: NextFunction) {
  res.setHeader("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("X-Frame-Options", "DENY");
  res.setHeader("X-XSS-Protection", "1; mode=block");
  res.setHeader("Referrer-Policy", "strict-origin-when-cross-origin");
  next();
}
```

### Acceptance Criteria

- [ ] WAF associated with ALB
- [ ] OWASP Top 10 rules active
- [ ] Rate limiting blocks excessive requests (test with load tool)
- [ ] SQL injection attempts blocked by WAF
- [ ] HTTPS enforced (HTTP redirects to HTTPS)
- [ ] Security headers present in all responses
- [ ] WAF metrics visible in CloudWatch

### Estimated Duration: 1–2 days

---

## Story 2.5: Structured Logging for Auth Service

**From:** Original Epic 5, Story 5.1 (Structured Logging)

As a DevOps Engineer
I want JSON-formatted logs for the Auth service
So that I can query login failures and security events in CloudWatch Insights

### Technical Requirements

- Single-line JSON format with standard fields
- Required fields: level, timestamp, trace_id, service, user_id (when available)
- PII redaction: mask email addresses, never log passwords
- Log levels: ERROR for auth failures, INFO for successful logins, DEBUG for development
- CloudWatch Logs integration
- CloudWatch Insights queries for common patterns

### Implementation Details

**1. Logger Implementation**

Create `packages/core-utils/src/logging/structured-logger.ts`:

```typescript
import pino from "pino";
import { randomUUID } from "crypto";

const LOG_LEVEL = process.env.LOG_LEVEL || "info";
const SERVICE_NAME = process.env.SERVICE_NAME || "unknown";

export const logger = pino({
  level: LOG_LEVEL,
  formatters: {
    level: (label) => ({ level: label }),
  },
  base: {
    service: SERVICE_NAME,
    environment: process.env.NODE_ENV || "development",
  },
  timestamp: pino.stdTimeFunctions.isoTime,
  redact: {
    paths: ["password", "passwordHash", "password_hash", "token", "authorization"],
    censor: "[REDACTED]",
  },
});

export function createRequestLogger(traceId?: string) {
  return logger.child({
    traceId: traceId || randomUUID(),
  });
}

export function maskEmail(email: string): string {
  if (!email || !email.includes("@")) return "***";
  const [local, domain] = email.split("@");
  const maskedLocal = local.length > 2 ? `${local.substring(0, 2)}***` : "***";
  return `${maskedLocal}@${domain}`;
}

export function maskIP(ip: string): string {
  if (!ip) return "***";
  const parts = ip.split(".");
  if (parts.length === 4) {
    return `${parts[0]}.${parts[1]}.***.***`;
  }
  return ip.substring(0, ip.length / 2) + "***";
}
```

**2. Request Logging Middleware**

Create `apps/auth-api/src/middleware/request-logger.ts`:

```typescript
import { Request, Response, NextFunction } from "express";
import { createRequestLogger, maskIP } from "@your-org/core-utils/logging";

export function requestLogger(req: Request, res: Response, next: NextFunction) {
  const traceId = (req.headers["x-trace-id"] as string) || undefined;
  const log = createRequestLogger(traceId);

  // Attach logger to request for use in handlers
  (req as any).log = log;
  (req as any).traceId = log.bindings().traceId;

  // Set trace ID in response header
  res.setHeader("X-Trace-Id", (req as any).traceId);

  const startTime = Date.now();

  // Log request
  log.info({
    event: "request_start",
    method: req.method,
    path: req.path,
    ip: maskIP(req.ip || ""),
    userAgent: req.get("user-agent"),
  });

  // Log response when finished
  res.on("finish", () => {
    const duration = Date.now() - startTime;
    log.info({
      event: "request_complete",
      method: req.method,
      path: req.path,
      statusCode: res.statusCode,
      duration,
    });
  });

  next();
}
```

**3. Auth-Specific Log Examples**

```typescript
// Successful login
logger.info({
  event: "user_login",
  userId: user.id,
  email: maskEmail(user.email),
  ip: req.ip,
  userAgent: req.get("user-agent"),
});

// Failed login
logger.warn({
  event: "login_failed",
  email: maskEmail(email),
  reason: "invalid_credentials",
  ip: req.ip,
  userAgent: req.get("user-agent"),
});

// User registration
logger.info({
  event: "user_registered",
  userId: newUser.id,
  email: maskEmail(newUser.email),
});

function maskEmail(email: string): string {
  const [local, domain] = email.split("@");
  return `${local.substring(0, 2)}***@${domain}`;
}
```

**Useful CloudWatch Insights Queries:**

```sql
-- Failed login attempts
fields @timestamp, event, email, ip
| filter event = "login_failed"
| stats count() by email, ip
| sort count desc

-- Successful logins by hour
fields @timestamp, event
| filter event = "user_login"
| stats count() by bin(@timestamp, 1h)
```

### Acceptance Criteria

- [ ] All logs output as single-line JSON
- [ ] Email addresses are masked in logs
- [ ] Passwords never appear in logs
- [ ] CloudWatch Insights query for failed logins works
- [ ] Logs include trace_id for request correlation
- [ ] Log level configurable via environment variable

### Estimated Duration: 1 day

---

## Outcome

**You have a secure, logged, working authentication system:**

- ✅ RDS MySQL database provisioned and secured
- ✅ User registration and login endpoints functional
- ✅ JWT-based authentication implemented
- ✅ WAF protecting against common attacks
- ✅ HTTPS enforced with auto-renewing certificates
- ✅ Structured logging for security monitoring
- ✅ Database migrations automated in deployment pipeline

**Next Step:** Build the CRUD service that leverages this Auth system.

**Total Duration:** 7–10 days (cumulative: 14–20 days from project start)

**Business Value Delivered:** Users can create accounts and authenticate. This enables all future protected features.
