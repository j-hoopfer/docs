# Epic 2: Core Infrastructure & Data Layer

**Goal:** Provision the "Stage" (VPC), the "Vault" (Secrets/DB), and the "Gatekeeper" (ACM/Security Groups).

**Duration:** 4–6 days

**Prerequisites:** Epic 0 complete, Terraform bootstrap deployed, `infrastructure-core` repo initialized.

---

## Story 2.0: Bootstrap Terraform State (Prerequisite)

**Status:** Should be completed from Epic 0, Story 0.5.

**Verify:**

```bash
cd ~/Projects/infrastructure-core/terraform/environments/dev
terraform init
# Should output: "Initializing the backend..." and reference your S3 bucket
```

If not complete, return to [Epic 0, Story 0.5](EPIC_0.md#story-05-terraform-workspace--bootstrap).

---

## Story 2.1: Provision Networking & Security Groups

As a Network Engineer
I want a VPC with strictly segmented subnets and firewalls
So that my database is unreachable from the internet and only accessible by the app

### Technical Requirements

- VPC with dual-mode NAT Gateway for private egress
- 6 subnets across 2 AZs: 2 public (ALB), 2 private app (ECS), 2 private DB
- Security Groups: ALB (80/443 from internet), App (3000 from ALB), DB (3306 from App only)
- DB subnet route table isolated (no IGW/NAT routes)
- All egress from DB blocked

### Implementation Details

**VPC Strategy:** Dual-mode (NAT Gateway for private egress; production-grade but cost-aware).

**Subnets:**

- Public (ALB): 2 subnets across 2 AZs
- Private (App/ECS): 2 subnets across 2 AZs
- Private (Database): 2 subnets across 2 AZs

**Security Groups (The "Strict Rules"):**

1. `sg_alb`: Allow 80/443 from `0.0.0.0/0`. Egress to `sg_app` on port 3000.
2. `sg_app`: Allow port 3000 **ONLY** from `sg_alb`. Egress to `sg_db` (port 3306) and `0.0.0.0/0` (for package updates).
3. `sg_db`: Allow port 3306 (MySQL) **ONLY** from `sg_app`. **No outbound internet access.**

### Terraform Structure

Create `terraform/modules/networking/main.tf`:

```hcl
variable "project" { type = string }
variable "environment" { type = string }
variable "vpc_cidr" { type = string }
variable "azs" { type = list(string) }

# VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "${var.project}-${var.environment}-vpc"
    Environment = var.environment
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags = { Name = "${var.project}-${var.environment}-igw" }
}

# Public Subnets (ALB)
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project}-${var.environment}-public-${count.index + 1}"
    Tier = "Public"
  }
}

# Private Subnets (App)
resource "aws_subnet" "private_app" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 2)
  availability_zone = var.azs[count.index]

  tags = {
    Name = "${var.project}-${var.environment}-private-app-${count.index + 1}"
    Tier = "PrivateApp"
  }
}

# Private Subnets (Database)
resource "aws_subnet" "private_db" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 4)
  availability_zone = var.azs[count.index]

  tags = {
    Name = "${var.project}-${var.environment}-private-db-${count.index + 1}"
    Tier = "PrivateDB"
  }
}

# NAT Gateway (for private subnet internet access)
# Note: Single NAT GW (~$32/mo) for Dev. For Prod HA, use count = length(var.azs)
# to provision 1 NAT Gateway per AZ (prevents outage if single AZ fails).
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.project}-${var.environment}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id  # TODO: For Prod, change to count-based for HA
  tags          = { Name = "${var.project}-${var.environment}-nat" }
}

# Route Tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project}-${var.environment}-public-rt" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${var.project}-${var.environment}-private-rt" }
}

# Database Route Table (Isolated - No Internet Access)
resource "aws_route_table" "database" {
  vpc_id = aws_vpc.main.id

  # No route to Internet Gateway
  # No route to NAT Gateway
  # Only implicit local VPC route exists

  tags = { Name = "${var.project}-${var.environment}-db-rt" }
}

# Route Table Associations
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_app" {
  count          = 2
  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_db" {
  count          = 2
  subnet_id      = aws_subnet.private_db[count.index].id
  route_table_id = aws_route_table.database.id  # Isolated - no internet route
}

# Security Groups
resource "aws_security_group" "alb" {
  name        = "${var.project}-${var.environment}-alb-sg"
  description = "Allow HTTP/HTTPS from internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description     = "To App containers"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  tags = { Name = "${var.project}-${var.environment}-alb-sg" }
}

resource "aws_security_group" "app" {
  name        = "${var.project}-${var.environment}-app-sg"
  description = "Allow traffic from ALB only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "From ALB"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description     = "To Database"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.db.id]
  }

  egress {
    description = "To Internet (for updates)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-${var.environment}-app-sg" }
}

resource "aws_security_group" "db" {
  name        = "${var.project}-${var.environment}-db-sg"
  description = "Allow MySQL from App only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "MySQL from App"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  # No egress rules = implicit deny

  tags = { Name = "${var.project}-${var.environment}-db-sg" }
}

# Outputs
output "vpc_id" { value = aws_vpc.main.id }
output "public_subnet_ids" { value = aws_subnet.public[*].id }
output "private_app_subnet_ids" { value = aws_subnet.private_app[*].id }
output "private_db_subnet_ids" { value = aws_subnet.private_db[*].id }
output "sg_alb_id" { value = aws_security_group.alb.id }
output "sg_app_id" { value = aws_security_group.app.id }
output "sg_db_id" { value = aws_security_group.db.id }
```

### Acceptance Criteria

- [ ] VPC created with /20 CIDR (e.g., `10.0.0.0/20`).
- [ ] 6 subnets created across 2 AZs (2 public, 2 private app, 2 private DB).
- [ ] Security: `sg_db` has **zero** rules allowing `0.0.0.0/0`.
- [ ] Connectivity: Private app subnet can reach internet (via NAT) but cannot be reached _from_ internet.
- [ ] `terraform plan` in `environments/dev` succeeds.

---

## Story 2.2: Provision Database (RDS MySQL)

As a Developer
I want a managed Relational Database Service (RDS)
So that my application state is persistent, backed up, and secure

### Technical Requirements

- MySQL 8.0 engine with utf8mb4 charset
- Instance class: `db.t4g.micro` (dev), `db.t4g.small` (prod)
- Storage: 20GB gp3 with autoscaling up to 100GB
- Multi-AZ deployment for production
- Password managed via Secrets Manager (not in Terraform state)
- Automated backups: 7 days (dev), 30 days (prod)
- Performance Insights enabled
- Private subnet deployment only

### Implementation Details

**Engine:** MySQL 8.0 (LTS, optimized for modern workloads)

**Instance Class:**

- Dev: `db.t4g.micro` (2 vCPU, 1GB RAM, burstable, ~$12/month)
- Prod: `db.t4g.small` or `db.r6g.large` (Multi-AZ)

**Storage:** 20GB gp3 (autoscaling enabled up to 100GB)

**Subnet Group:** Must use the **Private DB Subnets** from Story 2.1.

**Credentials:** Use `manage_master_user_password = true` (AWS auto-generates password and stores in Secrets Manager).

**Backups:**

- Dev: 7-day retention
- Prod: 30-day retention, automated snapshots

### Terraform Module

Create `terraform/modules/database/main.tf`:

```hcl
variable "project" { type = string }
variable "environment" { type = string }
variable "vpc_id" { type = string }
variable "db_subnet_ids" { type = list(string) }
variable "db_security_group_id" { type = string }
variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}

# DB Subnet Group
resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-${var.environment}-db-subnet-group"
  subnet_ids = var.db_subnet_ids

  tags = {
    Name        = "${var.project}-${var.environment}-db-subnet-group"
    Environment = var.environment
  }
}

# DB Parameter Group (MySQL 8.0 tuning)
resource "aws_db_parameter_group" "main" {
  name   = "${var.project}-${var.environment}-mysql8"
  family = "mysql8.0"

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }

  parameter {
    name  = "max_connections"
    value = "100"
  }

  tags = { Environment = var.environment }
}

# RDS Instance
resource "aws_db_instance" "main" {
  identifier     = "${var.project}-${var.environment}-db"
  engine         = "mysql"
  engine_version = "8.0.35"
  instance_class = var.instance_class

  # Storage
  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  # Networking
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.db_security_group_id]
  publicly_accessible    = false

  # Credentials (Modern approach - no passwords in state)
  db_name                     = replace("${var.project}${var.environment}", "-", "_")
  username                    = "dbadmin"
  manage_master_user_password = true

  # Parameter Group
  parameter_group_name = aws_db_parameter_group.main.name

  # Backups
  backup_retention_period = var.environment == "prod" ? 30 : 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "mon:04:00-mon:05:00"

  # Snapshots
  skip_final_snapshot       = var.environment == "dev" ? true : false
  final_snapshot_identifier = var.environment == "prod" ? "${var.project}-${var.environment}-final-snapshot-${formatdate("YYYY-MM-DD-hhmm", timestamp())}" : null

  # Protection
  deletion_protection = var.environment == "prod" ? true : false

  # Monitoring
  enabled_cloudwatch_logs_exports = ["error", "general", "slowquery"]
  performance_insights_enabled    = var.environment == "prod" ? true : false

  tags = {
    Name        = "${var.project}-${var.environment}-db"
    Environment = var.environment
  }
}

# Outputs
output "db_instance_endpoint" {
  value       = aws_db_instance.main.endpoint
  description = "RDS instance endpoint"
}

output "db_instance_address" {
  value       = aws_db_instance.main.address
  description = "RDS instance address (hostname only)"
}

output "db_name" {
  value       = aws_db_instance.main.db_name
  description = "Database name"
}

output "db_username" {
  value       = aws_db_instance.main.username
  description = "Master username"
}

output "db_secret_arn" {
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
  description = "ARN of the Secrets Manager secret containing the DB password"
  sensitive   = true
}
```

### Acceptance Criteria

- [ ] RDS instance running in **private DB subnets**.
- [ ] `publicly_accessible = false` verified in console.
- [ ] Connection test: Cannot connect to DB from laptop (unless using VPN/bastion).
- [ ] Master password stored in AWS Secrets Manager (not visible in Terraform state).
- [ ] CloudWatch Logs enabled for error/slow query tracking.
- [ ] Deletion protection enabled for prod.

### Security Note

The database password is **never** in your Terraform state. Retrieve it via:

```bash
aws secretsmanager get-secret-value \
  --secret-id <secret-arn-from-output> \
  --query SecretString \
  --output text | jq -r .password
```

---

## Story 2.3: Provision Container Registry (ECR)

As a DevOps Engineer
I want a private container registry
So that I can store Docker images securely in AWS

### Technical Requirements

- Private ECR repository for auth-api
- Image scanning on push enabled
- Tag mutability: MUTABLE (for dev flexibility)
- Lifecycle policy: expire untagged images after 7 days
- Repository URL output for CI/CD integration

### Implementation Details

Create `terraform/modules/ecr/main.tf`:

```hcl
variable "project" { type = string }
variable "environment" { type = string }
variable "repository_names" {
  type    = list(string)
  default = ["auth-api"]
}

resource "aws_ecr_repository" "repos" {
  for_each = toset(var.repository_names)
  name     = "${var.project}/${each.value}"

  image_scanning_configuration {
    scan_on_push = true
  }

  image_tag_mutability = "MUTABLE"

  tags = {
    Name        = "${var.project}/${each.value}"
    Environment = var.environment
  }
}

# Lifecycle Policy (expire untagged images after 7 days)
resource "aws_ecr_lifecycle_policy" "repos" {
  for_each   = aws_ecr_repository.repos
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 7 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 7
      }
      action = { type = "expire" }
    }]
  })
}

output "repository_urls" {
  value = { for k, v in aws_ecr_repository.repos : k => v.repository_url }
}
```

### Acceptance Criteria

- [ ] ECR repository created.
- [ ] Image scanning on push enabled.
- [ ] Lifecycle policy active (untagged images deleted after 7 days).

---

## Story 2.4: Secrets & Config (SSM + Secrets Manager)

As a Security Engineer
I want to distinguish between "Configuration" and "Credentials"
So that I pay less for config (SSM) and get rotation for credentials (Secrets Manager)

### Technical Requirements

- SSM Parameter Store (Standard tier) for non-sensitive configuration
- Secrets Manager for high-value credentials (API keys, tokens)
- Cost optimization: Free SSM vs $0.40/secret/month for Secrets Manager
- Terraform outputs ARNs only, never secret values
- DB password auto-managed in Secrets Manager (from Story 2.2)

### Implementation Details

**Strategy:**

| Type        | Service                        | Cost               | Use Case                                  |
| ----------- | ------------------------------ | ------------------ | ----------------------------------------- |
| Config      | SSM Parameter Store (Standard) | Free               | Feature flags, API URLs, public keys      |
| Credentials | AWS Secrets Manager            | $0.40/secret/month | DB passwords, API keys (Stripe, SendGrid) |

### Implementation Details

Create `terraform/modules/secrets/main.tf`:

```hcl
variable "project" { type = string }
variable "environment" { type = string }

# SSM Parameters (Config)
resource "aws_ssm_parameter" "app_config" {
  for_each = {
    "backend_url"    = "https://api.example.com"
    "frontend_url"   = "https://app.example.com"
    "log_level"      = "info"
    "feature_signup" = "enabled"
  }

  name  = "/${var.project}/${var.environment}/config/${each.key}"
  type  = "String"
  value = each.value

  tags = { Environment = var.environment }
}

# Secrets Manager (High-Value Credentials)
resource "aws_secretsmanager_secret" "api_keys" {
  for_each = toset(["stripe_api_key", "sendgrid_api_key"])

  name        = "/${var.project}/${var.environment}/secrets/${each.value}"
  description = "Managed secret for ${each.value}"

  tags = { Environment = var.environment }
}

# Placeholder values (update manually or via CI/CD)
resource "aws_secretsmanager_secret_version" "api_keys" {
  for_each      = aws_secretsmanager_secret.api_keys
  secret_id     = each.value.id
  secret_string = jsonencode({ value = "REPLACE_ME" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

output "ssm_parameter_arns" {
  value = { for k, v in aws_ssm_parameter.app_config : k => v.arn }
}

output "secrets_manager_arns" {
  value = { for k, v in aws_secretsmanager_secret.api_keys : k => v.arn }
}
```

### Acceptance Criteria

- [ ] Non-sensitive config stored in SSM (e.g., `/myapp/dev/config/backend_url`).
- [ ] High-value secrets in Secrets Manager (e.g., `/myapp/dev/secrets/stripe_api_key`).
- [ ] Terraform outputs ARNs only (never values).
- [ ] DB password is auto-managed in Secrets Manager (from Story 2.2).

---

## Story 2.5: Setup SSL Certificate (ACM)

As a Network Engineer
I want an SSL certificate for my domain
So that the ALB can serve HTTPS traffic

### Technical Requirements

- ACM certificate for primary domain and wildcard subdomain
- DNS validation method via Route 53
- Auto-creation of validation records
- Certificate ARN output for ALB integration
- Lifecycle: create_before_destroy for zero-downtime rotation

### Implementation Details

Create `terraform/modules/acm/main.tf`:

```hcl
variable "domain_name" { type = string }
variable "zone_id" { type = string }

resource "aws_acm_certificate" "main" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  subject_alternative_names = ["*.${var.domain_name}"]

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = var.domain_name }
}

# Auto-create DNS validation records
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id = var.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

output "certificate_arn" { value = aws_acm_certificate.main.arn }
```

### Acceptance Criteria

- [ ] ACM certificate requested.
- [ ] DNS validation records auto-created in Route 53.
- [ ] Certificate status: `Issued`.

---

## Terraform Directory Structure (Updated)

```text
infrastructure-core/
├── terraform/
│   ├── bootstrap/                   # S3 + DynamoDB (Epic 0)
│   ├── modules/
│   │   ├── networking/              # VPC, Subnets, Security Groups
│   │   ├── database/                # RDS MySQL, Subnet Group, Parameter Group
│   │   ├── ecr/                     # Container Registry
│   │   ├── secrets/                 # SSM + Secrets Manager
│   │   └── acm/                     # SSL Certificates
│   └── environments/
│       ├── dev/
│       │   ├── main.tf              # Calls modules in order
│       │   ├── variables.tf
│       │   ├── outputs.tf
│       │   └── versions.tf          # Backend config (from Epic 0)
│       └── prod/
```

### Example `environments/dev/main.tf`

```hcl
terraform {
  required_version = ">= 1.7.0"
}

provider "aws" {
  region = "us-east-1"
}

variable "project" { default = "myapp" }
variable "environment" { default = "dev" }

module "networking" {
  source      = "../../modules/networking"
  project     = var.project
  environment = var.environment
  vpc_cidr    = "10.0.0.0/20"
  azs         = ["us-east-1a", "us-east-1b"]
}

module "database" {
  source                = "../../modules/database"
  project               = var.project
  environment           = var.environment
  vpc_id                = module.networking.vpc_id
  db_subnet_ids         = module.networking.private_db_subnet_ids
  db_security_group_id  = module.networking.sg_db_id
  instance_class        = "db.t4g.micro"
}

module "ecr" {
  source           = "../../modules/ecr"
  project          = var.project
  environment      = var.environment
  repository_names = ["auth-api"]
}

module "secrets" {
  source      = "../../modules/secrets"
  project     = var.project
  environment = var.environment
}

module "acm" {
  source      = "../../modules/acm"
  domain_name = "myapp.com"
  zone_id     = "Z1234567890ABC"  # From Route 53
}

output "db_endpoint" { value = module.database.db_instance_endpoint }
output "ecr_urls" { value = module.ecr.repository_urls }
```

---

## ✅ Epic 2 Definition of Done

1. **Networking:** VPC with 6 subnets (public, private app, private DB) across 2 AZs; NAT Gateway provisioned.
2. **Security Groups:** ALB, App, and DB security groups follow least-privilege (DB unreachable from internet).
3. **Database:** RDS MySQL 8.0 running in private subnets; password auto-managed in Secrets Manager.
4. **Registry:** ECR repository created with scan-on-push and lifecycle policies.
5. **Secrets:** SSM for config, Secrets Manager for credentials; Terraform outputs ARNs only.
6. **SSL:** ACM certificate issued and validated via Route 53.
7. **Cost Awareness:** NAT Gateway (~$35/month) is the primary cost driver; document in team wiki.

### Database & Persistence

- [ ] **Isolation:** DB is in a private subnet; no public IP.
- [ ] **Access:** Only the ECS Security Group (port 3306) and the Bastion/VPN can touch the DB.
- [ ] **Secrets:** DB Password is NOT in Terraform state. It is in Secrets Manager.
- [ ] **Backups:** Automated daily backups enabled (Retention: 7 days Dev, 30 days Prod).
