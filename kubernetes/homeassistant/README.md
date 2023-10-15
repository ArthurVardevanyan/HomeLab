# HomeAssistant

```bash
kubectl kustomize kubernetes/homeassistant/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

## REF

- <https://blog.paul-steele.com/tech/2018/12/25/homeassistant-kubernetes-zwave-oh-my.html>
- <https://community.home-assistant.io/t/haha-highly-available-home-assistant/128426>
- <https://console.cloud.google.com/cloudpubsub/subscription/detail/HomeAssistant?project=tidal-eon-320014&tab=details>
- <https://console.nest.google.com/device-access/project/573a3683-373e-480f-a125-a94fafc77e86/information>
- <https://github.com/dseifert/homeassistant2influxdb>
- <https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_subscription>
- <https://www.home-assistant.io/integrations/nest/>
- <https://www.reddit.com/r/homeassistant/comments/im49ud/is_it_possible_to_get_data_from_my_utilitys_meters/>
- <https://www.reddit.com/r/homeassistant/comments/sq97e7/psa_if_youre_using_octoprint_use_mqtt_instead_of/>
- <https://www.reddit.com/r/homeassistant/comments/wa1g5x/running_homeassistant_as_nonroot_in_k8s/>
- <https://github.com/dronenb/HomeLab/blob/main/kubernetes/manifests/home-assistant/statefulset.yaml#L33-L57>
