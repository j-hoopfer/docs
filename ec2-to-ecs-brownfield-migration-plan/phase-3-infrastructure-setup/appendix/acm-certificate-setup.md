# Appendix: ACM Certificates

## What Is a TLS Certificate and Why Does It Matter?

When a browser visits `https://api.mycompany.com`, two things happen:

1. **Encryption** — All traffic between the browser and the server is encrypted. Nobody in the middle can read it.
2. **Identity verification** — The browser verifies that the server it's talking to actually owns the domain `api.mycompany.com`. This is what the certificate proves.

The certificate is issued by a trusted third party called a **Certificate Authority (CA)**. AWS operates its own CA called **ACM (AWS Certificate Manager)**. ACM certificates are free, auto-renewing, and integrate natively with AWS services like ALBs.

Without a certificate, you cannot serve HTTPS traffic. Without HTTPS, modern browsers show a "Not Secure" warning and many corporate security policies will block the connection entirely.

---

## The Relationship Between a Certificate and an ALB

The ALB is the thing that terminates HTTPS — meaning it decrypts incoming traffic before passing it to your services. To do that, the ALB needs to hold the certificate.

The flow looks like this:

```
Browser → HTTPS (port 443) → ALB (decrypts using cert) → HTTP (port 80) → ECS Service
```

This pattern is called **TLS termination at the load balancer**. Your services behind the ALB only ever see plain HTTP — they don't need to know anything about certificates. The ALB handles all the encryption/decryption at the edge.

When you attach a cert to an ALB HTTPS listener, you're saying: _"When traffic arrives on port 443, use this certificate to prove who we are and decrypt the request."_

---

## Why Does the Certificate Care About Your Domain?

A certificate is a statement: _"The entity presenting this cert is the legitimate owner of `api.mycompany.com`."_

Because the certificate is bound to a specific domain name, the domain in the cert must match the domain the browser is trying to reach. If a user visits `api.mycompany.com` but the cert says `api.otherdomain.com`, the browser will reject it with a certificate mismatch error.

This is why:

- You must **own** the domain before requesting a cert
- ACM must **verify** you own it before issuing the cert (via DNS validation)
- The `domain_name` field in `aws_acm_certificate` must match the real domain your ALB will serve traffic on

---

## Wildcard Certificates

The **apex** (also called the "root" or "naked" domain) is the domain with no subdomain prefix — just `mycompany.com` on its own. Everything with a prefix (`api.mycompany.com`, `auth.mycompany.com`) is a subdomain. The apex is the top of the hierarchy.

A **wildcard certificate** uses a `*` to cover all subdomains under a domain in a single cert.

```
mycompany.com          ← apex domain
api.mycompany.com      ← subdomain
auth.mycompany.com     ← subdomain
sub.api.mycompany.com  ← two levels deep (not covered by a single wildcard)
```

| Cert domain       | Covers                                                         | Does NOT cover                                                    |
| :---------------- | :------------------------------------------------------------- | :---------------------------------------------------------------- |
| `*.mycompany.com` | `api.mycompany.com`, `auth.mycompany.com`, `app.mycompany.com` | `mycompany.com` (apex), `sub.api.mycompany.com` (two levels deep) |
| `mycompany.com`   | `mycompany.com` only                                           | Any subdomain                                                     |

A wildcard cert is ideal for a shared ALB because a single cert covers all services regardless of what subdomains you add in the future.

---

## What Is a Subject Alternative Name (SAN)?

A certificate's **primary domain** (`domain_name`) covers one name. But a single certificate can also cover **additional names** — these are called Subject Alternative Names (SANs).

For example, you might want one cert that covers both the wildcard and the apex:

```hcl
resource "aws_acm_certificate" "main" {
  domain_name               = "*.mycompany.com"   # Primary — all subdomains
  subject_alternative_names = ["mycompany.com"]   # SAN — also covers the apex
  validation_method         = "DNS"
}
```

This means a user visiting `mycompany.com` (no subdomain) and a user visiting `api.mycompany.com` both get a valid certificate from the same cert. SANs save cost and complexity — you manage one cert instead of two.

---

## How ACM Verifies You Own the Domain (DNS Validation)

Before ACM issues the certificate, it needs proof you control the domain. The simplest method is **DNS validation**:

