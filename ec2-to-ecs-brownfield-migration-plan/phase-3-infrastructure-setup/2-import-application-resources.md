# Activity 2: Import Legacy Application Workloads (EC2)

**Goal:** Bring existing application compute resources (EC2) under Terraform management (`scale.infra-services`) to prepare for migration.

## Context & Themes

This document specifically covers importing the **legacy compute** layer. By bringing the "Pets" (EC2) under Terraform control in the Services layer, we can manage them alongside the future "Cattle" (ECS Fargate) before decommissioning them.

**Key Themes:**

- **Services Layer:** Managing the application runtime (`infra-services`).
- **Legacy Management:** Bringing manually created resources under IaC.
- **Transitional State:** Creates a bridge where EC2 and ECS coexist in the same project structure.

## Conceptual: Legacy EC2 vs. Future ECS Fargate

| Feature      | **Legacy EC2 Instances** (This Step)                                               | **Future ECS Tasks** (Next Phase)                                   |
| :----------- | :--------------------------------------------------------------------------------- | :------------------------------------------------------------------ |
| **Location** | `scale.infra-services/environments/...`                                            | `scale.infra-services/modules/ecs-service`                          |
| **Role**     | **"Pets"**: Long-lived, manually configured servers running the application today. | **"Cattle"**: Ephemeral, auto-scaled containers managed by Fargate. |

_In this step, we are strictly focused on bringing the **Legacy EC2 Instances** under Terraform control so we can safely manage the transition._

## Prerequisites

- [ ] [Activity 1: Import Existing Platform Infrastructure](1-import-existing-infrastructure.md) is complete (VPC, RDS, Security Groups).
- [ ] Terraform initialized in `scale.infra-services`.
- [ ] List of EC2 Instance IDs from Phase 1 Discovery.

---

## Feature 2: Import Legacy Application to Terraform

**Business Value:** Enables the Service team to own their legacy infrastructure. Moving EC2 import to the Services layer allows developers to self-service the eventual teardown of these instances.

### Story 2.1: Import Legacy EC2 Instances

- Title: Import Existing EC2 Instances into Infra-Services
- **Persona:** As a **Service Owner**, I need to import my existing EC2 instances into the services repository so that I can manage my application's infrastructure in one place.

- **Requirements:**
  - Existing EC2 instances imported into `scale.infra-services` (Services Layer)
  - `terraform plan` shows no changes (state matches reality)
  - No disruption to running services
  - Instance configured to use Security Groups from Platform Layer

- **Implementation Details:**

  #### 1) Import EC2 (Compute Layer - Services)

  Navigate to the specific service directory in the **services** repository.

  ```bash
  # Example: Importing the legacy auth-api instance
  cd scale.infra-services/environments/dev/us-east-1/auth-api
  ```

  Create a `main.tf` file for the EC2 instance.

  ```hcl
  # scale.infra-services/environments/dev/us-east-1/auth-api/main.tf

  # Data source to read the Security Group from Platform layer
  data "terraform_remote_state" "platform" {
    backend = "s3"
    config = {
      bucket = "yourcompany-terraform-state"
      key    = "dev/platform/00-network/terraform.tfstate" # Point to where SGs are defined
      region = "us-east-1"
    }
  }

  resource "aws_instance" "app_server" {
    ami           = "ami-0c55b159cbfafe1f0" # Replace with actual AMI ID
    instance_type = "t3.micro"
    subnet_id     = "subnet-xxxxxxxx"

    # Use the Security Group ID from the Platform layer
    vpc_security_group_ids = [data.terraform_remote_state.platform.outputs.app_sg_id]

    tags = {
      Name = "Legacy-App-Server"
    }

    lifecycle {
      ignore_changes = [ami, user_data] # Avoid accidental resets
    }
  }
  ```

  Run the import command using the EC2 Instance ID:

  ```bash
  terraform import aws_instance.app_server i-0123456789abcdef0
  ```

  #### 2) Verify Import

  Run `terraform plan` to verify the code matches the state. Modify `main.tf` until the plan shows **No Changes**.

  #### 3) Document Import Commands

  **Typical issues after import:**
  - **Plan shows tag changes**: Update Terraform to match actual tags
  - **Password attributes**: Use `lifecycle { ignore_changes = [password] }` for RDS
  - **User data**: Use `lifecycle { ignore_changes = [user_data] }` for EC2
  - **AMI changes**: Use `lifecycle { ignore_changes = [ami] }` if AMI updates are manual

  **Refinement loop:**

  ```bash
  terraform plan
  # Adjust code or add ignore_changes
  # Repeat until no changes shown
  ```

  #### 5) Document Import Commands

  **Create `IMPORT_COMMANDS.md` in repository:**

  ```markdown
  # Terraform Import Commands

  ## Network Layer (00-network)

  terraform import aws_vpc.existing vpc-0abc123def456
  terraform import aws_subnet.public_1a subnet-0abc111

  # ... (all commands)

  ## Application Layer (10-application)

  terraform import aws_security_group.ec2_app sg-0abc111
  terraform import aws_instance.app_server i-0abc123def456
  terraform import aws_db_instance.main app-database

  # ... (all commands)
  ```

  This serves as documentation and disaster recovery if state is lost.

- **Acceptance Criteria:**
  - ✅ All existing application resources (EC2, RDS, security groups) imported into `10-application` state
  - ✅ `terraform plan` shows zero changes (state matches reality)
  - ✅ Import commands documented in repository
  - ✅ **Existing EC2 and databases continue running normally — nothing disrupted**
