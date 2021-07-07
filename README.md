# HomeLab
### Desktop
```
sudo apt-get update && sudo apt-get upgrade -y && sudo apt-get dist-upgrade -y && sudo apt-get autoremove -y && flatpak update -y

git merge --no-ff develop
git merge --no-ff production

scp -r /home/arthur/vmware windowsBackup@10.0.0.7:/backup/Virtual_Machine_Backup/vmware

7z a -t7z -m0=lzma2 -mx=9 -mfb=128 -md=256m -ms=on archive.7z FOLDER

https://ohmyz.sh/
sudo apt-get install zsh-autosuggestions zsh-syntax-highlighting autojump

sudo usermod -s /usr/bin/zsh $(whoami)

omz update

```

## NAS
```
sudo apt-get install luckybackup
sudo apt-get autopurge ubuntu-advantage-tools

sudo gsettings set org.gnome.Vino require-encryption false

sudo journalctl --vacuum-time=1s && sudo journalctl --rotate --vacuum-size=5000M

sudo service apache2 restart

sudo systemctl start  gdm3
sudo systemctl stop  gdm3
```

#### Logging
```
journalctl --disk-usage
sudo journalctl --rotate
sudo journalctl --vacuum-time=2days
sudo journalctl --vacuum-files=5
sudo nano /etc/systemd/journald.conf
sudo rm /etc/systemd/journald.conf

sudo journalctl --vacuum-size=1M
sudo systemctl daemon-reload
```
#### Crontab
```
@reboot    sleep 25;  /home/arthur/docker/network.bash
@reboot    sleep 45;  mount /backup/Timeshift/Timeshift.img /media/arthur/Timeshift/
@reboot    sleep 600;  systemctl stop gdm
*/5 * * * * docker exec --user www-data nextcloud php -f cron.php
```

### ZFS
```
zfs send backup/File_Storage@2021.06.14-10.22.09 | ssh arthur@10.0.0.2 zfs receive -F backup/File_Storage

zfs send backup/Timeshift@2021.06.14-10.39.17    | ssh arthur@10.0.0.2 zfs receive -F backup/Timeshift

zfs send backup/WindowsBackup@2021.06.14-12.56.48	    | ssh arthur@10.0.0.2 zfs receive -F backup/WindowsBackup

zfs send backup/Virtual_Machine_Backup@2021.06.14-13.06.38	    | ssh arthur@10.0.0.2 zfs receive -F backup/Virtual_Machine_Backup
```
### Docker
```
sudo rm docker-compose.yaml && sudo nano docker-compose.yaml
sudo rm docker-compose.yaml && nano docker-compose.yaml
docker system prune -a
docker image prune -a
docker kill $(docker ps -q)
docker-compose down
docker-compose pull
sudo docker-compose --compatibility up --detach  --remove-orphans
```
##### Docker MacVlan Network Creation & Routing
```
docker network create -d macvlan \
--subnet=10.0.0.0/24 \
--ip-range=10.0.0.15/28 \
--gateway=10.0.0.1 \
-o parent=enp1s0 dockerBridge

sudo ip link add macvlan0 link enp1s0 type macvlan mode bridge
sudo ip link set dev macvlan0 up
sudo ip addr add 10.0.0.100/24 dev macvlan0
sudo ip route add 10.0.0.4 dev macvlan0
sudo ip route add 10.0.0.5 dev macvlan0
sudo ip route add 10.0.0.6 dev macvlan0
sudo ip route add 10.0.0.9 dev macvlan0

sudo chmod +x  network.bash
```
 
### SSL

```
sudo apt install certbot python3-certbot-apache 

sudo certbot --agree-tos -d server.arthurvardevanyan.com --manual --preferred-challenges dns certonly
cp -r /etc/letsencrypt/live/server.arthurvardevanyan.com/ /backup/Timeshift/letsencrypt/server.arthurvardevanyan.com
```

