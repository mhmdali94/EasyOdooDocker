#!/bin/bash
# ============================================================
#   ODOO DOCKER MANAGER - Interactive Management Script
#   Supports: Odoo 16, 17, 18, 19 | Multi-instance | Auto-fix
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

# ── Config ───────────────────────────────────────────────────
BASE_DIR="$HOME/docker"
META_FILE="$BASE_DIR/.odoo_manager_instances"

# Ports permanently reserved (Nginx Proxy Manager + system)
# 80=HTTP, 81=NPM UI, 443=HTTPS — DO NOT TOUCH
RESERVED_PORTS=(22 80 81 443 3306 5432 8080 8888)

# Odoo default admin credentials (user sets on first login if master pw)
DEFAULT_ADMIN_USER="admin"
DEFAULT_ADMIN_PASS="admin"

# ── Helpers ──────────────────────────────────────────────────
print_banner() {
  clear
  echo -e "${CYAN}${BOLD}"
  echo "  ╔═══════════════════════════════════════════════════════╗"
  echo "  ║          🐘  ODOO DOCKER MANAGER  🐘                  ║"
  echo "  ║     Multi-Instance | Auto-Fix | Smart Port Assign     ║"
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
  local msg="$1"
  echo -e "\n  ${YELLOW}${msg}${NC}"
  read -rp "  Type 'yes' to confirm: " ans
  [[ "$ans" == "yes" ]]
}

# ── Dependency Check ─────────────────────────────────────────
install_docker() {
  echo ""
  print_warn "Docker is not installed on this system."
  echo -e "  ${CYAN}Auto-install Docker now? (requires sudo)${NC}"
  read -rp "  [Y/n]: " ans
  [[ "$ans" =~ ^[Nn]$ ]] && { print_error "Docker is required. Exiting."; exit 1; }

  echo ""
  print_step "Detecting OS..."

  local os_id
  os_id=$(grep -oP '^ID=\K.*' /etc/os-release 2>/dev/null | tr -d '"')

  print_step "Installing Docker on: ${os_id}"
  echo ""

  case "$os_id" in
    ubuntu|debian|linuxmint|pop)
      print_step "Removing old Docker versions..."
      sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null
      print_step "Installing dependencies..."
      sudo apt-get update -qq
      sudo apt-get install -y ca-certificates curl gnupg lsb-release
      print_step "Adding Docker GPG key..."
      sudo install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/${os_id}/gpg \
        | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      sudo chmod a+r /etc/apt/keyrings/docker.gpg
      print_step "Adding Docker repository..."
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${os_id} $(lsb_release -cs) stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
      print_step "Installing Docker Engine + Compose plugin..."
      sudo apt-get update -qq
      sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
      ;;
    centos|rhel|fedora|rocky|almalinux)
      print_step "Installing Docker via yum/dnf..."
      sudo yum remove -y docker docker-client docker-client-latest \
        docker-common docker-latest docker-logrotate docker-engine 2>/dev/null
      sudo yum install -y yum-utils
      sudo yum-config-manager --add-repo \
        https://download.docker.com/linux/centos/docker-ce.repo
      sudo yum install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
      ;;
    *)
      print_warn "Unknown OS '${os_id}' — trying generic install script..."
      curl -fsSL https://get.docker.com | sudo sh
      ;;
  esac

  # Start and enable Docker
  print_step "Starting Docker service..."
  sudo systemctl enable docker
  sudo systemctl start docker

  # Add current user to docker group so no sudo needed
  print_step "Adding ${USER} to docker group..."
  sudo usermod -aG docker "$USER"

  # Verify
  if docker --version &>/dev/null; then
    print_success "Docker installed successfully: $(docker --version)"
    print_warn "NOTE: Log out and back in (or run: newgrp docker) for group changes to take effect"
    echo ""
    read -rp "  $(echo -e "${CYAN}Run with sudo for now and continue? [Y/n]: ${NC}")" cont
    [[ "$cont" =~ ^[Nn]$ ]] && exit 0
    # Re-run docker commands with sudo for this session if needed
    DOCKER_CMD="sudo docker"
  else
    print_error "Docker installation failed. Please install manually: https://docs.docker.com/engine/install/"
    exit 1
  fi
}

check_deps() {
  # ── Docker ──────────────────────────────────────────────────
  if ! command -v docker &>/dev/null; then
    install_docker
  else
    print_success "Docker found: $(docker --version 2>/dev/null | cut -d',' -f1)"
  fi

  # ── Docker Compose ───────────────────────────────────────────
  if ! docker compose version &>/dev/null && ! command -v docker-compose &>/dev/null; then
    print_warn "Docker Compose plugin not found — installing..."
    sudo apt-get install -y docker-compose-plugin 2>/dev/null \
      || sudo apt-get install -y docker-compose 2>/dev/null \
      || { print_error "Could not install docker-compose. Install manually."; exit 1; }
    print_success "Docker Compose installed"
  else
    print_success "Docker Compose found"
  fi

  # ── curl ─────────────────────────────────────────────────────
  if ! command -v curl &>/dev/null; then
    print_warn "curl not found — installing..."
    sudo apt-get install -y curl 2>/dev/null \
      || sudo yum install -y curl 2>/dev/null \
      || print_warn "Could not install curl — IP detection may fall back to local"
  fi

  mkdir -p "$BASE_DIR"
  touch "$META_FILE"
  return 0
}

# ── Docker Compose Command ───────────────────────────────────
dc() {
  if docker compose version &>/dev/null; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi
}

# ── Port Management ──────────────────────────────────────────
is_port_reserved() {
  local port=$1
  for r in "${RESERVED_PORTS[@]}"; do [[ "$r" == "$port" ]] && return 0; done
  return 1
}

is_port_used() {
  local port=$1
  # Check system listener
  ss -tlnp 2>/dev/null | grep -q ":${port} " && return 0
  # Check in metadata
  grep -q "web_port=${port}\|gevent_port=${port}" "$META_FILE" 2>/dev/null && return 0
  return 1
}

next_free_port() {
  local start=${1:-8069}
  local p=$start
  while true; do
    if ! is_port_reserved "$p" && ! is_port_used "$p"; then
      echo "$p"; return
    fi
    ((p++))
  done
}

# ── Metadata ─────────────────────────────────────────────────
# Format: name|version|dir|web_port|gevent_port|pg_user|pg_pass|master_pass|status
save_instance() {
  # Remove existing entry for this name
  local name=$1
  sed -i "/^${name}|/d" "$META_FILE" 2>/dev/null
  echo "$1|$2|$3|$4|$5|$6|$7|$8|$9" >> "$META_FILE"
}

get_instance_field() {
  local name=$1 field=$2
  local line; line=$(grep "^${name}|" "$META_FILE" 2>/dev/null | head -1)
  [[ -z "$line" ]] && return 1
  IFS='|' read -ra parts <<< "$line"
  case $field in
    name)        echo "${parts[0]}" ;;
    version)     echo "${parts[1]}" ;;
    dir)         echo "${parts[2]}" ;;
    web_port)    echo "${parts[3]}" ;;
    gevent_port) echo "${parts[4]}" ;;
    pg_user)     echo "${parts[5]}" ;;
    pg_pass)     echo "${parts[6]}" ;;
    master_pass) echo "${parts[7]}" ;;
    notes)       echo "${parts[8]}" ;;
  esac
}

