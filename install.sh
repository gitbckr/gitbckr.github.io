#!/usr/bin/env bash
#
# Gitbacker installer — self-hosted git backup tool
#
#   bash -c "$(curl -fsSL https://gitbacker.com/install.sh)"
#
# Or:
#   curl -fsSL https://gitbacker.com/install.sh | bash
#
# What this does:
#   1. Checks for Docker and Docker Compose
#   2. Prompts for install directory (default: ./gitbacker in current folder)
#   3. Generates a random JWT secret
#   4. Pulls images and starts all services
#   5. Seeds the admin account
#   6. Prints the URL to access Gitbacker
#
set -euo pipefail

main() {
  REPO="https://raw.githubusercontent.com/gitbckr/gitbacker/main"
  VERSION="${GITBACKER_VERSION:-latest}"

  # --- Helpers ---

  info()  { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
  ok()    { printf "\033[1;32m==>\033[0m %s\n" "$*"; }
  warn()  { printf "\033[1;33m==>\033[0m %s\n" "$*"; }
  fail()  { printf "\033[1;31m==>\033[0m %s\n" "$*" >&2; exit 1; }

  prompt() {
    # Read from /dev/tty so prompts work even under `curl | bash`.
    local prompt_text="$1" default="${2:-}" reply
    if [ -r /dev/tty ]; then
      printf "%s " "$prompt_text" > /dev/tty
      read -r reply < /dev/tty || reply=""
      printf "%s" "${reply:-$default}"
    else
      printf "%s" "$default"
    fi
  }

  choose_install_dir() {
    # Priority:
    #   1. GITBACKER_DIR env var (scripted/CI use — no prompt)
    #   2. Interactive: default to $PWD/gitbacker, let user confirm or override
    #   3. Non-interactive fallback: $PWD/gitbacker
    if [ -n "${GITBACKER_DIR:-}" ]; then
      printf "%s" "$GITBACKER_DIR"
      return
    fi

    local default="$PWD/gitbacker"
    if [ ! -r /dev/tty ]; then
      printf "%s" "$default"
      return
    fi

    local answer
    answer=$(prompt "Install Gitbacker to $default? [Y/n]" "y")
    case "$answer" in
      ""|[yY]|[yY][eE][sS])
        printf "%s" "$default"
        ;;
      *)
        local custom
        custom=$(prompt "Enter install path:" "$default")
        # Expand leading ~ manually (shell doesn't expand from read)
        custom="${custom/#\~/$HOME}"
        printf "%s" "${custom:-$default}"
        ;;
    esac
  }

  check_command() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 is required but not installed. See https://docs.docker.com/get-docker/"
  }

  random_secret() {
    head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 43
  }

  wait_for_healthy() {
    local url="$1" retries="${2:-30}" delay="${3:-2}"
    info "Waiting for API to be ready..."
    for i in $(seq 1 "$retries"); do
      if curl -sf "$url" >/dev/null 2>&1; then
        return 0
      fi
      sleep "$delay"
    done
    fail "API did not become healthy after $((retries * delay))s"
  }

  # --- Preflight checks ---

  info "Checking prerequisites..."
  check_command docker
  docker compose version >/dev/null 2>&1 || fail "Docker Compose V2 is required (docker compose, not docker-compose)"
  check_command curl
  ok "Docker and Docker Compose found"

  # --- Install directory ---

  INSTALL_DIR=$(choose_install_dir)
  info "Using install directory: $INSTALL_DIR"


  # If an existing install is found (either compose.yml OR .env present),
  # take the update path. Never regenerate secrets on top of an existing install.
  if [ -d "$INSTALL_DIR" ] && { [ -f "$INSTALL_DIR/docker-compose.yml" ] || [ -f "$INSTALL_DIR/.env" ]; }; then
    info "Existing installation detected at $INSTALL_DIR — updating in place"
    cd "$INSTALL_DIR"

    # Refresh compose file to pick up any new services/env vars/volumes.
    # .env and .admin-credentials are preserved (never overwritten).
    info "Refreshing docker-compose.yml..."
    curl -fsSL "$REPO/docker-compose.yml" -o docker-compose.yml

    info "Pulling latest images..."
    VERSION="$VERSION" docker compose pull </dev/null

    info "Restarting services..."
    VERSION="$VERSION" docker compose up -d </dev/null

    ok "Gitbacker updated and running at http://localhost:3000"
    if [ -f ".admin-credentials" ]; then
      echo ""
      echo "  Your admin credentials are in: $INSTALL_DIR/.admin-credentials"
    fi
    exit 0
  fi

  info "Installing to $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  # --- Create data directories ---

  mkdir -p "${INSTALL_DIR}/data/postgres" "${INSTALL_DIR}/data/redis" "${INSTALL_DIR}/data/backups"

  # --- Download configuration ---

  info "Downloading configuration..."
  curl -fsSL "$REPO/docker-compose.yml" -o docker-compose.yml
  curl -fsSL "$REPO/.env.example" -o .env

  # --- Patch .env for production ---

  JWT_SECRET=$(random_secret)
  ADMIN_PASSWORD=$(random_secret | head -c 16)

  sed -i.bak "s|^JWT_SECRET=.*|JWT_SECRET=$JWT_SECRET|" .env
  sed -i.bak "s|^ENVIRONMENT=.*|ENVIRONMENT=production|" .env
  rm -f .env.bak

  cat > .admin-credentials <<CREDS
Gitbacker Admin Credentials
============================
URL:      http://localhost:3000
Email:    admin@gitbacker.local
Password: $ADMIN_PASSWORD

Store this securely and delete this file.
CREDS
  chmod 600 .admin-credentials

  ok "Generated secrets and admin credentials"

  # --- Start ---

  info "Pulling images (this may take a minute)..."
  VERSION="$VERSION" docker compose pull --quiet </dev/null

  info "Starting Gitbacker..."
  VERSION="$VERSION" docker compose up -d </dev/null

  # --- Seed admin ---

  wait_for_healthy "http://localhost:8000/api/health"

  info "Creating admin account..."
  docker compose exec -T -e ADMIN_PASSWORD="$ADMIN_PASSWORD" api python seed_admin.py

  ok "Gitbacker is running!"
  echo ""
  echo "  Open:     http://localhost:3000"
  echo "  Email:    admin@gitbacker.local"
  echo "  Password: $ADMIN_PASSWORD"
  echo ""
  echo "  Credentials saved to: $INSTALL_DIR/.admin-credentials"
  echo ""
  echo "  To stop:    cd $INSTALL_DIR && docker compose down"
  echo "  To update:  bash -c \"\$(curl -fsSL https://gitbacker.com/install.sh)\""
  echo ""
}

main "$@"
