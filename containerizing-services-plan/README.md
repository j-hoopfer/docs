# Containerizing Services Plan

## Overview

This plan guides you through packaging your 12-Factor-ready application into production Docker containers. These changes focus on **Docker/container mechanics** and require DevOps/Platform team expertise.

**Prerequisites:** Complete [12-Factor App Preparation Plan](../prepare-app-for-12-factor-plan/) first. Your application must be stateless, config-externalized, and validated on EC2 before containerization.

---

## Why Containerize After 12-Factor Prep?

| Prerequisite from 12-Factor Plan | Why It Matters for Containers                                         |
| -------------------------------- | --------------------------------------------------------------------- |
| ✅ Config via env vars           | Containers inject config at runtime—no `.env` files baked into images |
| ✅ Logs to stdout                | Docker/ECS capture stdout automatically—file logging doesn't work     |
| ✅ Sessions in Redis             | Containers restart frequently—local sessions would log users out      |
| ✅ Files in S3                   | Container filesystem is ephemeral—local files disappear on restart    |
| ✅ Health checks working         | ECS/ALB need health endpoints to route traffic correctly              |

**If you haven't completed 12-Factor prep, containerization will fail in production.**

---

## Plan Architecture

This plan focuses on **Docker packaging mechanics**. No application code changes required (those were done in 12-Factor plan).

**Related Plans:**

- **Prerequisite:** [12-Factor App Preparation Plan](../prepare-app-for-12-factor-plan/) - MUST complete first
- **Next Step:** [ECS Brownfield Migration Plan](../ec2-to-ecs-brownfield-migration-plan/) - Deploy to Fargate
- **Foundation:** [Terraform Bootstrap Plan](../terraform-bootstrap-plan/) - Terraform state backend

---

## Success Criteria

Before deploying to ECS, verify:

- ✅ `docker build` succeeds without errors
- ✅ `docker run` works locally with only `-e` environment variables (no `.env` file)
- ✅ Application binds to `0.0.0.0` (not localhost/127.0.0.1)
- ✅ Container handles SIGTERM gracefully (exits within 10 seconds)
- ✅ No zombie processes accumulate during 24-hour run test
- ✅ Multi-architecture images built (amd64 + arm64)
- ✅ `docker-compose up` works for local development
- ✅ Container runs as non-root user
- ✅ Image size < 500MB (ideally < 200MB)
- ✅ Container passes health check within 30 seconds

---

## Execution Phases

### Phase 1: Basic Containerization (Foundation)

**Goal:** Create working Docker images

**Stories:**

