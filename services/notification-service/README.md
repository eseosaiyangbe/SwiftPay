# Notification Service

**Port:** 3003 | **Files:** `server.js` (705 lines), `email-sender.js`, `sms-sender.js`

## What this service owns

- **`notifications` table** — every notification sent, with `read` status, linked to a transaction
- **RabbitMQ queue** — consumes from `notifications` (published by transaction-service after a transfer completes)

## Why it exists separately

Sending an email or SMS is a **side effect** — it should never block or fail a money transfer. If SendGrid is having a bad day or your Twilio account is rate-limited, the transaction should still complete normally.

By consuming from a queue instead of being called directly, the notification service is fully decoupled: transaction-service publishes "transaction completed" and forgets about it. Notification-service picks it up when it's ready. If notification-service is down for 5 minutes, messages queue up and get processed when it restarts — no messages lost, no impact on transactions. This is the "fire and forget" event-driven pattern.

## Message flow

```
transaction-service
  └── publishes to `notifications` queue
        message: { userId, type, message, transactionId, amount, otherParty }

notification-service (this service)
  ├── consumes message from queue
  ├── INSERT into notifications table (for the activity feed in the UI)
  ├── send email via SMTP (nodemailer) — if SMTP configured, otherwise log only
  └── send SMS via Twilio — if TWILIO_* vars set, otherwise log only
```

## Most interesting code to read first

| Where | What it teaches |
|-------|----------------|
| `server.js` — queue consumer setup | How to consume reliably: `ack` after DB write, `nack` to retry on failure |
| `email-sender.js` | Nodemailer setup, HTML templates, graceful fallback when SMTP isn't configured |
| `sms-sender.js` | Twilio integration, how optional external services are handled |
| `GET /notifications/:userId` | How the UI's activity feed is powered |

## Run it locally

Email and SMS are optional — the service works without them, falling back to console logs.

```bash
cd ../..
docker compose up -d postgres rabbitmq
cd services/notification-service
npm install
npm run dev   # starts on port 3003
```

Or use the VS Code **"Debug Notification Service"** launch config.

## Health check

```bash
curl http://localhost:3003/health
# {"status":"healthy","postgres":"connected","rabbitmq":"connected","email":"not_configured","sms":"not_configured"}
```

## Enabling email (optional, for local testing)

You can use Gmail with an App Password. Add these to your `docker-compose.yml` under `notification-service → environment:`, or export them before running locally:

```bash
export SMTP_HOST=smtp.gmail.com
export SMTP_PORT=587
export SMTP_USER=your@gmail.com
export SMTP_PASSWORD=your-app-password   # not your Gmail login — create an App Password at myaccount.google.com/apppasswords
```

## Things to think about

- What happens if the notification-service is down when a transaction completes? Will the notification be lost?
- Why does the service `nack` (not acknowledge) a message when the DB write fails?
- Could you add a Slack notification channel without touching any other service?

---

**Read next:** [`services/api-gateway`](../api-gateway/README.md) — now that you understand all the backend services, see how the gateway ties them together into a single public API.
