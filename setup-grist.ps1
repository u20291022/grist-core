# ============================================================================
#  GRIST SELF-HOSTED: PostgreSQL + Keycloak + Nginx + Let's Encrypt
#  Windows PowerShell Version
# ============================================================================
#
#  АРХИТЕКТУРА:
#    Browser → Nginx (:80/:443) → Grist (:8484)
#    Browser → Nginx (:80/:443) → Keycloak (:8080)  [/keycloak/*]
#    Grist  → PostgreSQL (5432)  [база: grist]
#    Keycloak → PostgreSQL (5432)  [база: keycloak]
#
#  ИСПОЛЬЗОВАНИЕ:
#    1. Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
#    2. Отредактируйте переменные ниже
#    3. .\setup-grist.ps1
#    4. Скрипт автоматически соберёт образ и запустит стек
#    5. Для production: .\switch-to-production.ps1 grist.example.com
#
# ============================================================================

# ======================== НАСТРОЙТЕ ПОД СЕБЯ ================================

# -- Домен
#    localhost-тест: grist.localhost (браузеры резолвят → 127.0.0.1 автоматически)
#    production:     grist.example.com
$GRIST_DOMAIN = "grist.localhost"

# -- Протокол (http для localhost, https для production)
$GRIST_PROTO = "http"

# -- Организация / Команда
$TEAM = "my-company"

# -- Администратор Grist
$GRIST_ADMIN_EMAIL = "admin@example.com"

# -- PostgreSQL
$POSTGRES_PASSWORD = "Pg_Str0ng_P@ssw0rd_2024"
$GRIST_DB_NAME = "grist"
$KEYCLOAK_DB_NAME = "keycloak"
$POSTGRES_USER = "postgres"

# -- Keycloak
$KEYCLOAK_ADMIN = "admin"
$KEYCLOAK_ADMIN_PASSWORD = "Kc_Adm1n_P@ss"
$KEYCLOAK_REALM = "grist"
$KEYCLOAK_CLIENT_ID = "grist-app"

# Генерируем случайные строки
function Get-RandomHex {
    param([int]$Length)
    $bytes = New-Object byte[] ($Length / 2)
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $rng.GetBytes($bytes)
    return ($bytes | ForEach-Object { "{0:X2}" -f $_ }) -join ""
}

$KEYCLOAK_CLIENT_SECRET = Get-RandomHex 40
$GRIST_SESSION_SECRET = Get-RandomHex 64
$GRIST_BOOT_KEY = Get-RandomHex 32

# -- Let's Encrypt (для production)
$LETSENCRYPT_EMAIL = "admin@example.com"

# -- Директория установки
$INSTALL_DIR = Join-Path $HOME "grist-stack"

# Determine this script's directory (to locate grist-core)
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$GRIST_CORE_DIR = $SCRIPT_DIR

# ============================================================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Grist Self-Hosted Installer" -ForegroundColor Cyan
Write-Host "  Домен: $GRIST_DOMAIN" -ForegroundColor Cyan
Write-Host "  URL:   ${GRIST_PROTO}://${GRIST_DOMAIN}" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Создаем директории
$dirs = @(
    "$INSTALL_DIR/data/grist",
    "$INSTALL_DIR/data/postgres",
    "$INSTALL_DIR/nginx/conf.d",
    "$INSTALL_DIR/certbot/conf",
    "$INSTALL_DIR/certbot/www"
)

foreach ($dir in $dirs) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

Set-Location $INSTALL_DIR

# ====================== .env ======================
$env_content = @"
COMPOSE_PROJECT_NAME=grist-stack
GRIST_DOMAIN=$GRIST_DOMAIN
GRIST_PROTO=$GRIST_PROTO
TEAM=$TEAM

POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
GRIST_DB_NAME=$GRIST_DB_NAME
KEYCLOAK_DB_NAME=$KEYCLOAK_DB_NAME

KEYCLOAK_ADMIN=$KEYCLOAK_ADMIN
KEYCLOAK_ADMIN_PASSWORD=$KEYCLOAK_ADMIN_PASSWORD
KEYCLOAK_REALM=$KEYCLOAK_REALM
KEYCLOAK_CLIENT_ID=$KEYCLOAK_CLIENT_ID
KEYCLOAK_CLIENT_SECRET=$KEYCLOAK_CLIENT_SECRET

GRIST_SESSION_SECRET=$GRIST_SESSION_SECRET
GRIST_BOOT_KEY=$GRIST_BOOT_KEY
GRIST_ADMIN_EMAIL=$GRIST_ADMIN_EMAIL

LETSENCRYPT_EMAIL=$LETSENCRYPT_EMAIL
"@

