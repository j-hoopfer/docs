# Phase 2: Container Lifecycle

**Goal:** Ensure the container handles OS signals (SIGTERM) correctly to allow for zero-downtime deployments and graceful shutdowns.

## Context & Themes

Implement proper process management and graceful shutdown handling for containerized applications.

**Prerequisites:**

- [ ] [Docker Packaging](docker-packaging.md) completed

**Next Phase:**

- [Optimization](optimization.md)

---

## Feature 3: Container Lifecycle Management

**Business Value:** Prevents container instability and ensures graceful shutdowns work correctly.

### Story 3.1: Configure PID 1 and Signal Handling

- **Title:** Implement Init Process for Proper Signal Handling
- **Persona:** As a **developer**, I need the container to properly handle signals and reap zombie processes so that graceful shutdown works and containers don't accumulate zombies.

**Business Value:** Prevents container instability and ensures graceful shutdowns work correctly. Containers without proper PID 1 handling accumulate zombie processes over time and fail to shut down gracefully, causing dropped requests during deployments. This 30-minute fix prevents production incidents where containers become unresponsive after 24-48 hours uptime.

- **Requirements:**
  - Container handles SIGTERM for graceful shutdown
  - Reaps zombie child processes
  - Application doesn't run as PID 1 (unless it handles signals natively)

- **Implementation Details:**

  **The Problem:**
  - PID 1 has special responsibilities:
    1. Forward SIGTERM to child processes
    2. Reap zombie (defunct) child processes
  - Most runtimes (Node.js, Python, Java) don't handle this
  - Without proper init:
    - App doesn't shut down gracefully (30s timeout → SIGKILL)
    - Zombie processes accumulate
    - Container becomes unstable

  **Solution: Use tini**

  ```dockerfile
  FROM node:20-slim

  # Install tini
  RUN apt-get update && apt-get install -y tini && rm -rf /var/lib/apt/lists/*

  WORKDIR /app
  COPY package*.json ./
  RUN npm ci --production
  COPY . .

  EXPOSE 3000

  # Use tini as PID 1
  ENTRYPOINT ["/usr/bin/tini", "--"]
  CMD ["node", "server.js"]
  ```

  **For Alpine:**

  ```dockerfile
  FROM node:20-alpine
  RUN apk add --no-cache tini
  ENTRYPOINT ["/sbin/tini", "--"]
  CMD ["node", "server.js"]
  ```

  **Alternative: ECS initProcessEnabled**

  ```json
  {
    "family": "my-app",
    "containerDefinitions": [
      {
        "name": "app",
        "linuxParameters": {
          "initProcessEnabled": true
        }
      }
    ]
  }
  ```

  **Verify Signal Forwarding:**

  ```bash
  # Run container
  docker run -d --name test-app my-app

  # Send SIGTERM
  time docker stop test-app

  # Should stop within 5-10 seconds
  # If takes 30 seconds, signal forwarding broken
  ```

  **Verify Zombie Reaping:**

  ```bash
  # Exec into container
  docker exec test-app ps aux

  # Should NOT see defunct processes:
  # node  123  0.0  0.0  0  0  ?  Z  14:23  0:00 [node] <defunct>
  ```

  **Runtime-Specific Recommendations:**

  | Runtime | Native Handling?  | Recommendation                  |
  | ------- | ----------------- | ------------------------------- |
  | Node.js | ❌ No             | **Use tini/initProcessEnabled** |
  | Python  | ❌ No             | **Use tini/initProcessEnabled** |
  | Java    | ⚠️ Partial        | **Use tini/initProcessEnabled** |
  | Go      | ✅ Yes (if coded) | Optional (adds safety)          |
  | Nginx   | ✅ Yes            | No init needed                  |

- **Acceptance Criteria:**
  - ✅ tini or initProcessEnabled configured
  - ✅ Container stops gracefully within 10 seconds
  - ✅ No zombie processes after 24-hour run
  - ✅ Application logs show graceful shutdown message
  - ✅ Load test shows no zombie accumulation

---

## Story 2: Implement Graceful Shutdown

- **Title:** Handle SIGTERM for Zero-Downtime Deployments
- **Persona:** As a **user**, I need requests to complete before container shutdown so that transactions aren't interrupted during deployments.

