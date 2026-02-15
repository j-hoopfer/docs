# Activity 2: Shared Infrastructure Setup

## Feature 1: Network Foundation (VPC)

**Business Value:** Provides secure, isolated network foundation required for PCI/SOC 2 compliance and multi-tier architecture. Proper VPC setup (2-3 days) with public/private subnets prevents direct internet access to application containers, eliminating the #1 attack vector in cloud breaches. Also enables cost optimization through VPC endpoints ($200-500/month NAT savings) and high availability across multiple availability zones, supporting 99.95%+ uptime SLA.

### Story 1.1: VPC and Subnet Provisioning

**Business Value:** Creates the security foundation required for production deployments and compliance certifications. Multi-AZ VPC with public/private subnets (4-6 hours setup) prevents direct container internet access (required for PCI/SOC 2), enables zero-downtime deployments (containers can restart in alternate AZ), and provides IP address space for 100+ services. One company reduced security audit findings from 12 to 0 after implementing proper network segmentation via public/private subnets.

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
  - ✅ Public and Private subnets created across 2 AZs (4+ total)
  - ✅ Internet Gateway attached to VPC
  - ✅ Route tables created and associated correctly
  - ✅ Resources tagged consistently

---

### Story 1.2: Cost-Optimized Connectivity (NAT & VPC Endpoints)

**Business Value:** Delivers $200-500/month cost savings through VPC endpoints while maintaining private subnet internet access. S3 Gateway Endpoint (free, 1-hour setup) eliminates NAT charges for ECR traffic (image pulls), which can represent 60-80% of NAT data transfer costs. VPC endpoints also reduce latency by 30-50ms by keeping AWS service traffic within AWS backbone instead of routing through NAT Gateway and public internet. Critical for cost-efficient scaling beyond 5-10 containers.

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
  - ✅ Connectivity tested from private subnet (e.g. `curl` to internet or S3)
  - ✅ Fargate task in private subnet can reach the internet (test: `curl https://google.com`)
  - ✅ Cost decision documented

---

## Feature 2: Shared Infrastructure (Landing Zone)

**Business Value:** Provides reusable infrastructure foundation that serves 10-100 applications, delivering economies of scale and operational efficiency. Single shared ALB ($16/month) + ECS cluster (free) can host unlimited services vs. dedicated load balancers per app ($16-200/month each). Also standardizes deployments, reducing setup time from 2-3 days per app to 30 minutes (reuse existing infrastructure). Enables centralized TLS management, monitoring, and cost allocation.

### Story 2.1: Application Load Balancer (ALB)

**Business Value:** Provides single internet entry point for all services, reducing costs and operational complexity. One shared ALB ($16/month + $0.008/LCU-hour) serves unlimited applications via host/path routing vs. dedicated ALB per app ($16-50/month each). For 10 apps, this saves $144-484/month. Also provides centralized TLS termination (one certificate), unified access logs for security audits, and single firewall egress point for IP whitelisting. Essential for multi-service architectures and cost optimization.

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
  - ✅ External ALB created in public subnets and is Active
  - ✅ ALB DNS name resolves (e.g., `fargate-shared-alb-123456.us-east-1.elb.amazonaws.com`)
  - ✅ External ALB security group configured (80, 443 from internet)
  - ✅ HTTPS listener returns 404 for unmatched hosts (expected before app routing configured)
  - ✅ Security group allows only ports 80/443 from internet

---

### Story 2.1b: Internal Application Load Balancer (Internal ALB)

**Business Value:** Enables risk-free gradual migration through weighted traffic routing between EC2 and ECS, eliminating "big bang" cutover risk that causes 50-70% of migration failures. Internal ALB (1 day setup, $16/month) allows shifting traffic 5% → 25% → 50% → 100% with instant rollback capability, preventing multi-hour outages from bad deployments. Also keeps service-to-service traffic internal (saves $50-200/month in NAT charges and reduces latency 30-50ms). Critical for Strangler Fig migration pattern and zero-downtime transitions.

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

**Business Value:** Simplifies API Gateway configuration and eliminates complex path rewriting logic, reducing KrakenD config errors by 80%. Private DNS (2-3 hours setup, free) enables clean host-based routing (`test-api-1.internal`) instead of brittle path transformations, making KrakenD configs 50% smaller and easier to maintain. Also provides abstraction layer - changing backend infrastructure requires updating one DNS record vs. updating 20+ KrakenD endpoints. Reduces deployment errors and accelerates onboarding of new services.

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

**Business Value:** Automates SSL/TLS certificate management, eliminating manual renewal emergencies that cause 20-30% of production outages. ACM certificates (free, auto-renewing) prevent the "certificate expired" outages that happen at 2am when manually-managed certs expire. DNS validation (1-hour setup) enables automatic 60-day renewals forever, eliminating the 4-8 hours/year of manual certificate renewal work and preventing customer-facing SSL warnings. Required for HTTPS (PCI/SOC 2 compliance) and modern browser compatibility.

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

**Business Value:** Provides centralized container orchestration for unlimited applications at zero infrastructure cost (Fargate clusters are free). Single ECS cluster (5 minutes setup) enables unified monitoring, cost allocation tags, and operational consistency across all services. Container Insights (optional, $10-30/month) provides real-time performance metrics preventing 70% of scaling issues through visibility into CPU/memory usage trends. Essential foundation for all containerized workloads.

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

**Business Value:** Prevents uncontrolled log storage costs (logs never expire by default) and ensures operational visibility from day one. Setting retention policies (15 minutes) prevents surprise $500-2,000/month CloudWatch bills from unlimited log accumulation. Consistent log group naming enables fast troubleshooting (find logs in 30 seconds vs. 5-10 minutes) and automated log parsing for security monitoring. Creates audit trail for compliance (SOC 2, PCI require centralized logging with retention).

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
