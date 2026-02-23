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

### [Activity 1: Import Existing Platform Infrastructure](1-import-platform-infrastructure.md)

- **Goal**: Bring existing VPC, Network, Databases (RDS), and Security Groups under Platform Terraform control.
- **Why**: Establishes the foundational "manufacturing plant" baseline.

### [Activity 2: Remediate Network Gaps (New!)](2-remediate-network-gaps.md)

- **Goal**: Patch the legacy network to support Fargate (Add Private Subnets, NAT Gateways, SG Rules).
- **Why**: Closes the gap between "Legacy Flat Network" and "Secure Container Network" identified in Discovery.

### [Activity 3: Import Legacy Application Workloads (Optional)](3-import-application-resources.md)

- **Goal**: Bring existing legacy compute (EC2) under Service Terraform control.
- **Why**: Treats legacy EC2 as a managed "workload" to be strangled alongside Fargate.
- **Note**: This can be skipped if you prefer to manually delete the old EC2 instances in Phase 6 rather than spending time importing them into Terraform.

### [Activity 4: Shared Infrastructure Setup](4-setup-shared-infrastructure.md)

- **Goal**: Provision the **new** components: Load Balancers (ALB) and ECS Cluster.
- **Key Features**:
  - **Shared Public ALB** for internet traffic.
  - **Internal ALB** for Strangler Fig migration pattern.
  - **Internal DNS (Route 53)** for stable service-to-service communication.

### [Activity 5: Security Infrastructure](5-security-infrastructure.md)

- **Goal**: Implement defense-in-depth networking and IAM for the future state.
- **Stories**: Fargate Task Security Groups, IAM Task Roles (distinct from Legacy EC2 roles).

### [Activity 6: Artifact Management](6-artifact-management.md)

- **Goal**: Secure container registry (ECR).
- **Stories**: ECR creation, Lifecycle policies, Seed image pushing.

## Success Criteria

- `terraform plan` shows no changes for all imported resources (Activity 1 & 3).
- **Gap Report from Phase 1 is fully resolved** (Private Subnets and NAT Gateway exist).
- ECS Cluster is active and providing Fargate capacity (Activity 4).
- Shared ALB is responding and returning 404 (no apps registered yet — expected) (Activity 4).
- ECR repositories are created and ready to receive images (Activity 6).
- IAM Task Execution Role and Task Role exist with least-privilege policies (Activity 5).
