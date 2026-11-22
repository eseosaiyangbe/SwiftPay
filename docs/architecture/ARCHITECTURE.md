# SwiftPay Platform Architecture

![SwiftPay platform architecture](swiftpay-platform-architecture.png)

This document is the architecture design of record for SwiftPay as a managed workload of the Internal Developer Platform. The image above is rendered from the Mermaid source in this file, so the picture and the source never drift apart. The service level diagram in the repository README and `docs/architecture.md` remains the reference for ports, routes, and the multi environment deployment paths.

## The design in one paragraph

Users and the operator reach SwiftPay through Cloudflare Tunnel and Traefik ingress, the single public entry point. Inside Kubernetes on k3s, the frontend and API gateway front the Node.js services: auth, wallet, transaction, and notification. The transaction service records each transaction in PostgreSQL and publishes it to RabbitMQ; the transaction worker consumes the queue and processes asynchronously, storing the result and triggering notifications. Redis supports caching and transient state. Credentials for the database, cache, and messaging arrive from HashiCorp Vault through External Secrets, never from manifests. Prometheus, Loki, Grafana, and alerting are the shared platform observability stack, carrying business metrics beside technical metrics. Validation is the signature practice: the live audit executes a synthetic transfer through the real path and waits until Prometheus observes it before asserting success, because metrics for a transfer appear after processing, not at request time (44 of 44 checks passed, Phase 6 lab audit). The transaction worker unavailable drill exercises the queue backlog failure mode on purpose.

## Architecture diagram, Mermaid source

```mermaid
flowchart TB
    User["User"]
    Operator["Operator"]

    subgraph Edge["Edge and ingress"]
        CF["Cloudflare Tunnel<br/>swiftpay.eseosadevbox.com"]
        Ingress["Traefik ingress<br/>Single public entry point"]
    end

    subgraph Cluster["Kubernetes on k3s, SwiftPay workload"]
        subgraph Services["Node.js microservices"]
            Frontend["Frontend<br/>Web application"]
            Gateway["API Gateway<br/>Routes API traffic"]
            Auth["Auth Service<br/>Identity"]
            Wallet["Wallet Service<br/>Wallets and balances"]
            Txn["Transaction Service<br/>Records and publishes<br/>Guard and finalizer"]
            Notify["Notification Service<br/>User notifications"]
            Worker["Transaction Worker<br/>Asynchronous processing"]
        end

        subgraph Data["Data and messaging"]
            PG["PostgreSQL<br/>Transactional store"]
            Redis["Redis<br/>Cache and transient state"]
            MQ["RabbitMQ<br/>Transaction queue"]
        end

        subgraph Obs["Observability, shared platform stack"]
            Prom["Prometheus<br/>Business and technical metrics"]
            Grafana["Grafana<br/>Dashboards"]
            Loki["Loki<br/>Centralized logs"]
            Alerts["Alerting<br/>Service and dependency health"]
        end
    end

    subgraph Platform["Platform services, from the IDP"]
        Vault["HashiCorp Vault<br/>Secrets source of truth"]
        ExtSecrets["External Secrets<br/>Credentials for database,<br/>cache, and messaging"]
    end

    subgraph Delivery["Delivery"]
        Git["Git repository<br/>Manifests, Kustomize overlays,<br/>Terraform, migrations"]
        CI["GitHub Actions<br/>Build, publish, smoke,<br/>controlled promotion"]
    end

    subgraph Validation["Validation, the signature practice"]
        Audit["SwiftPay live audit<br/>44 of 44, Phase 6 lab audit"]
        Synthetic["Synthetic transfer<br/>Executed end to end"]
        Drill["Worker unavailable drill<br/>Queue backlog observed,<br/>recovery validated"]
    end

    User --> CF
    CF --> Ingress
    Ingress --> Frontend
    Ingress --> Gateway
    Frontend --> Gateway
    Gateway --> Auth
    Gateway --> Wallet
    Gateway --> Txn
    Txn -->|"records transaction"| PG
    Txn -->|"publishes"| MQ
    MQ -->|"consumes"| Worker
    Worker -->|"stores result"| PG
    Worker --> Notify
    Wallet --> PG
    Wallet --> Redis
    Txn --> Redis

    Vault --> ExtSecrets
    ExtSecrets --> Services
    ExtSecrets --> Data

    Services -->|"metrics"| Prom
    Data -->|"metrics"| Prom
    Services -->|"logs"| Loki
    Prom --> Grafana
    Prom --> Alerts
    Grafana --> Operator
    Alerts --> Operator

    Git --> CI
    CI -->|"deploys, then verifies at runtime"| Cluster

    Synthetic -->|"runs through the real path"| Gateway
    Audit --> Synthetic
    Audit -->|"waits until Prometheus<br/>observes the transfer"| Prom
    Audit -->|"asserts metrics, logs,<br/>and endpoint health"| Cluster
    Drill --> Worker
```

## Flow diagram: the synthetic transfer validation, Mermaid source

```mermaid
flowchart LR
    A["Live audit starts"] --> B["Execute a synthetic transfer<br/>Gateway, transaction service,<br/>queue, worker, store"]
    B --> C["Wait for evidence<br/>Poll Prometheus until the<br/>transfer is observed"]
    C --> D{"Transfer observed?"}
    D -->|"No, keep waiting<br/>within the audit window"| C
    D -->|"Yes"| E["Assert metrics success<br/>Then check logs and<br/>endpoint health"]
    E --> F["Record the audit result<br/>44 of 44, Phase 6"]
```

## Notes

- SwiftPay is a portfolio application in a lab environment. It is not a regulated financial system, and no compliance, settlement, or real money claims are made.
- Audit counts are point in time lab validation results documented in the platform repository.
- Live application: `https://swiftpay.eseosadevbox.com`.
