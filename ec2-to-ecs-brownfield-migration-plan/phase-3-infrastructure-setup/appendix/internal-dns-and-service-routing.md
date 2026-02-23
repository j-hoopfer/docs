# Appendix: Internal DNS and Service Routing

## The Problem This Solves

When a service inside your VPC wants to call another service, it needs an address. The naive options are bad:

- **Hardcoded IP** — ECS tasks get new IPs every time they restart. This breaks immediately.
- **ALB DNS name** — Works, but looks like `shared-internal-alb-1234567890.us-east-1.elb.amazonaws.com`. Your code is now coupled to an infrastructure name that could change.
- **Service name** — `http://auth.corp.internal` — stable, human-readable, infrastructure-agnostic. This is what we want.

The private hosted zone + internal ALB combination gives you the third option.

---

## The Four-Part Chain

No single resource makes this work. It requires four pieces applied in order across two phases:

```
Phase 3 (this activity)          Phase 5 (per-service deployment)
─────────────────────────        ──────────────────────────────────
1. Private hosted zone           3. DNS alias record
2. Internal ALB + listener       4. ALB listener rule + target group
```

Stories 4.3 and 4.4 only deliver parts 1 and 2. The zone is empty and the ALB has no routing rules — nothing resolves yet. Parts 3 and 4 are added by each service when it deploys.

---

## Full Call Path: Service A Calls Service B

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  VPC (10.0.0.0/16)                                                          │
│                                                                             │
│  ┌──────────────┐     1. DNS query                ┌──────────────────────┐  │
│  │  Service A   │  ──────────────────────────────▶│  Route 53 Resolver   │  │
│  │  (ECS task)  │     "auth.corp.internal"         │  (VPC DNS, .2 addr)  │  │
│  └──────────────┘                                 └──────────┬───────────┘  │
│                                                              │               │
│                                                  2. Looks up │               │
│                                                  corp.internal               │
│                                                  private zone │               │
│                                                              ▼               │
│                                                  ┌──────────────────────┐    │
│                                                  │  Private Hosted Zone │    │
│                                                  │  corp.internal       │    │
│                                                  │                      │    │
│                                                  │  auth.corp.internal  │    │
│                                                  │  → ALIAS → internal  │    │
│                                                  │    ALB DNS name      │    │
│                                                  └──────────┬───────────┘    │
│                                                             │                │
│                                                  3. Returns │                │
│                                                  internal ALB IP             │
│                                                             │                │
│  ┌──────────────┐     4. HTTP request             ┌────────▼─────────────┐  │
│  │  Service A   │  ──────────────────────────────▶│   Internal ALB       │  │
│  │  (ECS task)  │  Host: auth.corp.internal        │                      │  │
│  └──────────────┘                                 │  Listener rules:     │  │
│                                                   │  ┌─────────────────┐ │  │
│                                                   │  │ Host=auth.*     │ │  │
│                                                   │  │ → auth-svc-tg   │ │  │
│                                                   │  ├─────────────────┤ │  │
│                                                   │  │ Host=users.*    │ │  │
│                                                   │  │ → users-svc-tg  │ │  │
│                                                   │  └─────────────────┘ │  │
│                                                   └──────────┬───────────┘  │
│                                                              │               │
│                                                  5. Forward  │               │
│                                                  to target   │               │
│                                                  group       │               │
│                                                              ▼               │
│                                              ┌───────────────────────────┐  │
│                                              │  auth-service target group │  │
│                                              │  ┌──────────┐             │  │
│                                              │  │ ECS task │ 10.0.1.45   │  │
│                                              │  └──────────┘             │  │
│                                              │  ┌──────────┐             │  │
│                                              │  │ ECS task │ 10.0.2.112  │  │
│                                              │  └──────────┘             │  │
│                                              └───────────────────────────┘  │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

**What each step is doing:**

| Step | What happens                                                            | Resource responsible                                   |
| :--- | :---------------------------------------------------------------------- | :----------------------------------------------------- |
| 1    | Service A resolves `auth.corp.internal`                                 | VPC DNS resolver (built-in, always on)                 |
| 2    | Resolver finds the private zone and looks up the record                 | `aws_route53_zone.internal` (Story 4.4)                |
| 3    | Returns the internal ALB's DNS name as an ALIAS                         | `aws_route53_record` in auth-service stack (Phase 5)   |
| 4    | Service A connects to the ALB, sends `Host: auth.corp.internal`         | `aws_lb.internal` (Story 4.3)                          |
| 5    | ALB matches the host header rule, forwards to auth's target group       | `aws_lb_listener_rule` in auth-service stack (Phase 5) |
| 6    | ALB picks a healthy task from the target group and delivers the request | `aws_lb_target_group` in auth-service stack (Phase 5)  |

