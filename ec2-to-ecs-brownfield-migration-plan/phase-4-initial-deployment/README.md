# Phase 4: Initial Deployment

## Context & Themes

This phase focuses on deploying the first "pathfinder" service to the new infrastructure. It validates the end-to-end pipeline from commit to container running on Fargate, proving the migration path works before migrating critical services.

**Key Themes:**

- **Observability:** Ensuring logs and detailed monitoring are available to verify health.
- **Repeatability:** Establishing the CI/CD pattern (GitHub Actions) for future services.
- **Confidence:** Using a low-impact service to validate the architecture with minimal risk.
- **Security Verification:** Confirming IAM roles and Security Groups are correctly scoped.

## Prerequisites

Before starting this phase, ensure:

- [ ] Phase 3 Completed (ECS Cluster, ALB, ECR, and Security Infrastructure are live).
- [ ] Dockerfile created and tested locally for the pilot service.
- [ ] ECR Repository created (via Phase 3 Activity 6: Artifact Management).
- [ ] GitHub Actions secrets configured for AWS OIDC or access keys.

> **Note on VPC Endpoints:** VPC Interface Endpoints (for ECR, Secrets Manager, CloudWatch) are a Day 2 optimization deferred to Phase X. Fargate tasks in private subnets will use the NAT Gateway for AWS service traffic in this phase.

## Theme: Deploying the First Production Service

**Objective:**
Take one low-risk service (like the "Notification Service" or "Internal Admin Tool") and deploy it to the new ECS Fargate infrastructure. This proves the entire pipeline from code commit to running container is functional before migrating critical path services.

**Key Deliverables:**

- A Dockerized application running in Fargate.
- A functional CI/CD pipeline (GitHub Actions) deploying to ECS.
- The application is accessible via a Load Balancer (ALB).
- Production traffic is successfully handled.

### Navigation

This phase is broken down into the following activities:

1.  **[Activity 1: Deployment Artifacts (ECR & Images)](1-deployment-artifacts.md)**
    - **Goal:** Create the ECR repository and push the first Docker image manually.

2.  **[Activity 2: Service Deployment (ECS)](2-service-deployment.md)**
    - **Goal:** Deploy the ECS Task Definition, Service, and Target Group (Terraform).

3.  **[Activity 3: Traffic Routing (Strangler Fig)](3-traffic-routing.md)**
    - **Goal:** Configure ALB Listener Rules to route test traffic to Fargate.

4.  **[Activity 4: Validation & Cutover](4-validation-cutover.md)**
    - **Goal:** Verify functional parity and increase traffic weight.

5.  **[Activity 5: CI/CD Pipeline](5-cicd-pipeline.md)**
    - **Goal:** Automate the build and deploy process (GitHub Actions).

6.  **[Activity 6: Security Verification](6-security-verification.md)**
    - **Goal:** Audit Security Groups and IAM roles before full production load.

---

### Prerequisites

- **Phase 3 Completed:** The VPC, ECS Cluster, and ALB should already be provisioned.
- **Dockerized App:** You have a `Dockerfile` for the application you are migrating.
- **GitHub Repo:** You have admin access to the repository to add secrets/OIDC permissions.

### Estimated Timeline

- **Setup Artifacts (ECR/Task Def):** 1-2 Hours
- **Deploy Service:** 1 Hour
- **Configure Pipeline:** 2-3 Hours
- **Routing & Validation:** 1-2 Hours
- **Total:** ~1 Day for the first service. (Subsequent services will be much faster).
