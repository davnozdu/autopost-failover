#!/usr/bin/env bash
# Этап 5: вернуться на домашний сервер и УДАЛИТЬ резерв на DigitalOcean.
#
# Вызывается сторожем, когда дом снова отвечает (HOME_UP), а резервный дроплет
# ещё жив. Порядок важен — сначала спасаем данные, потом удаляем:
#
#   1) на РЕЗЕРВЕ ставим публикации на паузу (POST /api/scheduler/pause) — снимок
#      должен быть ФИНАЛЬНЫМ: всё, что резерв опубликует после снимка, не доедет
#      домой, и дом выдаст те же новости повторно;
#   2) форсим снимок БД в бэкап-репозиторий (POST /api/db-backup);
#   3) убеждаемся, что снимок реально лёг в репозиторий (свежий коммит файла);
#   4) просим ДОМ принять этот снимок (POST /api/db-restore?confirm=true) —
#      дом кладёт его «ожидающим» и перезапускается, подставляя базу на старте;
#   5) ждём, пока дом снова ответит /health;
#   6) только теперь удаляем дроплет.
#
# Любой сбой на шагах 2–5 ОСТАВЛЯЕТ резерв жить (и СНИМАЕТ с него паузу, чтобы он
# продолжал постить за главного): лучше платить центы за час, чем потерять посты.
# Исключение — резерв, который сам не отвечает /health (значит, он и не постил):
# такой удаляем, дом остаётся главным.
#
# ВАЖНО: выключенный (powered off) дроплет DigitalOcean ПРОДОЛЖАЕТ тарифицироваться —
# ресурсы за ним зарезервированы. Счётчик останавливает только УДАЛЕНИЕ (destroy),
# поэтому poweroff/shutdown здесь не используется нигде.
#
# Переменные окружения:
#   DO_TOKEN         — Personal Access Token DigitalOcean (Read+Write). ОБЯЗАТЕЛЕН.
#   HOME_HEALTH_URL  — тот же секрет, что у сторожа: http://дом:8778/health
#   API_KEY          — ключ HTTP API (одинаковый у дома и резерва)
#   BACKUP_REPO, BACKUP_TOKEN, BACKUP_BRANCH — для проверки свежести снимка
#   PORT             — порт резерва (по умолч. 8778)
#   SKIP_HOME_RESTORE=1 — не трогать дом (только бэкап + удаление резерва)
#   KEEP_SERVER=1    — всё проверить, но дроплет не удалять (тест)
#   TG_BOT_TOKEN, TG_CHAT_ID — уведомления

set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh

PORT="${PORT:-8778}"
BACKUP_BRANCH="${BACKUP_BRANCH:-main}"
DB_FILE="autopost-db.sqlite.gz"
FRESH_MINUTES="${FRESH_MINUTES:-30}"   # насколько свежим считаем снимок в репо

[ -n "${DO_TOKEN:-}" ] || die "DO_TOKEN не задан (секрет репозитория)"
command -v jq >/dev/null || die "нужен jq"

# ── 0. Есть ли что удалять ────────────────────────────────────────────────
existing=$(find_failover_server) || die "DigitalOcean API недоступен (проверьте DO_TOKEN)"
if [ -z "$existing" ]; then
  log "Резервного сервера нет — удалять нечего."
  emit "torn_down=false"
  exit 0
fi
ip=$(printf '%s' "$existing" | server_ip)
sid=$(printf '%s' "$existing" | jq -r '.id')
log "Резерв найден: ${SERVER_NAME} id=${sid}, ${ip}. Дом ожил — возвращаемся."

# Снимок БД (~20 МБ gzip) заливается в GitHub синхронно внутри запроса, поэтому
# таймаут щедрый: оборвать его на полпути хуже, чем подождать.
api_post() {  # api_post <base-url> <путь с параметрами> → тело ответа, код в $?
  curl -fsS --max-time 300 -X POST \
    -H "Authorization: Bearer ${API_KEY:-}" \
    -H "Content-Length: 0" \
    "${1}${2}"
}

# Снять паузу с резерва — вызывается на всех путях отказа, чтобы резерв остался
# рабочим, а не «живым, но молчащим».
resume_backup() {
  api_post "$backup_base" "/api/scheduler/resume" >/dev/null 2>&1 \
    && log "Паузу с резерва снял — он продолжает постить за главного." \
    || log "ВНИМАНИЕ: не удалось снять паузу с резерва — он не публикует! Зайдите в админку резерва."
}

