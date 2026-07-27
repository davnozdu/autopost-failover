#!/usr/bin/env bash
# Этап 4: поднять РЕЗЕРВНЫЙ сервер autopost на DigitalOcean.
#
# Вызывается сторожем, когда домашний сервер подтверждённо недоступен (HOME_DOWN).
# Создаёт дроплет с почасовой оплатой, ставит Docker через cloud-init и запускает
# образ ghcr.io/davnozdu/autopost:latest. Контейнер сам восстанавливает БД/настройки
# из приватного бэкап-репозитория (app/bootstrap.py: пустой том +
# BACKUP_REPO/BACKUP_TOKEN → снимок БД, иначе JSON настроек) и продолжает публикации.
#
# ИДЕМПОТЕНТНО: если дроплет с тегом autopost-failover уже есть — ничего не создаёт,
# просто печатает его IP. Двух резервов быть не может.
#
# АРХИТЕКТУРА: образ собирается ТОЛЬКО под linux/amd64 (в Dockerfile Intel-VAAPI),
# поэтому берём обычные x86-дроплеты (у DO это все базовые тарифы).
#
# Переменные окружения:
#   DO_TOKEN         — Personal Access Token DigitalOcean (Read+Write). ОБЯЗАТЕЛЕН.
#   BACKUP_REPO      — приватный репо с бэкапом, напр. davnozdu/autopost-config-backup
#   BACKUP_TOKEN     — PAT к нему (contents:read+write; резерв ещё и бэкапит в него)
#   BACKUP_BRANCH    — ветка бэкапа (по умолч. main)
#   SECRET_KEY       — ключ сессий/подписи гейта (тот же, что дома)
#   API_KEY          — ключ HTTP API (нужен для возврата домой, см. teardown.sh)
#   REMOTE_ACCESS_TOKEN — токен гейта (необяз.; если пусто — возьмётся из бэкапа БД)
#   TZ               — таймзона планировщика (по умолч. Europe/Prague)
#   AUTOPOST_IMAGE   — образ (по умолч. ghcr.io/davnozdu/autopost:latest, публичный)
#   PORT             — внешний порт (по умолч. 8778, как дома)
#   SIZE_SLUG        — тариф (по умолч. s-1vcpu-1gb, $6/мес); при недоступности
#                      берётся следующий по цене подходящий
#   REGIONS          — приоритет регионов через запятую (по умолч. fra1,ams3,lon1)
#   SSH_KEY_NAME     — имя SSH-ключа в аккаунте DO (очень желательно: без него
#                      попасть на сервер можно только через сброс пароля в консоли)
#   SWAP_GB          — размер файла подкачки (по умолч. 2; на 1 ГБ RAM он нужен)
#   WAIT_MINUTES     — сколько ждать ответа /health (по умолч. 12)
#   DRY_RUN          — 1: только показать выбранный тариф/цену, ничего не создавать
#   TG_BOT_TOKEN, TG_CHAT_ID — уведомление в Telegram

set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh

IMAGE_REF="${AUTOPOST_IMAGE:-ghcr.io/davnozdu/autopost:latest}"
PORT="${PORT:-8778}"
REGIONS="${REGIONS:-fra1,ams3,lon1}"
SIZE_SLUG="${SIZE_SLUG:-s-1vcpu-1gb}"
SWAP_GB="${SWAP_GB:-2}"
WAIT_MINUTES="${WAIT_MINUTES:-12}"
DRY_RUN="${DRY_RUN:-0}"

[ -n "${DO_TOKEN:-}" ] || die "DO_TOKEN не задан (секрет репозитория)"
command -v jq >/dev/null || die "нужен jq"

# ── 0. Уже подняли? ───────────────────────────────────────────────────────
existing=$(find_failover_server) || die "DigitalOcean API недоступен (проверьте DO_TOKEN)"
if [ -n "$existing" ]; then
  ip=$(printf '%s' "$existing" | server_ip)
  sid=$(printf '%s' "$existing" | jq -r '.id')
  summary "ℹ️ Резервный сервер уже поднят: ${SERVER_NAME} (id ${sid}, ${ip}). Ничего не создаю."
  emit "server_ip=${ip}"; emit "server_id=${sid}"; emit "provisioned=false"
  exit 0
fi

# ── 1. Кандидаты: тариф × регион, от дешёвых к дорогим ────────────────────
# Предпочитаем SIZE_SLUG (тот, что выбрал пользователь), остальные подходящие —
# как запасные варианты по возрастанию цены. Список availability у провайдера
# бывает неточным, поэтому при отказе просто пробуем следующего кандидата.
log "Подбираю тариф (регионы: ${REGIONS}, предпочтение: ${SIZE_SLUG})…"
sizes_json=$(do_api GET "/sizes?per_page=200") || die "не удалось получить список тарифов"

