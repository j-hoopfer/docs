# Activity 1: Import Existing Infrastructure

## Overview

This activity imports existing infrastructure into Terraform and provisions new AWS resources for Fargate. The goal is to bring existing EC2, RDS, and network infrastructure under Terraform management, then build new Fargate resources alongside them.

**Key Principle for Brownfield Migration:**

1. **Import existing infrastructure first** (VPC, EC2, RDS) — don't recreate what already exists
2. **Build new Fargate resources** (ECS Cluster, Task Definitions, Services) alongside existing infrastructure
3. **Migrate traffic gradually** from EC2 to Fargate in later phases

---

## Feature 1: Import Existing Infrastructure to Terraform

**Business Value:** Brings existing production infrastructure under version control and enables safe, tracked changes. Importing existing resources (3-4 hours) prevents manual drift, enables disaster recovery through code, and allows the team to manage both EC2 and Fargate infrastructure in one place. Organizations managing infrastructure manually spend 10-15 hours/month tracking changes across environments; Terraform reduces this to minutes.

### Story 1.1: Import Network Layer (VPC, Subnets, Routing)

**Business Value:** Establishes Terraform management of network foundation without disrupting running services. Network import (1-2 hours) enables automated disaster recovery, prevents manual configuration drift, and provides audit trail of all network changes. One outage caused by undocumented manual route table changes can cost $50K-500K in lost revenue; Terraform prevents this by making all changes trackable and reversible.

- **Title:** Import Existing VPC and Network Resources into Terraform State
- **Persona:** As a **DevOps engineer**, I need to import our existing VPC, subnets, and routing into Terraform so that we can manage network infrastructure as code without recreating or disrupting existing resources.

- **Requirements:**
  - Existing VPC and network resources imported into `00-network` layer
  - Terraform code accurately represents current infrastructure state
  - `terraform plan` shows no changes (state matches reality)
  - No disruption to existing EC2 instances or services
  - Network configuration remains unchanged

- **Prerequisites:**
  - Phase 0 (Discovery) completed — you have documented all resource IDs, CIDRs, and configurations
  - Repository structure from Phase -1 Story 3.1 created
  - Terraform state backend from Phase -1 Story 3.2 configured
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

  #### 1) Navigate to Network Layer

  ```bash
  cd terraform/environments/dev/00-network
  ```

  #### 2) Create Terraform Configuration for Existing VPC

  **Create `main.tf` to describe existing VPC:**

  ```hcl
  terraform {
    required_version = ">= 1.7.0"

    backend "s3" {
      bucket         = "yourcompany-terraform-state-123456789012"  # From Phase -1
      key            = "dev/00-network/terraform.tfstate"
      region         = "us-east-1"
      dynamodb_table = "terraform-state-lock"
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

  #### 5) Verify Import

  ```bash
  terraform plan
  # Should show: "No changes. Your infrastructure matches the configuration."
  # If it shows changes, adjust your Terraform code to match AWS reality
  ```

  #### 6) Iterative Refinement

  **Common drift after import:**
  - **Plan shows tag differences**: Update Terraform code to match actual tags
  - **Plan shows minor attribute differences**: Add to `lifecycle { ignore_changes = [...] }` if not important
  - **Route propagation settings**: Match what's in AWS Console

  **Iterative process:**

  ```bash
  # 1. Run plan
  terraform plan

  # 2. If changes shown, either:
  #    a) Update Terraform code to match AWS reality, OR
  #    b) Add to ignore_changes if attribute not important

  # 3. Repeat until plan shows zero changes
  ```

- **Acceptance Criteria:**
  - ✅ All existing network resources imported into `00-network` Terraform state
  - ✅ VPC created with DNS enabled (verified in imported state)
  - ✅ S3 VPC Endpoint created (or verified existing)
  - ✅ Connectivity tested from private subnet
  - ✅ Public and Private subnets confirmed in 2 AZs
  - ✅ `terraform plan` shows zero changes (state matches reality)
  - ✅ VPC, subnets, route tables, IGW, NAT all under Terraform management
  - ✅ **Existing EC2 instances continue running normally — nothing disrupted**

---

### Story 1.2: Import Application Layer (EC2, RDS, Security Groups)

**Business Value:** Brings existing compute and database resources under Terraform management for disaster recovery and change tracking. Application import (2-3 hours) enables team to manage EC2 instances, RDS databases, and security groups as code, preventing manual drift that causes 60% of security incidents and compliance failures.

- **Title:** Import Existing EC2, RDS, and Security Groups into Terraform State
- **Persona:** As a **DevOps engineer**, I need to import existing EC2 instances, RDS databases, and security groups into Terraform so that all infrastructure is managed as code in preparation for Fargate migration.

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
