# Internal HTTPS (End-to-End Encryption)

### Goal

Implement end-to-end encryption from the load balancer to the container to meet strict security and compliance requirements (e.g., PCI-DSS, HIPAA).

### Context

Currently, TLS terminates at the ALB. Traffic within the VPC (ALB → Fargate) is unencrypted HTTP. While efficient, some compliance frameworks require encryption in transit at all hops.

## Current State

TLS termination occurs at the Application Load Balancer (ALB). Traffic between the ALB and the Container (inside the private VPC) behaves as HTTP.

## Optimization

Implement TLS re-encryption from the ALB to the Container (End-to-End HTTPS).

## Why Defer

- **Complexity:** Requires managing SSL/TLS certificates inside the container image (e.g., Java Keystores, Nginx configs) and configuring the ALB to trust backend certificates.
- **Risk:** Certificate rotation management becomes significantly harder.
- **Justification:** For most non-PCI/HIPAA workloads, traffic inside a private VPC security group perimeter is considered secure enough for Day 1.
