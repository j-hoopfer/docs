# Business Epic C: Resource Management (The MVP - CRUD Service)

**Goal:** Users can create, read, update, and delete resources. Services communicate via Service Discovery. Performance is tuned with caching.

**Duration:** Days 21–30

**Business Value:** Delivers core application functionality. Users can manage their data through a performant, scalable API.

**Prerequisites:** Business Epic B complete (Auth Service deployed).

**SAFe Principle:** "Add optimization (Redis, Auto-scaling) only when the workload exists. Measure first, then optimize."

---

## Story 3.1: Deploy CRUD Service to ECS

**From:** Original Epic 3, Story 3.3 (Service Discovery) - Part 1

As a Backend Engineer
I want to deploy a second service (CRUD API) to ECS
So that users can manage resources independently from authentication

### Technical Requirements

- New ECS service: `crud-api` running in private app subnets
- Separate ECR repository for CRUD service
- Task definition with health checks on `/health` endpoint
- ALB listener rule: Route `/api/resources/*` to CRUD service
- Minimum 2 tasks for high availability
- Environment variables injected from SSM Parameter Store

### Implementation Details

**1. CRUD API Structure**

```typescript
// apps/crud-api/src/main.ts
import express from "express";
import { authenticateToken } from "@scale/auth-middleware"; // Shared package
import { resourceRouter } from "./resource-controller";
import { securityHeaders } from "./middleware/security-headers";
import { requestLogger } from "./middleware/request-logger";

const app = express();
const PORT = process.env.PORT || 3001;

// Middleware
app.use(express.json());
app.use(securityHeaders);
app.use(requestLogger);

// Health check (unauthenticated)
app.get("/health", (req, res) => {
  res.status(200).json({ status: "ok", service: "crud-api" });
});

// Protected routes
app.use("/api/resources", authenticateToken, resourceRouter);

app.listen(PORT, () => {
  console.log(`CRUD API running on port ${PORT}`);
});
```

**2. Resource Controller**

```typescript
// apps/crud-api/src/resource-controller.ts
import { Router, Request, Response } from "express";
import { v4 as uuidv4 } from "uuid";
import { query } from "./database";

const router = Router();

// Create resource
router.post("/", async (req: Request, res: Response) => {
  try {
    const userId = (req as any).user.userId;
    const { title, description, category } = req.body;

    if (!title) {
      return res.status(400).json({ error: "Title is required" });
    }

    const resourceId = uuidv4();
    await query(
      `INSERT INTO resources (id, user_id, title, description, category, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, NOW(), NOW())`,
      [resourceId, userId, title, description, category],
    );

    res.status(201).json({
      message: "Resource created",
      resource: { id: resourceId, title, description, category },
    });
  } catch (error) {
    console.error("Create resource error:", error);
    res.status(500).json({ error: "Internal server error" });
  }
});

// List user resources (with pagination)
router.get("/", async (req: Request, res: Response) => {
  try {
    const userId = (req as any).user.userId;
    const page = parseInt(req.query.page as string) || 1;
    const limit = parseInt(req.query.limit as string) || 20;
    const offset = (page - 1) * limit;

    const resources = await query(
      `SELECT id, title, description, category, created_at, updated_at 
       FROM resources 
       WHERE user_id = ? AND is_deleted = FALSE
       ORDER BY created_at DESC
       LIMIT ? OFFSET ?`,
      [userId, limit, offset],
    );

    const [countResult] = await query(
      "SELECT COUNT(*) as total FROM resources WHERE user_id = ? AND is_deleted = FALSE",
      [userId],
    );

    res.status(200).json({
      resources,
      pagination: {
        page,
        limit,
        total: countResult.total,
        totalPages: Math.ceil(countResult.total / limit),
      },
    });
  } catch (error) {
    console.error("List resources error:", error);
    res.status(500).json({ error: "Internal server error" });
  }
});

// Get single resource
router.get("/:id", async (req: Request, res: Response) => {
  try {
    const userId = (req as any).user.userId;
    const { id } = req.params;

    const resources = await query(
      `SELECT id, title, description, category, created_at, updated_at
       FROM resources
       WHERE id = ? AND user_id = ? AND is_deleted = FALSE`,
      [id, userId],
    );

    if (resources.length === 0) {
      return res.status(404).json({ error: "Resource not found" });
    }

    res.status(200).json({ resource: resources[0] });
  } catch (error) {
    console.error("Get resource error:", error);
    res.status(500).json({ error: "Internal server error" });
  }
});

// Update resource
router.put("/:id", async (req: Request, res: Response) => {
  try {
    const userId = (req as any).user.userId;
    const { id } = req.params;
    const { title, description, category } = req.body;

    // Verify ownership
    const existing = await query(
      "SELECT id FROM resources WHERE id = ? AND user_id = ? AND is_deleted = FALSE",
      [id, userId],
    );

    if (existing.length === 0) {
      return res.status(404).json({ error: "Resource not found" });
    }

    await query(
      `UPDATE resources 
       SET title = COALESCE(?, title),
           description = COALESCE(?, description),
           category = COALESCE(?, category),
           updated_at = NOW()
       WHERE id = ? AND user_id = ?`,
      [title, description, category, id, userId],
    );

    res.status(200).json({ message: "Resource updated" });
  } catch (error) {
    console.error("Update resource error:", error);
    res.status(500).json({ error: "Internal server error" });
  }
});

// Delete resource (soft delete)
router.delete("/:id", async (req: Request, res: Response) => {
  try {
    const userId = (req as any).user.userId;
    const { id } = req.params;

    const result = await query(
      `UPDATE resources 
       SET is_deleted = TRUE, updated_at = NOW()
       WHERE id = ? AND user_id = ? AND is_deleted = FALSE`,
      [id, userId],
    );

    if (result.affectedRows === 0) {
      return res.status(404).json({ error: "Resource not found" });
    }

    res.status(200).json({ message: "Resource deleted" });
  } catch (error) {
    console.error("Delete resource error:", error);
    res.status(500).json({ error: "Internal server error" });
  }
});

export { router as resourceRouter };
```

