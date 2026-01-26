# Epic 5: Observability

**Goal:** Achieve "Glass Box" visibility. Know _why_ it broke, not just _that_ it broke.
**Duration:** 2–4 days
**Prerequisites:** Epic 3 (ECS) & Epic 2 (RDS) complete.

---

## Story 5.1: Structured Logging (JSON)

As a DevOps Engineer
I want application logs to be machine-readable (JSON)
So that I can query fields like `level="error"` or `user_id="123"` in CloudWatch Insights without regex

### Technical Requirements

- Single-line JSON format (no multi-line stack traces)
- Required fields: level, timestamp (ISO8601), trace_id, service, env
- Stack traces serialized into error field
- PII redaction (emails, passwords)
- AWS CloudWatch Logs driver (awslogs)
- CloudWatch Insights query support
- Logging library: Pino (Node.js) or equivalent

### Implementation Details

- **Format:** Single-line JSON. No multi-line stack traces (serialize them into the `error` field).
- **Required Fields:** `level`, `timestamp` (ISO8601), `trace_id` (X-Ray correlation), `service`, `env`.
- **Driver:** Standard `awslogs` driver (simplest for MVP).

### Code Example (Node.js/Pino)

```javascript
const logger = pino({
  level: process.env.LOG_LEVEL || "info",
  base: { service: "auth-api", env: process.env.NODE_ENV },
  formatters: {
    level: (label) => ({ level: label }), // "info" instead of 30
  },
  timestamp: pino.stdTimeFunctions.isoTime,
});
```

### Acceptance Criteria

- [ ] Logs output as single-line JSON.
- [ ] CloudWatch Insights Query works: `fields @timestamp, level, message | filter level="error"`.
- [ ] PII (emails/passwords) is redacted.

---

## Story 5.2: Distributed Tracing (X-Ray)

As a SRE
I want to see the lifecycle of a request across all services
So that I can identify if the latency is coming from the API, the Database, or the Network

### Technical Requirements

- X-Ray daemon sidecar container in ECS task definition
- Daemon listens on UDP port 2000
- Application instrumented with aws-xray-sdk
- Sampling rate: 5% fixed (cost control)
- Error strategy: 100% error visibility via logs (Story 5.1), X-Ray for latency sampling
- IAM task role permission: xray:PutTraceSegments
- Service map shows: Client → ALB → Service → RDS

### Implementation Details

1. **Sidecar:** Add `aws-xray-daemon` container to the ECS Task Definition (UDP port 2000).
2. **SDK:** Instrument the app with `aws-xray-sdk`.
3. **Sampling:**

- **Rate:** 5% fixed rate (control costs).
- **Error Strategy:** Rely on Logs (Story 5.1) for 100% error visibility. X-Ray is for _latency_ sampling.

### Acceptance Criteria

- [ ] X-Ray Daemon running as sidecar.
- [ ] IAM Task Role has `xray:PutTraceSegments`.
- [ ] Service Map in AWS Console shows: `Client -> ALB -> Service -> RDS`.

---

## Story 5.3: "Golden Signals" Dashboard (Terraform)

As a SRE
I want a single dashboard showing Latency, Traffic, Errors, and Saturation
So that I can assess system health in 5 seconds

### Technical Requirements

- Terraform aws_cloudwatch_dashboard resource
- Latency widget: TargetResponseTime (P95, P99 percentiles)
- Traffic widget: RequestCount (sum per minute)
- Errors widget: HTTPCode_Target_5XX_Count / RequestCount ratio
- Saturation widget: Max CPU and Memory utilization (ECS service)
- Default time range: Last 1 hour
- Dashboard provisioned as infrastructure as code

### Implementation Details

- **Tool:** Terraform `aws_cloudwatch_dashboard` resource.
- **Widgets:**

1. **Latency:** `TargetResponseTime` (P95, P99).
2. **Traffic:** `RequestCount` (Sum/min).
3. **Errors:** `HTTPCode_Target_5XX_Count` / `RequestCount`.
4. **Saturation:** Max CPU/Memory Utilization of the ECS Service.

### Acceptance Criteria

- [ ] Dashboard provisioned via Terraform.
- [ ] All 4 signals populated with real data.
- [ ] Time range defaults to "Last 1 Hour".

---

## Story 5.4: Configure Critical Alerts

As a On-Call Engineer
I want to be alerted only when critical issues occur
So that I can sleep at night and trust the system

### Technical Requirements

- SNS topic: alerts-critical for email/SMS notifications
- Task Death alarm: RunningTaskCount < DesiredCount for 2 minutes
- High Error Rate alarm: 5XX Error Rate > 1% for 5 minutes
- High Latency alarm: P99 Latency > 2s for 5 minutes
- Alarm actions configured to SNS topic
- Alarm descriptions contain links to runbooks
- Email/SMS delivery via SNS subscriptions

### Implementation Details

- **SNS Topic:** `alerts-critical`.
- **Alarms:**

1. **Task Death:** `RunningTaskCount < DesiredCount` (for 2 mins).
2. **High Error Rate:** `5XX Error Rate > 1%` (for 5 mins).
3. **High Latency:** `P99 Latency > 2s` (for 5 mins).

- **Action:** Send email/SMS via SNS.

### Acceptance Criteria

- [ ] Stopping a task manually triggers the "Task Death" email within 2 minutes.
- [ ] Alarm descriptions contain links to Runbooks.

---

## Story 5.5: Database Monitoring (RDS)

As a DBA / Backend Engineer
I want deep visibility into database performance and capacity
So that I don't run out of disk space or hit CPU limits unexpectedly

### Technical Requirements

- RDS Performance Insights enabled (provides load average breakdown)
- CloudWatch alarm: FreeStorageSpace < 10GB or < 10%
- CloudWatch alarm: CPU Utilization > 80% for 15 minutes
- CloudWatch alarm: Freeable Memory < 256MB (critical for t4g.micro)
- Alarms send notifications to SNS alerts-critical topic
- Performance Insights retention: 7 days (free tier)
- Terraform-managed alarm resources

### Implementation Details

1. **Performance Insights:** Enable in RDS (via Terraform in Epic 2). This provides the "Load Average" breakdown (CPU vs. IO vs. Locks).
2. **CloudWatch Alarms:**

- **Free Storage Space:** Alert if `< 10%` (or fixed 10GB).
- **CPU Utilization:** Alert if `> 80%` for 15 minutes.
- **Freeable Memory:** Alert if `< 256MB` (Critical for `t4g.micro`).

### Terraform Resource Example

```hcl
resource "aws_cloudwatch_metric_alarm" "db_storage_low" {
  alarm_name          = "${var.project}-db-storage-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 10000000000 # 10 GB

  dimensions = { DBInstanceIdentifier = var.db_instance_id }
  alarm_actions = [aws_sns_topic.alerts_critical.arn]
}

```

### Acceptance Criteria

- [ ] Performance Insights enabled on RDS instance.
- [ ] Alarms created for Storage (<10GB) and CPU (>80%).
- [ ] Test: Simulate high CPU (stress test) or verify metric data flows to CloudWatch.

---

## ✅ Epic 5 Definition of Done

1. **Logs:** App logs are structured JSON and searchable.
2. **Traces:** X-Ray Service Map is generated automatically.
3. **Dashboard:** Terraform-managed dashboard shows Golden Signals.
4. **Alerts:** "Task Death", "High Errors", and "Low DB Storage" trigger SNS emails.
