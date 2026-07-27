#!/usr/bin/env bash
# Сторож домашнего сервера autopost.
#
# Проверяет живость домашнего сервера (эндпоинт /health) и определяет состояние
# HOME_UP / HOME_DOWN. Падение подтверждается несколькими попытками с паузой
# (по умолчанию 3 попытки с интервалом 10 минут) — одиночный сетевой сбой не
# считается отключением дома.
#
# По состоянию home_state следующие шаги workflow поднимают резервный сервер
# на DigitalOcean (provision.sh) или возвращают работу домой (teardown.sh).
#
# Переменные окружения:
#   HOME_HEALTH_URL   — URL проверки, напр. http://myhome.duckdns.org:8778/health (обязателен)
#   RETRIES           — число ДОПОЛНИТЕЛЬНЫХ попыток после первого провала (по умолч. 3)
#   RETRY_INTERVAL    — пауза между попытками в секундах (по умолч. 600 = 10 мин)
#   CURL_TIMEOUT      — таймаут одного запроса, сек (по умолч. 15)
#   TG_BOT_TOKEN, TG_CHAT_ID — опционально: уведомление в Telegram при отключении
#   GITHUB_OUTPUT, GITHUB_STEP_SUMMARY — заполняются в GitHub Actions (иначе игнор)

set -uo pipefail

URL="${HOME_HEALTH_URL:-}"
RETRIES="${RETRIES:-3}"
RETRY_INTERVAL="${RETRY_INTERVAL:-600}"
CURL_TIMEOUT="${CURL_TIMEOUT:-15}"

if [ -z "$URL" ]; then
  echo "::error::HOME_HEALTH_URL не задан (добавьте секрет репозитория)"
  exit 2
fi

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%SZ')] $*"; }

# Один запрос: успех = HTTP 200. /health отвечает 200 только если жив и процесс, и БД.
check_home() {
  curl -fsS --max-time "$CURL_TIMEOUT" -o /dev/null "$URL"
}

notify() {
  local text="$1"
  [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ] || return 0
  curl -fsS --max-time 15 \
    "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    --data-urlencode chat_id="${TG_CHAT_ID}" \
    --data-urlencode text="$text" >/dev/null 2>&1 || true
}

summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "$1" >>"$GITHUB_STEP_SUMMARY"
  log "$1"
}

emit() {  # emit key=value в GITHUB_OUTPUT (для следующих шагов workflow)
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1" >>"$GITHUB_OUTPUT"
}

log "Проверка домашнего сервера: $URL"
state="HOME_DOWN"
if check_home; then
  state="HOME_UP"
else
  log "Первая проверка не прошла — подтверждаю отключение (${RETRIES} x ${RETRY_INTERVAL}s)"
  for i in $(seq 1 "$RETRIES"); do
    log "Пауза ${RETRY_INTERVAL}s перед попыткой ${i}/${RETRIES}"
    sleep "$RETRY_INTERVAL"
    if check_home; then
      log "Попытка ${i}/${RETRIES}: сервер снова отвечает"
      state="HOME_UP"
      break
    fi
    log "Попытка ${i}/${RETRIES}: по-прежнему не отвечает"
  done
fi

emit "home_state=$state"
if [ "$state" = "HOME_UP" ]; then
  summary "✅ Домашний сервер отвечает — резерв не нужен."
else
  summary "🔴 Домашний сервер НЕ отвечает (подтверждено ${RETRIES} доп. попытками по ${RETRY_INTERVAL}s)."
  notify "🔴 autopost: домашний сервер недоступен (проверено ${RETRIES}×$((RETRY_INTERVAL/60))мин). Поднимаю резерв на DigitalOcean."
fi

# Ненулевой код НЕ возвращаем даже при HOME_DOWN — это штатная развилка, а не сбой
# самого сторожа; решение принимают следующие шаги по значению home_state.
exit 0
