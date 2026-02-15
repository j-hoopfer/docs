# Phase 6: Cutover & Cleanup

This phase focuses on the critical transition from the legacy EC2 infrastructure to the new Fargate platform. It employs the Strangler Fig pattern to ensure minimal risk and zero downtime during the migration.

## Objectives

- Implement gradual traffic shifting using an internal Application Load Balancer (ALB).
- Execute canary releases to validate the new environment with production traffic.
- Establish quick rollback mechanisms to revert changes instantly if issues arise.
- Decommission legacy EC2 resources once the migration is confirmed stable.

## Plan Structure

### [Strangler Fig Migration](./plan/strangler-fig.md)

Detailed guide on implementing the Strangler Fig pattern, including setting up an internal traffic mixer ALB, configuring weighted routing between EC2 and Fargate, and executing the cutover strategy.

1. **Traffic Shifting**: Learn how to route a percentage of traffic to the new Fargate services.
2. **Validation**: Verify system stability and performance under load.
3. **Rollback Procedures**: Steps to revert traffic back to EC2 in case of failure.
4. **Decommissioning**: Process for retiring old EC2 instances after successful migration.
