# Epic 6: Production Scalability & Performance

**Goal:** Ensure the application can handle high concurrency and serve assets efficiently via CDN and Caching.
**Duration:** 2–4 Days
**Prerequisites:** Epic 5 (Observability) complete.

---

## Story 6.1: Database Connection Pooling (MySQL)

As a Backend Engineer
I want proper database connection pooling
So that I don't crash the database by opening 1,000 connections during a traffic spike

### Technical Requirements

- **Formula:** `Pool Size = (RDS max_connections * 0.75–0.8 - reserved) / (Max ECS Tasks)`.
  - Reserve ~10–20 connections for replication, admin, migration jobs.
  - Example: `(150 * 0.8 - 15) / 10 tasks ≈ 12 per task`.
- **Pool Settings (mysql2):**
  - `waitForConnections: true`, `connectionLimit: <calculated>`, `queueLimit: 0` (no hard drop; app controls 503).
  - Prefer short-lived queries; release connections promptly.
- **Timeouts:**
  - Client: `connectTimeout: 5000ms` (fail fast).
  - Server: Consider RDS Parameter Group `wait_timeout=60s` for idle connections (Epic 2).
- **Error Handling:** If the pool is exhausted, return **503 Service Unavailable** (do not crash the process). Implement graceful fallbacks and backoff.

### Code Example (Node.js / mysql2)

```javascript
import mysql from "mysql2/promise";
import pino from "pino";

const logger = pino({ level: process.env.LOG_LEVEL || "info" });
const pool = mysql.createPool({
  host: process.env.DB_HOST,
  port: Number(process.env.DB_PORT || 3306),
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME,
  waitForConnections: true,
  connectionLimit: Number(process.env.DB_POOL_MAX || 12),
  queueLimit: 0,
  connectTimeout: 5000,
});

export async function query(sql, params) {
  try {
    const [rows] = await pool.query(sql, params);
    return rows;
  } catch (err) {
    if (String(err?.code).includes("POOL") || String(err?.message).includes("limit")) {
      // Map pool exhaustion to 503
      throw Object.assign(new Error("Service Unavailable"), { statusCode: 503 });
    }
    throw err;
  }
}
```

### Acceptance Criteria

- [ ] Connection pool configured with calculated limits (not defaults).
- [ ] Load Test (k6) shows DB connections stay flat while requests spike.
- [ ] **Resilience:** App returns `503` when pool is saturated.

---

## Story 6.2: Provision Redis Infrastructure (ElastiCache)

As a Platform Engineer
I want to deploy an ElastiCache Redis cluster
So that I can offload heavy reads from the database

### Technical Requirements

- **Architecture:** Primary + Replica (Multi-AZ) in Private Subnets.
- **Auth Source:** **AWS Secrets Manager** (supports rotation), inject into ECS Task Definition as secret.
- **Security:** Allow ingress on port `6379` **only** from `sg_app`.
- **Encryption:** Enable `at_rest_encryption` and `transit_encryption`; clients must use TLS.

### Terraform (module sketch)

```hcl
resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.project}-${var.environment}-redis"
  subnet_ids = var.private_app_subnet_ids
}

resource "aws_security_group" "redis" {
  name        = "${var.project}-${var.environment}-sg-redis"
  description = "Redis access from app only"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    security_groups = [var.sg_app_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_elasticache_replication_group" "main" {
  replication_group_id       = "${var.project}-${var.environment}-redis"
  description                = "App Cache"
  engine                     = "redis"
  engine_version             = "7.0"
  node_type                  = "cache.t4g.micro"
  num_cache_clusters         = 2
  automatic_failover_enabled = true
  multi_az_enabled           = true

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = var.redis_auth_token # from Secrets Manager

  subnet_group_name          = aws_elasticache_subnet_group.main.name
  security_group_ids         = [aws_security_group.redis.id]
}
```

### Acceptance Criteria

- [ ] Redis Cluster deployed (Primary + Replica).
- [ ] Security Group `sg_redis` allows only `sg_app`.
- [ ] Connection test: `redis-cli -h <endpoint> --tls -a <token> ping` -> `PONG`.

