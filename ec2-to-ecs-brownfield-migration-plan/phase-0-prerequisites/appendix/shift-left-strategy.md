# Shift Left Strategy: Why Early CI/CD Matters

**Goal:** Understand why we enforce Linting (`tflint`) and Formatting (`terraform fmt`) in Phase 0, before deploying a single resource.

## What is "Shift Left"?

"Shift Left" is a practice in software engineering where testing, validaton, and security checks are performed earlier in the lifecycle (i.e., further to the "left" on the timeline).

Instead of waiting for a deployment to fail in the `plan` or `apply` stage (where it takes minutes to detect), we want to catch errors in the "code" stage (where it takes seconds).

## Why Phase 0?

It might seem premature to set up CI pipelines when we don't even have infrastructure yet. However, setting this foundation now provides:

1.  **Immediate Feedback:** As soon as you write your first line of code, the system tells you if it's correct.
2.  **Standardization:** no debates about indentation or style; the tooling enforces it.
3.  **Security by Default:** We catch insecure configurations (like open security groups) before they ever exist.

## The Tooling Trio

Ref: [Enhancing Your Terraform Code with TFLint and FMT](https://rafaelmedeiros94.medium.com/enhancing-your-terraform-code-with-tflint-and-fmt-6aa1f32f1ba0)

### 1. Terraform Fmt (Style & Consistency)

`terraform fmt` ensures that all HCL code looks the same, regardless of who wrote it. It fixes indentation, spacing, and alignment automatically.

**Before `fmt` (Messy, hard to read):**

```hcl
resource "aws_instance" "example_instance" {
ami = "ami-12345678"
    instance_type = "t4.medium"
tags = {
Name = "ExampleInstance"
} }
```

**After `fmt` (Clean, standard):**

```hcl
resource "aws_instance" "example_instance" {
  ami           = "ami-12345678"
  instance_type = "t4.medium"
  tags = {
    Name = "ExampleInstance"
  }
}
```

_By adding this check to CI, we eliminate PR comments like "please fix indentation on line 12."_

### 2. TFLint (Deep Analysis)

`terraform validate` only checks if your syntax is valid. It doesn't know if "t4.medium" is actually a valid AWS instance type or if you're using deprecated features. `tflint` fills this gap.

**Example Scenario:**
You define an instance type that looks valid syntactically but doesn't exist in AWS.

**Code:**

```hcl
resource "aws_instance" "web" {
  ami           = "ami-12345678"
  instance_type = "t99.superlarge" # Syntax is valid, but this type doesn't exist!
}
```

- `terraform validate`: **Passes** ✅ (Syntax is fine)
- `terraform plan`: **Fails** ❌ (After waiting 2+ minutes for API calls)
- `tflint`: **Fails Immediately** ❌

**TFLint Output:**

```text
Error: "t99.superlarge" is an invalid instance type.
```

## Summary: The Cost of Bugs

| Detection Stage          | Time to Fix | Cost |
| :----------------------- | :---------- | :--- |
| **Local / CI (Phase 0)** | Minutes     | $    |
| **Plan / Apply**         | Hours       | $$   |
| **Production**           | Days        | $$$$ |

By implementing these checks in **Phase 0**, we ensure that we are building on a solid, quality-assured foundation from Day 1.
