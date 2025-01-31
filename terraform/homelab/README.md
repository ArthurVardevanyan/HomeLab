# HomeLab

GCP Project for HomeLab Resources.
Setup Here: [ArthurVardevanyan/gcp-projects](https://github.com/ArthurVardevanyan/gcp-projects/commit/58d4d966c6b7af2fe406ae1bdbd4ced9237d2180)

```bash
PROJECT_ID="$(vault kv get -field=project_id secret/gcp/org/av/projects)"
BUCKET_ID="$(vault kv get -field=bucket_id secret/gcp/org/av/projects)"

cat << EOF > backend.conf
bucket = "tf-state-homelab-${BUCKET_ID}"
prefix = "terraform/state"
EOF

tofu init -backend-config=backend.conf
tofu plan
tofu apply
```
