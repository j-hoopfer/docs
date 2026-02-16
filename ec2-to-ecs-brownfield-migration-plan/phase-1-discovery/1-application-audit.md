# Application Audit

**Goal:** Systematically review the application source code and runtime behavior to identify "Fargate Blockers" such as local file system writes, hardcoded IP addresses, or unmanaged background processes.

## Context & Themes

This document details the process of discovering and documenting the current state of the application on EC2. It ensures that all hidden dependencies, background processes, and local state are identified before migration begins, preventing "surprise" failures.

**Key Themes:**

- **Risk Identification:** Uncovering undocumented cron jobs and background workers.
- **Dependency Mapping:** Identifying local file system dependencies and internal traffic.
- **Operational Continuity:** Ensuring all business processes are accounted for before the move to Fargate.

## Prerequisites

Before starting this audit, ensure:

- [ ] SSH access to all production EC2 instances.
- [ ] `sudo` or root privileges to list all running processes and open ports.
- [ ] Access to the application source code repository (for cross-referencing).
- [ ] List of known endpoints and DNS records.

## Feature 1: Inventory Existing Infrastructure

**Business Value:** Prevents forgotten services from breaking during migration, protecting uptime and user experience. Cron jobs, background workers, and monitoring agents often run on EC2 but aren't documented—migrating without accounting for them causes silent failures.

### Story 1.1: Document Current EC2 Application Architecture

- **Title:** Inventory Current EC2 Deployment
- **Persona:** As a **DevOps engineer**, I need to fully document the current EC2 setup so that nothing is missed during migration.

**Business Value:** Creates the migration blueprint and risk assessment. Knowing exactly what runs on EC2 (web servers, cron jobs, workers, agents) prevents scope creep and forgotten components.

- **Requirements:**
  - Document all processes running on EC2
  - Document all cron jobs
  - Document all open ports and services
  - Document any local state or files

- **Implementation Details:**
  - **SSH to EC2 and run:**
    - `systemctl list-units --type=service --state=running` (running services)
    - `crontab -l` and `cat /etc/crontab` (scheduled jobs)
    - `netstat -tlnp` or `ss -tlnp` (open ports)
    - `df -h` (disk usage, identify data directories)
    - `ls -la /var/www/` or application directory
    - `cat /etc/nginx/sites-enabled/*` (nginx config)
    - `cat /etc/supervisor/conf.d/*` (if using supervisor)

- **Acceptance Criteria:**
  - ✅ Architecture diagram updated with current EC2 / RDS / Redis / ELB layout.
  - ✅ Spreadsheet created listing every running process on production servers.
  - ✅ List of all open ports and what service is listening on them.
  - ✅ "End-of-Support" date identified for current OS version.

### Story 1.2: Analyze Dependencies and Statefulness

- **Title:** Analyze Application State and Hardcoded Dependencies
- **Persona:** As a **System Auditor**, I need to examine the processes identified in Story 1.1 to find "Fargate Blockers" like local file writes, hardcoded IPs, or hidden configuration files.

- **Local State:** Does the app write to `/var/www/uploads` or `/tmp`?
- **Hardcoded IPs:** Run `grep -rE "10\.[0-9]{1,3}" .` in the code to find hardcoded internal IPs.
- **Hosts File:** `cat /etc/hosts` - are there manual DNS overrides preventing us from using Route53?
- **Shared Files:** Do cron jobs read files written by the main app?)

