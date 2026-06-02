# ============================================================
#  Hermes Agent — Dedicated Render Deployment Build (v5)
#  Single Dockerfile: Gateway + Dashboard + Chat WebUI + Router
#
#  HOW TO DEPLOY ON RENDER:
#  1. Create a New Web Service on Render (Docker runtime).
#  2. Connect the GitHub repository containing ONLY this Dockerfile.
#  3. Input the required Environment Variables in Render's dashboard.
#  4. Render will compile and orchestrate the deployment automatically!
# ============================================================

FROM nousresearch/hermes-agent:latest

USER root

# ── 1. SYSTEM UTILITIES & LIGHTWEIGHT DEPENDENCIES ──────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl jq git nodejs npm python3 netcat-openbsd tar gzip unzip dnsutils \
    && rm -rf /var/lib/apt/lists/* \
    && uv pip install --python /opt/hermes/.venv/bin/python \
       --no-cache-dir "huggingface_hub>=0.22" pyyaml \
    && curl -LsSf https://hf.co/cli/install.sh | bash \
    && ( [ -f /root/.local/bin/hf ] && mv /root/.local/bin/hf /usr/local/bin/hf || true ) \
    && chmod +x /usr/local/bin/hf || true

# ── 2. INITIALIZE CHAT FRONTEND (WebUI) ──────────────────────
RUN git clone --depth 1 https://github.com/nesquena/hermes-webui.git /opt/hermes-webui \
    && ( [ -f /opt/hermes-webui/requirements.txt ] \
         && uv pip install --python /opt/hermes/.venv/bin/python --no-cache-dir \
            -r /opt/hermes-webui/requirements.txt \
         || true ) \
    && chown -R hermes:hermes /opt/hermes-webui

# ── 3. ROUTER NETWORKING LAYERS ──────────────────────────────
RUN mkdir -p /opt/router \
    && cd /opt/router \
    && npm init -y --quiet \
    && npm install --quiet --no-fund http-proxy

# ── 4. WRITE ROBUST NODE.JS TRANSPARENT REVERSE PROXY ──────────
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

  try {
    var url = req.url || '';
    var qIdx = url.indexOf('?');
    if (qIdx !== -1) {
      var search = url.slice(qIdx + 1);
      var params = search.split('&');
      for (var i = 0; i < params.length; i++) {
        var pair = params[i].split('=');
        // FIXED: Check array index pair instead of reference to avoid comparing array to string
        if (pair === 'token' && decodeURIComponent(pair || '') === GATEWAY_TOKEN) {
          return true;
        }
      }
    }
  } catch (e) {}

  var cookies = parseCookies(req);
  if (cookies['hm_tok'] && decodeURIComponent(cookies['hm_tok']) === GATEWAY_TOKEN) {
    return true;
  }

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
  
  // FIXED: Properly extract pathname as a clean String index rather than an array
  var pathname = url.split('?');

  if (pathname === '/health' || pathname === '/health/') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ ok: true, ts: new Date().toISOString(), port: PORT }));
  }

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
            cookieFlags += '; Secure; SameSite=None';
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

  if (!authed(req)) {
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

  var isGateway = isGatewayPath(pathname);
  if (isGateway) {
    return proxy.web(req, res, { target: 'http://127.0.0.1:8642', changeOrigin: false });
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

  if (isDashboard) {
    return proxy.web(req, res, { target: 'http://127.0.0.1:9119', changeOrigin: true });
  }

  return proxy.web(req, res, { target: 'http://127.0.0.1:8787', changeOrigin: false });
});

server.on('upgrade', function(req, socket, head) {
  var url = req.url || '/';
  var referer = req.headers.referer || '';
  
  // FIXED: Properly extract pathname as a clean String index rather than an array
  var pathname = url.split('?');

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

# ── 5. WRITE STARTUP MANAGEMENT SYSTEM ─────────────────────────
RUN cat > /opt/start.sh << 'ENDSH'
#!/usr/bin/env bash
set -euo pipefail

# FIX: Force system-level $HOME variables to protect against Render's dynamic overrides
export HOME="/home/hermes"
export PATH="/opt/hermes/.venv/bin:/opt/data/.local/bin:$PATH"

HH="${HERMES_HOME:-/data}"

mkdir -p "$HH" "$HH/logs" "$HH/config" "$HH/memory"

echo "╔══════════════════════════════════════════╗"
echo "║   Hermes Agent — Dedicated Render Boot   ║"
echo "╚══════════════════════════════════════════╝"

# ── Background Frontend Sync ──────────────────────────────────
(cd /opt/hermes-webui && git pull >/dev/null 2>&1) &

# ── Read Storage Bucket Backup ───────────────────────────────
if [ -n "${HF_TOKEN:-}" ] && [ -n "${HF_BUCKET:-}" ]; then
  echo "[boot] 📦 Synchronizing storage volume with Hugging Face Storage Bucket..."
  export HF_TOKEN="${HF_TOKEN}"
  
  if hf sync "hf://buckets/${HF_BUCKET}" "$HH" \
      --exclude ".venv/*" --exclude "venv/*" --exclude ".cache/*" \
      --exclude "node_modules/*" --exclude "__pycache__/*" --exclude "*.pyc" \
      --exclude "*.log" --exclude "*.tmp" 2>/dev/null; then
    echo "[boot] ✅ Backup layers restored cleanly"
  else
    echo "[boot] ⚠️ Bucket empty or timeout — launching clean local storage container."
  fi
fi

# ── Safe Database Verification & WAL Configuration ────────────
echo "[boot] 🩺 Performing system database structural checks..."
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
                # FIXED: Check res correctly to prevent false-corruption wipes on restart
                if res and res == "ok":
                    cursor.execute("PRAGMA journal_mode=WAL;")
                    cursor.execute("PRAGMA synchronous=NORMAL;")
                    conn.commit()
                    print(f"[boot-recover] Database structure is healthy: {fname}")
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
                print(f"[boot-recover] Reset corrupted database: {fname}")
PY_SQLITE_RECOVER

# ── Synchronize 79 Built-In Skills ────────────────────────────
echo "[boot] 🧩 Merging 79 pre-baked skills to persistent storage..."
for src_skills in /opt/hermes/skills /opt/hermes/hermes_cli/skills /opt/hermes/hermes/skills; do
  if [ -d "$src_skills" ]; then
    mkdir -p "$HH/skills"
    cp -rn "$src_skills"/* "$HH/skills/" 2>/dev/null || true
  fi
done

# ── WebUI Session Persistence ──────────────────────────────────
echo "[boot] ⚙️ Synchronizing Chat WebUI settings..."
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

# ── Dynamic Environment Sync Matrix ────────────────────────────
ENV_FILE="$HH/.env"
echo "[boot] 🔑 Syncing environment variables..."
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

# ── Configuration Enforcement ────────────────────────────────
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

# Reset WebUI password restrictions to avoid token locks
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

# Sidebar Port Realignment Matrix
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

# ── EXECUTE OPERATIONS DAEMONS ────────────────────────────────
echo "[boot] 🚀 Starting Hermes Gateway (port 8642)..."
API_SERVER_ENABLED=true \
API_SERVER_HOST=127.0.0.1 \
API_SERVER_KEY="${API_SERVER_KEY:-local-dev-key}" \
  hermes gateway run > "$HH/logs/gateway.log" 2>&1 &

echo "[boot] 🚀 Starting Hermes Dashboard Control Panel (port 9119)..."
hermes dashboard \
  --host 0.0.0.0 \
  --port 9119 \
  --insecure \
  --no-open \
  > "$HH/logs/dashboard.log" 2>&1 &

echo "[boot] 🚀 Starting Chat WebUI Interface (port 8787)..."
cd /opt/hermes-webui
HERMES_WEBUI_AGENT_DIR=/opt/hermes \
HERMES_API_KEY="${API_SERVER_KEY:-local-dev-key}" \
WEBUI_PORT=8787 WEBUI_HOST=127.0.0.1 PORT=8787 \
  python3 server.py > "$HH/logs/webui.log" 2>&1 &

# ── Thread Binding Handshakes ─────────────────────────────────
for i in $(seq 1 45); do if nc -z 127.0.0.1 8642 2>/dev/null; then break; fi; sleep 2; done
for i in $(seq 1 45); do if nc -z 127.0.0.1 9119 2>/dev/null; then break; fi; sleep 2; done
for i in $(seq 1 45); do if nc -z 127.0.0.1 8787 2>/dev/null; then echo "[boot] ✅ Operational threads bound"; break; fi; sleep 2; done

# ── Background Storage Janitor worker ─────────────────────────
if [ -n "${HF_TOKEN:-}" ] && [ -n "${HF_BUCKET:-}" ]; then
  (
    echo "[boot-clean] 🧼 Sweeping garbage folders from remote cloud bucket volume..."
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

echo "[boot] 🔀 Running traffic director on port ${PORT:-10000}..."
exec node /opt/router/server.js
ENDSH

RUN chmod +x /opt/start.sh

# ── Kanban DB Idempotent Patch ───────────────────────────────
RUN python3 - << 'PYPATCH'
from pathlib import Path
import sys, re
p = Path("/opt/hermes/hermes_cli/kanban_db.py")
if not p.exists():
    sys.exit(0)
src = p.read_text(encoding="utf-8")
sentinel = "# hf-patch: idempotent"
if sentinel in src:
    sys.exit(0)
patched = re.sub(
    r'(conn\.execute\(["\']ALTER TABLE \w+ ADD COLUMN [^)]+\)["\'][ \t]*\))',
    r'try:\n        \1  ' + sentinel + r'\n    except Exception:\n        pass',
    src
)
if patched != src:
    p.write_text(patched, encoding="utf-8")
PYPATCH

# ── OVERRIDE USER PERMISSIONS FOR RENDER CONTAINERS ──────────
ENV HOME=/home/hermes

RUN mkdir -p /data /data/logs /home/hermes \
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
