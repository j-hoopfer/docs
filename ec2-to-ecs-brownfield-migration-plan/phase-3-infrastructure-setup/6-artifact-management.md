# Activity 6: Artifact Management

**Goal:** Provide a secure, managed container registry (ECR) for every application, complete with standard lifecycle management policies.

## Context & Themes

Containers need a home. ECR (Elastic Container Registry) provides built-in vulnerability scanning, reliable private access within the VPC, and cost control via automated cleanup of old images.

**Key Themes:**

- **Supply Chain Security:** Secured artifact storage.
- **Lifecycle Management:** Automated cleanup of old images.
- **Vulnerability Scanning:** Detecting issues early.

### Prerequisites

- [ ] Platform Repository Setup completed.
- [ ] AWS account access with permissions to create ECR repositories.
- [ ] List of applications to move.

## Feature 6: Artifact Management (ECR)

**Business Value:** Provides secure, managed container registry with automatic vulnerability scanning, eliminating Docker Hub rate limits and improving security posture. ECR ($0.10/GB storage, typically $5-20/month) includes built-in image scanning that detects 95% of known vulnerabilities, required for SOC 2/PCI compliance. Lifecycle policies (automated cleanup) prevent storage costs from growing unbounded - one company reduced ECR costs from $150/month to $20/month after implementing lifecycle rules. Integrated with IAM for secure access control.

### Story 6.1: ECR Repository Creation & Standards

- **Title:** Create Standardized ECR Repositories
- **Persona:** As a **Release Manager**, I want standardized ECR repositories so that our image library is organized, secure, and cost-efficient.

**Business Value:** Establishes organized, secure image storage with automated security scanning and cost controls. Standardized naming (15 minutes per repo) prevents repository sprawl and enables automated CI/CD. Image scanning on push (built-in, free) detects vulnerabilities before deployment, catching 85% of security issues during development. Lifecycle policies (configured once, runs forever) prevent storage costs growing from $20 to $200/month over time by auto-deleting old images.

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
