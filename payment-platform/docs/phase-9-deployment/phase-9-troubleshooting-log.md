# Phase 9 — EKS Deployment Troubleshooting Log

**Date:** 31 May 2026  
**Author:** <!-- your name -->  
**Cluster:** pearlpay-training (eu-west-2)

---

## Overview

This log documents every issue encountered during the live deployment of PearlPay to AWS EKS, the root cause of each problem, and how it was resolved. Each issue maps to a specific networking or Kubernetes concept.

---

## Issue 1 — ErrImagePull on all pods

**Symptom:**
```
NAME                    STATUS         
pearlpay-api-xxx        ErrImagePull   
pearlpay-frontend-xxx   ErrImagePull   
```

**Root cause:**
The Kubernetes manifests referenced `pearlpay/backend:latest` and `pearlpay/frontend:latest` — Docker Hub image names. The EKS cluster had no access to Docker Hub images built locally on a Windows machine. Images only existed on the local Docker Desktop instance.

**Networking concept:**
EKS worker nodes pull images from a container registry at startup. Without a registry, pods cannot start. This is like trying to install software from a USB drive that isn't plugged into the server.

**Fix:**
1. Created ECR (Elastic Container Registry) repositories in AWS
2. Built and tagged images with the ECR URL
3. Pushed images to ECR
4. Updated `k8s/deployment.yaml` with ECR image URLs

```bash
aws ecr create-repository --repository-name pearlpay/backend --region eu-west-2
docker build -t 387390481270.dkr.ecr.eu-west-2.amazonaws.com/pearlpay/backend:latest ./backend
docker push 387390481270.dkr.ecr.eu-west-2.amazonaws.com/pearlpay/backend:latest
```

**Lesson:** Always build and push images to a registry accessible by the cluster before deploying. Local Docker images are invisible to remote clusters.

---

## Issue 2 — API pod crashing: missing environment variables

**Symptom:**
```
RuntimeError: Missing required environment variables: JWT_SECRET, DATABASE_URL, REDIS_PASSWORD
```

**Root cause:**
The `k8s/secrets.yaml` file was deliberately emptied in Phase 5 (as a security fix) — it had `data: {}`. The API's startup validation correctly refused to start without the required secrets.

**Networking concept:**
This is not a networking issue — it's a secrets management issue. Kubernetes Secrets must be populated before pods that depend on them can start. The app was doing exactly what it should: failing securely.

**Fix:**
Created the Kubernetes secret with real values using `kubectl create secret`:

```bash
kubectl create secret generic pearlpay-secrets \
  --from-literal=DATABASE_URL="postgresql://payadmin:PASSWORD@RDS_ENDPOINT/payments" \
  --from-literal=JWT_SECRET="aX9kL2mP5nQ8rT1uW4vY7zA3bC6dE0fG" \
  --from-literal=REDIS_PASSWORD="redis-P@ssw0rd-Prod" \
  --dry-run=client -o yaml | kubectl apply -f -
```

**Lesson:** In production, the External Secrets Operator pulls secrets from Vault automatically. For this training deployment, secrets were injected manually.

---

## Issue 3 — 502 Bad Gateway from nginx (no ingress controller)

**Symptom:**
```
curl: (52) Empty reply from server
```
Then after fixing security groups:
```html
<h1>502 Bad Gateway</h1><hr><center>nginx</center>
```

**Root cause (part 1 — empty reply):**
The EKS cluster security group (`sg-08808e6c0e2201c3b`) had no inbound rule for port 80. The Network Load Balancer created by the nginx ingress controller could not forward traffic to the worker nodes.

**Root cause (part 2 — 502):**
No nginx ingress controller was installed. The Ingress resource existed in Kubernetes but with `class: none` — no controller was watching it. This is like having a postal address but no post office to process the mail.

**Networking concept:**
Kubernetes Ingress is just a routing rule definition. It does nothing without an ingress controller — a pod that reads those rules and actually forwards traffic. The nginx ingress controller creates its own Load Balancer in AWS and watches all Ingress resources.

**Fix:**
```bash
# Add inbound rules to EKS cluster security group
aws ec2 authorize-security-group-ingress \
  --group-id sg-08808e6c0e2201c3b \
  --protocol tcp --port 80 --cidr 0.0.0.0/0

# Install nginx ingress controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/aws/deploy.yaml
```

**Lesson:** Nginx ingress controller is not included in EKS by default. It must be installed separately. The controller creates its own NLB — this is different from any load balancers created by Terraform.

---

## Issue 4 — 502 Bad Gateway from nginx (network policy blocking)

**Symptom:**
Nginx running, pods running, service has endpoints — but still 502. Nginx logs showed:
```
connect() failed (111: Connection refused) while connecting to upstream
client: 86.29.30.2, upstream: "http://10.0.2.202:8000/api/health"
```

