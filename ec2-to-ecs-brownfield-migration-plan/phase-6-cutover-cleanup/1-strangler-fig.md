# Activity 1: Strangler Fig Migration

**Goal:** Execute a zero-downtime cutover from EC2 to Fargate using weighted routing, validate system stability through canary releases, and safely decommission legacy infrastructure.

## Context & Themes

Directly switching traffic (Big Bang) is too risky. By using an internal load balancer (Strangler Fig pattern), we can route traffic incrementally (1%, 5%, 50%, 100%) to the new Fargate services. This allows instant rollback if issues arise, ensuring business continuity.

**Key Themes:**

- **Zero-Downtime:** No service interruption.
- **Incremental Migration:** Controlling risk through granularity.
- **Risk Reversal:** Immediate rollback capability.

### Prerequisites

- [ ] All services migrated to Fargate (Phase 5 completed).
- [ ] Platform Repository Setup completed.
- [ ] Services Repository Setup completed.

## Feature 1: Strangler Fig Migration Pattern

**Business Value:** Minimizes risk during migration by allowing gradual traffic shifting from legacy EC2 to new Fargate infrastructure. The Strangler Fig pattern enables 0-100% traffic control (canary releases).

**(Junior Engineer Context: This is the safest way to deploy. If anything breaks, you can Rollback in <10 seconds by switching the ALB weights back to 100% Legacy / 0% Fargate. Also, remember: we are NOT migrating the database; both systems share the same RDS instance.)**

### Story 1.1: Create Internal ALB for Traffic Mixing

- **Title:** Set Up Internal Load Balancer for Gradual Cutover
- **Persona:** As a **Operations Engineer**, I want to gradually shift traffic from EC2 to Fargate so that we can validate the new platform with real traffic before full cutover.

- **Requirements:**
  - Route percentage of traffic to Fargate (canary)
  - Ability to quickly rollback to EC2
  - No application code changes for traffic shifting
  - Works with existing API Gateway/KrakenD architecture