---

## What Gets Built When (Two-Phase View)

### Phase 3 — Shared infrastructure (Stories 4.3 + 4.4)

```
corp.internal zone          Internal ALB
┌─────────────┐             ┌──────────────────────────┐
│             │             │                          │
│  (empty)    │             │  Listener :80            │
│             │             │  Default: 404            │
└─────────────┘             │                          │
                            └──────────────────────────┘
```

The zone exists but has no records. The ALB exists but has no routing rules. Nothing resolves or routes yet — this is intentional. The shared infrastructure is the skeleton; services flesh it out.

---

### Phase 5 — Auth service deploys (one example)

```
corp.internal zone          Internal ALB
┌──────────────────────┐    ┌──────────────────────────┐
│                      │    │                          │
│  auth.corp.internal  │    │  Listener :80            │
│  → ALIAS → ALB DNS   │    │  ┌──────────────────┐   │
│                      │    │  │ Host=auth.*       │   │
└──────────────────────┘    │  │ → auth-svc-tg     │   │
                            │  └──────────────────┘   │
                            │  Default: 404            │
                            │                          │
                            └──────────────────────────┘
                                         │
                                         ▼
                            ┌────────────────────────┐
                            │  auth-svc target group │
                            │  task 10.0.1.45:8080   │
                            │  task 10.0.2.112:8080  │
                            └────────────────────────┘
```

---

### Phase 5 — Users service also deploys

```
corp.internal zone          Internal ALB
┌──────────────────────┐    ┌──────────────────────────┐
│                      │    │                          │
│  auth.corp.internal  │    │  Listener :80            │
│  → ALIAS → ALB DNS   │    │  ┌──────────────────┐   │
│                      │    │  │ Host=auth.*       │   │
│  users.corp.internal │    │  │ → auth-svc-tg     │   │
│  → ALIAS → ALB DNS   │    │  ├──────────────────┤   │
│                      │    │  │ Host=users.*      │   │
└──────────────────────┘    │  │ → users-svc-tg    │   │
                            │  └──────────────────┘   │
                            │  Default: 404            │
                            └──────────────────────────┘
```

Both services share the same ALB and zone — each service only adds its own slice.

---

## Why the DNS Record Points to the ALB, Not Directly to the Tasks or Instances

### ECS Fargate tasks

ECS Fargate tasks get **ephemeral IPs** from the VPC CIDR. Every time a task is replaced — deployment, crash, scale event — it gets a new IP. The old IP is released immediately. If you pointed DNS at `10.0.1.45`, that IP dies when the task dies and DNS goes stale. Any caller that cached the old DNS response will fail until TTL expires.

```
Stable                            Dynamic
──────                            ───────
auth.corp.internal                10.0.1.45  ← task replaced → IP gone
→ internal-alb.elb.amazonaws.com  10.0.2.112  ← task replaced → IP gone
  (never changes)                 10.0.3.88  ← task replaced → IP gone
```

### EC2 instances — similar problem, different failure mode

EC2 instances behave differently depending on state:

| Event                                        | Private IP behaviour                                       |
| :------------------------------------------- | :--------------------------------------------------------- |
| **Reboot**                                   | IP is retained                                             |
| **Stop → Start**                             | IP is **released and reassigned** — you get a different IP |
| **Terminate**                                | IP is released immediately                                 |
| **Elastic Network Interface (ENI) attached** | IP is stable as long as the ENI exists                     |

A running EC2 instance that is never stopped does have a stable private IP. But relying on that creates a brittle dependency:

- **No health checking** — if the instance is running but the application on it is crashed, DNS still resolves. Callers get a connection refused or timeout.
- **No failover** — if the instance is unhealthy, callers are stuck until DNS TTL expires and you've manually updated the record.
- **No scale-out** — you can't put two instances behind one DNS name without also managing round-robin TTLs, which ALBs handle better.
- **Stop/start breaks it silently** — a routine maintenance stop reassigns the private IP, breaking all callers that cached the DNS value.

