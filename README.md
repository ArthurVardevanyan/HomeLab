# HomeLab

HomeLab Server & Desktop Configuration

- Server: Debian Stable /w K3s & ZFS
- Desktop: Pop!_OS Latest

  - Manual Patches Applied

    - <https://github.com/ArthurVardevanyan/pop-shell>
    - <https://github.com/ArthurVardevanyan/pop-cosmic>

## Desktop

```bash
git merge --no-ff develop
git merge --no-ff production

scp -r /home/arthur/vmware windowsBackup@10.0.0.3:/backup/WindowsBackup/vmware

7z a -t7z -m0=lzma2 -mx=9 -mfb=128 -md=256m -ms=on FOLDER.7z FOLDER

sudo sensors-detect
```

### Gnome

Manually Install Extensions from extensions.gnome.org

- gnome-shell-extension-netspeed
- gnome-shell-extension-places-menu
- gnome-shell-extension-transparentnotification
- gnome-shell-extension-tray-icons-reloaded

### Cura

Config files need to be applied manually.

```bash
machineConfigs/home/arthur/cura
```

### GWE

Database file needs to be restored manually.

### Python

Setup Python venv

```bash
python3 -m venv .
source bin/activate
```

### Spotify Libraries

Needed for Local Song Playback

```bash
https://github.com/ramedeiros/spotify_libraries/
```

## Server

### Cockpit

```bash
sudo nano /etc/cockpit/ws-certs.d/1-my-cert.cert
```

### Timeshift

```bash
sudo zfs create -V 76.76G backup/Timeshift
sudo mkfs.ext4 /dev/zd0
sudo mount /dev/zd0 /media/arthur/Timeshift
sudo umount /media/arthur/Timeshift
```

### ZFS

```bash
sudo zfs get compressratio
/usr/sbin/zfs send -i backup/File_Storage backup/File_Storage@2021.08.01 | pv | ssh arthur@10.0.0.4 /usr/sbin/zfs receive -F backup/File_Storage
zfs send backup/File_Storage@2021.06.14-10.22.09 | ssh arthur@10.0.0.4 zfs receive -F backup/File_Storage
```

### Docker Commands

```bash
sudo rm docker-compose.yaml && sudo nano docker-compose.yaml
sudo rm docker-compose.yaml && nano docker-compose.yaml
docker system prune -a
docker image prune -a
docker kill $(docker ps -q)
docker-compose down
docker-compose pull
sudo docker-compose --compatibility up --detach  --remove-orphans
```

### GitLab

```bash
gitlab-ctl registry-garbage-collect
gitlab-ctl reconfigure
```

### Database

```sql
CREATE USER 'arthur'@'10.0.0.X' IDENTIFIED BY 'arthur';
GRANT ALL PRIVILEGES ON *.* TO `arthur`@`10.0.0.X`;

FLUSH PRIVILEGES;

# % for everything

CREATE USER 'spotifyTest'@'10.42.0.%' IDENTIFIED BY 'spotifyTest';
GRANT ALL PRIVILEGES ON spotifyTest.* TO `spotifyTest`@`10.42.0.%`;

# View Only Access
GRANT SELECT, LOCK TABLES, SHOW VIEW ON *.* TO 'backup'@'10.42.0.1' IDENTIFIED BY 'backup';
```

### Ansible

```bash
ansible-playbook -i ansible/inventory --ask-become-pass ansible/server.yaml --ask-pass --check
ansible-playbook -i ansible/inventory --ask-become-pass ansible/desktop.yaml --ask-pass --check
```

### Kubernetes

<https://k3s.io/> <https://upcloud.com/community/tutorials/deploy-kubernetes-dashboard/>

```bash
watch $(echo "kubectl get pods -A -o wide |  grep -v 'svclb' | sort -k8 -r")
kubectl drain k3s-worker --ignore-daemonsets --delete-emptydir-data

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --disable traefik --flannel-iface=enp1s0" sh
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC=--flannel-iface=enp6s0 K3S_URL=https://10.0.0.3:6443 K3S_TOKEN=$K3S_TOKEN sh -
```