### Cockpit Cert
```
sudo su

rm /etc/cockpit/ws-certs.d/1-my-cert.cert
cat  /etc/letsencrypt/live/server.arthurvardevanyan.com/fullchain.pem >> /etc/cockpit/ws-certs.d/1-my-cert.cert
cat  /etc/letsencrypt/live/server.arthurvardevanyan.com/privkey.pem >> /etc/cockpit/ws-certs.d/1-my-cert.cert
systemctl restart cockpit.socket
```
### GitLab
```
gitlab-ctl registry-garbage-collect
gitlab-ctl reconfigure

sudo certbot --agree-tos -d gitlab.arthurvardevanyan.com --manual --preferred-challenges dns certonly

rm -rf /docker/gitlab/config/ssl/gitlab.arthurvardevanyan.com*
mkdir /home/arthur/docker/gitlab/config/ssl/gitlab.arthurvardevanyan.com/
cat /etc/letsencrypt/live/gitlab.arthurvardevanyan.com/fullchain.pem >> /home/arthur/docker/gitlab/config/ssl/gitlab.arthurvardevanyan.com/fullchain.pem
cat /etc/letsencrypt/live/gitlab.arthurvardevanyan.com/privkey.pem   >> /home/arthur/docker/gitlab/config/ssl/gitlab.arthurvardevanyan.com/privkey.pem
cat /etc/letsencrypt/live/gitlab.arthurvardevanyan.com/fullchain.pem >> /home/arthur/docker/gitlab/config/ssl/gitlab.arthurvardevanyan.com.crt
cat /etc/letsencrypt/live/gitlab.arthurvardevanyan.com/privkey.pem   >> /home/arthur/docker/gitlab/config/ssl/gitlab.arthurvardevanyan.com.key
```

### Nextcloud
```
sudo -u www-data php occ delete:old

sudo -u www-data php occ files:scan-app-data
sudo -u www-data php occ maintenance:repair

sudo -u www-data php occ preview:delete_old
sudo -u www-data php occ preview:generate-all


sudo rm -r ~/docker/nextcloud/letsencrypt/
sudo cp -r /etc/letsencrypt/ ~/docker/nextcloud/
docker container restart nextcloud

sudo su


sudo docker exec nextcloud apt-get update
sudo docker exec nextcloud apt-get install -y libmagickcore-6.q16-6-extra
sudo nano /home/arthur/docker/nextcloud/nextcloud/.htaccess

RewriteRule ^.well-known/webfinger /nextcloud/index.php/.well-known/webfinger [R=301,L]
RewriteRule ^.well-known/nodeinfo /nextcloud/index.php/.well-known/nodeinfo [R=301,L]

docker container restart nextcloud

```

### Pi-Hole
```
git clone https://github.com/anudeepND/whitelist.git
apt-get update && apt-get install python3 -y
./whitelist/scripts/referral.sh

```
### Database
```
CREATE USER 'arthur'@'10.0.0.X' IDENTIFIED BY 'arthur'; 
SET PASSWORD FOR 'arthur'@'10.0.0.X' = PASSWORD('arthur');
GRANT ALL PRIVILEGES ON *.* TO `arthur`@`10.0.0.X`;

FLUSH PRIVILEGES;

% for everything


mysqldump -h 10.0.0.5 -u arthur -p FinanceTracker > FinanceTracker.sql
mysqldump -h 10.0.0.5 -u arthur -p spotify > spotify.sql
mysqldump -h 10.0.0.5 -u arthur -p nextcloud > nextcloud.sql

mysqldump -h 10.0.0.5 -u arthur -p  --all-databases > sever.sql
```
##### Database Dump & Log Rotate
```
mysqldump -h 10.0.0.5 -ubackup -pbackup  --all-databases > /home/arthur/docker/mariadb/backup/server/server.sql
mysqldump -h 10.0.0.5 -ubackup -pbackup  spotify         > /home/arthur/docker/mariadb/backup/spotify/spotify.sql
mysqldump -h 10.0.0.5 -ubackup -pbackup  nextcloud       > /home/arthur/docker/mariadb/backup/nextcloud/nextcloud.sql
mysqldump -h 10.0.0.5 -ubackup -pbackup  FinanceTracker  > /home/arthur/docker/mariadb/backup/FinanceTracker/FinanceTracker.sql

/etc/logrotate.d/mysqlbackup

/home/arthur/docker/mariadb/backup/*/*.sql {
    daily
    rotate 180
    compress
    delaycompress
    create 640 root backup
    dateext
    dateformat .%Y-%m-%dT%H:%M:%S
    postrotate
        /home/arthur/docker/mariadb/backup/databaseDump.sh
    endscript
}
```