### The right pattern for EC2 — same as ECS, register in the ALB target group

Even for a single EC2 instance, the correct pattern is to register it in an ALB target group by **instance ID**, not by IP. The ALB then:

- Health-checks the application port (not just the OS)
- Removes the instance from rotation on unhealthy checks
- Handles IP changes transparently — it resolves the instance IP internally at health-check time

```
auth.corp.internal
→ ALIAS → internal ALB (stable)
    │
    └── target group (by instance ID, not IP)
            └── i-0abc123def456  ← EC2 instance
                (ALB resolves its current IP at health-check time)
```

The DNS record and ALB listener rule are identical whether the target is an ECS task or an EC2 instance — the difference is only in how the target group is populated.

### When you might point DNS directly at an EC2 IP

There are two legitimate cases:

1. **Bastion / jump host** — a bastion doesn't serve application traffic. You want `bastion.corp.internal → 10.0.1.5` as a convenience record for SSH. A TTL of 300s is fine; if it breaks, an engineer updates the record manually. This isn't in the critical traffic path.

2. **Single-instance tooling with a static ENI** — tools like a HAProxy instance, a NAT instance, or a legacy appliance that you've deliberately given a static ENI. The ENI's IP never changes as long as the ENI exists. A DNS record pointing at it is stable. Even here, prefer the ALB pattern if the tool supports HTTP health checks.

For anything in a service call path, always go through the ALB.

---

## Private Zone Naming — What to Use and What to Avoid

This is where most of the horror stories come from. The name of the private hosted zone determines which DNS queries get intercepted by Route 53. Pick the wrong name and queries silently fail, or public DNS stops working from inside the VPC.

### ❌ Never use `.local`

This is the most common trap. macOS and Linux resolve `.local` via **mDNS (Multicast DNS / Bonjour)** — a peer-to-peer protocol that bypasses the VPC DNS resolver entirely. Queries for `auth.corp.local` never reach Route 53; they're broadcast on the local network segment and silently drop.

This is also the source of most Active Directory horror stories. Companies that set their AD domain to `corp.local` (a very common historical default) discover that none of their Linux or macOS clients can resolve AD resources from inside AWS VPCs. The fix is a painful AD domain rename.

```
❌  corp.local    →  resolved via mDNS, never reaches Route 53
✅  corp.internal →  goes through VPC resolver, reaches Route 53 private zone
```

### ❌ Don't shadow your public domain

If you create a private hosted zone named `scale-consulting.io` — the same as your public zone — Route 53 will route **all** queries for that domain from inside the VPC to the private zone instead of the public one. Any public record that doesn't exist in the private zone becomes unreachable from inside the VPC: CloudFront distributions, external SaaS OAuth callback URLs, third-party API endpoints that use your domain, etc.

This pattern is called **split-horizon DNS** (or split-brain DNS). It's sometimes intentional, but it creates a maintenance burden: every public record you add must also be duplicated in the private zone, or it silently breaks for VPC-originated traffic.

The AD version of this is companies whose AD domain is `company.com` — their actual public domain. All internal DNS resolution works, but all traffic to public `company.com` resources from inside the VPC breaks.

```
❌  scale-consulting.io  as a private zone name
    → shadows your public zone
    → public records unreachable from inside VPC unless manually duplicated

✅  corp.internal
    → no public zone to shadow
    → completely separate namespace
```

### Safe naming options

| Name                           | Safe? | Notes                                                                                                           |
| :----------------------------- | :---- | :-------------------------------------------------------------------------------------------------------------- |
| `corp.internal`                | ✅    | Conventional, two-level, no mDNS or shadow conflict                                                             |
| `svc.internal`                 | ✅    | Same reasoning, slightly shorter                                                                                |
| `internal.scale-consulting.io` | ✅    | Subdomain of a domain you own — cleanest if you ever add VPN/Direct Connect so on-prem clients resolve the zone |
| `scale-consulting.io`          | ⚠️    | Only if you intentionally want split-horizon and will maintain both zones in sync                               |
| `corp.local`                   | ❌    | mDNS conflict on macOS and Linux                                                                                |
| anything ending in `.local`    | ❌    | Same                                                                                                            |

### Why two levels (`.corp.internal`) instead of just `.internal`?

