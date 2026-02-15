# Activity 4: Traffic Routing

## Feature 5: ALB Routing

**Business Value:** Connects application to internet traffic through production domain, completing end-to-end deployment. ALB listener rules (15-20 minutes) enable host-based routing supporting unlimited services on one load balancer, saving $16-50/month per service vs. dedicated ALBs. DNS configuration (10-15 minutes) provides friendly domain access and enables gradual cutover via weighted routing (Strangler Fig). Completes first production deployment proving migration pattern works.

### Story 5.1: Configure Host-Based Routing

**Business Value:** Routes production traffic to Fargate containers via host/path-based rules, enabling multi-service architecture on shared infrastructure. Listener rule (10-15 minutes) connects domain to target group, completing the deployment pipeline from code to customer traffic. Host-based routing enables unlimited services on one ALB (saving $16-50/month per additional service). Priority-based rule evaluation provides traffic control for gradual migrations and A/B testing. Final step before application receives real traffic.

- **Title:** Create ALB Listener Rule for Application
- **Persona:** As a **Network Engineer**, I want to configure routing rules so that requests for `auth.mysite.com` go to the auth-api service while `admin.mysite.com` goes to a different service.

- **Requirements:**
  - Each application has unique domain or path
  - ALB routes based on Host header
  - HTTPS listener handles all routing

- **Implementation Details:**
  - **Via AWS Console:**
    1. Go to **EC2 → Load Balancers → [Your ALB] → Listeners**
    2. Select **HTTPS:443** listener
    3. Click **Manage rules** (or **View/edit rules**)
    4. Click **Insert rule** (the + icon)
    5. Add condition:
       - Type: **Host header**
       - Value: `auth.mysite.com` (or your domain)
    6. Add action:
       - Type: **Forward to**
       - Target group: `auth-api-tg`
    7. Set priority:
       - Priority: **100** (increment by 10 for each service)
    8. Click **Save**
  - **Via AWS CLI:**

    ```bash
    # Get listener ARN
    LISTENER_ARN=$(aws elbv2 describe-listeners \
      --load-balancer-arn <alb-arn> \
      --query 'Listeners[?Port==`443`].ListenerArn' \
      --output text)

    # Create listener rule
    aws elbv2 create-rule \
      --listener-arn $LISTENER_ARN \
      --priority 100 \
      --conditions Field=host-header,Values=auth.mysite.com \
      --actions Type=forward,TargetGroupArn=<target-group-arn>

    # Verify rule
    aws elbv2 describe-rules --listener-arn $LISTENER_ARN
    ```

  - **Listener Rule Configuration:**
    - Listener: HTTPS:443 on `fargate-shared-alb`
    - Priority: Lower number = higher priority (start at 100, increment by 10)
  - **Condition (Host Header):**
    - Type: Host header
    - Value: `auth.mysite.com`
    - Can include wildcards: `*.api.mysite.com`
  - **Action:**
    - Type: Forward to target group
    - Target group: `auth-api-tg`
  - **Alternative: Path-Based Routing:**
    - Condition: Path pattern `/api/auth/*`
    - Useful when all apps share one domain
    - Requires app to handle path prefix
  - **Rule Priority Strategy:**
    | Priority | Host/Path | Target |
    |----------|-----------|--------|
    | 100 | auth.mysite.com | auth-api-tg |
    | 110 | admin.mysite.com | admin-tg |
    | 120 | api.mysite.com/v1/_ | api-v1-tg |
    | 200 | _.mysite.com | default-tg |
    | Default | \* | Return 404 |
  - **How It Works:**
    1. Request arrives at ALB for `auth.mysite.com`
    2. ALB evaluates rules in priority order
    3. Rule 100 matches: Host header = `auth.mysite.com`
    4. ALB forwards to `auth-api-tg`
    5. Target Group routes to healthy Fargate task
    6. Response returns through ALB to client

- **Acceptance Criteria:**
  - ✅ Listener rule created with correct priority
  - ✅ Host header condition matches application domain
  - ✅ Action forwards to correct target group
  - ✅ Request to domain returns application response (not 404)

---

### Story 5.2: Configure DNS

**Business Value:** Makes application accessible via production domain, completing the transition to Fargate. DNS configuration (10-15 minutes) enables customer access through friendly URLs instead of ugly ALB endpoints. Route 53 Alias records (recommended) provide instant failover capability and no extra DNS lookup delay. Gradual migration approach (test subdomain → production cutover) reduces risk of DNS issues impacting customers. Completion here means first application is fully migrated and serving production traffic from Fargate.

- **Title:** Point Domain to ALB
- **Persona:** As a **DevOps Engineer**, I want DNS configured so that users can access the application via a friendly domain name.

- **Requirements:**
  - DNS record points application domain to ALB
  - Record type appropriate for ALB (CNAME or Alias)
  - TTL allows for reasonable failover time

- **Implementation Details:**
  - **Option A: Route 53 (Recommended):**
    - Record type: A (Alias)
    - Alias target: Select ALB from dropdown
    - Why Alias: Works at zone apex (mysite.com), no extra DNS lookup
  - **Option B: External DNS (GoDaddy, Cloudflare, etc.):**
    - Record type: CNAME
    - Value: ALB DNS name (e.g., `fargate-shared-alb-123.us-east-1.elb.amazonaws.com`)
    - TTL: 300 seconds (5 minutes)
    - Note: CNAME cannot be used for zone apex
  - **For Migration (Blue/Green):**
    1. Keep old DNS pointing to EC2
    2. Add new subdomain pointing to ALB for testing (e.g., `auth-new.mysite.com`)
    3. Test thoroughly
    4. Update production DNS to point to ALB
    5. Keep EC2 running for rollback (1-2 weeks)
  - **Verify DNS Propagation:**

    ```bash
    # Check DNS resolution
    dig auth.mysite.com

    # Check HTTPS works
    curl -I https://auth.mysite.com/health

    # Check from different locations
    # Use: https://www.whatsmydns.net/
    ```

- **Acceptance Criteria:**
  - ✅ DNS record created pointing to ALB
  - ✅ `dig` or `nslookup` resolves to ALB IP
  - ✅ `https://[domain]/health` returns 200
  - ✅ HTTP redirects to HTTPS
