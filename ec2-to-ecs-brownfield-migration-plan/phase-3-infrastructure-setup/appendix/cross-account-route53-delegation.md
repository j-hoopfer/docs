# Appendix: Cross-Account Route 53 Delegation Role

> **This content has been merged into [acm-certificate-setup.md](acm-certificate-setup.md).**
>
> ACM certificate setup and cross-account Route 53 access are tightly coupled — validating a certificate requires writing a DNS record, and in multi-account setups the hosted zone lives in a different account from the one requesting the cert. The full setup, including the IAM role definition, provider alias configuration, per-account cert strategy, and troubleshooting, lives in the ACM appendix under **"Cross-Account Scenario"**.

<!--

The `example.com` public hosted zone lives in the **payer (management) account**. The `01-compute` stack is applied from the **workload account** (`infra-services`). Without a cross-account role, Terraform cannot look up the hosted zone or create the ACM DNS validation records — the credentials in scope during `terraform apply` simply have no access to the payer account's Route 53.

The fix is a two-part setup:

1. **Payer account:** IAM role that trusts the workload account and grants scoped Route 53 permissions.
2. **Workload account (`infra-platform`):** A second `aws` provider alias in `01-compute` that assumes that role.

---

## Part 1: IAM Role in the Payer Account

This must be created in the payer account. If the payer account has a Terraform project, add it there. Otherwise, create it manually via the AWS console or CLI.

### Role: `terraform-route53-dns-writer`

**Trust Policy** — allows the workload account to assume this role:

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

Replace `<WORKLOAD_ACCOUNT_ID>` with the account ID of `infra-services`.

> **Tighten this later:** Once Terraform is working, restrict the principal from `:root` to the specific IAM role or user that runs `terraform apply` in CI (e.g. the GitHub Actions OIDC role ARN).

**Permission Policy** — scoped to Route 53 only, limited to the specific hosted zone:

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

Replace `<HOSTED_ZONE_ID>` with the zone ID for `example.com` (run `scripts/get-import-ids.sh` to find it — the value after `/hostedzone/` in the Id column).

> **Why three statements?** `ListHostedZones` and `ListHostedZonesByName` are discovery operations — AWS does not support resource-level restrictions on them, so they must use `Resource: "*"`. Everything that operates on a known zone is scoped to the specific zone ARN. `GetChange` uses a separate `arn:aws:route53:::change/*` resource type (the change ID is not predictable), so it gets its own statement rather than falling back to `*`.

---

## Part 2: Provider Alias in `infra-platform`

Once the role exists, add a `dns` provider alias to `01-compute/provider.tf`:

```hcl
# provider.tf

provider "aws" {
  alias  = "dns"
  region = "us-east-1"
  assume_role {
    role_arn = "arn:aws:iam::<PAYER_ACCOUNT_ID>:role/terraform-route53-dns-writer"
  }
}
```

Then pin the Route 53 resources in `route53.tf` to that alias:

```hcl
# route53.tf

data "aws_route53_zone" "public" {
  provider     = aws.dns
  name         = "example.com"
  private_zone = false
}

resource "aws_route53_record" "cert_validation" {
  provider = aws.dns
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

Without `provider = aws.dns` on both blocks, Terraform uses the default workload account credentials and will fail with an `AccessDenied` or `NoSuchHostedZone` error.

---

## Checklist

- [ ] Identify the workload account ID (`infra-services`)
- [ ] Identify the `example.com` hosted zone ID (run `scripts/get-import-ids.sh`)
- [ ] Create `terraform-route53-dns-writer` in the payer account with the trust and permission policies above
- [ ] Add `provider "aws" { alias = "dns" ... }` to `01-compute/provider.tf`
- [ ] Add `provider = aws.dns` to both Route 53 blocks in `01-compute/route53.tf`
- [ ] Re-run `terraform apply` in `01-compute`
- [ ] (Later) Tighten the trust policy principal from `:root` to the specific CI role

-->
