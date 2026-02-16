# Appendix: Plan Directory Structure

This document outlines the directory structure for the `terraform-bootstrap-plan`.

## Directory Layout

To improve organization and readability, the plan documents have been separated into dedicated folders:

```
terraform-bootstrap-plan/
├── appendix/
│   ├── appendix.md
│   ├── iam-policy-design.md
│   ├── module-file-structure.md
│   └── plan-directory-structure.md  <-- This file
├── phase/
│   ├── phase-0-prerequisites.md
│   ├── phase-1-repository-setup.md
│   └── ... (other phase files)
└── README.md
```

### Rationale

- **`appendix/`**: Contains supplementary documentation, design decisions, and reference material that is not part of the core, sequential implementation steps.
- **`phase/`**: Contains the step-by-step implementation guides, ordered numerically. This makes the core workflow easy to follow from start to finish.