**Business Value:** Eliminates customer-facing 502 errors during deployments. Without graceful shutdown, deployments drop active requests (user sees error mid-transaction). Implementing SIGTERM handling (1-2 days) reduces deployment-related customer errors from 10-50 per deployment to 0, protecting user experience during rolling updates.

- **Requirements:**
  - Application listens for SIGTERM signal
  - On SIGTERM, stops accepting new connections
  - Drains existing requests (completes in-flight work)
  - Exits cleanly before SIGKILL timeout (default 30s)

- **Implementation Details:**

  **Node.js (Express):**

  ```javascript
  const express = require("express");
  const app = express();

  const server = app.listen(3000, "0.0.0.0", () => {
    console.log("Server started on port 3000");
  });

  // Graceful shutdown handler
  process.on("SIGTERM", () => {
    console.log("SIGTERM received, starting graceful shutdown");

    // Stop accepting new connections
    server.close(() => {
      console.log("HTTP server closed");

      // Close database connections
      db.end(() => {
        console.log("Database connections closed");
        process.exit(0);
      });
    });

    // Force shutdown after 25 seconds (before Docker SIGKILL at 30s)
    setTimeout(() => {
      console.error("Graceful shutdown timeout, forcing exit");
      process.exit(1);
    }, 25000);
  });
  ```

  **Python (Flask + Gunicorn):**

  Gunicorn handles SIGTERM gracefully by default:

  ```python
  # Gunicorn config: gunicorn_config.py
  graceful_timeout = 25  # Seconds to wait for workers to finish requests
  timeout = 30           # Worker timeout

  # Start with: gunicorn -c gunicorn_config.py app:app
  ```

  **Manual handling (if needed):**

  ```python
  import signal
  import sys

  def graceful_shutdown(signum, frame):
      print("SIGTERM received, shutting down gracefully")

      # Close database connections
      db.close()

      # Close Redis connections
      redis_client.close()

      sys.exit(0)

  signal.signal(signal.SIGTERM, graceful_shutdown)
  ```

  **Go:**

  ```go
  package main

  import (
      "context"
      "net/http"
      "os"
      "os/signal"
      "syscall"
      "time"
  )

  func main() {
      srv := &http.Server{Addr: ":8080"}

      go func() {
          if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
              log.Fatal(err)
          }
      }()

      // Wait for interrupt signal
      quit := make(chan os.Signal, 1)
      signal.Notify(quit, syscall.SIGTERM, syscall.SIGINT)
      <-quit

      log.Println("Shutting down server...")

      // Graceful shutdown with 25s timeout
      ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
      defer cancel()

      if err := srv.Shutdown(ctx); err != nil {
          log.Fatal("Server forced to shutdown:", err)
      }

      log.Println("Server exited")
  }
  ```

  **Test Graceful Shutdown:**

  ```bash
  # Terminal 1: Run container
  docker run -p 3000:3000 my-app

  # Terminal 2: Make long request
  curl http://localhost:3000/slow-endpoint  # Takes 10s

  # Terminal 3: Send SIGTERM while request in progress
  docker stop my-app

  # Expected: Request completes successfully, then container stops
  # Bad: Request gets 502 error
  ```

  **Configure ECS Stop Timeout:**

  ```json
  {
    "family": "my-app",
    "containerDefinitions": [
      {
        "stopTimeout": 30 // Seconds before SIGKILL (default 30)
      }
    ]
  }
  ```

- **Acceptance Criteria:**
  - ✅ `docker stop` exits within 10 seconds (not 30s timeout)
  - ✅ In-flight requests complete successfully during shutdown
  - ✅ No SIGKILL in logs during normal deployments
  - ✅ Zero dropped requests during rolling deployment
  - ✅ Database connections closed cleanly
  - ✅ Application logs show "Graceful shutdown complete"

---

## Phase Completion Checklist

Before proceeding to [Optimization](optimization.md):

- [ ] tini or initProcessEnabled configured
- [ ] SIGTERM handler implemented
- [ ] Container stops gracefully within 10 seconds
- [ ] No zombie processes accumulate
- [ ] In-flight requests complete during shutdown
- [ ] Database connections close cleanly
- [ ] Tested with load and simulated deployments

---

## Rollback Plan

- **Graceful shutdown fails:** Increase stopTimeout, verify SIGTERM handler
- **Zombie processes appear:** Verify tini is PID 1, check process spawning
- **Timeout during shutdown:** Reduce graceful shutdown timeout, check for stuck connections
