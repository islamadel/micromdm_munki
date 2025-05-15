#!/bin/bash
# Islam Adel
# Download / Update micromdm repo
# 2024-06-21
# 2024-06-26
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
cd "$SCRIPT_DIR"
wget -O ./main.zip https://github.com/micromdm/micromdm/archive/refs/heads/main.zip
unzip -o ./main.zip
cp -r ./custom_tools/* ./micromdm-main/tools/
chmod -R +x ./micromdm-main/tools/
rm main.zip
