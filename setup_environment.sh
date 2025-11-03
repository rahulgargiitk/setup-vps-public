#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

ensure_line_in_file() {
  local file=$1
  local line=$2
  if [[ ! -f "$file" ]]; then
    touch "$file"
  fi
  if ! grep -Fqx "$line" "$file"; then
    printf '%s\n' "$line" >>"$file"
  fi
}

ensure_path_exports() {
  local file=$1
  ensure_line_in_file "$file" 'export PATH="$HOME/.config/composer/vendor/bin:$PATH"'
  ensure_line_in_file "$file" 'export PATH="$HOME/.npm-global/bin:$PATH"'
}

ensure_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "[ERROR] This script must be run as root." >&2
    exit 1
  fi
}

apt_update() {
  log "Updating apt package lists..."
  apt-get update -y
}

install_packages() {
  local packages=("$@")
  local install_list=()

  for pkg in "${packages[@]}"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      log "Package '$pkg' already installed; skipping."
      continue
    fi

    if apt-cache show "$pkg" >/dev/null 2>&1; then
      install_list+=("$pkg")
    else
      warn "Package '$pkg' not found in repositories; skipping."
    fi
  done

  if [[ "${#install_list[@]}" -gt 0 ]]; then
    log "Installing packages: ${install_list[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${install_list[@]}"
  else
    log "No new packages to install."
  fi
}

install_optional_package() {
  local pkg=$1
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    log "Package '$pkg' already installed; skipping."
    return
  fi
  if apt-cache show "$pkg" >/dev/null 2>&1; then
    log "Installing optional package: $pkg"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
  else
    warn "Optional package '$pkg' not available; skipped."
  fi
}

install_docker() {
  if dpkg -s docker.io >/dev/null 2>&1; then
    log "Docker already installed."
  else
    log "Installing docker.io..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io
  fi
  manage_service docker
}

install_mongodb() {
  if dpkg -s mongodb-org >/dev/null 2>&1; then
    log "MongoDB packages already installed."
    manage_service mongod
    return
  fi

  if [[ ! -f /etc/os-release ]]; then
    warn "Cannot detect distribution; skipping MongoDB installation."
    return
  fi

  # shellcheck disable=SC1091
  . /etc/os-release

  local distro="${ID,,}"
  local codename="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
  local version="7.0"
  local repo_file="/etc/apt/sources.list.d/mongodb-org-${version}.list"
  local keyring="/usr/share/keyrings/mongodb-org-${version}.gpg"
  local supported=false

  case "$distro" in
    ubuntu)
      case "$codename" in
        noble|jammy|focal|bionic) supported=true ;;
        *)
          warn "MongoDB repository not provided for Ubuntu codename '${codename}'. Skipping MongoDB installation."
          rm -f "$repo_file" "$keyring"
          return
          ;;
      esac
      ;;
    debian)
      case "$codename" in
        bookworm|bullseye) supported=true ;;
        *)
          warn "MongoDB repository not provided for Debian codename '${codename}'. Skipping MongoDB installation."
          rm -f "$repo_file" "$keyring"
          return
          ;;
      esac
      ;;
    *)
      warn "MongoDB automated install not supported on distribution '$distro'; skipping."
      return
      ;;
  esac

  if [[ "${supported}" != true ]]; then
    warn "MongoDB automated install not supported on ${distro} ${codename}; skipping."
    return
  fi

  if [[ -z "$codename" ]]; then
    warn "Unable to determine distribution codename; skipping MongoDB installation."
    return
  fi

  if [[ ! -f "$repo_file" ]]; then
    log "Adding MongoDB ${version} repository for ${distro} ${codename}."
    install -d "$(dirname "$keyring")"
    if ! curl -fsSL "https://pgp.mongodb.com/server-${version}.asc" | gpg --dearmor -o "$keyring"; then
      warn "Failed to download MongoDB GPG key; skipping MongoDB installation."
      rm -f "$keyring"
      return
    fi
    echo "deb [ signed-by=${keyring} ] https://repo.mongodb.org/apt/${distro} ${codename}/mongodb-org/${version} multiverse" >"$repo_file"
  fi

  if ! apt-get update -y; then
    warn "apt-get update failed after adding MongoDB repo; skipping MongoDB installation."
    return
  fi

  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y mongodb-org; then
    warn "Failed to install MongoDB packages from official repository."
    return
  fi

  manage_service mongod
}

