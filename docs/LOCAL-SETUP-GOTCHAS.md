# Local Setup Gotchas ("Works on My Machine")

These are the most common environment-specific issues when running SwiftPay locally. For general debugging see [RUNBOOK.md](RUNBOOK.md) and [troubleshooting.md](troubleshooting.md).

**Learning path:** [`LEARNING-PATH.md`](../LEARNING-PATH.md) is **MicroK8s-first**. Most sections below target **Docker Compose on your host** (optional path) or cross-cutting issues (e.g. MicroK8s ingress/DNS).

## Port conflicts

### Postgres already running on 5432

If you have PostgreSQL running locally (e.g. Homebrew, Postgres.app), Docker Compose will fail with "address already in use" when binding `5432:5432`.

**Option A — Use a different host port**

In `docker-compose.yml`, change the postgres service:

```yaml
postgres:
  ports:
    - "5433:5432"   # Host 5433 → container 5432
```

Then point other local tools (e.g. pgAdmin, DBeaver) at `localhost:5433`. The **containers** still talk to `postgres:5432` on the Docker network, so no other service config changes are needed.

**Option B — Stop local Postgres**

```bash
# macOS (Homebrew)
brew services stop postgresql

# Or find and kill the process
lsof -i :5432
kill -9 <PID>
```

### Other ports in use (Redis 6379, RabbitMQ 5672/15672, app ports)

- Find the process: `lsof -i :<port>` (macOS/Linux).
- Either stop that process or change the host port in `docker-compose.yml` (e.g. `"6379:6379"` → `"6380:6379"`). Services inside Docker still use the container port; only the host mapping changes.

See also: [troubleshooting.md — Port Already in Use](troubleshooting.md#issue-port-already-in-use).

---

## Apple Silicon (M1/M2/M3) / ARM

Docker Desktop on Apple Silicon runs Linux ARM images. The images used by SwiftPay are multi-arch (e.g. `postgres:15-alpine`, `redis:7-alpine`, `rabbitmq:3-management-alpine`), so they work on ARM without changes.

If you hit ARM-specific issues:

- **Node service builds** — Dockerfiles use `node:*-alpine`; these have ARM variants. If you see "exec format error", ensure you’re not pulling an x86-only image.
- **Performance** — First run can be slower due to image pulls and possible emulation for any x86-only base; prefer ARM-native images where possible.

---

## Windows / WSL2

### Path separators and line endings

- Use **forward slashes** in paths in scripts and configs. WSL2 and Git Bash understand them; PowerShell may require `\` or `$env:VAR`.
- If shell scripts fail with `\r` or "command not found", fix CRLF line endings:
  ```bash
  git config core.autocrlf input
  ```
  Then re-checkout or convert existing files (e.g. `sed -i 's/\r$//' script.sh`).

### Running shell scripts

- Prefer **WSL2** or **Git Bash** for `.sh` scripts (e.g. `./terraform/bootstrap.sh`). PowerShell is not Bash and won’t run them as-is.
- If you must use PowerShell, either run `bash script.sh` from WSL/Git Bash or port the script to PowerShell.

### Docker

- Use **Docker Desktop** with the WSL2 backend. Ensure the project directory is under the WSL filesystem (e.g. `~/projects/swiftpay-wallet`) so volume mounts and file watching work correctly. Accessing the repo from `/mnt/c/...` can be slower and sometimes cause permission or path issues.

---

## swiftpay.local works in curl but not in browser (MicroK8s)

If `curl http://192.168.64.5/ -H "Host: swiftpay.local"` returns 200 but the browser shows "This site can't be reached" or ERR_CONNECTION_RESET when opening `swiftpay.local`:

1. **/etc/hosts must use the VM IP**  
   SwiftPay ingress runs in the MicroK8s VM (usually **192.168.64.5**). Your hosts file must point the hostname there:
   ```text
   192.168.64.5   swiftpay.local www.swiftpay.local api.swiftpay.local
   ```
   If you still have `192.168.64.2` for these, the browser will connect to the wrong host. Edit with `sudo nano /etc/hosts` or `sudo vi /etc/hosts`.

2. **Use http:// (not https://)**  
   Type **http://swiftpay.local** in the address bar. If you use `https://` or let the browser upgrade, the connection will fail (no TLS on local ingress).

3. **Flush DNS so the browser sees the new hosts**  
   ```bash
   sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
   ```
   Then reload the page or close and reopen the tab.

4. **Try a private/incognito window**  
   Avoids cached redirects or HSTS. Open **http://swiftpay.local** in that window.

5. **Verify resolution**  
   ```bash
   ping -c 1 swiftpay.local
   ```
   The IP shown must be **192.168.64.5** (or whatever IP you use in /etc/hosts). If it shows a different IP, fix /etc/hosts and flush DNS again.

---

## 502 Bad Gateway on /api/auth/login (MicroK8s)

If the login page loads but sign-in returns **502** or "Request failed", the API gateway or auth-service may not be Ready yet (probes too tight on a slow cluster). The **local overlay** includes `local-probe-delays-patch.yaml` so api-gateway and auth-service get longer initial delays before health checks. Reapply the local overlay and wait for pods to be Ready:

```bash
kubectl apply -k k8s/overlays/local
kubectl get pods -n swiftpay -w   # wait until api-gateway and auth-service are Running and Ready
```

Then try **http://swiftpay.local** and sign in again. No EKS/AKS changes—only `k8s/overlays/local/` is used for this.

---

## Quick reference

| Issue              | What to check / do                                      |
|--------------------|----------------------------------------------------------|
| Port in use        | Change host port in `docker-compose.yml` or free the port |
| Postgres conflict  | Use `5433:5432` for postgres or stop local Postgres     |
| ARM / M1 errors    | Use multi-arch/official images (current stack is fine)   |
| Windows scripts    | Use WSL2 or Git Bash; fix CRLF if needed                 |
| Paths on Windows   | Prefer WSL project path; forward slashes in configs     |
| swiftpay.local (browser) | /etc/hosts → 192.168.64.5; use http://; flush DNS; incognito |
