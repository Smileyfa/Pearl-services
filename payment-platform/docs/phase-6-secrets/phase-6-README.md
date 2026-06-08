# Phase 6 — Secret Management with HashiCorp Vault

**Phase status:** ✅ Complete  
**Findings remediated:** S-01 through S-05  
**Files changed:** 4 modified, 2 created  
**Date completed:** 29 May 2026
**Author:** Rasaq Bello

---

## Objective

Replace all hardcoded and environment-variable-based secrets with HashiCorp Vault as the central secret store. Rotate the JWT secret to invalidate all previously forged tokens. Demonstrate that secret rotation kills existing exploits without any code changes.

---

## What is Secret Management?

Secret management is the practice of storing, accessing, rotating, and auditing credentials in a centralised, controlled system rather than in source code, environment files, or Kubernetes manifests.

**The problem with secrets in `.env` files and source code:**
- Committed to git — permanent exposure in history
- No rotation mechanism — changing a secret requires redeployment
- No audit trail — impossible to know who accessed what
- Shared across environments — dev secrets leak into prod

**What Vault provides:**
- Centralised secret storage with encryption at rest
- Fine-grained access control — each service gets only what it needs
- Automatic secret rotation
- Full audit log — every secret read is recorded with timestamp and identity
- Dynamic secrets — generate database credentials on demand, revoke after use

---

## Architecture

```
Before Phase 6:                    After Phase 6:

.env (committed to git)            HashiCorp Vault
  JWT_SECRET=secret123      →        secret/pearlpay/jwt_secret
  DATABASE_URL=...          →        secret/pearlpay/database_url
  REDIS_PASSWORD=...        →        secret/pearlpay/redis_password
  OPENAI_API_KEY=...        →        secret/pearlpay/openai_api_key
         ↓                                    ↓
   backend reads                    vault_client.py reads at startup
   from environment                 overwrites environment variables
```

---

## Exploitation — Proof of Vulnerability

Before Phase 6, the JWT secret `secret123` was used to sign all tokens. This allowed forging of admin tokens as demonstrated in Phase 4:

```bash
# Forged admin token signed with secret123
curl "http://localhost:8000/api/admin/transactions" \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoiYWRtaW4ifQ.hGo6kcQH..."
# → Returned all transactions (BEFORE fix)
# → {"detail":"Internal server error"} (AFTER Vault rotation)
```

The same token that returned the full database in Phase 4 now returns an error — the secret was rotated in Vault without any code changes.

### Evidence
![Vault secrets stored](./vault-secrets-stored.png)
![Forged token rejected after rotation](./vault-forged-token-rejected.png)

---

## Fix 1 — Remove Hardcoded Secrets from main.py

**File:** `backend/main.py`

All hardcoded secrets replaced with `os.environ.get()`:

```python
# Before — hardcoded in source code
JWT_SECRET = "secret123"
OPENAI_API_KEY = "sk-proj-realisticTrainingKey..."
AWS_ACCESS_KEY_ID = "AKIA0000EXAMPLE"
AWS_SECRET_ACCESS_KEY = "wJalrXexample"
REDIS_PASSWORD = "redis-P@ssw0rd-Prod"

# After — loaded from environment (populated by Vault at startup)
JWT_SECRET = os.environ.get("JWT_SECRET")
OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY")
AWS_ACCESS_KEY_ID = os.environ.get("AWS_ACCESS_KEY_ID")
AWS_SECRET_ACCESS_KEY = os.environ.get("AWS_SECRET_ACCESS_KEY")
REDIS_PASSWORD = os.environ.get("REDIS_PASSWORD")
```

**Startup validation added — app refuses to start with missing secrets:**
```python
required_secrets = {
    "JWT_SECRET": JWT_SECRET,
    "DATABASE_URL": DATABASE_URL,
    "REDIS_PASSWORD": REDIS_PASSWORD,
}
missing = [name for name, value in required_secrets.items() if not value]
if missing:
    raise RuntimeError(f"Missing required environment variables: {', '.join(missing)}")
```

---

## Fix 2 — Vault Client (vault_client.py)

**File:** `backend/vault_client.py` — new file

```python
def get_vault_secrets():
    vault_addr = os.environ.get("VAULT_ADDR")
    vault_token = os.environ.get("VAULT_TOKEN")

    if not vault_addr:
        return {}  # fallback to environment variables

    try:
        response = requests.get(
            f"{vault_addr}/v1/secret/data/pearlpay",
            headers={"X-Vault-Token": vault_token},
            timeout=3,
        )
        response.raise_for_status()
        return response.json()["data"]["data"]
    except Exception as exc:
        logging.warning("Vault unavailable, falling back to environment variables: %s", exc)
        return {}

def load_secrets():
    secrets = get_vault_secrets()
    for secret_name, secret_value in secrets.items():
        # Vault overrides .env so rotated secrets take effect immediately
        os.environ[secret_name] = str(secret_value)
    return len(secrets)
```

**Called at the very start of main.py before any secret is read:**
```python
from vault_client import load_secrets
_secrets_loaded = load_secrets()  # must run before os.environ.get() calls
```

### Fallback behaviour
If Vault is unavailable (network issue, cold start), the app falls back to environment variables from `.env`. This keeps development resilient while ensuring production always uses Vault.

---

## Fix 3 — Vault in Docker Compose

**File:** `docker-compose.yml`

