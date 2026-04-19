#!/usr/bin/env bash
set -Eeuo pipefail

log() { echo "[$(date '+%F %T')] $*"; }
err() { echo "[$(date '+%F %T')] ERROR: $*" >&2; }

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "Please run as root (use sudo -E)."
    exit 1
  fi
}

trim_slashes() {
  local v="$1"
  v="/${v#/}"
  v="${v%/}"
  [[ "$v" == "/" ]] && v=""
  printf '%s' "$v"
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    err "Missing required environment variable: $name"
    exit 1
  fi
}

os_detect() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
  else
    OS_ID="unknown"
    OS_LIKE=""
  fi
}

install_packages_apt() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y "$@"
}

install_packages_yum() {
  yum install -y "$@"
}

install_packages_dnf() {
  dnf install -y "$@"
}

install_nginx() {
  if command -v nginx >/dev/null 2>&1; then
    log "nginx already installed"
    return
  fi
  os_detect
  log "Installing nginx..."
  case "$OS_ID" in
    ubuntu|debian)
      install_packages_apt nginx curl
      ;;
    centos|rhel|rocky|almalinux|amzn)
      if command -v dnf >/dev/null 2>&1; then
        install_packages_dnf nginx curl
      else
        install_packages_yum nginx curl
      fi
      ;;
    fedora)
      install_packages_dnf nginx curl
      ;;
    *)
      err "Unsupported OS for automatic nginx install: $OS_ID"
      exit 1
      ;;
  esac
}

install_certbot() {
  if command -v certbot >/dev/null 2>&1; then
    log "certbot already installed"
    return
  fi

  os_detect
  log "Installing certbot..."

  case "$OS_ID" in
    ubuntu|debian)
      if apt-cache show certbot >/dev/null 2>&1 && apt-cache show python3-certbot-nginx >/dev/null 2>&1; then
        install_packages_apt certbot python3-certbot-nginx
      else
        install_certbot_venv
      fi
      ;;
    centos|rhel|rocky|almalinux|amzn)
      if command -v dnf >/dev/null 2>&1; then
        if dnf info certbot >/dev/null 2>&1 && dnf info python3-certbot-nginx >/dev/null 2>&1; then
          install_packages_dnf certbot python3-certbot-nginx
        else
          install_certbot_venv
        fi
      else
        if yum info certbot >/dev/null 2>&1 && yum info python3-certbot-nginx >/dev/null 2>&1; then
          install_packages_yum certbot python3-certbot-nginx
        else
          install_certbot_venv
        fi
      fi
      ;;
    fedora)
      if dnf info certbot >/dev/null 2>&1 && dnf info python3-certbot-nginx >/dev/null 2>&1; then
        install_packages_dnf certbot python3-certbot-nginx
      else
        install_certbot_venv
      fi
      ;;
    *)
      install_certbot_venv
      ;;
  esac
}

install_certbot_venv() {
  log "Installing certbot via Python venv fallback..."
  os_detect
  case "$OS_ID" in
    ubuntu|debian)
      install_packages_apt python3 python3-venv python3-pip gcc libssl-dev libffi-dev python3-dev
      ;;
    centos|rhel|rocky|almalinux|amzn)
      if command -v dnf >/dev/null 2>&1; then
        install_packages_dnf python3 python3-pip gcc openssl-devel libffi-devel python3-devel
      else
        install_packages_yum python3 python3-pip gcc openssl-devel libffi-devel python3-devel
      fi
      ;;
    fedora)
      install_packages_dnf python3 python3-pip gcc openssl-devel libffi-devel python3-devel
      ;;
    *)
      err "Unsupported OS for automatic certbot install fallback: $OS_ID"
      exit 1
      ;;
  esac
  python3 -m venv /opt/certbot
  /opt/certbot/bin/pip install --upgrade pip
  /opt/certbot/bin/pip install certbot certbot-nginx
  ln -sf /opt/certbot/bin/certbot /usr/local/bin/certbot
}

