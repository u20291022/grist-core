#!/usr/bin/env bash
set -euo pipefail

# Determine this script's directory (to locate grist-core)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRIST_CORE_DIR="${SCRIPT_DIR}"

# ============================================================================
#  GRIST SELF-HOSTED: PostgreSQL + Keycloak + Nginx + Let's Encrypt
# ============================================================================
#
#  АРХИТЕКТУРА:
#    Browser → Nginx (:80/:443) → Grist (:8484)
#    Browser → Nginx (:80/:443) → Keycloak (:8080)  [/keycloak/*]
#    Grist  → PostgreSQL (5432)  [база: grist]
#    Keycloak → PostgreSQL (5432)  [база: keycloak]
#
#  РЕШЕНИЕ OIDC ISSUER MISMATCH:
#    Домен grist.localhost (RFC 6761: *.localhost → 127.0.0.1 в браузерах)
#    + Docker network alias grist.localhost → nginx контейнер
#    = и браузер, и Grist видят один и тот же issuer URL
#
#  ИСПОЛЬЗОВАНИЕ:
#    1. Отредактируйте переменные ниже
#    2. chmod +x setup-grist.sh && ./setup-grist.sh
#    3. Скрипт автоматически соберёт образ и запустит стек
#    4. Для production: ./switch-to-production.sh grist.example.com
#
# ============================================================================

# ======================== НАСТРОЙТЕ ПОД СЕБЯ ================================

# -- Домен
#    localhost-тест: grist.localhost (браузеры резолвят → 127.0.0.1 автоматически)
#    production:     grist.example.com
GRIST_DOMAIN="grist.localhost"

# -- Протокол (http для localhost, https для production)
GRIST_PROTO="http"

# -- Организация / Команда
TEAM="my-company"

# -- Администратор Grist
GRIST_ADMIN_EMAIL="admin@example.com"

# -- PostgreSQL
POSTGRES_PASSWORD="Pg_Str0ng_P@ssw0rd_2024"
GRIST_DB_NAME="grist"
KEYCLOAK_DB_NAME="keycloak"
POSTGRES_USER="postgres"

# -- Keycloak
KEYCLOAK_ADMIN="admin"
KEYCLOAK_ADMIN_PASSWORD="Kc_Adm1n_P@ss"
KEYCLOAK_REALM="grist"
KEYCLOAK_CLIENT_ID="grist-app"
KEYCLOAK_CLIENT_SECRET="$(openssl rand -hex 20 2>/dev/null || echo 'grist-oidc-change-me')"

# -- Grist
GRIST_SESSION_SECRET="$(openssl rand -hex 32 2>/dev/null || echo 'change-me-session-secret')"
GRIST_BOOT_KEY="$(openssl rand -hex 16 2>/dev/null || echo 'change-me-boot-key')"

# -- Let's Encrypt (для production)
LETSENCRYPT_EMAIL="admin@example.com"

# -- Директория установки
INSTALL_DIR="$HOME/grist-stack"

# ============================================================================
echo "========================================"
echo "  Grist Self-Hosted Installer"
echo "  Домен: ${GRIST_DOMAIN}"
echo "  URL:   ${GRIST_PROTO}://${GRIST_DOMAIN}"
echo "========================================"

mkdir -p "${INSTALL_DIR}"/{data/grist,data/postgres,nginx/conf.d,certbot/conf,certbot/www}
cd "${INSTALL_DIR}"

# ====================== .env ======================
cat > .env << ENVEOF
COMPOSE_PROJECT_NAME=grist-stack
GRIST_DOMAIN=${GRIST_DOMAIN}
GRIST_PROTO=${GRIST_PROTO}
TEAM=${TEAM}

POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
GRIST_DB_NAME=${GRIST_DB_NAME}
KEYCLOAK_DB_NAME=${KEYCLOAK_DB_NAME}

KEYCLOAK_ADMIN=${KEYCLOAK_ADMIN}
KEYCLOAK_ADMIN_PASSWORD=${KEYCLOAK_ADMIN_PASSWORD}
KEYCLOAK_REALM=${KEYCLOAK_REALM}
KEYCLOAK_CLIENT_ID=${KEYCLOAK_CLIENT_ID}
KEYCLOAK_CLIENT_SECRET=${KEYCLOAK_CLIENT_SECRET}

GRIST_SESSION_SECRET=${GRIST_SESSION_SECRET}
GRIST_BOOT_KEY=${GRIST_BOOT_KEY}
GRIST_ADMIN_EMAIL=${GRIST_ADMIN_EMAIL}

LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}
ENVEOF
echo "[✓] .env"

