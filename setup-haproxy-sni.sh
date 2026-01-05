#!/bin/sh
set -eu

ROUTES_FILE="${1:-/etc/haproxy/routes.txt}"
HAPROXY_CFG="/etc/haproxy/haproxy.cfg"
HAPROXY_BAK="/etc/haproxy/haproxy.cfg.bak.$(date +%Y%m%d%H%M%S)"
TZ_NAME="${TZ_NAME:-Europe/Vilnius}"

need_root() {
  [ "$(id -u)" -eq 0 ] || { echo "ERROR: Запустите от root" >&2; exit 1; }
}

install_packages() {
  echo "[1/7] Установка пакетов..."
  apk update
  apk add --no-cache haproxy ca-certificates tzdata busybox-extras
}

set_timezone() {
  echo "[2/7] Настройка timezone: $TZ_NAME"
  if [ -f "/usr/share/zoneinfo/$TZ_NAME" ]; then
    cp "/usr/share/zoneinfo/$TZ_NAME" /etc/localtime
    echo "$TZ_NAME" > /etc/timezone
  fi
}

validate_routes_file() {
  echo "[3/7] Проверка файла маршрутов: $ROUTES_FILE"
  [ -f "$ROUTES_FILE" ] || { echo "ERROR: Файл не найден: $ROUTES_FILE" >&2; exit 1; }

  bad=0
  lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno+1))
    l="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$l" ] && continue
    echo "$l" | grep -q '^[#]' && continue

    # shellcheck disable=SC2086
    set -- $l
    if [ "$#" -ne 5 ]; then
      echo "ERROR: $ROUTES_FILE:$lineno: ожидаю 5 полей: <proto> <listen_port> <host> <backend_ip> <backend_port>" >&2
      bad=1
      continue
    fi

    proto="$1"; listen_port="$2"; host="$3"; backend_ip="$4"; backend_port="$5"

    echo "$proto" | grep -Eq '^(tls|http)$' || { echo "ERROR: $ROUTES_FILE:$lineno: proto должен быть tls или http" >&2; bad=1; }
    echo "$listen_port" | grep -Eq '^[0-9]+$' || { echo "ERROR: $ROUTES_FILE:$lineno: listen_port не число" >&2; bad=1; }
    echo "$backend_port" | grep -Eq '^[0-9]+$' || { echo "ERROR: $ROUTES_FILE:$lineno: backend_port не число" >&2; bad=1; }

    echo "$host" | grep -Eq '^[A-Za-z0-9._-]+$' || { echo "ERROR: $ROUTES_FILE:$lineno: странный host: $host" >&2; bad=1; }
    [ -n "$backend_ip" ] || { echo "ERROR: $ROUTES_FILE:$lineno: backend_ip пуст" >&2; bad=1; }
  done < "$ROUTES_FILE"

  [ "$bad" -eq 0 ] || exit 1
}

