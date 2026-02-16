# Activity 3: Operational Excellence

**Goal:** Implement auto-scaling policies and comprehensive CloudWatch dashboards to ensure production services are resilient, cost-effective, and observable.

## Context & Themes

While the pilot service runs successfully, scaling manually during traffic spikes or outages is not sustainable. We need automated systems to adjust capacity and clear visibility into application health to maintain reliability at scale.

**Key Themes:**

- **Auto-Scaling:** Matching capacity to demand.
- **Observability:** Proactive monitoring and alerting.
- **Resilience:** Self-healing infrastructure.

### Prerequisites

- [ ] Services migrated to Fargate.
- [ ] Platform Repository Setup completed.
- [ ] Access to AWS Console/CloudWatch.

## Feature 3: Monitoring & Auto-Scaling

**Business Value:** Ensures high availability and cost efficiency by automatically adjusting resources to traffic demand and providing visibility into system health. Auto-scaling (15-20% cost savings) prevents paying for idle resources at night while handling peak traffic during the day. Comprehensive monitoring (CloudWatch Dashboards & Alarms) reduces Mean Time To Recovery (MTTR) by proactively alerting engineers to issues before customers report them, protecting revenue and brand reputation.

### Story 3.1: Configure Auto-Scaling

- **Title:** Implement Target Tracking Auto-Scaling
- **Persona:** As a **Operations Engineer**, I want services to scale automatically so that we handle traffic spikes without manual intervention.

- **Requirements:**
  - Scale based on CPU utilization
  - Minimum tasks for high availability
  - Maximum tasks for cost control
  - Scale-in protection during deployments

- **Implementation Details:**
  - **Auto-Scaling Configuration:**
    - AWS Console → ECS → Clusters → Services → Service auto scaling
    - Or via AWS CLI/Terraform
  - **Recommended Settings:**

    ```
    Minimum tasks: 2 (for high availability)
    Desired tasks: 2 (starting point)
    Maximum tasks: 10 (cost ceiling)

    Scaling Policy: Target Tracking
    Target metric: ECSServiceAverageCPUUtilization
    Target value: 70%
    Scale-out cooldown: 60 seconds
    Scale-in cooldown: 300 seconds
    Datapoints to alarm: 3 out of 3 (3-minute evaluation window)
    ```

  - **Why These Settings:**
    - Min 2: If one task dies, service stays up
    - Target 70% CPU: Room for traffic spikes before scaling
    - Scale-out 60s: React quickly to load
    - Scale-in 300s: Avoid thrashing (wait before removing capacity)
    - **3-minute evaluation (3 datapoints):** Prevents scaling on JVM garbage collection spikes
      - **Problem:** JVM GC can cause 30-second CPU spike → triggers scale-out → wastes money
      - **Solution:** Require 3 consecutive high readings (3 minutes) before scaling
      - Applies to Node.js, Python, Ruby (any runtime with GC)
  - **Alternative Metrics:**
    - `ECSServiceAverageMemoryUtilization` — For memory-bound apps
    - `ALBRequestCountPerTarget` — For request-based scaling
    - Custom CloudWatch metrics — For business-specific scaling

- **Acceptance Criteria:**
  - ✅ Auto-scaling policy configured
  - ✅ Service scales out when CPU > 70%
  - ✅ Service scales in when load decreases
  - ✅ Never goes below minimum tasks

---

### Story 4.2: Create Monitoring Dashboard

- **Title:** Build CloudWatch Dashboard for ECS Services
- **Persona:** As a **Operations Engineer**, I want a unified dashboard so that I can monitor all services at a glance.

- **Requirements:**
  - Single dashboard for all ECS services
  - Key metrics: CPU, Memory, Request count, Error rate
  - Easy to spot anomalies

