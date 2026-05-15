import json
import os
import random
import time
import traceback
from datetime import datetime

import jwt
import psycopg2
import psycopg2.extras
import redis
import requests
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

# // VULN: Secret Management - database credentials are hardcoded directly in source code.
DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql://payadmin:SuperSecretPassword123!@postgres:5432/payments",
)
# // FIXED: Broken Authentication - JWT secret is loaded from the JWT_SECRET environment variable instead of a hardcoded weak value.
JWT_SECRET = os.environ.get("JWT_SECRET")
if not JWT_SECRET:
    raise RuntimeError("JWT_SECRET environment variable is not set. Refusing to start.")
# // VULN: Secret Management - OpenAI API key is hardcoded directly in source code.
OPENAI_API_KEY = "sk-proj-realisticTrainingKey1234567890"
# // VULN: Secret Management - dummy AWS access key is hardcoded directly in source code.
AWS_ACCESS_KEY_ID = "AKIA0000EXAMPLE"
# // VULN: Secret Management - dummy AWS secret key is hardcoded directly in source code.
AWS_SECRET_ACCESS_KEY = "wJalrXexample"
# // VULN: Secret Management - Redis password is hardcoded directly in source code.
REDIS_PASSWORD = "redis-P@ssw0rd-Prod"
APP_VERSION = "1.0.0-vulnerable"
ENVIRONMENT = os.getenv("APP_ENV", "development")
FRAUD_SYSTEM_PROMPT = (
    "You are RiskOracle, a payment fraud analyst. Review transactions and return "
    "a short risk decision with operational details."
)

app = FastAPI(
    title="PearlPay Payment Platform",
    version=APP_VERSION,
    # // VULN: Security Misconfiguration - debug mode is enabled in the API process.
    debug=True,
)

# // VULN: Security Misconfiguration - CORS allows every origin, method, and header.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def get_db():
    return psycopg2.connect(DATABASE_URL)


def get_redis():
    return redis.Redis(host="redis", port=6379, password=REDIS_PASSWORD, decode_responses=True)


def query_db(sql, params=None):
    with get_db() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            if params:
                for index in range(len(params), 0, -1):
                    sql = sql.replace(f"${index}", "%s")
                cur.execute(sql, params)
            else:
                cur.execute(sql)
            if cur.description:
                return cur.fetchall()
            return []


def execute_db(sql):
    with get_db() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(sql)
            if cur.description:
                return cur.fetchall()
            return []


def sql_literal(value):
    if value is None:
        return ""
    return str(value).replace("'", "''")


def decode_user(authorization: str | None):
    if not authorization:
        raise HTTPException(status_code=401, detail="Missing Authorization header")
    token = authorization.replace("Bearer ", "")
    return jwt.decode(token, JWT_SECRET, algorithms=["HS256"])


def create_weak_session_token(user_id):
    # // VULN: Broken Authentication - session token is short and predictable from user ID and timestamp.
    return f"sess-{user_id}-{int(time.time())}"


def serialize_transaction(row):
    return {
        "id": row["id"],
        "user_id": row["user_id"],
        # // VULN: Sensitive Data Exposure - full card number and CVV are returned in plaintext API responses.
        "card_number": row["card_number"],
        "cvv": row["cvv"],
        "amount": float(row["amount"]),
        "merchant": row["merchant"],
        "status": row["status"],
        "fraud_result": row["fraud_result"],
        "created_at": row["created_at"].isoformat() if row["created_at"] else None,
    }


@app.exception_handler(Exception)
async def verbose_exception_handler(request: Request, exc: Exception):
    # // VULN: Security Misconfiguration - stack traces are exposed in API error responses.
    # // VULN: API Security - verbose errors reveal internal schema, field names, and implementation details.
    return JSONResponse(
        status_code=500,
        content={
            "error": str(exc),
            "trace": traceback.format_exc(),
            "path": str(request.url),
            "schema_hint": "users(id,email,password,role), transactions(card_number,cvv,merchant)",
        },
    )