list_instance_names() {
  awk -F'|' '{print $1}' "$META_FILE" 2>/dev/null | grep -v '^$'
}

instance_exists() {
  grep -q "^${1}|" "$META_FILE" 2>/dev/null
}

remove_instance_meta() {
  sed -i "/^${1}|/d" "$META_FILE" 2>/dev/null
}

# ── VPS IP Detection ─────────────────────────────────────────
get_vps_ip() {
  local ip
  # Try curl with forced IPv4
  ip=$(curl -4 -s --max-time 3 https://api.ipify.org 2>/dev/null)
  # Validate it looks like an IPv4 (x.x.x.x)
  if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ip=$(curl -4 -s --max-time 3 https://ifconfig.me 2>/dev/null)
  fi
  if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    # Extract IPv4 from ip route — most reliable on VPS
    ip=$(ip -4 route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[\d.]+')
  fi
  if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    # hostname -I can return multiple IPs; pick the first pure IPv4
    ip=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
  fi
  echo "${ip:-localhost}"
}

# ── odoo.conf Generator ──────────────────────────────────────
generate_odoo_conf() {
  local dir=$1 pg_user=$2 pg_pass=$3 master_pass=$4 gevent_port=$5

  mkdir -p "$dir/config"
  cat > "$dir/config/odoo.conf" <<EOF
[options]
; ── Database ────────────────────────────────────────────────
db_host = db
db_port = 5432
db_user = ${pg_user}
db_password = ${pg_pass}
db_name = False

; ── Admin ───────────────────────────────────────────────────
admin_passwd = ${master_pass}

; ── Addons ──────────────────────────────────────────────────
; This path MUST match the volume mount in docker-compose.yml
addons_path = /mnt/extra-addons,/usr/lib/python3/dist-packages/odoo/addons

; ── Performance ─────────────────────────────────────────────
workers = 2
max_cron_threads = 1
limit_memory_hard = 2684354560
limit_memory_soft = 2147483648
limit_request = 8192
limit_time_cpu = 120
limit_time_real = 240

; ── Logging ─────────────────────────────────────────────────
log_level = info
logfile = /var/log/odoo/odoo.log

; ── Longpolling / Livechat ──────────────────────────────────
longpolling_port = ${gevent_port}
gevent_port = ${gevent_port}

; ── Security ────────────────────────────────────────────────
list_db = True
proxy_mode = True
EOF
  print_success "Generated odoo.conf with correct addons_path"
}

# ── docker-compose.yml Generator ────────────────────────────
generate_compose() {
  local dir=$1 name=$2 version=$3
  local web_port=$4 gevent_port=$5
  local pg_user=$6 pg_pass=$7

  mkdir -p "$dir/addons" "$dir/config" "$dir/logs"

  cat > "$dir/docker-compose.yml" <<EOF
# Auto-generated by Odoo Docker Manager
# Instance: ${name} | Odoo ${version}
services:
  db:
    image: postgres:15
    container_name: ${name}-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: postgres
      POSTGRES_USER: ${pg_user}
      POSTGRES_PASSWORD: ${pg_pass}
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - db_data:/var/lib/postgresql/data
    networks:
      - ${name}_net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${pg_user} -d postgres"]
      interval: 10s
      timeout: 5s
      retries: 10

  odoo:
    image: odoo:${version}
    container_name: ${name}-app
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "${web_port}:8069"
      - "${gevent_port}:8072"
    environment:
      HOST: db
      PORT: 5432
      USER: ${pg_user}
      PASSWORD: ${pg_pass}
    volumes:
      - web_data:/var/lib/odoo
      - ./addons:/mnt/extra-addons
      - ./config/odoo.conf:/etc/odoo/odoo.conf:ro
      - ./logs:/var/log/odoo
    networks:
      - ${name}_net

networks:
  ${name}_net:
    driver: bridge

volumes:
  db_data:
  web_data:
EOF
  print_success "Generated docker-compose.yml"
}

# ── Summary Box ──────────────────────────────────────────────
show_summary() {
  local name=$1
  instance_exists "$name" || { print_error "Instance '$name' not found"; return 1; }

  local version web_port gevent_port pg_user pg_pass master_pass dir
  version=$(get_instance_field "$name" version)
  web_port=$(get_instance_field "$name" web_port)
  gevent_port=$(get_instance_field "$name" gevent_port)
  pg_user=$(get_instance_field "$name" pg_user)
  pg_pass=$(get_instance_field "$name" pg_pass)
  master_pass=$(get_instance_field "$name" master_pass)
  dir=$(get_instance_field "$name" dir)

  local vps_ip; vps_ip=$(get_vps_ip)

  # Container status
  local app_status db_status
  app_status=$(docker inspect --format='{{.State.Status}}' "${name}-app" 2>/dev/null || echo "not found")
  db_status=$(docker inspect --format='{{.State.Status}}' "${name}-db" 2>/dev/null || echo "not found")

  local status_color="${RED}"
  [[ "$app_status" == "running" ]] && status_color="${GREEN}"

  echo ""
  echo -e "${CYAN}${BOLD}  ╔══════════════════════════════════════════════════════════╗"
  echo -e "  ║  📦  INSTANCE SUMMARY: ${WHITE}${name}${CYAN}$(printf '%*s' $((32 - ${#name})) '')║"
  echo -e "  ╠══════════════════════════════════════════════════════════╣"
  printf "  ${CYAN}║  %-20s ${WHITE}%-35s${CYAN}║\n" "Odoo Version:"    "Odoo ${version}"
  printf "  ${CYAN}║  %-20s ${status_color}%-35s${CYAN}║\n" "App Status:"  "$app_status"
  printf "  ${CYAN}║  %-20s ${status_color}%-35s${CYAN}║\n" "DB Status:"   "$db_status"
  echo -e "  ${CYAN}╠══════════════════════════════════════════════════════════╣"
  printf "  ${CYAN}║  %-20s ${GREEN}%-35s${CYAN}║\n" "🌐 Web URL:"       "http://${vps_ip}:${web_port}"
  printf "  ${CYAN}║  %-20s ${GRAY}%-35s${CYAN}║\n" "Longpoll Port:"    "${gevent_port}"
  echo -e "  ${CYAN}╠══════════════════════════════════════════════════════════╣"
  printf "  ${CYAN}║  %-20s ${YELLOW}%-35s${CYAN}║\n" "👤 Login URL:"     "http://${vps_ip}:${web_port}/web/login"
  printf "  ${CYAN}║  %-20s ${YELLOW}%-35s${CYAN}║\n" "Username:"         "${DEFAULT_ADMIN_USER}"
  printf "  ${CYAN}║  %-20s ${YELLOW}%-35s${CYAN}║\n" "Password:"         "${DEFAULT_ADMIN_PASS}"
  printf "  ${CYAN}║  %-20s ${YELLOW}%-35s${CYAN}║\n" "Master Password:"  "${master_pass}"
  echo -e "  ${CYAN}╠══════════════════════════════════════════════════════════╣"
  printf "  ${CYAN}║  %-20s ${GRAY}%-35s${CYAN}║\n" "DB User:"          "${pg_user}"
  printf "  ${CYAN}║  %-20s ${GRAY}%-35s${CYAN}║\n" "DB Password:"      "${pg_pass}"
  echo -e "  ${CYAN}╠══════════════════════════════════════════════════════════╣"
  printf "  ${CYAN}║  %-20s ${WHITE}%-35s${CYAN}║\n" "📁 Instance Dir:"  "${dir}"
  printf "  ${CYAN}║  %-20s ${GRAY}%-35s${CYAN}║\n" "   addons:"        "${dir}/addons"
  printf "  ${CYAN}║  %-20s ${GRAY}%-35s${CYAN}║\n" "   odoo.conf:"     "${dir}/config/odoo.conf"
  printf "  ${CYAN}║  %-20s ${GRAY}%-35s${CYAN}║\n" "   logs:"          "${dir}/logs"
  echo -e "  ${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

# ── Container Status Check ───────────────────────────────────
is_running() {
  [[ "$(docker inspect --format='{{.State.Status}}' "${1}-app" 2>/dev/null)" == "running" ]]
}

# ── CREATE Instance ──────────────────────────────────────────
create_instance() {
  print_banner
  echo -e "  ${WHITE}${BOLD}➕  CREATE NEW ODOO INSTANCE${NC}"
  print_line
  echo ""

  # ── Name ──
  while true; do
    read -rp "  Instance name (e.g. odoo1, testing17): " name
    [[ -z "$name" ]] && { print_error "Name cannot be empty"; continue; }
    [[ ! "$name" =~ ^[a-z0-9_-]+$ ]] && { print_error "Use only: a-z 0-9 _ -"; continue; }
    instance_exists "$name" && { print_error "Instance '$name' already exists"; continue; }
    break
  done

  # ── Version ──
  echo ""
  echo -e "  ${CYAN}Select Odoo version:${NC}"
  echo "  1) Odoo 19.0"
  echo "  2) Odoo 18.0"
  echo "  3) Odoo 17.0"
  echo "  4) Odoo 16.0"
  echo "  5) Custom version"
  read -rp "  Choice [1-5]: " vchoice
  case $vchoice in
    1) version="19.0" ;;
    2) version="18.0" ;;
    3) version="17.0" ;;
    4) version="16.0" ;;
    5) read -rp "  Enter version (e.g. 15.0): " version ;;
    *) version="18.0" ;;
  esac

  # ── Ports ──
  echo ""
  local suggested_web; suggested_web=$(next_free_port 8069)
  local suggested_gevent; suggested_gevent=$(next_free_port $((suggested_web + 3)))
  # Make sure gevent != web
  [[ "$suggested_gevent" == "$suggested_web" ]] && suggested_gevent=$(next_free_port $((suggested_web + 1)))

  read -rp "  Web port [${suggested_web}]: " web_port
  web_port=${web_port:-$suggested_web}
  # Validate
  if is_port_reserved "$web_port" || is_port_used "$web_port"; then
    print_warn "Port $web_port is taken! Auto-assigning..."
    web_port=$(next_free_port "$web_port")
    print_info "Using port: $web_port"
  fi

  read -rp "  Gevent/Longpoll port [${suggested_gevent}]: " gevent_port
  gevent_port=${gevent_port:-$suggested_gevent}
  if is_port_reserved "$gevent_port" || is_port_used "$gevent_port" || [[ "$gevent_port" == "$web_port" ]]; then
    print_warn "Port $gevent_port is taken! Auto-assigning..."
    gevent_port=$(next_free_port $((web_port + 1)))
    print_info "Using gevent port: $gevent_port"
  fi

  # ── DB Credentials ──
  echo ""
  local default_pg_user="${name}_user"
  local default_pg_pass=$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 16 || echo "odoopass123")
  local default_master=$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 12 || echo "master123")

  read -rp "  PostgreSQL user [${default_pg_user}]: " pg_user
  pg_user=${pg_user:-$default_pg_user}

  read -rp "  PostgreSQL password [auto-generated]: " pg_pass
  pg_pass=${pg_pass:-$default_pg_pass}

  read -rp "  Odoo master password [auto-generated]: " master_pass
  master_pass=${master_pass:-$default_master}

  # ── Directory ──
  local dir="${BASE_DIR}/${name}"
  echo ""
  read -rp "  Install directory [${dir}]: " custom_dir
  dir=${custom_dir:-$dir}

  # ── Confirm ──
  echo ""
  print_line
  echo -e "  ${WHITE}Review before creating:${NC}"
  echo -e "  Name:            ${GREEN}${name}${NC}"
  echo -e "  Version:         ${GREEN}Odoo ${version}${NC}"
  echo -e "  Web port:        ${GREEN}${web_port}${NC}"
  echo -e "  Gevent port:     ${GREEN}${gevent_port}${NC}"
  echo -e "  DB user:         ${GREEN}${pg_user}${NC}"
  echo -e "  Directory:       ${GREEN}${dir}${NC}"
  print_line
  read -rp "  Proceed? [Y/n]: " go
  [[ "$go" =~ ^[Nn]$ ]] && { print_warn "Cancelled"; pause; return; }

  # ── Build ──
  echo ""
  print_step "Creating directory structure..."
  mkdir -p "$dir/addons" "$dir/config" "$dir/logs"

  print_step "Generating docker-compose.yml..."
  generate_compose "$dir" "$name" "$version" "$web_port" "$gevent_port" "$pg_user" "$pg_pass"

  print_step "Generating odoo.conf..."
  generate_odoo_conf "$dir" "$pg_user" "$pg_pass" "$master_pass" "$gevent_port"

  # Create .env file
  cat > "$dir/.env" <<EOF