Set-Content -Path ".env" -Value $env_content -Encoding UTF8
Write-Host "[✓] .env" -ForegroundColor Green

# ====================== init-db.sh ======================
$init_db_content = @"
#!/bin/bash
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    CREATE DATABASE $GRIST_DB_NAME;
    CREATE DATABASE $KEYCLOAK_DB_NAME;
EOSQL
"@

# Write with Unix line endings (LF only) for Linux compatibility
$init_db_content = $init_db_content -replace "`r`n", "`n"
[System.IO.File]::WriteAllText("$PWD/init-db.sh", $init_db_content)
Write-Host "[✓] init-db.sh" -ForegroundColor Green

# ====================== nginx.conf ======================
$nginx_conf = @"
upstream grist_backend {
    server grist:8484;
}

upstream keycloak_backend {
    server keycloak:8080;
}

server {
    listen 80;
    server_name $GRIST_DOMAIN;

    # Let's Encrypt challenge
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Keycloak
    location /keycloak/ {
        proxy_pass http://keycloak_backend;
        proxy_set_header Host `$host;
        proxy_set_header X-Real-IP `$remote_addr;
        proxy_set_header X-Forwarded-For `$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto `$scheme;
        proxy_set_header X-Forwarded-Host `$host;
        proxy_set_header X-Forwarded-Port `$server_port;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
    }

    # Grist
    location / {
        proxy_pass http://grist_backend;
        proxy_set_header Host `$host;
        proxy_set_header X-Real-IP `$remote_addr;
        proxy_set_header X-Forwarded-For `$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto `$scheme;

        # WebSocket
        proxy_http_version 1.1;
        proxy_set_header Upgrade `$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
"@

Set-Content -Path "nginx/conf.d/grist.conf" -Value $nginx_conf -Encoding UTF8
Write-Host "[✓] nginx/conf.d/grist.conf" -ForegroundColor Green

# ====================== Keycloak realm import ======================
$keycloak_realm = @"
{
  "realm": "$KEYCLOAK_REALM",
  "enabled": true,
  "registrationAllowed": true,
  "registrationEmailAsUsername": true,
  "loginWithEmailAllowed": true,
  "sslRequired": "none",
  "clients": [
    {
      "clientId": "$KEYCLOAK_CLIENT_ID",
      "name": "Grist",
      "enabled": true,
      "clientAuthenticatorType": "client-secret",
      "secret": "$KEYCLOAK_CLIENT_SECRET",
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
"@

Set-Content -Path "keycloak-realm-import.json" -Value $keycloak_realm -Encoding UTF8
Write-Host "[✓] keycloak-realm-import.json" -ForegroundColor Green

# ====================== docker-compose.yml ======================
$docker_compose = @"
services:

  # ======================== PostgreSQL ========================
  postgres:
    image: postgres:16-alpine
    container_name: grist-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: `${POSTGRES_USER}
      POSTGRES_PASSWORD: `${POSTGRES_PASSWORD}
      GRIST_DB_NAME: `${GRIST_DB_NAME}
      KEYCLOAK_DB_NAME: `${KEYCLOAK_DB_NAME}
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
      - ./init-db.sh:/docker-entrypoint-initdb.d/init-db.sh:ro
    networks:
      - grist-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U `${POSTGRES_USER}"]
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
      KEYCLOAK_ADMIN: `${KEYCLOAK_ADMIN}
      KEYCLOAK_ADMIN_PASSWORD: `${KEYCLOAK_ADMIN_PASSWORD}

      # --- БД ---
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://postgres:5432/`${KEYCLOAK_DB_NAME}
      KC_DB_USERNAME: `${POSTGRES_USER}
      KC_DB_PASSWORD: `${POSTGRES_PASSWORD}

      # --- Hostname (КЛЮЧЕВОЕ) ---
      KC_HOSTNAME_URL: `${GRIST_PROTO}://`${GRIST_DOMAIN}/keycloak
      KC_HOSTNAME_ADMIN_URL: `${GRIST_PROTO}://`${GRIST_DOMAIN}/keycloak

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
      APP_HOME_URL: `${GRIST_PROTO}://`${GRIST_DOMAIN}
      GRIST_DOMAIN: `${GRIST_DOMAIN}
      GRIST_SINGLE_ORG: `${TEAM}
      GRIST_ORG_IN_PATH: "true"
      GRIST_DEFAULT_EMAIL: `${GRIST_ADMIN_EMAIL}
      GRIST_SUPPORT_ANON: "false"
      GRIST_FORCE_LOGIN: "true"

      # --- Безопасность ---
      GRIST_SESSION_SECRET: `${GRIST_SESSION_SECRET}
      GRIST_BOOT_KEY: `${GRIST_BOOT_KEY}
      GRIST_SANDBOX_FLAVOR: gvisor

      # --- PostgreSQL ---
      TYPEORM_TYPE: postgres
      TYPEORM_HOST: postgres
      TYPEORM_PORT: "5432"
      TYPEORM_DATABASE: `${GRIST_DB_NAME}
      TYPEORM_USERNAME: `${POSTGRES_USER}
      TYPEORM_PASSWORD: `${POSTGRES_PASSWORD}

      # --- OIDC / Keycloak ---
      GRIST_OIDC_IDP_ISSUER: `${GRIST_PROTO}://`${GRIST_DOMAIN}/keycloak/realms/`${KEYCLOAK_REALM}
      GRIST_OIDC_IDP_CLIENT_ID: `${KEYCLOAK_CLIENT_ID}
      GRIST_OIDC_IDP_CLIENT_SECRET: `${KEYCLOAK_CLIENT_SECRET}
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
        aliases:
          - `${GRIST_DOMAIN}
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
  #   entrypoint: "/bin/sh -c 'trap exit TERM; while :; do certbot renew; sleep 12h & wait `$`${!}; done'"

networks:
  grist-net:
    driver: bridge
"@

Set-Content -Path "docker-compose.yml" -Value $docker_compose -Encoding UTF8
Write-Host "[✓] docker-compose.yml" -ForegroundColor Green

# ====================== switch-to-production.ps1 ======================
$switch_prod_lines = @(
    "# Переключение на production",
    "# Использование: .\switch-to-production.ps1 grist.example.com [admin@example.com]",
    "",
    "param(",
    "    [string]`$Domain,",
    "    [string]`$Email",
    ")",
    "",
    "if ([string]::IsNullOrWhiteSpace(`$Domain)) {",
    "    Write-Host 'Использование: .\switch-to-production.ps1 grist.example.com [admin@example.com]' -ForegroundColor Yellow",
    "    exit 1",
    "}",
    "",
    "if ([string]::IsNullOrWhiteSpace(`$Email)) {",
    "    `$Email = 'admin@' + `$Domain",
    "}",
    "",
    "Write-Host '=== Переключение на production ===' -ForegroundColor Cyan",
    "Write-Host ('  Домен: ' + `$Domain) -ForegroundColor Cyan",
    "Write-Host ('  Email: ' + `$Email) -ForegroundColor Cyan",
    "Write-Host ''",
    "",
    "# 1. Обновить .env",
    "`$envFile = '.env'",
    "if (Test-Path `$envFile) {",
    "    `$content = Get-Content `$envFile -Raw",
    "    `$content = `$content -replace '^GRIST_DOMAIN=.*', ('GRIST_DOMAIN=' + `$Domain)",
    "    `$content = `$content -replace '^GRIST_PROTO=.*', 'GRIST_PROTO=https'",
    "    `$content = `$content -replace '^LETSENCRYPT_EMAIL=.*', ('LETSENCRYPT_EMAIL=' + `$Email)",
    "    Set-Content -Path `$envFile -Value `$content -Encoding UTF8",
    "    Write-Host '[✓] .env обновлен' -ForegroundColor Green",
    "}",
    "",
    "# 2. Nginx конфиг с HTTPS",
    "`$nginxConfig = @`"",
    "upstream grist_backend {`n    server grist:8484;`n}`n",
    "upstream keycloak_backend {`n    server keycloak:8080;`n}`n",
    "server {`n    listen 80;`n    server_name `$Domain;`n",
    "    location /.well-known/acme-challenge/ {`n        root /var/www/certbot;`n    }",
    "    location / {`n        return 301 https://`\\`$host`\\`$request_uri;`n    }`n}`n",
    "server {`n    listen 443 ssl http2;`n    server_name `$Domain;`n",
    "    ssl_certificate /etc/letsencrypt/live/`$Domain/fullchain.pem;`n",
    "    ssl_certificate_key /etc/letsencrypt/live/`$Domain/privkey.pem;`n",
    "    ssl_protocols TLSv1.2 TLSv1.3;`n    ssl_ciphers HIGH:!aNULL:!MD5;`n    ssl_prefer_server_ciphers on;`n",
    "    location /keycloak/ {`n        proxy_pass http://keycloak_backend;`n",
    "        proxy_set_header Host `\\`$host;`n        proxy_set_header X-Real-IP `\\`$remote_addr;`n",
    "        proxy_set_header X-Forwarded-For `\\`$proxy_add_x_forwarded_for;`n        proxy_set_header X-Forwarded-Proto https;`n",
    "        proxy_set_header X-Forwarded-Host `\\`$host;`n",
    "        proxy_buffer_size 128k;`n        proxy_buffers 4 256k;`n        proxy_busy_buffers_size 256k;`n    }`n",
    "    location / {`n        proxy_pass http://grist_backend;`n        proxy_set_header Host `\\`$host;`n",
    "        proxy_set_header X-Real-IP `\\`$remote_addr;`n        proxy_set_header X-Forwarded-For `\\`$proxy_add_x_forwarded_for;`n",
    "        proxy_set_header X-Forwarded-Proto https;`n        proxy_http_version 1.1;`n",
    "        proxy_set_header Upgrade `\\`$http_upgrade;`n        proxy_set_header Connection `"upgrade`";`n",
    "        proxy_read_timeout 86400s;`n        proxy_send_timeout 86400s;`n    }`n}`n`"@",
    "",
    "Set-Content -Path 'nginx/conf.d/grist.conf' -Value `$nginxConfig -Encoding UTF8",
    "Write-Host '[✓] nginx/conf.d/grist.conf обновлен для HTTPS' -ForegroundColor Green",
    "",
    "Write-Host ''",
    "Write-Host '=== Готово! Следующие шаги: ===' -ForegroundColor Cyan",
    "Write-Host '1. Раскомментируйте certbot в docker-compose.yml' -ForegroundColor Yellow",
    "Write-Host ''",
    "Write-Host '2. Получите SSL сертификат:' -ForegroundColor Yellow",
    "Write-Host '   docker compose down' -ForegroundColor White",
    "Write-Host '   docker compose up -d nginx' -ForegroundColor White",
    "Write-Host ('   docker compose run --rm certbot certonly --webroot -w /var/www/certbot -d ' + `$Domain + ' --email ' + `$Email + ' --agree-tos --no-eff-email') -ForegroundColor White",
    "Write-Host ''",
    "Write-Host '3. Перезапустите все сервисы:' -ForegroundColor Yellow",
    "Write-Host '   docker compose down && docker compose up -d' -ForegroundColor White",
    "Write-Host ''",
    "Write-Host '4. Для автопродления - добавьте в Windows Task Scheduler:' -ForegroundColor Yellow",
    "Write-Host '   PowerShell: cd $(Get-Location) && docker compose run --rm certbot renew' -ForegroundColor White"
)

$switch_prod_script = $switch_prod_lines -join "`n"
Set-Content -Path "switch-to-production.ps1" -Value $switch_prod_script -Encoding UTF8
Write-Host "[✓] switch-to-production.ps1" -ForegroundColor Green

# ====================== Build custom Grist image ======================
Write-Host ""
Write-Host "[...] Building grist-custom:latest from $GRIST_CORE_DIR ..." -ForegroundColor Yellow
docker build -t grist-custom:latest "$GRIST_CORE_DIR"
if ($LASTEXITCODE -ne 0) {
    Write-Host "[X] Docker build failed!" -ForegroundColor Red
    exit 1
}
Write-Host "[✓] grist-custom:latest built" -ForegroundColor Green

# ====================== Start the stack ======================
Write-Host ""
Write-Host "[...] Starting docker compose ..." -ForegroundColor Yellow
Set-Location $INSTALL_DIR
docker compose up -d
if ($LASTEXITCODE -ne 0) {
    Write-Host "[X] docker compose up failed!" -ForegroundColor Red
    exit 1
}
Write-Host "[✓] docker compose up -d" -ForegroundColor Green

# ====================== Вывод ======================
$info_message = @"

========================================================================
  ✅  ВСЁ ГОТОВО
========================================================================

  📁  $INSTALL_DIR\
  ├── .env
  ├── docker-compose.yml
  ├── init-db.sh
  ├── keycloak-realm-import.json
  ├── switch-to-production.ps1
  ├── nginx\conf.d\grist.conf
  └── data\{grist,postgres}\

========================================================================
  🚀  ЗАПУСК
========================================================================

  cd $INSTALL_DIR
  docker compose up -d

  Подождите 30-60 секунд (Keycloak инициализируется).

========================================================================
  🔗  АДРЕСА
========================================================================

  Grist:          http://grist.localhost
  Keycloak Admin: http://grist.localhost/keycloak/admin
                  Логин: $KEYCLOAK_ADMIN / $KEYCLOAK_ADMIN_PASSWORD
  Grist Boot:     http://grist.localhost/admin?boot-key=$GRIST_BOOT_KEY

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
  5. Пользователь "$GRIST_ADMIN_EMAIL" = админ Grist

========================================================================
  🌐  PRODUCTION
========================================================================

  .\switch-to-production.ps1 grist.example.com admin@example.com

========================================================================
"@

Write-Host $info_message -ForegroundColor Cyan
