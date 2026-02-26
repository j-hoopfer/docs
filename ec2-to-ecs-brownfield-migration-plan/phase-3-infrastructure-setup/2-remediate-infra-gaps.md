# Activity 2: Remediate Network Gaps (Platform Layer)

**Goal:** Close the gaps identified in the [Infrastructure Audit](../../phase-1-discovery/2-infrastructure-audit.md) by updating the Platform Layer (`infra-platform`) to support Fargate requirements.

## Context & Themes

Before we can layer new services on top, we must patch the foundation. This step involves applying Terraform changes to the **Platform Account** to ensure the legacy VPC has Private Subnets, NAT Gateways, and Fargate-compatible Security Groups.

**Key Themes:**

- **Gap Closure:** Moving from "Legacy State" to "Fargate Ready".
- **Platform Layer:** Changes apply to `environments/network` and `infra-platform`.
- **Non-Destructive:** We are _adding_ capabilities (Subnets, Rules), not deleting legacy resources.

### Prerequisites

- [ ] [Activity 1: Import Platform Infrastructure](1-import-platform-infra.md) is complete (Current State is imported).
- [ ] [Infrastructure Audit](../../phase-1-discovery/2-infrastructure-audit.md) is complete (Gaps are identified).

---

## Feature 2: Network & Security Remediation

**Business Value:** Ensures the network foundation is capable of running secure, private container workloads without breaking existing legacy connectivity.

### Story 2.1: ECS Tasks Have Private Subnets to Run In

- **Title:** Close the "Subnet Gap" (Add Private Subnets)
- **Target Layer:** `scale.infra-platform` — `environments/dev/us-east-1/00-network/`
- **Persona:** As a **Cloud Engineer**, I need to provision missing Private Subnets so that Fargate tasks can run securely without public IP addresses.

**Why:** Fargate tasks in public subnets are a major security risk. To comply with "Secure by Design", tasks must live in Private Subnets.

- **Implementation Details:**
  - **Inputs:** Consult the Gap Report from Phase 1.
  - **Terraform Actions:**
    - Define new `aws_subnet` resources for `private-a` and `private-b` if missing.
    - Ensure they are in distinct Availability Zones (`us-east-1a`, `us-east-1b`).
    - Tag them clearly: `Tier = Private`, `kubernetes.io/role/internal-elb = 1`.

- **Acceptance Criteria:**
  - ✅ Legacy VPC now has at least 2 Private Subnets.
  - ✅ Terraform apply successful.

### Story 2.2: Containers Can Reach the Internet Without a Public IP

- **Title:** Provision NAT Gateway for Private Subnets
- **Target Layer:** `scale.infra-platform` — `environments/dev/us-east-1/00-network/`
- **Persona:** As a **Cloud Engineer**, I need to ensure private subnets can reach AWS services (ECR, SSM) and the internet (for patches/3rd party APIs).

**Why:** Without a NAT Gateway, Fargate tasks in private subnets cannot pull Docker images from ECR, causing immediate deployment failure (`CannotPullContainerError`).

- **Implementation Details:**
  - **Terraform Actions:**
    - Create `aws_eip` (Elastic IP).
    - Create `aws_nat_gateway` in a **Public Subnet**.
    - Create/Update `aws_route_table` for Private Subnets:
      - Route `0.0.0.0/0` &rarr; `aws_nat_gateway.id`.
  - **Cost awareness:** NAT Gateways cost ~$32/month. Ensure budget approval.

- **Acceptance Criteria:**
  - ✅ NAT Gateway active.
  - ✅ Private Route Tables point to NAT Gateway.
  - ✅ Connectivity verified (temporarily launch an EC2 in private subnet to test `curl google.com`).

### Story 2.3: Database Traffic is Accepted from ECS Tasks Only

- **Title:** Modernize Database Security Rules (Allow SG References)
- **Target Layer:** `scale.infra-platform` — `environments/dev/us-east-1/00-network/` (where `aws_security_group.rds` was imported in Activity 1)
- **Persona:** As a **DevOps Engineer**, I need to update the RDS Security Group to allow traffic from Fargate tasks, removing reliance on static EC2 IPs that break with dynamic container networking.

Legacy RDS security group rules commonly whitelist specific EC2 private IPs. Fargate tasks have fully dynamic IPs assigned at launch time — those static rules will silently fail the moment a Fargate task tries to connect to the database.

**Strategy:** This story adds a temporary broad rule to the RDS SG now, so the network path is unblocked the moment the first Fargate task deploys. [Activity 6, Story 6.2](6-create-security-groups.md) replaces this broad rule with scoped per-app SG references once the Fargate task security groups exist.

- **Implementation Details:**
  - **Target file:** `security_groups.tf` in `00-network` (same file where `aws_security_group.rds` lives from Activity 1).
  - **Action:** Add an `aws_vpc_security_group_ingress_rule` (or `aws_security_group_rule`) to the existing RDS SG allowing TCP on port 5432 (Postgres) or 3306 (MySQL) from the VPC CIDR block. Using the VPC CIDR is intentionally broad — it permits any resource in the VPC to reach the database, which is acceptable for the transition period but must be replaced.
  - **Why not create a shared `fargate-tasks-sg` here?** A single shared SG attached to all tasks is simpler but coarser — all apps can reach all databases. Activity 6 creates per-app SGs in `infra-services` with explicit per-app rules, which provides the granularity needed for least-privilege. That approach supersedes the shared SG pattern.

  ```hcl
  # File: security_groups.tf (in 00-network)
  # Temporary: allows any VPC resource to reach RDS on port 5432.
  # REPLACED in Activity 6 Story 6.2 with scoped per-app Fargate SG rules.
  resource "aws_vpc_security_group_ingress_rule" "rds_from_vpc_temp" {
    security_group_id = aws_security_group.rds.id
    description       = "TEMP: Allow Fargate tasks from VPC CIDR — replace with per-app SG rules in Activity 6"
    from_port         = 5432
    to_port           = 5432
    ip_protocol       = "tcp"
    cidr_ipv4         = aws_vpc.existing.cidr_block
  }
  ```

  > **NOTE** Do not remove existing EC2 SG rules. EC2 instances still need database access during the migration. Only remove those rules in Phase 6 after traffic has fully cut over to Fargate.

