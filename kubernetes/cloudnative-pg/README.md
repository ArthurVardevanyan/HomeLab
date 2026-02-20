# CloudNativePG

> [!CAUTION]
> CNPG manages instance pods directly without a Deployment or StatefulSet.
> If the operator is down and a pod is evicted, no controller will recreate it
> until the operator recovers. Automated failover also requires the operator to
> be running. Ensure the operator runs with multiple replicas and anti-affinity.

```bash
kubectl kustomize kubernetes/cloudnative-pg/overlays/okd | kubectl apply -f - --server-side
```

## REF

- <https://cloudnative-pg.io/docs/>
- <https://github.com/cloudnative-pg/cloudnative-pg>
