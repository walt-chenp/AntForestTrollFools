#!/bin/sh
set -eu

source_file="$(dirname "$0")/../antforest/AntForestManager.m"
entry_file="$(dirname "$0")/../PortEntry.m"
grep -Fq '(!self.enableSelfCollect && !self.enableAutoPatrol) || !self.jsBridge' "$source_file"
grep -Fq '@"action": @"exchange"' "$source_file"
grep -Fq '@"caQuotaId": caQuotaId ?: @""' "$source_file"
grep -Fq 'if (![taskStatus isEqualToString:@"FINISHED"] && !isSafeRewardTask(taskType, taskTitle)) continue;' "$source_file"
grep -Fq '![action isEqualToString:@"receive"]' "$source_file"
grep -Fq 'BOOL autoCompleteTask = [bizInfo[@"autoCompleteTask"] boolValue];' "$source_file"
if grep -Fq 'openURL:url options:@{}' "$source_file"; then exit 1; fi
if grep -Fq 'resSuccess || data[@"incAwardCount"]' "$source_file"; then exit 1; fi
grep -Fq '服务端仍为 TODO 时必须撤销旧版留下的误缓存' "$source_file"
grep -Fq '首页后台：等待领奖励任务桥接' "$source_file"
grep -Fq 'PSDJsBridge *bridge = self.rewardTaskBridge;' "$source_file"
if grep -Fq 'window.__afRewardEntryRetry' "$source_file"; then exit 1; fi
if grep -Fq '领奖励入口探针' "$source_file"; then exit 1; fi
if grep -Fq '[gDailyCompletedTasks containsObject:taskKey] && ![taskStatus isEqualToString:@"FINISHED"]' "$source_file"; then exit 1; fi
grep -Fq 'static BOOL hookRPCProbeMethod(Class cls)' "$entry_file"
grep -Fq 'objc_getClassList(classes, classCount)' "$entry_file"
grep -Fq 'startSilentRewardContext' "$entry_file"
grep -Fq 'daemonView' "$entry_file"
grep -Fq '会话探针 session=' "$entry_file"
if grep -Fq 'startFirstLoadRequest:' "$entry_file"; then exit 1; fi
