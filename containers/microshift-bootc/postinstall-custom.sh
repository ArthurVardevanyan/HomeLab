#!/bin/bash
# ==============================================================================
# Post-install Customizations for MicroShift BootC
# ==============================================================================
# This script runs during container build to configure:
# - Firewalld rules for pod networks and services
# - Sysctl settings for MicroShift
# - Cockpit installation (opt-in)
# - DNS configuration
# - Additional utilities
# ==============================================================================

set -euo pipefail

log_info() { echo -e "[INFO] $1"; }
log_success() { echo -e "[OK] $1"; }
log_warn() { echo -e "[WARN] $1"; }
log_error() { echo -e "[ERROR] $1"; }

# ---- Configuration ----
DOMAIN="${DOMAIN:-microshift.dc2.vardevanyan.com}"
COCKPIT="${COCKPIT:-0}"

# ---- Helper Functions ----

setup_firewall_rules() {
  log_info "Configuring firewalld rules..."

  # Allow pod network (trusted zone)
  firewall-offline-cmd --zone=trusted --add-source=10.42.0.0/16 2>/dev/null || true
  firewall-offline-cmd --zone=trusted --add-source=10.43.0.0/16 2>/dev/null || true

  # Allow public ports
  firewall-offline-cmd --zone=public --add-service=http 2>/dev/null || true
  firewall-offline-cmd --zone=public --add-service=https 2>/dev/null || true
  firewall-offline-cmd --zone=public --add-port=5353/udp 2>/dev/null || true
  firewall-offline-cmd --zone=public --add-port=6443/tcp 2>/dev/null || true
  firewall-offline-cmd --zone=public --add-port=30000-32767/tcp 2>/dev/null || true

  log_success "Firewalld rules configured."
}

setup_sysctl() {
  log_info "Configuring sysctl settings..."

  # Configure limits for cAdvisor and kubelet
  cat > /etc/sysctl.d/99-microshift.conf <<EOF
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 16384
EOF

  log_success "Sysctl settings configured."
}

install_cockpit() {
  if [[ "${COCKPIT}" != "1" ]] ; then
    log_info "Skipping Cockpit installation (COCKPIT=0)"
    return 0
  fi

  log_info "Installing Cockpit..."

  # Install cockpit and dependencies
  dnf install -y cockpit pcp cockpit-podman cockpit-ws cockpit-bridge 2>/dev/null || true

  # Create cockpit config directory
  mkdir -p /etc/cockpit/conf.d

  # Configure cockpit to listen on all interfaces
  cat > /etc/cockpit/cockpit.conf <<EOF
[WebService]
LoginGraceTime=120
ListenAddress=
EOF

  # Create 99-webui.json config
  mkdir -p /etc/cockpit/machines.d
  cat > /etc/cockpit/machines.d/99-webui.json <<EOF
{
  "name": "MicroShift Cluster",
  "url": "https://${DOMAIN}:6443",
  "token": "",
  "image": "default",
  "os": "Red Hat Enterprise Linux",
  "color": "#333333",
  "icon": "system"
}
EOF

  log_success "Cockpit installed and configured."
}

install_cni_plugins() {
  # Check if containernetworking-plugins is already installed
  if rpm -q containernetworking-plugins &>/dev/null; then
    return 0
  fi

  log_info "Installing CNI plugins..."

  # Set the package version and name
  CNP_VER=v1.8.0
  CNP_PKG="cni-plugins-linux-amd64-${CNP_VER}.tgz"
  [[ "$(uname -m)" = "aarch64" ]] && CNP_PKG="cni-plugins-linux-arm64-${CNP_VER}.tgz"

  # Download the package
  curl -fsSL --retry 5 -o "/tmp/${CNP_PKG}" \
      "https://github.com/containernetworking/plugins/releases/download/${CNP_VER}/${CNP_PKG}"

  # Extract the package into the CNI plugins directory
  mkdir -p /usr/libexec/cni
  tar zxvf "/tmp/${CNP_PKG}" -C /usr/libexec/cni

  # Clean up
  rm -f "/tmp/${CNP_PKG}"

  log_success "CNI plugins installed."
}

generate_subject_alt_names_config() {
  local config_path="${EXTRA_CONFIG:-/var/lib/microshift-okd/custom_config.yaml}"
  local domain="${DOMAIN}"

  local host_fqdn
  if hostname -f &>/dev/null; then
    host_fqdn=$(hostname -f)
  else
    host_fqdn=$(hostname)
  fi

  mkdir -p "$(dirname "${config_path}")"

  cat > "${config_path}" <<EOF
apiServer:
  subjectAltNames:
    - ${domain}
    - ${host_fqdn}
    - 127.0.0.1
    - localhost
EOF

  log_success "SubjectAltNames config generated: ${config_path}"
}

# ---- Main Execution ----

log_info "Running post-install customizations..."

# 1. Setup sysctl settings
setup_sysctl

# 2. Setup firewall rules
setup_firewall_rules

# 3. Install CNI plugins (if kindnet is present)
if rpm -q microshift-kindnet &>/dev/null; then
  # Disable openvswitch and systemd-resolved when kindnet is present
  systemctl disable openvswitch &>/dev/null || true
  systemctl disable systemd-resolved &>/dev/null || true

  install_cni_plugins
fi

# 4. Install Cockpit (opt-in)
install_cockpit

# 5. Generate subjectAltNames config (for API server)
generate_subject_alt_names_config

# 6. Create link to default kubeconfig
if [[ ! -f /root/.kube/config ]] ; then
  mkdir -p "$(readlink -f /root)/.kube"
  ln -sf /var/lib/microshift/resources/kubeadmin/kubeconfig /root/.kube/config
fi

# 7. Enable MicroShift service
systemctl enable microshift

log_success "Post-install customizations completed."