**Root cause:**
The `pearlpay-api-network-policy` only allowed ingress from pods labelled `app=pearlpay-frontend`. The nginx ingress controller pods are in the `ingress-nginx` namespace with different labels — they were blocked by the network policy from reaching the API pods.

**Networking concept:**
Network policies in Kubernetes are a pod-level firewall. Even though the service had the correct endpoints (pod IPs), the network policy silently dropped packets from nginx to the API. Connection refused at the pod level looks identical to a service misconfiguration from the outside.

**Fix:**
Added an ingress rule to the network policy allowing traffic from the `ingress-nginx` namespace:

```bash
kubectl patch networkpolicy pearlpay-api-network-policy --type=json -p='[{
  "op": "add",
  "path": "/spec/ingress/-",
  "value": {
    "from": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "ingress-nginx"}}}],
    "ports": [{"protocol": "TCP", "port": 8000}]
  }
}]'
```

**Lesson:** Network policies must account for all legitimate traffic sources — including infrastructure components like ingress controllers, monitoring agents, and service meshes. A policy that only allows app-to-app traffic will silently block infrastructure traffic.

---

## Issue 5 — App startup hanging: readOnlyRootFilesystem blocking uvicorn

**Symptom:**
```
INFO: Waiting for application startup.
```
App never progressed past this line. No error. Connection refused on port 8000 even from inside the pod.

**Root cause:**
The Kubernetes hardening in Phase 5 set `readOnlyRootFilesystem: true` in the container security context. Uvicorn (the Python web server) needs to write temporary files during startup — worker process files, hot-reload watchers. With a read-only filesystem, uvicorn started but could not complete initialisation. It silently hung rather than throwing an error.

**Networking concept:**
This is a container security vs application compatibility conflict. `readOnlyRootFilesystem: true` is a best practice that prevents attackers from writing malware or tools to the container. But it requires applications to be explicitly designed to not write to the local filesystem — they must use mounted volumes for any writes.

**Fix (temporary):**
```bash
kubectl patch deployment pearlpay-api --type=json -p='[{
  "op": "replace",
  "path": "/spec/template/spec/containers/0/securityContext/readOnlyRootFilesystem",
  "value": false
}]'
```

**Proper fix (production):**
Add a writable `emptyDir` volume mounted at `/tmp` and configure uvicorn to use it:
```yaml
volumes:
  - name: tmp
    emptyDir: {}
volumeMounts:
  - name: tmp
    mountPath: /tmp
```

**Lesson:** Hardening controls must be tested against the actual application. `readOnlyRootFilesystem: true` is the right security control but requires application-level changes to work correctly.

---

## Issue 6 — Frontend crashing: permission denied on vite.config.js

**Symptom:**
```
Error: EACCES: permission denied, open '/app/vite.config.js.timestamp-xxx.mjs'
```

**Root cause:**
Two layered issues:
1. `vite.config.js` was not tracked by git (`git status` showed it as untracked) — so Docker built the image without the config file
2. `runAsUser: 1000` in the pod security context meant the container ran as a non-root user, but files in `/app` were owned by root (built by root during `docker build`)

**Networking concept:**
Not a networking issue — a file ownership and container security conflict. When `runAsUser: 1000` is set, the container process cannot write to files owned by root. The correct fix is to set file ownership during the Docker build using `chown`.

**Fix (immediate):**
```bash
# Track the missing file
git add frontend/vite.config.js
git commit -m "fix: add vite config with allowedHosts"

# Force run as root temporarily for training
kubectl patch deployment pearlpay-frontend --type=json -p='[
  {"op": "replace", "path": "/spec/template/spec/securityContext/runAsUser", "value": 0},
  {"op": "replace", "path": "/spec/template/spec/securityContext/runAsNonRoot", "value": false}
]'
```

**Proper fix (production):**
Add to frontend Dockerfile:
```dockerfile
RUN chown -R node:node /app
USER node
```

**Lesson:** Security controls that change the running user ID must be paired with correct file ownership in the Docker image. `runAsNonRoot` is correct security posture — the application just needs to be built to support it.

---

## Issue 7 — App startup hanging: RDS unreachable

**Symptom:**
```
INFO: Waiting for application startup.
```
(Same symptom as Issue 5 but different cause)

**Root cause:**
The DATABASE_URL secret was created with an empty password — the shell escaped the `!` character in the password `fyxYg=5t!igNXhG7g*...` when creating the Kubernetes secret. The app was connecting to RDS with a blank password which failed authentication, causing the 30-retry startup loop to exhaust silently.

Additionally, the RDS security group only allowed inbound connections from the Terraform-defined API security group, not from the EKS cluster security group that the pods actually used. Port 5432 was effectively blocked.

**Networking concept:**
This is a security group chaining issue. In Terraform we defined: API SG → RDS SG on port 5432. But the EKS pods don't use the Terraform API SG — they use the EKS cluster security group created automatically by AWS. So the rule never applied to the actual pods.

