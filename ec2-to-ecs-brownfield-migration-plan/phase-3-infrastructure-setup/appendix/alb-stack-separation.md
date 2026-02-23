# Appendix: ALB Stack Separation at Enterprise Scale

## Current Approach (Brownfield Migration)

During this migration, both the public and internal ALBs live together within the `environments/dev/us-east-1/01-compute` stack.

- Low operational overhead — one `terraform apply` covers both.
- Change frequency is identical for both ALBs (you're still standing things up).
- Ownership of both is scoped to the Platform team.

---

## Why Enterprises Split These Into Separate Stacks

At scale, the public and internal ALBs develop fundamentally different operational characteristics:

| Dimension            | Public ALB                                | Internal ALB                                  |
| :------------------- | :---------------------------------------- | :-------------------------------------------- |
| **Ownership**        | Security / Network team                   | Platform / App team                           |
| **Change frequency** | Rare (needs CAB approval, audit trail)    | Frequent (new services claim paths often)     |
| **Blast radius**     | A misconfiguration exposes the internet   | Contained within the VPC                      |
| **Compliance**       | PCI-DSS, SOC2, WAF rules enforced here    | Internal SLAs only                            |
| **State isolation**  | Changes to internet-facing infra must not | Changes can be fast-tracked without impacting |
|                      | be bundled with internal workload changes | the public ingress layer                      |

The core principle: **the public ALB is an edge/security concern; the internal ALB is a workload concern.** Mixing them in one state file means a routine internal routing change could, in theory, trigger a plan that touches public-facing resources — introducing unnecessary risk and audit noise.

---

## The Target Enterprise Pattern

```
environments/
  dev/
    us-east-1/
      00-network/           # VPC, Subnets, NAT (Platform team)
      01-edge/              # Public ALB, WAF, ACM certs (Security team)
      02-compute/           # Internal ALB, ECS Cluster (Platform/App team)
      03-services/          # ECS Task Definitions, Services (App team)
```

- `01-edge` has its own state file. Only the Security/Network team has write access via CI/CD.
- `02-compute` has its own state file. Platform engineers deploy freely here.
- `02-compute` reads `01-edge` outputs via `data.terraform_remote_state` if it needs the public ALB ARN (e.g., to attach a listener rule).

---

## Migration Path: Splitting The Stack

When you're ready to promote to this pattern, follow these steps. **No infrastructure is destroyed** — this is purely a state reorganisation.

### Step 1: Prerequisites

- [ ] CI/CD pipelines are in place (see [workflow-before-scaling.md](workflow-before-scaling.md)).
- [ ] Remote state is configured (S3 + DynamoDB locking).
- [ ] You have a maintenance window or low-traffic period.

### Step 2: Create the `01-edge` Stack Directory

Create the new stack directory alongside the existing `01-compute`:

```bash
mkdir -p environments/dev/us-east-1/01-edge
```

Add the standard boilerplate files (`main.tf`, `variables.tf`, `outputs.tf`, `providers.tf`, `backend.tf`).

### Step 3: Write the Configuration for `01-edge`

Move the public ALB resource definitions from `load_balancer.tf` in `01-compute` into the new `01-edge` stack. At this point, **do not delete them from `01-compute` yet** — both stacks will temporarily have the config.

```bash
# 01-edge/load_balancer.tf
resource "aws_security_group" "alb_public" { ... }
resource "aws_lb" "public" { ... }
resource "aws_lb_listener" "http" { ... }
resource "aws_lb_listener" "https" { ... }
```

Add outputs to `01-edge/outputs.tf` so downstream stacks can consume them:

```hcl
# 01-edge/outputs.tf
output "public_alb_arn" {
  value = aws_lb.public.arn
}

output "public_alb_dns_name" {
  value = aws_lb.public.dns_name
}

output "https_listener_arn" {
  value = aws_lb_listener.https.arn
}
```

### Step 4: Import the Existing Resources Into the New Stack State

Rather than recreating the ALB (which would cause downtime), use `terraform import` to pull the existing AWS resources into the new `01-edge` state file.

```bash
cd environments/dev/us-east-1/01-edge
terraform init

# Import the existing resources by their AWS IDs
terraform import aws_lb.public <existing-alb-arn>
terraform import aws_security_group.alb_public <existing-sg-id>
terraform import aws_lb_listener.http <existing-http-listener-arn>
terraform import aws_lb_listener.https <existing-https-listener-arn>
```

Run `terraform plan` — it should show **no changes** if your config matches the live state.

> See [how-terraform-import-works.md](how-terraform-import-works.md) for a detailed walkthrough of the import process.

### Step 5: Remove the Resources From `01-compute`

Once the resources are safely in the `01-edge` state, remove them from `01-compute` in two sub-steps:

1. **Remove from state** (without destroying the real infrastructure):

   ```bash
   cd environments/dev/us-east-1/01-compute
   terraform state rm aws_lb.public
   terraform state rm aws_security_group.alb_public
   terraform state rm aws_lb_listener.http
   terraform state rm aws_lb_listener.https
   ```

2. **Delete the resource blocks** from `load_balancer.tf` in `01-compute`.

3. Run `terraform plan` in `01-compute` — it should show **no changes**.

### Step 6: Update `01-compute` to Consume `01-edge` Outputs

Anywhere `01-compute` previously referenced the public ALB directly, replace with a remote state data source:

```hcl
# 01-compute/data.tf
data "terraform_remote_state" "edge" {
  backend = "s3"
  config = {
    bucket = "your-terraform-state-bucket"
    key    = "dev/us-east-1/01-edge/terraform.tfstate"
    region = "us-east-1"
  }
}
```

Then reference outputs like:

```hcl
data.terraform_remote_state.edge.outputs.https_listener_arn
```

### Step 7: Lock Down CI/CD Permissions

- Grant the `01-edge` pipeline write access only to the Security/Network team.
- The `01-compute` pipeline retains its existing permissions.
- Add a policy that prevents `01-compute` from ever containing `aws_lb` resources with `internal = false`.

---

## Summary

| Phase         | Action                                                                     |
| :------------ | :------------------------------------------------------------------------- |
| **Now**       | Both ALBs in `load_balancer.tf` within `01-compute`                        |
| **Trigger**   | Security team takes ownership, or compliance requires audit separation     |
| **Migration** | Import public ALB into new `01-edge` stack, state rm from `01-compute`     |
| **End state** | `01-edge` owns public ingress; `01-compute` owns internal workload routing |

No downtime. No resource recreation. Pure state reorganisation.
