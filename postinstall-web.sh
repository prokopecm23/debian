#!/usr/bin/env bash
# Apache web server configuration for Debian 12. Runs inside the new system
# at the end of the install (also safe to run by hand: sudo bash postinstall-web.sh).
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }

# ---------- Apache ----------
echo 'ServerName lx-server' > /etc/apache2/conf-available/servername.conf
a2enconf servername

cat > /var/www/html/index.html <<'HTML'
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>LX-SERVER</title></head>
<body>
  <h1>LX-SERVER</h1>
  <p>Apache on Debian 12 is working behind the router.</p>
</body>
</html>
HTML

# ---------- SSH hardening ----------
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'CONF'
PermitRootLogin no
MaxAuthTries 3
X11Forwarding no
CONF

# ---------- Enable services (they start on first boot) ----------
systemctl enable ssh apache2

# ---------- Apply now (only when run on a live system, not in the installer) ----------
if [[ -d /run/systemd/system ]]; then
    systemctl restart apache2 ssh
    echo "Web server configured and restarted."
else
    echo "Config written (installer chroot). Everything starts on first boot."
fi