`.internal` is an unregistered TLD — it works today, but ICANN occasionally creates new TLDs. Using a second level (`corp.internal`) that you control eliminates any future public collision risk. It also reads more clearly: `auth.corp.internal` vs `auth.internal` — the former is unambiguous to any developer that it's a private non-routable address.

### Should the Zone Name Include the Environment?

This is a genuine design choice with real tradeoffs. There are two camps:

---

#### Option A — Same zone name across all environments (`corp.internal` everywhere)

```
dev account VPC   →  private zone: corp.internal
prod account VPC  →  private zone: corp.internal
```

**The key insight:** isolation is already enforced by the VPC boundary, not the zone name. A private hosted zone is associated with a specific VPC. A query from inside the dev VPC can only resolve records in the dev zone. Prod is a completely separate VPC with its own zone. Both zones are named `corp.internal` but they never see each other — they're as isolated as two files named `README.md` in different directories.

```
dev VPC                          prod VPC
───────────────────────          ───────────────────────
corp.internal zone               corp.internal zone
  auth.corp.internal               auth.corp.internal
  → dev internal ALB               → prod internal ALB
  (10.0.x.x)                       (172.16.x.x)

Queries from dev VPC             Queries from prod VPC
only resolve dev zone            only resolve prod zone
```

**Benefit:** your service Terraform code is environment-agnostic. The DNS record resource looks identical in dev and prod — just the target (the ALB DNS name from remote state) changes. No environment-specific conditionals, no variable substitution in the zone name.

```hcl
# This exact block works in both dev and prod — the zone_id
# comes from remote state, which points at the right zone per environment.
resource "aws_route53_record" "auth_internal" {
  zone_id = data.terraform_remote_state.compute.outputs.private_zone_id
  name    = "auth.corp.internal"  # same in both envs
  ...
}
```

---

#### Option B — Environment-prefixed zone names (`dev.corp.internal`, `prod.corp.internal`)

```
dev account VPC   →  private zone: dev.corp.internal
prod account VPC  →  private zone: prod.corp.internal
```

**When this adds genuine value:**

1. **VPN or Direct Connect is in scope.** If developer laptops or on-premises machines will resolve your private zone over a VPN tunnel, environment-prefixed names let a single machine distinguish between dev and prod services without needing split DNS on the client side. `auth.dev.corp.internal` and `auth.prod.corp.internal` can coexist in a Route 53 Resolver forwarding rule profile.

2. **Cross-account debugging tools** that query multiple VPCs simultaneously. Tools like AWS Systems Manager Fleet Manager or a centralised observability stack can resolve records from multiple environments at once — environment-prefixed names prevent ambiguity.

3. **Shared network account pattern.** If you use a Transit Gateway with a shared network account that can route to all environments, names like `dev.corp.internal` and `prod.corp.internal` become necessary to disambiguate within the same resolver context.

**Cost:** every service stack now has an environment-specific DNS name baked in, either via a variable or a conditional. The record:

```hcl
name = "auth.${var.environment}.corp.internal"
```

This is manageable, but it means the service URL your application code calls is different in dev vs prod (`http://auth.dev.corp.internal` vs `http://auth.prod.corp.internal`). That's usually handled via environment variable injection into the container, but it's one more thing to get right per deployment.

---

#### Recommendation for this architecture

Use **Option A** (same zone name, `corp.internal`) unless you know you need VPN or cross-account resolver access soon.

The VPC boundary provides the isolation you need. Option A keeps service Terraform simpler and means the URL a service calls is identical across environments — the only thing that changes is what the name resolves to, which is exactly how environment isolation should work.

If VPN or Direct Connect comes into scope later, it's straightforward to add environment-prefixed names at that point — you'd rename the zone and update the records, which Terraform handles cleanly with `create_before_destroy`.

---

### Summary: the two decisions and their defaults

| Decision               | Default         | Change if...                                                                                                      |
| :--------------------- | :-------------- | :---------------------------------------------------------------------------------------------------------------- |
| Zone name TLD          | `corp.internal` | You add VPN/Direct Connect and need cross-environment resolution — use `dev.corp.internal` / `prod.corp.internal` |
| Same name across envs? | Yes             | Only if you have a shared network account or cross-VPC resolver in scope from the start                           |

---

## Does Every Service Get Its Own Internal ALB?

No — that would defeat the purpose. All internal services share **one internal ALB**. The listener rule on that ALB is what distinguishes which service gets the request. This is the same pattern as the public ALB.

