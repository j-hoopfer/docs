# Phase 5: Scaling the Migration

## Context & Themes

Phase 3/4 established the pattern for deploying ONE application. This phase focuses on repeating this success efficiently across all remaining services. It shifts focus from "proof of concept" to "scalability" through automation, reusable patterns, and operational maturity.

**Key Themes:**

- **Reusability:** Creating centralized templates (GitHub Actions, Terraform) to avoid duplication.
- **Operational Excellence:** Implementing auto-scaling and monitoring dashboards.
- **Automation:** Reducing manual steps to migrate each service quickly.

## Prerequisites

Before starting this phase, ensure:

- [ ] Phase 4 Completed (Pilot service is successfully running in production).
- [ ] Terraform installed locally/CI.
- [ ] Understanding of current service interdependencies.
- [ ] Operational requirements (Monitoring metrics) defined for production services.

## Theme: Repeatable Success & Optimization

**Objective:**
Phase 3/4 established the pattern for deploying ONE application. Now you need to repeat this for the remaining 9+ apps efficiently. This phase shifts focus from "making it work" to "making it scale" through automation, reusable patterns, and operational maturity.

**Key Deliverables:**

- A centralized, reusable CI/CD pipeline template.
- Infrastructure as Code (Terraform) managing all services.
- Auto-scaling and monitoring dashboards for production operations.

### Navigation

This phase is broken down into the following activities:

1.  [Activity 1: Reusable CI/CD Workflows](1-reusable-workflows.md)
    - **Feature 1:** Centralized Deployment Templates
    - **Goal:** Don't copy-paste `deploy.yml` 10 times. Create a shared template.

2.  [Activity 2: Infrastructure Modules & Automation](2-service-infrastructure-automation.md)
    - **Feature 2:** Terraform Service Factory
    - **Concept:** Unlike Phase 3 (Foundation), this activity builds the **Service Factory**—reusable Terraform modules to stamp out new services (Target Groups, IAM Roles, Tasks) in minutes.
    - **Goal:** Automate the repetitive creation of service-level resources.

3.  [Activity 3: Operational Excellence](3-operational-excellence.md)
    - **Feature 3:** Monitoring & Auto-Scaling
    - **Goal:** Ensure the system handles load automatically and alerts you when things break.

> **Note on Service Discovery:**
> While previously considered part of Phase 5, Service Discovery (Cloud Map) is an optional post-migration optimization. It has been moved to [Phase X: Optimizations](../phase-x-optimizations/aws-cloud-map.md).

---

### Prerequisites

- **Phase 4 Completed:** At least one service is deployed and running in production.
- **Terraform Knowledge (Optional):** If adopting Activity 2, familiarity with basic Terraform is recommended.

### Estimated Timeline

- **Workflow Templating:** 1-2 Days
- **IaC Setup:** 3-5 Days (Initial Setup), then minutes per service.
- **Service Migration:** 1-2 Days per service (using Strangler Fig).
- **Operational Hardening:** Ongoing (Iterative improvements).