install_laravel_cli() {
  local user=$1

  if ! command -v composer >/dev/null 2>&1; then
    warn "Composer not installed; skipping Laravel installer setup for user '$user'."
    return
  fi

  if [[ "$user" != "root" ]] && ! id "$user" >/dev/null 2>&1; then
    warn "User '$user' does not exist; skipping Laravel installer setup."
    return
  fi

  if [[ "$user" == "root" ]]; then
    if composer global show laravel/installer >/dev/null 2>&1; then
      log "Laravel installer already present for user '$user'."
    else
      log "Installing Laravel installer for user '$user'."
      composer global require laravel/installer || warn "Failed to install Laravel installer for user '$user'."
    fi
    return
  fi

  if sudo -u "$user" -H bash -lc 'composer global show laravel/installer >/dev/null 2>&1'; then
    log "Laravel installer already present for user '$user'."
  else
    log "Installing Laravel installer for user '$user'."
    sudo -u "$user" -H bash -lc 'composer global require laravel/installer' || warn "Failed to install Laravel installer for user '$user'."
  fi
}

install_npm_global() {
  local user=$1
  local package=$2
  local label=${3:-$package}

  if ! command -v npm >/dev/null 2>&1; then
    warn "npm not installed; skipping npm package '$label'."
    return 1
  fi

  if [[ "$user" != "root" ]] && ! id "$user" >/dev/null 2>&1; then
    warn "User '$user' not found; skipping npm package '$label'."
    return 1
  fi

  local npm_cmd
  if [[ "$user" == "root" ]]; then
    npm_cmd=(npm)
  else
    npm_cmd=(sudo -u "$user" -H npm)
  fi

  if "${npm_cmd[@]}" list -g "$package" --depth=0 >/dev/null 2>&1; then
    log "npm package '$label' already installed globally for user '$user'."
    return 0
  fi

  log "Installing npm package '$label' globally for user '$user'."
  if ! "${npm_cmd[@]}" install -g "$package" >/dev/null 2>&1; then
    warn "Failed to install npm package '$label' for user '$user'."
    return 1
  fi

  return 0
}

install_frontend_tooling() {
  log "Installing TanStack Start and Mantine scaffolding CLIs."
  install_npm_global root create-tanstack-app "create-tanstack-app (TanStack Start scaffolder)"
  install_npm_global root create-mantine-app "create-mantine-app (Mantine project scaffolder)"

  if id rahul >/dev/null 2>&1; then
    install_npm_global rahul create-tanstack-app "create-tanstack-app (TanStack Start scaffolder)"
    install_npm_global rahul create-mantine-app "create-mantine-app (Mantine project scaffolder)"
  fi
}

configure_npm_prefix_for_user() {
  local user=$1

  if ! command -v npm >/dev/null 2>&1; then
    warn "npm not installed; skipping npm prefix configuration for '$user'."
    return
  fi

  if [[ "$user" != "root" ]] && ! id "$user" >/dev/null 2>&1; then
    warn "User '$user' not found; skipping npm prefix configuration."
    return
  fi

  local home_dir
  home_dir=$(getent passwd "$user" | cut -d: -f6)
  if [[ -z "$home_dir" ]]; then
    warn "Unable to determine home directory for user '$user'; skipping npm prefix configuration."
    return
  fi

  local npm_dir="$home_dir/.npm-global"
  mkdir -p "$npm_dir"
  chown "$user:$user" "$npm_dir" >/dev/null 2>&1 || true

  log "Configuring npm global prefix for user '$user'."
  if [[ "$user" == "root" ]]; then
    npm config set prefix "$npm_dir" >/dev/null 2>&1 || warn "Failed to configure npm prefix for '$user'."
  else
    sudo -u "$user" -H npm config set prefix "$HOME/.npm-global" >/dev/null 2>&1 || warn "Failed to configure npm prefix for '$user'."
  fi
}

configure_firewall() {
  if ! command -v ufw >/dev/null 2>&1; then
    warn "ufw not installed; skipping firewall configuration."
    return
  fi

  log "Applying UFW firewall policy and SSH whitelist."
  ufw default deny incoming
  ufw default allow outgoing
  local whitelist_ips=(
    45.122.120.72
    115.241.91.27
    150.129.237.38
  )

  for ip in "${whitelist_ips[@]}"; do
    ufw --force allow from "$ip" to any port 22 proto tcp
  done
  local open_ports=(80 443 2222 3000 8000)
  for port in "${open_ports[@]}"; do
    ufw --force allow "${port}/tcp"
  done

  if ufw status | grep -q "Status: inactive"; then
    log "Enabling UFW firewall."
    ufw --force enable
  else
    log "Reloading UFW firewall to apply rules."
    ufw reload
  fi
}

