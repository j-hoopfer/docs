# Activity 6: Validation & Cutover

## Feature 7: Validation Strategy

**Business Value:** Ensures production readiness before exposing application to customers, minimizing deployment failure risk. Validation strategy (comprehensive testing plan) confirms functional parity with legacy system. Cutover procedure (step-by-step checklist) manages the critical transition from EC2 to Fargate with minimal downtime or user impact. Strangler Fig routing technique allows gradual migration (endpoint by endpoint), ensuring safe rollback if issues arise.

### Story 7.1: Functional Testing

**Business Value:** Confirms the Fargate-hosted application behaves identically to the EC2 version. Functional verification (30-60 minutes) catches potential configuration or containerization issues before traffic switch. Testing key workflows (Auth, API calls, Database access) builds confidence in the new infrastructure. Critical gate before modifying live DNS or load balancer rules.

- **Title:** Verify Application Health
- **Persona:** As a **QA Engineer**, I need to ensure the new Fargate deployment works exactly like the existing EC2 deployment before switching traffic.

- **Requirements:**
  - Health endpoint returns 200 OK
  - Application logs show clean startup
  - Connects successfully to database/dependencies
  - Key user flows work (Login, CRUD)

- **Implementation Details:**
  1. **Direct ALB Access:**
     - Curl the ALB DNS name directly
     - `curl -v http://<ALB-DNS>/health`
  2. **Test Subdomain:**
     - Create temporary DNS `test.mysite.com` -> ALB
     - Run Postman collection against test domain
  3. **Log Verification:**
     - CloudWatch Logs: Check for errors/exceptions
     - Verify database connection success messages
  4. **Performance Sanity:**
     - Check response latency isn't significantly higher
     - Monitor CPU/Memory metrics during load

- **Acceptance Criteria:**
  - ✅ `/health` returns 200
  - ✅ No critical errors in logs
  - ✅ Database connectivity confirmed
  - ✅ Authentication flow works
  - ✅ Latency within acceptable range

---

### Story 7.2: Cutover Execution

**Business Value:** Executes the final switch to the new infrastructure with minimal risk. Controlled cutover process (1-2 hours) shifts traffic from legacy EC2 to Fargate containers. Weighted routing or DNS switchover strategies provide immediate rollback capability. Post-cutover monitoring period (24-48 hours) ensures stability under real production load. marks the successful completion of the migration phase.

- **Title:** Switch Production Traffic
- **Persona:** As a **Release Manager**, I want a controlled document process to switch traffic to Fargate so that we can rollback quickly if needed.

- **Requirements:**
  - Low TTL on DNS records (5 mins) prior to switch
  - Deployment team on standby
  - Rollback plan documented and tested

- **Implementation Details (Strangler Fig / Weighted):**
  1. **Preparation:**
     - Lower DNS TTL to 60s or 300s (24 hours in advance)
     - Ensure EC2 capacity is stable
  2. **Option A: Internal/Beta Switch:**
     - Only route specific internal IPs/headers to Fargate
     - Verify with internal users
  3. **Option B: Percentage Shift (Weighted Target Groups):**
     - Modify ALB Listener Rule
     - Send 5% traffic to Fargate Target Group
     - 95% to EC2 Target Group (if registered to ALB)
     - _Note: Harder if EC2 is on Classic ELB/different ALB_
  4. **Option C: DNS Swap (Big Bang):**
     - Update Route 53 Alias to point to new ALB
     - Watch traffic metrics on new ALB
     - Watch error rates
  5. **Monitoring (Post-Switch):**
     - Dashboard with: 5xx errors, Latency, CPU/Memory
     - Compare with EC2 metrics baseline

- **Acceptance Criteria:**
  - ✅ Traffic flowing to Fargate tasks
  - ✅ Error rate < 1% (or baseline)
  - ✅ Latency comparable to EC2
  - ✅ Old EC2 instances receiving 0 traffic (after propagation)
  - ✅ Rollback procedure confirmed available

---

## Success Criteria

1. **Infrastructure:**
   - [ ] VPC/Subnets configured correctly
   - [ ] Security Groups enforce least privilege
   - [ ] ALB and Target Groups created and healthy

2. **Application:**
   - [ ] Docker image built and in ECR
   - [ ] Task Definition configured with correct resources
   - [ ] ECS Service running desired count of tasks (2+)

3. **Pipeline:**
   - [ ] GitHub Actions workflow succeeds
   - [ ] OIDC Role configured securely
   - [ ] Deployment triggers on push to main

4. **Production Readiness:**
   - [ ] DNS points to ALB
   - [ ] HTTPS listener operational
   - [ ] CloudWatch Logs collecting application output
   - [ ] Auto-scaling policies configured (optional for initial, but recommended)
