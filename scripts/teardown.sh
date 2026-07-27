#!/usr/bin/env bash
# Этап 5: вернуться на домашний сервер и погасить резерв на Hetzner.
#
# Вызывается сторожем, когда дом снова отвечает (HOME_UP), а резервный сервер
# ещё жив. Порядок важен — сначала спасаем данные, потом удаляем:
#
#   1) на РЕЗЕРВЕ форсим снимок БД в бэкап-репозиторий (POST /api/db-backup);
#   2) убеждаемся, что снимок реально лёг в репозиторий (свежий коммит файла);
#   3) просим ДОМ принять этот снимок (POST /api/db-restore?confirm=true) —
#      дом кладёт его «ожидающим» и перезапускается, подставляя базу на старте;
#   4) ждём, пока дом снова ответит /health;
#   5) только теперь удаляем сервер Hetzner.
#
# Любой сбой на шагах 1–4 ОСТАВЛЯЕТ резерв жить: лучше платить €0,0075/час, чем
# потерять посты, сделанные на резерве. Исключение — резерв, который сам не
# отвечает /health (значит, он и не постил): такой удаляем, дом остаётся главным.
#
# Переменные окружения:
#   HCLOUD_TOKEN     — токен Hetzner Cloud (Read & Write). ОБЯЗАТЕЛЕН.
#   HOME_HEALTH_URL  — тот же секрет, что у сторожа: http://дом:8778/health
#   API_KEY          — ключ HTTP API (одинаковый у дома и резерва)
#   BACKUP_REPO, BACKUP_TOKEN, BACKUP_BRANCH — для проверки свежести снимка
#   PORT             — порт резерва (по умолч. 8778)
#   SKIP_HOME_RESTORE=1 — не трогать дом (только бэкап + удаление резерва)
#   KEEP_SERVER=1    — всё проверить, но сервер не удалять (тест)
#   TG_BOT_TOKEN, TG_CHAT_ID — уведомления

set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh

PORT="${PORT:-8778}"
BACKUP_BRANCH="${BACKUP_BRANCH:-main}"
DB_FILE="autopost-db.sqlite.gz"
FRESH_MINUTES="${FRESH_MINUTES:-30}"   # насколько свежим считаем снимок в репо

[ -n "${HCLOUD_TOKEN:-}" ] || die "HCLOUD_TOKEN не задан (секрет репозитория)"
command -v jq >/dev/null || die "нужен jq"

# ── 0. Есть ли что гасить ─────────────────────────────────────────────────
existing=$(find_failover_server) || die "Hetzner API недоступен (проверьте HCLOUD_TOKEN)"
if [ -z "$existing" ]; then
  log "Резервного сервера нет — гасить нечего."
  emit "torn_down=false"
  exit 0
fi
ip=$(printf '%s' "$existing" | server_ip)
sid=$(printf '%s' "$existing" | jq -r '.id')
log "Резерв найден: ${SERVER_NAME} id=${sid}, ${ip}. Дом ожил — возвращаемся."

api_post() {  # api_post <base-url> <путь с параметрами> → тело ответа, код в $?
  curl -fsS --max-time 120 -X POST \
    -H "Authorization: Bearer ${API_KEY:-}" \
    -H "Content-Length: 0" \
    "${1}${2}"
}

# ── 1. Жив ли резерв вообще ───────────────────────────────────────────────
backup_base="http://${ip}:${PORT}"
alive=0
for _ in 1 2 3; do
  if curl -fsS --max-time 15 -o /dev/null "${backup_base}/health"; then alive=1; break; fi
  sleep 10
done

if [ "$alive" != "1" ]; then
  summary "⚠️ Резерв ${ip} не отвечает /health — постить он не мог, спасать нечего. Удаляю."
  if [ "${KEEP_SERVER:-0}" = "1" ]; then
    log "KEEP_SERVER=1 — оставляю сервер."; emit "torn_down=false"; exit 0
  fi
  hc DELETE "/servers/${sid}" >/dev/null || die "не удалось удалить сервер ${sid}"
  notify "🧹 autopost: дом вернулся. Нерабочий резерв ${ip} удалён (он не отвечал /health)."
  emit "torn_down=true"
  exit 0
fi

# ── 2. Финальный снимок БД с резерва ──────────────────────────────────────
[ -n "${API_KEY:-}" ] || {
  notify "🔴 autopost: дом вернулся, но API_KEY не задан — не могу забрать БД с резерва ${ip}. Сервер оставлен."
  die "API_KEY не задан: без него нельзя снять финальный бэкап с резерва (сервер НЕ удалён)"
}
log "Форсирую снимок БД на резерве…"
ok=0
for attempt in 1 2 3; do
  resp=$(api_post "$backup_base" "/api/db-backup?force=true") && \
    [ "$(jq -r '.ok // false' <<<"$resp" 2>/dev/null)" = "true" ] && { ok=1; break; }
  log "Попытка ${attempt}: снимок не удался (${resp:-нет ответа})"
  sleep 20
