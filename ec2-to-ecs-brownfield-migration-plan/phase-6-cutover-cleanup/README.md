# Phase 6: Cutover & Cleanup

## Context & Themes

This phase focuses on **completing** the Strangler Fig traffic migration, then cleaning up the decommissioned legacy infrastructure. The Strangler Fig weighted-routing pattern _began_ in Phase 4, where an initial small percentage of traffic was shifted to Fargate. This phase increases the weight to 100% and decommissions the old EC2 instances once stable.

**Key Themes:**

- **Completion:** Shifting from "mostly Fargate" to "100% Fargate".
- **Validation:** Canary releases and rollback mechanisms before final cutover.
- **Cost Optimization:** Decommissioning expensive EC2 instances once they are no longer needed.
- **Clean State:** Ensuring no orphaned resources (SGs, Route 53 records, EBS volumes) are left behind.

## Prerequisites

Before starting this phase, ensure:

- [ ] Phase 5 Completed (All services deployed and auto-scaling).
- [ ] Load balancers configured for weighted routing (if applicable).
- [ ] Monitoring dashboards show healthy metrics for new services.
- [ ] Stakeholder sign-off for final cutover.

## Objectives

- Implement gradual traffic shifting using an internal Application Load Balancer (ALB).
- Execute canary releases to validate the new environment with production traffic.
- Establish quick rollback mechanisms to revert changes instantly if issues arise.
- Decommission legacy EC2 resources once the migration is confirmed stable.

## Plan Structure

### [Activity 1: Strangler Fig Migration](1-strangler-fig.md)

Detailed guide on implementing the Strangler Fig pattern, including setting up an internal traffic mixer ALB, configuring weighted routing between EC2 and Fargate, and executing the cutover strategy.

1. **Traffic Shifting**: Learn how to route a percentage of traffic to the new Fargate services.
2. **Validation**: Verify system stability and performance under load.
3. **Rollback Procedures**: Steps to revert traffic back to EC2 in case of failure.
4. **Decommissioning**: Process for retiring old EC2 instances after successful migration.
