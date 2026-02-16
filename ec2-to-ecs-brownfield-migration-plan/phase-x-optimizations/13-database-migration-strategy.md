# Zero-Downtime Database Migration Strategy

### Goal

Decouple application code deployments from database schema changes (using "expand and contract" patterns) to allow safe schema evolution without downtime.

### Context

Unlike application updates, database schema changes are risky and hard to roll back. Using compatible schema evolution is critical for true zero-downtime releases.

## Status

**Out of Scope** - Database schema evolution during migration

## Why This Matters

If you need to make **breaking schema changes** during the migration (add/remove columns, change data types, refactor tables), you need a strategy to keep both EC2 and Fargate apps working against the same database.

## What's Missing

### 8.1 Schema Changes During Migration

**Current State:**

- EC2 and Fargate both connect to the same RDS instance
- Schema must be compatible with both versions

**Gaps:**

- [ ] **No strategy for incompatible schema changes**
- [ ] **No rollback plan for failed migrations**
- [ ] **No testing of schema changes under load**

**Recommendations:**

### Zero-Downtime Schema Migration Patterns

**Pattern 1: Expand-Contract (Multi-Phase Migration)**

**Phase 1 - Expand (Add New Schema):**

```sql
-- Old schema has: users.name (VARCHAR)
-- New schema needs: users.first_name, users.last_name

-- Step 1: Add new columns (nullable)
ALTER TABLE users ADD COLUMN first_name VARCHAR(255);
ALTER TABLE users ADD COLUMN last_name VARCHAR(255);

-- Step 2: Backfill new columns from old column
UPDATE users SET
first_name = SPLIT_PART(name, ' ', 1),
last_name = SPLIT_PART(name, ' ', 2)
WHERE first_name IS NULL;

-- Step 3: Add trigger to keep both in sync during migration
CREATE TRIGGER sync_user_names
BEFORE INSERT OR UPDATE ON users
FOR EACH ROW
EXECUTE FUNCTION sync_name_fields();
```

**Pattern 2: Feature Flags for Schema Changes**

```javascript
// Application code checks which schema to use
if (process.env.USE_NEW_SCHEMA === "true") {
  // Use first_name, last_name
} else {
  // Use name
}
```

**Priority:** Medium-High (if schema changes needed), N/A (if schema stable)  
**Estimated Effort:** Variable (depends on complexity)  
**Owner:** Database Team + Application Team

---

### 8.2 Large Table Migrations (Millions of Rows)

**Recommendations:**

### Strategies for Large Tables

**Solution 1: pt-online-schema-change (Percona Toolkit)**

```bash
# Non-blocking ALTER for MySQL/MariaDB
pt-online-schema-change \
 --alter "ADD COLUMN first_name VARCHAR(255)" \
 D=mydb,t=users \
 --execute
```

**Solution 2: Batched Updates (PostgreSQL)**

```sql
-- Instead of:
UPDATE users SET first_name = SPLIT_PART(name, ' ', 1); -- Locks entire table

-- Do:
DO $$
DECLARE
batch_size INT := 10000;
BEGIN
LOOP
-- Update in batches
END LOOP;
END $$;
```

**Priority:** High (if large tables need migration), N/A (if small tables)  
**Estimated Effort:** 3-7 days (planning + execution + validation)  
**Owner:** Database Team
