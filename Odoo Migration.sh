#!/bin/bash
# ============================================================
#   ODOO MIGRATION TO v19
#   Run this script ON the SOURCE machine.
#
#   What it does:
#     1. Reads local Odoo config + dumps DB  (source: READ ONLY)
#     2. SSH into destination machine
#     3. Installs Docker on destination if not present
#     4. Creates Odoo 19 Docker instance on destination
#        (you choose name + ports + DB credentials)
#     5. Transfers DB + custom addons to destination
#     6. Runs step-by-step upgrade to Odoo 19 on destination
#     7. Verifies Arabic data + web UI
#
#   Source machine: NEVER modified — read-only (pg_dump only)
#   Destination:    remote Docker server you control via SSH
#   Arabic/UTF-8:   preserved throughout all steps
#
#   Author:  Mohammed Ali
#   Website: https://prismatechwork.com
#   GitHub:  https://github.com/mhmdali94/EasyOdooDocker
# ============================================================

# ── Colors & Styles ─────────────────────────────────────────
RED='\033[0;31m';    GREEN='\033[0;32m';   YELLOW='\033[1;33m'
BLUE='\033[0;34m';   CYAN='\033[0;36m';    MAGENTA='\033[0;35m'
WHITE='\033[1;37m';  GRAY='\033[0;37m';    BOLD='\033[1m'
NC='\033[0m'

# ── Constants ────────────────────────────────────────────────
TARGET_VERSION="19.0"
OPENUPGRADE_IMG="ghcr.io/oca/openupgrade"
LOCAL_BACKUP_DIR="$HOME/odoo_migration_backups"
LOCAL_LOG_DIR="$HOME/odoo_migration_logs"

# ── Global State ─────────────────────────────────────────────
# Source (this machine — read only)
SRC_ODOO_CONF=""
SRC_DB_HOST="localhost"
SRC_DB_PORT="5432"
SRC_DB_USER=""
SRC_DB_PASS=""
SRC_DB_NAME=""
SRC_VERSION=""
SRC_IS_DOCKER="false"          # true = source Odoo runs in Docker on this machine
SRC_DOCKER_CONTAINER_DB=""     # Docker container name for the source DB
SRC_PG_AUTH_METHOD=""          # password | peer_odoo | peer_postgres
SRC_ODOO_BIN=""                # full path to odoo-bin (detected from running process)
SRC_MASTER_PASS=""             # admin_passwd from source odoo.conf
declare -a SRC_ADDONS_PATHS=()

# Destination (remote Docker machine)
DST_SSH_USER=""
DST_SSH_HOST=""
DST_SSH_PORT="22"
DST_SSH_KEY=""
DST_SSH_CTL=""      # ControlMaster socket path — all SSH calls reuse this one connection
DST_HOME=""
DST_BASE_DIR=""

# Destination Odoo 19 instance
DST_INSTANCE_NAME=""
DST_INSTANCE_DIR=""
DST_WEB_PORT=""
DST_GEVENT_PORT=""
DST_PG_USER=""
DST_PG_PASS=""
DST_MASTER_PASS=""

# Migration tracking
declare -a HOP_LIST=()
BACKUP_FILE=""
ADDONS_BACKUP=""
MIGRATION_LOG=""
ERR_LOG=""          # errors-only log — easy to read and share with developer

