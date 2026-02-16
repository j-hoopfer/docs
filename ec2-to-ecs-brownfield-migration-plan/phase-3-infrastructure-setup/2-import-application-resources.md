# Activity 2: Import Application Layer (EC2, RDS, Security Groups)

**Goal:** Bring existing compute and database resources under Terraform management to prepare for Fargate.

## Context & Themes

This document specifically covers bringing the **stateful** and **compute** layers of your application under existing infrastructure management. This assumes the network layer (VPC, Subnets) has already been imported.

**Key Themes:**

- **Legacy Management:** Bringing manually created resources under IaC.
- **Risk Mitigation:** Avoiding disruption by importing existing network components.
- **Infrastructure as Code:** Establishing the foundation for automated configuration.

## Prerequisites

- [ ] [Activity 1: Import Network Infrastructure](1-import-existing-infrastructure.md) is complete.
- [ ] Terraform initialized in `10-application` layer.
- [ ] List of EC2 Instance IDs, RDS Identifiers, and Security Group IDs from Phase 1 Discovery.

---

## Feature 2: Import Application Infrastructure to Terraform

**Business Value:** Enables disaster recovery and change tracking for critical stateful resources. By importing EC2 and RDS into Terraform (2-3 hours), we prevent manual drift and ensure that the "old world" (EC2) and "new world" (Fargate) can coexist in the same codebase.

### Story 2.1: Import Application Resources

- Title: Import Existing EC2, RDS, and Security Groups into Terraform State
- **Persona:** As a **DevOps engineer**, I need to import existing EC2 instances, RDS databases, and security groups into Terraform so that all infrastructure is managed as code in preparation for Fargate migration.

**Business Value:** Brings existing compute and database resources under Terraform management for disaster recovery and change tracking. Application import (2-3 hours) enables team to manage EC2 instances, RDS databases, and security groups as code, preventing manual drift that causes 60% of security incidents and compliance failures.

- **Requirements:**
  - Existing EC2 instances imported into `10-application` layer
  - Existing RDS databases imported
  - Existing security groups imported
  - `terraform plan` shows no changes (state matches reality)
  - No disruption to running services

- **Implementation Details:**

  #### 1) Navigate to Application Layer

  ```bash
  cd ../10-application
  ```

  #### 2) Create Terraform Configuration for Existing Resources

  **Create `main.tf`:**

  ```hcl
  terraform {
    required_version = ">= 1.7.0"

    backend "s3" {
      bucket         = "yourcompany-terraform-state-123456789012"
      key            = "dev/10-application/terraform.tfstate"
      region         = "us-east-1"
      dynamodb_table = "terraform-state-lock"
      encrypt        = true
    }
  }

  provider "aws" {
    region = "us-east-1"
  }

  # Reference network layer outputs
  data "terraform_remote_state" "network" {
    backend = "s3"
    config = {
      bucket = "yourcompany-terraform-state-123456789012"
      key    = "dev/00-network/terraform.tfstate"
      region = "us-east-1"
    }
  }

  # Import existing security groups
  resource "aws_security_group" "ec2_app" {
    name        = "ec2-app-sg"  # Actual name from discovery
    description = "Security group for EC2 application"
    vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

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
    vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

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

  # Import existing EC2 instance
  resource "aws_instance" "app_server" {
    ami           = "ami-0abc123def456"  # Actual AMI from discovery
    instance_type = "t3.medium"          # Actual instance type

    subnet_id              = data.terraform_remote_state.network.outputs.private_subnet_ids[0]
    vpc_security_group_ids = [aws_security_group.ec2_app.id]

    tags = {
      Name = "legacy-app-server"
    }

    # Prevent accidental replacement during import
    lifecycle {
      ignore_changes = [ami, user_data]
    }
  }

  # Import RDS instance
  resource "aws_db_instance" "main" {
    identifier     = "app-database"  # Actual DB identifier
    engine         = "postgres"
    engine_version = "14.7"          # Actual version from discovery
    instance_class = "db.t3.medium"  # Actual instance class

    allocated_storage = 100
    storage_type      = "gp3"

    db_name  = "appdb"
    username = "dbadmin"
    password = "PLACEHOLDER"  # Use Secrets Manager; will ignore changes

    vpc_security_group_ids = [aws_security_group.rds.id]
    db_subnet_group_name   = aws_db_subnet_group.main.name

    backup_retention_period = 7
    skip_final_snapshot     = false
    final_snapshot_identifier = "app-database-final-snapshot"

    lifecycle {
      ignore_changes = [password]
    }

    tags = {
      Name = "app-database"
    }
  }

  resource "aws_db_subnet_group" "main" {
    name       = "app-db-subnet-group"
    subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids

    tags = {
      Name = "app-db-subnet-group"
    }
  }
  ```

  #### 3) Import Application Resources

  ```bash
  terraform init

  # Import security groups
  terraform import aws_security_group.ec2_app sg-0abc111
  terraform import aws_security_group.rds sg-0abc222

  # Import EC2 instance
  terraform import aws_instance.app_server i-0abc123def456

  # Import RDS resources
  terraform import aws_db_subnet_group.main app-db-subnet-group
  terraform import aws_db_instance.main app-database

  # Verify
  terraform plan
  # Should show minimal or no changes
  ```

  #### 4) Handle Common Import Drift

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
