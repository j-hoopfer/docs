# Enable Cost Guardrails

## Story 1.3: Enable Cost Guardrails

- **Title:** Configure AWS Cost Monitoring and Billing Alerts
- **Persona:** As a **FinOps engineer** (or **cloud administrator**), I need to configure cost monitoring and budget alerts so that we track migration spending and prevent budget overruns.

**Business Value:** Prevents surprise AWS bills and provides early warning of cost overruns during migration. Billing alarms (15 minutes setup) catch misconfigured resources or forgotten instances before they generate $5K-20K surprise bills. AWS Budgets provide forecasting and alerts when spending exceeds thresholds, essential for migration projects where new resources are constantly being created. Organizations without cost monitoring average 30-40% higher cloud spend due to undetected waste.

- **Requirements:**
  - CloudWatch billing alarms configured
  - AWS Budgets configured
  - Email notifications enabled
  - SNS topic created for cost alerts

- **Implementation Details:**

  #### 1) Enable Billing Alerts

  **Enable Billing Alerts (Console):**
  - Navigate to: Billing Dashboard → Billing Preferences
  - Check ✅ "Receive Billing Alerts"
  - Save preferences

  **Why this is required:** Without this setting, CloudWatch cannot access billing metrics.

  #### 2) Create SNS Topic for Cost Alerts

  ```bash
  # Create SNS topic for cost notifications
  aws sns create-topic --name billing-alerts --region us-east-1

  # Subscribe your email (replace YOUR_EMAIL)
  aws sns subscribe \
    --topic-arn arn:aws:sns:us-east-1:YOUR_ACCOUNT_ID:billing-alerts \
    --protocol email \
    --notification-endpoint YOUR_EMAIL@company.com \
    --region us-east-1

  # Check email and confirm subscription
  ```

  Or via Console: SNS → Topics → Create topic → Standard → Subscribe email

  #### 3) Configure CloudWatch Billing Alarm

  ```bash
  # Create billing alarm (adjust threshold as needed)
  aws cloudwatch put-metric-alarm \
    --alarm-name "EstimatedCharges-USD-100" \
    --alarm-description "Bill estimate exceeds $100" \
    --metric-name EstimatedCharges \
    --namespace AWS/Billing \
    --statistic Maximum \
    --period 21600 \
    --threshold 100 \
    --comparison-operator GreaterThanThreshold \
    --dimensions Name=Currency,Value=USD \
    --evaluation-periods 1 \
    --alarm-actions arn:aws:sns:us-east-1:YOUR_ACCOUNT_ID:billing-alerts \
    --region us-east-1
  ```

  Or via Console: CloudWatch → Alarms → Billing → Create alarm

  **What it does:** Sends email when estimated monthly charges exceed threshold (adjust $100 to your needs).

  #### 4) Create AWS Budget

  ```bash
  aws budgets create-budget \
    --account-id YOUR_ACCOUNT_ID \
    --budget '{
      "BudgetName":"MigrationMonthlyBudget",
      "BudgetLimit":{"Amount":"500","Unit":"USD"},
      "TimeUnit":"MONTHLY",
      "BudgetType":"COST",
      "CostTypes":{"IncludeCredit":false,"IncludeRefund":false}
    }' \
    --notifications-with-subscribers '[
      {
        "Notification":{
          "NotificationType":"ACTUAL",
          "ComparisonOperator":"GREATER_THAN",
          "Threshold":80,
          "ThresholdType":"PERCENTAGE"
        },
        "Subscribers":[{"SubscriptionType":"EMAIL","Address":"YOUR_EMAIL@company.com"}]
      }
    ]'
  ```

  Or via Console: AWS Budgets → Create budget → Cost budget

  **What it does:**
  - Tracks monthly spending against $500 budget (adjust to your needs)
  - Sends alert when 80% of budget consumed
  - Provides forecasting to predict end-of-month costs

  #### 5) Create Additional Budget Alerts (Recommended)

  **Multiple threshold alerts:**
  - 50% threshold: Early warning
  - 80% threshold: Action needed
  - 100% threshold: Budget exceeded
  - 110% threshold: Emergency escalation

  You can create multiple budgets or add multiple notifications to one budget via Console.

  #### 6) Test Notifications

  **Verify SNS subscription:**

  ```bash
  aws sns list-subscriptions-by-topic \
    --topic-arn arn:aws:sns:us-east-1:YOUR_ACCOUNT_ID:billing-alerts
  ```

  Expected output should show your email subscription with `"SubscriptionArn"` (not `"PendingConfirmation"`).

- **Acceptance Criteria:**
  - ✅ Billing alerts enabled in Billing Preferences
  - ✅ SNS topic created and email subscription confirmed
  - ✅ CloudWatch billing alarm created with appropriate threshold
  - ✅ AWS Budget created with 80% threshold notification
  - ✅ Email notifications received and tested
  - ✅ FinOps team has access to Cost Explorer and Budgets console
