# Phase 5 — Kubernetes Security Hardening

**Phase status:** ✅ Complete  
**Findings remediated:** 6 (K8S-01 through K8S-06)  
**Files changed:** 4 modified, 3 created  
**Date completed:** <!-- add date -->  
**Author:** <!-- your name -->

---

## Objective

Identify and remediate Kubernetes security misconfigurations across the PearlPay deployment manifests. Fix container privilege issues, resource limits, service account permissions, secret storage, and network isolation.

---

## What is Kubernetes Security Hardening?

Kubernetes orchestrates containers in production. A misconfigured cluster can turn a single compromised container into full infrastructure compromise. Kubernetes security hardening applies the principle of least privilege at the infrastructure layer — containers should only have the permissions, resources, and network access they absolutely need.

**The four pillars of Kubernetes security:**

```
1. Pod Security       — what a container can do on the host
2. Resource Controls  — how much CPU/memory a pod can consume
3. Identity & Access  — which Kubernetes API calls a pod can make
4. Network Policy     — which pods can talk to which pods
```

---

## Exploitation — Proof of Vulnerability

Before remediating, the container running as root was demonstrated:

```bash
docker exec -it payment-platform-backend-1 whoami
# → root

docker exec -it payment-platform-backend-1 id
# → uid=0(root) gid=0(root) groups=0(root)
```

Running as root inside the container and executing `env` exposed every application secret:

```
DATABASE_URL  = postgresql://payadmin:SuperSecretPassword123!@postgres:5432/payments
JWT_SECRET    = secret123
REDIS_PASSWORD = redis-P@ssw0rd-Prod
AWS_ACCESS_KEY_ID = AKIA0000EXAMPLE
AWS_SECRET_ACCESS_KEY = wJalrXXexample
OPENAI_API_KEY = sk-proj-realisticTrainingKey1234567890abcdef
ANTHROPIC_API_KEY = sk-ant-realisticTrainingKey1234567890abcdef
VAULT_TOKEN = hvs.realisticTrainingVaultToken123456789
```

**Every secret in the application exposed in a single command.**

Kubernetes Secrets were also shown to be base64-encoded only — not encrypted:

```bash
echo "c2VjcmV0MTIz" | base64 -d
# → secret123
```

One command decoded the JWT secret from the secrets manifest.

### Evidence
![Root container exploitation](./exploit-root-container-secrets.png)
![Kubernetes secrets base64 decoded](./exploit-k8s-secrets-base64.png)

---

## Fix 1 — Pods Running as Root (K8S-01)

**File:** `k8s/deployment.yaml`  
**CVSS:** 7.0 — High  
**Semgrep Finding:** F-01, F-02

### Problem
```yaml
securityContext:
  runAsUser: 0  # root
```
If an attacker achieves code execution inside the container they immediately have root privileges — able to read all files, modify the filesystem, and access every mounted secret.

### Fix
```yaml
securityContext:
  runAsUser: 1000      # non-root user
  runAsNonRoot: true   # Kubernetes enforces this — pod fails to start if image requires root
  fsGroup: 1000        # filesystem group for volume mounts
```

### Why `runAsNonRoot: true` matters
Setting `runAsUser: 1000` alone can be overridden by the container image. `runAsNonRoot: true` tells Kubernetes to reject the pod entirely if the container tries to run as root — it is enforced at the kubelet level before the container starts.

---

## Fix 2 — Privileged Containers (K8S-02)

**File:** `k8s/deployment.yaml`  
**CVSS:** 8.8 — High  
**Semgrep Finding:** F-06, F-07, F-08, F-09

### Problem
```yaml
securityContext:
  privileged: true
```
A privileged container has near-complete access to the host kernel. An attacker inside a privileged container can:
- Mount the host filesystem: `mount /dev/sda1 /host`
- Read every file on the host including other containers' secrets
- Load kernel modules
- Escape the container entirely and compromise the node

