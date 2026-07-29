#!/bin/sh
set -e

# =============================================================================
# Entrypoint — Libra Pulse single container
# Variables soportadas (mismas que el .env del proyecto):
#   GRAFANA_ADMIN_USER      (obligatorio)
#   GRAFANA_ADMIN_PASSWORD  (obligatorio, no puede ser "admin")
#   GRAFANA_HMAC_SECRET     (obligatorio) — secreto compartido con
#     PK_GAL_TELEMETRY.GET_URL_PANEL para validar el token de un solo
#     minuto usado en el SSO desde Forms (sustituye el envío de la
#     contraseña real por la URL)
# =============================================================================

# ── Validar credenciales obligatorias ─────────────────────────────────────────
if [ -z "${GRAFANA_ADMIN_USER:-}" ]; then
    echo "[entrypoint] ERROR: GRAFANA_ADMIN_USER no definida." >&2
    exit 1
fi
if [ -z "${GRAFANA_ADMIN_PASSWORD:-}" ] || [ "${GRAFANA_ADMIN_PASSWORD}" = "admin" ]; then
    echo "[entrypoint] ERROR: GRAFANA_ADMIN_PASSWORD no definida o usa el valor por defecto 'admin'." >&2
    exit 1
fi
if [ -z "${GRAFANA_HMAC_SECRET:-}" ]; then
    echo "[entrypoint] ERROR: GRAFANA_HMAC_SECRET no definida." >&2
    exit 1
fi

GAL_SESSION_TOKEN=$(openssl rand -hex 32)

# ── Directorios de datos (por si el volumen /data se monta vacío) ─────────────
mkdir -p \
  /data/grafana/plugins \
  /data/prometheus \
  /data/loki/chunks \
  /data/loki/rules \
  /data/loki/compactor \
  /data/tempo/blocks \
  /data/tempo/wal \
  /data/tempo/generator \
  /data/alloy \
  /var/log/supervisor \
  /var/log/galileo \
  /etc/grafana \
  /etc/nginx/njs

chown -R telemetry:telemetry \
  /data \
  /var/log/supervisor \
  /var/log/galileo \
  /apps/resources

# ── Generar grafana.ini desde variables de entorno ────────────────────────────
cat > /etc/grafana/grafana.ini <<EOF
[server]
root_url = %(protocol)s://%(domain)s:%(http_port)s/
serve_from_sub_path = false

[live]
allowed_origins = *

[security]
admin_user     = ${GRAFANA_ADMIN_USER}
admin_password = ${GRAFANA_ADMIN_PASSWORD}

[users]
allow_sign_up = false
default_theme = light

[date_formats]
use_browser_locale = true

[auth.anonymous]
enabled = false

[auth.proxy]
enabled = true
header_name = X-WEBAUTH-USER
header_property = username
auto_sign_up = true
whitelist = 127.0.0.1
enable_login_token = true

[dashboards]
default_home_dashboard_path = /etc/grafana/provisioning/dashboards/galileo-overview.json
EOF

# ── Configuración extra de Nginx ──────────────────────────────────────────────
echo "map_hash_bucket_size 128;" > /etc/nginx/conf.d/00-map-hash.conf

# ── Script njs: verifica el token HMAC de un solo uso por minuto (SSO desde Forms) ──
# Sustituye la comparación en claro de user:pass — el secreto compartido
# (GRAFANA_HMAC_SECRET) nunca viaja por la URL, solo un HMAC de la ventana
# de tiempo actual, calculado también por PK_GAL_TELEMETRY.GET_URL_PANEL.
cat > /etc/nginx/njs/auth_token.js << EOF
function checkToken(r) {
    var secret = "${GRAFANA_HMAC_SECRET}";
    var token = r.args.token || '';
    var crypto = require('crypto');
    var ventanaActual = Math.floor(Date.now() / 1000 / 60);

    // Tolerancia de un minuto (ventana actual y anterior) para cubrir el
    // desfase entre el cálculo en BD y la llegada de la petición a Nginx.
    for (var i = 0; i <= 1; i++) {
        var esperado = crypto.createHmac('sha256', secret)
                              .update(String(ventanaActual - i))
                              .digest('hex');
        if (token !== '' && token === esperado) {
            return '1';
        }
    }
    return '0';
}

