#!/usr/bin/env bash
set -euo pipefail

#############################################
# BASIC VARS – EDIT THESE
#############################################
DOMAIN="example.com"              # e.g. example.com
MAIL_HOST="mail.${DOMAIN}"        # e.g. mail.example.com
ROUNDCUBE_DB_PASS="changeMeDB!"
DOVECOT_USER_PASS_PLAIN="ChangeMeMail!"
DKIM_SELECTOR="mail"              # e.g. "mail", "default", "2025"
DKIM_KEY_PATH="/var/lib/rspamd/dkim/${DOMAIN}.${DKIM_SELECTOR}.key"
PHP_FPM_SOCK="/run/php/php-fpm.sock"
#############################################

log() {
  echo "==> $*"
}

section() {
  echo
  echo "============================================================"
  echo " $*"
  echo "============================================================"
}

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

section "1) Hostname and base packages"

log "Setting hostname to ${MAIL_HOST}"
hostnamectl set-hostname "${MAIL_HOST}"

log "Updating apt and installing mail/web packages..."
apt update
DEBIAN_FRONTEND=noninteractive apt install -y \
  postfix postfix-pcre dovecot-imapd dovecot-lmtpd dovecot-core \
  rspamd clamav-daemon mariadb-server nginx php-fpm php-mbstring php-xml php-intl \
  php-mysql php-gd php-curl php-zip php-ldap php-imap roundcube roundcube-core \
  roundcube-plugins roundcube-mysql certbot python3-certbot-nginx

section "2) vmail user and maildir base"

log "Ensuring vmail group (gid 5000) exists..."
if ! getent group vmail >/dev/null; then
  groupadd -g 5000 vmail
fi

log "Ensuring vmail user (uid 5000) exists..."
if ! id vmail >/dev/null 2>&1; then
  useradd -g vmail -u 5000 vmail -d /var/mail/vmail -m
fi

log "Creating /var/mail/vmail and fixing permissions..."
mkdir -p /var/mail/vmail
chown -R vmail:vmail /var/mail/vmail
chmod 750 /var/mail/vmail

section "3) MariaDB for Roundcube"

log "Creating Roundcube database and user..."
mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS roundcube CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'roundcube'@'localhost' IDENTIFIED BY '${ROUNDCUBE_DB_PASS}';
GRANT ALL PRIVILEGES ON roundcube.* TO 'roundcube'@'localhost';
FLUSH PRIVILEGES;
SQL
log "MariaDB for Roundcube configured."

section "4) Roundcube config"

log "Writing /etc/roundcube/config.inc.php ..."
cat > /etc/roundcube/config.inc.php <<EOF
<?php
\$config['db_dsnw'] = 'mysql://roundcube:${ROUNDCUBE_DB_PASS}@localhost/roundcube';

\$config['default_host'] = 'ssl://${MAIL_HOST}';
\$config['default_port'] = 993;

\$config['smtp_server'] = 'tls://${MAIL_HOST}';
\$config['smtp_port']   = 587;
\$config['smtp_user']   = '%u';
\$config['smtp_pass']   = '%p';
EOF
log "Roundcube configured to talk to IMAP ${MAIL_HOST}:993 and SMTP ${MAIL_HOST}:587."

section "5) Configuring Dovecot (IMAP + LMTP + virtual users)"