configure_sysctl() {
  local sysctl_file="/etc/sysctl.d/99-custom.conf"
  local tmp_file

  tmp_file=$(mktemp)
  cat <<'EOF' >"$tmp_file"
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF

  if [[ -f "$sysctl_file" ]] && cmp -s "$tmp_file" "$sysctl_file"; then
    rm -f "$tmp_file"
    log "Sysctl settings already configured."
  else
    install -m 0644 "$tmp_file" "$sysctl_file"
    rm -f "$tmp_file"
    if ! sysctl -p "$sysctl_file" >/dev/null 2>&1; then
      warn "Failed to apply sysctl settings from $sysctl_file."
    else
      log "Sysctl settings applied from $sysctl_file."
    fi
  fi
}

configure_mysql_memory() {
  local conf_dir="/etc/mysql/mysql.conf.d"
  local conf_file="${conf_dir}/zz-custom-memory.cnf"

  if [[ ! -d "$conf_dir" ]]; then
    warn "MySQL configuration directory '${conf_dir}' not found; skipping memory tuning."
    return
  fi

  local tmp_file
  tmp_file=$(mktemp)
  cat <<'EOF' >"$tmp_file"
[mysqld]
innodb_buffer_pool_size = 128M
innodb_log_file_size = 64M
innodb_buffer_pool_instances = 1
max_connections = 75
tmp_table_size = 32M
max_heap_table_size = 32M
table_open_cache = 256
thread_cache_size = 32
performance_schema = OFF
EOF

  install -m 0644 "$tmp_file" "$conf_file"
  rm -f "$tmp_file"
  log "MySQL memory tuning applied at ${conf_file}. Restart MySQL when ready to use it."
}

ensure_swap() {
  local swap_file="/swapfile"
  local swap_size_gb=3
  local swap_size_bytes=$((swap_size_gb * 1024 * 1024 * 1024))

  if swapon --show=NAME | grep -Fxq "$swap_file"; then
    log "Swap file ${swap_file} already active."
    return
  fi

  if [[ -f "$swap_file" ]]; then
    log "Swap file ${swap_file} already exists but inactive. Reinitializing."
  else
    log "Creating ${swap_size_gb}G swap file at ${swap_file}."
    fallocate -l "$swap_size_bytes" "$swap_file" || dd if=/dev/zero of="$swap_file" bs=1M count=$((swap_size_gb * 1024))
  fi

  chmod 600 "$swap_file"
  mkswap "$swap_file"
  swapon "$swap_file"

  if ! grep -q "^${swap_file}" /etc/fstab; then
    log "Persisting swap file in /etc/fstab."
    printf '%s none swap sw 0 0\n' "$swap_file" >> /etc/fstab
  fi
}

stop_and_disable_service() {
  local svc=$1
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl not available; cannot stop service '$svc'."
    return
  fi
  if ! systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
    warn "Service '${svc}.service' not found; skipping stop/disable."
    return
  fi
  if systemctl is-active "$svc" >/dev/null 2>&1; then
    systemctl stop "$svc" >/dev/null 2>&1 || warn "Failed to stop service '$svc'."
  else
    log "Service '$svc' already inactive."
  fi
  if systemctl is-enabled "$svc" >/dev/null 2>&1; then
    systemctl disable "$svc" >/dev/null 2>&1 || warn "Failed to disable service '$svc'."
  else
    log "Service '$svc' already disabled."
  fi
  if systemctl is-active "$svc" >/dev/null 2>&1; then
    warn "Service '$svc' is still active; manual intervention may be required."
  else
    log "Service '$svc' now inactive and disabled."
  fi
}

manage_service() {
  local svc=$1
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl not available; cannot manage service '$svc'."
    return
  fi
  if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
    systemctl enable "$svc" >/dev/null 2>&1 || warn "Failed to enable service '$svc'."
    systemctl start "$svc" >/dev/null 2>&1 || warn "Failed to start service '$svc'."
    log "Service '$svc' enabled and started."
  else
    warn "Service '${svc}.service' not found; skipping."
  fi
}

set_timezone() {
  local tz=$1
  if command -v timedatectl >/dev/null 2>&1; then
    log "Setting system timezone to ${tz}..."
    timedatectl set-timezone "$tz"
  else
    warn "timedatectl not available; skipping timezone configuration."
  fi
}

ensure_user() {
  local user=$1
  local shell_path

  shell_path=$(command -v zsh || echo "/usr/bin/zsh")

  if id "$user" >/dev/null 2>&1; then
    log "User '$user' already exists."
    usermod -s "$shell_path" "$user"
  else
    log "Creating user '$user' with home directory and zsh shell."
    useradd -m -s "$shell_path" "$user"
  fi

  usermod -aG sudo "$user"

  local home_dir
  home_dir=$(getent passwd "$user" | cut -d: -f6)
  if [[ -n "$home_dir" && ! -d "$home_dir" ]]; then
    log "Creating missing home directory for '$user' at $home_dir."
    mkdir -p "$home_dir"
    chown "$user:$user" "$home_dir"
  fi
}