**3. Database Migration for Resources Table**

```sql
-- migrations/002_create_resources_table.sql
CREATE TABLE resources (
  id CHAR(36) PRIMARY KEY,
  user_id CHAR(36) NOT NULL,
  title VARCHAR(255) NOT NULL,
  description TEXT,
  category VARCHAR(100),
  is_deleted BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  INDEX idx_user_id (user_id),
  INDEX idx_category (category),
  INDEX idx_created_at (created_at),
  INDEX idx_is_deleted (is_deleted),

  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

**4. ECS Service Configuration**

```hcl
resource "aws_ecs_service" "crud_api" {
  name            = "crud-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.crud_api.arn
  desired_count   = 2
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_app_subnet_ids
    security_groups  = [var.sg_app_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.crud_api.arn
    container_name   = "crud-api"
    container_port   = 3001
  }

  service_registries {
    registry_arn = aws_service_discovery_service.crud_api.arn
  }

  depends_on = [aws_lb_listener_rule.crud_api]
}

# ALB Listener Rule
resource "aws_lb_listener_rule" "crud_api" {
  listener_arn = var.https_listener_arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.crud_api.arn
  }

  condition {
    path_pattern {
      values = ["/api/resources/*"]
    }
  }
}
```

### Acceptance Criteria

- [ ] CRUD API deployed to ECS with 2 healthy tasks
- [ ] `/api/resources` endpoints accessible via ALB
- [ ] Health checks passing
- [ ] Resources table created via migration
- [ ] Authentication middleware validates JWT tokens
- [ ] CRUD operations work end-to-end

### Estimated Duration: 2–3 days

---

## Story 3.2: Service Discovery - Inter-Service Communication

**From:** Original Epic 3, Story 3.3 (Service Discovery)

As a Platform Engineer
I want services to discover each other via Cloud Map
So that the Auth API can communicate with the CRUD API without hardcoded IPs

### Technical Requirements

- AWS Cloud Map namespace: `local` (DNS-based)
- Service Discovery services for: auth-api, crud-api
- DNS names: `auth-api.local`, `crud-api.local`
- Services can resolve each other within VPC
- Health checks integrated with ECS service health

### Implementation Details

**1. Cloud Map Namespace**

```hcl
resource "aws_service_discovery_private_dns_namespace" "main" {
  name = "local"
  vpc  = var.vpc_id

  tags = {
    Name        = "${var.project}-${var.environment}-namespace"
    Environment = var.environment
  }
}
```

**2. Service Discovery Services**

```hcl
# Auth API Service Discovery
resource "aws_service_discovery_service" "auth_api" {
  name = "auth-api"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

# CRUD API Service Discovery
resource "aws_service_discovery_service" "crud_api" {
  name = "crud-api"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}
```

**3. Example: Auth API calling CRUD API**

```typescript
// apps/auth-api/src/services/user-resources.ts
import http from "http";

async function getUserResourceCount(userId: string, authToken: string): Promise<number> {
  return new Promise((resolve, reject) => {
    const options = {
      hostname: "crud-api.local", // Service Discovery DNS
      port: 3001,
      path: "/api/resources?limit=1",
      method: "GET",
      headers: {
        Authorization: `Bearer ${authToken}`,
      },
    };

    const req = http.request(options, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => {
        const response = JSON.parse(data);
        resolve(response.pagination?.total || 0);
      });
    });

    req.on("error", reject);
    req.end();
  });
}
```

### Acceptance Criteria

- [ ] Cloud Map namespace created
- [ ] Service Discovery configured for auth-api and crud-api
- [ ] DNS resolution works: `dig auth-api.local` returns IPs
- [ ] Services can communicate using service names
- [ ] Health check failures remove unhealthy tasks from DNS

### Estimated Duration: 1 day

---

## Story 3.3: Shared Auth Middleware Package

**New:** Code reuse infrastructure

As a Developer
I want shared authentication middleware
So that all services can validate JWTs consistently

### Technical Requirements

- Create `packages/auth-middleware` in monorepo
- Export `authenticateToken` middleware
- JWT validation with RS256 support
- Token caching (in-memory) to reduce verification overhead
- Published as `@scale/auth-middleware` for internal use

### Implementation Details

**1. Auth Middleware Package**

```typescript
// packages/auth-middleware/src/index.ts
import jwt from "jsonwebtoken";
import { Request, Response, NextFunction } from "express";