# ── Полное УДАЛЕНИЕ дроплета (не выключение!) ─────────────────────────────
# Возвращает 0, только когда дроплета ФАКТИЧЕСКИ нет в API.
delete_server_fully() {
  local id="$1" gone=0
  do_api DELETE "/droplets/${id}" >/dev/null || return 1
  # удаление асинхронное — дожидаемся исчезновения из API (до ~100 с)
  for _ in $(seq 1 20); do
    if ! do_api GET "/droplets/${id}" >/dev/null 2>&1; then gone=1; break; fi
    sleep 5
  done
  [ "$gone" = "1" ] || return 1
  log "Дроплет ${id} удалён — тарификация остановлена."
  # Финальная сверка: дроплетов с нашим тегом не осталось. Выдача по тегу
  # обновляется с задержкой, поэтому свежеудалённый может ещё «висеть» — если
  # это ТОТ ЖЕ id, перепроверяем; чужой id означает второй резерв и это ошибка.
  local left left_id
  for _ in 1 2 3; do
    left=$(find_failover_server)
    [ -z "$left" ] && break
    left_id=$(jq -r '.id' <<<"$left")
    if [ "$left_id" != "$id" ]; then
      log "ВНИМАНИЕ: в аккаунте есть ЕЩЁ ОДИН дроплет с тегом ${SERVER_TAG} (id ${left_id})!"
      return 1
    fi
    log "Выдача по тегу ещё показывает удалённый ${id} — перепроверяю…"
    sleep 10
  done
  if [ -n "$left" ]; then
    log "ВНИМАНИЕ: дроплет ${id} удалён по GET, но всё ещё виден в выдаче по тегу."
    return 1
  fi
  # снапшоты от резерва тоже тарифицируются — если вдруг появились, сообщаем
  local snaps
  snaps=$(do_api GET "/snapshots?resource_type=droplet&per_page=100" \
    | jq -r --arg n "$SERVER_NAME" '[.snapshots[]? | select(.name | contains($n)) | .id] | join(" ")' 2>/dev/null)
  [ -n "$snaps" ] && log "ВНИМАНИЕ: остались снапшоты резерва (${snaps}) — они тарифицируются, удалите вручную."
  return 0
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
  delete_server_fully "$sid" || {
    notify "⚠️ autopost: не удалось удалить нерабочий резерв ${ip} (id ${sid}) — снесите вручную, он тарифицируется."
    die "дроплет ${sid} не удалён"
  }
  notify "🧹 autopost: дом вернулся. Нерабочий резерв ${ip} удалён (он не отвечал /health). Тарификация остановлена."
  emit "torn_down=true"
  exit 0
fi

# ── 2. Финальный снимок БД с резерва ──────────────────────────────────────
[ -n "${API_KEY:-}" ] || {
  notify "🔴 autopost: дом вернулся, но API_KEY не задан — не могу забрать БД с резерва ${ip}. Сервер оставлен."
  die "API_KEY не задан: без него нельзя снять финальный бэкап с резерва (сервер НЕ удалён)"
}
# Пауза ПЕРЕД снимком: после неё резерв ничего не публикует, значит снимок финальный.
# Уже начатая публикация доработает — поэтому даём ей несколько секунд.
resp=$(api_post "$backup_base" "/api/scheduler/pause")
if [ "$(jq -r '.paused // false' <<<"$resp" 2>/dev/null)" = "true" ]; then
  log "Публикации на резерве поставлены на паузу."
  sleep 10
else
  # Старый образ на резерве (без ручки паузы) — не повод отменять возврат, просто
  # остаётся узкое окно, где резерв может опубликовать что-то мимо снимка.
  log "ВНИМАНИЕ: пауза на резерве не сработала (${resp:-нет ответа}) — продолжаю, но возможна двойная публикация."
fi

log "Форсирую снимок БД на резерве…"
ok=0
for attempt in 1 2 3; do
  resp=$(api_post "$backup_base" "/api/db-backup?force=true") && \
    [ "$(jq -r '.ok // false' <<<"$resp" 2>/dev/null)" = "true" ] && { ok=1; break; }
  log "Попытка ${attempt}: снимок не удался (${resp:-нет ответа})"
  sleep 20
done
if [ "$ok" != "1" ]; then
  resume_backup
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
      resume_backup
      summary "🔴 Снимок БД в ${BACKUP_REPO} старше ${FRESH_MINUTES} мин — резерв НЕ удаляю."
      notify "🔴 autopost: снимок БД в бэкап-репо не обновился. Резерв ${ip} оставлен."
      emit "torn_down=false"; exit 0
    fi
  else
    log "Не удалось прочитать/разобрать дату коммита снимка — доверяю ответу резерва"
  fi
fi

# ── 4. Дом принимает снимок и перезапускается ─────────────────────────────
home_base="${HOME_HEALTH_URL%/}"; home_base="${home_base%/health}"

# ЗАЩИТА ОТ ОТКАТА ДОМАШНЕЙ БАЗЫ. Резерв мог отработать вхолостую: например, дом
# на самом деле работал и постил, но был недоступен из интернета (сбой маршрута,
# провайдер, DDNS), и сторож ошибочно решил «дом лежит». Тогда база резерва —
# это СТАРАЯ копия из бэкапа, и отдавать её домой нельзя: домашние публикации
# откатятся. Сверяем по последней публикации: везём базу домой, только если на
# резерве публикации СВЕЖЕЕ домашних.
api_get() { curl -fsS --max-time 30 -H "Authorization: Bearer ${API_KEY:-}" "${1}${2}"; }
newer_on_backup="unknown"
b_pub=$(api_get "$backup_base" "/api/status" | jq -r '.last_published // empty' 2>/dev/null)
h_pub=$(api_get "$home_base"   "/api/status" | jq -r '.last_published // empty' 2>/dev/null)
if [ -n "$b_pub" ] || [ -n "$h_pub" ]; then
  log "Последняя публикация: резерв=${b_pub:-нет}, дом=${h_pub:-нет}"
  # ISO-8601 в UTC сравним лексикографически; пустая строка = «публикаций нет»
  if [ -z "$b_pub" ]; then newer_on_backup="no"
  elif [ -z "$h_pub" ]; then newer_on_backup="yes"
  elif [[ "$b_pub" > "$h_pub" ]]; then newer_on_backup="yes"
  else newer_on_backup="no"; fi
fi

if [ "$newer_on_backup" = "no" ] && [ "${FORCE_HOME_RESTORE:-0}" != "1" ]; then
  log "На резерве нет публикаций новее домашних — базу домой НЕ везу (иначе откат)."
  summary "ℹ️ Резерв ничего нового не опубликовал: домашняя база остаётся своей, дроплет удаляю."
elif [ "${SKIP_HOME_RESTORE:-0}" = "1" ] || [ -z "${HOME_HEALTH_URL:-}" ]; then
  log "Восстановление дома пропущено (SKIP_HOME_RESTORE)."
else
  log "Прошу дом принять свежий снимок БД…"
  resp=$(api_post "$home_base" "/api/db-restore?confirm=true&restart=true")
  if [ "$(jq -r '.ok // false' <<<"$resp" 2>/dev/null)" != "true" ]; then
    resume_backup
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
    resume_backup
    summary "🔴 Дом не поднялся после перезапуска за 5 мин. Резерв НЕ удаляю."
    notify "🔴 autopost: дом не вернулся после применения снимка БД. Резерв ${ip} оставлен работать — проверьте домашний сервер."
    emit "torn_down=false"; exit 0
  fi
  log "Дом снова отвечает и работает уже на свежей базе."
fi

# ── 5. Удаляем резерв ─────────────────────────────────────────────────────
if [ "${KEEP_SERVER:-0}" = "1" ]; then
  summary "🧪 KEEP_SERVER=1: всё проверено, но дроплет ${sid} оставлен. Публикации на нём оставлены НА ПАУЗЕ — иначе он постил бы параллельно с домом."
  emit "torn_down=false"; exit 0
fi
delete_server_fully "$sid" || {
  notify "⚠️ autopost: резерв ${ip} (id ${sid}) НЕ удалился полностью — зайдите в консоль DigitalOcean и снесите вручную, иначе тарификация продолжается."
  die "дроплет ${sid} не удалён полностью"
}
summary "🧹 Резерв УДАЛЁН из аккаунта DigitalOcean (id ${sid}, ${ip}) — тарификация остановлена. Работаем дома на базе, доехавшей с резерва."
notify "🟢 autopost: дом вернулся. Свежая БД перенесена с резерва, дроплет удалён (не выключен) — оплата остановлена."
emit "torn_down=true"
exit 0
