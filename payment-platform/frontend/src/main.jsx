import React, { useEffect, useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import "./styles.css";

const API_BASE = import.meta.env.VITE_API_BASE || "http://localhost:8000";

function App() {
  const [auth, setAuth] = useState(null);
  const [mode, setMode] = useState("login");
  const [health, setHealth] = useState(null);
  const [transactions, setTransactions] = useState([]);
  const [adminTransactions, setAdminTransactions] = useState([]);
  const [selectedTransaction, setSelectedTransaction] = useState(null);
  const [fraudResult, setFraudResult] = useState("");
  const [error, setError] = useState("");
  const [merchantSearch, setMerchantSearch] = useState("");

  useEffect(() => {
    fetch(`${API_BASE}/api/health`)
      .then((res) => res.json())
      .then(setHealth)
      .catch(() => setHealth({ status: "offline" }));
  }, []);

  useEffect(() => {
    if (auth?.token) {
      loadTransactions();
      loadAdminTransactions();
    }
  }, [auth]);

  const totalVolume = useMemo(
    () => transactions.reduce((sum, txn) => sum + Number(txn.amount || 0), 0),
    [transactions]
  );

  async function api(path, options = {}) {
    const headers = { "Content-Type": "application/json", ...(options.headers || {}) };
    if (auth?.token) {
      headers.Authorization = `Bearer ${auth.token}`;
    }
    const response = await fetch(`${API_BASE}${path}`, { ...options, headers });
    const data = await response.json();
    if (!response.ok) {
      throw new Error(data.detail || data.error || "Request failed");
    }
    return data;
  }

  async function submitLogin(event) {
    event.preventDefault();
    setError("");
    const form = new FormData(event.currentTarget);
    try {
      const data = await api("/api/login", {
        method: "POST",
        body: JSON.stringify(Object.fromEntries(form.entries())),
      });
      setAuth(data);
    } catch (err) {
      setError(err.message);
    }
  }

  async function submitRegister(event) {
    event.preventDefault();
    setError("");
    const form = new FormData(event.currentTarget);
    try {
      const data = await api("/api/register", {
        method: "POST",
        body: JSON.stringify(Object.fromEntries(form.entries())),
      });
      setMode("login");
      setError(`Created ${data.user.email} with role ${data.user.role}. You can log in now.`);
    } catch (err) {
      setError(err.message);
    }
  }

  async function submitPayment(event) {
    event.preventDefault();
    setError("");
    const form = new FormData(event.currentTarget);
    const payload = Object.fromEntries(form.entries());
    payload.amount = payload.amount;
    try {
      const data = await api("/api/payments", {
        method: "POST",
        body: JSON.stringify(payload),
      });
      setFraudResult(data.transaction.fraud_result);
      event.currentTarget.reset();
      loadTransactions();
      loadAdminTransactions();
    } catch (err) {
      setError(err.message);
    }
  }

  async function loadTransactions(search = merchantSearch) {
    try {
      const data = await api(`/api/transactions?merchant=${encodeURIComponent(search)}`);
      setTransactions(data.transactions);
    } catch (err) {
      setError(err.message);
    }
  }

  async function loadAdminTransactions() {
    try {
      const data = await api("/api/admin/transactions?admin=true");
      setAdminTransactions(data.transactions);
    } catch (err) {
      setError(err.message);
    }
  }

  async function inspectTransaction(id) {
    try {
      const data = await api(`/api/transactions/${id}`);
      setSelectedTransaction(data.transaction);
    } catch (err) {
      setError(err.message);
    }
  }

  async function analyzeFraud(event) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    try {
      const data = await api("/api/fraud/analyze", {
        method: "POST",
        body: JSON.stringify(Object.fromEntries(form.entries())),
      });
      setFraudResult(`${data.result}\n\nSystem prompt: ${data.metadata.system_prompt}`);
    } catch (err) {
      setError(err.message);
    }
  }

  return (
    <main className="app-shell">
      <header className="hero">
        <nav>
          <div className="brand">
            <span className="brand-mark">P</span>
            <span>PearlPay</span>
          </div>
          <div className="status-pill">
            API {health?.status || "checking"} · {health?.environment || "unknown"}
          </div>
        </nav>
        <section className="hero-grid">
          <div>
            <p className="eyebrow">Payment operations console</p>
            <h1>Move money with real-time transaction visibility.</h1>
            <p className="subcopy">
              A polished training platform for payment workflows, merchant webhooks, admin review,
              and AI-assisted fraud decisions.
            </p>
          </div>
          <div className="metric-card">
            <span>Daily processing capacity</span>
            <strong>$2.0M</strong>
            <small>Simulated authorization, settlement, and review flows</small>
          </div>
        </section>
      </header>

      {error && <div className="alert">{error}</div>}

      {!auth ? (
        <section className="auth-layout">
          <div className="panel">
            <div className="tab-row">
              <button className={mode === "login" ? "active" : ""} onClick={() => setMode("login")}>
                Login
              </button>
              <button className={mode === "register" ? "active" : ""} onClick={() => setMode("register")}>
                Register
              </button>
            </div>
            {mode === "login" ? (
              <form onSubmit={submitLogin} className="form-stack">
                <label>Email<input name="email" defaultValue="ava@example.com" /></label>
                <label>Password<input name="password" type="password" defaultValue="password123" /></label>
                <button type="submit">Enter dashboard</button>
              </form>
            ) : (
              <form onSubmit={submitRegister} className="form-stack">
                <label>Full name<input name="full_name" defaultValue="Jordan Vale" /></label>
                <label>Email<input name="email" defaultValue="jordan@example.com" /></label>
                <label>Password<input name="password" type="password" defaultValue="password123" /></label>
                <label>Role<input name="role" defaultValue="admin" /></label>
                <button type="submit">Create account</button>
              </form>
            )}
          </div>
        </section>
      ) : (
        <section className="dashboard">
          <div className="welcome-card">
            <div>
              <p className="eyebrow">Signed in as {auth.user.email}</p>
              <h2>{auth.user.full_name}</h2>
            </div>
            <div className="token-box">Session {auth.session_token}</div>
          </div>

          <div className="stats-grid">
            <div className="stat"><span>Your transactions</span><strong>{transactions.length}</strong></div>
            <div className="stat"><span>Your processed volume</span><strong>${totalVolume.toLocaleString()}</strong></div>
            <div className="stat"><span>API version</span><strong>{health?.version}</strong></div>
          </div>

          <div className="content-grid">
            <section className="panel">
              <h3>Submit payment</h3>
              <form onSubmit={submitPayment} className="form-stack">
                <label>Card number<input name="card_number" defaultValue="4111111111111111" /></label>
                <label>CVV<input name="cvv" defaultValue="123" /></label>
                <label>Amount<input name="amount" defaultValue="2499.95" /></label>
                <label>Merchant<input name="merchant" defaultValue="Blue Harbor Electronics" /></label>
                <label>Merchant webhook<input name="webhook_url" defaultValue="https://merchant.example/webhooks/payments" /></label>
                <button type="submit">Authorize payment</button>
              </form>
            </section>

            <section className="panel">
              <h3>AI fraud analysis</h3>
              <form onSubmit={analyzeFraud} className="form-stack">
                <label>Merchant note<textarea name="merchant" defaultValue="Premium travel package, rush delivery requested" /></label>
                <label>Amount<input name="amount" defaultValue="32500" /></label>
                <button type="submit">Run fraud review</button>
              </form>
              {fraudResult && (
                // VULN: AI/LLM Security - unvalidated LLM response is rendered directly to the UI.
                <div className="fraud-output" dangerouslySetInnerHTML={{ __html: fraudResult.replace(/\n/g, "<br />") }} />
              )}
            </section>
          </div>

          <section className="panel">
            <div className="table-header">
              <h3>Your transaction history</h3>
              <div className="search-row">
                <input value={merchantSearch} onChange={(e) => setMerchantSearch(e.target.value)} placeholder="Search merchant" />
                <button onClick={() => loadTransactions()}>Search</button>
              </div>
            </div>
            <TransactionTable transactions={transactions} onInspect={inspectTransaction} />
          </section>

          {selectedTransaction && (
            <section className="panel detail-panel">
              <h3>Transaction detail #{selectedTransaction.id}</h3>
              <pre>{JSON.stringify(selectedTransaction, null, 2)}</pre>
            </section>
          )}

          <section className="panel admin-panel">
            <h3>Admin transaction dashboard</h3>
            <p className="muted">Global operations view for authorization, settlement, and manual review.</p>
            <TransactionTable transactions={adminTransactions} onInspect={inspectTransaction} unsafeMerchant />
          </section>
        </section>
      )}
    </main>
  );
}

function TransactionTable({ transactions, onInspect, unsafeMerchant = false }) {
  return (
    <div className="table-wrap">
      <table>
        <thead>
          <tr>
            <th>ID</th>
            <th>Merchant</th>
            <th>Amount</th>
            <th>Status</th>
            <th>Card</th>
            <th>CVV</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          {transactions.map((txn) => (
            <tr key={`${unsafeMerchant ? "admin" : "user"}-${txn.id}`}>
              <td>#{txn.id}</td>
              <td>
                {unsafeMerchant ? (
                  // VULN: XSS (Stored) - merchant names are rendered without sanitization in the admin dashboard.
                  <span dangerouslySetInnerHTML={{ __html: txn.merchant }} />
                ) : (
                  txn.merchant
                )}
              </td>
              <td>${Number(txn.amount).toLocaleString()}</td>
              <td><span className={`status ${txn.status}`}>{txn.status}</span></td>
              <td>{txn.card_number}</td>
              <td>{txn.cvv}</td>
              <td><button className="ghost" onClick={() => onInspect(txn.id)}>Inspect</button></td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

createRoot(document.getElementById("root")).render(<App />);
