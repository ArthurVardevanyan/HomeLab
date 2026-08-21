#!/bin/bash

# Ensure $HOME exists when starting
if [[ ! -d "${HOME}" ]]; then
  mkdir -p "${HOME}"
fi

# Setup $PS1 for a consistent and reasonable prompt
if [[ -w "${HOME}" && ! -f "${HOME}"/.bashrc ]]; then
  echo "PS1='[\u@\h \W]\$ '" >"${HOME}"/.bashrc
fi

# Add current (arbitrary) user to /etc/passwd and /etc/group
if ! whoami &>/dev/null; then
  if [[ -w /etc/passwd ]]; then
    MY_UID=$(id -u) || { echo "Error: Failed to get UID" >&2; exit 1; }
    echo "${USER_NAME:-user}:x:${MY_UID}:0:${USER_NAME:-user} user:${HOME}:/bin/bash" >>/etc/passwd || { echo "Error: Failed to write /etc/passwd" >&2; exit 1; }
    echo "${USER_NAME:-user}:x:${MY_UID}:" >>/etc/group || { echo "Error: Failed to write /etc/group" >&2; exit 1; }
  fi
fi

if [[ ! -f /home/user/.zshrc ]]; then
  cp -rf /home/tooling/{.gitconfig,.oh-my-zsh,.zshrc,.bashrc} /home/user/ >/dev/null 2>&1 || { echo "Error: Failed to copy dotfiles" >&2; exit 1; }
  # shellcheck disable=SC2154
  chown "${USER_ID}":"${GROUP_ID}" /home/user/{.gitconfig,.oh-my-zsh,.zshrc,.bashrc} >/dev/null 2>&1 || { echo "Error: Failed to set ownership" >&2; exit 1; }
  # shellcheck disable=SC2154
  chmod 0775 /home/user/{.gitconfig,.oh-my-zsh,.zshrc,.bashrc} >/dev/null 2>&1 || { echo "Error: Failed to set permissions" >&2; exit 1; }
fi

exec "$@"
