# Activity 1: Import Existing Network Infrastructure

**Goal:** Bring existing VPC and network foundation under Terraform management to prepare for Fargate.

## Context & Themes

This document details the process of importing legacy resources (VPC, Subnets) into Terraform state. This avoids recreating critical networking components.

**Key Themes:**

- **Legacy Management:** Bringing manually created resources under IaC.
- **Risk Mitigation:** Avoiding disruption by importing existing network components.
- **Infrastructure as Code:** Establishing the foundation for automated configuration.

### Prerequisites

- [ ] Terraform State Bootstrap completed (S3 bucket and DynamoDB table exist).
- [ ] Platform Repository Setup completed with `backend.tf` files ([Phase 0, Story 1.3](../../ec2-to-ecs-brownfield-migration-plan/phase-0-prerequisites/1-platform-repository-setup.md#story-13-configure-terraform-backend-and-providers)).
- [ ] Terraform installed and configured locally.
- [ ] AWS credentials with sufficient permissions (VPC, EC2, IAM read/write).
- [ ] Access to the AWS Console for ID lookups (VPC IDs, Subnet IDs).

**Important:** Phase 0 configured the repository with a **Layered State** approach. This means each account and each layer (`00-network`, `01-compute`) has its own `backend.tf` and state file. This ensures proper isolation between the shared Network account and Workload accounts.

---

## Feature 1: Import Existing Infrastructure to Terraform

**Business Value:** Brings existing production infrastructure under version control and enables safe, tracked changes. Importing existing resources (3-4 hours) prevents manual drift, enables disaster recovery through code, and allows the team to manage both EC2 and Fargate infrastructure in one place. Organizations managing infrastructure manually spend 10-15 hours/month tracking changes across environments; Terraform reduces this to minutes.

We utilize a 3-Repository strategy to separate concerns and minimize blast radius:

1. `infra-terraform-bootstrap` (State Buckets & Locks)
2. `infra-platform` (Shared networking, ECS Cluster, and other common infrastructure)
3. `infra-services` (App-specific resources like Task Definitions and Target Groups)

This activity focuses on the `infra-platform` repository.

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

  #### 1) Navigate to Environment Directory (in `infra-platform` repo)

  For the Shared Network, we work in the `network` account folder.

  ```bash
  cd infra-platform/environments/network/us-east-1/00-network
  ```

  **Expected directory structure from Phase 0:**

  ```
  environments/network/us-east-1/00-network/
  ├── backend.tf       # Layer-specific S3 backend
  ├── provider.tf      # Layer-specific AWS provider
  ├── versions.tf      # Layer-specific versions
  └── (Resources will be added here: vpc.tf, variables.tf, etc.)
  ```

  **Note:** Each layer manages its own state. Resources in `01-compute` (Workload Account) will read VPC details from this layer's state using `terraform_remote_state`.

  #### 2) Verify Existing Configuration Files

  ```bash
  # Verify backend.tf exists inside the layer
  cat backend.tf
  # Should show the S3 backend configuration for this specific layer

  # Verify provider.tf exists inside the layer
  cat provider.tf
  # Should show the AWS provider with region and default tags for 'network'
  ```

  #### 3) Gather Resource IDs from AWS

  **Create a helper script to retrieve all network resource IDs:**

  ```bash
  # Create scripts directory
  mkdir -p scripts

  # Create the discovery script
  cat > scripts/get-import-ids.sh << 'EOF'
  #!/bin/bash
  ```

# Script to retrieve AWS network resource IDs for Terraform import

set -e

# VPC ID - Get this from AWS Console or use this command first

echo "Enter your VPC ID (e.g., vpc-0abc123def456):"
read VPC_ID

echo "=== VPC ==="
aws ec2 describe-vpcs --vpc-ids $VPC_ID \
 --query 'Vpcs[0].[VpcId,CidrBlock,Tags[?Key==`Name`].Value|[0]]' \
 --output table

echo ""
echo "=== Subnets ==="
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
 --query 'Subnets[].[Tags[?Key==`Name`].Value|[0],SubnetId,CidrBlock,AvailabilityZone]' \
 --output table

echo ""
echo "=== Internet Gateway ==="
aws ec2 describe-internet-gateways \
 --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
 --query 'InternetGateways[0].[InternetGatewayId,Tags[?Key==`Name`].Value|[0]]' \
 --output table

echo ""
echo "=== NAT Gateways ==="
aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" \
 --query 'NatGateways[].[NatGatewayId,SubnetId,NatGatewayAddresses[0].AllocationId,Tags[?Key==`Name`].Value|[0]]' \
 --output table

echo ""
echo "=== Route Tables ==="
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
 --query 'RouteTables[].[RouteTableId,Tags[?Key==`Name`].Value|[0],Associations[].SubnetId]' \
 --output table

echo ""
echo "=== Route Table Associations ==="
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
 --query 'RouteTables[].Associations[].[RouteTableAssociationId,SubnetId,RouteTableId]' \
 --output table
EOF

chmod +x scripts/get-import-ids.sh

````

**Run the script to gather all resource IDs:**

```bash
./scripts/get-import-ids.sh
````

**Save the output** - you'll use these IDs in the next steps to:

1. Populate the resource definitions in `vpc.tf` (Step 4)
2. Run the import commands (Step 6)

**Example output:**

```
=== Subnets ===
┌────────────────────┬─────────────────────┬──────────────┬──────────────┐
│ public-subnet-1a   │ subnet-0abc111      │ 10.0.1.0/24  │ us-east-1a   │
│ public-subnet-1b   │ subnet-0abc222      │ 10.0.2.0/24  │ us-east-1b   │
│ private-subnet-1a  │ subnet-0abc333      │ 10.0.10.0/24 │ us-east-1a   │
│ private-subnet-1b  │ subnet-0abc444      │ 10.0.11.0/24 │ us-east-1b   │
└────────────────────┴─────────────────────┴──────────────┴──────────────┘
```

**Pro tip:** Save the output to a file for reference:

```bash
./scripts/get-import-ids.sh > network-ids.txt
```

#### 4) Create Network Resource Definitions

**Create `us-east-1/00-network/vpc.tf` using the IDs from Step 3:**

Replace the example values below with actual values from your `get-import-ids.sh` output.

```hcl
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
```

**Create `us-east-1/00-network/outputs.tf` for downstream consumption:**

```hcl
# Outputs for application layer to consume
output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.existing.id
}

output "public_subnet_ids" {
  description = "IDs of public subnets (for ALB)"
  value       = [aws_subnet.public_1a.id, aws_subnet.public_1b.id]
}

output "private_subnet_ids" {
  description = "IDs of private subnets (for ECS tasks)"
  value       = [aws_subnet.private_1a.id, aws_subnet.private_1b.id]
}
```

**Resulting file structure:**

```
environments/dev/
├── backend.tf          # Backend (from Phase 0)
├── provider.tf         # Provider (from Phase 0)
├── versions.tf         # Versions (from Phase 0)
├── us-east-1/
│   ├── 00-network/
│   │   ├── vpc.tf      # VPC and network resources (NEW)
│   │   └── outputs.tf  # Output values (NEW)
│   ├── 01-compute/
│   ├── 02-storage/
│   └── 03-monitoring/
└── us-west-2/
```

**Important:** Since we're using a single state file per environment, all layers (00-network, 01-compute, etc.) and all regions (us-east-1, us-west-2) are managed together in one Terraform run. The `backend.tf`, `provider.tf`, and `versions.tf` files at the `environments/dev/` level are shared across all layers and regions.

#### 5) Initialize Terraform

```bash
# Run from the environment directory
# You should be in: infra-platform/environments/dev/
terraform init
```

This initializes the backend and downloads providers for the entire environment (all layers and all regions together).

#### 6) Import VPC Resources

**Use the actual resource IDs from Step 3 (get-import-ids.sh output):**

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

**Pro tip:** Create an import script to avoid copy-paste errors:

```bash
cat > scripts/import-network.sh << 'EOF'
#!/bin/bash
# Paste your actual resource IDs here from get-import-ids.sh output

terraform import aws_vpc.existing vpc-0abc123def456
terrafo8m import aws_subnet.public_1a subnet-0abc111
terraform import aws_subnet.public_1b subnet-0abc222
terraform import aws_subnet.private_1a subnet-0abc333
terraform import aws_subnet.private_1b subnet-0abc444
terraform import aws_internet_gateway.existing igw-0abc123
terraform import aws_eip.nat eipalloc-0abc123
terraform import aws_nat_gateway.existing nat-0abc123
terraform import aws_route_table.public rtb-0abc111
terraform import aws_route_table.private rtb-0abc222
terraform import aws_route_table_association.public_1a subnet-0abc111/rtb-0abc111
terraform import aws_route_table_association.public_1b subnet-0abc222/rtb-0abc111
terraform import aws_route_table_association.private_1a subnet-0abc333/rtb-0abc222
terraform import aws_route_table_association.private_1b subnet-0abc444/rtb-0abc222
EOF

chmod +x scripts/import-network.sh
./scripts/import-network.sh
```

#### 7) Verify Import

```bash
terraform plan
# Should show: "No changes. Your infrastructure matches the configuration."
# If it shows changes, adjust your Terraform code to match AWS reality
```

#### 7) Iterative Refinement

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

### Next Steps

- Proceed to [Activity 1.2: Import Application Layer (EC2, RDS)](1.2-import-application-resources.md) to bring compute and database resources under management.