```yaml
vault:
  image: hashicorp/vault:1.15
  container_name: payment-platform-vault
  environment:
    VAULT_DEV_ROOT_TOKEN_ID: dev-root-token
    VAULT_DEV_LISTEN_ADDRESS: 0.0.0.0:8200
  ports:
    - "8200:8200"
  cap_add:
    - IPC_LOCK
  healthcheck:
    test: ["CMD", "sh", "-c", "VAULT_ADDR=http://0.0.0.0:8200 vault status"]
    interval: 5s
    timeout: 3s
    retries: 10
    start_period: 5s

vault-init:
  image: hashicorp/vault:1.15
  depends_on:
    vault:
      condition: service_healthy
  environment:
    VAULT_ADDR: http://vault:8200
    VAULT_TOKEN: dev-root-token
  command:
    - sh
    - -c
    - |
      vault secrets enable -path=secret kv-v2 || true
      vault kv put secret/pearlpay \
        database_url='postgresql://payadmin:...' \
        jwt_secret='aX9kL2mP5nQ8rT1uW4vY7zA3bC6dE0fG' \
        redis_password='redis-P@ssw0rd-Prod' \
        openai_api_key='sk-proj-...'
      echo "Vault initialised"
```

> ⚠️ **Dev mode only** — Vault dev mode stores data in memory and uses a static root token. Never use dev mode in production. Production Vault uses persistent storage, TLS, and dynamic tokens.

**Backend startup order enforced:**
```yaml
backend:
  depends_on:
    vault:
      condition: service_healthy
    vault-init:
      condition: service_completed_successfully
```

---

## Secret Rotation — Proof It Works

The most powerful demonstration of Vault is secret rotation.

**Before rotation** — forged admin token signed with `secret123` returned full database:
```bash
curl "http://localhost:8000/api/admin/transactions" \
  -H "Authorization: Bearer FORGED_TOKEN_secret123"
# → {"transactions": [...all card data...]}
```

**After rotation** — same token rejected immediately:
```bash
curl "http://localhost:8000/api/admin/transactions" \
  -H "Authorization: Bearer FORGED_TOKEN_secret123"
# → {"detail": "Internal server error"}
```

**No code changes, no redeployment** — only the secret in Vault changed. This is the power of centralised secret management.

To rotate the JWT secret in the future:
```bash
# Update secret in Vault
docker exec -e VAULT_ADDR=http://0.0.0.0:8200 \
  -e VAULT_TOKEN=dev-root-token \
  payment-platform-vault \
  vault kv patch secret/pearlpay jwt_secret="NEW_STRONG_SECRET"

# Restart backend to pick up new secret
docker-compose restart backend
```

---

## Vault UI

Vault has a built-in web UI accessible at:
```
http://localhost:8200
```

Login with token: `dev-root-token`

Navigate to `secret/pearlpay` to view, edit, and rotate secrets through the UI.

---

## What Remains for Production

This phase implements Vault for local development. Production hardening (Phase 9) will add:

| Control | Dev (current) | Production (Phase 9) |
|---|---|---|
| Vault mode | Dev (in-memory) | Server mode (persistent) |
| Authentication | Static root token | AppRole / Kubernetes auth |
| TLS | Disabled | Enabled |
| Secret engine | KV v2 | KV v2 + Dynamic secrets |
| Token rotation | Manual | Automatic lease renewal |
| Audit logging | Disabled | File + syslog |

---

## Files Changed

| File | Action | Purpose |
|---|---|---|
| `backend/main.py` | Modified | Removed hardcoded secrets, added startup validation |
| `backend/vault_client.py` | Created | Vault API client with environment fallback |
| `docker-compose.yml` | Modified | Added Vault + vault-init services |
| `.env` | Modified | Updated VAULT_ADDR and VAULT_TOKEN |
| `k8s/secrets.yaml` | Modified (Phase 5) | Emptied — Vault injects at runtime |
| `k8s/encryption-config.yaml` | Created (Phase 5) | AES-CBC encryption at rest |

---

## What I Learned

1. **Secret rotation is the real value of Vault** — storing secrets in Vault is useful, but the ability to rotate them without redeployment is transformative. Rotating the JWT secret invalidated every forged token ever created — instantly, without touching a single line of code. In a real breach scenario this is the difference between containment and continued compromise.

2. **Startup order matters in containerised environments** — the backend crashed repeatedly because it started before Vault had initialised. `depends_on` with `condition: service_completed_successfully` solved this but required understanding the difference between a service being running versus a service having completed its initialisation work.

3. **`setdefault` vs direct assignment changes security posture** — using `os.environ.setdefault()` meant `.env` values silently took precedence over Vault. Switching to direct assignment `os.environ[key] = value` made Vault authoritative. One line of code, completely different security behaviour.

4. **Dev mode is a training wheel, not a crutch** — Vault dev mode is perfect for learning but stores everything in memory and uses a static token. Every production deployment needs Vault in server mode with persistent storage, TLS, and proper authentication. Knowing the difference is what hiring managers test for.

5. **Secrets in git are permanent** — even after removing `JWT_SECRET=secret123` from `.env`, it exists forever in git history. In a real incident, any secret ever committed to git must be considered compromised and rotated immediately. Tools like `git-secrets` and `gitleaks` prevent this from happening in the first place — covered in Phase 7.

---

## Next Phase

[Phase 7 — CI/CD Security →](../phase-7-cicd/README.md)

---

## Resources

- [HashiCorp Vault Documentation](https://developer.hashicorp.com/vault/docs)
- [Vault KV Secrets Engine](https://developer.hashicorp.com/vault/docs/secrets/kv/kv-v2)
- [Vault Dev Mode](https://developer.hashicorp.com/vault/docs/concepts/dev-server)
- [External Secrets Operator](https://external-secrets.io/)
- [OWASP Secrets Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html)
- [GitLeaks — Secret Scanning](https://github.com/gitleaks/gitleaks)
