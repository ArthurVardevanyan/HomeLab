# HomeLab

## SSL

sudo certbot --agree-tos -d server.arthurvardevanyan.com --manual --preferred-challenges dns certonly
cp -r /etc/letsencrypt/live/server.arthurvardevanyan.com/ /backup/Timeshift/letsencrypt/server.arthurvardevanyan.com

### Cockpit Cert
ln -s  /etc/letsencrypt/live/server.arthurvardevanyan.com/fullchain.pem >> /etc/cockpit/ws-certs.d/1-my-cert.cert
ln -s  /etc/letsencrypt/live/server.arthurvardevanyan.com/privkey.pem >> /etc/cockpit/ws-certs.d/1-my-cert.cert

### GitLab
sudo certbot --agree-tos -d gitlab.arthurvardevanyan.com --manual --preferred-challenges dns certonly

rm -rf /docker/gitlab/config/ssl/gitlab.arthurvardevanyan.com*
mkdir /home/arthur/docker/gitlab/config/ssl/gitlab.arthurvardevanyan.com/

cat /etc/letsencrypt/live/gitlab.arthurvardevanyan.com/fullchain.pem >> /home/arthur/docker/gitlab/config/ssl/gitlab.arthurvardevanyan.com/fullchain.pem
cat /etc/letsencrypt/live/gitlab.arthurvardevanyan.com/privkey.pem   >> /home/arthur/docker/gitlab/config/ssl/gitlab.arthurvardevanyan.com/privkey.pem
cat /etc/letsencrypt/live/gitlab.arthurvardevanyan.com/fullchain.pem >> /home/arthur/docker/gitlab/config/ssl/gitlab.arthurvardevanyan.com.crt
cat /etc/letsencrypt/live/gitlab.arthurvardevanyan.com/privkey.pem   >> /home/arthur/docker/gitlab/config/ssl/gitlab.arthurvardevanyan.com.key

gitlab-ctl reconfigure

### GitLab Runner