# Phase 5: Scaling the Migration

## Theme: Repeatable Success & Optimization

**Objective:**
Phase 3/4 established the pattern for deploying ONE application. Now you need to repeat this for the remaining 9+ apps efficiently. This phase shifts focus from "making it work" to "making it scale" through automation, reusable patterns, and operational maturity.

**Key Deliverables:**

- A centralized, reusable CI/CD pipeline template.
- Infrastructure as Code (Terraform) managing all services.
- Auto-scaling and monitoring dashboards for production operations.

### Navigation

This phase is broken down into the following activities:

1.  [Activity 1: Reusable CI/CD Workflows](plan/reusable-workflows.md)
    - **Feature 1:** Centralized Deployment Templates
    - **Goal:** Don't copy-paste `deploy.yml` 10 times. Create a shared template.

2.  [Activity 2: Infrastructure as Code](plan/infrastructure-setup.md)
    - **Feature 2:** Terraform Modules
    - **Goal:** Automate the creation of Target Groups, ECS Services, and IAM roles.

3.  [Activity 3: Service Discovery](plan/service-discovery.md)
    - **Feature 3:** Internal Service Communication (Optimization)
    - **Goal:** Enable direct service-to-service calls via internal DNS (Cloud Map), removing the ALB hop.

4.  [Activity 4: Operational Excellence](plan/operational-excellence.md)
    - **Feature 4:** Monitoring & Auto-Scaling
    - **Goal:** Ensure the system handles load automatically and alerts you when things break.

---

### Prerequisites

- **Phase 4 Completed:** At least one service is deployed and running in production.
- **Terraform Knowledge (Optional):** If adopting Activity 2, familiarity with basic Terraform is recommended.

### Estimated Timeline

- **Workflow Templating:** 1-2 Days
- **IaC Setup:** 3-5 Days (Initial Setup), then minutes per service.
- **Service Migration:** 1-2 Days per service (using Strangler Fig).
- **Operational Hardening:** Ongoing (Iterative improvements).
