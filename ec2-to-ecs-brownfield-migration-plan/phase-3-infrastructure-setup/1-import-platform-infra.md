# Activity 1: Import Existing Platform Infrastructure (Network, RDS, Security Groups)

**Goal:** Bring existing VPC, network, database, and security foundation under Terraform management (`scale.infra-platform`).

## Context & Themes

This document details the process of importing legacy resources into the **Platform** Terraform state. This avoids recreating critical components and establishes the "Contract" that the Service layer will consume.

**Key Themes:**

- **Platform Layer:** Importing resources that are shared or foundational (`infra-platform`).
- **Risk Mitigation:** Avoiding disruption by importing existing components "as-is".
- **Separation of Concerns:** Security Groups and Databases belong to Platform; App compute belongs to Services.

### Prerequisites

- [ ] Terraform State Bootstrap plan completed.
- [ ] Platform Repository Setup completed.
- [ ] Terraform installed and configured locally.
- [ ] AWS credentials with sufficient permissions.
- [ ] List of VPC IDs, Subnet IDs, RDS Identifiers, and Security Group IDs from Phase 1 Discovery.

---

## Feature 1: Import existing platform Infrastructure to Terraform

**Business Value:** Brings all foundational manufacturing (VPC, Security, Data) under version control. By checking this into `scale.infra-platform`, we create a stable base for the application migration.

### Story 1.1: Import Network Layer (VPC, Subnets, Routing)

- **Title:** Import Existing VPC and Network Resources into Terraform State
- **Persona:** As a **DevOps engineer**, I need to import our existing VPC, subnets, and routing into Terraform so that we can manage network infrastructure as code without recreating or disrupting existing resources.

**Business Value:** Establishes Terraform management of network foundation without disrupting running services. Network import (1-2 hours) enables automated disaster recovery, prevents manual configuration drift, and provides audit trail of all network changes. One outage caused by undocumented manual route table changes can cost $50K-500K in lost revenue; Terraform prevents this by making all changes trackable and reversible.

- **Requirements:**
  - Existing VPC and network resources imported into `00-network` layer
  - Terraform code accurately represents current infrastructure state
  - `terraform plan` shows no changes (state matches reality)
  - No disruption to existing EC2 instances or services
  - Network configuration remains unchanged

- **Prerequisites:**
  - Phase 1 (Discovery) completed — you have documented all resource IDs, CIDRs, and configurations
  - Repository structure from [Terraform Bootstrap Plan Phase 1](../../terraform-state-bootstrap-plan/1-repository-setup.md) created
  - Terraform state backend from [Terraform Bootstrap Plan Phase 3](../../terraform-state-bootstrap-plan/3-bootstrap-dev.md) configured
  - Terraform and AWS CLI configured

