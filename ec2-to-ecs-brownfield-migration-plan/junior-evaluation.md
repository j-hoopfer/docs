# EC2 to ECS Migration Plan - Junior Engineer Evaluation

**Evaluator Perspective:** Junior Engineer (0-1 years experience)  
**Evaluation Date:** February 15, 2026  
**Plan Version:** Phase 4 Refactored & Phase 0-6 Structure

---

## Executive Summary

**Overall Execution Readiness: 89%** ⬆️ (Excellent)

**Recommendation: High Confidence**

As a new hire, I feel very confident following this plan. The structure is logical, moving from "learning what we have" (Discovery) to "fixing the code" (App Readiness) before touching scary infrastructure. The recent refactoring of Phase 4 into smaller appendices made a huge difference—I no longer feel overwhelmed by a giant wall of text.

**Remaining Caveats:**

1. **Context Switching**: The plan relies heavily on linking to other repos (like `terraform-state-bootstrap-plan`) and sub-folders. I sometimes lose my place in the "meta-plan".
2. **Terraform Complexity**: Phase 3 assumes I'm comfortable with modules right away.
3. **Database Migration**: The "brownfield" aspect of moving RDS/Data is mentioned but feels high-risk for a junior.

---

## Phase-by-Phase Assessment

### Phase 0: Prerequisites

**Execution Readiness: 90%**

**Top 3 Risks/Blockers:**

1. **SSO Access**: "Configure AWS SSO" is easy to say, hard to do if I don't have permissions.
2. **Tool Versions**: If I have an older Terraform version, will it break? (Needs `.tool-versions` or strict version pinning in docs).
3. **Repo Access**: Do I have read access to the `terraform-state-bootstrap-plan`?

**Top 3 Strengths:**

1. **Clear Linkage**: Explicitly tells me to go do the Bootstrap Plan first.
2. **Reasoning**: Explains _why_ I need these tools, not just to install them.
3. **Sanity Checks**: The validation steps in the linked plans are life-savers.

---

### Phase 1: Discovery

**Execution Readiness: 85%**

**Top 3 Risks/Blockers:**

1. **"What is 'weird'?"**: The audit asks me to look for hardcoded IPs. I might miss some if I don't know regex.
2. **Hidden Dependencies**: I might miss a cron job running on an EC2 instance if I don't know where to look (`/var/spool/cron` vs `/etc/cron.d`).
3. **Non-Standard Ports**: If an app runs on port 8080 but I assume 80, I might document it wrong.

**Top 3 Strengths:**

1. **Scripts provided**: The audit scripts (implied) are helpful.
2. **Spreadsheet Template**: I know exactly where to put the data I find.
3. **Scope Definition**: Clearly defines what is "out of scope" so I don't waste time.

---

### Phase 2: Application Readiness (12-Factor)

**Execution Readiness: 95%** ⭐ **(Best Phase)**

**Top 3 Risks/Blockers:**

1. **Code Changes**: I might be afraid to change `app.py` to remove local filesystem writes without causing a bug.
2. **Secrets**: Moving from `.env` file to Secrets Manager is a big jump in logic.
3. **Local Testing**: "Works on my machine" vs "Works in Docker".

**Top 3 Strengths:**

1. **Concept Breakdown**: Splitting "12-Factor" from "Containerization" is brilliant. It stops me from trying to learn Docker and App Architecture at the same time.
2. **Step-by-Step Guides**: The sub-guides (e.g., `12-factor-prep/1-configuration.md`) are very granular.
3. **Clear "Definition of Done"**: I know exactly when to move to the next step.

---

### Phase 3: Infrastructure Setup (Terraform)

**Execution Readiness: 80%**

**Top 3 Risks/Blockers:**

1. **State Management**: If I mess up the backend config, I might corrupt the state file.
2. **Networking**: VPCs, Subnets, and NAT Gateways are complex. I might just copy-paste without understanding.
3. **Cost**: I'm afraid of spinning up a NAT Gateway and costing the company money if I leave it running.

**Top 3 Strengths:**

1. **Modular Approach**: Separating networking from app infra makes it less scary.
2. **Diagrams**: The architecture diagrams help me visualize what I'm building.
3. **Naming Conventions**: Clear rules on how to name things prevent arguments.

---

### Phase 4: Initial Deployment

**Execution Readiness: 92%** ⬆️ (Significant improvement)

**Top 3 Risks/Blockers:**

1. **ECS Concepts**: "Tasks" vs "Services" vs "Definitions" is still a bit confusing initially.
2. **Pipeline Failures**: If GitHub Actions fails, debugging it requires understanding YAML and AWS OIDC.
3. **Logs**: Searching CloudWatch logs for why a task stopped (CrashLoopBackOff) can be frustrating.

**Top 3 Strengths:**

1. **Appendix Refactor**: The new `appendix/` folder is a gold mine. The `troubleshooting-guide.md` specifically addresses my biggest fear (Project failing).
2. **Golden Paths**: The `ecs-deployment-strategies.md` gives me a clear default (Rolling Update) so I don't have to guess.
3. **Security First**: The `security-hardening.md` checklist makes me feel like I'm doing "senior" work safely.

---

### Phase 5 & 6 (Scaling & Cutover)

**Execution Readiness: 75%**

**Top 3 Risks/Blockers:**

1. **Downtime**: The "Cutover" phase is terrifying. Scaling up is fine, but switching traffic (DNS) feels irreversible.
2. **Rollback**: If the cutover fails, the rollback steps need to be practically copy-pasteable.
3. **Data Sync**: Ensuring the data in RDS is perfectly synced during cutover is a high-stress task.

**Top 3 Strengths:**

1. **Strangler Fig Pattern**: Mentioning this pattern gives me a strategy to research.
2. **Cleanup**: Explicit steps to remove old EC2 instances ensures we don't pay for double infra.
3. **Monitoring**: Emphasis on checking metrics before cutover.

---

## Final Thoughts

The documentation is in a really good place. The recent modularization of Phase 4 was the missing piece that makes this consumable for a junior engineer. If I have a senior engineer to review my Terraform plans and sit with me during the Phase 6 cutover, I can execute 90% of this autonomy.
