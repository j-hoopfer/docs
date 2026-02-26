# Local Development

**Goal:** Enable developers to run the full application stack locally (using `docker-compose`) so they can iterate rapidly without needing a deployed environment.

## Context & Themes

Replicating the production environment locally is key to velocity. By using `docker-compose`, developers can run the app, database, and cache without complex manual setup, eliminating "it works on my machine" issues.

**Key Themes:**

- **Dev/Prod Parity:** Running the same stack locally as in production.
- **Rapid Iteration:** Fast feedback loops without deployment.
- **Dependency Isolation:** Encapsulating backing services in containers.

### Prerequisites

- [ ] Docker Desktop installed and running.
- [ ] Application Dockerfile created.

## Feature 2: Local Development Parity

**Business Value:** Enables developers to run the full application stack locally, eliminating "works on my machine" issues and accelerating onboarding.

### Story 2.1: Establish Local Development Parity within `docker-compose`

- **Title:** Create docker-compose for Local Development
- **Persona:** As a **developer**, I need to run the entire application stack locally so that I can develop and test features without deploying to AWS.

**Business Value:** Enables developers to run the full application stack locally, eliminating "works on my machine" issues. Local docker-compose environment matches production ECS behavior, reducing deployment surprises and debugging time. Onboarding new developers drops from 2-3 days to 30 minutes.

- **Requirements:**
  - Application runs with all dependencies (database, Redis, etc.)
  - Environment matches production configuration
  - Hot reload for rapid development
  - Seed data for development
  - Single command to start entire stack

- **Implementation Details:**

  **First-time setup — create your local `.env`:**

  ```bash
  # Copy the example file and populate with your local values
  cp .env.example .env
  # Edit .env with real local values — this file is gitignored, never commit it
  ```

  > **Why `env_file` instead of inline `environment:`?** Inline values in docker-compose are committed to git. Anything sensitive (DB passwords, API keys, AWS credentials) must live in `.env` instead, injected at runtime via `env_file`. This mirrors how ECS injects secrets in production — your app always reads `process.env.SECRET`, regardless of where the value came from. See [Appendix: Secrets Management for 12-Factor Applications](../appendix/secrets-for-12-factor-apps.md) for the full ADR.

  **Create docker-compose.yml:**

  ```yaml
  # docker-compose.yml
  version: "3.8"

  services:
    # Application Service
    app:
      build:
        context: .
        dockerfile: Dockerfile
      ports:
        - "3000:3000"
      env_file:
        - .env # All app config and secrets come from here — never inline sensitive values
      volumes:
        # Hot reload - mount source code
        - .:/app
        - /app/node_modules # Don't overwrite node_modules
      depends_on:
        postgres:
          condition: service_healthy
        redis:
          condition: service_healthy
      command: npm run dev # Use dev mode with hot reload

    # PostgreSQL Database
    postgres:
      image: postgres:15-alpine
      ports:
        - "5432:5432"
      environment:
        POSTGRES_USER: postgres
        POSTGRES_PASSWORD: postgres
        POSTGRES_DB: myapp
      volumes:
        - postgres_data:/var/lib/postgresql/data
        - ./scripts/init-db.sql:/docker-entrypoint-initdb.d/init.sql
      healthcheck:
        test: ["CMD-SHELL", "pg_isready -U postgres"]
        interval: 5s
        timeout: 5s
        retries: 5

    # Redis Cache
    redis:
      image: redis:7-alpine
      ports:
        - "6379:6379"
      volumes:
        - redis_data:/data
      healthcheck:
        test: ["CMD", "redis-cli", "ping"]
        interval: 5s
        timeout: 3s
        retries: 5

    # Background Worker (if applicable)
    worker:
      build:
        context: .
        dockerfile: Dockerfile
      environment:
        NODE_ENV: development
        DB_HOST: postgres
        DB_PORT: 5432
        DB_NAME: myapp
        DB_USER: postgres
        DB_PASSWORD: postgres
        REDIS_HOST: redis
        REDIS_PORT: 6379
      volumes:
        - .:/app
        - /app/node_modules
      depends_on:
        - postgres
        - redis
      command: npm run worker

  volumes:
    postgres_data:
    redis_data:
  ```

  **Development Dockerfile (with hot reload):**

  ```dockerfile
  # Dockerfile.dev
  FROM node:20-slim

  # Install tini
  RUN apt-get update && apt-get install -y tini && rm -rf /var/lib/apt/lists/*

  WORKDIR /app

  # Copy package files
  COPY package*.json ./

  # Install ALL dependencies (including devDependencies for hot reload)
  RUN npm install

  # Copy application code (volume will override in docker-compose)
  COPY . .

  # Don't run as root in dev
  RUN groupadd -g 1001 appgroup && \
      useradd -u 1001 -g appgroup -m appuser && \
      chown -R appuser:appgroup /app

  USER appuser

  EXPOSE 3000

  ENTRYPOINT ["/usr/bin/tini", "--"]
  CMD ["npm", "run", "dev"]
  ```

  **Or use production Dockerfile with override:**

  ```yaml
  # docker-compose.override.yml (automatically loaded)
  version: "3.8"

  services:
    app:
      volumes:
        - .:/app
        - /app/node_modules
      command: npm run dev
      environment:
        NODE_ENV: development
  ```

  **Database Seed Script:**

  ```sql
  -- scripts/init-db.sql
  CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    email VARCHAR(255) UNIQUE NOT NULL,
    name VARCHAR(255),
    created_at TIMESTAMP DEFAULT NOW()
  );

  -- Seed development data
  INSERT INTO users (email, name) VALUES
    ('admin@example.com', 'Admin User'),
    ('developer@example.com', 'Dev User')
  ON CONFLICT (email) DO NOTHING;
  ```

  **Helper Scripts in package.json:**

  ```json
  {
    "scripts": {
      "dev": "nodemon server.js",
      "docker:up": "docker-compose up -d",
      "docker:down": "docker-compose down",
      "docker:logs": "docker-compose logs -f app",
      "docker:restart": "docker-compose restart app",
      "docker:shell": "docker-compose exec app sh",
      "docker:migrate": "docker-compose exec app npm run migrate",
      "docker:seed": "docker-compose exec app npm run seed",
      "docker:test": "docker-compose exec app npm test",
      "docker:clean": "docker-compose down -v && docker system prune -f"
    }
  }
  ```

  **Development Workflow:**

  ```bash
  # First time setup
  cp .env.example .env   # then populate .env with your local values
  docker-compose up -d
  docker-compose exec app npm run migrate
  docker-compose exec app npm run seed

  # Daily development
  docker-compose up  # Watch logs
  # OR
  docker-compose up -d && docker-compose logs -f app

  # Make code changes → auto-reload

  # Run tests
  docker-compose exec app npm test

  # Access database
  docker-compose exec postgres psql -U postgres -d myapp

  # Access Redis
  docker-compose exec redis redis-cli

  # Stop everything
  docker-compose down

  # Nuclear option (delete data)
  docker-compose down -v
  ```

  **.env.example (for local development):**

  ```bash
  # .env.example (commit this)
  # Copy to .env for local development: cp .env.example .env

  NODE_ENV=development

  # Database (matches docker-compose.yml)
  DB_HOST=postgres
  DB_PORT=5432
  DB_NAME=myapp
  DB_USER=postgres
  DB_PASSWORD=postgres

  # Redis
  REDIS_HOST=redis
  REDIS_PORT=6379

  # AWS (use your local credentials)
  AWS_ACCESS_KEY_ID=your_key_here
  AWS_SECRET_ACCESS_KEY=your_secret_here
  AWS_REGION=us-east-1

  # S3
  S3_BUCKET=myapp-dev-uploads

  # Optional: LocalStack for local AWS testing
  # AWS_ENDPOINT=http://localstack:4566
  ```

  **Using LocalStack (Optional - Local AWS):**

  ```yaml
  # Add to docker-compose.yml
  services:
    localstack:
      image: localstack/localstack:latest
      ports:
        - "4566:4566"
      environment:
        SERVICES: s3,ses,secretsmanager
        DEFAULT_REGION: us-east-1
      volumes:
        - localstack_data:/var/lib/localstack

  volumes:
    localstack_data:
  ```

  **Troubleshooting:**

  **Port already in use:**

  ```bash
  # Find what's using port 3000
  lsof -i :3000
  # Kill it
  kill -9 <PID>
  # Or change port in docker-compose.yml
  ports:
    - "3001:3000"
  ```

  **Database connection failed:**

  ```bash
  # Check if postgres is healthy
  docker-compose ps
  # View postgres logs
  docker-compose logs postgres
  # Recreate database
  docker-compose down postgres
  docker-compose up -d postgres
  ```

  **Volume permission errors:**

  ```bash
  # Match host and container user IDs
  # In Dockerfile:
  RUN groupadd -g $(id -g) appgroup && \
      useradd -u $(id -u) -g appgroup appuser
  ```