POSTGRES_USER=${pg_user}
POSTGRES_PASSWORD=${pg_pass}
EOF
  chmod 600 "$dir/.env"

  # Create addons README
  cat > "$dir/addons/README.md" <<EOF
# Custom Addons for ${name}

Place your Odoo modules here.
Each addon must be a folder with __manifest__.py inside.

After adding a module:
  1. Restart the container:  cd ${dir} && docker compose restart odoo
  2. In Odoo: Settings → Activate Developer Mode
  3. Apps → Update Apps List
  4. Search and install your module

Addons path in container: /mnt/extra-addons
EOF

  print_step "Starting containers..."
  cd "$dir" || { print_error "Cannot cd to $dir"; return 1; }

  if ! dc up -d 2>&1 | while IFS= read -r line; do echo "  $line"; done; then
    print_error "Docker compose failed! Attempting diagnostics..."
    diagnose_instance "$name" "$dir"
    return 1
  fi

  # Save metadata
  save_instance "$name" "$version" "$dir" "$web_port" "$gevent_port" "$pg_user" "$pg_pass" "$master_pass" ""

  echo ""
  print_success "Instance '${name}' created and started!"
  print_info "Wait ~30 seconds for Odoo to initialize on first run"
  show_summary "$name"
  pause
}

# ── LIST Instances ────────────────────────────────────────────
list_instances() {
  print_banner
  echo -e "  ${WHITE}${BOLD}📋  ALL ODOO INSTANCES${NC}"
  print_line
  echo ""

  local names; names=$(list_instance_names)
  if [[ -z "$names" ]]; then
    print_warn "No instances found. Create one first!"
    pause; return
  fi

  local vps_ip; vps_ip=$(get_vps_ip)

  printf "  ${BOLD}${CYAN}%-18s %-10s %-8s %-10s %-10s %s${NC}\n" \
    "NAME" "VERSION" "STATUS" "WEB PORT" "GEVENT" "URL"
  print_line

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    local version web_port gevent_port
    version=$(get_instance_field "$name" version)
    web_port=$(get_instance_field "$name" web_port)
    gevent_port=$(get_instance_field "$name" gevent_port)

    local status color
    status=$(docker inspect --format='{{.State.Status}}' "${name}-app" 2>/dev/null || echo "stopped")
    case $status in
      running)  color="${GREEN}" ;;
      exited)   color="${RED}" ;;
      *)        color="${YELLOW}" ;;
    esac

    printf "  ${WHITE}%-18s${NC} %-10s ${color}%-8s${NC} %-10s %-10s ${CYAN}%s${NC}\n" \
      "$name" "odoo:$version" "$status" "$web_port" "$gevent_port" \
      "http://${vps_ip}:${web_port}"
  done <<< "$names"

  echo ""
  print_line
  echo -e "  ${GRAY}Note: Ports 80, 81, 443 are reserved for Nginx Proxy Manager${NC}"
  pause
}

