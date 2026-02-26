# 12-Factor App Preparation Plan

## Context & Themes

This phase focuses on decoupling the application from the underlying infrastructure. It establishes the foundation for a seamless transition to containerized environments.

**Key Themes:**

- **Statelessness:** Ensuring the application does not rely on local file storage or memory for session data, allowing it to scale horizontally.
- **Secrets Management:** Decoupling credentials from the codebase to improve security and flexibility across environments.
- **Logs as Event Streams:** Treating logs as a stream of events sent to stdout/stderr, enabling aggregation and analysis by centralized logging systems.

Why is this critical _before_ containers? Addressing these factors in a known EC2 environment isolates architectural changes from packaging changes, reducing the complexity of the migration.

## Overview

This plan prepares your application for cloud-native deployment by implementing the [12-Factor App methodology](https://12factor.net/). These changes make your application **stateless, scalable, and environment-agnostic**—critical for running in containerized, ephemeral environments like ECS Fargate.

**Key Insight:** All these changes can (and should) be implemented and validated on EC2 **before** containerization. This de-risks the migration by proving cloud-native patterns work in your existing environment.

---

## Why 12-Factor First, Containers Second?

| Approach                            | Risk Profile          | Advantages                                                               |
| ----------------------------------- | --------------------- | ------------------------------------------------------------------------ |
| **12-Factor → Containers → ECS** ✅ | Low risk, incremental | Changes validated on EC2 first; smaller scope per phase; rollback easier |
| **Containers + 12-Factor + ECS** ❌ | High risk, big bang   | Too many changes at once; hard to debug failures; difficult rollback     |

**Recommendation:** Complete this plan on EC2, validate in production for 1-2 weeks, then proceed to containerization.

---

## Prerequisites

Before starting this phase, ensure:

- [ ] Phase 1 Discovery complete
- [ ] Terraform State Bootstrap complete

---

## Plan Architecture

This plan focuses on **application code changes** for cloud-native patterns. No Docker or container knowledge required.

**Related Plans:**

- **Prerequisite:** [Terraform State Bootstrap Plan](../../../terraform-state-bootstrap-plan/README.md) - Set up Terraform state backend
- **Next Step:** [Containerizing Services Plan](../containerizing-services/README.md) - Package into Docker containers
- **Final Step:** [ECS Brownfield Migration Plan](../../README.md) - Deploy to Fargate

---

## Success Criteria

Before proceeding to containerization, verify:

- ✅ Application reads all config from environment variables (no `.env` in codebase)
- ✅ All application secrets created in AWS Secrets Manager (naming convention agreed, ARNs recorded)
- ✅ No hardcoded secrets (verified with gitleaks scan)
- ✅ Logs go to stdout/stderr (works on EC2, will work in containers)
- ✅ Sessions stored in Redis/database (users stay logged in across server restarts)
- ✅ File uploads go to S3 (no local filesystem dependencies)
- ✅ Cron jobs documented and migration plan created
- ✅ Background workers can run as separate processes
- ✅ Health check endpoints return 200 OK
- ✅ Database connection pools sized appropriately
- ✅ Application handles proxy headers (X-Forwarded-For)
- ✅ Email delivery works via cloud service (no local filesystem mails)
- ✅ Timezone handling verified
- ✅ DNS caching configured for RDS failover
- ✅ Secrets rotation tested

---

## Execution Phases

### Phase 1: Configuration & Secrets (Foundation)

**Goal:** Externalize all configuration and eliminate hardcoded secrets

**Stories:**

- [Story 1: Find and Eliminate Hardcoded Secrets](1-configuration-and-secrets.md#story-1)
- [Story 2: Migrate Configuration to Environment Variables](1-configuration-and-secrets.md#story-2)
- [Story 3: Create Secrets in AWS Secrets Manager](1-configuration-and-secrets.md#story-3)

**Validation:** Deploy to EC2 dev environment using only environment variables (no `.env` file in repo); all secrets exist in Secrets Manager with ARNs recorded

---

### Phase 2: Stateless Application (Critical)

**Goal:** Remove all local state dependencies

**Stories:**

- [Story 3: Eliminate Ephemeral Filesystem Dependencies](2-stateless-application.md#story-3)
- [Story 4: Externalize Session Storage](2-stateless-application.md#story-4)

**Validation:** Restart EC2 instance; verify file uploads and user sessions persist

---

### Phase 3: Observability (Operations)

**Goal:** Enable visibility without SSH access

**Stories:**

- [Story 5: Implement Console-Based Logging](3-observability.md#story-5)
- [Story 6: Implement Health Check Endpoints](3-observability.md#story-6)
- [Story 7: Implement Dependency Health Checks](3-observability.md#story-7)

**Validation:** Logs visible in CloudWatch, health checks return 200 OK, ALB can use health endpoint

---

### Phase 4: Backing Services (Cloud Integration)

**Goal:** Migrate to managed cloud services

**Stories:**

- [Story 8: Replace Local Mail Agent with Cloud Email Service](4-backing-services.md#story-8)
- [Story 9: Replace Local Crontab with AWS EventBridge Scheduler](4-backing-services.md#story-9)
- [Story 10: Deploy Queue Workers as Dedicated Service](4-backing-services.md#story-10)

**Validation:** Emails send via SES/SendGrid, cron jobs run via EventBridge, workers process jobs independently

---

### Phase 5: Network & Security (Cloud-Native Patterns)

**Goal:** Handle load balancer environment and cloud security

**Stories:**

- [Story 11: Configure Trusted Proxy Headers](5-network-and-security.md#story-11)
- [Story 12: Database Connection Pooling](5-network-and-security.md#story-12)
- [Story 13: Handle DNS Caching for Failover](5-network-and-security.md#story-13)
- [Story 14: Support Secrets Rotation](5-network-and-security.md#story-14)
- [Story 15: Standardize Application Timezone](5-network-and-security.md#story-15)

**Validation:** Rate limiting works, connection pool stable under load, RDS failover succeeds, secret rotation successful

---

## Team Assignment

| Role                 | Responsibilities                                                                                                                |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| **Development Team** | Implement stories 1-7, 11-15 (application code changes)                                                                         |
| **DevOps Team**      | Implement story 3 (Secrets Manager provisioning), stories 8-10 (infrastructure: EventBridge, workers); support development team |
| **Security Team**    | Review story 1 (secrets scan), story 14 (rotation); approve changes                                                             |
| **QA Team**          | Validate each phase on EC2 before proceeding to next phase                                                                      |

---

## Risk Mitigation

### Low-Risk Changes (Safe to deploy immediately)

- Story 5: Console-based logging (backward compatible with EC2)
- Story 6: Health check endpoints (just adds new routes)
- Story 11: Proxy headers (only affects traffic behind ALB)

### Medium-Risk Changes (Requires testing)

- Story 2: Environment variables (test in dev first)
- Story 8: Cloud email service (parallel run with old system)
- Story 13: DNS caching (test RDS failover in staging)

### High-Risk Changes (Requires careful rollout)

- Story 3: S3 file storage (dual-write to local + S3, then cutover)
- Story 4: External sessions (test thoroughly in staging first)
- Story 12: Connection pooling (load test to verify limits)

---

## Common Pitfalls

1. **Skipping EC2 validation**: Don't jump straight to containers. Validate 12-Factor patterns on EC2 first.
2. **Not testing session externalization**: This breaks user logins if misconfigured. Test extensively.
3. **Forgetting log consumers**: Update log shippers, dashboards, alerts to handle stdout logging.
4. **Undersizing connection pools**: Calculate based on expected max tasks, not current EC2 count.
5. **Not rotating exposed secrets**: If gitleaks finds secrets in git history, rotate them immediately.

---

## How to Use This Plan

1. **Read this README** to understand the overall approach
2. **Review each phase** in this directory
3. **Complete Phase 1** (configuration) first—it's the foundation for everything else
4. **Deploy and validate each phase on EC2** before proceeding to the next
5. **Run the Pre-Containerization Checklist** (below) before moving to containerization plan

---

## Pre-Containerization Checklist

Before proceeding to the [Containerizing Services Plan](../containerizing-services/README.md), verify:

- [ ] All config read from environment variables (no `.env` files)
- [ ] Zero secrets in codebase (gitleaks scan passes)
- [ ] All application secrets created in AWS Secrets Manager with ARNs recorded
- [ ] Application logs to stdout/stderr
- [ ] Sessions stored in Redis/database
- [ ] File uploads go to S3
- [ ] Cron jobs migrated to EventBridge
- [ ] Workers run as separate processes
- [ ] Health check endpoints working
- [ ] Application handles proxy headers correctly
- [ ] Email delivery via cloud service
- [ ] Connection pooling configured
- [ ] Timezone handling verified
- [ ] DNS caching configured
- [ ] Secrets rotation tested
- [ ] **All changes validated in production on EC2 for at least 1 week**

---

## 12-Factor Methodology Mapping

| 12-Factor Principle        | Stories Implementing It                               |
| -------------------------- | ----------------------------------------------------- |
| **I. Codebase**            | Already satisfied (git repo)                          |
| **II. Dependencies**       | Containerizing Services Plan (Dockerfile)             |
| **III. Config**            | Story 1, 2, 3 (env vars, no secrets, Secrets Manager) |
| **IV. Backing Services**   | Story 3, 4, 8, 9 (S3, Redis, SES, EventBridge)        |
| **V. Build, Release, Run** | ECS Brownfield Migration Plan (CI/CD)                 |
| **VI. Processes**          | Story 4 (stateless, external sessions)                |
| **VII. Port Binding**      | Containerizing Services Plan (network binding)        |
| **VIII. Concurrency**      | Story 10 (separate workers)                           |
| **IX. Disposability**      | Containerizing Services Plan (SIGTERM)                |
| **X. Dev/Prod Parity**     | Containerizing Services Plan (docker-compose)         |
| **XI. Logs**               | Story 5 (stdout logging)                              |
| **XII. Admin Processes**   | Story 9 (EventBridge for scheduled tasks)             |

---

## Support & Questions

For questions about this plan:

- **Application changes**: Contact Development Lead
- **Infrastructure setup**: Contact DevOps Lead
- **Security review**: Contact Security Team
- **Overall migration**: Contact Migration Project Manager

**Next Steps:** Once this plan is complete and validated on EC2, proceed to [Containerizing Services Plan](../containerizing-services/README.md).
