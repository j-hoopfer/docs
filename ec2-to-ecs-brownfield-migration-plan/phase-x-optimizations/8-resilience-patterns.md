# Circuit Breaker and Retry Strategies for Inter-Service Calls

### Goal

Prevent cascading failures by implementing resilience patterns (Circuit Breakers using `polly` or similar libraries) in application code.

### Context

In a distributed system, one failing service can exhaust resources in dependent services if requests are retried indefinitely. Circuit breakers fail fast to protect the system.

## Status

**Out of Scope** - Application-level resilience patterns

## Why This Matters

When Service A calls Service B, transient failures will occur (network blips, Service B overloaded, etc.). Without retry logic and circuit breakers, cascading failures can bring down the entire system.

## What's Missing

### 3.1 Circuit Breaker Pattern

**Current State:**

- Applications make HTTP calls to other services
- No circuit breaker logic (services retry indefinitely or fail immediately)

**Gaps:**

- [ ] **No protection against cascading failures**
- [ ] **Unhealthy services continue receiving traffic** (making them worse)
- [ ] **No graceful degradation** when dependencies fail

**Recommendations:**

### Circuit Breaker Implementation

**Pattern Overview:**

```
States:
CLOSED → Normal operation, requests pass through
OPEN → Too many failures, requests fail immediately (don't call service)
HALF-OPEN → Testing if service recovered, allow limited requests

Transitions:
CLOSED → OPEN: After X failures in Y seconds
OPEN → HALF-OPEN: After Z seconds (cooldown period)
HALF-OPEN → CLOSED: If test requests succeed
HALF-OPEN → OPEN: If test requests fail
```

**Node.js Implementation (using opossum):**

```javascript
const CircuitBreaker = require("opossum");

// Wrap HTTP client
const options = {
  timeout: 3000, // If function takes >3s, trigger failure
  errorThresholdPercentage: 50, // Open circuit if >50% fail
  resetTimeout: 30000, // Try again after 30 seconds
  volumeThreshold: 10, // Need at least 10 requests before calculating error rate
};

const breaker = new CircuitBreaker(callUserService, options);

// Fallback when circuit is open
breaker.fallback(() => {
  console.log("Circuit open, using cached data");
  return getCachedUserData();
});

// Events
breaker.on("open", () =>
  console.log("Circuit opened - user-service unhealthy"),
);
breaker.on("halfOpen", () =>
  console.log("Circuit half-open - testing user-service"),
);
breaker.on("close", () => console.log("Circuit closed - user-service healthy"));

// Usage
async function getUserProfile(userId) {
  try {
    return await breaker.fire(userId);
  } catch (err) {
    console.error("Failed to get user profile", err);
    return null; // Or default value
  }
}
```

**Priority:** High (for production resilience)  
**Estimated Effort:** 2-3 days per application  
**Owner:** Application Development Team

---

### 3.2 Retry Strategy with Exponential Backoff

**Current State:**

- HTTP clients may retry with default settings (often immediate retry)
- No jitter, no backoff

**Gaps:**

- [ ] **No exponential backoff** (retries at same rate, overwhelming failing service)
- [ ] **No jitter** (all clients retry at same time, thundering herd)
- [ ] **No distinction** between retryable errors (503) vs non-retryable (404)

**Recommendations:**

### Retry Strategy

**Retryable vs Non-Retryable Errors:**
| Error | Retry? | Reason |
|-------|--------|--------|
| 500 Internal Server Error | Yes | Transient server issue |
| 502 Bad Gateway | Yes | Service temporarily down |
| 503 Service Unavailable | Yes | Service overloaded |
| 504 Gateway Timeout | Yes | Request took too long |
| 429 Too Many Requests | Yes (with backoff) | Rate limited |
| 408 Request Timeout | Yes | Network issue |
| 404 Not Found | No | Resource doesn't exist |
| 401 Unauthorized | No | Bad credentials |
| 400 Bad Request | No | Client error |

**Exponential Backoff with Jitter:**

```
Attempt 1: Wait 0s (immediate)
Attempt 2: Wait 1s + jitter(0-1s) = 1-2s
Attempt 3: Wait 2s + jitter(0-2s) = 2-4s
Attempt 4: Wait 4s + jitter(0-4s) = 4-8s
Max retries: 3-5
```

**Node.js Implementation (using axios-retry):**

```javascript
const axios = require("axios");
const axiosRetry = require("axios-retry");

axiosRetry(axios, {
  retries: 3,
  retryDelay: axiosRetry.exponentialDelay, // 1s, 2s, 4s
  retryCondition: (error) => {
    // Retry on network errors or 5xx responses
    return (
      axiosRetry.isNetworkOrIdempotentRequestError(error) ||
      error.response?.status >= 500
    );
  },
  onRetry: (retryCount, error, requestConfig) => {
    console.log(`Retry attempt ${retryCount} for ${requestConfig.url}`);
  },
});

// Usage
try {
  const response = await axios.get("http://user-api.internal/users/123");
  return response.data;
} catch (error) {
  console.error("Failed after retries", error);
  throw error;
}
```

**Priority:** High (for production resilience)  
**Estimated Effort:** 1-2 days per application  
**Owner:** Application Development Team

---

### 3.3 Timeout Configuration

**Current State:**

- HTTP client timeouts may be using defaults (often 60+ seconds)

**Gaps:**

- [ ] **No consistent timeout strategy** across services
- [ ] **Timeouts too long** (user waits forever for error)
- [ ] **No distinction** between connection timeout vs read timeout

**Recommendations:**

### Timeout Strategy

**Timeout Types:**
| Timeout | Purpose | Recommended Value |
|---------|---------|-------------------|
| Connection Timeout | Time to establish TCP connection | 2-5 seconds |
| Read Timeout | Time to receive response after connection | 5-30 seconds |
| Overall Request Timeout | Total time for entire request | 10-60 seconds |

**Priority:** Medium-High  
**Estimated Effort:** 1 day per application  
**Owner:** Application Development Team

---

### 3.4 Bulkhead Pattern (Optional)

**Recommendations:**

### Bulkhead Pattern

**Concept:**
Isolate resources to prevent one failing dependency from exhausting all resources.

**Example:**
Instead of 1 shared connection pool for all services:

- User Service: 10 connections
- Auth Service: 5 connections
- Notification Service: 3 connections

If Notification Service is slow/down, it only consumes its 3 connections, not all 18.

**Priority:** Low (nice-to-have)  
**Estimated Effort:** 2-3 days  
**Owner:** Application Development Team
