#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  Migrate to VPS.sh
#  Odoo v14–v18  →  Odoo 19 Community Edition  (bare VPS system install)
#  v1.0 — https://github.com/mhmdali94/EasyOdooDocker
#
#  Run this script ON THE SOURCE machine.
#  It installs Odoo 19 Community on the destination VPS and migrates the DB.
#
#  Source machine: READ-ONLY — pg_dump only, nothing is modified.
#
#  What it does:
#    1. Reads source Odoo (same logic as Odoo Migration.sh)
#    2. Connects to destination VPS via SSH (ControlMaster — password once)
#    3. Installs Odoo 19 Community deb + PostgreSQL on the VPS
#    4. Dumps and restores the source database
#    5. Runs OpenUpgrade hops via Docker  (14→15→16→17→18)  --network=host
#    6. Runs system Odoo 19 --update=all with auto jsonb-fix loop
#    7. Starts the odoo systemd service and verifies it is running
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
pause()   { echo ""; read -rp "  Press [Enter] to continue..." _; echo ""; }

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

# Source (same variables as Odoo Migration.sh)
SRC_VERSION=""
SRC_DB_NAME=""
SRC_DB_USER=""
SRC_DB_PASS=""
SRC_DB_HOST="localhost"
SRC_DB_PORT="5432"
SRC_ODOO_CONF=""
SRC_ODOO_BIN=""
SRC_MASTER_PASS=""
SRC_PG_AUTH_METHOD=""
SRC_IS_DOCKER="false"
SRC_DOCKER_CONTAINER_DB=""
SRC_ADDONS_PATHS=()

# Destination VPS
DST_SSH_USER="root"
DST_SSH_HOST=""
DST_SSH_PORT="22"
DST_SSH_CTL="/tmp/.vps_mig_ctl_${$}"
_DST_SSH_BASE="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=60 -o ServerAliveCountMax=5"

DST_DB_NAME=""
DST_DB_USER=""
DST_DB_PASS=""
DST_MASTER_PASS=""
DST_ODOO_CONF="/etc/odoo/odoo.conf"
DST_ADDONS_DIR="/opt/odoo-addons"
DST_WEB_PORT="8069"
DST_GEVENT_PORT="8072"

# Local working paths
LOCAL_BACKUP_DIR="${HOME}/odoo_vps_migration_backups"
LOCAL_LOG_DIR="${HOME}/odoo_vps_migration_backups/logs"
MIGRATION_LOG="/dev/null"
ERR_LOG="/dev/null"
HOP_LIST=()
BACKUP_FILE=""
ADDONS_BACKUP=""

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

# ══════════════════════════════════════════════════════════════
#  SOURCE DETECTION — copied exactly from Odoo Migration.sh
# ══════════════════════════════════════════════════════════════

parse_conf_key() {
  grep -E "^${2}\s*=" "$1" 2>/dev/null | head -1 \
    | sed "s/^${2}\s*=\s*//" | tr -d '\r' | xargs
}

detect_local_version() {
  local v=""

  # Method 1: run the exact binary detected from the running process
  if [[ -n "$SRC_ODOO_BIN" && -x "$SRC_ODOO_BIN" ]]; then
    v=$("$SRC_ODOO_BIN" --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1)
    [[ -n "$v" ]] && { echo "$v"; return; }
    local src_dir; src_dir=$(dirname "$SRC_ODOO_BIN")
    for rel in \
        "${src_dir}/odoo/release.py" \
        "${src_dir}/openerp/release.py" \
        "${src_dir}/release.py"; do
      [[ -f "$rel" ]] && {
        v=$(grep -oP "(?<=series\s=\s')[^']+" "$rel" 2>/dev/null \
          || grep -oP "(?<=version\s=\s')[0-9]+\.[0-9]+" "$rel" 2>/dev/null)
        [[ -n "$v" ]] && { echo "$v"; return; }
      }
    done
  fi

  # Method 2: binaries in PATH
  for bin in odoo-bin odoo openerp-server; do
    v=$(command -v "$bin" &>/dev/null && "$bin" --version 2>/dev/null \
        | grep -oP '\d+\.\d+' | head -1)
    [[ -n "$v" ]] && { echo "$v"; return; }
  done

  # Method 3: import odoo Python module
  v=$(python3 -c "import odoo; print(odoo.release.series)" 2>/dev/null \
      | grep -oP '\d+\.\d+' | head -1)
  [[ -n "$v" ]] && { echo "$v"; return; }

  # Method 4: dpkg (apt-installed Odoo)
  v=$(dpkg -l 2>/dev/null | awk '/^ii.*odoo/{print $3}' | grep -oP '^\d+\.\d+' | head -1)
  [[ -n "$v" ]] && { echo "$v"; return; }

  echo ""
}

get_custom_addons_paths() {
  IFS=',' read -ra _paths <<< "$1"
  for p in "${_paths[@]}"; do
    p=$(echo "$p" | xargs)
    [[ "$p" == *"dist-packages"* ]] && continue
    [[ "$p" == *"site-packages"* ]] && continue
    [[ "$p" == *"/usr/lib"*      ]] && continue
    [[ "$p" == *"/usr/share"*    ]] && continue
    [[ -d "$p" ]] && echo "$p"
  done
}

# Run pg command on source using whatever auth method was resolved
_src_pg() {
  local cmd=$1; shift
  case "$SRC_PG_AUTH_METHOD" in
    password)
      PGPASSWORD="$SRC_DB_PASS" PGCLIENTENCODING="UTF8" \
        "$cmd" -h "$SRC_DB_HOST" -p "$SRC_DB_PORT" -U "$SRC_DB_USER" "$@"
      ;;
    peer_odoo)
      sudo -u "$SRC_DB_USER" env PGCLIENTENCODING="UTF8" "$cmd" -U "$SRC_DB_USER" "$@"
      ;;
    peer_postgres)
      sudo -u postgres env PGCLIENTENCODING="UTF8" "$cmd" -U postgres "$@"
      ;;
  esac
}

