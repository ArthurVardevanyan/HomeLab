#!/bin/bash

# Exempt the PLACEHOLDER in image digest — filled in by CI after build
export EXEMPTIONS=(
  "check=placeholder,match=PLACEHOLDER"
)
