# Phase 4: Backing Services

**Goal:** Treat backing services (databases, caches, queues, email services) as attached resources accessed strictly via network environment variables, not local daemons (like local postfix).

## Context & Themes

Treat backing services (databases, caches, queues, email services) as attached resources accessed via environment variables. Decouple application deployment from infrastructure management.

**Business Value:** Enables flexible infrastructure changes without code redeployment. Switching from local sendmail to cloud email service, replacing cron with EventBridge, and separating workers from web servers improves reliability, scalability, and operational efficiency.

**Prerequisites:**

- [ ] [Observability](3-observability.md) completed

**Next Phase:** [Network & Security](5-network-and-security.md)

---

## Feature 4: Managed Backing Services

**Business Value:** Enables flexible infrastructure changes without code redeployment.

### Story 4.1: Replace Local Mail Agent with Cloud Email Service

- **Title:** Migrate from Sendmail to Cloud Email Provider
- **Persona:** As a **developer**, I need the application to send emails via an external service so that email delivery works without `sendmail` or `postfix` installed in the container.

**Business Value:** Automates credential management and improves security by eliminating hardcoded AWS keys and local mail agents. Cloud email services (SES, SendGrid) provide automatic temporary credentials via IAM task roles, preventing email failures from expired credentials and eliminating the security risk of keys in source code. This prevents SOC 2 audit findings around credential management and ensures email delivery works in ephemeral containers without sendmail/postfix dependencies.

- **Requirements:**
  - No reliance on local mail transfer agents (`sendmail`, `postfix`)
  - Email delivery via SMTP or API
  - Email credentials stored securely (not in code)
  - Delivery status trackable
  - Support for transactional and bulk email

- **Implementation Details:**

  **Step 1: Choose Email Provider**

  | Provider     | Type     | Pricing            | Features                     | Recommendation       |
  | ------------ | -------- | ------------------ | ---------------------------- | -------------------- |
  | **AWS SES**  | SMTP/API | $0.10/1K emails    | IAM integration, high volume | **Best for AWS**     |
  | **SendGrid** | SMTP/API | Free up to 100/day | Analytics, templates         | Good for startups    |
  | **Mailgun**  | SMTP/API | $0.80/1K emails    | Advanced routing             | Good for reliability |
  | **Postmark** | API      | $10/1K emails      | Focus on transactional       | Premium option       |

  **Step 2: Configure AWS SES (Recommended)**

  ```bash
  # Verify sender email/domain
  aws ses verify-email-identity --email-address noreply@example.com

  # Or verify entire domain (allows any email@example.com)
  aws ses verify-domain-identity --domain example.com

  # Check verification status
  aws ses get-identity-verification-attributes \
    --identities noreply@example.com

  # Move out of sandbox (required for production)
  # Request via AWS Console: SES → Account Dashboard → Request Production Access
  ```

  **Step 3: Update Application Code**

  **Option A: SMTP (works with any provider)**

  ```javascript
  // Node.js (nodemailer)
  const nodemailer = require("nodemailer");

  const transporter = nodemailer.createTransporter({
    host: process.env.SMTP_HOST, // email-smtp.us-east-1.amazonaws.com (SES)
    port: process.env.SMTP_PORT || 587, // or 465 for SSL
    secure: false, // true for 465, false for 587
    auth: {
      user: process.env.SMTP_USERNAME,
      pass: process.env.SMTP_PASSWORD,
    },
  });

  async function sendEmail() {
    await transporter.sendMail({
      from: "noreply@example.com",
      to: "customer@example.com",
      subject: "Order Confirmation",
      text: "Your order #12345 has been confirmed.",
      html: "<p>Your order <strong>#12345</strong> has been confirmed.</p>",
    });
  }
  ```

  ```python
  # Python
  import smtplib
  from email.mime.text import MIMEText
  import os

  def send_email():
      msg = MIMEText('Your order #12345 has been confirmed.')
      msg['Subject'] = 'Order Confirmation'
      msg['From'] = 'noreply@example.com'
      msg['To'] = 'customer@example.com'

      with smtplib.SMTP(os.environ['SMTP_HOST'], 587) as server:
          server.starttls()
          server.login(os.environ['SMTP_USERNAME'], os.environ['SMTP_PASSWORD'])
          server.send_message(msg)
  ```

  **Option B: AWS SES API (better for AWS environments)**

  ```javascript
  // Node.js
  const { SESClient, SendEmailCommand } = require("@aws-sdk/client-ses");

  const ses = new SESClient({ region: process.env.AWS_REGION });

  async function sendEmail() {
    const command = new SendEmailCommand({
      Source: "noreply@example.com",
      Destination: { ToAddresses: ["customer@example.com"] },
      Message: {
        Subject: { Data: "Order Confirmation" },
        Body: {
          Text: { Data: "Your order #12345 has been confirmed." },
          Html: {
            Data: "<p>Your order <strong>#12345</strong> has been confirmed.</p>",
          },
        },
      },
    });

    await ses.send(command);
  }
  ```

  **Benefits of API over SMTP:**
  - No SMTP credentials needed (uses IAM task role)
  - Automatic credential rotation
  - Better error handling
  - Direct access to SES features (reputation dashboard, etc.)

  **Step 4: Configure Environment Variables**

  ```bash
  # For SMTP
  SMTP_HOST=email-smtp.us-east-1.amazonaws.com
  SMTP_PORT=587
  SMTP_USERNAME=AKIA...  # From SES SMTP credentials
  SMTP_PASSWORD=BPaB...  # From SES SMTP credentials

  # For SES API
  AWS_REGION=us-east-1
  # No credentials needed - uses IAM task role
  ```

  **Step 5: Add IAM Permissions (for SES API approach)**

  ECS Task Role:

  ```json
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": ["ses:SendEmail", "ses:SendRawEmail"],
        "Resource": "*"
      }
    ]
  }
  ```

  **Step 6: Track Delivery Status**

  ```bash
  # Configure SES to publish bounce/complaint notifications to SNS
  aws ses set-identity-notification-topic \
    --identity example.com \
    --notification-type Bounce \
    --sns-topic arn:aws:sns:us-east-1:123456789012:ses-bounces

  aws ses set-identity-notification-topic \
    --identity example.com \
    --notification-type Complaint \
    --sns-topic arn:aws:sns:us-east-1:123456789012:ses-complaints
  ```

  **Step 7: Remove Old Dependencies**

  ```dockerfile
  # Remove from Dockerfile (if present)
  # RUN apt-get install -y sendmail postfix  # Delete this
  ```

  ```bash
  # Remove from EC2
  sudo systemctl stop sendmail
  sudo systemctl disable sendmail
  ```

