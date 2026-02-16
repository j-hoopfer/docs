# Branch Protection Rules: A Guide

**Goal:** Understand what Branch Protection Rules are, why they are critical for infrastructure stability, and how they are applied in our migration plan.

## What are Branch Protection Rules?

Branch protection rules are a feature in GitHub (and other VCS providers like GitLab/Bitbucket) that allow you to enforce specific workflows and requirements before code can be merged into a target branch (typically `main` or `production`).

They act as "Gatekeepers" for your codebase, ensuring that no change enters the production stream without meeting predefined quality and security standards.

## Why Use Them? (Business Value)

1.  **Prevent "Drift" & Breaking Changes:** By preventing direct pushes to `main`, we ensure that no one accidentally breaks the production environment with an untested change.
2.  **Enforce Code Review:** Requiring approvals ensures knowledge sharing and prevents "siloed" code that only one person understands.
3.  **Ensure Quality (CI/CD):** By requiring status checks (like `tflint` and `terraform validate`) to pass, we mechanically guarantee that the code is syntactically correct before a human even looks at it.
4.  **Security:** Prevents force-pushes that could rewrite history or delete the branch.

## Common Rule Configurations

Here are standard configurations used in high-performing DevOps teams.

### 1. Require Pull Request Before Merging

**What it does:** Disables the ability to push code directly to the branch. All changes must come via a Pull Request (PR).
**Why:**

- Forces a structured review process.
- Creates an audit trail of _why_ a change was made.
- Allows CI/CD pipelines to run on the proposed changes _before_ they affect the main codebase.

### 2. Require Approvals

**What it does:** Mandates that a certain number of people (usually 1 or 2) with write access must approve the PR.
**Why:**

- **"Four-Eyes Principle":** A second pair of eyes catches bugs that the author missed.
- **Knowledge Sharing:** Ensures more than one person understands critical infrastructure changes.

### 3. Require Status Checks to Pass

**What it does:** Blocks the merge button until external CI systems report a "Success" status.

**Important Implementation Note:**
It is a common misconception that a failing CI pipeline automatically blocks a merge. **By default, GitHub allows you to merge a Pull Request even if your CI status is "Failed" or "In Progress."** You must explicitly enable this rule to _force_ the merge mechanism to wait for a green checkmark.

**Examples in our plan:**

- `TFLint`: Checks for AWS best practices (e.g., catching invalid instance types).
- `Terraform Fmt`: Checks for code style consistency.
- `Terraform Validate`: Checks for syntax errors.
  **Why:**
- Automates the "boring" parts of code review.
- Prevents broken code from ever reaching the main branch.

### 4. Require Code Owner Reviews

**What it does:** If a file has a designated "Code Owner" (defined in a `CODEOWNERS` file), that specific person/team _must_ approve the change.
**Why:**

- Critical for security/sensitive files (e.g., IAM policies).
- Ensures that the subject matter experts for a specific domain sign off on changes to their area.

## How We Apply This (Phase 0)

In Phase 0, we are setting up:

- **Rule 1:** Block direct pushes to `main`.
- **Rule 2:** Require **1 Approval** for all changes.
- **Rule 3:** Require **Status Checks** (`TFLint`, `Terraform Fmt`, `Terraform Validate`) to pass.

This establishes a "Safety Net" from Day 1, ensuring that as we move into complex migration phases, our foundation remains stable.