**Fix:**
```bash
# Get RDS security group
aws rds describe-db-instances --query "DBInstances[?DBInstanceIdentifier=='pearlpay-payments'].VpcSecurityGroups[*].VpcSecurityGroupId"

# Allow EKS cluster SG to reach RDS
aws ec2 authorize-security-group-ingress \
  --group-id sg-00c1e4e3cad809a64 \  # RDS SG
  --protocol tcp --port 5432 \
  --source-group sg-08808e6c0e2201c3b  # EKS cluster SG
```

**Lesson:** Terraform-defined security groups and AWS-auto-created security groups (like the EKS cluster SG) are separate. Always verify actual traffic paths using `aws ec2 describe-security-group-rules` rather than assuming Terraform rules apply.

---

## Issue 8 — Redis not running in cluster

**Symptom:**
API started but Redis connection failed at runtime, causing session storage errors.

**Root cause:**
Redis was defined in `docker-compose.yml` for local development but had no Kubernetes manifest. The `REDIS_PASSWORD` secret was set but there was no Redis service for the API to connect to at `redis:6379`.

**Fix:**
```bash
kubectl create deployment redis --image=redis:7-alpine -- redis-server --requirepass redis-P@ssw0rd-Prod
kubectl expose deployment redis --port=6379 --name=redis
```

**Lesson:** Docker Compose services do not automatically become Kubernetes deployments. Every service needs its own Kubernetes manifest. Redis, Vault, and any other dependencies must be explicitly deployed to the cluster.

---

## Issue 9 — Browser shows 404 despite curl working

**Symptom:**
`curl -H "Host: api.pearlpay.example" http://ELB_URL/api/health` returned `{"status":"ok"}` but visiting the ELB URL in the browser showed 404.

**Root cause:**
The nginx ingress uses host-based routing — it routes requests based on the `Host` HTTP header. The browser sends `Host: aee1a3b3...elb.eu-west-2.amazonaws.com` (the actual URL), but the ingress rules expect `Host: api.pearlpay.example`. No rule matched, so nginx returned 404.

**Networking concept:**
Host-based routing is how one load balancer serves multiple applications. The ingress reads the `Host` header and routes to different backends. Without a real domain pointing to the ELB, you have to trick the browser by adding hosts file entries.

**Fix:**
Added entries to `C:\Windows\System32\drivers\etc\hosts`:
```
13.43.153.239 app.pearlpay.example
13.43.153.239 api.pearlpay.example
```

**Production fix:**
Create a DNS CNAME record pointing `pearlpay.pearlservices.co.uk` to the ELB hostname. Cloudflare handles this automatically after domain setup.

---

## Summary — Issues by category

| Category | Issues | Key learning |
|---|---|---|
| Container registry | Issue 1 | Always push to ECR before deploying to EKS |
| Secrets management | Issue 2, 8 | Empty secrets and missing services must be provisioned separately |
| Security group rules | Issue 3, 7 | Terraform SGs ≠ AWS auto-created SGs. Verify actual paths |
| Ingress controller | Issue 3 | Nginx ingress controller must be installed — not included in EKS |
| Network policy | Issue 4 | Include ingress-nginx namespace in API network policy |
| Security hardening | Issue 5, 6 | readOnlyRootFilesystem and runAsNonRoot require app-level support |
| DNS/routing | Issue 9 | Host-based routing requires real DNS or hosts file entries |

---

## Commands reference — useful for next deployment

```bash
# Check pod status
kubectl get pods

# Check pod logs
kubectl logs -l app=pearlpay-api --tail=50

# Check service endpoints
kubectl get endpoints pearlpay-api

# Check ingress
kubectl describe ingress pearlpay-ingress

# Check security group rules
aws ec2 describe-security-group-rules --filters "Name=group-id,Values=SG_ID"

# Force pod restart
kubectl rollout restart deployment/pearlpay-api

# Check EKS nodes
kubectl get nodes

# Connect kubectl to cluster
aws eks update-kubeconfig --name pearlpay-training --region eu-west-2

# Get ELB DNS name
kubectl get services -n ingress-nginx
```

---

## Next deployment checklist

Before running `terraform apply` and `kubectl apply` next time, verify:

- [ ] ECR repositories exist and images are pushed
- [ ] `k8s/secret.yaml` has real values (not empty `data: {}`)
- [ ] `k8s/deployment.yaml` has ECR image URLs
- [ ] `k8s/networkpolicy.yaml` includes ingress-nginx namespace rule
- [ ] `readOnlyRootFilesystem: false` in deployment (or emptyDir volume mounted)
- [ ] Nginx ingress controller installed after cluster creation
- [ ] EKS cluster SG has port 80/443 inbound rule added manually
- [ ] RDS SG has port 5432 inbound from EKS cluster SG
- [ ] Redis deployed to cluster
- [ ] Hosts file updated OR real DNS configured