# ====================== init-db.sh ======================
cat > init-db.sh << 'INITEOF'
#!/bin/bash
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    CREATE DATABASE ${GRIST_DB_NAME:-grist};
    CREATE DATABASE ${KEYCLOAK_DB_NAME:-keycloak};
EOSQL
INITEOF
chmod +x init-db.sh
echo "[✓] init-db.sh"

# ====================== nginx.conf ======================
cat > nginx/conf.d/grist.conf << NGINXEOF
upstream grist_backend {
    server grist:8484;
}

upstream keycloak_backend {
    server keycloak:8080;
}

server {
    listen 80;
    server_name ${GRIST_DOMAIN};

    # Let's Encrypt challenge
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Keycloak
    location /keycloak/ {
        proxy_pass http://keycloak_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
    }

    # Grist
    location / {
        proxy_pass http://grist_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
NGINXEOF
echo "[✓] nginx/conf.d/grist.conf"

# ====================== Keycloak realm import ======================
cat > keycloak-realm-import.json << REALMEOF
{
  "realm": "${KEYCLOAK_REALM}",
  "enabled": true,
  "registrationAllowed": true,
  "registrationEmailAsUsername": true,
  "loginWithEmailAllowed": true,
  "sslRequired": "none",
  "clients": [
    {
      "clientId": "${KEYCLOAK_CLIENT_ID}",
      "name": "Grist",
      "enabled": true,
      "clientAuthenticatorType": "client-secret",
      "secret": "${KEYCLOAK_CLIENT_SECRET}",
      "redirectUris": [
        "${GRIST_PROTO}://${GRIST_DOMAIN}/oauth2/callback",
        "http://${GRIST_DOMAIN}/oauth2/callback",
        "http://grist.localhost/oauth2/callback"
      ],
      "webOrigins": [
        "${GRIST_PROTO}://${GRIST_DOMAIN}",
        "http://${GRIST_DOMAIN}",
        "http://grist.localhost"
      ],
      "protocol": "openid-connect",
      "publicClient": false,
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": false,
      "attributes": {
        "post.logout.redirect.uris": "${GRIST_PROTO}://${GRIST_DOMAIN}##http://grist.localhost"
      }
    }
  ],
  "roles": {
    "realm": [
      { "name": "grist-user", "description": "Grist user" },
      { "name": "grist-admin", "description": "Grist admin" }
    ]
  },
  "defaultRoles": ["grist-user"]
}
REALMEOF
echo "[✓] keycloak-realm-import.json"

# ====================== docker-compose.yml ======================
cat > docker-compose.yml << 'COMPOSEEOF'
services:

  # ======================== PostgreSQL ========================
  postgres:
    image: postgres:16-alpine
    container_name: grist-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      GRIST_DB_NAME: ${GRIST_DB_NAME}
      KEYCLOAK_DB_NAME: ${KEYCLOAK_DB_NAME}
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
      - ./init-db.sh:/docker-entrypoint-initdb.d/init-db.sh:ro
    networks:
      - grist-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER}"]
      interval: 10s
      timeout: 5s
      retries: 5

  # ======================== Keycloak ========================
  keycloak:
    image: quay.io/keycloak/keycloak:latest
    container_name: grist-keycloak
    restart: unless-stopped
    command: start-dev --import-realm
    environment:
      KEYCLOAK_ADMIN: ${KEYCLOAK_ADMIN}
      KEYCLOAK_ADMIN_PASSWORD: ${KEYCLOAK_ADMIN_PASSWORD}

      # --- БД ---
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://postgres:5432/${KEYCLOAK_DB_NAME}
      KC_DB_USERNAME: ${POSTGRES_USER}
      KC_DB_PASSWORD: ${POSTGRES_PASSWORD}

      # --- Hostname (КЛЮЧЕВОЕ) ---
      # Keycloak advertise'ит этот URL как issuer
      # Браузер и Grist оба обращаются по нему
      KC_HOSTNAME_URL: ${GRIST_PROTO}://${GRIST_DOMAIN}/keycloak
      KC_HOSTNAME_ADMIN_URL: ${GRIST_PROTO}://${GRIST_DOMAIN}/keycloak

      KC_HTTP_RELATIVE_PATH: /keycloak
      KC_HTTP_ENABLED: "true"
      KC_PROXY_HEADERS: xforwarded
      KC_HEALTH_ENABLED: "true"

    healthcheck:
      test: ["CMD-SHELL", "exec 3<>/dev/tcp/localhost/8080 && echo -e 'GET /keycloak/health/ready HTTP/1.1\r\nHost: localhost\r\n\r\n' >&3 && cat <&3 | grep -q '200 OK'"]
      interval: 10s
      timeout: 5s
      retries: 20
      start_period: 60s

    volumes:
      - ./keycloak-realm-import.json:/opt/keycloak/data/import/grist-realm.json:ro
    networks:
      - grist-net
    depends_on:
      postgres:
        condition: service_healthy

  # ======================== Grist ========================
  grist:
    image: grist-custom:latest
    container_name: grist-app
    restart: unless-stopped
    environment:
      # --- Основные ---
      APP_HOME_URL: ${GRIST_PROTO}://${GRIST_DOMAIN}
      GRIST_DOMAIN: ${GRIST_DOMAIN}
      GRIST_SINGLE_ORG: ${TEAM}
      GRIST_ORG_IN_PATH: "true"
      GRIST_DEFAULT_EMAIL: ${GRIST_ADMIN_EMAIL}
      GRIST_SUPPORT_ANON: "false"
      GRIST_FORCE_LOGIN: "true"

      # --- Безопасность ---
      GRIST_SESSION_SECRET: ${GRIST_SESSION_SECRET}
      GRIST_BOOT_KEY: ${GRIST_BOOT_KEY}
      GRIST_SANDBOX_FLAVOR: gvisor

      # --- PostgreSQL ---
      TYPEORM_TYPE: postgres
      TYPEORM_HOST: postgres
      TYPEORM_PORT: "5432"
      TYPEORM_DATABASE: ${GRIST_DB_NAME}
      TYPEORM_USERNAME: ${POSTGRES_USER}
      TYPEORM_PASSWORD: ${POSTGRES_PASSWORD}

      # --- OIDC / Keycloak ---
      # Issuer через nginx alias — один URL для браузера и для Grist
      GRIST_OIDC_IDP_ISSUER: ${GRIST_PROTO}://${GRIST_DOMAIN}/keycloak/realms/${KEYCLOAK_REALM}
      GRIST_OIDC_IDP_CLIENT_ID: ${KEYCLOAK_CLIENT_ID}
      GRIST_OIDC_IDP_CLIENT_SECRET: ${KEYCLOAK_CLIENT_SECRET}
      GRIST_OIDC_IDP_SCOPES: "openid email profile"
      GRIST_OIDC_IDP_ENABLED_PROTECTIONS: "STATE,NONCE"
      GRIST_OIDC_SP_IGNORE_EMAIL_VERIFIED: "true"

      # --- UI ---
      GRIST_HIDE_UI_ELEMENTS: "billing,templates"
      GRIST_WIDGET_LIST_URL: "https://github.com/gristlabs/grist-widget/releases/download/latest/manifest.json"

    volumes:
      - ./data/grist:/persist
    networks:
      - grist-net
    depends_on:
      postgres:
        condition: service_healthy
      keycloak:
        condition: service_healthy

  # ======================== Nginx ========================
  nginx:
    image: nginx:alpine
    container_name: grist-nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./certbot/conf:/etc/letsencrypt:ro
      - ./certbot/www:/var/www/certbot:ro
    networks:
      grist-net:
        # ╔══════════════════════════════════════════════════════════╗
        # ║  КЛЮЧ К РЕШЕНИЮ ISSUER MISMATCH                        ║
        # ║                                                          ║
        # ║  nginx получает alias = GRIST_DOMAIN (grist.localhost)   ║
        # ║                                                          ║
        # ║  Браузер: grist.localhost → 127.0.0.1 (RFC 6761) → :80  ║
        # ║  Grist:   grist.localhost → nginx (docker DNS)   → :80  ║
        # ║                                                          ║
        # ║  Один URL — нет mismatch ✓                              ║
        # ╚══════════════════════════════════════════════════════════╝
        aliases:
          - ${GRIST_DOMAIN}
    depends_on:
      - grist
      - keycloak

  # ======================== Certbot (раскомментировать для production) ========================
  # certbot:
  #   image: certbot/certbot
  #   container_name: grist-certbot
  #   volumes:
  #     - ./certbot/conf:/etc/letsencrypt
  #     - ./certbot/www:/var/www/certbot
  #   entrypoint: "/bin/sh -c 'trap exit TERM; while :; do certbot renew; sleep 12h & wait $${!}; done'"

networks:
  grist-net:
    driver: bridge
COMPOSEEOF
echo "[✓] docker-compose.yml"

# ====================== switch-to-production.sh ======================
cat > switch-to-production.sh << 'SWITCHEOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -z "${1:-}" ]; then
  echo "Использование: ./switch-to-production.sh grist.example.com [admin@example.com]"
  exit 1
fi

DOMAIN="$1"
EMAIL="${2:-admin@${DOMAIN}}"

echo "=== Переключение на production ==="
echo "  Домен: ${DOMAIN}"
echo "  Email: ${EMAIL}"

# 1. Обновить .env
sed -i "s|^GRIST_DOMAIN=.*|GRIST_DOMAIN=${DOMAIN}|" .env
sed -i "s|^GRIST_PROTO=.*|GRIST_PROTO=https|" .env
sed -i "s|^LETSENCRYPT_EMAIL=.*|LETSENCRYPT_EMAIL=${EMAIL}|" .env

# 2. Nginx конфиг с HTTPS
cat > nginx/conf.d/grist.conf << SSLNGINX
upstream grist_backend {
    server grist:8484;
}
upstream keycloak_backend {
    server keycloak:8080;
}

server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    location /keycloak/ {
        proxy_pass http://keycloak_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
    }

    location / {
        proxy_pass http://grist_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
SSLNGINX

echo ""
echo "=== Готово! Следующие шаги: ==="
echo ""
echo "1. Раскомментируйте certbot в docker-compose.yml"
echo ""
echo "2. Сначала получите сертификат (nginx без SSL):"
echo "   docker compose down"
echo "   # Временно закомментируйте ssl блок в nginx/conf.d/grist.conf"
echo "   docker compose up -d nginx"
echo "   docker compose run --rm certbot certonly --webroot \\"
echo "     -w /var/www/certbot -d ${DOMAIN} \\"
echo "     --email ${EMAIL} --agree-tos --no-eff-email"
echo ""
echo "3. Верните ssl блок и перезапустите:"
echo "   docker compose down && docker compose up -d"
echo ""
echo "4. Автопродление (cron):"
echo "   0 0 */60 * * cd $(pwd) && docker compose run --rm certbot renew && docker compose exec nginx nginx -s reload"
SWITCHEOF
chmod +x switch-to-production.sh
echo "[✓] switch-to-production.sh"

# ====================== Вывод ======================
# ====================== Build custom Grist image ======================
echo ""
echo "[...] Building grist-custom:latest from ${GRIST_CORE_DIR} ..."
docker build -t grist-custom:latest "${GRIST_CORE_DIR}"
echo "[✓] grist-custom:latest built"

# ====================== Start the stack ======================
echo ""
echo "[...] Starting docker compose ..."
cd "${INSTALL_DIR}"
docker compose up -d
echo "[✓] docker compose up -d"

cat << INFOEOF

========================================================================
  ✅  ВСЁ ГОТОВО
========================================================================

  📁  ${INSTALL_DIR}/
  ├── .env
  ├── docker-compose.yml
  ├── init-db.sh
  ├── keycloak-realm-import.json
  ├── switch-to-production.sh
  ├── nginx/conf.d/grist.conf         ← монтируется в /etc/nginx/conf.d
  └── data/{grist,postgres}/

========================================================================
  🚀  ЗАПУСК
========================================================================

  cd ${INSTALL_DIR}
  docker compose up -d

  Подождите 30-60 секунд (Keycloak инициализируется).

========================================================================
  🔗  АДРЕСА
========================================================================

  Grist:          http://grist.localhost
  Keycloak Admin: http://grist.localhost/keycloak/admin
                  Логин: ${KEYCLOAK_ADMIN} / ${KEYCLOAK_ADMIN_PASSWORD}
  Grist Boot:     http://grist.localhost/admin?boot-key=${GRIST_BOOT_KEY}

========================================================================
  🔑  КАК РЕШЁН ISSUER MISMATCH
========================================================================

  Проблема:
    Grist (docker) не видит localhost → не может сходить к Keycloak
    Браузер не видит keycloak:8080 → не может залогиниться

  Решение:
    nginx получает Docker network alias "grist.localhost"

    Браузер:
      grist.localhost → 127.0.0.1 (RFC 6761) → host :80 → nginx → keycloak

    Grist (внутри docker):
      grist.localhost → nginx (docker DNS alias) → keycloak

    Keycloak (KC_HOSTNAME_URL):
      advertise'ит issuer = http://grist.localhost/keycloak/realms/grist

    Один и тот же URL для всех → нет mismatch ✓

========================================================================
  👤  ПЕРВАЯ НАСТРОЙКА
========================================================================

  1. Realm "grist" и клиент "grist-app" созданы автоматически
  2. Keycloak Admin → realm "grist" → Users → Add user
  3. Задайте email → Credentials → Set password
  4. Откройте http://grist.localhost → логин через Keycloak
  5. Пользователь "${GRIST_ADMIN_EMAIL}" = админ Grist

========================================================================
  🌐  PRODUCTION
========================================================================

  ./switch-to-production.sh grist.example.com admin@example.com

========================================================================
INFOEOF
