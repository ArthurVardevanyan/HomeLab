# Keep Alive Go Script

```bash
export GCS_BUCKET=okd_homelab_keep_alive
export ALLOWED_DELTA=9000 # 15 Minutes
export DISCORD="$(vault kv get -field=discord secret/homelab/keep-alive)"
```
