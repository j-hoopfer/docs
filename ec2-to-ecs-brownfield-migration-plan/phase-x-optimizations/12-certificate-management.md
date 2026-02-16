# Certificate Renewal & Expiration Monitoring

### Goal

Prevent outages caused by expired SSL/TLS certificates by automating renewal with AWS ACM where possible and setting strict monitoring alerts for external certificates.

### Context

Certificate expiry is a common "Day 2" outage cause. In the new world, most certs should be managed by ACM on the load balancer, but any internal certs must also be tracked.

## Status

**Out of Scope** - Operational monitoring enhancement

## Why This Matters

SSL/TLS certificates expire. If your ALB certificate expires, your site goes down. While ACM auto-renews DNS-validated certificates, renewal can fail if DNS validation records are accidentally deleted.

## What's Missing

### 4.1 ACM Certificate Expiration Monitoring

**Current State:**

- ACM certificates requested and attached to ALB
- DNS validation configured in Route 53
- ACM auto-renewal enabled

**Gaps:**

- [ ] **No proactive monitoring** of certificate expiration dates
- [ ] **No alerting** if auto-renewal fails
- [ ] **No notification** when certificates are close to expiry
- [ ] **No tracking** of certificate rotation in logs

**Recommendations:**

### Certificate Monitoring Setup

**CloudWatch Alarm for Expiration:**

```bash
# ACM publishes DaysToExpiry metric
aws cloudwatch put-metric-alarm \
 --alarm-name "ACM-Certificate-Expiring-Soon" \
 --alarm-description "ACM certificate expires in <30 days" \
 --metric-name DaysToExpiry \
 --namespace AWS/CertificateManager \
 --statistic Minimum \
 --period 86400 \
 --evaluation-periods 1 \
 --threshold 30 \
 --comparison-operator LessThanThreshold \
 --alarm-actions arn:aws:sns:us-east-1:123456789012:critical-alerts
```

**Priority:** Medium  
**Estimated Effort:** 1 day  
**Owner:** Platform/SRE Team

---

### 4.2 Certificate Renewal Validation

**Gaps:**

- [ ] **No verification** that DNS validation records remain in place
- [ ] **No testing** of renewal process
- [ ] **No alerting** on renewal failures

**Recommendations:**

### Certificate Renewal Validation

**DNS Validation Record Monitoring:**

- ACM requires CNAME records for validation
- If deleted, renewal fails
- Monitor that validation records exist

**Priority:** Low-Medium  
**Estimated Effort:** 0.5 day  
**Owner:** Platform Team

---

### 4.3 External Certificate Monitoring (if applicable)

**Gaps:**

- If using external certificates (not ACM), monitoring is even more critical

**Recommendations:**

### External Certificate Monitoring

**For Non-ACM Certificates:**

- Use external monitoring service (SSL Labs, Uptime Robot, Pingdom)
- Check certificate daily
- Alert 30 days before expiration

**Priority:** High (if using external certs), N/A (if using ACM)  
**Estimated Effort:** 2-3 days  
**Owner:** Platform Team