interface AuthenticatedRequest extends Request {
  user?: {
    userId: string;
    email: string;
  };
}

const JWT_SECRET = process.env.JWT_SECRET!;

// Simple in-memory cache (for MVP)
const tokenCache = new Map<string, { userId: string; email: string; exp: number }>();

export function authenticateToken(req: AuthenticatedRequest, res: Response, next: NextFunction) {
  const authHeader = req.headers["authorization"];
  const token = authHeader && authHeader.split(" ")[1];

  if (!token) {
    return res.status(401).json({ error: "Access token required" });
  }

  // Check cache first
  const cached = tokenCache.get(token);
  if (cached && cached.exp > Date.now() / 1000) {
    req.user = { userId: cached.userId, email: cached.email };
    return next();
  }

  // Verify token
  jwt.verify(token, JWT_SECRET, (err: any, decoded: any) => {
    if (err) {
      tokenCache.delete(token); // Remove invalid token from cache
      return res.status(403).json({ error: "Invalid or expired token" });
    }

    req.user = {
      userId: decoded.userId,
      email: decoded.email,
    };

    // Cache valid token
    tokenCache.set(token, {
      userId: decoded.userId,
      email: decoded.email,
      exp: decoded.exp,
    });

    // Clean up cache periodically (prevent memory leak)
    if (tokenCache.size > 10000) {
      const now = Date.now() / 1000;
      for (const [key, value] of tokenCache.entries()) {
        if (value.exp < now) {
          tokenCache.delete(key);
        }
      }
    }

    next();
  });
}

export type { AuthenticatedRequest };
```

**2. Package Configuration**

```json
// packages/auth-middleware/package.json
{
  "name": "@scale/auth-middleware",
  "version": "1.0.0",
  "main": "dist/index.js",
  "types": "dist/index.d.ts",
  "scripts": {
    "build": "tsc",
    "test": "jest"
  },
  "dependencies": {
    "jsonwebtoken": "^9.0.2"
  },
  "peerDependencies": {
    "express": "^4.18.0"
  },
  "devDependencies": {
    "@types/express": "^4.17.21",
    "@types/jsonwebtoken": "^9.0.5",
    "typescript": "^5.3.3"
  }
}
```

### Acceptance Criteria

- [ ] `@scale/auth-middleware` package created
- [ ] Middleware validates JWT tokens correctly
- [ ] Invalid tokens return 403 Forbidden
- [ ] Missing tokens return 401 Unauthorized
- [ ] Token caching reduces verification overhead
- [ ] Both auth-api and crud-api use shared package

### Estimated Duration: 1 day

---

## Story 3.4: Performance Optimization - Redis Caching

**From:** Original Epic 6, Stories 6.2 (Redis Infrastructure) + 6.3 (Caching Strategy)

As a Backend Engineer
I want to cache frequently accessed resources in Redis
So that we reduce database load and improve response times

### Technical Requirements

- ElastiCache Redis cluster (Primary + Replica, Multi-AZ)
- Security group: Port 6379 accessible only from `sg_app`
- Encryption: At-rest and in-transit enabled
- Cache strategy: Cache-aside pattern for GET `/api/resources/:id`
- TTL: 5 minutes for resource data
- Cache invalidation on UPDATE/DELETE operations
- Redis connection pooling via ioredis

### Implementation Details

**1. Redis Infrastructure**

Create `terraform/modules/cache/redis.tf`:

```hcl
variable "project" { type = string }
variable "environment" { type = string }
variable "vpc_id" { type = string }
variable "private_app_subnet_ids" { type = list(string) }
variable "sg_app_id" { type = string }
variable "node_type" {
  type    = string
  default = "cache.t4g.micro"
}

