#!/bin/bash
# Auto-fix CRLF line endings — safe to run on any system.
# If this file was edited on Windows or transferred via certain tools,
# \r characters break heredocs. Strip them before re-executing.
if file "$0" 2>/dev/null | grep -q CRLF || \
   cat "$0" | head -5 | grep -qP '\r' 2>/dev/null; then
  echo "  Detected Windows line endings (CRLF). Converting and re-running..."
  sed -i 's/\r//' "$0" && exec bash "$0" "$@"
fi
# ============================================================
#   ODOO 14 → ODOO 14 DOCKER MIGRATION
#
#   Moves a native Odoo 14 installation into a Docker container.
#   Same version — no upgrade, just a new home.
#
#   Source:  READ-ONLY — backup via Odoo's own web API.
#            Only the master password is needed.
#            Nothing is installed, changed, or touched on prod.
#
#   Target:  Fresh Docker container running Odoo 14.
#            Can be this machine (local) or a remote server (SSH).
#
#   Steps:
#     1.  Configure source   (URL + master password + pick DB)
#     2.  Configure target   (local Docker or remote SSH)
#     3.  Download backup    (POST /web/database/backup → zip file)
#     4.  Extract backup     (dump.sql + filestore/)
#     5.  Create Docker      (PostgreSQL 13 + Odoo 14 containers)
#     6.  Restore database   (psql < dump.sql into pg container)
#     7.  Restore filestore  (copy into Docker volume)
#     8.  Migrate addons     (copy third-party addons from source)
#     9.  Start Odoo         (bring up the web container)
#     10. Verify             (HTTP check + container status)
#
#   Author:  Mohammed Ali
#   Website: https://prismatechwork.com
#   GitHub:  https://github.com/mhmdali94/EasyOdooDocker
# ============================================================

# Interactive wizard — strict pipefail/errexit would exit on every
# non-zero return (e.g. grep with no matches). We use explicit exit 1
# calls instead and protect all detection code with || true.

# ── Colors ───────────────────────────────────────────────────
RED='\033[0;31m';    GREEN='\033[0;32m';   YELLOW='\033[1;33m'
BLUE='\033[0;34m';   CYAN='\033[0;36m';    MAGENTA='\033[0;35m'
WHITE='\033[1;37m';  GRAY='\033[0;37m';    BOLD='\033[1m';  NC='\033[0m'

# ── Global state ─────────────────────────────────────────────

# Source (production — read-only, never touched)
SRC_URL=""           # e.g. http://192.168.1.10:8069
SRC_MASTER_PASS=""   # admin_passwd from odoo.conf
SRC_DB=""            # database name to backup

# Destination
DST_TYPE="local"     # local | remote
DST_SSH_USER=""
DST_SSH_HOST=""
DST_SSH_PORT="22"
DST_SSH_KEY=""       # path to private key file (key auth)
DST_SSH_PASS=""      # password (password auth — uses sshpass)
DST_SSH_AUTH=""      # key | password
DST_SSH_CTL=""       # ControlMaster socket — reused for all SSH calls

DST_INSTANCE_NAME="odoo14"
DST_BASE_DIR=""      # set after instance name is chosen
DST_WEB_PORT="8069"
DST_LONGPOLL_PORT="8072"
DST_PG_USER="odoo14"
DST_PG_PASS=""
DST_MASTER_PASS=""
DST_DB=""            # target DB name (defaults to SRC_DB)

# Python dependencies collected from custom addon manifests
ADDON_PY_DEPS=""

# Files
WORK_DIR="$HOME/odoo_migration_work"
BACKUP_ZIP=""        # path to downloaded .zip
EXTRACT_DIR=""       # path to extracted backup contents

