# Phase 3: Infrastructure Setup

## Overview

This phase establishes the foundational infrastructure required to run ECS Fargate workloads. It involves importing existing resources (network, EC2, RDS) into Terraform and creating the new shared components (ALB, ECS Cluster, Security Groups).

## Activities

### [Activity 1: Import Existing Infrastructure](plan/infrastructure-import.md)

- **Goal**: Bring existing VPC, Network, and Application resources under Terraform control.
- **Why**: Enables safe, tracked changes and disaster recovery (Infrastructure as Code).

### Activity 2: Terraform State Management

- **Status**: _Skipped / Completed in Prerequisites_.
- **Goal**: Ensure remote state backend (S3 + DynamoDB) is configured.

### [Activity 3: Shared Infrastructure Setup](plan/shared-infrastructure.md)

- **Goal**: Provision proper Networking (VPC endpoints), Load Balancers (ALB), and ECS Cluster.
- **Key Feature**: **Internal ALB** for Strangler Fig migration pattern.

### [Activity 4: Security Infrastructure](plan/security-infrastructure.md)

- **Goal**: Implement defense-in-depth networking and IAM.
- **Stories**: Application Security Groups, Database Access Rules, IAM Task Roles.

### [Activity 5: Artifact Management](plan/artifact-management.md)

- **Goal**: Secure container registry (ECR).
- **Stories**: ECR creation, Lifecycle policies, Seed image pushing.

## Success Criteria

- `terraform plan` shows no changes for imported resources.
- ECS Cluster is active and providing capacity.
- ALB is responding to HTTP requests.
- ECR repositories are ready to receive images.
