# Network Provisioning Guide

This guide details the process for provisioning a new network (VPC) in a new AWS account or region using Terraform.

## Prerequisites

- Access to the target AWS account via AWS SSO/Identity Center.
- Terraform installed (v1.5+ recommended).
- A bootstrapped Terraform state bucket and DynamoDB table in each of the target accounts and regions (see `terraform-state-bootstrap-plan`).

## Directory Structure

We follow a strict directory hierarchy for infrastructure resources:

`scale.infra-platform/environments/<environment>/<region>/00-network/`

Example: `scale.infra-platform/environments/prod/us-east-1/00-network/`

## Use Cases

This guide covers two distinct scenarios:

1.  [**Scenario A: Same Account, New Environment**](#scenario-a-same-account-new-environment)
    - Example: Adding a `staging` VPC in the same AWS account as `dev` (if sharing an account) or `prod`.
    - _Note: Typically, we prefer separate accounts for true isolation, but sometimes regional isolation or logical separation is needed._

2.  [**Scenario B: New AWS Account (Cross-Account)**](#scenario-b-new-aws-account-cross-account)
    - Example: Provisioning the first VPC in a brand new `prod` or `sandbox` AWS account.
    - _Prerequisite: You must have AWS credentials for the NEW account._
3.  [**Scenario C: Hub-and-Spoke (Shared Networking Account)**](#scenario-c-hub-and-spoke-shared-networking-account)
    - Example: A setup with a dedicated "Networking" account hosting a Transit Gateway, connected to "Dev" and "Prod" workload accounts.
    - _Key Concept: Mapping Accounts to "Logical Environments"._

---

## Scenario A: Same Account, New Environment

Use this when you are adding a second VPC to an account that already has one (e.g., adding an isolated `data` or `demo` network to the `dev` account).

### 1. Directory Structure (New Stack)

Create a **sibling stack** inside the existing environment/account folder. Do not create a new top-level environment folder unless you are using a new AWS Account.

```bash
# Current: scale.infra-platform/environments/dev/us-east-1/00-network
# New:     scale.infra-platform/environments/dev/us-east-1/00-network-demo

mkdir -p scale.infra-platform/environments/dev/us-east-1/00-network-demo
cd scale.infra-platform/environments/dev/us-east-1/00-network-demo
```

### 2. Backend Config (Reuse Bucket, New Key)

Since you are in the same account, you reuse the existing Terraform State Bucket. **Crucial:** Change the `key` to match the new folder.

```hcl
# backend.tf
terraform {
  backend "s3" {
    bucket         = "scale-solutions-terraform-state-dev"
    key            = "platform/dev/us-east-1/00-network-demo/terraform.tfstate" # NEW key
    region         = "us-east-1"
    dynamodb_table = "terraform-locks-dev"
  }
}
```

### 3. Provider & Resources

Copy `provider.tf` and `vpc.tf` from the existing `00-network` stack.

**Important:** Update the `cidr_block` in `vpc.tf` to avoid overlap if you plan to peer them. Update tags only if necessary (e.g., `Attribute = "demo"`).

---

## Scenario B: New AWS Account (Cross-Account)

Use this when setting up a VPC in a completely separate AWS account (e.g., `prod` account vs `dev` account).

### 1. Prerequisite: Bootstrap State

**Before provisioning the network**, the new account must have a place to store state file.

- Refer to: `terraform-state-bootstrap-plan`
- Ensure an S3 bucket (e.g., `scale-solutions-terraform-state-prod`) exists in the new account.

### 2. Authenticate to New Account

Ensure your terminal session is authenticated against the **target** account.

```bash
aws sso login --profile prod-admin
export AWS_PROFILE=prod-admin
```

### 3. Directory Setup

Create the directory structure for the new account environment.

```bash
mkdir -p scale.infra-platform/environments/prod/us-east-1/00-network
cd scale.infra-platform/environments/prod/us-east-1/00-network
```

### 4. Backend Config (New Bucket)

Point to the **new** state bucket in the local `backend.tf`.

```hcl
# backend.tf
terraform {
  backend "s3" {
    bucket         = "scale-solutions-terraform-state-prod" # NEW bucket in PROD account
    key            = "platform/prod/us-east-1/00-network/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks-prod" # NEW table in PROD account
  }
}
```

### 5. Provider Config

Update `provider.tf` tags to reflect the new environment.

```hcl
# provider.tf
provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      Environment = "prod" # CHANGED
      ManagedBy   = "Terraform"
      # ...
    }
  }
}
```

### 6. Resource Definitions

Create your `vpc.tf` and `outputs.tf`. Since this is an isolated account, you can often reuse standard CIDR ranges (e.g., `10.100.0.0/16`) unless you plan to peer with other accounts, in which case unique CIDRs are required.

---

## Scenario C: Hub-and-Spoke (Shared Networking Account)

This scenario applies when you have a dedicated **Networking Account** (Hub) and separate **Workload Accounts** (Spokes).

In this model, "Environment" in the directory structure maps to the **Account Purpose** (Lifecycle Stage), not just a tag.

### 1. Conceptual Mapping

We treat the **Networking Account** as its own "logical environment" in your folder structure, often called `shared-network` or `net`.

| AWS Account            | Logical "Env" Folder | Purpose                      | Terraform State Bucket      |
| :--------------------- | :------------------- | :--------------------------- | :-------------------------- |
| `MyCompany-Networking` | `shared-network`     | Transit Gateway, Egress VPCs | `s3://...-state-networking` |
| `MyCompany-Dev`        | `dev`                | Workload Spoke VPCs          | `s3://...-state-dev`        |
| `MyCompany-Prod`       | `prod`               | Workload Spoke VPCs          | `s3://...-state-prod`       |

### 2. Implementation: Directory Structure

Add a new top-level folder for the networking account.

```text
scale.infra-platform/
└── environments/
    ├── shared-network/             <-- Maps to Networking Account
    │   └── us-east-1/
    │       ├── 00-transit-hub/     <-- The Hub (Transit Gateway)
    │       ├── 01-egress-dev/      <-- Egress VPC for Dev Traffic
    │       └── 01-egress-prod/     <-- Egress VPC for Prod Traffic
    ├── dev/                        <-- Maps to Dev Account
    │   └── us-east-1/
    │       └── 00-network/         <-- The "Spoke" VPC
    └── prod/                       <-- Maps to Prod Account
        └── us-east-1/
            └── 00-network/         <-- The "Spoke" VPC
```

_Note: Egress VPCs are prefixed with `01-` because they depend on the Hub (`00-transit-hub`) to function properly._

### 3. Configuration Differences

#### A. The Networking Account (`shared-network`)

This is where your Transit Hub lives. The tags here reflect that these resources support _all_ environments.

**File:** `environments/shared-network/us-east-1/00-transit-hub/provider.tf`

```hcl
provider "aws" {
  region = "us-east-1"
  profile = "networking-admin" # AWS SSO Profile for Networking Account

  default_tags {
    tags = {
      Environment = "shared"       # or "foundation"
      Account     = "networking"   # Useful to verify which account owns it
      Role        = "hub"
      ManagedBy   = "Terraform"
    }
  }
}
```

#### B. The Dev Workload Account (`dev`)

This contains a **Spoke VPC** that has no Internet Gateway (IGW). Instead, it routes 0.0.0.0/0 to the Transit Gateway.

**File:** `environments/dev/us-east-1/00-network/provider.tf`

```hcl
provider "aws" {
  region = "us-east-1"
  profile = "dev-admin" # AWS SSO Profile for Dev Account

  default_tags {
    tags = {
      Environment = "dev"
      Account     = "workload-dev"
      Role        = "spoke"
      ManagedBy   = "Terraform"
    }
  }
}
```

### 4. Connection Strategy (Resource Access Manager)

Since these are separate accounts, you cannot reference resources directly.

1.  **Share**: The Networking account shares the Transit Gateway via **AWS RAM** to your Organization.
2.  **Attach**: The Workload (Dev/Prod) account creates an `aws_ec2_transit_gateway_vpc_attachment`.

## Common Steps (Deployment)

### 1. Deployment

1.  **Initialize:** `terraform init`
2.  **Review:** `terraform plan -out=tfplan`
3.  **Apply:** `terraform apply tfplan`

## Verification

After applying, verify the following in the AWS Console:

1.  VPC exists with correct CIDR.
2.  Subnets are created in correct Availability Zones.
3.  Route tables are associated correctly (Private subnets -> NAT, Public -> IGW).
