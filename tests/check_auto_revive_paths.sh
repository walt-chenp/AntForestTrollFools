#!/bin/sh
set -e

echo "[1/4] Checking canReviveFriendBubble detection coverage..."
grep -q "isWithinReviveHours" antforest/AntForestManager.m || { echo "❌ Missing isWithinReviveHours helper"; exit 1; }
grep -q "+5g" antforest/AntForestManager.m || { echo "❌ Missing +5g badge detection in canReviveFriendBubble"; exit 1; }
grep -q "canReborn" antforest/AntForestManager.m || { echo "❌ Missing reborn keys in canReviveFriendBubble"; exit 1; }
grep -q "protectRewardEnergy" antforest/AntForestManager.m || { echo "❌ Missing protectRewardEnergy check"; exit 1; }
grep -q "protectFlag" antforest/AntForestManager.m || { echo "❌ Missing protectFlag check"; exit 1; }

echo "[2/4] Checking revive active hours isolation..."
# queueAutoReviveForUser and reviveSendNext should NOT be gated by vitality task hours (isWithinTaskActiveHours)
sed -n '/- (void)queueAutoReviveForUser:/,/^}/p' antforest/AntForestManager.m | grep -q "isWithinTaskActiveHours" && { echo "❌ queueAutoReviveForUser still gated by isWithinTaskActiveHours"; exit 1; }
sed -n '/- (void)reviveSendNext/,/^}/p' antforest/AntForestManager.m | grep -q "isWithinTaskActiveHours" && { echo "❌ reviveSendNext still gated by isWithinTaskActiveHours"; exit 1; }

echo "[3/4] Checking PK board isolation & total ranking response recognition..."
grep -q "isPkOrPvp" antforest/AntForestManager.m || { echo "❌ Missing isPkOrPvp in matchFriendIdAndBubbles"; exit 1; }
grep -q "isTotalRankResponse" antforest/AntForestManager.m || { echo "❌ Missing isTotalRankResponse in matchFriendIdAndBubbles"; exit 1; }
grep -q "排行榜扫描发现.*待复活过期能量" antforest/AntForestManager.m || { echo "❌ Missing revive stage record log"; exit 1; }

echo "[4/4] Checking queueAutoReviveForUser invocation on ranking discovery..."
sed -n '/\/\/ 严格隔离榜单类型/,/匹配排行/p' antforest/AntForestManager.m | grep -q "queueAutoReviveForUser" || { echo "❌ queueAutoReviveForUser not called in rankArr scan"; exit 1; }

echo "[5/5] Checking queryTotalRank modern RPC payload, no relationLocal pollution and self-healing daily count..."
sed -n '/-(void)queryTotalRank/,/^}/p' antforest/AntForestManager.m | grep -q 'version = @"20241025"' || { echo "❌ Missing version 20241025 in queryTotalRank"; exit 1; }
sed -n '/-(void)queryTotalRank/,/^}/p' antforest/AntForestManager.m | grep -q "relationLocal" && { echo "❌ queryTotalRank should NOT contain relationLocal (causes H5 PK board freeze)"; exit 1; }
grep -q "autoReviveLimitReachedToday" antforest/AntForestManager.m || { echo "❌ Missing autoReviveLimitReachedToday check"; exit 1; }
sed -n '/static NSInteger reviveDailyCount/,/^}/p' antforest/AntForestManager.m | grep -q 'return \[defaults integerForKey:@"autoReviveCount"\]' && { echo "❌ reviveDailyCount still falls back to dirty autoReviveCount cache"; exit 1; }

echo "[6/6] Checking 1v1 Energy Challenge (pvpHome.html) & PK subpage isolation..."
grep -q "isPkOrChallengeURL" PortEntry.m || { echo "❌ Missing isPkOrChallengeURL in PortEntry.m"; exit 1; }
grep -q "currentEnergyPvpBattleRecord" antforest/AntForestManager.m || { echo "❌ Missing currentEnergyPvpBattleRecord in AntForestManager.m"; exit 1; }
grep -q "hasPureRankData" antforest/AntForestManager.m || { echo "❌ Missing hasPureRankData total rank fallback in AntForestManager.m"; exit 1; }

echo "✅ All Auto-Revive expired energy & 1v1 Challenge isolation checks passed successfully!"
