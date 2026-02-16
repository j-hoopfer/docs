# Appendix: ECS Deployment Fundamentals

## Overview

This appendix explains the core concepts of ECS Fargate deployments, including task definitions, services, and the relationships between AWS components.

**Use this appendix when:**

- Understanding how ECS components fit together
- Creating your first ECS service
- Troubleshooting deployment issues
- Planning resource naming conventions
- Understanding the deployment sequence

---

## Table of Contents

1. [What is a Task Definition?](#what-is-a-task-definition)
2. [The Complete Deployment Sequence](#the-complete-deployment-sequence)
3. [Component Relationships](#component-relationships)
4. [Naming Conventions](#naming-conventions)
5. [Key Concepts Explained](#key-concepts-explained)
6. [Quick Reference](#quick-reference)

---

## What is a Task Definition?

A **Task Definition** is a blueprint that tells ECS how to run your container. Think of it as a detailed `docker run` command saved as configuration.

**It specifies:**

- Which Docker image to use
- How much CPU and memory to allocate
- What environment variables to set
- Which secrets to inject from Secrets Manager
- Where to send logs (CloudWatch)
- Which ports to expose
- What IAM roles to use (execution role, task role)
- Health check configuration

**Example analogy:**

- Task Definition = Recipe
- ECS Service = Chef that follows the recipe
- Running Task = The actual dish being served

---

## The Complete Deployment Sequence

Here's the correct order to deploy a new service:

```
1. Push Image to ECR
   ↓
2. Create Task Definition (blueprint)
   ↓
3. Create Target Group (ALB routing destination)
   ↓
4. Create ECS Service (runs tasks using the blueprint)
   ↓
5. Add ALB Listener Rule (routes traffic to target group)
   ↓
6. Configure DNS (point domain to ALB)
```

**Why this order matters:**

- You need the image in ECR before creating the task definition (image URI required)
- You need the target group before creating the service (service connects to it)
- You need the service running before adding the listener rule (otherwise rule routes to nothing)

---

## Component Relationships

**Example:** This diagram shows the pattern using `your-service` as a placeholder. Replace with your actual service names (e.g., `test-api-1`, `test-api-2`, `auth-api`).

```
┌─────────────────────────────────────────────────────────────┐
│                         USER REQUEST                         │
└───────────────────────────────┬─────────────────────────────┘
                                ↓
                    ┌───────────────────────┐
                    │  Application Load     │
                    │  Balancer (ALB)       │
                    │  - SSL Termination    │
                    │  - Host-based routing │
                    └───────────┬───────────┘
                                ↓
                    ┌───────────────────────┐
                    │  Listener Rule        │
                    │  Priority: 100        │
                    │  Condition: Host      │
                    │  yourapp.mysite.com   │
                    └───────────┬───────────┘
                                ↓
                    ┌───────────────────────┐
                    │  Target Group         │
                    │  your-service-tg      │
                    │  Type: IP             │
                    │  Health: /health      │
                    └───────────┬───────────┘
                                ↓
    ┌───────────────────────────────────────────────────────────────┐
    │                  ECS CLUSTER: your-cluster                     │
    │                  (e.g., test, production)                      │
    │                                                                │
    │               ┌───────────────────────┐                        │
    │               │  ECS Service          │                        │
    │               │  your-service         │                        │
    │               │  Desired: 2           │                        │
    │               │  Uses: Task Def       │                        │
    │               └───────────┬───────────┘                        │
    │                           ↓                                    │
    │       ┌───────────────────┴───────────────────────┐           │
    │       ↓                                           ↓           │
    │ ┌───────────────────┐                   ┌───────────────────┐ │
    │ │  Fargate Task 1   │                   │  Fargate Task 2   │ │
    │ │  IP: 10.100.4.23  │                   │  IP: 10.100.6.45  │ │
    │ │  Port: 3000       │                   │  Port: 3000       │ │
    │ │  Status: Healthy  │                   │  Status: Healthy  │ │
    │ └─────────┬─────────┘                   └─────────┬─────────┘ │
    │           └─────────────────┬─────────────────────┘           │
    └─────────────────────────────┼─────────────────────────────────┘
                                  ↓
              ┌───────────────────────────────────────────┐
              │     Task Definition (Blueprint)            │
              │  Family: your-service                     │
              │  Container: your-service                  │
              │  - Image: ECR URI                         │
              │  - CPU: 256, Memory: 512                  │
              │  - Env vars, Secrets, Logs, Health check  │
              └───────────────────────────────────────────┘
```

**Key:** The **ECS Cluster** is a logical grouping that contains Services and Tasks. Multiple services (like `test-api-1`, `test-api-2`, `auth-api`) can run in the same cluster, sharing the same infrastructure pool.

---

## Naming Conventions

**Critical: Keep these names identical for simplicity.**

AWS doesn't technically require these names to match, but keeping them the same eliminates confusion and makes operations easier.

**Recommended Pattern:**

| Component                            | What to Name It         | Example 1               | Example 2             |
| ------------------------------------ | ----------------------- | ----------------------- | --------------------- |
| **Task Definition Family**           | `[app-name]`            | `test-api-1`            | `auth-api`            |
| **Container Name** (inside task def) | `[app-name]`            | `test-api-1`            | `auth-api`            |
| **ECS Service**                      | `[app-name]`            | `test-api-1`            | `auth-api`            |
| **Target Group**                     | `[app-name]-tg`         | `test-api-1-tg`         | `auth-api-tg`         |
| **Security Group**                   | `[app-name]-fargate-sg` | `test-api-1-fargate-sg` | `auth-api-fargate-sg` |

**Why This Matters:**

✅ **Easy Debugging:** When you see `test-api-1` in CloudWatch logs, you know exactly which service it is  
✅ **Simpler CI/CD:** Use one variable for Task Family, Container Name, and Service Name  
✅ **Team Clarity:** No mental mapping required - name = service  
✅ **Less Errors:** No chance of updating the wrong container in a multi-container task definition

**When to Use Different Names:**

- Multiple environments: `test-api-1-staging` vs `test-api-1-production`
- Version migrations: `auth-api-v2` (temporary during cutover)

**What Happens If You Don't Match?**

Nothing breaks, but you'll create unnecessary complexity:

- Task Family: `legacy-test-api-1-v2`
- Container: `test-api-1-container`
- Service: `production-test-api-1-service`

Now you need to remember this mapping everywhere - in CI/CD scripts, troubleshooting commands, documentation, team communication, etc.

**Example for Your Deployment:**

```bash
# test-api-1
Task Definition Family: test-api-1
Container Name: test-api-1
Service Name: test-api-1
Target Group: test-api-1-tg

# test-api-2
Task Definition Family: test-api-2
Container Name: test-api-2
Service Name: test-api-2
Target Group: test-api-2-tg

# auth-api
Task Definition Family: auth-api
Container Name: auth-api
Service Name: auth-api
Target Group: auth-api-tg
```

---

## Key Concepts Explained

### Task Definition vs Task vs Service

| Component           | What It Is                        | Analogy                |
| ------------------- | --------------------------------- | ---------------------- |
| **Task Definition** | A JSON blueprint                  | Recipe card            |
| **Task**            | A running container instance      | Dish being served      |
| **Service**         | Maintains desired number of tasks | Chef who keeps cooking |

**Example:**

- Task Definition: "Run `auth-api:latest` with 512MB RAM on port 3000"
- Service: "Keep 2 copies of auth-api running at all times"
- Tasks: The actual 2 running containers

### Why Do I Need All These Things?

**Q: Can't I just run a container like Docker Compose?**

A: ECS adds production capabilities:

- **Target Group**: Load balances across multiple containers, health checks
- **Service**: Auto-restarts failed containers, rolling deployments
- **ALB**: SSL termination, routing multiple apps on one load balancer
- **Task Definition**: Version control for infrastructure, rollback capability

### Task Definition Versions

Every time you update a task definition, AWS creates a new **revision**:

- `auth-api:1` (initial)
- `auth-api:2` (added environment variable)
- `auth-api:3` (updated image)

**Your ECS Service points to a specific revision:**

- Service runs `auth-api:3`
- If there's an issue, you can rollback to `auth-api:2`

### What Happens When You Deploy

```
1. GitHub Actions pushes new image to ECR
   - Tags it with git SHA: auth-api:abc123f

2. GitHub Actions creates new task definition revision
   - auth-api:4 with image auth-api:abc123f

3. GitHub Actions updates ECS Service
   - "Use task definition auth-api:4"

4. ECS Service starts rolling deployment
   - Starts 1 new task (auth-api:4)
   - Waits for it to be healthy
   - Stops 1 old task (auth-api:3)
   - Repeats until all tasks updated

5. Target Group health checks pass
   - ALB routes traffic to new tasks
   - Old tasks drained and terminated
```

---

## Quick Reference

### When You Need Each Component

| You Need                 | To Do This                                      |
| ------------------------ | ----------------------------------------------- |
| **Task Definition**      | Always (defines what to run)                    |
| **ECR Repository**       | Always (stores your image)                      |
| **ECS Service**          | Run containers continuously (not one-off tasks) |
| **Target Group**         | Receive traffic from ALB                        |
| **ALB Listener Rule**    | Route traffic based on domain/path              |
| **Security Group**       | Control network access                          |
| **CloudWatch Log Group** | See application logs                            |

---

## Related Documentation

- See [networking-and-security-groups.md](../../phase-3-infrastructure-setup/appendix/networking-and-security-groups.md) for security group patterns
- See [github-actions-cicd.md](github-actions-cicd.md) for deployment automation
- See [troubleshooting-and-operations.md](../../phase-5-scaling/appendix/troubleshooting-and-operations.md) for debugging failed deployments
