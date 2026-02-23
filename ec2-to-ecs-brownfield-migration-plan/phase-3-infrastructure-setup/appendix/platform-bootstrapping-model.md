# Appendix: The Platform Bootstrapping Model (Golden Path)

In an enterprise migration, the boundary between Platform Engineering and Software Engineering (SWE) is critical. If you ask 10 different SWE teams to write Terraform for their own Security Groups, you will get 10 different implementations—some of which will accidentally expose ports to the internet (`0.0.0.0/0`).

To prevent this, the **Platform Team owns the security boundaries**, even when those boundaries live inside the SWE's repository (`scale.infra-services`). This is known as the "Golden Path" or Platform Bootstrapping model.

## How it works in practice

### Phase 3: Platform Team "Scaffolds" the Services Repo

1. The Platform team finishes the shared cluster in `scale.infra-platform`.
2. **Crucial Step:** The Platform team then clones the `scale.infra-services` repo. They create the folder structure for all the legacy apps (e.g., `environments/dev/us-east-1/auth-api/`).
3. Inside those folders, the Platform team writes the Terraform to create the **Application Security Groups**.
4. _Why?_ Because the Platform team knows the exact ID of the ALB Security Group and the VPC. They wire up the "Security Group Chaining" so it is secure by default.
5. They commit this boilerplate to the `scale.infra-services` repo.

### Phase 4: SWEs Take Ownership

1. The SWE team is told: _"Your infrastructure repo is ready. We already created your Security Groups and wired them to the load balancer."_
2. The SWE team goes into their folder in `scale.infra-services`.
3. They only have to write the Terraform for their specific **Task Definition** (CPU, Memory, Environment Variables) and the **ECS Service**.
4. They reference the Security Group the Platform team already made for them.

## Why this is the Enterprise Standard

1. **Frictionless for SWEs:** Developers don't get blocked trying to figure out AWS networking or cross-repo state lookups.
2. **Secure by Default:** The InfoSec team signs off on Phase 3 because they know the Platform team hardcoded the Security Group rules to only allow traffic from the internal ALB.
3. **Parallel Work:** The Platform team can batch-create all 10 App SGs in an afternoon during Phase 3, while the SWEs are still busy dockerizing their apps in Phase 2.
