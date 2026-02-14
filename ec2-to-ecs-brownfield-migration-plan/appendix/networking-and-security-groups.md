# Appendix: Networking and Security Groups

## Overview

This appendix provides best practices for organizing security groups in ECS Fargate environments, focusing on scalable patterns that minimize duplication while maintaining security.

**Use this appendix when:**

- Creating security groups for new ECS services
- Deciding between shared vs per-service security groups
- Implementing least-privilege network access
- Scaling from 1 service to 10+ services
- Troubleshooting network connectivity issues

---

## Table of Contents

1. [The Problem with One-Per-Service](#the-problem-with-one-per-service)
2. [Recommended Pattern: Baseline + Service-Specific](#recommended-pattern-baseline--service-specific)
3. [Implementation in ECS Service](#implementation-in-ecs-service)
4. [When to Use Each Pattern](#when-to-use-each-pattern)
5. [Migration Path](#migration-path)

---

## The Problem with One-Per-Service

The naive approach is to create a unique security group for every service:

- `test-api-1-sg` with ALB inbound rule
- `test-api-2-sg` with ALB inbound rule
- `auth-api-sg` with ALB inbound rule
- ... 10 more services, 10 more duplicate rules

**Problems:**

- ❌ Duplicate ALB access rules across every service SG
- ❌ Updating the ALB rule requires changing 10+ security groups
- ❌ Harder to audit ("which services can access the ALB?" = check 10 SGs)
- ❌ Doesn't scale well

---

## Recommended Pattern: Baseline + Service-Specific

**You can attach up to 5 security groups to a single ECS task.** Use this to create a scalable pattern:

### 1. Baseline Security Group (Shared by ALL services)

**Name:** `fargate-baseline-sg` or `fargate-common-sg`

**Purpose:** Common rules that apply to every Fargate service

**Rules:**

```
Inbound:
- Source: ALB Security Group (sg-alb-xxx)
  Port: 3000 (or your app port)
  Description: "Allow ALB to reach all Fargate services"

Outbound:
- Destination: 0.0.0.0/0
  Port: All
  Description: "Allow internet access for ECR pulls, API calls, etc."
```

**Attached to:** Every single Fargate service

### 2. Service-Specific Security Groups (Optional, for Resource Isolation)

**Pattern:** Create these ONLY for services that need specific resource access

**Example 1: Database Access**

**Name:** `auth-api-database-sg`

**Purpose:** Marker SG to grant auth-api (and only auth-api) database access

**Rules:**

```
Inbound: None
Outbound: None
```

**Why no rules?** This SG is just a "marker" - the RDS security group references it.

**RDS Security Group gets updated:**

```
Inbound:
- Source: auth-api-database-sg
  Port: 5432
  Description: "Allow auth-api to connect to database"
```

**Attached to:** Only `auth-api` service

**Example 2: S3 Access (Via VPC Endpoint)**

**Name:** `billing-api-s3-sg`

**Purpose:** Grant S3 VPC endpoint access to billing-api only

**VPC Endpoint SG gets updated:**

```
Inbound:
- Source: billing-api-s3-sg
  Port: 443
  Description: "Allow billing-api to reach S3 via VPC endpoint"
```

**Attached to:** Only `billing-api` service

---

## Complete Example

**Scenario:** 3 services, 1 needs database access

**Security Groups Created:**

1. `fargate-baseline-sg` (shared)
2. `auth-api-database-sg` (service-specific)

**Service Attachments:**

| Service      | Security Groups Attached                        | Result                                             |
| ------------ | ----------------------------------------------- | -------------------------------------------------- |
| `auth-api`   | `fargate-baseline-sg`<br>`auth-api-database-sg` | ✅ Can receive ALB traffic<br>✅ Can access RDS    |
| `test-api-1` | `fargate-baseline-sg`                           | ✅ Can receive ALB traffic<br>❌ Cannot access RDS |
| `test-api-2` | `fargate-baseline-sg`                           | ✅ Can receive ALB traffic<br>❌ Cannot access RDS |

**Database (RDS) Security Group:**

```
Inbound:
- Source: auth-api-database-sg
  Port: 5432
```

**Result:** Only auth-api can connect to the database (principle of least privilege)

---

## Implementation in ECS Service

**When creating ECS Service (Console):**

```
Networking:
  Security Groups:
    - fargate-baseline-sg        ← Always include
    - auth-api-database-sg       ← Add if service needs DB
```

**When creating ECS Service (CLI):**

```bash
aws ecs create-service \
  --cluster production-cluster \
  --service-name auth-api \
  --task-definition auth-api:1 \
  --network-configuration "awsvpcConfiguration={
    subnets=[subnet-xxx,subnet-yyy],
    securityGroups=[sg-baseline-xxx,sg-auth-api-database-yyy],
    assignPublicIp=DISABLED
  }"
```

---

## When to Use Each Pattern

| Scenario                                             | Pattern                     | Security Groups                                 |
| ---------------------------------------------------- | --------------------------- | ----------------------------------------------- |
| POC with identical services                          | Baseline only               | `fargate-baseline-sg`                           |
| Production with services needing different DB access | Baseline + Service-Specific | `fargate-baseline-sg` + `[app]-database-sg`     |
| Multi-tenant with strict isolation                   | One-per-service             | `[app]-sg` (not recommended at scale)           |
| Microservices accessing different external APIs      | Baseline + Service-Specific | `fargate-baseline-sg` + `[app]-external-api-sg` |

---

## Benefits Summary

✅ **Centralized Common Rules:** ALB access rule exists in one place  
✅ **Scalable:** Add 100 services, still just 1 baseline SG  
✅ **Principle of Least Privilege:** Only grant database access to services that need it  
✅ **Easy Auditing:** "Which services can access RDS?" = Check which services have the database SG attached  
✅ **Flexible:** Can mix and match up to 5 SGs per service  
✅ **Cost Effective:** Security groups are free (unlike NACLs or firewall appliances)

---

## Migration Path

**If you already have one-per-service SGs:**

1. Create `fargate-baseline-sg` with ALB access rule
2. Attach it to all existing services (in addition to their current SG)
3. Verify traffic still flows
4. Remove ALB rules from individual service SGs
5. For new services, only attach baseline + service-specific (if needed)
6. Eventually remove old per-service SGs if they're empty

---

## Related Documentation

- See [ecs-deployment-fundamentals.md](ecs-deployment-fundamentals.md) for understanding ECS networking
- See [aws-authentication-and-security.md](aws-authentication-and-security.md) for IAM security best practices
- See [troubleshooting-and-operations.md](troubleshooting-and-operations.md) for debugging connectivity issues
