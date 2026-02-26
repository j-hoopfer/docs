# Appendix: Reusing EC2 Security Groups for Fargate

**Related Story:** [Story 5.1: Create Application Security Groups](../5-security-infra.md#story-51-create-application-security-groups)

## Can I Use the Same Security Groups for ECS That I Have for EC2?

Yes — technically you can, and the story already accounts for this under the "Based on Phase 0 Discovery" decision point. The two valid paths are:

- **Reuse existing EC2 SG:** Add the ALB inbound rule to the existing SG (if not already present). Valid and saves time.
- **Create a new Fargate-specific SG:** Cleaner separation, recommended for long-term maintainability.

## Why You Might Still Want Separate SGs

Even though reusing is _allowed_, there are strong reasons to create Fargate-specific security groups:

1. **Lifecycle clarity** — EC2 SGs likely carry rules irrelevant to Fargate (e.g., port 22 for SSH). Fargate tasks cannot be SSH'd into, so those rules are noise that can confuse future reviewers and auditors.

2. **Post-migration cleanup** — When you decommission EC2, you can cleanly delete the EC2 SG without touching Fargate. If both workloads share one SG, untangling rules later is risky and error-prone.

3. **Least privilege** — A shared SG means EC2 and Fargate have identical inbound rules, which may be broader than what Fargate actually needs.

4. **Naming and auditability** — A SG named `auth-api-fargate-sg` makes it immediately obvious what it's attached to during security audits and incident response. A generic or EC2-named SG creates ambiguity.

## The Non-Negotiable Requirement Either Way

Regardless of whether you reuse or create new, the SG **must** have an inbound rule sourced from the **ALB security group ID** (not a CIDR like `10.x.x.x/x`) on the application port. This is the security group chaining pattern that prevents direct container access.

> **Common Mistake:** Using `10.100.0.0/20` as the inbound source instead of the ALB SG ID. A CIDR-based rule allows _any_ resource in the VPC to connect to your container, not just the ALB.

## Recommendation for Brownfield Migrations

For a brownfield migration where the priority is moving fast with minimal risk:

- **Short term:** Reuse the existing EC2 SG and add the ALB inbound rule. This is a safe, low-effort path to unblock deployment.
- **Before decommissioning EC2:** Split into separate SGs — one for EC2, one for Fargate — before removing EC2. This makes teardown clean and auditable.

Do not remove existing EC2 inbound rules from the shared SG during the migration period. EC2 instances still need their access intact until cutover is complete.