- **Requirements:**
  - Audit every process from Story 1.1 for local filesystem usage
  - Audit codebase for hardcoded IP addresses
  - Audit server configuration for manual host overrides
  - Determine if cron jobs are stateful (rely on previous runs)

  - **Critical Deep Dive: Cron Job Statefulness**
    - **The Risk:** Cron jobs on EC2 often rely on local file history from previous runs (e.g. `/tmp/last_run_id.txt`).
    - **Fargate Impact:** Each ECS task starts fresh. A cron job looking for a file from yesterday will fail.

    - **Example problematic patterns:**
      - Script reads `/tmp/last_run_id.txt` to determine what to process next
      - Incremental backup script checks local state file
      - ETL job tracks last processed record in local database
    - **Fargate impact:** Each ECS task starts fresh - no local state persists between runs
    - **Check for:**
      ```bash
      # Search cron scripts for file reads that might be state
      grep -r "/tmp/" /path/to/cron/scripts
      grep -r "\.txt\|\.json\|\.db" /path/to/cron/scripts
      # Look for any file I/O that isn't logging
      ```
    - **Migration strategies for stateful cron jobs:**
      1. **Use S3 for state files:** Store `last_run_id.txt` in S3, read/write on each run
      2. **Use DynamoDB for state:** Track processing state in DynamoDB table
      3. **Use RDS/database:** Store "last processed" timestamp in database
      4. **Make idempotent:** Design job to process full dataset each time (with deduplication)

- **Acceptance Criteria:**
  - ✅ All running services documented
  - ✅ All cron jobs documented with schedules
  - ✅ **Cron jobs verified as stateless or refactored to use external state (S3/DynamoDB/RDS)**
  - ✅ **Cron jobs tested to run successfully multiple times without side effects**
  - ✅ All open ports documented
  - ✅ Local data directories identified and migration plan created

### Story 1.3: Audit Current Logging Setup and Consumers

- **Title:** Document Current Logging Configuration and Downstream Dependencies
- **Persona:** As a **DevOps engineer**, I need to understand how logs are currently written, stored, and consumed so that I can ensure logging continues to work on both EC2 and ECS during migration.

**Business Value:** Protects observability and compliance during migration. Log shippers, SIEM integrations, and compliance tools often read directly from log files on EC2—switching to stdout logging without updating consumers breaks dashboards, alerts, and audit trails. Identifying log consumers upfront (1 hour) prevents blindness during the most critical migration window when monitoring is essential.

- **Requirements:**
  - Document where application logs are written today
  - Identify any systems that read/scrape/ship these logs
  - Understand log retention and rotation policies
  - Plan backward-compatible logging changes

- **Implementation Details:**
  - **Audit current log destinations:**
    - Where does the app write logs? (file path, stdout, syslog?)
    - `ls -la /var/log/` — check for app-specific log files
    - Check app config for logging settings (winston, log4j, monolog, etc.)
    - Check nginx/apache access and error log locations
  - **Audit log consumers (critical!):**
    - Is there a log shipper? (Filebeat, Fluentd, CloudWatch Agent, Datadog Agent?)
    - What files is it watching?
    - Where does it ship logs to? (ELK, Splunk, CloudWatch, Datadog?)
    - Are there any dashboards or alerts built on these logs?
    - Are there any scripts or tools that parse log files directly?
  - **Audit log rotation:**
    - Check `/etc/logrotate.d/` for app log rotation configs
    - How long are logs retained?
    - Any compliance requirements for log retention?
  - **Audit process manager log handling:**
    - If using systemd: `journalctl -u <service>` — stdout already captured
    - If using PM2: `~/.pm2/logs/` — stdout already captured
    - If using supervisor: check `stdout_logfile` in config
  - **Key questions to answer:**
    - If we switch to stdout logging, will log consumers still work?
    - Do we need to update log shipper configs?
    - Are there any file-path-dependent integrations that will break?

- **Acceptance Criteria:**
  - ✅ Current log file locations documented
  - ✅ All log consumers/shippers identified
  - ✅ Log shipping destinations documented (ELK, Splunk, CloudWatch, etc.)
  - ✅ Impact assessment: what breaks if we switch to stdout?
  - ✅ Migration plan for log consumers documented

### Story 1.4: Audit Host-Level Agents and APM Tools

- **Title:** Inventory OS-Level Monitoring and Security Agents
- **Persona:** As a **DevOps engineer**, I need to audit all host-level agents running on EC2 so that I can plan their migration to sidecar containers or AWS-native alternatives, avoiding blind spots in observability and security after moving to Fargate.