- [Story 1: Create Production-Ready Dockerfile](plan/docker-packaging.md#story-1)
- [Story 2: Configure Network Binding and Port Exposure](plan/docker-packaging.md#story-2)
- [Story 3: Establish Local Development Parity with docker-compose](plan/docker-packaging.md#story-3)

**Validation:** `docker-compose up` starts full stack locally; app responds to HTTP requests

---

### Phase 2: Container Lifecycle (Reliability)

**Goal:** Handle container start/stop signals correctly

**Stories:**

- [Story 4: Handle PID 1 and Zombie Processes](plan/container-lifecycle.md#story-4)
- [Story 5: Implement SIGTERM Handler](plan/container-lifecycle.md#story-5)

**Validation:** `docker stop` exits gracefully in < 10s; no zombie processes after 24-hour run

---

### Phase 3: Optimization (Performance & Cost)

**Goal:** Minimize image size and startup time

**Stories:**

- [Story 6: Build Multi-Architecture Container Images](plan/optimization.md#story-6)
- [Story 7: Optimize Container Startup Time](plan/optimization.md#story-7)
- [Story 8: Configure Container Memory and CPU Limits](plan/optimization.md#story-8)

**Validation:** Image < 500MB, health check passes in < 30s, ARM64 image works correctly

---

### Phase 4: Security Hardening (Production Readiness)

**Goal:** Lock down container security

**Stories:**

- [Story 9: Run Containers as Non-Root User](plan/security.md#story-9)

**Validation:** `docker exec whoami` returns non-root user; no permission errors

---

## Team Assignment

| Role                     | Responsibilities                                       |
| ------------------------ | ------------------------------------------------------ |
| **DevOps/Platform Team** | Implement all stories 1-9 (Docker expertise required)  |
| **Development Team**     | Support with application startup/config questions      |
| **Security Team**        | Review story 9 (non-root); approve final images        |
| **QA Team**              | Validate containers work correctly with docker-compose |

---

## Container Best Practices

### Image Building

- ✅ Use multi-stage builds to reduce size
- ✅ Use `.dockerignore` to exclude unnecessary files
- ✅ Build for both amd64 and arm64 (20% cost savings with Graviton)
- ✅ Use specific base image tags (not `latest`)
- ✅ Run as non-root user
- ❌ Don't bake secrets or `.env` files into images
- ❌ Don't use `latest` tags in production
- ❌ Don't run as root user

### Container Runtime

- ✅ Inject all config via environment variables
- ✅ Handle SIGTERM for graceful shutdown
- ✅ Use init process (tini/dumb-init) or ECS `initProcessEnabled`
- ✅ Bind to `0.0.0.0` for network interfaces
- ✅ Keep containers stateless (no local file writes)
- ❌ Don't rely on container filesystem for persistence
- ❌ Don't bind to localhost/127.0.0.1
- ❌ Don't ignore SIGTERM signals

---

## Local Development Workflow

Once containerization is complete:

```bash
# Start full stack locally
docker-compose up -d

# View logs
docker-compose logs -f app

# Run migrations
docker-compose exec app npm run migrate

# Run tests
docker-compose exec app npm test

# Stop stack
docker-compose down
```

This matches the ECS production environment closely, reducing "works on my machine" issues.

---

## Common Pitfalls

1. **Binding to localhost**: App must bind to `0.0.0.0`, not `127.0.0.1` (ALB can't reach it)
2. **Ignoring SIGTERM**: Container gets `SIGKILL` after 30s, dropping in-flight requests
3. **Running as root**: Security risk; many orgs block root containers
4. **Baking .env into image**: Secrets leak; can't reuse image across environments
5. **Not handling PID 1**: Zombie processes accumulate; graceful shutdown fails
6. **Large images**: Slow deploys; use multi-stage builds to reduce size
7. **No docker-compose**: Developers can't test locally; bugs discovered in production

---

## Architecture Patterns

### Single-Stage vs Multi-Stage Builds

**Single-Stage (Simple but Large):**

```dockerfile
FROM node:18
COPY . /app
RUN npm install
CMD ["node", "server.js"]
```

**Result:** ~1GB image (includes build tools)

**Multi-Stage (Complex but Small):**

```dockerfile
# Build stage
FROM node:18 AS builder
COPY package*.json ./
RUN npm ci --only=production

# Runtime stage
FROM node:18-slim
COPY --from=builder /node_modules ./node_modules
COPY . /app
USER node
CMD ["node", "server.js"]
```

**Result:** ~200MB image (only runtime dependencies)

**Recommendation:** Use multi-stage builds for production

---

### PID 1 Handling

Containers run the `CMD` as PID 1, which has special responsibilities:

- Reap zombie processes
- Forward signals (SIGTERM) to children

**Options:**

1. **Use tini/dumb-init** (recommended for most apps)
2. **ECS `initProcessEnabled: true`** (easiest for ECS)
3. **Application handles PID 1** (only if using Node.js, Go, Python, Java, etc.)

See [Story 4](plan/container-lifecycle.md#story-4) for details.

---

## Resource Sizing Guide

| Application Type      | Recommended Resources     | Notes                          |
| --------------------- | ------------------------- | ------------------------------ |
| **Node.js API**       | 512 CPU, 1024 MB          | Set `--max-old-space-size=768` |
| **Python API**        | 512 CPU, 1024 MB          | Workers may need more          |
| **Java API**          | 1024 CPU, 2048 MB         | Set `-Xmx1536m` for heap       |
| **Static Frontend**   | 256 CPU, 512 MB           | Nginx/served assets            |
| **Background Worker** | 256-1024 CPU, 512-2048 MB | Depends on job type            |

**Guidance:** Profile on EC2 first, then add 20-30% headroom for spikes.

---

## Multi-Architecture Benefits

| Architecture         | Use Case                          | Cost            | Performance                        |
| -------------------- | --------------------------------- | --------------- | ---------------------------------- |
| **x86_64 (amd64)**   | Standard, universal compatibility | Baseline        | Standard                           |
| **ARM64 (Graviton)** | Cost-optimized workloads          | **20% cheaper** | Equal or better for most workloads |

**Recommendation:** Build both; start with ARM64 for 20% savings, fall back to x86_64 if compatibility issues.

---

## Pre-ECS Deployment Checklist

Before deploying to ECS Fargate, verify:

- [ ] Dockerfile builds successfully (`docker build -t my-app .`)
- [ ] Container runs with only env vars (`docker run -e DB_HOST=... my-app`)
- [ ] Application binds to `0.0.0.0` (not localhost)
- [ ] SIGTERM handler works (`docker stop` exits gracefully)
- [ ] No zombie processes (24-hour run test)
- [ ] Multi-arch images built and tested (amd64 + arm64)
- [ ] docker-compose works for local development
- [ ] Container runs as non-root user
- [ ] Image size < 500MB
- [ ] Health check passes within 30 seconds
- [ ] No secrets in image (`docker history` shows nothing sensitive)
- [ ] ECR repository created (via Terraform in Phase 3)
- [ ] CI/CD pipeline builds and pushes images

---

## Troubleshooting

### Container Won't Start

- Check logs: `docker logs <container-id>`
- Verify env vars: `docker inspect <container-id> | grep -A 20 Env`
- Test locally: `docker run -it my-app /bin/sh`

### Health Checks Failing

- Test endpoint: `docker run -p 3000:3000 my-app` then `curl localhost:3000/health`
- Check startup time: Add `startPeriod: 60` in task definition

### Can't Connect to Container

- Verify binding: `docker exec <id> netstat -tlnp` (should show `0.0.0.0:3000`)
- Check port mapping: `docker ps` (ports column)

### Zombie Processes Accumulating

- Add init process: Use `tini` or set `initProcessEnabled: true` in task definition

---

## Support & Questions

For questions about this plan:

- **Docker/Container Issues**: Contact DevOps Lead
- **Application Behavior**: Contact Development Lead
- **Image Security**: Contact Security Team
- **Overall Migration**: Contact Migration Project Manager

**Next Steps:** Once containerization is complete and validated locally, proceed to [ECS Brownfield Migration Plan](../ec2-to-ecs-brownfield-migration-plan/) for Fargate deployment.