# ── SELECT Instance Helper ────────────────────────────────────
select_instance() {
  local prompt="${1:-Select instance:}"
  local names; names=$(list_instance_names)
  if [[ -z "$names" ]]; then
    print_error "No instances found"
    return 1
  fi

  echo ""
  echo -e "  ${CYAN}${prompt}${NC}"
  local i=1
  declare -A idx_map
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    local status
    status=$(docker inspect --format='{{.State.Status}}' "${name}-app" 2>/dev/null || echo "stopped")
    local color="${RED}"; [[ "$status" == "running" ]] && color="${GREEN}"
    echo -e "  ${i}) ${WHITE}${name}${NC}  ${color}[${status}]${NC}"
    idx_map[$i]=$name
    ((i++))
  done <<< "$names"
  echo "  0) Cancel"
  echo ""
  read -rp "  Choice: " choice
  [[ "$choice" == "0" ]] && return 1
  SELECTED_INSTANCE="${idx_map[$choice]}"
  [[ -z "$SELECTED_INSTANCE" ]] && { print_error "Invalid choice"; return 1; }
  return 0
}

# ── START/STOP/RESTART ────────────────────────────────────────
manage_container() {
  print_banner
  echo -e "  ${WHITE}${BOLD}⚡  START / STOP / RESTART${NC}"
  print_line

  select_instance "Select instance to manage:" || { pause; return; }
  local name="$SELECTED_INSTANCE"
  local dir; dir=$(get_instance_field "$name" dir)

  echo ""
  echo -e "  ${CYAN}Action for ${WHITE}${name}${CYAN}:${NC}"
  echo "  1) Start"
  echo "  2) Stop"
  echo "  3) Restart"
  echo "  4) Restart Odoo only (not DB)"
  echo "  0) Back"
  read -rp "  Choice: " action

  cd "$dir" || { print_error "Cannot cd to $dir"; pause; return; }

  case $action in
    1) print_step "Starting ${name}...";  dc up -d && print_success "Started" ;;
    2) print_step "Stopping ${name}...";  dc down   && print_success "Stopped" ;;
    3) print_step "Restarting ${name}..."; dc restart && print_success "Restarted" ;;
    4) print_step "Restarting odoo service..."; dc restart odoo && print_success "Odoo restarted" ;;
    0) return ;;
    *) print_error "Invalid choice" ;;
  esac

  show_summary "$name"
  pause
}

# ── LOGS ─────────────────────────────────────────────────────
view_logs() {
  print_banner
  echo -e "  ${WHITE}${BOLD}📜  VIEW LOGS${NC}"
  print_line

  select_instance "Select instance to view logs:" || { pause; return; }
  local name="$SELECTED_INSTANCE"
  local dir; dir=$(get_instance_field "$name" dir)

  echo ""
  echo -e "  ${CYAN}Logs for ${WHITE}${name}${CYAN} (press Ctrl+C to stop):${NC}"
  echo ""
  cd "$dir" && dc logs -f --tail=100 odoo
  pause
}

# ── EDIT Instance ─────────────────────────────────────────────
edit_instance() {
  print_banner
  echo -e "  ${WHITE}${BOLD}✏️   EDIT INSTANCE${NC}"
  print_line

  select_instance "Select instance to edit:" || { pause; return; }
  local name="$SELECTED_INSTANCE"
  local dir version web_port gevent_port pg_user pg_pass master_pass
  dir=$(get_instance_field "$name" dir)
  version=$(get_instance_field "$name" version)
  web_port=$(get_instance_field "$name" web_port)
  gevent_port=$(get_instance_field "$name" gevent_port)
  pg_user=$(get_instance_field "$name" pg_user)
  pg_pass=$(get_instance_field "$name" pg_pass)
  master_pass=$(get_instance_field "$name" master_pass)

  echo ""
  echo -e "  ${CYAN}What to edit for ${WHITE}${name}${CYAN}?${NC}"
  echo "  1) Edit odoo.conf (nano)"
  echo "  2) Change ports (requires restart)"
  echo "  3) Change master password"
  echo "  4) Rebuild containers (keep data)"
  echo "  5) Fix addons not loading"
  echo "  6) Open shell inside Odoo container"
  echo "  0) Back"
  read -rp "  Choice: " echoice

  case $echoice in
    1)
      nano "$dir/config/odoo.conf"
      print_info "Restart needed to apply config changes"
      cd "$dir" && dc restart odoo
      print_success "Restarted with new config"
      ;;
    2)
      echo ""
      local new_web new_gevent
      read -rp "  New web port [${web_port}]: " new_web
      new_web=${new_web:-$web_port}
      read -rp "  New gevent port [${gevent_port}]: " new_gevent
      new_gevent=${new_gevent:-$gevent_port}

      # Validate ports
      for p in "$new_web" "$new_gevent"; do
        if [[ "$p" != "$web_port" ]] && [[ "$p" != "$gevent_port" ]]; then
          if is_port_reserved "$p" || is_port_used "$p"; then
            print_error "Port $p is reserved or already in use!"; pause; return
          fi
        fi
      done

      cd "$dir" && dc down
      generate_compose "$dir" "$name" "$version" "$new_web" "$new_gevent" "$pg_user" "$pg_pass"
      generate_odoo_conf "$dir" "$pg_user" "$pg_pass" "$master_pass" "$new_gevent"
      dc up -d
      save_instance "$name" "$version" "$dir" "$new_web" "$new_gevent" "$pg_user" "$pg_pass" "$master_pass" ""
      web_port=$new_web; gevent_port=$new_gevent
      print_success "Ports updated and containers restarted"
      ;;
    3)
      read -rp "  New master password: " new_master
      [[ -z "$new_master" ]] && { print_warn "Unchanged"; pause; return; }
      sed -i "s/^admin_passwd = .*/admin_passwd = ${new_master}/" "$dir/config/odoo.conf"
      cd "$dir" && dc restart odoo
      save_instance "$name" "$version" "$dir" "$web_port" "$gevent_port" "$pg_user" "$pg_pass" "$new_master" ""
      print_success "Master password updated"
      ;;
    4)
      print_warn "This will recreate containers but KEEP volumes/data"
      confirm "Rebuild containers for ${name}?" || { pause; return; }
      cd "$dir" && dc down && dc up -d --force-recreate
      print_success "Containers rebuilt"
      ;;
    5)
      fix_addons "$name" "$dir"
      ;;
    6)
      print_info "Opening shell in ${name}-app container. Type 'exit' to leave."
      docker exec -it "${name}-app" /bin/bash 2>/dev/null \
        || docker exec -it "${name}-app" /bin/sh
      ;;
    0) return ;;
    *) print_error "Invalid choice" ;;
  esac

  show_summary "$name"
  pause
}

