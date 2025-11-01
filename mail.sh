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

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

echo "[1/20] set hostname"
hostnamectl set-hostname "${MAIL_HOST}"

echo "[2/20] apt update & install packages"
apt update
DEBIAN_FRONTEND=noninteractive apt install -y \
  postfix postfix-pcre dovecot-imapd dovecot-lmtpd dovecot-core \
  rspamd clamav-daemon mariadb-server nginx php-fpm php-mbstring php-xml php-intl \
  php-mysql php-gd php-curl php-zip php-ldap php-imap roundcube roundcube-core \
  roundcube-plugins roundcube-mysql certbot python3-certbot-nginx

echo "[3/20] create vmail user"
if ! getent group vmail >/dev/null; then
  groupadd -g 5000 vmail
fi
if ! id vmail >/dev/null 2>&1; then
  useradd -g vmail -u 5000 vmail -d /var/mail/vmail -m
fi
mkdir -p /var/mail/vmail
chown -R vmail:vmail /var/mail/vmail
chmod 750 /var/mail/vmail

echo "[4/20] configure MariaDB for roundcube"
mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS roundcube CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'roundcube'@'localhost' IDENTIFIED BY '${ROUNDCUBE_DB_PASS}';
GRANT ALL PRIVILEGES ON roundcube.* TO 'roundcube'@'localhost';
FLUSH PRIVILEGES;
SQL

echo "[5/20] write roundcube config"
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

echo "[6/20] dovecot main config"
cat > /etc/dovecot/dovecot.conf <<'EOF'
protocols = imap lmtp
listen = *
auth_mechanisms = plain login
!include conf.d/*.conf
!include_try local.conf
EOF

echo "[7/20] dovecot mail location"
cat > /etc/dovecot/conf.d/10-mail.conf <<'EOF'
mail_location = maildir:/var/mail/vmail/%d/%n
mail_uid = vmail
mail_gid = vmail
EOF

echo "[8/20] dovecot passwd file (sample users)"
cat > /etc/dovecot/passwd <<EOF
admin@${DOMAIN}:{PLAIN}${DOVECOT_USER_PASS_PLAIN}
info@${DOMAIN}:{PLAIN}${DOVECOT_USER_PASS_PLAIN}
EOF
chown root:dovecot /etc/dovecot/passwd
chmod 640 /etc/dovecot/passwd

echo "[9/20] dovecot auth (passwd-file)"
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

echo "[10/20] dovecot 10-auth (disable system, enable passwd-file)"
sed -i 's/^!include auth-system.conf.ext/#!include auth-system.conf.ext/' /etc/dovecot/conf.d/10-auth.conf
if ! grep -q 'auth-passwdfile.conf.ext' /etc/dovecot/conf.d/10-auth.conf; then
  echo '!include auth-passwdfile.conf.ext' >> /etc/dovecot/conf.d/10-auth.conf
fi

echo "[11/20] dovecot master for postfix lmtp & auth"
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

echo "[12/20] dovecot ssl (Let’s Encrypt paths)"
cat > /etc/dovecot/conf.d/10-ssl.conf <<EOF
ssl = required
ssl_cert = </etc/letsencrypt/live/${MAIL_HOST}/fullchain.pem
ssl_key  = </etc/letsencrypt/live/${MAIL_HOST}/privkey.pem
EOF

echo "[13/20] postfix main.cf"
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

echo "[14/20] postfix master.cf (add submission if missing)"
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

echo "[15/20] postfix virtual mailbox file"
cat > /etc/postfix/vmailbox <<EOF
admin@${DOMAIN}   ${DOMAIN}/admin/
info@${DOMAIN}    ${DOMAIN}/info/
EOF
postmap /etc/postfix/vmailbox

echo "[16/20] create maildirs"
mkdir -p /var/mail/vmail/${DOMAIN}/admin
mkdir -p /var/mail/vmail/${DOMAIN}/info
chown -R vmail:vmail /var/mail/vmail/${DOMAIN}
chmod -R 700 /var/mail/vmail/${DOMAIN}

echo "[17/20] nginx for roundcube"
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

echo "[18/20] rspamd DKIM (placeholder)"
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

echo "[19/20] restart services"
systemctl restart dovecot
systemctl restart postfix
systemctl restart php*-fpm || true
systemctl restart nginx

echo "[20/20] done."

echo
echo "IMPORTANT:"
echo "1) Get cert:  certbot certonly --manual --preferred-challenges dns -d ${MAIL_HOST}"
echo "2) Paste real DKIM key into: ${DKIM_KEY_PATH}"
echo "3) Login to: https://${MAIL_HOST} with admin@${DOMAIN}"
echo