---

## Story 6.3: Implement App-Side Caching (Cache-Aside)

As a Backend Engineer
I want to implement the "Cache-Aside" pattern
So that frequently accessed data (e.g., User Profiles) loads in <10ms

### Technical Requirements

- **Pattern:** `Get Cache -> (Miss) -> Get DB -> Set Cache -> Return`.
- **TTL:** Default **5 minutes** (adjust per endpoint criticality).
- **Failover:** If Redis is down, catch the error, log it, and **fall back to DB**. Do not crash.
- **Metrics:** Log `cache_hit`, `cache_miss`, and latency per operation.

### Code Example (Node.js / ioredis)

```javascript
import Redis from "ioredis";
const redis = new Redis({
  host: process.env.REDIS_HOST,
  port: Number(process.env.REDIS_PORT || 6379),
  password: process.env.REDIS_AUTH_TOKEN,
  tls: {}, // enable TLS
});

const TTL_SECONDS = Number(process.env.CACHE_TTL || 300);

export async function getUserProfile(userId) {
  const key = `user:${userId}`;
  const cached = await redis.get(key);
  if (cached) {
    // logger.info({ key }, 'cache_hit');
    return JSON.parse(cached);
  }
  const profile = await query("SELECT * FROM users WHERE id=?", [userId]);
  await redis.setex(key, TTL_SECONDS, JSON.stringify(profile));
  // logger.info({ key }, 'cache_miss');
  return profile;
}
```

### Acceptance Criteria

- [ ] Cache-Aside pattern implemented for high-read endpoints.
- [ ] **Resilience:** App functions (slower) if Redis is unreachable.
- [ ] **Metrics:** Hits/misses visible in logs and CloudWatch Insights.

---

## Story 6.4: Static Asset Offloading (CDN)

As a Frontend Engineer
I want static assets served from CloudFront
So that I reduce load on the ECS tasks and improve global load speeds

### Technical Requirements

- **Origin:** S3 Bucket (Private, Block Public Access).
- **Access:** CloudFront **Origin Access Control (OAC)**.
- **Caching:** Use Managed Cache Policy `CachingOptimized` (`658327ea-f89d-4fab-a63d-7e88639e58f4`).
- **Protocol:** Redirect HTTP to HTTPS.

### Terraform (key pieces)

```hcl
resource "aws_s3_bucket" "assets" {
  bucket = "${var.project}-${var.environment}-assets"
  block_public_acls   = true
  block_public_policy = true
  ignore_public_acls  = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "oac" {
  name                   = "${var.project}-${var.environment}-oac"
  description            = "OAC for private S3 origin"
  origin_access_control_origin_type = "s3"
  signing_behavior       = "always"
  signing_protocol       = "sigv4"
}

resource "aws_cloudfront_distribution" "cdn" {
  enabled = true
  default_cache_behavior {
    target_origin_id = "s3-origin"
    viewer_protocol_policy = "redirect-to-https"
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f4"
  }
  origin {
    domain_name = aws_s3_bucket.assets.bucket_regional_domain_name
    origin_id   = "s3-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }
}

# Bucket policy for OAC (replace account and distribution IDs)
resource "aws_s3_bucket_policy" "assets" {
  bucket = aws_s3_bucket.assets.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid      = "AllowCloudFrontAccessViaOAC",
      Effect   = "Allow",
      Principal = { Service = "cloudfront.amazonaws.com" },
      Action   = ["s3:GetObject"],
      Resource = ["${aws_s3_bucket.assets.arn}/*"],
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.cdn.arn
        }
      }
    }]
  })
}
```

### Acceptance Criteria

- [ ] S3 Bucket created (Public Access Block = True).
- [ ] CloudFront Distribution active.
- [ ] **Security:** Direct S3 URL access is denied; must go through CloudFront.
- [ ] Assets load via the CloudFront domain.

---

## ✅ Epic 6 Definition of Done

1. **DB Resilience:** Connection pooling prevents DB crashes under load.
2. **Caching:** Redis Cluster active; Cache-aside pattern implemented.
3. **Assets:** Static files served via CloudFront (HTTPS).
