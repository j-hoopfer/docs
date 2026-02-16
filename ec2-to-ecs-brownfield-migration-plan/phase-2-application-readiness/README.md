# Phase 2: Application Readiness

## Overview

Phase 2 focuses on preparing your application for the move to ECS Fargate. This involves two main workstreams:

1.  **12-Factor App Preparation**: Ensuring the application architecture is cloud-native (stateless, config-driven, etc.).
2.  **Containerization**: Packaging the application into Docker containers that are production-ready.

## Workstreams

The work in this phase is divided into two sequential workstreams:

### [1. 12-Factor App Preparation](12-factor-prep/README.md)

Before you even write a Dockerfile, you must decouple your application from the server it runs on.

- **[1. Configuration & Secrets](12-factor-prep/1-configuration-and-secrets.md):** Move config to environment variables.
- **[2. Stateless Application](12-factor-prep/2-stateless-application.md):** Move sessions to Redis/Database.
- **[3. Observability](12-factor-prep/3-observability.md):** Structure logs to stdout/stderr.
- **[4. Backing Services](12-factor-prep/4-backing-services.md):** Ensure DB/Cache are reachable via network.
- **[5. Network & Security](12-factor-prep/5-network-and-security.md):** Implement health checks and proper binding.

### [2. Containerizing Services](containerizing-services/README.md)

Once the application logic is cloud-native, you package it into a container.

- **[1. Dockerfile Basics](containerizing-services/1-dockerfile-basics.md):** Create the initial Dockerfile.
- **[2. Local Development](containerizing-services/2-local-development.md):** Validate it works with `docker-compose`.
- **[3. Container Lifecycle](containerizing-services/3-container-lifecycle.md):** Handle SIGTERM and graceful shutdowns.
- **[4. Optimization](containerizing-services/4-optimization.md):** Reduce image size and build times.
- **[5. Container Security](containerizing-services/5-container-security.md):** Runs as non-root, scan for CVEs.

## Success Criteria

- Application runs locally via `docker-compose`.
- Passes all 12-Factor checks.
- Docker images are built, scanned, and strictly versioned.
