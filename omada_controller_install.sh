#!/usr/bin/env bash
# title   : install-omada-safe.sh
# purpose : Safer installer for TP-Link Omada Software Controller
# supports: Ubuntu 20.04 (focal), 22.04 (jammy), 24.04 (noble), 24.10 (oracular*)
# note    : *Для 24.10 MongoDB берём из репозитория noble (24.04) — это типовой фоллбэк.
# updated : 2025-09-19

set -Eeuo pipefail
IFS=$'\n\t'

# ---------------------- utils ----------------------
log()  { printf "\033[1;32m[+]\033[0m %s\n" "$*"; }
info() { printf "\033[0;36m[~]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31m[✗]\033[0m %s\n" "$*" >&2; exit 1; }
cleanup(){ warn "Произошла ошибка. Проверьте сообщения выше."; }
trap cleanup ERR

usage() {
  cat <<'USAGE'
Безопасная установка TP-Link Omada Controller.

Опции:
  --omada-url URL         Прямая ссылка на .deb Omada (рекомендуется)
  --omada-sha256 SHA      Контрольная сумма SHA256 для .deb
  --ufw-allow-cidr CIDR   Разрешить доступ к 8043 только из CIDR (пример: 192.168.0.0/16)
  --help                  Показать помощь

Если --omada-url не задан — скрипт аккуратно спарсит последнюю стабильную .deb
с https://support.omadanetworks.com под вашу архитектуру. Для максимальной безопасности
используйте URL+SHA256.
USAGE
}

OMADA_URL="https://static.tp-link.com/upload/software/2025/202508/20250802/omada_v5.15.24.19_linux_x64_20250724152622.deb"
OMADA_SHA=""
UFW_CIDR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --omada-url)        OMADA_URL="${2:-}"; shift 2 ;;
    --omada-sha256)     OMADA_SHA="${2:-}"; shift 2 ;;
    --ufw-allow-cidr)   UFW_CIDR="${2:-}"; shift 2 ;;
    -h|--help)          usage; exit 0 ;;
    *)                  die "Неизвестный аргумент: $1 (см. --help)";;
  esac
done

echo -e "\n=== TP-Link Omada Controller — безопасная установка ===\n"

# ---------------------- base checks ----------------------
if [[ "$(id -u)" -ne 0 ]]; then
  die "Нужны права root. Запустите: sudo bash $0 [опции]"
fi

# AVX нужен для MongoDB 5+/8+
if ! lscpu | grep -iq 'avx'; then
  die "CPU без AVX. MongoDB 5.0+/8.0 требует AVX."
fi

# OS detection
[[ -r /etc/os-release ]] || die "Не могу прочитать /etc/os-release"
. /etc/os-release
case "${VERSION_CODENAME:-}" in
  focal|jammy|noble|oracular) OS_CODENAME="$VERSION_CODENAME" ;;
  *) die "Поддерживаются только Ubuntu 20.04/22.04/24.04/24.10";;
esac
ARCH="$(dpkg --print-architecture)" # amd64 | arm64 | ...
info "Обнаружена Ubuntu $VERSION_ID ($OS_CODENAME), arch=$ARCH"

export DEBIAN_FRONTEND=noninteractive

# ---------------------- prerequisites ----------------------
log "Устанавливаю базовые зависимости (curl, gpg и пр.)"
apt-get update -qq
apt-get install -yq --no-install-recommends \
  ca-certificates gnupg curl jq lsb-release apt-transport-https \
  coreutils grep sed gawk

# ---------------------- MongoDB 8.0 repo ----------------------
# Для 24.10 используем репозиторий noble
MONGO_REPO_CODENAME="$OS_CODENAME"
if [[ "$OS_CODENAME" == "oracular" ]]; then
  warn "MongoDB 8.0 для Ubuntu 24.10: используем репозиторий noble (24.04) в качестве фоллбэка."
  MONGO_REPO_CODENAME="noble"
fi

log "Добавляю репозиторий MongoDB 8.0 и настраиваю пиннинг"
curl -fsSL --proto '=https' --tlsv1.2 https://www.mongodb.org/static/pgp/server-8.0.asc \
  | gpg --dearmor -o /usr/share/keyrings/mongodb-server-8.0.gpg

echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg] https://repo.mongodb.org/apt/ubuntu ${MONGO_REPO_CODENAME}/mongodb-org/8.0 multiverse" \
  > /etc/apt/sources.list.d/mongodb-org-8.0.list

cat >/etc/apt/preferences.d/mongodb-org-8.0.pref <<'PREF'
Package: mongodb-org*
Pin: version 8.0*
Pin-Priority: 1001
PREF

apt-get update -qq

log "Ставлю MongoDB 8.0, OpenJDK 21 (headless), jsvc"
apt-get install -y mongodb-org openjdk-21-jre-headless jsvc

