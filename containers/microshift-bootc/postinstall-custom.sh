#!/bin/bash
# ==============================================================================
# Post-install Customizations for MicroShift BootC
# ==============================================================================
# This script runs during container build to configure:
# - Sysctl settings for MicroShift
# - CRI-O policy.json and registries.d (required by el9 crio on CentOS 10)
# - Cockpit installation (opt-in)
# - DNS configuration
# - Additional utilities
# Note: kubeconfig symlink is handled via /etc/tmpfiles.d/microshift-bootc.conf
#       (persistent across bootc upgrades; target file created at runtime).
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
  if [[ "${COCKPIT}" != "1" ]]; then
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

setup_crio_policy() {
  log_info "Configuring CRI-O image policy..."

  # CRI-O (built for el9) only checks /etc/containers/policy.json, but
  # CentOS 10's containers-common-6.0 moved it to /usr/share/containers/.
  if [[ ! -f /etc/containers/policy.json && -f /usr/share/containers/policy.json ]]; then
    cp /usr/share/containers/policy.json /etc/containers/policy.json
  fi

  # Same for registries.d: without these files, CRI-O does not look up
  # the sigstore signatures that policy.json requires for the Red Hat registry.
  mkdir -p /etc/containers/registries.d
  for f in /usr/share/containers/registries.d/*.yaml; do
    if [[ -f "${f}" && ! -f "/etc/containers/registries.d/$(basename "${f}")" ]]; then
      cp "${f}" /etc/containers/registries.d/
    fi
  done

  log_success "CRI-O policy configured."
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
  arch="$(uname -m)"
  if [[ "${arch}" = "aarch64" ]]; then
    CNP_PKG="cni-plugins-linux-arm64-${CNP_VER}.tgz"
  fi

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
  # MicroShift merges /etc/microshift/config.d/*.yaml over its defaults, and /etc
  # is delivered on bootc upgrades (unlike /var). 127.0.0.1 and localhost are
  # excluded — MicroShift rejects them in subjectAltNames.
  local config_path="${EXTRA_CONFIG:-/etc/microshift/config.d/10-san.yaml}"
  local domain="${DOMAIN}"

  mkdir -p "$(dirname "${config_path}")"

  cat > "${config_path}" <<EOF
apiServer:
  subjectAltNames:
    - ${domain}
EOF

  log_success "SubjectAltNames config generated: ${config_path}"
}

# ---- Main Execution ----

log_info "Running post-install customizations..."

# 1. Setup sysctl settings
setup_sysctl

# 2. Setup firewall rules
setup_firewall_rules

# 3. Configure CRI-O policy.json (required for el9 crio on CentOS 10)
setup_crio_policy

# 4. Install CNI plugins (if kindnet is present)
if rpm -q microshift-kindnet &>/dev/null; then
  # Disable openvswitch and systemd-resolved when kindnet is present
  systemctl disable openvswitch &>/dev/null || true
  systemctl disable systemd-resolved &>/dev/null || true

  install_cni_plugins
fi

# 5. Install Cockpit (opt-in)
install_cockpit

# 6. Set system hostname (write to /etc/hostname so it persists;
#    hostnamectl is not available during the build stage)
echo "${DOMAIN}" > /etc/hostname

# 7. Generate subjectAltNames config (for API server)
generate_subject_alt_names_config

# Note: kubeconfig symlink is handled via /etc/tmpfiles.d/microshift-bootc.conf
#       (persistent across bootc upgrades; target file created at runtime).

# 8. Enable MicroShift service
systemctl enable microshift

log_success "Post-install customizations completed."
