# Appendix: ECS Cluster Best Practices

**Related Story:** [Story 4.5 — Create Shared ECS Cluster](../4-setup-shared-infrastructure.md)

This appendix explains every setting applied to the shared ECS cluster and why each one exists. The goal is to give engineers a durable mental model, not just a copy-paste template.

---

## Table of Contents

1. [Separate `aws_ecs_cluster_capacity_providers` Resource](#1-separate-aws_ecs_cluster_capacity_providers-resource)
2. [FARGATE + FARGATE_SPOT with a Weighted Strategy](#2-fargate--fargate_spot-with-a-weighted-strategy)
3. [Container Insights](#3-container-insights)
4. [ECS Exec via `execute_command_configuration`](#4-ecs-exec-via-execute_command_configuration)
5. [Dedicated ECS Exec Audit Log Group](#5-dedicated-ecs-exec-audit-log-group)
6. [CloudWatch Encryption on ECS Exec Logs](#6-cloudwatch-encryption-on-ecs-exec-logs)

---

## 1. Separate `aws_ecs_cluster_capacity_providers` Resource

### What

Capacity providers (the compute backing for ECS tasks) are managed by a **dedicated resource** — `aws_ecs_cluster_capacity_providers` — rather than inline on `aws_ecs_cluster`.

```hcl
# Correct
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
  ...
}

# Wrong — will fail to compile against current AWS provider
resource "aws_ecs_cluster" "main" {
  capacity_providers = ["FARGATE"] # ← this attribute no longer exists
}
```

### Why

AWS removed the `capacity_providers` attribute from the `aws_ecs_cluster` resource in recent releases of the AWS Terraform provider. The reason is lifecycle ownership: when capacity provider settings are inline on the cluster, any external tool or team that modifies them (e.g., via the AWS console or a separate Terraform stack) creates drift that Terraform cannot reconcile cleanly. The separate resource gives Terraform an independent lifecycle to manage capacity providers on its own plan/apply cycle.

**Practical consequence:** keeping `capacity_providers` on `aws_ecs_cluster` produces a hard compilation error. It must be moved to `aws_ecs_cluster_capacity_providers`.

---

## 2. FARGATE + FARGATE_SPOT with a Weighted Strategy

### What

Two capacity providers are registered, with a default strategy that splits traffic between them:

```hcl
default_capacity_provider_strategy {
  base              = 1
  weight            = 60
  capacity_provider = "FARGATE"
}

default_capacity_provider_strategy {
  weight            = 40
  capacity_provider = "FARGATE_SPOT"
}
```

### Why

**FARGATE (on-demand)** provides guaranteed task placement. AWS guarantees capacity and charges a fixed per-vCPU/per-GB rate.

**FARGATE_SPOT** uses spare AWS capacity at a discount of roughly 50–70% off on-demand pricing. The trade-off: Spot tasks can be reclaimed by AWS with a two-minute warning when demand spikes.

**The strategy balances cost and reliability:**

| Parameter                     | Value | Meaning                                                                                                                |
| ----------------------------- | ----- | ---------------------------------------------------------------------------------------------------------------------- |
| `base = 1` on FARGATE         | 1     | Always start at least 1 task on guaranteed on-demand capacity. Prevents a total service outage if Spot is unavailable. |
| `weight = 60` on FARGATE      | 60    | After the base is satisfied, 60 out of every 100 additional tasks go to on-demand.                                     |
| `weight = 40` on FARGATE_SPOT | 40    | 40 out of every 100 additional tasks go to Spot, reducing cost as the service scales.                                  |

**For stateless, horizontally scalable services** (the Fargate migration target), Spot interruptions are manageable — ECS simply replaces the interrupted task. The `base = 1` guarantee prevents a cold-start window where no tasks are running.

**For services that cannot tolerate interruption** (e.g., long-running batch jobs, stateful workloads), override the strategy at the `aws_ecs_service` level to use `FARGATE` exclusively.

---

## 3. Container Insights

### What

```hcl
setting {
  name  = "containerInsights"
  value = "enabled"
}
```

### Why

Container Insights publishes **pre-built CloudWatch metrics** for CPU utilization, memory utilization, network I/O, and disk I/O at the cluster, service, and task level — without any agent installation or custom metric configuration.

**Without Container Insights:** the only available metrics are basic EC2-level metrics that don't apply to Fargate. You'd have no visibility into whether your tasks are CPU-throttled, memory-pressured, or just idle.

**With Container Insights:** you get actionable signals to drive auto-scaling policies (scale out on CPU > 70%), capacity planning (right-size task CPU/memory), and alerting (alarm when memory > 90% for > 5 min).

**Cost:** Container Insights does add CloudWatch charges — roughly $0.50/GB of metric data ingested. For most workloads this is negligible relative to the debugging and operational value. It can be disabled per service if cost becomes a concern at scale.

---

## 4. ECS Exec via `execute_command_configuration`

### What

```hcl
configuration {
  execute_command_configuration {
    logging = "OVERRIDE"

    log_configuration {
      cloud_watch_encryption_enabled = true
      cloud_watch_log_group_name     = aws_cloudwatch_log_group.ecs_exec.name
    }
  }
}
```

### Why

ECS Exec uses AWS Systems Manager (SSM) Session Manager to open an interactive shell directly into a running Fargate container — no bastion host, no SSH, no inbound security group rules required.

**The problem it solves:** In a Fargate environment, containers are fully managed by AWS. There is no underlying EC2 instance you can SSH into. Before ECS Exec existed, debugging a misbehaving container required either embedding a sidecar debug tool in the container image or reading logs and hoping for the best.

**ECS Exec allows:**

- Running `bash` inside a container to inspect the filesystem, environment variables, or process state.
- Executing one-off diagnostic commands (`curl`, `netstat`, `dig`) without rebuilding the image.
- Investigating race conditions or startup failures in real time.

**`logging = "OVERRIDE"`** means ECS Exec sessions produce an audit log in the specified CloudWatch log group. This is important for security compliance: you get a record of who (IAM principal) ran what command in which container, and when.

Without the `configuration` block entirely, ECS Exec is disabled cluster-wide and must be enabled per-service. Enabling it at the cluster level means all services inherit the capability without additional configuration.

**Prerequisites at the service level:** ECS Exec also requires `enable_execute_command = true` on each `aws_ecs_service` resource and the task IAM role must have the `ssmmessages:*` permissions. The cluster setting is necessary but not sufficient on its own.

---

## 5. Dedicated ECS Exec Audit Log Group

### What

```hcl
resource "aws_cloudwatch_log_group" "ecs_exec" {
  name              = "/ecs/exec"
  retention_in_days = 30
}
```

A separate `/ecs/exec` log group is created alongside the existing `/ecs/shared` application log group.

### Why

**Separation of concerns:** Application logs (`/ecs/shared`) are high-volume, written continuously by every task. ECS Exec audit logs (`/ecs/exec`) are low-volume, event-driven, and have a different audience — security and compliance reviewers, not application developers.

Mixing them in the same log group makes it harder to:

- Set independent retention policies (compliance may require exec logs to be kept longer than app logs).
- Control log group access via IAM (developers may have read access to app logs but exec logs may be restricted to security leads).
- Route them to different downstream systems (e.g., SIEM ingestion for exec logs only).

**Retention at 30 days** is a reasonable default. Adjust upward if your compliance requirements mandate longer audit trails.

---

## 6. CloudWatch Encryption on ECS Exec Logs

### What

```hcl
cloud_watch_encryption_enabled = true
```

### Why

By default, CloudWatch Log Groups are encrypted using an AWS-managed key. Setting `cloud_watch_encryption_enabled = true` on the ECS Exec log configuration signals to AWS that exec session data should be encrypted — aligning with defense-in-depth for audit data.

ECS Exec sessions can capture sensitive output: environment variable values, secrets that a developer `echo`s or a misconfigured app prints to stdout, internal service hostnames, etc. Encrypting audit logs ensures this data is protected at rest.

**Note:** To use a customer-managed KMS key (CMK) instead of the AWS-managed default, add a `kms_key_id` to the `aws_cloudwatch_log_group.ecs_exec` resource and update the `execute_command_configuration` to reference it. This is recommended for environments with strict data sovereignty or compliance requirements (PCI-DSS, HIPAA).

---

## Reference: Full Terraform

The complete, production-ready Terraform for these resources lives in:

- [`environments/dev/us-east-1/01-compute/ecs.tf`](../../../../../scale.infra-platform/environments/dev/us-east-1/01-compute/ecs.tf) — cluster + capacity providers
- [`environments/dev/us-east-1/01-compute/cloudwatch.tf`](../../../../../scale.infra-platform/environments/dev/us-east-1/01-compute/cloudwatch.tf) — log groups
