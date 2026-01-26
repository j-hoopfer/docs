# Epic 1: Containerization & App Security

**Goal:** Build production-ready Docker images, reduce attack surface, and add native health checks.

**Duration:** 2–3 days

**Prerequisites:** Epic 0 complete, Docker installed, AWS CLI configured via SSO.

---

## Story 1.1: Create Base Dockerfile

As a Developer
I want to containerize the application using a standard base image
So that I can run the app consistently without "it works on my machine" issues

### Technical Requirements

- Base image: `node:22-slim` (Debian-based, lighter than full Node)
- Build from monorepo root to compile all workspace dependencies
- Use `npm ci` for deterministic installs (lockfile present)
- Expose port 3000 (application default)
- `.dockerignore` excludes `node_modules`, `.git`, `.env*`, build outputs

### Implementation Details

**Context:** We are working in the monorepo-starter sandbox and will build from the repo root.

- Create `.dockerignore`: Exclude `node_modules`, `.git`, `.env*`, build output folders.
- Base Image: Use `node:22-slim` (Debian-based, lighter than full Node, friendlier than Alpine).
- Dependencies: A root `package-lock.json` exists, so prefer `npm ci` for deterministic installs.
- Build TypeScript.
- Expose port `3000` (default in app).

> Monorepo note: The app lives in `apps/auth-api`, and depends on `@scale/core-utils`. We will build at the workspace root so both projects compile.

### Example (Base) Dockerfile

```dockerfile
# Base (single-stage) — for initial validation only
FROM node:22-slim
WORKDIR /app

# Faster layer caching
COPY package*.json ./
# Lockfile present → use npm ci for reproducible installs
RUN npm ci

# Copy source (monorepo: apps + packages)
COPY . .

# Build all referenced TS projects
RUN npm run build

ENV NODE_ENV=development
EXPOSE 3000

# Run the auth-api
CMD ["node", "apps/auth-api/dist/main.js"]
```

### .dockerignore (Recommended)

```gitignore
# dependencies
node_modules

# vcs
.git

# env & secrets
.env
.env.*

# build outputs
**/dist
**/.tsbuildinfo

# misc
.DS_Store
npm-debug.log*
yarn-debug.log*
yarn-error.log*
```

### Acceptance Criteria

- [ ] Dockerfile exists in project root.
- [ ] `.dockerignore` excludes `node_modules` and `.git`.
- [ ] `docker build -t my-app:base .` succeeds.
- [ ] `docker run -p 3000:3000 my-app:base` starts app.
- [ ] `curl http://localhost:3000/health` returns `200 OK`.
- [ ] Verification: First line of build output shows small context (< 5MB).

---

## Story 1.2: Optimize w/ Multi-Stage Build

As a DevOps Engineer
I want to refactor the Dockerfile to use multi-stage builds
So that the final image excludes compilers and source code

### Technical Requirements

- Two-stage build: Builder (install + compile) and Runner (runtime only)
- Builder stage: Install all deps, build TypeScript, prune devDependencies
- Runner stage: Copy pruned `node_modules` and `dist` from builder
- Final image excludes TypeScript compiler and source files
- Target 50%+ size reduction vs single-stage

### Implementation Details (The "Prune Pattern")

- Stage 1 (Builder): Install all dependencies, build the app, then run `npm prune --production` to remove devDependencies (like TypeScript).
- Stage 2 (Runner): Copy the already pruned `node_modules` and the `dist` folder from Builder.

Why? This solves the "Monorepo workspace linking" issue where `npm install` in the runner can fail to resolve local packages.

### Example (Multi-Stage) Dockerfile

```dockerfile
# Stage 1: Builder
FROM node:22-slim AS builder
WORKDIR /app

# Install root/workspace deps
COPY package*.json ./
RUN npm ci

# Copy source (limit to relevant dirs for smaller context)
COPY apps/auth-api ./apps/auth-api
COPY packages/core-utils ./packages/core-utils
COPY tsconfig*.json ./

# Build all (composite projects)
RUN npm run build

# Stage 2: Runner
FROM node:22-slim AS runner
WORKDIR /app
ENV NODE_ENV=production


# Bring compiled outputs and manifests for runtime packages
COPY --from=builder /app/apps/auth-api/dist ./apps/auth-api/dist
COPY --from=builder /app/apps/auth-api/package.json ./apps/auth-api/package.json
COPY --from=builder /app/packages/core-utils/dist ./packages/core-utils/dist
COPY --from=builder /app/packages/core-utils/package.json ./packages/core-utils/package.json

# Copy the PRUNED node_modules (contains only prod deps)
COPY --from=builder /app/node_modules ./node_modules

# (Final image contains only runtime artifacts and pruned dependencies)

EXPOSE 3000
CMD ["node", "apps/auth-api/dist/main.js"]
```

### Acceptance Criteria

- [ ] Dockerfile uses `FROM ... AS builder` and second `FROM ...` runner.
- [ ] Final image size is < 200MB (`docker images`).
- [ ] No `*.ts` files in final image (`find` returns 0).
- [ ] `typescript` compiler not present in runtime `node_modules`.
- [ ] App starts successfully.