write_http_only_conf() {
  local conf="$1"
  cat > "$conf" <<CONF
server {
    listen ${NGINX_LISTEN_PORT};
    listen [::]:${NGINX_LISTEN_PORT};
    server_name ${NGINX_SERVER_NAME};

    client_max_body_size ${NGINX_CLIENT_MAX_BODY_SIZE};

    location ^~ /.well-known/acme-challenge/ {
        root ${CERTBOT_WEBROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location = /healthz {
        add_header Content-Type text/plain;
        return 200 'ok';
    }

    location ${USER_REPORT_PREFIX}/ {
        proxy_pass http://${USER_REPORT_UPSTREAM}/;
        include /etc/nginx/proxy_params;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_read_timeout 60s;
    }

    location = ${USER_REPORT_PREFIX} {
        return 301 ${USER_REPORT_PREFIX}/;
    }

    location ${NODE_REPORT_PREFIX}/ {
        proxy_pass http://${NODE_REPORT_UPSTREAM}/;
        include /etc/nginx/proxy_params;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_read_timeout 60s;
    }

    location = ${NODE_REPORT_PREFIX} {
        return 301 ${NODE_REPORT_PREFIX}/;
    }

    location ${DISPATCH_PREFIX}/ {
        proxy_pass http://${DISPATCH_UPSTREAM}/;
        include /etc/nginx/proxy_params;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_read_timeout 60s;
    }

    location = ${DISPATCH_PREFIX} {
        return 301 ${DISPATCH_PREFIX}/;
    }

    location / {
        return 404;
    }
}
CONF
}

write_https_conf() {
  local conf="$1"
  cat > "$conf" <<CONF
server {
    listen ${NGINX_LISTEN_PORT};
    listen [::]:${NGINX_LISTEN_PORT};
    server_name ${NGINX_SERVER_NAME};

    location ^~ /.well-known/acme-challenge/ {
        root ${CERTBOT_WEBROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location = /healthz {
        add_header Content-Type text/plain;
        return 200 'ok';
    }

    return 301 https://\$host:${NGINX_HTTPS_PORT}\$request_uri;
}

server {
    listen ${NGINX_HTTPS_PORT} ssl http2;
    listen [::]:${NGINX_HTTPS_PORT} ssl http2;
    server_name ${NGINX_SERVER_NAME};

    ssl_certificate ${SSL_CERT_PATH};
    ssl_certificate_key ${SSL_CERT_KEY_PATH};
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    client_max_body_size ${NGINX_CLIENT_MAX_BODY_SIZE};

    location = /healthz {
        add_header Content-Type text/plain;
        return 200 'ok';
    }

    location ${USER_REPORT_PREFIX}/ {
        proxy_pass http://${USER_REPORT_UPSTREAM}/;
        include /etc/nginx/proxy_params;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_read_timeout 60s;
    }

    location = ${USER_REPORT_PREFIX} {
        return 301 ${USER_REPORT_PREFIX}/;
    }

    location ${NODE_REPORT_PREFIX}/ {
        proxy_pass http://${NODE_REPORT_UPSTREAM}/;
        include /etc/nginx/proxy_params;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_read_timeout 60s;
    }

    location = ${NODE_REPORT_PREFIX} {
        return 301 ${NODE_REPORT_PREFIX}/;
    }

    location ${DISPATCH_PREFIX}/ {
        proxy_pass http://${DISPATCH_UPSTREAM}/;
        include /etc/nginx/proxy_params;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_read_timeout 60s;
    }

    location = ${DISPATCH_PREFIX} {
        return 301 ${DISPATCH_PREFIX}/;
    }

    location / {
        return 404;
    }
}
CONF
}

ensure_dirs() {
  mkdir -p "$CERTBOT_WEBROOT/.well-known/acme-challenge"
  mkdir -p /etc/nginx/conf.d
}

nginx_test() {
  nginx -t
}

nginx_enable_and_reload() {
  systemctl enable nginx >/dev/null 2>&1 || true
  if systemctl is-active --quiet nginx; then
    systemctl reload nginx
  else
    systemctl restart nginx
  fi
}

obtain_certbot_cert() {
  require_env CERTBOT_EMAIL
  require_env CERTBOT_DOMAINS

  install_certbot

  local first_domain
  first_domain="${CERTBOT_DOMAINS%%,*}"
  first_domain="${first_domain// /}"
  SSL_CERT_PATH="/etc/letsencrypt/live/${first_domain}/fullchain.pem"
  SSL_CERT_KEY_PATH="/etc/letsencrypt/live/${first_domain}/privkey.pem"

  IFS=',' read -r -a doms <<< "$CERTBOT_DOMAINS"
  local domain_args=()
  for d in "${doms[@]}"; do
    d="${d// /}"
    [[ -n "$d" ]] && domain_args+=( -d "$d" )
  done

  if [[ ${#domain_args[@]} -eq 0 ]]; then
    err "CERTBOT_DOMAINS is empty after parsing"
    exit 1
  fi

  log "Requesting certificate for domains: ${CERTBOT_DOMAINS}"
  certbot certonly --nginx \
    --non-interactive \
    --agree-tos \
    --email "$CERTBOT_EMAIL" \
    --keep-until-expiring \
    --expand \
    "${domain_args[@]}"

  if [[ ! -f "$SSL_CERT_PATH" || ! -f "$SSL_CERT_KEY_PATH" ]]; then
    err "Certificate files not found after certbot run: $SSL_CERT_PATH / $SSL_CERT_KEY_PATH"
    exit 1
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable certbot.timer >/dev/null 2>&1 || true
    systemctl start certbot.timer >/dev/null 2>&1 || true
  fi
}

main() {
  require_root

  require_env USER_REPORT_UPSTREAM
  require_env NODE_REPORT_UPSTREAM
  require_env DISPATCH_UPSTREAM

  : "${NGINX_LISTEN_PORT:=80}"
  : "${NGINX_HTTPS_PORT:=443}"
  : "${NGINX_SERVER_NAME:=_}"
  : "${NGINX_CLIENT_MAX_BODY_SIZE:=20m}"
  : "${USER_REPORT_PREFIX:=/user}"
  : "${NODE_REPORT_PREFIX:=/node}"
  : "${DISPATCH_PREFIX:=/dispatch}"
  : "${ENABLE_HTTPS:=false}"
  : "${HTTP_TO_HTTPS_REDIRECT:=true}"
  : "${ENABLE_CERTBOT:=false}"
  : "${CERTBOT_WEBROOT:=/var/www/certbot}"

  USER_REPORT_PREFIX="$(trim_slashes "$USER_REPORT_PREFIX")"
  NODE_REPORT_PREFIX="$(trim_slashes "$NODE_REPORT_PREFIX")"
  DISPATCH_PREFIX="$(trim_slashes "$DISPATCH_PREFIX")"

  install_nginx
  ensure_dirs

  local conf="/etc/nginx/conf.d/nxpanel-services.conf"

  # Step 1: write HTTP config so domain is reachable on port 80 for ACME challenge.
  write_http_only_conf "$conf"
  nginx_test
  nginx_enable_and_reload

  if [[ "$ENABLE_HTTPS" == "true" ]]; then
    if [[ "$ENABLE_CERTBOT" == "true" ]]; then
      obtain_certbot_cert
    else
      require_env SSL_CERT_PATH
      require_env SSL_CERT_KEY_PATH
    fi

    write_https_conf "$conf"
    nginx_test
    nginx_enable_and_reload
  fi

  log "Done."
  log "HTTP:  http://${NGINX_SERVER_NAME}:${NGINX_LISTEN_PORT}"
  if [[ "$ENABLE_HTTPS" == "true" ]]; then
    log "HTTPS: https://${NGINX_SERVER_NAME}:${NGINX_HTTPS_PORT}"
    log "Certificate: ${SSL_CERT_PATH}"
  fi
}

main "$@"
