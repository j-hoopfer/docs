# Common Migration Traps

This guide provides a quick reference for common issues encountered during the EC2 to Fargate migration, along with their symptoms and the phase where they should be addressed.

## Quick Reference Table

| Trap                          | Symptom                                  | Resolution                                                              | Phase to Fix |
| ----------------------------- | ---------------------------------------- | ----------------------------------------------------------------------- | ------------ |
| **App binds to `localhost`**  | Health checks fail, connection refused   | Bind to `0.0.0.0` or allow incoming requests from all IPs.              | Phase 2      |
| **No NAT Gateway**            | Tasks stuck in PENDING, can't pull image | Create NAT Gateway/Endpoints or select public subnet (not recommended). | Phase 3      |
| **Database SG missing SG**    | Database connection refused              | Allow Inbound from `FargateServiceSG`, not just specific IPs.           | Phase 3      |
| **No `/health` endpoint**     | Tasks killed before ready                | Implement a simple `gGET /health` responding 200 OK.                    | Phase 2      |
| **Secrets hardcoded**         | Works locally, fails in Fargate          | Use Environment Variables mapped to Secrets Manager.                    | Phase 2      |
| **Logs to files**             | Zero visibility into errors              | Write logs to STDOUT/STDERR for CloudWatch capture.                     | Phase 2      |
| **Wrong Docker architecture** | "exec format error" in logs              | Build with `--platform linux/amd64` (or target platform).               | Phase 2      |
| **Sessions in local memory**  | Users randomly logged out                | Externalize session state to Redis or Database.                         | Phase 2      |
| **Calling via public URL**    | High Latency + NAT costs                 | Use Service Connect or internal ALBs for service-to-service calls.      | Phase 5      |

## Detailed Explanations

### Application Binding to Localhost

- **Issue:** Containerized applications must bind to `0.0.0.0` to be accessible from outside the container. If your app defaults to `127.0.0.1` or `localhost`, the ALB health checks will fail.
- **Resolution:** Configure your application server (Express, Flask, Spring Boot, etc.) or web server (Nginx) to listen on `0.0.0.0`.

### Missing NAT Gateway

- **Issue:** Fargate tasks in private subnets need internet access to pull Docker images from ECR (unless using PrivateLink endpoints). Without a NAT Gateway (or endpoints), the task will hang in PENDING status.
- **Resolution:** Ensure your private subnets have a route to a NAT Gateway in a public subnet.

### Security Group Mismatches

- **Issue:** The most common connectivity issue. Ensure your RDS/ElastiCache Security Group allows inbound traffic on the database port from the **Fargate Service Security Group**, not just specific IPs.
- **Resolution:** Create a new Security Group for your Fargate Service (`FargateServiceSG`). Edit your Database SG to allow Inbound TCP on port 5432 (or 3306) from `FargateServiceSG`.

### Health Check Endpoint

- **Issue:** ECS requires a responsive HTTP endpoint (usually `/health`) to verify the application is running. If this doesn't exist or returns 500, ECS will kill and restart the task repeatedly.
- **Resolution:** Add a dedicated route `/health` that returns a JSON `{"status": "ok"}` and HTTP 200. It should be lightweight and not perform heavy database queries.

### Architecture Mismatch

- **Issue:** Building a Docker image on an Apple Silicon (ARM64) Mac without specifying `--platform linux/amd64` will result in an image that fails to run on Fargate x86 infrastructure with an "exec format error".
- **Resolution:** Always build with `docker buildx build --platform linux/amd64 ...` for production images if targeting Intel infrastructure, or ensure your Task Definition is set to ARM64.
