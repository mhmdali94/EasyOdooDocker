# 🐘 Odoo Docker Manager

An interactive Bash script to deploy and manage multiple Odoo instances on a Linux VPS using Docker — no manual config files, no guesswork.

**By [Mohammed Ali](https://prismatechwork.com) · [GitHub](https://github.com/mhmdali94/EasyOdooDocker)**

---

## Features

- **Multi-instance** — run Odoo 16, 17, 18 (or any version) side-by-side on the same server
- **One-command setup** — auto-generates `docker-compose.yml` and `odoo.conf` with sane defaults
- **Smart port assignment** — detects used/reserved ports and auto-assigns free ones
- **Auto Docker install** — detects your distro (Ubuntu, Debian, CentOS, RHEL, Fedora) and installs Docker if missing
- **Instance management** — start, stop, restart, view logs, edit config, open shell
- **Addons auto-fix** — diagnoses and repairs broken custom module setups in one click
- **Import existing** — register an already-running docker-compose Odoo setup
- **Port map** — see all registered and system-used ports at a glance
- **Optional tools installer** — install Nginx Proxy Manager and/or Portainer as Docker containers with a single menu choice
- **Nginx Proxy Manager aware** — ports 80, 81, 443 are permanently reserved

---

## Requirements

- Linux VPS (Ubuntu 20.04+ recommended; also works on Debian, CentOS, RHEL, Fedora, Rocky, AlmaLinux)
- `bash` 4+
- Internet access (for pulling Docker images)
- `curl` (auto-installed if missing)

> Docker and Docker Compose are **auto-installed** if not present.

---

## Installation

```bash
# Clone the repo
git clone https://github.com/mhmdali94/EasyOdooDocker.git
cd EasyOdooDocker

# Make the script executable
chmod +x "Odoo Manager.sh"

# Run it
bash "Odoo Manager.sh"
```

---

## Usage

Launch the script and navigate the interactive menu:

```text
  ╔═══════════════════════════════════════════════════════╗
  ║          🐘  ODOO DOCKER MANAGER  🐘                  ║
  ║     Multi-Instance | Auto-Fix | Smart Port Assign     ║
  ╠═══════════════════════════════════════════════════════╣
  ║  🌐 https://prismatechwork.com                        ║
  ║  🐙 https://github.com/mhmdali94/EasyOdooDocker       ║
  ╚═══════════════════════════════════════════════════════╝

  Main Menu

  1) ➕  Create new Odoo instance
  2) 📋  List all instances
  3) 🔍  Full summary (all instances)
  4) 🗺️   Port usage map
  5) ⚡  Start / Stop / Restart instance
  6) ✏️   Edit / Configure instance
  7) 📜  View live logs
  8) 🔧  Fix addons not loading
  9) 🗑️   Delete instance
  10) 📥  Import existing instance
  11) 🛠️  Install optional tools (Nginx Proxy Manager / Portainer)
```

### Creating an instance

1. Choose **1) Create new Odoo instance**
2. Enter a name (e.g. `odoo17`, `client-demo`)
3. Select Odoo version (16, 17, 18, or custom)
4. Accept or override the suggested ports
5. Set or auto-generate DB credentials and master password
6. Confirm — the script pulls the image, generates all config files, and starts the containers

Access your instance at `http://YOUR_SERVER_IP:PORT` once it's up (~30 seconds on first run).

---

## Optional Tools

Access via **11) Install optional tools** from the main menu. The script checks if the tool is already installed and asks before proceeding.

### Nginx Proxy Manager

A Docker-based reverse proxy with a web UI for managing domains, SSL certificates, and proxying your Odoo instances behind a clean URL.

- Ports: `80` (HTTP), `81` (Admin UI), `443` (HTTPS)
- Installed to: `~/docker/nginx-proxy-manager/`
- Default login: `admin@example.com` / `changeme` — **change immediately after first login**

### Portainer

A web UI for managing all Docker containers, images, volumes, and networks on your server.

- Port: `9000` (HTTP) / `9443` (HTTPS)
- No default credentials — you create the admin account on first visit

---

## Instance File Structure

Each instance is stored under `~/docker/<name>/`:

```text
~/docker/odoo17/
├── docker-compose.yml   # Auto-generated
├── config/
│   └── odoo.conf        # Auto-generated Odoo config
├── addons/              # Drop your custom modules here
│   └── README.md
├── logs/                # Odoo log files
└── .env                 # DB credentials (chmod 600)
```

### Adding custom addons

1. Copy your module folder into `~/docker/<name>/addons/`
2. Use **8) Fix addons not loading** from the menu (or restart manually)
3. In Odoo: **Settings → Activate Developer Mode → Apps → Update Apps List**

---

## Port Reservations

| Port | Reserved for           |
|------|------------------------|
| 80   | Nginx HTTP             |
| 81   | Nginx Proxy Manager UI |
| 443  | Nginx HTTPS            |
| 22   | SSH                    |
| 3306 | MySQL                  |
| 5432 | PostgreSQL             |
| 8080 | Common web services    |
| 8888 | Common web services    |

Odoo instances are assigned free ports starting from **8069** (web) and **8072** (longpoll/gevent).

---

## Supported Distros

| Distro                                      | Auto-install Docker     |
|---------------------------------------------|-------------------------|
| Ubuntu / Debian / Linux Mint / Pop!_OS      | ✅                      |
| CentOS / RHEL / Rocky / AlmaLinux / Fedora  | ✅                      |
| Other                                       | ✅ (via get.docker.com) |

---

## Author

**Mohammed Ali**
- Website: [prismatechwork.com](https://prismatechwork.com)
- GitHub: [github.com/mhmdali94](https://github.com/mhmdali94)

---

## License

MIT — free to use, modify, and distribute.
