# setup_environment.sh Specification

## Overview

`setup_environment.sh` bootstraps a Debian/Ubuntu server with a pre-defined developer/ops stack. It installs command-line tools, configures Zsh and productivity plugins, prepares container tooling, enables security hardening, and provisions language runtimes plus frontend scaffolding utilities. The script is designed to be idempotent so it can be re-run safely.

## Requirements

- Run as `root` (directly or via `sudo`).
- Debian or Ubuntu distribution (MongoDB repository support limited to the codenames called out below).
- Internet access for apt repositories, GitHub clones, Composer, npm, and curl-based installers.

## Major Tasks

1. **System packages:** Installs core utilities (`zsh`, `curl`, `git`, `docker.io`, `docker-compose-plugin`, `ufw`, `fail2ban`, `rsync`, `bash-completion`, etc.), CLI tools (`fzf`, `ncdu`, `htop`, `glances`, `yt-dlp`, `ffmpeg`, …), database servers (`mysql-server`, `mysql-client`), and language/runtime dependencies (`php-cli`, Composer, Node.js, npm).
2. **Optional packages:** Attempts to install `ntop` and `zsh-completions` when available without failing the run if repositories lack them.
3. **Docker:** Installs `docker.io`, enables the service, and ensures it starts on boot.
4. **MongoDB:** Adds the official MongoDB 7.0 apt repository for supported Ubuntu (`bionic`, `focal`, `jammy`, `noble`) and Debian (`bullseye`, `bookworm`) releases, installs `mongodb-org`, and enables the `mongod` service. Unsupported codenames are skipped with a warning.
5. **MySQL:** Installs MySQL server/client, writes a low-memory config override (`/etc/mysql/mysql.conf.d/zz-custom-memory.cnf`), and leaves the `mysql` service stopped and disabled so memory usage stays low until manually started.
6. **Security hardening:**
   - Configures UFW with default deny inbound/allow outbound, whitelists SSH from `45.122.120.72`, and opens TCP ports `80`, `443`, `2222`, `3000`, and `8000`.
   - Enables and starts `fail2ban`.
   - Sets `vm.swappiness=10` and `vm.vfs_cache_pressure=50` in `/etc/sysctl.d/99-custom.conf`.
7. **Shell setup:**
   - Ensures Oh My Zsh and plugins (`z`, `fzf`, `zsh-autosuggestions`, `zsh-syntax-highlighting`) are installed for `root` and user `rahul`.
   - Appends `$HOME/.config/composer/vendor/bin` and `$HOME/.npm-global/bin` to `.zshrc` PATH.
8. **Users:** Creates user `rahul` (if missing), grants sudo, and aligns shell preferences.
9. **Composer & Laravel:** Installs Composer, then installs the Laravel installer globally for `root` and `rahul`.
10. **npm tooling:** Configures a per-user global npm prefix (`~/.npm-global`) and installs TanStack Start (`create-tanstack-app`) and Mantine (`create-mantine-app`) scaffolding CLIs for both users.
11. **Swap & timezone:** Creates a persistent 3 GB `/swapfile`, updates `/etc/fstab`, applies timezone `Asia/Kolkata`, and writes sysctl settings.

## Idempotency Notes

- Package installs skip already-installed items via `dpkg -s`.
- Oh My Zsh, Composer, npm global tools, and firewall rules are only applied if missing.
- Swap creation, sysctl configuration, MongoDB repo addition, and MySQL memory tuning rewrite files only when changes are needed.
- MySQL remains disabled after each run; start manually with `systemctl start mysql` when required.

## Post-Run Verification

After executing the script, consider verifying:

- `ufw status` shows expected rules and active status.
- `fail2ban-client status` reports the service running.
- `swapon --show` includes `/swapfile`.
- `sysctl vm.swappiness` and `sysctl vm.vfs_cache_pressure` reflect the tuned values.
- `echo $PATH` inside a new Zsh session for both `root` and `rahul` includes Composer and npm global bins.
- `mysql` is inactive (`systemctl status mysql`) unless you intentionally start it.
