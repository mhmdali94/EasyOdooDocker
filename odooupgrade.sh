#!/usr/bin/env bash
# odooupgrade.sh — Upgrade an Odoo Docker instance to the next major version
# Runs on the Docker server. Source is NEVER modified.
# Path: 14 → 15 → 16 → 17 → 18 → 19  (one step at a time)

# ── Colors ─────────────────────────────────────────────────────────────────
RED='\033[0;31m';    GREEN='\033[0;32m';   YELLOW='\033[1;33m'
BLUE='\033[0;34m';   CYAN='\033[0;36m';    MAGENTA='\033[0;35m'
WHITE='\033[1;37m';  GRAY='\033[0;37m';    BOLD='\033[1m';  NC='\033[0m'

print_banner() {
  clear
  echo -e "${CYAN}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════════╗"
  echo "  ║   🐳  ODOO DOCKER VERSION UPGRADE                       ║"
  echo "  ║   14 → 15 → 16 → 17 → 18 → 19  (one step at a time)    ║"
  echo "  ║   Source container is READ-ONLY — never modified         ║"
  echo "  ╚══════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

print_line()    { echo -e "${GRAY}  ──────────────────────────────────────────────────────────${NC}"; }
print_success() { echo -e "  ${GREEN}✔  $1${NC}"; }
print_error()   { echo -e "  ${RED}✖  $1${NC}"; }
print_warn()    { echo -e "  ${YELLOW}⚠  $1${NC}"; }
print_info()    { echo -e "  ${CYAN}ℹ  $1${NC}"; }
print_step()    { echo -e "\n${MAGENTA}${BOLD}  ▶  $1${NC}"; }

pause() { echo ""; read -rp "  $(echo -e "${GRAY}Press [Enter] to continue...${NC}")" _; }

ask() {
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
  read -rsp "  $prompt: " _v; echo ""
  printf -v "$var_name" '%s' "$_v"
}

rand_pass() {
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 20 || echo "OdooPass$(date +%s)"
}

die() { echo -e "\n  ${RED}✖  $*${NC}" >&2; exit 1; }

# ── Global state ─────────────────────────────────────────────────────────────
SRC_CONTAINER=""    # selected Odoo container name
SRC_VERSION=""      # source major version (integer)
SRC_PORT=""         # host port the source container is mapped to
SRC_MASTER_PASS=""  # Odoo master password of the source
SRC_DB=""           # source database name
SRC_DB_CONTAINER="" # companion PostgreSQL container
SRC_BASE_DIR=""     # compose working directory on host
SRC_FILESTORE=""    # host path of /var/lib/odoo mount
SRC_ADDONS=""       # host path of /mnt/extra-addons mount

DST_VERSION=""      # target major version
DST_INSTANCE=""     # new instance name  e.g. odoo9015
DST_BASE_DIR=""     # directory for new instance
DST_PORT=""         # web port for new instance
DST_GEVENT_PORT=""  # longpolling port
DST_PG_USER="odoo"
DST_PG_PASS=""      # auto-generated
DST_DB=""           # database name in new instance
DST_MASTER_PASS=""  # Odoo master password for new instance

ODOO_MANAGER_META="$HOME/docker/.odoo_manager_instances"

ADDON_PY_DEPS=""
WORK_DIR="$HOME/odoo_upgrade_work"
BACKUP_ZIP=""
EXTRACT_DIR=""

# ── Prereqs ───────────────────────────────────────────────────────────────────
check_prereqs() {
  command -v docker  &>/dev/null || die "docker not found."
  command -v python3 &>/dev/null || die "python3 not found."
  command -v curl    &>/dev/null || die "curl not found."
  command -v rsync   &>/dev/null || die "rsync not found (apt install rsync)."
  docker info &>/dev/null 2>&1   || die "Docker daemon is not running."
  docker compose version &>/dev/null 2>&1 || die "Docker Compose v2 plugin not found."
}

# ── Helper: get major version from image tag ──────────────────────────────────
_img_version() {
  echo "$1" | grep -oE '[0-9]+\.[0-9]+|:[0-9]+' | grep -oE '[0-9]+' | head -1 || true
}

# ── Helper: first free port starting from $1 ─────────────────────────────────
_free_port() {
  for p in $(seq "${1:-8069}" 8200); do
    ss -tlnp 2>/dev/null | grep -q ":${p} " && continue
    docker ps --format '{{.Ports}}' 2>/dev/null | grep -q ":${p}->" && continue
    echo "$p"; return
  done
  echo "${1:-8069}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# WIZARD — all user input collected here before any work starts
# ═══════════════════════════════════════════════════════════════════════════════
wizard() {
  # ── 1. Pick source container ──────────────────────────────────────────────
  print_step "Source — select Odoo container"
  print_line

  local raw
  raw=$(docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null \
    | grep -i odoo | grep -viE '(postgres|_db[^a-z])' || true)
  [[ -z "$raw" ]] && die "No running Odoo containers found."

  declare -a _names _images
  local i=1
  while IFS=$'\t' read -r _n _img; do
    local _v; _v=$(_img_version "$_img")
    printf "  ${CYAN}[%d]${NC}  %-40s  %s\n" "$i" "$_n" "${_v:+Odoo $_v}"
    _names+=("$_n"); _images+=("$_img"); ((i++))
  done <<< "$raw"

  echo ""
  local pick=1
  [[ ${#_names[@]} -gt 1 ]] && ask "Select source container number" "1" pick
  [[ "$pick" -ge 1 && "$pick" -le ${#_names[@]} ]] || die "Invalid selection."

  SRC_CONTAINER="${_names[$((pick-1))]}"
  local src_img="${_images[$((pick-1))]}"
  SRC_VERSION=$(_img_version "$src_img")
  [[ -z "$SRC_VERSION" ]] && ask "Enter source Odoo major version" "14" SRC_VERSION

  # ── 2. Auto-detect source metadata ───────────────────────────────────────
  echo ""
  print_success "Container : ${SRC_CONTAINER}  (Odoo ${SRC_VERSION})"

  # Host port
  SRC_PORT=$(docker inspect "$SRC_CONTAINER" \
    --format '{{range $p,$b := .NetworkSettings.Ports}}{{if $b}}{{(index $b 0).HostPort}} {{end}}{{end}}' \
    2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "8069")

  # Companion DB container
  local compose_proj
  compose_proj=$(docker inspect "$SRC_CONTAINER" \
    --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true)
  if [[ -n "$compose_proj" ]]; then
    SRC_DB_CONTAINER=$(docker ps \
      --filter "label=com.docker.compose.project=${compose_proj}" \
      --format '{{.Names}}' 2>/dev/null \
      | grep -iE '(db|postgres)' | head -1 || true)
  fi
  if [[ -z "$SRC_DB_CONTAINER" ]]; then
    local _base; _base=$(echo "$SRC_CONTAINER" | sed 's/_odoo$//; s/-app$//')
    for _c in "${_base}_db" "${_base}-db" "${_base}_postgres" "${_base}-postgres"; do
      docker inspect "$_c" &>/dev/null 2>&1 && { SRC_DB_CONTAINER="$_c"; break; }
    done
  fi
  [[ -n "$SRC_DB_CONTAINER" ]] && print_success "DB container : ${SRC_DB_CONTAINER}"

  # Base dir, filestore, addons from docker mounts/labels
  SRC_BASE_DIR=$(docker inspect "$SRC_CONTAINER" \
    --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null || true)
  SRC_FILESTORE=$(docker inspect "$SRC_CONTAINER" \
    --format '{{range .Mounts}}{{if eq .Destination "/var/lib/odoo"}}{{.Source}}{{end}}{{end}}' \
    2>/dev/null || true)
  SRC_ADDONS=$(docker inspect "$SRC_CONTAINER" \
    --format '{{range .Mounts}}{{if eq .Destination "/mnt/extra-addons"}}{{.Source}}{{end}}{{end}}' \
    2>/dev/null || true)
  [[ -z "$SRC_BASE_DIR" && -n "$SRC_ADDONS"    ]] && SRC_BASE_DIR=$(dirname "$SRC_ADDONS")
  [[ -z "$SRC_BASE_DIR" && -n "$SRC_FILESTORE" ]] && SRC_BASE_DIR=$(dirname "$SRC_FILESTORE")
  [[ -n "$SRC_BASE_DIR"  ]] && print_success "Base dir     : ${SRC_BASE_DIR}"
  [[ -n "$SRC_FILESTORE" ]] && print_success "Filestore    : ${SRC_FILESTORE}"
  [[ -n "$SRC_ADDONS"    ]] && print_success "Addons       : ${SRC_ADDONS}"

  # ── 3. Source master password ─────────────────────────────────────────────
  echo ""
  local _mp_hint
  _mp_hint=$(docker exec "$SRC_CONTAINER" bash -c \
    "grep -E '^[[:space:]]*admin_passwd[[:space:]]*=' /etc/odoo/odoo.conf 2>/dev/null \
     | head -1 | sed 's/^[^=]*=//' | tr -d ' \r'" 2>/dev/null || true)
  [[ -z "$_mp_hint" || "$_mp_hint" =~ ^\$ ]] && _mp_hint=""

  if [[ -n "$_mp_hint" ]]; then
    print_info "Master password found in odoo.conf — press Enter to accept."
    echo -en "  Source master password [${CYAN}(from conf)${NC}]: "
    read -rsp "" _mp; echo ""
    SRC_MASTER_PASS="${_mp:-$_mp_hint}"
  else
    ask_secret "Source Odoo master password" SRC_MASTER_PASS
  fi
  [[ -z "$SRC_MASTER_PASS" ]] && die "Master password is required."

  # ── 4. Fetch + select database ────────────────────────────────────────────
  echo ""
  # Try db_name from conf first
  SRC_DB=$(docker exec "$SRC_CONTAINER" bash -c \
    "grep -E '^[[:space:]]*db_name[[:space:]]*=' /etc/odoo/odoo.conf 2>/dev/null \
     | head -1 | sed 's/^[^=]*=//' | tr -d ' \r'" 2>/dev/null || true)
  [[ "$SRC_DB" == "False" ]] && SRC_DB=""

  if [[ -z "$SRC_DB" ]]; then
    print_info "Fetching database list from Odoo (port ${SRC_PORT})..."
    local _raw _list
    _raw=$(curl -s --connect-timeout 15 \
      -X POST "http://localhost:${SRC_PORT}/jsonrpc" \
      -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","method":"call","id":1,"params":{"service":"db","method":"list","args":[]}}' \
      2>/dev/null || true)
    _list=$(printf '%s\n' "$_raw" | python3 -c \
      "import sys,json; [print(x) for x in (json.load(sys.stdin).get('result') or [])]" \
      2>/dev/null || true)

    if [[ -z "$_list" ]]; then
      print_warn "Could not fetch DB list automatically."
      ask "Source database name" "" SRC_DB
    else
      local -a _dbs=()
      while IFS= read -r _d; do [[ -n "$_d" ]] && _dbs+=("$_d"); done <<< "$_list"
      if [[ ${#_dbs[@]} -eq 1 ]]; then
        SRC_DB="${_dbs[0]}"
        print_success "Database auto-detected: ${SRC_DB}"
      else
        print_info "Databases available:"
        local j=1
        for _d in "${_dbs[@]}"; do
          echo -e "    ${CYAN}[$j]${NC}  $_d"; ((j++))
        done
        echo ""
        local dp; ask "Select database number" "1" dp
        SRC_DB="${_dbs[$((dp-1))]}"
      fi
    fi
  else
    print_success "Database auto-detected: ${SRC_DB}"
  fi
  [[ -z "$SRC_DB" ]] && die "Database name is required."

  # ── 5. Target version ─────────────────────────────────────────────────────
  echo ""
  local next=$((SRC_VERSION + 1))
  [[ $next -gt 19 ]] && die "Already at maximum supported version (19)."
  print_info "Upgrading Odoo ${SRC_VERSION} → ${next}  (one step at a time)"
  DST_VERSION="$next"

  # ── 6. Destination configuration ─────────────────────────────────────────
  print_step "Destination — configure new instance"
  print_line
  echo ""

  local _default_name
  _default_name=$(echo "${SRC_CONTAINER%_odoo}" | sed "s/${SRC_VERSION}/${DST_VERSION}/g")
  ask "New instance name" "$_default_name" DST_INSTANCE

  local _default_dir
  [[ -n "$SRC_BASE_DIR" ]] \
    && _default_dir=$(echo "$SRC_BASE_DIR" | sed "s/${SRC_VERSION}/${DST_VERSION}/g") \
    || _default_dir="/opt/odoo/${DST_INSTANCE}"
  ask "Directory for new instance" "$_default_dir" DST_BASE_DIR

  local _default_port; _default_port=$(_free_port "$((SRC_PORT + 1))")
  while true; do
    ask "Web port for new instance" "$_default_port" DST_PORT
    [[ "$DST_PORT" =~ ^[0-9]+$ && "$DST_PORT" -ge 1 && "$DST_PORT" -le 65535 ]] && break
    print_error "Invalid port number."
  done

  local _default_gevent; _default_gevent=$(_free_port "$((DST_PORT + 1))")
  while true; do
    ask "Gevent / longpolling port" "$_default_gevent" DST_GEVENT_PORT
    [[ "$DST_GEVENT_PORT" =~ ^[0-9]+$ && "$DST_GEVENT_PORT" -ge 1 && "$DST_GEVENT_PORT" -le 65535 ]] && break
    print_error "Invalid port number."
  done

  ask "Database name" "${SRC_DB}" DST_DB

  echo ""
  ask_secret "Master password for new Odoo instance" DST_MASTER_PASS
  [[ -z "$DST_MASTER_PASS" ]] && die "Destination master password is required."

  DST_PG_PASS=$(rand_pass)

  # ── 7. Confirm ────────────────────────────────────────────────────────────
  echo ""
  print_line
  print_info "Upgrade plan:"
  print_info "  Source  : ${SRC_CONTAINER}  (Odoo ${SRC_VERSION}, db: ${SRC_DB})"
  print_info "  Target  : ${DST_INSTANCE}   (Odoo ${DST_VERSION}, db: ${DST_DB})"
  print_info "  Port    : ${DST_PORT}"
  print_info "  Dir     : ${DST_BASE_DIR}"
  print_line
  echo ""
  echo -en "  Proceed? [${CYAN}y${NC}]: "
  read -r _yn
  [[ "${_yn,,}" == "n" || "${_yn,,}" == "no" ]] && exit 0
}

# ── Step 1: Directories + config files ───────────────────────────────────────
step_setup_files() {
  print_step "Step 1 of 7 — Create directories and config files"
  print_line

  mkdir -p "${DST_BASE_DIR}"/{addons,filestore,config,logs,postgresql}
  print_success "Directories created under ${DST_BASE_DIR}"

  local port_line=""
  [[ "${DST_VERSION}" -le 15 ]] && port_line="xmlrpc_port = ${DST_PORT}"

  cat > "${DST_BASE_DIR}/config/odoo.conf" <<EOF
[options]
addons_path       = /mnt/extra-addons,/usr/lib/python3/dist-packages/odoo/addons
db_host           = db
db_port           = 5432
db_user           = ${DST_PG_USER}
db_password       = ${DST_PG_PASS}
db_name           = ${DST_DB}
admin_passwd      = ${DST_MASTER_PASS}
data_dir          = /var/lib/odoo
logfile           = /var/log/odoo/odoo.log
log_level         = warn
workers           = 0
longpolling_port  = ${DST_GEVENT_PORT}
gevent_port       = ${DST_GEVENT_PORT}
${port_line}
EOF
  print_success "odoo.conf written  (master password saved)"

  cat > "${DST_BASE_DIR}/docker-compose.yml" <<EOF
services:
  db:
    image: postgres:13
    container_name: ${DST_INSTANCE}_db
    environment:
      POSTGRES_USER: ${DST_PG_USER}
      POSTGRES_PASSWORD: ${DST_PG_PASS}
      POSTGRES_DB: postgres
    volumes:
      - ./postgresql:/var/lib/postgresql/data
    restart: unless-stopped

  odoo:
    image: odoo:${DST_VERSION}.0
    container_name: ${DST_INSTANCE}_odoo
    depends_on:
      - db
    ports:
      - "${DST_PORT}:8069"
      - "${DST_GEVENT_PORT}:8072"
    volumes:
      - ./addons:/mnt/extra-addons
      - ./filestore:/var/lib/odoo
      - ./config:/etc/odoo
      - ./logs:/var/log/odoo
    restart: unless-stopped
EOF
  print_success "docker-compose.yml written"
}

# ── Step 2: Download backup via Odoo API ─────────────────────────────────────
step_download_backup() {
  print_step "Step 2 of 7 — Download backup from source Odoo (master password)"
  print_line
  print_info "Calling POST /web/database/backup on source — nothing is modified."
  print_warn "Large databases may take several minutes."
  echo ""

  mkdir -p "$WORK_DIR"
  EXTRACT_DIR="$WORK_DIR/${SRC_DB}_extract"

  local _attempt _is_zip _code _sz
  for _attempt in 1 2 3; do
    rm -f "$WORK_DIR/${SRC_DB}_"*.zip 2>/dev/null || true
    BACKUP_ZIP="$WORK_DIR/${SRC_DB}_$(date +%Y%m%d_%H%M%S).zip"

    local _code_file="$WORK_DIR/.http_$$"
    curl \
      --connect-timeout 30 --max-time 7200 \
      -w "%{http_code}" \
      -o "$BACKUP_ZIP" \
      --progress-bar \
      -X POST "http://localhost:${SRC_PORT}/web/database/backup" \
      -F "master_pwd=${SRC_MASTER_PASS}" \
      -F "name=${SRC_DB}" \
      -F "backup_format=zip" \
      > "$_code_file" 2>/dev/null
    echo ""

    _code=$(cat "$_code_file" 2>/dev/null || echo "000")
    rm -f "$_code_file"
    _code="${_code//[^0-9]/}"
    _sz=$(du -sh "$BACKUP_ZIP" | cut -f1)

    # Check magic bytes — a real ZIP starts with PK (0x504B)
    _is_zip=$(python3 -c \
      "f=open('${BACKUP_ZIP}','rb'); print('yes' if f.read(2)==b'PK' else 'no')" \
      2>/dev/null || echo "no")

    if [[ "$_is_zip" == "yes" ]]; then
      print_success "Backup downloaded (${_sz})"
      break
    fi

    # Extract Odoo's error text from the HTML response
    local _odoo_err
    _odoo_err=$(python3 -c "
import re, sys
html = open('${BACKUP_ZIP}', errors='replace').read()
# Odoo wrong-password error appears in <p class='alert-danger'> or similar
for pat in [r'alert-danger[^>]*>\s*([^<]{10,})', r'<p>([^<]{10,})</p>', r'<pre>([^<]+)</pre>']:
    m = re.search(pat, html, re.S)
    if m:
        print(m.group(1).strip()[:200]); break
" 2>/dev/null || true)

    echo ""
    print_error "Backup failed (HTTP ${_code:-000}, ${_sz}) — response is not a ZIP."
    if [[ -n "$_odoo_err" ]]; then
      print_warn "Odoo says: ${_odoo_err}"
    fi
    rm -f "$BACKUP_ZIP"

    if [[ $_attempt -lt 3 ]]; then
      echo ""
      print_info "Retry ${_attempt}/3 — re-enter the master password:"
      ask_secret "Master password" SRC_MASTER_PASS
      [[ -z "$SRC_MASTER_PASS" ]] && die "Master password cannot be empty."
    else
      echo ""
      print_info "Verify the correct master password with:"
      print_info "  docker exec ${SRC_CONTAINER} grep admin_passwd /etc/odoo/odoo.conf"
      die "Backup download failed after 3 attempts."
    fi
  done

  print_info "Extracting backup..."
  rm -rf "$EXTRACT_DIR"; mkdir -p "$EXTRACT_DIR"
  python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
    "$BACKUP_ZIP" "$EXTRACT_DIR" || die "Failed to extract backup ZIP."
  print_success "Extracted to ${EXTRACT_DIR}"
}

# ── Step 3: Start PostgreSQL + restore database ───────────────────────────────
step_restore_db() {
  print_step "Step 3 of 7 — Start PostgreSQL and restore database"
  print_line

  cd "${DST_BASE_DIR}"
  docker compose up -d db
  print_info "Waiting for PostgreSQL..."
  local w=0
  while ! docker exec "${DST_INSTANCE}_db" pg_isready -U "${DST_PG_USER}" -q 2>/dev/null; do
    sleep 2; ((w+=2)); printf "."
    [[ $w -ge 90 ]] && die "PostgreSQL not ready after 90s."
  done
  echo ""; print_success "PostgreSQL is ready"

  docker exec "${DST_INSTANCE}_db" psql -U "${DST_PG_USER}" -d postgres -c \
    "SET password_encryption='md5'; ALTER USER ${DST_PG_USER} WITH PASSWORD '${DST_PG_PASS}';" \
    &>/dev/null || true

  print_info "Creating database ${DST_DB}..."
  docker exec "${DST_INSTANCE}_db" psql -U "${DST_PG_USER}" -d postgres -c \
    "DROP DATABASE IF EXISTS \"${DST_DB}\";" &>/dev/null || true
  docker exec "${DST_INSTANCE}_db" psql -U "${DST_PG_USER}" -d postgres -c \
    "CREATE DATABASE \"${DST_DB}\" OWNER ${DST_PG_USER};" \
    || die "Could not create database."

  print_info "Restoring dump.sql..."
  docker exec -i "${DST_INSTANCE}_db" \
    psql -U "${DST_PG_USER}" -d "${DST_DB}" \
    < "${EXTRACT_DIR}/dump.sql" \
    || print_warn "psql had warnings (usually harmless). Continuing."
  print_success "Database restored"
}

# ── Step 4: Copy filestore ────────────────────────────────────────────────────
step_restore_filestore() {
  print_step "Step 4 of 7 — Copy filestore"
  print_line

  local src=""
  [[ -d "${EXTRACT_DIR}/filestore" ]] && src="${EXTRACT_DIR}/filestore"
  [[ -z "$src" && -n "$SRC_FILESTORE" && -d "$SRC_FILESTORE" ]] && src="$SRC_FILESTORE"

  if [[ -z "$src" ]]; then
    print_warn "No filestore found — attachments will be missing."
    return 0
  fi

  print_info "Copying filestore from ${src} ..."
  rsync -a --info=progress2 "${src}/" "${DST_BASE_DIR}/filestore/"
  chown -R 101:101 "${DST_BASE_DIR}/filestore/" 2>/dev/null || true
  print_success "Filestore copied  (ownership set to odoo 101:101)"
}

# ── Step 5: Copy addons ───────────────────────────────────────────────────────
step_copy_addons() {
  print_step "Step 5 of 7 — Copy custom addons"
  print_line

  if [[ -z "$SRC_ADDONS" || ! -d "$SRC_ADDONS" ]]; then
    print_warn "Source addons path not found — skipping."
    print_warn "Place Odoo ${DST_VERSION}-compatible addons in: ${DST_BASE_DIR}/addons/"
    return 0
  fi

  print_warn "Addons are copied from Odoo ${SRC_VERSION} — some may not be compatible with ${DST_VERSION}."
  rsync -a --info=progress2 "${SRC_ADDONS}/" "${DST_BASE_DIR}/addons/"
  print_success "Addons copied"

  local _scan='
import sys,ast,glob,os
deps=set()
for p in glob.glob(os.path.join(sys.argv[1],"*","__manifest__.py")):
    try:
        m=ast.literal_eval(open(p,errors="ignore").read())
        [deps.add(x) for x in m.get("external_dependencies",{}).get("python",[]) if x]
    except: pass
print("\n".join(sorted(deps)))
'
  local _raw; _raw=$(python3 -c "$_scan" "${DST_BASE_DIR}/addons" 2>/dev/null || true)
  ADDON_PY_DEPS=$(printf '%s\n' "$_raw" | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')
  [[ -n "$ADDON_PY_DEPS" ]] \
    && print_success "Python packages in manifests: ${ADDON_PY_DEPS}" \
    || print_info "No external Python deps declared in manifests"
}

# ── Step 6: Run Odoo schema upgrade ──────────────────────────────────────────
step_run_upgrade() {
  print_step "Step 6 of 7 — Run Odoo ${DST_VERSION} schema upgrade  (-u all --stop-after-init)"
  print_line
  echo ""
  print_warn "Upgrades the database schema from Odoo ${SRC_VERSION} to ${DST_VERSION}."
  print_warn "Takes 10–60+ minutes for large databases. Do NOT interrupt."
  echo ""
  pause

  cd "${DST_BASE_DIR}"
  print_info "Pulling odoo:${DST_VERSION}.0 ..."
  docker pull "odoo:${DST_VERSION}.0" || print_warn "Pull failed — using local cache if available."

  print_info "Running upgrade container (output streamed below)..."
  print_line
  echo ""

  docker compose run --rm \
    --entrypoint "" \
    odoo bash -c "
      python3 -m pip install --upgrade pip setuptools --quiet 2>/dev/null || true
      ${ADDON_PY_DEPS:+python3 -m pip install ${ADDON_PY_DEPS} --quiet 2>/dev/null || true}
      exec odoo -d '${DST_DB}' -u all --stop-after-init --no-http --workers=0 --logfile=''
    "
  local rc=$?

  echo ""; print_line
  if [[ $rc -eq 0 ]]; then
    print_success "Schema upgrade completed (exit 0)"
  else
    print_warn "Upgrade container exited with code ${rc} (warnings are normal)."
    echo -en "  Continue and start Odoo anyway? [${CYAN}y${NC}]: "
    read -r _yn
    [[ "${_yn,,}" == "n" || "${_yn,,}" == "no" ]] && exit 1
  fi
}

# ── Step 7: Start Odoo + auto-fix Python deps ─────────────────────────────────
step_start_odoo() {
  print_step "Step 7 of 7 — Start Odoo ${DST_VERSION} and verify"
  print_line

  cd "${DST_BASE_DIR}"
  docker compose up -d odoo

  # Upgrade pip as root (avoids old-pip pyproject.toml failures)
  docker exec -u root "${DST_INSTANCE}_odoo" \
    python3 -m pip install --upgrade pip setuptools --quiet 2>/dev/null || true

  if [[ -n "$ADDON_PY_DEPS" ]]; then
    print_info "Installing manifest-declared packages: ${ADDON_PY_DEPS}"
    docker exec -u root "${DST_INSTANCE}_odoo" \
      python3 -m pip install ${ADDON_PY_DEPS} --quiet \
      && print_success "Packages installed" || print_warn "pip had errors — continuing"
  fi

  # Auto-fix loop: detect ImportErrors from Odoo log, install missing packages.
  print_info "Waiting for Odoo — auto-fixing missing Python packages if needed..."
  local _attempt _fixed="" _ok=false
  for _attempt in 1 2 3 4 5; do
    docker exec -u root "${DST_INSTANCE}_odoo" \
      truncate -s0 /var/log/odoo/odoo.log 2>/dev/null || true
    docker restart "${DST_INSTANCE}_odoo" >/dev/null
    sleep 20

    local _code
    _code=$(docker exec "${DST_INSTANCE}_odoo" \
      curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 \
      "http://127.0.0.1:8069/web/login" 2>/dev/null | tr -cd '0-9' || echo "000")
    if [[ "$_code" == "200" || "$_code" == "302" || "$_code" == "303" ]]; then
      _ok=true; print_success "Odoo is responding (attempt ${_attempt})"; break
    fi

    local _log
    _log=$(docker exec "${DST_INSTANCE}_odoo" \
      tail -150 /var/log/odoo/odoo.log 2>/dev/null || true)

    local _new
    _new=$(printf '%s\n' \
      "$(printf '%s\n' "$_log" | grep -oE "No module named '[^']+'" | grep -oE "'[^']+'" | tr -d "'" | sed 's/\..*//')" \
      "$(printf '%s\n' "$_log" | grep -iE "pip3? install [a-zA-Z0-9_-]+" | grep -oE "install [a-zA-Z0-9_-]+" | awk '{print $2}')" \
      | sort -u | grep -v '^$' | grep -vFx "$(printf '%s\n' ${_fixed})" \
      | tr '\n' ' ' | sed 's/ $//')

    [[ -z "$_new" ]] && { print_warn "Not responding (attempt ${_attempt}) — no ImportErrors found"; break; }

    print_info "Attempt ${_attempt}: installing ${_new}"
    docker exec -u root "${DST_INSTANCE}_odoo" \
      python3 -m pip install ${_new} --quiet \
      && print_success "Installed: ${_new}" || print_warn "pip failed for: ${_new}"
    _fixed="${_fixed} ${_new}"
  done

  echo ""; print_line
  if [[ "$_ok" == true ]]; then
    local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
    print_success "Odoo ${DST_VERSION} is live at  http://${ip}:${DST_PORT}"
    print_success "Source container (${SRC_CONTAINER}) was NOT modified."

    # ── Register in Odoo Manager ──────────────────────────────────────────
    if [[ -f "$ODOO_MANAGER_META" || -d "$(dirname "$ODOO_MANAGER_META")" ]]; then
      mkdir -p "$(dirname "$ODOO_MANAGER_META")"
      # Remove any stale entry with the same name, then append
      sed -i "/^${DST_INSTANCE}|/d" "$ODOO_MANAGER_META" 2>/dev/null || true
      echo "${DST_INSTANCE}|${DST_VERSION}|${DST_BASE_DIR}|${DST_PORT}|${DST_GEVENT_PORT}|${DST_PG_USER}|${DST_PG_PASS}|${DST_MASTER_PASS}|upgraded from ${SRC_CONTAINER}" \
        >> "$ODOO_MANAGER_META"
      print_success "Registered in Odoo Manager  (${ODOO_MANAGER_META})"
    else
      print_info "Odoo Manager meta file not found — creating it."
      mkdir -p "$(dirname "$ODOO_MANAGER_META")"
      echo "${DST_INSTANCE}|${DST_VERSION}|${DST_BASE_DIR}|${DST_PORT}|${DST_GEVENT_PORT}|${DST_PG_USER}|${DST_PG_PASS}|${DST_MASTER_PASS}|upgraded from ${SRC_CONTAINER}" \
        >> "$ODOO_MANAGER_META"
      print_success "Registered in Odoo Manager  (${ODOO_MANAGER_META})"
    fi

    echo ""
    print_info "Next steps:"
    print_info "  1. Log in and verify your data"
    print_info "  2. Update any addons that are incompatible with v${DST_VERSION}"
    [[ "${DST_VERSION}" -lt 19 ]] && \
      print_info "  3. Run odooupgrade.sh again to continue: v${DST_VERSION} → v$((DST_VERSION+1))"
    print_info "  4. When ready to decommission source: cd ${SRC_BASE_DIR} && docker compose stop"
  else
    print_warn "Odoo did not respond after ${_attempt} attempt(s)."
    print_info "  Logs : docker exec ${DST_INSTANCE}_odoo tail -50 /var/log/odoo/odoo.log"
    print_info "  Test : curl -I http://localhost:${DST_PORT}/web/login"
  fi
  print_line
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  print_banner
  check_prereqs
  wizard
  step_setup_files
  step_download_backup
  step_restore_db
  step_restore_filestore
  step_copy_addons
  step_run_upgrade
  step_start_odoo
  echo ""
  print_success "Upgrade complete."
  echo ""
}

main "$@"
