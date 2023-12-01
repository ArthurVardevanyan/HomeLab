#!/bin/bash

# Ensure $HOME exists when starting
if [ ! -d "${HOME}" ]; then
  mkdir -p "${HOME}"
fi

# Setup $PS1 for a consistent and reasonable prompt
if [ -w "${HOME}" ] && [ ! -f "${HOME}"/.bashrc ]; then
  echo "PS1='[\u@\h \W]\$ '" >"${HOME}"/.bashrc
fi

# Add current (arbitrary) user to /etc/passwd and /etc/group
if ! whoami &>/dev/null; then
  if [ -w /etc/passwd ]; then
    echo "${USER_NAME:-user}:x:$(id -u):0:${USER_NAME:-user} user:${HOME}:/bin/bash" >>/etc/passwd
    echo "${USER_NAME:-user}:x:$(id -u):" >>/etc/group
  fi
fi

if [[ ! -f /home/user/.zshrc ]]; then
  cp -rf /home/tooling/{.gitconfig,.oh-my-zsh,.zshrc,.bashrc} /home/user/ >/dev/null 2>&1 || true
  chown "${USER_ID}":"${GROUP_ID}" /home/user/{.gitconfig,.oh-my-zsh,.zshrc,.bashrc} >/dev/null 2>&1 || true
  chmod 0775 /home/user/{.gitconfig,.oh-my-zsh,.zshrc,.bashrc} >/dev/null 2>&1 || true
fi

exec "$@"
