# PearlPay Vulnerable Payment Platform

PearlPay is a deliberately vulnerable payment processing platform for DevSecOps learning. It includes user authentication, card payment submission, transaction history, an admin dashboard, merchant webhooks, AI-assisted fraud analysis, local Docker services, Kubernetes manifests, Terraform AWS infrastructure, and CI/CD workflow examples.

This application is intentionally unsafe and should only be used in an isolated lab environment.

## Architecture

```text
                         +----------------------+
                         |  GitHub Actions CI   |
                         +----------+-----------+
                                    |
                                    v
+-------------+       +-------------+------------+       +----------------+
| React SPA   | <---> | FastAPI Payment API      | <---> | PostgreSQL RDS |
| frontend    |       | auth, payments, admin    |       | transactions   |
+------+------+       +------+------+------------+       +----------------+
       |                     |      |
       |                     |      +--------------------+ 
       |                     |                           |
       v                     v                           v
+-------------+       +-------------+            +----------------+
| Admin UI    |       | Redis cache |            | AI/LLM fraud   |
| dashboard   |       | sessions    |            | detection API  |
+-------------+       +-------------+            +----------------+
                              |
                              v
                       +---------------+
                       | Merchant      |
                       | webhooks      |
                       +---------------+
```

## Local Setup

From this directory:

```bash
docker-compose up --build
```

Services:

- Frontend: http://localhost:5173
- Backend API: http://localhost:8000
- API health: http://localhost:8000/api/health
- PostgreSQL: localhost:5432
- Redis: localhost:6379

## Run the App and Create a Test Transaction

1. Start the stack:

   ```bash
   docker-compose up --build
   ```

2. Open http://localhost:5173.
3. Log in with the seeded user:
   - Email: `ava@example.com`
   - Password: `password123`
4. Submit a payment with sample data:
   - Card number: `4111111111111111`
   - CVV: `123`
   - Amount: `2499.95`
   - Merchant: `Blue Harbor Electronics`
   - Webhook URL: `https://merchant.example/webhooks/payments`
5. Review the payment in the transaction history and admin dashboard.

You can also create a transaction through the API:

```bash
TOKEN=$(curl -s http://localhost:8000/api/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"ava@example.com","password":"password123"}' | python -c 'import json,sys; print(json.load(sys.stdin)["token"])')

curl http://localhost:8000/api/payments \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"card_number":"5555555555554444","cvv":"456","amount":"18950.00","merchant":"Atlas Industrial Supply","webhook_url":"https://merchant.example/webhooks/payments"}'
```

## Known Vulnerabilities

## Security Roadmap