done
if [ "$ok" != "1" ]; then
  summary "🔴 Резерв ${ip} не смог положить снимок БД в бэкап-репозиторий. Сервер НЕ удаляю — данные на нём."
  notify "🔴 autopost: дом вернулся, но резерв ${ip} не смог забэкапить БД. Сервер оставлен работать — разберитесь вручную."
  emit "torn_down=false"
  exit 0
fi
log "Снимок отправлен: $(jq -r '.status' <<<"$resp")"

# ── 3. Проверка, что снимок реально свежий в репозитории ──────────────────
if [ -n "${BACKUP_REPO:-}" ] && [ -n "${BACKUP_TOKEN:-}" ]; then
  commit_date=$(curl -fsS --max-time 30 \
    -H "Authorization: Bearer ${BACKUP_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${BACKUP_REPO}/commits?path=${DB_FILE}&sha=${BACKUP_BRANCH}&per_page=1" \
    | jq -r '.[0].commit.committer.date // empty')
  # `date -u -d` — GNU-синтаксис (раннер ubuntu). Если дату разобрать не вышло,
  # проверку ПРОПУСКАЕМ: считать её «старой» нельзя, иначе резерв не погаснет никогда.
  ts=$(date -u -d "$commit_date" +%s 2>/dev/null || true)
  if [ -n "$commit_date" ] && [ -n "$ts" ] && [ "$ts" -gt 0 ] 2>/dev/null; then
    age=$(( $(date -u +%s) - ts ))
    log "Снимок в репозитории от ${commit_date} (${age}с назад)"
    if [ "$age" -gt $((FRESH_MINUTES * 60)) ] || [ "$age" -lt -300 ]; then
      summary "🔴 Снимок БД в ${BACKUP_REPO} старше ${FRESH_MINUTES} мин — резерв НЕ удаляю."
      notify "🔴 autopost: снимок БД в бэкап-репо не обновился. Резерв ${ip} оставлен."
      emit "torn_down=false"; exit 0
    fi
  else
    log "Не удалось прочитать/разобрать дату коммита снимка — доверяю ответу резерва"
  fi
fi

# ── 4. Дом принимает снимок и перезапускается ─────────────────────────────
home_base="${HOME_HEALTH_URL%/health}"
if [ "${SKIP_HOME_RESTORE:-0}" = "1" ] || [ -z "${HOME_HEALTH_URL:-}" ]; then
  log "Восстановление дома пропущено (SKIP_HOME_RESTORE)."
else
  log "Прошу дом принять свежий снимок БД…"
  resp=$(api_post "$home_base" "/api/db-restore?confirm=true&restart=true")
  if [ "$(jq -r '.ok // false' <<<"$resp" 2>/dev/null)" != "true" ]; then
    summary "🔴 Дом не принял снимок БД (${resp:-нет ответа}). Резерв НЕ удаляю."
    notify "🔴 autopost: дом ожил, но не принял свежую БД с резерва. Резерв ${ip} оставлен работать."
    emit "torn_down=false"; exit 0
  fi
  log "Дом принял снимок ($(jq -r '.staged_bytes' <<<"$resp") байт) и перезапускается — жду возврата…"
  back=0
  for _ in $(seq 1 20); do          # до ~5 минут
    sleep 15
    if curl -fsS --max-time 10 -o /dev/null "$HOME_HEALTH_URL"; then back=1; break; fi
  done
  if [ "$back" != "1" ]; then
    summary "🔴 Дом не поднялся после перезапуска за 5 мин. Резерв НЕ удаляю."
    notify "🔴 autopost: дом не вернулся после применения снимка БД. Резерв ${ip} оставлен работать — проверьте домашний сервер."
    emit "torn_down=false"; exit 0
  fi
  log "Дом снова отвечает и работает уже на свежей базе."
fi

# ── 5. Гасим резерв ───────────────────────────────────────────────────────
if [ "${KEEP_SERVER:-0}" = "1" ]; then
  summary "🧪 KEEP_SERVER=1: всё проверено, но сервер ${sid} оставлен."
  emit "torn_down=false"; exit 0
fi
hc DELETE "/servers/${sid}" >/dev/null || {
  notify "⚠️ autopost: не удалось удалить резерв ${ip} (id ${sid}) — удалите вручную, он тарифицируется."
  die "не удалось удалить сервер ${sid}"
}
summary "🧹 Резерв удалён (id ${sid}, ${ip}). Работаем дома на базе, доехавшей с резерва."
notify "🟢 autopost: дом вернулся. Свежая БД перенесена с резерва, сервер Hetzner удалён — оплата остановлена."
emit "torn_down=true"
exit 0
