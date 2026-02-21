# Terraform Workflow: Local Execution & GitHub Synchronization

Since we are currently not using GitHub Actions to apply Terraform changes automatically, all infrastructure changes must be applied **locally** from your workstation. This document outlines the lifecycle for making changes, applying them to AWS, and saving your work to GitHub.

## 1. Prerequisites

Before starting, ensure you have:

- AWS CLI installed and configured.
- Terraform installed (use `tfenv` or checks `terraform --version`).
- Git installed.
- Active AWS credentials (SSO login).

```bash
# Example login command
aws sso login --profile my-profile
export AWS_PROFILE=my-profile
```

## 2. The Local Lifecycle (Standard Workflow)

This is the cycle you will repeat for every infrastructure change.

### Step 1: Navigate to the correct directory

Terraform state is isolated by environment and layer. You must run commands from the directory corresponding to the resources you want to change.

```bash
# Example: Modifying the network layer in Dev US-East-1
cd environments/dev/us-east-1/00-network
```

### Step 2: Update Code

Edit your `.tf` files (e.g., `main.tf`, `variables.tf`) using your editor.

### Step 3: Initialization

If you added new modules or providers, or if this is your first time in this directory, initialize Terraform.

```bash
terraform init
```

### Step 4: Format & Validate (Optional but Recommended)

Keep your code clean and check for syntax errors before planning.

```bash
terraform fmt    # Automatically formats code to standard style
terraform validate # Checks for syntax validity
```

### Step 5: Plan

Generate a plan to see what Terraform _intends_ to do. **Always review this output carefully.**

```bash
terraform plan -out=tfplan
```

- **Green (+)**: Resources to be created.
- **Yellow (~)**: Resources to be modified in place.
- **Red (-)**: Resources to be destroyed.

### Step 6: Apply

Apply the changes to real AWS infrastructure using the plan you just generated. This step locks the state file in S3/DynamoDB so no one else can write to it simultaneously.

```bash
terraform apply "tfplan"
```

- Wait for the "Apply complete!" message.
- If errors occur, fix the code and repeat from Step 5.

## 3. The Git Lifecycle (Save & Share)

Once your infrastructure changes are successfully applied and verified, you must commit the code changes to GitHub. This ensures the code in the repository matches the real infrastructure.

### Step 1: Check Status

See which files have changed.

```bash
git status
```

- **Note**: You should **NEVER** see `.tfstate`, `.tfstate.backup`, or `tfplan` files in this list. They should be ignored by `.gitignore`.

### Step 2: Stage Changes

Add the modified Terraform files.

```bash
git add .
# OR specific files
git add main.tf variables.tf
```

### Step 3: Commit

Write a clear message explaining _what_ changed and _why_.

```bash
git commit -m "feat: added private subnets to dev vpc for fargate cluster"
```

### Step 4: Push to GitHub

Upload your changes to the remote repository.

```bash
git push origin <your-branch-name>
```

## 4. Pulling Changes from GitHub (Syncing)

If you need to apply changes that were pushed to GitHub by another team member (or from another machine), follow this workflow to sync your local environment.

### Step 1: Pull Latest Code

Download the latest changes from the remote repository.

```bash
git pull origin <branch-name>
```

### Step 2: Re-Initialize

Dependencies might have changed (e.g., new providers or modules updates).

```bash
terraform init
```

### Step 3: Verify State

Run a plan to ensure your local Terraform sees the infrastructure correctly.

```bash
terraform plan
```

- **Ideal Result**: "No changes. Your infrastructure matches the configuration."
  - This means the previous author applied their changes successfully.
- **If Changes are Detected**:
  - This means code was committed but **not** applied to AWS yet.
  - Review the plan and run `terraform apply` if intended.

## 5. Future Workflow: CICD Automation (Target State)

Once we enable GitHub Actions for Terraform, the workflow will shift significantly. **You will no longer run `terraform apply` locally.** The "source of truth" maintenance moves from your laptop to the automation server.

### The New "GitOps" Cycle

1.  **Branching**: Always start with a new branch.

    ```bash
    git checkout -b feature/add-fargate-cluster
    ```

2.  **Local Development**:
    - Edit code.
    - Run `terraform validate` and `terraform plan` locally to catch easy errors.
    - **STOP HERE**: Do not apply changes manually.

3.  **Push & Pull Request**:
    - Push your branch to GitHub.
    - Open a **Pull Request (PR)** against `main`.

4.  **Automated Plan**:
    - GitHub Actions triggers automatically on the PR.
    - It runs `terraform plan` and posts the output as a comment on your PR.
    - Review this plan to ensure it matches your expectations.

5.  **Merge & Apply**:
    - Once the PR is approved and merged into `main`, GitHub Actions triggers the **Apply** job.
    - The pipeline runs `terraform apply` against the live infrastructure.

### Key Differences

| Feature            | Local Workflow (Current) | CICD Workflow (Future)            |
| :----------------- | :----------------------- | :-------------------------------- |
| **Who Applies?**   | You (from terminal)      | GitHub Actions (backend)          |
| **When to Apply?** | Before committing        | After merging PR                  |
| **State Lock**     | Locked by your user      | Locked by CI Bot                  |
| **Safety**         | Relies on human caution  | enforced by PR reviews & policies |

## Summary Checklist (Current Local Workflow)

1.  [ ] `aws sso login`
2.  [ ] `cd <env-dir>`
3.  [ ] **Code Changes**
4.  [ ] `terraform fmt`
5.  [ ] `terraform plan -out=tfplan` (Review!)
6.  [ ] `terraform apply "tfplan"` (Apply to AWS)
7.  [ ] **Verify Infrastructure** works as expected
8.  [ ] `git add .`
9.  [ ] `git commit -m "..."`
10. [ ] `git push`
