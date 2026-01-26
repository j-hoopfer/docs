# ECS Fargate Migration Plan - Phase 2: Infrastructure Setup

## Overview

This phase provisions the shared AWS infrastructure that all migrated applications will use. The goal is to build a secure, cost-optimized foundation once—then deploy multiple applications on top of it.

**Key Principle:** Build shared resources (VPC, ALB, ECS Cluster) first, then per-application resources (Security Groups, Task Definitions, Services) in Phase 3.

---

## Feature 0: Terraform State Management

**Before provisioning any infrastructure, you must set up remote Terraform state management.** This ensures state is durable, encrypted, and team-accessible. Without this, you'll face state corruption, conflicts, and lost infrastructure.

### Story 0.1: Bootstrap Terraform State Backend

- **Title:** Create S3 Bucket and DynamoDB Table for Terraform State
- **Persona:** As a **DevOps engineer**, I want remote Terraform state storage so that infrastructure state is durable, encrypted, and supports team collaboration with state locking.

- **Requirements:**
  - S3 bucket for storing Terraform state files
  - Versioning enabled on S3 bucket for rollback capability
  - Encryption at rest enabled
  - Public access completely blocked
  - TLS enforcement via bucket policy
  - DynamoDB table for state locking (prevents concurrent modifications)

- **Implementation Details:**
  - **Create bootstrap directory:**
    ```bash
    mkdir -p terraform/bootstrap
    cd terraform/bootstrap
    ```
  - **Create `main.tf` (local state only for this one-time bootstrap):**

    ```hcl
    provider "aws" {
      region = "us-east-1"
    }

    # S3 Bucket for Remote State
    resource "aws_s3_bucket" "terraform_state" {
      bucket = "fargate-migration-state-YOUR-ACCOUNT-ID"  # Must be globally unique

      lifecycle {
        prevent_destroy = true
      }

      tags = {
        Name        = "Terraform State Bucket"
        Purpose     = "fargate-migration"
        Environment = "shared"
      }
    }

    resource "aws_s3_bucket_versioning" "enabled" {
      bucket = aws_s3_bucket.terraform_state.id
      versioning_configuration {
        status = "Enabled"
      }
    }

    resource "aws_s3_bucket_server_side_encryption_configuration" "default" {
      bucket = aws_s3_bucket.terraform_state.id
      rule {
        apply_server_side_encryption_by_default {
          sse_algorithm = "AES256"
        }
      }
    }

    # Public Access Block (Critical Security)
    resource "aws_s3_bucket_public_access_block" "terraform_state" {
      bucket                  = aws_s3_bucket.terraform_state.id
      block_public_acls       = true
      block_public_policy     = true
      ignore_public_acls      = true
      restrict_public_buckets = true
    }

    # Enforce TLS (HTTPS only)
    resource "aws_s3_bucket_policy" "enforce_tls" {
      bucket = aws_s3_bucket.terraform_state.id
      policy = jsonencode({
        Version = "2012-10-17",
        Statement = [{
          Sid       = "DenyRequestsWithoutTLS",
          Effect    = "Deny",
          Principal = "*",
          Action    = "s3:*",
          Resource  = [
            aws_s3_bucket.terraform_state.arn,
            "${aws_s3_bucket.terraform_state.arn}/*"
          ],
          Condition = {
            Bool = { "aws:SecureTransport" = "false" }
          }
        }]
      })
    }

    # DynamoDB for State Locking
    resource "aws_dynamodb_table" "terraform_locks" {
      name         = "terraform-locks"
      billing_mode = "PAY_PER_REQUEST"
      hash_key     = "LockID"

      attribute {
        name = "LockID"
        type = "S"
      }

      tags = {
        Name        = "Terraform State Lock Table"
        Purpose     = "fargate-migration"
        Environment = "shared"
      }
    }

    # Outputs
    output "state_bucket_name" {
      value       = aws_s3_bucket.terraform_state.id
      description = "Name of the S3 bucket for Terraform state"
    }

    output "lock_table_name" {
      value       = aws_dynamodb_table.terraform_locks.name
      description = "Name of the DynamoDB table for state locking"
    }
    ```

  - **Deploy bootstrap (one-time operation):**

    ```bash
    cd terraform/bootstrap
    terraform init
    terraform apply
    # Note the outputs: bucket name and DynamoDB table name
    ```

  - **Why this runs with local state:**
    - This is a chicken-and-egg problem: you can't use remote state until the bucket exists
    - Bootstrap runs once with local state to create the bucket
    - All subsequent Terraform operations use the remote backend
    - Keep the local `terraform.tfstate` file safe as backup (commit to git or store securely)

- **Acceptance Criteria:**
  - ✅ S3 bucket created with globally unique name
  - ✅ Bucket versioning enabled (verified in console)
  - ✅ Encryption enabled (AES256)
  - ✅ Public access blocked (all 4 settings enabled)
  - ✅ TLS enforcement policy attached
  - ✅ DynamoDB table `terraform-locks` created with `LockID` hash key
  - ✅ Outputs displayed bucket and table names

---

### Story 0.2: Configure Remote Backend for Infrastructure

- **Title:** Migrate Infrastructure Code to Use Remote State
- **Persona:** As a **DevOps engineer**, I want to configure the Terraform backend so that all infrastructure changes use the secure S3 backend with locking.

- **Requirements:**
  - Backend configuration for infrastructure Terraform code
  - State file isolation per environment if multi-environment
  - Verification that state lock works

- **Implementation Details:**
  - **Create infrastructure directory structure:**

    ```bash
    mkdir -p terraform/infrastructure
    cd terraform/infrastructure
    ```

  - **Create `backend.tf`:**

    ```hcl
    terraform {
      required_version = ">= 1.7.0"

      backend "s3" {
        bucket         = "fargate-migration-state-YOUR-ACCOUNT-ID"
        key            = "infrastructure/terraform.tfstate"
        region         = "us-east-1"
        dynamodb_table = "terraform-locks"
        encrypt        = true
      }

      required_providers {
        aws = {
          source  = "hashicorp/aws"
          version = "~> 5.0"
        }
      }
    }

    provider "aws" {
      region = var.aws_region

      default_tags {
        tags = {
          Project     = "fargate-migration"
          ManagedBy   = "terraform"
          Environment = var.environment
        }
      }
    }
    ```

  - **Create `variables.tf`:**

    ```hcl
    variable "aws_region" {
      description = "AWS region for infrastructure"
      type        = string
      default     = "us-east-1"
    }

    variable "environment" {
      description = "Environment name (e.g., production, staging)"
      type        = string
      default     = "production"
    }

    variable "project_name" {
      description = "Project name for resource naming"
      type        = string
      default     = "fargate-migration"
    }
    ```

  - **Initialize backend:**

    ```bash
    cd terraform/infrastructure
    terraform init
    # You should see: "Successfully configured the backend 's3'!"
    ```

  - **Verify state locking works:**

    ```bash
    # In Terminal 1:
    terraform plan  # This acquires a lock

    # In Terminal 2 (while Terminal 1 is running):
    terraform plan  # Should fail with lock error
    ```

  - **Multi-environment setup (optional):**
    If you plan to have dev/staging/production environments, use separate state files:
    ```
    terraform/
    ├── bootstrap/
    │   └── main.tf
    └── environments/
        ├── dev/
        │   ├── main.tf
        │   ├── backend.tf      # key = "dev/terraform.tfstate"
        │   └── terraform.tfvars
        ├── staging/
        │   ├── main.tf
        │   ├── backend.tf      # key = "staging/terraform.tfstate"
        │   └── terraform.tfvars
        └── production/
            ├── main.tf
            ├── backend.tf      # key = "production/terraform.tfstate"
            └── terraform.tfvars
    ```

