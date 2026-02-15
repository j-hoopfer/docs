# Phase 4: Security

## Overview

Implement container security best practices to minimize attack surface and protect against vulnerabilities.

**Business Value:** Reduces blast radius of security incidents and satisfies compliance requirements. Running as non-root prevents privilege escalation during container escapes. Image scanning catches vulnerabilities before production deployment.

**Prerequisites:** [Optimization](optimization.md) completed

**Next Phase:** Ready for [ECS Deployment](../../ec2-to-ecs-brownfield-migration-plan/plan/phase-3-infrastructure-setup.md)

---

## Story 1: Run as Non-Root User

**Business Value:** Limits blast radius of container escape vulnerabilities. Running as non-root (30 minutes) prevents escalated privileges if container is compromised. Required for many compliance frameworks and enterprise security policies.

- **Title:** Implement Non-Root Container Execution
- **Persona:** As a **security engineer**, I need containers to run as non-root so that container escape vulnerabilities have limited impact.

- **Requirements:**
  - Process must not run as UID 0 (root)
  - Application files have appropriate permissions
  - No privilege escalation in container
  - Application works correctly as non-root

- **Implementation Details:**

  **Complete Dockerfile Pattern:**

  ```dockerfile
  FROM node:20-slim

  # Install system dependencies as root
  RUN apt-get update && \
      apt-get install -y tini && \
      rm -rf /var/lib/apt/lists/*

  # Create non-root user
  RUN groupadd -g 1001 appgroup && \
      useradd -u 1001 -g appgroup -m -s /bin/bash appuser

  WORKDIR /app

  # Install dependencies as root (needs write to /app)
  COPY package*.json ./
  RUN npm ci --production

  # Copy application code
  COPY . .

  # Change ownership to app user
  RUN chown -R appuser:appgroup /app

  # Switch to non-root user (all subsequent commands run as appuser)
  USER appuser

  EXPOSE 3000

  ENTRYPOINT ["/usr/bin/tini", "--"]
  CMD ["node", "server.js"]
  ```

  **Verify Non-Root:**

  ```bash
  # Check user
  docker run my-app whoami
  # Output: appuser

  docker run my-app id
  # Output: uid=1001(appuser) gid=1001(appgroup)

  # Verify PID 1
  docker run -d --name test my-app
  docker exec test ps aux
  # tini should be PID 1, node should be owned by appuser
  ```

  **Common Issues:**

  **Can't bind to port 80:**

  ```
  Error: listen EACCES: permission denied 0.0.0.0:80
  ```

  **Solution:** Use non-privileged port (3000, 8080). Let ALB handle 80/443.

  **Permission denied writing files:**

  ```
  Error: EACCES: permission denied, open '/app/uploads/file.txt'
  ```

  **Solution:** Ensure directory is owned by appuser:

  ```dockerfile
  RUN mkdir -p /app/uploads && chown appuser:appgroup /app/uploads
  ```

  **ReadOnly Filesystem (Best Practice):**

  ```json
  {
    "containerDefinitions": [
      {
        "readonlyRootFilesystem": true,
        "mountPoints": [
          {
            "sourceVolume": "tmp",
            "containerPath": "/tmp",
            "readOnly": false
          }
        ]
      }
    ],
    "volumes": [
      {
        "name": "tmp",
        "host": {}
      }
    ]
  }
  ```

  **Security Scanning:**

  ```bash
  # Scan image for vulnerabilities
  docker scan my-app

  # Or use AWS ECR scanning
  aws ecr start-image-scan \
    --repository-name my-app \
    --image-id imageTag=latest

  # View results
  aws ecr describe-image-scan-findings \
    --repository-name my-app \
    --image-id imageTag=latest
  ```

- **Acceptance Criteria:**
  - ✅ Container runs as UID 1001 (non-root)
  - ✅ Application starts and functions correctly
  - ✅ No permission denied errors
  - ✅ Doesn't require `--privileged` flag
  - ✅ Security scan shows no critical vulnerabilities
  - ✅ ReadOnly filesystem configured (optional but recommended)

---

## Story 2: Implement Image Scanning

**Business Value:** Catches vulnerabilities before production deployment. Automated scanning in CI/CD prevents deploying images with known CVEs, reducing security incident risk and satisfying compliance requirements.

- **Title:** Enable Automated Vulnerability Scanning
- **Persona:** As a **security engineer**, I need automated image scanning so that vulnerabilities are caught before production deployment.

- **Requirements:**
  - Images scanned for vulnerabilities before deployment
  - Critical vulnerabilities block deployment
  - Scan results tracked and remediated
  - Scanning integrated into CI/CD