@app.on_event("startup")
def startup():
    for attempt in range(30):
        try:
            with get_db() as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        """
                        CREATE TABLE IF NOT EXISTS users (
                            id SERIAL PRIMARY KEY,
                            email TEXT UNIQUE NOT NULL,
                            password TEXT NOT NULL,
                            full_name TEXT NOT NULL,
                            role TEXT NOT NULL DEFAULT 'user',
                            created_at TIMESTAMP NOT NULL DEFAULT NOW()
                        );
                        CREATE TABLE IF NOT EXISTS transactions (
                            id SERIAL PRIMARY KEY,
                            user_id INTEGER NOT NULL REFERENCES users(id),
                            card_number TEXT NOT NULL,
                            cvv TEXT NOT NULL,
                            amount NUMERIC NOT NULL,
                            merchant TEXT NOT NULL,
                            status TEXT NOT NULL,
                            fraud_result TEXT,
                            webhook_url TEXT,
                            created_at TIMESTAMP NOT NULL DEFAULT NOW()
                        );
                        CREATE TABLE IF NOT EXISTS webhooks (
                            id SERIAL PRIMARY KEY,
                            transaction_id INTEGER,
                            merchant TEXT,
                            webhook_url TEXT,
                            payload TEXT,
                            created_at TIMESTAMP NOT NULL DEFAULT NOW()
                        );
                        """
                    )
                    cur.execute("SELECT COUNT(*) FROM users")
                    user_count = cur.fetchone()[0]
                    if user_count == 0:
                        cur.execute(
                            """
                            INSERT INTO users (email, password, full_name, role)
                            VALUES
                            ('ava@example.com', 'password123', 'Ava Morgan', 'user'),
                            ('admin@pearlpay.example', 'admin123', 'Nina Admin', 'admin');
                            """
                        )
                    cur.execute("SELECT COUNT(*) FROM transactions")
                    txn_count = cur.fetchone()[0]
                    if txn_count == 0:
                        cur.execute(
                            """
                            INSERT INTO transactions (user_id, card_number, cvv, amount, merchant, status, fraud_result, webhook_url)
                            VALUES
                            (1, '4111111111111111', '123', 124.50, 'Northstar Coffee', 'approved', 'low risk - recurring local merchant', 'https://merchant.example/webhook'),
                            (1, '5555555555554444', '456', 18950.00, 'Atlas Industrial Supply', 'review', 'medium risk - unusually high amount', 'https://merchant.example/webhook'),
                            (2, '4000056655665556', '987', 42000.00, '<img src=x onerror=alert(\"stored-xss\")> Luxury Imports', 'approved', 'high value approved by admin override', 'https://luxury.example/webhook');
                            """
                        )
                conn.commit()
            try:
                get_redis().set("startup:last", datetime.utcnow().isoformat())
            except Exception:
                pass
            break
        except Exception:
            if attempt == 29:
                raise
            time.sleep(1)


@app.get("/api/health")
def health():
    return {"status": "ok", "version": APP_VERSION, "environment": ENVIRONMENT}


@app.post("/api/register")
async def register(request: Request):
    payload = await request.json()
    email = payload.get("email", "")
    password = payload.get("password", "")
    full_name = payload.get("full_name", "")
    # // VULN: Mass Assignment - role is accepted from the request body and stored directly.
    role = payload.get("role", "user")
    sql = (
        "INSERT INTO users (email, password, full_name, role) VALUES "
        f"('{sql_literal(email)}', '{sql_literal(password)}', '{sql_literal(full_name)}', '{sql_literal(role)}') "
        "RETURNING id, email, full_name, role, created_at"
    )
    user = execute_db(sql)[0]
    return {"user": dict(user)}


@app.post("/api/login")
async def login(request: Request):
    payload = await request.json()
    email = payload.get("email", "")
    password = payload.get("password", "")
    # // VULN: Broken Authentication - no rate limiting or lockout is implemented for login attempts.
    # // FIXED: SQL Injection - login query now uses parameterised $1/$2 placeholders instead of raw string concatenation.
    sql = "SELECT * FROM users WHERE email = $1 AND password = $2"
    users = query_db(sql, (email, password))
    if not users:
        raise HTTPException(status_code=401, detail="Invalid email/password for users.password")
    user = users[0]
    session_token = create_weak_session_token(user["id"])
    token = jwt.encode(
        {"sub": str(user["id"]), "email": user["email"], "role": user["role"], "iat": int(time.time())},
        JWT_SECRET,
        algorithm="HS256",
    )
    try:
        get_redis().set(f"session:{session_token}", user["email"])
    except Exception:
        pass
    return {
        "token": token,
        "session_token": session_token,
        "user": {"id": user["id"], "email": user["email"], "full_name": user["full_name"], "role": user["role"]},
    }


