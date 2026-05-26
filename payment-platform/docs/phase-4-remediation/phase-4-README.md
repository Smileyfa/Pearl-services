# Phase 4 — Vulnerability Remediation

**Phase status:** ✅ Complete  
**Vulnerabilities fixed:** 9  
**Date completed:** 22 May 2026  
**Author:** Rasaq Bello

---

## Objective

Remediate all P1 and P2 vulnerabilities identified in Phases 2 and 3. For each vulnerability: exploit it from the UI or terminal to prove it is real, implement the fix using secure coding practices, and verify the exploit no longer works after the fix.

---

## Approach

Every vulnerability was worked through in this order:

```
1. Understand the vulnerable code
2. Exploit it from the UI (no code access — attacker perspective)
3. Implement the fix
4. Verify the exploit is dead
5. Commit with a descriptive message
```

This mirrors real security engineering — fixes without proof of exploitability are just assumptions.

---

## Fix 1 — SQL Injection (F-04)

**File:** `backend/main.py`  
**CVSS:** 9.8 — Critical  
**Priority:** P1

### Business Risk
Any attacker could log into any account without knowing the password by typing `' OR '1'='1'--` into the login form. Once authenticated, the transaction search endpoint could be manipulated to dump every transaction in the database — card numbers, CVVs, and amounts for all customers. This is an immediate PCI-DSS breach.

### Exploitation (UI)
Navigated to `http://localhost:5173`, entered `' OR '1'='1'--` in the email field with any password. Logged straight in as Ava Morgan with no credentials.

### Vulnerable Code
```python
# Login endpoint
sql = f"SELECT * FROM users WHERE email = '{email}' AND password = '{password}'"

# Transaction search
sql = f"SELECT * FROM transactions WHERE user_id = {user['sub']} AND merchant ILIKE '%{merchant}%'"
```

### Fixed Code
```python
# Login endpoint
sql = "SELECT * FROM users WHERE email = $1 AND password = $2"
users = query_db(sql, (email, password))

# Transaction search
sql = "SELECT * FROM transactions WHERE user_id = $1 AND merchant ILIKE $2 ORDER BY created_at DESC"
rows = query_db(sql, (user["sub"], f"%{merchant}%"))
```

### Why This Works
The `$1`, `$2` placeholders tell the database driver to treat user input as pure data — never as SQL syntax. Even if an attacker types `' OR '1'='1'--` it is stored as a literal string, not executed as a command.

### Evidence
![SQL injection exploit](./exploit-sqli-ui-bypass)
![SQL injection fixed](./exploit-sqli-ui-fixed)

---

## Fix 2 — Hardcoded JWT Secret (F-05)

**File:** `backend/main.py`  
**CVSS:** 8.1 — High  
**Priority:** P1

### Business Risk
The JWT secret `secret123` was hardcoded in source code. Anyone who reads the code on GitHub can forge valid tokens for any user — including admin — without ever logging in. No credentials needed, no suspicious login attempts in logs, completely silent attack.

### Exploitation (UI)
1. Logged in as Ava, copied the JWT token from the Network tab
2. Pasted into jwt.io, changed `"role": "user"` to `"role": "admin"`
3. Entered `secret123` in the Verify Signature box — signature verified
4. Used forged token to access the admin endpoint — full database returned

### Vulnerable Code
```python
JWT_SECRET = "secret123"
```

### Fixed Code
```python
JWT_SECRET = os.environ.get("JWT_SECRET")
if not JWT_SECRET:
    raise RuntimeError("JWT_SECRET environment variable is not set. Refusing to start.")
```

### Why This Works
The secret is loaded from the environment at runtime — never stored in source code or git history. The `RuntimeError` ensures the app refuses to start if the secret is missing, rather than running insecurely with no secret.

### Evidence
![JWT token exposed](./exploit-jwt-network-token-exposed.png)
![JWT extracted token](./exploit-jwt-extracted-token.png)
![JWT admin access](./exploit-jwt-ui-admin-access.png)
![JWT forged admin access](./forged-jwt-admin-token.png)

---

## Fix 3 — Broken Access Control (A-08)

**File:** `backend/main.py`  
**CVSS:** 9.1 — Critical  
**Priority:** P1