### Fix
```yaml
securityContext:
  allowPrivilegeEscalation: false  # cannot gain more privileges than parent process
  readOnlyRootFilesystem: true     # cannot write to the container filesystem
  capabilities:
    drop: ["ALL"]                  # all Linux capabilities removed
```

### What each setting does

| Setting | Effect |
|---|---|
| `allowPrivilegeEscalation: false` | Prevents setuid/setgid binaries from escalating privileges |
| `readOnlyRootFilesystem: true` | Attacker cannot write malware, modify configs, or install tools |
| `capabilities: drop: ["ALL"]` | Removes all Linux capabilities — NET_ADMIN, SYS_ADMIN, etc. |

---

## Fix 3 — No Resource Limits (K8S-03)

**File:** `k8s/deployment.yaml`  
**CVSS:** 5.3 — Medium

### Problem
No CPU or memory limits defined. A single compromised or buggy pod can consume all node resources, causing a denial of service for every other pod on the same node.

### Fix
```yaml
# API container
resources:
  requests:
    cpu: 100m       # guaranteed minimum
    memory: 128Mi
  limits:
    cpu: 500m       # hard maximum
    memory: 512Mi

# Frontend container
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 256Mi
```

### Requests vs Limits explained

**Requests** — the amount of CPU/memory Kubernetes guarantees the pod. Used for scheduling decisions.

**Limits** — the hard maximum. If the container exceeds the memory limit, Kubernetes kills it (OOMKilled). If it exceeds CPU limit, it is throttled.

Without limits, one misbehaving pod can starve every other pod on the node.

---

## Fix 4 — Default Service Account (K8S-04)

**File:** `k8s/deployment.yaml` + new `k8s/serviceaccounts.yaml`  
**CVSS:** 7.5 — High

### Problem
```yaml
serviceAccountName: default
```
The default service account inherits permissions from cluster setup and often has broad API access. An attacker inside a pod can use the auto-mounted service account token to make Kubernetes API calls:

```bash
# Inside any pod using default service account
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
curl -H "Authorization: Bearer $TOKEN" https://kubernetes.default.svc/api/v1/secrets
```

If the default service account has read access to secrets — every secret in the cluster is exposed.

### Fix — Dedicated service accounts with token automounting disabled
```yaml
# deployment.yaml
serviceAccountName: pearlpay-api-sa
```

```yaml
# serviceaccounts.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pearlpay-api-sa
  namespace: default
automountServiceAccountToken: false  # no token mounted unless explicitly needed
```

`automountServiceAccountToken: false` means no Kubernetes API credentials are mounted into the pod at all. An attacker inside the container has no token to steal.

---

## Fix 5 — Secrets Not Encrypted at Rest (K8S-05)

**File:** `k8s/secrets.yaml` updated + new `k8s/encryption-config.yaml`  
**CVSS:** 9.1 — Critical  
**Semgrep Finding:** F-10

### Problem
Kubernetes Secrets are base64-encoded by default — not encrypted. Anyone with access to etcd (the Kubernetes datastore) or the secrets manifest can decode every secret instantly:

```bash
echo "c2VjcmV0MTIz" | base64 -d
# → secret123
```

### Fix — Two layers

**Layer 1 — Remove secrets from manifests entirely**
```yaml
# secrets.yaml
data: {}  # empty — Vault injects at runtime
annotations:
  security-note: "Secrets injected by External Secrets Operator from HashiCorp Vault"
```

**Layer 2 — Encryption at rest configuration**
```yaml
# encryption-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: pearlpay-secrets-key
              secret: REPLACE_WITH_BASE64_ENCODED_32_BYTE_KEY
      - identity: {}
```

This tells the Kubernetes API server to encrypt all Secret objects with AES-CBC before writing to etcd. Even with direct etcd access, secrets are unreadable without the encryption key.

**Full remediation** — completed in Phase 6 with HashiCorp Vault replacing Kubernetes Secrets entirely.

---

## Fix 6 — No Network Policies (K8S-06)

**File:** new `k8s/networkpolicy.yaml`  
**CVSS:** 7.5 — High