# ── Print helpers ────────────────────────────────────────────
print_banner() {
  clear
  echo -e "${CYAN}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════════╗"
  echo "  ║   🐳  ODOO 14 → ODOO 14 DOCKER MIGRATION               ║"
  echo "  ║   Move native Odoo 14 into a Docker container            ║"
  echo "  ║   Production server: READ-ONLY (backup API only)         ║"
  echo "  ╠══════════════════════════════════════════════════════════╣"
  echo -e "  ║  ${GRAY}🌐  https://prismatechwork.com${CYAN}                           ║"
  echo -e "  ║  ${GRAY}🐙  github.com/mhmdali94/EasyOdooDocker${CYAN}                  ║"
  echo "  ╚══════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

print_line()    { echo -e "${GRAY}  ──────────────────────────────────────────────────────────${NC}"; }
print_success() { echo -e "  ${GREEN}✔  $1${NC}"; }
print_error()   { echo -e "  ${RED}✖  $1${NC}"; }
print_warn()    { echo -e "  ${YELLOW}⚠  $1${NC}"; }
print_info()    { echo -e "  ${CYAN}ℹ  $1${NC}"; }
print_step()    { echo -e "\n${MAGENTA}${BOLD}  ▶  $1${NC}"; }

pause() {
  echo ""
  read -rp "  $(echo -e "${GRAY}Press [Enter] to continue...${NC}")" _
}

ask() {
  # ask "prompt text" "default" varname
  # Uses echo -en so ANSI color codes in the prompt are actually rendered.
  # read -rp does NOT process \033 escape sequences on all systems.
  local prompt="$1" default="$2" var_name="$3"
  if [[ -n "$default" ]]; then
    echo -en "  $prompt [${CYAN}${default}${NC}]: "
    read -r _v
    printf -v "$var_name" '%s' "${_v:-$default}"
  else
    echo -en "  $prompt: "
    read -r _v
    printf -v "$var_name" '%s' "$_v"
  fi
}

ask_secret() {
  local prompt="$1" var_name="$2"
  read -rsp "  $prompt: " _v
  echo ""
  printf -v "$var_name" '%s' "$_v"
}

rand_pass() {
  # Generate a random 20-char password without special chars
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 20 || echo "Odoo14Pass$(date +%s)"
}

# ── SSH helpers ───────────────────────────────────────────────
#
# Strategy:
#   Key auth   → ControlMaster (one connection, multiplexed)
#   Password   → sshpass on EVERY command (no mux socket to die)
#
# The ControlMaster approach is unreliable with password auth because
# the background master process can die between steps, leaving a stale
# socket that causes "Master refused session request" errors.
# Running sshpass per-command is slightly slower but always works.

# Build the base SSH options string (no auth-specific flags)
_ssh_base_opts() {
  # ServerAliveInterval keeps the connection alive during long operations (large restore dumps).
  # -T disables PTY allocation — not needed for scripted commands and avoids interference.
  echo "-T -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -o ServerAliveInterval=60 -o ServerAliveCountMax=20 -p ${DST_SSH_PORT}"
}

# Verify SSH connectivity and set up ControlMaster for key auth
open_ssh_mux() {
  mkdir -p "$WORK_DIR"
  print_info "Testing SSH connection to ${DST_SSH_USER}@${DST_SSH_HOST}:${DST_SSH_PORT}..."

  if [[ "$DST_SSH_AUTH" == "key" ]]; then
    # Key auth — establish a ControlMaster that lives for the whole script
    DST_SSH_CTL="$WORK_DIR/.ssh_ctl_$$"
    rm -f "$DST_SSH_CTL"
    local base_opts; base_opts=$(_ssh_base_opts)
    # shellcheck disable=SC2086
    ssh $base_opts \
      -o ControlMaster=yes -o ControlPersist=4h \
      -o BatchMode=yes \
      -i "${DST_SSH_KEY}" \
      -S "${DST_SSH_CTL}" \
      -N -M \
      "${DST_SSH_USER}@${DST_SSH_HOST}" 2>/dev/null &
    sleep 3
    if ssh -S "$DST_SSH_CTL" -O check "${DST_SSH_USER}@${DST_SSH_HOST}" 2>/dev/null; then
      print_success "SSH connected (key auth, ControlMaster active)"
    else
      print_error "Cannot connect to ${DST_SSH_HOST} with key ${DST_SSH_KEY}"
      print_info  "Test:  ssh -i ${DST_SSH_KEY} -p ${DST_SSH_PORT} ${DST_SSH_USER}@${DST_SSH_HOST}"
      exit 1
    fi

  elif [[ "$DST_SSH_AUTH" == "password" ]]; then
    # Password auth — verify once now; every dst() call uses sshpass directly
    DST_SSH_CTL=""
    if ! command -v sshpass &>/dev/null; then
      print_error "sshpass is required for password authentication."
      print_info  "Install:  apt-get install sshpass"
      exit 1
    fi
    local base_opts; base_opts=$(_ssh_base_opts)
    local result
    # shellcheck disable=SC2086
    result=$(sshpass -p "${DST_SSH_PASS}" \
      ssh $base_opts \
      -o BatchMode=no -o PasswordAuthentication=yes \
      "${DST_SSH_USER}@${DST_SSH_HOST}" \
      "echo ok" 2>/dev/null) || result=""
    if [[ "$result" == "ok" ]]; then
      print_success "SSH connected (password auth)"
    else
      print_error "Cannot connect to ${DST_SSH_HOST} — wrong password or password auth disabled."
      print_info  "Test:  ssh -p ${DST_SSH_PORT} ${DST_SSH_USER}@${DST_SSH_HOST}"
      exit 1
    fi
  fi
}

close_ssh_mux() {
  # Only key auth uses a socket; password auth has nothing to close
  if [[ -n "$DST_SSH_CTL" && -S "$DST_SSH_CTL" ]]; then
    ssh -S "$DST_SSH_CTL" -O exit "${DST_SSH_USER}@${DST_SSH_HOST}" 2>/dev/null || true
  fi
}

# Run a command on the destination (local or remote)
dst() {
  if [[ "$DST_TYPE" == "remote" ]]; then
    local base_opts; base_opts=$(_ssh_base_opts)
    if [[ "$DST_SSH_AUTH" == "password" ]]; then
      # shellcheck disable=SC2086
      sshpass -p "${DST_SSH_PASS}" \
        ssh $base_opts \
        -o BatchMode=no -o PasswordAuthentication=yes \
        "${DST_SSH_USER}@${DST_SSH_HOST}" "$@"
    else
      ssh -S "$DST_SSH_CTL" "${DST_SSH_USER}@${DST_SSH_HOST}" "$@"
    fi
  else
    bash -c "$*"
  fi
}

# Transfer a local file/dir to the destination
dst_put() {
  local src="$1" dest_dir="$2"
  if [[ "$DST_TYPE" == "remote" ]]; then
    local base_opts; base_opts=$(_ssh_base_opts)
    if [[ "$DST_SSH_AUTH" == "password" ]]; then
      sshpass -p "${DST_SSH_PASS}" \
        rsync -az --progress \
        -e "ssh $base_opts -o BatchMode=no -o PasswordAuthentication=yes" \
        "$src" "${DST_SSH_USER}@${DST_SSH_HOST}:${dest_dir}/"
    else
      rsync -az --progress \
        -e "ssh -S '${DST_SSH_CTL}' -p ${DST_SSH_PORT}" \
        "$src" "${DST_SSH_USER}@${DST_SSH_HOST}:${dest_dir}/"
    fi
  else
    cp -r "$src" "$dest_dir/"
  fi
}

# ── Dependency check ──────────────────────────────────────────
check_deps() {
  print_step "Checking local dependencies"
  local missing=()
  for cmd in curl unzip python3; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    print_error "Missing on this machine: ${missing[*]}"
    print_info  "Install: brew install ${missing[*]}  (macOS)"
    print_info  "      or: apt install ${missing[*]}  (Debian/Ubuntu)"
    exit 1
  fi
  print_success "curl, unzip, python3 — all found"
}

# ── Auto-detect running Odoo (read-only, no changes) ─────────
#
# Populates globals: ODOO_CONF_PATH, SRC_DB_HINT,
#                    SRC_PASS_HINT, SRC_PORT_HINT, ODOO_ADDONS_HINT
#
# Every command here uses || true so a detection failure never
# crashes the script — all values gracefully fall back to "".
#
_detect_local_odoo() {
  ODOO_CONF_PATH=""
  SRC_DB_HINT=""
  SRC_PASS_HINT=""
  SRC_PORT_HINT=""
  ODOO_ADDONS_HINT=""

  # ── 1. Find odoo.conf ──────────────────────────────────────
  local conf=""
  local candidate
  for candidate in \
      /etc/odoo/odoo.conf \
      /etc/odoo.conf \
      /etc/odoo-server.conf \
      /etc/odoo14.conf \
      /etc/odoo14-server.conf \
      /etc/odoo15.conf \
      /etc/odoo16.conf \
      /etc/odoo17.conf \
      /opt/odoo/odoo.conf \
      /opt/odoo/conf/odoo.conf \
      /home/odoo/odoo.conf \
      /home/odoo/conf/odoo.conf \
      /odoo/odoo.conf \
      /odoo/conf/odoo.conf \
      /odoo/odoo-server/odoo.conf \
      /usr/lib/python3/dist-packages/odoo/odoo.conf
  do
    if [ -f "$candidate" ]; then
      conf="$candidate"
      break
    fi
  done

  # If not found via fixed paths, try reading from the running process args
  if [ -z "$conf" ]; then
    local proc_conf
    proc_conf=$(ps aux 2>/dev/null \
      | grep -E 'odoo-bin|odoo\.py|odoo-server' \
      | grep -v grep \
      | sed -n 's/.*-c[= ]\([^ ]*\.conf\).*/\1/p;s/.*--config[= ]\([^ ]*\).*/\1/p' \
      | head -1) || proc_conf=""
    if [ -n "$proc_conf" ] && [ -f "$proc_conf" ]; then
      conf="$proc_conf"
    fi
  fi

  # Last resort: search /etc for any .conf containing addons_path
  if [ -z "$conf" ]; then
    conf=$(find /etc -maxdepth 3 -name "*.conf" 2>/dev/null \
      | xargs grep -l "addons_path" 2>/dev/null \
      | head -1) || conf=""
  fi

  # ── 2. Read values from the conf file (all with || true) ───
  if [ -n "$conf" ] && [ -f "$conf" ]; then
    ODOO_CONF_PATH="$conf"

    local db mp port

    # db_name
    db=$(grep -E '^[[:space:]]*db_name[[:space:]]*=' "$conf" 2>/dev/null \
         | head -1 \
         | sed 's/^[^=]*=[[:space:]]*//' \
         | tr -d '[:space:]') || db=""
    if [ -n "$db" ] && [ "$db" != "False" ] && [ "$db" != "false" ]; then
      SRC_DB_HINT="$db"
    fi

    # admin_passwd
    mp=$(grep -E '^[[:space:]]*admin_passwd[[:space:]]*=' "$conf" 2>/dev/null \
         | head -1 \
         | sed 's/^[^=]*=[[:space:]]*//' \
         | tr -d '[:space:]') || mp=""
    if [ -n "$mp" ] && [ "$mp" != "admin" ]; then
      SRC_PASS_HINT="$mp"
    fi

    # xmlrpc_port / http_port (try both key names)
    port=$(grep -E '^[[:space:]]*(xmlrpc_port|http_port)[[:space:]]*=' "$conf" 2>/dev/null \
           | head -1 \
           | sed 's/^[^=]*=[[:space:]]*//' \
           | tr -d '[:space:]') || port=""
    if [ -n "$port" ] && echo "$port" | grep -qE '^[0-9]+$'; then
      SRC_PORT_HINT="$port"
    fi

    # addons_path — read the raw comma-separated value; step_migrate_addons will parse it
    local ap
    ap=$(grep -E '^[[:space:]]*addons_path[[:space:]]*=' "$conf" 2>/dev/null \
         | head -1 \
         | sed 's/^[^=]*=[[:space:]]*//' \
         | tr -d '\r') || ap=""
    [ -n "$ap" ] && ODOO_ADDONS_HINT="$ap"
  fi

  # ── 3. Detect addons_path from running process args ────────
  if [ -z "$ODOO_ADDONS_HINT" ]; then
    local proc_addons
    proc_addons=$(ps aux 2>/dev/null \
      | grep -E 'odoo-bin|odoo\.py' \
      | grep -v grep \
      | sed -n 's/.*--addons-path[= ]\([^ ]*\).*/\1/p' \
      | head -1) || proc_addons=""
    [ -n "$proc_addons" ] && ODOO_ADDONS_HINT="$proc_addons"
  fi

  # ── 4. Search filesystem for __manifest__.py files ─────────
  # When neither the conf file nor process args reveal the addons path,
  # find it by locating Odoo module directories (they always contain
  # __manifest__.py). The parent of those dirs is the addons directory.
  if [ -z "$ODOO_ADDONS_HINT" ]; then
    local _found_dirs=""
    local _root
    for _root in \
        /odoo /odoo/custom /odoo/home \
        /opt/odoo /opt/odoo14 /opt/odoo-server /opt/odoo-ce \
        /home/odoo /home/odoo14 \
        /srv/odoo \
        /root/odoo \
        /var/lib/odoo \
        /odoo/odoo-server
    do
      [ -d "$_root" ] || continue
      # Find __manifest__.py files up to depth 6, skip .git and dist-packages
      local _hits
      _hits=$(find "$_root" -maxdepth 6 -name "__manifest__.py" \
        -not -path "*/.git/*" \
        -not -path "*/dist-packages/*" \
        -not -path "*/site-packages/*" \
        2>/dev/null | head -30) || continue
      [ -z "$_hits" ] && continue
      # Each manifest is at <addons_dir>/<module>/__manifest__.py
      # so dirname twice gives the addons_dir
      local _dirs
      _dirs=$(printf '%s\n' "$_hits" | while IFS= read -r _m; do
        _mod="$(dirname "$_m")"
        dirname "$_mod"
      done | sort -u)
      [ -n "$_dirs" ] && _found_dirs=$(printf '%s\n%s' "$_found_dirs" "$_dirs")
    done
    if [ -n "$_found_dirs" ]; then
      # Build comma-separated list of unique non-standard paths
      local _unique_custom
      _unique_custom=$(printf '%s\n' "$_found_dirs" \
        | grep -v '^$' \
        | sort -u \
        | while IFS= read -r _d; do
            case "$_d" in
              */dist-packages/odoo/addons*) ;;
              */site-packages/odoo/addons*) ;;
              /usr/lib/python3*)            ;;
              /usr/local/lib/python3*)      ;;
              *) echo "$_d" ;;
            esac
          done \
        | tr '\n' ',' | sed 's/,$//')
      [ -n "$_unique_custom" ] && ODOO_ADDONS_HINT="$_unique_custom"
    fi
  fi

  # ── 6. Detect port from running process args ───────────────
  if [ -z "$SRC_PORT_HINT" ]; then
    local proc_port
    proc_port=$(ps aux 2>/dev/null \
      | grep -E 'odoo-bin|odoo\.py' \
      | grep -v grep \
      | grep -oE '\-\-(http-port|xmlrpc-port) [0-9]+|\-\-(http-port|xmlrpc-port)=[0-9]+' \
      | grep -oE '[0-9]+' \
      | head -1) || proc_port=""
    if [ -n "$proc_port" ] && echo "$proc_port" | grep -qE '^[0-9]+$'; then
      SRC_PORT_HINT="$proc_port"
    fi
  fi

  # ── 7. Live-probe common ports ─────────────────────────────
  if [ -z "$SRC_PORT_HINT" ]; then
    local p code
    for p in 8069 8070 8071 8072; do
      code=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 3 "http://localhost:$p/web/login" 2>/dev/null) || code="000"
      if [ "$code" = "200" ] || [ "$code" = "302" ] || [ "$code" = "303" ]; then
        SRC_PORT_HINT="$p"
        break
      fi
    done
  fi

  # ── 8. Final fallback ──────────────────────────────────────
  if [ -z "$SRC_PORT_HINT" ]; then
    SRC_PORT_HINT="8069"
  fi
}