- **Implementation Details:**
  - **Architecture Overview:**

    ```
    Current:
    Public ALB → KrakenD (EC2) → Apps (EC2) → DB

    With Internal ALB (Traffic Mixer):
    Public ALB → KrakenD (EC2) → Internal ALB → [EC2 (90%) | Fargate (10%)] → DB
    ```

  - **Why Internal ALB:**
    - KrakenD doesn't have native weighted routing
    - ALB has built-in weighted target group routing
    - Single config change in KrakenD (point to Internal ALB)
    - Traffic split controlled via AWS Console (no redeploy needed)
  - **Step 1: Create Internal ALB**
    - AWS Console → EC2 → Load Balancers → Create
    - Name: `internal-traffic-mixer`
    - Scheme: **Internal** (not internet-facing)
    - VPC: Same as Fargate tasks
    - Subnets: Private subnets
    - Security Group: Allow traffic from KrakenD SG
  - **Step 2: Create Target Groups**
    - **Legacy Target Group (EC2):**
      - Name: `legacy-auth-api-tg`
      - Target Type: **Instance**
      - Register: Existing EC2 instances running auth-api
      - Health Check: `/health`
    - **Fargate Target Group:**
      - Name: `fargate-auth-api-tg`
      - Target Type: **IP**
      - Auto-registered by ECS Service
      - Health Check: `/health`
  - **Step 3: Configure Weighted Routing**
    - Create HTTPS listener on Internal ALB (or HTTP if internal traffic doesn't need encryption)
    - Listener Rule:
      - Forward to target groups:
        - `legacy-auth-api-tg`: Weight **100**
        - `fargate-auth-api-tg`: Weight **0**
    - This starts with 100% traffic to EC2
  - **Step 4: Update KrakenD**
    - Change backend URL from EC2 direct IP to Internal ALB DNS:

    ```json
    {
      "endpoint": "/api/auth",
      "backend": [
        {
          "host": ["http://internal-traffic-mixer.production.local"],
          "url_pattern": "/auth"
        }
      ]
    }
    ```

    - Deploy KrakenD once. All future traffic shifts happen via ALB weights.

- **Acceptance Criteria:**
  - ✅ Internal ALB created in private subnets
  - ✅ Both target groups (EC2 and Fargate) created
  - ✅ KrakenD updated to point to Internal ALB
  - ✅ 100% traffic flowing through Internal ALB to EC2 (baseline)

---

### Story 1.2: Execute Canary Release

- **Title:** Gradually Shift Traffic to Fargate
- **Persona:** As a **Operations Engineer**, I want to incrementally shift traffic so that I can monitor for errors before committing to full migration.

- **Requirements:**
  - Start with 0% Fargate, end with 100%
  - Monitor error rates at each increment
  - Ability to instant rollback
  - No downtime during shifts

- **Implementation Details:**
  - **Traffic Shifting Schedule:**
    | Day | EC2 Weight | Fargate Weight | Duration | Action |
    |-----|------------|----------------|----------|--------|
    | 1 | 100% | 0% | Baseline | Verify ALB routing works |
    | 2 | 95% | 5% | 4 hours | Monitor error rates |
    | 2 | 90% | 10% | 24 hours | Extended monitoring |
    | 3 | 75% | 25% | 24 hours | Increase if stable |
    | 4 | 50% | 50% | 24 hours | Half traffic |
    | 5 | 25% | 75% | 24 hours | Majority on Fargate |
    | 6 | 0% | 100% | Ongoing | Full migration |
  - **How to Shift Traffic:**
    - AWS Console → EC2 → Target Groups
    - Select Internal ALB listener
    - Edit rule → Modify weights
    - No deployment, no KrakenD changes—instant effect
  - **Monitoring During Canary:**
    - **CloudWatch Metrics to Watch:**
      - `HTTPCode_Target_5XX_Count` (both target groups)
      - `TargetResponseTime` (compare EC2 vs Fargate)
      - `HealthyHostCount` (both target groups)
      - `UnHealthyHostCount` (should be 0)
    - **CloudWatch Logs:**
      - Search for `error` or `exception` in Fargate logs
      - Compare error patterns to EC2 logs
    - **Application Metrics (if APM in place):**
      - Response time percentiles (p50, p95, p99)
      - Error rates by endpoint
      - Database query times
  - **Rollback Trigger Criteria:**
    | Metric | Threshold | Action |
    |--------|-----------|--------|
    | 5XX Error Rate | > 1% increase | Rollback to previous weight |
    | Response Time | > 50% increase | Investigate, consider rollback |
    | Healthy Hosts | < desired count | Immediate rollback |
    | User Reports | Critical bug reports | Immediate rollback |
  - **Rollback Procedure:**
    1. Go to EC2 → Load Balancers → Internal ALB → Listeners
    2. Edit rule weights: EC2 = 100%, Fargate = 0%
    3. Changes take effect within seconds
    4. Monitor traffic shift in Target Group metrics
    5. Investigate Fargate issues before next attempt
- **Acceptance Criteria:**
  - ✅ Traffic successfully shifted through all stages
  - ✅ No increase in error rates during migration
  - ✅ Fargate response times comparable to EC2
  - ✅ 100% traffic on Fargate with stable metrics

---

### Story 1.3: Decommission Legacy Infrastructure

- **Title:** Clean Up EC2 Resources After Migration
- **Persona:** As a **Cloud Engineer**, I want to decommission old infrastructure so that we stop paying for unused resources.

- **Requirements:**
  - Confirm Fargate is handling 100% traffic successfully
  - Remove EC2 from target group
  - Terminate EC2 instances (after retention period)
  - Clean up associated resources

- **Implementation Details:**
  - **Decommission Checklist (Per Application):**
    - [ ] Fargate handling 100% traffic for 7+ days
    - [ ] No error rate increase
    - [ ] No user complaints
    - [ ] Rollback not needed in past week
  - **Step 1: Remove EC2 from Target Group**
    - AWS Console → EC2 → Target Groups → `legacy-auth-api-tg`
    - Deregister instances
    - Wait for connection draining (default 300s)
  - **Step 2: Stop EC2 Instance (Don't Terminate Yet)**
    - Stop instance (keeps EBS volumes)
    - Retention period: 7-14 days
    - Why: Easy restart if critical issue discovered
  - **Step 3: Create AMI Backup**
    - AWS Console → EC2 → Instances → Create Image
    - Name: `auth-api-ec2-backup-YYYYMMDD`
    - Store in case of disaster recovery need
  - **Step 4: Terminate EC2 Instance**
    - After retention period with no issues
    - Terminate instance
    - Delete associated EBS volumes (if not needed)
  - **Step 5: Clean Up Associated Resources**
    - [ ] Delete legacy target group
    - [ ] Remove old security group rules referencing EC2
    - [ ] Delete EC2 security group (if app-specific)
    - [ ] Remove old CloudWatch log groups
    - [ ] Update monitoring dashboards
    - [ ] Update documentation
  - **Cost Savings Calculation:**
    | Resource | Monthly Cost | Notes |
    |----------|-------------|-------|
    | EC2 t3.medium | ~$30 | Per instance |
    | EBS 50GB | ~$5 | Per instance |
    | Old ELB (if exists) | ~$18 | If migrating to shared ALB |
    | **Potential Savings** | ~$53/app | Times 10 apps = $530/month |

- **Acceptance Criteria:**
  - ✅ EC2 instances terminated
  - ✅ AMI backups created
  - ✅ Legacy target groups deleted
  - ✅ No orphaned resources
  - ✅ Cost reduction visible in billing

---

## Deep Dive: How Stangler Fig Works

This section explains how the Strangler Fig pattern works for both **external traffic** (users → API Gateway → services) and **internal traffic** (service-to-service calls), including the role of the Internal ALB.

### The Problem — Why Strangler Fig?

**Big Bang Migration Risks:**

- Deploy everything to Fargate at once
- Flip DNS from EC2 to Fargate
- If something breaks: rollback is complex, potential extended downtime

**Strangler Fig Approach:**

- Run EC2 and Fargate in parallel
- Gradually shift traffic: 5% → 25% → 50% → 100%
- Monitor at each stage
- Instant rollback: just change weights back

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              EXTERNAL TRAFFIC                                │
│                           (Users → Your APIs)                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│    Internet                                                                  │
│       │                                                                      │
│       ▼                                                                      │
│  ┌─────────────┐                                                            │
│  │ Public ALB  │  ← HTTPS termination, host-based routing                   │
│  │ (External)  │                                                            │
│  └──────┬──────┘                                                            │
│         │                                                                    │
│         ▼                                                                    │
│  ┌─────────────┐                                                            │
│  │  KrakenD    │  ← API Gateway (still on EC2 during migration)             │
│  │   (EC2)     │                                                            │
│  └──────┬──────┘                                                            │
│         │                                                                    │
│         │  All backend calls go through Internal ALB                         │
│         ▼                                                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                              INTERNAL TRAFFIC                                │
│                         (Service-to-Service)                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│         │                                                                    │
│         ▼                                                                    │
│  ┌──────────────────┐                                                       │
│  │   Internal ALB   │  ← Traffic Mixer (weighted routing)                   │
│  │  (Private Only)  │                                                       │
│  └────────┬─────────┘                                                       │
│           │                                                                  │
│     ┌─────┴─────┐                                                           │
│     │  Weights  │                                                           │
│     ▼           ▼                                                           │
│  ┌──────┐   ┌──────┐                                                        │
│  │ EC2  │   │ ECS  │                                                        │
│  │ 70%  │   │ 30%  │  ← Adjust weights to shift traffic                     │
│  └──┬───┘   └──┬───┘                                                        │
│     │         │                                                              │
│     └────┬────┘                                                              │
│          ▼                                                                   │
│     ┌─────────┐                                                             │
│     │   RDS   │  ← Same database, both EC2 and ECS connect                  │
│     └─────────┘                                                             │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Internal ALB — The Traffic Mixer

The Internal ALB is the key component that enables gradual migration. It sits between callers (KrakenD, other services) and backends (EC2 and ECS).

**Why not just use DNS switching?**

- DNS TTLs cause inconsistent cutover (some clients cache longer)
- No weighted routing capability
- Rollback requires waiting for TTL expiry

**Why Internal ALB works:**

- Instant traffic shifting (weight changes apply immediately)
- Same ALB serves both EC2 and ECS backends
- Callers only know one endpoint (`http://internal.yourcompany.local`)
- Health checks automatically remove unhealthy targets

### Step-by-Step Migration Flow

#### Phase A: Baseline (Before Migration)

```
KrakenD → EC2 instances directly (or via existing internal routing)
Service A → Service B (via private IPs or existing DNS)
```

**Action:** Update all internal callers to use Internal ALB

- KrakenD config: Point to `http://internal.yourcompany.local/auth-api`
- Service env vars: `AUTH_API_URL=http://internal.yourcompany.local/auth-api`

**Internal ALB State:**
| Service | EC2 Target Group | ECS Target Group |
|---------|-----------------|------------------|
| auth-api | 100% | 0% |
| user-api | 100% | 0% |

**Validation:** All traffic flows through Internal ALB to EC2. Nothing has changed functionally.

---

#### Phase B: Deploy ECS (0% Traffic)

**Action:** Deploy service to ECS Fargate

- ECS Service created, tasks running
- Health checks passing
- Added to Internal ALB target group with weight 0%

**Internal ALB State:**
| Service | EC2 Target Group | ECS Target Group |
|---------|-----------------|------------------|
| auth-api | 100% | 0% (deployed, ready) |

**Validation:**

- ECS tasks are healthy
- Can test directly: `curl http://<task-private-ip>:3000/health`
- No production traffic yet

---

#### Phase C: Canary (5-10% Traffic)

**Action:** Shift small percentage to ECS

**Internal ALB State:**
| Service | EC2 Target Group | ECS Target Group |
|---------|-----------------|------------------|
| auth-api | 95% | 5% |

**How to change weights:**

```
AWS Console → EC2 → Load Balancers → internal-services-alb
→ Listeners → View/edit rules → Edit rule
→ Forward to:
   - legacy-auth-api-tg: Weight 95
   - fargate-auth-api-tg: Weight 5
→ Save
```

**Monitoring (critical):**

- Compare error rates: EC2 target group vs ECS target group
- Compare latency: `TargetResponseTime` for both groups
- Watch CloudWatch Logs for new errors in ECS
- Monitor for 2-4 hours minimum

**Rollback trigger:**

- ECS error rate > EC2 error rate + 1%
- ECS latency > EC2 latency + 50ms
- Any critical functionality broken

**Rollback action:** Set ECS weight back to 0%

---

#### Phase D: Gradual Increase

**Action:** If canary is healthy, increase traffic

**Progression:**
| Stage | EC2 Weight | ECS Weight | Duration | Notes |
|-------|-----------|-----------|----------|-------|
| Canary | 95% | 5% | 4 hours | Initial validation |
| Early | 90% | 10% | 24 hours | Extended monitoring |
| Mid | 75% | 25% | 24 hours | Quarter traffic |
| Half | 50% | 50% | 24 hours | Equal split |
| Majority | 25% | 75% | 24 hours | ECS handling most |
| Full | 0% | 100% | Ongoing | Migration complete |

**Key insight:** At each stage, if issues occur, you can instantly revert to the previous stage by changing weights.

---

#### Phase E: Full Migration (100% ECS)

**Internal ALB State:**
| Service | EC2 Target Group | ECS Target Group |
|---------|-----------------|------------------|
| auth-api | 0% | 100% |

**Validation:**

- All traffic on ECS for 7+ days
- No error rate increase
- No latency increase
- No user complaints

---

#### Phase F: Decommission EC2

**Action:** Remove EC2 from the equation

1. **Deregister EC2 from target group**
   - Allows connection draining (300 seconds default)
2. **Stop EC2 instance (don't terminate yet)**
   - Keep for 7-14 days as safety net
   - Easy to restart if critical issue found

3. **Delete legacy target group**
   - Clean up unused resources

4. **Terminate EC2 instance**
   - After retention period passes
   - Create AMI backup first

5. **Update Internal ALB rules**
   - Remove weighted routing, simplify to single target group
   - Optional: Now you can consider Cloud Map for direct routing

### Internal Service-to-Service Calls

The same pattern applies when **Service A calls Service B**:

```
┌───────────────────────────────────────────────────────────────┐
│                     Service A (ECS Task)                       │
│                                                                │
│   Code: axios.get(process.env.USER_API_URL + '/users/123')    │
│                                                                │
│   Env: USER_API_URL=http://internal.yourcompany.local/user-api│
└───────────────────────────────┬───────────────────────────────┘
                                │
                                ▼
┌───────────────────────────────────────────────────────────────┐
│                      Internal ALB                              │
│                                                                │
│   Rule: Path /user-api/* → Forward to:                        │
│         - legacy-user-api-tg (70%)                            │
│         - fargate-user-api-tg (30%)                           │
└───────────────────────────────┬───────────────────────────────┘
                                │
                    ┌───────────┴───────────┐
                    ▼                       ▼
          ┌─────────────────┐     ┌─────────────────┐
          │  User API (EC2) │     │  User API (ECS) │
          │      70%        │     │      30%        │
          └─────────────────┘     └─────────────────┘
```

**Key points:**

- Service A doesn't know or care if User API runs on EC2 or ECS
- Traffic split is controlled at the ALB level
- Both EC2 and ECS talk to the same database
- You can migrate services independently

### Migration Sequencing with Dependencies

When services depend on each other, migrate in dependency order:

```
Example dependency chain:
  frontend → auth-api → user-api → notification-service
                                         ↓
                                   (external SMTP)
```

**Recommended order:**

1. **Leaf services first** (notification-service) — no internal dependencies
2. **Work backward** (user-api → auth-api)
3. **Frontend last** — depends on everything

**Why this order:**

- When you migrate auth-api, user-api is already stable on ECS
- Internal calls (auth-api → user-api) go through Internal ALB
- If auth-api has issues, you can isolate the problem

**Alternative: Migrate independently**

- Because Internal ALB handles routing, you can actually migrate in any order
- EC2 auth-api can call ECS user-api through Internal ALB
- ECS auth-api can call EC2 user-api through Internal ALB
- The Internal ALB abstracts the backend location

### Routing Rules on Internal ALB

**Option 1: Path-based routing (recommended)**

- Single DNS: `internal.yourcompany.local`
- Rules route by path prefix

```
Rule 1: Path = /auth-api/*    → auth-api target groups
Rule 2: Path = /user-api/*    → user-api target groups
Rule 3: Path = /notifications/* → notifications target groups
Default: Return 404
```

**Service configuration:**

```bash
AUTH_API_URL=http://internal.yourcompany.local/auth-api
USER_API_URL=http://internal.yourcompany.local/user-api
```

**Option 2: Host-based routing**

- Multiple DNS records, all pointing to same ALB
- Rules route by Host header

```
auth-api.internal.yourcompany.local → auth-api target groups
user-api.internal.yourcompany.local → user-api target groups
```

**Service configuration:**

```bash
AUTH_API_URL=http://auth-api.internal.yourcompany.local
USER_API_URL=http://user-api.internal.yourcompany.local
```

**Recommendation:** Start with path-based (simpler DNS setup), switch to host-based if you need cleaner URLs.

### Comparison — External vs Internal Strangler Fig

| Aspect             | External Traffic                  | Internal Traffic                    |
| ------------------ | --------------------------------- | ----------------------------------- |
| **Entry Point**    | Public ALB                        | Internal ALB                        |
| **Caller**         | Internet users, mobile apps       | KrakenD, other services             |
| **TLS**            | Required (HTTPS)                  | Optional (HTTP OK in VPC)           |
| **DNS**            | Public DNS (Route 53 public zone) | Private DNS (Route 53 private zone) |
| **Traffic Mixer**  | Public ALB or Route 53 weighted   | Internal ALB weighted target groups |
| **Rollback Speed** | Instant (ALB weights)             | Instant (ALB weights)               |
| **Security**       | Security group: 0.0.0.0/0 on 443  | Security group: VPC CIDR only       |

### After Full Migration — Simplification Options

Once all services are 100% on ECS, you can simplify:

**Option A: Keep Internal ALB (recommended initially)**

- Pros: Familiar, debuggable, health checks
- Cons: Extra hop, ALB cost (~$16/month)

**Option B: Switch to Cloud Map (Service Discovery)**

- Direct task-to-task communication
- Lower latency (no ALB hop)
- Requires updating service URLs to Cloud Map DNS
- Example: `http://auth-api.production.local:3000`

**Option C: ECS Service Connect**

- AWS-managed service mesh
- Automatic DNS, load balancing, observability
- Newer feature, more abstraction

**Recommendation:** Keep Internal ALB for 3-6 months post-migration. It's simpler to operate and debug. Consider Cloud Map later if you need lower latency or want to reduce costs.