# ── FIX ADDONS ───────────────────────────────────────────────
fix_addons() {
  local name=${1:-""}
  local dir=${2:-""}

  if [[ -z "$name" ]]; then
    select_instance "Select instance to fix addons:" || { pause; return; }
    name="$SELECTED_INSTANCE"
    dir=$(get_instance_field "$name" dir)
  fi

  echo ""
  print_step "Diagnosing addons issue for: ${name}"
  echo ""

  # Check 1: addons folder exists
  if [[ ! -d "$dir/addons" ]]; then
    print_warn "addons/ folder missing — creating it"
    mkdir -p "$dir/addons"
  else
    print_success "addons/ folder exists: $dir/addons"
  fi

  # Check 2: odoo.conf has correct addons_path
  if ! grep -q "addons_path.*extra-addons" "$dir/config/odoo.conf" 2>/dev/null; then
    print_warn "odoo.conf missing addons_path for /mnt/extra-addons — fixing..."
    # Add or replace addons_path
    if grep -q "^addons_path" "$dir/config/odoo.conf" 2>/dev/null; then
      sed -i 's|^addons_path.*|addons_path = /mnt/extra-addons,/usr/lib/python3/dist-packages/odoo/addons|' \
        "$dir/config/odoo.conf"
    else
      sed -i '/^\[options\]/a addons_path = /mnt/extra-addons,/usr/lib/python3/dist-packages/odoo/addons' \
        "$dir/config/odoo.conf"
    fi
    print_success "Fixed addons_path in odoo.conf"
  else
    print_success "odoo.conf has correct addons_path"
  fi

  # Check 3: volume mount in compose
  if ! grep -q "extra-addons" "$dir/docker-compose.yml" 2>/dev/null; then
    print_warn "docker-compose.yml missing addons volume mount — fixing..."
    local version web_port gevent_port pg_user pg_pass
    version=$(get_instance_field "$name" version)
    web_port=$(get_instance_field "$name" web_port)
    gevent_port=$(get_instance_field "$name" gevent_port)
    pg_user=$(get_instance_field "$name" pg_user)
    pg_pass=$(get_instance_field "$name" pg_pass)
    generate_compose "$dir" "$name" "$version" "$web_port" "$gevent_port" "$pg_user" "$pg_pass"
    print_success "Regenerated docker-compose.yml with correct volume mount"
  else
    print_success "docker-compose.yml has addons volume mount"
  fi

  # Check 4: any addons present
  local addon_count
  addon_count=$(find "$dir/addons" -maxdepth 2 -name "__manifest__.py" 2>/dev/null | wc -l)
  if [[ "$addon_count" -eq 0 ]]; then
    print_warn "No modules found in $dir/addons yet (no __manifest__.py)"
    print_info "Place your module folders in: $dir/addons/"
  else
    print_success "Found ${addon_count} addon module(s) in addons/"
  fi

  # Restart to apply
  print_step "Restarting Odoo to apply changes..."
  cd "$dir" && dc restart odoo 2>&1 | tail -3
  print_success "Done! Now in Odoo: Settings → Developer Mode → Apps → Update Apps List"
}

# ── DIAGNOSE ─────────────────────────────────────────────────
diagnose_instance() {
  local name=$1 dir=$2
  echo ""
  print_warn "Running diagnostics for: $name"
  echo ""

  # Check if images exist
  local version; version=$(get_instance_field "$name" version)
  print_step "Checking Docker image odoo:${version}..."
  if ! docker image inspect "odoo:${version}" &>/dev/null; then
    print_warn "Image odoo:${version} not cached locally — pulling..."
    docker pull "odoo:${version}" && print_success "Image pulled" || print_error "Pull failed — check internet"
  else
    print_success "Image odoo:${version} available"
  fi

  # Check ports
  local web_port gevent_port
  web_port=$(get_instance_field "$name" web_port)
  gevent_port=$(get_instance_field "$name" gevent_port)
  for p in "$web_port" "$gevent_port"; do
    if ss -tlnp 2>/dev/null | grep -q ":${p} "; then
      print_error "Port $p is already bound by another process!"
    fi
  done

  # Check config file
  [[ -f "$dir/config/odoo.conf" ]] \
    && print_success "odoo.conf found" \
    || print_error "odoo.conf MISSING at $dir/config/odoo.conf"

  # Check docker compose file
  [[ -f "$dir/docker-compose.yml" ]] \
    && print_success "docker-compose.yml found" \
    || print_error "docker-compose.yml MISSING"

  # Docker daemon
  docker info &>/dev/null \
    && print_success "Docker daemon running" \
    || print_error "Docker daemon is NOT running — start with: sudo systemctl start docker"

  echo ""
  print_info "Check logs with: cd $dir && docker compose logs"
}

# ── DELETE Instance ───────────────────────────────────────────
delete_instance() {
  print_banner
  echo -e "  ${WHITE}${BOLD}🗑️   DELETE INSTANCE${NC}"
  print_line

  select_instance "Select instance to DELETE:" || { pause; return; }
  local name="$SELECTED_INSTANCE"
  local dir; dir=$(get_instance_field "$name" dir)

  echo ""
  print_warn "This will permanently delete containers, volumes, and all data for: ${name}"
  echo ""
  echo -e "  ${CYAN}Delete options:${NC}"
  echo "  1) Delete containers + volumes (DATA LOST)"
  echo "  2) Delete containers only (keep volumes/data)"
  echo "  3) Delete everything including files on disk"
  echo "  0) Cancel"
  read -rp "  Choice: " dchoice
  [[ "$dchoice" == "0" ]] && return

  confirm "CONFIRM DELETE of '${name}'?" || { print_warn "Cancelled"; pause; return; }

  cd "$dir" 2>/dev/null || true

  case $dchoice in
    1)
      print_step "Removing containers and volumes..."
      dc down -v 2>/dev/null
      print_success "Containers and volumes removed"
      ;;
    2)
      print_step "Removing containers (keeping volumes)..."
      dc down 2>/dev/null
      print_success "Containers removed (volumes preserved)"
      ;;
    3)
      print_step "Removing containers, volumes, and all files..."
      dc down -v 2>/dev/null
      rm -rf "$dir"
      print_success "Everything deleted"
      ;;
  esac

  remove_instance_meta "$name"
  print_success "Instance '${name}' removed from registry"
  pause
}

# ── IMPORT Existing Instance ──────────────────────────────────
import_existing() {
  print_banner
  echo -e "  ${WHITE}${BOLD}📥  IMPORT EXISTING ODOO INSTANCE${NC}"
  print_line
  echo ""
  print_info "Use this to register an existing docker-compose Odoo setup"
  echo ""

  read -rp "  Instance name: " name
  [[ -z "$name" ]] && return
  instance_exists "$name" && { print_error "Name already registered"; pause; return; }

  read -rp "  Directory (where docker-compose.yml is): " dir
  [[ ! -f "$dir/docker-compose.yml" ]] && { print_error "No docker-compose.yml at $dir"; pause; return; }

  read -rp "  Odoo version: " version
  read -rp "  Web port: " web_port
  read -rp "  Gevent port: " gevent_port
  read -rp "  DB user: " pg_user
  read -rp "  DB password: " pg_pass
  read -rp "  Master password: " master_pass

  save_instance "$name" "$version" "$dir" "$web_port" "$gevent_port" "$pg_user" "$pg_pass" "$master_pass" "imported"
  print_success "Instance '${name}' imported!"
  show_summary "$name"
  pause
}

