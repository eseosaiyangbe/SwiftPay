# Technology Choices & Tradeoffs

> **For Beginners**: Understand why we chose each technology and what alternatives exist

---

## Table of Contents

1. [Frontend Technologies](#frontend-technologies)
2. [Backend Technologies](#backend-technologies)
3. [Database Technologies](#database-technologies)
4. [Infrastructure Technologies](#infrastructure-technologies)
5. [DevOps Technologies](#devops-technologies)
6. [Decision Framework](#decision-framework)

---

## Frontend Technologies

### React

**What**: JavaScript library for building user interfaces

**Why We Chose It:**
- ✅ **Popular**: Large community, lots of resources
- ✅ **Component-based**: Reusable UI components
- ✅ **Ecosystem**: Many libraries available
- ✅ **Job Market**: Widely used in industry

**How It Works:**
```javascript
// Component example
function Button({ text, onClick }) {
  return <button onClick={onClick}>{text}</button>;
}

// Use component
<Button text="Click me" onClick={handleClick} />
```

**Alternatives:**
- **Vue.js**: Simpler, easier to learn
- **Angular**: More features, steeper learning curve
- **Svelte**: Compiles to vanilla JavaScript (smaller bundle)

**Tradeoffs:**
- ✅ **Pros**: Large ecosystem, great tooling
- ❌ **Cons**: Can be complex for simple apps, frequent updates

**When to Use:**
- Complex UIs with lots of interactivity
- Need component reusability
- Team familiar with JavaScript

---

### Nginx

**What**: Web server and reverse proxy

**Why We Chose It:**
- ✅ **Performance**: Very fast, handles many connections
- ✅ **Reverse Proxy**: Routes requests to backend
- ✅ **Static Files**: Efficiently serves React build files
- ✅ **Production-Ready**: Used by many companies

**How It Works:**
```nginx
# Serve React app
location / {
    root /usr/share/nginx/html;
    try_files $uri /index.html;
}

# Proxy API requests
location /api {
    proxy_pass http://api-gateway:80;
}
```

**Alternatives:**
- **Apache**: Older, more features, heavier
- **Caddy**: Automatic HTTPS, simpler config
- **Traefik**: Good for containers, auto-discovery

**Tradeoffs:**
- ✅ **Pros**: Fast, reliable, widely used
- ❌ **Cons**: Configuration can be complex

**When to Use:**
- Serving static files
- Need reverse proxy
- Production deployments

---

## Backend Technologies

### Node.js

**What**: JavaScript runtime - runs JavaScript on server

**Why We Chose It:**
- ✅ **Same Language**: Frontend and backend both JavaScript
- ✅ **Fast**: Non-blocking I/O, handles many requests
- ✅ **Ecosystem**: npm has millions of packages
- ✅ **Developer Experience**: Easy to get started

**How It Works:**
```javascript
// Simple HTTP server
const http = require('http');
const server = http.createServer((req, res) => {
    res.writeHead(200);
    res.end('Hello World');
});
server.listen(3000);
```

**Alternatives:**
- **Python (Django/Flask)**: Better for data science, ML
- **Java (Spring)**: Enterprise-grade, more verbose
- **Go**: Very fast, good for microservices
- **Rust**: Fastest, memory-safe, harder to learn

**Tradeoffs:**
- ✅ **Pros**: Fast development, large ecosystem
- ❌ **Cons**: Single-threaded (but uses event loop), can be memory-intensive

**When to Use:**
- JavaScript/TypeScript team
- I/O-heavy applications (APIs, real-time)
- Fast development needed

---

### Express.js

**What**: Web framework for Node.js

**Why We Chose It:**
- ✅ **Simple**: Minimal, unopinionated
- ✅ **Flexible**: Add what you need
- ✅ **Popular**: Most used Node.js framework
- ✅ **Middleware**: Easy to add functionality

**How It Works:**
```javascript
const express = require('express');
const app = express();

app.get('/users', (req, res) => {
    res.json({ users: [...] });
});

app.listen(3000);
```

**Alternatives:**
- **Fastify**: Faster, similar API
- **NestJS**: More features, TypeScript-first
- **Koa**: More modern, async/await focused

**Tradeoffs:**
- ✅ **Pros**: Simple, flexible, lots of middleware
- ❌ **Cons**: Need to add features yourself (security, validation)

**When to Use:**
- Building REST APIs
- Need flexibility
- Team familiar with JavaScript

---

## Database Technologies

### PostgreSQL

**What**: Relational database - stores data in tables

**Why We Chose It:**
- ✅ **ACID**: Ensures data consistency (critical for money!)
- ✅ **SQL**: Powerful query language
- ✅ **Reliable**: Battle-tested, used by many companies
- ✅ **Features**: JSON support, full-text search, extensions

**How It Works:**
```sql
-- Create table
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    email VARCHAR(255) UNIQUE,
    password_hash VARCHAR(255)
);

-- Query
SELECT * FROM users WHERE email = 'user@example.com';
```

**Alternatives:**
- **MySQL**: Similar, also popular
- **MongoDB**: NoSQL, document-based, different use case
- **SQLite**: Lightweight, good for small apps
- **DynamoDB**: NoSQL, managed (AWS)

**Tradeoffs:**
- ✅ **Pros**: Reliable, powerful, ACID transactions
- ❌ **Cons**: Can be slower than NoSQL for simple queries

**When to Use:**
- Need ACID transactions (money, orders)
- Complex queries with joins
- Data relationships matter

**When NOT to Use:**
- Simple key-value storage (use Redis)
- Unstructured data (use MongoDB)
- High write throughput (consider NoSQL)

---

### Redis

**What**: In-memory data store (cache)

**Why We Chose It:**
- ✅ **Speed**: In-memory = microseconds
- ✅ **Simple**: Key-value store, easy to use
- ✅ **Features**: Expiration, pub/sub, lists
- ✅ **Reliable**: Used by many companies

**How It Works:**
```javascript
// Store data
redis.set('user:123', JSON.stringify(userData), 'EX', 3600); // Expires in 1 hour

// Get data
const userData = await redis.get('user:123');
```

**Alternatives:**
- **Memcached**: Simpler, older, fewer features
- **Hazelcast**: Distributed cache, more features
- **In-memory database**: Store in application memory (simpler, but lost on restart)

**Tradeoffs:**
- ✅ **Pros**: Very fast, simple, reliable
- ❌ **Cons**: Limited by RAM, data lost on restart (but that's OK for cache)

**When to Use:**
- Caching frequently accessed data
- Session storage
- Rate limiting
- Real-time features (pub/sub)

**When NOT to Use:**
- Primary database (use PostgreSQL)
- Need persistence (use PostgreSQL)
- Complex queries (use PostgreSQL)

---

## Infrastructure Technologies

PayFlow targets **AWS EKS** and **Azure AKS** with similar hub-style networking patterns. The following diagram summarizes the VPC-style split across clouds (detail lives in [architecture.md](architecture.md#infrastructure) and [terraform/terraform.md](../terraform/terraform.md)).

![AWS and Azure VPC service comparison](assets/AWS%20and%20Azure%20VPC%20Service-2026-03-30-111526.png)

### RabbitMQ

**What**: Message queue - stores messages until processed

**Why We Chose It:**
- ✅ **Reliability**: Messages stored on disk, won't lose them
- ✅ **Features**: Dead letter queues, retries, routing
- ✅ **Mature**: Battle-tested, used by many companies
- ✅ **Management UI**: Easy to monitor

**How It Works:**
```javascript
// Producer (send message)
channel.sendToQueue('transactions', Buffer.from(JSON.stringify(data)));

// Consumer (receive message)
channel.consume('transactions', (msg) => {
    const data = JSON.parse(msg.content.toString());
    // Process message
    channel.ack(msg);
});
```

**Alternatives:**
- **Apache Kafka**: Better for high throughput, event streaming
- **AWS SQS**: Managed service (cloud), simpler
- **NATS**: Lightweight, fast, fewer features
- **Redis Pub/Sub**: Simple, but not persistent

**Tradeoffs:**
- ✅ **Pros**: Reliable, feature-rich, mature
- ❌ **Cons**: Can be complex, requires management

**When to Use:**
- Async processing (don't need immediate response)
- Decouple services
- Need message persistence
- Need retries and dead letter queues

**When NOT to Use:**
- Need immediate response (use HTTP)
- Simple pub/sub (use Redis)
- Very high throughput (consider Kafka)

---

## DevOps Technologies

### Docker

**What**: Containerization platform

**Why We Chose It:**
- ✅ **Consistency**: Runs same way everywhere
- ✅ **Isolation**: Apps don't interfere
- ✅ **Portability**: Move containers easily
- ✅ **Ecosystem**: Large community, many tools

**How It Works:**
```dockerfile
# Dockerfile
FROM node:18-alpine
WORKDIR /app
COPY package.json .
RUN npm install
COPY . .
CMD ["node", "server.js"]
```

**Alternatives:**
- **Podman**: Docker-compatible, rootless
- **containerd**: Lower-level, used by Kubernetes
- **LXC**: Linux containers, more complex

**Tradeoffs:**
- ✅ **Pros**: Industry standard, great tooling
- ❌ **Cons**: Can be resource-intensive, learning curve

**When to Use:**
- Need consistency across environments
- Microservices architecture
- CI/CD pipelines
- Cloud deployments

---

### Kubernetes

**What**: Container orchestration platform

**Why We Chose It:**
- ✅ **Industry Standard**: Most used orchestration platform
- ✅ **Features**: Auto-scaling, self-healing, rolling updates
- ✅ **Ecosystem**: Many tools and services
- ✅ **Cloud Support**: Works on all major clouds

**How It Works:**
```yaml
# Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-gateway
spec:
  replicas: 3
  template:
    spec:
      containers:
      - name: api-gateway
        image: api-gateway:latest
```

**Alternatives:**
- **Docker Swarm**: Simpler, less features
- **Nomad**: Simpler, multi-cloud
- **ECS (AWS)**: Managed, AWS-specific
- **Cloud Run (GCP)**: Serverless containers

**Tradeoffs:**
- ✅ **Pros**: Powerful, industry standard, great features
- ❌ **Cons**: Complex, steep learning curve

**When to Use:**
- Production deployments
- Need auto-scaling
- Multiple services
- Cloud deployments

**When NOT to Use:**
- Simple applications (use Docker Compose)
- Learning this repo: follow [`LEARNING-PATH.md`](../LEARNING-PATH.md)—**MicroK8s first**; Compose is optional for a lighter start
- Small team (use managed services)

---

### MicroK8s

**What**: Lightweight Kubernetes for local development

**Why We Chose It:**
- ✅ **Local Kubernetes**: Run K8s on your machine
- ✅ **Lightweight**: Smaller than full Kubernetes
- ✅ **Easy Setup**: Simple installation
- ✅ **Learning**: Great for learning K8s

**Alternatives:**
- **Minikube**: Another local K8s option
- **Kind**: Kubernetes in Docker
- **k3s**: Even lighter, good for edge

**Tradeoffs:**
- ✅ **Pros**: Easy to set up, good for learning
- ❌ **Cons**: Not production-grade, resource-intensive

**When to Use:**
- Learning Kubernetes
- Local development
- Testing K8s configurations

---

## Decision Framework

### How to Choose Technologies

**1. Understand Requirements**
- What problem are you solving?
- What are the constraints?
- What are the priorities?

**2. Evaluate Options**
- Research alternatives
- Compare features
- Consider tradeoffs

**3. Consider Context**
- Team expertise
- Budget
- Timeline
- Scale requirements

**4. Make Decision**
- Choose based on requirements
- Document decision
- Be ready to change if needed

### Common Patterns

**Pattern 1: Start Simple, Scale Later**
- Start with simple technology
- Change when you have a reason
- Example: Start with SQLite, move to PostgreSQL when needed

**Pattern 2: Use What You Know**
- Leverage team expertise
- Faster development
- Example: Node.js team uses Node.js

**Pattern 3: Industry Standard**
- Use popular technologies
- Easier to hire
- More resources available
- Example: React, PostgreSQL, Kubernetes

**Pattern 4: Managed Services**
- Use cloud-managed services
- Less operational overhead
- Example: AWS RDS instead of self-hosted PostgreSQL

---

## Technology Stack Summary

### Our Choices

| Layer | Technology | Why |
|-------|-----------|-----|
| **Frontend** | React | Popular, component-based |
| **Web Server** | Nginx | Fast, production-ready |
| **Backend** | Node.js + Express | Same language as frontend, fast development |
| **Database** | PostgreSQL | ACID transactions, reliable |
| **Cache** | Redis | Fast, simple, reliable |
| **Message Queue** | RabbitMQ | Reliable, feature-rich |
| **Containerization** | Docker | Industry standard |
| **Orchestration** | Kubernetes | Industry standard, powerful |

### Alternatives Considered

| Layer | Our Choice | Alternative | Why We Didn't Choose |
|-------|-----------|-------------|---------------------|
| Frontend | React | Vue.js | React more popular, better ecosystem |
| Database | PostgreSQL | MongoDB | Need ACID transactions for money |
| Message Queue | RabbitMQ | Kafka | RabbitMQ simpler, sufficient for our needs |
| Orchestration | Kubernetes | Docker Swarm | Kubernetes more powerful, industry standard |

---

## Summary

✅ **You learned**:
- Why we chose each technology
- What alternatives exist
- Tradeoffs to consider
- How to make technology decisions

**Key Takeaways:**
- **No perfect choice**: Every technology has tradeoffs
- **Context matters**: Choose based on your needs
- **Start simple**: Add complexity when needed
- **Be flexible**: Be ready to change if needed

**Next**: 
- Explore the code to see how technologies are used
- Try alternatives and see what works for you
- Read [Architecture Overview](./architecture.md) to see how it all fits together

---

*Understanding technology choices helps you make better decisions! 🛠️*

