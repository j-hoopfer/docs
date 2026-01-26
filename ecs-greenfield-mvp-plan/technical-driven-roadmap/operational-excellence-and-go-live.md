# Epic 10: Operational Excellence & Go-Live

**Goal:** Transform the system from "Technically Ready" to "Operationally Supported."
**Duration:** 2–3 Days
**Prerequisites:** All previous Epics.
**Estimated Story Points:** 21–34 (depending on automation complexity)

---

## Story 10.1: Incident Runbooks (The "3 AM" Docs)

As a On-Call Engineer
I want step-by-step guides for critical alerts
So that I can resolve outages quickly without guessing

### Technical Requirements

- Markdown-based Wiki (GitHub /docs or Notion)
- Links from CloudWatch Alarms to specific runbooks
- Runbook template: Alert name, severity, plain English description, investigation steps, common root causes, resolution procedures, escalation path
- Required runbooks: High Error Rate (5xx), High Latency, Task Crash Loop, Database Failover, Auth/Third-Party Service Degradation
- Escalation matrix defined for each severity level

**Acceptance Criteria:**

- [ ] Runbooks created for all "Critical" alerts defined in Epic 5.
- [ ] CloudWatch Alarm descriptions updated with links to specific Runbooks.
- [ ] Escalation matrix defined (who to page at each severity level).
- [ ] "Fire Drill": A developer uses the Runbook to debug a staged issue without asking for help.
- [ ] All runbooks peer-reviewed and approved by Tech Lead.

---

## Story 10.2: Service Level Objectives (SLOs)

As a Product Owner
I want to define acceptable reliability targets
So that we know when to freeze features and focus on stability

### Technical Requirements

- SLIs defined: Availability (Successful Requests / Total Requests), Latency (Requests < 500ms / Total Requests), Error Budget
- SLOs defined: Availability 99.9% (Monthly Error Budget: ~43 minutes), Latency 95% of requests < 500ms
- CloudWatch Dashboard widget tracking Error Budget Remaining (hourly updates)
- 30-day rolling availability %, latency percentiles (p50, p95, p99)
- Alert when error budget drops below 10%
- SLO targets agreed upon by Engineering/Product/Stakeholders

**Acceptance Criteria:**

- [ ] SLOs defined and agreed upon by Engineering/Product/Stakeholders.
- [ ] CloudWatch Dashboard shows "Availability %" and "Error Budget" over the last 30 days.
- [ ] Alerting configured for SLO breaches.
- [ ] SLO targets documented in team wiki/README.

---

## Story 10.3: Public Status Page

As a Customer Support Lead
I want a public status page
So that users know if the system is down without flooding support tickets

### Technical Requirements

- Tool: Atlassian Statuspage (Free tier) or static S3 site
- Components: API, Dashboard, Database, Third-Party (Stripe/Auth0)
- Display: Current status (Operational, Degraded, Incident), Scheduled maintenance, Incident history (90 days)
- Optional automation: CloudWatch Alarms to Status Page via SNS + Lambda
- Subscription notifications (email/SMS)
- DNS CNAME configured (e.g., status.myapp.com)

**Acceptance Criteria:**

- [ ] Status page live (e.g., `status.myapp.com`).
- [ ] DNS CNAME configured.
- [ ] Support team has documented access procedures and update guidelines.
- [ ] Status page accessible to all support and leadership staff.
- [ ] Test post to status page verified.

---

## Story 10.4: Pre-Production Validation & Load Testing

As a QA Lead
I want to validate production readiness before go-live
So that we catch performance regressions and configuration issues early

### Technical Requirements

- Synthetic monitoring tests against staging: Critical user workflows (login → action → logout), Third-party integrations (Auth0, Stripe), Database failover simulation (optional)
- Load test (k6, JMeter, or Locust): Ramp to 2x expected peak over 10 minutes, Hold at peak for 15 minutes
- Verify autoscaling policies trigger correctly
- Verify no memory leaks, connection pool exhaustion
- Capture baseline metrics: CPU, Memory, DB connections, Lambda duration
- Dependencies: Epics 1-9 complete

**Acceptance Criteria:**

- [ ] Synthetic test suite passes 5 consecutive times.
- [ ] Load test completes without errors.
- [ ] All services scale correctly under load.
- [ ] Results reviewed and approved by Tech Lead.

---

## Story 10.5: The "Production Readiness Review" (PRR)

As a Tech Lead
I want a final "Go/No-Go" audit
So that we don't launch with obvious gaps

### Technical Requirements