# ── GLOBAL STATUS ─────────────────────────────────────────────
show_all_summaries() {
  print_banner
  echo -e "  ${WHITE}${BOLD}🔍  FULL SUMMARY — ALL INSTANCES${NC}"
  print_line

  local names; names=$(list_instance_names)
  if [[ -z "$names" ]]; then
    print_warn "No instances registered"
    pause; return
  fi

  while IFS= read -r name; do
    [[ -n "$name" ]] && show_summary "$name"
  done <<< "$names"

  print_line
  echo -e "  ${GRAY}Ports 80, 81, 443 → Nginx Proxy Manager (DO NOT USE)${NC}"
  pause
}

# ── PORT OVERVIEW ─────────────────────────────────────────────
show_port_map() {
  print_banner
  echo -e "  ${WHITE}${BOLD}🗺️   PORT USAGE MAP${NC}"
  print_line
  echo ""

  echo -e "  ${RED}RESERVED (Nginx Proxy Manager + System):${NC}"
  echo -e "  ${RED}  80   → HTTP (Nginx)${NC}"
  echo -e "  ${RED}  81   → Nginx Proxy Manager UI${NC}"
  echo -e "  ${RED}  443  → HTTPS (Nginx)${NC}"
  echo ""

  echo -e "  ${GREEN}REGISTERED ODOO INSTANCES:${NC}"
  local names; names=$(list_instance_names)
  if [[ -z "$names" ]]; then
    echo -e "  ${GRAY}  (none)${NC}"
  else
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      local web_port gevent_port version
      web_port=$(get_instance_field "$name" web_port)
      gevent_port=$(get_instance_field "$name" gevent_port)
      version=$(get_instance_field "$name" version)
      echo -e "  ${GREEN}  ${web_port}   → ${name} (Odoo ${version}) web${NC}"
      echo -e "  ${CYAN}  ${gevent_port}   → ${name} longpoll/gevent${NC}"
    done <<< "$names"
  fi

  echo ""
  echo -e "  ${YELLOW}LISTENING PORTS (from system):${NC}"
  ss -tlnp 2>/dev/null | awk 'NR>1 {print "  " $4}' | grep -E ':\d+$' | sort -t: -k2 -n | head -20
  pause
}

# ── INSTALL NGINX PROXY MANAGER ──────────────────────────────
install_npm() {
  echo ""
  print_step "Checking Nginx Proxy Manager..."

  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^nginx-proxy-manager$"; then
    local state; state=$(docker inspect --format='{{.State.Status}}' nginx-proxy-manager 2>/dev/null)
    print_warn "Nginx Proxy Manager container already exists (status: ${state})"
    read -rp "  Reinstall / recreate it? [y/N]: " ans
    [[ ! "$ans" =~ ^[Yy]$ ]] && return
    docker rm -f nginx-proxy-manager 2>/dev/null
  fi

  local npm_dir="${BASE_DIR}/nginx-proxy-manager"
  mkdir -p "$npm_dir/data" "$npm_dir/letsencrypt"

  cat > "$npm_dir/docker-compose.yml" <<'EOF'
# Nginx Proxy Manager
services:
  app:
    image: jc21/nginx-proxy-manager:latest
    container_name: nginx-proxy-manager
    restart: unless-stopped
    ports:
      - "80:80"
      - "81:81"
      - "443:443"
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
EOF

  print_step "Starting Nginx Proxy Manager..."
  cd "$npm_dir" && dc up -d

  if docker inspect --format='{{.State.Status}}' nginx-proxy-manager 2>/dev/null | grep -q "running"; then
    local vps_ip; vps_ip=$(get_vps_ip)
    echo ""
    print_success "Nginx Proxy Manager is running!"
    echo ""
    echo -e "  ${CYAN}${BOLD}  ╔══════════════════════════════════════════╗"
    echo -e "  ║  🌐  NGINX PROXY MANAGER ACCESS           ║"
    echo -e "  ╠══════════════════════════════════════════╣"
    printf "  ${CYAN}║  %-18s ${GREEN}%-23s${CYAN}║\n" "Admin UI:" "http://${vps_ip}:81"
    printf "  ${CYAN}║  %-18s ${YELLOW}%-23s${CYAN}║\n" "Default email:" "admin@example.com"
    printf "  ${CYAN}║  %-18s ${YELLOW}%-23s${CYAN}║\n" "Default password:" "changeme"
    echo -e "  ${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    print_warn "Change the default credentials immediately after first login!"
  else
    print_error "Container failed to start. Check: cd ${npm_dir} && docker compose logs"
  fi
}

# ── INSTALL PORTAINER ─────────────────────────────────────────
install_portainer() {
  echo ""
  print_step "Checking Portainer..."

  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^portainer$"; then
    local state; state=$(docker inspect --format='{{.State.Status}}' portainer 2>/dev/null)
    print_warn "Portainer container already exists (status: ${state})"
    read -rp "  Reinstall / recreate it? [y/N]: " ans
    [[ ! "$ans" =~ ^[Yy]$ ]] && return
    docker rm -f portainer 2>/dev/null
  fi

  local port=9000
  if is_port_used "$port"; then
    print_warn "Port 9000 is in use — trying 9001..."
    port=9001
  fi

  print_step "Creating Portainer volume..."
  docker volume create portainer_data 2>/dev/null

  print_step "Starting Portainer on port ${port}..."
  docker run -d \
    --name portainer \
    --restart unless-stopped \
    -p "${port}:9000" \
    -p 9443:9443 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:latest

  if docker inspect --format='{{.State.Status}}' portainer 2>/dev/null | grep -q "running"; then
    local vps_ip; vps_ip=$(get_vps_ip)
    echo ""
    print_success "Portainer is running!"
    echo ""
    echo -e "  ${CYAN}${BOLD}  ╔══════════════════════════════════════════╗"
    echo -e "  ║  🐳  PORTAINER ACCESS                     ║"
    echo -e "  ╠══════════════════════════════════════════╣"
    printf "  ${CYAN}║  %-18s ${GREEN}%-23s${CYAN}║\n" "HTTP UI:" "http://${vps_ip}:${port}"
    printf "  ${CYAN}║  %-18s ${GREEN}%-23s${CYAN}║\n" "HTTPS UI:" "https://${vps_ip}:9443"
    printf "  ${CYAN}║  %-18s ${YELLOW}%-23s${CYAN}║\n" "Setup:" "Create admin on first visit"
    echo -e "  ${CYAN}╚══════════════════════════════════════════╝${NC}"
  else
    print_error "Container failed to start. Check: docker logs portainer"
  fi
}

