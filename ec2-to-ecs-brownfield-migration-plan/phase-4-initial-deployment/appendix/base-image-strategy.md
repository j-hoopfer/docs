# Base Image Strategy (Golden Images)

## Overview

The choice of Docker base image significantly impacts security, size, and build speed.

---

## 1. Hierarchy of Base Images

We recommend a 3-tier strategy:

1. **Vendor Base (Tier 0):** `ubuntu:22.04`, `node:18-alpine`, `python:3.11-slim`.
   - Owned by: Maintainer (Canonical/Docker).
   - Change Freq: Rarely.

2. **Company Base (Tier 1):** `my-company/python-base:v1.0.0`.
   - Adds: Internal CA certs, monitoring agents (Datadog/NewRelic), common tools (`curl`, `jq`), security patches.
   - Owned by: Platform Team.
   - Change Freq: Monthly (patch Tuesday).

3. **Application Image (Tier 2):** `my-company/auth-api:v1.0.0`.
   - Adds: Application code (`pip install`, `npm install`).
   - Owned by: App Team.
   - Change Freq: Daily (deployments).

---

## 2. Choosing the Right Vendor Base

| Image Type     | Example                               | Size (approx) | Use Case                        | Pros                          | Cons                                                        |
| :------------- | :------------------------------------ | :------------ | :------------------------------ | :---------------------------- | :---------------------------------------------------------- |
| **Full OS**    | `ubuntu`, `debian`                    | 100MB+        | Legacy apps needing system libs | Easy debugging, lots of tools | Large attack surface, many CVEs                             |
| **Slim**       | `python:3.9-slim`, `node:18-slim`     | 40-60MB       | Most modern apps                | Smaller, fewer CVEs           | Missing some compile tools                                  |
| **Alpine**     | `python:3.9-alpine`, `node:18-alpine` | 5-10MB        | High performance apps           | Tiny, secure                  | Uses `musl` libc (can break C extensions like numpy/pandas) |
| **Distroless** | `gcr.io/distroless/python3`           | 20MB          | Security-critical apps          | No shell, very secure         | Hard to debug (cannot `exec` in)                            |

**Recommendation:**

- Start with `slim` variants (Debian-based).
- Use `alpine` only if you verify dependencies work.
- Use `distroless` for mature production services.

---

## 3. Automating Base Image Updates

**Problem:** Application teams rarely update `FROM python:3.9`.
**Solution:** Automated PRs.

**Workflow:**

1. Use **Renovate** or **Dependabot**.
2. Configure to watch `Dockerfile`.
3. When `python:3.9.18` is released, bot opens PR bumping from `3.9.17`.
4. Tests run -> Auto-merge if green -> Deploy.

**Example Renovate Config:**

```json
{
  "extends": ["config:base"],
  "docker": {
    "enabled": true,
    "pinDigests": true
  }
}
```

---

## 4. Caching Strategy for Builds

Slow builds kill developer velocity.

**Layer Ordering:**
Put stable things first, volatile things last.

```dockerfile
# BAD
COPY . .
RUN pip install -r requirements.txt

# GOOD (Layers cached until requirements.txt changes)
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .
```

**Docker BuildKit:**
Enable BuildKit for parallelism and cache mounts.
`DOCKER_BUILDKIT=1 docker build ...`

**Registry Cache:**
Use `--cache-from` in CI/CD to pull previous layers.