# ── STEP 1: Source configuration ─────────────────────────────
step_source() {
  print_step "Step 1 of 10 — Configure source (production server)"
  print_line
  print_info "Running ON this Odoo server — detecting configuration..."
  echo ""

  # ── Auto-detect everything we can ─────────────────────────
  _detect_local_odoo

  # Report what was found
  if [[ -n "$ODOO_CONF_PATH" ]]; then
    print_success "odoo.conf found: $ODOO_CONF_PATH"
  else
    print_warn "No odoo.conf found — will use manual values."
  fi
  print_success "Odoo port detected: ${SRC_PORT_HINT}"
  [[ -n "$SRC_DB_HINT"      ]] && print_success "Database detected:    ${SRC_DB_HINT}"
  [[ -n "$SRC_PASS_HINT"   ]] && print_success "Master password:      (read from conf)"
  [[ -n "$ODOO_ADDONS_HINT" ]] && print_success "addons_path detected: ${ODOO_ADDONS_HINT}"
  echo ""

  # ── Build and confirm the source URL ──────────────────────
  local auto_url="http://localhost:${SRC_PORT_HINT}"
  ask "Source Odoo URL" "$auto_url" SRC_URL
  SRC_URL="${SRC_URL%/}"

  # ── Verify Odoo is actually responding ────────────────────
  echo ""
  print_info "Testing connection..."
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 10 "$SRC_URL/web/login" 2>/dev/null || echo "000")

  case "$http_code" in
    200|302|303)
      print_success "Odoo is up at $SRC_URL" ;;
    000)
      print_error "Cannot connect to $SRC_URL"
      print_warn  "Is Odoo running?  sudo systemctl status odoo"
      exit 1 ;;
    404)
      print_error "Got 404 — Odoo is NOT on this URL/port."
      print_warn  "Try: http://localhost:8069  or  http://localhost:8070"
      print_info  "Check which port Odoo listens on:  sudo ss -tlnp | grep odoo"
      exit 1 ;;
    *)
      print_warn "Unexpected HTTP $http_code — proceeding cautiously." ;;
  esac

  # ── Master password ────────────────────────────────────────
  echo ""
  if [[ -n "$SRC_PASS_HINT" ]]; then
    print_info "Master password pre-filled from odoo.conf. Press Enter to accept."
    echo -en "  Master password [${CYAN}(from conf)${NC}]: "
    read -rsp "" _mp
    echo ""
    SRC_MASTER_PASS="${_mp:-$SRC_PASS_HINT}"
  else
    ask_secret "Master password (admin_passwd from odoo.conf)" SRC_MASTER_PASS
  fi
  [[ -z "$SRC_MASTER_PASS" ]] && { print_error "Master password is required."; exit 1; }

  # ── List / pick database ───────────────────────────────────
  echo ""
  print_info "Fetching database list..."
  local raw_dbs
  raw_dbs=$(curl -s --connect-timeout 15 \
    -X POST "$SRC_URL/jsonrpc" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"call","id":1,"params":{"service":"db","method":"list","args":[]}}' \
    2>/dev/null || true)

  local db_list
  db_list=$(echo "$raw_dbs" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); [print(x) for x in d.get('result',[])]" \
    2>/dev/null || true)

  if [[ -z "$db_list" ]]; then
    print_warn "Could not fetch DB list (Odoo may hide it — this is normal)."
    ask "Database name to migrate" "${SRC_DB_HINT:-}" SRC_DB
  else
    print_success "Databases found on this server:"
    echo ""
    local i=1
    local -a db_arr=()
    while IFS= read -r db; do
      [[ -z "$db" ]] && continue
      echo -e "    ${CYAN}[$i]${NC}  $db"
      db_arr+=("$db")
      ((i++))
    done <<< "$db_list"
    echo ""
    # Auto-select the db from conf if it's in the list
    local default_pick=1
    for idx in "${!db_arr[@]}"; do
      [[ "${db_arr[$idx]}" == "$SRC_DB_HINT" ]] && { default_pick=$((idx + 1)); break; }
    done
    local pick
    ask "Select database number" "$default_pick" pick
    SRC_DB="${db_arr[$((pick - 1))]:-}"
  fi

  [[ -z "$SRC_DB" ]] && { print_error "No database selected."; exit 1; }
  print_success "Source: $SRC_URL  |  Database: $SRC_DB"
}