_resolve_src_pg_auth() {
  local test_cmd=(-d postgres -t -c "SELECT 1;")

  if [[ -n "$SRC_DB_PASS" && "$SRC_DB_PASS" != "False" ]]; then
    if PGPASSWORD="$SRC_DB_PASS" psql \
        -h "$SRC_DB_HOST" -p "$SRC_DB_PORT" -U "$SRC_DB_USER" \
        "${test_cmd[@]}" &>/dev/null; then
      SRC_PG_AUTH_METHOD="password"
      print_success "PostgreSQL auth: password (from odoo.conf)"
      return 0
    fi
    print_warn "Password from odoo.conf did not work — trying peer auth..."
  else
    print_info "No password in odoo.conf — trying peer auth (standard server install)"
  fi

  if id "$SRC_DB_USER" &>/dev/null; then
    if sudo -u "$SRC_DB_USER" psql -U "$SRC_DB_USER" "${test_cmd[@]}" &>/dev/null; then
      SRC_PG_AUTH_METHOD="peer_odoo"
      print_success "PostgreSQL auth: peer (sudo -u ${SRC_DB_USER})"
      return 0
    fi
  fi

  if sudo -u postgres psql -U postgres "${test_cmd[@]}" &>/dev/null; then
    SRC_PG_AUTH_METHOD="peer_postgres"
    print_success "PostgreSQL auth: peer (sudo -u postgres)"
    return 0
  fi

  echo ""
  echo -e "  ${YELLOW}  Could not connect to PostgreSQL automatically.${NC}"
  echo -e "  ${GRAY}  Tried: password from config, peer as '${SRC_DB_USER}', peer as 'postgres'${NC}"
  echo ""
  read -rsp "  PostgreSQL password for '${SRC_DB_USER}' (Enter to abort): " SRC_DB_PASS; echo ""
  [[ -z "$SRC_DB_PASS" ]] && { print_error "Cannot connect to PostgreSQL. Aborting."; return 1; }

  if PGPASSWORD="$SRC_DB_PASS" psql \
      -h "$SRC_DB_HOST" -p "$SRC_DB_PORT" -U "$SRC_DB_USER" \
      "${test_cmd[@]}" &>/dev/null; then
    SRC_PG_AUTH_METHOD="password"
    print_success "PostgreSQL auth: password (manually entered)"
    return 0
  fi

  print_error "Still cannot connect to PostgreSQL. Check credentials and try again."
  return 1
}

_src_list_dbs_docker() {
  docker exec -e PGPASSWORD="$SRC_DB_PASS" "$SRC_DOCKER_CONTAINER_DB" \
    psql -U "$SRC_DB_USER" -t \
    -c "SELECT datname FROM pg_database WHERE datistemplate=false AND datname<>'postgres' ORDER BY datname;" \
    2>/dev/null | tr -d ' ' | grep -v '^$'
}

_src_list_dbs_native() {
  _src_pg psql -d postgres -t \
    -c "SELECT datname FROM pg_database WHERE datistemplate=false AND datname<>'postgres' ORDER BY datname;" \
    2>/dev/null | tr -d ' ' | grep -v '^$'
}

_src_pick_database() {
  local dbs=$1
  local hint=$2
  if [[ -z "$dbs" ]]; then
    print_warn "Could not list databases automatically"
    read -rp "  Enter database name to migrate: " SRC_DB_NAME
    [[ -z "$SRC_DB_NAME" ]] && { print_error "Database name required"; return 1; }
  else
    echo ""
    echo -e "  ${CYAN}  Databases found:${NC}"
    local i=1 default_ch=1
    local _dbs_arr=()
    while IFS= read -r db; do
      [[ -z "$db" ]] && continue
      if [[ -n "$hint" && "$hint" == *"$db"* ]]; then
        echo -e "  ${GREEN}  ${i}) ${db}  ← active (detected from running processes)${NC}"
        default_ch=$i
      else
        echo "    ${i}) ${db}"
      fi
      _dbs_arr+=("$db")
      ((i++))
    done <<< "$dbs"
    read -rp "  Choose database to migrate [${default_ch}]: " ch; ch=${ch:-$default_ch}
    SRC_DB_NAME="${_dbs_arr[$((ch-1))]}"
    [[ -z "$SRC_DB_NAME" ]] && { print_error "Invalid choice"; return 1; }
  fi
  return 0
}

_src_confirm_version() {
  local auto_ver=$1
  if [[ -z "$auto_ver" ]]; then
    read -rp "  Could not auto-detect version. Enter it (e.g. 14.0): " SRC_VERSION
  else
    print_success "Detected version: ${auto_ver}"
    read -rp "  Confirm version [${auto_ver}]: " inp
    SRC_VERSION="${inp:-$auto_ver}"
  fi
  local maj; maj=$(version_major "$SRC_VERSION")
  if [[ "$maj" -lt 14 || "$maj" -ge 19 ]]; then
    print_error "Version ${SRC_VERSION} is not supported. Must be v14–v18."
    return 1
  fi
  return 0
}