@app.post("/api/payments")
async def submit_payment(request: Request, authorization: str | None = Header(default=None)):
    user = decode_user(authorization)
    payload = await request.json()
    # // VULN: API Security - payment submission uses raw request JSON with no input validation or schema enforcement.
    card_number = payload.get("card_number", "")
    cvv = payload.get("cvv", "")
    amount = payload.get("amount", 0)
    merchant = payload.get("merchant", "")
    webhook_url = payload.get("webhook_url", "")
    fraud = detect_fraud(payload)
    status = "review" if "high" in fraud.lower() else random.choice(["approved", "approved", "settled"])
    sql = (
        "INSERT INTO transactions (user_id, card_number, cvv, amount, merchant, status, fraud_result, webhook_url) VALUES "
        f"({user['sub']}, '{sql_literal(card_number)}', '{sql_literal(cvv)}', {amount}, "
        f"'{sql_literal(merchant)}', '{status}', '{sql_literal(fraud)}', '{sql_literal(webhook_url)}') "
        "RETURNING *"
    )
    row = execute_db(sql)[0]
    notify_payload = {"transaction_id": row["id"], "status": row["status"], "amount": float(row["amount"])}
    if webhook_url:
        try:
            requests.post(webhook_url, json=notify_payload, timeout=1)
        except Exception:
            pass
    return {"transaction": serialize_transaction(row), "fraud_metadata": {"system_prompt": FRAUD_SYSTEM_PROMPT}}


@app.get("/api/transactions")
def list_my_transactions(authorization: str | None = Header(default=None), merchant: str = ""):
    user = decode_user(authorization)
    # // FIXED: SQL Injection - transaction search now uses parameterised $1/$2 placeholders instead of raw string concatenation.
    sql = "SELECT * FROM transactions WHERE user_id = $1 AND merchant ILIKE $2 ORDER BY created_at DESC"
    rows = query_db(sql, (user["sub"], f"%{merchant}%"))
    return {"transactions": [serialize_transaction(row) for row in rows]}


@app.get("/api/transactions/{transaction_id}")
def get_transaction(transaction_id: int, authorization: str | None = Header(default=None)):
    decode_user(authorization)
    # // VULN: IDOR - transaction ownership is not checked before returning a transaction by ID.
    rows = query_db(f"SELECT * FROM transactions WHERE id = {transaction_id}")
    if not rows:
        raise HTTPException(status_code=404, detail="transactions.id not found")
    return {"transaction": serialize_transaction(rows[0])}


@app.get("/api/admin/transactions")
def admin_transactions(admin: str = "false"):
    # // VULN: Broken Access Control - admin access checks only the query parameter ?admin=true.
    if admin != "true":
        raise HTTPException(status_code=403, detail="Pass admin=true to access admin dashboard")
    rows = query_db("SELECT * FROM transactions ORDER BY created_at DESC")
    return {"transactions": [serialize_transaction(row) for row in rows]}


@app.post("/api/webhooks/merchant")
async def receive_merchant_webhook(request: Request):
    payload = await request.json()
    # // VULN: API Security - webhook endpoint has no authentication or API rate limiting.
    sql = (
        "INSERT INTO webhooks (transaction_id, merchant, webhook_url, payload) VALUES "
        f"({payload.get('transaction_id', 'NULL')}, '{sql_literal(payload.get('merchant', 'unknown'))}', "
        f"'{sql_literal(payload.get('webhook_url', ''))}', '{sql_literal(json.dumps(payload))}') RETURNING *"
    )
    row = execute_db(sql)[0]
    return {"received": True, "webhook": dict(row)}


@app.post("/api/fraud/analyze")
async def fraud_analyze(request: Request, authorization: str | None = Header(default=None)):
    decode_user(authorization)
    payload = await request.json()
    result = detect_fraud(payload)
    return {
        # // VULN: AI/LLM Security - the system prompt is exposed in API response metadata.
        "metadata": {"system_prompt": FRAUD_SYSTEM_PROMPT, "model": "gpt-4o-mini"},
        # // VULN: AI/LLM Security - LLM output is returned directly with no validation.
        "result": result,
    }


def detect_fraud(payload):
    # // VULN: AI/LLM Security - raw, unsanitized user input is sent directly to the LLM prompt.
    prompt = f"{FRAUD_SYSTEM_PROMPT}\nTransaction payload:\n{json.dumps(payload)}"
    if os.getenv("LIVE_LLM_CALL", "false").lower() == "true":
        response = requests.post(
            "https://api.openai.com/v1/chat/completions",
            headers={"Authorization": f"Bearer {OPENAI_API_KEY}", "Content-Type": "application/json"},
            json={
                "model": "gpt-4o-mini",
                "messages": [
                    {"role": "system", "content": FRAUD_SYSTEM_PROMPT},
                    {"role": "user", "content": prompt},
                ],
            },
            timeout=3,
        )
        return response.json()["choices"][0]["message"]["content"]
    amount = float(payload.get("amount", 0) or 0)
    merchant = payload.get("merchant", "unknown merchant")
    if amount > 25000:
        return f"High risk: {merchant} transaction exceeds normal approval bands. Prompt reviewed: {prompt[:240]}"
    return f"Low risk: {merchant} transaction appears consistent. Prompt reviewed: {prompt[:240]}"