# Redis Security Group
resource "aws_security_group" "redis" {
  name        = "${var.project}-${var.environment}-redis-sg"
  description = "Security group for ElastiCache Redis"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Redis from app layer"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.sg_app_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project}-${var.environment}-redis-sg"
    Environment = var.environment
  }
}

# Subnet Group
resource "aws_elasticache_subnet_group" "redis" {
  name       = "${var.project}-${var.environment}-redis-subnet"
  subnet_ids = var.private_app_subnet_ids

  tags = {
    Environment = var.environment
  }
}

# Parameter Group
resource "aws_elasticache_parameter_group" "redis" {
  name   = "${var.project}-${var.environment}-redis-params"
  family = "redis7"

  parameter {
    name  = "maxmemory-policy"
    value = "volatile-lru"
  }
}

# Redis Replication Group (Primary + Replica)
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "${var.project}-${var.environment}-redis"
  description          = "Redis cluster for ${var.project} ${var.environment}"

  node_type            = var.node_type
  num_cache_clusters   = 2  # Primary + 1 Replica
  parameter_group_name = aws_elasticache_parameter_group.redis.name
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.redis.name
  security_group_ids = [aws_security_group.redis.id]

  automatic_failover_enabled = true
  multi_az_enabled           = true

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = random_password.redis_auth.result

  snapshot_retention_limit = var.environment == "prod" ? 7 : 1
  snapshot_window          = "05:00-06:00"
  maintenance_window       = "mon:06:00-mon:07:00"

  tags = {
    Name        = "${var.project}-${var.environment}-redis"
    Environment = var.environment
  }
}

resource "random_password" "redis_auth" {
  length  = 32
  special = false  # Redis auth token doesn't support all special chars
}

# Store Redis credentials in Secrets Manager
resource "aws_secretsmanager_secret" "redis" {
  name = "${var.project}/${var.environment}/redis-credentials"
}

resource "aws_secretsmanager_secret_version" "redis" {
  secret_id = aws_secretsmanager_secret.redis.id
  secret_string = jsonencode({
    host     = aws_elasticache_replication_group.redis.primary_endpoint_address
    port     = 6379
    password = random_password.redis_auth.result
  })
}

# Outputs
output "redis_endpoint" { value = aws_elasticache_replication_group.redis.primary_endpoint_address }
output "redis_port" { value = 6379 }
output "redis_secret_arn" { value = aws_secretsmanager_secret.redis.arn }
```

**2. Redis Client Setup**

```typescript
// apps/crud-api/src/cache.ts
import Redis from "ioredis";
import pino from "pino";

const logger = pino({ level: process.env.LOG_LEVEL || "info" });

const redis = new Redis({
  host: process.env.REDIS_HOST!,
  port: Number(process.env.REDIS_PORT || 6379),
  password: process.env.REDIS_PASSWORD,
  tls: process.env.NODE_ENV === "production" ? {} : undefined,
  retryStrategy: (times) => {
    const delay = Math.min(times * 50, 2000);
    return delay;
  },
  maxRetriesPerRequest: 3,
});

redis.on("connect", () => logger.info("Redis connected"));
redis.on("error", (err) => logger.error({ err }, "Redis error"));

export async function getFromCache<T>(key: string): Promise<T | null> {
  try {
    const data = await redis.get(key);
    return data ? JSON.parse(data) : null;
  } catch (error) {
    logger.error({ error, key }, "Cache get error");
    return null; // Fail open: return null on cache errors
  }
}

export async function setInCache(key: string, value: any, ttl: number = 300): Promise<void> {
  try {
    await redis.setex(key, ttl, JSON.stringify(value));
  } catch (error) {
    logger.error({ error, key }, "Cache set error");
    // Fail silently: cache is not critical path
  }
}