# ── Print Helpers ────────────────────────────────────────────
print_banner() {
  clear
  echo -e "${CYAN}${BOLD}"
  echo "  ╔═══════════════════════════════════════════════════════╗"
  echo "  ║    🚀  ODOO MIGRATION TO v19  🚀                      ║"
  echo "  ║   Run on SOURCE machine → pushes to DESTINATION       ║"
  echo "  ║   v14 / v15 / v16 / v17 / v18  →  Odoo 19 Docker     ║"
  echo "  ╠═══════════════════════════════════════════════════════╣"
  echo -e "  ║  ${GRAY}🌐 https://prismatechwork.com${CYAN}                          ║"
  echo -e "  ║  ${GRAY}🐙 https://github.com/mhmdali94/EasyOdooDocker${CYAN}         ║"
  echo "  ╚═══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

print_line()    { echo -e "${GRAY}  ─────────────────────────────────────────────────────${NC}"; }
print_success() { echo -e "  ${GREEN}✔  $1${NC}"; }
print_error()   { echo -e "  ${RED}✖  $1${NC}"; }
print_warn()    { echo -e "  ${YELLOW}⚠  $1${NC}"; }
print_info()    { echo -e "  ${CYAN}ℹ  $1${NC}"; }
print_step()    { echo -e "  ${MAGENTA}➜  $1${NC}"; }

pause() {
  echo ""
  read -rp "  $(echo -e "${GRAY}Press [Enter] to continue...${NC}")" _
}

confirm() {
  echo -e "\n  ${YELLOW}$1${NC}"
  read -rp "  Type 'yes' to confirm: " ans
  [[ "$ans" == "yes" ]]
}

log_msg() {
  [[ -n "$MIGRATION_LOG" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$MIGRATION_LOG"
}

err_msg() {
  # Write to both logs and print in red
  local line="$1"
  echo "[$(date '+%H:%M:%S')] $line" | tee -a "$ERR_LOG" >> "$MIGRATION_LOG"
}

# ══════════════════════════════════════════════════════════════
#  ERROR EXPLANATION ENGINE
#  Maps raw Odoo/pg error lines → plain English with fix advice
# ══════════════════════════════════════════════════════════════
explain_error() {
  local line="$1"

  # ── pg_restore — safe to ignore ─────────────────────────────
  [[ "$line" == *"already exists"* ]] && {
    echo "SAFE — object already existed in DB (normal during upgrade, skip it)"; return; }
  [[ "$line" == *"role"*"does not exist"* ]] && {
    echo "SAFE — ownership warning, handled by --no-owner flag (skip it)"; return; }
  [[ "$line" == *"could not execute query"*"already exists"* ]] && {
    echo "SAFE — duplicate object, harmless during restore"; return; }

  # ── Missing Python packages ──────────────────────────────────
  if echo "$line" | grep -qE "ModuleNotFoundError|No module named"; then
    local pkg; pkg=$(echo "$line" | grep -oP "No module named '\K[^']+" | head -1)
    [[ -z "$pkg" ]] && pkg=$(echo "$line" | grep -oP "ModuleNotFoundError: No module named '\K[^']+" | head -1)
    echo "FIX — Python package missing on destination. Run: pip3 install ${pkg:-<package>}"; return
  fi

  # ── Module loading failures ──────────────────────────────────
  if echo "$line" | grep -qE "Failed to load module|Cannot load module"; then
    local mod; mod=$(echo "$line" | grep -oP "module[': ]+\K\w+" | head -1)
    echo "FIX — Module '${mod:-unknown}' failed to load. Check: 1) __manifest__.py version, 2) missing dependencies, 3) syntax errors in .py files"; return
  fi

  # ── Deprecated decorators ────────────────────────────────────
  [[ "$line" == *"@api.multi"* || "$line" == *"api.multi"* ]] && {
    echo "FIX — @api.multi removed in v14+. Delete the decorator (just use def method(self):)"; return; }
  [[ "$line" == *"@api.one"* || "$line" == *"api.one"* ]] && {
    echo "FIX — @api.one removed in v14+. Delete the decorator and return single value"; return; }
  [[ "$line" == *"api.cr_uid"* || "$line" == *"cr, uid"* ]] && {
    echo "FIX — Old-style API (cr, uid). Rewrite method using new API (self, env)"; return; }

  # ── Import errors (API changes between versions) ─────────────
  if echo "$line" | grep -qE "ImportError|cannot import name"; then
    local what; what=$(echo "$line" | grep -oP "cannot import name '\K[^']+" | head -1)
    echo "FIX — '${what:-symbol}' was moved or removed in this Odoo version. Check OCA migration notes for v$(version_major "$TARGET_VERSION")"; return
  fi

  # ── XML / View errors ────────────────────────────────────────
  if echo "$line" | grep -qE "ParseError|Invalid XML|XMLSyntaxError|Element.*not allowed"; then
    echo "FIX — XML view error in custom module. Open the view file and check for removed tags/attributes in this Odoo version"; return
  fi
  [[ "$line" == *"view_type"*"not allowed"* || "$line" == *"arch"*"not valid"* ]] && {
    echo "FIX — View architecture changed. Remove unsupported XML attributes from the view"; return; }

  # ── Field / model errors ─────────────────────────────────────
  if echo "$line" | grep -qE "Field.*not found|field.*does not exist|no column named"; then
    local field; field=$(echo "$line" | grep -oP "Field '\K[^']+" | head -1)
    echo "FIX — Field '${field:-unknown}' was removed or renamed in this Odoo version. Update the model definition"; return
  fi
  [[ "$line" == *"_columns"* ]] && {
    echo "FIX — _columns dict removed. Convert to class-level field declarations"; return; }
  [[ "$line" == *"fields.function"* ]] && {
    echo "FIX — fields.function() removed. Use @api.depends with a compute= method"; return; }

  # ── Database / schema errors ─────────────────────────────────
  if echo "$line" | grep -qE "UndefinedTable|relation.*does not exist|table.*not found"; then
    local tbl; tbl=$(echo "$line" | grep -oP "relation \"\K[^\"]+" | head -1)
    echo "SERIOUS — Table '${tbl:-unknown}' missing. Schema migration may have failed. Check previous hop errors"; return
  fi
  if echo "$line" | grep -qE "UndefinedColumn|column.*does not exist"; then
    local col; col=$(echo "$line" | grep -oP "column \"\K[^\"]+" | head -1)
    echo "FIX — Column '${col:-unknown}' missing in DB. Model may have changed. Developer needs to add migration script"; return
  fi
  [[ "$line" == *"violates foreign key"* ]] && {
    echo "WARN — Foreign key violation. Some records reference data that no longer exists. May need data cleanup"; return; }
  [[ "$line" == *"violates not-null"* ]] && {
    echo "FIX — Required field has NULL value. A new required field was added — needs a default value in migration"; return; }
  [[ "$line" == *"duplicate key"* || "$line" == *"unique constraint"* ]] && {
    echo "WARN — Duplicate data. Two records have the same value for a unique field. Check and clean the data"; return; }

  # ── External ID / reference data ─────────────────────────────
  [[ "$line" == *"External ID"*"not found"* || "$line" == *"xmlid"*"not found"* ]] && {
    echo "WARN — A reference (xml_id) was deleted in this version. May cause missing menu items or actions. Usually non-critical"; return; }

  # ── Access / security errors ─────────────────────────────────
  [[ "$line" == *"AccessError"* || "$line" == *"access rights"* ]] && {
    echo "WARN — Access rights issue. Security rules may need update after migration. Check ir.model.access.csv"; return; }

  # ── Constraint errors ────────────────────────────────────────
  [[ "$line" == *"ConstraintViolation"* || "$line" == *"_sql_constraints"* ]] && {
    echo "WARN — SQL constraint violated. Data in the database breaks a rule defined in the model"; return; }

  # ── CRITICAL errors ──────────────────────────────────────────
  [[ "$line" == *"CRITICAL"* ]] && {
    echo "STOP — Critical error. Odoo crashed. Check the full error above for the root cause"; return; }
  [[ "$line" == *"Traceback"* ]] && {
    echo "INFO — Start of a Python exception trace. Read the lines below this one for the actual error"; return; }

  # No match
  echo ""
}

# ══════════════════════════════════════════════════════════════
#  HOP ERROR SUMMARY
#  Called after each hop — shows what failed and what to fix
# ══════════════════════════════════════════════════════════════
show_hop_summary() {
  local hop_ver=$1
  local err_count=$2
  local warn_count=$3
  local hop_start_line=$4   # line number in ERR_LOG where this hop started

  echo ""
  print_line
  echo -e "  ${WHITE}${BOLD}  📊  Result for hop → Odoo ${hop_ver}${NC}"
  print_line

  if [[ $err_count -eq 0 && $warn_count -eq 0 ]]; then
    print_success "Clean hop — no errors or warnings detected"
    print_line
    return 0
  fi

  [[ $err_count -gt 0 ]]  && echo -e "  ${RED}  Errors:   ${err_count}${NC}"
  [[ $warn_count -gt 0 ]] && echo -e "  ${YELLOW}  Warnings: ${warn_count}${NC}"

  if [[ $err_count -gt 0 && -f "$ERR_LOG" ]]; then
    echo ""
    echo -e "  ${RED}${BOLD}  Error details (errors from this hop):${NC}"
    echo ""

    # Read errors added during this hop
    local line_num=0
    local shown=0
    while IFS= read -r err_line; do
      ((line_num++))
      [[ $line_num -le $hop_start_line ]] && continue
      [[ $shown -ge 20 ]] && {
        echo -e "  ${GRAY}  ... and more errors. See full error log: ${ERR_LOG}${NC}"
        break
      }

      echo -e "  ${RED}  ▶ ${err_line}${NC}"
      local explanation; explanation=$(explain_error "$err_line")
      if [[ -n "$explanation" ]]; then
        local exp_color="$YELLOW"
        [[ "$explanation" == SAFE* ]]    && exp_color="$GREEN"
        [[ "$explanation" == STOP* ]]    && exp_color="$RED"
        [[ "$explanation" == SERIOUS* ]] && exp_color="$RED"
        echo -e "  ${exp_color}    ↳ ${explanation}${NC}"
      fi
      echo ""
      ((shown++))
    done < "$ERR_LOG"
  fi

  echo -e "  ${CYAN}  Full error log:  ${GRAY}${ERR_LOG}${NC}"
  echo -e "  ${CYAN}  Full migration log: ${GRAY}${MIGRATION_LOG}${NC}"
  print_line

  if [[ $err_count -gt 0 ]]; then
    echo ""
    echo -e "  ${YELLOW}  You can:${NC}"
    echo -e "  ${GRAY}  a) Fix the errors above and re-run the migration${NC}"
    echo -e "  ${GRAY}  b) Continue to next hop (errors may resolve in later hops)${NC}"
    echo -e "  ${GRAY}  c) Stop here and restore from the rollback point${NC}"
    echo ""
    read -rp "  $(echo -e "${YELLOW}Errors found. Continue to next hop anyway? [Y/n]: ${NC}")" cont
    [[ "$cont" =~ ^[Nn]$ ]] && return 1
  fi
  return 0
}

# ══════════════════════════════════════════════════════════════
#  DESTINATION SSH HELPERS
#  All destination operations go through dst_sh / dst_scp / dst_rsync.
#  They reuse a single ControlMaster connection — password typed ONCE only.
#  The source machine is never touched by any of these functions.
# ══════════════════════════════════════════════════════════════

# Base SSH options (no key or password here — auth is handled by ControlMaster)
_DST_SSH_BASE="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=60 -o ServerAliveCountMax=10"

dst_sh() {
  ssh $_DST_SSH_BASE \
    -o ControlPath="$DST_SSH_CTL" \
    -p "$DST_SSH_PORT" \
    "${DST_SSH_USER}@${DST_SSH_HOST}" "$@"
}

dst_scp() {
  scp -o StrictHostKeyChecking=no \
    -o ControlPath="$DST_SSH_CTL" \
    -P "$DST_SSH_PORT" "$@"
}

dst_rsync() {
  rsync -az --exclude='*.pyc' --exclude='__pycache__' \
    -e "ssh $_DST_SSH_BASE -o ControlPath=${DST_SSH_CTL} -p ${DST_SSH_PORT}" \
    "$@"
}

# ══════════════════════════════════════════════════════════════
#  VERSION UTILITIES
# ══════════════════════════════════════════════════════════════
version_major() { echo "${1%%.*}"; }

build_hop_list() {
  local src_int; src_int=$(version_major "$1")
  local tgt_int; tgt_int=$(version_major "$TARGET_VERSION")
  local hops=()
  for ((v=src_int+1; v<=tgt_int; v++)); do hops+=("${v}.0"); done
  echo "${hops[@]}"
}

# ══════════════════════════════════════════════════════════════
#  STEP 1 — READ SOURCE ODOO (this machine, read-only)
# ══════════════════════════════════════════════════════════════
parse_conf_key() {
  grep -E "^${2}\s*=" "$1" 2>/dev/null | head -1 \
    | sed "s/^${2}\s*=\s*//" | tr -d '\r' | xargs
}

detect_local_version() {
  local v=""

  # Method 1: run the exact binary detected from the running process (most reliable)
  if [[ -n "$SRC_ODOO_BIN" && -x "$SRC_ODOO_BIN" ]]; then
    v=$("$SRC_ODOO_BIN" --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1)
    [[ -n "$v" ]] && { echo "$v"; return; }
    # If --version fails (some builds don't support it), read release.py in same dir
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

  # Method 3: import odoo Python module (works if installed in system Python)
  v=$(python3 -c "import odoo; print(odoo.release.series)" 2>/dev/null \
      | grep -oP '\d+\.\d+' | head -1)
  [[ -n "$v" ]] && { echo "$v"; return; }

  # Method 4: dpkg (only works for apt-installed Odoo, not source installs)
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

# Wrapper: run pg command on source using whatever auth method works
# Usage: _src_pg psql|pg_dump [extra args...]
_src_pg() {
  local cmd=$1; shift
  case "$SRC_PG_AUTH_METHOD" in
    password)
      PGPASSWORD="$SRC_DB_PASS" PGCLIENTENCODING="UTF8" \
        "$cmd" -h "$SRC_DB_HOST" -p "$SRC_DB_PORT" -U "$SRC_DB_USER" "$@"
      ;;
    peer_odoo)
      # Run as the Odoo OS user — PG peer auth matches OS username to PG username
      sudo -u "$SRC_DB_USER" \
        env PGCLIENTENCODING="UTF8" \
        "$cmd" -U "$SRC_DB_USER" "$@"
      ;;
    peer_postgres)
      # Run as postgres superuser — can access any database without password
      sudo -u postgres \
        env PGCLIENTENCODING="UTF8" \
        "$cmd" -U postgres "$@"
      ;;
  esac
}

# Detect which PostgreSQL auth method works for this server and set SRC_PG_AUTH_METHOD.
# Only called for non-Docker sources. Tries password → peer odoo user → peer postgres user.
_resolve_src_pg_auth() {
  # Always connect to 'postgres' maintenance DB for the test — avoids needing
  # a DB named after the user (e.g. 'odoo' DB may not exist on this server)
  local test_cmd=(-d postgres -t -c "SELECT 1;")

  # Method 1: password from odoo.conf (skip if empty or literal "False")
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
    print_info "No password in odoo.conf — using peer auth (standard for server installs)"
  fi

  # Method 2: peer auth — run as the Odoo OS user (no password needed)
  # pg_hba.conf line: "local all all peer" means the OS username = PG username
  if id "$SRC_DB_USER" &>/dev/null; then
    if sudo -u "$SRC_DB_USER" psql -U "$SRC_DB_USER" \
        "${test_cmd[@]}" &>/dev/null; then
      SRC_PG_AUTH_METHOD="peer_odoo"
      print_success "PostgreSQL auth: peer auth (sudo -u ${SRC_DB_USER}) — no password needed"
      return 0
    fi
  fi

  # Method 3: peer auth as postgres superuser (always has full access)
  if sudo -u postgres psql -U postgres \
      "${test_cmd[@]}" &>/dev/null; then
    SRC_PG_AUTH_METHOD="peer_postgres"
    print_success "PostgreSQL auth: peer auth (sudo -u postgres) — no password needed"
    return 0
  fi

  # Method 4: manual password — last resort only
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
  # List databases from inside Docker container (source is Docker-based)
  docker exec -e PGPASSWORD="$SRC_DB_PASS" "$SRC_DOCKER_CONTAINER_DB" \
    psql -U "$SRC_DB_USER" -t \
    -c "SELECT datname FROM pg_database WHERE datistemplate=false AND datname<>'postgres' ORDER BY datname;" \
    2>/dev/null | tr -d ' ' | grep -v '^$'
}

_src_list_dbs_native() {
  # Connect to maintenance DB 'postgres' to list all databases
  _src_pg psql -d postgres -t \
    -c "SELECT datname FROM pg_database WHERE datistemplate=false AND datname<>'postgres' ORDER BY datname;" \
    2>/dev/null | tr -d ' ' | grep -v '^$'
}

_src_pick_database() {
  local dbs=$1
  local hint=$2   # DB name hint extracted from running postgres workers
  if [[ -z "$dbs" ]]; then
    print_warn "Could not list databases automatically"
    read -rp "  Enter database name to migrate: " SRC_DB_NAME
    [[ -z "$SRC_DB_NAME" ]] && { print_error "Database name required"; return 1; }
  else
    echo ""
    echo -e "  ${CYAN}  Databases found:${NC}"
    local i=1 default_ch=1
    declare -A _dbmap
    while IFS= read -r db; do
      [[ -z "$db" ]] && continue
      # Mark the DB that matches the active postgres connection hint
      if [[ -n "$hint" && "$hint" == *"$db"* ]]; then
        echo -e "  ${GREEN}  ${i}) ${db}  ← active (detected from running processes)${NC}"
        default_ch=$i
      else
        echo "    ${i}) ${db}"
      fi
      _dbmap[$i]=$db
      ((i++))
    done <<< "$dbs"
    read -rp "  Choose database to migrate [${default_ch}]: " ch; ch=${ch:-$default_ch}
    SRC_DB_NAME="${_dbmap[$ch]}"
    [[ -z "$SRC_DB_NAME" ]] && { print_error "Invalid choice"; return 1; }
  fi
  return 0
}

_src_confirm_version() {
  local auto_ver=$1
  if [[ -z "$auto_ver" ]]; then
    read -rp "  Could not auto-detect version. Enter it (e.g. 17.0): " SRC_VERSION
  else
    print_success "Detected version: ${auto_ver}"
    read -rp "  Confirm version [${auto_ver}]: " inp
    SRC_VERSION="${inp:-$auto_ver}"
  fi
  local maj; maj=$(version_major "$SRC_VERSION")
  if [[ "$maj" -lt 14 || "$maj" -ge 19 ]]; then
    print_error "Version ${SRC_VERSION} is not supported. Must be v14, v15, v16, v17, or v18."
    return 1
  fi
  return 0
}

setup_source() {
  print_banner
  echo -e "  ${WHITE}${BOLD}📖  STEP 1 — Read Source Odoo (this machine)${NC}"
  print_line
  echo -e "  ${GREEN}  Source machine is read-only — nothing will be modified here.${NC}"
  echo ""

  # ── Detect source type ────────────────────────────────────────

  # Priority 1: Read running processes — fastest and most reliable
  # ps aux directly shows the config file path and active DB names
  print_step "Scanning running Odoo processes..."
  local found_conf=""
  local proc_conf proc_db_hint

  # Extract config path AND binary path from the running Odoo process
  local proc_line
  proc_line=$(ps aux 2>/dev/null | grep -v grep \
    | grep -E 'odoo-bin|odoo\.py|openerp-server|odoo-server|python.*odoo|python.*openerp' \
    | head -1)

  proc_conf=$(echo "$proc_line" | grep -oP '(?<=-c\s)\S+' | head -1)

  # Extract full path to odoo-bin / odoo.py from the process command
  local proc_bin
  proc_bin=$(echo "$proc_line" | grep -oP '\S*(?:odoo-bin|odoo\.py|openerp-server)\S*' | head -1)
  [[ -f "$proc_bin" ]] && SRC_ODOO_BIN="$proc_bin"

  # Extract active DB names from PostgreSQL worker processes
  # Format: "postgres: VER/main: USER DBNAME [host] state"
  proc_db_hint=$(ps aux 2>/dev/null \
    | grep -v grep \
    | grep -oP 'postgres: [^:]+: \S+ \K\S+(?= \[)' \
    | grep -v '^postgres$' | sort -u | tr '\n' ' ' | xargs)

  # Show what was found in the process list
  if [[ -n "$proc_conf" && -f "$proc_conf" ]]; then
    found_conf="$proc_conf"
    echo -e "  ${GREEN}  ✔ Running Odoo process detected${NC}"
    echo -e "  ${GRAY}    Config:    ${found_conf}${NC}"
    [[ -n "$SRC_ODOO_BIN" ]] && \
      echo -e "  ${GRAY}    Binary:    ${SRC_ODOO_BIN}${NC}"
    [[ -n "$proc_db_hint" ]] && \
      echo -e "  ${GRAY}    Active DB: ${proc_db_hint}${NC}"
  elif [[ -n "$proc_conf" ]]; then
    echo -e "  ${YELLOW}  Process found but config file not readable: ${proc_conf}${NC}"
  else
    echo -e "  ${GRAY}  No running Odoo process found (Odoo may be stopped or running in Docker)${NC}"
  fi
  echo ""

  # Priority 2: Odoo Manager Docker instances on this machine
  local local_meta="$HOME/docker/.odoo_manager_instances"
  local has_docker_instances=false
  if [[ -f "$local_meta" ]] && grep -q . "$local_meta" 2>/dev/null; then
    has_docker_instances=true
  fi

  # Priority 3: Standard paths — covers common install conventions
  if [[ -z "$found_conf" ]]; then
    for c in \
      /etc/odoo-server.conf /etc/odoo/odoo.conf /etc/odoo.conf \
      /etc/openerp-server.conf /etc/openerp.conf \
      /opt/odoo/odoo.conf /opt/odoo/server/odoo.conf \
      /opt/odoo-server/odoo.conf /opt/odoo-server/odoo-server.conf \
      /home/odoo/odoo.conf /home/odoo/odoo-server.conf \
      /srv/odoo/odoo.conf /var/lib/odoo/odoo.conf \
      /odoo/odoo.conf /odoo/odoo-server.conf /root/odoo/odoo.conf; do
      [[ -f "$c" ]] && { found_conf="$c"; print_success "Found config: ${c}"; break; }
    done
  fi

  # Priority 4: Deep search — only runs if process detection and standard paths both failed
  local -a deep_found=()
  if ! $has_docker_instances && [[ -z "$found_conf" ]]; then
    echo -e "  ${GRAY}  Standard paths checked — nothing found. Running deep search...${NC}"
    echo -e "  ${GRAY}  (scanning filesystem for odoo*.conf / openerp*.conf — please wait)${NC}"
    while IFS= read -r hit; do
      # Filter out fake configs: source code samples, addon tools, packaging templates
      echo "$hit" | grep -qE '/addons/|/debian/|/posbox/|/doc/|/tests?/|/sample|/example|/template' \
        && continue
      deep_found+=("$hit")
    done < <(find / -maxdepth 12 \
               \( -name "odoo.conf" -o -name "odoo-server.conf" \
                  -o -name "openerp.conf" -o -name "openerp-server.conf" \) \
               -not -path "/proc/*" \
               -not -path "/sys/*" \
               -not -path "/dev/*" \
               -not -path "/run/*" \
               -not -path "/tmp/*" \
               -not -path "/snap/*" \
               2>/dev/null | sort -u)
    if [[ ${#deep_found[@]} -gt 0 ]]; then
      found_conf="${deep_found[0]}"
      echo -e "  ${GREEN}  Deep search found ${#deep_found[@]} config file(s)${NC}"
    else
      echo -e "  ${GRAY}  Deep search complete — no Odoo config found anywhere.${NC}"
    fi
    echo ""
  fi

  # Show user what was found
  echo -e "  ${CYAN}  Source type detected:${NC}"
  $has_docker_instances && \
    echo -e "  ${GREEN}  ✔ Docker instances (Odoo Manager)${NC}" || \
    echo -e "  ${GRAY}  ✗ No Odoo Manager instances found${NC}"
  if [[ ${#deep_found[@]} -gt 1 ]]; then
    echo -e "  ${GREEN}  ✔ ${#deep_found[@]} config files found by deep search:${NC}"
    for f in "${deep_found[@]}"; do echo -e "  ${GRAY}      ${f}${NC}"; done
  elif [[ -n "$found_conf" ]]; then
    echo -e "  ${GREEN}  ✔ Traditional server Odoo: ${found_conf}${NC}"
  else
    echo -e "  ${GRAY}  ✗ No server Odoo config found${NC}"
  fi
  echo ""

  # ── Ask which source type to use ─────────────────────────────
  local src_type=""

  if $has_docker_instances && [[ -n "$found_conf" ]]; then
    echo "    1) Docker instance (Odoo Manager) on this machine"
    echo "    2) Traditional server Odoo (${found_conf})"
    echo "    3) Enter config path manually"
    read -rp "  Source type [1]: " src_type; src_type=${src_type:-1}

  elif $has_docker_instances; then
    echo "    1) Docker instance (Odoo Manager) on this machine"
    echo "    2) Enter config path manually"
    read -rp "  Source type [1]: " src_type; src_type=${src_type:-1}

  elif [[ ${#deep_found[@]} -gt 1 ]]; then
    # Multiple configs found — let user pick which one
    echo -e "  ${CYAN}  Multiple odoo.conf files found — which one is the source?${NC}"
    local fi=1
    declare -A _confmap
    for f in "${deep_found[@]}"; do
      echo "    ${fi}) ${f}"
      _confmap[$fi]="$f"
      ((fi++))
    done
    echo "    ${fi}) Enter path manually"
    read -rp "  Choose [1]: " src_type
    if [[ "${_confmap[$src_type]}" ]]; then
      found_conf="${_confmap[$src_type]}"
      src_type="server"
    else
      src_type="manual"
    fi

  elif [[ -n "$found_conf" ]]; then
    echo "    1) Traditional server Odoo (${found_conf})"
    echo "    2) Enter config path manually"
    read -rp "  Source type [1]: " src_type; src_type=${src_type:-1}
    [[ "$src_type" == "1" ]] && src_type="server"
    [[ "$src_type" == "2" ]] && src_type="manual"

  else
    print_warn "No Odoo installation found anywhere on this machine."
    echo ""
    echo -e "  ${GRAY}  This can happen if:${NC}"
    echo -e "  ${GRAY}  • Odoo runs inside a Docker container managed by a different tool${NC}"
    echo -e "  ${GRAY}  • The config file has a non-standard name${NC}"
    echo -e "  ${GRAY}  • Odoo is installed but not yet configured${NC}"
    echo ""
    echo "    1) Enter config path manually"
    read -rp "  Choice [1]: " _; src_type="manual"
  fi

  # ── Branch: Docker source ─────────────────────────────────────
  if [[ "$src_type" == "1" ]] && $has_docker_instances; then
    SRC_IS_DOCKER="true"
    echo ""
    echo -e "  ${CYAN}  Odoo Manager instances on this machine:${NC}"
    local idx=1
    declare -A _instmap
    while IFS='|' read -r m_name m_ver m_dir m_web m_gev m_pgu m_pgp _ m_st; do
      [[ -z "$m_name" ]] && continue
      printf "    %d) %-20s  v%-5s  [%s]\n" "$idx" "$m_name" "$m_ver" "$m_st"
      _instmap[$idx]="$m_name|$m_ver|$m_dir|$m_pgu|$m_pgp"
      ((idx++))
    done < "$local_meta"

    echo ""
    read -rp "  Choose instance to migrate [1]: " ich; ich=${ich:-1}
    local sel="${_instmap[$ich]}"
    [[ -z "$sel" ]] && { print_error "Invalid choice"; return 1; }

    IFS='|' read -r _nm _ver _dir _pgu _pgp <<< "$sel"
    SRC_VERSION="$_ver"
    SRC_DB_USER="$_pgu"
    SRC_DB_PASS="$_pgp"
    SRC_DOCKER_CONTAINER_DB="${_nm}-db"
    SRC_ODOO_CONF="${_dir}/config/odoo.conf"
    SRC_ADDONS_PATHS=("${_dir}/addons")

    print_success "Selected: ${_nm} (v${SRC_VERSION})"
    print_info  "DB container: ${SRC_DOCKER_CONTAINER_DB}"
    print_info  "Addons:       ${_dir}/addons"

    # Confirm version
    _src_confirm_version "$SRC_VERSION" || return 1

    # List and pick database
    echo ""
    print_step "Listing databases inside Docker container '${SRC_DOCKER_CONTAINER_DB}'..."
    local dbs; dbs=$(_src_list_dbs_docker)
    _src_pick_database "$dbs" "$proc_db_hint" || return 1

  # ── Branch: Traditional server Odoo (auto-found conf) ─────────
  elif [[ "$src_type" == "1" || "$src_type" == "server" ]]; then
    SRC_IS_DOCKER="false"
    SRC_ODOO_CONF="$found_conf"
    print_success "Using config: ${SRC_ODOO_CONF}"

    SRC_DB_HOST=$(parse_conf_key "$SRC_ODOO_CONF" "db_host");   SRC_DB_HOST=${SRC_DB_HOST:-localhost}
    SRC_DB_PORT=$(parse_conf_key "$SRC_ODOO_CONF" "db_port");   SRC_DB_PORT=${SRC_DB_PORT:-5432}
    SRC_DB_USER=$(parse_conf_key "$SRC_ODOO_CONF" "db_user");   SRC_DB_USER=${SRC_DB_USER:-odoo}
    SRC_DB_PASS=$(parse_conf_key "$SRC_ODOO_CONF" "db_password")
    SRC_MASTER_PASS=$(parse_conf_key "$SRC_ODOO_CONF" "admin_passwd")
    local addons_path; addons_path=$(parse_conf_key "$SRC_ODOO_CONF" "addons_path")

    # Ask for master password — read from config if present, otherwise ask
    echo ""
    if [[ -n "$SRC_MASTER_PASS" && "$SRC_MASTER_PASS" != "False" ]]; then
      echo -e "  ${GREEN}  ✔ Master password found in odoo.conf${NC}"
      echo -e "  ${GRAY}    It will be reused on the destination Odoo 19 instance.${NC}"
      read -rsp "  Master password [keep current — press Enter, or type new]: " _mp; echo ""
      [[ -n "$_mp" ]] && SRC_MASTER_PASS="$_mp"
    else
      echo -e "  ${YELLOW}  Master password not found in odoo.conf.${NC}"
      read -rsp "  Enter Odoo master password (will be set on destination): " SRC_MASTER_PASS; echo ""
      [[ -z "$SRC_MASTER_PASS" ]] && SRC_MASTER_PASS="admin"
    fi

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
    if [[ -n "$addons_path" ]]; then
      while IFS= read -r p; do
        [[ -n "$p" ]] && SRC_ADDONS_PATHS+=("$p")
      done < <(get_custom_addons_paths "$addons_path")
    fi

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
    local addons_path; addons_path=$(parse_conf_key "$SRC_ODOO_CONF" "addons_path")

    # Ask for master password — read from config if present, otherwise ask
    echo ""
    if [[ -n "$SRC_MASTER_PASS" && "$SRC_MASTER_PASS" != "False" ]]; then
      echo -e "  ${GREEN}  ✔ Master password found in odoo.conf${NC}"
      echo -e "  ${GRAY}    It will be reused on the destination Odoo 19 instance.${NC}"
      read -rsp "  Master password [keep current — press Enter, or type new]: " _mp; echo ""
      [[ -n "$_mp" ]] && SRC_MASTER_PASS="$_mp"
    else
      echo -e "  ${YELLOW}  Master password not found in odoo.conf.${NC}"
      read -rsp "  Enter Odoo master password (will be set on destination): " SRC_MASTER_PASS; echo ""
      [[ -z "$SRC_MASTER_PASS" ]] && SRC_MASTER_PASS="admin"
    fi

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
    if [[ -n "$addons_path" ]]; then
      while IFS= read -r p; do
        [[ -n "$p" ]] && SRC_ADDONS_PATHS+=("$p")
      done < <(get_custom_addons_paths "$addons_path")
    fi
  fi

  echo ""
  print_line
  echo -e "  ${GREEN}${BOLD}  Source confirmed (READ-ONLY):${NC}"
  echo -e "  ${GRAY}  Type:     $( [[ "$SRC_IS_DOCKER" == "true" ]] && echo "Docker (Odoo Manager)" || echo "Traditional server" )${NC}"
  echo -e "  ${GRAY}  Version:  ${SRC_VERSION}${NC}"
  echo -e "  ${GRAY}  Database: ${SRC_DB_NAME}${NC}"
  [[ ${#SRC_ADDONS_PATHS[@]} -gt 0 ]] && \
    echo -e "  ${GRAY}  Addons:   ${SRC_ADDONS_PATHS[*]}${NC}"
  print_line
  return 0
}

# ══════════════════════════════════════════════════════════════
#  STEP 2 — CONNECT TO DESTINATION MACHINE
# ══════════════════════════════════════════════════════════════
setup_destination_ssh() {
  print_banner
  echo -e "  ${WHITE}${BOLD}🖥️   STEP 2 — Connect to Destination Machine${NC}"
  print_line
  echo -e "  ${GRAY}  This is the server where Odoo 19 Docker will be installed.${NC}"
  echo -e "  ${GRAY}  You will type the SSH password ONCE — all commands reuse that connection.${NC}"
  echo ""

  read -rp "  Destination SSH user (e.g. root): " DST_SSH_USER
  read -rp "  Destination IP or hostname:       " DST_SSH_HOST
  read -rp "  SSH port [22]:                    " DST_SSH_PORT; DST_SSH_PORT=${DST_SSH_PORT:-22}

  # ── Set up ControlMaster socket path ─────────────────────────
  # /tmp is always writable; use PID so multiple runs don't clash
  DST_SSH_CTL="/tmp/.odoo_mig_ctl_${$}"

  # ── Try SSH key first (strict — no password fallback) ─────────
  local key_ok=false
  read -rp "  SSH key path (press Enter to skip and use password): " DST_SSH_KEY
  if [[ -n "$DST_SSH_KEY" && -f "$DST_SSH_KEY" ]]; then
    print_step "Testing SSH key auth (no password fallback)..."
    if ssh $_DST_SSH_BASE \
        -o PasswordAuthentication=no \
        -o BatchMode=yes \
        -o ControlMaster=yes \
        -o ControlPath="$DST_SSH_CTL" \
        -o ControlPersist=7200 \
        -p "$DST_SSH_PORT" \
        -i "$DST_SSH_KEY" \
        "${DST_SSH_USER}@${DST_SSH_HOST}" "echo ok" &>/dev/null; then
      key_ok=true
      print_success "Connected via SSH key — connection will be reused for all steps"
    else
      print_warn "Key auth failed — will try password"
    fi
  elif [[ -n "$DST_SSH_KEY" ]]; then
    print_warn "Key file '${DST_SSH_KEY}' not found — will try password"
  fi

  # ── Password auth using ControlMaster (typed once, reused forever) ──
  if ! $key_ok; then
    echo ""
    echo -e "  ${CYAN}  Password auth — you type it ONCE below.${NC}"
    echo -e "  ${GRAY}  All subsequent steps reuse this connection automatically.${NC}"
    echo ""
    # Open ControlMaster in the foreground so the user can type the password
    ssh $_DST_SSH_BASE \
      -o ControlMaster=yes \
      -o ControlPath="$DST_SSH_CTL" \
      -o ControlPersist=7200 \
      -p "$DST_SSH_PORT" \
      "${DST_SSH_USER}@${DST_SSH_HOST}" "echo ok" || {
        print_error "Connection failed. Check IP, port, and password."
        return 1
      }
    print_success "Connected — password will NOT be asked again during this migration"
  fi

  # ── Verify the control socket works ───────────────────────────
  if ! dst_sh "echo ok" &>/dev/null; then
    print_error "ControlMaster socket not working. Cannot continue."
    return 1
  fi

  DST_HOME=$(dst_sh "echo \$HOME")
  DST_BASE_DIR="${DST_HOME}/docker"
  print_success "Destination home: ${DST_HOME}"
  return 0
}

# ══════════════════════════════════════════════════════════════
#  STEP 3 — INSTALL DOCKER ON DESTINATION (if not present)
# ══════════════════════════════════════════════════════════════
install_docker_on_destination() {
  print_step "Checking Docker on destination..."

  if dst_sh "docker --version" &>/dev/null; then
    local ver; ver=$(dst_sh "docker --version 2>/dev/null | cut -d',' -f1")
    print_success "Docker already installed: ${ver}"
    return 0
  fi

  echo ""
  print_warn "Docker not found on destination machine."
  read -rp "  Install Docker now on ${DST_SSH_HOST}? [Y/n]: " ans
  [[ "$ans" =~ ^[Nn]$ ]] && {
    print_error "Docker is required. Please install it on the destination and retry."
    return 1
  }

  print_step "Detecting OS on destination..."
  local os_id; os_id=$(dst_sh "grep -oP '^ID=\K.*' /etc/os-release 2>/dev/null | tr -d '\"'")
  print_info "Destination OS: ${os_id}"

  print_step "Installing Docker on destination..."
  case "$os_id" in
    ubuntu|debian|linuxmint|pop)
      dst_sh "apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null; \
        apt-get update -qq && \
        apt-get install -y ca-certificates curl gnupg lsb-release && \
        install -m 0755 -d /etc/apt/keyrings && \
        curl -fsSL https://download.docker.com/linux/${os_id}/gpg \
          | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
        chmod a+r /etc/apt/keyrings/docker.gpg && \
        echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
          https://download.docker.com/linux/${os_id} \$(lsb_release -cs) stable\" \
          > /etc/apt/sources.list.d/docker.list && \
        apt-get update -qq && \
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
      ;;
    centos|rhel|rocky|almalinux|fedora)
      dst_sh "yum remove -y docker docker-client docker-client-latest docker-common \
          docker-latest docker-logrotate docker-engine 2>/dev/null; \
        yum install -y yum-utils && \
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo && \
        yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
      ;;
    *)
      print_step "Unknown OS — trying generic Docker install script..."
      dst_sh "curl -fsSL https://get.docker.com | sh"
      ;;
  esac

  # Enable and start Docker on destination
  dst_sh "systemctl enable docker && systemctl start docker" &>/dev/null

  if dst_sh "docker --version" &>/dev/null; then
    print_success "Docker installed on destination"
  else
    print_error "Docker installation failed on destination. Install it manually."
    return 1
  fi
  return 0
}

# ══════════════════════════════════════════════════════════════
#  STEP 4 — CREATE ODOO 19 INSTANCE ON DESTINATION
# ══════════════════════════════════════════════════════════════
create_destination_instance() {
  print_banner
  echo -e "  ${WHITE}${BOLD}🐘  STEP 4 — Create Odoo 19 Instance on Destination${NC}"
  print_line
  echo ""

  # ── Read destination Odoo Manager registry ───────────────────
  # Odoo Manager.sh stores its instance list in $DST_BASE_DIR/.odoo_manager_instances
  # Format: name|version|dir|web_port|gevent_port|pg_user|pg_pass|master_pass|status
  local DST_META_FILE="${DST_BASE_DIR}/.odoo_manager_instances"
  local dst_meta_content; dst_meta_content=$(dst_sh "cat '${DST_META_FILE}' 2>/dev/null || echo ''")

  # Show existing instances on destination so user knows what's there
  if [[ -n "$dst_meta_content" ]]; then
    echo -e "  ${CYAN}  Existing Odoo instances on ${DST_SSH_HOST} (from Odoo Manager):${NC}"
    local idx=0
    while IFS='|' read -r m_name m_ver m_dir m_web m_gev m_pgu _ _ m_st; do
      [[ -z "$m_name" ]] && continue
      printf "  ${GRAY}  %-20s  v%-5s  web:%-5s  gevent:%-5s  [%s]${NC}\n" \
        "$m_name" "$m_ver" "$m_web" "$m_gev" "$m_st"
      ((idx++))
    done <<< "$dst_meta_content"
    [[ $idx -eq 0 ]] && echo -e "  ${GRAY}  (registry file exists but is empty)${NC}"
  else
    echo -e "  ${GRAY}  No Odoo Manager registry found on destination — fresh server or first use.${NC}"
  fi
  echo ""

  # ── Collect reserved names and ports from destination registry ─
  local dst_registered_names; dst_registered_names=$(echo "$dst_meta_content" | awk -F'|' '{print $1}' | grep -v '^$')
  local dst_registered_ports; dst_registered_ports=$(echo "$dst_meta_content" | awk -F'|' '{print $4"\n"$5}' | grep -v '^$')

  # ── Instance name ─────────────────────────────────────────────
  while true; do
    read -rp "  Instance name (e.g. client-odoo19): " DST_INSTANCE_NAME
    [[ -z "$DST_INSTANCE_NAME" ]] && { print_error "Name cannot be empty"; continue; }
    [[ ! "$DST_INSTANCE_NAME" =~ ^[a-z0-9_-]+$ ]] && { print_error "Use only: a-z 0-9 _ -"; continue; }

    # Check against Odoo Manager registry on destination
    if echo "$dst_registered_names" | grep -qx "$DST_INSTANCE_NAME"; then
      print_warn "Name '${DST_INSTANCE_NAME}' is already registered in Odoo Manager on the destination."
      print_info "Existing instances: $(echo "$dst_registered_names" | tr '\n' ' ')"
      continue
    fi
    # Also check the directory (catches instances created outside Odoo Manager)
    if dst_sh "test -d '${DST_BASE_DIR}/${DST_INSTANCE_NAME}'" &>/dev/null; then
      print_warn "Directory '${DST_BASE_DIR}/${DST_INSTANCE_NAME}' already exists on destination."
      continue
    fi
    break
  done

  DST_INSTANCE_DIR="${DST_BASE_DIR}/${DST_INSTANCE_NAME}"

  # ── Port selection ────────────────────────────────────────────
  echo ""
  print_step "Checking ports on destination (live listeners + Odoo Manager registry)..."

  # Ports currently listening (catches running containers from any source)
  local live_ports; live_ports=$(dst_sh "ss -tlnp 2>/dev/null | awk 'NR>1{print \$4}' | grep -oP ':\K[0-9]+\$'" 2>/dev/null || echo "")

  _dst_port_free() {
    local p=$1
    # Reject if listening right now
    echo "$live_ports" | grep -qx "$p" && return 1
    # Reject if registered in Odoo Manager (catches stopped instances)
    echo "$dst_registered_ports" | grep -qx "$p" && return 1
    return 0
  }

  local def_web=8069
  while ! _dst_port_free "$def_web"; do ((def_web++)); done
  local def_gevent=8072
  while ! _dst_port_free "$def_gevent" || [[ "$def_gevent" -eq "$def_web" ]]; do ((def_gevent++)); done

  print_info "Suggested ports are confirmed free (not used by live containers or registered instances)"
  read -rp "  Web port (Odoo UI) [${def_web}]: "     DST_WEB_PORT;    DST_WEB_PORT=${DST_WEB_PORT:-$def_web}
  read -rp "  Gevent/longpoll port [${def_gevent}]: " DST_GEVENT_PORT; DST_GEVENT_PORT=${DST_GEVENT_PORT:-$def_gevent}

  # Final validation on user-entered ports
  for chk_port in "$DST_WEB_PORT" "$DST_GEVENT_PORT"; do
    if ! _dst_port_free "$chk_port"; then
      print_warn "Port ${chk_port} is already in use or registered on destination."
      print_info "Please restart and choose different ports, or stop the conflicting instance first."
      return 1
    fi
  done

  # ── DB credentials ────────────────────────────────────────────
  echo ""
  local def_pg_user="${DST_INSTANCE_NAME}_user"
  local def_pg_pass; def_pg_pass=$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 16 || echo "odoopass123")

  # Use the master password from the source Odoo if we have it — saves the user from re-typing it
  local def_master="${SRC_MASTER_PASS:-}"
  [[ -z "$def_master" ]] && def_master=$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 12 || echo "master123")

  read -rp "  PostgreSQL user [${def_pg_user}]: "     DST_PG_USER;    DST_PG_USER=${DST_PG_USER:-$def_pg_user}
  read -rp "  PostgreSQL password [auto-generated]: "  DST_PG_PASS;    DST_PG_PASS=${DST_PG_PASS:-$def_pg_pass}
  if [[ -n "$SRC_MASTER_PASS" ]]; then
    echo -e "  ${GRAY}  Master password pre-filled from source Odoo${NC}"
    read -rsp "  Odoo master password [same as source — press Enter to keep]: " DST_MASTER_PASS; echo ""
    DST_MASTER_PASS="${DST_MASTER_PASS:-$def_master}"
  else
    read -rsp "  Odoo master password: " DST_MASTER_PASS; echo ""
    DST_MASTER_PASS="${DST_MASTER_PASS:-$def_master}"
  fi

  # ── Confirm ───────────────────────────────────────────────────
  echo ""
  print_line
  echo -e "  ${WHITE}Will create on ${DST_SSH_HOST}:${NC}"
  echo -e "  Instance:    ${GREEN}${DST_INSTANCE_NAME}${NC}"
  echo -e "  Directory:   ${GREEN}${DST_INSTANCE_DIR}${NC}"
  echo -e "  Web port:    ${GREEN}${DST_WEB_PORT}${NC}   (confirmed free)"
  echo -e "  Gevent port: ${GREEN}${DST_GEVENT_PORT}${NC}  (confirmed free)"
  echo -e "  DB user:     ${GREEN}${DST_PG_USER}${NC}"
  echo -e "  ${GRAY}  This instance will be registered in Odoo Manager on the destination${NC}"
  print_line
  read -rp "  Proceed? [Y/n]: " go
  [[ "$go" =~ ^[Nn]$ ]] && { print_warn "Cancelled"; return 1; }

  # Create directories on destination
  print_step "Creating directories on destination..."
  dst_sh "mkdir -p '${DST_INSTANCE_DIR}/addons' '${DST_INSTANCE_DIR}/config' '${DST_INSTANCE_DIR}/logs'"

  # Generate docker-compose.yml locally and copy to destination
  print_step "Writing docker-compose.yml on destination..."
  local tmp_compose; tmp_compose=$(mktemp)
  cat > "$tmp_compose" <<EOF
# Auto-generated by Odoo Migration Manager
# Instance: ${DST_INSTANCE_NAME} | Odoo ${TARGET_VERSION}
services:
  db:
    image: postgres:15
    container_name: ${DST_INSTANCE_NAME}-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: postgres
      POSTGRES_USER: ${DST_PG_USER}
      POSTGRES_PASSWORD: ${DST_PG_PASS}
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - db_data:/var/lib/postgresql/data
    networks:
      - ${DST_INSTANCE_NAME}_net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DST_PG_USER} -d postgres"]
      interval: 10s
      timeout: 5s
      retries: 10

  odoo:
    image: odoo:${TARGET_VERSION}
    container_name: ${DST_INSTANCE_NAME}-app
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "${DST_WEB_PORT}:8069"
      - "${DST_GEVENT_PORT}:8072"
    environment:
      HOST: db
      PORT: 5432
      USER: ${DST_PG_USER}
      PASSWORD: ${DST_PG_PASS}
    volumes:
      - web_data:/var/lib/odoo
      - ./addons:/mnt/extra-addons
      - ./config/odoo.conf:/etc/odoo/odoo.conf:ro
      - ./logs:/var/log/odoo
    networks:
      - ${DST_INSTANCE_NAME}_net

networks:
  ${DST_INSTANCE_NAME}_net:
    driver: bridge

volumes:
  db_data:
  web_data:
EOF
  dst_scp "$tmp_compose" "${DST_SSH_USER}@${DST_SSH_HOST}:${DST_INSTANCE_DIR}/docker-compose.yml"
  rm -f "$tmp_compose"
  print_success "docker-compose.yml copied to destination"

  # Generate odoo.conf locally and copy to destination
  print_step "Writing odoo.conf on destination..."
  local tmp_conf; tmp_conf=$(mktemp)
  cat > "$tmp_conf" <<EOF
[options]
db_host = db
db_port = 5432
db_user = ${DST_PG_USER}
db_password = ${DST_PG_PASS}
db_name = False
admin_passwd = ${DST_MASTER_PASS}
addons_path = /mnt/extra-addons,/usr/lib/python3/dist-packages/odoo/addons
workers = 2
max_cron_threads = 1
limit_memory_hard = 2684354560
limit_memory_soft = 2147483648
limit_request = 8192
limit_time_cpu = 120
limit_time_real = 240
log_level = info
logfile = /var/log/odoo/odoo.log
longpolling_port = ${DST_GEVENT_PORT}
gevent_port = ${DST_GEVENT_PORT}
list_db = True
proxy_mode = True
EOF
  dst_scp "$tmp_conf" "${DST_SSH_USER}@${DST_SSH_HOST}:${DST_INSTANCE_DIR}/config/odoo.conf"
  rm -f "$tmp_conf"
  print_success "odoo.conf copied to destination"

  # Start DB container on destination
  print_step "Starting PostgreSQL on destination (DB only — not Odoo yet)..."
  dst_sh "cd '${DST_INSTANCE_DIR}' && docker compose up -d db"

  print_step "Waiting for PostgreSQL to be ready on destination..."
  local retries=0
  while ! dst_sh "docker exec '${DST_INSTANCE_NAME}-db' pg_isready -U '${DST_PG_USER}'" &>/dev/null; do
    sleep 4; ((retries++))
    [[ $retries -gt 25 ]] && { print_error "DB never became healthy on destination"; return 1; }
    printf "  ${GRAY}  waiting... (${retries}/25)${NC}\r"
  done
  echo ""
  print_success "PostgreSQL ready on destination"

  # ── Register in Odoo Manager registry on destination ─────────
  # Format: name|version|dir|web_port|gevent_port|pg_user|pg_pass|master_pass|status
  # This makes the instance visible to Odoo Manager.sh on the destination.
  print_step "Registering instance in Odoo Manager on destination..."
  dst_sh "mkdir -p '${DST_BASE_DIR}' && \
    sed -i '/^${DST_INSTANCE_NAME}|/d' '${DST_META_FILE}' 2>/dev/null || true && \
    echo '${DST_INSTANCE_NAME}|${TARGET_VERSION}|${DST_INSTANCE_DIR}|${DST_WEB_PORT}|${DST_GEVENT_PORT}|${DST_PG_USER}|${DST_PG_PASS}|${DST_MASTER_PASS}|stopped' \
      >> '${DST_META_FILE}'"
  print_success "Instance '${DST_INSTANCE_NAME}' registered — Odoo Manager.sh on destination will see it"

  return 0
}

# ══════════════════════════════════════════════════════════════
#  STEP 5 — DUMP DATABASE (local, read-only)
# ══════════════════════════════════════════════════════════════
dump_source_db() {
  local ts; ts=$(date +%Y%m%d_%H%M%S)
  BACKUP_FILE="${LOCAL_BACKUP_DIR}/${SRC_DB_NAME}_v${SRC_VERSION}_${ts}.dump"
  ADDONS_BACKUP="${LOCAL_BACKUP_DIR}/${SRC_DB_NAME}_addons_${ts}.tar.gz"
  MIGRATION_LOG="${LOCAL_LOG_DIR}/migration_${SRC_DB_NAME}_to_v19_${ts}.log"

  ERR_LOG="${LOCAL_LOG_DIR}/ERRORS_${SRC_DB_NAME}_to_v19_${ts}.log"

  mkdir -p "$LOCAL_BACKUP_DIR" "$LOCAL_LOG_DIR"
  touch "$MIGRATION_LOG" "$ERR_LOG"
  log_msg "Migration started: ${SRC_DB_NAME} v${SRC_VERSION} → v${TARGET_VERSION}"
  log_msg "Destination: ${DST_SSH_USER}@${DST_SSH_HOST} instance=${DST_INSTANCE_NAME}"
  echo "# Error log — $(date)" > "$ERR_LOG"
  echo "# DB: ${SRC_DB_NAME} | ${SRC_VERSION} → ${TARGET_VERSION}" >> "$ERR_LOG"
  echo "# Destination: ${DST_SSH_USER}@${DST_SSH_HOST}" >> "$ERR_LOG"
  echo "" >> "$ERR_LOG"

  # pg_dump reads the DB — does NOT modify anything on the source
  print_step "Dumping '${SRC_DB_NAME}' (binary format, UTF-8/Arabic safe)..."
  if [[ "$SRC_IS_DOCKER" == "true" ]]; then
    print_info "Source is Docker — running pg_dump inside container '${SRC_DOCKER_CONTAINER_DB}'"
    # Stream dump from inside the container directly to a local file — nothing written inside container
    docker exec \
      -e PGPASSWORD="$SRC_DB_PASS" \
      -e PGCLIENTENCODING="UTF8" \
      "$SRC_DOCKER_CONTAINER_DB" \
      pg_dump -U "$SRC_DB_USER" \
        -F c --no-owner --no-acl --encoding=UTF8 \
        "$SRC_DB_NAME" > "$BACKUP_FILE"
  else
    print_info "Source is server Odoo — auth method: ${SRC_PG_AUTH_METHOD}"
    _src_pg pg_dump \
      -F c --no-owner --no-acl --encoding=UTF8 \
      "$SRC_DB_NAME" > "$BACKUP_FILE"
  fi

  if [[ ! -s "$BACKUP_FILE" ]]; then
    print_error "Dump failed or empty. Check PostgreSQL credentials."
    log_msg "ERROR: Dump failed"
    return 1
  fi

  local sz; sz=$(du -sh "$BACKUP_FILE" | cut -f1)
  print_success "Dump complete: ${BACKUP_FILE} (${sz})"
  log_msg "Dump: ${BACKUP_FILE} (${sz})"

  # Backup local addons (local tar — does not modify source, just reads)
  if [[ ${#SRC_ADDONS_PATHS[@]} -gt 0 ]]; then
    print_step "Archiving custom addons..."
    tar -czf "$ADDONS_BACKUP" "${SRC_ADDONS_PATHS[@]}" 2>/dev/null \
      && print_success "Addons archived: ${ADDONS_BACKUP}" \
      || print_warn "Addons archive had warnings (non-critical)"
  fi

  return 0
}

# ══════════════════════════════════════════════════════════════
#  STEP 6 — TRANSFER DUMP TO DESTINATION
# ══════════════════════════════════════════════════════════════
transfer_to_destination() {
  local sz; sz=$(du -sh "$BACKUP_FILE" | cut -f1)
  print_step "Transferring dump (${sz}) to destination..."
  print_info "This may take a few minutes depending on database size and network speed"

  dst_scp "$BACKUP_FILE" "${DST_SSH_USER}@${DST_SSH_HOST}:/tmp/_odoo_migrate.dump"
  if ! dst_sh "test -s /tmp/_odoo_migrate.dump"; then
    print_error "Transfer failed — dump not found on destination"
    return 1
  fi
  print_success "Dump transferred to destination"
  log_msg "Dump transferred to destination"
  return 0
}

# ══════════════════════════════════════════════════════════════
#  STEP 7 — RESTORE DB ON DESTINATION
# ══════════════════════════════════════════════════════════════
restore_on_destination() {
  print_step "Preparing database '${SRC_DB_NAME}' on destination..."

  # Terminate any existing connections then drop/recreate
  dst_sh "docker exec -e PGPASSWORD='${DST_PG_PASS}' '${DST_INSTANCE_NAME}-db' \
    psql -U '${DST_PG_USER}' postgres \
    -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${SRC_DB_NAME}' AND pid<>pg_backend_pid();\"" \
    &>/dev/null || true

  dst_sh "docker exec -e PGPASSWORD='${DST_PG_PASS}' '${DST_INSTANCE_NAME}-db' \
    psql -U '${DST_PG_USER}' postgres \
    -c \"DROP DATABASE IF EXISTS \\\"${SRC_DB_NAME}\\\";\"" &>/dev/null

  dst_sh "docker exec -e PGPASSWORD='${DST_PG_PASS}' '${DST_INSTANCE_NAME}-db' \
    psql -U '${DST_PG_USER}' postgres \
    -c \"CREATE DATABASE \\\"${SRC_DB_NAME}\\\" ENCODING 'UTF8' TEMPLATE template0;\""

  dst_sh "docker exec -e PGPASSWORD='${DST_PG_PASS}' '${DST_INSTANCE_NAME}-db' \
    psql -U '${DST_PG_USER}' postgres \
    -c \"GRANT ALL PRIVILEGES ON DATABASE \\\"${SRC_DB_NAME}\\\" TO \\\"${DST_PG_USER}\\\";\""

  print_step "Copying dump into destination DB container..."
  dst_sh "docker cp /tmp/_odoo_migrate.dump '${DST_INSTANCE_NAME}-db:/tmp/restore.dump'"

  print_step "Restoring database on destination (may take several minutes)..."
  local restore_log
  restore_log=$(dst_sh "docker exec \
    -e PGPASSWORD='${DST_PG_PASS}' \
    -e PGCLIENTENCODING='UTF8' \
    '${DST_INSTANCE_NAME}-db' \
    pg_restore -U '${DST_PG_USER}' -d '${SRC_DB_NAME}' \
      --no-owner --no-acl -F c /tmp/restore.dump 2>&1" || true)

  echo "$restore_log" >> "$MIGRATION_LOG"

  # Separate safe warnings from real errors
  local safe_count real_count
  safe_count=$(echo "$restore_log" | grep -cE "already exists|role.*does not exist" || true)
  real_count=$(echo  "$restore_log" | grep -cE "^pg_restore: error:" || true)
  real_count=$(( real_count - safe_count ))
  [[ $real_count -lt 0 ]] && real_count=0

  echo ""
  echo -e "  ${WHITE}${BOLD}  pg_restore result:${NC}"
  print_line

  if [[ $real_count -eq 0 && $safe_count -eq 0 ]]; then
    print_success "Restore completed with zero errors"
  else
    [[ $safe_count -gt 0 ]] && print_info "${safe_count} safe warning(s) — 'already exists' messages, ignore these"
    [[ $real_count -gt 0 ]] && print_warn "${real_count} real error(s) — shown below"

    echo ""
    echo "$restore_log" | while IFS= read -r l; do
      [[ -z "$l" ]] && continue
      local exp; exp=$(explain_error "$l")
      if echo "$l" | grep -qE "already exists|role.*does not exist"; then
        echo -e "  ${GRAY}  ○ ${l}${NC}"
        [[ -n "$exp" ]] && echo -e "  ${GREEN}    ↳ ${exp}${NC}"
      elif echo "$l" | grep -qE "^pg_restore: error:|^ERROR:"; then
        echo -e "  ${RED}  ▶ ${l}${NC}"
        [[ -n "$exp" ]] && echo -e "  ${YELLOW}    ↳ ${exp}${NC}"
        echo "$l" >> "$ERR_LOG"
      else
        echo -e "  ${GRAY}  · ${l}${NC}"
      fi
    done
  fi

  print_line
  # Cleanup temp files on destination only (/tmp — source untouched)
  dst_sh "docker exec '${DST_INSTANCE_NAME}-db' rm -f /tmp/restore.dump; rm -f /tmp/_odoo_migrate.dump" &>/dev/null
  log_msg "DB restore complete: safe_warns=${safe_count} real_errors=${real_count}"

  if [[ $real_count -gt 0 ]]; then
    echo ""
    print_warn "Restore had ${real_count} real error(s). This may cause issues in the upgrade."
    read -rp "  $(echo -e "${YELLOW}Continue anyway? [Y/n]: ${NC}")" cont
    [[ "$cont" =~ ^[Nn]$ ]] && return 1
  else
    print_success "Database restored successfully on destination"
  fi
  return 0
}

# ══════════════════════════════════════════════════════════════
#  STEP 8 — MIGRATE CUSTOM MODULES TO DESTINATION
# ══════════════════════════════════════════════════════════════
migrate_modules() {
  if [[ ${#SRC_ADDONS_PATHS[@]} -eq 0 ]] && [[ ! -f "$ADDONS_BACKUP" ]]; then
    print_info "No custom addons found — skipping module migration"
    return 0
  fi

  echo ""
  print_step "Migrating custom modules..."

  # Extract addons to local temp dir
  local tmp_addons; tmp_addons=$(mktemp -d)

  if [[ -f "$ADDONS_BACKUP" && -s "$ADDONS_BACKUP" ]]; then
    tar -xzf "$ADDONS_BACKUP" -C "$tmp_addons" 2>/dev/null || true
  else
    # Copy directly from source addons paths
    for p in "${SRC_ADDONS_PATHS[@]}"; do
      cp -r "$p/." "$tmp_addons/" 2>/dev/null || true
    done
  fi

  # Safety check: every manifest we edit must be inside $tmp_addons (the temp copy),
  # never inside an original source addons path.
  local tmp_addons_real; tmp_addons_real=$(realpath "$tmp_addons")

  # Find modules — all paths will be under $tmp_addons_real
  local -a modules=()
  while IFS= read -r mf; do
    local mdir; mdir=$(dirname "$mf")
    # Abort rather than touch a source path (should never happen, but be certain)
    local mdir_real; mdir_real=$(realpath "$mdir")
    if [[ "$mdir_real" != "$tmp_addons_real"* ]]; then
      print_error "SAFETY ABORT: manifest path '${mdir}' is outside temp dir — source would be modified!"
      rm -rf "$tmp_addons"
      return 1
    fi
    modules+=("$(basename "$mdir"):$mdir")
  done < <(find "$tmp_addons" -maxdepth 4 -name "__manifest__.py" 2>/dev/null)

  if [[ ${#modules[@]} -eq 0 ]]; then
    print_info "No custom modules found in addons paths"
    rm -rf "$tmp_addons"
    return 0
  fi

  local tgt_major; tgt_major=$(version_major "$TARGET_VERSION")
  local deprecated=("@api\.multi" "@api\.one" "self\.pool\.get" "from openerp" "_columns\s*=" "fields\.function\(")

  print_success "Found ${#modules[@]} custom module(s)"
  echo ""
  printf "  ${BOLD}${CYAN}%-28s %-24s %s${NC}\n" "MODULE" "VERSION" "STATUS"
  print_line

  for entry in "${modules[@]}"; do
    local mname="${entry%%:*}"
    local mdir="${entry##*:}"
    local manifest="$mdir/__manifest__.py"

    # Update version in manifest (ASCII-only sed — Arabic content inside file untouched)
    local old_ver new_ver=""
    old_ver=$(grep -oP "'version'\s*:\s*'\K[^']*" "$manifest" 2>/dev/null | head -1)
    if [[ -n "$old_ver" ]]; then
      local old_maj; old_maj=$(echo "$old_ver" | grep -oP '^\d+')
      new_ver="${old_ver/$old_maj/$tgt_major}"
      sed -i "s/'version'\s*:\s*'${old_ver}'/'version': '${new_ver}'/" "$manifest" 2>/dev/null
    fi

    # Scan for deprecated APIs
    local warns=()
    for pat in "${deprecated[@]}"; do
      grep -rqP "$pat" "$mdir" 2>/dev/null && warns+=("$(echo "$pat" | tr -d '\\')")
    done

    if [[ ${#warns[@]} -eq 0 ]]; then
      printf "  ${WHITE}%-28s${NC} ${GRAY}%-24s${NC} ${GREEN}✔ OK${NC}\n" \
        "$mname" "${old_ver:---}→${new_ver:-${tgt_major}.0.1.0.0}"
    else
      printf "  ${WHITE}%-28s${NC} ${GRAY}%-24s${NC} ${YELLOW}⚠ needs developer review${NC}\n" \
        "$mname" "${old_ver:---}→${new_ver:-${tgt_major}.0.1.0.0}"
    fi
    log_msg "Module ${mname}: ${old_ver} → ${new_ver} | warns: ${warns[*]:-none}"
  done

  echo ""
  # Transfer updated addons to destination
  print_step "Copying modules to destination addons folder..."
  if command -v rsync &>/dev/null; then
    dst_rsync "$tmp_addons/" "${DST_SSH_USER}@${DST_SSH_HOST}:${DST_INSTANCE_DIR}/addons/"
  else
    # Fallback: tar pipe over SSH
    tar -czf - -C "$tmp_addons" . 2>/dev/null \
      | dst_sh "tar -xzf - -C '${DST_INSTANCE_DIR}/addons/'"
  fi
  print_success "Modules transferred to destination: ${DST_INSTANCE_DIR}/addons/"

  rm -rf "$tmp_addons"
  return 0
}

# ══════════════════════════════════════════════════════════════
#  STEP 9 — RUN UPGRADE HOPS ON DESTINATION
# ══════════════════════════════════════════════════════════════
run_hop_on_destination() {
  local hop_ver=$1 db=$2

  echo ""
  echo -e "  ${CYAN}${BOLD}  ─── Upgrading to Odoo ${hop_ver} on destination ───${NC}"

  local ou_img="${OPENUPGRADE_IMG}:${hop_ver}"
  local std_img="odoo:${hop_ver}"

  # Decide which image to use
  local use_img="$std_img"
  if dst_sh "docker image inspect '$ou_img'" &>/dev/null 2>&1 \
      || dst_sh "docker pull '$ou_img'" &>/dev/null 2>&1; then
    use_img="$ou_img"
    print_step "Using OpenUpgrade image: ${use_img}"
  else
    print_step "Using native Odoo image: ${use_img}"
  fi

  echo ""
  echo -e "  ${GRAY}  Legend: ${RED}ERR${NC} ${YELLOW}WARN${NC} ${GREEN}OK${NC} ${GRAY}INFO${NC}"
  echo -e "  ${GRAY}  Each error line shows an explanation to help you fix it.${NC}"
  echo -e "  ${GRAY}  Full log: ${MIGRATION_LOG}${NC}"
  print_line
  echo ""

  # Record ERR_LOG size before this hop so show_hop_summary knows which lines are new
  local err_log_before; err_log_before=$(wc -l < "$ERR_LOG" 2>/dev/null || echo 0)

  # Temp files for counting (needed because the pipe runs in a subshell)
  local tmp_err; tmp_err=$(mktemp)
  local tmp_warn; tmp_warn=$(mktemp)
  echo 0 > "$tmp_err"; echo 0 > "$tmp_warn"

  local _in_traceback=0

  dst_sh "docker run --rm \
    --network '${DST_INSTANCE_NAME}_net' \
    -e HOST=db \
    -e USER='${DST_PG_USER}' \
    -e PASSWORD='${DST_PG_PASS}' \
    -v '${DST_INSTANCE_DIR}/addons:/mnt/extra-addons' \
    -v '${DST_INSTANCE_DIR}/config/odoo.conf:/etc/odoo/odoo.conf:ro' \
    -v '${DST_INSTANCE_DIR}/logs:/var/log/odoo' \
    '${use_img}' \
    odoo --update=all --stop-after-init \
      --db_host=db \
      --db_user='${DST_PG_USER}' \
      --db_password='${DST_PG_PASS}' \
      --database='${db}' \
      --no-http 2>&1" \
  | while IFS= read -r line; do

      echo "$line" >> "$MIGRATION_LOG"

      # ── CRITICAL ───────────────────────────────────────────────
      if echo "$line" | grep -qE " CRITICAL "; then
        echo -e "  ${RED}${BOLD}│ CRITICAL │ ${line}${NC}"
        echo "$line" >> "$ERR_LOG"
        local exp; exp=$(explain_error "$line")
        [[ -n "$exp" ]] && echo -e "  ${RED}│          ↳ ${exp}${NC}"
        local c; c=$(cat "$tmp_err"); echo $((c+1)) > "$tmp_err"

      # ── ERROR ──────────────────────────────────────────────────
      elif echo "$line" | grep -qE " ERROR "; then
        echo -e "  ${RED}│ ERROR │ ${line}${NC}"
        echo "$line" >> "$ERR_LOG"
        local exp; exp=$(explain_error "$line")
        [[ -n "$exp" ]] && echo -e "  ${YELLOW}│       ↳ ${exp}${NC}"
        local c; c=$(cat "$tmp_err"); echo $((c+1)) > "$tmp_err"

      # ── Traceback start ────────────────────────────────────────
      elif echo "$line" | grep -qE "^Traceback|^  File "; then
        echo -e "  ${RED}│ TRACE │ ${line}${NC}"
        echo "$line" >> "$ERR_LOG"
        [[ "$line" == "Traceback"* ]] && {
          local exp; exp=$(explain_error "$line")
          [[ -n "$exp" ]] && echo -e "  ${YELLOW}│       ↳ ${exp}${NC}"
        }

      # ── Exception line (the actual error in a traceback) ───────
      elif echo "$line" | grep -qE "^[A-Za-z]+Error:|^[A-Za-z]+Exception:|^odoo\.exceptions"; then
        echo -e "  ${RED}│ EXCP  │ ${line}${NC}"
        echo "$line" >> "$ERR_LOG"
        local exp; exp=$(explain_error "$line")
        [[ -n "$exp" ]] && echo -e "  ${YELLOW}│       ↳ ${exp}${NC}"
        local c; c=$(cat "$tmp_err"); echo $((c+1)) > "$tmp_err"

      # ── WARNING ────────────────────────────────────────────────
      elif echo "$line" | grep -qE " WARNING "; then
        echo -e "  ${YELLOW}│ WARN  │ ${GRAY}${line}${NC}"
        local c; c=$(cat "$tmp_warn"); echo $((c+1)) > "$tmp_warn"

      # ── Important INFO lines (module loading progress) ─────────
      elif echo "$line" | grep -qE "Loading module|Updating module|module\.loading|Modules loaded|odoo\.service|Registry loaded|init db"; then
        echo -e "  ${GREEN}│ OK    │ ${GRAY}${line}${NC}"

      # ── All other lines (dim, just log them) ───────────────────
      else
        echo -e "  ${GRAY}│       │ ${line}${NC}"
      fi

    done

  local hop_errors; hop_errors=$(cat "$tmp_err" 2>/dev/null || echo 0)
  local hop_warns;  hop_warns=$(cat  "$tmp_warn" 2>/dev/null || echo 0)
  rm -f "$tmp_err" "$tmp_warn"

  echo ""
  log_msg "Hop to ${hop_ver} finished: errors=${hop_errors} warnings=${hop_warns}"

  show_hop_summary "$hop_ver" "$hop_errors" "$hop_warns" "$err_log_before"
  return $?
}

run_all_hops() {
  local db=$1
  local total=${#HOP_LIST[@]}
  local current=1

  for hop_ver in "${HOP_LIST[@]}"; do
    echo ""
    print_line
    echo -e "  ${WHITE}${BOLD}  Hop ${current}/${total} → Odoo ${hop_ver}${NC}"
    print_line

    # Save rollback point on destination before each hop
    local hop_bk="${DST_HOME}/hop_${db}_to_${hop_ver}_$(date +%Y%m%d_%H%M%S).dump"
    print_step "Saving rollback point on destination before ${hop_ver}..."
    dst_sh "docker exec \
      -e PGPASSWORD='${DST_PG_PASS}' \
      -e PGCLIENTENCODING='UTF8' \
      '${DST_INSTANCE_NAME}-db' \
      pg_dump -U '${DST_PG_USER}' -F c --no-owner --no-acl --encoding=UTF8 \
        '${db}' > '${hop_bk}' 2>/dev/null" || true
    dst_sh "test -s '${hop_bk}'" &>/dev/null \
      && print_success "Rollback point: ${hop_bk}" \
      || print_warn "Rollback point save failed (continuing anyway)"

    # run_hop_on_destination streams logs, calls show_hop_summary, and returns
    # 0 (continue) or 1 (user chose to stop after seeing errors)
    if ! run_hop_on_destination "$hop_ver" "$db"; then
      print_warn "Migration paused after hop to v${hop_ver}."
      print_info "Rollback points are saved on destination in ${DST_HOME}/"
      print_info "Fix the errors shown above, then re-run from this hop."
      return 1
    fi

    ((current++))
  done
  return 0
}

# ══════════════════════════════════════════════════════════════
#  STEP 10 — START & VERIFY ON DESTINATION
# ══════════════════════════════════════════════════════════════
post_verify() {
  local db=$1
  echo ""
  print_banner
  echo -e "  ${WHITE}${BOLD}✅  STEP 10 — Start & Verify Odoo 19${NC}"
  print_line
  echo ""

  print_step "Starting Odoo 19 on destination..."
  dst_sh "cd '${DST_INSTANCE_DIR}' && docker compose up -d"
  print_info "Waiting 40 seconds for Odoo to initialize..."
  sleep 40

  local ok=0 warn=0

  # Container status
  local st; st=$(dst_sh "docker inspect --format='{{.State.Status}}' '${DST_INSTANCE_NAME}-app' 2>/dev/null || echo unknown")
  if [[ "$st" == "running" ]]; then
    print_success "Odoo 19 container: running"; ((ok++))
  else
    print_error "Odoo 19 container status: ${st}"; ((warn++))
    print_info "Check on destination: docker logs ${DST_INSTANCE_NAME}-app"
  fi

  # HTTP check (from source to destination)
  local http; http=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 20 "http://${DST_SSH_HOST}:${DST_WEB_PORT}/web/login" 2>/dev/null || echo "0")
  if [[ "$http" =~ ^(200|303|301|302)$ ]]; then
    print_success "Web UI responding at http://${DST_SSH_HOST}:${DST_WEB_PORT} (HTTP ${http})"; ((ok++))
  else
    print_warn "Web UI returned HTTP ${http} — may still be starting"; ((warn++))
  fi

  # Arabic data check
  print_step "Verifying Arabic/UTF-8 data integrity..."
  local arabic_count
  arabic_count=$(dst_sh "docker exec \
    -e PGPASSWORD='${DST_PG_PASS}' \
    '${DST_INSTANCE_NAME}-db' \
    psql -U '${DST_PG_USER}' -d '${db}' -t \
    -c \"SELECT COUNT(*) FROM res_partner WHERE name ~ '[^\\\\x00-\\\\x7F]';\" 2>/dev/null" \
    | tr -d ' ')

  if [[ "$arabic_count" =~ ^[0-9]+$ && "$arabic_count" -gt 0 ]]; then
    print_success "Arabic data verified: ${arabic_count} records with Arabic/non-ASCII names"; ((ok++))
  elif [[ "$arabic_count" == "0" ]]; then
    print_info "No Arabic names in res_partner (normal if data is in other fields)"; ((ok++))
  else
    print_warn "Could not verify Arabic data yet (DB still initializing)"; ((warn++))
  fi

  # Module count
  local mod_count
  mod_count=$(dst_sh "docker exec \
    -e PGPASSWORD='${DST_PG_PASS}' \
    '${DST_INSTANCE_NAME}-db' \
    psql -U '${DST_PG_USER}' -d '${db}' -t \
    -c \"SELECT COUNT(*) FROM ir_module_module WHERE state='installed';\" 2>/dev/null" \
    | tr -d ' ')
  [[ "$mod_count" =~ ^[0-9]+$ ]] && \
    print_success "Installed modules in DB: ${mod_count}" && ((ok++))

  # ── Final error report ───────────────────────────────────────
  echo ""
  print_line
  echo -e "  ${WHITE}${BOLD}  📋  FULL MIGRATION ERROR REPORT${NC}"
  print_line

  if [[ -f "$ERR_LOG" ]]; then
    local total_errors; total_errors=$(grep -c . "$ERR_LOG" 2>/dev/null || echo 0)
    if [[ "$total_errors" -eq 0 ]]; then
      print_success "Zero errors logged across all hops — clean migration"
    else
      echo -e "  ${YELLOW}  Total error lines logged: ${total_errors}${NC}"
      echo -e "  ${GRAY}  (Each line below is a unique error type)${NC}"
      echo ""

      # Deduplicate similar errors and show top 30
      local shown_errors=0
      while IFS= read -r err_line; do
        [[ $shown_errors -ge 30 ]] && {
          echo -e "  ${GRAY}  ... ${total_errors} total. See full list:${NC}"
          echo -e "  ${GRAY}  ${ERR_LOG}${NC}"
          break
        }
        echo -e "  ${RED}  ▶ ${err_line}${NC}"
        local exp; exp=$(explain_error "$err_line")
        if [[ -n "$exp" ]]; then
          local ecolor="$YELLOW"
          [[ "$exp" == SAFE*    ]] && ecolor="$GREEN"
          [[ "$exp" == SERIOUS* ]] && ecolor="$RED"
          [[ "$exp" == STOP*    ]] && ecolor="$RED"
          echo -e "  ${ecolor}    ↳ ${exp}${NC}"
        fi
        echo ""
        ((shown_errors++))
      done < <(sort -u "$ERR_LOG")

      echo -e "  ${CYAN}  Error log: ${GRAY}${ERR_LOG}${NC}"
      echo -e "  ${CYAN}  Full log:  ${GRAY}${MIGRATION_LOG}${NC}"
      echo ""
      echo -e "  ${YELLOW}  What to do with errors:${NC}"
      echo -e "  ${GRAY}  • SAFE lines: no action needed (ignored by Odoo)${NC}"
      echo -e "  ${GRAY}  • FIX lines:  follow the ↳ instruction above${NC}"
      echo -e "  ${GRAY}  • SERIOUS lines: contact your developer before go-live${NC}"
      echo -e "  ${GRAY}  • If Odoo opened and data looks correct, the migration succeeded${NC}"
    fi
  else
    print_info "No error log found (was not initialized — check migration was fully run)"
  fi

  echo ""
  echo -e "  ${CYAN}${BOLD}  ╔══════════════════════════════════════════════════════════╗"
  echo -e "  ║  🎉  MIGRATION TO ODOO 19 COMPLETE                      ║"
  echo -e "  ╠══════════════════════════════════════════════════════════╣"
  printf "  ${CYAN}║  %-22s ${GREEN}%-31s${CYAN}║\n" "Destination server:" "$DST_SSH_HOST"
  printf "  ${CYAN}║  %-22s ${GREEN}%-31s${CYAN}║\n" "Instance name:"     "$DST_INSTANCE_NAME"
  printf "  ${CYAN}║  %-22s ${WHITE}%-31s${CYAN}║\n" "Odoo version:"      "19.0"
  printf "  ${CYAN}║  %-22s ${WHITE}%-31s${CYAN}║\n" "Database:"          "$db"
  printf "  ${CYAN}║  %-22s ${GREEN}%-31s${CYAN}║\n" "URL:"               "http://${DST_SSH_HOST}:${DST_WEB_PORT}"
  printf "  ${CYAN}║  %-22s ${YELLOW}%-31s${CYAN}║\n" "Login:"             "http://${DST_SSH_HOST}:${DST_WEB_PORT}/web/login"
  printf "  ${CYAN}║  %-22s ${YELLOW}%-31s${CYAN}║\n" "Admin user:"        "admin"
  printf "  ${CYAN}║  %-22s ${YELLOW}%-31s${CYAN}║\n" "Master password:"   "$DST_MASTER_PASS"
  echo -e "  ${CYAN}╠══════════════════════════════════════════════════════════╣"
  printf "  ${CYAN}║  %-22s ${GRAY}%-31s${CYAN}║\n" "Instance dir:"      "$DST_INSTANCE_DIR"
  printf "  ${CYAN}║  %-22s ${GRAY}%-31s${CYAN}║\n" "DB backup:"         "$BACKUP_FILE"
  printf "  ${CYAN}║  %-22s ${GRAY}%-31s${CYAN}║\n" "Migration log:"     "$MIGRATION_LOG"
  echo -e "  ${CYAN}╠══════════════════════════════════════════════════════════╣"
  printf "  ${CYAN}║  %-22s ${GREEN}${ok} passed${NC}${CYAN} / ${YELLOW}${warn} warnings${NC}${CYAN}%-20s${CYAN}║\n" "Checks:" ""
  echo -e "  ${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""

  if [[ $warn -gt 0 ]]; then
    print_warn "If Odoo doesn't open, wait 30s more and try again — first start after migration is slower."
    print_info "For module errors: Settings → Developer Mode → Apps → Update Apps List"
  fi

  # Update status in destination Odoo Manager registry
  local dst_meta="${DST_BASE_DIR}/.odoo_manager_instances"
  local new_status="running"
  [[ $warn -gt 0 ]] && new_status="running-with-warnings"
  dst_sh "sed -i 's/^${DST_INSTANCE_NAME}|.*|stopped\$/${DST_INSTANCE_NAME}|${TARGET_VERSION}|${DST_INSTANCE_DIR}|${DST_WEB_PORT}|${DST_GEVENT_PORT}|${DST_PG_USER}|${DST_PG_PASS}|${DST_MASTER_PASS}|${new_status}/' '${dst_meta}' 2>/dev/null || true"
  print_success "Odoo Manager registry updated: status = ${new_status}"

  log_msg "Migration complete: ok=${ok} warn=${warn}"
}

# ══════════════════════════════════════════════════════════════
#  MAIN MIGRATION FLOW
# ══════════════════════════════════════════════════════════════
run_migration() {
  print_banner
  echo -e "  ${WHITE}${BOLD}  HOW THIS WORKS:${NC}"
  echo ""
  echo -e "  ${GRAY}  ┌─ SOURCE (this machine) ────────────────────────────────┐${NC}"
  echo -e "  ${GRAY}  │  READ-ONLY — Odoo DB, config, and addons are NEVER     │${NC}"
  echo -e "  ${GRAY}  │  modified. Only pg_dump (read) is run against the DB.  │${NC}"
  echo -e "  ${GRAY}  └────────────────────────────────────────────────────────┘${NC}"
  echo -e "  ${GRAY}                      │ pg_dump + addons (SSH)${NC}"
  echo -e "  ${GRAY}                      ▼${NC}"
  echo -e "  ${GRAY}  ┌─ DESTINATION (remote Docker server) ───────────────────┐${NC}"
  echo -e "  ${GRAY}  │  Docker installed → Odoo 19 instance created           │${NC}"
  echo -e "  ${GRAY}  │  DB restored → step-by-step upgrade → Odoo 19 running │${NC}"
  echo -e "  ${GRAY}  └────────────────────────────────────────────────────────┘${NC}"
  echo ""
  print_line
  echo -e "  ${WHITE}${BOLD}  SOURCE MACHINE — WHAT THIS SCRIPT WILL AND WILL NOT DO:${NC}"
  echo ""
  echo -e "  ${GREEN}  ✔ WILL READ (no modifications):${NC}"
  echo -e "  ${GRAY}    • odoo.conf — to get DB credentials and addons paths${NC}"
  echo -e "  ${GRAY}    • PostgreSQL DB via pg_dump — export only, DB is untouched after${NC}"
  echo -e "  ${GRAY}    • Custom addons folders — copied to a temp dir, originals untouched${NC}"
  echo ""
  echo -e "  ${GREEN}  ✔ WILL CREATE (only in your home directory, never in Odoo directories):${NC}"
  echo -e "  ${GRAY}    • ${LOCAL_BACKUP_DIR}/${NC}"
  echo -e "  ${GRAY}      — one .dump file (pg_dump export of the DB)${NC}"
  echo -e "  ${GRAY}      — one .tar.gz archive of custom addons (copy, originals untouched)${NC}"
  echo -e "  ${GRAY}    • ${LOCAL_LOG_DIR}/${NC}"
  echo -e "  ${GRAY}      — migration.log and ERRORS.log for this run${NC}"
  echo ""
  echo -e "  ${RED}  ✖ WILL NEVER:${NC}"
  echo -e "  ${GRAY}    • Modify the Odoo database (pg_dump is read-only)${NC}"
  echo -e "  ${GRAY}    • Edit odoo.conf or any Odoo config file${NC}"
  echo -e "  ${GRAY}    • Edit or delete any source addon or module file${NC}"
  echo -e "  ${GRAY}    • Stop, restart, or touch the Odoo or PostgreSQL service${NC}"
  echo -e "  ${GRAY}    • Write to any Odoo directory (/etc/odoo, /opt/odoo, addons paths)${NC}"
  echo -e "  ${GRAY}    • Install any package or run any apt/yum command on this machine${NC}"
  print_line
  echo ""
  read -rp "  $(echo -e "${WHITE}Press [Enter] to confirm you have read the above and start...${NC}")" _

  # ── 1. Read local source ─────────────────────────────────
  setup_source || { pause; return; }

  # Build hop list immediately after source version is known
  IFS=' ' read -ra HOP_LIST <<< "$(build_hop_list "$SRC_VERSION" "$TARGET_VERSION")"
  local hops=${#HOP_LIST[@]}
  echo ""
  print_info "Migration path: v${SRC_VERSION} → $(IFS=' → '; echo "${HOP_LIST[*]}")"
  print_info "Total hops: ${hops} | Estimated time: $((hops * 15))–$((hops * 40)) minutes"

  # ── 2. Connect to destination ────────────────────────────
  echo ""
  print_line
  setup_destination_ssh || { pause; return; }

  # ── 3. Install Docker on destination if needed ───────────
  echo ""
  print_line
  install_docker_on_destination || { pause; return; }

  # ── 4. Create Odoo 19 instance on destination ───────────
  echo ""
  print_line
  create_destination_instance || { pause; return; }

  # ── 5. Dump local DB (source read-only) ─────────────────
  echo ""
  print_line
  echo ""
  print_step "Dumping source database..."
  dump_source_db || { print_error "Dump failed. Aborting."; pause; return; }

  # ── Confirm before transfer ──────────────────────────────
  echo ""
  print_line
  echo -e "\n  ${WHITE}${BOLD}Ready to migrate — final review:${NC}"
  echo -e "  DB:          ${GREEN}${SRC_DB_NAME}${NC} (v${SRC_VERSION})"
  echo -e "  Hops:        ${GREEN}$(IFS=' → '; echo "${HOP_LIST[*]}")${NC}"
  echo -e "  Destination: ${GREEN}${DST_SSH_USER}@${DST_SSH_HOST}${NC}"
  echo -e "  Instance:    ${GREEN}${DST_INSTANCE_NAME}${NC}  port ${DST_WEB_PORT}"
  echo -e "  Backup:      ${GREEN}${BACKUP_FILE}${NC}"
  print_line
  confirm "Start the migration now?" || { print_warn "Cancelled"; pause; return; }

  # ── 6. Transfer dump to destination ─────────────────────
  echo ""
  print_line
  echo ""
  transfer_to_destination || { print_error "Transfer failed"; pause; return; }

  # ── 7. Restore DB on destination ────────────────────────
  echo ""
  print_line
  echo ""
  print_step "Restoring DB on destination..."
  restore_on_destination || { print_error "Restore failed"; pause; return; }

  # ── 8. Migrate custom modules ────────────────────────────
  echo ""
  print_line
  migrate_modules

  # ── 9. Run upgrade hops on destination ──────────────────
  echo ""
  print_line
  echo ""
  print_step "Starting upgrade chain on destination (${hops} hop(s) to Odoo 19)..."
  print_warn "Keep this terminal open — do not close it during upgrade"
  echo ""
  run_all_hops "$SRC_DB_NAME" || { pause; return; }

  # ── 10. Verify ──────────────────────────────────────────
  post_verify "$SRC_DB_NAME"
  pause
}

# ══════════════════════════════════════════════════════════════
#  DEPENDENCY CHECK (on source machine)
# ══════════════════════════════════════════════════════════════
check_local_deps() {
  local missing=0

  if ! command -v pg_dump &>/dev/null; then
    print_warn "pg_dump not found — installing postgresql-client..."
    sudo apt-get install -y postgresql-client 2>/dev/null \
      || sudo yum install -y postgresql 2>/dev/null \
      || { print_error "Cannot install pg_dump. Please install postgresql-client manually."; ((missing++)); }
    command -v pg_dump &>/dev/null && print_success "pg_dump installed"
  else
    print_success "pg_dump found"
  fi

  if ! command -v ssh &>/dev/null; then
    print_error "ssh not found — please install openssh-client"
    ((missing++))
  else
    print_success "ssh found"
  fi

  if ! command -v curl &>/dev/null; then
    sudo apt-get install -y curl 2>/dev/null || true
  fi

  mkdir -p "$LOCAL_BACKUP_DIR" "$LOCAL_LOG_DIR"

  [[ $missing -gt 0 ]] && return 1
  return 0
}

# ══════════════════════════════════════════════════════════════
#  MAIN MENU
# ══════════════════════════════════════════════════════════════
main_menu() {
  while true; do
    print_banner
    local bk_count; bk_count=$(ls "$LOCAL_BACKUP_DIR"/*.dump 2>/dev/null | wc -l | tr -d ' ')
    echo -e "  ${GRAY}Local backups: ${WHITE}${bk_count}${GRAY} | ${WHITE}${LOCAL_BACKUP_DIR}${NC}"
    print_line
    echo ""
    echo -e "  ${WHITE}${BOLD}Main Menu${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} 🚀  Start migration to Odoo 19"
    echo -e "  ${CYAN}2)${NC} 💾  List local backups"
    echo -e "  ${CYAN}3)${NC} 📜  View migration log"
    echo ""
    print_line
    echo -e "  ${GRAY}0) Exit${NC}"
    echo ""
    read -rp "  $(echo -e "${WHITE}Choose [0-3]: ${NC}")" choice

    case $choice in
      1) run_migration ;;
      2)
        print_banner
        echo -e "  ${WHITE}${BOLD}💾  LOCAL BACKUPS${NC}"; print_line; echo ""
        ls -lth "$LOCAL_BACKUP_DIR"/ 2>/dev/null | grep -E '\.dump|\.tar\.gz' \
          | awk '{printf "  %s  %s  %s\n", $5, $6" "$7" "$8, $9}' \
          || print_warn "No backups yet"
        echo ""
        print_info "Location: ${LOCAL_BACKUP_DIR}"
        pause ;;
      3)
        print_banner
        echo -e "  ${WHITE}${BOLD}📜  MIGRATION LOGS${NC}"; print_line; echo ""
        local -a logs=()
        while IFS= read -r f; do logs+=("$f"); done < <(ls -t "$LOCAL_LOG_DIR"/*.log 2>/dev/null)
        if [[ ${#logs[@]} -eq 0 ]]; then
          print_warn "No logs yet"; pause; continue
        fi
        local i=1; declare -A _lmap
        for lf in "${logs[@]}"; do
          echo "  ${i}) $(basename "$lf")"; _lmap[$i]="$lf"; ((i++))
        done
        echo "  0) Cancel"
        read -rp "  Choose: " lch; [[ "$lch" == "0" ]] && continue
        local lf="${_lmap[$lch]}"
        [[ -n "$lf" ]] && less -R "$lf"
        pause ;;
      0) echo -e "\n  ${GREEN}Goodbye!${NC}\n"; exit 0 ;;
      *) print_error "Invalid choice"; sleep 1 ;;
    esac
  done
}

# ── Entry Point ──────────────────────────────────────────────
print_banner
print_step "Checking dependencies on this (source) machine..."
check_local_deps || exit 1
echo ""
main_menu