# ── STEP 2: Destination configuration ────────────────────────
step_destination() {
  print_step "Step 2 of 10 — Configure destination"
  print_line
  echo ""

  echo -e "  Where should the new Docker Odoo 14 container run?"
  echo -e "    ${CYAN}[1]${NC}  This server  (local Docker — same machine as production)"
  echo -e "    ${CYAN}[2]${NC}  A different server (SSH)"
  echo ""
  print_warn "If you choose [1], Docker will run ALONGSIDE native Odoo on this machine."
  print_info "The Docker container will get a different port (e.g. 8070) so both can coexist."
  echo ""
  local choice
  ask "Choice" "1" choice

  if [[ "$choice" == "2" ]]; then
    DST_TYPE="remote"
    echo ""
    ask "SSH host or IP"   ""     DST_SSH_HOST
    ask "SSH user"         "root" DST_SSH_USER
    ask "SSH port"         "22"   DST_SSH_PORT

    echo ""
    echo -e "  SSH authentication method:"
    echo -e "    ${CYAN}[1]${NC}  Password  (type your server password)"
    echo -e "    ${CYAN}[2]${NC}  SSH key   (path to a private key file)"
    echo ""
    local auth_choice
    ask "Auth method" "1" auth_choice

    if [[ "$auth_choice" == "2" ]]; then
      DST_SSH_AUTH="key"
      ask "Path to private key file" "$HOME/.ssh/id_rsa" DST_SSH_KEY
      if [[ ! -f "$DST_SSH_KEY" ]]; then
        print_error "Key file not found: $DST_SSH_KEY"
        exit 1
      fi
      print_success "Key: $DST_SSH_KEY"
    else
      DST_SSH_AUTH="password"
      ask_secret "SSH password for ${DST_SSH_USER}@${DST_SSH_HOST}" DST_SSH_PASS
      if [[ -z "$DST_SSH_PASS" ]]; then
        print_error "Password cannot be empty."
        exit 1
      fi
    fi

    echo ""
    open_ssh_mux
  else
    DST_TYPE="local"
    if ! command -v docker &>/dev/null; then
      print_error "Docker is not installed on this server."
      print_info  "Install it with:  curl -fsSL https://get.docker.com | sh"
      exit 1
    fi
    if ! docker info &>/dev/null; then
      print_error "Docker daemon is not running."
      print_info  "Start it with:  sudo systemctl start docker"
      exit 1
    fi
    print_success "Docker is running"
  fi

  # ── Instance details ───────────────────────────────────────
  echo ""
  ask "Instance name (used for container/folder names)" "odoo14docker" DST_INSTANCE_NAME

  if [[ "$DST_TYPE" == "remote" ]]; then
    DST_BASE_DIR="/opt/odoo/${DST_INSTANCE_NAME}"
  else
    DST_BASE_DIR="/opt/odoo-docker/${DST_INSTANCE_NAME}"
  fi

  # ── Port — warn if 8069 is already taken locally ──────────
  local default_web_port="8069"
  if [[ "$DST_TYPE" == "local" ]] && ss -tlnp 2>/dev/null | grep -q ':8069 ' || \
     [[ "$DST_TYPE" == "local" ]] && netstat -tlnp 2>/dev/null | grep -q ':8069 '; then
    default_web_port="8070"
    print_warn "Port 8069 is in use (native Odoo). Defaulting Docker to port 8070."
    print_info "You can change this to any free port."
  fi

  # Ask for port and re-prompt until a valid number is given
  while true; do
    ask "Docker web port" "$default_web_port" DST_WEB_PORT
    if echo "$DST_WEB_PORT" | grep -qE '^[0-9]+$' && \
       [ "$DST_WEB_PORT" -ge 1 ] && [ "$DST_WEB_PORT" -le 65535 ]; then
      break
    fi
    print_error "  '$DST_WEB_PORT' is not a valid port number. Enter a number between 1 and 65535."
  done

  while true; do
    ask "Docker longpolling port" "8072" DST_LONGPOLL_PORT
    if echo "$DST_LONGPOLL_PORT" | grep -qE '^[0-9]+$' && \
       [ "$DST_LONGPOLL_PORT" -ge 1 ] && [ "$DST_LONGPOLL_PORT" -le 65535 ]; then
      break
    fi
    print_error "  '$DST_LONGPOLL_PORT' is not a valid port number. Enter a number between 1 and 65535."
  done
  ask "PostgreSQL user"                           "odoo14" DST_PG_USER

  local default_pg_pass; default_pg_pass=$(rand_pass)
  ask "PostgreSQL password"                       "$default_pg_pass" DST_PG_PASS

  local default_master; default_master=$(rand_pass)
  ask "New Odoo master password (for Docker instance)" "$default_master" DST_MASTER_PASS

  # ── Target DB name ─────────────────────────────────────────
  ask "Target database name (inside Docker)" "$SRC_DB" DST_DB

  echo ""
  print_success "Destination configured:"
  print_info "  Type:         $DST_TYPE"
  print_info "  Directory:    $DST_BASE_DIR"
  print_info "  Web port:     $DST_WEB_PORT"
  print_info "  Database:     $DST_DB"
  print_line
}

# ── STEP 3: Download backup from source ──────────────────────
step_download() {
  print_step "Step 3 of 10 — Download backup from production (read-only)"
  print_line
  print_info "Calling POST /web/database/backup on source."
  print_info "This only reads the database — nothing is modified on prod."
  print_warn "Large databases may take several minutes to download."
  echo ""

  mkdir -p "$WORK_DIR"

  # Clean up any stale zip/extract from a previous failed run for this DB
  rm -f "$WORK_DIR/${SRC_DB}_"*.zip 2>/dev/null || true
  rm -rf "$WORK_DIR/${SRC_DB}_"*/ 2>/dev/null || true

  BACKUP_ZIP="$WORK_DIR/${SRC_DB}_$(date +%Y%m%d_%H%M%S).zip"

  # Write the HTTP status code to a separate temp file so the progress
  # bar can still print to the terminal (no 2>&1 that would swallow it).
  local http_code_file="$WORK_DIR/.http_code_$$"

  curl \
    --connect-timeout 30 \
    --max-time 7200 \
    -w "%{http_code}" \
    -o "$BACKUP_ZIP" \
    --progress-bar \
    -X POST "$SRC_URL/web/database/backup" \
    -F "master_pwd=${SRC_MASTER_PASS}" \
    -F "name=${SRC_DB}" \
    -F "backup_format=zip" \
    > "$http_code_file" 2>/dev/null
  echo ""   # newline after progress bar

  local http_code
  http_code=$(cat "$http_code_file" 2>/dev/null || echo "000")
  rm -f "$http_code_file"

  # ── Non-200: the response body is text (HTML/JSON error) ──
  if [[ "$http_code" != "200" ]]; then
    print_error "Server returned HTTP $http_code"
    if [[ -f "$BACKUP_ZIP" ]]; then
      # Safe to read as text only when it's an error response (not a zip)
      local errmsg
      errmsg=$(strings "$BACKUP_ZIP" 2>/dev/null | head -5 | tr '\n' ' ') || \
      errmsg=$(head -c 300 "$BACKUP_ZIP" 2>/dev/null | tr -dc '[:print:]') || \
      errmsg=""
      if echo "$errmsg" | grep -qi "wrong master\|AccessDenied\|Forbidden"; then
        print_error "Wrong master password."
      elif [[ -n "$errmsg" ]]; then
        print_error "Server said: $errmsg"
      fi
    fi
    rm -f "$BACKUP_ZIP"
    exit 1
  fi

  # ── HTTP 200: file must exist and be a valid zip ───────────
  if [[ ! -f "$BACKUP_ZIP" ]]; then
    print_error "Backup file was not created."
    exit 1
  fi

  local fsize
  fsize=$(stat -f%z "$BACKUP_ZIP" 2>/dev/null || stat -c%s "$BACKUP_ZIP" 2>/dev/null || echo 0)

  # A real backup is always larger than a few KB.
  # An error page (wrong password HTML) would be tiny.
  if [[ "$fsize" -lt 10000 ]]; then
    print_error "File is only ${fsize} bytes — looks like an error page, not a backup."
    local errmsg
    errmsg=$(strings "$BACKUP_ZIP" 2>/dev/null | head -5 | tr '\n' ' ') || errmsg=""
    [[ -n "$errmsg" ]] && print_error "Content: $errmsg"
    rm -f "$BACKUP_ZIP"
    exit 1
  fi

  # Confirm it is actually a zip
  if ! unzip -t "$BACKUP_ZIP" &>/dev/null; then
    print_error "Downloaded file is not a valid zip archive."
    exit 1
  fi

  local human_size
  human_size=$(du -sh "$BACKUP_ZIP" | cut -f1)
  print_success "Backup downloaded: $BACKUP_ZIP  ($human_size)"
}

# ── STEP 4: Extract backup ────────────────────────────────────
step_extract() {
  print_step "Step 4 of 10 — Extract backup"
  print_line

  EXTRACT_DIR="${BACKUP_ZIP%.zip}"
  rm -rf "$EXTRACT_DIR"
  mkdir -p "$EXTRACT_DIR"

  print_info "Extracting to: $EXTRACT_DIR"
  unzip -q "$BACKUP_ZIP" -d "$EXTRACT_DIR"

  # Validate expected contents
  if [[ ! -f "$EXTRACT_DIR/dump.sql" ]]; then
    print_error "dump.sql not found in backup archive."
    print_info "Archive contents:"
    ls -la "$EXTRACT_DIR/"
    exit 1
  fi

  local sql_size; sql_size=$(du -sh "$EXTRACT_DIR/dump.sql" | cut -f1)
  print_success "dump.sql  ($sql_size)"

  if [[ -d "$EXTRACT_DIR/filestore" ]]; then
    local fs_size; fs_size=$(du -sh "$EXTRACT_DIR/filestore" | cut -f1)
    print_success "filestore/  ($fs_size)"
  else
    print_warn "No filestore/ in backup — OK if no file attachments."
  fi
}