- **Implementation Details:**
  - **Dashboard Widgets:**
    | Widget | Metric | Source |
    |--------|--------|--------|
    | ECS CPU | CPUUtilization | Container Insights |
    | ECS Memory | MemoryUtilization | Container Insights |
    | ALB Requests | RequestCount | ALB metrics |
    | ALB 5XX Errors | HTTPCode_Target_5XX_Count | ALB metrics |
    | ALB Response Time | TargetResponseTime | ALB metrics |
    | Healthy Tasks | HealthyHostCount | Target Group |
    | Running Tasks | RunningTaskCount | ECS metrics |
  - **CloudWatch Dashboard JSON:**
    ```json
    {
      "widgets": [
        {
          "type": "metric",
          "properties": {
            "title": "ECS CPU Utilization",
            "metrics": [
              [
                "ECS/ContainerInsights",
                "CpuUtilized",
                "ClusterName",
                "production-cluster",
                "ServiceName",
                "auth-api-service"
              ],
              ["...", "user-api-service"],
              ["...", "admin-panel-service"]
            ],
            "period": 60,
            "stat": "Average"
          }
        }
      ]
    }
    ```
- **Acceptance Criteria:**
  - ✅ Dashboard created with key metrics
  - ✅ All ECS services visible
  - ✅ Team can access dashboard

---

### Story 4.3: Configure CloudWatch Alarms

- **Title:** Set Up Alerting for Critical Issues
- **Persona:** As a **Operations Engineer**, I want automated alerts so that we're notified of issues before users report them.

- **Requirements:**
  - Alert on high error rates
  - Alert on service degradation
  - Alert on task failures
  - Notifications via Slack/PagerDuty/Email

- **Implementation Details:**
  - **Critical Alarms:**
    | Alarm | Metric | Threshold | Action |
    |-------|--------|-----------|--------|
    | High 5XX Rate | HTTPCode_Target_5XX_Count | > 10 in 5 min | Alert team |
    | No Healthy Tasks | HealthyHostCount | < 1 for 1 min | Page on-call |
    | High CPU | CPUUtilization | > 90% for 5 min | Alert team |
    | High Memory | MemoryUtilization | > 90% for 5 min | Alert team |
    | Service Deployment Failed | ECS events | Task stopped reason | Alert team |
  - **SNS Topic for Alerts:**
    ```bash
    aws sns create-topic --name ecs-alerts
    aws sns subscribe --topic-arn arn:aws:sns:us-east-1:123456789012:ecs-alerts \
      --protocol email --notification-endpoint ops-team@yourcompany.com
    ```
  - **Example Alarm (High Error Rate):**
    ```bash
    aws cloudwatch put-metric-alarm \
      --alarm-name "auth-api-high-5xx" \
      --alarm-description "High 5XX error rate on auth-api" \
      --metric-name HTTPCode_Target_5XX_Count \
      --namespace AWS/ApplicationELB \
      --statistic Sum \
      --period 300 \
      --threshold 10 \
      --comparison-operator GreaterThanThreshold \
      --evaluation-periods 1 \
      --alarm-actions arn:aws:sns:us-east-1:123456789012:ecs-alerts \
      --dimensions Name=TargetGroup,Value=targetgroup/auth-api-tg/abc123 \
                   Name=LoadBalancer,Value=app/fargate-shared-alb/xyz789
    ```

- **Acceptance Criteria:**
  - ✅ Alarms configured for all services
  - ✅ Notifications reaching team
  - ✅ No alert fatigue (thresholds tuned)

---

## Success Criteria

### Reusable Workflows

- [ ] Infrastructure repo created
- [ ] Reusable workflow template created
- [ ] App repos updated to use template
- [ ] Template versioning strategy defined

### Infrastructure as Code

- [ ] Terraform state locking configured (DynamoDB)
- [ ] Modules created for services
- [ ] Existing services imported to Terraform state

### Service Discovery

- [ ] Cloud Map namespace created
- [ ] ECS services registered with service discovery
- [ ] Application config updated to use internal DNS

### Strangler Fig Migration

- [ ] Internal ALB created
- [ ] Traffic successfully shifted via weighted target groups
- [ ] EC2 instances decommissioned after successful cutover

### Operational Excellence

- [ ] Auto-scaling configured for all services
- [ ] CloudWatch dashboard active
- [ ] Alarms configured and routing to Slack/Email
