# Phase 4: Initial Deployment

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

1.  [Activity 1: Security Verification](plan/security-verification.md)
    - **Feature 1:** Security Groups & IAM Roles
    - **Goal:** Ensure the networking and permission model is secure before deploying resources.

2.  [Activity 2: Deployment Artifacts](plan/deployment-artifacts.md)
    - **Feature 2:** ECR Repository
    - **Feature 3:** Task Definition
    - **Goal:** Prepare the container image and the blueprint for how it runs on Fargate.

3.  [Activity 3: Service Deployment](plan/service-deployment.md)
    - **Feature 3:** Target Groups
    - **Feature 4:** ECS Service
    - **Goal:** Launch the actual running containers and connect them to the internal network.

4.  [Activity 4: Traffic Routing](plan/traffic-routing.md)
    - **Feature 5:** ALB Routing & DNS
    - **Goal:** Expose the service to the internet/users via a stable URL.

5.  [Activity 5: CI/CD Pipeline](plan/cicd-pipeline.md)
    - **Feature 6:** GitHub Actions Workflow
    - **Goal:** Automate the build and deploy process to eliminate manual errors.

6.  [Activity 6: Validation & Cutover](plan/validation-cutover.md)
    - **Feature 7:** Validation Strategy
    - **Goal:** Verify health and safely switch production traffic to the new infrastructure.

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