1. ACM generates a unique `CNAME` record (a specific name and value).
2. You add that `CNAME` to your domain's **public** DNS zone.
3. ACM periodically checks for the record. Once found, it issues the cert.
4. ACM keeps checking forever — this is also how it handles automatic renewal.

In Terraform, this is automated:

- `aws_acm_certificate` requests the cert and exposes the required `CNAME` details via `domain_validation_options`.
- `aws_route53_record` reads those details and creates the record in your public Route 53 zone.
- `aws_acm_certificate_validation` waits until ACM confirms the record is found and the cert is `ISSUED`.

> ⚠️ The validation record must go in the **public** hosted zone — not the private `corp.internal` zone used for internal service discovery. ACM validates from the public internet and cannot see private DNS.

---

## Which Layer Does the Cert Belong To?

The certificate is an **edge/ingress concern** — it is tightly coupled to the public ALB HTTPS listener and has no relevance to internal workloads or the internal ALB. It lives in the same stack as the public ALB (`01-compute` for now). If the public ALB is ever promoted to its own `01-edge` stack (see [alb-stack-separation.md](alb-stack-separation.md)), the certificate moves with it.

---

## Cross-Account Scenario: Hosted Zone Lives in a Different AWS Account

This is very common in multi-account AWS setups. The domain and its public Route 53 hosted zone are typically owned by a central **DNS account** or a **Shared Services / Platform account**, while the certificate is requested in a **Workload account** (e.g., `infra-platform` dev).

The problem: `data.aws_route53_zone.public` and `aws_route53_record.cert_validation` query Route 53, which uses the AWS credentials of the current provider. If the hosted zone is in a different account, the lookup will fail with `no hosted zones found`.

### Solution: Use a Second Provider with Cross-Account Role Assumption

Add a second AWS provider configured to assume a role in the DNS account, then target the Route 53 resources at that provider.

#### Step 1: Add a DNS account provider alias

```hcl
# File: providers.tf (in 01-compute)

# Default provider — Workload account (where the cert is requested)
provider "aws" {
  region = "us-east-1"
}

# Secondary provider — Payer account (where the hosted zone lives)
provider "aws" {
  alias  = "dns"
  region = "us-east-1"

  assume_role {
    role_arn = "arn:aws:iam::<PAYER_ACCOUNT_ID>:role/terraform-route53-dns-writer"
    # See "IAM Role Requirements" below for the trust and permission policies this role needs.
  }
}
```

#### Step 2: Target the Route 53 resources at the DNS provider

All cert-related resources live together in `acm.tf` — the cert, the zone lookup, the validation records, and the waiter. Only the two Route 53 blocks need the `provider = aws.dns` override; the `aws_acm_certificate` and `aws_acm_certificate_validation` resources run against the default (Workload) provider and are unchanged.

```hcl
# File: acm.tf (Route 53 section)

# Look up the hosted zone using the DNS account credentials
data "aws_route53_zone" "public" {
  provider = aws.dns          # ← targets the DNS account
  name         = "example.com"
  private_zone = false
}

# Create the validation record in the DNS account
resource "aws_route53_record" "cert_validation" {
  provider = aws.dns              # ← targets the DNS account
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }
  allow_overwrite = true
  zone_id         = data.aws_route53_zone.public.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
}
```

> ⚠️ Without `provider = aws.dns` on **both** Route 53 blocks, Terraform uses the default workload account credentials and will fail with an `AccessDenied` or `NoSuchHostedZone` error.

> **Why everything is in `acm.tf`:** The cert, zone lookup, validation records, and waiter are a single logical unit — you cannot validate the cert without the records, and you cannot create the records without the cert's `domain_validation_options`. Keeping them in one file means an engineer reading `acm.tf` sees the full picture without jumping to `route53.tf`. `route53.tf` is reserved exclusively for the private hosted zone used for internal service discovery.

### What If You Can't Assume a Role Into the DNS Account?

If cross-account role assumption isn't available (e.g., the DNS account is managed by a separate team), you have two options:

**Option A — Manual validation (no Terraform for the CNAME)**

1. Run `terraform apply` with only `aws_acm_certificate` (comment out `aws_acm_certificate_validation` temporarily).
2. After apply, go to the ACM console and copy the CNAME name/value from the certificate's validation details.
3. Give those values to the DNS team to add manually.
4. Once the cert reaches `ISSUED`, uncomment `aws_acm_certificate_validation` and run `terraform apply` again.