- Security checklist: WAF in BLOCK mode, DB password rotated, S3 buckets private, SSL/TLS certificates valid
- Scale checklist: Autoscaling policies active, Quotas checked (Max vCPUs in region), Concurrency limits configured
- Data checklist: Backup retention 30 days, Deletion Protection ON, Data encryption at rest enabled
- Ops checklist: PagerDuty schedule configured, Runbooks accessible and tested, On-call escalation tested
- Legal checklist: Privacy Policy/Terms linked, Cookie banner active, GDPR/compliance checklist completed
- Monitoring checklist: All dashboards created, Alerts configured and tested, Logs retained 30+ days
- Documentation checklist: Runbooks, SLOs, architecture diagrams, deployment procedures finalized
- Dependencies: Stories 10.1-10.4 complete

**Acceptance Criteria:**

- [ ] All PRR items checked off (sign-off by Tech Lead, Security Lead, Product Owner).
- [ ] **"Go Live" Decision:** Stakeholders and executives sign off on launch.
- [ ] Risk register reviewed; mitigations in place for known issues.

---

## Story 10.6: Post-Launch Retrospective & Stabilization

As a Engineering Manager
I want to capture lessons learned
So that we continuously improve operational practices

### Technical Requirements

- Timing: 48-72 hours post-launch
- Team retrospective: What went well, What could be improved, Action items for next sprint
- 72-hour monitoring: Check error rates, latency, resource utilization hourly
- Document incidents with timestamps (even minor ones)
- Validate runbooks effectiveness for any alerts that fire
- Post-launch report: Peak concurrent users, Unexpected scaling behavior, Customer feedback, Recommended follow-up work
- Backlog updated with follow-up work

**Acceptance Criteria:**

- [ ] Retrospective meeting held and notes captured.
- [ ] 72-hour stability metrics confirmed (no critical incidents, error budget intact).
- [ ] Post-launch report delivered to leadership.
- [ ] Backlog updated with follow-up work for next phase.

---

## Dependencies & Sequencing

```
Epic 10.1 (Runbooks) ────→ Epic 10.4 (Validation) ────→ Epic 10.5 (PRR) ────→ **GO LIVE**
Epic 10.2 (SLOs) ─────────↗                              ↓
Epic 10.3 (Status Page) ──↗                        Epic 10.6 (Retrospective)
```

**Recommended Execution:**

- **Days 1–2:** Complete Stories 10.1, 10.2, 10.3 in parallel.
- **End of Day 2:** Begin Story 10.4 (Pre-Production Validation).
- **Day 3:** Finalize Story 10.5 (PRR) and stakeholder sign-off.
- **Go-Live:** Deploy to production.
- **Days 4–6:** Execute Story 10.6 (Post-Launch Retrospective).

---

## Stakeholder Communication Cadence

- **Pre-Launch (Daily):** Engineering Daily Standup.
- **Pre-Launch (EOD):** Status update to Product/Leadership (pass/fail on PRR items).
- **Launch Day (Hourly):** War room check-in (first 8 hours).
- **Post-Launch (Daily):** Incident report + metrics review (first 72 hours).

---

## Phase 3 Completion Criteria

**Phase 3 is "COMPLETE" when:**

✅ All Epics 1–10 stories are "Done" (Definition of Done met).
✅ PRR checklist is 100% checked off.
✅ Stakeholders have signed off on go-live.
✅ System is in production and handling real traffic.
✅ On-call team is staffed and trained on runbooks.
✅ First incident is resolved successfully using runbooks.

---

## Appendix: Runbook Template

```markdown
# Runbook: [Alert Name]

**Severity:** [Critical | High | Medium]
**Last Updated:** [Date]

## What Does This Alert Mean?

[Plain English description. Why might it fire? What's the user impact?]

## Immediate Triage (First 2 minutes)

1. Check the CloudWatch Dashboard: [link to dashboard].
2. Check the service logs: [link to log group].
3. Check external dependencies: [Auth0 status, Stripe status, etc.].

## Common Root Causes

- [ ] Root Cause #1
- [ ] Root Cause #2
- [ ] Root Cause #3

## Resolution Steps

### If Root Cause #1:

1. Step 1...
2. Step 2...
3. Verify by [checking metric/log].

### If Root Cause #2:

...

## Rollback (if deployment was recent)

`aws ecs update-service --cluster prod --service my-service --force-new-deployment`

## Escalation

- **First 10 minutes:** Handle autonomously per steps above.
- **After 15 minutes unresolved:** Page on-call lead: [Slack channel/phone].
- **After 30 minutes unresolved:** Notify VP Engineering + Customer Support Lead.

## Related Links

- [Architecture Diagram](link)
- [Deployment Procedure](link)
- [Historical Incidents](link)
```