- **Acceptance Criteria:**
  - ✅ `terraform init` successfully configures S3 backend
  - ✅ `terraform plan` shows no changes (expected for empty state)
  - ✅ State file visible in S3 bucket at expected key path
  - ✅ State locking verified (concurrent operations blocked)
  - ✅ Team members can run `terraform plan` after pulling code

---

### Story 0.3: Establish Terraform State Backup Strategy

- **Title:** Document State Recovery Procedures
- **Persona:** As a **DevOps engineer**, I need documented procedures for recovering from state file corruption or accidental deletion so that we can recover infrastructure without panic.

- **Requirements:**
  - Document state recovery procedure
  - Document how to use S3 versioning to recover previous state
  - Test state recovery process

- **Implementation Details:**
  - **State recovery procedure (document in team wiki/runbook):**

    **Scenario 1: Recover from corrupted state**

    ```bash
    # List versions of state file
    aws s3api list-object-versions \
      --bucket fargate-migration-state-YOUR-ACCOUNT-ID \
      --prefix infrastructure/terraform.tfstate

    # Download specific version
    aws s3api get-object \
      --bucket fargate-migration-state-YOUR-ACCOUNT-ID \
      --key infrastructure/terraform.tfstate \
      --version-id <VERSION-ID> \
      terraform.tfstate.backup

    # Verify contents
    cat terraform.tfstate.backup | jq '.version'

    # Restore (upload as current version)
    aws s3 cp terraform.tfstate.backup \
      s3://fargate-migration-state-YOUR-ACCOUNT-ID/infrastructure/terraform.tfstate
    ```

    **Scenario 2: Accidentally deleted DynamoDB lock table**

    ```bash
    # Recreate from bootstrap code
    cd terraform/bootstrap
    terraform apply -target=aws_dynamodb_table.terraform_locks
    ```

    **Scenario 3: Lost local bootstrap state**
    - If you lose the local `terraform.tfstate` from bootstrap:
    - Import existing resources manually:
      ```bash
      terraform import aws_s3_bucket.terraform_state fargate-migration-state-YOUR-ACCOUNT-ID
      terraform import aws_dynamodb_table.terraform_locks terraform-locks
      ```

  - **Test recovery (practice run):**
    1. Make a backup of current state: `terraform state pull > backup.tfstate`
    2. Intentionally break state: Edit S3 file to corrupt JSON
    3. Run `terraform plan` — should fail
    4. Restore from S3 version using procedure above
    5. Run `terraform plan` — should succeed
    6. Document findings and update runbook

- **Acceptance Criteria:**
  - ✅ State recovery procedure documented in team wiki
  - ✅ Recovery tested in non-production environment
  - ✅ S3 versioning confirmed enabled and tested
  - ✅ Team trained on recovery procedure
  - ✅ Runbook includes emergency contacts

---

## Feature 1: Network Foundation (VPC)

### Story 1.1: VPC and Subnet Provisioning

- **Title:** Provision VPC with Public and Private Subnets
- **Persona:** As a **Cloud Engineer**, I want to provision a VPC with distinct Public and Private subnets so that my load balancers are accessible to the internet while my application containers remain hidden for security.

- **Requirements:**
  - Region matches current setup (e.g., `us-east-1`)
  - VPC CIDR provides sufficient IP space for all applications
  - Subnets span at least 2 Availability Zones for high availability
  - DNS resolution enabled for internal service discovery

- **Implementation Details:**
  - **VPC Configuration:**
    - CIDR: `10.100.0.0/20` (4,096 IPs total)
    - `enableDnsHostnames: true`
    - `enableDnsSupport: true`
    - Tags: `Name: fargate-migration-vpc`, `Environment: production`
  - **Public Subnets (x2)** — Used for ALB and NAT Gateways:
    - Public A (`us-east-1a`): `10.100.0.0/23` (512 IPs)
    - Public B (`us-east-1b`): `10.100.2.0/23` (512 IPs)
    - Tag: `kubernetes.io/role/elb: 1` (if ever using EKS)
  - **Private Subnets (x2)** — Used for Fargate Tasks:
    - Private A (`us-east-1a`): `10.100.4.0/23` (512 IPs)
    - Private B (`us-east-1b`): `10.100.6.0/23` (512 IPs)
    - Tag: `kubernetes.io/role/internal-elb: 1` (if ever using EKS)
  - **Reserved Subnets (x2)** — For RDS/ElastiCache (optional):
    - Data A (`us-east-1a`): `10.100.8.0/23`
    - Data B (`us-east-1b`): `10.100.10.0/23`
  - **Internet Gateway:**
    - Create and attach to VPC
    - Tag: `Name: fargate-migration-igw`
  - **Route Tables:**
    - Public RT: `0.0.0.0/0` → Internet Gateway
    - Private RT A: `0.0.0.0/0` → NAT Gateway A
    - Private RT B: `0.0.0.0/0` → NAT Gateway B
    - Associate subnets to correct route tables

- **Acceptance Criteria:**
  - ✅ VPC created with DNS hostnames and DNS support enabled
  - ✅ 4+ subnets created across 2 AZs
  - ✅ Internet Gateway attached to VPC
  - ✅ Route tables created and associated correctly
  - ✅ Resources tagged consistently

---

### Story 1.2: Cost-Optimized Connectivity (NAT & VPC Endpoints)

- **Title:** Configure NAT Gateways and VPC Endpoints
- **Persona:** As a **FinOps Stakeholder**, I want to optimize traffic costs for AWS services so that we don't pay NAT Gateway processing fees for internal AWS service traffic.

- **Requirements:**
  - Private subnets must have outbound internet access
  - AWS service traffic should bypass NAT Gateway where possible
  - Cost vs. availability trade-off documented

