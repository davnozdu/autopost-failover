#!/usr/bin/env bash
# Этап 4: поднять РЕЗЕРВНЫЙ сервер autopost на Hetzner Cloud.
#
# Вызывается сторожем, когда домашний сервер подтверждённо недоступен (HOME_DOWN).
# Создаёт самый дешёвый доступный x86-сервер с почасовой оплатой, ставит на него
# Docker и запускает образ ghcr.io/davnozdu/autopost:latest. Контейнер сам
# восстанавливает БД/настройки из приватного бэкап-репозитория (app/bootstrap.py:
# пустой том + BACKUP_REPO/BACKUP_TOKEN → снимок БД, иначе JSON настроек) и
# продолжает публикации.
#
# ИДЕМПОТЕНТНО: если сервер с меткой role=autopost-failover уже есть — ничего не
# создаёт, просто печатает его IP. Двух резервов быть не может.
#
# АРХИТЕКТУРА: образ собирается ТОЛЬКО под linux/amd64 (в Dockerfile Intel-VAAPI),
# поэтому ARM-тарифы (CAX…) отфильтрованы — берём x86.
#
# Переменные окружения:
#   HCLOUD_TOKEN     — токен проекта Hetzner Cloud (Read & Write). ОБЯЗАТЕЛЕН.
#   BACKUP_REPO      — приватный репо с бэкапом, напр. davnozdu/autopost-config-backup
#   BACKUP_TOKEN     — PAT к нему (contents:read+write; резерв ещё и бэкапит в него)
#   BACKUP_BRANCH    — ветка бэкапа (по умолч. main)
#   SECRET_KEY       — ключ сессий/подписи гейта (тот же, что дома — чтобы куки/токен совпали)
#   API_KEY          — ключ HTTP API (необяз.)
#   REMOTE_ACCESS_TOKEN — токен гейта (необяз.; если пусто — возьмётся из бэкапа БД)
#   TZ               — таймзона планировщика (по умолч. Europe/Prague)
#   AUTOPOST_IMAGE   — образ (по умолч. ghcr.io/davnozdu/autopost:latest, публичный)
#   PORT             — внешний порт (по умолч. 8778, как дома)
#   SERVER_TYPE      — принудительный тариф (иначе выбирается самый дешёвый доступный)
#   LOCATIONS        — приоритет локаций через запятую (по умолч. fsn1,nbg1,hel1)
#   SSH_KEY_NAME     — имя SSH-ключа в проекте Hetzner (необяз., для ручного дебага)
#   WAIT_MINUTES     — сколько ждать ответа /health на резерве (по умолч. 12)
#   DRY_RUN          — 1: только показать выбранный тариф/цену, ничего не создавать
#   TG_BOT_TOKEN, TG_CHAT_ID — уведомление в Telegram

set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh

IMAGE_REF="${AUTOPOST_IMAGE:-ghcr.io/davnozdu/autopost:latest}"
PORT="${PORT:-8778}"
LOCATIONS="${LOCATIONS:-fsn1,nbg1,hel1}"
WAIT_MINUTES="${WAIT_MINUTES:-12}"
DRY_RUN="${DRY_RUN:-0}"

[ -n "${HCLOUD_TOKEN:-}" ] || die "HCLOUD_TOKEN не задан (секрет репозитория)"
command -v jq >/dev/null || die "нужен jq"

# ── 0. Уже подняли? ───────────────────────────────────────────────────────
existing=$(find_failover_server) || die "Hetzner API недоступен (проверьте HCLOUD_TOKEN)"
if [ -n "$existing" ]; then
  ip=$(printf '%s' "$existing" | server_ip)
  sid=$(printf '%s' "$existing" | jq -r '.id')
  summary "ℹ️ Резервный сервер уже поднят: ${SERVER_NAME} (id ${sid}, ${ip}). Ничего не создаю."
  emit "server_ip=${ip}"; emit "server_id=${sid}"; emit "provisioned=false"
  exit 0
