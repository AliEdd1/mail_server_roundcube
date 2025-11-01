# Self-Hosted Mail Stack (Postfix + Dovecot + Rspamd + Roundcube + Nginx)

This repo contains a Bash script that provisions a minimal mail server on a Debian/Ubuntu-like system:

- **Postfix** (SMTP, submission)
- **Dovecot** (IMAP, LMTP, virtual maildirs)
- **Rspamd** (spam, DKIM signing)
- **MariaDB** (for Roundcube)
- **Roundcube** (webmail)
- **Nginx** (TLS terminator for Roundcube)
- **Let’s Encrypt** paths pre-wired

It’s based on real, working manual steps, rewritten to be repeatable.

---

## 1. What it does

1. sets the hostname to `mail.YOURDOMAIN`
2. installs all required packages
3. creates a `vmail` system user (uid/gid 5000)
4. configures Dovecot to use virtual Maildir under `/var/mail/vmail/%d/%n`
5. creates users `admin@domain` and `info@domain` in `/etc/dovecot/passwd`
6. configures Postfix for **virtual mailboxes** and LMTP to Dovecot
7. wires Postfix to **Rspamd** using milter
8. prepares **Roundcube** with MariaDB backend
9. creates Nginx vhost for `https://mail.domain`
10. creates maildirs and sets permissions

---

## 2. Requirements

- Fresh Debian/Ubuntu server
- A real domain, e.g. `manatsp.ir`
- DNS A record: `mail.manatsp.ir -> your_server_ip`
- Let’s Encrypt certificate present (or you run `certbot` yourself)
- Port 80/443/25/587/993 open

---

## 3. Usage

```bash
git clone https://github.com/your-user/your-mail-repo.git
cd your-mail-repo
sudo bash install-mailstack.sh
