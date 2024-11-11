#!/bin/bash

kubectl get --raw /.well-known/openid-configuration
kubectl get --raw /openid/v1/jwks