- **Acceptance Criteria:**
  - ✅ Application sends email successfully without sendmail/postfix
  - ✅ Test email delivered to inbox (not spam)
  - ✅ Bounce notifications received in SNS topic
  - ✅ Email delivery logs visible in SES dashboard
  - ✅ No `sendmail` binary required in Docker image
  - ✅ SMTP credentials or IAM role configured correctly
  - ✅ Production access granted (if using SES)
  - ✅ Email sending tested from Fargate task

- **EC2 Testing:**
  - Deploy SES integration to EC2 first
  - Send test emails and verify delivery
  - Test bounce and complaint handling
  - Verify IAM role-based access works (if using API approach)

---

## Story 2: Replace Local Crontab with AWS EventBridge Scheduler

- **Title:** Migrate Cron Jobs to EventBridge Scheduler
- **Persona:** As a **system administrator**, I need scheduled tasks to run exactly once at the specified time so that batch jobs (reports, cleanup, notifications) execute reliably without duplication across multiple tasks.

**Business Value:** Provides reliable, auditable scheduled task execution with built-in monitoring and retry logic. EventBridge tracks every execution (success/failure) in CloudWatch, eliminating "did the nightly batch run?" uncertainty. Automatic retries on failure prevent midnight pages for transient issues. One company reduced cron-related incidents from 3-4/month to 0 after migrating to EventBridge, saving 10+ hours of on-call time monthly.

- **Requirements:**
  - No `crontab` entries inside Docker container
  - Scheduled jobs must run exactly once, regardless of task count
  - Job execution must be logged and auditable
  - Failed jobs must be retryable
  - Support for different schedule patterns (cron, rate)

