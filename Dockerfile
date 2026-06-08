# ============================================================
#  Hermes Agent — Render Deployment (Render-optimised v1.0)
#  Single Dockerfile: Gateway + Dashboard + Chat WebUI + Router
#
#  HOW TO DEPLOY ON RENDER:
#  1. Push this Dockerfile to your GitHub repo (root of repo)
#  2. Connect repo in Render → New Web Service → Docker runtime
#  3. Set the following Environment Variables in Render Dashboard:
#
#  ┌─────────────────────────────────────────────────────────────┐
#  │  REQUIRED                                                   │
#  │  GATEWAY_TOKEN          → any strong password (your login)  │
#  │  API_SERVER_KEY         → random long secret string         │
#  │                                                             │
#  │  AI PROVIDER (at least one)                                 │
#  │  OPENROUTER_API_KEY     → from openrouter.ai (recommended)  │
#  │  OPENAI_API_KEY         → from platform.openai.com          │
#  │  ANTHROPIC_API_KEY      → from console.anthropic.com        │
#  │                                                             │
#  │  HF BUCKET (persistence across restarts)                    │
#  │  HF_TOKEN               → write token from hf.co/settings   │
#  │  HF_BUCKET              → Sanyam400/Hermes-storage          │
#  │                                                             │
#  │  OPTIONAL TELEGRAM                                          │
#  │  TELEGRAM_BOT_TOKEN     → from @BotFather                   │
#  │  TELEGRAM_ALLOWED_USERS → your numeric Telegram user ID     │
#  │  CLOUDFLARE_WORKERS_TOKEN → auto-deploys a Worker proxy     │
#  │  TELEGRAM_API_BASE      → manual proxy URL (alternative)    │
#  └─────────────────────────────────────────────────────────────┘
#
#  Render-specific changes vs HF Spaces version:
#  • PORT default changed to 10000 (Render default; overrideable)
#  • EXPOSE updated to 10000
#  • Removed HF_HUB_ENABLE_HF_TRANSFER / HF_XET_HIGH_PERFORMANCE
#    (HF transfer protocol not needed outside HF infra)
#  • Added SIGTERM trap in start.sh for graceful shutdown
#  • Health check path is /health (already exists in router)
#  • /data directory used for ephemeral runtime data;
#    HF bucket sync preserves state across Render restarts/redeploys
#  • Render attaches a Persistent Disk at /data for paid plans
#    (set mountPath=/data in render.yaml — see bottom of file)
#  • No USER switching issues — Render runs containers as root by
#    default; hermes user is still created and used via su/exec
# ============================================================

FROM nousresearch/hermes-agent:latest

USER root

# ── Global Environment Configuration ───────────────────────────
ENV PYTHONUNBUFFERED=1 \
    HERMES_HOME=/data \
    HERMES_WEBUI_AGENT_DIR=/opt/hermes \
    HERMES_WEBUI_ONBOARDING_OPEN=1 \
    NODE_OPTIONS=--no-deprecation \
    # Render injects PORT=10000 at runtime. We set 10000 as the
    # build-time default so the router binds correctly even without
    # an explicit Render env var override.
    PORT=10000 \
    TERM=xterm-256color \
    SHELL=/bin/bash \
    SYNC_INTERVAL=30 \
    # Browser / Chromium no-sandbox flags (required in any container)
    AGENT_BROWSER_ARGS="--no-sandbox,--disable-dev-shm-usage,--disable-gpu,--disable-setuid-sandbox,--disable-software-rasterizer,--disable-blink-features=AutomationControlled,--window-size=1920,1080,--lang=en-US,--no-first-run,--no-default-browser-check" \
    AGENT_BROWSER_CHROME_FLAGS="--no-sandbox,--disable-dev-shm-usage,--disable-gpu,--disable-setuid-sandbox,--disable-software-rasterizer,--disable-blink-features=AutomationControlled,--window-size=1920,1080,--lang=en-US,--no-first-run,--no-default-browser-check" \
    PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright \
    AGENT_BROWSER_INIT_SCRIPT=/opt/hermes-stealth/stealth-init.js

