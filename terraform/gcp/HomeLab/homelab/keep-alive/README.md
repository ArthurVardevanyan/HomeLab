# Keep Alive Go Script

Fetches latest files from GCS Bucket and compares against current time. If time delta is higher then allotted, send an alert to discord.

Used to check if HomeLab is no longer able to reach out to send notifications, whether due to a crash, power outage, internet outage, etc.

## Environment Variables

```bash
export GCS_BUCKET=okd_homelab_keep_alive
export ALLOWED_DELTA=900 # 15 Minutes
export DISCORD="$(vault kv get -field=discord secret/homelab/keep-alive)"
```

## TODO

- Error Handling
- Multi Zone Logic

## REF

- <https://cloud.google.com/community/tutorials/using-scheduler-invoke-private-functions-oidc>
- <https://jeanklaas.com/blog/cloud-functions-with-terraform-guide/>
- <https://www.cloudskillsboost.google/focuses/5171?parent=catalog>
- <https://benjamincongdon.me/blog/2019/01/21/Getting-Started-with-Golang-Google-Cloud-Functions/>
- <https://stackoverflow.com/questions/63163956/how-to-deploy-this-function-to-google-cloud>
- <https://cloud.google.com/functions/docs/securing/function-identity>