- **Implementation Details:**

  **Step 1: Inventory Current Cron Jobs**

  ```bash
  # On EC2
  crontab -l

  # Example output:
  # 0 2 * * * /usr/bin/php /var/www/app/artisan report:daily
  # */15 * * * * /usr/bin/node /var/www/app/cleanup.js
  # 0 0 * * 0 /usr/bin/python /var/www/app/weekly-summary.py
  ```

  **Step 2: Create Separate Task Definition for Each Job**

  **Option A: Dedicated task definition per job**

  ```json
  // task-definition-daily-report.json
  {
    "family": "daily-report",
    "cpu": "256",
    "memory": "512",
    "containerDefinitions": [
      {
        "name": "app",
        "image": "123456789012.dkr.ecr.us-east-1.amazonaws.com/my-app:latest",
        "command": ["php", "artisan", "report:daily"],
        "logConfiguration": {
          "logDriver": "awslogs",
          "options": {
            "awslogs-group": "/ecs/daily-report",
            "awslogs-region": "us-east-1",
            "awslogs-stream-prefix": "ecs"
          }
        }
      }
    ]
  }
  ```

  **Option B: Single worker task definition with command override**

  ```json
  // task-definition-worker.json
  {
    "family": "worker",
    "cpu": "256",
    "memory": "512",
    "containerDefinitions": [
      {
        "name": "app",
        "image": "123456789012.dkr.ecr.us-east-1.amazonaws.com/my-app:latest",
        "command": ["echo", "Override this in EventBridge"],
        "logConfiguration": {
          "logDriver": "awslogs",
          "options": {
            "awslogs-group": "/ecs/worker",
            "awslogs-region": "us-east-1",
            "awslogs-stream-prefix": "ecs"
          }
        }
      }
    ]
  }
  ```

  **Step 3: Create EventBridge Scheduler Rules**

  ```bash
  # Daily report at 2 AM
  aws scheduler create-schedule \
    --name daily-report \
    --schedule-expression "cron(0 2 * * ? *)" \
    --target '{
      "Arn": "arn:aws:ecs:us-east-1:123456789012:cluster/my-cluster",
      "RoleArn": "arn:aws:iam::123456789012:role/EventBridgeECSRole",
      "EcsParameters": {
        "TaskDefinitionArn": "arn:aws:ecs:us-east-1:123456789012:task-definition/daily-report:1",
        "LaunchType": "FARGATE",
        "NetworkConfiguration": {
          "awsvpcConfiguration": {
            "Subnets": ["subnet-abc123"],
            "SecurityGroups": ["sg-abc123"],
            "AssignPublicIp": "DISABLED"
          }
        }
      },
      "RetryPolicy": {
        "MaximumRetryAttempts": 2,
        "MaximumEventAge": 3600
      }
    }' \
    --flexible-time-window '{"Mode": "OFF"}'

  # Cleanup every 15 minutes
  aws scheduler create-schedule \
    --name cleanup-every-15min \
    --schedule-expression "rate(15 minutes)" \
    --target '{
      "Arn": "arn:aws:ecs:us-east-1:123456789012:cluster/my-cluster",
      "RoleArn": "arn:aws:iam::123456789012:role/EventBridgeECSRole",
      "EcsParameters": {
        "TaskDefinitionArn": "arn:aws:ecs:us-east-1:123456789012:task-definition/worker:1",
        "TaskCount": 1,
        "LaunchType": "FARGATE",
        "NetworkConfiguration": {
          "awsvpcConfiguration": {
            "Subnets": ["subnet-abc123"],
            "SecurityGroups": ["sg-abc123"]
          }
        },
        "Overrides": {
          "ContainerOverrides": [{
            "Name": "app",
            "Command": ["node", "cleanup.js"]
          }]
        }
      }
    }' \
    --flexible-time-window '{"Mode": "OFF"}'
  ```

  **Step 4: Create IAM Role for EventBridge**

  ```json
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": "ecs:RunTask",
        "Resource": [
          "arn:aws:ecs:us-east-1:123456789012:task-definition/daily-report:*",
          "arn:aws:ecs:us-east-1:123456789012:task-definition/worker:*"
        ]
      },
      {
        "Effect": "Allow",
        "Action": "iam:PassRole",
        "Resource": [
          "arn:aws:iam::123456789012:role/ecsTaskRole",
          "arn:aws:iam::123456789012:role/ecsTaskExecutionRole"
        ]
      }
    ]
  }
  ```

  **Step 5: Monitor Job Execution**

  ```bash
  # Check recent executions
  aws ecs list-tasks --cluster my-cluster --family daily-report

  # View task logs in CloudWatch
  aws logs tail /ecs/daily-report --follow

  # Create CloudWatch Alarm for failed tasks
  aws cloudwatch put-metric-alarm \
    --alarm-name daily-report-failures \
    --metric-name TasksFailed \
    --namespace AWS/ECS \
    --statistic Sum \
    --period 3600 \
    --evaluation-periods 1 \
    --threshold 1 \
    --comparison-operator GreaterThanThreshold \
    --dimensions Name=ClusterName,Value=my-cluster Name=ServiceName,Value=daily-report
  ```

  **Step 6: Handle Timezone Correctly**

  EventBridge uses UTC. Convert local time to UTC:

  ```bash
  # Original cron: 2 AM Eastern Time (EST/EDT)
  # EST: UTC-5, EDT: UTC-4
  # During EST (Nov-Mar): 2 AM EST = 7 AM UTC
  # During EDT (Mar-Nov): 2 AM EDT = 6 AM UTC

  # Solution: Use 7 AM UTC and document the behavior
  # cron(0 7 * * ? *)

  # Or handle timezone in application code
  ```