```
                         ┌─────────────────────────┐
service-a.corp.internal  │                         │
service-b.corp.internal  │   ONE internal ALB      │
service-c.corp.internal  │   Many listener rules   │
         All resolve     │                         │
         to same ALB ───▶│  Host=service-a → tg-a  │
                         │  Host=service-b → tg-b  │
                         │  Host=service-c → tg-c  │
                         │  Default: 404           │
                         └─────────────────────────┘
```

The ALB costs ~$16/month. Without sharing, each service would need its own (~$16 × N services).

---

## How Does the Strangler Fig Pattern Use This?

During migration, both the old EC2 instance and the new Fargate task can be registered in the **same target group** with weighted routing — or in two separate target groups with a weighted listener rule.

```
auth.corp.internal
    │
    ▼
Internal ALB listener rule (weighted forward)
    ├── 80% → fargate target group (new)
    └── 20% → ec2 target group    (old, being phased out)
```

You shift traffic gradually: 20/80 → 50/50 → 90/10 → 100/0, monitoring error rates at each step. When you're confident, drain the EC2 target group and deregister the old instance. The DNS record and ALB rule never change — only the weights do.

---

## What Outputs Does Story 4.4 Need to Export?

The private zone ID must be exported from `01-compute` so service stacks can write records into it:

```hcl
output "private_zone_id" {
  description = "Route 53 private hosted zone ID — service stacks register corp.internal alias records here"
  value       = aws_route53_zone.internal.zone_id
}
```

A service stack then consumes it:

```hcl
data "terraform_remote_state" "compute" {
  backend = "s3"
  config  = { ... }
}

resource "aws_route53_record" "auth_internal" {
  zone_id = data.terraform_remote_state.compute.outputs.private_zone_id
  name    = "auth.corp.internal"
  type    = "A"

  alias {
    name                   = data.terraform_remote_state.compute.outputs.internal_alb_dns_name
    zone_id                = data.terraform_remote_state.compute.outputs.internal_alb_zone_id
    evaluate_target_health = true
  }
}
```

---

## Acceptance Criteria for the Full Chain

Story 4.4 only establishes the zone. The full chain is only testable once at least one service has deployed in Phase 5. At that point:

- [ ] `nslookup auth.corp.internal` resolves from inside the VPC (e.g., from an EC2 bastion or ECS exec session)
- [ ] `curl http://auth.corp.internal` returns a response from the auth service (not the ALB 404 default)
- [ ] Deploying a new auth task (task replacement) does not break `curl http://auth.corp.internal` — the ALB absorbs the task churn transparently

---

## Route 53 Private DNS vs Active Directory DNS

These two DNS systems look similar on the surface — both resolve internal names, both are invisible from the public internet — but they serve fundamentally different purposes and operate at different layers.

### What each one does

|                         | Route 53 Private DNS                                                                    | Active Directory DNS                                                                                          |
| :---------------------- | :-------------------------------------------------------------------------------------- | :------------------------------------------------------------------------------------------------------------ |
| **Purpose**             | Resolves service names to load balancer addresses inside AWS                            | Resolves Windows hostnames, domain controllers, Kerberos service records, GPO distribution points             |
| **What it knows about** | ALB DNS names, ECS task aliases, RDS endpoints, anything you explicitly register        | Windows machine names, AD sites and services, `_ldap._tcp.corp.com` SRV records, `_kerberos._tcp` SRV records |
| **Who queries it**      | ECS tasks, Lambda functions, any VPC workload                                           | Windows clients, Linux machines joined to the domain, anything doing LDAP/Kerberos auth                       |
| **Record management**   | You manage records via Terraform                                                        | AD manages records automatically as machines join/leave the domain                                            |
| **Health awareness**    | ALB alias records have `evaluate_target_health = true` — unhealthy targets are excluded | None — AD DNS just returns IPs; availability is handled by domain controller redundancy                       |
| **Zone type**           | Route 53 private hosted zone, VPC-associated                                            | Windows DNS zone, replicated across domain controllers via AD replication                                     |

### Why they don't replace each other

Route 53 private DNS has no concept of Kerberos, GSSAPI, LDAP, or group policy. It can't tell your VPC workloads who to authenticate with or enforce domain membership. AD DNS has no concept of ECS task health, ALB weighted routing, or Terraform-managed infrastructure. You need both if you have both Windows workloads and containerised services.

