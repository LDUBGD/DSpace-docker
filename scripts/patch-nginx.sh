#!/bin/bash
set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
ENV_FILE="$SCRIPT_DIR/../.env"

if [ -f "$ENV_FILE" ]; then
    set -a
    source <(grep -vE '^\s*#' "$ENV_FILE" | grep -vE '^\s*$')
    set +a
else
    echo "❌ Error: .env file not found."
    exit 1
fi

TARGET_FILE="$SCRIPT_DIR/../nginx/conf.d/dspace.conf"
mkdir -p "$(dirname "$TARGET_FILE")"

echo "🔧 Patching Nginx..."

# INTELLIGENT PROTOCOL DETECTION
PROTO_HEADER="http"
PORT_HEADER="80"

# Якщо в URL є https АБО ми сказали, що SSL увімкнено
if [[ "$DSPACE_UI_BASEURL" == https* ]] || [ "${PUBLIC_SSL:-false}" = "true" ]; then
    echo "🔒 HTTPS Detected. Configuring secure headers."
    PROTO_HEADER="https"
    PORT_HEADER="443"
else
    echo "🔓 HTTP Detected."
fi

UPSTREAM_UI="http://127.0.0.1:${DSPACE_UI_PORT:-8081}"
UPSTREAM_API="http://${DSPACE_CONTAINER_NAME:-dspace}:${DSPACE_INTERNAL_PORT:-8080}${DSPACE_REST_NAMESPACE:-/server}"

cat <<EOF > "$TARGET_FILE"
server {
    listen 80;
    server_name _ ;

    client_max_body_size 512M;
    large_client_header_buffers 4 32k;
    
    # Оптимізація буферів
    proxy_buffer_size 128k;
    proxy_buffers 4 256k;
    proxy_busy_buffers_size 256k;

    location / {
        proxy_pass ${UPSTREAM_UI};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$http_host;
        proxy_cache_bypass \$http_upgrade;
        
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host \$http_host;
        
        # CRITICAL FOR CLOUDFLARE & DSPACE 7
        proxy_set_header X-Forwarded-Proto ${PROTO_HEADER};
        proxy_set_header X-Forwarded-Port ${PORT_HEADER};
    }

    location ${DSPACE_REST_NAMESPACE:-/server} {
        proxy_pass ${UPSTREAM_API};
        
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host \$http_host;
        
        # CRITICAL FOR CLOUDFLARE & DSPACE 7
        proxy_set_header X-Forwarded-Proto ${PROTO_HEADER};
        proxy_set_header X-Forwarded-Port ${PORT_HEADER};
        
        # Виправлення для куків
        proxy_cookie_path ${DSPACE_REST_NAMESPACE:-/server} /;
        
        proxy_read_timeout 300s;
        proxy_connect_timeout 300s;
    }
}
EOF

echo "✅ Nginx configured."