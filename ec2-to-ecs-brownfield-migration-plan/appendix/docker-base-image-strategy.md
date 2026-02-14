# Appendix: Docker Base Image Strategy (Golden Images)

## Overview

This appendix explains the base image (golden image) pattern, when to use it, and how to implement it for enterprise container environments.

**Use this appendix when:**

- Deciding whether to create custom base images
- Understanding the tradeoffs of base images
- Planning base image maintenance strategy
- Implementing enterprise container standards
- Considering security hardening requirements

---

## Table of Contents

1. [Is it a Best Practice?](#is-it-a-best-practice)
2. [Recommendation for Brownfield Migration](#recommendation-for-brownfield-migration)
3. [When Base Images Are Critical](#when-base-images-are-critical)
4. [How to Implement Custom Base Images](#how-to-implement-custom-base-images)
5. [Maintenance Strategy](#maintenance-strategy)
6. [When to Use Base Images (Decision Matrix)](#when-to-use-base-images-decision-matrix)
7. [Alternatives to Base Images](#alternatives-to-base-images)

---

## Is it a Best Practice?

**Yes, for established enterprises.**  
**No, for early-stage migrations (usually).**

### Common Pattern

```
Your Base Image (mycompany/node-base:20)
  ├── Node.js 20
  ├── Common npm packages
  ├── Security scanning tools
  ├── Monitoring agents (DataDog, New Relic)
  └── Standard hardening

Your App Images
  ├── app1:latest → FROM mycompany/node-base:20
  ├── app2:latest → FROM mycompany/node-base:20
  └── app3:latest → FROM mycompany/node-base:20
```

### Pros vs Cons

| **Pros (Why do it?)**                                              | **Cons (Why avoid it?)**                                                             |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------ |
| **Security Governance:** Ensure every container has latest patches | **Maintenance Burden:** You own an OS distribution - must patch weekly               |
| **Build Speed:** Install heavy tools once, reuse across apps       | **Coupling:** Break base image = break ALL applications                              |
| **Standardization:** Forces same Node version and OS config        | **"It works on my machine":** Developers use standard Node locally, base image in CI |
| **Compliance:** Embed required security agents in one place        | **Versioning Complexity:** Must manage base image versions carefully                 |
| **Faster builds:** Common layers cached, only rebuild app code     | **Slower initial setup:** Must build base before apps                                |
| **Consistency:** All apps use same dependencies                    | **Extra complexity:** One more thing to maintain and version                         |

---

## Recommendation for Brownfield Migration

**The Golden Rule:** Base images are a **scaling optimization**, not a starting point. Ship working containers first, optimize later.

### Migration Timeline

```
Phase 1-2: Use node:20-alpine (get to Fargate fast)
  ├── Focus: Containerization & initial deployment
  └── Goal: Working containers in production

Phase 3: Stabilize & Monitor
  ├── Focus: Observability, performance tuning
  └── Goal: Reliable production workloads

Phase 4+: Introduce Base Images (if needed)
  ├── Focus: Standardization & security hardening
  └── Goal: Enterprise-grade container governance
```

**Don't do this for initial containerization (Phase 1-2).**  
Stick to standard multi-stage builds (e.g., `FROM node:20-alpine`).

**Move this to Phase 4+ (Optimization & Hardening).**  
Once you have 2+ services running in production and security team demands specific hardening.

---

## When Base Images Are Critical

Only prioritize base images **before migration** if:

- ✅ Security/compliance requires pre-approved hardened images
- ✅ Corporate policy forbids pulling from Docker Hub
- ✅ You need embedded agents (vulnerability scanning, SIEM integration)
- ✅ Air-gapped environment (must use internal registry)

Otherwise, **containerize first with standard images**, then optimize with base images once you have working Fargate deployments.

---

## How to Implement Custom Base Images

### Step 1: Create Repository for Base Image

**Directory structure:**

```
infrastructure/base-images/
├── node-20/
│   ├── Dockerfile
│   └── README.md
├── python-311/
│   ├── Dockerfile
│   └── README.md
└── .github/
    └── workflows/
        └── build-base-images.yml
```

**Example Dockerfile:**

```dockerfile
# infrastructure/base-images/node-20/Dockerfile
FROM node:20-alpine

# 1. OS Updates & Security Patches
RUN apk update && apk upgrade --no-cache

# 2. Install global dependencies required by ALL apps
RUN apk add --no-cache \
    tini \
    curl \
    ca-certificates

# 3. Create non-root user (standardize across all apps)
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

# 4. Set global defaults
WORKDIR /app
RUN chown appuser:appgroup /app

# Use tini as init process
ENTRYPOINT ["/sbin/tini", "--"]

# Metadata
LABEL maintainer="devops@company.com"
LABEL org.opencontainers.image.description="Node.js 20 base image with security hardening"
```

### Step 2: Build & Push to ECR

**Tagging Strategy:**

- **Do NOT just use `latest`**
- Use Semantic Versioning: `v1.0.0`, `v1.0.1`, `v1.1.0`
- Include date for traceability: `v1.0.1-20260127`
- Tag both specific version AND latest: `v1.0.1` + `latest`

**GitHub Actions workflow:**

```yaml
name: Build Base Images

on:
  push:
    branches: [main]
    paths:
      - "node-20/**"
  schedule:
    - cron: "0 2 * * 1" # Weekly on Monday at 2 AM UTC
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

jobs:
  build-node-base:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: us-east-1

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Generate version tag
        id: version
        run: |
          VERSION="v1.0.0"
          DATE=$(date +%Y%m%d)
          echo "tag=${VERSION}-${DATE}" >> $GITHUB_OUTPUT
          echo "version=${VERSION}" >> $GITHUB_OUTPUT

      - name: Build and push Node.js base image
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          ECR_REPOSITORY: base-images/node-20
          IMAGE_TAG: ${{ steps.version.outputs.tag }}
          VERSION_TAG: ${{ steps.version.outputs.version }}
        run: |
          docker build \
            -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG \
            -t $ECR_REGISTRY/$ECR_REPOSITORY:$VERSION_TAG \
            -t $ECR_REGISTRY/$ECR_REPOSITORY:latest \
            ./node-20/

          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$VERSION_TAG
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:latest
```

### Step 3: Update Application Dockerfiles

**Before (using public image):**

```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production
COPY . .
USER node
CMD ["node", "src/server.js"]
```

**After (using golden image):**

```dockerfile
# --- Builder Stage (Still uses public image) ---
FROM node:20-alpine AS builder
WORKDIR /build
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# --- Runner Stage (Uses YOUR Golden Image) ---
ARG BASE_IMAGE_VERSION=v1.0.0
FROM 123456789012.dkr.ecr.us-east-1.amazonaws.com/base-images/node-20:${BASE_IMAGE_VERSION}

WORKDIR /app

# User 'appuser' already exists from base image
COPY --from=builder --chown=appuser:appgroup /build/dist ./dist
COPY --from=builder --chown=appuser:appgroup /build/node_modules ./node_modules

USER appuser
CMD ["node", "dist/index.js"]
```

### Critical: IAM Permissions for Private Base Images

**Task Execution Role must have permission to pull from base image repository:**

```hcl
resource "aws_iam_role_policy" "ecr_pull_permissions" {
  name = "ecr-pull-permissions"
  role = aws_iam_role.ecs_task_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = [
          aws_ecr_repository.auth_service.arn,
          aws_ecr_repository.base_image_node.arn  # Don't forget this!
        ]
      }
    ]
  })
}
```

**Common mistake:** Forgetting to grant ECR permissions for base image repository → `CannotPullContainerError`

---

## Maintenance Strategy

### Weekly Security Patching

```bash
# Automated weekly rebuild (via GitHub Actions schedule)
# Picks up latest Alpine security patches
# Triggers rebuild of all application images
```

### Version Upgrade Path

1. **Base image update released:** `v1.0.0` → `v1.1.0`
2. **Test in dev:** Update one service's Dockerfile to use `v1.1.0`
3. **Validate compatibility:** Run integration tests
4. **Gradual rollout:** Update other services one-by-one
5. **Deprecate old:** After 30 days, remove `v1.0.0` tag

### Breaking Changes

```
v1.x.x → v2.0.0 (major version bump)
  ├── Maintain v1.x.x for 90 days (security patches only)
  ├── Communicate breaking changes to all teams
  └── Provide migration guide
```

---

## When to Use Base Images (Decision Matrix)

| **Scenario**                            | **Use Base Image?** | **Rationale**                             |
| --------------------------------------- | ------------------- | ----------------------------------------- |
| Single application, first migration     | ❌ No               | Unnecessary complexity                    |
| 2-3 applications, similar tech stack    | ⚠️ Maybe            | Consider if security requirements mandate |
| 5+ applications, standardization needed | ✅ Yes              | Economies of scale kick in                |
| Security/compliance requires hardening  | ✅ Yes              | Embed security controls once              |
| Air-gapped environment                  | ✅ Yes              | Cannot pull from Docker Hub               |
| Developer velocity is priority          | ❌ No               | Standard images faster to iterate         |
| Production stability is priority        | ✅ Yes              | Control the entire stack                  |

---

## Alternatives to Base Images

### 1. Copy-Paste Pattern (Low-Tech)

Keep a `Dockerfile.template` with security hardening. Copy-paste into each service.

**Pros:** No dependencies, easy to customize per service  
**Cons:** No consistency enforcement, harder to patch

### 2. Multi-Stage Builds with Shared Stage

```dockerfile
# Common base stage (repeated in each Dockerfile)
FROM node:20-alpine AS hardened-base
RUN apk update && apk upgrade --no-cache
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

# Application stage
FROM hardened-base
COPY --chown=appuser:appgroup . /app
USER appuser
CMD ["node", "server.js"]
```

**Pros:** No external dependencies, still get layer caching  
**Cons:** Repeated code, harder to enforce standards

---

## Real-World Migration Path

**Week 1-4:** Use standard images

```dockerfile
FROM node:20-alpine
# ... application code
```

**Week 5-8:** Add hardening inline (multi-stage)

```dockerfile
FROM node:20-alpine AS base
RUN apk update && apk upgrade
RUN adduser -D appuser

FROM base
COPY --chown=appuser . /app
USER appuser
CMD ["node", "server.js"]
```

**Week 9+:** Extract to base image (if 3+ services)

```dockerfile
FROM 123456789012.dkr.ecr.us-east-1.amazonaws.com/base-images/node-20:v1.0.0
COPY --chown=appuser . /app
USER appuser
CMD ["node", "server.js"]
```

---

## Summary for Migration Roadmap

- **Phase 1-2 (Containerization):** **Skip base images.** Use `FROM node:20-alpine`. Faster, one less dependency.
- **Phase 3 (Stabilization):** Monitor if you're copy-pasting complex security setups.
- **Phase 4+ (Optimization):** Introduce base images _if_ 3+ services and security requirements justify overhead.

**Bottom line:** Base images are a best practice for production at scale, but they're an optimization, not a requirement. Get apps containerized and running in Fargate first, then introduce base images as a refinement.

---

## Related Documentation

- See [ecs-deployment-fundamentals.md](ecs-deployment-fundamentals.md) for understanding container deployment
- See [github-actions-cicd.md](github-actions-cicd.md) for building and pushing images
- See [aws-authentication-and-security.md](aws-authentication-and-security.md) for ECR IAM permissions
