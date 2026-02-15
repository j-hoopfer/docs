# Activity 3: Service Discovery

## Feature 3: Internal Service Communication

**Business Value:** Reduces internal network latency and cost by enabling direct service-to-service communication, bypassing the load balancer. Service Discovery (Cloud Map) allows services to find each other via internal DNS (e.g., `auth-api.production.local`), simplifying configuration and removing the need for hardcoded IPs or external load balancers for internal traffic. This optimization typically saves $15-50/month per load balancer and reduces latency by 10-50ms per request.

> **⚠️ IMPORTANT: This feature is a FUTURE OPTIMIZATION, not required for migration.**
>
> During migration, you will use the **Internal ALB** (set up in Phase 2) for all internal service-to-service communication. The Internal ALB is required for the Strangler Fig cutover pattern.
>
> Cloud Map Service Discovery is an **optional optimization** to consider 3-6 months after migration is complete. It removes the ALB hop for slightly lower latency and cost savings, but adds complexity.
>
> **Migration phases:**
>
> 1. **During migration:** KrakenD and services → Internal ALB → EC2/ECS (weighted routing)
> 2. **Post-migration (optional):** Services → Cloud Map DNS → ECS directly (no ALB hop)

### Story 3.1: Enable AWS Cloud Map Service Discovery

- **Title:** Configure Direct Service-to-Service Communication (Post-Migration Optimization)
- **Persona:** As a **Developer**, I want services to communicate directly via DNS so that we eliminate the Internal ALB hop for lower latency.

- **Requirements:**
  - Internal DNS names for each service
  - No public internet routing for internal calls
  - Automatic registration/deregistration of tasks

- **Prerequisites:**
  - All services fully migrated to ECS (100% traffic, EC2 decommissioned)
  - Internal ALB no longer needed for weighted routing
  - Team comfortable with ECS operations

- **Implementation Details:**
  - **Context: Why This is Optional**
    - The Internal ALB already solves the "keep traffic in VPC" problem
    - Cloud Map removes the ALB hop: Service A → DNS → Service B task IP directly
    - Trade-off: Slightly lower latency vs. losing ALB's health checks and load balancing
    - If your internal traffic volume is low, the ALB cost (~$16/month) may not be worth optimizing away
  - **The Problem Cloud Map Solves:**
    - With Internal ALB: App A → Internal ALB → App B (extra network hop)
    - With Cloud Map: App A → App B directly (DNS resolves to task IP)
    - Latency improvement: ~1-5ms (usually negligible unless high-volume internal calls)
  - **The Solution (Cloud Map):**
    - With Service Discovery: App A calls `http://app-b.production.local:3000`
    - Traffic flow: App A → VPC internal network → App B (direct)
    - Benefits:
      - Slightly lower latency (no ALB hop)
      - No ALB cost for internal traffic
      - No TLS needed (internal traffic)
  - **Setup Steps:**
    1. **Create Cloud Map Namespace:**
       - AWS Console → Cloud Map → Create namespace
       - Name: `production.local` (or `internal.yourcompany`)
       - Type: Private DNS namespace
       - VPC: Select your Fargate VPC
    2. **Enable Service Discovery on ECS Service:**
       - When creating ECS Service, expand "Service discovery"
       - Enable service discovery integration
       - Namespace: Select `production.local`
       - Service discovery name: `auth-api` (becomes `auth-api.production.local`)
       - DNS record type: A (for IP-based routing)
       - TTL: 60 seconds
    3. **Update Application Configuration:**
       - Old: `API_URL=https://api.yoursite.com`
       - New: `AUTH_SERVICE_URL=http://auth-api.production.local:3000`
       - Note: Use HTTP (not HTTPS) for internal traffic
  - **Service Discovery DNS Names:**
    | Service | Internal DNS | Port |
    |---------|-------------|------|
    | auth-api | auth-api.production.local | 3000 |
    | user-api | user-api.production.local | 3000 |
    | notification-service | notifications.production.local | 3000 |
    | admin-panel | admin-panel.production.local | 3000 |
  - **Security Group Updates:**
    - Services that receive internal traffic need SG rules:
    - Add inbound rule: Port 3000 from `[calling-service]-sg`
    - Or create a shared `internal-services-sg` that all internal services use

- **Acceptance Criteria:**
  - ✅ Cloud Map namespace created
  - ✅ ECS services register with service discovery
  - ✅ `dig auth-api.production.local` resolves inside VPC
  - ✅ Internal service calls work without public internet
  - ✅ No NAT Gateway charges for internal traffic

---

### Story 3.2: Update Application Configurations for Internal Routing

- **Title:** Refactor Service URLs to Use Internal DNS
- **Persona:** As a **Developer**, I want to update service configurations so that internal calls use the private network.

- **Requirements:**
  - Identify all inter-service communication
  - Update URLs to use internal DNS names
  - Maintain external URLs for client-facing endpoints

- **Implementation Details:**
  - **Audit Current Service Communication:**
    - Map which services call which other services
    - Example dependency map:
      ```
      frontend → auth-api (login, token validation)
      frontend → user-api (profile, settings)
      admin-panel → user-api (user management)
      admin-panel → notification-service (send alerts)
      user-api → notification-service (welcome emails)
      ```
  - **Configuration Pattern:**

    ```javascript
    // config.js
    module.exports = {
      // External (client-facing) - keep public URLs
      publicUrl: process.env.PUBLIC_URL || "https://api.yoursite.com",

      // Internal (server-to-server) - use service discovery
      services: {
        auth:
          process.env.AUTH_SERVICE_URL ||
          "http://auth-api.production.local:3000",
        user:
          process.env.USER_SERVICE_URL ||
          "http://user-api.production.local:3000",
        notifications:
          process.env.NOTIFICATION_SERVICE_URL ||
          "http://notifications.production.local:3000",
      },
    };
    ```

  - **Environment Variables (Task Definition):**
    ```json
    "environment": [
      { "name": "AUTH_SERVICE_URL", "value": "http://auth-api.production.local:3000" },
      { "name": "USER_SERVICE_URL", "value": "http://user-api.production.local:3000" },
      { "name": "PUBLIC_URL", "value": "https://api.yoursite.com" }
    ]
    ```
  - **Testing Internal Connectivity:**

    ```bash
    # Exec into a running task
    aws ecs execute-command --cluster production-cluster \
      --task <task-id> --container auth-api --interactive \
      --command "/bin/sh"

    # Test DNS resolution
    nslookup user-api.production.local

    # Test connectivity
    curl http://user-api.production.local:3000/health
    ```

- **Acceptance Criteria:**
  - ✅ Service dependency map documented
  - ✅ Internal URLs configured in task definitions
  - ✅ Services can reach each other via internal DNS
  - ✅ External client traffic still uses public ALB URLs
