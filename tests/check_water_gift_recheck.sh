#!/bin/sh
set -eu

source_file="$(dirname "$0")/../PortEntry.m"
grep -Fq "startForestHomeWhenBridgeReady" "$source_file"
grep -Fq "森林首页 H5 Bridge 等待超时" "$source_file"
grep -Fq "portUpdateBridgeReadyStatus" "$source_file"
grep -Fq "rvkViewController" "$source_file"
grep -Fq "if (waterLaunchAttempted)" "$(dirname "$0")/../antforest/AntForestManager.m"