### Problem
By default Kubernetes allows all pods to communicate with all other pods. If an attacker compromises the frontend pod, they can make direct database connections, call internal APIs, and move laterally across the cluster.

### Fix — Least privilege network rules
```yaml
# API can only receive traffic from frontend, only send to postgres and redis
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: pearlpay-api-network-policy
spec:
  podSelector:
    matchLabels:
      app: pearlpay-api
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: pearlpay-frontend
      ports:
        - protocol: TCP
          port: 8000
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: postgres
      ports:
        - protocol: TCP
          port: 5432
    - to:
        - podSelector:
            matchLabels:
              app: redis
      ports:
        - protocol: TCP
          port: 6379
```

### What this prevents

| Attack | Without NetworkPolicy | With NetworkPolicy |
|---|---|---|
| Frontend → Database direct connection | ✅ Possible | ❌ Blocked |
| Compromised pod → internal API calls | ✅ Possible | ❌ Blocked |
| Lateral movement across cluster | ✅ Possible | ❌ Blocked |
| Database port scanning from pods | ✅ Possible | ❌ Blocked |

---

## Files Changed

| File | Action | Purpose |
|---|---|---|
| `k8s/deployment.yaml` | Modified | Non-root, no privileges, resource limits, dedicated SAs |
| `k8s/secrets.yaml` | Modified | Removed base64 secrets, added Vault annotation |
| `k8s/serviceaccounts.yaml` | Created | Dedicated service accounts with token automounting disabled |
| `k8s/encryption-config.yaml` | Created | AES-CBC encryption at rest for Kubernetes Secrets |
| `k8s/networkpolicy.yaml` | Created | Least privilege network rules between pods |

---

## Before vs After

| Security Control | Before | After |
|---|---|---|
| Container user | root (uid=0) | non-root (uid=1000) |
| Privileged mode | true | removed |
| Privilege escalation | allowed | false |
| Root filesystem writes | allowed | readOnly |
| Linux capabilities | all | none (drop ALL) |
| Resource limits | none | CPU + memory limits |
| Service account | default (shared) | dedicated per workload |
| SA token automount | true | false |
| Secrets storage | base64 only | Vault-backed (Phase 6) |
| Network isolation | none | least privilege policies |

---

## What I Learned

1. **Infrastructure security is the blast radius multiplier** — application vulnerabilities have limited impact when the infrastructure is hardened. Container escapes, lateral movement, and secret theft all depend on permissive infrastructure configuration. Fixing the app code is not enough.

2. **Base64 is not encryption** — this seems obvious but Kubernetes Secrets are widely misunderstood. Many teams assume their secrets are secure because they're in a Secret resource. One `base64 -d` command proved otherwise. Real secret security requires either encryption at rest (etcd-level) or external secret management (Vault).

3. **Least privilege applies at every layer** — the same principle that drove our application fixes (never trust user input, only return what's needed) applies to infrastructure. Pods should only have the network access, filesystem access, and API permissions they need. Nothing more.

4. **`runAsNonRoot: true` is stronger than `runAsUser: 1000`** — setting a non-root user ID can be overridden by the container image. The `runAsNonRoot` flag enforces this at the Kubernetes scheduler level — the pod won't start if the image requires root. Defence in depth means layering controls so one misconfiguration doesn't undo another.

5. **Network policies are default-deny in practice** — Kubernetes allows all traffic by default. Creating even one NetworkPolicy for a pod switches it to default-deny for the policy types specified. This means you can incrementally add policies without breaking everything at once.

---

## Next Phase

[Phase 6 — Secret Management with HashiCorp Vault →](../phase-6-secrets/README.md)

---

## Resources

- [Kubernetes Security Best Practices](https://kubernetes.io/docs/concepts/security/)
- [NSA Kubernetes Hardening Guide](https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF)
- [CIS Kubernetes Benchmark](https://www.cisecurity.org/benchmark/kubernetes)
- [Kubernetes NetworkPolicy](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [Kubernetes Encryption at Rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
- [OWASP Kubernetes Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Kubernetes_Security_Cheat_Sheet.html)
