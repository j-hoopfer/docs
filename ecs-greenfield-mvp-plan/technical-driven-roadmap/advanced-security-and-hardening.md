# Epic 8: Advanced Security & Hardening

**Goal:** Implement "Defense in Depth" via automated scanning, edge protection (WAF), and credential rotation.
**Duration:** 2–4 Days
**Prerequisites:** Epics 0–7 complete.

---

## Story 8.1: Infrastructure Scanning (IaC)

As a Security Engineer
I want Terraform code scanned for misconfigurations
So that insecure resources (like open S3 buckets) never reach production

### Technical Requirements

- **Tool:** Checkov (Industry standard, open source).
- **Pipeline:** Run before `terraform plan`.
- **Policy:** Fail build on High or Critical findings.
- **Example:** `CKV_AWS_20` (S3 bucket should be private).

### GitHub Actions Integration

```yaml
- name: Run Checkov
  uses: bridgecrewio/checkov-action@v12
  with:
    directory: terraform/
    soft_fail: false # Fail build on errors
    skip_check: CKV_AWS_23,CKV_AWS_144 # Document exceptions here
```

### Acceptance Criteria

- [ ] Checkov runs in CI/CD pipeline before Plan.
- [ ] Build fails if an S3 bucket is public or Security Group allows `0.0.0.0/0` on port 22.
- [ ] Exceptions are documented in the `skip_check` config.

---

## Story 8.2: Vulnerability Alerting (Container)

As a DevSecOps Engineer
I want to be notified immediately if a critical vulnerability is found
So that I can patch the OS without blocking daily deployments for unfixable CVEs

### Technical Requirements

- **Trigger:** ECR "Image Scan Complete" event (via EventBridge).
- **Filter:** `severity == "CRITICAL"`.
- **Action:** Send notification to `alerts-critical` SNS topic (Email/Slack).
- **Constraint:** Do not break the build pipeline.

### Terraform Configuration (EventBridge)

```hcl
resource "aws_cloudwatch_event_rule" "ecr_vuln" {
  name        = "capture-ecr-critical"
  description = "Trigger on Critical ECR findings"
  event_pattern = jsonencode({
    source      = ["aws.ecr"],
    detail-type = ["ECR Image Scan"],
    detail      = {
      "scan-status" = ["COMPLETE"],
      "finding-severity-counts" = { "CRITICAL" = [{ numeric = [">", 0] }] }
    }
  })
}

resource "aws_cloudwatch_event_target" "sns" {
  rule      = aws_cloudwatch_event_rule.ecr_vuln.name
  target_id = "SendToSNS"
  arn       = var.sns_topic_arn
}
```

### Acceptance Criteria

- [ ] ECR "Scan on Push" enabled in Terraform.
- [ ] EventBridge Rule created.
- [ ] Test: Pushing a vulnerable image (e.g., `node:14`) triggers an email alert.
- [ ] Test: The GitHub Actions build passes (does not block deployment).

---

## Story 8.3: Web Application Firewall (WAF) & Rate Limiting

As a Security Engineer
I want to block common attacks (SQLi, XSS) and bots at the edge
So that malicious traffic never reaches my application containers

### Technical Requirements

- **Resource:** `aws_wafv2_web_acl`.
- **Association:** Associate with the ALB.
- **Managed Rules (Core):**
  - `AWSManagedRulesCommonRuleSet` (OWASP Top 10).
  - `AWSManagedRulesKnownBadInputsRuleSet` (Log4j, etc.).
  - `AWSManagedRulesAmazonIpReputationList` (Block known botnets).
- **Rate Limiting Rule:**
  - Limit: 2,000 requests / 5 minutes per IP.
  - Action: Block (403 Forbidden).

### Terraform Configuration

```hcl
resource "aws_wafv2_web_acl" "main" {
  name  = "${var.project}-${var.environment}-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  # Rule 1: AWS Common Rules (SQLi, XSS)
  rule {
    name     = "AWS-Common"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWS-Common"
      sampled_requests_enabled   = true
    }
  }

  # Rule 2: Known Bad Inputs
  rule {
    name     = "AWS-KnownBadInputs"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWS-KnownBadInputs"
      sampled_requests_enabled   = true
    }
  }

  # Rule 3: IP Reputation List
  rule {
    name     = "AWS-IpReputation"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWS-IpReputation"
      sampled_requests_enabled   = true
    }
  }

  # Rule 4: Rate Limiting
  rule {
    name     = "RateLimit"
    priority = 10

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project}-${var.environment}-waf"
    sampled_requests_enabled   = true
  }
}

# Associate WAF with ALB
resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = var.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.main.arn
}
```

### Acceptance Criteria

- [ ] WAF ACL attached to ALB.
- [ ] Common Rules (SQLi/XSS) enabled.
- [ ] Rate Limit (2k/5min) enabled.
- [ ] Test: `curl -H "User-Agent: bad-bot"` returns 403.

---

## Story 8.4: Automated Secret Rotation

As a Security Compliance Officer
I want database passwords to rotate automatically
So that a leaked credential becomes useless quickly

### Technical Requirements

- **Service:** AWS Secrets Manager.
- **Rotation Lambda:** Use the AWS-provided generic RDS rotation function.
- **Schedule:** Rotate every 30 days.

### Terraform Configuration

```hcl
resource "aws_secretsmanager_secret_rotation" "db_password" {
  secret_id           = aws_secretsmanager_secret.db_password.id
  rotation_lambda_arn = aws_lambda_function.rotate_db_password.arn

  rotation_rules {
    automatically_after_days = 30
  }
}

# Note: For RDS instances created with manage_master_user_password = true,
# rotation is handled automatically by AWS. This configuration is for
# manually managed secrets or non-RDS databases.
```

### Acceptance Criteria

- [ ] Secret Rotation enabled in Secrets Manager.
- [ ] Clicking "Rotate Secret Immediately" updates the DB password and the Secret value.
- [ ] Application reconnects automatically (proven via Epic 6 connection pooling resilience).

---

## ✅ Epic 8 Definition of Done

1. **Code Security:** IaC is scanned; build fails on misconfigs.
2. **Image Security:** Critical CVEs trigger alerts (without blocking devs).
3. **Edge Security:** WAF blocks SQLi, XSS, and fast flood attacks.
4. **Credential Security:** DB passwords rotate automatically.
