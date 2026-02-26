# Distributed Tracing (Day 2 Optimization)

**Category:** Observability
**Recommendation:** Defer until after initial migration is stable. Request ID propagation in logs is sufficient for most debugging scenarios during Day 1.

**Business Value:** Enables tracking requests across multiple services and containers, critical for debugging distributed systems. When a customer reports "checkout is slow," distributed tracing shows exactly which step is slow (payment API 3s, database query 500ms, etc.). This reduces troubleshooting time from hours to minutes. Most valuable for microservices architectures; less critical for monolithic apps.

---

## Story: Add Request ID Propagation for Distributed Tracing

- **Title:** Implement Distributed Tracing
- **Persona:** As a **developer**, I need to track requests across multiple services so that I can debug issues that span multiple containers/services.

- **Requirements:**
  - Every request generates or receives a unique request ID
  - Request ID is included in all log entries
  - Request ID is propagated to downstream services
  - Request ID is returned in response headers

- **Implementation Details:**

  **Step 1: Generate/Extract Request ID**

  ```javascript
  const { v4: uuidv4 } = require("uuid");

  app.use((req, res, next) => {
    // Use existing request ID or generate new one
    req.id =
      req.headers["x-request-id"] || req.headers["x-amzn-trace-id"] || uuidv4();

    // Add to response headers
    res.setHeader("X-Request-ID", req.id);

    next();
  });
  ```

  **Step 2: Include in Logs**

  ```javascript
  // Add request ID to logger context
  const logger = winston.createLogger({
    format: winston.format.combine(
      winston.format.timestamp(),
      winston.format.printf(
        (info) =>
          `${info.timestamp} ${info.level}: [${info.requestId || "N/A"}] ${
            info.message
          }`,
      ),
    ),
    transports: [new winston.transports.Console()],
  });

  app.use((req, res, next) => {
    req.logger = logger.child({ requestId: req.id });
    next();
  });

  // Usage
  app.get("/api/users", (req, res) => {
    req.logger.info("Fetching users");
    // Log will include request ID
  });
  ```

  **Step 3: Propagate to Downstream Services**

  ```javascript
  const axios = require("axios");

  app.get("/api/orders", async (req, res) => {
    // Forward request ID to downstream service
    const response = await axios.get("http://inventory-service/api/stock", {
      headers: {
        "X-Request-ID": req.id,
      },
    });

    res.json(response.data);
  });
  ```

  **Step 4: AWS X-Ray Integration (Optional)**

  For deeper tracing with AWS X-Ray:

  ```javascript
  const AWSXRay = require("aws-xray-sdk-core");
  const app = express();

  // Capture all AWS SDK calls
  const AWS = AWSXRay.captureAWS(require("aws-sdk"));

  // Capture HTTP requests
  app.use(AWSXRay.express.openSegment("my-app"));

  app.get("/api/users", async (req, res) => {
    const subsegment = AWSXRay.getSegment().addNewSubsegment("database-query");
    const users = await db.query("SELECT * FROM users");
    subsegment.close();

    res.json(users);
  });

  app.use(AWSXRay.express.closeSegment());
  ```

- **Acceptance Criteria:**
  - ✅ Every request has a unique request ID
  - ✅ Request ID included in all log entries for that request
  - ✅ Request ID propagated to downstream services
  - ✅ Request ID returned in response headers
  - ✅ Can search CloudWatch Logs by request ID to see full request lifecycle
  - ✅ X-Ray integration configured (if using)
