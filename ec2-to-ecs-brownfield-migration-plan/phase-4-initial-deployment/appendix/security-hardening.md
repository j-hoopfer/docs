# ECS Security Hardening Checklist

## Overview

This checklist ensures your ECS Fargate deployment meets enterprise security standards.

---

## 1. Container Security

- [ ] **Non-Root User:**
  - Build images to run as non-root (e.g., `USER node`).
  - Restrict root access in Task Definition if possible.

- [ ] **Read-Only Root Filesystem:**
  - Set `readOnlyRootFilesystem: true` in Task Definition.
  - Mount `/tmp` as a volume if write access is needed.

- [ ] **Minimal Base Images:**
  - Use `alpine` or `distroless` images to reduce attack surface.
  - Remove unnecessary binaries (curl/wget/shell) if not needed.

- [ ] **Image Scan on Push:**
  - Enable ECR Image Scan on Push.
  - Check findings before deployment pipeline proceeds.

---

## 2. Infrastructure Security

- [ ] **Private Subnets Only:**
  - Deploy Fargate tasks in private subnets (no public IP).
  - Use NAT Gateway or VPC Endpoints for outbound traffic.

- [ ] **Strict Security Groups:**
  - Ensure ECS tasks ONLY accept traffic from ALB SG.
  - Ensure DB only accepts traffic from ECS SG.
  - Remove all `0.0.0.0/0` inbound rules (except public ALB 80/443).

- [ ] **CloudTrail Logging:**
  - Ensure `cloudtrail` is enabled for API calls.
  - Monitor `RunTask`, `UpdateService`, `RegisterTaskDefinition`.

- [ ] **VPC Flow Logs:**
  - Enable VPC Flow Logs to monitor traffic patterns.
  - Send logs to CloudWatch or S3 for analysis.

---

## 3. Data Protection

- [ ] **Secrets Management:**
  - DO NOT store secrets in environment variables (plaintext).
  - Use `secrets` block in Task Definition (fetches from SSM/Secrets Manager).
  - Use KMS encryption for Secrets Manager.

- [ ] **Encryption in Transit:**
  - Use HTTPS for ALB listeners (ACM Certificate).
  - Use TLS for database connections.
  - Consider App Mesh or Service Connect for strict mTLS between services.

- [ ] **Encryption at Rest:**
  - Enable ECR image encryption (KMS).
  - Enable CloudWatch Logs encryption (KMS).

---

## 4. Identity & Access Management (IAM)

- [ ] **Least Privilege Roles:**
  - **Task Execution Role:** Only permissions to pull image and get secrets.
  - **Task Role:** Only permissions needed by application logic (S3/DynamoDB).
  - Avoid `AdministratorAccess` or wildly broad `*` actions.

- [ ] **No Access Keys:**
  - Use IAM Roles for tasks and CI/CD (OIDC).
  - Rotate any unavoidable long-lived credentials regularly.

---

## 5. Runtime Security

- [ ] **Resource Limits:**
  - Set `cpu` and `memory` limits to prevent resource exhaustion attacks.
  - Use `ulimits` if necessary.

- [ ] **Monitoring:**
  - Enable Container Insights for detailed metrics.
  - Set CloudWatch Alarms for abnormal CPU/Memory usage.
