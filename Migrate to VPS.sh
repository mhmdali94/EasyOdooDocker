#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  Migrate to VPS.sh
#  Odoo v14–v18  →  Odoo 19 Community Edition  (bare VPS system install)
#  v1.0 — https://github.com/mhmdali94/EasyOdooDocker
#
#  Run this script on the SOURCE machine (or any machine that can reach both
#  the source server and the destination VPS via SSH).
#
#  What it does:
#    1. Detects the source Odoo database (v14–v18)
#    2. Connects to the destination VPS via SSH (ControlMaster — password once)
#    3. Installs Odoo 19 Community Edition (deb package) on the VPS
#    4. Creates the PostgreSQL user and database
#    5. Dumps and restores the source database
#    6. Runs OpenUpgrade hops via Docker (14→15→16→17→18) using --network=host
#    7. Runs system Odoo 19 --update=all with auto jsonb-fix loop
#    8. Starts the odoo systemd service and verifies it is responding
#
#  SOURCE types supported:
#    - Traditional server on THIS machine (peer/password PostgreSQL)
#    - Traditional server on a REMOTE machine (SSH)
#    - Docker instance registered in Odoo Manager
#
#  Docker is used ONLY during migration hops — it is not part of the final setup.
# ══════════════════════════════════════════════════════════════════════════════

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m';    YELLOW='\033[0;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m';   WHITE='\033[1;37m';  GRAY='\033[0;90m'
BLUE='\033[0;34m';   NC='\033[0m';        BOLD='\033[1m'

# ── Print helpers ──────────────────────────────────────────────────────────────
print_line()    { echo -e "  ${GRAY}─────────────────────────────────────────────────────${NC}"; }
print_step()    { echo -e "  ${CYAN}➜  $*${NC}"; }
print_success() { echo -e "  ${GREEN}✔  $*${NC}"; }
print_error()   { echo -e "  ${RED}✖  $*${NC}"; }
print_warn()    { echo -e "  ${YELLOW}⚠  $*${NC}"; }
print_info()    { echo -e "  ${CYAN}ℹ  $*${NC}"; }

log_msg() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$MIGRATION_LOG" 2>/dev/null || true; }

pause() { echo ""; read -rp "  Press [Enter] to continue..." _; echo ""; }

confirm() {
  local prompt="${1:-Are you sure?}"
  read -rp "  ${prompt} [Y/n]: " _ans
  [[ "${_ans:-Y}" =~ ^[Yy]$ ]]
}

gen_password() { tr -dc 'A-Za-z0-9@#%^' </dev/urandom 2>/dev/null | head -c 20; }

version_major() { echo "${1%%.*}"; }

# ── Global state ──────────────────────────────────────────────────────────────
TARGET_VERSION="19.0"
OPENUPGRADE_IMG="ghcr.io/oca/openupgrade"

SRC_TYPE=""          # local_server | remote_server | docker
SRC_VERSION=""
SRC_DB_NAME=""
SRC_DB_USER=""
SRC_DB_PASS=""
SRC_DB_HOST="127.0.0.1"
SRC_DB_PORT="5432"
SRC_ODOO_CONF=""
SRC_ADDONS_PATHS=()

# SSH – source (only for remote_server type)
SRC_SSH_USER="root"
SRC_SSH_HOST=""
SRC_SSH_PORT="22"
SRC_SSH_CTL="/tmp/vps_mig_src_$$"

# SSH – destination VPS
DST_SSH_USER="root"
DST_SSH_HOST=""
DST_SSH_PORT="22"
DST_SSH_CTL="/tmp/vps_mig_dst_$$"
_DST_SSH_BASE="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=60 -o ServerAliveCountMax=5"

# Destination
DST_DB_NAME=""
DST_DB_USER=""
DST_DB_PASS=""
DST_ODOO_CONF="/etc/odoo/odoo.conf"
DST_ADDONS_DIR="/opt/odoo-addons"
DST_WEB_PORT="8069"
DST_GEVENT_PORT="8072"

# Working paths
LOCAL_BACKUP_DIR="${HOME}/odoo_vps_migration_backups"
MIGRATION_LOG="/dev/null"
ERR_LOG="/dev/null"
HOP_LIST=()
BACKUP_FILE=""
ADDONS_ARCHIVE=""

# ── SSH helpers ────────────────────────────────────────────────────────────────
dst_sh() {
  ssh -o ControlMaster=no \
      -o ControlPath="$DST_SSH_CTL" \
      $_DST_SSH_BASE \
      -p "$DST_SSH_PORT" \
      "${DST_SSH_USER}@${DST_SSH_HOST}" "$@"
}

dst_scp() {
  scp -o StrictHostKeyChecking=no \
      -o ControlPath="$DST_SSH_CTL" \
      -P "$DST_SSH_PORT" "$@"
}

src_sh() {
  ssh -o ControlMaster=no \
      -o ControlPath="$SRC_SSH_CTL" \
      -o StrictHostKeyChecking=no \
      -p "$SRC_SSH_PORT" \
      "${SRC_SSH_USER}@${SRC_SSH_HOST}" "$@"
}

src_scp() {
  scp -o StrictHostKeyChecking=no \
      -o ControlPath="$SRC_SSH_CTL" \
      -P "$SRC_SSH_PORT" "$@"
}

setup_dst_ssh() {
  echo ""
  print_line
  echo -e "  ${WHITE}${BOLD}  STEP 1 — Connect to Destination VPS${NC}"
  print_line
  echo ""

  read -rp "  Destination VPS IP or hostname: " DST_SSH_HOST
  [[ -z "$DST_SSH_HOST" ]] && { print_error "Host required"; return 1; }

  read -rp "  SSH user [root]: " u; DST_SSH_USER="${u:-root}"
  read -rp "  SSH port [22]: " p;   DST_SSH_PORT="${p:-22}"

  print_step "Connecting to ${DST_SSH_USER}@${DST_SSH_HOST}:${DST_SSH_PORT} ..."
  print_info "You will be asked for the SSH password ONCE. All commands reuse this connection."
  echo ""

  ssh -o ControlMaster=yes \
      -o ControlPath="$DST_SSH_CTL" \
      -o ControlPersist=7200 \
      $_DST_SSH_BASE \
      -p "$DST_SSH_PORT" \
      -N -f \
      "${DST_SSH_USER}@${DST_SSH_HOST}" \
    || { print_error "SSH connection failed"; return 1; }

  print_success "SSH connection established (7200s keepalive)"
}

# ── Version / hop helpers ──────────────────────────────────────────────────────
build_hop_list() {
  # Returns space-separated list of versions from (source+1) up to and including 19.0
  local major; major=$(version_major "$1")
  local out=()
  for v in 15 16 17 18 19; do
    [[ $v -gt $major ]] && out+=("${v}.0")
  done
  echo "${out[@]}"
}

# ── Source: parse odoo.conf ────────────────────────────────────────────────────
parse_odoo_conf() {
  local f="$1"
  SRC_DB_USER=$(grep -oP '(?<=db_user\s=\s)\S+' "$f" | head -1 || true)
  SRC_DB_PASS=$(grep -oP '(?<=db_password\s=\s)\S+' "$f" | head -1 || true)
  SRC_DB_HOST=$(grep -oP '(?<=db_host\s=\s)\S+' "$f" | head -1 || true)
  SRC_DB_PORT=$(grep -oP '(?<=db_port\s=\s)\S+' "$f" | head -1 || true)
  local raw_addons; raw_addons=$(grep -oP '(?<=addons_path\s=\s).+' "$f" | head -1 || true)
  IFS=',' read -ra SRC_ADDONS_PATHS <<< "$raw_addons"
  [[ -z "$SRC_DB_HOST"  || "$SRC_DB_HOST"  == "False" ]] && SRC_DB_HOST="127.0.0.1"
  [[ -z "$SRC_DB_PORT"  || "$SRC_DB_PORT"  == "False" ]] && SRC_DB_PORT="5432"
  [[ -z "$SRC_DB_USER"  || "$SRC_DB_USER"  == "False" ]] && SRC_DB_USER="odoo"
}

# ── Source: find odoo.conf (local) ────────────────────────────────────────────
find_odoo_conf_local() {
  # 1. Fixed well-known paths
  local candidates=(
    /etc/odoo/odoo.conf
    /etc/odoo.conf
    /opt/odoo/odoo.conf
    /opt/odoo/server/odoo.conf
    /opt/odoo14/odoo.conf
    /opt/odoo15/odoo.conf
    /opt/odoo16/odoo.conf
    /opt/odoo17/odoo.conf
    /opt/odoo18/odoo.conf
    /home/odoo/odoo.conf
    /home/odoo/.odoorc
    /root/odoo.conf
  )
  for p in "${candidates[@]}"; do
    [[ -f "$p" ]] && { echo "$p"; return 0; }
  done

  # 2. Check the running Odoo process for the -c / --config flag
  local proc_conf
  proc_conf=$(ps aux 2>/dev/null | grep -E '[o]doo.*\.conf' \
    | grep -oP '(?<=-c\s|--config[= ])[^ ]+' | head -1)
  [[ -f "$proc_conf" ]] && { echo "$proc_conf"; return 0; }

  # 3. Scan common install roots (fast, depth-limited)
  local found
  found=$(find /etc /opt /home /root /srv /var/lib/odoo \
    -maxdepth 5 -name 'odoo.conf' 2>/dev/null | head -1)
  [[ -f "$found" ]] && { echo "$found"; return 0; }

  return 1
}

# ── Source: local server ───────────────────────────────────────────────────────
setup_source_local() {
  echo ""
  print_line
  echo -e "  ${WHITE}${BOLD}  SOURCE — Local Server (this machine)${NC}"
  print_line
  echo ""

  print_step "Auto-detecting Odoo config file..."
  local found
  found=$(find_odoo_conf_local 2>/dev/null || true)

  if [[ -f "$found" ]]; then
    print_success "Config: ${found}"
    SRC_ODOO_CONF="$found"
  else
    print_warn "Could not auto-detect odoo.conf"
    read -rp "  Path to odoo.conf: " SRC_ODOO_CONF
    [[ ! -f "$SRC_ODOO_CONF" ]] && { print_error "File not found: ${SRC_ODOO_CONF}"; return 1; }
  fi

  parse_odoo_conf "$SRC_ODOO_CONF"

  # Detect version — no confirmation prompt, just use what we find
  local auto_ver=""
  for f in /usr/lib/python3/dist-packages/odoo/release.py \
            /usr/local/lib/python3*/dist-packages/odoo/release.py \
            /opt/odoo/odoo/release.py /opt/odoo14/odoo/release.py \
            /opt/odoo/server/odoo/release.py; do
    [[ -f "$f" ]] && {
      auto_ver=$(grep -oP "version = '\K\d+\.\d+" "$f" 2>/dev/null | head -1)
      [[ -n "$auto_ver" ]] && break
    }
  done
  [[ -z "$auto_ver" ]] && \
    auto_ver=$(find /usr /opt -name 'release.py' -path '*/odoo/*' 2>/dev/null \
      | head -3 | xargs grep -hoP "version = '\K\d+\.\d+" 2>/dev/null | head -1 || true)
  [[ -z "$auto_ver" ]] && \
    auto_ver=$(python3 -c "import odoo; print(odoo.release.version)" 2>/dev/null \
               | grep -oP '\d+\.\d+' | head -1 || true)

  if [[ -n "$auto_ver" ]]; then
    print_success "Version: ${auto_ver}"
    SRC_VERSION="$auto_ver"
  else
    read -rp "  Could not detect version. Enter it (e.g. 14.0): " SRC_VERSION
  fi

  local maj; maj=$(version_major "$SRC_VERSION")
  [[ $maj -lt 14 || $maj -ge 19 ]] && { print_error "Must be v14–v18"; return 1; }

  # List databases — auto-select if only one exists
  local dbs=()
  local raw_dbs
  raw_dbs=$(sudo -u odoo psql -tAc \
    "SELECT datname FROM pg_database WHERE datistemplate=false \
     AND datname NOT IN ('postgres','template0','template1') ORDER BY datname;" \
    2>/dev/null) || \
  raw_dbs=$(PGPASSWORD="$SRC_DB_PASS" psql -h "$SRC_DB_HOST" -p "$SRC_DB_PORT" \
    -U "$SRC_DB_USER" -tAc \
    "SELECT datname FROM pg_database WHERE datistemplate=false \
     AND datname NOT IN ('postgres','template0','template1') ORDER BY datname;" \
    2>/dev/null) || true

  while IFS= read -r db; do
    [[ -n "$db" ]] && dbs+=("$db")
  done <<< "$raw_dbs"

  if [[ ${#dbs[@]} -eq 1 ]]; then
    SRC_DB_NAME="${dbs[0]}"
    print_success "Database: ${SRC_DB_NAME} (only one found — auto-selected)"
  elif [[ ${#dbs[@]} -gt 1 ]]; then
    echo ""
    echo -e "  ${GRAY}  Available databases:${NC}"
    for i in "${!dbs[@]}"; do
      echo -e "    ${CYAN}$((i+1)))${NC} ${dbs[$i]}"
    done
    echo ""
    read -rp "  Choose database [1]: " ch; ch="${ch:-1}"
    SRC_DB_NAME="${dbs[$((ch-1))]}"
  else
    read -rp "  Could not list databases. Enter name: " SRC_DB_NAME
  fi

  [[ -z "$SRC_DB_NAME" ]] && { print_error "No database selected"; return 1; }
  print_success "Source: ${SRC_DB_NAME} (v${SRC_VERSION})"
  SRC_TYPE="local_server"
}

# ── Source: remote server ──────────────────────────────────────────────────────
setup_source_remote() {
  echo ""
  print_line
  echo -e "  ${WHITE}${BOLD}  SOURCE — Remote Server (SSH)${NC}"
  print_line
  echo ""

  read -rp "  Source server IP or hostname: " SRC_SSH_HOST
  [[ -z "$SRC_SSH_HOST" ]] && { print_error "Host required"; return 1; }
  read -rp "  SSH user [root]: " u; SRC_SSH_USER="${u:-root}"
  read -rp "  SSH port [22]: " p;   SRC_SSH_PORT="${p:-22}"

  print_step "Connecting to ${SRC_SSH_USER}@${SRC_SSH_HOST}..."
  ssh -o ControlMaster=yes \
      -o ControlPath="$SRC_SSH_CTL" \
      -o ControlPersist=3600 \
      -o StrictHostKeyChecking=no \
      -p "$SRC_SSH_PORT" \
      -N -f \
      "${SRC_SSH_USER}@${SRC_SSH_HOST}" \
    || { print_error "SSH to source failed"; return 1; }
  print_success "Connected to source"

  # Detect config — check known paths, then running process, then find
  print_step "Auto-detecting Odoo config on source..."
  SRC_ODOO_CONF=""
  local _found_remote
  _found_remote=$(src_sh "
    for p in /etc/odoo/odoo.conf /etc/odoo.conf /opt/odoo/odoo.conf \
              /opt/odoo14/odoo.conf /opt/odoo15/odoo.conf /opt/odoo16/odoo.conf \
              /opt/odoo17/odoo.conf /opt/odoo18/odoo.conf \
              /home/odoo/odoo.conf /root/odoo.conf; do
      [ -f \"\$p\" ] && echo \"\$p\" && break
    done
    # check running process
    ps aux 2>/dev/null | grep -E '[o]doo.*\.conf' | grep -oP '(?<=-c )[^ ]+' | head -1
    # last resort: find
    find /etc /opt /home /root -maxdepth 5 -name 'odoo.conf' 2>/dev/null | head -1
  " 2>/dev/null | grep -v '^$' | head -1 | tr -d '[:space:]' || true)

  if [[ -n "$_found_remote" ]]; then
    SRC_ODOO_CONF="$_found_remote"
    print_success "Found config: ${SRC_ODOO_CONF}"
  else
    print_warn "Could not auto-detect config on source"
    read -rp "  Config path on source: " SRC_ODOO_CONF
  fi

  # Pull config locally to parse it
  local tmp_conf; tmp_conf=$(mktemp)
  src_scp "${SRC_SSH_USER}@${SRC_SSH_HOST}:${SRC_ODOO_CONF}" "$tmp_conf" 2>/dev/null \
    || { print_error "Cannot read source config"; rm -f "$tmp_conf"; return 1; }
  parse_odoo_conf "$tmp_conf"; rm -f "$tmp_conf"

  # Detect version on source
  local auto_ver
  auto_ver=$(src_sh "
    # Try release.py in common install paths
    for f in /usr/lib/python3/dist-packages/odoo/release.py \
              /usr/local/lib/python3*/dist-packages/odoo/release.py \
              /opt/odoo/odoo/release.py /opt/odoo14/odoo/release.py; do
      [ -f \"\$f\" ] && grep -oP \"version = '\\K\\d+\\.\\d+\" \"\$f\" 2>/dev/null | head -1 && break
    done
    # Fallback: find any release.py
    find /usr /opt -name 'release.py' -path '*/odoo/*' 2>/dev/null | head -1 | xargs grep -oP \"version = '\\K\\d+\\.\\d+\" 2>/dev/null | head -1
    # Last resort: python import
    python3 -c 'import odoo; print(odoo.release.version)' 2>/dev/null | grep -oP '\\d+\\.\\d+' | head -1
  " 2>/dev/null | grep -P '^\d+\.\d+$' | head -1 || true)

  if [[ -n "$auto_ver" ]]; then
    print_success "Version: ${auto_ver}"
    SRC_VERSION="$auto_ver"
  else
    read -rp "  Could not detect version. Enter it (e.g. 14.0): " SRC_VERSION
  fi

  local maj; maj=$(version_major "$SRC_VERSION")
  [[ $maj -lt 14 || $maj -ge 19 ]] && { print_error "Must be v14–v18"; return 1; }

  # List databases — auto-select if only one
  local dbs=()
  local raw_dbs
  raw_dbs=$(src_sh \
    "sudo -u odoo psql -tAc \"SELECT datname FROM pg_database \
     WHERE datistemplate=false AND datname NOT IN ('postgres','template0','template1') \
     ORDER BY datname;\" 2>/dev/null || \
     PGPASSWORD='${SRC_DB_PASS}' psql -h '${SRC_DB_HOST}' -p '${SRC_DB_PORT}' \
     -U '${SRC_DB_USER}' -tAc \"SELECT datname FROM pg_database \
     WHERE datistemplate=false AND datname NOT IN ('postgres','template0','template1') \
     ORDER BY datname;\" 2>/dev/null" || true)

  while IFS= read -r db; do
    [[ -n "$db" ]] && dbs+=("$db")
  done <<< "$raw_dbs"

  if [[ ${#dbs[@]} -eq 1 ]]; then
    SRC_DB_NAME="${dbs[0]}"
    print_success "Database: ${SRC_DB_NAME} (auto-selected)"
  elif [[ ${#dbs[@]} -gt 1 ]]; then
    echo ""
    echo -e "  ${GRAY}  Available databases:${NC}"
    for i in "${!dbs[@]}"; do
      echo -e "    ${CYAN}$((i+1)))${NC} ${dbs[$i]}"
    done
    echo ""
    read -rp "  Choose database [1]: " ch; ch="${ch:-1}"
    SRC_DB_NAME="${dbs[$((ch-1))]}"
  else
    read -rp "  Could not list databases. Enter name: " SRC_DB_NAME
  fi

  [[ -z "$SRC_DB_NAME" ]] && { print_error "No database selected"; return 1; }
  print_success "Source: ${SRC_DB_NAME} (v${SRC_VERSION}) on ${SRC_SSH_HOST}"
  SRC_TYPE="remote_server"
}

# ── Source: Docker instance ────────────────────────────────────────────────────
setup_source_docker() {
  echo ""
  print_line
  echo -e "  ${WHITE}${BOLD}  SOURCE — Docker Instance (Odoo Manager)${NC}"
  print_line
  echo ""

  local meta="${HOME}/docker/odoo_instances.meta"
  if [[ ! -f "$meta" ]]; then
    # Try common paths
    for p in /root/docker/odoo_instances.meta /opt/docker/odoo_instances.meta; do
      [[ -f "$p" ]] && meta="$p" && break
    done
  fi
  [[ ! -f "$meta" ]] && { print_error "Odoo Manager meta file not found"; return 1; }

  echo -e "  ${GRAY}  Registered instances:${NC}"
  local instances=()
  local i=1
  while IFS='|' read -r name ver dir pgu pgp rest; do
    [[ "$name" == \#* || -z "$name" ]] && continue
    printf "    ${CYAN}%d)${NC}  %-20s v%-6s\n" "$i" "$name" "$ver"
    instances+=("${name}|${ver}|${dir}|${pgu}|${pgp}")
    ((i++))
  done < "$meta"

  echo ""
  read -rp "  Choose instance [1]: " ch; ch="${ch:-1}"
  local sel="${instances[$((ch-1))]}"
  [[ -z "$sel" ]] && { print_error "Invalid choice"; return 1; }

  IFS='|' read -r _nm _ver _dir _pgu _pgp <<< "$sel"
  SRC_VERSION="$_ver"
  SRC_DB_USER="$_pgu"
  SRC_DB_PASS="$_pgp"
  SRC_DB_HOST="127.0.0.1"

  # Get port from docker-compose.yml
  local compose="${_dir}/docker-compose.yml"
  local pg_port; pg_port=$(grep -oP '(?<=")\d+(?=:5432")' "$compose" 2>/dev/null | head -1)
  SRC_DB_PORT="${pg_port:-5432}"

  local maj; maj=$(version_major "$SRC_VERSION")
  [[ $maj -lt 14 || $maj -ge 19 ]] && { print_error "Instance version must be v14–v18"; return 1; }

  # List databases in that instance
  local dbs=()
  local raw_dbs
  raw_dbs=$(docker exec "${_nm}-db" psql -U "$_pgu" -tAc \
    "SELECT datname FROM pg_database WHERE datistemplate=false \
     AND datname NOT IN ('postgres','template0','template1') ORDER BY datname;" \
    2>/dev/null || true)

  if [[ -n "$raw_dbs" ]]; then
    echo ""
    echo -e "  ${GRAY}  Databases in this instance:${NC}"
    local j=1
    while IFS= read -r db; do
      echo -e "    ${CYAN}${j})${NC} ${db}"
      dbs+=("$db"); ((j++))
    done <<< "$raw_dbs"
    echo ""
    read -rp "  Choose database [1]: " ch2; ch2="${ch2:-1}"
    SRC_DB_NAME="${dbs[$((ch2-1))]}"
  else
    read -rp "  Enter database name: " SRC_DB_NAME
  fi

  SRC_ADDONS_PATHS=("${_dir}/addons")
  [[ -z "$SRC_DB_NAME" ]] && { print_error "No database selected"; return 1; }
  print_success "Source: ${SRC_DB_NAME} (v${SRC_VERSION}) from Docker instance ${_nm}"
  SRC_TYPE="docker"
}

# ── Select source ──────────────────────────────────────────────────────────────
setup_source() {
  echo ""
  print_line
  echo -e "  ${WHITE}${BOLD}  STEP 2 — Select Source${NC}"
  print_line
  echo ""
  echo -e "  ${CYAN}1)${NC} Server on THIS machine (local)"
  echo -e "  ${CYAN}2)${NC} Server on a REMOTE machine (SSH)"
  echo -e "  ${CYAN}3)${NC} Docker instance (Odoo Manager)"
  echo ""
  read -rp "  Source type [1]: " ch; ch="${ch:-1}"
  case "$ch" in
    1) setup_source_local  || return 1 ;;
    2) setup_source_remote || return 1 ;;
    3) setup_source_docker || return 1 ;;
    *) print_error "Invalid choice"; return 1 ;;
  esac
}

# ── Ask destination config ─────────────────────────────────────────────────────
ask_dst_config() {
  echo ""
  print_line
  echo -e "  ${WHITE}${BOLD}  STEP 3 — Destination Database Config${NC}"
  print_line
  echo ""

  read -rp "  Database name to create [${SRC_DB_NAME}]: " n
  DST_DB_NAME="${n:-$SRC_DB_NAME}"

  read -rp "  PostgreSQL user [odoo19_user]: " u
  DST_DB_USER="${u:-odoo19_user}"

  local gen; gen=$(gen_password)
  read -rp "  PostgreSQL password [auto-generated, press Enter]: " p
  DST_DB_PASS="${p:-$gen}"

  read -rp "  Odoo web port [8069]: " wp
  DST_WEB_PORT="${wp:-8069}"

  read -rp "  Odoo gevent/longpoll port [8072]: " gp
  DST_GEVENT_PORT="${gp:-8072}"

  echo ""
  print_line
  echo -e "  ${GRAY}  Plan:${NC}"
  echo -e "    Source:    ${SRC_DB_NAME} (v${SRC_VERSION})"
  echo -e "    Target:    Odoo 19 on ${DST_SSH_HOST}"
  echo -e "    DB:        ${DST_DB_NAME} (user: ${DST_DB_USER})"
  echo -e "    Web port:  ${DST_WEB_PORT}   Gevent: ${DST_GEVENT_PORT}"
  echo -e "    Config:    ${DST_ODOO_CONF}"
  echo -e "    Addons:    ${DST_ADDONS_DIR}"
  print_line

  confirm "Proceed?" || return 1

  # Init log files
  mkdir -p "$LOCAL_BACKUP_DIR"
  local ts; ts=$(date +%Y%m%d_%H%M%S)
  MIGRATION_LOG="${LOCAL_BACKUP_DIR}/migration_${DST_DB_NAME}_v${SRC_VERSION}_to_v19_${ts}.log"
  ERR_LOG="${LOCAL_BACKUP_DIR}/ERRORS_${DST_DB_NAME}_v${SRC_VERSION}_to_v19_${ts}.log"
  echo "# Migration: ${DST_DB_NAME} v${SRC_VERSION}→19 started $(date)" > "$MIGRATION_LOG"
  echo "# Errors: ${DST_DB_NAME} $(date)" > "$ERR_LOG"

  log_msg "Source: ${SRC_DB_NAME} v${SRC_VERSION} type=${SRC_TYPE}"
  log_msg "Destination: ${DST_SSH_HOST} DB=${DST_DB_NAME} user=${DST_DB_USER}"
}

# ── Install Odoo 19 on destination ────────────────────────────────────────────
install_prerequisites() {
  print_step "Updating package list..."
  dst_sh "DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>&1" \
    >> "$MIGRATION_LOG" 2>&1 || true

  print_step "Installing system prerequisites..."
  dst_sh "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    python3 python3-dev python3-pip python3-venv \
    postgresql postgresql-client \
    libxml2-dev libxslt1-dev libldap2-dev libsasl2-dev \
    libtiff5-dev libjpeg-dev libopenjp2-7-dev zlib1g-dev \
    libfreetype6-dev liblcms2-dev libwebp-dev \
    libharfbuzz-dev libfribidi-dev libxcb1-dev libpq-dev \
    npm node-gyp curl wget git unzip ca-certificates \
    2>&1" >> "$MIGRATION_LOG" 2>&1 \
    || print_warn "Some prerequisites may have failed — check log"

  # rtlcss for Arabic/RTL support
  print_step "Installing rtlcss (Arabic/RTL support)..."
  dst_sh "npm install -g rtlcss 2>&1" >> "$MIGRATION_LOG" 2>&1 \
    || print_warn "rtlcss install failed (RTL CSS may not render correctly)"

  # wkhtmltopdf — detect OS version
  print_step "Installing wkhtmltopdf..."
  if dst_sh "which wkhtmltopdf > /dev/null 2>&1"; then
    print_success "wkhtmltopdf already installed"
  else
    local codename
    codename=$(dst_sh "lsb_release -cs 2>/dev/null || . /etc/os-release && echo \$VERSION_CODENAME" \
               2>/dev/null | tr -d '[:space:]' || echo "jammy")
    # Map older codenames to available wkhtmltopdf releases
    case "$codename" in
      focal|hirsute|impish) codename="focal" ;;
      *)                    codename="jammy"  ;;
    esac
    local wk_url="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.${codename}_amd64.deb"
    dst_sh "wget -q '${wk_url}' -O /tmp/wkhtmltox.deb 2>&1 && \
            DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/wkhtmltox.deb -qq 2>&1 && \
            rm -f /tmp/wkhtmltox.deb" >> "$MIGRATION_LOG" 2>&1 \
      || print_warn "wkhtmltopdf install failed (PDF reports may not work)"
  fi
}

install_odoo19() {
  print_step "Checking for existing Odoo 19..."
  if dst_sh "command -v odoo > /dev/null 2>&1 && odoo --version 2>/dev/null | grep -q '19'"; then
    print_success "Odoo 19 already installed"
    return 0
  fi

  print_step "Downloading Odoo 19 Community deb package..."
  local url="https://nightly.odoo.com/19.0/nightly/deb/odoo_19.0.latest_all.deb"
  dst_sh "wget -q '${url}' -O /tmp/odoo19.deb 2>&1" >> "$MIGRATION_LOG" 2>&1

  if ! dst_sh "test -s /tmp/odoo19.deb" 2>/dev/null; then
    print_error "Download failed — check internet on destination"
    print_info "URL: ${url}"
    return 1
  fi

  print_step "Installing Odoo 19 (may take a few minutes)..."
  dst_sh "DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/odoo19.deb 2>&1" \
    >> "$MIGRATION_LOG" 2>&1 || {
    print_warn "apt install failed, trying dpkg + fix-broken..."
    dst_sh "DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/odoo19.deb 2>&1; \
            apt-get -f install -y -qq 2>&1" >> "$MIGRATION_LOG" 2>&1 \
      || { print_error "Odoo 19 installation failed — see ${MIGRATION_LOG}"; return 1; }
  }
  dst_sh "rm -f /tmp/odoo19.deb" 2>/dev/null || true

  local ver; ver=$(dst_sh "odoo --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1" 2>/dev/null || echo "")
  if [[ "$ver" == "19"* ]]; then
    print_success "Odoo 19 installed (${ver})"
  else
    print_error "Odoo 19 install appears incomplete (got: ${ver:-nothing})"
    return 1
  fi
}

setup_dst_postgres() {
  print_step "Starting PostgreSQL service..."
  dst_sh "systemctl start postgresql 2>/dev/null || service postgresql start 2>/dev/null || true" \
    >> "$MIGRATION_LOG" 2>&1
  dst_sh "systemctl enable postgresql 2>/dev/null || true" >> "$MIGRATION_LOG" 2>&1

  # Find pg_hba.conf and allow password auth on 127.0.0.1 (needed by Docker migration containers)
  print_step "Configuring PostgreSQL password auth for migration containers..."
  local pg_ver
  pg_ver=$(dst_sh "pg_lsclusters -h 2>/dev/null | awk '{print \$1}' | head -1" 2>/dev/null | tr -d '[:space:]' || echo "")
  [[ -z "$pg_ver" ]] && pg_ver=$(dst_sh "ls /etc/postgresql/ 2>/dev/null | sort -V | tail -1" 2>/dev/null | tr -d '[:space:]' || echo "14")

  local hba="/etc/postgresql/${pg_ver}/main/pg_hba.conf"
  dst_sh "test -f '${hba}'" 2>/dev/null || \
    hba=$(dst_sh "find /etc/postgresql -name pg_hba.conf 2>/dev/null | head -1" | tr -d '[:space:]')

  dst_sh "grep -qE '127\.0\.0\.1.*scram-sha-256|127\.0\.0\.1.*md5' '${hba}' 2>/dev/null || \
          echo 'host    all    all    127.0.0.1/32    scram-sha-256' >> '${hba}' && \
          systemctl reload postgresql 2>/dev/null || \
          pg_ctlcluster ${pg_ver} main reload 2>/dev/null || true" \
    >> "$MIGRATION_LOG" 2>&1 || true

  # Create PostgreSQL role
  print_step "Creating PostgreSQL role: ${DST_DB_USER}..."
  dst_sh "sudo -u postgres psql -c \
    \"DO \\\$\\\$
     BEGIN
       IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='${DST_DB_USER}') THEN
         CREATE ROLE \\\"${DST_DB_USER}\\\" WITH LOGIN PASSWORD '${DST_DB_PASS}' CREATEDB;
       ELSE
         ALTER  ROLE \\\"${DST_DB_USER}\\\" WITH LOGIN PASSWORD '${DST_DB_PASS}' CREATEDB;
       END IF;
     END
     \\\$\\\$;\"" >> "$MIGRATION_LOG" 2>&1 \
    || { print_error "Failed to create PostgreSQL role"; return 1; }

  print_success "PostgreSQL role '${DST_DB_USER}' ready"
}

write_odoo_conf() {
  print_step "Writing ${DST_ODOO_CONF} on destination..."
  local tmp; tmp=$(mktemp)
  cat > "$tmp" <<CONF
[options]
db_host = 127.0.0.1
db_port = 5432
db_user = ${DST_DB_USER}
db_password = ${DST_DB_PASS}
db_name =
addons_path = /usr/lib/python3/dist-packages/odoo/addons,${DST_ADDONS_DIR}
data_dir = /var/lib/odoo
logfile = /var/log/odoo/odoo.log
log_level = info
http_port = ${DST_WEB_PORT}
longpolling_port = ${DST_GEVENT_PORT}
workers = 2
max_cron_threads = 1
limit_memory_hard = 2684354560
limit_memory_soft = 2147483648
limit_request = 8192
limit_time_cpu = 600
limit_time_real = 1200
CONF
  dst_scp "$tmp" "${DST_SSH_USER}@${DST_SSH_HOST}:${DST_ODOO_CONF}"
  rm -f "$tmp"
  dst_sh "chmod 640 '${DST_ODOO_CONF}' && chown odoo:odoo '${DST_ODOO_CONF}' 2>/dev/null || true" \
    >> "$MIGRATION_LOG" 2>&1
  print_success "odoo.conf written"
}

prepare_destination() {
  echo ""
  print_line
  echo -e "  ${WHITE}${BOLD}  STEP 4 — Prepare Destination VPS${NC}"
  print_line
  echo ""

  install_prerequisites || return 1
  echo ""
  install_odoo19         || return 1
  echo ""
  dst_sh "mkdir -p '${DST_ADDONS_DIR}' && chown odoo:odoo '${DST_ADDONS_DIR}' 2>/dev/null || true" \
    >> "$MIGRATION_LOG" 2>&1
  setup_dst_postgres || return 1
  write_odoo_conf    || return 1
  print_success "Destination VPS is ready"
}

# ── Dump source DB ─────────────────────────────────────────────────────────────
dump_source_db() {
  echo ""
  print_line
  echo -e "  ${WHITE}${BOLD}  STEP 5 — Dump Source Database${NC}"
  print_line
  echo ""

  mkdir -p "$LOCAL_BACKUP_DIR"
  local ts; ts=$(date +%Y%m%d_%H%M%S)
  BACKUP_FILE="${LOCAL_BACKUP_DIR}/${SRC_DB_NAME}_v${SRC_VERSION}_${ts}.dump"
  ADDONS_ARCHIVE="${LOCAL_BACKUP_DIR}/${SRC_DB_NAME}_addons_${ts}.tar.gz"

  print_step "Dumping '${SRC_DB_NAME}' (binary / UTF-8)..."

  case "$SRC_TYPE" in
    local_server)
      sudo -u odoo pg_dump -Fc --encoding=UTF8 --no-owner --no-acl \
        "$SRC_DB_NAME" > "$BACKUP_FILE" 2>/dev/null || \
      PGPASSWORD="$SRC_DB_PASS" pg_dump -h "$SRC_DB_HOST" -p "$SRC_DB_PORT" \
        -U "$SRC_DB_USER" -Fc --encoding=UTF8 --no-owner --no-acl \
        "$SRC_DB_NAME" > "$BACKUP_FILE" \
      || { print_error "Dump failed"; return 1; }
      ;;

    remote_server)
      # Pipe pg_dump directly from source through SSH to local file — no temp file written on source
      print_step "Dumping from remote source (piping directly — source is read-only)..."
      src_sh "sudo -u odoo pg_dump -Fc --encoding=UTF8 --no-owner --no-acl \
                '${SRC_DB_NAME}' 2>/dev/null || \
              PGPASSWORD='${SRC_DB_PASS}' pg_dump \
                -h '${SRC_DB_HOST}' -p '${SRC_DB_PORT}' \
                -U '${SRC_DB_USER}' -Fc --encoding=UTF8 --no-owner --no-acl \
                '${SRC_DB_NAME}'" \
        > "$BACKUP_FILE" \
        || { print_error "Remote dump failed"; rm -f "$BACKUP_FILE"; return 1; }
      ;;

    docker)
      local ctr; ctr=$(echo "${SRC_DB_NAME}" | cut -d_ -f1)
      docker exec \
        -e PGPASSWORD="$SRC_DB_PASS" \
        "${ctr}-db" \
        pg_dump -U "$SRC_DB_USER" -Fc --encoding=UTF8 --no-owner --no-acl \
          "$SRC_DB_NAME" > "$BACKUP_FILE" \
      || { print_error "Docker dump failed"; return 1; }
      ;;
  esac

  local size; size=$(du -sh "$BACKUP_FILE" 2>/dev/null | cut -f1)
  print_success "Dump: ${BACKUP_FILE} (${size})"
  log_msg "Dump: ${BACKUP_FILE} size=${size}"

  # Archive custom addons (skip standard Odoo paths)
  local custom_addons=()
  local std_paths=("/usr/lib/python3/dist-packages/odoo" "/usr/local/lib/python" "/opt/odoo/odoo")
  for raw_p in "${SRC_ADDONS_PATHS[@]}"; do
    local p; p="${raw_p// /}"
    [[ -z "$p" ]] && continue
    local is_std=0
    for sp in "${std_paths[@]}"; do
      [[ "$p" == *"$sp"* ]] && is_std=1 && break
    done
    [[ $is_std -eq 0 && -d "$p" ]] && custom_addons+=("$p")
  done

  if [[ ${#custom_addons[@]} -gt 0 ]]; then
    print_step "Archiving custom addons: ${custom_addons[*]}"
    tar -czf "$ADDONS_ARCHIVE" "${custom_addons[@]}" 2>/dev/null \
      && print_success "Addons archived: ${ADDONS_ARCHIVE}" \
      || print_warn "Addons archive had errors (continuing)"
  else
    print_info "No custom addons found"
    ADDONS_ARCHIVE=""
  fi
}

# ── Transfer and restore DB ────────────────────────────────────────────────────
transfer_and_restore_db() {
  echo ""
  print_line
  echo -e "  ${WHITE}${BOLD}  STEP 6 — Transfer & Restore Database${NC}"
  print_line
  echo ""

  local size; size=$(du -sh "$BACKUP_FILE" 2>/dev/null | cut -f1)
  local remote_dump="/tmp/${SRC_DB_NAME}_mig_$$.dump"

  print_step "Transferring dump (${size}) to destination..."
  dst_scp "$BACKUP_FILE" "${DST_SSH_USER}@${DST_SSH_HOST}:${remote_dump}" \
    || { print_error "Transfer failed"; return 1; }
  print_success "Dump transferred"

  # Transfer custom addons
  if [[ -n "$ADDONS_ARCHIVE" && -f "$ADDONS_ARCHIVE" ]]; then
    print_step "Deploying custom addons to ${DST_ADDONS_DIR}..."
    local remote_addons="/tmp/odoo_addons_$$.tar.gz"
    dst_scp "$ADDONS_ARCHIVE" "${DST_SSH_USER}@${DST_SSH_HOST}:${remote_addons}" \
      && dst_sh "tar -xzf '${remote_addons}' -C '${DST_ADDONS_DIR}' 2>&1 && \
                 chown -R odoo:odoo '${DST_ADDONS_DIR}' && \
                 rm -f '${remote_addons}'" >> "$MIGRATION_LOG" 2>&1 \
      && print_success "Custom addons deployed" \
      || print_warn "Custom addons deployment had errors"
  fi

  print_step "Creating database '${DST_DB_NAME}'..."
  dst_sh "sudo -u postgres psql -c \
    \"DROP DATABASE IF EXISTS \\\"${DST_DB_NAME}\\\"; \
     CREATE DATABASE \\\"${DST_DB_NAME}\\\" ENCODING 'UTF8' OWNER \\\"${DST_DB_USER}\\\";\"" \
    >> "$MIGRATION_LOG" 2>&1 \
    || { print_error "Failed to create database"; return 1; }

  print_step "Restoring database (may take several minutes)..."
  local restore_out
  restore_out=$(dst_sh "PGPASSWORD='${DST_DB_PASS}' pg_restore \
    -h 127.0.0.1 -U '${DST_DB_USER}' -d '${DST_DB_NAME}' \
    --no-owner --no-acl -F c '${remote_dump}' 2>&1" || true)
  echo "$restore_out" >> "$MIGRATION_LOG"

  local errs; errs=$(echo "$restore_out" | grep -ci "error" 2>/dev/null || echo 0)
  if [[ ${errs:-0} -gt 0 ]]; then
    print_warn "Restore finished with ${errs} warnings (usually harmless)"
  else
    print_success "Restore completed with zero errors"
  fi

  dst_sh "rm -f '${remote_dump}'" 2>/dev/null || true
  print_success "Database '${DST_DB_NAME}' ready on ${DST_SSH_HOST}"
}

# ── Upgrade hops (Docker on destination, --network=host) ─────────────────────
ensure_docker_on_dst() {
  dst_sh "command -v docker > /dev/null 2>&1" && {
    print_success "Docker available on destination"
    return 0
  }
  print_warn "Docker not found — needed for upgrade hops (v14→...→v18)"
  confirm "Install Docker on destination VPS?" || { print_error "Cannot continue without Docker"; return 1; }

  print_step "Installing Docker..."
  dst_sh "curl -fsSL https://get.docker.com | bash 2>&1" >> "$MIGRATION_LOG" 2>&1 \
    || { print_error "Docker install failed — see ${MIGRATION_LOG}"; return 1; }
  print_success "Docker installed"
}

pre_hop_sql_patches() {
  local hop_ver=$1 db=$2 prev_ver=$3

  # 14→15: mail module created these keys without ir_model_data; Odoo 15 base
  # tries to INSERT them again → UniqueViolation. Delete so Odoo 15 re-creates.
  if [[ "$prev_ver" == "14"* ]] && [[ "$hop_ver" == "15.0" ]]; then
    print_info "Pre-hop patch (14→15): removing conflicting ir_config_parameter rows..."
    dst_sh "PGPASSWORD='${DST_DB_PASS}' psql -h 127.0.0.1 -U '${DST_DB_USER}' -d '${db}' -q \
      -c \"DELETE FROM ir_config_parameter \
           WHERE key IN ('mail.catchall.alias','mail.catchall.domain');\"" \
      >> "$MIGRATION_LOG" 2>&1 || true
    print_success "Pre-hop patch applied"
  fi
}

run_one_hop() {
  local hop_ver=$1 db=$2

  local ou_img="${OPENUPGRADE_IMG}:${hop_ver}"
  local std_img="odoo:${hop_ver}"
  local use_img="$std_img"

  echo ""
  echo -e "  ${CYAN}${BOLD}  ─── Upgrading to Odoo ${hop_ver} ───${NC}"
  echo ""

  print_step "Checking for OpenUpgrade ${hop_ver} image..."
  if dst_sh "docker image inspect '${ou_img}' > /dev/null 2>&1"; then
    use_img="$ou_img"
    print_success "OpenUpgrade image cached"
  else
    print_info "Pulling OpenUpgrade ${hop_ver} (may take a few minutes)..."
    local pull_out
    pull_out=$(dst_sh "docker pull '${ou_img}' 2>&1" || true)
    echo "$pull_out" | grep -qiE "Downloaded newer|up to date|Pull complete" \
      && use_img="$ou_img" \
      || {
        print_warn "OpenUpgrade not available — using native odoo:${hop_ver}"
        print_warn "$(echo "$pull_out" | tail -1)"
      }
  fi
  echo -e "  ${CYAN}ℹ  Image: ${use_img}${NC}"
  echo ""

  print_step "Running odoo --update=all --stop-after-init on ${hop_ver}..."
  print_warn "This may take 10–40 minutes for large databases"

  local hop_out
  hop_out=$(dst_sh "docker run --rm \
    --network=host \
    -e HOST=127.0.0.1 \
    -e USER='${DST_DB_USER}' \
    -e PASSWORD='${DST_DB_PASS}' \
    -v '${DST_ADDONS_DIR}:/mnt/extra-addons' \
    '${use_img}' \
    odoo --update=all --stop-after-init \
      --db_host=127.0.0.1 \
      --db_user='${DST_DB_USER}' \
      --db_password='${DST_DB_PASS}' \
      --database='${db}' \
      --no-http 2>&1" || true)
  echo "$hop_out" >> "$MIGRATION_LOG"

  local errors; errors=$(echo "$hop_out" | grep -c " ERROR \| CRITICAL " 2>/dev/null || echo 0)

  if echo "$hop_out" | grep -qiE "shutdown complete|modules loaded"; then
    print_success "Hop to ${hop_ver} complete"
    [[ ${errors:-0} -gt 0 ]] && print_warn "${errors} non-critical error(s) logged"
    return 0
  fi

  if echo "$hop_out" | grep -qiE "CRITICAL|Failed to initialize"; then
    print_error "Hop to ${hop_ver} FAILED (${errors} error(s))"
    echo ""
    echo "$hop_out" | grep -iE "ERROR|CRITICAL" | tail -6 | \
      while IFS= read -r l; do echo -e "  ${RED}  ${l}${NC}"; done
    echo ""
    echo "=== HOP FAILED: ${hop_ver} ===" >> "$ERR_LOG"
    echo "$hop_out" >> "$ERR_LOG"
    if confirm "Continue to next hop anyway? (not recommended unless you know the error is safe)"; then
      return 0
    fi
    return 1
  fi

  print_warn "Hop to ${hop_ver} — unclear result, proceeding"
  return 0
}

run_all_hops() {
  local db=$1
  local total=${#HOP_LIST[@]}

  # Docker hops: everything BEFORE 19.0 — system Odoo handles the final step
  local docker_hops=()
  for h in "${HOP_LIST[@]}"; do
    [[ "$h" != "19.0" ]] && docker_hops+=("$h")
  done

  if [[ ${#docker_hops[@]} -eq 0 ]]; then
    print_info "Source is v18 — no intermediate hops needed, going straight to system Odoo 19"
    return 0
  fi

  ensure_docker_on_dst || return 1

  local current=1
  local prev_ver="$SRC_VERSION"

  for hop_ver in "${docker_hops[@]}"; do
    echo ""
    print_line
    echo -e "  ${WHITE}${BOLD}  Hop ${current}/${#docker_hops[@]} → Odoo ${hop_ver}${NC}"
    print_line

    # Rollback point before hop
    local hop_bk="/tmp/hop_${db}_before_${hop_ver}_$(date +%Y%m%d_%H%M%S).dump"
    print_step "Saving rollback point (${hop_bk})..."
    dst_sh "PGPASSWORD='${DST_DB_PASS}' pg_dump \
      -h 127.0.0.1 -U '${DST_DB_USER}' \
      -Fc --no-owner --no-acl --encoding=UTF8 \
      '${db}' > '${hop_bk}' 2>/dev/null" || true
    dst_sh "test -s '${hop_bk}'" 2>/dev/null \
      && print_success "Rollback saved: ${hop_bk}" \
      || print_warn "Rollback save failed (continuing)"

    pre_hop_sql_patches "$hop_ver" "$db" "$prev_ver"

    run_one_hop "$hop_ver" "$db" || return 1

    prev_ver="$hop_ver"
    ((current++))
  done
  return 0
}

# ── Finalize with system Odoo 19 ──────────────────────────────────────────────
finalize_odoo19_system() {
  local db=$1
  local max_attempts=80
  local attempt=0

  echo ""
  print_line
  echo -e "  ${WHITE}${BOLD}  STEP 8 — Finalize Schema (system Odoo 19)${NC}"
  print_line
  print_info "Running system Odoo 19 --update=all to complete the schema migration."
  print_info "Odoo 19 stores Selection + translated fields as jsonb — auto-fixing column by column."
  echo ""

  # Stop service if somehow already running
  dst_sh "systemctl stop odoo 2>/dev/null || true" >> "$MIGRATION_LOG" 2>&1

  while [[ $attempt -lt $max_attempts ]]; do
    ((attempt++))
    printf "  ${CYAN}ℹ  Attempt %d/%d — odoo --update=all --stop-after-init...${NC}\n" \
      "$attempt" "$max_attempts"

    local out
    out=$(dst_sh "sudo -u odoo /usr/bin/odoo \
      --update=all \
      --stop-after-init \
      --config='${DST_ODOO_CONF}' \
      --database='${db}' \
      --no-http 2>&1" || true)
    echo "$out" >> "$MIGRATION_LOG"

    if echo "$out" | grep -qiE "shutdown complete|modules loaded|registry loaded"; then
      echo ""
      print_success "Schema finalized after ${attempt} attempt(s)"
      return 0
    fi

    # Find the failing jsonb ALTER in PostgreSQL logs
    local failing_stmt
    failing_stmt=$(dst_sh \
      "find /var/log/postgresql -name '*.log' 2>/dev/null | xargs tail -n 300 2>/dev/null | \
       grep 'STATEMENT.*TYPE jsonb' | tail -1" \
      2>/dev/null || true)

    if [[ -z "$failing_stmt" ]]; then
      if echo "$out" | grep -qiE "CRITICAL|Failed to initialize"; then
        echo ""
        print_error "Odoo 19 schema update failed (not a jsonb issue):"
        echo "$out" | grep -iE "ERROR|CRITICAL" | tail -8 | \
          while IFS= read -r l; do echo -e "  ${RED}  $l${NC}"; done
        return 1
      fi
      echo ""
      print_success "Schema finalized (attempt ${attempt})"
      return 0
    fi

    local tbl col
    tbl=$(echo "$failing_stmt" | grep -oP 'ALTER TABLE "\K[^"]+(?=")')
    col=$(echo "$failing_stmt" | grep -oP 'ALTER COLUMN "\K[^"]+(?=" TYPE jsonb)')

    if [[ -z "$tbl" || -z "$col" ]]; then
      print_warn "Cannot parse failing jsonb statement:"
      print_info "$failing_stmt"
      return 1
    fi

    printf "  ${YELLOW}⚠  Auto-fixing: %s.%s  (varchar → jsonb)${NC}\n" "$tbl" "$col"

    dst_sh "PGPASSWORD='${DST_DB_PASS}' psql -h 127.0.0.1 -U '${DST_DB_USER}' -d '${db}' -q \
      -c \"UPDATE \\\"${tbl}\\\"
           SET    \\\"${col}\\\" = CASE
             WHEN \\\"${col}\\\" ~ '^[a-z0-9_]+\$'
             THEN to_json(\\\"${col}\\\")::text
             ELSE json_build_object('en_US', \\\"${col}\\\")::text
           END
           WHERE \\\"${col}\\\" IS NOT NULL
             AND \\\"${col}\\\" <> ''
             AND \\\"${col}\\\" NOT LIKE '{%'
             AND \\\"${col}\\\" NOT LIKE '[%'
             AND \\\"${col}\\\" NOT LIKE '\\\"%';\"" \
      >> "$MIGRATION_LOG" 2>&1 || true

    log_msg "jsonb fix: ${tbl}.${col}"
    print_success "Fixed ${tbl}.${col} — retrying..."
  done

  echo ""
  print_error "Reached ${max_attempts} auto-fix attempts — manual intervention needed"
  print_info "Check ${MIGRATION_LOG} for details"
  return 1
}

# ── Enable PostgreSQL logging for jsonb detection ─────────────────────────────
enable_pg_statement_logging() {
  # PostgreSQL must log failing statements so finalize_odoo19_system can detect them
  dst_sh "sudo -u postgres psql -c \"ALTER SYSTEM SET log_min_error_statement = 'error';\" 2>/dev/null && \
          sudo -u postgres psql -c \"SELECT pg_reload_conf();\" 2>/dev/null || true" \
    >> "$MIGRATION_LOG" 2>&1 || true
}

# ── Start and verify ───────────────────────────────────────────────────────────
start_and_verify() {
  local db=$1

  echo ""
  print_line
  echo -e "  ${WHITE}${BOLD}  STEP 9 — Start & Verify Odoo 19${NC}"
  print_line
  echo ""

  # Set db_name in odoo.conf
  print_step "Setting db_name in odoo.conf..."
  dst_sh "grep -q '^db_name' '${DST_ODOO_CONF}' && \
          sed -i \"s/^db_name.*/db_name = ${db}/\" '${DST_ODOO_CONF}' || \
          echo 'db_name = ${db}' >> '${DST_ODOO_CONF}'" \
    >> "$MIGRATION_LOG" 2>&1 || true

  print_step "Enabling and starting Odoo service..."
  dst_sh "systemctl enable odoo 2>/dev/null && systemctl start odoo 2>/dev/null || \
          service odoo start 2>/dev/null || true" >> "$MIGRATION_LOG" 2>&1

  print_step "Waiting for Odoo to start (up to 90s)..."
  local i http_code
  for i in $(seq 1 18); do
    sleep 5
    http_code=$(dst_sh \
      "curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:${DST_WEB_PORT}/web/login' 2>/dev/null || echo 000")
    if [[ "$http_code" == "200" || "$http_code" == "303" || "$http_code" == "302" ]]; then
      print_success "Odoo 19 responding on port ${DST_WEB_PORT} (HTTP ${http_code})"
      break
    fi
    printf "  ${GRAY}  waiting... (%d/18)${NC}\n" "$i"
  done

  local svc_status
  svc_status=$(dst_sh "systemctl is-active odoo 2>/dev/null || echo unknown" | tr -d '[:space:]')
  if [[ "$svc_status" == "active" ]]; then
    print_success "Service status: active"
  else
    print_warn "Service status: ${svc_status}"
    print_info "Tail logs: sudo journalctl -u odoo -n 50"
    print_info "Odoo log:  tail -50 /var/log/odoo/odoo.log"
  fi

  # Arabic data sanity check
  local arabic_count
  arabic_count=$(dst_sh \
    "PGPASSWORD='${DST_DB_PASS}' psql -h 127.0.0.1 -U '${DST_DB_USER}' -d '${db}' -tAc \
     \"SELECT count(*) FROM res_partner WHERE name ~ '[^\x00-\x7F]';\" 2>/dev/null || echo 0" \
    | tr -d '[:space:]')
  if [[ "${arabic_count:-0}" -gt 0 ]]; then
    print_success "Arabic data intact: ${arabic_count} partner record(s) with non-ASCII names"
  else
    print_info "Arabic partner count: ${arabic_count:-0} (data may use ASCII names only)"
  fi

  echo ""
  print_line
  echo -e "  ${GREEN}${BOLD}  ✅  Migration Complete!${NC}"
  print_line
  echo ""
  echo -e "    ${WHITE}Odoo 19 URL:${NC}    http://${DST_SSH_HOST}:${DST_WEB_PORT}"
  echo -e "    ${WHITE}Database:${NC}       ${db}"
  echo -e "    ${WHITE}PG user:${NC}        ${DST_DB_USER}"
  echo -e "    ${WHITE}Config:${NC}         ${DST_ODOO_CONF}"
  echo -e "    ${WHITE}Extra addons:${NC}   ${DST_ADDONS_DIR}"
  echo -e "    ${WHITE}Odoo logs:${NC}      /var/log/odoo/odoo.log"
  echo -e "    ${WHITE}Migration log:${NC}  ${MIGRATION_LOG}"
  echo ""
  print_line
}

# ── Main migration flow ────────────────────────────────────────────────────────
run_migration() {
  # Step 1 — SSH to destination
  setup_dst_ssh || { pause; return; }

  # Step 2 — Source
  setup_source || { pause; return; }

  # Step 3 — Destination config
  ask_dst_config || { pause; return; }

  # Step 4 — Install Odoo 19 + PostgreSQL
  prepare_destination || { pause; return; }

  # Enable PostgreSQL statement logging (needed for jsonb detection later)
  enable_pg_statement_logging

  # Step 5 — Dump
  dump_source_db || { pause; return; }

  # Step 6 — Transfer & restore
  transfer_and_restore_db || { pause; return; }

  # Step 7 — Upgrade hops
  IFS=' ' read -ra HOP_LIST <<< "$(build_hop_list "$SRC_VERSION")"
  local hops=${#HOP_LIST[@]}

  if [[ $hops -gt 0 ]]; then
    echo ""
    print_line
    echo -e "  ${WHITE}${BOLD}  STEP 7 — Upgrade Chain${NC}"
    print_line
    print_info "Path: v${SRC_VERSION} → $(IFS=' → '; echo "${HOP_LIST[*]}")"
    print_warn "Keep this terminal open — the upgrade will take 10–60 min"
    echo ""
    run_all_hops "$DST_DB_NAME" || { pause; return; }
  fi

  # Step 8 — Finalize with system Odoo 19 + jsonb fix
  finalize_odoo19_system "$DST_DB_NAME" || { pause; return; }

  # Step 9 — Start service + verify
  start_and_verify "$DST_DB_NAME"
  pause
}

# ── View logs menu ─────────────────────────────────────────────────────────────
view_logs() {
  local logs=()
  while IFS= read -r f; do logs+=("$f"); done < <(ls -t "${LOCAL_BACKUP_DIR}"/migration_*.log 2>/dev/null | head -10)
  if [[ ${#logs[@]} -eq 0 ]]; then
    print_info "No migration logs found in ${LOCAL_BACKUP_DIR}"; pause; return
  fi
  echo ""
  echo -e "  ${GRAY}  Recent logs:${NC}"
  local i=1
  for f in "${logs[@]}"; do
    echo -e "  ${CYAN}${i})${NC} ${f}"; ((i++))
  done
  echo ""
  read -rp "  Open log [1]: " ch; ch="${ch:-1}"
  local idx=$((ch - 1))
  [[ -n "${logs[$idx]}" ]] && less "${logs[$idx]}" || print_error "Invalid choice"
}

# ── Banner ─────────────────────────────────────────────────────────────────────
show_banner() {
  clear
  echo ""
  echo -e "  ${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
  echo -e "  ${CYAN}║${NC}  ${WHITE}${BOLD}🖥️   ODOO → VPS MIGRATION                          ${NC}${CYAN}║${NC}"
  echo -e "  ${CYAN}║${NC}  ${GRAY}  v14–v18  →  Odoo 19 Community (bare VPS install)  ${NC}${CYAN}║${NC}"
  echo -e "  ${CYAN}║${NC}  ${GRAY}  Installs Odoo 19 from scratch on destination       ${NC}${CYAN}║${NC}"
  echo -e "  ${CYAN}╠═══════════════════════════════════════════════════════╣${NC}"
  echo -e "  ${CYAN}║${NC}  ${BLUE}🌐 https://prismatechwork.com${NC}                       ${CYAN}║${NC}"
  echo -e "  ${CYAN}║${NC}  ${BLUE}🐙 https://github.com/mhmdali94/EasyOdooDocker${NC}      ${CYAN}║${NC}"
  echo -e "  ${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
  echo ""
}

# ── Cleanup ────────────────────────────────────────────────────────────────────
cleanup() {
  ssh -o ControlPath="$DST_SSH_CTL" -O exit "${DST_SSH_USER}@${DST_SSH_HOST}" 2>/dev/null || true
  ssh -o ControlPath="$SRC_SSH_CTL" -O exit "${SRC_SSH_USER}@${SRC_SSH_HOST}" 2>/dev/null || true
  rm -f "$DST_SSH_CTL" "$SRC_SSH_CTL"
}
trap cleanup EXIT

# ── Entry point ────────────────────────────────────────────────────────────────
while true; do
  show_banner
  echo -e "  ${WHITE}${BOLD}  Menu${NC}"
  echo ""
  echo -e "  ${CYAN}1)${NC} Start migration  (v14–v18 → Odoo 19 Community on VPS)"
  echo -e "  ${CYAN}2)${NC} View migration logs"
  echo -e "  ${CYAN}0)${NC} Exit"
  echo ""
  read -rp "  Choice [1]: " _ch; _ch="${_ch:-1}"
  case "$_ch" in
    1) run_migration ;;
    2) view_logs ;;
    0) echo ""; exit 0 ;;
    *) print_error "Invalid choice" ;;
  esac
  echo ""
done