export async function deleteFromCache(key: string): Promise<void> {
  try {
    await redis.del(key);
  } catch (error) {
    logger.error({ error, key }, "Cache delete error");
  }
}

export { redis };
```

**3. Update Resource Controller with Caching**

```typescript
// Get single resource (with caching)
router.get("/:id", async (req: Request, res: Response) => {
  try {
    const userId = (req as any).user.userId;
    const { id } = req.params;
    const cacheKey = `resource:${userId}:${id}`;

    // Try cache first
    const cached = await getFromCache(cacheKey);
    if (cached) {
      logger.debug({ cacheKey }, "Cache hit");
      return res.status(200).json({ resource: cached, cached: true });
    }

    // Cache miss: query database
    logger.debug({ cacheKey }, "Cache miss");
    const resources = await query(
      `SELECT id, title, description, category, created_at, updated_at
       FROM resources
       WHERE id = ? AND user_id = ? AND is_deleted = FALSE`,
      [id, userId],
    );

    if (resources.length === 0) {
      return res.status(404).json({ error: "Resource not found" });
    }

    const resource = resources[0];

    // Store in cache
    await setInCache(cacheKey, resource, 300); // 5 min TTL

    res.status(200).json({ resource, cached: false });
  } catch (error) {
    console.error("Get resource error:", error);
    res.status(500).json({ error: "Internal server error" });
  }
});

// Update resource (invalidate cache)
router.put("/:id", async (req: Request, res: Response) => {
  try {
    const userId = (req as any).user.userId;
    const { id } = req.params;
    const { title, description, category } = req.body;

    // ... existing update logic ...

    // Invalidate cache
    const cacheKey = `resource:${userId}:${id}`;
    await deleteFromCache(cacheKey);

    res.status(200).json({ message: "Resource updated" });
  } catch (error) {
    console.error("Update resource error:", error);
    res.status(500).json({ error: "Internal server error" });
  }
});
```

### Acceptance Criteria

- [ ] ElastiCache Redis cluster deployed in Multi-AZ mode
- [ ] Redis accessible only from app security group
- [ ] Encryption enabled (at-rest and in-transit)
- [ ] GET requests check cache before database
- [ ] Cache hits logged for monitoring
- [ ] UPDATE/DELETE operations invalidate cache
- [ ] Load test shows reduced database queries

### Estimated Duration: 2 days

---

## Story 3.5: Auto-Scaling - Scale Based on Real Workload

**From:** Original Epic 7, Stories 7.1 (Load Test) + 7.2 (Auto-Scaling)

As a Platform Engineer
I want ECS services to auto-scale based on CPU and request count
So that the system handles traffic spikes automatically

### Technical Requirements

- Load test to establish baseline (k6)
- Target tracking policy: CPU 70% for CRUD API
- Target tracking policy: Request count for Auth API (if needed)
- Min tasks: 2, Max tasks: 10
- Scale out cooldown: 60s, Scale in cooldown: 300s
- CloudWatch alarms for scaling events

### Implementation Details

**1. Load Test Script (k6)**

```javascript
// load-tests/crud-api.js
import http from "k6/http";
import { check, sleep } from "k6";

export const options = {
  stages: [
    { duration: "2m", target: 50 }, // Warm up
    { duration: "5m", target: 200 }, // Peak load
    { duration: "2m", target: 0 }, // Cool down
  ],
  thresholds: {
    http_req_duration: ["p(95)<500"], // 95% requests < 500ms
    http_req_failed: ["rate<0.01"], // < 1% errors
  },
};

const TOKEN = __ENV.AUTH_TOKEN; // Pass via environment
const BASE_URL = "https://api.yourdomain.com";

export default function () {
  const headers = {
    Authorization: `Bearer ${TOKEN}`,
    "Content-Type": "application/json",
  };

  // Read operation (most common)
  const listRes = http.get(`${BASE_URL}/api/resources?limit=10`, { headers });
  check(listRes, { "list status 200": (r) => r.status === 200 });

  sleep(1);

  // Create operation (less frequent)
  if (Math.random() < 0.2) {
    const createRes = http.post(
      `${BASE_URL}/api/resources`,
      JSON.stringify({
        title: `Test Resource ${Date.now()}`,
        description: "Load test resource",
        category: "test",
      }),
      { headers },
    );
    check(createRes, { "create status 201": (r) => r.status === 201 });
  }

  sleep(1);
}
```

Run the test:

```bash
k6 run --env AUTH_TOKEN="your_jwt_token" load-tests/crud-api.js
```

**2. Auto-Scaling Policies**

Create `terraform/modules/compute/autoscaling.tf`:

```hcl
variable "project" { type = string }
variable "environment" { type = string }
variable "ecs_cluster_name" { type = string }
variable "ecs_service_name" { type = string }
variable "min_capacity" {
  type    = number
  default = 2
}
variable "max_capacity" {
  type    = number
  default = 10
}