- **Implementation Details:**

  **Enable ECR Scanning:**

  ```bash
  # Enable scan on push
  aws ecr put-image-scanning-configuration \
    --repository-name my-app \
    --image-scanning-configuration scanOnPush=true

  # Create EventBridge rule for findings
  aws events put-rule \
    --name ecr-scan-findings \
    --event-pattern '{
      "source": ["aws.ecr"],
      "detail-type": ["ECR Image Scan"]
    }'

  # Send to SNS for notifications
  aws events put-targets \
    --rule ecr-scan-findings \
    --targets Id=1,Arn=arn:aws:sns:us-east-1:123456789012:security-alerts
  ```

  **CI/CD Integration (GitHub Actions):**

  ```yaml
  name: Build and Scan

  on: push

  jobs:
    build-and-scan:
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v3

        - name: Login to ECR
          run: |
            aws ecr get-login-password --region us-east-1 | \
              docker login --username AWS --password-stdin \
              ${{ secrets.ECR_REGISTRY }}

        - name: Build image
          run: docker build -t ${{ secrets.ECR_REGISTRY }}/my-app:${{ github.sha }} .

        - name: Push image
          run: docker push ${{ secrets.ECR_REGISTRY }}/my-app:${{ github.sha }}

        - name: Wait for scan
          run: sleep 30

        - name: Check scan results
          run: |
            FINDINGS=$(aws ecr describe-image-scan-findings \
              --repository-name my-app \
              --image-id imageTag=${{ github.sha }} \
              --query 'imageScanFindings.findingSeverityCounts.CRITICAL' \
              --output text)

            if [ "$FINDINGS" != "None" ] && [ "$FINDINGS" != "0" ]; then
              echo "Critical vulnerabilities found!"
              exit 1
            fi
  ```

  **Trivy Alternative (Open Source):**

  ```bash
  # Install trivy
  brew install aquasecurity/trivy/trivy

  # Scan image
  trivy image --severity HIGH,CRITICAL my-app:latest

  # Fail CI if vulnerabilities found
  trivy image --exit-code 1 --severity CRITICAL my-app:latest
  ```

  **Vulnerability Remediation Process:**
  1. **Identify:** Scan finds CVE-2024-1234 in base image
  2. **Assess:** Check CVE severity and exploitability
  3. **Remediate:**
     - Update base image version
     - Update vulnerable dependency
     - Apply security patch
  4. **Verify:** Re-scan to confirm fix
  5. **Deploy:** Push patched image

- **Acceptance Criteria:**
  - ✅ ECR scan on push enabled
  - ✅ Critical vulnerabilities block deployment
  - ✅ Security team notified of findings
  - ✅ Scan results reviewed weekly
  - ✅ Vulnerability remediation process documented
  - ✅ Base images updated regularly

---

## Story 3: Implement Secrets Management (Validation)

**Business Value:** Validates that secrets are properly externalized and never baked into images. Prevents credential leaks and satisfies compliance requirements.

- **Title:** Verify No Secrets in Container Images
- **Persona:** As a **security engineer**, I need to verify no secrets are in images so that credentials aren't leaked through image distribution.

- **Requirements:**
  - No secrets in image layers
  - No secrets in environment variables (use Secrets Manager)
  - Secrets rotation doesn't require redeployment
  - Audit trail for secret access

- **Implementation Details:**

  **Scan for Secrets:**

  ```bash
  # Use gitleaks on Dockerfile context
  gitleaks detect --source .

  # Check image layers
  docker history my-app:latest --no-trunc

  # Search image filesystem
  docker run --rm my-app:latest find / -name "*.env" 2>/dev/null
  ```

  **ECS Secrets Configuration:**

  ```json
  {
    "containerDefinitions": [
      {
        "secrets": [
          {
            "name": "DB_PASSWORD",
            "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789012:secret:prod/db/password:password::"
          },
          {
            "name": "API_KEY",
            "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789012:secret:prod/api-key:key::"
          }
        ],
        "environment": [
          { "name": "NODE_ENV", "value": "production" },
          { "name": "PORT", "value": "3000" }
        ]
      }
    ]
  }
  ```

  **IAM Permissions:**

  ```json
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": ["secretsmanager:GetSecretValue"],
        "Resource": [
          "arn:aws:secretsmanager:us-east-1:123456789012:secret:prod/*"
        ]
      }
    ]
  }
  ```

- **Acceptance Criteria:**
  - ✅ No secrets found in image layers
  - ✅ No `.env` files in image
  - ✅ Secrets injected at runtime via ECS
  - ✅ Secret rotation tested successfully
  - ✅ IAM permissions follow least privilege
  - ✅ Secret access logged in CloudTrail

---

## Story 4: Read-Only Root Filesystem

**Business Value:** Prevents attackers from establishing persistence if container is compromised. Read-only filesystem (1-2 hours to implement and test) blocks malware installation and file modifications, significantly reducing breach impact and satisfying compliance requirements.

