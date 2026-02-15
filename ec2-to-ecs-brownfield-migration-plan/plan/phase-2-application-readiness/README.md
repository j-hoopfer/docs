# Phase 2: Application Readiness

## Overview

Phase 2 focuses on preparing your application for the move to ECS Fargate. This involves two main workstreams:

1.  **12-Factor App Preparation**: Ensuring the application architecture is cloud-native (stateless, config-driven, etc.).
2.  **Containerization**: Packaging the application into Docker containers that are production-ready.

## Workstreams

### [1. 12-Factor App Preparation](12-factor-prep/README.md)

- **Configuration & Secrets**: Move config to environment variables.
- **Statelessness**: Move sessions to Redis/Database.
- **Backing Services**: Ensure DB/Cache are reachable via network.
- **Network & Security**: Implement health checks and proper binding.
- **Observability**: Structure logs to stdout/stderr.

### [2. Containerizing Services](containerizing-services/README.md)

- **Docker Packaging**: ongoing creation of Dockerfiles.
- **Lifecycle Management**: Handling SIGTERM and graceful shutdowns.
- **Optimization**: Reducing image size and build times.
- **Security**: Scanning images and running as non-root.

## Success Criteria

- Application runs locally via `docker-compose`.
- Passes all 12-Factor checks.
- Docker images are built, scanned, and strictly versioned.
