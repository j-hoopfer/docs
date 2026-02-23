# Phase 0: Prerequisites

## Context & Themes

Before any migration work begins, the team must have the correct tooling, repository structure, and Terraform state infrastructure in place. This phase is short (1-2 days) but **blocking** — nothing in Phase 1 or beyond can proceed without it.

**Key Themes:**

- **IaC Foundation:** Repositories and Terraform backends must exist before writing any `.tf` files.
- **Blast Radius Reduction:** Separate repositories for Platform and Services prevent application deployments from touching core networking.
- **Bootstrap First:** The Terraform State Bootstrap (S3 + DynamoDB) is a prerequisite for all Terraform layers.

## Prerequisites

- [ ] AWS account(s) exist with appropriate access (Management, Platform/Network, Workload).
- [ ] AWS CLI configured with credentials.
- [ ] Terraform installed locally (version pinned in `.terraform-version` or `required_version`).
- [ ] GitHub (or equivalent) organization access to create repositories.
- [ ] **[Terraform State Bootstrap Plan](../../terraform-state-bootstrap-plan/README.md) completed** — This creates the S3 bucket and DynamoDB table used by all Terraform layers. Complete at least Phases 0-3 of the Bootstrap Plan before proceeding.

---

## Activities

### [Activity 1: Platform Repository Setup](1-platform-repository-setup.md)

- **Goal:** Create and initialize the `infra-platform` repository.
- **Result:** A layered directory structure (`environments/<account>/<region>/<layer>`) with `backend.tf` files pre-configured, ready to receive infrastructure code in Phase 3.

### [Activity 2: Services Repository Setup](2-services-repository-setup.md)

- **Goal:** Create and initialize the `infra-services` repository.
- **Result:** A parallel structure for application-level resources (ECS Services, Target Groups, ALB rules), isolating deployment concerns from platform networking.

---

## Success Criteria

- [ ] `infra-platform` repository created with correct directory structure.
- [ ] `infra-services` repository created with correct directory structure.
- [ ] Terraform state backend (S3 + DynamoDB) configured for each layer (`backend.tf` populated).
- [ ] `terraform init` succeeds in all layer directories.
- [ ] Team members have read/write access to both repositories.

---

**Next Step:** Proceed to [Phase 1: Discovery](../phase-1-discovery/README.md).
