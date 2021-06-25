# HomeLab


# Cockpit Cert
ln -s  /etc/letsencrypt/live/server.arthurvardevanyan.com/fullchain.pem >> /etc/cockpit/ws-certs.d/1-my-cert.cert
ln -s  /etc/letsencrypt/live/server.arthurvardevanyan.com/privkey.pem >> /etc/cockpit/ws-certs.d/1-my-cert.cert