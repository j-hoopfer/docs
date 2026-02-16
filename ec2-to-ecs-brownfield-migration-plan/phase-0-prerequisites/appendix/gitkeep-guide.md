# What is `.gitkeep`?

**Goal:** Understand why we see empty `.gitkeep` files in our directory structure and why they are necessary for our CI/CD pipelines.

## The Problem: Empty Directories

By design, **Git does not track empty directories**.

If you create a directory structure like `environments/dev/us-east-1/` but don't put any files inside it, Git will completely ignore those folders when you commit.

### Why this breaks CI/CD

In our setup, we have a GitHub Action (`validate.yml`) that tries to run `terraform init` inside specific directories:

```yaml
steps:
  - name: Terraform Init
    working-directory: environments/dev/us-east-1
    run: terraform init -backend=false
```

If Git ignored the empty folders, the GitHub Runner will clone your repository, but the `environments/dev/us-east-1` path **will not exist**. The workflow will crash with a "No such file or directory" error.

## The Solution: `.gitkeep`

To force Git to track a folder, we place a hidden, empty file inside it. By convention, this file is named `.gitkeep`.

- The filename `.gitkeep` is not an official Git feature; it's just a convention used by developers.
- You can technically name it `.placeholder` or `README.md`, but `.gitkeep` explicitly tells other developers: _"This file is here just to keep the folder in Git."_

## When to Remove It?

Once you add real files (like `main.tf`, `variables.tf`, etc.) to that directory, the folder is no longer empty. At that point, the `.gitkeep` file becomes redundant and can be safely deleted.

However, leaving it there causes no harm—Terraform ignores dotfiles by default.