# ── System deps & HF CLI ──────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl jq git nodejs npm python3 netcat-openbsd tar gzip unzip dnsutils \
        libglib2.0-0 libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 \
        libcups2 libdrm2 libdbus-1-3 libxcb1 libxkbcommon0 libx11-6 \
        libxcomposite1 libxdamage1 libxext6 libxfixes3 libxrandr2 \
        libgbm1 libpango-1.0-0 libcairo2 libasound2 libatspi2.0-0 \
    && rm -rf /var/lib/apt/lists/* \
    && uv pip install --python /opt/hermes/.venv/bin/python \
       --no-cache-dir "huggingface_hub>=0.22" pyyaml \
    && curl -LsSf https://hf.co/cli/install.sh | bash \
    && ( [ -f /root/.local/bin/hf ] && mv /root/.local/bin/hf /usr/local/bin/hf || true ) \
    && chmod +x /usr/local/bin/hf || true

# ── Clone Hermes WebUI ────────────────────────────────────────
RUN git clone --depth 1 https://github.com/nesquena/hermes-webui.git /opt/hermes-webui \
    && ( [ -f /opt/hermes-webui/requirements.txt ] \
         && /opt/hermes/.venv/bin/pip install --no-cache-dir \
            -r /opt/hermes-webui/requirements.txt \
         || true )

# ── WebUI & Agent bypass patch ────────────────────────────────
RUN cat << 'EOF' > /tmp/patch_workspace.py
try:
    import os, re

    web_dir = "/opt/hermes-webui"
    if os.path.exists(web_dir):
        for root, dirs, files in os.walk(web_dir):
            dirs[:] = [d for d in dirs if not d.startswith('.')]
            for fname in files:
                fpath = os.path.join(root, fname)
                try:
                    with open(fpath, 'r', encoding='utf-8', errors='ignore') as f:
                        content = f.read()
                    original = content
                    content = re.sub(r'https?://127\.0\.0\.1:9119/?', '/dashboard', content)
                    content = re.sub(r'https?://localhost:9119/?', '/dashboard', content)
                    content = content.replace('127.0.0.1:9119', '/dashboard')
                    content = content.replace('localhost:9119', '/dashboard')
                    content = re.sub(r'":9119"', '"/dashboard"', content)
                    content = re.sub(r'":9119/"', '"/dashboard"', content)
                    if fname.endswith(".py"):
                        content = content.replace("password_enabled = true", "password_enabled = False")
                        content = content.replace("password_enabled=True", "password_enabled=False")
                        content = content.replace("auth_enabled = true", "auth_enabled = False")
                        content = content.replace("auth_enabled=True", "auth_enabled=False")
                    if content != original:
                        with open(fpath, 'w', encoding='utf-8') as f:
                            f.write(content)
                except Exception:
                    pass
    print("Bypass patching completed successfully.")
except Exception as e:
    print(f"Bypass patching failed silently: {e}")
EOF

RUN python3 /tmp/patch_workspace.py \
    && rm /tmp/patch_workspace.py \
    && chown -R hermes:hermes /opt/hermes-webui

# ── Node router deps ──────────────────────────────────────────
RUN mkdir -p /opt/router \
    && cd /opt/router \
    && npm init -y --quiet \
    && npm install --quiet --no-fund http-proxy

# ── Node.js reverse proxy ─────────────────────────────────────
RUN cat > /opt/router/server.js << 'ENDJS'
'use strict';
var http  = require('http');
var urlParser = require('url');
var proxy = require('http-proxy').createProxyServer({ proxyTimeout: 120000 });

// Render injects PORT=10000 by default; respect whatever is set at runtime
var PORT          = parseInt(process.env.PORT || '10000', 10);
var GATEWAY_TOKEN = process.env.GATEWAY_TOKEN || '';

var DASHBOARD_PATHS = [
  '/dashboard', '/skills', '/plugins', '/mcp', '/webhooks',
  '/pairing', '/profiles', '/config', '/keys', '/system',
  '/cron', '/models', '/logs', '/env'
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

  var cleanGatewayToken = GATEWAY_TOKEN.trim();

  try {
    var url = req.url || '';
    var qIdx = url.indexOf('?');
    if (qIdx !== -1) {
      var search = url.slice(qIdx + 1);
      var params = search.split('&');
      for (var i = 0; i < params.length; i++) {
        var pair = params[i].split('=');
        if (pair[0] === 'token' && decodeURIComponent(pair[1] || '').trim() === cleanGatewayToken) {
          return true;
        }
      }
    }
  } catch (e) {}

  var cookies = parseCookies(req);
  if (cookies['hm_tok'] && decodeURIComponent(cookies['hm_tok']).trim() === cleanGatewayToken) {
    return true;
  }

  var auth = req.headers['authorization'] || '';
  if (auth.trim() === 'Bearer ' + cleanGatewayToken) return true;

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
    '<p class="note">Set GATEWAY_TOKEN in your Render environment variables to activate this gate.</p>' +
    '</div></body></html>';
}

var server = http.createServer(function(req, res) {
  var url = req.url || '/';
  var referer = req.headers.referer || '';
  var pathname = urlParser.parse(url).pathname || '/';

  if (pathname === '/login' || pathname === '/login/') {
    res.writeHead(302, { 'Location': '/' });
    return res.end();
  }

  // Public health check — Render uses this to verify the service is live
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
        var cleanGatewayToken = GATEWAY_TOKEN.trim();
        var cleanInputToken = tok.trim();

        if (!cleanGatewayToken || cleanInputToken === cleanGatewayToken) {
          // On Render the service is behind HTTPS terminated at Render's edge,
          // so SameSite=None; Secure is correct here too.
          var cookieFlags = '; Path=/; HttpOnly; Secure; SameSite=None; Max-Age=31536000';
          var cookies = parseCookies(req);
          var targetScope = cookies['hm_redirect'] || cookies['hm_scope'] || 'webui';
          var destination = (targetScope === 'dashboard') ? '/dashboard' : '/';

          res.writeHead(302, {
            'Set-Cookie': [
              'hm_tok=' + encodeURIComponent(cleanInputToken) + cookieFlags,
              'hm_redirect=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT' + cookieFlags
            ],
            'Location': destination
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
      return res.end(JSON.stringify({ error: 'Unauthorized', hint: 'Please login at /_login.' }));
    }

    var isDashboardNav = pathname === '/dashboard' || pathname.indexOf('/dashboard/') === 0;
    var redirectScope = isDashboardNav ? 'dashboard' : 'webui';
    var cookieFlags = '; Path=/; HttpOnly; Secure; SameSite=None; Max-Age=31536000';

    res.writeHead(302, {
      'Set-Cookie': 'hm_redirect=' + redirectScope + cookieFlags,
      'Location': '/_login'
    });
    return res.end();
  }

  var cookies = parseCookies(req);
  var scopeCookie = cookies['hm_scope'] || '';

  if (pathname === '/dashboard' || pathname.indexOf('/dashboard/') === 0) {
    var cookieFlags2 = '; Path=/; HttpOnly; Secure; SameSite=None; Max-Age=31536000';
    res.setHeader('Set-Cookie', 'hm_scope=dashboard' + cookieFlags2);
    return proxy.web(req, res, { target: 'http://127.0.0.1:9119', changeOrigin: true });
  }

  if (isDashboardPath(pathname)) {
    return proxy.web(req, res, { target: 'http://127.0.0.1:9119', changeOrigin: true });
  }

  if (isGatewayPath(pathname)) {
    return proxy.web(req, res, { target: 'http://127.0.0.1:8642', changeOrigin: false });
  }

  return proxy.web(req, res, { target: 'http://127.0.0.1:8787', changeOrigin: false });
});

server.on('upgrade', function(req, socket, head) {
  var url = req.url || '/';
  var referer = req.headers.referer || '';
  var pathname = urlParser.parse(url).pathname || '/';

  if (!authed(req)) {
    socket.destroy();
    return;
  }

  var cookies = parseCookies(req);
  var activeScope = cookies['hm_scope'] || 'webui';
  var isDashboard = isDashboardPath(pathname);

  if (pathname === '/dashboard' || pathname.indexOf('/dashboard/') === 0) {
    isDashboard = true;
  } else if (referer) {
    try {
      var refPath = urlParser.parse(referer).pathname || '';
      if (refPath === '/dashboard' || refPath.indexOf('/dashboard/') === 0 || isDashboardPath(refPath)) {
        isDashboard = true;
      }
    } catch (e) {}
  }

  if (!isDashboard && activeScope === 'dashboard') {
    isDashboard = true;
  }

  var target = isDashboard
    ? 'http://127.0.0.1:9119'
    : (isGatewayPath(pathname) ? 'http://127.0.0.1:8642' : 'http://127.0.0.1:8787');

  proxy.ws(req, socket, head, { target: target, changeOrigin: (target.indexOf('9119') >= 0) });
});

// ── Graceful shutdown for Render's SIGTERM ─────────────────────
// Render sends SIGTERM before stopping the container. We close the
// HTTP server so no new connections are accepted, then let Node exit.
// Background processes (gateway, dashboard, webui) will be cleaned
// up by the OS after the main process exits.
function shutdown(signal) {
  console.log('[router] Received ' + signal + ' — shutting down gracefully...');
  server.close(function() {
    console.log('[router] HTTP server closed. Exiting.');
    process.exit(0);
  });
  // Force-exit after 20s in case something hangs
  setTimeout(function() {
    console.error('[router] Shutdown timeout — forcing exit');
    process.exit(1);
  }, 20000);
}
process.on('SIGTERM', function() { shutdown('SIGTERM'); });
process.on('SIGINT',  function() { shutdown('SIGINT'); });

server.listen(PORT, '0.0.0.0', function() {
  console.log('[router] Hermes Reverse Proxy active on port ' + PORT);
});
ENDJS

# ── Agent-browser config (no-sandbox + stealth) ───────────────
RUN mkdir -p /home/hermes/.agent-browser /opt/hermes/.agent-browser \
    && cat > /home/hermes/.agent-browser/config.json << 'ENDJSON'
{
  "$schema": "https://agent-browser.dev/schema.json",
  "args": "--no-sandbox,--disable-dev-shm-usage,--disable-gpu,--disable-setuid-sandbox,--disable-software-rasterizer,--disable-blink-features=AutomationControlled,--disable-features=IsolateOrigins,site-per-process,--window-size=1920,1080,--user-agent=Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36,--lang=en-US,--accept-lang=en-US,en;q=0.9,--disable-notifications,--no-first-run,--no-default-browser-check,--disable-background-networking,--disable-sync,--disable-translate",
  "headless": true,
  "ignoreHttpsErrors": true
}
ENDJSON
RUN cp /home/hermes/.agent-browser/config.json /opt/hermes/.agent-browser/config.json

# ── Install Playwright Chromium into shared path ──────────────
RUN mkdir -p /opt/hermes/.playwright \
    && PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright \
       npx --yes playwright install chromium \
    && PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright \
       npx playwright install-deps chromium 2>/dev/null || true \
    && chown -R hermes:hermes /opt/hermes/.playwright

# ── playwright-stealth ────────────────────────────────────────
RUN uv pip install --python /opt/hermes/.venv/bin/python \
    --no-cache-dir "playwright-stealth>=1.0.5"

# ── Stealth init script ───────────────────────────────────────
RUN mkdir -p /opt/hermes-stealth \
    && cat > /opt/hermes-stealth/stealth-init.js << 'ENDJS'
(function() {
  try { Object.defineProperty(navigator, 'webdriver', { get: () => undefined, configurable: true }); } catch(e) {}
  try {
    Object.defineProperty(navigator, 'plugins', {
      get: () => {
        const arr = [
          { name: 'Chrome PDF Plugin', filename: 'internal-pdf-viewer', description: 'Portable Document Format' },
          { name: 'Chrome PDF Viewer', filename: 'mhjfbmdgcfjbbpaeojofohoefgiehjai', description: '' },
          { name: 'Native Client', filename: 'internal-nacl-plugin', description: '' }
        ];
        arr.__proto__ = PluginArray.prototype;
        return arr;
      }, configurable: true
    });
  } catch(e) {}
  try { Object.defineProperty(navigator, 'languages', { get: () => ['en-US', 'en'], configurable: true }); } catch(e) {}
  try {
    if (!window.chrome) { window.chrome = { runtime: {} }; }
    else if (!window.chrome.runtime) { window.chrome.runtime = {}; }
  } catch(e) {}
  try {
    const origQuery = window.navigator.permissions.query;
    window.navigator.permissions.__proto__.query = function(params) {
      if (params.name === 'notifications') {
        return Promise.resolve({ state: Notification.permission === 'denied' ? 'prompt' : Notification.permission });
      }
      return origQuery.call(this, params);
    };
  } catch(e) {}
  try { Object.defineProperty(navigator, 'platform', { get: () => 'Linux x86_64', configurable: true }); } catch(e) {}
})();
ENDJS

# ── Kanban DB patch ───────────────────────────────────────────
RUN cat << 'EOF' > /tmp/patch_kanban.py
import sys
try:
    from pathlib import Path
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
except Exception as e:
    print(f"Kanban patch failed silently: {e}")
EOF
RUN python3 /tmp/patch_kanban.py && rm /tmp/patch_kanban.py

# ── Ownership, symlinks, permissions ─────────────────────────
RUN chsh -s /bin/bash hermes || true \
    && mkdir -p /data /data/logs \
    && mkdir -p /home/hermes \
    && rm -rf /home/hermes/.hermes && ln -sf /data /home/hermes/.hermes \
    && rm -rf /opt/data && ln -sf /data /opt/data \
    && touch /home/hermes/.bashrc \
    && echo "export PATH=\"/opt/hermes/.venv/bin:/opt/data/.local/bin:\$PATH\"" >> /home/hermes/.bashrc \
    && echo "export PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright" >> /home/hermes/.bashrc \
    && echo "export AGENT_BROWSER_ARGS=\"--no-sandbox,--disable-dev-shm-usage,--disable-gpu,--disable-setuid-sandbox,--disable-software-rasterizer\"" >> /home/hermes/.bashrc \
    && echo "export AGENT_BROWSER_CHROME_FLAGS=\"--no-sandbox,--disable-dev-shm-usage,--disable-gpu,--disable-setuid-sandbox,--disable-software-rasterizer\"" >> /home/hermes/.bashrc \
    && chown -R hermes:hermes /data /home/hermes /opt/hermes /opt/hermes-webui /opt/router /opt/hermes-stealth \
    && chown -h hermes:hermes /home/hermes/.hermes /opt/data \
    && chmod -R 777 /data \
    && chown -R hermes:hermes /opt/hermes/.playwright /opt/hermes/.agent-browser /home/hermes/.agent-browser

# ── Boot script ───────────────────────────────────────────────
RUN cat > /opt/start.sh << 'ENDSH'
#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/hermes/.venv/bin:/opt/data/.local/bin:$PATH"

HH="${HERMES_HOME:-/data}"

mkdir -p "$HH" "$HH/logs" "$HH/config" "$HH/memory"

echo "╔══════════════════════════════════════════╗"
echo "║   Hermes Agent — Render bootloader       ║"
echo "╚══════════════════════════════════════════╝"

# Pre-create agent-browser socket dir
mkdir -p /tmp/agent-browser-sockets || true
chmod 777 /tmp/agent-browser-sockets 2>/dev/null || true

# ── 1. BACKGROUND FRONTEND UPDATES ───────────────────────────
echo "[boot] 🔄 Checking for WebUI updates in background..."
(cd /opt/hermes-webui && git pull >/dev/null 2>&1) &

# ── 2. RESTORE FROM HF BUCKET (synchronous) ──────────────────
# WHY: Dashboard and WebUI read ALL data from /data at startup.
# Restoring before services start prevents blank-screen first boot.
# On Render paid plans you also have a persistent disk at /data,
# so the restore fills any gaps from the bucket as a supplement.
# On Render free plans /data is ephemeral — bucket is the only
# persistence layer, making this step critical.
if [ -n "${HF_TOKEN:-}" ] && [ -n "${HF_BUCKET:-}" ]; then
  export HF_TOKEN="${HF_TOKEN}"
  echo "[boot] 📦 Restoring workspace from HF bucket (synchronous)..."
  if hf sync "hf://buckets/${HF_BUCKET}" "$HH" \
      --exclude ".venv/**"          --exclude "**/venv/**"          --exclude "venv/**" \
      --exclude ".cache/**"         --exclude "**/.cache/**" \
      --exclude "node_modules/**"   --exclude "**/node_modules/**" \
      --exclude "__pycache__/**"    --exclude "**/__pycache__/**" \
      --exclude "**/*.pyc"          --exclude "**/*.log" \
      --exclude "logs/**"           --exclude "**/logs/**" \
      --exclude "**/*.db-wal"       --exclude "**/*.db-shm"         --exclude "**/*.db-journal" \
      2>/dev/null; then
    echo "[boot] ✅ Workspace restored from HF bucket"
  else
    echo "[boot] ⚠️  Bucket empty or first run — starting fresh"
  fi