- **Acceptance Criteria:**
  - ✅ `docker-compose up` starts full stack
  - ✅ Application responds on localhost:3000
  - ✅ Database accessible and seeded
  - ✅ Redis working for sessions/cache
  - ✅ Code changes trigger hot reload
  - ✅ Tests pass in container
  - ✅ New developer can start in < 5 minutes
  - ✅ No secrets or credentials in `docker-compose.yml` — all injected via `env_file: .env`
  - ✅ `.env` is gitignored; `.env.example` is committed with placeholder values

---

## Additional Tips

**Multi-Service Monorepo:**

```yaml
# docker-compose.yml for monorepo
services:
  auth-api:
    build:
      context: ./services/auth-api
    ports:
      - "3001:3000"
    depends_on:
      - postgres

  user-api:
    build:
      context: ./services/user-api
    ports:
      - "3002:3000"
    depends_on:
      - postgres

  frontend:
    build:
      context: ./frontend
    ports:
      - "3000:3000"
    environment:
      AUTH_API_URL: http://auth-api:3000
      USER_API_URL: http://user-api:3000
```

**Debugging in Container:**

```bash
# Exec into running container
docker-compose exec app sh

# Run commands
npm run migrate
npm test
env | grep DB  # Check environment

# Debug with Node inspector
# In docker-compose.yml:
command: node --inspect=0.0.0.0:9229 server.js
ports:
  - "9229:9229"

# Connect from VS Code or Chrome DevTools
```

**Performance:**

```yaml
# Enable BuildKit for faster builds
COMPOSE_DOCKER_CLI_BUILD=1
DOCKER_BUILDKIT=1

# Use bind mounts for development speed
# Use named volumes for database persistence
volumes:
  - .:/app:delegated  # Better performance on Mac/Windows
```

---

## Rollback Plan

- **Slow container startup:** Use Dockerfile.dev with faster base image
- **Database won't start:** Check docker-compose logs, verify healthcheck
- **Hot reload not working:** Check volume mounts, restart container
- **Out of disk space:** `docker system prune -a --volumes -f`

---

## Next Steps

After local development is working:

1. Add developers to team
2. Document custom setup (if any)
3. Proceed to [Container Lifecycle](container-lifecycle.md)
