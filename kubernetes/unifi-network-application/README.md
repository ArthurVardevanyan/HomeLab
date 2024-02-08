# Unifi Network Application

```bash
keytool -importkeystore \
  -srckeystore keystore \
  -destkeystore keystore.p12 \
  -deststoretype PKCS12 \
  -srcalias unifi \
  -deststorepass aircontrolenterprise \
  -destkeypass aircontrolenterprise
```

<https://docs.linuxserver.io/images/docker-unifi-network-application/#supported-architectures>
<https://security.stackexchange.com/questions/3779/how-can-i-export-my-private-key-from-a-java-keytool-keystore>
