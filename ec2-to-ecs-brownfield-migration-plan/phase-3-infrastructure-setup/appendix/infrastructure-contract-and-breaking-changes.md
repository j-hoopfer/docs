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
