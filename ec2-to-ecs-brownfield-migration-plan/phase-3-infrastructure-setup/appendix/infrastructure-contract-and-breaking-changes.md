# Infrastructure Contract and Separation of Concerns

This appendix defines the "contract" between the Platform (Core Infrastructure) and Services (Application) layers, specifically regarding where resources live and how they interact.

## The Platform vs. Services Split

To maintain security, stability, and separation of duties, we enforce the following split:

| Component                | Layer    | Repository             | Responsibility                                       |
| :----------------------- | :------- | :--------------------- | :--------------------------------------------------- |
| **VPC / Networking**     | Platform | `scale.infra-platform` | Network topology, Subnets, Routing, NAT Gateways     |
| **Security Groups**      | Platform | `scale.infra-platform` | Firewall rules. Defines "Who can talk to whom".      |
| **Databases (RDS)**      | Platform | `scale.infra-platform` | Persistent stateful data. Long-lived infrastructure. |
| **Load Balancers (ALB)** | Platform | `scale.infra-platform` | Ingress controllers. Shared resources.               |
| **ECS Cluster**          | Platform | `scale.infra-platform` | The compute plane "Data Center".                     |
| **Legacy EC2 Instances** | Services | `scale.infra-services` | The application runtime (Legacy).                    |
| **ECS Tasks / Services** | Services | `scale.infra-services` | The application runtime (Future).                    |

## Why this Architecture?

### 1. Security Groups in Platform

By keeping Security Groups in the Platform layer, the **Security Team** or **Platform Engineers** maintain a single source of truth for network access. Developers do not need to understand CIDR blocks or ports; they simply attach the provided Security Group ID to their service.

### 2. Databases in Platform

RDS instances are "Infrastructure" in the truest sense. They contain persistent data that must survive application redeployments or service teardowns. By keeping them in the Platform layer, we protect them from accidental deletion during service changes.

### 3. Legacy EC2 in Services

Although EC2 instances are infrastructure, in this context they represent "The Application". Moving them to the Services layer treats them as "Workloads" rather than "Core Infrastructure". This allows the Service layer to own the _lifecycle_ of the application, whether it is running on EC2 (legacy) or Fargate (modern).

## Infrastructure Contract (Breaking Changes)

The Platform Layer enables the Service Layer. The "Contract" consists of the **Terraform Outputs** from the Platform layer:

- `vpc_id`
- `private_subnet_ids`
- `ecs_cluster_id`
- `app_security_group_id`
- `db_endpoint`

### Rules for Changes

1. **Platform Changes:** Must not remove or rename outputs without coordination.
2. **Service Changes:** Must consume outputs as `data` sources (remote state).

---

## How the Contract Works in Practice: Publisher and Consumer

`outputs.tf` and `data "terraform_remote_state"` are two halves of the same pattern. Neither is useful without the other.

**`outputs.tf` is the publisher.** It writes named values into the stack's S3 state file. Without it, the state file contains no exported values — the object is empty and every consumer reference breaks.

**`data "terraform_remote_state"` is the consumer.** It reads those published values out of the state file in a different repo or stack.

```hcl
# scale.infra-platform / 01-compute / outputs.tf  (PUBLISHER)
# This is what makes the values available to any other stack.
output "ecs_cluster_arn" {
  description = "ARN of the shared ECS cluster"
  value       = aws_ecs_cluster.main.arn
}

output "https_listener_arn" {
  description = "ARN of the public HTTPS listener"
  value       = aws_lb_listener.https.arn
}

output "alb_security_group_id" {
  description = "Security group ID of the public ALB"
  value       = aws_security_group.alb_public.id
}
```

```hcl
# scale.infra-services / auth-api / data.tf  (CONSUMER)
# This reads the values published above from the remote state file.
data "terraform_remote_state" "compute" {
  backend = "s3"
  config = {
    bucket = "scale-solutions-terraform-state-dev"
    key    = "platform/dev/us-east-1/01-compute/terraform.tfstate"
    region = "us-east-1"
  }
}

# Then reference anywhere in the service stack as:
# data.terraform_remote_state.compute.outputs.ecs_cluster_arn
# data.terraform_remote_state.compute.outputs.https_listener_arn
# data.terraform_remote_state.compute.outputs.alb_security_group_id
```

> **Common misconception:** It might seem like you only need the `data` block in the service repo and can skip `outputs.tf` in the platform repo. This is wrong. The `data` block reads from the state file — if the platform stack has no `outputs.tf`, the state file publishes nothing and `data.terraform_remote_state.compute.outputs` returns an empty object. Every downstream reference fails at plan time.

**Mental model:** think of `outputs.tf` as defining an API surface for the stack. The state file is the endpoint. `data "terraform_remote_state"` is the client calling that API. You need both.

---

## What Counts as a Breaking Change

Because service stacks reference platform outputs by name, any of the following in a platform stack is a **breaking change** that requires coordination with service teams before applying:

| Change                        | Why it breaks consumers                                                                                                                 |
| ----------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| Remove an output              | `data.terraform_remote_state.*.outputs.<name>` becomes `null` — Terraform plans succeed but applies fail or produce incorrect resources |
| Rename an output              | Same effect as removal from the consumer's perspective                                                                                  |
| Change an output's value type | e.g., changing from a string ARN to a list causes type errors in consumer attribute assignments                                         |

**Safe changes** (do not require consumer coordination):

- Adding a new output (purely additive)
- Changing the output `description`
- Changing the underlying resource while keeping the output name and type stable