else
  echo "[boot] ℹ️  HF_TOKEN / HF_BUCKET not set — skipping bucket restore"
  echo "[boot]     Data will NOT persist across Render restarts on free plan."
  echo "[boot]     Set HF_TOKEN and HF_BUCKET to enable persistence."
fi

# ── 3. SQLITE INTEGRITY RECOVERY & WAL ENABLING ──────────────
echo "[boot] 🩺 Checking database integrity & enabling WAL mode..."
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
                if res and res[0] == "ok":
                    cursor.execute("PRAGMA journal_mode=WAL;")
                    cursor.execute("PRAGMA synchronous=NORMAL;")
                    conn.commit()
                    print(f"[boot-recover] Database OK and WAL enabled: {fname}")
                else:
                    raise Exception(f"Integrity check failed: {res[0] if res else 'Unknown'}")
                conn.close()
            except Exception as e:
                print(f"[boot-recover] SQLite corrupt/locked: {db_path} ({e})")
                for suffix in ["", "-journal", "-wal", "-shm"]:
                    p = db_path + suffix if suffix else db_path
                    if os.path.exists(p):
                        try: os.remove(p)
                        except Exception: pass
                print(f"[boot-recover] Reset corrupted file: {fname}")
PY_SQLITE_RECOVER

# ── 4. MERGE BUILT-IN SKILLS ──────────────────────────────────
echo "[boot] 🧩 Merging built-in skills into persistent storage..."
for src_skills in /opt/hermes/skills /opt/hermes/hermes_cli/skills /opt/hermes/hermes/skills; do
  if [ -d "$src_skills" ]; then
    mkdir -p "$HH/skills"
    cp -rn "$src_skills"/* "$HH/skills/" 2>/dev/null || true
  fi
done

# ── 5. WEBUI SETTINGS LINKING ─────────────────────────────────
echo "[boot] ⚙️  Linking WebUI configuration assets..."
touch "$HH/webui_settings.json"
if [ ! -s "$HH/webui_settings.json" ]; then
  echo '{"password":"","password_enabled":false,"auth_enabled":false}' > "$HH/webui_settings.json"
else
  if jq . "$HH/webui_settings.json" >/dev/null 2>&1; then
    jq '.password="" | .password_enabled=false | .auth_enabled=false' "$HH/webui_settings.json" \
      > "$HH/webui_settings.json.tmp" && mv "$HH/webui_settings.json.tmp" "$HH/webui_settings.json"
  else
    echo '{"password":"","password_enabled":false,"auth_enabled":false}' > "$HH/webui_settings.json"
  fi
fi
rm -f /opt/hermes-webui/settings.json
ln -sf "$HH/webui_settings.json" /opt/hermes-webui/settings.json

# ── 6. ENVIRONMENT CREDENTIALS SYNC ──────────────────────────
ENV_FILE="$HH/.env"
echo "[boot] 🔑 Synchronizing environment credentials..."
touch "$ENV_FILE"

TMP_ENV=$(mktemp)
[ -f "$ENV_FILE" ] && cat "$ENV_FILE" > "$TMP_ENV"

upsert_key() {
  local key="$1"
  local val="$2"
  if [ -n "$val" ]; then
    sed -i "/^${key}=/d" "$TMP_ENV" || true
    echo "${key}=${val}" >> "$TMP_ENV"
  fi
}

upsert_key "OPENROUTER_API_KEY"  "${OPENROUTER_API_KEY:-}"
upsert_key "OPENAI_API_KEY"      "${OPENAI_API_KEY:-}"
upsert_key "ANTHROPIC_API_KEY"   "${ANTHROPIC_API_KEY:-}"
upsert_key "HF_TOKEN"            "${HF_TOKEN:-}"
upsert_key "API_SERVER_KEY"      "${API_SERVER_KEY:-}"
upsert_key "AGENT_BROWSER_ARGS"  "--no-sandbox,--disable-dev-shm-usage,--disable-gpu,--disable-setuid-sandbox,--disable-software-rasterizer,--disable-blink-features=AutomationControlled,--window-size=1920,1080,--lang=en-US,--no-first-run,--no-default-browser-check"
upsert_key "AGENT_BROWSER_CHROME_FLAGS" "--no-sandbox,--disable-dev-shm-usage,--disable-gpu,--disable-setuid-sandbox,--disable-software-rasterizer,--disable-blink-features=AutomationControlled,--window-size=1920,1080,--lang=en-US,--no-first-run,--no-default-browser-check"
upsert_key "PLAYWRIGHT_BROWSERS_PATH"   "/opt/hermes/.playwright"
upsert_key "AGENT_BROWSER_INIT_SCRIPT"  "/opt/hermes-stealth/stealth-init.js"

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  upsert_key "TELEGRAM_BOT_TOKEN" "${TELEGRAM_BOT_TOKEN}"
  USERS="${TELEGRAM_ALLOWED_USERS:-}"
  if [ -n "$USERS" ]; then
    [[ ! "$USERS" =~ ^\[.*\]$ ]] && USERS="[$USERS]"
    upsert_key "TELEGRAM_ALLOWED_USERS" "$USERS"
  fi
fi

mv "$TMP_ENV" "$ENV_FILE"
chmod 600 "$ENV_FILE"

# ── 7. TELEGRAM / CLOUDFLARE PROXY SETUP ─────────────────────
TELEGRAM_PROXY_URL=""

if [ -n "${TELEGRAM_API_BASE:-}" ]; then
  TELEGRAM_PROXY_URL="${TELEGRAM_API_BASE}"
  echo "[boot-tg] 📡 Using TELEGRAM_API_BASE: ${TELEGRAM_PROXY_URL}"
fi

if [ -z "$TELEGRAM_PROXY_URL" ] && [ -n "${CLOUDFLARE_WORKERS_TOKEN:-}" ]; then
  echo "[boot] ☁️  Auto-provisioning Cloudflare Telegram proxy Worker..."
  TELEGRAM_PROXY_URL=$(python3 - << 'PYEOF'
import sys, json, urllib.request, urllib.error, os, re, socket, time

TOKEN = os.environ.get("CLOUDFLARE_WORKERS_TOKEN", "").strip()
# On Render, RENDER_EXTERNAL_URL is available — use it as the worker name seed
SPACE = os.environ.get("RENDER_EXTERNAL_URL", os.environ.get("SPACE_HOST", ""))

def cf_req(method, path, body=None, content_type="application/json"):
    url = "https://api.cloudflare.com/client/v4" + path
    data = None
    if body is not None:
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method,
        headers={"Authorization": "Bearer " + TOKEN, "Content-Type": content_type})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        try: return json.loads(e.read())
        except: return {"success": False, "error": str(e)}
    except Exception as e:
        return {"success": False, "error": str(e)}

accounts = cf_req("GET", "/accounts")
if not accounts.get("result"):
    sys.stderr.write("[boot] CF: could not get account: " + str(accounts) + "\n")
    sys.exit(0)
account_id = accounts["result"][0]["id"]

hostname = SPACE or "hermes-render"
# Strip https:// if present (RENDER_EXTERNAL_URL includes scheme)
hostname = re.sub(r'^https?://', '', hostname)
worker_name = re.sub(r"[^a-z0-9-]", "-", hostname.lower())[:50] + "-tgproxy"
worker_name = re.sub(r"-+", "-", worker_name).strip("-")
sys.stderr.write("[boot] Worker name: " + worker_name + "\n")

script = b"""addEventListener('fetch', function(event) {
  event.respondWith(handle(event.request));
});
async function handle(request) {
  var u = new URL(request.url);
  var t = new URL('https://api.telegram.org');
  var fileMatch = u.pathname.match(/^([/]bot[^/]+)[/](documents|photos|videos|video_notes|voice|audio|sticker|animations|thumbnails)[/](.+)$/);
  if (fileMatch) {
    t.pathname = '/file' + fileMatch[1] + '/' + fileMatch[2] + '/' + fileMatch[3];
  } else {
    t.pathname = u.pathname;
  }
  t.search = u.search;
  var init = { method: request.method, headers: request.headers, redirect: 'follow' };
  if (request.method !== 'GET' && request.method !== 'HEAD') { init.body = request.body; }
  try {
    var r = await fetch(t.toString(), init);
    var h = new Headers(r.headers);
    h.set('Access-Control-Allow-Origin', '*');
    return new Response(r.body, { status: r.status, headers: h });
  } catch(e) {
    return new Response(JSON.stringify({ok:false,error:e.message}),
      {status:502, headers:{'Content-Type':'application/json'}});
  }
}
"""

deploy = cf_req("PUT",
    "/accounts/" + account_id + "/workers/scripts/" + worker_name,
    body=script, content_type="application/javascript")
if not deploy.get("success"):
    sys.stderr.write("[boot] Worker deploy failed: " + json.dumps(deploy)[:300] + "\n")
    sys.exit(0)

cf_req("POST",
    "/accounts/" + account_id + "/workers/scripts/" + worker_name + "/subdomain",
    body={"enabled": True})

subdomain = ""
for _ in range(3):
    r = cf_req("GET", "/accounts/" + account_id + "/workers/subdomain")
    subdomain = ((r.get("result") or {}).get("subdomain") or "").strip()
    if subdomain: break
    time.sleep(3)

if subdomain:
    proxy_url = "https://" + worker_name + "." + subdomain + ".workers.dev"
    sys.stderr.write("[boot] Proxy URL: " + proxy_url + "\n")
    print(proxy_url, end="")
else:
    sys.stderr.write("[boot] Worker deployed but subdomain unavailable. Set TELEGRAM_API_BASE manually.\n")
PYEOF
  )
  [ -n "$TELEGRAM_PROXY_URL" ] && echo "[boot] ✅ CF proxy: ${TELEGRAM_PROXY_URL}" \
    || echo "[boot] ⚠️  CF Worker deploy failed — falling back to direct"
fi

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  if [ -n "$TELEGRAM_PROXY_URL" ]; then
    TG_TEST_URL="${TELEGRAM_PROXY_URL}/bot${TELEGRAM_BOT_TOKEN}/getMe"
    if curl -s --connect-timeout 8 "$TG_TEST_URL" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print('ok' if d.get('ok') else 'fail')" \
        2>/dev/null | grep -q "ok"; then
      echo "[boot] ✅ Telegram proxy working"
    else
      echo "[boot] ⚠️  Telegram proxy test inconclusive — check gateway logs"
    fi
  else
    echo "[boot] 🌐 No proxy — testing direct Telegram..."
    if curl -s -I --connect-timeout 8 "https://api.telegram.org" > /dev/null 2>&1; then
      echo "[boot] ✅ Direct Telegram OK"
    else
      echo "[boot] ❌ api.telegram.org unreachable — add CLOUDFLARE_WORKERS_TOKEN"
    fi
  fi
fi

if [ -n "$TELEGRAM_PROXY_URL" ]; then
  sed -i "/^TELEGRAM_API_BASE=/d" "${HERMES_HOME:-/data}/.env" 2>/dev/null || true
  echo "TELEGRAM_API_BASE=${TELEGRAM_PROXY_URL}" >> "${HERMES_HOME:-/data}/.env"
  export TELEGRAM_API_BASE="$TELEGRAM_PROXY_URL"
else
  export TELEGRAM_API_BASE="${TELEGRAM_API_BASE:-}"
fi

# ── 8. CONFIGURATION ENFORCEMENT ─────────────────────────────
CFG="$HH/config.yaml"
if [ ! -f "$CFG" ]; then
  echo "[boot] ✍  Writing config.yaml..."
  if   [ -n "${OPENROUTER_API_KEY:-}" ]; then PROVIDER="openrouter"
  elif [ -n "${ANTHROPIC_API_KEY:-}"  ]; then PROVIDER="anthropic"
  elif [ -n "${OPENAI_API_KEY:-}"     ]; then PROVIDER="openai"
  else                                         PROVIDER="auto"; fi

  MODEL="${HERMES_MODEL:-openai/gpt-4o-mini}"
  cat > "$CFG" << YAML
model:
  provider: ${PROVIDER}
  default: "${MODEL}"

browser:
  command_timeout: 90
  inactivity_timeout: 120
  chromium_args:
    - --no-sandbox
    - --disable-dev-shm-usage
    - --disable-gpu
    - --disable-setuid-sandbox
    - --disable-software-rasterizer
    - --disable-blink-features=AutomationControlled
    - --window-size=1920,1080
    - --lang=en-US
    - --no-first-run
    - --no-default-browser-check
YAML
else
  if ! grep -q "^browser:" "$CFG" 2>/dev/null; then
    echo "[boot] 🔧 Appending browser config block..."
    cat >> "$CFG" << YAML

browser:
  command_timeout: 90
  inactivity_timeout: 120
  chromium_args:
    - --no-sandbox
    - --disable-dev-shm-usage
    - --disable-gpu
    - --disable-setuid-sandbox
    - --disable-software-rasterizer
    - --disable-blink-features=AutomationControlled
    - --window-size=1920,1080
    - --lang=en-US
    - --no-first-run
    - --no-default-browser-check
YAML
  fi
fi

# ── 9. START SERVICES ─────────────────────────────────────────
cd "$HH"

echo "[boot] 🚀 Starting Hermes Gateway (port 8642)..."
API_SERVER_ENABLED=true \
API_SERVER_HOST=127.0.0.1 \
API_SERVER_KEY="${API_SERVER_KEY:-local-dev-key}" \
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}" \
TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-}" \
TELEGRAM_API_BASE="${TELEGRAM_API_BASE:-}" \
OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" \
OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
AGENT_BROWSER_ARGS="--no-sandbox,--disable-dev-shm-usage,--disable-gpu,--disable-setuid-sandbox,--disable-software-rasterizer,--disable-blink-features=AutomationControlled,--window-size=1920,1080,--lang=en-US,--no-first-run,--no-default-browser-check" \
AGENT_BROWSER_CHROME_FLAGS="--no-sandbox,--disable-dev-shm-usage,--disable-gpu,--disable-setuid-sandbox,--disable-software-rasterizer,--disable-blink-features=AutomationControlled,--window-size=1920,1080,--lang=en-US,--no-first-run,--no-default-browser-check" \
PLAYWRIGHT_BROWSERS_PATH="/opt/hermes/.playwright" \
AGENT_BROWSER_INIT_SCRIPT="/opt/hermes-stealth/stealth-init.js" \
  hermes gateway run > "$HH/logs/gateway.log" 2>&1 &

echo "[boot] 🗂️  Starting Hermes Dashboard (port 9119)..."
(
  unset TELEGRAM_BOT_TOKEN
  hermes dashboard \
    --host 0.0.0.0 \
    --port 9119 \
    --insecure \
    --no-open \
    > "$HH/logs/dashboard.log" 2>&1
) &

start_webui() {
  cd /opt/hermes-webui
  export HERMES_WEBUI_PASSWORD=""
  export WEBUI_PASSWORD=""
  export PASSWORD=""
  export ADMIN_PASSWORD=""
  export AUTH_ENABLED="false"
  export PASSWORD_ENABLED="false"
  HERMES_WEBUI_AGENT_DIR=/opt/hermes \
  HERMES_API_KEY="${API_SERVER_KEY:-local-dev-key}" \
    python3 server.py >> "$HH/logs/webui.log" 2>&1
}

echo "[boot] 🌐 Starting Hermes WebUI (port 8787)..."
start_webui &
WEBUI_PID=$!

# ── 10. WAIT FOR BACKENDS ────────────────────────────────────
echo "[boot] ⏳ Waiting for gateway on :8642..."
for i in $(seq 1 45); do
  curl -sf http://127.0.0.1:8642/health >/dev/null 2>&1 && { echo "[boot] ✅ Gateway UP!"; break; }
  sleep 2
done

echo "[boot] ⏳ Waiting for dashboard on :9119..."
for i in $(seq 1 45); do
  nc -z 127.0.0.1 9119 2>/dev/null && { echo "[boot] ✅ Dashboard UP!"; break; }
  sleep 2
done

echo "[boot] ⏳ Waiting for WebUI on :8787..."
for i in $(seq 1 45); do
  nc -z 127.0.0.1 8787 2>/dev/null && { echo "[boot] ✅ WebUI UP!"; break; }
  sleep 2
done

# ── WATCHDOG ─────────────────────────────────────────────────
(
  RESTART_DELAY=5
  CHECK_INTERVAL=15
  while true; do
    sleep $CHECK_INTERVAL

    if ! nc -z 127.0.0.1 8787 2>/dev/null; then
      echo "[watchdog] ⚠️  WebUI (8787) DOWN — restarting..."
      sleep $RESTART_DELAY
      (cd /opt/hermes-webui && git pull >/dev/null 2>&1) || true
      start_webui &
      WEBUI_PID=$!
      sleep 8
      nc -z 127.0.0.1 8787 2>/dev/null \
        && echo "[watchdog] ✅ WebUI restarted" \
        || { echo "[watchdog] ❌ WebUI restart failed"; tail -20 "$HH/logs/webui.log" | sed 's/^/[watchdog]   /' || true; }
    fi

    if ! curl -sf http://127.0.0.1:8642/health >/dev/null 2>&1; then
      echo "[watchdog] ⚠️  Gateway (8642) DOWN — restarting..."
      sleep $RESTART_DELAY
      API_SERVER_ENABLED=true \
      API_SERVER_HOST=127.0.0.1 \
      API_SERVER_KEY="${API_SERVER_KEY:-local-dev-key}" \
      TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}" \
      TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-}" \
      TELEGRAM_API_BASE="${TELEGRAM_API_BASE:-}" \
      OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" \
      OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
      ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
      PLAYWRIGHT_BROWSERS_PATH="/opt/hermes/.playwright" \
      AGENT_BROWSER_ARGS="--no-sandbox,--disable-dev-shm-usage,--disable-gpu,--disable-setuid-sandbox,--disable-software-rasterizer,--disable-blink-features=AutomationControlled,--window-size=1920,1080,--lang=en-US,--no-first-run,--no-default-browser-check" \
      AGENT_BROWSER_CHROME_FLAGS="--no-sandbox,--disable-dev-shm-usage,--disable-gpu,--disable-setuid-sandbox,--disable-software-rasterizer,--disable-blink-features=AutomationControlled,--window-size=1920,1080,--lang=en-US,--no-first-run,--no-default-browser-check" \
      AGENT_BROWSER_INIT_SCRIPT="/opt/hermes-stealth/stealth-init.js" \
        hermes gateway run --replace >> "$HH/logs/gateway.log" 2>&1 &
      sleep 10
      curl -sf http://127.0.0.1:8642/health >/dev/null 2>&1 \
        && echo "[watchdog] ✅ Gateway restarted" \
        || { echo "[watchdog] ❌ Gateway restart failed"; tail -20 "$HH/logs/gateway.log" | sed 's/^/[watchdog]   /' || true; }
    fi

    if ! nc -z 127.0.0.1 9119 2>/dev/null; then
      echo "[watchdog] ⚠️  Dashboard (9119) DOWN — restarting..."
      sleep $RESTART_DELAY
      (
        unset TELEGRAM_BOT_TOKEN || true
        hermes dashboard \
          --host 0.0.0.0 --port 9119 --insecure --no-open \
          >> "$HH/logs/dashboard.log" 2>&1
      ) &
      sleep 8
      nc -z 127.0.0.1 9119 2>/dev/null \
        && echo "[watchdog] ✅ Dashboard restarted" \
        || { echo "[watchdog] ❌ Dashboard restart failed"; tail -10 "$HH/logs/dashboard.log" | sed 's/^/[watchdog]   /' || true; }
    fi
  done
) &

# ── 11. HF BUCKET SYNC (background, periodic) ────────────────
# Syncs /data → HF bucket every SYNC_INTERVAL seconds.
# This is the persistence layer for Render (no native disk on free plan,
# and even on paid plans this is an offsite backup).
if [ -n "${HF_TOKEN:-}" ] && [ -n "${HF_BUCKET:-}" ]; then
  (
    echo "[boot-clean] 🧼 Cleaning residual deps from bucket..."
    hf buckets remove "hf://buckets/${HF_BUCKET}/.venv/"        --recursive --yes >/dev/null 2>&1 || true
    hf buckets remove "hf://buckets/${HF_BUCKET}/venv/"         --recursive --yes >/dev/null 2>&1 || true
    hf buckets remove "hf://buckets/${HF_BUCKET}/.cache/"       --recursive --yes >/dev/null 2>&1 || true
    hf buckets remove "hf://buckets/${HF_BUCKET}/node_modules/" --recursive --yes >/dev/null 2>&1 || true
    echo "[boot-clean] ✅ Bucket optimized."

    sleep 20   # let gateway finish migrations before first upload

    while true; do
      python3 -c "
import os, sqlite3, glob
for db in glob.glob('/data/*.db'):
    try:
        c = sqlite3.connect(db, timeout=5)
        c.execute('PRAGMA wal_checkpoint(PASSIVE);')
        c.close()
    except: pass
" 2>/dev/null || true

      hf sync "$HH" "hf://buckets/${HF_BUCKET}" \
          --delete \
          --exclude ".venv/**"         --exclude "**/venv/**"         --exclude "venv/**" \
          --exclude ".cache/**"        --exclude "**/.cache/**" \
          --exclude "node_modules/**"  --exclude "**/node_modules/**" \
          --exclude "__pycache__/**"   --exclude "**/__pycache__/**" \
          --exclude "**/*.pyc"         --exclude "**/*.log" \
          --exclude "logs/**"          --exclude "**/logs/**" \
          --exclude "**/*.db-wal"      --exclude "**/*.db-shm"        --exclude "**/*.db-journal" \
          >/dev/null 2>&1 || true

      sleep "${SYNC_INTERVAL:-30}"
    done
  ) &