### Business Risk
The admin endpoint was protected only by a `?admin=true` query parameter. Any user who discovered this — by reading error messages, inspecting network traffic, or reading public documentation — had full admin access to every transaction in the database.

### Exploitation (UI)
Ran in browser console with no authentication:
```javascript
fetch("http://localhost:8000/api/admin/transactions?admin=true")
  .then(r => r.json()).then(console.log)
```
Returned all transactions from all users with no token required.

### Vulnerable Code
```python
@app.get("/api/admin/transactions")
def admin_transactions(admin: str = "false"):
    if admin != "true":
        raise HTTPException(status_code=403, detail="Pass admin=true to access admin dashboard")
    rows = query_db("SELECT * FROM transactions ORDER BY created_at DESC")
    return {"transactions": [serialize_transaction(row) for row in rows]}
```

### Fixed Code
```python
@app.get("/api/admin/transactions")
def admin_transactions(authorization: str | None = Header(default=None)):
    user = decode_user(authorization)
    if user["role"] != "admin":
        raise HTTPException(status_code=403, detail="Admin role required")
    rows = query_db("SELECT * FROM transactions ORDER BY created_at DESC")
    return {"transactions": [serialize_transaction(row) for row in rows]}
```

### Why This Works
The endpoint now requires a valid JWT token with `role: admin`. A missing token, invalid token, or regular user token all return 403. The query parameter trick returns `"Missing Authorization header"`.

### Verification Results
| Scenario | Before | After |
|---|---|---|
| `?admin=true` no token | ✅ Full access | ❌ 403 |
| Regular user token | ✅ Full access | ❌ 403 Admin role required |
| Forged admin token | ✅ Full access | ✅ Still works (Phase 6) |

### Evidence
![Access control fixed](./exploit-access-control-fixed.png)

---

## Fix 4 — IDOR (A-04)

**File:** `backend/main.py`  
**CVSS:** 8.1 — High  
**Priority:** P1

### Business Risk
Any authenticated user could access any other user's transaction by changing the ID number in the API request. Logged in as User 1, an attacker could retrieve User 2's $42,000 transaction — including card number and CVV — just by requesting `/api/transactions/3` instead of `/api/transactions/1`.

### Exploitation (UI)
Logged in as Ava (User 1), ran in browser console:
```javascript
fetch("http://localhost:8000/api/transactions/3", {
  headers: {"Authorization": "Bearer AVA_TOKEN"}
}).then(r => r.json()).then(console.log)
```
Returned User 2's transaction with full card details.

### Vulnerable Code
```python
decode_user(authorization)  # result discarded — only checks token is valid
rows = query_db(f"SELECT * FROM transactions WHERE id = {transaction_id}")
```

### Fixed Code
```python
user = decode_user(authorization)  # result stored and used
rows = query_db(
    "SELECT * FROM transactions WHERE id = $1 AND user_id = $2",
    (transaction_id, user["sub"])
)
```

### Why This Works
The `AND user_id = $2` clause means the database only returns the transaction if it belongs to the requesting user. Even knowing transaction ID 3 exists, User 1 gets a 404 because the ownership check fails.

### Evidence
![IDOR exploit](./exploit-idor-before.png)
![IDOR fixed](./idor-after-fix.png)

---

## Fix 5 — Sensitive Data Exposure (A-09)

**File:** `backend/main.py`  
**CVSS:** 7.5 — High  
**Priority:** P1

### Business Risk
Full card numbers and CVVs were returned in every API response. Any vulnerability that exposed API responses — XSS, IDOR, network interception — also exposed complete payment card data. This is a direct PCI-DSS violation. CVV codes must never be stored or returned after a transaction is complete.

### Exploitation (UI)
Ran in browser console:
```javascript
fetch("http://localhost:8000/api/transactions?merchant=", {
  headers: {"Authorization": "Bearer TOKEN"}
}).then(r => r.json()).then(data => {
  data.transactions.forEach(t => {
    console.log(`Card: ${t.card_number} | CVV: ${t.cvv}`)
  })
})
```
Returned full card numbers and CVVs for all transactions.

### Vulnerable Code
```python
"card_number": row["card_number"],  # 4111111111111111
"cvv": row["cvv"],                  # 123
```