- **Acceptance Criteria:**
  - ✅ RDS Security Group has an inbound rule that permits dynamic Fargate task IPs (VPC CIDR or SG reference — not static EC2 IPs).
  - ✅ Existing EC2 SG rules remain intact.
  - ✅ `terraform plan` shows no unexpected changes to other resources.
  - ✅ Rule is annotated as temporary (`TEMP:` prefix in description) so it is easy to identify and remove in Activity 6.

### Story 2.4: Workload Account Can Manage DNS Records in the Payer Zone

- **Title:** Create Cross-Account IAM Role for Route 53 DNS Validation
- **Target Layer:** DNS / Shared Services account (not the workload account)
- **Persona:** As a **Cloud Engineer**, I need to create an IAM role in the account that owns the public Route 53 hosted zone so that Terraform running in the workload account can create the ACM DNS validation record during Phase 3 Story 4.1.
- **Applies when:** Phase 1 Story 2.3 flagged `GAP → hosted zone is in a different account`.

**Why:** ACM issues certificates in the workload account. DNS validation requires writing a `CNAME` record to the public hosted zone. If that zone is in a different AWS account, the default Terraform provider cannot reach it. Without this role, `terraform apply` will fail at the `aws_route53_record.cert_validation` step with `no matching Route 53 Hosted Zone found`.

> ✅ If the public hosted zone is already in the same account as the workload, skip this story entirely.

- **Implementation Details:**

Work with the team that owns the DNS / Shared Services account to create the following:

**IAM Policy — minimum permissions needed in the DNS account:**

Create `terraform-route53-dns-writer-policy`

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListHostedZones",
      "Effect": "Allow",
      "Action": [
        "route53:ListHostedZones",
        "route53:ListHostedZonesByName",
        "route53:GetHostedZone"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ManageDnsRecordsInZone",
      "Effect": "Allow",
      "Action": [
        "route53:ChangeResourceRecordSets",
        "route53:ListResourceRecordSets",
        "route53:GetChange"
      ],
      "Resource": "arn:aws:route53:::hostedzone/<HOSTED_ZONE_ID>"
    }
  ]
}
```

**Step 1: Create the IAM permissions policy** using the JSON above.

**Step 2: Create the IAM role** — the trust policy is provided _at creation time_ (it is not a separate action). Choose the trust policy option below that matches your setup, then create the role with it.

**IAM Trust Policy — allows the workload account(s) to assume the role:**

Choose the option that matches your setup:

**Option A — Explicit account list (fewer accounts, tighter control):**

List each workload account that needs to write DNS validation records. A common pattern is one account per environment (`dev`, `staging`, `prod`).

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": [
          "arn:aws:iam::<DEV_ACCOUNT_ID>:root",
          "arn:aws:iam::<STAGING_ACCOUNT_ID>:root",
          "arn:aws:iam::<PROD_ACCOUNT_ID>:root"
        ]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

````

Using `:root` as the principal means _any_ IAM entity in that account can assume the role (subject to that account's own IAM policies). To lock it down further, replace `:root` with a specific role ARN — e.g., the Terraform execution role for each environment:

```json
"AWS": [
  "arn:aws:iam::<DEV_ACCOUNT_ID>:role/TerraformExecutionRole",
  "arn:aws:iam::<PROD_ACCOUNT_ID>:role/TerraformExecutionRole"
]
```

**Option B — AWS Organizations condition (many accounts, scales automatically):**

If you manage accounts through AWS Organizations, you can trust the entire org rather than listing every account. New accounts automatically get access without touching the trust policy.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "*"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "aws:PrincipalOrgID": "<ORG_ID>"
        }
      }
    }
  ]
}
```

`<ORG_ID>` is your AWS Organizations ID — find it with `aws organizations describe-organization --query 'Organization.Id'`. The `aws:PrincipalOrgID` condition restricts assumption to principals that belong to your org, so external accounts cannot assume the role even though `Principal` is `*`.

> ⚠️ Option B is broader — any account in the org can assume this role. Acceptable for a low-risk read/write-DNS role; you may want to add an `aws:PrincipalAccount` condition to narrow it to specific account IDs if your org is large.

Name the role `terraform-route53-dns-writer`.

**Step 3: Attach the permissions policy to the role** — attach `terraform-route53-dns-writer-policy` to the `terraform-route53-dns-writer` role.

Once created, record the full role ARN — it is required for `providers.tf` in Story 4.1.

For full Terraform implementation details and the `provider = aws.dns` override pattern, see the [ACM Certificate Setup appendix](appendix/acm-certificate-setup.md#cross-account-scenario-hosted-zone-lives-in-a-different-aws-account).

- **Acceptance Criteria:**
  - ✅ `terraform-route53-dns-writer` exists in the DNS account with the minimum Policy above.
  - ✅ Trust policy allows the workload account to assume the role.
  - ✅ Role ARN documented and shared with the engineer executing Phase 3 Story 4.1.
  - ✅ Assumption tested: `aws sts assume-role --role-arn <arn> --role-session-name test` exits successfully from the workload account.
````