# ── STEP 5: Create Docker instance ───────────────────────────
step_create_docker() {
  print_step "Step 5 of 10 — Create Docker Odoo 14 instance on destination"
  print_line

  # ── Install Docker on remote if missing ───────────────────
  if [[ "$DST_TYPE" == "remote" ]]; then
    print_info "Checking Docker on ${DST_SSH_HOST}..."
    if ! dst "command -v docker &>/dev/null"; then
      print_info "Installing Docker..."
      dst "curl -fsSL https://get.docker.com | sh && systemctl enable --now docker"
      print_success "Docker installed"
    else
      print_success "Docker already installed"
    fi
    # Ensure docker compose (v2 plugin) is available
    if ! dst "docker compose version" > /dev/null 2>&1; then
      print_info "Installing docker-compose-plugin..."
      dst "apt-get install -y docker-compose-plugin 2>/dev/null || true"
    fi
    if ! dst "docker compose version" > /dev/null 2>&1; then
      print_error "docker compose v2 is not available on ${DST_SSH_HOST}."
      print_info  "Install manually: apt-get install docker-compose-plugin"
      exit 1
    fi
    print_success "docker compose v2 available"
  fi

  # ── Wipe any previous containers + DB volume for this instance ──
  # POSTGRES_PASSWORD is only applied on FIRST volume initialization.
  # If we reuse an old volume, postgres keeps the old password → auth fail.
  # Solution: always start fresh. Odoo data volume is wiped too for consistency.
  print_info "Removing any previous containers and volumes for '${DST_INSTANCE_NAME}'..."
  dst "docker stop ${DST_INSTANCE_NAME}_odoo ${DST_INSTANCE_NAME}_db 2>/dev/null; \
       docker rm   ${DST_INSTANCE_NAME}_odoo ${DST_INSTANCE_NAME}_db 2>/dev/null; \
       docker volume rm ${DST_INSTANCE_NAME}_db_data ${DST_INSTANCE_NAME}_odoo_data 2>/dev/null; \
       true"
  print_success "Clean slate — old containers/volumes removed (or didn't exist)"

  # ── Create directory structure ─────────────────────────────
  print_info "Creating directory structure..."
  # logs dir gets open permissions so the container's odoo user can write to it
  dst "mkdir -p '${DST_BASE_DIR}/addons' '${DST_BASE_DIR}/config' '${DST_BASE_DIR}/logs' && chmod 777 '${DST_BASE_DIR}/logs'"

  # ── Write odoo.conf ────────────────────────────────────────
  # Uses printf instead of a heredoc — immune to CRLF line endings.
  print_info "Writing odoo.conf..."
  local conf
  conf=$(printf '%s\n' \
    '[options]' \
    "admin_passwd = ${DST_MASTER_PASS}" \
    'db_host = db' \
    'db_port = 5432' \
    "db_user = ${DST_PG_USER}" \
    "db_password = ${DST_PG_PASS}" \
    'addons_path = /mnt/extra-addons,/usr/lib/python3/dist-packages/odoo/addons' \
    'data_dir = /var/lib/odoo' \
    'logfile = /var/log/odoo/odoo.log' \
    'log_level = info' \
    'workers = 0' \
    'proxy_mode = True')

  if [[ "$DST_TYPE" == "remote" ]]; then
    echo "$conf" | dst "cat > '${DST_BASE_DIR}/config/odoo.conf'"
  else
    echo "$conf" > "${DST_BASE_DIR}/config/odoo.conf"
  fi

  # ── Write docker-compose.yml ───────────────────────────────
  # Uses printf instead of a heredoc — immune to CRLF line endings.
  print_info "Writing docker-compose.yml..."
  local compose
  compose=$(printf '%s\n' \
    'services:' \
    '' \
    '  db:' \
    '    image: postgres:13' \
    "    container_name: ${DST_INSTANCE_NAME}_db" \
    '    restart: unless-stopped' \
    '    environment:' \
    "      POSTGRES_USER: ${DST_PG_USER}" \
    "      POSTGRES_PASSWORD: ${DST_PG_PASS}" \
    '      POSTGRES_DB: postgres' \
    '    volumes:' \
    '      - db_data:/var/lib/postgresql/data' \
    '    networks:' \
    '      - odoo_net' \
    '' \
    '  odoo:' \
    '    image: odoo:14.0' \
    "    container_name: ${DST_INSTANCE_NAME}_odoo" \
    '    restart: unless-stopped' \
    '    depends_on:' \
    '      - db' \
    '    ports:' \
    "      - \"${DST_WEB_PORT}:8069\"" \
    "      - \"${DST_LONGPOLL_PORT}:8072\"" \
    '    volumes:' \
    '      - odoo_data:/var/lib/odoo' \
    "      - ${DST_BASE_DIR}/config:/etc/odoo" \
    "      - ${DST_BASE_DIR}/addons:/mnt/extra-addons" \
    "      - ${DST_BASE_DIR}/logs:/var/log/odoo" \
    '    networks:' \
    '      - odoo_net' \
    '' \
    'volumes:' \
    '  db_data:' \
    "    name: ${DST_INSTANCE_NAME}_db_data" \
    '  odoo_data:' \
    "    name: ${DST_INSTANCE_NAME}_odoo_data" \
    '' \
    'networks:' \
    '  odoo_net:' \
    "    name: ${DST_INSTANCE_NAME}_net")

  if [[ "$DST_TYPE" == "remote" ]]; then
    echo "$compose" | dst "cat > '${DST_BASE_DIR}/docker-compose.yml'"
  else
    echo "$compose" > "${DST_BASE_DIR}/docker-compose.yml"
  fi

  # ── Start only the DB container ────────────────────────────
  print_info "Starting PostgreSQL container (db only)..."
  dst "cd '${DST_BASE_DIR}' && docker compose up -d db"

  # Wait up to 180 s for PostgreSQL to be ready.
  # First-time volume initialization (creating the data directory) can take 30-60s.
  print_info "Waiting for PostgreSQL to accept connections..."
  local waited=0
  while ! dst "docker exec ${DST_INSTANCE_NAME}_db pg_isready -U ${DST_PG_USER}" &>/dev/null; do
    sleep 3
    ((waited += 3))
    [[ $waited -ge 180 ]] && {
      print_error "PostgreSQL container did not become ready in 180s."
      print_info  "Check: docker logs ${DST_INSTANCE_NAME}_db"
      exit 1
    }
    printf "."
  done
  echo ""
  print_success "PostgreSQL is ready"

  # Sync the PG user password with odoo.conf.
  # IMPORTANT: force md5 storage to match the pg_hba.conf 'md5' auth method.
  # PostgreSQL 13+ defaults to scram-sha-256 storage, but pg_hba.conf uses md5.
  # A scram-stored password cannot satisfy an md5 auth challenge → auth fails.
  # Unix-socket local connections use trust auth, so no password is needed here.
  dst "docker exec ${DST_INSTANCE_NAME}_db \
    psql -U ${DST_PG_USER} -d postgres \
    -c \"SET password_encryption='md5'; ALTER USER ${DST_PG_USER} WITH PASSWORD '${DST_PG_PASS}';\""
  print_success "PostgreSQL password set (md5, synced with odoo.conf)"
}