ranked=$(jq -n --argjson s "$sizes_json" --arg regs "$REGIONS" --arg pref "$SIZE_SLUG" '
  ($regs | split(",") | map(ascii_downcase | ltrimstr(" ") | rtrimstr(" "))) as $order |
  [ $s.sizes[]
    | select(.available == true)
    | select(.memory >= 1024 and .disk >= 20)
    | . as $sz
    | ($sz.regions[] | select(. as $r | $order | index($r))) as $r
    | {slug: $sz.slug, region: $r, vcpus: $sz.vcpus, memory: $sz.memory, disk: $sz.disk,
       hourly: ($sz.price_hourly | tonumber), monthly: ($sz.price_monthly | tonumber),
       rank: ($order | index($r)),
       pref: (if $sz.slug == $pref then 0 else 1 end)}
  ]
  | unique_by([.slug, .region])
  | sort_by(.pref, .hourly, .rank)
')
[ "$(jq 'length' <<<"$ranked")" -gt 0 ] || die "не нашёл подходящего тарифа в регионах ${REGIONS}"

pick=$(jq -c '.[0]' <<<"$ranked")
p_slug=$(jq -r '.slug' <<<"$pick"); p_reg=$(jq -r '.region' <<<"$pick")
p_hour=$(jq -r '.hourly' <<<"$pick"); p_month=$(jq -r '.monthly' <<<"$pick")
log "Выбран тариф: ${p_slug} ($(jq -r '.vcpus' <<<"$pick") vCPU, $(jq -r '.memory' <<<"$pick") МБ RAM, $(jq -r '.disk' <<<"$pick") ГБ) в ${p_reg} — \$${p_hour}/час (\$${p_month}/мес)"

if [ "$DRY_RUN" = "1" ]; then
  summary "🧪 DRY_RUN: создал бы ${p_slug} в ${p_reg} за \$${p_hour}/час (\$${p_month}/мес). Ничего не создано."
  summary "$(printf '\nПорядок попыток (предпочтение → цена → регион):')"
  summary "$(jq -r '.[:8][] | "  \(.slug)\t\(.vcpus) vCPU, \(.memory) МБ, \(.disk) ГБ\t\(.region)\t$\(.hourly)/ч\t$\(.monthly)/мес"' <<<"$ranked")"
  emit "provisioned=false"
  exit 0
fi

# ── 2. Образ ОС ───────────────────────────────────────────────────────────
# Берём СВЕЖУЮ Ubuntu и ставим Docker сами (~1 мин при старте). Marketplace-образ
# «docker-*» у DO собран на Ubuntu 20.04, которая уже без обновлений безопасности,
# а сервер торчит в интернет — экономия минуты того не стоит. Переопределяется
# переменной OS_IMAGE.
os_image="${OS_IMAGE:-}"
if [ -z "$os_image" ]; then
  os_image=$(do_api GET "/images?type=distribution&per_page=200" \
    | jq -r '[.images[] | select(.slug != null) | select(.slug | endswith("-x64")) | .slug]
             | (map(select(. == "ubuntu-24-04-x64")) + map(select(startswith("ubuntu-24")))
                + map(select(startswith("ubuntu-22")))) | .[0] // empty')
fi
[ -n "$os_image" ] || die "не нашёл подходящий образ ОС"
log "Образ ОС: ${os_image}"

# ── 3. SSH-ключ (желательно, но не обязателен) ────────────────────────────
ssh_keys="[]"
if [ -n "${SSH_KEY_NAME:-}" ]; then
  ssh_keys=$(do_api GET "/account/keys?per_page=200" \
    | jq -c --arg n "$SSH_KEY_NAME" '[.ssh_keys[] | select(.name == $n) | .id]')
  [ "$(jq 'length' <<<"$ssh_keys")" -gt 0 ] \
    || log "ВНИМАНИЕ: SSH-ключ «${SSH_KEY_NAME}» в аккаунте DO не найден — создаю без ключа"
else
  log "ВНИМАНИЕ: SSH_KEY_NAME не задан. Зайти на сервер можно будет только через веб-консоль DO со сбросом пароля."
fi

# ── 4. cloud-init: swap, Docker, контейнер ────────────────────────────────
# Секреты уезжают в user_data (виден только владельцу токена DO); на самом сервере
# кладём их в /opt/autopost/.env с правами 600.
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
# Файл подкачки: на тарифе с 1 ГБ RAM монтаж видео-сториз (ffmpeg) может упереться
# в память, а OOM-killer убьёт контейнер. Своп дешевле, чем тариф вдвое дороже.
if [ ! -f /swapfile ] && [ "${SWAP_GB}" -gt 0 ]; then
  fallocate -l ${SWAP_GB}G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=\$((${SWAP_GB}*1024))
  chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
if ! command -v docker >/dev/null 2>&1; then
  for i in 1 2 3; do curl -fsSL https://get.docker.com | sh && break; sleep 20; done
fi
systemctl enable --now docker
mkdir -p /opt/autopost/data /opt/autopost/site
umask 077
set +x   # не светить секреты в логе cloud-init
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
touch /opt/autopost/READY
CLOUDEOF
)

# ── 5. Создание: идём по кандидатам, пока какой-нибудь не создастся ───────
created=""; sid=""; ip=""
attempt=0
while read -r cand; do
  [ -n "$cand" ] || continue
  attempt=$((attempt + 1))
  [ "$attempt" -gt 6 ] && break
  c_slug=$(jq -r '.slug' <<<"$cand"); c_reg=$(jq -r '.region' <<<"$cand")
  c_hour=$(jq -r '.hourly' <<<"$cand"); c_month=$(jq -r '.monthly' <<<"$cand")
  body=$(jq -n --arg name "$SERVER_NAME" --arg size "$c_slug" --arg image "$os_image" \
    --arg region "$c_reg" --arg ud "$user_data" --argjson keys "$ssh_keys" --arg tag "$SERVER_TAG" '
    {name:$name, region:$region, size:$size, image:$image,
     ssh_keys:$keys, backups:false, ipv6:true, monitoring:false,
     user_data:$ud, tags:[$tag]}')
  log "Попытка ${attempt}: создаю ${c_slug} в ${c_reg} (\$${c_hour}/час)…"
  resp=$(do_api POST "/droplets" "$body")
  if [ $? -eq 0 ] && [ "$(jq -r '.droplet.id // empty' <<<"$resp")" != "" ]; then
    created="$resp"; sid=$(jq -r '.droplet.id' <<<"$resp")
    p_slug="$c_slug"; p_reg="$c_reg"; p_hour="$c_hour"; p_month="$c_month"
    break
  fi
  err=$(jq -r '.message // .id // "неизвестная ошибка"' <<<"$resp" 2>/dev/null)
  log "Отказ: ${err} — пробую следующий тариф"
done < <(jq -c '.[]' <<<"$ranked")

if [ -z "$created" ]; then
  notify "🔴 autopost: НЕ удалось поднять резерв на DigitalOcean (перебрал ${attempt} тарифов)."
  die "DigitalOcean не создал дроплет ни по одному из ${attempt} кандидатов"
fi

# IP появляется не сразу — дожидаемся статуса active
log "Дроплет ${sid} создаётся, жду сетевых настроек…"
for _ in $(seq 1 30); do
  d=$(do_api GET "/droplets/${sid}" | jq -c '.droplet // empty')
  ip=$(printf '%s' "$d" | server_ip)
  st=$(printf '%s' "$d" | jq -r '.status // empty')
  [ -n "$ip" ] && [ "$st" = "active" ] && break
  sleep 10
done
[ -n "$ip" ] || die "дроплет ${sid} создан, но публичный IP не появился — проверьте консоль DO"

summary "🟢 Резерв создан: ${SERVER_NAME} id=${sid}, IP ${ip}, ${p_slug} @ ${p_reg}, \$${p_hour}/час (\$${p_month}/мес)."
emit "server_ip=${ip}"; emit "server_id=${sid}"; emit "provisioned=true"

# ── 6. Ждём, пока контейнер поднимется и ответит /health ──────────────────
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
  notify "🟢 autopost: домашний сервер лежит — поднял резерв на DigitalOcean.
Адрес: http://${ip}:${PORT}/?access=<ваш токен доступа>
Тариф ${p_slug} @ ${p_reg}, \$${p_hour}/час. Удалю автоматически, когда дом вернётся."
else
  summary "⚠️ Дроплет создан (${ip}), но /health не ответил за ${WAIT_MINUTES} мин — контейнер ещё ставится или упал. Сервер НЕ удаляю: зайдите и посмотрите \`docker logs autopost\`."
  notify "⚠️ autopost: резерв ${ip} создан, но /health молчит ${WAIT_MINUTES} мин. Проверьте docker logs autopost."
fi
exit 0
