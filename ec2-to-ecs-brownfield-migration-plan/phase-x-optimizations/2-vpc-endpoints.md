# VPC Endpoints (Interface Endpoints) for ECR/S3

### Goal

Eliminate NAT Gateway data processing charges for AWS service traffic (like image pulls and S3 uploads) and improve security by keeping traffic entirely within the AWS network.

### Context

Outbound requests to AWS services currently traverse the NAT Gateway, incurring costs ($0.045/GB). VPC Endpoints allow direct, private connectivity to these services, bypassing the public internet path.

## Current State

Outbound requests to AWS services (pulling images from ECR, accessing S3) traverse a NAT Gateway.

## Optimization

Use AWS PrivateLink (Interface Endpoints) to keep traffic entirely on the AWS backbone, bypassing the NAT Gateway.

## Why Defer

- **Complexity:** Requires precise VPC Endpoint Policy configuration. A misconfiguration leads to obscure "Image Pull Errors" or S3 timeouts that are hard to debug.
- **Value:** Saves significant NAT Gateway data processing costs ($$$).
- **Justification:** NAT Gateway just works for Day 1. We should optimize for cost (endpoints) only after connectivity is proven.

---

## Feature 2: VPC Endpoints (Optional Cost Optimization)

### Story 2.1: Plan VPC Endpoints

- **Title:** Evaluate VPC Endpoints to Reduce NAT Gateway Costs
- **Persona:** As a **cloud architect**, I need to understand VPC Endpoint options so that I can reduce data transfer costs and avoid NAT Gateway dependency for AWS service traffic.

- **Requirements:**
  - Identify AWS services the application will call
  - Evaluate cost/benefit of VPC Endpoints vs NAT Gateway
  - Document decision for implementation phase
- **Implementation Details:**
  - **Critical: S3 Gateway Endpoint is FREE and prevents massive NAT costs:**
    - ECR Docker image layers are stored in S3
    - Without S3 Gateway Endpoint, image pulls route through NAT Gateway
    - Large images pulling through NAT can cost $10-50+/month per service
    - S3 Gateway Endpoint has **zero** endpoint cost and **zero** data processing cost
    - **Always create S3 Gateway Endpoint, even if you choose NAT Gateway for other traffic**
  - **Required for Fargate without NAT:**
    - `com.amazonaws.<region>.ecr.api` (ECR API calls)
    - `com.amazonaws.<region>.ecr.dkr` (Docker image pulls)
    - `com.amazonaws.<region>.s3` (ECR stores layers in S3) - Gateway endpoint, free
    - `com.amazonaws.<region>.logs` (CloudWatch Logs)
  - **Commonly needed:**
    - `com.amazonaws.<region>.secretsmanager` (if using Secrets Manager)
    - `com.amazonaws.<region>.ssm` (if using SSM Parameter Store)
  - **Cost comparison:**
    - NAT Gateway: $32/month + $0.045/GB processed
    - Interface Endpoint: ~$7.30/month per endpoint per AZ + $0.01/GB processed
    - For low-traffic apps, VPC Endpoints may be cheaper; for high-traffic, NAT may be simpler

- **Acceptance Criteria:**
  - ✅ List of required AWS services documented
  - ✅ Cost comparison completed for your expected traffic
  - ✅ Decision documented: NAT Gateway vs VPC Endpoints vs hybrid approach