- **Acceptance Criteria:**
  - ✅ Scheduled jobs run at expected times (verified in CloudWatch Logs)
  - ✅ Scaling web service to 5 tasks does NOT cause 5x job execution
  - ✅ Job execution visible in ECS Task history
  - ✅ Failed jobs trigger CloudWatch Alarm
  - ✅ Job execution logs searchable in CloudWatch Logs
  - ✅ EventBridge Scheduler dashboard shows all scheduled tasks
  - ✅ Retry logic configured for transient failures
  - ✅ Old crontab entries removed from EC2 and Dockerfile

- **EC2 Testing:**
  - Keep cron jobs running on EC2 during transition
  - Run EventBridge + ECS task executions in parallel
  - Verify outputs match between cron and EventBridge approaches
  - Once validated, disable EC2 cron jobs

---

## Story 3: Deploy Queue Workers as Dedicated ECS Service

**Business Value:** Enables independent scaling of background job processing, preventing web request performance degradation during heavy batch jobs. Separating workers from web servers (1-2 days) allows scaling workers to 10 instances during nightly reports while keeping web servers at 3 instances, optimizing costs and performance. Prevents scenarios where background jobs consume all CPU/memory, causing web requests to time out and customer complaints.

- **Title:** Separate Background Workers from Web Process
- **Persona:** As a **developer**, I need background job workers (Sidekiq, Celery, Bull) to run as a separate service so that queue processing is decoupled from web request handling and can scale independently.

- **Requirements:**
  - Queue workers must not run inside the web container
  - Workers must be independently scalable
  - Workers must connect to same queue backend (Redis, SQS)
  - Worker scaling must be based on queue depth
  - Failed jobs must be retryable

