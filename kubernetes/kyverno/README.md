# Kyverno

Only Admission Controller is Active

```bash
kubectl kustomize kubernetes/kyverno/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -

wget https://github.com/kyverno/kyverno/releases/download/v1.15.1/install.yaml
```

## WebHook CleanUp

```bash
kubectl delete validatingwebhookconfigurations kyverno-cel-exception-validating-webhook-cfg
kubectl delete validatingwebhookconfigurations kyverno-exception-validating-webhook-cfg
kubectl delete validatingwebhookconfigurations kyverno-global-context-validating-webhook-cfg
kubectl delete validatingwebhookconfigurations kyverno-policy-validating-webhook-cfg
kubectl delete validatingwebhookconfigurations kyverno-resource-validating-webhook-cfg
kubectl delete mutatingwebhookconfigurations kyverno-policy-mutating-webhook-cfg
kubectl delete mutatingwebhookconfigurations kyverno-resource-mutating-webhook-cfg
kubectl delete mutatingwebhookconfigurations kyverno-verify-mutating-webhook-cfg
```

## REF

- <https://kyverno.io/docs/installation/methods>