# ── STEP 6: Restore database ──────────────────────────────────
step_restore_db() {
  print_step "Step 6 of 10 — Restore database into Docker PostgreSQL"
  print_line

  local dump="$EXTRACT_DIR/dump.sql"

  # Helper: run psql INSIDE the postgres container via docker exec.
  # Always connects to the 'postgres' system database for admin commands
  # (psql default = connect to a DB named after the user, which may not exist).
  local pg_admin="docker exec ${DST_INSTANCE_NAME}_db psql -U ${DST_PG_USER} -d postgres"

  # ── Create the target database if it doesn't exist ─────────
  print_info "Creating database '${DST_DB}' inside PostgreSQL container..."
  local db_exists
  db_exists=$(dst "${pg_admin} -tAc \"SELECT 1 FROM pg_database WHERE datname='${DST_DB}'\"" 2>/dev/null || true)

  if [[ "$db_exists" == "1" ]]; then
    print_warn "Database '${DST_DB}' already exists — will restore into it."
  else
    if ! dst "${pg_admin} -c \"CREATE DATABASE \\\"${DST_DB}\\\" OWNER ${DST_PG_USER};\""; then
      print_error "Failed to create database '${DST_DB}'."
      print_info  "Check container logs:  docker logs ${DST_INSTANCE_NAME}_db"
      exit 1
    fi
    print_success "Database '${DST_DB}' created"
  fi

  # ── Transfer dump to destination if remote ─────────────────
  if [[ "$DST_TYPE" == "remote" ]]; then
    print_info "Transferring dump.sql to ${DST_SSH_HOST}..."
    if ! dst_put "$dump" "$DST_BASE_DIR"; then
      print_error "Failed to transfer dump.sql to ${DST_SSH_HOST}."
      print_info  "Check network connectivity and disk space on ${DST_SSH_HOST}."
      exit 1
    fi
    dump="${DST_BASE_DIR}/dump.sql"
    # Verify file actually arrived
    if ! dst "test -f '${dump}'"; then
      print_error "dump.sql not found on remote at ${dump} after transfer."
      exit 1
    fi
    print_success "dump.sql transferred ($(dst "du -sh '${dump}'" | cut -f1))"
  fi

  # ── Restore SQL dump ───────────────────────────────────────
  print_info "Restoring SQL dump — this may take several minutes for large databases..."
  print_info "Odoo dumps often emit non-fatal errors (duplicate objects, role ownership)."
  print_info "Those are harmless — the restore continues regardless."
  echo ""

  local restore_ok=0
  if [[ "$DST_TYPE" == "remote" ]]; then
    # Stream dump.sql from the remote file into psql running in the container.
    # The < redirection is evaluated by the REMOTE shell, not the local one.
    # ON_ERROR_STOP=0 lets psql continue past harmless Odoo dump errors.
    if dst "docker exec -i ${DST_INSTANCE_NAME}_db \
        psql -U ${DST_PG_USER} -d '${DST_DB}' -v ON_ERROR_STOP=0 --quiet \
        < '${dump}'" ; then
      restore_ok=1
    fi
  else
    if docker exec -i "${DST_INSTANCE_NAME}_db" \
        psql -U "${DST_PG_USER}" -d "${DST_DB}" -v ON_ERROR_STOP=0 --quiet \
        < "$dump" ; then
      restore_ok=1
    fi
  fi

  if [[ $restore_ok -eq 0 ]]; then
    print_warn "psql exited with a non-zero code — some statements may have failed."
    print_info "This is often harmless. Checking table count to verify..."
  fi

  # ── Post-restore sanity check ─────────────────────────────
  local table_count
  table_count=$(dst "${pg_admin} -d '${DST_DB}' -tAc \
    \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public'\"" \
    2>/dev/null || echo "0")
  table_count="${table_count//[^0-9]/}"   # strip whitespace/newlines
  if [[ -z "$table_count" || "$table_count" -lt 10 ]]; then
    print_error "Restore check failed — only ${table_count:-0} tables found in '${DST_DB}'."
    print_info  "The dump may not have been applied correctly."
    print_info  "Common causes: large dump timed out, psql auth error, disk full."
    print_info  "Run manually:  docker exec -i ${DST_INSTANCE_NAME}_db psql -U ${DST_PG_USER} -d '${DST_DB}' < /path/to/dump.sql"
    exit 1
  fi
  print_success "Restore verified — ${table_count} tables found in '${DST_DB}'"

  # ── Grant ownership to our DB user ────────────────────────
  dst "${pg_admin} -c \"GRANT ALL PRIVILEGES ON DATABASE \\\"${DST_DB}\\\" TO ${DST_PG_USER};\""

  print_success "Database '${DST_DB}' restored"

  # Clean up dump on remote to free space
  [[ "$DST_TYPE" == "remote" ]] && dst "rm -f '${dump}'" || true
}

# ── STEP 7: Restore filestore ─────────────────────────────────
step_restore_filestore() {
  print_step "Step 7 of 10 — Restore filestore"
  print_line

  if [[ ! -d "$EXTRACT_DIR/filestore" ]]; then
    print_warn "No filestore in backup — skipping."
    return 0
  fi

  # In Docker Odoo, the filestore lives in the named volume at:
  #   /var/lib/odoo/filestore/<db_name>/
  # We copy into that volume using a temporary alpine container.

  if [[ "$DST_TYPE" == "remote" ]]; then
    print_info "Transferring filestore to ${DST_SSH_HOST}..."
    dst "mkdir -p '${DST_BASE_DIR}/filestore_import'"
    # Use --info=progress2 instead of --progress so rsync prints ONE updating
    # line for the whole transfer instead of a line per file (filestore has
    # thousands of files and --progress floods the terminal).
    local _opts; _opts=$(_ssh_base_opts)
    if [[ "$DST_SSH_AUTH" == "password" ]]; then
      sshpass -p "${DST_SSH_PASS}" \
        rsync -az --info=progress2 \
        -e "ssh $_opts -o BatchMode=no -o PasswordAuthentication=yes" \
        "$EXTRACT_DIR/filestore" \
        "${DST_SSH_USER}@${DST_SSH_HOST}:${DST_BASE_DIR}/filestore_import/"
    else
      rsync -az --info=progress2 \
        -e "ssh -S '${DST_SSH_CTL}' -p ${DST_SSH_PORT}" \
        "$EXTRACT_DIR/filestore" \
        "${DST_SSH_USER}@${DST_SSH_HOST}:${DST_BASE_DIR}/filestore_import/"
    fi

    print_info "Copying filestore into Docker volume..."
    dst "docker run --rm \
      -v ${DST_INSTANCE_NAME}_odoo_data:/var/lib/odoo \
      -v ${DST_BASE_DIR}/filestore_import/filestore:/src:ro \
      alpine sh -c 'mkdir -p /var/lib/odoo/filestore/${DST_DB} && \
        cp -r /src/. /var/lib/odoo/filestore/${DST_DB}/ && \
        chown -R 101:101 /var/lib/odoo && \
        echo done'"

    dst "rm -rf '${DST_BASE_DIR}/filestore_import'"
  else
    local fs_abs
    fs_abs="$(cd "$EXTRACT_DIR/filestore" && pwd)"
    print_info "Copying filestore into Docker volume..."
    docker run --rm \
      -v "${DST_INSTANCE_NAME}_odoo_data:/var/lib/odoo" \
      -v "${fs_abs}:/src:ro" \
      alpine sh -c "mkdir -p /var/lib/odoo/filestore/${DST_DB} && \
        cp -r /src/. /var/lib/odoo/filestore/${DST_DB}/ && \
        chown -R 101:101 /var/lib/odoo && \
        echo done"
  fi

  print_success "Filestore restored to volume at filestore/${DST_DB}/"
}

# ── STEP 8: Migrate custom addons ────────────────────────────
_is_standard_odoo_path() {
  local p="$1"
  [[ "$p" == */dist-packages/odoo/addons* ]] && return 0
  [[ "$p" == */site-packages/odoo/addons* ]] && return 0
  [[ "$p" == /usr/lib/python3*            ]] && return 0
  [[ "$p" == /usr/local/lib/python3*      ]] && return 0
  # Core Odoo source tree addons (built into Docker image, don't copy)
  [[ "$p" == */odoo-server/addons         ]] && return 0
  [[ "$p" == */odoo-server/addons/        ]] && return 0
  return 1
}

