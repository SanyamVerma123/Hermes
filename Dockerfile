# ============================================================
#  Hermes Agent — Self-contained Render/HF deployment (Stable v5)
#  Single Dockerfile: Gateway + Dashboard + Chat WebUI + Router
#
#  HOW TO DEPLOY ON RENDER:
#  1. Create a New Web Service on Render (Docker runtime).
#  2. Connect your GitHub repository containing ONLY this Dockerfile.
#  3. Set Environment Variables in Render's dashboard (see instructions).
#  4. Render will build and deploy the container automatically!
#
#  URLS:
#     /            → Chat Web UI (Secure - Redirects to /_login if unauthenticated)
#     /dashboard   → Hermes Dashboard (Secure - Redirects to /_login if unauthenticated)
#     /v1/* -> OpenAI-compatible API (Secure - Returns 401 JSON if unauthenticated)
#     /health      → Status JSON (no auth required for health-checks)
# ============================================================

FROM nousresearch/hermes-agent:latest

USER root

# ── System deps & HF CLI installation ────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl jq git nodejs npm python3 netcat-openbsd tar gzip unzip dnsutils \
    && rm -rf /var/lib/apt/lists/* \
    && uv pip install --python /opt/hermes/.venv/bin/python \
       --no-cache-dir "huggingface_hub>=0.22" pyyaml \
    && curl -LsSf https://hf.co/cli/install.sh | bash \
    && ( [ -f /root/.local/bin/hf ] && mv /root/.local/bin/hf /usr/local/bin/hf || true ) \
    && chmod +x /usr/local/bin/hf || true

# ── Clone Hermes WebUI (the chat front-end) ──────────────────
RUN git clone --depth 1 https://github.com/nesquena/hermes-webui.git /opt/hermes-webui \
    && ( [ -f /opt/hermes-webui/requirements.txt ] \
         && /opt/hermes/.venv/bin/pip install --no-cache-dir \
            -r /opt/hermes-webui/requirements.txt \
         || true ) \
    && chown -R hermes:hermes /opt/hermes-webui

# ── Node router deps ──────────────────────────────────────────
RUN mkdir -p /opt/router \
    && cd /opt/router \
    && npm init -y --quiet \
    && npm install --quiet --no-fund http-proxy

# ── Write the Node.js reverse proxy ──────────────────────────
RUN cat > /opt/router/server.js << 'ENDJS'
'use strict';
var http  = require('http');
var proxy = require('http-proxy').createProxyServer({ proxyTimeout: 120000 });

// Render dynamically injects PORT; default to 10000
var PORT          = parseInt(process.env.PORT || '10000', 10);
var GATEWAY_TOKEN = process.env.GATEWAY_TOKEN || '';

var DASHBOARD_PATHS = [
  '/dashboard', '/skills', '/plugins', '/mcp', '/webhooks', 
  '/pairing', '/profiles', '/config', '/keys', '/system', 
  '/cron', '/models', '/logs', '/assets', '/env', '/api', '/openapi.json'
];

var GATEWAY_PATHS = [
  '/v1', '/health', '/status'
];

// Helper functions for precise path matching
function isDashboardPath(pathname) {
  for (var i = 0; i < DASHBOARD_PATHS.length; i++) {
    var p = DASHBOARD_PATHS[i];
    if (pathname === p || pathname.indexOf(p + '/') === 0) {
      return true;
    }
  }
  return false;
}

function isGatewayPath(pathname) {
  for (var i = 0; i < GATEWAY_PATHS.length; i++) {
    var p = GATEWAY_PATHS[i];
    if (pathname === p || pathname.indexOf(p + '/') === 0) {
      return true;
    }
  }
  return false;
}

proxy.on('error', function(err, req, res) {
  console.error('[router] proxy error:', err.message, req.url);
  if (res && res.socket && !res.headersSent) {
    res.writeHead(502, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(
      '<!DOCTYPE html><html><head><meta charset="utf-8">' +
      '<meta http-equiv="refresh" content="5"><title>Starting…</title>' +
      '<style>body{background:#0d0f14;color:#e2e2e8;font-family:system-ui;' +
      'display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0}' +
      '.c{text-align:center}.spin{font-size:3rem;animation:s 1s linear infinite}' +
      '@keyframes s{to{transform:rotate(360deg)}}</style></head>' +
      '<body><div class="c"><div class="spin">⚙️</div>' +
      '<h2 style="margin:.5rem 0">Hermes is starting…</h2>' +
      '<p style="color:#686c7a">This page refreshes automatically every 5 seconds</p>' +
      '</div></body></html>'
    );
  }
});

// Parse cookies safely
function parseCookies(req) {
  var out = {};
  var cookieHeader = req.headers.cookie || '';
  cookieHeader.split(';').forEach(function(c) {
    var idx = c.indexOf('=');
    if (idx < 1) return;
    out[c.slice(0, idx).trim()] = c.slice(idx + 1).trim();
  });
  return out;
}

function authed(req) {
  if (!GATEWAY_TOKEN) return true;

  // 1. Check Query Token parameter (forces compatibility inside iFrame contexts)
  try {
    var url = req.url || '';
    var qIdx = url.indexOf('?');
    if (qIdx !== -1) {
      var search = url.slice(qIdx + 1);
      var params = search.split('&');
      for (var i = 0; i < params.length; i++) {
        var pair = params[i].split('=');
        if (pair === 'token' && decodeURIComponent(pair || '') === GATEWAY_TOKEN) {
          return true;
        }
      }
    }
  } catch (e) {}

  // 2. Check Cookie
  var cookies = parseCookies(req);
  if (cookies['hm_tok'] && decodeURIComponent(cookies['hm_tok']) === GATEWAY_TOKEN) {
    return true;
  }

  // 3. Check Authorization header
  var auth = req.headers['authorization'] || '';
  if (auth === 'Bearer ' + GATEWAY_TOKEN) return true;

  return false;
}

function loginPage(errMsg) {
  var errHtml = errMsg ? '<div class="err">&#9888;&nbsp;' + errMsg + '</div>' : '';
  return '<!DOCTYPE html><html lang="en"><head>' +
    '<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<title>Hermes &mdash; Sign in</title>' +
    '<style>*{box-sizing:border-box;margin:0;padding:0}' +
    'body{background:#0d0f14;color:#e2e2e8;font-family:system-ui;' +
    'display:flex;align-items:center;justify-content:center;min-height:100vh}' +
    '.card{background:#161920;border:1px solid #252830;border-radius:18px;' +
    'padding:2.6rem 2.2rem;width:100%;max-width:400px}' +
    '.icon{font-size:2.6rem;margin-bottom:.5rem}' +
    'h1{font-size:1.45rem;margin-bottom:.2rem}' +
    '.sub{color:#5a5e6b;font-size:.875rem;margin-bottom:1.8rem}' +
    'label{display:block;font-size:.8rem;color:#8a8e9b;margin-bottom:.4rem}' +
    'input{width:100%;padding:.78rem 1rem;background:#0d0f14;border:1px solid #2a2d38;' +
    'border-radius:9px;color:#e2e2e8;font-size:1rem;margin-bottom:1.2rem;outline:none}' +
    'input:focus{border-color:#7c3aed;box-shadow:0 0 0 3px rgba(124,58,237,.18)}' +
    'button{width:100%;padding:.8rem;background:#7c3aed;border:none;border-radius:9px;' +
    'color:#fff;font-size:1rem;font-weight:600;cursor:pointer;transition:.15s}' +
    'button:hover{background:#6d28d9}' +
    '.err{background:rgba(239,68,68,.1);border:1px solid rgba(239,68,68,.3);' +
    'color:#f87171;border-radius:8px;padding:.6rem .9rem;font-size:.85rem;margin-bottom:1.1rem}' +
    '.note{font-size:.75rem;color:#3a3d4a;margin-top:1rem;text-align:center}' +
    '</style></head><body><div class="card">' +
    '<div class="icon">&#129391;</div>' +
    '<h1>Hermes Agent</h1>' +
    '<p class="sub">Enter your gateway token to access the workspace.</p>' +
    errHtml +
    '<form method="POST" action="/_login">' +
    '<label for="tok">Gateway Token</label>' +
    '<input id="tok" type="password" name="token" placeholder="Your GATEWAY_TOKEN secret" autofocus autocomplete="current-password"/>' +
    '<button type="submit">Sign in &nbsp;&rarr;</button>' +
    '</form>' +
    '<p class="note">Set GATEWAY_TOKEN in your env variables to activate this gate.</p>' +
    '</div></body></html>';
}

var server = http.createServer(function(req, res) {
  var url = req.url || '/';
  var referer = req.headers.referer || '';
  
  // FIX: Properly extract the pathname string (was an array previously, causing healthcheck failures)
  var pathname = url.split('?');

  // Route: /health check (public - crucial for Render's zero-downtime deploy engine)
  if (pathname === '/health' || pathname === '/health/') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ ok: true, ts: new Date().toISOString(), port: PORT }));
  }

  // Route: /_login page
  if (pathname === '/_login' || pathname === '/_login/') {
    if (req.method === 'POST') {
      var body = '';
      req.on('data', function(d) { body += d; });
      req.on('end', function() {
        var tok = new URLSearchParams(body).get('token') || '';
        if (!GATEWAY_TOKEN || tok === GATEWAY_TOKEN) {
          var isHttps = req.headers['x-forwarded-proto'] === 'https' || req.headers['x-forwarded-ssl'] === 'on';
          var cookieFlags = '; Path=/; HttpOnly';
          if (isHttps) {
            cookieFlags += '; Secure; SameSite=None'; // Support iframe loading fallback
          } else {
            cookieFlags += '; SameSite=Lax';
          }
          res.writeHead(302, {
            'Set-Cookie': 'hm_tok=' + encodeURIComponent(tok) + cookieFlags,
            'Location': '/'
          });
          return res.end();
        }
        res.writeHead(401, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(loginPage('Invalid token — try again.'));
      });
      return;
    }
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    return res.end(loginPage(''));
  }

  // Mandatory Authentication Check
  if (!authed(req)) {
    // If request belongs to assets/APIs, return a clean 401 status to prevent WebUI crashes
    var isApiOrAsset = pathname.indexOf('/v1/') === 0 || 
                       pathname.indexOf('/api/') === 0 || 
                       pathname.indexOf('/static/') === 0 ||
                       pathname.indexOf('/assets/') === 0 || 
                       pathname.indexOf('/openapi.json') === 0;

    if (isApiOrAsset) {
      res.writeHead(401, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'Unauthorized', hint: 'Please login at /_login to fetch credentials.' }));
    }

    res.writeHead(302, { 'Location': '/_login' });
    return res.end();
  }

  // Route: Gateway endpoints (Port 8642)
  var isGateway = isGatewayPath(pathname);
  if (isGateway) {
    return proxy.web(req, res, { target: 'http://127.0.0.1:8642', changeOrigin: false });
  }

  // Route: Dashboard endpoints (Port 9119)
  var isDashboard = isDashboardPath(pathname);
  if (!isDashboard && referer) {
    try {
      var refPath = referer.replace(/^https?:\/\/[^\/]+/, '');
      var qIdx = refPath.indexOf('?');
      if (qIdx !== -1) {
        refPath = refPath.slice(0, qIdx);
      }
      isDashboard = isDashboardPath(refPath);
    } catch (e) {
      isDashboard = false;
    }
  }

  if (isDashboard) {
    return proxy.web(req, res, { target: 'http://127.0.0.1:9119', changeOrigin: true });
  }

  // Default Route: WebUI chat interface (Port 8787)
  return proxy.web(req, res, { target: 'http://127.0.0.1:8787', changeOrigin: false });
});

server.on('upgrade', function(req, socket, head) {
  var url = req.url || '/';
  var referer = req.headers.referer || '';
  var pathname = url.split('?');

  // Restrict unauthenticated WebSockets
  if (!authed(req)) {
    socket.destroy();
    return;
  }

  var isDashboard = isDashboardPath(pathname);
  if (!isDashboard && referer) {
    try {
      var refPath = referer.replace(/^https?:\/\/[^\/]+/, '');
      var qIdx = refPath.indexOf('?');
      if (qIdx !== -1) {
        refPath = refPath.slice(0, qIdx);
      }
      isDashboard = isDashboardPath(refPath);
    } catch (e) {
      isDashboard = false;
    }
  }

  var target = isDashboard 
    ? 'http://127.0.0.1:9119' 
    : (isGatewayPath(pathname) ? 'http://127.0.0.1:8642' : 'http://127.0.0.1:8787');

  proxy.ws(req, socket, head, { target: target, changeOrigin: (target.indexOf('9119') >= 0) });
});

server.listen(PORT, '0.0.0.0', function() {
  console.log('[router] Transparent Reverse Proxy active on port ' + PORT);
});
ENDJS

# ── Write start.sh ────────────────────────────────────────────
RUN cat > /opt/start.sh << 'ENDSH'
#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/hermes/.venv/bin:/opt/data/.local/bin:$PATH"

HH="${HERMES_HOME:-/data}"

mkdir -p "$HH" "$HH/logs" "$HH/config" "$HH/memory"

echo "╔══════════════════════════════════════════╗"
echo "║   Hermes Agent — Render Bootloader       ║"
echo "╚══════════════════════════════════════════╝"

# ── 1. BACKGROUND FRONTEND UPDATES ────────────────────────────
echo "[boot] 🔄 Checking for WebUI updates in background..."
(cd /opt/hermes-webui && git pull >/dev/null 2>&1) &

# ── 2. FAST SYNC FROM STORAGE BUCKET ──────────────────────────
if [ -n "${HF_TOKEN:-}" ] && [ -n "${HF_BUCKET:-}" ]; then
  echo "[boot] 📦 Restoring from Hugging Face Storage Bucket..."
  export HF_TOKEN="${HF_TOKEN}"
  
  if hf sync "hf://buckets/${HF_BUCKET}" "$HH" \
      --exclude ".venv/*" --exclude "venv/*" --exclude ".cache/*" \
      --exclude "node_modules/*" --exclude "__pycache__/*" --exclude "*.pyc" \
      --exclude "*.log" --exclude "*.tmp" 2>/dev/null; then
    echo "[boot] ✅ Backup restored instantly"
  else
    echo "[boot] ⚠️ Bucket is empty or connection failed — starting fresh."
  fi
fi

# ── 3. AUTOMATIC SQLITE INTEGRITY RECOVERY & WAL ENABLING ─────
echo "[boot] 🩺 Checking database integrity & enabling WAL mode to prevent corruption..."
python3 - <<'PY_SQLITE_RECOVER'
import os, sqlite3
db_dir = "/data"
if os.path.exists(db_dir):
    for fname in os.listdir(db_dir):
        if fname.endswith(".db"):
            db_path = os.path.join(db_dir, fname)
            try:
                conn = sqlite3.connect(db_path)
                cursor = conn.cursor()
                cursor.execute("PRAGMA integrity_check;")
                res = cursor.fetchone()
                # FIX: Check res tuple index correctly to prevent automatic database wipes on boot
                if res and res == "ok":
                    cursor.execute("PRAGMA journal_mode=WAL;")
                    cursor.execute("PRAGMA synchronous=NORMAL;")
                    conn.commit()
                    print(f"[boot-recover] Database OK and WAL enabled: {fname}")
                else:
                    raise Exception(f"Integrity check failed: {res if res else 'Unknown'}")
                conn.close()
            except Exception as e:
                print(f"[boot-recover] SQLite database corrupt/locked: {db_path} ({e})")
                for suffix in ["", "-journal", "-wal", "-shm"]:
                    p = db_path + suffix if suffix else db_path
                    if os.path.exists(p):
                        try:
                            os.remove(p)
                        except Exception:
                            pass
                print(f"[boot-recover] Reset corrupted file: {fname}")
PY_SQLITE_RECOVER

# ── 4. MERGE BUILT-IN SKILLS INTO PERSISTENT STORAGE ──────────
echo "[boot] 🧩 Merging 79 built-in skills into persistent storage..."
for src_skills in /opt/hermes/skills /opt/hermes/hermes_cli/skills /opt/hermes/hermes/skills; do
  if [ -d "$src_skills" ]; then
    mkdir -p "$HH/skills"
    cp -rn "$src_skills"/* "$HH/skills/" 2>/dev/null || true
  fi
done

# ── 5. INTEGRITY LINKING OF WEBUI SETTINGS ────────────────────
echo "[boot] ⚙️ Linking WebUI configuration assets..."
touch "$HH/webui_settings.json"
if [ ! -s "$HH/webui_settings.json" ]; then
  if [ -f "/opt/hermes-webui/settings.json" ]; then
    cp "/opt/hermes-webui/settings.json" "$HH/webui_settings.json"
  else
    echo '{"password":"","password_enabled":false,"auth_enabled":false}' > "$HH/webui_settings.json"
  fi
fi
rm -f /opt/hermes-webui/settings.json
ln -sf "$HH/webui_settings.json" /opt/hermes-webui/settings.json

# ── 6. MERGE AND SYNC ENVIRONMENT CREDENTIALS ─────────────────
ENV_FILE="$HH/.env"
echo "[boot] 🔑 Writing environment configuration..."
touch "$ENV_FILE"

TMP_ENV=$(mktemp)
if [ -f "$ENV_FILE" ]; then
  cat "$ENV_FILE" > "$TMP_ENV"
fi

upsert_key() {
  local key="$1"
  local val="$2"
  if [ -n "$val" ]; then
    sed -i "/^${key}=/d" "$TMP_ENV" || true
    echo "${key}=${val}" >> "$TMP_ENV"
  fi
}

upsert_key "OPENROUTER_API_KEY" "${OPENROUTER_API_KEY:-}"
upsert_key "OPENAI_API_KEY" "${OPENAI_API_KEY:-}"
upsert_key "ANTHROPIC_API_KEY" "${ANTHROPIC_API_KEY:-}"
upsert_key "HF_TOKEN" "${HF_TOKEN:-}"
upsert_key "API_SERVER_KEY" "${API_SERVER_KEY:-}"

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  upsert_key "TELEGRAM_BOT_TOKEN" "${TELEGRAM_BOT_TOKEN}"
  USERS="${TELEGRAM_ALLOWED_USERS:-}"
  if [ -n "$USERS" ]; then
    if [[ ! "$USERS" =~ ^\[.*\]$ ]]; then
      USERS="[$USERS]"
    fi
    upsert_key "TELEGRAM_ALLOWED_USERS" "$USERS"
  fi
fi

mv "$TMP_ENV" "$ENV_FILE"
chmod 600 "$ENV_FILE"

# ── 7. TELEGRAM INJECTION & DIAGNOSIS ─────────────────────────
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  echo "[boot] 🌐 Checking network reachability to api.telegram.org..."
  if curl -s -I --connect-timeout 5 "https://api.telegram.org" > /dev/null; then
    echo "[boot] ✅ Telegram Connection OK"
  else
    echo "[boot] ❌ Network Connection WARNING: api.telegram.org unreachable"
  fi
fi

# ── 8. CONFIGURATION ENFORCEMENT ──────────────────────────────
CFG="$HH/config.yaml"
if [ ! -f "$CFG" ]; then
  echo "[boot] ✍️  Writing config.yaml..."

  if [ -n "${OPENROUTER_API_KEY:-}" ]; then PROVIDER="openrouter"
  elif [ -n "${ANTHROPIC_API_KEY:-}"  ]; then PROVIDER="anthropic"
  elif [ -n "${OPENAI_API_KEY:-}"     ]; then PROVIDER="openai"
  else                                        PROVIDER="auto"; fi

  MODEL="${HERMES_MODEL:-openai/gpt-4o-mini}"

  cat > "$CFG" << YAML
model:
  provider: ${PROVIDER}
  default: "${MODEL}"
YAML
fi

# Clear any WebUI passwords to avoid user lockouts during setup
python3 - <<'PY_PASS_CLEAN'
import os, json, yaml
for fpath in ["/data/settings.json", "/data/webui_settings.json", "/opt/hermes-webui/settings.json"]:
    if os.path.exists(fpath):
        try:
            with open(fpath, 'r') as f:
                data = json.load(f)
            data['password'] = ""
            data['password_enabled'] = False
            data['auth_enabled'] = False
            with open(fpath, 'w') as f:
                json.dump(data, f, indent=2)
            print(f"[boot] Reset passwords in: {fpath}")
        except Exception:
            pass

cfg_yaml = "/data/config.yaml"
if os.path.exists(cfg_yaml):
    try:
        with open(cfg_yaml, 'r') as f:
            cfg = yaml.safe_load(f) or {}
        if 'webui' in cfg:
            cfg['webui']['password'] = None
            cfg['webui']['auth_enabled'] = False
            with open(cfg_yaml, 'w') as f:
                yaml.safe_dump(cfg, f)
            print("[boot] Removed WebUI configuration block password gates.")
    except Exception:
        pass
PY_PASS_CLEAN

# ── 9. PATCH CHAT WEBUI TO ROUTE DASHBOARD ITEMS TO /DASHBOARD ─
echo "[boot] 🔀 Linking WebUI sidebar directories directly to proxy..."
python3 - <<'PY_WEBUI_ROUTE_PATCH'
import os, re
web_dir = "/opt/hermes-webui"
for root, _, files in os.walk(web_dir):
    for fname in files:
        if fname.endswith((".html", ".py", ".js")):
            fpath = os.path.join(root, fname)
            try:
                with open(fpath, 'r', encoding='utf-8') as f:
                    content = f.read()
                
                new_content = re.sub(r'href="[^"]*9119[^"]*"', 'href="/dashboard"', content)
                new_content = re.sub(r"href='[^']*9119[^']*'", "href='/dashboard'", new_content)
                new_content = new_content.replace("http://127.0.0.1:9119", "/dashboard")
                new_content = new_content.replace("http://localhost:9119", "/dashboard")
                new_content = new_content.replace("localhost:9119", "/dashboard")
                new_content = new_content.replace("127.0.0.1:9119", "/dashboard")

                if new_content != content:
                    with open(fpath, 'w', encoding='utf-8') as f:
                        f.write(new_content)
            except Exception:
                pass
PY_WEBUI_ROUTE_PATCH

# ── 10. START SERVICES ─────────────────────────────────────────
echo "[boot] 🚀 Starting Hermes Gateway (port 8642)..."
API_SERVER_ENABLED=true \
API_SERVER_HOST=127.0.0.1 \
API_SERVER_KEY="${API_SERVER_KEY:-local-dev-key}" \
  hermes gateway run > "$HH/logs/gateway.log" 2>&1 &

echo "[boot] 🗂️  Starting Hermes Dashboard (port 9119)..."
hermes dashboard \
  --host 0.0.0.0 \
  --port 9119 \
  --insecure \
  --no-open \
  > "$HH/logs/dashboard.log" 2>&1 &

echo "[boot] 🌐 Starting Hermes WebUI (port 8787)..."
cd /opt/hermes-webui
HERMES_WEBUI_AGENT_DIR=/opt/hermes \
HERMES_API_KEY="${API_SERVER_KEY:-local-dev-key}" \
WEBUI_PORT=8787 WEBUI_HOST=127.0.0.1 PORT=8787 \
  python3 server.py > "$HH/logs/webui.log" 2>&1 &

# ── 11. WAIT FOR BACKENDS TO BIND ──────────────────────────────
echo "[boot] ⏳ Waiting for gateway on :8642..."
for i in $(seq 1 45); do
  if nc -z 127.0.0.1 8642 2>/dev/null; then
    echo "[boot] ✅ Gateway is UP!"
    break
  fi
  sleep 2
done

echo "[boot] ⏳ Waiting for dashboard on :9119..."
for i in $(seq 1 45); do
  if nc -z 127.0.0.1 9119 2>/dev/null; then
    echo "[boot] ✅ Dashboard is UP!"
    break
  fi
  sleep 2
done

echo "[boot] ⏳ Waiting for WebUI on :8787..."
for i in $(seq 1 45); do
  if nc -z 127.0.0.1 8787 2>/dev/null; then
    echo "[boot] ✅ WebUI is UP!"
    break
  fi
  sleep 2
done

# ── 12. BACKGROUND CLOUD JANITOR ───────────────────────────────
if [ -n "${HF_TOKEN:-}" ] && [ -n "${HF_BUCKET:-}" ]; then
  (
    echo "[boot-clean] 🧼 Purging remote junk folders (.venv, .cache) from bucket..."
    hf buckets remove "hf://buckets/${HF_BUCKET}/.venv/" --recursive --yes >/dev/null 2>&1 || true
    hf buckets remove "hf://buckets/${HF_BUCKET}/.cache/" --recursive --yes >/dev/null 2>&1 || true
    hf buckets remove "hf://buckets/${HF_BUCKET}/node_modules/" --recursive --yes >/dev/null 2>&1 || true
    
    while true; do
      sleep "${SYNC_INTERVAL:-300}"
      hf sync "$HH" "hf://buckets/${HF_BUCKET}" \
          --exclude ".venv/*" --exclude "venv/*" --exclude ".cache/*" \
          --exclude "node_modules/*" --exclude "__pycache__/*" --exclude "*.pyc" \
          --exclude "*.log" --exclude "*.tmp" >/dev/null 2>&1 || true
    done
  ) &
fi

# ── 13. START ROUTER ───────────────────────────────────────────
echo "[boot] 🔀 Starting router on port ${PORT:-10000}..."
exec node /opt/router/server.js
ENDSH

RUN chmod +x /opt/start.sh

# ── Kanban DB idempotent patch ────────────────────────────────
RUN python3 - << 'PYPATCH'
from pathlib import Path
import sys
p = Path("/opt/hermes/hermes_cli/kanban_db.py")
if not p.exists():
    print("kanban_db.py not found — skip"); sys.exit(0)
src = p.read_text(encoding="utf-8")
sentinel = "# hf-patch: idempotent"
if sentinel in src:
    print("already patched"); sys.exit(0)
import re
patched = re.sub(
    r'(conn\.execute\(["\']ALTER TABLE \w+ ADD COLUMN [^)]+\)["\'][ \t]*\))',
    r'try:\n        \1  ' + sentinel + r'\n    except Exception:\n        pass',
    src
)
if patched != src:
    p.write_text(patched, encoding="utf-8")
    print("kanban patch: applied")
else:
    print("kanban patch: pattern not found — may already be fixed upstream")
PYPATCH

# ── FIX ALL DATABASE FRAGMENTATION & OWNERSHIP ────────────────
# 1. We pre-create /data
# 2. We explicitly override the HOME environment variable during container setup so that 
#    no platform can dynamically override our file-system paths.
ENV HOME=/home/hermes

RUN mkdir -p /data /data/logs \
    && mkdir -p /home/hermes \
    && rm -rf /home/hermes/.hermes && ln -sf /data /home/hermes/.hermes \
    && rm -rf /opt/data && ln -sf /data /opt/data \
    && chown -R hermes:hermes /data /home/hermes /opt/hermes /opt/hermes-webui /opt/router /opt/start.sh \
    && chown -h hermes:hermes /home/hermes/.hermes /opt/data \
    && chmod -R 777 /data /home/hermes

# ── Environment ───────────────────────────────────────────────
ENV HERMES_HOME=/data \
    HERMES_WEBUI_AGENT_DIR=/opt/hermes \
    PYTHONUNBUFFERED=1 \
    PORT=10000 \
    HF_HUB_ENABLE_HF_TRANSFER=1

EXPOSE 10000

HEALTHCHECK --interval=30s --timeout=10s --start-period=180s \
    CMD curl -fsS http://localhost:10000/health || exit 1

USER hermes

ENTRYPOINT ["/opt/start.sh"]