export default { checkToken };
EOF

# ── Generar nginx.conf sustituyendo variables de entorno ─────────────────────
cat > /etc/nginx/conf.d/grafana.conf << EOF
js_import auth_token from /etc/nginx/njs/auth_token.js;
js_set \$auth_ok auth_token.checkToken;

map \$cookie_libra_pulse_auth \$cookie_ok {
    default                  0;
    "${GAL_SESSION_TOKEN}"   1;
}

map \$cookie_grafana_session \$grafana_session_ok {
    default  0;
    ""       0;
    ~.+      1;
}

map "\${auth_ok}\${cookie_ok}\${grafana_session_ok}" \$allow {
    default  0;
    ~1       1;
}

map \$auth_ok \$set_auth_cookie {
    1       "libra_pulse_auth=${GAL_SESSION_TOKEN}; Path=/; HttpOnly";
    default "";
}

server {
    listen 80;

    location /login {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_pass http://127.0.0.1:3000;
    }

    location /logout {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        add_header Set-Cookie "libra_pulse_auth=; Path=/; HttpOnly; Expires=Thu, 01 Jan 1970 00:00:00 GMT";
        proxy_pass http://127.0.0.1:3000;
    }

    location /user/ {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_pass http://127.0.0.1:3000;
    }

    location /public/ {
        proxy_set_header X-WEBAUTH-USER "${GRAFANA_ADMIN_USER}";
        proxy_set_header X-WEBAUTH-ROLE "Viewer";
        proxy_set_header Host \$host;
        proxy_pass http://127.0.0.1:3000;
        proxy_hide_header Cache-Control;
        add_header Cache-Control "no-cache";
    }

    location /api/live/ws {
        proxy_set_header X-WEBAUTH-USER "${GRAFANA_ADMIN_USER}";
        proxy_set_header X-WEBAUTH-ROLE "Viewer";
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_http_version 1.1;
        proxy_pass http://127.0.0.1:3000;
    }

    location /api/ {
        proxy_set_header X-WEBAUTH-USER "${GRAFANA_ADMIN_USER}";
        proxy_set_header X-WEBAUTH-ROLE "Viewer";
        proxy_set_header Host \$host;
        proxy_pass http://127.0.0.1:3000;
    }

    location /apis/ {
        proxy_set_header X-WEBAUTH-USER "${GRAFANA_ADMIN_USER}";
        proxy_set_header X-WEBAUTH-ROLE "Viewer";
        proxy_set_header Host \$host;
        proxy_pass http://127.0.0.1:3000;
    }

    location /avatar/ {
        proxy_set_header X-WEBAUTH-USER "${GRAFANA_ADMIN_USER}";
        proxy_set_header X-WEBAUTH-ROLE "Viewer";
        proxy_set_header Host \$host;
        proxy_pass http://127.0.0.1:3000;
    }

    location / {
        if (\$allow = "0") {
            return 302 \$scheme://\$http_host/login;
        }

        add_header Set-Cookie \$set_auth_cookie;

        proxy_set_header X-WEBAUTH-USER "${GRAFANA_ADMIN_USER}";
        proxy_set_header X-WEBAUTH-ROLE "Viewer";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_http_version 1.1;

        proxy_pass http://127.0.0.1:3000;
    }
}
EOF

# ── Deshabilitar el site default de nginx ─────────────────────────────────────
rm -f /etc/nginx/sites-enabled/default

# ── Forzar recarga de provisioning tras arranque de Grafana ──────────────────
(sleep 15 && curl -sf -X POST \
  -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
  http://localhost:3000/api/admin/provisioning/dashboards/reload) &

chown -R telemetry:telemetry /etc/grafana /etc/nginx/conf.d/grafana.conf /etc/nginx/njs/auth_token.js

echo "[entrypoint] Configuración lista. Arrancando supervisord..."
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/libra-pulse.conf