#!/usr/bin/env bash
# Общие помощники для сторожа и управления резервным сервером DigitalOcean.
# Подключается через `source scripts/lib.sh`. Требует curl и jq (есть на ubuntu-latest).

DO_API="https://api.digitalocean.com/v2"

# Имя и ТЕГ резервного дроплета. Наличие дроплета с этим тегом И ЕСТЬ состояние
# failover — отдельного хранилища состояния не заводим.
SERVER_NAME="${SERVER_NAME:-autopost-failover}"
SERVER_TAG="autopost-failover"

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

# do_api <METHOD> <PATH> [BODY] — запрос к DigitalOcean API. Печатает тело ответа.
# Ненулевой код возврата при HTTP >= 400 (тело всё равно печатается — там причина).
# DELETE у DO отвечает 204 с пустым телом — это успех.
do_api() {
  local method="$1" path="$2" body="${3:-}"
  local out code
  if [ -n "$body" ]; then
    out=$(curl -sS --max-time 60 -w '\n%{http_code}' -X "$method" \
      -H "Authorization: Bearer ${DO_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$body" "${DO_API}${path}")
  else
    out=$(curl -sS --max-time 60 -w '\n%{http_code}' -X "$method" \
      -H "Authorization: Bearer ${DO_TOKEN}" \
      "${DO_API}${path}")
  fi
  code="${out##*$'\n'}"
  printf '%s' "${out%$'\n'*}"
  [ "$code" -lt 400 ] 2>/dev/null || return 1
}

# Найти резервный дроплет по тегу. Печатает JSON дроплета или пустую строку.
find_failover_server() {
  do_api GET "/droplets?tag_name=${SERVER_TAG}&per_page=50" \
    | jq -c '.droplets[0] // empty'
}

# Публичный IPv4 дроплета из его JSON.
server_ip() {
  jq -r '[.networks.v4[]? | select(.type=="public") | .ip_address][0] // empty'
}