# ── INSTALL TOOLS MENU ────────────────────────────────────────
install_tools_menu() {
  print_banner
  echo -e "  ${WHITE}${BOLD}🛠️   INSTALL OPTIONAL TOOLS${NC}"
  print_line
  echo ""

  # Show current status
  local npm_status portainer_status
  npm_status=$(docker inspect --format='{{.State.Status}}' nginx-proxy-manager 2>/dev/null || echo "not installed")
  portainer_status=$(docker inspect --format='{{.State.Status}}' portainer 2>/dev/null || echo "not installed")

  local npm_color="${RED}"; [[ "$npm_status" == "running" ]] && npm_color="${GREEN}"
  local pt_color="${RED}";  [[ "$portainer_status" == "running" ]] && pt_color="${GREEN}"

  echo -e "  ${CYAN}Tool                  Status${NC}"
  print_line
  printf "  ${WHITE}%-22s${NC} ${npm_color}%s${NC}\n" "Nginx Proxy Manager" "$npm_status"
  printf "  ${WHITE}%-22s${NC} ${pt_color}%s${NC}\n" "Portainer" "$portainer_status"
  echo ""
  print_line
  echo ""
  echo -e "  ${GREEN}1)${NC} Install Nginx Proxy Manager  ${GRAY}(reverse proxy + SSL, ports 80/81/443)${NC}"
  echo -e "  ${GREEN}2)${NC} Install Portainer             ${GRAY}(Docker web UI, port 9000)${NC}"
  echo -e "  ${GREEN}3)${NC} Install Both"
  echo -e "  ${GRAY}0) Back${NC}"
  echo ""
  read -rp "  Choice [0-3]: " tchoice

  case $tchoice in
    1) install_npm    ;;
    2) install_portainer ;;
    3) install_npm && echo "" && install_portainer ;;
    0) return ;;
    *) print_error "Invalid choice" ;;
  esac

  pause
}

# ── MONITOR DASHBOARD ─────────────────────────────────────────
# Draws a colored block progress bar.  Usage: _mon_bar <pct> <width>
_mon_bar() {
  local pct=${1:-0} width=${2:-16} filled empty color bar="" i
  (( pct > 100 )) && pct=100
  filled=$(( pct * width / 100 ))
  empty=$(( width - filled ))
  if   (( pct >= 85 )); then color=$RED
  elif (( pct >= 65 )); then color=$YELLOW
  else color=$GREEN
  fi
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty;  i++)); do bar+="░"; done
  printf "${color}%s${NC}" "$bar"
}

show_monitor() {
  local _ref=20 _quit=false _key _hc_tmp
  _hc_tmp="/tmp/_odoo_mon_hc_$$"
  trap '_quit=true; rm -f "$_hc_tmp" 2>/dev/null' INT TERM

  while [[ "$_quit" == false ]]; do
    clear

    # ── host memory (from /proc/meminfo) ──────────────────────────────────
    local mT mA mU mP sT sF sU sP
    mT=$(awk '/^MemTotal:/{print $2}'     /proc/meminfo 2>/dev/null || echo 2097152)
    mA=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo 524288)
    sT=$(awk '/^SwapTotal:/{print $2}'    /proc/meminfo 2>/dev/null || echo 0)
    sF=$(awk '/^SwapFree:/{print $2}'     /proc/meminfo 2>/dev/null || echo 0)
    mU=$(( mT - mA ))
    mP=$(( mT > 0 ? mU * 100 / mT : 0 ))
    sU=$(( sT - sF ))
    sP=$(( sT > 0 ? sU * 100 / sT : 0 ))
    local mTg mUg sTg sUg
    mTg=$(awk "BEGIN{printf \"%.1f\",${mT}/1048576}")
    mUg=$(awk "BEGIN{printf \"%.1f\",${mU}/1048576}")
    sTg=$(awk "BEGIN{printf \"%.1f\",${sT}/1048576}")
    sUg=$(awk "BEGIN{printf \"%.1f\",${sU}/1048576}")
    local load uptime_p ts
    load=$(awk '{printf "%s  %s  %s",$1,$2,$3}' /proc/loadavg 2>/dev/null || echo "N/A")
    uptime_p=$(uptime -p 2>/dev/null | sed 's/^up //' || echo "N/A")
    ts=$(date '+%H:%M:%S')

    # ── build port map from meta file ─────────────────────────────────────
    unset _pmap; declare -A _pmap
    if [[ -f "$META_FILE" ]]; then
      while IFS='|' read -r _n _v _d _wp _rest || [[ -n "$_n" ]]; do
        [[ -z "$_n" || "$_n" == \#* || -z "$_wp" ]] && continue
        _pmap["${_n}-app"]="$_wp"
        _pmap["${_n}_odoo"]="$_wp"
        _pmap["${_n}-odoo"]="$_wp"
      done < "$META_FILE"
    fi

    # ── fire health checks in parallel (TCP port probe) ───────────────────
    rm -f "$_hc_tmp"
    for _k in "${!_pmap[@]}"; do
      local _wp="${_pmap[$_k]}"
      [[ -z "$_wp" ]] && continue
      (
        if timeout 2 bash -c "echo >/dev/tcp/127.0.0.1/${_wp}" 2>/dev/null; then
          printf '%s=UP\n' "$_k"
        else
          printf '%s=DOWN\n' "$_k"
        fi
      ) >> "$_hc_tmp" &
    done

    # ── capture docker stats while health checks run in background ─────────
    local _stats
    _stats=$(docker stats --no-stream \
      --format "{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}|{{.BlockIO}}" \
      2>/dev/null)

    wait  # wait for all health check subshells

    # collect health check results into associative array
    unset _hcm; declare -A _hcm
    if [[ -f "$_hc_tmp" ]]; then
      while IFS='=' read -r _k _v; do
        [[ -n "$_k" ]] && _hcm["$_k"]="$_v"
      done < "$_hc_tmp"
      rm -f "$_hc_tmp"
    fi

    # ── header banner ─────────────────────────────────────────────────────
    echo -e "${CYAN}${BOLD}"
    echo "  ╔═══════════════════════════════════════════════════════════════╗"
    printf "  ║  📊  ODOO SERVER MONITOR       %s    ↻%ds  [q]uit   ║\n" "$ts" "$_ref"
    echo "  ╠═══════════════════════════════════════════════════════════════╣"
    printf "  ║  🖥  LOAD: %-18s  UP: %-24s ║\n" "$load" "$uptime_p"
    echo "  ╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # ── host RAM / SWAP bars ───────────────────────────────────────────────
    printf "  ${WHITE}RAM${NC}  "; _mon_bar "$mP" 22
    printf "  ${WHITE}%s${NC}/${WHITE}%s${NC} GB  " "$mUg" "$mTg"
    if   (( mP >= 90 )); then echo -e "${RED}${BOLD}${mP}%%  🔥 CRITICAL — containers are swapping to disk!${NC}"
    elif (( mP >= 75 )); then echo -e "${YELLOW}${mP}%%  ⚠ HIGH — performance degraded${NC}"
    elif (( mP >= 55 )); then echo -e "${YELLOW}${mP}%%${NC}"
    else                      echo -e "${GREEN}${mP}%%${NC}"
    fi

    if (( sT > 0 )); then
      printf "  ${WHITE}SWP${NC}  "; _mon_bar "$sP" 22
      printf "  ${WHITE}%s${NC}/${WHITE}%s${NC} GB  " "$sUg" "$sTg"
      if (( sP >= 50 )); then
        echo -e "${RED}${sP}%%  HEAVY SWAP — severe disk I/O bottleneck!${NC}"
      else
        echo -e "${CYAN}${sP}%%${NC}"
      fi
    else
      echo -e "  ${GRAY}SWP  none${NC}  ${YELLOW}⚠ add swap to prevent OOM kills${NC}"
    fi
    echo ""

    # ── container table ────────────────────────────────────────────────────
    printf "  ${BOLD}${WHITE}%-20s %-8s %-17s %-23s %-22s %s${NC}\n" \
      "CONTAINER" "STATUS" "CPU" "RAM" "NET I/O (↓/↑)" "WEB"
    echo -e "  ${GRAY}$(printf '─%.0s' {1..92})${NC}"

    local _ndown=0 _warn_msgs=()

    while IFS='|' read -r cname cpu mem_str mem_pc netio blockio; do
      [[ -z "$cname" ]] && continue

      # container running state
      local cst; cst=$(docker inspect --format '{{.State.Status}}' "$cname" 2>/dev/null || echo "?")
      local st_ico st_col
      case "$cst" in
        running)    st_ico="🟢 UP "; st_col=$GREEN  ;;
        exited)     st_ico="🔴 DN "; st_col=$RED;   _ndown=$(( _ndown + 1 )) ;;
        restarting) st_ico="🟡 RS "; st_col=$YELLOW ;;
        *)          st_ico="⚪ ?? "; st_col=$GRAY   ;;
      esac

      # CPU progress bar (8 blocks)
      local cn="${cpu//[^0-9.]/}"; cn="${cn%%.*}"; cn="${cn:-0}"
      local cc; (( cn >= 80 )) && cc=$RED || { (( cn >= 40 )) && cc=$YELLOW || cc=$CYAN; }
      local cb="" i
      for ((i=0; i<8; i++)); do (( i < cn*8/100 )) && cb+="█" || cb+="░"; done

      # RAM progress bar (10 blocks)
      local rn="${mem_pc//[^0-9.]/}"; rn="${rn%%.*}"; rn="${rn:-0}"
      local rc; (( rn >= 85 )) && rc=$RED || { (( rn >= 65 )) && rc=$YELLOW || rc=$GREEN; }
      local rb=""
      for ((i=0; i<10; i++)); do (( i < rn*10/100 )) && rb+="█" || rb+="░"; done

      # classify container
      local type_ico="${GRAY}📦${NC}" is_app=false is_db=false
      if   [[ "$cname" == *-app   || "$cname" == *_odoo || "$cname" == *-odoo ]]; then
        is_app=true; type_ico="${MAGENTA}🐘${NC}"
      elif [[ "$cname" == *-db    || "$cname" == *_db   || "$cname" == *postgres* ]]; then
        is_db=true;  type_ico="${BLUE}🗄${NC} "
      fi

      # web health (Odoo app containers only)
      local web_str="${GRAY}—${NC}"
      if [[ "$is_app" == true ]]; then
        local wp="${_pmap[$cname]:-}"
        if [[ -n "$wp" ]]; then
          case "${_hcm[$cname]:-}" in
            UP)   web_str="${GREEN}✅ :${wp}${NC}" ;;
            DOWN) web_str="${RED}✖  :${wp}${NC}"; _warn_msgs+=("${cname}: port ${wp} not responding") ;;
            *)    [[ "$cst" == "running" ]] \
                    && web_str="${YELLOW}? :${wp}${NC}" \
                    || web_str="${RED}— stopped${NC}" ;;
          esac
        else
          web_str="${GRAY}(no port)${NC}"
        fi
      fi

      # print row
      printf "  ${type_ico} ${st_col}%-18s${NC} " "$cname"
      printf "${st_col}%-7s${NC}  " "$st_ico"
      printf "${cc}%s${NC} %-7s  " "$cb" "$cpu"
      printf "${rc}%s${NC} %-21s  " "$rb" "$mem_str"
      printf "${GRAY}%-22s${NC}  " "$netio"
      echo -e "$web_str"

    done <<< "$_stats"

    echo -e "  ${GRAY}$(printf '─%.0s' {1..92})${NC}"
    echo ""

    # ── warnings / tips ────────────────────────────────────────────────────
    if (( mP >= 75 )); then
      echo -e "  ${YELLOW}⚠  Server RAM ${mP}% used (${mUg}/${mTg}GB) — all instances share this memory${NC}"
    fi
    if (( sT == 0 )); then
      echo -e "  ${YELLOW}ℹ  No swap — if RAM fills, containers will be OOM-killed without warning${NC}"
    fi
    if (( _ndown > 0 )); then
      echo -e "  ${RED}✖  ${_ndown} container(s) are DOWN${NC}"
    fi
    for _wm in "${_warn_msgs[@]}"; do
      echo -e "  ${RED}✖  ${_wm}${NC}"
    done
    echo ""

    # ── refresh countdown with q-to-quit ──────────────────────────────────
    local s
    for ((s=_ref; s>0; s--)); do
      printf "\r  ${GRAY}↻ Refreshing in ${WHITE}%ds${GRAY} — press ${WHITE}q${GRAY} to return to menu   ${NC}" "$s"
      read -r -t 1 -n 1 _key 2>/dev/null
      local _re=$?
      [[ $_re -eq 0 && ( "$_key" == "q" || "$_key" == "Q" ) ]] && { _quit=true; break; }
      [[ "$_quit" == true ]] && break
    done
    printf "\r%95s\r" ""

  done

  trap - INT TERM
  rm -f "$_hc_tmp" 2>/dev/null
  echo ""
}

