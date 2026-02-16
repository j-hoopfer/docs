# Spot Instances (Fargate Spot)

### Goal

Reduce compute costs by up to 70% by utilizing Fargate Spot for fault-tolerant and background workloads, while maintaining high availability through capacity provider strategies.

### Context

Fargate Spot offers significant savings but comes with the risk of task interruptions. It is best suited for stateless web services and async workers where occasional restarts are acceptable.

## Current State

Fargate (On-Demand) capacity providers.

## Optimization

Fargate Spot capacity providers (approx. 70% cheaper than On-Demand).

## Why Defer

- **Complexity:** Requires the application to handle specific POSIX signals (SIGTERM) for graceful shutdown within 2 minutes.
- **Risk:** "Spot Interruptions" can cause availability dips if the application drain time is not tuned correctly.
- **Justification:** Migrate to Spot only after the application mechanics are stable on standard Fargate.