# Auto-scaling target
resource "aws_appautoscaling_target" "ecs_service" {
  max_capacity       = var.max_capacity
  min_capacity       = var.min_capacity
  resource_id        = "service/${var.ecs_cluster_name}/${var.ecs_service_name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

# CPU-based scaling policy
resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.project}-${var.environment}-cpu-autoscaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_service.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_service.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_service.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 70.0
    scale_out_cooldown = 60
    scale_in_cooldown  = 300
  }
}

# Memory-based scaling policy (optional, useful for memory-intensive apps)
resource "aws_appautoscaling_policy" "memory" {
  name               = "${var.project}-${var.environment}-memory-autoscaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_service.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_service.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_service.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value       = 80.0
    scale_out_cooldown = 60
    scale_in_cooldown  = 300
  }
}

# Request count scaling (for ALB-fronted services)
resource "aws_appautoscaling_policy" "request_count" {
  name               = "${var.project}-${var.environment}-request-autoscaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_service.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_service.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_service.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = var.alb_target_group_suffix
    }
    target_value       = 1000.0  # 1000 requests per target per minute
    scale_out_cooldown = 60
    scale_in_cooldown  = 300
  }
}

# CloudWatch Alarms for scaling events
resource "aws_cloudwatch_metric_alarm" "scale_out" {
  alarm_name          = "${var.project}-${var.environment}-scale-out"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "High CPU - scaling out"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  tags = {
    Environment = var.environment
  }
}

resource "aws_cloudwatch_metric_alarm" "scale_in" {
  alarm_name          = "${var.project}-${var.environment}-scale-in"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 5
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 30
  alarm_description   = "Low CPU - may scale in"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  tags = {
    Environment = var.environment
  }
}
```

### Acceptance Criteria

- [ ] Load test establishes baseline: "1 task handles X RPS at Y% CPU"
- [ ] Auto-scaling policies configured for CRUD API
- [ ] Min 2 tasks, max 10 tasks enforced
- [ ] Load test triggers scale-out event
- [ ] CloudWatch shows scaling activities
- [ ] Tasks scale in after load decreases

### Estimated Duration: 1–2 days

---

## Outcome

**You have a performant, scalable CRUD application:**

- ✅ CRUD API deployed with full Create/Read/Update/Delete operations
- ✅ Service Discovery enables inter-service communication
- ✅ Shared authentication middleware ensures consistent security
- ✅ Redis caching reduces database load by ~60-80% for reads
- ✅ Auto-scaling handles traffic spikes automatically
- ✅ Load testing establishes performance baselines

**Next Step:** Move advanced features (Blue/Green deployments, Distributed Tracing, Disaster Recovery) to a prioritized backlog.

**Total Duration:** 7–10 days (cumulative: 21–30 days from project start)

**Business Value Delivered:** Users can fully manage their resources with predictable performance and automatic scaling.

---

## What About the Rest?

Items from the original roadmap that are **deferred to the backlog** (implement only when needed):

### Technical Debt / Optimization Backlog

**From Epic 5:**

- Story 5.2: Distributed Tracing (X-Ray) - Add only if debugging multi-service issues becomes difficult
- Story 5.3: Golden Signals Dashboard - Nice-to-have for SRE maturity

**From Epic 7:**

- Story 7.3: Chaos Engineering - Add when system is stable and team is ready
- Story 7.4: Disaster Recovery Drills - Schedule quarterly after go-live

**From Epic 8:**

- Story 8.1: IaC Scanning (Checkov) - Add to CI/CD when security audit requires it
- Story 8.2: Vulnerability Alerting - Implement when compliance demands it

**From Epic 9:**

- Epic 9: Blue/Green Deployments - Add when zero-downtime is a hard requirement
- Rolling updates are sufficient for MVP

**From Epic 10:**

- Story 10.1: Incident Runbooks - Create as incidents occur organically
- Story 10.2: SLOs - Define after 30 days of production metrics
- Story 10.3: Public Status Page - Add when customer base grows
- Story 10.4: Pre-Production Validation - Comprehensive suite grows with features

These items are **important but not critical for MVP**. Implement them using the same story-driven approach when business needs justify the investment.