fi

# ── 12. START ROUTER ──────────────────────────────────────────
# PORT is injected by Render at runtime (default 10000).
# The router must bind to 0.0.0.0 so Render's edge can reach it.
echo "[boot] 🔀 Starting router on port ${PORT:-10000}..."
exec node /opt/router/server.js
ENDSH

RUN chmod +x /opt/start.sh

# ── Final ownership pass ──────────────────────────────────────
RUN chown hermes:hermes /opt/start.sh /opt/router/server.js \
    && chown -R hermes:hermes /opt/hermes-stealth

# Render default port is 10000
EXPOSE 10000

USER hermes

ENTRYPOINT ["/opt/start.sh"]

# ══════════════════════════════════════════════════════════════
#  render.yaml  (optional — place in repo root alongside Dockerfile)
#  Uncomment and commit this file to use Render Blueprints.
#
#  services:
#    - type: web
#      name: hermes-agent
#      runtime: docker
#      plan: starter          # or "free" for testing
#      healthCheckPath: /health
#      envVars:
#        - key: PORT
#          value: 10000
#        - key: GATEWAY_TOKEN
#          sync: false
#        - key: API_SERVER_KEY
#          sync: false
#        - key: OPENROUTER_API_KEY
#          sync: false
#        - key: HF_TOKEN
#          sync: false
#        - key: HF_BUCKET
#          value: Sanyam400/Hermes-storage
#        # Optional Telegram
#        - key: TELEGRAM_BOT_TOKEN
#          sync: false
#        - key: TELEGRAM_ALLOWED_USERS
#          sync: false
#        - key: CLOUDFLARE_WORKERS_TOKEN
#          sync: false
#      # Persistent disk (paid plans only — remove on free plan)
#      disk:
#        name: hermes-data
#        mountPath: /data
#        sizeGB: 5
# ══════════════════════════════════════════════════════════════
