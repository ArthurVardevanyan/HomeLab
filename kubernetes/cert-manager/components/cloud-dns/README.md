# Cloud DNS

```bash
PROJECT_ID="$(vault kv get -field=project_id secret/gcp/org/av/projects)"

curl -X GET \
     -H "Authorization: Bearer $(gcloud auth print-access-token )" \
     "https://dns.googleapis.com/dns/v1/projects/homelab-${PROJECT_ID}/managedZones?alt=json&dnsName=arthurvardevanyan.com.&prettyPrint=false" | jq
```