- **Implementation Details:**
  - **NAT Gateways:**
    - Production: 2 NAT Gateways (one per AZ) for high availability
    - Dev/Cost-Saving: 1 NAT Gateway (single point of failure, but ~$32/month savings)
    - Place in Public Subnets
    - Allocate Elastic IP for each NAT Gateway
    - Cost: ~$32/month per NAT + $0.045/GB processed
  - **VPC Endpoints (Cost Optimization):**
    - **Gateway Endpoint for S3** (Free):
      - Service: `com.amazonaws.us-east-1.s3`
      - Associate with Private Route Tables
      - Why: ECR stores image layers in S3—this is significant traffic
    - **Interface Endpoints (Optional, ~$7/month each per AZ):**
      - `com.amazonaws.us-east-1.ecr.api` — ECR API calls
      - `com.amazonaws.us-east-1.ecr.dkr` — Docker image pulls
      - `com.amazonaws.us-east-1.logs` — CloudWatch Logs
      - `com.amazonaws.us-east-1.secretsmanager` — Secrets Manager
      - Why: Eliminates NAT dependency for AWS services entirely
    - **Decision Matrix:**
      | Scenario | Recommendation |
      |----------|---------------|
      | Low traffic, cost-sensitive | 1 NAT + S3 Gateway Endpoint |
      | Production, high availability | 2 NAT + S3 Gateway Endpoint |
      | Production, high AWS traffic | 2 NAT + All VPC Endpoints |
      | No NAT (maximum savings) | All VPC Endpoints (ECR, S3, Logs, Secrets) |

- **Acceptance Criteria:**
  - ✅ NAT Gateway(s) deployed in public subnet(s)
  - ✅ Private route tables point to NAT Gateway
  - ✅ S3 Gateway Endpoint created and associated with private route tables
  - ✅ Fargate task in private subnet can reach the internet (test: `curl https://google.com`)
  - ✅ Cost decision documented

---

## Feature 2: Shared Infrastructure (Landing Zone)

### Story 2.1: Application Load Balancer (ALB)

- **Title:** Provision Shared Internet-Facing Load Balancer
- **Persona:** As a **System Architect**, I want a single Internet-Facing Load Balancer so that I can route traffic to multiple services using a single entry point and SSL certificate.

- **Requirements:**
  - Single ALB shared across all migrated applications
  - Internet-facing for public access
  - HTTPS termination with ACM certificate
  - HTTP to HTTPS redirect

- **Implementation Details:**
  - **ALB Configuration:**
    - Name: `fargate-shared-alb`
    - Scheme: Internet-facing
    - IP Address Type: IPv4 (or dualstack if IPv6 needed)
    - Subnets: Both Public Subnets
    - Tags: `Environment: production`
  - **Security Group (`alb-sg`):**
    - Inbound Rules:
      - Port 80 (HTTP) from `0.0.0.0/0` — for redirect
      - Port 443 (HTTPS) from `0.0.0.0/0` — for traffic
    - Outbound Rules:
      - All traffic to VPC CIDR (`10.100.0.0/20`) — or restrict to private subnets
  - **HTTPS Listener (Port 443):**
    - Protocol: HTTPS
    - SSL Certificate: ACM certificate (see Story 2.2)
    - SSL Policy: `ELBSecurityPolicy-TLS13-1-2-2021-06` (modern TLS)
    - Default Action: Return fixed 404 response (no default target)
      - Why: Forces explicit routing rules per app; prevents accidental exposure
  - **HTTP Listener (Port 80):**
    - Default Action: Redirect to HTTPS (301)
    - Status Code: `HTTP_301`
  - **Access Logs (Optional but Recommended):**
    - Enable and send to S3 bucket
    - Useful for debugging and compliance

- **Acceptance Criteria:**
  - ✅ ALB is Active
  - ✅ ALB DNS name resolves (e.g., `fargate-shared-alb-123456.us-east-1.elb.amazonaws.com`)
  - ✅ HTTP requests redirect to HTTPS
  - ✅ HTTPS listener returns 404 for unmatched hosts (expected before app routing configured)
  - ✅ Security group allows only ports 80/443 from internet

---

### Story 2.1b: Internal Application Load Balancer (Internal ALB)

- **Title:** Provision Internal Load Balancer for Service-to-Service Traffic
- **Persona:** As a **System Architect**, I want an Internal Load Balancer so that services can call each other without traffic leaving the VPC, and I can use weighted routing for gradual migrations.

- **Requirements:**
  - Internal-only ALB (not internet-facing)
  - Host-based or path-based routing for multiple services
  - Supports weighted target groups for Strangler Fig migration
  - Security group restricts access to VPC only
  - (Optional) Private DNS for friendly URLs

