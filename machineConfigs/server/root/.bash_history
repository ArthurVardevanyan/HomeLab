apt-get update
apt-get install sudo
nano /etc/sudoers
exit
/usr/bin/luckybackup -c --no-questions --skip-critical /root/.luckyBackup/profiles/default.profile > /root/.luckyBackup/logs/default-LastCronLog.log 2>&1
rm /etc/cockpit/ws-certs.d/1-my-cert.cert
cat  /etc/letsencrypt/live/arthurvardevanyan.com/fullchain.pem >> /etc/cockpit/ws-certs.d/1-my-cert.cert
cat  /etc/letsencrypt/live/arthurvardevanyan.com/privkey.pem >> /etc/cockpit/ws-certs.d/1-my-cert.cert