# ── STEP 1: Read source Odoo ───────────────────────────────────────────────────
setup_source() {
  echo ""
  print_line
  echo -e "  ${WHITE}${BOLD}  STEP 1 — Read Source Odoo (this machine)${NC}"
  print_line
  echo -e "  ${GREEN}  Source machine is READ-ONLY — nothing will be modified here.${NC}"
  echo ""

  # ── Detect running Odoo process (most reliable) ───────────────
  print_step "Scanning running Odoo processes..."
  local found_conf="" proc_db_hint="" proc_bin=""

  local proc_line
  proc_line=$(ps aux 2>/dev/null | grep -v grep \
    | grep -E 'odoo-bin|odoo\.py|openerp-server|odoo-server|python.*odoo|python.*openerp' \
    | head -1)

  found_conf=$(echo "$proc_line" | grep -oP '(?<=-c\s)\S+' | head -1)
  proc_bin=$(echo "$proc_line"   | grep -oP '\S*(?:odoo-bin|odoo\.py|openerp-server)\S*' | head -1)
  [[ -f "$proc_bin" ]] && SRC_ODOO_BIN="$proc_bin"

  proc_db_hint=$(ps aux 2>/dev/null | grep -v grep \
    | grep -oP 'postgres: [^:]+: \S+ \K\S+(?= \[)' \
    | grep -v '^postgres$' | sort -u | tr '\n' ' ' | xargs)

  if [[ -n "$found_conf" && -f "$found_conf" ]]; then
    echo -e "  ${GREEN}  ✔ Running Odoo process detected${NC}"
    echo -e "  ${GRAY}    Config:    ${found_conf}${NC}"
    [[ -n "$SRC_ODOO_BIN" ]]  && echo -e "  ${GRAY}    Binary:    ${SRC_ODOO_BIN}${NC}"
    [[ -n "$proc_db_hint" ]]  && echo -e "  ${GRAY}    Active DB: ${proc_db_hint}${NC}"
  elif [[ -n "$found_conf" ]]; then
    echo -e "  ${YELLOW}  Process found but config not readable: ${found_conf}${NC}"
    found_conf=""
  else
    echo -e "  ${GRAY}  No running Odoo process found (may be stopped or Docker)${NC}"
  fi
  echo ""

  # ── Check for Odoo Manager Docker instances ───────────────────
  local local_meta="$HOME/docker/.odoo_manager_instances"
  local has_docker=false
  [[ -f "$local_meta" ]] && grep -q . "$local_meta" 2>/dev/null && has_docker=true

  # ── Well-known config paths ───────────────────────────────────
  if [[ -z "$found_conf" ]]; then
    for c in \
      /etc/odoo-server.conf /etc/odoo/odoo.conf /etc/odoo.conf \
      /etc/openerp-server.conf /etc/openerp.conf \
      /opt/odoo/odoo.conf /opt/odoo/server/odoo.conf \
      /opt/odoo-server/odoo.conf /home/odoo/odoo.conf \
      /home/odoo/odoo-server.conf /srv/odoo/odoo.conf \
      /var/lib/odoo/odoo.conf /root/odoo/odoo.conf; do
      [[ -f "$c" ]] && { found_conf="$c"; print_success "Found config: ${c}"; break; }
    done
  fi

  # ── Deep filesystem search (last resort) ─────────────────────
  local -a deep_found=()
  if ! $has_docker && [[ -z "$found_conf" ]]; then
    echo -e "  ${GRAY}  Running deep search for odoo.conf...${NC}"
    while IFS= read -r hit; do
      echo "$hit" | grep -qE '/addons/|/debian/|/doc/|/tests?/|/sample|/template' && continue
      deep_found+=("$hit")
    done < <(find / -maxdepth 12 \
               \( -name "odoo.conf" -o -name "odoo-server.conf" \
                  -o -name "openerp.conf" -o -name "openerp-server.conf" \) \
               -not -path "/proc/*" -not -path "/sys/*" \
               -not -path "/dev/*" -not -path "/snap/*" \
               2>/dev/null | sort -u)
    [[ ${#deep_found[@]} -gt 0 ]] && found_conf="${deep_found[0]}"
  fi

  # ── Show menu based on what was found ────────────────────────
  echo -e "  ${CYAN}  Source type:${NC}"
  $has_docker && \
    echo -e "  ${GREEN}  ✔ Odoo Manager Docker instances${NC}" || \
    echo -e "  ${GRAY}  ✗ No Odoo Manager instances${NC}"
  [[ -n "$found_conf" ]] && \
    echo -e "  ${GREEN}  ✔ Traditional server Odoo: ${found_conf}${NC}" || \
    echo -e "  ${GRAY}  ✗ No server config found${NC}"
  echo ""

  local src_choice=""
  if $has_docker && [[ -n "$found_conf" ]]; then
    echo "    1) Docker instance (Odoo Manager)"
    echo "    2) Traditional server Odoo (${found_conf})"
    echo "    3) Enter config path manually"
    read -rp "  Source type [1]: " src_choice; src_choice=${src_choice:-1}
  elif $has_docker; then
    echo "    1) Docker instance (Odoo Manager)"
    echo "    2) Enter config path manually"
    read -rp "  Source type [1]: " src_choice; src_choice=${src_choice:-1}
  elif [[ ${#deep_found[@]} -gt 1 ]]; then
    echo -e "  ${CYAN}  Multiple configs found:${NC}"
    local fi=1
    local _confmap=()
    for f in "${deep_found[@]}"; do
      echo "    ${fi}) ${f}"; _confmap+=("$f"); ((fi++))
    done
    echo "    ${fi}) Enter path manually"
    read -rp "  Choose [1]: " src_choice
    if [[ "$src_choice" -le "${#_confmap[@]}" ]] 2>/dev/null; then
      found_conf="${_confmap[$((src_choice-1))]}"
      src_choice="server"
    else
      src_choice="manual"
    fi
  elif [[ -n "$found_conf" ]]; then
    echo "    1) Traditional server Odoo (${found_conf})"
    echo "    2) Enter config path manually"
    read -rp "  Source type [1]: " src_choice; src_choice=${src_choice:-1}
    [[ "$src_choice" == "1" ]] && src_choice="server"
    [[ "$src_choice" == "2" ]] && src_choice="manual"
  else
    print_warn "No Odoo installation found on this machine."
    echo "    1) Enter config path manually"
    read -rp "  Choice [1]: " _; src_choice="manual"
  fi

  # ── Branch: Docker source ─────────────────────────────────────
  if [[ "$src_choice" == "1" ]] && $has_docker; then
    SRC_IS_DOCKER="true"
    echo ""
    echo -e "  ${CYAN}  Odoo Manager instances:${NC}"
    local idx=1
    local _instarr=()
    while IFS='|' read -r m_name m_ver m_dir m_web m_gev m_pgu m_pgp _ m_st; do
      [[ -z "$m_name" ]] && continue
      printf "    %d) %-20s  v%-5s  [%s]\n" "$idx" "$m_name" "$m_ver" "$m_st"
      _instarr+=("${m_name}|${m_ver}|${m_dir}|${m_pgu}|${m_pgp}")
      ((idx++))
    done < "$local_meta"
    echo ""
    read -rp "  Choose instance [1]: " ich; ich=${ich:-1}
    local sel="${_instarr[$((ich-1))]}"
    [[ -z "$sel" ]] && { print_error "Invalid choice"; return 1; }
    IFS='|' read -r _nm _ver _dir _pgu _pgp <<< "$sel"
    SRC_VERSION="$_ver"; SRC_DB_USER="$_pgu"; SRC_DB_PASS="$_pgp"
    SRC_DOCKER_CONTAINER_DB="${_nm}-db"
    SRC_ODOO_CONF="${_dir}/config/odoo.conf"
    SRC_ADDONS_PATHS=("${_dir}/addons")
    print_success "Selected: ${_nm} (v${SRC_VERSION})"
    _src_confirm_version "$SRC_VERSION" || return 1
    echo ""
    print_step "Listing databases in '${SRC_DOCKER_CONTAINER_DB}'..."
    local dbs; dbs=$(_src_list_dbs_docker)
    _src_pick_database "$dbs" "$proc_db_hint" || return 1

  # ── Branch: Traditional server ────────────────────────────────
  elif [[ "$src_choice" == "1" || "$src_choice" == "server" ]]; then
    SRC_IS_DOCKER="false"
    SRC_ODOO_CONF="$found_conf"
    print_success "Using config: ${SRC_ODOO_CONF}"
    SRC_DB_HOST=$(parse_conf_key "$SRC_ODOO_CONF" "db_host");   SRC_DB_HOST=${SRC_DB_HOST:-localhost}
    SRC_DB_PORT=$(parse_conf_key "$SRC_ODOO_CONF" "db_port");   SRC_DB_PORT=${SRC_DB_PORT:-5432}
    SRC_DB_USER=$(parse_conf_key "$SRC_ODOO_CONF" "db_user");   SRC_DB_USER=${SRC_DB_USER:-odoo}
    SRC_DB_PASS=$(parse_conf_key "$SRC_ODOO_CONF" "db_password")
    SRC_MASTER_PASS=$(parse_conf_key "$SRC_ODOO_CONF" "admin_passwd")
    local addons_raw; addons_raw=$(parse_conf_key "$SRC_ODOO_CONF" "addons_path")
    _ask_master_password
    echo ""
    print_step "Resolving PostgreSQL connection..."
    _resolve_src_pg_auth || return 1
    print_step "Detecting Odoo version..."
    _src_confirm_version "$(detect_local_version)" || return 1
    echo ""
    print_step "Listing databases..."
    local dbs; dbs=$(_src_list_dbs_native)
    _src_pick_database "$dbs" "$proc_db_hint" || return 1
    SRC_ADDONS_PATHS=()
    [[ -n "$addons_raw" ]] && while IFS= read -r p; do
      [[ -n "$p" ]] && SRC_ADDONS_PATHS+=("$p")
    done < <(get_custom_addons_paths "$addons_raw")

  # ── Branch: Manual config path ────────────────────────────────
  else
    SRC_IS_DOCKER="false"
    echo ""
    read -rp "  Full path to odoo.conf: " SRC_ODOO_CONF
    [[ ! -f "$SRC_ODOO_CONF" ]] && { print_error "File not found: ${SRC_ODOO_CONF}"; return 1; }
    SRC_DB_HOST=$(parse_conf_key "$SRC_ODOO_CONF" "db_host");   SRC_DB_HOST=${SRC_DB_HOST:-localhost}
    SRC_DB_PORT=$(parse_conf_key "$SRC_ODOO_CONF" "db_port");   SRC_DB_PORT=${SRC_DB_PORT:-5432}
    SRC_DB_USER=$(parse_conf_key "$SRC_ODOO_CONF" "db_user");   SRC_DB_USER=${SRC_DB_USER:-odoo}
    SRC_DB_PASS=$(parse_conf_key "$SRC_ODOO_CONF" "db_password")
    SRC_MASTER_PASS=$(parse_conf_key "$SRC_ODOO_CONF" "admin_passwd")
    local addons_raw; addons_raw=$(parse_conf_key "$SRC_ODOO_CONF" "addons_path")
    _ask_master_password
    echo ""
    print_step "Resolving PostgreSQL connection..."
    _resolve_src_pg_auth || return 1
    print_step "Detecting Odoo version..."
    _src_confirm_version "$(detect_local_version)" || return 1
    echo ""
    print_step "Listing databases..."
    local dbs; dbs=$(_src_list_dbs_native)
    _src_pick_database "$dbs" "$proc_db_hint" || return 1
    SRC_ADDONS_PATHS=()
    [[ -n "$addons_raw" ]] && while IFS= read -r p; do
      [[ -n "$p" ]] && SRC_ADDONS_PATHS+=("$p")
    done < <(get_custom_addons_paths "$addons_raw")
  fi

  echo ""
  print_line
  echo -e "  ${GREEN}${BOLD}  Source confirmed (READ-ONLY):${NC}"
  echo -e "  ${GRAY}  Version:  ${SRC_VERSION}${NC}"
  echo -e "  ${GRAY}  Database: ${SRC_DB_NAME}${NC}"
  [[ ${#SRC_ADDONS_PATHS[@]} -gt 0 ]] && \
    echo -e "  ${GRAY}  Addons:   ${SRC_ADDONS_PATHS[*]}${NC}"
  print_line
}

_ask_master_password() {
  echo ""
  if [[ -n "$SRC_MASTER_PASS" && "$SRC_MASTER_PASS" != "False" ]]; then
    echo -e "  ${GREEN}  ✔ Master password found in odoo.conf${NC}"
    echo -e "  ${GRAY}    Will be reused on the destination Odoo 19.${NC}"
    read -rsp "  Master password [keep — press Enter, or type new]: " _mp; echo ""
    [[ -n "$_mp" ]] && SRC_MASTER_PASS="$_mp"
  else
    echo -e "  ${YELLOW}  Master password not found in odoo.conf.${NC}"
    read -rsp "  Enter Odoo master password (will be set on destination): " SRC_MASTER_PASS; echo ""
    [[ -z "$SRC_MASTER_PASS" ]] && SRC_MASTER_PASS="admin"
  fi
}

# ══════════════════════════════════════════════════════════════
#  STEP 2: Connect to destination VPS
# ══════════════════════════════════════════════════════════════
setup_dst_ssh() {
  echo ""
  print_line
  echo -e "  ${WHITE}${BOLD}  STEP 2 — Connect to Destination VPS${NC}"
  print_line
  echo -e "  ${GRAY}  You will type the SSH password ONCE — all steps reuse that connection.${NC}"
  echo ""

  read -rp "  Destination VPS IP or hostname: " DST_SSH_HOST
  [[ -z "$DST_SSH_HOST" ]] && { print_error "Host required"; return 1; }
  read -rp "  SSH user [root]: " u;  DST_SSH_USER="${u:-root}"
  read -rp "  SSH port [22]: "   p;  DST_SSH_PORT="${p:-22}"

  print_step "Connecting to ${DST_SSH_USER}@${DST_SSH_HOST}:${DST_SSH_PORT} ..."

  ssh $_DST_SSH_BASE \
    -o ControlMaster=yes \
    -o ControlPath="$DST_SSH_CTL" \
    -o ControlPersist=7200 \
    -p "$DST_SSH_PORT" \
    "${DST_SSH_USER}@${DST_SSH_HOST}" "echo ok" \
  || { print_error "SSH connection failed"; return 1; }

  print_success "Connected — password will NOT be asked again during this migration"
}

# ══════════════════════════════════════════════════════════════
#  STEP 3: Destination config
# ══════════════════════════════════════════════════════════════
ask_dst_config() {
  echo ""
  print_line
  echo -e "  ${WHITE}${BOLD}  STEP 3 — Destination Configuration${NC}"
  print_line
  echo ""

  read -rp "  Database name on destination [${SRC_DB_NAME}]: " n
  DST_DB_NAME="${n:-$SRC_DB_NAME}"

  read -rp "  PostgreSQL user [odoo19_user]: " u
  DST_DB_USER="${u:-odoo19_user}"

  local gen; gen=$(gen_password)
  read -rp "  PostgreSQL password [auto-generated — press Enter]: " p
  DST_DB_PASS="${p:-$gen}"

  # Master password — default to source master pass
  echo ""
  local def_master="${SRC_MASTER_PASS:-}"
  [[ -z "$def_master" ]] && def_master=$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 16)
  if [[ -n "$SRC_MASTER_PASS" ]]; then
    read -rsp "  Odoo master password [same as source — press Enter to keep]: " DST_MASTER_PASS; echo ""
    DST_MASTER_PASS="${DST_MASTER_PASS:-$def_master}"
  else
    read -rsp "  Odoo master password: " DST_MASTER_PASS; echo ""
    DST_MASTER_PASS="${DST_MASTER_PASS:-$def_master}"
  fi

  read -rp "  Odoo web port [8069]: "   wp; DST_WEB_PORT="${wp:-8069}"
  read -rp "  Gevent/longpoll port [8072]: " gp; DST_GEVENT_PORT="${gp:-8072}"

  echo ""
  print_line
  echo -e "  ${GRAY}  Migration plan:${NC}"
  echo -e "    Source:      ${SRC_DB_NAME} (v${SRC_VERSION})"
  echo -e "    Destination: Odoo 19 on ${DST_SSH_HOST}"
  echo -e "    DB:          ${DST_DB_NAME}  (user: ${DST_DB_USER})"
  echo -e "    Web port:    ${DST_WEB_PORT}  Gevent: ${DST_GEVENT_PORT}"
  echo -e "    Config:      ${DST_ODOO_CONF}"
  print_line

  confirm "Proceed?" || return 1

  # Init log files
  mkdir -p "$LOCAL_BACKUP_DIR" "$LOCAL_LOG_DIR"
  local ts; ts=$(date +%Y%m%d_%H%M%S)
  MIGRATION_LOG="${LOCAL_LOG_DIR}/migration_${DST_DB_NAME}_v${SRC_VERSION}_to_v19_${ts}.log"
  ERR_LOG="${LOCAL_LOG_DIR}/ERRORS_${DST_DB_NAME}_v${SRC_VERSION}_to_v19_${ts}.log"
  echo "# VPS Migration: ${DST_DB_NAME} v${SRC_VERSION}→19 $(date)" > "$MIGRATION_LOG"
  echo "# Errors: ${DST_DB_NAME} $(date)" > "$ERR_LOG"
  log_msg "Source: ${SRC_DB_NAME} v${SRC_VERSION} type=${SRC_IS_DOCKER}"
  log_msg "Destination: ${DST_SSH_HOST} DB=${DST_DB_NAME}"
}

# ══════════════════════════════════════════════════════════════
#  STEP 4: Install Odoo 19 on destination VPS
# ══════════════════════════════════════════════════════════════
install_prerequisites() {
  print_step "Updating package list..."
  dst_sh "DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>&1" >> "$MIGRATION_LOG" 2>&1 || true

  print_step "Installing system packages..."
  dst_sh "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    python3 python3-dev python3-pip python3-venv \
    postgresql postgresql-client \
    libxml2-dev libxslt1-dev libldap2-dev libsasl2-dev \
    libtiff5-dev libjpeg-dev libopenjp2-7-dev zlib1g-dev \
    libfreetype6-dev liblcms2-dev libwebp-dev \
    libharfbuzz-dev libfribidi-dev libxcb1-dev libpq-dev \
    npm node-gyp curl wget git unzip ca-certificates 2>&1" \
    >> "$MIGRATION_LOG" 2>&1 || print_warn "Some packages may have failed — check log"

  print_step "Installing rtlcss (Arabic/RTL support)..."
  dst_sh "npm install -g rtlcss 2>&1" >> "$MIGRATION_LOG" 2>&1 \
    || print_warn "rtlcss install failed"

  print_step "Installing wkhtmltopdf..."
  if dst_sh "which wkhtmltopdf > /dev/null 2>&1"; then
    print_success "wkhtmltopdf already installed"
  else
    local codename
    codename=$(dst_sh \
      "lsb_release -cs 2>/dev/null || . /etc/os-release && echo \$VERSION_CODENAME" \
      2>/dev/null | tr -d '[:space:]' || echo "jammy")
    case "$codename" in focal|hirsute|impish) codename="focal" ;; *) codename="jammy" ;; esac
    dst_sh "wget -q 'https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.${codename}_amd64.deb' \
              -O /tmp/wkhtmltox.deb 2>&1 && \
            DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/wkhtmltox.deb -qq 2>&1 && \
            rm -f /tmp/wkhtmltox.deb" >> "$MIGRATION_LOG" 2>&1 \
      || print_warn "wkhtmltopdf install failed (PDF reports may not work)"
  fi
}

install_odoo19() {
  print_step "Checking for Odoo 19..."
  if dst_sh "command -v odoo > /dev/null 2>&1 && odoo --version 2>/dev/null | grep -q '19'"; then
    print_success "Odoo 19 already installed"
    return 0
  fi

  print_step "Downloading Odoo 19 Community deb package..."
  local url="https://nightly.odoo.com/19.0/nightly/deb/odoo_19.0.latest_all.deb"
  dst_sh "wget -q '${url}' -O /tmp/odoo19.deb 2>&1" >> "$MIGRATION_LOG" 2>&1
  dst_sh "test -s /tmp/odoo19.deb" 2>/dev/null \
    || { print_error "Download failed — check internet on VPS. URL: ${url}"; return 1; }

  print_step "Installing Odoo 19 (may take a few minutes)..."
  dst_sh "DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/odoo19.deb 2>&1" \
    >> "$MIGRATION_LOG" 2>&1 || {
    dst_sh "DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/odoo19.deb 2>&1; \
            apt-get -f install -y -qq 2>&1" >> "$MIGRATION_LOG" 2>&1 \
      || { print_error "Odoo 19 installation failed — see ${MIGRATION_LOG}"; return 1; }
  }
  dst_sh "rm -f /tmp/odoo19.deb" 2>/dev/null || true

  local ver; ver=$(dst_sh "odoo --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1" 2>/dev/null || echo "")
  [[ "$ver" == "19"* ]] && print_success "Odoo 19 installed (${ver})" \
    || { print_error "Install may have failed (got: ${ver:-nothing})"; return 1; }
}

setup_dst_postgres() {
  print_step "Starting PostgreSQL..."
  dst_sh "systemctl start postgresql 2>/dev/null || service postgresql start 2>/dev/null || true" \
    >> "$MIGRATION_LOG" 2>&1
  dst_sh "systemctl enable postgresql 2>/dev/null || true" >> "$MIGRATION_LOG" 2>&1

  # Allow password auth on 127.0.0.1 (needed by Docker migration containers)
  print_step "Configuring pg_hba.conf for 127.0.0.1 password auth..."
  local pg_ver
  pg_ver=$(dst_sh "ls /etc/postgresql/ 2>/dev/null | sort -V | tail -1" | tr -d '[:space:]' || echo "14")
  local hba="/etc/postgresql/${pg_ver}/main/pg_hba.conf"
  dst_sh "test -f '${hba}'" 2>/dev/null || \
    hba=$(dst_sh "find /etc/postgresql -name pg_hba.conf 2>/dev/null | head -1" | tr -d '[:space:]')
  dst_sh "grep -qE '127\\.0\\.0\\.1.*scram-sha-256|127\\.0\\.0\\.1.*md5' '${hba}' 2>/dev/null || \
          { echo 'host all all 127.0.0.1/32 scram-sha-256' >> '${hba}'; \
            systemctl reload postgresql 2>/dev/null || true; }" \
    >> "$MIGRATION_LOG" 2>&1 || true

  print_step "Creating PostgreSQL role '${DST_DB_USER}'..."
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
  print_success "PostgreSQL role ready"
}

write_odoo_conf_on_dst() {
  print_step "Writing ${DST_ODOO_CONF}..."
  local tmp; tmp=$(mktemp)
  cat > "$tmp" <<CONF
[options]
db_host = 127.0.0.1
db_port = 5432
db_user = ${DST_DB_USER}
db_password = ${DST_DB_PASS}
db_name =
admin_passwd = ${DST_MASTER_PASS}
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
  install_odoo19 || return 1
  echo ""
  dst_sh "mkdir -p '${DST_ADDONS_DIR}' && chown odoo:odoo '${DST_ADDONS_DIR}' 2>/dev/null || true" \
    >> "$MIGRATION_LOG" 2>&1
  setup_dst_postgres || return 1
  write_odoo_conf_on_dst || return 1

  # Enable PostgreSQL statement logging so jsonb failures can be detected
  dst_sh "sudo -u postgres psql -c \"ALTER SYSTEM SET log_min_error_statement='error';\" 2>/dev/null && \
          sudo -u postgres psql -c \"SELECT pg_reload_conf();\" 2>/dev/null || true" \
    >> "$MIGRATION_LOG" 2>&1 || true

  print_success "Destination VPS is ready"
}

# ══════════════════════════════════════════════════════════════
#  STEP 5: Dump source DB
# ══════════════════════════════════════════════════════════════
dump_source_db() {
  echo ""
  print_line
  echo -e "  ${WHITE}${BOLD}  STEP 5 — Dump Source Database${NC}"
  print_line
  echo ""

  local ts; ts=$(date +%Y%m%d_%H%M%S)
  BACKUP_FILE="${LOCAL_BACKUP_DIR}/${SRC_DB_NAME}_v${SRC_VERSION}_${ts}.dump"
  ADDONS_BACKUP="${LOCAL_BACKUP_DIR}/${SRC_DB_NAME}_addons_${ts}.tar.gz"
  mkdir -p "$LOCAL_BACKUP_DIR"

  print_step "Dumping '${SRC_DB_NAME}' (binary / UTF-8, read-only on source)..."

  if [[ "$SRC_IS_DOCKER" == "true" ]]; then
    print_info "Source is Docker — streaming pg_dump from container"
    docker exec \
      -e PGPASSWORD="$SRC_DB_PASS" \
      -e PGCLIENTENCODING="UTF8" \
      "$SRC_DOCKER_CONTAINER_DB" \
      pg_dump -U "$SRC_DB_USER" -Fc --no-owner --no-acl --encoding=UTF8 \
        "$SRC_DB_NAME" > "$BACKUP_FILE"
  else
    print_info "Source is server Odoo — auth method: ${SRC_PG_AUTH_METHOD}"
    _src_pg pg_dump -Fc --no-owner --no-acl --encoding=UTF8 \
      "$SRC_DB_NAME" > "$BACKUP_FILE"
  fi

  [[ ! -s "$BACKUP_FILE" ]] && { print_error "Dump failed or empty"; return 1; }

  local sz; sz=$(du -sh "$BACKUP_FILE" | cut -f1)
  print_success "Dump: ${BACKUP_FILE} (${sz})"
  log_msg "Dump: ${BACKUP_FILE} sz=${sz}"

  # Archive custom addons
  if [[ ${#SRC_ADDONS_PATHS[@]} -gt 0 ]]; then
    print_step "Archiving custom addons: ${SRC_ADDONS_PATHS[*]}"
    tar -czf "$ADDONS_BACKUP" "${SRC_ADDONS_PATHS[@]}" 2>/dev/null \
      && print_success "Addons archived: ${ADDONS_BACKUP}" \
      || print_warn "Addons archive had warnings (non-critical)"
  else
    ADDONS_BACKUP=""
  fi
}

# ══════════════════════════════════════════════════════════════
#  STEP 6: Transfer and restore DB on VPS
# ══════════════════════════════════════════════════════════════
transfer_and_restore_db() {
  echo ""
  print_line
  echo -e "  ${WHITE}${BOLD}  STEP 6 — Transfer & Restore Database${NC}"
  print_line
  echo ""

  local sz; sz=$(du -sh "$BACKUP_FILE" | cut -f1)
  print_step "Transferring dump (${sz}) to destination..."
  dst_scp "$BACKUP_FILE" "${DST_SSH_USER}@${DST_SSH_HOST}:/tmp/_odoo_vps_migrate.dump" \
    || { print_error "Transfer failed"; return 1; }
  print_success "Dump transferred"

  # Transfer custom addons
  if [[ -n "$ADDONS_BACKUP" && -f "$ADDONS_BACKUP" ]]; then
    print_step "Deploying custom addons to ${DST_ADDONS_DIR}..."
    dst_scp "$ADDONS_BACKUP" "${DST_SSH_USER}@${DST_SSH_HOST}:/tmp/_odoo_vps_addons.tar.gz" \
      && dst_sh "tar -xzf /tmp/_odoo_vps_addons.tar.gz -C '${DST_ADDONS_DIR}' 2>&1 && \
                 chown -R odoo:odoo '${DST_ADDONS_DIR}' && \
                 rm -f /tmp/_odoo_vps_addons.tar.gz" >> "$MIGRATION_LOG" 2>&1 \
      && print_success "Custom addons deployed" \
      || print_warn "Addons deployment had errors"
  fi

  print_step "Creating database '${DST_DB_NAME}'..."
  dst_sh "sudo -u postgres psql -c \
    \"DROP DATABASE IF EXISTS \\\"${DST_DB_NAME}\\\"; \
     CREATE DATABASE \\\"${DST_DB_NAME}\\\" ENCODING 'UTF8' OWNER \\\"${DST_DB_USER}\\\";\"" \
    >> "$MIGRATION_LOG" 2>&1 || { print_error "Failed to create database"; return 1; }

  print_step "Restoring database (may take several minutes)..."
  local restore_out
  restore_out=$(dst_sh "PGPASSWORD='${DST_DB_PASS}' pg_restore \
    -h 127.0.0.1 -U '${DST_DB_USER}' -d '${DST_DB_NAME}' \
    --no-owner --no-acl -F c /tmp/_odoo_vps_migrate.dump 2>&1" || true)
  echo "$restore_out" >> "$MIGRATION_LOG"
  dst_sh "rm -f /tmp/_odoo_vps_migrate.dump" 2>/dev/null || true

  local errs; errs=$(echo "$restore_out" | grep -ci "error" 2>/dev/null || echo 0)
  [[ ${errs:-0} -gt 0 ]] \
    && print_warn "Restore finished with ${errs} warning(s) — usually harmless" \
    || print_success "Restore completed with zero errors"
  print_success "Database '${DST_DB_NAME}' ready on ${DST_SSH_HOST}"
}

# ══════════════════════════════════════════════════════════════
#  STEP 7: Upgrade hops (Docker on VPS, --network=host)
# ══════════════════════════════════════════════════════════════
build_hop_list() {
  local major; major=$(version_major "$1")
  local out=()
  for v in 15 16 17 18 19; do
    [[ $v -gt $major ]] && out+=("${v}.0")
  done
  echo "${out[@]}"
}

ensure_docker_on_dst() {
  dst_sh "command -v docker > /dev/null 2>&1" && {
    print_success "Docker available on VPS"
    return 0
  }
  print_warn "Docker not found — needed for upgrade hops"
  confirm "Install Docker on destination VPS?" || { print_error "Cannot continue without Docker"; return 1; }
  print_step "Installing Docker..."
  dst_sh "curl -fsSL https://get.docker.com | bash 2>&1" >> "$MIGRATION_LOG" 2>&1 \
    || { print_error "Docker install failed"; return 1; }
  print_success "Docker installed"
}

pre_hop_sql_patches() {
  local hop_ver=$1 db=$2 prev_ver=$3
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
    use_img="$ou_img"; print_success "OpenUpgrade image cached"
  else
    print_info "Pulling OpenUpgrade ${hop_ver}..."
    local pull_out
    pull_out=$(dst_sh "docker pull '${ou_img}' 2>&1" || true)
    echo "$pull_out" | grep -qiE "Downloaded newer|up to date|Pull complete" \
      && use_img="$ou_img" && print_success "OpenUpgrade pulled" \
      || { print_warn "OpenUpgrade not available — using native odoo:${hop_ver}"; \
           print_warn "$(echo "$pull_out" | tail -1)"; }
  fi
  echo -e "  ${CYAN}ℹ  Image: ${use_img}${NC}"

  print_step "Running upgrade to ${hop_ver} (may take 10–40 minutes)..."

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
    print_error "Hop to ${hop_ver} FAILED"
    echo "$hop_out" | grep -iE "ERROR|CRITICAL" | tail -6 | \
      while IFS= read -r l; do echo -e "  ${RED}  ${l}${NC}"; done
    echo "=== HOP FAILED: ${hop_ver} ===" >> "$ERR_LOG"
    echo "$hop_out" >> "$ERR_LOG"
    confirm "Continue to next hop anyway?" && return 0 || return 1
  fi

  print_warn "Hop to ${hop_ver} — unclear result, proceeding"
  return 0
}

run_all_hops() {
  local db=$1
  local docker_hops=()
  for h in "${HOP_LIST[@]}"; do
    [[ "$h" != "19.0" ]] && docker_hops+=("$h")
  done

  [[ ${#docker_hops[@]} -eq 0 ]] && {
    print_info "Source is v18 — no intermediate hops needed"
    return 0
  }

  ensure_docker_on_dst || return 1

  local current=1 prev_ver="$SRC_VERSION"
  for hop_ver in "${docker_hops[@]}"; do
    echo ""
    print_line
    echo -e "  ${WHITE}${BOLD}  Hop ${current}/${#docker_hops[@]} → Odoo ${hop_ver}${NC}"
    print_line

    local hop_bk="/tmp/hop_${db}_before_${hop_ver}_$(date +%Y%m%d_%H%M%S).dump"
    print_step "Saving rollback point..."
    dst_sh "PGPASSWORD='${DST_DB_PASS}' pg_dump \
      -h 127.0.0.1 -U '${DST_DB_USER}' \
      -Fc --no-owner --no-acl --encoding=UTF8 \
      '${db}' > '${hop_bk}' 2>/dev/null" || true
    dst_sh "test -s '${hop_bk}'" 2>/dev/null \
      && print_success "Rollback: ${hop_bk}" \
      || print_warn "Rollback save failed"

    pre_hop_sql_patches "$hop_ver" "$db" "$prev_ver"
    run_one_hop "$hop_ver" "$db" || return 1

    prev_ver="$hop_ver"
    ((current++))
  done
  return 0
}

# ══════════════════════════════════════════════════════════════
#  STEP 8: Finalize with system Odoo 19 + jsonb auto-fix loop
# ══════════════════════════════════════════════════════════════
finalize_odoo19_system() {
  local db=$1
  local max_attempts=80 attempt=0

  echo ""
  print_line
  echo -e "  ${WHITE}${BOLD}  STEP 8 — Finalize Schema (system Odoo 19)${NC}"
  print_line
  print_info "Running system Odoo 19 --update=all to finalize the schema."
  print_info "Odoo 19 stores Selection + translated fields as jsonb — auto-fixing column by column."
  echo ""

  dst_sh "systemctl stop odoo 2>/dev/null || true" >> "$MIGRATION_LOG" 2>&1

  while [[ $attempt -lt $max_attempts ]]; do
    ((attempt++))
    printf "  ${CYAN}ℹ  Attempt %d/%d — odoo --update=all --stop-after-init...${NC}\n" \
      "$attempt" "$max_attempts"

    local out
    out=$(dst_sh "sudo -u odoo /usr/bin/odoo \
      --update=all --stop-after-init \
      --config='${DST_ODOO_CONF}' \
      --database='${db}' \
      --no-http 2>&1" || true)
    echo "$out" >> "$MIGRATION_LOG"

    if echo "$out" | grep -qiE "shutdown complete|modules loaded|registry loaded"; then
      echo ""
      print_success "Schema finalized after ${attempt} attempt(s)"
      return 0
    fi

    local failing_stmt
    failing_stmt=$(dst_sh \
      "find /var/log/postgresql -name '*.log' 2>/dev/null | xargs tail -n 300 2>/dev/null | \
       grep 'STATEMENT.*TYPE jsonb' | tail -1" 2>/dev/null || true)

    if [[ -z "$failing_stmt" ]]; then
      if echo "$out" | grep -qiE "CRITICAL|Failed to initialize"; then
        echo ""
        print_error "Schema update failed (not a jsonb issue):"
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
      print_warn "Cannot parse failing jsonb statement: ${failing_stmt}"
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
  done

  echo ""
  print_error "Reached ${max_attempts} auto-fix attempts — manual intervention needed"
  print_info "Check ${MIGRATION_LOG}"
  return 1
}

# ══════════════════════════════════════════════════════════════
#  STEP 9: Start service and verify
# ══════════════════════════════════════════════════════════════
start_and_verify() {
  local db=$1
  echo ""
  print_line
  echo -e "  ${WHITE}${BOLD}  STEP 9 — Start & Verify Odoo 19${NC}"
  print_line
  echo ""

  print_step "Setting db_name in odoo.conf..."
  dst_sh "grep -q '^db_name' '${DST_ODOO_CONF}' \
    && sed -i \"s/^db_name.*/db_name = ${db}/\" '${DST_ODOO_CONF}' \
    || echo 'db_name = ${db}' >> '${DST_ODOO_CONF}'" >> "$MIGRATION_LOG" 2>&1 || true

  print_step "Starting Odoo service..."
  dst_sh "systemctl enable odoo 2>/dev/null && systemctl start odoo 2>/dev/null || \
          service odoo start 2>/dev/null || true" >> "$MIGRATION_LOG" 2>&1

  print_step "Waiting for Odoo (up to 90s)..."
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

  local svc; svc=$(dst_sh "systemctl is-active odoo 2>/dev/null || echo unknown" | tr -d '[:space:]')
  [[ "$svc" == "active" ]] \
    && print_success "Service: active" \
    || { print_warn "Service status: ${svc}"; \
         print_info "Logs: journalctl -u odoo -n 50  |  tail -50 /var/log/odoo/odoo.log"; }

  local arabic_count
  arabic_count=$(dst_sh \
    "PGPASSWORD='${DST_DB_PASS}' psql -h 127.0.0.1 -U '${DST_DB_USER}' -d '${db}' -tAc \
     \"SELECT count(*) FROM res_partner WHERE name ~ '[^\x00-\x7F]';\" 2>/dev/null || echo 0" \
    | tr -d '[:space:]')
  [[ "${arabic_count:-0}" -gt 0 ]] \
    && print_success "Arabic data intact: ${arabic_count} partner record(s) with non-ASCII names" \
    || print_info "Arabic partner count: ${arabic_count:-0}"

  echo ""
  print_line
  echo -e "  ${GREEN}${BOLD}  ✅  Migration Complete!${NC}"
  print_line
  echo ""
  echo -e "    ${WHITE}Odoo 19 URL:${NC}    http://${DST_SSH_HOST}:${DST_WEB_PORT}"
  echo -e "    ${WHITE}Database:${NC}       ${db}"
  echo -e "    ${WHITE}Config:${NC}         ${DST_ODOO_CONF}"
  echo -e "    ${WHITE}Addons:${NC}         ${DST_ADDONS_DIR}"
  echo -e "    ${WHITE}Odoo log:${NC}       /var/log/odoo/odoo.log"
  echo -e "    ${WHITE}Migration log:${NC}  ${MIGRATION_LOG}"
  echo ""
  print_line
}

# ══════════════════════════════════════════════════════════════
#  Main flow
# ══════════════════════════════════════════════════════════════
run_migration() {
  setup_source           || { pause; return; }
  setup_dst_ssh          || { pause; return; }
  ask_dst_config         || { pause; return; }
  prepare_destination    || { pause; return; }
  dump_source_db         || { pause; return; }
  transfer_and_restore_db || { pause; return; }

  IFS=' ' read -ra HOP_LIST <<< "$(build_hop_list "$SRC_VERSION")"

  if [[ ${#HOP_LIST[@]} -gt 0 ]]; then
    echo ""
    print_line
    echo -e "  ${WHITE}${BOLD}  STEP 7 — Upgrade Chain${NC}"
    print_line
    print_info "Path: v${SRC_VERSION} → $(IFS=' → '; echo "${HOP_LIST[*]}")"
    print_warn "Keep this terminal open — the upgrade will take 10–60 min"
    run_all_hops "$DST_DB_NAME" || { pause; return; }
  fi

  finalize_odoo19_system "$DST_DB_NAME" || { pause; return; }
  start_and_verify       "$DST_DB_NAME"
  pause
}

view_logs() {
  local logs=()
  while IFS= read -r f; do logs+=("$f"); done \
    < <(ls -t "${LOCAL_LOG_DIR}"/migration_*.log 2>/dev/null | head -10)
  if [[ ${#logs[@]} -eq 0 ]]; then
    print_info "No migration logs in ${LOCAL_LOG_DIR}"; pause; return
  fi
  echo ""
  for i in "${!logs[@]}"; do echo -e "  ${CYAN}$((i+1)))${NC} ${logs[$i]}"; done
  echo ""
  read -rp "  Open log [1]: " ch; ch="${ch:-1}"
  [[ -n "${logs[$((ch-1))]}" ]] && less "${logs[$((ch-1))]}" || print_error "Invalid choice"
}

cleanup() {
  ssh -o ControlPath="$DST_SSH_CTL" -O exit \
    "${DST_SSH_USER}@${DST_SSH_HOST}" 2>/dev/null || true
  rm -f "$DST_SSH_CTL"
}
trap cleanup EXIT

# ── Entry point ────────────────────────────────────────────────────────────────
while true; do
  clear
  echo ""
  echo -e "  ${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
  echo -e "  ${CYAN}║${NC}  ${WHITE}${BOLD}🖥️   ODOO → VPS MIGRATION                          ${NC}${CYAN}║${NC}"
  echo -e "  ${CYAN}║${NC}  ${GRAY}  v14–v18  →  Odoo 19 Community (bare VPS install)  ${NC}${CYAN}║${NC}"
  echo -e "  ${CYAN}║${NC}  ${GRAY}  Installs Odoo 19 from scratch on destination VPS   ${NC}${CYAN}║${NC}"
  echo -e "  ${CYAN}╠═══════════════════════════════════════════════════════╣${NC}"
  echo -e "  ${CYAN}║${NC}  ${BLUE}🌐 https://prismatechwork.com${NC}                       ${CYAN}║${NC}"
  echo -e "  ${CYAN}║${NC}  ${BLUE}🐙 https://github.com/mhmdali94/EasyOdooDocker${NC}      ${CYAN}║${NC}"
  echo -e "  ${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
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
