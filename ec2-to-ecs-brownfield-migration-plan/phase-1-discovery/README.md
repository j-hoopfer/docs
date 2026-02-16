# Phase 1: Discovery & Planning

## Context & Themes

This phase focuses on understanding the existing EC2 environment and mapping it to ECS Fargate requirements. It establishes the migration strategy, identifies potential risks, and ensures all stakeholders are aligned before any resources are changed.

**Key Themes:**

- **Audit & Inventory:** Documenting current state (ports, env vars, dependencies, storage).
- **Migration Strategy:** Deciding on the migration order (Strangler Fig vs Big Bang) and pattern.
- **Risk Assessment:** Identifying blocking issues early (e.g., persistent local storage dependencies).
- **Stakeholder Alignment:** Ensuring developers and ops agree on the new architecture.

## Prerequisites

Before starting this phase, ensure:

- [ ] **Phase 0 Completed:** Repositories and Terraform state are set up.
- [ ] AWS Read-only Access (to inspect current EC2 resources).
- [ ] Access to all relevant source code repositories.
- [ ] List of application owners and stakeholders.
- [ ] Documentation of the current architecture (diagrams, etc.) is accessible.

## Activities & Stories

The following activities should be completed in order:

### 1. [Story 1.1: Application Audit](1-application-audit.md)

**Goal:** Systematically review the application source code and runtime behavior to identify "Fargate Blockers" such as local file system writes, hardcoded IP addresses, or unmanaged background processes.

### 2. [Story 1.2: Infrastructure Audit](2-infrastructure-audit.md)

**Goal:** Systematically review the existing AWS environment (VPC, Security Groups, IAM) to identify network barriers and permission gaps that must be addressed before Fargate deployment can succeed.

### 3. [Story 1.3: Migration Planning](3-migration-planning.md)

**Goal:** Transform the audit findings into concrete architectural decisions (IAM policies, ECR strategy, Cutover Plan, Rollback Plan) that will guide the Phase 2 implementation.

---

**Next Step:** Once discovery is complete and risks are mitigated, proceed to [Phase 2: Application Readiness](../phase-2-application-readiness/README.md) to begin 12-Factor modifications.
