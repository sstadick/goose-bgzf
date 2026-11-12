#!/usr/bin/env bash
set -euo pipefail
exec "${GOOSE:-goose}" run "${GOOSE_DOC:-../goose-doc/main.goose}" -- \
  --title "goose-bgzf API" --symbols api.txt --require-docs --require-examples \
  --output "${DOC_OUTPUT:-API.md}" "$@" bgzf.goose