### Fixed Code
```python
"card_number": f"**** **** **** {str(row['card_number'])[-4:]}",  # **** **** **** 1111
"cvv": "***"                                                        # ***
```

### Why This Works
Only the last 4 digits of the card number are returned — sufficient for display purposes. CVV is replaced with `***` and never returned under any circumstances. This matches the industry standard used by every legitimate payment processor.

### Evidence
![Sensitive data exploit](./exploit-sensitive-data-before.png)
![Sensitive data console](./exploit-sensitive-data-console.png)
![Sensitive data console fixed](./exploit-sensitive-data-console-fix.png)
![Sensitive data fixed](./exploit-sensitive-data-fixed.png)

---

## Fix 6 — Debug Mode & Information Disclosure (A-06)

**File:** `backend/main.py`  
**CVSS:** 5.3 — Medium  
**Priority:** P2

### Business Risk
Debug mode exposed internal error details — variable names, framework information, database schema hints — to anyone who triggered an error. An attacker could fingerprint the exact technology stack and look up known CVEs. The error message `"Invalid email/password for users.password"` leaked the actual database table and column name.

### Exploitation (UI)
Visited `http://localhost:8000/api/transactions/abc` directly in the browser. Received:
```json
{"detail":[{"type":"int_parsing","loc":["path","transaction_id"],"msg":"Input should be a valid integer","input":"abc"}]}
```
Revealed: variable name `transaction_id`, validation framework (Pydantic), routing architecture.

### Fix Applied
```python
# Disabled debug mode
app = FastAPI(debug=False)

# Added generic exception handlers
@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request, exc):
    return JSONResponse(status_code=422, content={"detail": "Invalid request parameters"})

@app.exception_handler(Exception)
async def generic_exception_handler(request, exc):
    return JSONResponse(status_code=500, content={"detail": "Internal server error"})
```

### Evidence
![Debug mode exploit](./exploit-debug-mode-ui.png)
![Debug mode fixed](./exploit-debug-mode-fixed.png)

---

## Fix 7 — CORS Wildcard (A-07)

**File:** `backend/main.py`  
**CVSS:** 6.5 — Medium  
**Priority:** P2

### Business Risk
`allow_origins=["*"]` combined with `allow_credentials=True` meant any website on the internet could make authenticated API requests on behalf of a logged-in PearlPay user. A phishing site could silently steal transaction data just by getting a victim to visit it while logged in.

### Exploitation
```bash
curl -I -H "Origin: http://evil-attacker.com" http://localhost:8000/api/health
```
Response:
```
access-control-allow-origin: http://evil-attacker.com
access-control-allow-credentials: true
```
The server approved `evil-attacker.com` as a trusted origin.

### Vulnerable Code
```python
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_credentials=True,
    allow_methods=["*"], allow_headers=["*"])
```

### Fixed Code
```python
app.add_middleware(CORSMiddleware,
    allow_origins=["http://localhost:5173"],
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "DELETE"],
    allow_headers=["Authorization", "Content-Type"])
```

---

## Fix 8 — Missing Security Headers (D-02, D-04, D-07)

**File:** `backend/main.py`  
**CVSS:** 6.1 — Medium  
**Priority:** P2

### Business Risk
Missing security headers left users exposed to XSS attacks, clickjacking, and MIME sniffing. Without CSP, any injected script executes freely. Without X-Frame-Options, the payment page can be embedded in a malicious iframe to trick users into authorising payments they didn't intend to make.

### Exploitation
```bash
curl -I http://localhost:8000/api/health
```
No security headers present in response. Server banner revealed `uvicorn` — technology fingerprinting.

### Fixed Code
```python
@app.middleware("http")
async def add_security_headers(request, call_next):
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Content-Security-Policy"] = "default-src 'self'"
    response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    response.headers["X-XSS-Protection"] = "1; mode=block"
    response.headers["Server"] = "PearlPay"
    return response
```

### Evidence
![Security headers before](./exploit-security-headers-before.png)
![Security headers fixed](./exploit-security-headers-fixed.png)

---

## Fix 9 — Mass Assignment (A-10)

**File:** `backend/main.py`  
**CVSS:** 8.1 — High  
**Priority:** P2

