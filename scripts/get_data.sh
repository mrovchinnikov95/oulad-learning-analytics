#!/usr/bin/env bash
# Скачивает OULAD с UCI Machine Learning Repository (CC BY 4.0) в data/download/, сверяет архив и
# распакованные CSV с data/SHA256SUMS и кладёт CSV в data/raw/. Уже скачанное не качает повторно.
set -euo pipefail
cd "$(dirname "$0")/.."
URL="https://archive.ics.uci.edu/static/public/349/open+university+learning+analytics+dataset.zip"

# GNU sha256sum (Linux) или shasum (macOS: системный sha256sum не знает --quiet).
sha_check() { if sha256sum --version 2>/dev/null | grep -q GNU; then sha256sum --check --quiet; else shasum -a 256 --check --quiet; fi; }

mkdir -p data/download data/raw
if [ ! -f data/download/oulad.zip ]; then
    echo "→ скачиваю $URL"
    curl -fsSL -o data/download/oulad.zip.part "$URL"
    mv data/download/oulad.zip.part data/download/oulad.zip
fi
(cd data && grep ' download/' SHA256SUMS | sha_check)
unzip -q -o data/download/oulad.zip '*.csv' OULAD.names -d data/raw
(cd data && grep ' raw/' SHA256SUMS | sha_check)
echo "данные на месте: data/raw/ ($(ls data/raw/*.csv | wc -l | tr -d ' ') CSV и OULAD.names, суммы сходятся с data/SHA256SUMS)"
