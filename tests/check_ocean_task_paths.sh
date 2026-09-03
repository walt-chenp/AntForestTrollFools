#!/bin/sh
set -eu

source_file="$(dirname "$0")/../antforest/AntForestManager.m"
entry_file="$(dirname "$0")/../PortEntry.m"
header_file="$(dirname "$0")/../antforest/AntForestManager.h"
makefile="$(dirname "$0")/../Makefile"

grep -Fq 'enableAutoOceanTasks' "$header_file"
grep -Fq 'oceanBridge' "$header_file"
grep -Fq 'queryOceanTaskList' "$header_file"
grep -Fq 'handleOceanTaskListResponse:' "$header_file"
grep -Fq 'receiveOceanTaskAward:' "$header_file"

grep -Fq 'handleOceanTaskListResponse:' "$source_file"
grep -Fq 'queryOceanTaskList' "$source_file"
grep -Fq '神奇海洋·任务探测' "$source_file"
grep -Fq 'antOceanTaskVOList' "$source_file"
grep -Fq 'ANTOCEAN_TASK' "$source_file"

grep -Fq 'isOceanURL' "$entry_file"
grep -Fq 'toggleAutoOceanTasks:' "$entry_file"
grep -Fq '神奇海洋 · 已绑定海洋 H5 Bridge' "$entry_file"
grep -Fq 'AntForestPort-Ocean 收取日志' "$entry_file"

grep -Fq 'isSafeOceanTask' "$source_file"
grep -Fq 'sLastExecutedSceneCode containsString:@"OCEAN"' "$source_file"
grep -Fq 'queryOceanTaskListWithForce:YES' "$source_file"
grep -Fq 'id bridge = self.oceanBridge ?: self.jsBridge;' "$source_file"

grep -Fq 'AntForestPort-Ocean.dylib' "$makefile"
grep -Fq 'AntForestPort-Ocean-iOS14.dylib' "$makefile"