step_migrate_addons() {
  print_step "Step 8 of 10 — Migrate custom addons from source server"
  print_line
  echo ""

  # ── 1. Build the raw addons_path string ───────────────────
  # Priority: auto-detected from conf/process → ask user
  local addons_path_raw="$ODOO_ADDONS_HINT"

  if [[ -n "$addons_path_raw" ]]; then
    print_success "addons_path detected: $addons_path_raw"
  else
    print_warn "Could not auto-detect addons_path from odoo.conf or process args."
    echo ""
    echo -e "  Enter the comma-separated addons_path from your odoo.conf."
    echo -e "  Example: ${GRAY}/opt/odoo/addons,/opt/odoo/custom/addons${NC}"
    echo -e "  Press Enter with no value to skip (no custom addons)."
    echo ""
    ask "addons_path" "" addons_path_raw
    if [[ -z "$addons_path_raw" ]]; then
      print_warn "Skipped. If Odoo shows CSS/module errors after start, re-run with:"
      print_info "  rsync -az /your/custom/addons/ user@host:${DST_BASE_DIR}/addons/"
      return 0
    fi
  fi

  # ── 2. Parse, deduplicate, and filter to custom paths only ──
  local -a custom_paths=()
  local _p _seen=""
  while IFS= read -r _p; do
    _p="${_p#"${_p%%[![:space:]]*}"}"   # ltrim
    _p="${_p%"${_p##*[![:space:]]}"}"   # rtrim
    [[ -z "$_p" ]]              && continue
    _is_standard_odoo_path "$_p" && continue
    # Skip duplicates
    echo "$_seen" | grep -qxF "$_p"    && continue
    [[ ! -d "$_p" ]] && {
      print_warn "Path does not exist, skipping: $_p"
      continue
    }
    custom_paths+=("$_p")
    _seen="${_seen}"$'\n'"${_p}"
  done < <(echo "$addons_path_raw" | tr ',' '\n')

  if [[ ${#custom_paths[@]} -eq 0 ]]; then
    print_warn "No custom addons paths found after filtering standard Odoo paths."
    return 0
  fi

  # ── 3. Show what will be copied ───────────────────────────
  echo ""
  echo -e "  ${WHITE}Custom addons to migrate:${NC}"
  echo ""
  local total_count=0
  for _p in "${custom_paths[@]}"; do
    local _count
    _count=$(find "$_p" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    echo -e "    ${CYAN}${_p}${NC}  →  ${_count} addon(s)"
    ((total_count += _count))
  done
  echo ""

  if [[ $total_count -eq 0 ]]; then
    print_warn "Custom paths found but they are all empty — skipping."
    return 0
  fi

  # Default answer is yes — this is required for a complete migration
  local ans
  ask "Copy all ${total_count} addon(s) to the Docker instance?" "y" ans
  if [[ "${ans,,}" != "y" ]]; then
    print_warn "Skipped. Copy addons manually before starting Odoo:"
    print_info "  rsync -az /your/custom/addons/ ${DST_SSH_USER:-user}@${DST_SSH_HOST:-host}:${DST_BASE_DIR}/addons/"
    return 0
  fi

  # ── 4. rsync each custom path's contents to destination ───
  local _opts; _opts=$(_ssh_base_opts)
  for _p in "${custom_paths[@]}"; do
    local _src="${_p%/}/"   # trailing slash: copy contents, not the dir wrapper
    print_info "Syncing: ${_p}  →  ${DST_BASE_DIR}/addons/"
    if [[ "$DST_TYPE" == "remote" ]]; then
      if [[ "$DST_SSH_AUTH" == "password" ]]; then
        sshpass -p "${DST_SSH_PASS}" \
          rsync -az --info=progress2 \
          -e "ssh $_opts -o BatchMode=no -o PasswordAuthentication=yes" \
          "$_src" "${DST_SSH_USER}@${DST_SSH_HOST}:${DST_BASE_DIR}/addons/"
      else
        rsync -az --info=progress2 \
          -e "ssh -S '${DST_SSH_CTL}' -p ${DST_SSH_PORT}" \
          "$_src" "${DST_SSH_USER}@${DST_SSH_HOST}:${DST_BASE_DIR}/addons/"
      fi
    else
      rsync -a "$_src" "${DST_BASE_DIR}/addons/"
    fi
    print_success "Done: ${_p}"
  done

  print_success "All ${total_count} custom addon(s) installed at ${DST_BASE_DIR}/addons/"

  # ── 5. Scan manifests for Python dependencies ─────────────
  # Collect all external_dependencies.python from every addon manifest.
  # Store in the global ADDON_PY_DEPS so step_start_odoo can install them
  # AFTER the container is running (container doesn't exist yet here).
  print_info "Scanning addons for Python dependencies..."
  ADDON_PY_DEPS=""
  local _raw_deps=""

  local _scan_py
  _scan_py='
import sys, ast, glob, os
addons_dir = sys.argv[1]
deps = set()
for p in glob.glob(os.path.join(addons_dir, "*", "__manifest__.py")):
    try:
        m = ast.literal_eval(open(p, errors="ignore").read())
        for pkg in m.get("external_dependencies", {}).get("python", []):
            if pkg and isinstance(pkg, str):
                deps.add(pkg)
    except Exception:
        pass
print("\n".join(sorted(deps)))
'
  for _p in "${custom_paths[@]}"; do
    local _more
    _more=$(python3 -c "$_scan_py" "$_p" 2>/dev/null) || _more=""
    [ -n "$_more" ] && _raw_deps=$(printf '%s\n%s' "$_raw_deps" "$_more")
  done

  ADDON_PY_DEPS=$(printf '%s\n' "$_raw_deps" \
    | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')

  if [[ -z "$ADDON_PY_DEPS" ]]; then
    print_info "No external Python dependencies found in addons."
  else
    print_success "Python packages needed: ${ADDON_PY_DEPS}"
    print_info "(Will be installed into the Odoo container in step 9)"
  fi
}

# ── STEP 9: Start Odoo container ──────────────────────────────
step_start_odoo() {
  print_step "Step 9 of 10 — Start Odoo 14 container"
  print_line

  dst "cd '${DST_BASE_DIR}' && docker compose up -d odoo"

  # Upgrade pip once so subsequent installs can handle modern pyproject.toml.
  # -u root: packages land in /usr/local/lib/pythonX/dist-packages/ (always
  # importable) rather than odoo user's ~/.local inside the filestore volume.
  dst "docker exec -u root ${DST_INSTANCE_NAME}_odoo \
    python3 -m pip install --upgrade pip setuptools --quiet" 2>/dev/null || true

  # Install Python deps declared in addon manifests (collected in step 8).
  if [[ -n "$ADDON_PY_DEPS" ]]; then
    print_info "Installing manifest-declared packages: ${ADDON_PY_DEPS}"
    dst "docker exec -u root ${DST_INSTANCE_NAME}_odoo \
      python3 -m pip install ${ADDON_PY_DEPS} --quiet" \
      && print_success "Manifest packages installed" \
      || print_warn "pip had errors on manifest packages — continuing"
  fi

  # Auto-fix loop: some addons have undeclared Python deps and raise
  # ImportError at load time. Detect them from Odoo's log and install
  # automatically, up to 5 rounds.
  print_info "Starting Odoo — will auto-fix any missing Python packages..."
  local _attempt _fixed_pkgs="" _odoo_ok=false
  for _attempt in 1 2 3 4 5; do
    # Clear log so we only see errors from THIS boot, then restart
    dst "docker exec -u root ${DST_INSTANCE_NAME}_odoo \
      truncate -s0 /var/log/odoo/odoo.log" 2>/dev/null || true
    dst "docker restart ${DST_INSTANCE_NAME}_odoo" >/dev/null
    sleep 20  # give Odoo time to attempt module loading and hit any ImportErrors

    # Quick HTTP check — 200/302/303 means Odoo is up
    local _code
    _code=$(dst "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 \
      'http://127.0.0.1:${DST_WEB_PORT}/web/login'" 2>/dev/null | tr -cd '0-9' || echo "000")
    if [[ "$_code" == "200" || "$_code" == "302" || "$_code" == "303" ]]; then
      _odoo_ok=true
      print_success "Odoo is up (attempt ${_attempt})"
      break
    fi

    # Parse log for missing package names using two patterns:
    #   1. Standard Python: No module named 'X'  (may be 'X.Y' — use top-level X)
    #   2. Custom messages: "pip[3] install X"
    local _log
    _log=$(dst "docker exec ${DST_INSTANCE_NAME}_odoo \
      tail -150 /var/log/odoo/odoo.log 2>/dev/null" 2>/dev/null || true)

    local _from_no_module _from_pip_hint _new_pkgs
    _from_no_module=$(printf '%s\n' "$_log" \
      | grep -oE "No module named '[^']+'" \
      | grep -oE "'[^']+'" | tr -d "'" \
      | sed 's/\..*//' | sort -u)
    _from_pip_hint=$(printf '%s\n' "$_log" \
      | grep -iE "pip3? install [a-zA-Z0-9_-]+" \
      | grep -oE "install [a-zA-Z0-9_-]+" | awk '{print $2}' | sort -u)

    _new_pkgs=$(printf '%s\n%s\n' "$_from_no_module" "$_from_pip_hint" \
      | sort -u | grep -v '^$' \
      | grep -vFx "$(printf '%s\n' $_fixed_pkgs)" \
      | tr '\n' ' ' | sed 's/ $//')

    if [[ -z "$_new_pkgs" ]]; then
      print_warn "Odoo not responding (attempt ${_attempt}) — no new ImportErrors in log"
      break
    fi

    print_info "Attempt ${_attempt}: detected missing packages: ${_new_pkgs}"
    dst "docker exec -u root ${DST_INSTANCE_NAME}_odoo \
      python3 -m pip install ${_new_pkgs} --quiet" \
      && print_success "Installed: ${_new_pkgs}" \
      || print_warn "pip install failed for: ${_new_pkgs}"
    _fixed_pkgs="${_fixed_pkgs} ${_new_pkgs}"
  done

  if [[ "$_odoo_ok" == false ]]; then
    print_warn "Odoo did not respond after ${_attempt} attempt(s)."
    print_info "Check logs: docker exec ${DST_INSTANCE_NAME}_odoo tail -50 /var/log/odoo/odoo.log"
    return 0
  fi

  local check_host
  if [[ "$DST_TYPE" == "remote" ]]; then
    check_host="$DST_SSH_HOST"
  else
    check_host="127.0.0.1"
  fi
  print_success "Odoo is responding at http://${check_host}:${DST_WEB_PORT}"
}

# ── STEP 9: Verify ────────────────────────────────────────────
step_verify() {
  print_step "Step 10 of 10 — Verify migration"
  print_line

  local check_host
  if [[ "$DST_TYPE" == "remote" ]]; then
    check_host="$DST_SSH_HOST"
  else
    check_host="127.0.0.1"
  fi

  # HTTP check from destination machine to avoid firewall false negatives
  local code
  if [[ "$DST_TYPE" == "remote" ]]; then
    code=$(dst "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 \
      'http://127.0.0.1:${DST_WEB_PORT}/web/login'" 2>/dev/null || echo "000")
  else
    code=$(curl -s -o /dev/null -w "%{http_code}" \
      --connect-timeout 10 "http://127.0.0.1:${DST_WEB_PORT}/web/login" 2>/dev/null || echo "000")
  fi
  code="${code//[^0-9]/}"
  if [[ "$code" =~ ^(200|302|303)$ ]]; then
    print_success "Web UI: http://${check_host}:${DST_WEB_PORT}  (HTTP $code)"
  else
    print_warn "Web UI returned HTTP $code — may still be initializing."
    print_info  "Check logs: docker exec ${DST_INSTANCE_NAME}_odoo tail -30 /var/log/odoo/odoo.log"
  fi

  # Container status
  echo ""
  print_info "Container status:"
  dst "docker ps --filter name=${DST_INSTANCE_NAME} \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"

  # Disk usage of volumes
  echo ""
  print_info "Volume sizes:"
  dst "docker system df -v 2>/dev/null | grep '${DST_INSTANCE_NAME}' || true"
}

# ── Final summary ─────────────────────────────────────────────
print_summary() {
  local dst_host
  if [[ "$DST_TYPE" == "remote" ]]; then
    dst_host="$DST_SSH_HOST"
  else
    dst_host="localhost"
  fi

  echo ""
  print_line
  echo -e "  ${GREEN}${BOLD}  ✅  Migration complete!${NC}"
  print_line
  echo ""
  echo -e "  ${WHITE}${BOLD}  Access your new Odoo 14 instance:${NC}"
  echo ""
  echo -e "    URL             : ${CYAN}http://${dst_host}:${DST_WEB_PORT}${NC}"
  echo -e "    Database        : ${CYAN}${DST_DB}${NC}"
  echo -e "    Master password : ${CYAN}${DST_MASTER_PASS}${NC}"
  echo ""
  echo -e "  ${WHITE}${BOLD}  PostgreSQL (inside Docker network):${NC}"
  echo ""
  echo -e "    Host   : db  (container name: ${DST_INSTANCE_NAME}_db)"
  echo -e "    User   : ${CYAN}${DST_PG_USER}${NC}"
  echo -e "    Pass   : ${CYAN}${DST_PG_PASS}${NC}"
  echo ""
  echo -e "  ${WHITE}${BOLD}  Useful commands:${NC}"
  echo ""
  echo -e "    ${GRAY}# Odoo logs${NC}"
  echo -e "    docker logs -f ${DST_INSTANCE_NAME}_odoo"
  echo ""
  echo -e "    ${GRAY}# Stop / Start${NC}"
  echo -e "    cd ${DST_BASE_DIR} && docker compose down"
  echo -e "    cd ${DST_BASE_DIR} && docker compose up -d"
  echo ""
  echo -e "    ${GRAY}# Odoo shell${NC}"
  echo -e "    docker exec -it ${DST_INSTANCE_NAME}_odoo odoo shell -d ${DST_DB}"
  echo ""
  echo -e "  ${GRAY}  Backup saved at: $BACKUP_ZIP${NC}"

  # ── Odoo Manager registration ─────────────────────────────
  # The Odoo Manager script tracks instances in ~/docker/.odoo_manager_instances.
  # Register this instance automatically if the Manager is present on destination.
  local manager_meta=""
  if [[ "$DST_TYPE" == "remote" ]]; then
    manager_meta=$(dst "cat \$HOME/docker/.odoo_manager_instances 2>/dev/null" | \
      grep "^${DST_INSTANCE_NAME}|" 2>/dev/null || true)
  else
    manager_meta=$(grep "^${DST_INSTANCE_NAME}|" \
      "$HOME/docker/.odoo_manager_instances" 2>/dev/null || true)
  fi

  if [[ -z "$manager_meta" ]]; then
    # Not yet registered — write the entry
    local meta_line="${DST_INSTANCE_NAME}|14.0|${DST_BASE_DIR}|${DST_WEB_PORT}|${DST_LONGPOLL_PORT}|${DST_PG_USER}|${DST_PG_PASS}|${DST_MASTER_PASS}|migrated"
    if [[ "$DST_TYPE" == "remote" ]]; then
      dst "mkdir -p \"\$HOME/docker\" && \
        grep -v '^${DST_INSTANCE_NAME}|' \"\$HOME/docker/.odoo_manager_instances\" > /tmp/.omtmp 2>/dev/null || true; \
        echo '${meta_line}' >> /tmp/.omtmp; \
        mv /tmp/.omtmp \"\$HOME/docker/.odoo_manager_instances\""
    else
      mkdir -p "$HOME/docker"
      local f="$HOME/docker/.odoo_manager_instances"
      touch "$f"
      grep -v "^${DST_INSTANCE_NAME}|" "$f" > /tmp/.omtmp 2>/dev/null || true
      echo "$meta_line" >> /tmp/.omtmp
      mv /tmp/.omtmp "$f"
    fi
    echo ""
    print_success "Instance registered in Odoo Manager (~/docker/.odoo_manager_instances)"
    print_info  "Run 'Odoo Manager.sh' on the destination server to manage it."
  else
    echo ""
    print_info "Already registered in Odoo Manager."
  fi

  print_line
  echo ""
}

# ── Main ──────────────────────────────────────────────────────
main() {
  mkdir -p "$WORK_DIR"
  print_banner

  echo -e "  ${WHITE}This script migrates Odoo 14 (native) → Odoo 14 (Docker).${NC}"
  echo -e "  ${GRAY}Same version. No upgrade. Production server: read-only.${NC}"
  echo ""
  pause

  check_deps

  # Each step is a discrete function — clear progress, easy to debug
  step_source            # 1. Source URL + master pass + pick DB
  step_destination       # 2. Local or remote Docker
  step_download          # 3. curl /web/database/backup → zip
  step_extract           # 4. unzip → dump.sql + filestore/
  step_create_docker     # 5. Create containers, start DB only
  step_restore_db        # 6. psql < dump.sql
  step_restore_filestore # 7. copy filestore into volume
  step_migrate_addons    # 8. copy third-party addons from source
  step_start_odoo        # 9. bring up Odoo container
  step_verify            # 10. HTTP + container check

  print_summary

  # Clean up SSH mux
  [[ "$DST_TYPE" == "remote" ]] && close_ssh_mux || true
}

# ── Trap for cleanup ─────────────────────────────────────────
trap 'close_ssh_mux 2>/dev/null; echo -e "\n${RED}  Script interrupted.${NC}"' INT TERM

main "$@"