configure_shell_for_user() {
  local user=$1
  local home_dir
  home_dir=$(getent passwd "$user" | cut -d: -f6)

  if [[ -z "$home_dir" ]]; then
    warn "Unable to determine home directory for user '$user'; skipping shell configuration."
    return
  fi

  if [[ ! -d "$home_dir/.oh-my-zsh" ]]; then
    log "Installing Oh My Zsh for user '$user'."
    if [[ "$user" == "root" ]]; then
      RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    else
      sudo -u "$user" -H bash -lc 'RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"'
    fi
  else
    log "Oh My Zsh already installed for user '$user'."
  fi

  local custom_dir="$home_dir/.oh-my-zsh/custom"
  if [[ "$user" == "root" ]]; then
    mkdir -p "$custom_dir/plugins"
    if [[ ! -d "$custom_dir/plugins/zsh-autosuggestions" ]]; then
      git clone https://github.com/zsh-users/zsh-autosuggestions "$custom_dir/plugins/zsh-autosuggestions"
    fi
    if [[ ! -d "$custom_dir/plugins/zsh-syntax-highlighting" ]]; then
      git clone https://github.com/zsh-users/zsh-syntax-highlighting "$custom_dir/plugins/zsh-syntax-highlighting"
    fi

    if [[ ! -f "$home_dir/.zshrc" ]]; then
      cp "$home_dir/.oh-my-zsh/templates/zshrc.zsh-template" "$home_dir/.zshrc"
    fi

    if grep -q "^plugins=" "$home_dir/.zshrc"; then
      sed -i 's/^plugins=.*/plugins=(git z fzf zsh-autosuggestions zsh-syntax-highlighting)/' "$home_dir/.zshrc"
    else
      printf '\nplugins=(git z fzf zsh-autosuggestions zsh-syntax-highlighting)\n' >>"$home_dir/.zshrc"
    fi
  else
    sudo -u "$user" -H bash -lc '
      mkdir -p ~/.oh-my-zsh/custom/plugins
      if [ ! -d ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions ]; then
        git clone https://github.com/zsh-users/zsh-autosuggestions ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions
      fi
      if [ ! -d ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting ]; then
        git clone https://github.com/zsh-users/zsh-syntax-highlighting ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting
      fi
      if [ ! -f ~/.zshrc ]; then
        cp ~/.oh-my-zsh/templates/zshrc.zsh-template ~/.zshrc
      fi
      if grep -q "^plugins=" ~/.zshrc; then
        sed -i "s/^plugins=.*/plugins=(git z fzf zsh-autosuggestions zsh-syntax-highlighting)/" ~/.zshrc
      else
        printf "\nplugins=(git z fzf zsh-autosuggestions zsh-syntax-highlighting)\n" >> ~/.zshrc
      fi
    '
  fi

  ensure_path_exports "$home_dir/.zshrc"

  local shell_path
  shell_path=$(command -v zsh || echo "/usr/bin/zsh")

  chsh -s "$shell_path" "$user" >/dev/null 2>&1 || warn "Failed to set default shell for '$user'."
}

main() {
  ensure_root

  local packages=(
    zsh
    sudo
    curl
    php-cli
    php-mbstring
    php-xml
    php-curl
    php-zip
    unzip
    composer
    nodejs
    npm
    gnupg
    git
    mc
    screen
    tmux
    ncdu
    nmap
    sqlite3
    lynx
    fzf
    z
    sshpass
    yt-dlp
    ffmpeg
    ctop
    glances
    htop
    links
    zip
    tar
    mlocate
    ufw
    fail2ban
    docker-compose-plugin
    rsync
    bash-completion
    mysql-server
    mysql-client
  )

  apt_update
  install_packages "${packages[@]}"
  install_optional_package ntop
  install_optional_package zsh-completions
  install_docker
  install_mongodb
  configure_firewall

  manage_service fail2ban

  set_timezone "Asia/Kolkata"

  ensure_user "rahul"
  configure_npm_prefix_for_user "root"
  configure_npm_prefix_for_user "rahul"
  install_frontend_tooling
  configure_shell_for_user "root"
  configure_shell_for_user "rahul"
  install_laravel_cli "root"
  install_laravel_cli "rahul"
  configure_mysql_memory
  stop_and_disable_service mysql
  ensure_swap
  configure_sysctl

  log "Setup complete."
}

main "$@"
