#!/usr/bin/env bash
# Общие помощники для сторожа и управления резервным сервером Hetzner Cloud.
# Подключается через `source scripts/lib.sh`. Требует curl и jq (есть на ubuntu-latest).

HCLOUD_API="https://api.hetzner.cloud/v1"

# Имя/метка резервного сервера. Присутствие такого сервера в проекте Hetzner И ЕСТЬ
# состояние failover — отдельного хранилища состояния не заводим.
SERVER_NAME="${SERVER_NAME:-autopost-failover}"
SERVER_LABEL="role=autopost-failover"

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%SZ')] $*"; }

die() { echo "::error::$*"; exit 2; }

summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "$1" >>"$GITHUB_STEP_SUMMARY"
  log "$1"
}

emit() {  # emit key=value в GITHUB_OUTPUT (для следующих шагов workflow)
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1" >>"$GITHUB_OUTPUT"
  return 0
}

notify() {
  local text="$1"
  [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ] || return 0
  curl -fsS --max-time 15 \
    "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    --data-urlencode chat_id="${TG_CHAT_ID}" \
    --data-urlencode text="$text" >/dev/null 2>&1 || true
}

# hc <METHOD> <PATH> [BODY] — запрос к Hetzner Cloud API. Печатает тело ответа.
# Ненулевой код возврата при HTTP >= 400 (тело всё равно печатается — там причина).
hc() {
  local method="$1" path="$2" body="${3:-}"
  local out code
  if [ -n "$body" ]; then
    out=$(curl -sS --max-time 60 -w '\n%{http_code}' -X "$method" \
      -H "Authorization: Bearer ${HCLOUD_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$body" "${HCLOUD_API}${path}")
  else
    out=$(curl -sS --max-time 60 -w '\n%{http_code}' -X "$method" \
      -H "Authorization: Bearer ${HCLOUD_TOKEN}" \
      "${HCLOUD_API}${path}")
  fi
  code="${out##*$'\n'}"
  printf '%s' "${out%$'\n'*}"
  [ "$code" -lt 400 ] 2>/dev/null || return 1
}

# Найти резервный сервер по метке. Печатает JSON сервера или пустую строку.
find_failover_server() {
  hc GET "/servers?label_selector=$(printf '%s' "$SERVER_LABEL" | sed 's/=/%3D/')" \
    | jq -c '.servers[0] // empty'
}

server_ip() { jq -r '.public_net.ipv4.ip // empty'; }