**Business Value:** Preserves security posture and operational visibility during migration. Security agents (CrowdStrike, Qualys), APM tools (Datadog, New Relic), and monitoring agents provide critical protection and insights—losing them during migration creates security gaps and blind spots. Planning agent migration (2-3 hours) vs. discovering monitoring gaps in production (high-severity incidents with no visibility) protects compliance and incident response capabilities.

- **Requirements:**
  - Identify all running agents on EC2 instances (APM, monitoring, security)
  - Determine which agents are compatible with Fargate
  - Plan migration strategy for each agent (sidecar, AWS native, or discontinue)
  - Update application architecture to include sidecars where needed

- **Implementation Details:**
  - **SSH to EC2 and audit running processes:**
    ```bash
    ps aux | grep -E 'datadog|newrelic|dynatrace|splunk|crowdstrike|falcon|qualys'
    systemctl list-units --type=service | grep -E 'datadog|newrelic|dynatrace'
    dpkg -l | grep -E 'datadog|newrelic'  # Debian/Ubuntu
    rpm -qa | grep -E 'datadog|newrelic'  # RHEL/Amazon Linux
    ```
  - **Common agents and their Fargate strategies:**

    | Agent Type       | EC2 Agent                | Fargate Strategy                                             |
    | ---------------- | ------------------------ | ------------------------------------------------------------ |
    | **APM**          | Datadog Agent            | Sidecar container OR Datadog Lambda extension                |
    |                  | New Relic Infrastructure | Not supported - use New Relic APM library                    |
    |                  | Dynatrace OneAgent       | Sidecar container with proper configuration                  |
    | **Log Shipping** | Filebeat, Fluentd        | **Not needed** - use awslogs driver instead                  |
    |                  | Splunk Forwarder         | **Not needed** - ship logs via Firehose or Lambda            |
    |                  | CloudWatch Agent         | **Not needed** - use awslogs driver                          |
    | **Security**     | CrowdStrike Falcon       | **Not supported on Fargate** - use AWS GuardDuty + Inspector |
    |                  | Qualys, Tenable          | **Not supported** - scan container images in ECR instead     |
    | **Service Mesh** | Consul Agent             | Not recommended - use AWS App Mesh or Service Connect        |

  - **Decision tree for each agent:**
    1. **Is there an AWS-native alternative?**
       - **Monitoring:** CloudWatch Container Insights (built-in)
       - **Logs:** CloudWatch Logs (awslogs driver)
       - **Security:** GuardDuty, Inspector, Security Hub
       - → **Preferred:** Use AWS native tools
    2. **Does the vendor support Fargate sidecar?**
       - **Datadog:** Yes ([docs](https://docs.datadoghq.com/integrations/ecs_fargate/))
       - **New Relic:** Yes, via sidecar
       - **Dynatrace:** Yes ([docs](https://www.dynatrace.com/support/help/setup-and-configuration/setup-on-container-platforms/amazon-web-services/amazon-ecs/deploy-oneagent-as-ecs-fargate-sidecar))
       - → **Acceptable:** Deploy as sidecar container
    3. **Can we instrument the app instead of using a host agent?**
       - **APM:** Use application-level SDK (Datadog Tracer, New Relic APM library, X-Ray SDK)
       - → **Good:** Less infrastructure overhead
    4. **Is this agent still needed?**
       - Legacy agents from previous vendors
       - Duplicate monitoring (e.g., both Datadog and CloudWatch)
       - → **Best:** Simplify and consolidate

  - **Sidecar container example (Datadog):**
    ```json
    {
      "containerDefinitions": [
        {
          "name": "app",
          "image": "my-app:latest",
          "portMappings": [{ "containerPort": 3000 }],
          "environment": [
            { "name": "DD_AGENT_HOST", "value": "localhost" },
            { "name": "DD_TRACE_AGENT_PORT", "value": "8126" }
          ]
        },
        {
          "name": "datadog-agent",
          "image": "public.ecr.aws/datadog/agent:latest",
          "environment": [
            { "name": "DD_API_KEY", "valueFrom": "arn:aws:secretsmanager:..." },
            { "name": "ECS_FARGATE", "value": "true" },
            { "name": "DD_APM_ENABLED", "value": "true" }
          ]
        }
      ]
    }
    ```
  - **Cost implications:**
    - Sidecar containers consume additional vCPU/memory (e.g., Datadog agent ~128MB)
    - Calculate: (Number of tasks) × (Agent memory) × $0.004445/GB/hour
    - Example: 10 tasks × 128MB × 730 hours = ~$4/month extra
  - **Migration planning:**
    - **Phase 0 (Discovery):** Audit and plan (this story)
    - **Phase 1 (App Readiness):** Update task definitions to include sidecars
    - **Phase 3 (Deployment):** Deploy with sidecars and verify metrics/logs flow

- **Acceptance Criteria:**
  - ✅ All host-level agents identified and categorized
  - ✅ Migration strategy documented for each agent (AWS native, sidecar, discontinue)
  - ✅ Sidecar container task definitions drafted for required agents
  - ✅ Cost impact of sidecars calculated
  - ✅ Team trained on sidecar deployment pattern
  - ✅ Dashboards and alerts verified to work with new agent architecture

---

## Feature 2: Secrets & Configuration Audit

**Business Value:** Eliminates security vulnerabilities and prevents compliance violations. Hardcoded secrets in code or Docker images create audit findings and security incidents (average cost: $50K-200K per breach). Moving to Secrets Manager (1 day effort) achieves SOC2/HIPAA compliance requirements and prevents credential leaks. Also enables secure secret rotation without application restarts.

### Story 2.1: Document Secret Requirements

- **Title:** Document Secret Types and Configuration Needs
- **Persona:** As a **cloud architect**, I need to understand what types of secrets the application uses so that I can plan Secrets Manager structure and IAM permissions in Phase 2.

**Business Value:** Creates high-level inventory of what secrets and configuration types are needed, enabling proper Secrets Manager planning in Phase 2. This 30-minute exercise prevents discovering missing secrets during deployment (causing rollback delays) and ensures Phase 1 developers know what to externalize.

- **Requirements:**
  - Identify secret categories (database, API keys, tokens, certificates)
  - Document where secrets currently live (EC2 files, environment variables)
  - List third-party integrations requiring credentials
  - Plan secret storage strategy (Secrets Manager vs SSM Parameter Store)

- **Implementation Details:**
  - **High-level inventory (no code diving yet):**
    - SSH to EC2 and list `.env` files and config directories
    - Check systemd/supervisor configs for environment variable usage
    - Document known integrations (Stripe, SendGrid, etc.)
  - **Categorize secret types:**
    - **Secrets** (DB passwords, API keys, tokens) → Secrets Manager
    - **Sensitive config** (internal URLs, feature flags) → SSM Parameter Store
    - **Non-sensitive config** (log levels, timeouts) → ECS Task Definition environment
  - **Create simple inventory table:**

    | Secret Type      | Current Location | Destination     | Notes              |
    | ---------------- | ---------------- | --------------- | ------------------ |
    | DB Password      | `/app/.env`      | Secrets Manager | RDS credentials    |
    | Stripe API Key   | `/app/.env`      | Secrets Manager | Payment processing |
    | Redis Password   | Systemd config   | Secrets Manager | ElastiCache        |
    | SendGrid API Key | `/app/.env`      | Secrets Manager | Email service      |
    | Log Level        | `.env`           | Task Definition | Non-sensitive      |

  - **Note:** Actual code scanning for hardcoded secrets happens in Phase 1, Story 2.1

- **Acceptance Criteria:**
  - ✅ Secret types documented (database, API keys, integrations)
  - ✅ Current storage locations identified (files, configs)
  - ✅ Planned destination documented (Secrets Manager, SSM, Task Def)
  - ✅ Inventory shared with Phase 1 team for implementation

---

## Feature 3: Service-to-Service Communication Audit

**Business Value:** Prevents performance degradation and unnecessary costs from inefficient traffic routing. Internal service calls that hairpin through the internet (service → NAT → ALB → service) add 100-500ms latency and incur NAT data transfer fees ($50-200/month). Planning internal communication correctly (2-3 hours) improves response times by 40-60% and reduces infrastructure costs, directly impacting user experience and margins.

### Story 3.1: Inventory Internal Service Calls

- **Title:** Audit How Applications Communicate Internally
- **Persona:** As a **DevOps engineer**, I need to understand how our applications call each other today so that I can ensure internal traffic stays in the VPC after migration and doesn't accidentally hairpin through the internet.

**Business Value:** Identifies hidden performance bottlenecks before they impact users. Services calling each other via public URLs instead of internal DNS add unnecessary latency (100-500ms per request) and create NAT data transfer costs. Discovering this pattern in Phase 0 allows architecture improvements that enhance user experience and reduce monthly costs by $100-300.

- **Requirements:**
  - Identify all service-to-service communication patterns
  - Document the URLs/endpoints each app uses to call other internal services
  - Determine if calls use public URLs or private IPs/hostnames
  - Plan internal communication strategy for ECS

- **Implementation Details:**
  - **Audit current state:**
    - Search codebase for HTTP client calls to other internal services
    - Check environment variables for service URLs (e.g., `AUTH_API_URL`, `USER_SERVICE_URL`)
    - Review nginx/proxy configs for upstream definitions
    - Check `/etc/hosts` for any hostname mappings
  - **Common patterns to look for:**
    - `http://10.x.x.x:3000/...` (private IP — good, but won't work with dynamic ECS tasks)
    - `http://auth-api.internal:3000/...` (private DNS — ideal)
    - `https://api.example.com/auth/...` (public URL — BAD for internal calls)
  - **The trap:**
    - If services call each other via the public ALB URL, traffic goes: Task → NAT Gateway → Internet → ALB → Target task
    - This is slow, costly (NAT data transfer fees), and breaks if NAT/internet has issues
    - Traffic should stay inside the VPC
  - **Document for each service:**
    - What other internal services does it call?
    - What URL pattern does it use?
    - Is it configurable via environment variable?

- **Acceptance Criteria:**
  - ✅ All internal service-to-service calls documented
  - ✅ Current URL patterns identified (public vs private)
  - ✅ Services using public URLs flagged for update
  - ✅ Internal communication strategy selected for ECS

### Story 3.2: Plan Internal Communication Strategy

- **Title:** Select ECS Internal Communication Pattern
- **Persona:** As a **cloud architect**, I need to select the internal communication strategy for ECS so that service-to-service calls are fast, reliable, and stay within the VPC.

**Business Value:** Optimizes internal traffic for speed and cost-efficiency. Internal ALB costs $16/month but saves $100-300/month in NAT fees while improving latency by 40-60%. This decision (1 hour of planning) pays for itself immediately and scales with service growth. Proper service discovery also enables modern microservices architecture, supporting future business agility.

- **Requirements:**
  - Evaluate options for internal service discovery
  - Select approach based on complexity and requirements
  - Plan implementation for Phase 2 (infrastructure) and Phase 3 (deployment)

- **Implementation Details:**
  - **Option 1: Internal Application Load Balancer (Recommended)**
    - Create a second ALB, internal-facing only (not internet-facing)
    - Use same host-based routing pattern as external ALB
    - Services call: `http://internal-alb.yourcompany.local/service-name/endpoint`
    - Pros:
      - Familiar pattern (same as external ALB)
      - Single stable DNS name
      - Health checks built-in
      - Easy to implement — just add another ALB
      - Apps only need env var change (`SERVICE_URL=http://internal-alb/...`)
    - Cons:
      - Extra ALB cost (~$16/month + LCU charges)
      - Extra hop (task → ALB → task)
    - Security: Internal ALB only accessible from within VPC (security group restricts to VPC CIDR)
  - **Option 2: AWS Cloud Map (Service Discovery)**
    - Register services with Cloud Map namespace (e.g., `services.local`)
    - Services call: `http://auth-api.services.local:3000/endpoint`
    - DNS resolves directly to task private IP
    - Pros:
      - No extra ALB hop (direct task-to-task)
      - Lower latency
      - No additional ALB cost
    - Cons:
      - More complex setup
      - No built-in load balancing (relies on DNS round-robin or client-side)
      - Requires ECS Service Discovery configuration
    - Best for: High-volume internal traffic, latency-sensitive calls
    - Consider as Phase 4 optimization after Internal ALB is working
  - **Option 3: Environment Variables with Task IPs**
    - Not recommended — ECS tasks get dynamic IPs, would need constant updates

- **Recommendation:**
  - Start with Internal ALB (Option 1) — simpler, familiar, works reliably
  - If internal traffic volume is high and latency matters, add Cloud Map (Option 2) in Phase 4
  - Both options keep traffic inside the VPC

- **Infrastructure impact:**
  - Phase 2: Create Internal ALB, internal target groups, private hosted zone for DNS
  - Phase 3: Add internal ALB target group per service, configure internal DNS
  - Phase 1 (App): Update env vars to use internal URL pattern

- **Acceptance Criteria:**
  - ✅ Internal communication strategy selected and documented
  - ✅ Decision rationale documented
  - ✅ Infrastructure requirements identified for Phase 2
  - ✅ App configuration changes identified for Phase 1

### Story 3.3: Evaluate Internal TLS Requirements

- **Title:** Assess Need for TLS on Internal Service-to-Service Traffic
- **Persona:** As a **security engineer**, I need to evaluate whether internal service-to-service traffic requires TLS encryption so that we make an informed decision and document the rationale.

**Business Value:** Balances compliance requirements with operational complexity. For regulated industries (healthcare, finance), internal TLS is mandatory for compliance (HIPAA, PCI-DSS) and avoids audit findings that block enterprise sales. For non-regulated companies, documenting the "VPC as trust boundary" decision (30 minutes) satisfies security reviews and avoids over-engineering that slows velocity. Right-sizing security prevents both compliance violations and analysis paralysis.

- **Requirements:**
  - Review current internal communication security model
  - Assess compliance/regulatory requirements for encryption in transit
  - Evaluate options if internal TLS is required
  - Document decision and rationale

- **Implementation Details:**
  - **Questions to answer:**
    - Does our compliance framework (SOC2, HIPAA, PCI-DSS, etc.) require encryption for internal traffic?
    - Is "VPC as trust boundary" acceptable per our security policy?
    - What sensitive data flows between internal services?
    - Are there any regulatory audit findings requiring internal TLS?
  - **Current state:**
    - Document: Do internal calls use TLS today? (likely no)
    - Document: What is the current security justification? (likely: private network, perimeter auth)
  - **Options if internal TLS is required:**
    - **Option A: Internal ALB with HTTPS** (simplest)
      - Internal ALB terminates TLS using ACM private certificate
      - Traffic: Task → HTTPS → Internal ALB → HTTP → Target Task
      - Pros: Easy setup, ACM handles cert rotation
      - Cons: Last hop (ALB to task) is unencrypted
    - **Option B: End-to-End TLS** (complex)
      - Each application terminates TLS with its own certificate
      - Requires certificate management solution (HashiCorp Vault, cert-manager, etc.)
      - Significant app changes required
    - **Option C: Service Mesh with mTLS** (most complex)
      - AWS App Mesh with Envoy sidecars
      - Automatic mutual TLS between all services
      - Pros: Automatic cert rotation, zero app changes for TLS
      - Cons: Significant infrastructure complexity, operational overhead
  - **Recommendation:**
    - If internal TLS is not required today: Document decision, proceed with migration, revisit later
    - If internal TLS is required: Start with Option A (Internal ALB + HTTPS), defer mesh to future project
    - Do not add internal TLS complexity during migration unless mandated

- **Acceptance Criteria:**
  - ✅ Compliance/regulatory requirements for internal TLS documented
  - ✅ Current internal TLS state documented
  - ✅ Decision made: internal TLS required (yes/no)
  - ✅ If yes: implementation approach selected
  - ✅ If no: rationale documented for audit trail