- **Title:** Enable Read-Only Root Filesystem
- **Persona:** As a **security engineer**, I want the container's root filesystem to be read-only so that attackers cannot establish persistence or modify application code.

- **Requirements:**
  - Root filesystem mounted read-only at runtime
  - Writable tmpfs volume for `/tmp` (application temp files)
  - No write permissions to `/app` or system directories at runtime
  - Application must not write logs/state to disk (use stdout/CloudWatch)
  - Tested with `docker run --read-only --tmpfs /tmp`

- **Implementation Details:**

  **1. Identify Writable Paths:**

  Most applications only need `/tmp` writable. Common needs:
  - `/tmp` - Temporary files
  - `/var/run` - Runtime state (if needed)
  - No writes to `/app`, `/etc`, `/usr`, or other system paths

  **2. Update Dockerfile (Optional):**

  ```dockerfile
  # Document writable path requirement
  VOLUME ["/tmp"]
  ```

  **3. Run with Read-Only Filesystem:**

  ```bash
  # Build image
  docker build -t my-app:hardened .

  # Run with Read-Only Root + Writable /tmp
  docker run --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,size=64m \
    -p 3000:3000 \
    my-app:hardened
  ```

  **4. Test Application:**

  ```bash
  # 1) Test App Health
  curl http://localhost:3000/health
  # Should return: 200 OK

  # 2) Test Write Block (Should Fail)
  CID=$(docker ps -q --filter ancestor=my-app:hardened)
  docker exec "$CID" sh -c 'touch /app/malware.sh'
  # Expected: touch: /app/malware.sh: Read-only file system

  # 3) Test Valid Write (Should Succeed)
  docker exec "$CID" sh -c 'touch /tmp/valid-temp-file && ls /tmp'
  # Should show: valid-temp-file

  # 4) Verify no log files on disk
  docker exec "$CID" find /app -name "*.log" 2>/dev/null
  # Should return nothing (logs go to stdout)
  ```

  **5. ECS Task Definition:**

  ```json
  {
    "containerDefinitions": [
      {
        "name": "app",
        "readonlyRootFilesystem": true,
        "mountPoints": [
          {
            "sourceVolume": "tmp",
            "containerPath": "/tmp",
            "readOnly": false
          }
        ]
      }
    ],
    "volumes": [
      {
        "name": "tmp",
        "host": {}
      }
    ]
  }
  ```

  **Common Issues:**

  **Application writes logs to file:**

  ```
  Error: EROFS: read-only file system, open '/app/logs/app.log'
  ```

  **Solution:** Configure logging to stdout (should be done in 12-Factor prep):

  ```javascript
  // Instead of file logging
  const logger = console; // Writes to stdout

  // Or with winston
  new winston.transports.Console();
  ```

  **Application caches to disk:**

  ```
  Error: EROFS: read-only file system, mkdir '/app/cache'
  ```

  **Solution:** Use `/tmp` or external cache (Redis):

  ```javascript
  const cacheDir = process.env.CACHE_DIR || "/tmp/cache";
  ```

- **Acceptance Criteria:**
  - ✅ Container runs with `--read-only` flag
  - ✅ Application functions correctly with read-only root
  - ✅ `/tmp` is writable with tmpfs mount
  - ✅ Write attempts to `/app` or system dirs fail
  - ✅ No logs written to filesystem (all to stdout)
  - ✅ ECS task definition includes `readonlyRootFilesystem: true`
  - ✅ Load tested for 1 hour with read-only filesystem

---

## Phase Completion Checklist

All containerization work complete. Ready for ECS deployment:

- [ ] Container runs as non-root user
- [ ] Image scanning enabled and passing
- [ ] No secrets in container images
- [ ] Read-only root filesystem tested and validated
- [ ] Security best practices implemented
- [ ] Vulnerability remediation process established
- [ ] All previous phases completed:
  - [ ] 12-Factor App Preparation complete
  - [ ] Docker packaging complete
  - [ ] Container lifecycle management implemented
  - [ ] Optimization complete

**You are now ready for ECS infrastructure setup!**

Proceed to [CI/CD for Containers Plan](../../cicd-for-containers-plan/) to automate image builds, or skip directly to [ECS Infrastructure Setup](../../ec2-to-ecs-brownfield-migration-plan/plan/phase-3-infrastructure-setup.md) if CI/CD already exists.

---

## Rollback Plan

- **Permission errors:** Temporarily run as root to debug, fix permissions, revert to non-root
- **Scan failures:** Update base image, patch vulnerabilities, request exception if needed
- **Secret access issues:** Verify IAM permissions, check secret ARNs, validate network connectivity to Secrets Manager endpoint
