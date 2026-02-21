# Appendix: Organizing Terraform Projects

This document outlines the standard architecture for organizing infrastructure-as-code. It moves from high-level best practices to specific definitions and implementation details.

## 1. Core Best Practices

We follow these four "Golden Rules" to maintain scalability and prevent "deployment fear":

1.  **One State File per Logical Unit ("Stack"):** Never put all infrastructure in one massive state file. Split them by lifecycle (e.g., Network changes rarely; Compute changes often).
2.  **Split Files by Feature, Not Resource:** Inside a stack, group resources by their _logical purpose_ (e.g., `vpc.tf` contains subnets/routes), not their _resource type_ (e.g., avoid `subnets.tf`).
3.  **Modules for Patterns, Stacks for Instances:** Use Modules to define _how_ something is built (the blueprint). Use Stacks (Environments) to define _where_ it is built (the house).
4.  **Predictable Hierarchy:** The directory structure must map 1:1 to the AWS Account/Region/Workload structure.

---

## 2. Component Definitions

To communicate effectively, we distinguish between these terms:

### A. The Business Environment

**Definition:** The high-level lifecycle stage of the organization.

- **Examples:** `Dev`, `Staging`, `Prod`.
- **Scope:** Contains _many_ Terraform Stacks. Maps to a high-level folder like `environments/dev/` or an AWS Account.

### B. The Terraform Stack (Root Module)

**Definition:** A single deployable unit of infrastructure with its own `terraform.tfstate` file.

- **Examples:** `00-network`, `ecs-service-payments`, `02-storage`.
- **Scope:** This is the smallest unit you can run `terraform apply` on. It often represents a single "layer" of infrastructure.

### C. The Shared Module

**Definition:** A reusable library of Terraform code that creates nothing until called.

- **Examples:** `modules/vpc`, `modules/ecs-service`.
- **Scope:** Versioned blueprints. They interact with no specific AWS account until instantiated by a Stack.

---

## 3. Implementation Strategy

This is how we apply the concepts and best practices to our file system.

### A. The Directory Hierarchy (Macro-Structure)

We arrange Stacks inside Business Environments. Stacks are always **siblings** under the Region folder.

```text
scale.infra-platform/              <-- Project Repository
├── environments/
│   ├── shared-network/            <-- Env: Shared Services (Networking Account)
│   │   └── us-east-1/
│   │       ├── 00-transit-hub/    <-- Stack: Transit Gateway (The Hub)
│   │       │   ├── tgw.tf
│   │       │   ├── tgwe.tf
│   │       │   ├── backend.tf
│   │       │   └── outputs.tf
│   │       ├── 01-egress-dev/     <-- Stack: VPC for Dev Egress
│   │       │   ├── vpc.tf
│   │       │   ├── backend.tf
│   │       │   └── outputs.tf
│   │       └── 01-egress-prod/    <-- Stack: VPC for Prod Egress
│   │           └── ...
│   ├── dev/                       <-- Env: Dev (Workload Account)
│   │   └── us-east-1/
│   │       ├── 00-network/        <-- Stack: Spoke VPC (No IGW)
│   │       │   ├── vpc.tf
│   │       │   └── backend.tf
│   │       └── 01-compute/        <-- Stack: ECS Cluster & Nodes
│   └── prod/                      <-- Env: Prod (Workload Account)
│       └── ...
└── modules/                       <-- Shared Modules
    └── vpc/                       <-- Blueprint for any VPC
```

### B. File Organization (Micro-Structure)

Inside a specific _Terraform Stack_ (e.g., `00-network`), we group files by **Logical Resource Group**.

**The Goal:** A developer should understand a feature by opening _one_ file, not five.

| File Name            | Logical Group       | Contents                                                                               |
| :------------------- | :------------------ | :------------------------------------------------------------------------------------- |
| `vpc.tf`             | **Core Networking** | The VPC _plus_ its tightly coupled children: Subnets, Route Tables, IGW, NAT Gateways. |
| `security_groups.tf` | **Firewalls**       | All Security Groups and Rules. (Split this file if it exceeds 300 lines).              |
| `backend.tf`         | **State Config**    | S3 bucket and DynamoDB locking configuration.                                          |
| `provider.tf`        | **AWS Config**      | Region, Profile, and `default_tags`.                                                   |
| `variables.tf`       | **Inputs**          | CIDR blocks, environment names.                                                        |
| `outputs.tf`         | **Exports**         | Easy consumption for other stacks (e.g., `vpc_id`).                                    |