# ── MAIN MENU ─────────────────────────────────────────────────
main_menu() {
  while true; do
    print_banner

    # Quick status line
    local count; count=$(list_instance_names 2>/dev/null | grep -c . || echo 0)
    echo -e "  ${GRAY}Registered instances: ${WHITE}${count}${GRAY} | Base dir: ${WHITE}${BASE_DIR}${NC}"
    print_line
    echo ""
    echo -e "  ${WHITE}${BOLD}Main Menu${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} ➕  Create new Odoo instance"
    echo -e "  ${CYAN}2)${NC} 📋  List all instances"
    echo -e "  ${CYAN}3)${NC} 🔍  Full summary (all instances)"
    echo -e "  ${CYAN}4)${NC} 🗺️   Port usage map"
    echo -e "  ${YELLOW}5)${NC} ⚡  Start / Stop / Restart instance"
    echo -e "  ${YELLOW}6)${NC} ✏️   Edit / Configure instance"
    echo -e "  ${YELLOW}7)${NC} 📜  View live logs"
    echo -e "  ${YELLOW}8)${NC} 🔧  Fix addons not loading"
    echo -e "  ${RED}9)${NC} 🗑️   Delete instance"
    echo -e "  ${GRAY}10)${NC} 📥  Import existing instance"
    echo -e "  ${BLUE}11)${NC} 🛠️   Install optional tools ${GRAY}(Nginx Proxy Manager / Portainer)${NC}"
    echo -e "  ${MAGENTA}12)${NC} 📊  Live server monitor ${GRAY}(CPU · RAM · Net · web health)${NC}"
    echo ""
    print_line
    echo -e "  ${GRAY}0) Exit${NC}"
    echo ""
    read -rp "  $(echo -e "${WHITE}Choose [0-12]: ${NC}")" choice

    case $choice in
      1)  create_instance ;;
      2)  list_instances ;;
      3)  show_all_summaries ;;
      4)  show_port_map ;;
      5)  manage_container ;;
      6)  edit_instance ;;
      7)  view_logs ;;
      8)  fix_addons ;;
      9)  delete_instance ;;
      10) import_existing ;;
      11) install_tools_menu ;;
      12) show_monitor ;;
      0)  echo -e "\n  ${GREEN}Goodbye!${NC}\n"; exit 0 ;;
      *)  print_error "Invalid choice"; sleep 1 ;;
    esac
  done
}

# ── ENTRY POINT ───────────────────────────────────────────────
check_deps || exit 1
main_menu