- **Implementation Details:**

  **Step 1: Separate Worker Code from Web Code**

  **Shared Docker Image Approach (Recommended):**

  ```dockerfile
  # Same Dockerfile for web and worker
  FROM node:20-slim

  WORKDIR /app
  COPY package*.json ./
  RUN npm ci --production
  COPY . .

  # Default: web server
  CMD ["node", "server.js"]

  # Worker will override with: ["node", "worker.js"]
  ```

  **Step 2: Create Worker Task Definition**

  ```json
  {
    "family": "my-app-worker",
    "cpu": "256",
    "memory": "512",
    "containerDefinitions": [
      {
        "name": "worker",
        "image": "123456789012.dkr.ecr.us-east-1.amazonaws.com/my-app:latest",
        "command": ["node", "worker.js"], // Override default CMD
        "environment": [
          { "name": "NODE_ENV", "value": "production" },
          { "name": "WORKER_CONCURRENCY", "value": "5" }
        ],
        "secrets": [
          {
            "name": "REDIS_HOST",
            "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789012:secret:redis-host"
          }
        ],
        "logConfiguration": {
          "logDriver": "awslogs",
          "options": {
            "awslogs-group": "/ecs/my-app-worker",
            "awslogs-region": "us-east-1",
            "awslogs-stream-prefix": "worker"
          }
        }
      }
    ]
  }
  ```

  **Step 3: Implement Worker Code**

  **Node.js (Bull/BullMQ):**

  ```javascript
  // worker.js
  const { Worker } = require("bullmq");

  const worker = new Worker(
    "email-queue",
    async (job) => {
      console.log(`Processing job ${job.id}`);
      await sendEmail(job.data.to, job.data.subject, job.data.body);
      return { success: true };
    },
    {
      connection: {
        host: process.env.REDIS_HOST,
        port: process.env.REDIS_PORT,
      },
      concurrency: parseInt(process.env.WORKER_CONCURRENCY || "5"),
    },
  );

  worker.on("completed", (job) => {
    console.log(`Job ${job.id} completed`);
  });

  worker.on("failed", (job, err) => {
    console.error(`Job ${job.id} failed:`, err);
  });

  // Graceful shutdown
  process.on("SIGTERM", async () => {
    console.log("SIGTERM received, closing worker...");
    await worker.close();
    process.exit(0);
  });
  ```

  **Python (Celery):**

  ```python
  # worker.py
  from celery import Celery
  import os

  app = Celery('tasks',
      broker=f"redis://{os.environ['REDIS_HOST']}:6379/0",
      backend=f"redis://{os.environ['REDIS_HOST']}:6379/0")

  @app.task
  def send_email(to, subject, body):
      print(f"Sending email to {to}")
      # Send email logic
      return {"success": True}

  if __name__ == '__main__':
      app.worker_main(['worker', '--loglevel=info', '--concurrency=5'])
  ```

  **Step 4: Create Worker ECS Service**

  ```bash
  aws ecs create-service \
    --cluster my-cluster \
    --service-name my-app-worker \
    --task-definition my-app-worker:1 \
    --desired-count 2 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={
      subnets=[subnet-abc123],
      securityGroups=[sg-abc123],
      assignPublicIp=DISABLED
    }"
  ```

  **Step 5: Configure Auto-Scaling Based on Queue Depth**

  ```bash
  # Register scalable target
  aws application-autoscaling register-scalable-target \
    --service-namespace ecs \
    --resource-id service/my-cluster/my-app-worker \
    --scalable-dimension ecs:service:DesiredCount \
    --min-capacity 1 \
    --max-capacity 10

  # Create scaling policy based on custom metric (queue depth)
  aws application-autoscaling put-scaling-policy \
    --service-namespace ecs \
    --resource-id service/my-cluster/my-app-worker \
    --scalable-dimension ecs:service:DesiredCount \
    --policy-name scale-on-queue-depth \
    --policy-type TargetTrackingScaling \
    --target-tracking-scaling-policy-configuration '{
      "TargetValue": 100.0,
      "CustomizedMetricSpecification": {
        "MetricName": "QueueDepth",
        "Namespace": "MyApp",
        "Statistic": "Average"
      },
      "ScaleInCooldown": 300,
      "ScaleOutCooldown": 60
    }'
  ```

  **Step 6: Publish Queue Depth Metric**

  ```javascript
  // In web application (when jobs are enqueued)
  const {
    CloudWatchClient,
    PutMetricDataCommand,
  } = require("@aws-sdk/client-cloudwatch");

  const cloudwatch = new CloudWatchClient({ region: process.env.AWS_REGION });

  async function publishQueueDepth() {
    const queueLength = await getQueueLength(); // Get from Redis/SQS

    await cloudwatch.send(
      new PutMetricDataCommand({
        Namespace: "MyApp",
        MetricData: [
          {
            MetricName: "QueueDepth",
            Value: queueLength,
            Unit: "Count",
            Timestamp: new Date(),
          },
        ],
      }),
    );
  }

  // Publish every 60 seconds
  setInterval(publishQueueDepth, 60000);
  ```

- **Acceptance Criteria:**
  - ✅ Web service and worker service run as separate ECS Services
  - ✅ Stopping web service does not stop job processing
  - ✅ Worker service can scale independently of web service
  - ✅ Jobs enqueued by web service are processed by worker service
  - ✅ Worker auto-scaling triggers when queue depth exceeds threshold
  - ✅ Failed jobs are retried with exponential backoff
  - ✅ Worker logs visible in CloudWatch Logs
  - ✅ Queue depth metric published to CloudWatch

- **EC2 Testing:**
  - Run worker process separately on EC2 (separate systemd service or PM2 process)
  - Verify jobs are processed independently
  - Test scaling workers without affecting web process
  - Validate job failure and retry behavior

---

## Phase Completion Checklist

Before proceeding to [Network & Security](5-network-and-security.md) phase:

- [ ] Email sending migrated to cloud provider (SES/SendGrid)
- [ ] No sendmail/postfix dependencies in Docker image
- [ ] Email delivery tracking configured
- [ ] Cron jobs migrated to EventBridge Scheduler
- [ ] EventBridge rules created for all scheduled tasks
- [ ] Old crontab entries removed
- [ ] Workers separated from web process
- [ ] Worker auto-scaling configured based on queue depth
- [ ] All backing services tested on EC2 first

---

## Rollback Plan

If issues are discovered after deployment:

1. **Email delivery failures:** Revert to SMTP if SES API fails, check IAM permissions, verify domain verification
2. **Missed scheduled jobs:** Re-enable EC2 cron jobs temporarily, check EventBridge rule status and IAM role
3. **Worker processing issues:** Scale workers manually, check queue connectivity, verify worker code handles job format
4. **Queue depth metric issues:** Manually scale workers, verify CloudWatch metric publishing
