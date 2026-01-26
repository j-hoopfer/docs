# Epic 7: Optimization & Resilience

**Goal:** Tune the system for real-world traffic, automate elasticity, and prove disaster recovery capabilities.
**Duration:** 3–5 Days
**Prerequisites:** Epic 6 (Production Readiness) complete.

---

## Story 7.1: Load Test Baseline

As a Performance Engineer
I want to identify the breaking point of a single ECS task
So that I can configure auto-scaling policies based on real data, not guesses

### Technical Requirements

- **Tool:** k6 (scriptable, integrates with CloudWatch).
- **Target:** A **REAL** endpoint (e.g., `GET /api/users` or `POST /auth/login`). **Do not use `/health`.**
- **Metric:** Find the "knee of the curve"—where Latency spikes or CPU hits 90%.

### k6 Example Script (Real Endpoint)

```javascript
import http from "k6/http";
import { check, sleep } from "k6";

export const options = {
  stages: [
    { duration: "2m", target: 50 }, // Warm up
    { duration: "5m", target: 200 }, // Sustained Load
    { duration: "2m", target: 0 }, // Cool down
  ],
  thresholds: {
    http_req_duration: ["p(95)<500"], // Latency Goal
    http_req_failed: ["rate<0.01"], // Error Goal
  },
};

export default function () {
  // Use a real operation that touches the DB
  const res = http.get("https://api.yourdomain.com/api/public/products");
  check(res, { "status is 200": (r) => r.status === 200 });
  sleep(1);
}
```

### Acceptance Criteria

- [ ] Load test script targets a logic-heavy endpoint (not `/health`).
- [ ] Baseline documented: "1 Task handles X RPS at 70% CPU".
- [ ] Breaking point identified (Latency > 2s or Errors > 1%).

---

## Story 7.2: Configure ECS Auto-Scaling Policies

As a Platform Engineer
I want ECS to automatically scale tasks based on load
So that the system handles traffic spikes without manual intervention

### Technical Requirements

- **Policy Type:** Target Tracking Scaling.
- **Metrics:**

1. **Backend API:** Scale on **CPU Utilization** (Target: 70%).
2. **KrakenD Proxy:** Scale on **ALB Request Count** (Target: 1000 req/min). _Excellent distinction made here._

- **Limits:** Min: 2, Max: 10 (Set distinct limits for Dev vs Prod).
- **Cooldowns:** Scale Out: 60s (Fast). Scale In: 300s (Slow).

### Terraform Configuration

```hcl
resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.service_name}-cpu-autoscaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_target.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 70.0
    scale_out_cooldown = 60
    scale_in_cooldown  = 300
  }
}

```

### Acceptance Criteria

- [ ] Target Tracking policies applied via Terraform.
- [ ] Backend scales on CPU; Proxy scales on Request Count (if applicable).
- [ ] Terraform `apply` succeeds without errors.

---

## Story 7.3: Verify Scaling Behavior

As a SRE
I want to validate that auto-scaling works as expected
So that I'm confident the system will handle production traffic spikes

### Technical Requirements

- **Procedure:**

1. Ensure Service is at Min Capacity (2 tasks).
2. Run k6 script at **200%** of the baseline RPS found in Story 7.1.
3. Watch the `DesiredCount` metric in ECS.

### Acceptance Criteria

- [ ] **Scale Out:** Desired Count increases (e.g., 2 → 4) within 3 minutes.
- [ ] **Stability:** New tasks start and pass health checks.
- [ ] **Scale In:** 10 minutes after load stops, Desired Count drops back to 2.

---

## Story 7.4: Disaster Recovery (DR) Drill

As a SRE
I want to verify database restoration capabilities
So that I'm confident we can recover from catastrophic failures

### Technical Requirements

- **Source:** Latest **Automated** RDS Snapshot.
- **Target:** Restore to a **NEW** instance identifier (e.g., `db-restore-test`).
- **Verification:** Connect via Bastion/App and run `SELECT COUNT(*)` on a critical table.

### Acceptance Criteria

- [ ] Snapshot successfully restored to a new DB instance.
- [ ] App (configured with new DB endpoint) can read data.
- [ ] **Cleanup:** Restored DB instance is DELETED after the test.
- [ ] **RTO (Recovery Time Objective):** Time to restore is recorded (e.g., "Took 15 minutes").

---

## Story 7.5: Cost Optimization & Cleanup

As a FinOps Lead
I want to right-size my resources and clean up waste
So that I am not paying for unused capacity

### Technical Requirements

1. **Compute Optimizer:** Check AWS Compute Optimizer recommendations.

- _Action:_ If Fargate tasks utilize only 10% CPU, decrease `cpu` and `memory` in Task Definition.

2. **Log Retention:** Verify CloudWatch Log Groups have expiration set (e.g., 30 days).
3. **ECR Lifecycle:** Verify Lifecycle Policy is actually deleting old images.
4. **Unused Assets:** Delete unattached EBS volumes or old Snapshots (if manual).

### Acceptance Criteria

- [ ] Fargate Task CPU/Memory adjusted based on Story 7.1 data.
- [ ] CloudWatch Log Groups have `retention_in_days` set.
- [ ] ECR Lifecycle policy verified (no images older than 14 days in Dev).
- [ ] Estimated monthly cost calculated and documented.

---

## ✅ Epic 7 Definition of Done

1. **Baseline:** We know exactly how much traffic 1 task can handle.
2. **Elasticity:** The system automatically adds/removes tasks based on that baseline.
3. **Recovery:** We have proven we can restore the database from a backup.
4. **Efficiency:** Resources are right-sized to minimize waste.
