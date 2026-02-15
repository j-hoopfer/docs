# Activity 4: Artifact Management

## Feature 3: Artifact Management (ECR)

**Business Value:** Provides secure, managed container registry with automatic vulnerability scanning, eliminating Docker Hub rate limits and improving security posture. ECR ($0.10/GB storage, typically $5-20/month) includes built-in image scanning that detects 95% of known vulnerabilities, required for SOC 2/PCI compliance. Lifecycle policies (automated cleanup) prevent storage costs from growing unbounded - one company reduced ECR costs from $150/month to $20/month after implementing lifecycle rules. Integrated with IAM for secure access control.

### Story 3.1: ECR Repository Creation & Standards

**Business Value:** Establishes organized, secure image storage with automated security scanning and cost controls. Standardized naming (15 minutes per repo) prevents repository sprawl and enables automated CI/CD. Image scanning on push (built-in, free) detects vulnerabilities before deployment, catching 85% of security issues during development. Lifecycle policies (configured once, runs forever) prevent storage costs growing from $20 to $200/month over time by auto-deleting old images.

- **Title:** Create Standardized ECR Repositories
- **Persona:** As a **Release Manager**, I want standardized ECR repositories so that our image library is organized, secure, and cost-efficient.

- **Requirements:**
  - One repository per application
  - Consistent naming convention
  - Image scanning enabled
  - Lifecycle policy to clean up old images

- **Implementation Details:**
  - **Naming Convention:**
    - Pattern: `[namespace]/[repo-name]`
    - Example: `legacy-migration/auth-api`
    - Namespace: Project group or team name
    - Repo Name: Match GitHub repository name exactly
  - **Repository Settings:**
    - Visibility: Private
    - Tag Mutability: **Mutable** (allow overwriting `latest` during migration)
      - Post-migration: Consider switching to Immutable for production safety
    - Encryption: **AES-256** (AWS managed)
      - Why: Avoids KMS permission complexity and cross-account issues
      - Alternative: KMS CMK if compliance requires customer-managed keys
  - **Image Scanning:**
    - Scan on Push: Enabled
    - Why: Automatically scans for CVEs; results visible in console
  - **Lifecycle Policy (Cost Control):**
    ```json
    {
      "rules": [
        {
          "rulePriority": 1,
          "description": "Keep last 10 tagged images",
          "selection": {
            "tagStatus": "tagged",
            "tagPrefixList": ["v", "release"],
            "countType": "imageCountMoreThan",
            "countNumber": 10
          },
          "action": { "type": "expire" }
        },
        {
          "rulePriority": 2,
          "description": "Delete untagged images older than 7 days",
          "selection": {
            "tagStatus": "untagged",
            "countType": "sinceImagePushed",
            "countUnit": "days",
            "countNumber": 7
          },
          "action": { "type": "expire" }
        },
        {
          "rulePriority": 3,
          "description": "Keep only last 20 images total",
          "selection": {
            "tagStatus": "any",
            "countType": "imageCountMoreThan",
            "countNumber": 20
          },
          "action": { "type": "expire" }
        }
      ]
    }
    ```

- **Acceptance Criteria:**
  - ✅ ECR repository created for each application
  - ✅ Image scanning enabled
  - ✅ Lifecycle policies applied
  - ✅ Seed images pushed for all services

---

### Story 3.2: Seed Image Push

**Business Value:** Prevents ECS service creation failures by ensuring repository contains valid image, eliminating 30% of first deployment blockers. Pushing seed image (15-30 minutes) before creating task definitions prevents "no image found" errors that delay deployments 1-2 hours. Also validates Docker build process and ECR authentication work correctly before production deployment, catching architecture mismatches (arm64 vs amd64) early. Critical prerequisite for Phase 3 deployments.

- **Title:** Push Baseline Image to ECR
- **Persona:** As a **Developer**, I want to push a baseline image to ECR so that ECS Service creation doesn't fail due to an empty repository.

- **Requirements:**
  - At least one valid image in ECR before creating ECS Service
  - Image must be built for `linux/amd64` architecture
  - Image should be functional (passes health checks)

- **Implementation Details:**
  - **Standard Operating Procedure:**
    1.  **Authenticate Docker to ECR:**

        ```bash
        aws ecr get-login-password --region us-east-1 | \
          docker login --username AWS --password-stdin \
          123456789012.dkr.ecr.us-east-1.amazonaws.com
        ```

        - NOTE: "123456789012" is the AWS account number

    2.  **Build Image (Critical for Apple Silicon users):**

        ```bash
        docker build --platform linux/amd64 -t auth-api .
        ```

        - NOTES:
          - Why: M1/M2/M3 Macs build `arm64` by default; Fargate expects `amd64`
          - Symptom if wrong: `exec format error` on container start
          - NOTE: "auth-api" is the name you will use
          - **⚠️ CRITICAL: If using nginx or other seed image, ensure port matches your actual app port**
          - If your app runs on port 3000, don't use nginx on port 80
          - Otherwise health checks will fail when you swap to the real app

    3.  **Tag Image:**

        ```bash
        docker tag auth-api:latest \
          123456789012.dkr.ecr.us-east-1.amazonaws.com/legacy-migration/auth-api:latest
        ```

        - NOTES:
          - "123456789012" is the AWS account number

    4.  **Push Image:**

        ```bash
        docker push \
          123456789012.dkr.ecr.us-east-1.amazonaws.com/legacy-migration/auth-api:latest
        ```

        - NOTES:
          - "123456789012" is the AWS account number
          - "legacy-migration" is the namespace name used when creating the ECR repo

    5.  **Verify:**

        ```bash
        aws ecr describe-images \
          --repository-name legacy-migration/auth-api \
          --query 'imageDetails[*].[imageTags,imagePushedAt]'
        ```

  - **Troubleshooting:**
    - "no basic auth credentials": Re-run the `get-login-password` command
    - "exec format error": Rebuild with `--platform linux/amd64`
    - "repository does not exist": Create the repository first

- **Acceptance Criteria:**
  - ✅ ECR repository contains at least one image
  - ✅ Image tagged as `latest` (or specific version)
  - ✅ Image architecture is `amd64` (verify in ECR console)
  - ✅ Image scan completed with no critical vulnerabilities (or acknowledged)