log "Writing /etc/dovecot/dovecot.conf ..."
cat > /etc/dovecot/dovecot.conf <<'EOF'
protocols = imap lmtp
listen = *
auth_mechanisms = plain login
!include conf.d/*.conf
!include_try local.conf
EOF

log "Writing /etc/dovecot/conf.d/10-mail.conf ..."
cat > /etc/dovecot/conf.d/10-mail.conf <<'EOF'
mail_location = maildir:/var/mail/vmail/%d/%n
mail_uid = vmail
mail_gid = vmail
EOF

log "Creating sample virtual users in /etc/dovecot/passwd ..."
cat > /etc/dovecot/passwd <<EOF
admin@${DOMAIN}:{PLAIN}${DOVECOT_USER_PASS_PLAIN}
info@${DOMAIN}:{PLAIN}${DOVECOT_USER_PASS_PLAIN}
EOF
chown root:dovecot /etc/dovecot/passwd
chmod 640 /etc/dovecot/passwd
log "Dovecot password file ready."

log "Writing /etc/dovecot/conf.d/auth-passwdfile.conf.ext ..."
cat > /etc/dovecot/conf.d/auth-passwdfile.conf.ext <<'EOF'
passdb {
  driver = passwd-file
  args = scheme=PLAIN username_format=%u /etc/dovecot/passwd
}

userdb {
  driver = static
  args = uid=vmail gid=vmail home=/var/mail/vmail/%d/%n
}
EOF

log "Enabling passwd-file auth in /etc/dovecot/conf.d/10-auth.conf ..."
sed -i 's/^!include auth-system.conf.ext/#!include auth-system.conf.ext/' /etc/dovecot/conf.d/10-auth.conf
if ! grep -q 'auth-passwdfile.conf.ext' /etc/dovecot/conf.d/10-auth.conf; then
  echo '!include auth-passwdfile.conf.ext' >> /etc/dovecot/conf.d/10-auth.conf
fi

log "Writing /etc/dovecot/conf.d/10-master.conf for LMTP + Postfix auth ..."
cat > /etc/dovecot/conf.d/10-master.conf <<'EOF'
service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}

service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
  user = dovecot
}
EOF

log "Writing /etc/dovecot/conf.d/10-ssl.conf (expects LE certs)..."
cat > /etc/dovecot/conf.d/10-ssl.conf <<EOF
ssl = required
ssl_cert = </etc/letsencrypt/live/${MAIL_HOST}/fullchain.pem
ssl_key  = </etc/letsencrypt/live/${MAIL_HOST}/privkey.pem
EOF

log "Restarting Dovecot..."
systemctl restart dovecot
log "Dovecot is configured."

section "6) Configuring Postfix (virtual, LMTP to Dovecot, submission, Rspamd)"

log "Writing /etc/postfix/main.cf ..."
cat > /etc/postfix/main.cf <<EOF
myhostname = ${MAIL_HOST}
mydomain = ${DOMAIN}
myorigin = \$mydomain

mydestination = localhost
virtual_mailbox_domains = ${DOMAIN}
virtual_mailbox_base = /var/mail/vmail
virtual_mailbox_maps = hash:/etc/postfix/vmailbox
virtual_transport = lmtp:unix:private/dovecot-lmtp

inet_interfaces = all
inet_protocols = ipv4
smtpd_banner = \$myhostname ESMTP

smtpd_tls_cert_file = /etc/letsencrypt/live/${MAIL_HOST}/fullchain.pem
smtpd_tls_key_file  = /etc/letsencrypt/live/${MAIL_HOST}/privkey.pem
smtpd_tls_security_level = may
smtp_tls_security_level  = may
smtpd_tls_auth_only = yes

smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_auth_enable = yes

smtpd_recipient_restrictions =
    permit_sasl_authenticated,
    reject_unauth_destination

relay_domains =

milter_default_action = accept
milter_protocol = 6
smtpd_milters = inet:127.0.0.1:11332
non_smtpd_milters = inet:127.0.0.1:11332
EOF

log "Ensuring submission service in /etc/postfix/master.cf ..."
if ! grep -q "^submission " /etc/postfix/master.cf; then
cat >> /etc/postfix/master.cf <<'EOF'

submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
EOF
fi

log "Writing /etc/postfix/vmailbox (sample boxes)..."
cat > /etc/postfix/vmailbox <<EOF
admin@${DOMAIN}   ${DOMAIN}/admin/
info@${DOMAIN}    ${DOMAIN}/info/
EOF

log "Running postmap on /etc/postfix/vmailbox ..."
postmap /etc/postfix/vmailbox

log "Restarting Postfix..."
systemctl restart postfix
log "Postfix is configured."

section "7) Creating maildirs for sample users"

log "Creating /var/mail/vmail/${DOMAIN}/admin and /var/mail/vmail/${DOMAIN}/info ..."
mkdir -p /var/mail/vmail/${DOMAIN}/admin
mkdir -p /var/mail/vmail/${DOMAIN}/info
chown -R vmail:vmail /var/mail/vmail/${DOMAIN}
chmod -R 700 /var/mail/vmail/${DOMAIN}
log "Maildirs created."

section "8) Nginx vhost for Roundcube"

log "Writing /etc/nginx/sites-available/${MAIL_HOST} ..."
cat > /etc/nginx/sites-available/${MAIL_HOST} <<EOF
server {
    listen 443 ssl http2;
    server_name ${MAIL_HOST};

    ssl_certificate     /etc/letsencrypt/live/${MAIL_HOST}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${MAIL_HOST}/privkey.pem;

    root /var/lib/roundcube;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_FPM_SOCK};
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico)$ {
        expires max;
        log_not_found off;
    }
}

server {
    listen 80;
    server_name ${MAIL_HOST};
    return 301 https://\$host\$request_uri;
}
EOF

log "Enabling nginx site..."
ln -sf /etc/nginx/sites-available/${MAIL_HOST} /etc/nginx/sites-enabled/${MAIL_HOST}

log "Testing nginx config..."
nginx -t

log "Reloading nginx..."
systemctl reload nginx
log "Nginx vhost for Roundcube is ready."

section "9) Rspamd / DKIM"

log "Creating /var/lib/rspamd/dkim ..."
mkdir -p /var/lib/rspamd/dkim

if [[ ! -f "${DKIM_KEY_PATH}" ]]; then
  log "Creating placeholder DKIM key file at ${DKIM_KEY_PATH} (paste your key here)..."
  echo "# paste your DKIM private key here" > "${DKIM_KEY_PATH}"
  chown _rspamd:_rspamd "${DKIM_KEY_PATH}"
  chmod 600 "${DKIM_KEY_PATH}"
else
  log "DKIM key file already exists at ${DKIM_KEY_PATH}"
fi

log "Writing /etc/rspamd/local.d/dkim_signing.conf ..."
cat > /etc/rspamd/local.d/dkim_signing.conf <<EOF
domain {
    ${DOMAIN} {
        selector = "${DKIM_SELECTOR}";
        path = "${DKIM_KEY_PATH}";
    }
}

allow_users = ["*"];
sign_authenticated = true;
sign_local = true;
use_domain = "header";
use_esld = false;
EOF

log "Restarting rspamd..."
systemctl restart rspamd
log "Rspamd/DKIM configured."

section "10) Final restarts and notes"

log "Restarting main services just to be safe..."
systemctl restart dovecot
systemctl restart postfix
systemctl restart php*-fpm || true
systemctl restart nginx

echo
echo "============================================================"
echo " DONE"
echo "============================================================"
echo "Domain:            ${DOMAIN}"
echo "Mail host:         ${MAIL_HOST}"
echo "Roundcube URL:     https://${MAIL_HOST}"
echo "IMAP:              ${MAIL_HOST}:993 (SSL)"
echo "SMTP submission:   ${MAIL_HOST}:587 (STARTTLS)"
echo
echo "Users created:"
echo "  admin@${DOMAIN}"
echo "  info@${DOMAIN}"
echo "Password (both):   ${DOVECOT_USER_PASS_PLAIN}"
echo
echo "IMPORTANT:"
echo "1) You MUST have LE certs at: /etc/letsencrypt/live/${MAIL_HOST}/"
echo "   If not, run: certbot certonly --manual --preferred-challenges dns -d ${MAIL_HOST}"
echo "2) Paste your REAL DKIM private key into: ${DKIM_KEY_PATH}"
echo "3) Then: systemctl restart rspamd postfix dovecot nginx"
echo