**Anti-Patterns to Avoid:**

- ❌ **The Monolith:** Putting everything in `main.tf`.
- ❌ **Micro-Files:** Creating `subnet_a.tf`, `subnet_b.tf`, `route_public.tf`. (Too fragmented).

### C. Numbering Prefix Strategy (`00-`, `01-`)

You will notice directories prefixed with numbers (e.g., `00-network`). This is a **purely human-readable convention** to indicate dependency order.

**Does Terraform use these numbers?**
No. Terraform has no concept of "multi-directory" execution. It runs strictly within the one directory you point it to. It does not know that `00-network` exists while it is running `01-compute`.

**Why use them?**

1.  **Visual Sorting:** It keeps your file explorer sorted logically. Without numbers, `compute` would appear before `network` alphabetically, which is the reverse of their deployment order.
2.  **Deployment Runbook:** It tells the human (or CI/CD script) the required order of operations:
    - _"Run everything starting with `00-` first."_
    - _"Once those succeed, run everything starting with `01-`."_

**The Tiers:**

- **`00-` (Foundation):** VPCs, IAM Roles, EZ-Setup. (Must exist before anything else).
- **`01-` (Infrastructure):** ECS Clusters, Databases, Load Balancers. (Depends on Foundation).
- **`02-` (Services):** Application containers, Lambda functions. (Depends on Infrastructure).

**Why duplicate numbers (e.g., multiple `01-`)?**
If two stacks are siblings that do not depend on _each other_, they can share a number.

- Example: `01-rds-postgres` and `01-redis-cache`. Neither needs the other to exist; they both just need the VPC (`00-network`). You can deploy them in parallel.

### Nuance: Dependency vs. Category

Sometimes a resource fits a **Category** (like Networking) but must be deployed later due to **Dependency**.

- **Example:** In our Shared Network, the Egress VPCs (`01-egress-dev`) are technically "Networks". You might expect them to be `00-`.
- **Reasoning:** They cannot connect until the Transit Gateway (`00-transit-hub`) exists. Therefore, we bump them to `01-` to signal: _"Build the Hub first (00), THEN build the Egress VPCs (01)."_
- **Rule:** When in doubt, **Dependency wins**. If Stack B needs Stack A, Stack B must have a higher number.

---

## 4. Use Cases: Adding New Infrastructure

How do these rules apply when you need to create something new?

### Use Case A: Adding a new VPC (e.g., for Data Isolation)

**Scenario:** You need a separate network for sensitive data in `dev`.

- **Action:** Create a **New Stack** (Folder). Do _not_ add code to existing `00-network`.
- **Structure:**
  ```text
  environments/dev/us-east-1/
  ├── 00-network-app/   (Existing)
  └── 00-network-data/  (NEW Separate Stack)
  ```
- **Why:** You want to be able to destroy the App network without accidentally touching the Data network.

### Use Case B: Adding a new Service (e.g., Payment API)

**Scenario:** A new microservice container needs to be deployed.

- **Action:** Create a **New Stack** (Folder) in the Services repository.
- **Structure:**
  ```text
  scale.infra-services/environments/dev/us-east-1/
  ├── auth-api/      (Existing)
  └── payment-api/   (NEW Stack)
  ```
- **Why:** Deploying "Payment API" should never block or risk "Auth API".

### Use Case C: Adding a Route to an Existing VPC

**Scenario:** You need to add a route to a Peering Connection in the existing Dev network.

- **Action:** Edit the **Existing File** (`vpc.tf`) in the existing Stack (`00-network`).
- **Why:** A route is a child resource of the VPC table. It belongs in the Core Networking logical group.

### Use Case D: Adding Shared Infrastructure (e.g., Transit Gateway)

**Scenario:** You need to deploy a central hub that multiple environments (dev, prod) will connect to.

- **Action:** Create a **New Business Environment** (Folder) if it's a separate account (e.g., `shared-network`), or a **New Stack** if it's in a shared "Tools" account.
- **Structure:**
  ```text
  environments/shared-network/us-east-1/
  └── 00-transit/  (NEW Separate Stack)
  ```
- **Why:** Shared services must have an independent lifecycle. You must be able to update the Hub without locking the Spoke (Dev) state files.
