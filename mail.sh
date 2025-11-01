#!/usr/bin/env bash
set -euo pipefail

# ============================================
# INTERACTIVE INPUT
# ============================================
read -rp "Enter base domain (e.g. example.com): " DOMAIN
read -rp "Enter mail hostname (e.g. mail.${DOMAIN}): " MAIL_HOST
MAIL_HOST=${MAIL_HOST:-mail.${DOMAIN}}

read -rp "Enter primary mail user (e.g. admin): " MAIL_USER
MAIL_USER=${MAIL_USER:-admin}

read -rp "Enter second mail user (optional, e.g. info) [press Enter to skip]: " MAIL_USER2
MAIL_USER2=${MAIL_USER2:-}

read -rsp "Enter password for mail users (IMAP/SMTP): " MAIL_PASS
echo
read -rsp "Enter Roundcube DB password: " ROUNDCUBE_DB_PASS
echo

# DKIM selector (can press enter)
read -rp "Enter DKIM selector (default: mail): " DKIM_SELECTOR
DKIM_SELECTOR=${DKIM_SELECTOR:-mail}

PHP_FPM_SOCK="/run/php/php-fpm.sock"
DKIM_KEY_PATH="/var/lib/rspamd/dkim/${DOMAIN}.${DKIM_SELECTOR}.key"

log() { echo "==> $*"; }
section() {
  echo; echo "============================================================"
  echo " $*"
  echo "============================================================"
}

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

# 1) hostname, packages
section "1) Hostname and packages"
log "Setting hostname to ${MAIL_HOST}"
hostnamectl set-hostname "${MAIL_HOST}"

log "Updating apt and installing required packages..."
apt update
DEBIAN_FRONTEND=noninteractive apt install -y \
  postfix postfix-pcre dovecot-imapd dovecot-lmtpd dovecot-core \
  rspamd clamav-daemon mariadb-server nginx php-fpm php-mbstring php-xml php-intl \
  php-mysql php-gd php-curl php-zip php-ldap php-imap roundcube roundcube-core \
  roundcube-plugins roundcube-mysql certbot python3-certbot-nginx

# 2) vmail
section "2) vmail user and maildir base"
log "Ensuring vmail user/group..."
getent group vmail >/dev/null || groupadd -g 5000 vmail
id vmail >/dev/null 2>&1 || useradd -g vmail -u 5000 vmail -d /var/mail/vmail -m
mkdir -p /var/mail/vmail
chown -R vmail:vmail /var/mail/vmail
chmod 750 /var/mail/vmail

# 3) MariaDB
section "3) MariaDB for Roundcube"
log "Creating database 'roundcube' and user 'roundcube'..."
mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS roundcube CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'roundcube'@'localhost' IDENTIFIED BY '${ROUNDCUBE_DB_PASS}';
GRANT ALL PRIVILEGES ON roundcube.* TO 'roundcube'@'localhost';
FLUSH PRIVILEGES;
SQL

# 4) Roundcube
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

# 5) Dovecot
section "5) Configuring Dovecot (IMAP/LMTP)"
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

log "Creating Dovecot passwd file from user input ..."
{
  echo "${MAIL_USER}@${DOMAIN}:{PLAIN}${MAIL_PASS}"
  if [[ -n "${MAIL_USER2}" ]]; then
    echo "${MAIL_USER2}@${DOMAIN}:{PLAIN}${MAIL_PASS}"
  fi
} > /etc/dovecot/passwd
chown root:dovecot /etc/dovecot/passwd
chmod 640 /etc/dovecot/passwd

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
grep -q 'auth-passwdfile.conf.ext' /etc/dovecot/conf.d/10-auth.conf || \
  echo '!include auth-passwdfile.conf.ext' >> /etc/dovecot/conf.d/10-auth.conf

log "Writing /etc/dovecot/conf.d/10-master.conf ..."
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

log "Writing /etc/dovecot/conf.d/10-ssl.conf ..."
cat > /etc/dovecot/conf.d/10-ssl.conf <<EOF
ssl = required
ssl_cert = </etc/letsencrypt/live/${MAIL_HOST}/fullchain.pem
ssl_key  = </etc/letsencrypt/live/${MAIL_HOST}/privkey.pem
EOF

log "Restarting Dovecot..."
systemctl restart dovecot

# 6) Postfix
section "6) Configuring Postfix"
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

log "Writing /etc/postfix/vmailbox ..."
{
  echo "${MAIL_USER}@${DOMAIN}   ${DOMAIN}/${MAIL_USER}/"
  if [[ -n "${MAIL_USER2}" ]]; then
    echo "${MAIL_USER2}@${DOMAIN}   ${DOMAIN}/${MAIL_USER2}/"
  fi
} > /etc/postfix/vmailbox

log "postmap /etc/postfix/vmailbox ..."
postmap /etc/postfix/vmailbox

log "Restarting Postfix..."
systemctl restart postfix

# 7) maildirs
section "7) Creating maildirs"
mkdir -p /var/mail/vmail/${DOMAIN}/${MAIL_USER}
if [[ -n "${MAIL_USER2}" ]]; then
  mkdir -p /var/mail/vmail/${DOMAIN}/${MAIL_USER2}
fi
chown -R vmail:vmail /var/mail/vmail/${DOMAIN}
chmod -R 700 /var/mail/vmail/${DOMAIN}

# 8) Nginx
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

ln -sf /etc/nginx/sites-available/${MAIL_HOST} /etc/nginx/sites-enabled/${MAIL_HOST}
nginx -t
systemctl reload nginx

# 9) rspamd / DKIM
section "9) Rspamd / DKIM"
mkdir -p /var/lib/rspamd/dkim
if [[ ! -f "${DKIM_KEY_PATH}" ]]; then
  echo "# paste your DKIM private key here" > "${DKIM_KEY_PATH}"
  chown _rspamd:_rspamd "${DKIM_KEY_PATH}"
  chmod 600 "${DKIM_KEY_PATH}"
fi

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

systemctl restart rspamd

# 10) final
section "10) Done"
echo "Domain:          ${DOMAIN}"
echo "Mail host:       ${MAIL_HOST}"
echo "Login 1:         ${MAIL_USER}@${DOMAIN}"
[[ -n "${MAIL_USER2}" ]] && echo "Login 2:         ${MAIL_USER2}@${DOMAIN}"
echo "Mail password:   (what you entered)"
echo
echo "IMPORTANT:"
echo " - You must have certs in /etc/letsencrypt/live/${MAIL_HOST}/"
echo " - Paste real DKIM into ${DKIM_KEY_PATH}"
echo " - Open https://${MAIL_HOST} for Roundcube"