**Option B — Email validation (not recommended)**

ACM also supports email validation — it sends an email to standard admin addresses for the domain (e.g., `admin@mycompany.com`). Someone must click the approval link. This is harder to automate and should only be used as a last resort.

### IAM Role Requirements in the DNS Account

Create a role named `terraform-route53-dns-writer` in the DNS account. The Workload account's Terraform caller assumes this role to look up the hosted zone and write validation records.

**Trust Policy** — allows the Workload account to assume this role:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::<WORKLOAD_ACCOUNT_ID>:root"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

Replace `<WORKLOAD_ACCOUNT_ID>` with the account ID of the Workload account.

> **Tighten this later:** Once Terraform is running in CI, restrict the principal from `:root` to the specific IAM role that runs `terraform apply` (e.g., the GitHub Actions OIDC role ARN).

**Permission Policy** — scoped to Route 53 only, with record mutations limited to the specific hosted zone:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListHostedZones",
      "Effect": "Allow",
      "Action": ["route53:ListHostedZones", "route53:ListHostedZonesByName"],
      "Resource": "*"
    },
    {
      "Sid": "ManageZone",
      "Effect": "Allow",
      "Action": [
        "route53:GetHostedZone",
        "route53:ListTagsForResource",
        "route53:ChangeResourceRecordSets",
        "route53:ListResourceRecordSets"
      ],
      "Resource": "arn:aws:route53:::hostedzone/<HOSTED_ZONE_ID>"
    },
    {
      "Sid": "PollChanges",
      "Effect": "Allow",
      "Action": ["route53:GetChange"],
      "Resource": "arn:aws:route53:::change/*"
    }
  ]
}
```

Replace `<HOSTED_ZONE_ID>` with the zone ID for your domain (run `scripts/get-import-ids.sh` to find it).

#### Why each permission is required

| Permission                         | Why it's needed                                                                    | Can be scoped?                                                                        |
| :--------------------------------- | :--------------------------------------------------------------------------------- | :------------------------------------------------------------------------------------ |
| `route53:ListHostedZones`          | `data "aws_route53_zone"` calls this to enumerate all zones, then filters by name  | No — AWS does not support resource restrictions on list operations                    |
| `route53:ListHostedZonesByName`    | The Terraform provider calls this as an alternative zone lookup path               | No — same reason                                                                      |
| `route53:GetHostedZone`            | Called after the zone is found to read its full details                            | Yes — zone ARN                                                                        |
| `route53:ListTagsForResource`      | `data "aws_route53_zone"` reads the zone's tags as part of its refresh cycle       | Yes — zone ARN                                                                        |
| `route53:ChangeResourceRecordSets` | Creates/updates/deletes the CNAME validation record                                | Yes — zone ARN                                                                        |
| `route53:ListResourceRecordSets`   | Terraform reads existing records during plan and refresh                           | Yes — zone ARN                                                                        |
| `route53:GetChange`                | After submitting the CNAME, Terraform polls this until the change reaches `INSYNC` | Partially — change IDs are dynamic, but can be scoped to `arn:aws:route53:::change/*` |

---

### Cross-Account Setup Checklist

- [ ] Identify the Workload account ID
- [ ] Identify the hosted zone ID for your domain (run `scripts/get-import-ids.sh`)
- [ ] Create `terraform-route53-dns-writer` in the DNS account with the trust and permission policies above
- [ ] Add `provider "aws" { alias = "dns" ... }` to `01-compute/provider.tf`
- [ ] Add `provider = aws.dns` to both Route 53 blocks in `01-compute/route53.tf`
- [ ] Re-run `terraform apply` in `01-compute`
- [ ] (Later) Tighten the trust policy principal from `:root` to the specific CI role

---

## Can I Have the Same Wildcard Cert in Multiple Workload Accounts?

Yes — and this is the expected pattern in a multi-account setup.

**ACM certificates are account-scoped.** There is no mechanism in AWS to share a certificate across accounts (AWS RAM explicitly does not support ACM). The certificate must live in the same account as the resource using it. This means:

- Dev account → its own `*.scale-consulting.io` cert in `environments/dev/us-east-1/01-compute`
- Prod account → its own `*.scale-consulting.io` cert in `environments/prod/us-east-1/01-compute`

Both certs validate against the same hosted zone in the payer account, via the same cross-account `aws.dns` provider alias. The cross-account role needs to trust both workload accounts (or you can create a separate role per account — same policy, different trust).

### Why Doesn't the Validation CNAME Conflict?

ACM generates the validation CNAME deterministically from the domain and zone — it is the same name and value regardless of which account requested the cert. So when dev applies and creates the record, and prod later applies and tries to create the same record, they are writing the exact same CNAME.

This is precisely why `allow_overwrite = true` is set on `aws_route53_record.cert_validation`. Without it, the second account's apply would fail with `InvalidChangeBatch: already exists`. With it, the upsert succeeds silently — the record ends up identical either way.

```
Dev apply  → creates _c4e73163....scale-consulting.io CNAME → <acm-validation-value>
Prod apply → overwrites with identical value ✅ (no conflict, no error)
```

ACM in each account independently polls the public DNS record and validates. Both certs reach `ISSUED`.

### What This Looks Like Across Accounts

|                      | Dev account                       | Prod account                      |
| :------------------- | :-------------------------------- | :-------------------------------- |
| **ACM cert**         | `*.scale-consulting.io` in dev    | `*.scale-consulting.io` in prod   |
| **Cert ARN**         | Different ARN                     | Different ARN                     |
| **Validation CNAME** | Same record, same value           | Same record, same value           |
| **ALB**              | Dev ALB uses dev cert ARN         | Prod ALB uses prod cert ARN       |
| **Provider alias**   | `aws.dns` → assumes role in payer | `aws.dns` → assumes role in payer |

The trust policy on `terraform-route53-dns-writer` in the payer account needs to allow both workload accounts:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": [
          "arn:aws:iam::<DEV_ACCOUNT_ID>:root",
          "arn:aws:iam::<PROD_ACCOUNT_ID>:root"
        ]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

> Or create a `terraform-route53-dns-writer` role per account with single-account trust policies — this is stricter and easier to audit, at the cost of maintaining two identical permission policies.

---

## Prerequisites (Before You Write Any Terraform)

| #   | Requirement                                | Detail                                                                                                          |
| :-- | :----------------------------------------- | :-------------------------------------------------------------------------------------------------------------- |
| 1   | **You own the domain**                     | `*.example.com` is a placeholder. Replace with a real domain you control.                                       |
| 2   | **Public Route 53 hosted zone exists**     | The zone must be public and resolvable from the internet.                                                       |
| 3   | **Cert reaches `ISSUED` before Story 4.2** | DNS validation takes 2–5 min typically, up to 30 min. The `aws_acm_certificate_validation` waiter handles this. |
| 4   | **Cert is in the same region as the ALB**  | e.g., `us-east-1`. Exception: CloudFront always requires `us-east-1`.                                           |

| Domain scenario                | Action                                                                                                                |
| :----------------------------- | :-------------------------------------------------------------------------------------------------------------------- |
| Domain is already in Route 53  | Check the [Route 53 console](https://console.aws.amazon.com/route53) for an existing **public** hosted zone.          |
| Domain is at another registrar | Either transfer DNS to Route 53, or manually create the validation `CNAME` at your registrar after `terraform apply`. |
| You don't have a domain yet    | Register one via Route 53 Domains or any registrar. A `.com` domain is ~$12/year.                                     |

---

## Why `aws_acm_certificate_validation` Instead of `aws_acm_certificate`?

When attaching a cert to an ALB listener, you have two options:

| Reference                                             | Behaviour                                                                                                                                                     |
| :---------------------------------------------------- | :------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `aws_acm_certificate.main.arn`                        | Terraform creates the listener immediately, even if the cert is still `PENDING_VALIDATION`. The apply may succeed but the listener will silently fail in AWS. |
| `aws_acm_certificate_validation.main.certificate_arn` | Terraform waits until the cert reaches `ISSUED` before creating the listener. Safer — no partial failures.                                                    |

Always use `aws_acm_certificate_validation.main.certificate_arn` in the listener.

---

## Terraform Implementation

All four cert-related resources live in `acm.tf`. They form a single logical unit: request cert → prove ownership via DNS → wait for issuance. Keeping them together means you can read the full flow in one file without cross-referencing `route53.tf`.

`route53.tf` is reserved exclusively for the private hosted zone (`aws_route53_zone.internal`) used for internal service discovery.

### File: `acm.tf`

```hcl
# ── Certificate ───────────────────────────────────────────────────────────────
# Step 1: Request the certificate
resource "aws_acm_certificate" "main" {
  domain_name               = "*.example.com"    # Replace with your real domain — covers all subdomains
  subject_alternative_names = ["example.com"]    # Also covers the apex (e.g. example.com with no subdomain)
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true # Required for safe cert rotation later
  }
}

# ── Validation DNS Records ─────────────────────────────────────────────────────
# Step 2: Look up the PUBLIC hosted zone for your domain.
# Uses the dns provider alias because the hosted zone lives in the DNS account.
# The private corp.internal zone in route53.tf is NOT used here —
# ACM validates from the public internet and cannot reach private DNS.
data "aws_route53_zone" "public" {
  provider = aws.dns

  name         = "example.com" # Replace with your real apex domain (no wildcard)
  private_zone = false
}

# Step 3: Create the DNS validation CNAME record ACM needs to verify domain ownership
resource "aws_route53_record" "cert_validation" {
  provider = aws.dns

  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }
  allow_overwrite = true # Prevents failure if the record already exists (e.g. from a previous cert or when adding the apex SAN)
  zone_id         = data.aws_route53_zone.public.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
}

# ── Validation Waiter ──────────────────────────────────────────────────────────
# Step 4: Wait for ACM to confirm the cert is ISSUED before proceeding.
# Blocks apply until the cert reaches ISSUED so the HTTPS listener
# is never created against a PENDING_VALIDATION cert.
resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}
```

---

## Troubleshooting

### `InvalidChangeBatch: [Tried to create resource record set ... but it already exists]`

**Cause:** A validation CNAME for that domain already exists in the hosted zone — most commonly because:

- A previous cert was created and the old record was never cleaned up, or
- You added the apex as a SAN (`subject_alternative_names = ["example.com"]`) after the wildcard cert already existed. ACM generates a second `domain_validation_options` entry for the apex, and Terraform tries to create a new record for it — but the CNAME was already placed when the original cert was validated.

**Fix:** Add `allow_overwrite = true` to the `aws_route53_record.cert_validation` resource:

```hcl
resource "aws_route53_record" "cert_validation" {
  # ...
  allow_overwrite = true  # ← add this
  zone_id         = data.aws_route53_zone.public.zone_id
  # ...
}
```

This is safe — ACM validation records are idempotent. The name and value are deterministic for a given domain and zone, so overwriting with the same value has no effect.

---

### IAM Permission Errors on the Cross-Account Role

**Cause:** The `terraform-route53-dns-writer` role is either missing a required action or has an action applied to the wrong resource type.

The most common culprit is `route53:ListTagsForResource` — the Terraform provider calls this when refreshing the `data "aws_route53_zone"` resource (it reads zone tags). It works fine, but **only when scoped to the zone ARN**, not to `arn:aws:route53:::change/*` or `"*"`. Placing it in the wrong statement causes a policy validation error from AWS.

Similarly, `route53:GetChange` uses a `arn:aws:route53:::change/<id>` resource ARN — it cannot be placed in the same statement as the zone ARN.

The correct policy separates these into three statements:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListHostedZones",
      "Effect": "Allow",
      "Action": ["route53:ListHostedZones", "route53:ListHostedZonesByName"],
      "Resource": "*"
    },
    {
      "Sid": "ManageZone",
      "Effect": "Allow",
      "Action": [
        "route53:GetHostedZone",
        "route53:ListTagsForResource",
        "route53:ChangeResourceRecordSets",
        "route53:ListResourceRecordSets"
      ],
      "Resource": "arn:aws:route53:::hostedzone/<HOSTED_ZONE_ID>"
    },
    {
      "Sid": "PollChanges",
      "Effect": "Allow",
      "Action": ["route53:GetChange"],
      "Resource": "arn:aws:route53:::change/*"
    }
  ]
}
```

---

## Acceptance Criteria

- ✅ Public hosted zone exists for the domain in Route 53.
- ✅ Certificate Status: `ISSUED` (visible in ACM console).
- ✅ `aws_acm_certificate_validation` completes without timeout.
- ✅ Certificate attached to the Public ALB HTTPS Listener.
