# Documentation Update Plan: Multi-Account Architecture Alignment

**Goal:** comprehensive update of all migration documentation to reflect the decided Multi-Account AWS Organization strategy and Layered Terraform State approach.

## 1. Core Architecture Changes

The documentation currently assumes a single-account "Environment" structure (`environments/dev/us-east-1`). We are moving to a **Multi-Account** structure:

- **Management Account:** Identity Center, Organizations (Root).
- **Network (Platform) Account:** Shared VPC, Transit Gateways, VPN (`environments/network/...`).
- **Workload Accounts (Dev/Prod):** ECS Clusters, ALB, Target Groups (`environments/dev/...`, `environments/prod/...`).

**Key Pattern:** Layered State

- `00-network`: Lives in Network Account (or shared if single-vpc pattern).
- `01-compute`: Lives in Workload Account.

---

## 2. Phase-by-Phase Update Checklist

### Phase 0: Prerequisites

#### [x] `1-platform-repository-setup.md` (Platform Repo)

- **Status:** **Updated**
- **Changes Made:**
  - Updated directory structure to `environments/<account>/<region>/<layer>`.
  - Added `network` account folder.
  - Updated `backend.tf` instructions to be per-layer.

#### [ ] `2-services-repository-setup.md` (Services Repo)

- **Status:** Needs Update
- **Required Changes:**
  - Update directory structure examples to match the multi-account pattern if necessary (services likely stay in workload accounts, but ensuring consistency in naming `dev` vs `network` is key).
  - Verify `backend.tf` instructions enforce the layered/service-isolated state pattern.

### Phase 1: Discovery

#### [ ] `1-application-audit.md`

- **Status:** Needs Review
- **Required Changes:**
  - Add section on identifying which _Account_ the application currently resides in vs where it will go.

#### [ ] `2-infrastructure-audit.md`

- **Status:** Needs Update
- **Required Changes:**
  - Explicitly ask to identify "Shared Resources" (VPC, NAT, IGW) vs "Workload Resources" (EC2, ALB, RDS).
  - These will now live in different Terraform states/layers.

### Phase 3: Infrastructure Setup (The Big One)

#### [ ] `1-import-existing-infrastructure.md`

- **Status:** **CRITICAL UPDATE NEEDED**
- **Required Changes:**
  - **Paths:** Change `cd environments/dev` to `cd environments/network/us-east-1/00-network`.
  - **Scope:** Clarify that this file ONLY imports VPC/Subnets/IGW/NAT.
  - **Context:** Remove references to "Single state per environment". Replace with "Layered State" explanation.

#### [ ] `2-import-application-resources.md`

- **Status:** Needs Update
- **Required Changes:**
  - **Paths:** Change directory references to `environments/dev/us-east-1/10-application` (or `01-compute`).
  - **Data Sources:** Explain how to read Remote State from the `00-network` layer (since they are now separate state files).
  - _Example:_ `data "terraform_remote_state" "network" { ... }`

#### [ ] `3-setup-shared-infrastructure.md`

- **Status:** Needs Update
- **Required Changes:**
  - **Split Responsibility:**
    - VPC/NAT/IGW -> `00-network` (Network Account).
    - ALB/Security Groups -> `01-compute` (Workload Account) or potentially `00-network` depending on the "Shared ALB" decision.
  - **Security Groups:** Explain proper referencing across layers.

#### [ ] `4-security-infrastructure.md` (IAM/Security)

- **Status:** Needs Update
- **Required Changes:**
  - Update IAM Role assumptions. Cross-account access might be needed if pipelines deploy to multiple accounts.

### Phase 4: Deployment

#### [ ] `1-deployment-artifacts.md` (ECR)

- **Status:** Needs Update
- **Required Changes:**
  - Clarify where ECR lives. Is there a shared `artifacts` account, or does it live in `dev`/`prod`?
  - If shared, update login/push instructions for cross-account ECR access.

#### [ ] `5-cicd-pipeline.md`

- **Status:** Needs Update
- **Required Changes:**
  - Pipelines now need to assume roles in specific Target Accounts (`dev` vs `prod`).
  - Update `aws-actions/configure-aws-credentials` examples to show role assumption.

---

## 3. Appendix & Examples

#### [ ] `appendix/backend-tf-best-practices.md`

- **Status:** Needs Update
- **Required Changes:**
  - Rewrite to champion **Layered State** over "Single State per Env".
  - Add diagram/explanation of `00-network` vs `01-compute`.

#### [ ] `appendix/naming-conventions.md` (if exists)

- **Status:** Create/Update
- **Required Changes:**
  - Define account naming (`scale-network`, `scale-dev`, `scale-prod`).
  - Define layer numbering standard (`00`, `10`, `20` etc).

## 4. Execution Order

1.  **Phase 3 Refactor:** This is the blocking item for the current work. Update `1-import-existing-infrastructure.md` and `3-setup-shared-infrastructure.md` first.
2.  **Phase 0-1 Align:** Ensure discovery/setup docs don't confuse users with old paths.
3.  **Phase 4 & CI/CD:** Update last as they depend on the structural decisions.