### Business Risk
The registration endpoint accepted a `role` field from the request body and stored it directly. Any attacker could register as an admin user simply by adding `"role": "admin"` to a normal registration request — no exploitation required, just knowledge of the API.

### Exploitation
```bash
curl -X POST http://localhost:8000/api/register \
  -H "Content-Type: application/json" \
  -d '{"email": "hacker@evil.com", "password": "pass", "full_name": "Hacker", "role": "admin"}'
```
Response: `"role": "admin"` — self-registered as admin.

### Vulnerable Code
```python
role = payload.get("role", "user")  # attacker controls this
sql = f"INSERT INTO users ... VALUES ('{email}', '{password}', '{full_name}', '{role}')"
```

### Fixed Code
```python
role = "user"  # hardcoded — never from request body
sql = "INSERT INTO users (email, password, full_name, role) VALUES ($1, $2, $3, $4) RETURNING ..."
user = execute_db(sql, (email, password, full_name, role))[0]
```

### Verification
Sent `"role": "admin"` in registration request. Response returned `"role": "user"` — the field was ignored entirely.

### Evidence
![Exploit Mass assignment](./exploit-mass-assignment-before.png)
![Mass assignment fixed](./exploit-mass-assignment-fixed.png)

---

## Summary — All Fixes

| # | Vulnerability | ID | CVSS | Commit |
|---|---|---|---|---|
| 1 | SQL Injection | F-04 | 9.8 | `fix: remediate SQL injection with parameterised queries` |
| 2 | Hardcoded JWT Secret | F-05 | 8.1 | `fix: load JWT secret from environment variable` |
| 3 | Broken Access Control | A-08 | 9.1 | `fix: replace ?admin=true with JWT role check` |
| 4 | IDOR | A-04 | 8.1 | `fix: add ownership check to prevent IDOR` |
| 5 | Sensitive Data Exposure | A-09 | 7.5 | `fix: mask card number and remove CVV from responses` |
| 6 | Debug Mode | A-06 | 5.3 | `fix: disable debug mode and add generic exception handlers` |
| 7 | CORS Wildcard | A-07 | 6.5 | `fix: restrict CORS to frontend origin` |
| 8 | Missing Security Headers | D-02,04,07 | 6.1 | `fix: add security headers middleware` |
| 9 | Mass Assignment | A-10 | 8.1 | `fix: remove mass assignment from register endpoint` |

---

## What I Learned

1. **Exploit before fix, every time** — running the attack first proved the vulnerability was real and exploitable, not just a theoretical finding. The before/after evidence is what makes a remediation credible to anyone.

2. **Vulnerabilities chain together** — the most devastating attack combined hardcoded JWT secret + broken access control + sensitive data exposure in a single request. Fixing one without the others would have left the system partially exposed. Think in attack chains, not individual findings.

3. **Secure coding is about trust boundaries** — every fix came down to the same principle: never trust user input. SQL injection, mass assignment, and IDOR all happened because the application trusted data from the request body or URL. Parameterised queries, hardcoded roles, and ownership checks all enforce the boundary between trusted and untrusted data.

4. **Failing secure is a feature** — the JWT secret fix raises a `RuntimeError` if the secret is missing, refusing to start. A misconfigured app that crashes is safer than one that runs with no authentication. Building systems that fail loudly and safely is a core security engineering principle.

5. **Headers are free security** — adding five security headers took 10 lines of code and zero performance impact. CSP, X-Frame-Options, and HSTS provide meaningful browser-level protection for essentially no cost. There is no excuse for missing security headers in a production application.

---

## Next Phase

[Phase 5 — Kubernetes Security Hardening →](../phase-5-kubernetes/README.md)

---

## Resources

- [OWASP Secure Coding Practices](https://owasp.org/www-project-secure-coding-practices-quick-reference-guide/)
- [OWASP SQL Injection Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html)
- [OWASP JWT Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/JSON_Web_Token_for_Java_Cheat_Sheet.html)
- [OWASP Mass Assignment Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Mass_Assignment_Cheat_Sheet.html)
- [OWASP Clickjacking Defence](https://cheatsheetseries.owasp.org/cheatsheets/Clickjacking_Defense_Cheat_Sheet.html)
- [PCI-DSS Requirements](https://www.pcisecuritystandards.org/document_library/)