### Verification

```bash
# Build and check size
docker build -t my-app:optimized .
docker images | grep my-app

# Check for TS files (should be 0)
docker run --rm my-app:optimized sh -lc 'find . -name "*.ts" | wc -l'

# Run the app
docker run --rm -p 3000:3000 my-app:optimized
curl http://localhost:3000/health
```

---

## Story 1.3: Non-Root User Security

As a Security Engineer
I want to run the container as a non-privileged user
So that I limit the blast radius of a potential compromise

### Technical Requirements

- Create system user/group `appuser` (non-root, no login shell)
- Application runs as UID > 1000 (not root/0)
- All app directories owned by `appuser`
- App listens on port > 1024 (port 3000)
- Container USER directive set to `appuser` before CMD

### Implementation Details

- Create system user/group `appuser` in the Dockerfile.
- `chown` application directories to `appuser`.
- Add `USER appuser` before `CMD`.
- Ensure the app listens on a port > 1024 (`3000` by default).

### Example (User + Permissions)

```dockerfile
# Add to the runner stage
RUN groupadd -r appuser && useradd -r -g appuser appuser
RUN mkdir -p /app && chown -R appuser:appuser /app
USER appuser
```

### Acceptance Criteria

- [ ] Dockerfile creates system user `appuser`.
- [ ] `USER appuser` directive present before `CMD`.
- [ ] Container runs successfully and serves health endpoint.
- [ ] `docker exec <cid> whoami` returns `appuser`.

### Verification

```bash
docker build -t my-app:secure .
docker run -d --name test-secure -p 3000:3000 my-app:secure
docker exec test-secure whoami  # must print: appuser
```

---

## Story 1.4: Native Health Check

As a DevOps Engineer
I want a container-native health check
So that ECS can automatically replace hung containers

### Technical Requirements

- HEALTHCHECK instruction in Dockerfile
- Interval: 30s, Timeout: 5s, Start period: 5s, Retries: 3
- Check hits `/health` endpoint on port 3000
- Uses Node.js built-in `http` module (no external dependencies)
- Returns exit code 0 (healthy) or 1 (unhealthy)

### Implementation Details

- Add `HEALTHCHECK` instruction.
- Use built-in Node `http` client (no `curl` dependency on slim image).

### Example (Node-based HEALTHCHECK)

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD node -e "require('http').get('http://localhost:3000/health', (r) => {if (r.statusCode !== 200) process.exit(1); else process.exit(0);});" || exit 1
```

### Acceptance Criteria

- [ ] `HEALTHCHECK` instruction present.
- [ ] Check uses native Node (no `curl`).
- [ ] `docker inspect --format='{{.State.Health.Status}}' <cid>` returns `healthy` after startup.

---

## Story 1.5: Read-Only Root Filesystem (Hardening)

As a Security Engineer
I want the container's root filesystem to be read-only
So that attackers cannot establish persistence

### Technical Requirements

- Root filesystem mounted read-only at runtime
- Writable tmpfs volume for `/tmp` (application temp files)
- No write permissions to `/app` or system directories at runtime
- Application must not write logs/state to disk (use stdout/CloudWatch)
- Tested with `docker run --read-only --tmpfs /tmp`

### Implementation Details

- Identify writable needs (e.g., `/tmp` or log paths).
- Declare `VOLUME ["/tmp"]` or create tmpfs at run.
- Test with `--read-only` and mount tmpfs for `/tmp`.

### Example (Run with Read-Only Root)

```dockerfile
# Optional in Dockerfile (documents writable path)
VOLUME ["/tmp"]
```

```bash
# Build
docker build -t my-app:hardened .

# Run with Read-Only Root + Writable /tmp
docker run --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  -p 3000:3000 \
  my-app:hardened

# 1) Test App Health
curl http://localhost:3000/health

# 2) Test Write Block (Should Fail)
CID=$(docker ps -q --filter ancestor=my-app:hardened)
docker exec "$CID" sh -lc 'touch /app/malware.sh'  # expect: Read-only file system

# 3) Test Valid Write (Should Succeed)
docker exec "$CID" sh -lc 'touch /tmp/valid-temp-file'
```

### Acceptance Criteria

- [ ] Dockerfile defines writable path (VOLUME `/tmp`) or documented tmpfs mount.
- [ ] App runs with `docker run --read-only --tmpfs /tmp ...`.
- [ ] `touch /root/hacked.txt` fails inside container; `/tmp` writes succeed.

---

## ✅ Epic 1 Definition of Done

- **Image:** Multi-stage, < 200MB, contains no source code (`*.ts`).
- **Security:** Runs as non-root (`appuser`), Read-only filesystem supported and verified.
- **Observability:** Native `HEALTHCHECK` implemented.
- **Local Test:** Validated with `docker run --read-only` and `/health` passes.

> Compatibility note: The repo currently includes a multi-stage Dockerfile. Align ports (`3000`) and entrypoint (`apps/auth-api/dist/main.js`) during optimization, or set `PORT=8001` if keeping existing healthcheck/EXPOSE.
