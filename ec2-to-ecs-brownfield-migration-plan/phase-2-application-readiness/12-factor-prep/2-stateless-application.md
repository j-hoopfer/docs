# Phase 2: Stateless Application

**Goal:** Remove all reliance on local filesystem persistence so that containers can be replaced or scaled horizontally without data loss.

## Context & Themes

This document details the critical transition from stateful, server-bound applications to stateless, ephemeral containers. By decoupling the application from the underlying filesystem, we ensure that any container can be replaced at any time without data loss.

**Key Themes:**

- **Statelessness:** No client data stored on the container filesystem.
- **Immutability:** Containers are replaced, never patched. This is also what makes Auto Scaling possible — an Auto Scaling Group (ASG) can spin up new instances and terminate old ones based on CPU/memory utilization without human intervention, because every instance is identical and disposable. If an instance holds local state (a user's session, an uploaded file), killing it breaks that user. Statelessness removes that constraint entirely.
- **Externalized State:** All persistence moves to managed backing services (S3, Redis, RDS).

## Prerequisites

Before starting this task, ensure:

- [ ] [Configuration & Secrets](1-configuration-and-secrets.md) phase is completed.
- [ ] Access to the application codebase and ability to modify storage logic.
- [ ] AWS credentials with permissions to create S3 buckets and ElastiCache clusters.

## Overview

This phase ensures your application treats containers as ephemeral and cattle-not-pets. **No local state, no sticky sessions, no filesystem dependencies.** This is the core of 12-Factor methodology and enables horizontal scaling.

**Business Value:** Eliminates data loss from container restarts and enables horizontal scaling to handle traffic spikes. Applications with local filesystem storage lose critical data (uploads, reports) when containers restart, breaking customer functionality. This phase prevents that and enables scaling from 1 to 10 containers in under 2 minutes.

**Next Phase:** [Observability](3-observability.md)

---

## Feature 2: Stateless Architecture

**Business Value:** Eliminates data loss from container restarts and enables horizontal scaling.

### Story 2.1: Eliminate Ephemeral Filesystem Dependencies

- **Title:** Migrate File Storage from Local Filesystem to S3
- **Persona:** As a **developer**, I need to remove all reliance on local filesystem storage so that the application continues to function when containers are destroyed and recreated.

**Business Value:** Prevents data loss and enables horizontal scaling. Applications storing files locally (uploads, generated reports, caches) lose data when containers restart, breaking critical features like document uploads or invoice generation. Migrating to S3 (1-2 days) enables multi-instance deployments (horizontal scaling) and prevents customer-impacting data loss. One company prevented $50K in lost customer invoices by moving file storage to S3 before migration.

- **Requirements:**
  - Identify all file upload/download paths (e.g., `/var/www/uploads`, `/tmp/cache`)
  - Refactor file storage to use AWS S3 or EFS
  - Ensure no application state is stored on local disk
  - Files must persist across container restarts
  - Files must be accessible from any task instance

- **Implementation Details:**

  **Step 1: Audit Filesystem Usage**

  ```bash
  # Find file write operations
  grep -r "writeFile\|fopen\|file_put_contents\|open(" . --include="*.js" --include="*.php" --include="*.py"

  # Find upload handlers
  grep -r "upload\|multipart" . -i

  # Find temp file usage
  grep -r "/tmp\|/var/www/uploads" .

  # Check for file caching
  grep -r "cache.*file\|FileCache" .
  ```

  **Step 2: Create S3 Bucket with Proper Configuration**

  ```bash
  # Create bucket
  aws s3 mb s3://my-app-uploads-prod

  # Enable versioning (optional, for recovery)
  aws s3api put-bucket-versioning \
    --bucket my-app-uploads-prod \
    --versioning-configuration Status=Enabled

  # Block public access (important!)
  aws s3api put-public-access-block \
    --bucket my-app-uploads-prod \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

  # Enable lifecycle rules (delete old temp files)
  cat > lifecycle.json <<EOF
  {
    "Rules": [{
      "Id": "delete-temp-files",
      "Status": "Enabled",
      "Prefix": "temp/",
      "Expiration": { "Days": 7 }
    }]
  }
  EOF
  aws s3api put-bucket-lifecycle-configuration \
    --bucket my-app-uploads-prod \
    --lifecycle-configuration file://lifecycle.json
  ```

  **Step 3: Refactor Application Code**

  **Before (local filesystem - BAD):**

  ```javascript
  const multer = require("multer");
  const upload = multer({ dest: "/var/www/uploads/" }); // Lost on restart!

  app.post("/upload", upload.single("file"), (req, res) => {
    res.json({ path: `/uploads/${req.file.filename}` });
  });

  app.get("/uploads/:filename", (req, res) => {
    res.sendFile(`/var/www/uploads/${req.params.filename}`);
  });
  ```

  **After (S3 - GOOD):**

  ```javascript
  const {
    S3Client,
    PutObjectCommand,
    GetObjectCommand,
  } = require("@aws-sdk/client-s3");
  const { getSignedUrl } = require("@aws-sdk/s3-request-presigner");
  const multer = require("multer");

  const s3 = new S3Client({ region: process.env.AWS_REGION });
  const upload = multer({ storage: multer.memoryStorage() }); // In-memory buffer

  app.post("/upload", upload.single("file"), async (req, res) => {
    const key = `uploads/${Date.now()}-${req.file.originalname}`;

    await s3.send(
      new PutObjectCommand({
        Bucket: process.env.S3_BUCKET,
        Key: key,
        Body: req.file.buffer,
        ContentType: req.file.mimetype,
      }),
    );

    res.json({ key });
  });

  app.get("/download/:key", async (req, res) => {
    const command = new GetObjectCommand({
      Bucket: process.env.S3_BUCKET,
      Key: req.params.key,
    });

    // Generate pre-signed URL (valid for 1 hour)
    const url = await getSignedUrl(s3, command, { expiresIn: 3600 });
    res.redirect(url);
  });
  ```

  **Python (Flask) Example:**

  ```python
  import boto3
  from flask import Flask, request, jsonify
  from werkzeug.utils import secure_filename
  import os

  app = Flask(__name__)
  s3 = boto3.client('s3', region_name=os.environ['AWS_REGION'])
  bucket = os.environ['S3_BUCKET']

  @app.route('/upload', methods=['POST'])
  def upload_file():
      file = request.files['file']
      filename = secure_filename(file.filename)
      key = f"uploads/{filename}"

      s3.upload_fileobj(
          file,
          bucket,
          key,
          ExtraArgs={'ContentType': file.content_type}
      )

      return jsonify({'key': key})

  @app.route('/download/<path:key>')
  def download_file(key):
      url = s3.generate_presigned_url(
          'get_object',
          Params={'Bucket': bucket, 'Key': key},
          ExpiresIn=3600
      )
      return redirect(url)
  ```

  **Step 4: Add IAM Permissions**

  ECS Task Role needs S3 access (attach this policy to the ECS task role):

  > **Transitional phase — EC2:** During the period when the application is still running on EC2 alongside ECS, attach this same policy to the **EC2 Instance Profile role**. EC2 instances use instance profile credentials (not task role credentials), so the policy must be explicitly added to both roles until the EC2 fleet is decommissioned.

  ```json
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
        "Resource": "arn:aws:s3:::my-app-uploads-prod/*"
      },
      {
        "Effect": "Allow",
        "Action": "s3:ListBucket",
        "Resource": "arn:aws:s3:::my-app-uploads-prod"
      }
    ]
  }
  ```

  > **Local development:** Your code now requires S3, which creates a problem for developers working locally — relying on a live AWS connection is slow and fragile, and giving every developer broad AWS credentials violates least privilege. The recommended solution is a local S3-compatible emulator via Docker Compose. [MinIO](https://min.io/) is the lightest option; [LocalStack](https://localstack.cloud/) emulates the broader AWS API surface if you need more services.
  >
  > ```yaml
  > # docker-compose.yml (local dev only)
  > services:
  >   minio:
  >     image: minio/minio
  >     command: server /data --console-address ":9001"
  >     ports:
  >       - "9000:9000" # S3 API endpoint — point AWS_ENDPOINT_URL here
  >       - "9001:9001" # MinIO web console
  >     environment:
  >       MINIO_ROOT_USER: minioadmin
  >       MINIO_ROOT_PASSWORD: minioadmin
  > ```
  >
  > ```bash
  > # .env (local)
  > AWS_ENDPOINT_URL=http://localhost:9000
  > AWS_ACCESS_KEY_ID=minioadmin
  > AWS_SECRET_ACCESS_KEY=minioadmin
  > S3_BUCKET=my-app-uploads-dev
  > ```
  >
  > AWS SDKs (boto3, `@aws-sdk/client-s3`) will automatically use `AWS_ENDPOINT_URL` when set, so no code changes are needed — just the env var.

  **Step 5: Migrate Existing Files**

  ```bash
  # From EC2 to S3
  aws s3 sync /var/www/uploads/ s3://my-app-uploads-prod/uploads/

  # Verify
  aws s3 ls s3://my-app-uploads-prod/uploads/ | wc -l
  ```

  **Step 6: Alternative - EFS for High-Frequency Access**

  If you need POSIX filesystem (lots of small reads/writes):

  ```hcl
  # Terraform: Create EFS
  resource "aws_efs_file_system" "app_storage" {
    encrypted = true
    lifecycle_policy {
      transition_to_ia = "AFTER_30_DAYS"
    }
  }

  resource "aws_efs_mount_target" "app" {
    for_each = var.private_subnet_ids
    file_system_id  = aws_efs_file_system.app_storage.id
    subnet_id       = each.value
    security_groups = [aws_security_group.efs.id]
  }

  # ECS Task Definition
  resource "aws_ecs_task_definition" "app" {
    volume {
      name = "efs_storage"
      efs_volume_configuration {
        file_system_id = aws_efs_file_system.app_storage.id
        root_directory = "/uploads"
      }
    }

    container_definitions = jsonencode([{
      mountPoints = [{
        sourceVolume  = "efs_storage"
        containerPath = "/var/www/uploads"
        readOnly      = false
      }]
    }])
  }
  ```

  **EFS vs S3 Decision Matrix:**

  | Factor             | S3                      | EFS                         |
  | ------------------ | ----------------------- | --------------------------- |
  | **Cost**           | $0.023/GB/month         | $0.30/GB/month              |
  | **Performance**    | High latency (50-100ms) | Low latency (sub-ms)        |
  | **Use Case**       | Upload/download files   | POSIX filesystem operations |
  | **Concurrency**    | Unlimited               | Good (NFS-based)            |
  | **Lifecycle Mgmt** | Built-in                | Manual                      |
  | **Recommendation** | **Default choice**      | Only if POSIX required      |

  > **EFS caveat:** EFS cannot be mounted on Windows containers or Fargate tasks running a Windows OS. This guide assumes Linux containers, but it is worth knowing before choosing EFS for a mixed-OS environment.

- **Acceptance Criteria:**
  - ✅ File uploads persist after container restart
  - ✅ No application errors when `/var/www/uploads` doesn't exist
  - ✅ Files are accessible from any running task instance
  - ✅ Existing files migrated to S3/EFS
  - ✅ File URLs return valid content
  - ✅ IAM permissions configured for S3 access
  - ✅ Load test shows file operations work under concurrent load

- **EC2 Testing:**
  - Deploy S3-based code to EC2 first
  - Verify uploads work and files are accessible
  - Test with multiple application servers (if available)
  - Validate IAM role-based access works

---

## Story 2.2: Externalize Session Storage

- **Title:** Migrate Sessions to Redis/Database
- **Persona:** As a **user**, I need my login session to persist across requests so that I am not randomly logged out when my requests hit different Fargate tasks behind the load balancer.

**Business Value:** Enables horizontal scaling and load balancing, which are impossible with server-side sessions. ElastiCache session storage (2-3 days implementation) allows traffic to route to any container, preventing user logouts during deployments and enabling 3-10x more concurrent users via horizontal scaling. Improves user experience by eliminating unexpected logouts and enables zero-downtime deployments where containers restart without affecting active sessions. Critical for achieving 99.9% uptime SLA.

- **Requirements:**
  - Sessions must not be stored in local RAM or filesystem
  - Sessions must be accessible by all running task instances
  - Session store must be highly available and low-latency
  - User sessions persist across container restarts
  - Sessions work correctly when scaled to multiple tasks

- **Implementation Details:**

  **Step 1: Provision ElastiCache Redis**

  ```bash
  # Create Redis cluster (via AWS CLI or Terraform)
  aws elasticache create-cache-cluster \
    --cache-cluster-id my-app-sessions \
    --engine redis \
    --engine-version 7.0 \
    --cache-node-type cache.t3.micro \
    --num-cache-nodes 1 \
    --preferred-availability-zone us-east-1a

  # Get endpoint
  aws elasticache describe-cache-clusters \
    --cache-cluster-id my-app-sessions \
    --show-cache-node-info \
    --query 'CacheClusters[0].CacheNodes[0].Endpoint'
  ```

  > **Security Groups (required):** ElastiCache nodes deploy inside your VPC and are unreachable by default. Without an explicit inbound rule, EC2 instances and ECS tasks will time out connecting on port 6379. Add an inbound rule to the Redis Security Group allowing **TCP 6379** from the Application Security Group (the SG attached to your EC2 instances / ECS tasks). Scope it to the SG ID — not a CIDR — so the rule stays correct as instances are replaced.

  > **Data persistence:** Standard ElastiCache Redis is in-memory only. If the Redis node reboots (maintenance, AZ failure), all sessions are lost and every active user is logged out. If that is a business risk, consider one of:
  >
  > - **Multi-AZ with automatic failover** — a read replica is promoted within seconds of a primary failure; session data is preserved.
  > - **Redis AOF (append-only file) persistence** — ElastiCache supports this via the `appendonly yes` parameter group setting; AOF logs every write to disk so data survives a reboot.
  >
  > For session storage specifically, Multi-AZ failover is usually the right tradeoff: it protects against node failure without the write-latency overhead of AOF.

  **Step 2: Update Application Session Configuration**

  **Node.js (Express) Example:**

  ```javascript
  const session = require("express-session");
  const RedisStore = require("connect-redis").default;
  const { createClient } = require("redis");

  // Create Redis client
  const redisClient = createClient({
    socket: {
      host: process.env.REDIS_HOST,
      port: process.env.REDIS_PORT || 6379,
    },
    password: process.env.REDIS_AUTH_TOKEN, // If auth enabled
  });
  redisClient.connect().catch(console.error);

  // Configure session middleware
  app.use(
    session({
      store: new RedisStore({ client: redisClient }),
      secret: process.env.SESSION_SECRET,
      resave: false,
      saveUninitialized: false,
      cookie: {
        secure: process.env.NODE_ENV === "production", // HTTPS only
        httpOnly: true,
        maxAge: 1000 * 60 * 60 * 24 * 7, // 7 days
      },
    }),
  );
  ```

  **PHP (Laravel) Example:**

  ```bash
  # .env
  SESSION_DRIVER=redis
  REDIS_HOST=my-app-sessions.abc123.cache.amazonaws.com
  REDIS_PORT=6379
  REDIS_PASSWORD=null
  ```

  ```php
  // config/session.php (default Laravel config works)
  'driver' => env('SESSION_DRIVER', 'redis'),
  'connection' => 'session',
  ```

  **Step 3: Verify Session Sharing Across Instances**

  ```bash
  # Run two instances of your app locally
  docker run -d --name app1 -p 3001:3000 -e REDIS_HOST=redis my-app
  docker run -d --name app2 -p 3002:3000 -e REDIS_HOST=redis my-app

  # Login via app1
  curl -c cookies.txt -X POST http://localhost:3001/login -d "username=test&password=test"

  # Make authenticated request to app2 (different instance)
  curl -b cookies.txt http://localhost:3002/profile

  # Should see authenticated response
  ```

  **Step 4: Configure Session Cleanup**

  Redis TTL handles expiration automatically, but verify:

  ```bash
  # Check Redis for sessions
  redis-cli -h $REDIS_HOST
  KEYS sess:*
  TTL sess:abc123def456  # Should show remaining seconds
  ```

  **Database sessions are slower but work:**

  | Store    | Latency | Scalability | Recommendation       |
  | -------- | ------- | ----------- | -------------------- |
  | Redis    | < 5ms   | Excellent   | **Preferred**        |
  | Database | 20-50ms | Good        | Acceptable fallback  |
  | Local    | < 1ms   | **None**    | Don't use in Fargate |

- **Acceptance Criteria:**
  - ✅ User logs in on Task A, next request routed to Task B—user remains logged in
  - ✅ Scaling from 1 to N tasks does not cause session loss
  - ✅ Container restart does not log out active users
  - ✅ Sessions visible in Redis (`redis-cli KEYS sess:*`)
  - ✅ Load test with session-authenticated requests works correctly
  - ✅ Session TTL expires correctly (old sessions cleaned up)

- **EC2 Testing:**
  - Deploy Redis session code to EC2 first
  - Test session persistence across app restarts
  - Verify Redis connectivity and authentication
  - Test session expiration behavior

---

## Phase Completion Checklist

- [ ] No files written to local filesystem for persistent storage
- [ ] File uploads stored in S3 or EFS
- [ ] Existing files migrated to S3/EFS
- [ ] Sessions stored in Redis or database
- [ ] User sessions persist across container restarts
- [ ] Multiple application instances can serve same user
- [ ] Load tests pass with horizontal scaling
- [ ] Application tested on EC2 with external storage

---

## Rollback Plan

If issues are discovered after deployment:

1. **Lost file uploads:** Restore from S3 versioning or recent backup
2. **Session issues:** Fall back to database sessions (slower but functional)
3. **S3 access errors:** Check IAM task role permissions, verify bucket policy
4. **Redis connection errors:** Check security groups, verify Redis endpoint