### Three convergence patterns

#### Pattern 1 — Completely separate namespaces (simplest, most common)

AD uses `corp.company.com`. Route 53 uses `corp.internal`. They never interact. VPC workloads that need to do LDAP/AD lookups point directly at the domain controller IPs (or use [AWS Managed Microsoft AD](https://docs.aws.amazon.com/directoryservice/latest/admin-guide/directory_microsoft_ad.html), which registers into the VPC DNS resolver automatically).

```
corp.internal  →  Route 53 private zone  →  service ALB aliases
corp.company.com  →  AD DNS on DCs  →  Windows hostnames, SRV records

No overlap. No forwarding rules needed.
```

This is fine as long as your ECS services don't need to resolve AD names and your Windows machines don't need to resolve `corp.internal` names.

---

#### Pattern 2 — Route 53 Resolver forwarding rules (hybrid, most flexible)

When workloads in the VPC need to resolve both AD names and service names, you use **Route 53 Resolver forwarding rules** to split queries by namespace:

```
Query for *.corp.internal     →  Route 53 private zone  (served locally)
Query for *.corp.company.com  →  Forwarded to domain controller IPs
Query for anything else       →  Public DNS (Route 53 resolver default)
```

```
┌─────────────────────────────────────────────────────────────┐
│  VPC DNS Resolver (169.254.169.253)                         │
│                                                             │
│  Forwarding rules:                                          │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ corp.internal        → Route 53 private zone        │    │
│  │ corp.company.com     → 10.0.10.5 (DC1)              │    │
│  │                        10.0.10.6 (DC2)              │    │
│  │ <everything else>    → public Route 53              │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

This is the clean solution for orgs running a mix of Windows workloads (joined to AD) and containerised workloads (needing service discovery). The Terraform resources for this are `aws_route53_resolver_rule` and `aws_route53_resolver_rule_association`.

> **Note:** The domain controllers must be reachable from the VPC — either running in the VPC itself, reachable via VPN/Direct Connect, or provided by AWS Managed Microsoft AD.

---

#### Pattern 3 — AD-integrated zone for everything (avoid unless forced)

Some organisations try to host `corp.internal` inside Active Directory DNS and have Route 53 forward all internal queries to the domain controllers. This means:

- Every service DNS record must be manually added to AD DNS (no Terraform automation)
- AD replication latency can cause stale records during deployments
- Losing domain controller connectivity breaks all service-to-service calls, not just Windows auth
- AD admins become a dependency for every service deployment

This pattern couples your service deployment pipeline to your Windows AD team. Avoid it unless your AD team is the one running the containers.

---

### The `.corp.local` trap in hybrid environments

The classic hybrid horror story: an organisation whose AD domain is `corp.local`. They extend into AWS. Two things break simultaneously:

1. **macOS/Linux VPC workloads** — `.local` is resolved via mDNS, never reaching Route 53 or the AD DCs. These machines can't resolve AD names at all.
2. **Windows machines** — Windows doesn't use mDNS for domain resolution, so AD queries work. But any AWS-native internal DNS (`corp.internal` or similar) needs to be set up separately.

The result is an environment where Windows and Linux/container workloads have fundamentally different DNS behaviour, leading to intermittent failures that are extremely hard to diagnose.

If your AD domain is `corp.local`, the correct long-term fix is an AD domain rename to `corp.company.com` (or similar) — a disruptive but one-time operation. The short-term workaround for containers is to avoid the AD namespace entirely and use a Route 53 private zone with a completely different name (`corp.internal`, `svc.internal`, etc.).

---

### Quick reference: which system answers which query

| Query                         | Answered by                 | Where record lives                 |
| :---------------------------- | :-------------------------- | :--------------------------------- |
| `auth.corp.internal`          | Route 53 private zone       | Terraform, per-service stack       |
| `users.corp.internal`         | Route 53 private zone       | Terraform, per-service stack       |
| `dc01.corp.company.com`       | AD DNS on domain controller | AD, auto-registered on domain join |
| `_ldap._tcp.corp.company.com` | AD DNS on domain controller | AD, auto-registered                |
| `scale-consulting.io`         | Public Route 53             | Terraform, payer account           |
| `s3.amazonaws.com`            | Public DNS                  | AWS                                |