fi

# ── 1. Выбор самого дешёвого ДОСТУПНОГО x86-тарифа ────────────────────────
# Считаем по почасовой цене брутто; отбрасываем ARM (образ amd64), устаревшие
# тарифы и слишком слабые (нужно ≥2 ГБ RAM и ≥20 ГБ диска под образ ~1.2 ГБ + видео).
log "Подбираю тариф (локации: ${LOCATIONS})…"
types_json=$(hc GET "/server_types?per_page=100") || die "не удалось получить список тарифов"
dcs_json=$(hc GET "/datacenters?per_page=100") || die "не удалось получить список ЦОДов"

# ranked — ВСЕ подходящие пары (тариф, локация), от дешёвых к дорогим; pick — первая.
ranked=$(jq -n --argjson t "$types_json" --argjson d "$dcs_json" \
  --arg locs "$LOCATIONS" --arg force "${SERVER_TYPE:-}" '
  ($locs | split(",") | map(ascii_downcase | ltrimstr(" ") | rtrimstr(" "))) as $order |
  # доступные пары (тариф, ЦОД) по приоритету локаций
  [ $d.datacenters[]
    | . as $dc
    | ($order | index($dc.location.name)) as $rank
    | select($rank != null)
    | $dc.server_types.available[] as $tid
    | {tid: $tid, dc: $dc.name, loc: $dc.location.name, rank: $rank}
  ] as $avail |
  [ $t.server_types[]
    | select(.deprecated != true)
    | select(.architecture == "x86")
    | select(.memory >= 2 and .disk >= 20)
    | . as $st
    | ($st.prices[] | select(.location as $l | $order | index($l)) ) as $p
    | ($avail[] | select(.tid == $st.id and .loc == $p.location)) as $a
    | {name: $st.name, id: $st.id, cores: $st.cores, memory: $st.memory, disk: $st.disk,
       loc: $p.location, dc: $a.dc, rank: $a.rank,
       hourly: ($p.price_hourly.gross | tonumber),
       monthly: ($p.price_monthly.gross | tonumber)}
  ]
  | if ($force | length) > 0 then map(select(.name == $force)) else . end
  | unique_by([.name, .loc])
  | sort_by(.hourly, .rank)
')
pick=$(jq -c '.[0] // empty' <<<"$ranked")

[ -n "$pick" ] || die "не нашёл доступного x86-тарифа в локациях ${LOCATIONS}${SERVER_TYPE:+ (запрошен ${SERVER_TYPE})}"

st_name=$(jq -r '.name' <<<"$pick")
st_loc=$(jq -r '.loc'  <<<"$pick")
st_hour=$(jq -r '.hourly' <<<"$pick")
st_month=$(jq -r '.monthly' <<<"$pick")
log "Выбран тариф: ${st_name} ($(jq -r '.cores' <<<"$pick") vCPU, $(jq -r '.memory' <<<"$pick") ГБ RAM, $(jq -r '.disk' <<<"$pick") ГБ) в ${st_loc} — €${st_hour}/час (€${st_month}/мес)"

if [ "$DRY_RUN" = "1" ]; then
  summary "🧪 DRY_RUN: создал бы ${st_name} в ${st_loc} за €${st_hour}/час (€${st_month}/мес). Ничего не создано."
  # Полная картина цен — чтобы видеть, не отсекли ли мы фильтрами что-то дешёвое.
  summary "$(printf '\nПодходящие варианты (x86, доступны в %s):' "$LOCATIONS")"
  summary "$(jq -r '.[:10][] | "  \(.name)\t\(.cores) vCPU, \(.memory) ГБ, \(.disk) ГБ\t\(.loc)\t€\(.hourly|tostring[:7])/ч\t€\(.monthly|tostring[:6])/мес"' <<<"$ranked")"
  summary "$(printf '\nЧто отсеяно фильтрами (для сверки):')"
  summary "$(jq -n --argjson t "$types_json" --argjson d "$dcs_json" -r '
    [ $d.datacenters[] | .location.name as $l | .server_types.available[] | {tid:., loc:$l} ] as $avail |
    [ $t.server_types[] | select(.deprecated != true) | . as $st
      | ($avail[] | select(.tid == $st.id)) as $a
      | ($st.prices[] | select(.location == $a.loc)) as $p
      | {name:$st.name, arch:$st.architecture, cores:$st.cores, memory:$st.memory,
         loc:$a.loc, hourly:($p.price_hourly.gross|tonumber)} ]
    | unique_by([.name,.loc]) | sort_by(.hourly)
    | map(select(.arch != "x86" or .memory < 2))
    | .[:8][] | "  \(.name)\t\(.arch)\t\(.cores) vCPU, \(.memory) ГБ\t\(.loc)\t€\(.hourly|tostring[:7])/ч  ← \(if .arch != "x86" then "ARM: образ autopost только amd64" else "мало памяти" end)"')"
  emit "provisioned=false"
  exit 0
fi

# ── 2. Образ ОС: предпочитаем app-образ docker-ce (Docker предустановлен) ──
os_image=$(hc GET "/images?type=app&per_page=100" \
  | jq -r '[.images[] | select(.name=="docker-ce") | .name] | .[0] // empty')
if [ -z "$os_image" ]; then
  os_image=$(hc GET "/images?type=system&per_page=100&architecture=x86" \
    | jq -r '[.images[] | select(.status=="available") | .name]
             | (map(select(. == "ubuntu-24.04")) + map(select(startswith("ubuntu-")))) | .[0] // empty')
fi
[ -n "$os_image" ] || die "не нашёл подходящий образ ОС"
log "Образ ОС: ${os_image}"

# ── 3. cloud-init: поставить Docker (если нет) и запустить контейнер ───────
# Секреты уезжают в user_data — он виден только владельцу токена Hetzner; на самом
# сервере кладём их в /opt/autopost/.env с правами 600.
env_file=$(cat <<ENVEOF
DATA_DIR=data
TZ=${TZ:-Europe/Prague}
SECRET_KEY=${SECRET_KEY:-}
API_KEY=${API_KEY:-}
BACKUP_REPO=${BACKUP_REPO:-}
BACKUP_TOKEN=${BACKUP_TOKEN:-}
BACKUP_BRANCH=${BACKUP_BRANCH:-main}
RESTORE_ON_EMPTY=true
RESTRICT_PUBLIC=true
REMOTE_ACCESS_TOKEN=${REMOTE_ACCESS_TOKEN:-}
TRUSTED_NETWORKS=127.0.0.0/8,::1/128
LOGIN_CAPTCHA=true
LOGIN_AUTOBAN=true
ENVEOF
)

user_data=$(cat <<CLOUDEOF
#!/bin/bash
set -x
export DEBIAN_FRONTEND=noninteractive
# Docker: в app-образе docker-ce уже стоит, в чистой Ubuntu — ставим.
if ! command -v docker >/dev/null 2>&1; then
  for i in 1 2 3; do curl -fsSL https://get.docker.com | sh && break; sleep 20; done
fi
systemctl enable --now docker
mkdir -p /opt/autopost/data /opt/autopost/site
umask 077
set +x   # не светить секреты в /var/log/cloud-init-output.log
cat >/opt/autopost/.env <<'ENVFILE'
${env_file}
ENVFILE
chmod 600 /opt/autopost/.env
set -x
# Образ публичный — логин в GHCR не нужен.
for i in 1 2 3; do docker pull ${IMAGE_REF} && break; sleep 20; done
docker rm -f autopost 2>/dev/null
docker run -d --name autopost --restart unless-stopped \\
  -p ${PORT}:8080 \\
  --env-file /opt/autopost/.env \\
  -v /opt/autopost/data:/app/data \\
  -v /opt/autopost/site:/app/templates_sites \\
  ${IMAGE_REF}
# Метка «готово» — по ней видно в консоли Hetzner, что cloud-init доехал.
touch /opt/autopost/READY
CLOUDEOF
)

# ── 4. Создание сервера ───────────────────────────────────────────────────
ssh_keys="[]"
if [ -n "${SSH_KEY_NAME:-}" ]; then
  ssh_keys=$(jq -n --arg n "$SSH_KEY_NAME" '[$n]')
fi

body=$(jq -n \
  --arg name "$SERVER_NAME" --arg type "$st_name" --arg image "$os_image" \
  --arg loc "$st_loc" --arg ud "$user_data" --argjson keys "$ssh_keys" '
  {name:$name, server_type:$type, image:$image, location:$loc,
   start_after_create:true, user_data:$ud, ssh_keys:$keys,
   public_net:{enable_ipv4:true, enable_ipv6:true},
   labels:{role:"autopost-failover"}}')

log "Создаю сервер ${SERVER_NAME} (${st_name} @ ${st_loc})…"
created=$(hc POST "/servers" "$body")
if [ $? -ne 0 ]; then
  err=$(jq -r '.error.message // "неизвестная ошибка"' <<<"$created" 2>/dev/null)
  notify "🔴 autopost: НЕ удалось поднять резерв на Hetzner: ${err}"
  die "Hetzner отказал: ${err}"
fi

sid=$(jq -r '.server.id' <<<"$created")
ip=$(jq -r '.server.public_net.ipv4.ip' <<<"$created")
root_pw=$(jq -r '.root_password // empty' <<<"$created")
summary "🟢 Резерв создан: ${SERVER_NAME} id=${sid}, IP ${ip}, ${st_name} @ ${st_loc}, €${st_hour}/час."
emit "server_ip=${ip}"; emit "server_id=${sid}"; emit "provisioned=true"
# Root-пароль (когда SSH-ключ не задан) в ЛОГ НЕ ПИШЕМ: репозиторий публичный,
# логи прогонов видны всем. Маскируем и отправляем только в Telegram.
if [ -n "$root_pw" ]; then
  echo "::add-mask::${root_pw}"
  notify "🔑 autopost-резерв ${ip}: root-пароль ${root_pw} (SSH-ключ в проекте Hetzner не задан)"
  log "root-пароль сгенерирован и отправлен в Telegram (в лог не пишу — репозиторий публичный)"
fi

# ── 5. Ждём, пока контейнер поднимется и ответит /health ──────────────────
health="http://${ip}:${PORT}/health"
log "Жду ответа ${health} (до ${WAIT_MINUTES} мин)…"
deadline=$(( $(date +%s) + WAIT_MINUTES * 60 ))
ok=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  sleep 20
  if curl -fsS --max-time 10 -o /dev/null "$health"; then ok=1; break; fi
done

if [ "$ok" = "1" ]; then
  summary "✅ Резерв работает: ${health} отвечает. Вход: http://${ip}:${PORT}/?access=<токен>"
  notify "🟢 autopost: домашний сервер лежит — поднял резерв на Hetzner.
Адрес: http://${ip}:${PORT}/?access=<ваш токен доступа>
Тариф ${st_name} @ ${st_loc}, €${st_hour}/час. Погашу автоматически, когда дом вернётся."
else
  summary "⚠️ Сервер создан (${ip}), но /health не ответил за ${WAIT_MINUTES} мин — контейнер ещё ставится или упал. Сервер НЕ удаляю: зайдите и посмотрите \`docker logs autopost\`."
  notify "⚠️ autopost: резерв ${ip} создан, но /health молчит ${WAIT_MINUTES} мин. Проверьте docker logs autopost."
fi
exit 0