# Привязываем mongod к localhost на всякий случай
if [[ -f /etc/mongod.conf ]]; then
  if grep -qE '^\s*bindIp\s*:' /etc/mongod.conf; then
    sed -E -i 's/^\s*bindIp\s*:\s*.*/  bindIp: 127.0.0.1/' /etc/mongod.conf || true
  else
    awk '1; END{print "net:\n  bindIp: 127.0.0.1"}' /etc/mongod.conf > /etc/mongod.conf.new && mv /etc/mongod.conf.new /etc/mongod.conf
  fi
fi
systemctl enable --now mongod

# ---------------------- Omada package fetch ----------------------
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/125 Safari/537.36"
DEB_PATH=""
DEB_URL=""

resolve_omada_url() {
  local patt base page
  case "$ARCH" in
    amd64) patt='(linux_(x64|amd64|x86_64))' ;;
    arm64) patt='(linux_(arm64|aarch64))' ;;
    *)     die "Неподдерживаемая архитектура: $ARCH (нужны amd64/arm64)" ;;
  esac

  base="https://support.omadanetworks.com/us/product/omada-software-controller/?resourceType=download"
  page="$(mktemp)"
  curl -fsSL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 40 \
       --compressed -A "$UA" "$base" -o "$page"

  mapfile -t urls < <(
    grep -oP '<a[^>]+href="\K[^"]+\.deb' "$page" \
    | grep -Ei "$patt" \
    | grep -Eiv '(beta|rc)' \
    | awk '{u=$0; if(u !~ /^https?:\/\//) u="https://support.omadanetworks.com"u; print u}' \
    | sort -u
  )
  [[ ${#urls[@]} -gt 0 ]] || die "Не нашёл подходящий .deb на странице загрузок для $ARCH"

  local best
  best="$(
    printf '%s\n' "${urls[@]}" \
    | awk -F/ '{
        u=$0; f=$NF; ver="0.0.0";
        if (match(f, /[0-9]+(\.[0-9]+){1,3}/)) ver=substr(f,RSTART,RLENGTH);
        print ver " " u
      }' \
    | sort -V | tail -n1 | awk '{print $2}'
  )"

  [[ "$best" =~ ^https://(support\.)?omadanetworks\.com/ ]] || die "Подозрительный домен ссылки: $best"
  curl -fsSI -A "$UA" "$best" | grep -qE '^HTTP/.* 200' || die "HEAD не вернул 200 для $best"
  echo "$best"
}

if [[ -n "$OMADA_URL" ]]; then
  info "Использую заданный URL Omada"
  [[ "$OMADA_URL" =~ ^https?:// ]] || die "Некорректный URL: $OMADA_URL"
  DEB_URL="$OMADA_URL"
else
  log "Парсю страницу загрузок Omada для поиска последней стабильной версии"
  DEB_URL="$(resolve_omada_url)"
fi

log "Скачиваю Omada пакет"
DEB_PATH="/tmp/$(basename "$DEB_URL")"
curl -fL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 600 \
     --compressed -A "$UA" -o "$DEB_PATH" "$DEB_URL"
info "Сохранено: $DEB_PATH"

if [[ -n "$OMADA_SHA" ]]; then
  log "Проверяю SHA256"
  DOWN_SHA="$(sha256sum "$DEB_PATH" | awk '{print $1}')"
  [[ "$DOWN_SHA" == "$OMADA_SHA" ]] || die "Несовпадение SHA256 (ожидалось $OMADA_SHA, получено $DOWN_SHA)"
else
  warn "SHA256 не задан — продолжаю без проверки целостности (рекомендуется указать --omada-sha256)"
fi

# ---------------------- install Omada ----------------------
log "Устанавливаю Omada (.deb) через apt (корректно обрабатывает зависимости)"
apt-get install -y "$DEB_PATH"

# Автозапуск сервиса, если он есть
if systemctl list-unit-files | grep -qi 'omada.*service'; then
  svc="$(systemctl list-unit-files | awk '/omada.*service/ {print $1; exit}')"
  systemctl enable --now "$svc"
fi

# ---------------------- optional firewall ----------------------
if [[ -n "$UFW_CIDR" ]]; then
  if command -v ufw >/dev/null 2>&1; then
    log "UFW: разрешаю 8043 из $UFW_CIDR"
    ufw allow from "$UFW_CIDR" to any port 8043 proto tcp || warn "Не удалось добавить правило UFW"
  else
    warn "UFW не установлен. Чтобы ограничить доступ: apt-get install ufw && ufw allow from $UFW_CIDR to any port 8043 proto tcp"
  fi
fi

# ---------------------- result ----------------------
IP="$(hostname -I | awk '{print $1}')"
echo
printf "\033[0;32m[✓]\033[0m Omada установлена.\n"
printf "\033[0;32m[→]\033[0m Откройте: https://%s:8043  (самоподписанный сертификат)\n" "$IP"
printf "\033[0;32m[ℹ]\033[0m Ограничьте доступ к порту 8043 только из доверенной сети.\n"