generate_haproxy_cfg() {
  echo "[4/7] Генерация $HAPROXY_CFG..."

  if [ -f "$HAPROXY_CFG" ]; then
    cp "$HAPROXY_CFG" "$HAPROXY_BAK"
    echo "  backup: $HAPROXY_BAK"
  fi

  mkdir -p /etc/haproxy

  {
    echo "global"
    echo "  log stdout format raw local0"
    echo "  maxconn 4096"
    echo ""
    echo "defaults"
    echo "  log global"
    echo "  timeout connect 5s"
    echo "  timeout client  2m"
    echo "  timeout server  2m"
    echo ""

    # ---------- TLS (SNI passthrough) ----------
    tls_ports="$(awk '
      /^[[:space:]]*#/ {next}
      NF==0 {next}
      $1=="tls" {print $2}
    ' "$ROUTES_FILE" | sort -n | uniq)"

    for p in $tls_ports; do
      echo "frontend ft_tls_${p}"
      echo "  bind :$p"
      echo "  mode tcp"
      echo "  option tcplog"
      echo "  tcp-request inspect-delay 5s"
      echo "  tcp-request content accept if { req_ssl_hello_type 1 }"
      echo ""

      idx=0
      awk -v port="$p" '
        /^[[:space:]]*#/ {next}
        NF==0 {next}
        $1=="tls" && $2==port {print $0}
      ' "$ROUTES_FILE" | while IFS= read -r row; do
        # shellcheck disable=SC2086
        set -- $row
        proto="$1"; listen_port="$2"; sni="$3"; backend_ip="$4"; backend_port="$5"
        idx=$((idx+1))
        bk="bk_tls_${listen_port}_${idx}"
        echo "  use_backend $bk if { req_ssl_sni -i $sni }"
      done

      echo ""
      echo "  default_backend bk_tls_${p}_default"
      echo ""

      idx=0
      awk -v port="$p" '
        /^[[:space:]]*#/ {next}
        NF==0 {next}
        $1=="tls" && $2==port {print $0}
      ' "$ROUTES_FILE" | while IFS= read -r row; do
        # shellcheck disable=SC2086
        set -- $row
        proto="$1"; listen_port="$2"; sni="$3"; backend_ip="$4"; backend_port="$5"
        idx=$((idx+1))
        bk="bk_tls_${listen_port}_${idx}"
        echo "backend $bk"
        echo "  mode tcp"
        echo "  option tcp-check"
        echo "  server s1 ${backend_ip}:${backend_port} check"
        echo ""
      done

      echo "backend bk_tls_${p}_default"
      echo "  mode tcp"
      echo "  # blackhole для неизвестного SNI: чтобы случайно не проксировать на первый сервис"
      echo "  server s1 127.0.0.1:1 check"
      echo ""
    done

    # ---------- HTTP (Host routing) ----------
    http_ports="$(awk '
      /^[[:space:]]*#/ {next}
      NF==0 {next}
      $1=="http" {print $2}
    ' "$ROUTES_FILE" | sort -n | uniq)"

    for p in $http_ports; do
      echo "frontend ft_http_${p}"
      echo "  bind :$p"
      echo "  mode http"
      echo "  option httplog"
      echo "  option forwardfor"
      echo ""

      # ACL + use_backend
      idx=0
      awk -v port="$p" '
        /^[[:space:]]*#/ {next}
        NF==0 {next}
        $1=="http" && $2==port {print $0}
      ' "$ROUTES_FILE" | while IFS= read -r row; do
        # shellcheck disable=SC2086
        set -- $row
        proto="$1"; listen_port="$2"; host="$3"; backend_ip="$4"; backend_port="$5"
        idx=$((idx+1))
        bk="bk_http_${listen_port}_${idx}"
        acl="host_${listen_port}_${idx}"
        # hdr(host) может содержать :port; матчим и host, и host:port
        echo "  acl $acl hdr(host) -i $host ${host}:${listen_port}"
        echo "  use_backend $bk if $acl"
      done

      echo ""
      echo "  default_backend bk_http_${p}_default"
      echo ""

      # Backends
      idx=0
      awk -v port="$p" '
        /^[[:space:]]*#/ {next}
        NF==0 {next}
        $1=="http" && $2==port {print $0}
      ' "$ROUTES_FILE" | while IFS= read -r row; do
        # shellcheck disable=SC2086
        set -- $row
        proto="$1"; listen_port="$2"; host="$3"; backend_ip="$4"; backend_port="$5"
        idx=$((idx+1))
        bk="bk_http_${listen_port}_${idx}"
        echo "backend $bk"
        echo "  mode http"
        echo "  server s1 ${backend_ip}:${backend_port} check"
        echo ""
      done

      echo "backend bk_http_${p}_default"
      echo "  mode http"
      echo "  # blackhole для неизвестного Host: чтобы случайно не проксировать на первый сервис"
      echo "  server s1 127.0.0.1:1 check"
      echo ""
    done
  } > "$HAPROXY_CFG"
}

validate_haproxy_cfg() {
  echo "[5/7] Валидация конфига..."
  haproxy -c -f "$HAPROXY_CFG"
}

enable_and_start() {
  echo "[6/7] Запуск HAProxy..."
  rc-update add haproxy default >/dev/null 2>&1 || true
  rc-service haproxy restart
}

post_check() {
  echo "[7/7] Готово. Слушающие порты:"
  if command -v ss >/dev/null 2>&1; then
    ss -lntp | grep haproxy || true
  else
    netstat -lntp | grep haproxy || true
  fi

  echo ""
  echo "Примеры теста:"
  echo "  HTTP: curl -v http://<IP_CT>/ -H 'Host: api.example.com'"
  echo "  TLS : openssl s_client -connect <IP_CT>:443 -servername git.example.com -brief"
}

need_root
install_packages
set_timezone
validate_routes_file
generate_haproxy_cfg
validate_haproxy_cfg
enable_and_start
post_check
