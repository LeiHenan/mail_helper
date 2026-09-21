#!/bin/bash
# 构建邮箱助手 HAP。用法: ./build-hap.sh [debug|release]（默认 debug）
# 产物: entry/build/default/outputs/default/entry-default-unsigned.hap
set -euo pipefail

export DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk"
export JAVA_HOME="/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home"
export PATH="$JAVA_HOME/bin:$PATH"

BUILD_MODE="${1:-debug}"

/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  --mode module \
  -p product=default \
  -p module=entry@default \
  -p buildMode="$BUILD_MODE" \
  assembleHap
