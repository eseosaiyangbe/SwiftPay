# SwiftPay Observability Runbook

This runbook explains how SwiftPay is monitored from the external DevOps Monitor stack.

Use it when you want to verify SwiftPay metrics, troubleshoot alerts, or confirm that the custom DevOps Monitor dashboard is reading real business signals from Prometheus.

## Current Verified Baseline

SwiftPay is monitored by the external stack in:

```bash
/home/theinventor/Desktop/devops/devopseasylearning/Obervability-Stack
```

SwiftPay runs in:

```bash
/home/theinventor/Desktop/devops/devopseasylearning/SwiftPay
```

Verified DevOps Monitor URL:

```text
http://localhost:4000/dashboard
```

Verified Prometheus URL:

```text
http://localhost:9090
```

## What We Added

Prometheus now scrapes SwiftPay service metrics directly from Docker DNS names on the shared observability network.

Scrape jobs:

```text
swiftpay-api-gateway
swiftpay-auth-service
swiftpay-wallet-service
swiftpay-transaction-service
swiftpay-notification-service
```

Business recording rules:

```text
swiftpay:pending_transactions
swiftpay:pending_amount
swiftpay:transaction_queue_depth
swiftpay:completed_transfers_total
swiftpay:transaction_failure_rate_5m
swiftpay:wallet_failed_transfer_rate_5m
swiftpay:wallet_circuit_breaker_state
```

Dashboard section:

```text
DevOps Monitor -> Dashboard -> SwiftPay Money Flow
```

Cards:

```text
Pending Transactions
Pending Amount
Queue Depth
Completed Transfers
Wallet Circuit
Transaction Failures
Wallet Failures
```

## Why These Metrics Matter

| Signal | Healthy Meaning | Problem Meaning |
|---|---|---|
| Pending Transactions | Usually `0` | Transfers were accepted but not completed |
| Pending Amount | Usually `$0.00` | Money is stuck before wallet movement completes |
| Queue Depth | Usually `0` | RabbitMQ has a transaction backlog |
| Completed Transfers | Grows during healthy usage | Staying flat during expected traffic can point to a broken happy path |
| Wallet Circuit | `Closed` | `Open` means Transaction Service is protecting Wallet Service |
| Transaction Failures | Usually `0/min` | Transaction worker is marking transfers failed |
| Wallet Failures | Usually `0/min` | Wallet Service rejected or failed transfers |

## Verify Prometheus Configuration

Run from the observability stack:

```bash
cd /home/theinventor/Desktop/devops/devopseasylearning/Obervability-Stack
docker compose exec -T prometheus promtool check config /etc/prometheus/prometheus.yml
docker compose exec -T prometheus promtool check rules /etc/prometheus/alert_rules.yml /etc/prometheus/recording_rules.yml
```

Expected result:

```text
SUCCESS
```

## Reload Prometheus

After editing Prometheus config or rules:

```bash
curl -fsS -X POST http://localhost:9090/-/reload
```

## Verify SwiftPay Targets

```bash
curl -fsS --get http://localhost:9090/api/v1/query \
  --data-urlencode 'query=up{job=~"swiftpay-.+"}' | jq .
```

Expected result:

```text
All SwiftPay jobs return value "1".
```

## Verify Business Metrics

```bash
curl -fsS --get http://localhost:9090/api/v1/query \
  --data-urlencode 'query=swiftpay:pending_transactions' | jq .
```

Expected healthy value:

```text
0
```

Check the DevOps Monitor API:

```bash
curl -fsS http://localhost:4000/api/apps/swiftpay/business | jq .
```

Expected shape:

```json
{
  "app": "swiftpay",
  "metrics": {
    "pendingTransactions": 0,
    "pendingAmount": 0,
    "queueDepth": 0,
    "completedTransfersTotal": 3,
    "transactionFailureRate": 0,
    "walletFailureRate": 0,
    "walletCircuitBreakerState": 0
  }
}
```

## Alert Rules Added

SwiftPay alert rules now cover:

```text
SwiftPayMetricsScrapeDown
SwiftPayPendingTransactionsStuck
SwiftPayMoneyStuckPending
SwiftPayTransactionQueueDepthHigh
SwiftPayTransactionFailureRateHigh
SwiftPayWalletFailureRateHigh
SwiftPayWalletCircuitBreakerOpen
```

Each alert points back to the SwiftPay money-flow runbook so the next action is discoverable during troubleshooting.

## Rebuild The DevOps Monitor UI

Run this after changing the custom UI:

```bash
cd /home/theinventor/Desktop/devops/devopseasylearning/Obervability-Stack
docker compose up -d --build devops-monitor-ui
```

Verify:

```bash
docker compose ps devops-monitor-ui prometheus
```

Expected result:

```text
devops-monitor-ui   Up   healthy
prometheus          Up   healthy
```

## Notes For Kubernetes Later

The current Docker Compose jobs are intentionally named like future Kubernetes service identities.

When we move to Kubernetes, the target discovery mechanism will change from static Docker DNS targets to Kubernetes service discovery or ServiceMonitor resources, but the business signals should stay the same:

```text
pending transactions
pending amount
queue depth
completed transfers
failure rates
circuit breaker state
```

That means the dashboard and alert meaning can survive the platform move.
