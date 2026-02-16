# ECS Service Connect

### Goal

Utilize ECS Service Connect to simplify detailed traffic management (metrics, distributed tracing, and resilience patterns) across the service mesh without implementing a full complex mesh solution like Istio.

### Context

Standard ALB-based routing is simple but lacks fine-grained inter-service observability. Service Connect automatically injects Envoy proxies to manage this traffic transparently.

## Current State

Standard ALB-based routing.

## Optimization

Use Service Connect for service mesh-lite features (resiliency, traffic visualization) without a full Envoy sidecar setup.

## Why Defer

- **Complexity:** Adds a proxy sidecar to the task definition and changes traffic flow mechanics.
- **Status:** Explicitly listed as "Do NOT use for Strangler Fig" in `2-shared-infrastructure.md` due to compatibility complexities with external traffic routing during migration.