- **Implementation Details:**

  #### Why Import Existing Infrastructure?

  **This is a brownfield migration**, not greenfield. You have:
  - Existing VPC with subnets, route tables, NAT gateways
  - Running EC2 instances serving production traffic
  - RDS databases and ElastiCache clusters in use
  - Security groups already configured

  **You cannot use `terraform apply` to create these** — they already exist. If you try, Terraform will error with "resource already exists."

  **The workflow is:**
  1. Write Terraform code that describes existing resources
  2. Import resources into Terraform state (`terraform import`)
  3. Verify state matches reality (`terraform plan` shows no changes)
  4. Now you can manage existing infrastructure via Terraform
  5. Add new Fargate resources alongside existing EC2 resources
  6. Eventually migrate traffic and decommission EC2

  #### 1) Navigate to Network Layer (in `infra-platform` repo)

  ```bash
  cd infra-platform/environments/dev/us-east-1/00-network
  ```

  #### 2) Create Terraform Configuration for Existing VPC

  **Create `main.tf` to describe existing VPC:**

  ```hcl
  terraform {
    required_version = ">= 1.7.0"

    backend "s3" {
      bucket         = "mycompany-terraform-state-dev"  # Created by infra-terraform-bootstrap
      key            = "infra-platform/dev/us-east-1/00-network/terraform.tfstate"
      region         = "us-east-1"
      dynamodb_table = "terraform-locks-dev"
      encrypt        = true
    }
  }

  provider "aws" {
    region = "us-east-1"
  }

  # Import existing VPC
  resource "aws_vpc" "existing" {
    cidr_block           = "10.0.0.0/16"  # Use actual CIDR from Phase 0 discovery
    enable_dns_hostnames = true
    enable_dns_support   = true

    tags = {
      Name = "existing-vpc"  # Use actual tag from discovery
    }
  }

  # Import existing public subnets (for ALB)
  resource "aws_subnet" "public_1a" {
    vpc_id            = aws_vpc.existing.id
    cidr_block        = "10.0.1.0/24"  # Actual CIDR from discovery
    availability_zone = "us-east-1a"

    tags = {
      Name = "public-subnet-1a"
    }
  }

  resource "aws_subnet" "public_1b" {
    vpc_id            = aws_vpc.existing.id
    cidr_block        = "10.0.2.0/24"  # Actual CIDR from discovery
    availability_zone = "us-east-1b"

    tags = {
      Name = "public-subnet-1b"
    }
  }

  # Import existing private subnets (for EC2/Fargate)
  resource "aws_subnet" "private_1a" {
    vpc_id            = aws_vpc.existing.id
    cidr_block        = "10.0.10.0/24"  # Actual CIDR from discovery
    availability_zone = "us-east-1a"

    tags = {
      Name = "private-subnet-1a"
    }
  }

  resource "aws_subnet" "private_1b" {
    vpc_id            = aws_vpc.existing.id
    cidr_block        = "10.0.11.0/24"  # Actual CIDR from discovery
    availability_zone = "us-east-1b"

    tags = {
      Name = "private-subnet-1b"
    }
  }

  # Import Internet Gateway
  resource "aws_internet_gateway" "existing" {
    vpc_id = aws_vpc.existing.id

    tags = {
      Name = "existing-igw"
    }
  }

  # Import NAT Gateway (if exists)
  resource "aws_eip" "nat" {
    domain = "vpc"

    tags = {
      Name = "nat-eip"
    }
  }

  resource "aws_nat_gateway" "existing" {
    allocation_id = aws_eip.nat.id
    subnet_id     = aws_subnet.public_1a.id

    tags = {
      Name = "existing-nat"
    }
  }

  # Import route tables
  resource "aws_route_table" "public" {
    vpc_id = aws_vpc.existing.id

    route {
      cidr_block = "0.0.0.0/0"
      gateway_id = aws_internet_gateway.existing.id
    }

    tags = {
      Name = "public-rt"
    }
  }

  resource "aws_route_table" "private" {
    vpc_id = aws_vpc.existing.id

    route {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.existing.id
    }

    tags = {
      Name = "private-rt"
    }
  }

  # Route table associations
  resource "aws_route_table_association" "public_1a" {
    subnet_id      = aws_subnet.public_1a.id
    route_table_id = aws_route_table.public.id
  }

  resource "aws_route_table_association" "public_1b" {
    subnet_id      = aws_subnet.public_1b.id
    route_table_id = aws_route_table.public.id
  }

  resource "aws_route_table_association" "private_1a" {
    subnet_id      = aws_subnet.private_1a.id
    route_table_id = aws_route_table.private.id
  }

  resource "aws_route_table_association" "private_1b" {
    subnet_id      = aws_subnet.private_1b.id
    route_table_id = aws_route_table.private.id
  }

  # Outputs for application layer to consume
  output "vpc_id" {
    value = aws_vpc.existing.id
  }

  output "vpc_cidr_block" {
    description = "The CIDR block of the VPC — consumed by downstream stacks (e.g. internal ALB security group) to avoid hardcoding the CIDR and ensure it stays in sync with the network layer"
    value       = aws_vpc.existing.cidr_block
  }

  output "public_subnet_ids" {
    value = [aws_subnet.public_1a.id, aws_subnet.public_1b.id]
  }

  output "private_subnet_ids" {
    value = [aws_subnet.private_1a.id, aws_subnet.private_1b.id]
  }
  ```

  #### 3) Initialize Terraform

  ```bash
  terraform init
  ```

  #### 4) Import VPC Resources

  **Use actual resource IDs from Phase 0 discovery:**

  ```bash
  # Import VPC
  terraform import aws_vpc.existing vpc-0abc123def456

  # Import subnets
  terraform import aws_subnet.public_1a subnet-0abc111
  terraform import aws_subnet.public_1b subnet-0abc222
  terraform import aws_subnet.private_1a subnet-0abc333
  terraform import aws_subnet.private_1b subnet-0abc444

  # Import Internet Gateway
  terraform import aws_internet_gateway.existing igw-0abc123

  # Import NAT Gateway resources
  terraform import aws_eip.nat eipalloc-0abc123
  terraform import aws_nat_gateway.existing nat-0abc123

  # Import route tables
  terraform import aws_route_table.public rtb-0abc111
  terraform import aws_route_table.private rtb-0abc222

  # Import route table associations
  terraform import aws_route_table_association.public_1a subnet-0abc111/rtb-0abc111
  terraform import aws_route_table_association.public_1b subnet-0abc222/rtb-0abc111
  terraform import aws_route_table_association.private_1a subnet-0abc333/rtb-0abc222
  terraform import aws_route_table_association.private_1b subnet-0abc444/rtb-0abc222
  ```

  #### 4) Import Security Groups

  Navigate to `scale.infra-platform` to import Security Groups. Ideally, these live in `00-network` or a dedicated `01-security` directory, depending on your module structure.

  ```bash
  cd infra-platform/environments/dev/us-east-1/00-network
  ```

  **Create `security_groups.tf`:**

  ```hcl
  # Import existing security groups
  resource "aws_security_group" "ec2_app" {
    name        = "ec2-app-sg"  # Actual name from discovery
    description = "Security group for EC2 application"
    vpc_id      = aws_vpc.main.id

    # Add actual ingress/egress rules from Phase 0 discovery
    ingress {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }

    egress {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }

    tags = {
      Name = "ec2-app-sg"
    }
  }

  resource "aws_security_group" "rds" {
    name        = "rds-sg"
    description = "RDS security group"
    vpc_id      = aws_vpc.main.id

    ingress {
      from_port       = 5432  # Postgres port
      to_port         = 5432
      protocol        = "tcp"
      security_groups = [aws_security_group.ec2_app.id]
    }

    tags = {
      Name = "rds-sg"
    }
  }

  # Exported so 02-storage can reference this SG when defining the RDS instance,
  # and so Activity 6 can add Fargate task SG rules to it.
  output "rds_sg_id" {
    description = "Security group ID for the RDS instance — consumed by 02-storage and by Activity 6 when adding Fargate task SG ingress rules."
    value       = aws_security_group.rds.id
  }
  ```

  Run the import command:

  ```bash
  terraform import aws_security_group.ec2_app sg-0123456789abcdef0
  terraform import aws_security_group.rds sg-0987654321fedcba0
  ```

  #### 5) Import RDS (Database Layer)

  Navigate to the storage directory in the platform repository.

  ```bash
  cd ../02-storage
  ```

  Create a `main.tf` file to define the RDS resource you are importing.

  ```hcl
  # scale.infra-platform/environments/dev/us-east-1/02-storage/main.tf

  # Data source to get VPC/SG info from local remote state or direct reference if inside same module
  data "terraform_remote_state" "network" {
    backend = "s3"
    config = {
      bucket = "mycompany-terraform-state-dev"
      key    = "infra-platform/dev/us-east-1/00-network/terraform.tfstate"
      region = "us-east-1"
    }
  }

  resource "aws_db_instance" "main" {
    # These values must match the existing RDS instance exactly
    identifier             = "my-existing-db" # Replace with actual DB identifier
    allocated_storage      = 20
    storage_type           = "gp2"
    engine                 = "postgres"
    engine_version         = "13.7"
    instance_class         = "db.t3.micro"
    name                   = "app_production"
    username               = "admin"
    password               = "TEMPORARY_PASSWORD_CHANGE_ME" # Will be ignored by lifecycle rule
    parameter_group_name   = "default.postgres13"
    skip_final_snapshot    = true

    # Reference the Security Group ID from the network state
    vpc_security_group_ids = [data.terraform_remote_state.network.outputs.rds_sg_id]
    db_subnet_group_name   = "default-vpc-xxxx"

    lifecycle {
      ignore_changes = [password] # Prevent Terraform from resetting password
    }
  }
  ```

  Run the import command:

  ```bash
  terraform import aws_db_instance.main my-existing-db
  ```

  #### 6) Verify Import

  Navigate to each directory (`00-network`, `02-storage`) and run:

  ```bash
  terraform plan
  # Should show: "No changes. Your infrastructure matches the configuration."
  # If it shows changes, adjust your Terraform code to match AWS reality
  ```

- **Acceptance Criteria:**
  - ✅ All existing network resources imported into `00-network` Terraform state
  - ✅ VPC created with DNS enabled (verified in imported state)
  - ✅ Connectivity tested from private subnet
  - ✅ Public and Private subnets confirmed in 2 AZs
  - ✅ `terraform plan` shows zero changes (state matches reality)
  - ✅ VPC, subnets, route tables, IGW, NAT all under Terraform management
  - ✅ `rds_sg_id` exported from `00-network` outputs (consumed by `02-storage`)
  - ✅ **Existing EC2 instances continue running normally — nothing disrupted**
