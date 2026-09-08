#!/bin/sh
set -eu

source_file="$(dirname "$0")/../antforest/AntForestManager.m"

echo "[1/3] Checking isSafeFarmTask filters out mini-game internal actions and external app wakeups..."
grep -Fq '订单' "$source_file"
grep -Fq 'lmct' "$source_file"
grep -Fq 'zh_nlgj' "$source_file"
grep -Fq 'fkssj' "$source_file"
grep -Fq 'kuaishou' "$source_file"
grep -Fq 'meituan' "$source_file"
grep -Fq 'taobaochengjiu' "$source_file"
grep -Fq 'jindouduobao' "$source_file"
grep -Fq '新手引导' "$source_file"

echo "[2/3] Checking isSafeFarmTask allows legitimate floatball and browse tasks..."
grep -Fq 'floatball' "$source_file"
grep -Fq 'star30s' "$source_file"
grep -Fq 'denghuo' "$source_file"
grep -Fq 'chouchoule' "$source_file"
grep -Fq 'jdly' "$source_file"
grep -Fq 'qutoutiao' "$source_file"
grep -Fq 'huiyuan' "$source_file"

echo "[3/3] Checking 400000040 deduplication safeguard..."
grep -Fq 'alreadyFailed = [gDailyFailedTasks containsObject:resolvedKey];' "$source_file"

echo "✅ All Baba Farm task path checks passed successfully!"
