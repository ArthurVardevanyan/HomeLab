# Ansible

## Remote VsCode

```bash
 ansible-playbook -i ansible/inventory --ask-become-pass ansible/vscode-server.yaml --ask-pass \
  -e 'ansible_python_interpreter=/usr/bin/python3'
```

## Ref

- <https://github.com/k3s-io/k3s-ansible>
- <https://webworxshop.com/automating-my-infrastructure-with-ansible-and-gitlab-ci-part-1-getting-started/?pk_campaign=reddit-homelab>
- <https://stackoverflow.com/questions/63266075/how-to-run-ansible-playbook-from-gitlab-ci>
- <https://der-jd.de/blog/2021/01/02/Using-ansible-with-gitlab-ci/>
- <https://docs.ansible.com/ansible/latest/collections/ansible/posix/sysctl_module.html>
- <https://idbs-engineering.com/containers/2019/08/27/auto-expiry-quayio-tags.html>
- <https://www.cyberciti.biz/faq/ansible-apt-update-all-packages-on-ubuntu-debian-linux/>
