# Phase 3: Infrastructure Setup

## Context & Themes

This phase focuses on establishing the foundational infrastructure required to run ECS Fargate workloads. It transitions from planning to concrete infrastructure implementation using Terraform, ensuring a secure and scalable base for all future services.

**Key Themes:**

- **Infrastructure as Code (IaC):** All resources managed via Terraform for reproducibility and disaster recovery.
- **Security First:** Implementing least privilege networking (Security Groups) and IAM roles from day one.
- **Shared Services:** Establishing common resources (ALB, ECS Cluster) to be used by all migrated services.
- **Foundation vs. Factory:** This phase builds the shared "Data Center" (VPC, Cluster). Phase 5 will build the "Factory" (Modules) to deploy apps into it.
- **Contract of Infrastructure:** Platform outputs (VPC IDs, ALBs) are the "API" for services. See [Infrastructure Contract Appendix](appendix/infrastructure-contract-and-breaking-changes.md).
- **Hybrid Networking:** Ensuring connectivity between new Fargate tasks and legacy EC2 instances during the transition.

## Prerequisites

Before starting this phase, ensure:

- [ ] Phase 2 ("Application Readiness") items are essentially ready (Dockerfiles drafted).
- [ ] Terraform installed and authenticated with AWS (local or CI/CD).
- [ ] **IaC Linting tools (TFLint, Checkov) configured in repository.**
- [ ] AWS Administrator access for creating IAM roles, VPC resources, and Load Balancers.
- [ ] Terraform State bucket and DynamoDB table created (from [Terraform State Bootstrap](../../terraform-state-bootstrap-plan/3-bootstrap-dev.md)).
- [ ] **Repository structures with backend.tf files created** (from [Phase 0, Platform Setup](../phase-0-prerequisites/1-platform-repository-setup.md) and [Services Setup](../phase-0-prerequisites/2-services-repository-setup.md)).

**Note:** The backend configuration (`backend.tf`) in each layer should already exist from Phase 0. You will add the infrastructure code (`main.tf`, `variables.tf`, etc.) in this phase.

## Overview

This phase establishes the foundational infrastructure required to run ECS Fargate workloads. It involves importing existing resources (network, EC2, RDS) into Terraform and creating the new shared components (ALB, ECS Cluster, Security Groups).

## Activities

### [Activity 1: Import Existing Network Infrastructure](1-import-existing-infrastructure.md)

- **Goal**: Bring existing VPC and Network resources under Terraform control.
- **Why**: Enables safe, tracked changes and disaster recovery (Infrastructure as Code).

### [Activity 2: Import Application Resources](2-import-application-resources.md)

- **Goal**: Bring existing compute (EC2) and database (RDS) resources under Terraform control.
- **Why**: Allows managing legacy and new infrastructure in the same codebase.

### [Activity 3: Shared Infrastructure Setup](3-setup-shared-infrastructure.md)

- **Goal**: Provision proper Networking (VPC endpoints), Load Balancers (ALB), and ECS Cluster.
- **Key Features**:
  - **Internal ALB** for Strangler Fig migration pattern.
  - **Internal DNS (Route 53)** for stable service-to-service communication.

### [Activity 4: Security Infrastructure](4-security-infrastructure.md)

- **Goal**: Implement defense-in-depth networking and IAM.
- **Stories**: Application Security Groups, Database Access Rules, IAM Task Roles.

### [Activity 5: Artifact Management](5-artifact-management.md)

- **Goal**: Secure container registry (ECR).
- **Stories**: ECR creation, Lifecycle policies, Seed image pushing.

## Success Criteria

- `terraform plan` shows no changes for imported resources.
- ECS Cluster is active and providing capacity.
- ALB is responding to HTTP requests.
- ECR repositories are ready to receive images.