- **Implementation Details:**
  - **Why Internal ALB — Two Primary Reasons:**
    1. **Strangler Fig Migration (Primary Reason):** The Internal ALB enables weighted routing between EC2 and ECS target groups. This is how we gradually shift traffic (5% → 25% → 50% → 100%) and instantly rollback if issues occur. Without this, we'd have to do a risky "big bang" cutover.
    2. **Keep Traffic in VPC (Secondary Benefit):** Internal calls stay inside the private network instead of hairpinning out through NAT Gateway → Internet → back through Public ALB. This reduces latency and avoids NAT data transfer costs.
  - **Important:** Even if you were okay with traffic traversing the internet, you would still need the Internal ALB for the gradual migration capability. The traffic isolation is a bonus, not the primary driver.
  - **Why NOT just use DNS switching for cutover:**
    - DNS TTLs cause inconsistent cutover (some clients cache longer than others)
    - No weighted routing capability — it's all-or-nothing
    - Rollback requires waiting for TTL expiry (could be minutes to hours)
    - ALB weight changes take effect immediately (seconds)
  - **Internal ALB Configuration:**
    - Name: `internal-services-alb`
    - Scheme: **Internal** (critical: NOT internet-facing)
    - IP Address Type: IPv4
    - Subnets: **Private Subnets** (both AZs)
    - Tags: `Environment: production`, `Purpose: internal-service-mesh`
  - **Security Group (`internal-alb-sg`):**
    - Inbound Rules:
      - Port 80 (HTTP) from VPC CIDR (`10.100.0.0/20`) — internal traffic only
      - Port 443 (HTTPS) from VPC CIDR — if using internal TLS
    - Outbound Rules:
      - All traffic to VPC CIDR
    - **Important:** No `0.0.0.0/0` rules—this ALB is private only
    - **⚠️ Note: Allow full VPC CIDR, not just private subnets**
      - Internal ALB may receive traffic from:
        - Other ECS tasks (private subnets)
        - Lambda functions (could be in public or private subnets)
        - EC2 instances in public subnets
        - VPN/Direct Connect connections
      - Safest approach: Allow entire VPC CIDR (`10.100.0.0/20`)
      - Still internal-only (not exposed to internet)
  - **HTTP Listener (Port 80):**
    - Protocol: HTTP (TLS not required for internal VPC traffic)
    - Default Action: Return fixed 404 response
    - Per-service rules added in Phase 3
  - **HTTPS Listener (Port 443) — Optional:**
    - Only if internal TLS is required (see Phase 0 Story 11.3)
    - Requires ACM Private CA certificate for internal domain
    - Example: `*.internal.yourcompany.local`
  - **Private Hosted Zone (Route 53) — OPTIONAL:**
    - **Why it's optional:** The Internal ALB gets an AWS-generated DNS name automatically (e.g., `internal-services-alb-1234567890.us-east-1.elb.amazonaws.com`). This works perfectly fine. The private hosted zone just gives you a friendlier URL.
    - **Without private DNS (simpler, works fine):**
      ```
      AUTH_API_URL=http://internal-services-alb-1234567890.us-east-1.elb.amazonaws.com/auth-api
      ```
    - **With private DNS (cleaner, but extra setup):**
      ```
      AUTH_API_URL=http://internal.yourcompany.local/auth-api
      ```
    - **Benefits of private DNS:**
      - More readable URLs in configs and logs
      - Abstraction layer — if you replace the ALB, update one DNS record instead of N app configs
      - Consistent naming across environments
    - **If you choose to set it up:**
      - Create Private Hosted Zone: `internal.yourcompany.local`
      - Associate with VPC
      - Create A record (Alias): `internal.yourcompany.local` → Internal ALB
  - **Alternative DNS approach (per-service records):**
    - `auth-api.internal.yourcompany.local` → Internal ALB (same ALB, different hostname)
    - Then use host-based routing rules
    - More DNS records to manage, but cleaner per-service URLs
  - **Recommendation:** Start without private DNS (use ALB's AWS name directly). Add the friendly DNS later if the ugly URLs bother you. It's easy to add and doesn't require app changes beyond updating env vars.

- **Acceptance Criteria:**
  - ✅ Internal ALB created in private subnets
  - ✅ Scheme is "Internal" (verify in console — this is critical)
  - ✅ Security group only allows VPC CIDR (no 0.0.0.0/0)
  - ✅ HTTP listener configured with default 404 action
  - ✅ ALB DNS name is reachable from within VPC (test from EC2 or ECS task)
  - ✅ (Optional) Private hosted zone created and resolves correctly

---

### Story 2.1c: Private DNS for Internal ALB (For KrakenD Host-Based Routing)

- **Title:** Configure Private Hosted Zone for Clean Service Routing
- **Persona:** As a **System Architect**, I want private DNS names for backend services so that KrakenD can use host-based routing without path transformations.

- **Requirements:**
  - Private hosted zone for internal service discovery
  - DNS records pointing to Internal ALB
  - Enables KrakenD to strip paths and set Host headers

- **Implementation Details:**
  - **Why This Matters (KrakenD Integration):**

    Your architecture uses **KrakenD API Gateway** for authentication and path-based routing. KrakenD receives requests like `/test-api-1/health` and needs to route them to backend services. Using private DNS with host-based routing is the cleanest pattern:

    **Traffic Flow:**

    ```
    User → Public ALB → KrakenD (strips /test-api-1) → Internal ALB (routes by Host header) → Service
    ```

    **KrakenD Configuration Pattern:**

    ```json
    {
      \"endpoint\": \"/test-api-1/{everything}\",
      \"backend\": [{
        \"host\": [\"http://test-api-1.internal\"],
        \"url_pattern\": \"/{everything}\"
      }]
    }
    ```

    KrakenD automatically:
    1. Strips the `/test-api-1` prefix
    2. Forwards to `http://test-api-1.internal/health`
    3. Sets `Host: test-api-1.internal` header

    **No ALB path transformation needed** - the Internal ALB just routes by Host header.

  - **Create Private Hosted Zone:**

    Via AWS Console:
    1. Route 53 → Hosted zones → Create hosted zone
    2. Domain name: `internal` (or `internal.yourcompany.local`)
    3. Type: **Private hosted zone**
    4. VPC: Select your Fargate VPC
    5. Create

    Via CLI:

    ```bash
    aws route53 create-hosted-zone \\
      --name internal \\
      --vpc VPCRegion=us-east-1,VPCId=vpc-xxxxx \\
      --caller-reference $(date +%s)
    ```

  - **Create DNS Records (One per Service):**

    All records point to the **same Internal ALB** (routing happens via Host header):

    | DNS Name              | Type      | Target           | Used By              |
    | --------------------- | --------- | ---------------- | -------------------- |
    | `test-api-1.internal` | A (ALIAS) | Internal ALB DNS | KrakenD → test-api-1 |
    | `test-api-2.internal` | A (ALIAS) | Internal ALB DNS | KrakenD → test-api-2 |
    | `auth-api.internal`   | A (ALIAS) | Internal ALB DNS | KrakenD → auth-api   |

    Via Console:
    1. Route 53 → Hosted zones → `internal`
    2. Create record → Simple routing
    3. Name: `test-api-1` (full name will be `test-api-1.internal`)
    4. Type: A
    5. Alias: Yes → Choose Internal ALB
    6. Repeat for test-api-2, auth-api

  - **Internal ALB Listener Rules (Host-Based Routing):**

    Add listener rules to the Internal ALB HTTP listener (port 80):

    Via Console:
    1. EC2 → Load Balancers → Internal ALB → Listeners → HTTP:80
    2. View/edit rules → Add rule
    3. Add condition: Host header is `test-api-1.internal`
    4. Add action: Forward to `test-api-1-tg`
    5. Priority: 10
    6. Repeat for test-api-2 (priority 20), auth-api (priority 30)

    Via CLI:

    ```bash
    # Get listener ARN
    LISTENER_ARN=$(aws elbv2 describe-listeners \\
      --load-balancer-arn <internal-alb-arn> \\
      --query 'Listeners[?Port==`80`].ListenerArN' --output text)

    # Create rule for test-api-1
    aws elbv2 create-rule \\
      --listener-arn $LISTENER_ARN \\
      --priority 10 \\
      --conditions Field=host-header,Values='test-api-1.internal' \\
      --actions Type=forward,TargetGroupArn=<test-api-1-tg-arn>
    ```

  - **Verify Setup:**

    From within VPC (EC2 or ECS task):

    ```bash
    # DNS resolution
    dig test-api-1.internal  # Should return Internal ALB IP

    # HTTP request with Host header
    curl -H \"Host: test-api-1.internal\" http://test-api-1.internal/health
    ```

- **Acceptance Criteria:**
  - ✅ Private hosted zone `internal` created and associated with VPC
  - ✅ DNS records created for each service (all pointing to Internal ALB)
  - ✅ Internal ALB listener rules configured with host-header conditions
  - ✅ DNS resolution works from within VPC
  - ✅ HTTP requests with Host header route to correct target group

---

### Story 2.2: ACM Certificate Provisioning

- **Title:** Request and Validate SSL Certificate
- **Persona:** As a **DevOps Engineer**, I want an ACM certificate for my domains so that HTTPS works on the ALB without manual certificate management.

- **Requirements:**
  - Certificate must cover all application domains
  - Certificate must be in the same region as ALB
  - DNS validation preferred (auto-renews)

- **Implementation Details:**
  - **Certificate Request:**
    - Domain: `*.yourcompany.com` (wildcard) OR list each subdomain
    - Wildcard example: covers `auth.yourcompany.com`, `api.yourcompany.com`, etc.
    - Alternative: Request with multiple SANs (Subject Alternative Names)
  - **Validation Method:**
    - DNS Validation (Recommended): Add CNAME record to DNS
      - ACM provides the CNAME name and value
      - If using Route 53: ACM can auto-create the record
    - Email Validation: Requires access to admin email addresses
  - **Certificate ARN:**
    - After validation, note the ARN for ALB listener configuration
    - Format: `arn:aws:acm:us-east-1:123456789:certificate/abc-123`
  - **Renewal:**
    - ACM auto-renews DNS-validated certificates
    - No action required if DNS record remains in place

- **Acceptance Criteria:**
  - ✅ ACM certificate requested for required domains
  - ✅ DNS validation records created
  - ✅ Certificate status is "Issued"
  - ✅ Certificate attached to ALB HTTPS listener

---

### Story 2.3: ECS Cluster Creation

- **Title:** Create Shared ECS Cluster
- **Persona:** As a **DevOps Engineer**, I want a consolidated ECS Cluster so that I can manage all Fargate services in one place with unified monitoring.

- **Requirements:**
  - Single cluster for all applications
  - Fargate capacity provider enabled
  - Container Insights enabled for observability

- **Implementation Details:**
  - **Cluster Configuration:**
    - Name: `production-cluster` (or `fargate-platform`)
    - Capacity Providers: `FARGATE`, `FARGATE_SPOT` (optional for cost savings)
    - Default Capacity Provider Strategy:
      - `FARGATE` weight: 1 (use for production workloads)
      - `FARGATE_SPOT` weight: 0 (or 1 for dev/non-critical)
  - **Container Insights:**
    - Enable: Yes
    - Why: Provides CPU, memory, network metrics per task
    - Creates CloudWatch metrics namespace: `ECS/ContainerInsights`
  - **Service Connect Namespace (Optional):**
    - If services need to call each other by name
    - Creates Cloud Map namespace for internal DNS
    - Example: `auth-api.production.local`
  - **⚠️ CRITICAL: Do NOT use Service Connect for Strangler Fig Migration**
    - **The Problem:**
      - Service Connect creates service mesh networking with its own load balancing
      - Strangler Fig pattern requires weighted routing at the ALB level
      - Service Connect + ALB weighted routing **do not work together**
      - You cannot gradually shift traffic from EC2 to Fargate using Service Connect
    - **For this migration: Use Internal ALB instead**
      - ✅ Phase 2: Deploy Internal ALB with Target Groups for EC2 and Fargate
      - ✅ Phase 3: Use ALB listener rules to weight traffic (90% EC2 → 10% Fargate)
      - ✅ Phase 4: Gradually shift weights (50/50 → 10/90 → 0/100)
      - ❌ DO NOT enable Service Connect until migration is complete
    - **After migration is complete:**
      - Service Connect can be enabled for new greenfield services
      - Service Connect is excellent for service-to-service communication
      - Not suitable for brownfield migration with weighted routing

  - **Tags:**
    - `Environment: production`
    - `ManagedBy: platform-team`

- **Acceptance Criteria:**
  - ✅ Cluster status is "Active"
  - ✅ Capacity providers configured (FARGATE at minimum)
  - ✅ Container Insights enabled
  - ✅ **Service Connect namespace created but NOT enabled on services yet**
  - ✅ **Internal ALB created for Strangler Fig pattern (see Infrastructure Setup phase)**
  - ✅ Cluster visible in ECS console with all services

---

### Story 2.4: CloudWatch Log Groups

- **Title:** Create Centralized Log Groups
- **Persona:** As an **Operations Engineer**, I want pre-created log groups with retention policies so that application logs are organized and don't accumulate indefinitely.

- **Requirements:**
  - Log group per application (or shared with prefixes)
  - Retention policy to control costs
  - Consistent naming convention

- **Implementation Details:**
  - **Naming Convention:**
    - Pattern: `/ecs/[cluster-name]/[app-name]`
    - Example: `/ecs/production-cluster/auth-api`
  - **Retention Policy:**
    - Production: 30 days (or 90 days for compliance)
    - Development: 7 days
    - Why: CloudWatch Logs charges for storage; old logs add up
  - **Log Group Creation:**
    - Create before deploying services (or let ECS auto-create)
    - If auto-created, manually set retention afterward
  - **Log Insights Queries (Save Common Queries):**
    - Error count: `fields @timestamp, @message | filter @message like /error/i | stats count(*)`
    - Recent errors: `fields @timestamp, @message | filter level = 'error' | sort @timestamp desc | limit 50`

- **Acceptance Criteria:**
  - ✅ Log group exists for each application
  - ✅ Retention policy set (not "Never expire")
  - ✅ Naming convention followed consistently

---

## Feature 2b: Application Security Groups

> **Note:** Security groups are infrastructure, owned by the SRE/Infra team. Creating them in Phase 2 (not Phase 3) allows parallel work — infra team sets up SGs while app teams work on Phase 1 containerization.

### Story 2.5: Create Application Security Groups

- **Title:** Create Per-Application Security Groups for Fargate Tasks
- **Persona:** As a **Security Engineer**, I want to create application security groups upfront so that they're ready when we deploy services in Phase 3.

- **Requirements:**
  - One security group per application (or reuse existing if appropriate)
  - Inbound traffic allowed ONLY from ALB security group
  - No direct internet access to containers
  - Decision from Phase 0 audit implemented (reuse vs. create new)

- **Implementation Details:**
  - **Based on Phase 0 Discovery (Story 2.3):**
    - If reusing existing EC2 SG: Add ALB inbound rule to existing SG
    - If creating new: Create Fargate-specific SG
  - **New Security Group Configuration (if creating):**
    - Name: `[app-name]-fargate-sg` (e.g., `auth-api-fargate-sg`)
    - VPC: Select the Fargate VPC
    - Description: "Security group for [app-name] Fargate tasks"
  - **Inbound Rules:**
    | Type | Port | Source | Description |
    |------|------|--------|-------------|
    | Custom TCP | App Port (e.g., 3000) | `sg-xxx` (alb-sg) | Allow ALB health checks and traffic |
    | Custom TCP | App Port (e.g., 3000) | `sg-xxx` (internal-alb-sg) | Allow Internal ALB (if using) |
  - **Outbound Rules:**
    | Type | Port | Destination | Description |
    |------|------|-------------|-------------|
    | All Traffic | All | 0.0.0.0/0 | Allow outbound (DB, APIs, etc.) |
  - **Why Security Group Chaining:**
    - If someone discovers your container's IP, they cannot connect directly
    - Only traffic through the ALB is allowed
    - Defense in depth
  - **Common Mistake:**
    - Using CIDR `10.100.0.0/20` as source instead of security group ID
    - This allows ANY resource in the VPC to connect, not just the ALB
  - **Create all app SGs now:**
    - Don't wait for Phase 3 — create SGs for all 10 apps upfront
    - Infra team can batch this work while app teams containerize
    - SGs are free (no cost until attached to resources)

- **Acceptance Criteria:**
  - ✅ Security group created (or existing SG updated) for each application
  - ✅ Inbound rule references ALB security group ID (not CIDR)
  - ✅ Internal ALB SG added if using Internal ALB
  - ✅ Application port documented per app
  - ✅ Outbound allows internet access (for external APIs, etc.)

---

### Story 2.6: Update Database Security Groups for Fargate Access

- **Title:** Allow Fargate Task Security Groups to Access Databases
- **Persona:** As a **Security Engineer**, I want to update database security groups now so that Fargate tasks can connect when deployed in Phase 3.

- **Requirements:**
  - RDS security group must allow inbound from each Fargate task security group
  - Same applies to ElastiCache, OpenSearch, or any data stores
  - Updates can be done before Fargate tasks are deployed (SG rules are forward-looking)

- **Implementation Details:**
  - **Add Inbound Rules to RDS Security Group:**
    | Type | Port | Source | Description |
    |------|------|--------|-------------|
    | PostgreSQL | 5432 | `sg-xxx` (auth-api-fargate-sg) | Allow auth-api Fargate tasks |
    | PostgreSQL | 5432 | `sg-xxx` (user-api-fargate-sg) | Allow user-api Fargate tasks |
    | ... | ... | ... | (repeat for each app that needs DB access) |
  - **Add Inbound Rules to ElastiCache Security Group:**
    | Type | Port | Source | Description |
    |------|------|--------|-------------|
    | Custom TCP | 6379 | `sg-xxx` (auth-api-fargate-sg) | Allow Redis from auth-api |
    | ... | ... | ... | (repeat for each app that needs Redis) |
  - **Batch this work:**
    - Add all app SGs to database SGs now
    - Don't wait for each app to be deployed
    - Rules referencing SGs that aren't attached to anything yet are harmless
  - **Alternative: Shared Fargate SG:**
    - Create one `fargate-apps-sg` used by all Fargate tasks
    - Add only this one SG to database rules
    - Simpler, but less granular (all apps can reach all databases)
  - **Keep EC2 SG rules intact:**
    - Don't remove the existing EC2 SG inbound rules
    - EC2 apps still need database access during migration
    - Remove EC2 rules after migration is complete

- **Acceptance Criteria:**
  - ✅ RDS security group allows inbound from all Fargate task SGs
  - ✅ ElastiCache security group allows inbound from all Fargate task SGs
  - ✅ EC2 access rules preserved (for migration period)
  - ✅ Changes documented for rollback if needed

---

## Feature 3: Artifact Management (ECR)

### Story 3.1: ECR Repository Creation & Standards

- **Title:** Create Standardized ECR Repositories
- **Persona:** As a **Release Manager**, I want standardized ECR repositories so that our image library is organized, secure, and cost-efficient.

- **Requirements:**
  - One repository per application
  - Consistent naming convention
  - Image scanning enabled
  - Lifecycle policy to clean up old images

- **Implementation Details:**
  - **Naming Convention:**
    - Pattern: `[namespace]/[repo-name]`
    - Example: `legacy-migration/auth-api`
    - Namespace: Project group or team name
    - Repo Name: Match GitHub repository name exactly
  - **Repository Settings:**
    - Visibility: Private
    - Tag Mutability: **Mutable** (allow overwriting `latest` during migration)
      - Post-migration: Consider switching to Immutable for production safety
    - Encryption: **AES-256** (AWS managed)
      - Why: Avoids KMS permission complexity and cross-account issues
      - Alternative: KMS CMK if compliance requires customer-managed keys
  - **Image Scanning:**
    - Scan on Push: Enabled
    - Why: Automatically scans for CVEs; results visible in console
  - **Lifecycle Policy (Cost Control):**
    ```json
    {
      "rules": [
        {
          "rulePriority": 1,
          "description": "Keep last 10 tagged images",
          "selection": {
            "tagStatus": "tagged",
            "tagPrefixList": ["v", "release"],
            "countType": "imageCountMoreThan",
            "countNumber": 10
          },
          "action": { "type": "expire" }
        },
        {
          "rulePriority": 2,
          "description": "Delete untagged images older than 7 days",
          "selection": {
            "tagStatus": "untagged",
            "countType": "sinceImagePushed",
            "countUnit": "days",
            "countNumber": 7
          },
          "action": { "type": "expire" }
        },
        {
          "rulePriority": 3,
          "description": "Keep only last 20 images total",
          "selection": {
            "tagStatus": "any",
            "countType": "imageCountMoreThan",
            "countNumber": 20
          },
          "action": { "type": "expire" }
        }
      ]
    }
    ```

- **Acceptance Criteria:**
  - ✅ ECR repository created for each application
  - ✅ Image scanning enabled
  - ✅ Lifecycle policy applied
  - ✅ KMS encryption disabled (using AES-256)

---

### Story 3.2: Seed Image Push

- **Title:** Push Baseline Image to ECR
- **Persona:** As a **Developer**, I want to push a baseline image to ECR so that ECS Service creation doesn't fail due to an empty repository.

- **Requirements:**
  - At least one valid image in ECR before creating ECS Service
  - Image must be built for `linux/amd64` architecture
  - Image should be functional (passes health checks)

- **Implementation Details:**
  - **Standard Operating Procedure:**
    1.  **Authenticate Docker to ECR:**

        ```bash
        aws ecr get-login-password --region us-east-1 | \
          docker login --username AWS --password-stdin \
          123456789012.dkr.ecr.us-east-1.amazonaws.com
        ```

        - NOTE: "123456789012" is the AWS account number

    2.  **Build Image (Critical for Apple Silicon users):**

        ```bash
        docker build --platform linux/amd64 -t auth-api .
        ```

        - NOTES:
          - Why: M1/M2/M3 Macs build `arm64` by default; Fargate expects `amd64`
          - Symptom if wrong: `exec format error` on container start
          - NOTE: "auth-api" is the name you will use
          - **⚠️ CRITICAL: If using nginx or other seed image, ensure port matches your actual app port**
          - If your app runs on port 3000, don't use nginx on port 80
          - Otherwise health checks will fail when you swap to the real app

    3.  **Tag Image:**

        ```bash
        docker tag auth-api:latest \
          123456789012.dkr.ecr.us-east-1.amazonaws.com/legacy-migration/auth-api:latest
        ```

        - NOTES:
          - "123456789012" is the AWS account number

    4.  **Push Image:**

        ```bash
        docker push \
          123456789012.dkr.ecr.us-east-1.amazonaws.com/legacy-migration/auth-api:latest
        ```

        - NOTES:
          - "123456789012" is the AWS account number
          - "legacy-migration" is the namespace name used when creating the ECR repo
          - "auth-api" is the name ...

    5.  **Verify:**

        ```bash
        aws ecr describe-images \
          --repository-name legacy-migration/auth-api \
          --query 'imageDetails[*].[imageTags,imagePushedAt]'
        ```

        - NOTES:
          - "123456789012" is the AWS account number
          - "legacy-migration" is the namespace name used when creating the ECR repo
          - "auth-api" is the name ...

  - **Troubleshooting:**
    - "no basic auth credentials": Re-run the `get-login-password` command
    - "exec format error": Rebuild with `--platform linux/amd64`
    - "repository does not exist": Create the repository first

- **Acceptance Criteria:**
  - ✅ ECR repository contains at least one image
  - ✅ Image tagged as `latest` (or specific version)
  - ✅ Image architecture is `amd64` (verify in ECR console)
  - ✅ Image scan completed with no critical vulnerabilities (or acknowledged)

---

## Feature 4: Secrets Management

### Story 4.1: Secrets Manager Setup

- **Title:** Migrate Secrets to AWS Secrets Manager
- **Persona:** As a **Security Engineer**, I want application secrets stored in Secrets Manager so that credentials are encrypted, auditable, and not hardcoded in task definitions.

- **Requirements:**
  - Database credentials stored securely
  - API keys and tokens stored securely
  - Secrets accessible by ECS tasks via IAM

- **Implementation Details:**
  - **Secret Naming Convention:**
    - Pattern: `[environment]/[app-name]/[secret-type]`
    - Examples:
      - `production/auth-api/database` — DB credentials
      - `production/auth-api/api-keys` — Third-party API keys
      - `production/shared/redis` — Shared Redis password
  - **Secret Structure (JSON):**
    ```json
    {
      "username": "app_user",
      "password": "super-secret-password",
      "host": "mydb.cluster-abc123.us-east-1.rds.amazonaws.com",
      "port": "5432",
      "database": "auth_db"
    }
    ```
  - **Accessing in ECS Task Definition:**
    - Use `secrets` block (not `environment`)
    - ECS injects values at container start
    ```json
    "secrets": [
      {
        "name": "DB_PASSWORD",
        "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789012:secret:production/auth-api/database:password::"
      }
    ]
    ```
  - **IAM Permissions:**
    - Task Execution Role needs: `secretsmanager:GetSecretValue`
    - Restrict to specific secret ARNs (least privilege)
  - **Rotation (Optional):**
    - Enable automatic rotation for database credentials
    - Requires RDS Proxy or application-level credential refresh

- **Acceptance Criteria:**
  - ✅ Secrets created in Secrets Manager
  - ✅ Secrets follow naming convention
  - ✅ Task Execution Role has permission to read secrets
  - ✅ No plaintext secrets in ECS Task Definition

---

## Feature 5: IAM Roles

### Story 5.1: Task Execution Role (Shared)

- **Title:** Create ECS Task Execution Role
- **Persona:** As a **Cloud Admin**, I want a shared Task Execution Role so that Fargate can pull images and write logs without per-app IAM setup.

- **Requirements:**
  - Allows Fargate to pull images from ECR
  - Allows Fargate to write logs to CloudWatch
  - Allows Fargate to read secrets from Secrets Manager
- **Implementation Details:**
  - **Role Name:** `ecsTaskExecutionRole` (AWS convention)
  - **Trust Policy:**
    ```json
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Principal": { "Service": "ecs-tasks.amazonaws.com" },
          "Action": "sts:AssumeRole"
        }
      ]
    }
    ```
  - **Managed Policies:**
    - `AmazonECSTaskExecutionRolePolicy` (ECR pull, CloudWatch Logs)
  - **Inline Policy (for Secrets Manager):**
    ```json
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Action": ["secretsmanager:GetSecretValue"],
          "Resource": "arn:aws:secretsmanager:us-east-1:123456789012:secret:production/*"
        }
      ]
    }
    ```
  - **Optional (for SSM Parameter Store):**
    ```json
    {
      "Effect": "Allow",
      "Action": ["ssm:GetParameters"],
      "Resource": "arn:aws:ssm:us-east-1:123456789012:parameter/production/*"
    }
    ```

- **Acceptance Criteria:**
  - ✅ Role exists with correct trust policy
  - ✅ Role has `AmazonECSTaskExecutionRolePolicy` attached
  - ✅ Role can read from Secrets Manager (test with `aws sts assume-role`)

---

### Story 5.2: Task Role Template (Per-App)

- **Title:** Create Application-Specific Task Role
- **Persona:** As a **Cloud Admin**, I want per-application Task Roles so that each app has only the AWS permissions it needs (least privilege).

- **Requirements:**
  - Separate role per application (if app needs AWS access)
  - Only permissions required by application code
  - No hardcoded credentials in application

- **Implementation Details:**
  - **Role Name:** `[app-name]-task-role` (e.g., `auth-api-task-role`)
  - **Trust Policy:** Same as Task Execution Role (ECS tasks)
  - **Example Policies by Use Case:**
    - **S3 Access:**
      ```json
      {
        "Effect": "Allow",
        "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
        "Resource": "arn:aws:s3:::my-app-bucket/*"
      }
      ```
    - **SQS Access:**
      ```json
      {
        "Effect": "Allow",
        "Action": [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage"
        ],
        "Resource": "arn:aws:sqs:us-east-1:123456789012:my-queue"
      }
      ```
    - **SES Email:**
      ```json
      {
        "Effect": "Allow",
        "Action": ["ses:SendEmail", "ses:SendRawEmail"],
        "Resource": "*",
        "Condition": {
          "StringEquals": { "ses:FromAddress": "noreply@mycompany.com" }
        }
      }
      ```
    - **DynamoDB Access:**
      ```json
      {
        "Effect": "Allow",
        "Action": ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:Query"],
        "Resource": "arn:aws:dynamodb:us-east-1:123456789012:table/my-table"
      }
      ```
  - **No Task Role Needed If:**
    - App only talks to RDS/ElastiCache (uses network, not IAM)
    - App only makes external API calls (no AWS services)

- **Acceptance Criteria:**
  - ✅ Task Role created for apps requiring AWS access
  - ✅ Permissions scoped to specific resources (not `*`)
  - ✅ No AWS credentials hardcoded in application
  - ✅ Application can access required AWS services when running in Fargate

---

### Story 5.3: Configure Deployer IAM Permissions

- **Title:** Grant CI/CD Pipeline Permission to Deploy ECS Services
- **Persona:** As a **DevOps engineer**, I need the CI/CD deployer role to have `iam:PassRole` permission so that GitHub Actions can deploy ECS services with the correct Task and Execution Roles.

- **Requirements:**
  - CI/CD deployer can register task definitions
  - CI/CD deployer can update ECS services
  - CI/CD deployer can pass Task Role and Execution Role to ECS
  - Permissions follow least-privilege principle

- **Implementation Details:**
  - **The Problem:**
    - When GitHub Actions runs `aws ecs register-task-definition`, it needs to specify:
      - `taskRoleArn` (role the application uses)
      - `executionRoleArn` (role ECS uses to pull image and fetch secrets)
    - **Without `iam:PassRole`, deployment fails with:**
      ```
      User: arn:aws:sts::123456789012:assumed-role/GitHubActionsDeployerRole/...
      is not authorized to perform: iam:PassRole on resource: arn:aws:iam::123456789012:role/ECSTaskRole
      ```
  - **Create Deployer Role Policy:**

    ```hcl
    # terraform/iam-deployer.tf

    resource "aws_iam_role" "github_actions_deployer" {
      name = "GitHubActionsDeployerRole"

      assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Effect = "Allow"
          Principal = {
            Federated = aws_iam_openid_connect_provider.github.arn
          }
          Action = "sts:AssumeRoleWithWebIdentity"
          Condition = {
            StringEquals = {
              "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            }
            StringLike = {
              "token.actions.githubusercontent.com:sub" = "repo:my-org/my-repo:*"
            }
          }
        }]
      })
    }

    resource "aws_iam_role_policy" "deployer_ecs" {
      name = "ECSDeploymentPolicy"
      role = aws_iam_role.github_actions_deployer.id

      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid = "ECSDeployment"
            Effect = "Allow"
            Action = [
              "ecs:RegisterTaskDefinition",
              "ecs:DeregisterTaskDefinition",
              "ecs:DescribeTaskDefinition",
              "ecs:DescribeServices",
              "ecs:UpdateService",
              "ecs:ListTasks",
              "ecs:DescribeTasks"
            ]
            Resource = "*"
          },
          {
            Sid = "PassRoleToECS"
            Effect = "Allow"
            Action = "iam:PassRole"
            Resource = [
              aws_iam_role.ecs_task_role.arn,
              aws_iam_role.ecs_execution_role.arn
            ]
            Condition = {
              StringEquals = {
                "iam:PassedToService": "ecs-tasks.amazonaws.com"
              }
            }
          },
          {
            Sid = "ECRAccess"
            Effect = "Allow"
            Action = [
              "ecr:GetAuthorizationToken",
              "ecr:BatchCheckLayerAvailability",
              "ecr:GetDownloadUrlForLayer",
              "ecr:BatchGetImage"
            ]
            Resource = "*"
          }
        ]
      })
    }
    ```

  - **Least-privilege PassRole:**
    - **Restrict to specific roles:** Only allow passing the Task and Execution roles (not all roles)
    - **Restrict to ECS service:** `Condition: iam:PassedToService = ecs-tasks.amazonaws.com`
    - This prevents deployer from passing arbitrary roles to other services
  - **Test deployment:**

    ```bash
    # Assume deployer role
    aws sts assume-role --role-arn arn:aws:iam::123456789012:role/GitHubActionsDeployerRole

    # Try registering task definition
    aws ecs register-task-definition \
      --family my-app \
      --task-role-arn arn:aws:iam::123456789012:role/ECSTaskRole \
      --execution-role-arn arn:aws:iam::123456789012:role/ECSExecutionRole \
      --container-definitions '[...]'

    # Should succeed with iam:PassRole permission
    ```

- **Acceptance Criteria:**
  - ✅ Deployer role created with OIDC trust for GitHub Actions
  - ✅ `iam:PassRole` permission granted for Task and Execution roles only
  - ✅ Condition restricts PassRole to `ecs-tasks.amazonaws.com`
  - ✅ CI/CD pipeline can register task definitions
  - ✅ CI/CD pipeline can update ECS services
  - ✅ Attempting to pass other IAM roles fails (security test)

---

## Infrastructure Setup Checklist

Complete before moving to Phase 3:

### Networking

- [ ] VPC created with DNS enabled
- [ ] Public subnets created (2 AZs)
- [ ] Private subnets created (2 AZs)
- [ ] Internet Gateway attached
- [ ] NAT Gateway(s) deployed
- [ ] Route tables configured correctly
- [ ] S3 VPC Endpoint created
- [ ] Connectivity tested from private subnet

### Load Balancer

- [ ] External ALB created in public subnets
- [ ] External ALB security group configured (80, 443 from internet)
- [ ] ACM certificate issued
- [ ] HTTPS listener configured with certificate
- [ ] HTTP to HTTPS redirect configured
- [ ] Internal ALB created in private subnets
- [ ] Internal ALB security group configured (80 from VPC CIDR only)
- [ ] Internal ALB DNS name documented (AWS-generated name works fine)
- [ ] (Optional) Private hosted zone created for friendly URLs

### ECS

- [ ] ECS Cluster created
- [ ] Container Insights enabled
- [ ] Capacity providers configured

### Security Groups (Per-Application)

- [ ] Fargate security group created (or existing SG updated) for each application
- [ ] Inbound rules reference ALB SG (not CIDR)
- [ ] Internal ALB SG added to inbound rules (if using Internal ALB)
- [ ] RDS security group updated to allow all Fargate app SGs
- [ ] ElastiCache security group updated to allow all Fargate app SGs
- [ ] EC2 SG rules preserved (for migration period)

### ECR

- [ ] Repositories created for all applications
- [ ] Lifecycle policies applied
- [ ] Image scanning enabled
- [ ] Seed images pushed

### Secrets

- [ ] Secrets migrated to Secrets Manager
- [ ] Naming convention followed

### IAM

- [ ] Task Execution Role created with Secrets Manager access
- [ ] Per-app Task Roles created (if needed)

### Logging

- [ ] CloudWatch Log Groups created
- [ ] Retention policies set
