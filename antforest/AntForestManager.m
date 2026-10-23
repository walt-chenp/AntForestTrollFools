//
//  AntForestManager.m
//  antforest
//
//  Created by walt-chenp.
//

#import "AntForestManager.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "Tool.h"

@implementation AntForestManager

static AntForestManager *afm = nil;
static NSDate *lastCollectStartedAt = nil;
static NSString *lastScheduledMinute = nil;
static NSMutableSet<NSString *> *recordedCollectedBubbles = nil;
static NSMutableSet<NSString *> *pendingCollectBubbles = nil;
static NSMutableSet<NSString *> *takeLookVisitedFriends = nil;
static NSString *takeLookCurrentFriendId = nil;
static BOOL takeLookRunning = NO;
static BOOL takeLookWaitingForFriend = NO;
static NSUInteger takeLookRounds = 0;
static NSUInteger takeLookRequestToken = 0;
static NSUInteger takeLookPass = 0;
static NSUInteger takeLookTotalRounds = 0;
static const NSUInteger kTakeLookMaxRounds = 150;
static const NSUInteger kTakeLookMaxPasses = 3;
static BOOL rankScanPending = NO;
static NSUInteger collectionCycle = 0;
static BOOL selfPriorityPending = NO;
static NSUInteger selfPriorityCycle = 0;
static NSMutableArray<NSString *> *deferredFriendRankIds = nil;
static NSArray<NSString *> *deferredRankedFriendIds = nil;
static NSString *lastWaterScheduledMinute = nil;
static BOOL waterRunning = NO;
static BOOL waterAwaitingHome = NO;
static BOOL waterAwaitingLimit = NO;
static BOOL waterAwaitingTransfer = NO;
static NSUInteger waterRequestToken = 0;
static NSUInteger waterRetryCount = 0;
static NSUInteger waterTransferRetryCount = 0;
static const NSTimeInterval kWaterTransferCooldown = 1.5;
static NSUInteger waterTargetCount = 0;
static NSUInteger waterSucceededCount = 0;
static NSUInteger waterQueueIndex = 0;
static NSArray<NSString *> *waterQueue = nil;
static NSString *waterCurrentUserId = nil;
static NSString *waterCurrentBizNo = nil;
static NSString *waterRunReason = nil;
static BOOL waterFriendRefreshPending = NO;
static BOOL waterLaunchAttempted = NO;
static BOOL collectAfterLaunchWater = NO;
static NSMutableArray<NSString *> *reviveQueue = nil;
static NSMutableSet<NSString *> *reviveQueuedIds = nil;
static BOOL reviveRunning = NO;
static NSString *reviveCurrentUserId = nil;
static NSUInteger reviveRequestToken = 0;
static BOOL reviveRewardRefreshNeeded = NO;
static NSMutableSet<NSString *> *todayCollectedAnimalKeys = nil;
static NSMutableDictionary<NSString *, NSNumber *> *lastAnimalCollectAttemptTimes = nil;
static NSMutableSet<NSString *> *shieldReportedFriendsInRound = nil;
static NSMutableSet<NSString *> *sDoubleCollectCheckedUsers = nil;

static NSString *getTaskActiveStartTimeString(void) {
    NSString *t = AntForestManager.sharedInstance.rewardTaskStartTime;
    if (!t.length) {
        t = [NSUserDefaults.standardUserDefaults stringForKey:@"rewardTaskStartTime"];
    }
    return t.length ? t : @"07:00";
}

// 活跃时间窗口：根据用户设置的时间（默认 07:00）动态判定。未到时间前处于静默期，仅允许能量签到，常规做任务挂起等待指定时刻；达到指定时刻后进入活跃期
static BOOL isWithinTaskActiveHours(void) {
    NSString *startTime = getTaskActiveStartTimeString();
    NSArray *parts = [startTime componentsSeparatedByString:@":"];
    NSInteger targetHour = 7;
    NSInteger targetMinute = 0;
    if (parts.count >= 2) {
        targetHour = [parts[0] integerValue];
        targetMinute = [parts[1] integerValue];
    } else if (parts.count == 1) {
        targetHour = [parts[0] integerValue];
    }
    
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *nowComp = [calendar components:(NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:[NSDate date]];
    NSInteger currentMinutes = nowComp.hour * 60 + nowComp.minute;
    NSInteger targetMinutes = targetHour * 60 + targetMinute;
    
    return (currentMinutes >= targetMinutes);
}

// 定义一个全局串行队列
dispatch_queue_t globalSerialQueueQuery;
dispatch_queue_t globalSerialQueueCollect;
dispatch_queue_t globalSerialQueueTest;

+(id)sharedInstance{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        afm=[[self alloc]init];
#if !ENABLE_PROBE_LOGS
        [afm clearProbeLogs];
#endif
        
        // 创建一个串行队列
        globalSerialQueueQuery = dispatch_queue_create("antforest_query", DISPATCH_QUEUE_SERIAL);
        globalSerialQueueCollect = dispatch_queue_create("antforest_collect", DISPATCH_QUEUE_SERIAL);
        globalSerialQueueTest = dispatch_queue_create("antforest_test", DISPATCH_QUEUE_SERIAL);
        recordedCollectedBubbles = [NSMutableSet set];
        pendingCollectBubbles = [NSMutableSet set];
        takeLookVisitedFriends = [NSMutableSet set];
        deferredFriendRankIds = [NSMutableArray array];
        reviveQueue = [NSMutableArray array];
        reviveQueuedIds = [NSMutableSet set];
        todayCollectedAnimalKeys = [NSMutableSet set];
        lastAnimalCollectAttemptTimes = [NSMutableDictionary dictionary];
        shieldReportedFriendsInRound = [NSMutableSet set];
        sDoubleCollectCheckedUsers = [NSMutableSet set];
        afm.rewardTaskStartTime = [[NSUserDefaults standardUserDefaults] stringForKey:@"rewardTaskStartTime"] ?: @"07:00";
        
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                [afm notifyActiveH5PageToRefresh];
                if (afm.enableAutoPatrolNew) {
                    [afm queryMonopolyTaskListWithForce:YES];
                    [afm claimAllVisibleMonopolyRewardsOnWebView];
                }
                if (afm.enableAutoAIFish) {
                    [afm queryAIFishTaskListWithForce:YES];
                    [afm claimAllVisibleAIFishRewardsOnWebView];
                }
                if (afm.enableAutoOceanTasks) {
                    [afm queryOceanTaskListWithForce:YES];
                }
                if (afm.enableAutoRewardTasks) {
                    [afm queryVitalityTaskListWithForce:YES];
                    [afm claimAllVisibleRewardTaskRewardsOnWebView];
                }
                if (afm.enableAutoFarmTasks) {
                    [afm queryFarmTaskListWithForce:YES];
                    [afm claimAllVisibleFarmRewardsOnWebView];
                }
            });
        }];
    });
    return afm;
}

- (NSInteger)waterGrams {
    switch (self.waterEnergyId) {
        case 40: return 18;
        case 41: return 33;
        case 42: return 66;
        default: return 10;
    }
}

+ (NSString *)extractNameFromDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *key in @[ @"displayName", @"userName", @"remarkName", @"name", @"nickName", @"userDisplayName", @"showName", @"realName", @"alias" ]) {
        id val = dict[key];
        if ([val isKindOfClass:NSString.class] && [(NSString *)val length] > 0) return (NSString *)val;
    }
    for (NSString *subKey in @[ @"userBaseInfo", @"userInfo", @"contact", @"extInfo" ]) {
        id subDict = dict[subKey];
        if ([subDict isKindOfClass:NSDictionary.class]) {
            NSString *nested = [self extractNameFromDictionary:subDict];
            if (nested.length > 0) return nested;
        }
    }
    return nil;
}

+ (NSString *)extractUserIdFromDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *key in @[ @"userId", @"userID", @"uid", @"id" ]) {
        id val = dict[key];
        if ([val isKindOfClass:NSString.class] && [(NSString *)val length] > 0) return (NSString *)val;
        if ([val isKindOfClass:NSNumber.class]) return [(NSNumber *)val stringValue];
    }
    for (NSString *subKey in @[ @"userBaseInfo", @"userInfo", @"contact" ]) {
        id subDict = dict[subKey];
        if ([subDict isKindOfClass:NSDictionary.class]) {
            NSString *nested = [self extractUserIdFromDictionary:subDict];
            if (nested.length > 0) return nested;
        }
    }
    return nil;
}

- (NSString *)waterDisplayNameForUser:(NSString *)uid {
    NSDictionary *contact = [self.friendsName[uid] isKindOfClass:NSDictionary.class] ? self.friendsName[uid] : nil;
    NSString *name = [AntForestManager extractNameFromDictionary:contact];
    if (!name.length) return @"好友";
    return name.length == 1 ? [name stringByAppendingString:@"***"] : [[name substringToIndex:MIN((NSUInteger)2, name.length)] stringByAppendingString:@"***"];
}

- (NSString *)friendDisplayNameForUser:(NSString *)uid {
    if (!uid.length) return @"好友";
    if ([uid isEqualToString:self.myUserId]) return @"自己";
    NSDictionary *contact = [self.friendsName[uid] isKindOfClass:NSDictionary.class] ? self.friendsName[uid] : nil;
    NSString *name = [contact[@"displayName"] isKindOfClass:NSString.class] ? contact[@"displayName"] : nil;
    if (!name.length) name = [contact[@"name"] isKindOfClass:NSString.class] ? contact[@"name"] : nil;
    if (!name.length) name = [AntForestManager extractNameFromDictionary:contact];
    return name.length ? name : @"好友";
}

static NSString *waterTodayKey(void) {
    return getCurrentDateString();
}

static NSMutableDictionary<NSString *, NSNumber *> *waterDailyCounts(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *today = waterTodayKey();
    if (![[defaults stringForKey:@"waterDailyDate"] isEqualToString:today]) {
        [defaults setObject:today forKey:@"waterDailyDate"];
        [defaults setObject:@{} forKey:@"waterDailyCounts"];
    }
    NSDictionary *saved = [defaults dictionaryForKey:@"waterDailyCounts"] ?: @{};
    return [saved mutableCopy];
}

static void saveWaterDailyCounts(NSDictionary *counts) {
    [NSUserDefaults.standardUserDefaults setObject:counts forKey:@"waterDailyCounts"];
}

static NSString *waterJSONString(id value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static id waterFindValue(id value, NSString *key, NSUInteger depth) {
    if (depth > 8) return nil;
    if ([value isKindOfClass:NSDictionary.class]) {
        id direct = value[key];
        if (direct) return direct;
        for (id child in [(NSDictionary *)value allValues]) {
            id found = waterFindValue(child, key, depth + 1);
            if (found) return found;
        }
    } else if ([value isKindOfClass:NSArray.class]) {
        for (id child in (NSArray *)value) {
            id found = waterFindValue(child, key, depth + 1);
            if (found) return found;
        }
    }
    return nil;
}

static BOOL waterResponseSucceeded(id value) {
    id success = waterFindValue(value, @"success", 0);
    if ([success respondsToSelector:@selector(boolValue)] && [success boolValue]) return YES;
    id result = waterFindValue(value, @"resultCode", 0);
    if ([result isKindOfClass:NSString.class] && [result caseInsensitiveCompare:@"SUCCESS"] == NSOrderedSame) return YES;
    result = waterFindValue(value, @"result", 0);
    return [result respondsToSelector:@selector(integerValue)] && [result integerValue] == 1;
}

static NSString *waterResponseCode(id value) {
    id code = waterFindValue(value, @"resultCode", 0);
    return [code isKindOfClass:NSString.class] ? [(NSString *)code uppercaseString] : @"";
}

static BOOL waterResponseInsufficient(id value) {
    for (NSString *key in @[ @"resultCode", @"resultDesc", @"resultMessage", @"errorCode", @"errorMsg", @"message", @"memo", @"desc" ]) {
        id candidate = waterFindValue(value, key, 0);
        if (![candidate isKindOfClass:NSString.class]) continue;
        NSString *text = [(NSString *)candidate lowercaseString];
        if ([text containsString:@"insufficient"] || [text containsString:@"not enough"] || [text containsString:@"能量不足"] || [text containsString:@"能量不够"]) return YES;
    }
    return NO;
}

static NSString *waterResponseSummary(id value) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *key in @[ @"success", @"result", @"resultCode", @"resultDesc", @"resultMessage", @"errorCode", @"errorMsg", @"message", @"memo", @"desc", @"waterLimit" ]) {
        id candidate = waterFindValue(value, key, 0);
        if (!candidate || candidate == NSNull.null) continue;
        NSString *text = [candidate isKindOfClass:NSString.class] ? candidate : [candidate description];
        if (text.length > 80) text = [[text substringToIndex:80] stringByAppendingString:@"…"];
        [parts addObject:[NSString stringWithFormat:@"%@=%@", key, text]];
    }
    return parts.count ? [parts componentsJoinedByString:@"，"] : @"未发现状态字段";
}

static BOOL isWithinReviveHours(void) {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *comp = [calendar components:NSCalendarUnitHour fromDate:[NSDate date]];
    return (comp.hour >= 6 && comp.hour <= 23);
}

static BOOL canReviveFriendBubble(NSDictionary *dictRank) {
    if (![dictRank isKindOfClass:NSDictionary.class]) return NO;
    
    NSDictionary *resData = [dictRank[@"resData"] isKindOfClass:NSDictionary.class] ? dictRank[@"resData"] : nil;
    
    // 1. 检查 wateringBubbles 列表中的 fuhuo/protect/reborn 气泡（好友首页特征）
    NSArray *wBubbles = dictRank[@"wateringBubbles"] ?: resData[@"wateringBubbles"];
    if ([wBubbles isKindOfClass:NSArray.class]) {
        for (id b in wBubbles) {
            if ([b isKindOfClass:NSDictionary.class]) {
                NSDictionary *ext = [b[@"extInfo"] isKindOfClass:NSDictionary.class] ? b[@"extInfo"] : nil;
                // 若该气泡有明确不可复活原因（如已被他人复活或超期），跳过该气泡，继续遍历其他气泡
                if (ext && ext[@"notProtectReason"]) {
                    continue;
                }
                if (b[@"canProtect"] != nil && ![b[@"canProtect"] boolValue]) {
                    continue;
                }
                NSString *bizType = [NSString stringWithFormat:@"%@", b[@"bizType"] ?: @""];
                NSString *subBiz = [NSString stringWithFormat:@"%@", b[@"subBizType"] ?: @""];
                if ([b[@"canProtect"] boolValue] || [b[@"canRevive"] boolValue] || [b[@"canReborn"] boolValue] ||
                    [ext[@"canProtect"] boolValue] || [ext[@"canRevive"] boolValue] || [ext[@"canReborn"] boolValue] ||
                    [bizType isEqualToString:@"fuhuo"] || [bizType containsString:@"protect"] || [bizType containsString:@"reborn"] ||
                    [subBiz isEqualToString:@"fuhuo"] || [subBiz containsString:@"protect"] || [subBiz containsString:@"reborn"]) {
                    return YES;
                }
            }
        }
    }
    
    // 2. 检查 bubbles 列表（部分页面返回的通用气泡列表）
    NSArray *bubbles = dictRank[@"bubbles"] ?: resData[@"bubbles"];
    if ([bubbles isKindOfClass:NSArray.class]) {
        for (id b in bubbles) {
            if ([b isKindOfClass:NSDictionary.class]) {
                NSDictionary *ext = [b[@"extInfo"] isKindOfClass:NSDictionary.class] ? b[@"extInfo"] : nil;
                if (ext && ext[@"notProtectReason"]) continue;
                NSString *bizType = [NSString stringWithFormat:@"%@", b[@"bizType"] ?: @""];
                NSString *subBiz = [NSString stringWithFormat:@"%@", b[@"subBizType"] ?: @""];
                if ([b[@"canProtect"] boolValue] || [b[@"canRevive"] boolValue] || [b[@"canReborn"] boolValue] ||
                    [bizType isEqualToString:@"fuhuo"] || [bizType containsString:@"protect"] || [bizType containsString:@"reborn"] ||
                    [subBiz isEqualToString:@"fuhuo"] || [subBiz containsString:@"protect"] || [subBiz containsString:@"reborn"]) {
                    return YES;
                }
            }
        }
    }
    
    // 3. 检查 userEnergy / userForest 结构
    NSDictionary *ue = [dictRank[@"userEnergy"] isKindOfClass:NSDictionary.class] ? dictRank[@"userEnergy"] : (resData[@"userEnergy"] ?: nil);
    if (ue) {
        if ([ue[@"canProtectBubble"] boolValue] || [ue[@"canReviveBubble"] boolValue] || [ue[@"canProtect"] boolValue] ||
            [ue[@"canRebornBubble"] boolValue] || [ue[@"canReborn"] boolValue] || [ue[@"hasProtectBubble"] boolValue] || [ue[@"hasRebornBubble"] boolValue]) {
            return YES;
        }
    }
    
    // 4. 检查全量常规字段与标识（涵盖 protect/reborn/revive/fuhuo 各种命名变体）
    static NSArray<NSString *> *reviveKeys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        reviveKeys = @[
            @"canProtectBubble", @"canProtect", @"protectBubble", @"canProtectEnergy",
            @"canRevive", @"canReviveBubble", @"energyRevive", @"reviveBubble",
            @"hasProtectBubble", @"hasReviveBubble", @"hasRebornBubble",
            @"canHelpRevive", @"canHelpProtect", @"canHelpReborn",
            @"canReborn", @"canRebornBubble", @"rebornBubble",
            @"protectFlag", @"rebornFlag", @"reviveFlag", @"fuhuoFlag",
            @"canProtectReborn", @"hasProtectReborn"
        ];
    });
    for (NSString *key in reviveKeys) {
        id val = dictRank[key] ?: (resData ? resData[key] : nil);
        if (val && val != NSNull.null) {
            if ([val respondsToSelector:@selector(boolValue)] && [val boolValue]) return YES;
            if ([val isKindOfClass:NSString.class]) {
                NSString *str = (NSString *)val;
                if ([str isEqualToString:@"Y"] || [str isEqualToString:@"1"] || [str caseInsensitiveCompare:@"true"] == NSOrderedSame) return YES;
            }
        }
    }
    
    // 5. 检查状态枚举值（protectStatus / rebornStatus / reviveStatus）
    for (NSString *key in @[ @"protectStatus", @"rebornStatus", @"reviveStatus" ]) {
        id pStatus = dictRank[key] ?: (resData ? resData[key] : nil);
        if (pStatus && pStatus != NSNull.null) {
            if ([pStatus respondsToSelector:@selector(integerValue)] && [pStatus integerValue] == 1) return YES;
            if ([pStatus isKindOfClass:NSString.class]) {
                NSString *str = (NSString *)pStatus;
                if ([str containsString:@"PROTECT"] || [str containsString:@"REVIVE"] || [str containsString:@"REBORN"] || [str containsString:@"CAN"]) return YES;
            }
        }
    }
    
    // 6. 检查待复活奖励能量字段（如 protectRewardEnergy: 5, rebornEnergy: "5g" 等）
    for (NSString *key in @[ @"protectRewardEnergy", @"rebornRewardEnergy", @"protectEnergy", @"rebornEnergy", @"reviveEnergy" ]) {
        id val = dictRank[key] ?: (resData ? resData[key] : nil);
        if (val && val != NSNull.null) {
            if ([val respondsToSelector:@selector(integerValue)] && [val integerValue] > 0) return YES;
            if ([val isKindOfClass:NSString.class]) {
                NSString *str = (NSString *)val;
                if ([str containsString:@"5"]) return YES;
            }
        }
    }
    
    // 7. 检查 UI 气泡徽章与标签（即用户排行榜截图右侧醒目的橙色“+5g”待复活气泡）
    for (NSString *key in @[ @"actionText", @"rightDesc", @"tag", @"tagText", @"tagDesc", @"badge", @"badgeText", @"bubbleText", @"subTitle", @"operateType", @"buttonText", @"robFlag", @"userRobFlag" ]) {
        id val = dictRank[key] ?: (resData ? resData[key] : nil);
        if (val && val != NSNull.null) {
            if ([val isKindOfClass:NSString.class]) {
                NSString *text = (NSString *)val;
                if ([text containsString:@"+5g"] || [text containsString:@"+5G"] || [text containsString:@"5g"] ||
                    [text containsString:@"复活"] || [text containsString:@"reborn"] || [text containsString:@"protect"]) {
                    return YES;
                }
            } else if ([val isKindOfClass:NSDictionary.class]) {
                NSDictionary *d = (NSDictionary *)val;
                for (id subVal in d.allValues) {
                    if ([subVal isKindOfClass:NSString.class]) {
                        NSString *text = (NSString *)subVal;
                        if ([text containsString:@"+5g"] || [text containsString:@"+5G"] || [text containsString:@"5g"] ||
                            [text containsString:@"复活"] || [text containsString:@"reborn"] || [text containsString:@"protect"]) {
                            return YES;
                        }
                    }
                }
            }
        }
    }
    
    // 8. 检查 robFlags 列表（部分接口将标记放在数组内）
    for (NSString *key in @[ @"robFlags", @"userRobFlags", @"userRobFlagList", @"tags" ]) {
        id list = dictRank[key] ?: (resData ? resData[key] : nil);
        if ([list isKindOfClass:NSArray.class]) {
            for (id item in (NSArray *)list) {
                NSString *text = [NSString stringWithFormat:@"%@", item];
                if ([text containsString:@"protect"] || [text containsString:@"reborn"] ||
                    [text containsString:@"revive"] || [text containsString:@"fuhuo"] ||
                    [text containsString:@"5g"] || [text containsString:@"5G"]) {
                    return YES;
                }
            }
        }
    }
    
    // 9. 智能兜底扫描：遍历排行榜条目中的非常规字段，精准识别任何含有 +5g 或 protect/reborn 特征的属性
    static NSSet<NSString *> *excludedNameKeys = nil;
    static dispatch_once_t onceExclude;
    dispatch_once(&onceExclude, ^{
        excludedNameKeys = [NSSet setWithObjects:@"userId", @"userName", @"displayName", @"loginId", @"realName",
                            @"avatar", @"icon", @"headImg", @"photo", @"mediumIcon", @"tinyIcon", @"largeIcon",
                            @"rank", @"ranking", @"energy", @"certificateCount", @"canCollectEnergy", nil];
    });
    for (NSString *key in dictRank) {
        if ([excludedNameKeys containsObject:key]) continue;
        id val = dictRank[key];
        if ([val isKindOfClass:NSString.class]) {
            NSString *str = (NSString *)val;
            if ([str containsString:@"+5g"] || [str containsString:@"+5G"]) {
                return YES;
            }
            NSString *lowKey = key.lowercaseString;
            if (([lowKey containsString:@"reborn"] || [lowKey containsString:@"fuhuo"] || ([lowKey containsString:@"protect"] && ![lowKey containsString:@"shield"])) &&
                ([str isEqualToString:@"Y"] || [str isEqualToString:@"1"] || [str caseInsensitiveCompare:@"true"] == NSOrderedSame || [str containsString:@"CAN"])) {
                return YES;
            }
        } else if ([val isKindOfClass:NSNumber.class]) {
            NSString *lowKey = key.lowercaseString;
            if (([lowKey containsString:@"reborn"] || [lowKey containsString:@"fuhuo"] || ([lowKey containsString:@"protect"] && ![lowKey containsString:@"shield"])) &&
                [val boolValue]) {
                return YES;
            }
        }
    }
    
    return NO;
}

static NSInteger reviveDailyCount(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *today = getCurrentDateString();
    if (![[defaults stringForKey:@"autoReviveDate"] isEqualToString:today]) {
        [defaults setObject:today forKey:@"autoReviveDate"];
        [defaults setObject:@[] forKey:@"autoReviveSuccessFriendsToday"];
        [defaults setBool:NO forKey:@"autoReviveLimitReachedToday"];
        [defaults setInteger:0 forKey:@"autoReviveCount"];
        [defaults synchronize];
        [reviveQueue removeAllObjects];
        [reviveQueuedIds removeAllObjects];
    }
    if ([defaults boolForKey:@"autoReviveLimitReachedToday"]) {
        return 6;
    }
    NSArray *successList = [defaults arrayForKey:@"autoReviveSuccessFriendsToday"];
    if ([successList isKindOfClass:NSArray.class]) {
        return successList.count;
    }
    // 首次运行或兼容旧版本：清空旧版本残留的脏数据 autoReviveCount，重置为 0
    [defaults setObject:@[] forKey:@"autoReviveSuccessFriendsToday"];
    [defaults setBool:NO forKey:@"autoReviveLimitReachedToday"];
    [defaults setInteger:0 forKey:@"autoReviveCount"];
    [defaults synchronize];
    return 0;
}

- (void)reviveRefreshRewardIfNeeded {
    if (!reviveRewardRefreshNeeded || !self.enableSelfCollect || !self.jsBridge) return;
    reviveRewardRefreshNeeded = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1200 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        if (self.enableSelfCollect && self.jsBridge) {
            [self recordStage:@"复活奖励：请求本人首页"];
            [self queryMyBubbles];
        }
    });
}

- (void)reviveStopWithReason:(NSString *)reason {
    reviveRunning = NO;
    reviveCurrentUserId = nil;
    reviveRequestToken++;
    [reviveQueue removeAllObjects];
    if (reason.length) [self recordStage:[NSString stringWithFormat:@"复活 · %@", reason]];
    [self reviveRefreshRewardIfNeeded];
}

- (void)reviveSendNext {
    if (!isWithinReviveHours()) {
        reviveRunning = NO;
        reviveCurrentUserId = nil;
        return;
    }
    if (!self.enableAutoRevive) {
        if (reviveRunning) [self reviveStopWithReason:@"任务已停止"];
        return;
    }
    if (!self.jsBridge) {
        [self probeAndRestoreBridges];
        if (!self.jsBridge) {
            reviveRunning = NO;
            reviveCurrentUserId = nil;
            return;
        }
    }
    if (reviveDailyCount() >= 6) {
        [NSUserDefaults.standardUserDefaults setInteger:6 forKey:@"autoReviveCount"];
        [self recordStage:@"复活 · 帮复活能量已达支付宝官方上限（6/6 次）"];
        reviveRunning = NO;
        reviveCurrentUserId = nil;
        [reviveQueue removeAllObjects];
        return;
    }
    if (!reviveQueue.count) {
        reviveRunning = NO;
        reviveCurrentUserId = nil;
        [self reviveRefreshRewardIfNeeded];
        return;
    }
    reviveRunning = YES;
    reviveCurrentUserId = reviveQueue.firstObject;
    [reviveQueue removeObjectAtIndex:0];
    NSUInteger token = ++reviveRequestToken;
    NSString *timestamp = [NSString stringWithFormat:@"%ld", (long)(NSDate.date.timeIntervalSince1970 * 1000)];
    NSString *name = [AntForestManager extractNameFromDictionary:self.friendsName[reviveCurrentUserId]] ?: @"好友";
    NSDictionary *body = @{ @"targetUserId": reviveCurrentUserId, @"version": @"20241025", @"source": @"chInfo_ch_appcenter__chsub_9patch" };
    NSDictionary *data = @{ @"handlerName": @"rpc", @"data": @{ @"operationType": @"alipay.antforest.forest.h5.protectBubble", @"headers": @{ @"source": @"chInfo_ch_appcenter__chsub_9patch", @"ags-source": @"chInfo_ch_appcenter__chsub_9patch" }, @"requestData": @[body], @"getResponse": @YES }, @"callbackId": [NSString stringWithFormat:@"revive_%@.%@", timestamp, [AntForestManager getNumberRandom:12]] };
    NSString *queue1 = waterJSONString(@[data]);
    if (!queue1.length) {
        if (reviveCurrentUserId.length) [reviveQueuedIds addObject:reviveCurrentUserId];
        reviveRunning = NO;
        reviveCurrentUserId = nil;
        if (reviveQueue.count > 0) [self reviveSendNext];
        return;
    }
    NSString *url = @"https://render.alipay.com/p/yuyan/180020010001247580/home.html";
    [self recordStage:[NSString stringWithFormat:@"复活 · 请求帮助好友“%@”复活能量", name]];
    [self safeFlushBridge:self.jsBridge message:queue1 url:url];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (reviveRunning && token == reviveRequestToken) {
            NSString *timeoutUser = reviveCurrentUserId;
            if (timeoutUser.length) [reviveQueuedIds addObject:timeoutUser];
            [self recordStage:[NSString stringWithFormat:@"复活 · 帮助好友“%@”复活回包超时，尝试下一位", name]];
            reviveRunning = NO;
            reviveCurrentUserId = nil;
            reviveRequestToken++;
            if (self.enableAutoRevive && reviveQueue.count > 0) {
                [self reviveSendNext];
            } else {
                [self reviveRefreshRewardIfNeeded];
            }
        }
    });
}

- (void)queueAutoReviveForUser:(NSString *)userId {
    if (!isWithinReviveHours()) return;
    if (!self.enableAutoRevive || !userId.length || [userId isEqualToString:self.myUserId]) return;
    NSInteger count = reviveDailyCount();
    if (count >= 6) {
        static NSDate *lastLimitLoggedDate = nil;
        if (!lastLimitLoggedDate || [[NSDate date] timeIntervalSinceDate:lastLimitLoggedDate] > 180) {
            lastLimitLoggedDate = [NSDate date];
            [self recordStage:[NSString stringWithFormat:@"复活 · 帮复活能量今日已达 6/6 上限，跳过后续好友（今日已成功复活 %ld 位）", (long)count]];
        }
        return;
    }
    if (reviveRunning && [reviveCurrentUserId isEqualToString:userId]) return;
    if ([reviveQueue containsObject:userId]) return;
    if ([reviveQueuedIds containsObject:userId]) return;
    NSString *name = [AntForestManager extractNameFromDictionary:self.friendsName[userId]] ?: @"好友";
    [self recordStage:[NSString stringWithFormat:@"复活 · 发现好友“%@”有待复活能量(+5g)，加入复活队列", name]];
    [reviveQueue addObject:userId];
    if (!reviveRunning) [self reviveSendNext];
}

- (void)handleAutoReviveResponse:(id)args {
    if (!reviveRunning || ![args isKindOfClass:NSDictionary.class]) return;
    NSDictionary *dict = (NSDictionary *)args;
    NSDictionary *resData = [dict[@"resData"] isKindOfClass:NSDictionary.class] ? dict[@"resData"] : dict;
    if (!resData) return;
    NSString *name = [AntForestManager extractNameFromDictionary:self.friendsName[reviveCurrentUserId]] ?: @"好友";
    BOOL isSuccess = waterResponseSucceeded(resData) || waterResponseSucceeded(dict) ||
                     [resData[@"success"] boolValue] || [dict[@"success"] boolValue] ||
                     [[resData[@"resultCode"] description] isEqualToString:@"SUCCESS"] ||
                     [[dict[@"resultCode"] description] isEqualToString:@"SUCCESS"];
    if (isSuccess) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSMutableArray *successList = [[defaults arrayForKey:@"autoReviveSuccessFriendsToday"] ?: @[] mutableCopy];
        if (reviveCurrentUserId.length && ![successList containsObject:reviveCurrentUserId]) {
            [successList addObject:reviveCurrentUserId];
            [defaults setObject:successList forKey:@"autoReviveSuccessFriendsToday"];
            [defaults setInteger:successList.count forKey:@"autoReviveCount"];
        }
        if (reviveCurrentUserId.length) [reviveQueuedIds addObject:reviveCurrentUserId];
        NSInteger count = successList.count;
        [self recordStage:[NSString stringWithFormat:@"复活 · 成功帮助好友“%@”复活能量（今日 %ld/6 次）", name, (long)MIN((NSInteger)6, count)]];
        reviveRewardRefreshNeeded = YES;
        reviveRunning = NO;
        reviveCurrentUserId = nil;
        reviveRequestToken++;
        double delaySec = 1.2 + (arc4random_uniform(1000) / 1000.0);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.enableAutoRevive) [self reviveSendNext];
        });
    } else {
        NSString *code = waterResponseCode(resData);
        if ([code isEqualToString:@"TARGET_USER_PROTECT_BY_ENERGY_SHIELD"]) {
            if (reviveCurrentUserId.length) [reviveQueuedIds addObject:reviveCurrentUserId];
            [self recordStage:[NSString stringWithFormat:@"复活 · 好友“%@”已有能量保护罩，已跳过", name]];
            reviveRunning = NO;
            reviveCurrentUserId = nil;
            reviveRequestToken++;
            double delaySec = 1.0 + (arc4random_uniform(800) / 1000.0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self.enableAutoRevive) [self reviveSendNext];
            });
            return;
        }
        
        NSString *memo = [NSString stringWithFormat:@"%@ %@", resData[@"resultDesc"] ?: @"", resData[@"memo"] ?: dict[@"memo"] ?: @""];
        BOOL isDailyLimit = [code isEqualToString:@"PROTECT_REBORN_TIRED"] ||
                            [code isEqualToString:@"DAILY_PROTECT_LIMIT"] ||
                            [code isEqualToString:@"TODAY_PROTECT_LIMIT"] ||
                            [code isEqualToString:@"USER_DAILY_PROTECT_LIMIT"] ||
                            [code isEqualToString:@"DAILY_LIMIT_EXCEEDED"] ||
                            [memo containsString:@"今天帮助复活次数已达上限"] ||
                            [memo containsString:@"今日帮助复活次数已达上限"] ||
                            [memo containsString:@"今日复活次数已达上限"] ||
                            [memo containsString:@"今天复活次数已达上限"] ||
                            [memo containsString:@"每日最多帮助"];
        if (isDailyLimit) {
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"autoReviveLimitReachedToday"];
            [NSUserDefaults.standardUserDefaults setInteger:6 forKey:@"autoReviveCount"];
            [NSUserDefaults.standardUserDefaults synchronize];
            [self recordStage:@"复活 · 帮复活能量已达支付宝官方上限（今天已用完，明天再继续吧）"];
            reviveRunning = NO;
            reviveCurrentUserId = nil;
            reviveRequestToken++;
            [reviveQueue removeAllObjects];
            return;
        }
        
        if (reviveCurrentUserId.length) [reviveQueuedIds addObject:reviveCurrentUserId];
        [self recordStage:[NSString stringWithFormat:@"复活 · 帮助好友“%@”复活未完成：%@，尝试下一位", name, waterResponseSummary(resData)]];
        reviveRunning = NO;
        reviveCurrentUserId = nil;
        reviveRequestToken++;
        double delaySec = 1.0 + (arc4random_uniform(800) / 1000.0);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.enableAutoRevive) [self reviveSendNext];
        });
    }
}

- (void)waterFinishCurrentFriendWithStatus:(NSString *)status {
    NSString *name = [self waterDisplayNameForUser:waterCurrentUserId];
    if (status.length) [self recordStage:[NSString stringWithFormat:@"浇水 · %@：%@", name, status]];
    waterQueueIndex++;
    waterCurrentUserId = nil;
    waterCurrentBizNo = nil;
    waterTargetCount = 0;
    waterSucceededCount = 0;
    waterRetryCount = 0;
    waterAwaitingHome = waterAwaitingLimit = waterAwaitingTransfer = NO;
    waterRequestToken++;
    [self performSelector:@selector(waterStartNextFriend) withObject:nil afterDelay:kWaterTransferCooldown];
}

- (void)waterStopWithReason:(NSString *)reason {
    if (!waterRunning) return;
    waterRunning = NO;
    waterAwaitingHome = waterAwaitingLimit = waterAwaitingTransfer = NO;
    waterRequestToken++;
    [self recordStage:[NSString stringWithFormat:@"浇水 · 任务结束：%@", reason]];
    waterQueue = nil;
    waterCurrentUserId = nil;
    waterCurrentBizNo = nil;
    if (!collectAfterLaunchWater) return;
    collectAfterLaunchWater = NO;
    if (!self.enableAutoCollect || !self.jsBridge) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self recordStage:@"蚂蚁森林自动浇水结束，开始自动收取"];
        [self autoCollectBubbles];
    });
}

- (void)waterSendRPC:(NSString *)operation body:(NSDictionary *)body {
    if (!self.jsBridge) { [self waterStopWithReason:@"H5 Bridge 未连接"]; return; }
    NSString *timestamp = [NSString stringWithFormat:@"%ld", (long)(NSDate.date.timeIntervalSince1970 * 1000)];
    NSString *callback = [NSString stringWithFormat:@"water_%@.%@", timestamp, [AntForestManager getNumberRandom:12]];
    NSDictionary *data = @{ @"handlerName": @"rpc", @"data": @{ @"operationType": operation, @"headers": @{ @"source": @"chInfo_ch_appcenter__chsub_9patch", @"ags-source": @"chInfo_ch_appcenter__chsub_9patch" }, @"requestData": @[body], @"getResponse": @YES }, @"callbackId": callback };
    NSString *queue = waterJSONString(@[data]);
    if (!queue.length) { [self waterStopWithReason:@"请求编码失败"]; return; }
    NSString *url = @"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&__webview_options__=bc%3D3194732";
    [self.jsBridge _doFlushMessageQueue:queue url:url];
}

- (void)waterRequestFriendHome {
    NSUInteger requestToken = ++waterRequestToken;
    waterAwaitingHome = YES;
    waterAwaitingLimit = waterAwaitingTransfer = NO;
    NSDictionary *body = @{ @"userId": waterCurrentUserId, @"version": @"20241025", @"source": @"chInfo_ch_appcenter__chsub_9patch", @"fromAct": @"TAKE_LOOK", @"configVersionMap": @{ @"wateringBubbleConfig": @"0" }, @"skipWhackMole": @NO, @"activityParam": @{}, @"currentEnergy": @99999999, @"currentVitalityAmount": @8888888 };
    [self waterSendRPC:@"alipay.antforest.forest.h5.queryFriendHomePage" body:body];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!waterRunning || requestToken != waterRequestToken || !waterAwaitingHome) return;
        if (waterRetryCount++ == 0) { [self waterRequestFriendHome]; return; }
        [self waterFinishCurrentFriendWithStatus:@"好友主页回包超时，已跳过"];
    });
}

- (void)waterRequestLimit {
    NSUInteger requestToken = ++waterRequestToken;
    waterAwaitingHome = NO;
    waterAwaitingLimit = YES;
    waterRetryCount = 0;
    [self waterSendRPC:@"alipay.antforest.forest.h5.queryMiscInfo" body:@{ @"queryBizType": @"waterLimit", @"source": @"SELF_HOME", @"targetUserId": waterCurrentUserId, @"version": @"20230501" }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!waterRunning || requestToken != waterRequestToken || !waterAwaitingLimit) return;
        if (waterRetryCount++ == 0) { [self waterRequestLimit]; return; }
        [self waterFinishCurrentFriendWithStatus:@"浇水限额回包超时，已跳过"];
    });
}

- (void)waterTransferOnce {
    NSUInteger requestToken = ++waterRequestToken;
    waterAwaitingLimit = NO;
    waterAwaitingTransfer = YES;
    NSDictionary *extInfoDict = self.waterReminderEnabled ? @{
        @"sendChat": @"true",
        @"sendMsg": @"true",
        @"remind": @"true",
        @"remindCollect": @"true",
        @"notice": @"true",
        @"remindFriend": @"true",
        @"fillMsg": @"true",
        @"waterRemind": @"true",
        @"remindText": @"提醒TA来收（7天不收会退回）"
    } : @{
        @"sendChat": @"false",
        @"remind": @"false"
    };
    NSString *extInfoJson = waterJSONString(extInfoDict) ?: @"{}";
    
    NSDictionary *body = @{
        @"bizNo": waterCurrentBizNo,
        @"energyId": @(self.waterEnergyId),
        @"extInfo": extInfoDict,
        @"extInfoStr": extInfoJson,
        @"from": @"",
        @"source": @"chInfo_ch_appcenter__chsub_9patch",
        @"targetUser": waterCurrentUserId,
        @"transferType": @"WATERING",
        @"version": @"20241025"
    };
    [self recordStage:[NSString stringWithFormat:@"浇水 · 诊断：请求第 %lu/%lu 次浇水（提醒=%@）", (unsigned long)(waterSucceededCount + 1), (unsigned long)waterTargetCount, self.waterReminderEnabled ? @"开" : @"关"]];
    [self waterSendRPC:@"alipay.antforest.forest.h5.transferEnergy" body:body];
    [self waterSendRPC:@"alipay.antmember.forest.h5.transferEnergy" body:body];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!waterRunning || requestToken != waterRequestToken || !waterAwaitingTransfer) return;
        if (waterTransferRetryCount++ == 0) {
            waterAwaitingTransfer = NO;
            waterRetryCount = 0;
            [self recordStage:@"浇水 · 收取回包超时，重新获取好友凭据后重试"];
            [self waterRequestFriendHome];
            return;
        }
        [self waterFinishCurrentFriendWithStatus:[NSString stringWithFormat:@"第 %lu 次浇水未确认，已跳过", (unsigned long)(waterSucceededCount + 1)]];
    });
}

- (void)waterStartNextFriend {
    if (!waterRunning) return;
    if (waterQueueIndex >= waterQueue.count) { [self waterStopWithReason:[NSString stringWithFormat:@"%@完成", waterRunReason ?: @"浇水"]]; return; }
    waterCurrentUserId = waterQueue[waterQueueIndex];
    if (!waterCurrentUserId.length || [waterCurrentUserId isEqualToString:self.myUserId]) { [self waterFinishCurrentFriendWithStatus:@"无效好友，已跳过"]; return; }
    NSInteger done = [waterDailyCounts()[waterCurrentUserId] integerValue];
    NSInteger remaining = MAX(0, 3 - done);
    if (!remaining) { [self waterFinishCurrentFriendWithStatus:@"今日已浇满 3 次，已跳过"]; return; }
    waterTargetCount = (NSUInteger)remaining;
    waterSucceededCount = 0;
    waterRetryCount = 0;
    waterTransferRetryCount = 0;
    [self waterRequestFriendHome];
}

- (void)startWateringSelectedFriendsWithReason:(NSString *)reason {
    if (waterRunning) { [self recordStage:@"浇水 · 当前任务仍在执行"]; return; }
    NSArray *friends = [[NSOrderedSet orderedSetWithArray:self.waterFriendIds ?: @[]].array filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *uid, __unused NSDictionary *bindings) { return uid.length > 0; }]];
    if (!friends.count) { [self recordStage:@"浇水 · 未选择好友"]; return; }
    if (!self.jsBridge) { [self recordStage:@"浇水 · H5 Bridge 未连接"]; return; }
    waterRunning = YES;
    waterQueue = friends;
    waterQueueIndex = 0;
    waterRunReason = reason ?: @"手动浇水";
    [self recordStage:[NSString stringWithFormat:@"浇水 · %@开始：%lu 位好友，%ld g，每人补足至每日 3 次", waterRunReason, (unsigned long)friends.count, (long)self.waterGrams]];
    [self waterStartNextFriend];
}

- (void)startLaunchWateringThenCollect {
    BOOL shouldCollect = self.enableAutoCollect;
    if (waterLaunchAttempted) {
        if (shouldCollect) [self autoCollectBubbles];
        return;
    }
    waterLaunchAttempted = YES;
    if (waterRunning) {
        [self recordStage:@"蚂蚁森林自动浇水跳过：已有浇水任务运行中"];
        if (shouldCollect) [self autoCollectBubbles];
        return;
    }
    if (!self.waterFriendIds.count) {
        [self recordStage:@"蚂蚁森林自动浇水跳过：未选择好友"];
        if (shouldCollect) [self autoCollectBubbles];
        return;
    }
    collectAfterLaunchWater = shouldCollect;
    [self startWateringSelectedFriendsWithReason:@"蚂蚁森林自动浇水"];
}

- (void)handleWaterResponse:(id)args {
    if (!waterRunning || ![args isKindOfClass:NSDictionary.class]) return;
    if (waterAwaitingHome) {
        NSString *bizNo = [waterFindValue(args, @"bizNo", 0) isKindOfClass:NSString.class] ? waterFindValue(args, @"bizNo", 0) : nil;
        if (!bizNo.length) return;
        waterCurrentBizNo = bizNo;
        [self recordStage:@"浇水 · 已获取好友主页凭据"];
        [self waterRequestLimit];
        return;
    }
    if (waterAwaitingLimit) {
        if (!waterFindValue(args, @"waterLimit", 0)) return;
        [self recordStage:@"浇水 · 已通过浇水限额校验"];
        [self waterTransferOnce];
        return;
    }
    if (!waterAwaitingTransfer) return;
    [self recordStage:[NSString stringWithFormat:@"浇水 · 诊断：收取回包 %@", waterResponseSummary(args)]];
    if (!waterResponseSucceeded(args)) {
        NSString *code = waterResponseCode(args);
        if ([code isEqualToString:@"WATERING_TIMES_LIMIT"]) {
            NSMutableDictionary *counts = waterDailyCounts();
            counts[waterCurrentUserId] = @3;
            saveWaterDailyCounts(counts);
            [self waterFinishCurrentFriendWithStatus:@"服务端确认今日已浇满 3 次，已跳过"];
            return;
        }
        if ([code isEqualToString:@"WATER_NOT_GET_LOCK"] || [code isEqualToString:@"PARAM_ILLEGAL"]) {
            waterAwaitingTransfer = NO;
            waterRequestToken++;
            if (waterTransferRetryCount++ == 0) {
                NSTimeInterval delay = [code isEqualToString:@"WATER_NOT_GET_LOCK"] ? 2.0 : kWaterTransferCooldown;
                [self recordStage:[NSString stringWithFormat:@"浇水 · %@，%.0f 秒后重新获取凭据重试", [code isEqualToString:@"WATER_NOT_GET_LOCK"] ? @"服务端限流" : @"服务端参数异常", delay]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (waterRunning && !waterAwaitingHome && !waterAwaitingLimit && !waterAwaitingTransfer) [self waterRequestFriendHome];
                });
                return;
            }
            [self waterFinishCurrentFriendWithStatus:[NSString stringWithFormat:@"第 %lu 次浇水被服务端拒绝（%@），已跳过", (unsigned long)(waterSucceededCount + 1), code]];
            return;
        }
        if (waterResponseInsufficient(args)) [self waterStopWithReason:@"能量不足"];
        return;
    }
    waterAwaitingTransfer = NO;
    waterRetryCount = 0;
    waterTransferRetryCount = 0;
    waterSucceededCount++;
    NSMutableDictionary *counts = waterDailyCounts();
    counts[waterCurrentUserId] = @([counts[waterCurrentUserId] integerValue] + 1);
    saveWaterDailyCounts(counts);
    [self recordStage:[NSString stringWithFormat:@"浇水 · %@：成功 %lu/%lu，%ld g", [self waterDisplayNameForUser:waterCurrentUserId], (unsigned long)waterSucceededCount, (unsigned long)waterTargetCount, (long)self.waterGrams]];
    if (self.waterReminderEnabled && waterCurrentUserId.length) {
        NSDictionary *remindBody = @{
            @"targetUserId": waterCurrentUserId,
            @"bizType": @"WATERING",
            @"source": @"chInfo_ch_appcenter__chsub_9patch",
            @"version": @"20230501"
        };
        [self waterSendRPC:@"alipay.antmember.forest.h5.waterReminder" body:remindBody];
    }
    if (waterSucceededCount >= waterTargetCount) [self waterFinishCurrentFriendWithStatus:@"本次完成"];
    else dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWaterTransferCooldown * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (waterRunning) [self waterRequestFriendHome]; });
}

- (void)refreshWaterFriends {
    // 好友浇水列表只认本次总能量榜快照，不能混入历史昵称缓存。
    [self.friendsRank removeAllObjects];
    waterFriendRefreshPending = YES;
    [self queryTotalRank];
    [self recordStage:@"浇水 · 已请求刷新好友列表"];
}

- (void)startScheduledWaterTimer {
    [self.scheduledWaterTimer invalidate];
    self.scheduledWaterTimer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(checkScheduledWater) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.scheduledWaterTimer forMode:NSRunLoopCommonModes];
    [self checkScheduledWater];
}

- (void)checkScheduledWater {
    if (!self.enableAutoWater) return;
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init]; formatter.dateFormat = @"HH:mm";
    NSString *time = [formatter stringFromDate:NSDate.date];
    if (![self.waterScheduledTimes containsObject:time]) return;
    formatter.dateFormat = @"yyyy-MM-dd HH:mm";
    NSString *minute = [formatter stringFromDate:NSDate.date];
    if ([lastWaterScheduledMinute isEqualToString:minute]) return;
    lastWaterScheduledMinute = minute;
    [self startWateringSelectedFriendsWithReason:@"定时浇水"];
}

- (void)updateWaterFriendListFromResponse:(NSDictionary *)dict {
    if (!waterFriendRefreshPending) return;
    NSArray *contacts = [dict[@"contactsDicArray"] isKindOfClass:NSArray.class] ? dict[@"contactsDicArray"] : nil;
    if (contacts.count) {
        for (NSDictionary *contact in contacts) {
            NSString *uid = [AntForestManager extractUserIdFromDictionary:contact];
            if (uid.length) self.friendsName[uid] = contact;
        }
    }
    NSDictionary *resData = [dict[@"resData"] isKindOfClass:NSDictionary.class] ? dict[@"resData"] : nil;
    NSArray *rankings = [resData[@"totalDatas"] isKindOfClass:NSArray.class] ? resData[@"totalDatas"] : nil;
    if (!rankings.count) rankings = [resData[@"friendRanking"] isKindOfClass:NSArray.class] ? resData[@"friendRanking"] : nil;
    if (!rankings.count) return;
    [self.friendsRank removeAllObjects];
    for (NSDictionary *ranking in rankings) {
        NSString *uid = [AntForestManager extractUserIdFromDictionary:ranking];
        if (uid.length) {
            self.friendsRank[uid] = ranking[@"rank"] ?: @0;
            NSString *name = [AntForestManager extractNameFromDictionary:ranking];
            if (name.length) {
                NSMutableDictionary *contact = [self.friendsName[uid] mutableCopy] ?: [NSMutableDictionary dictionary];
                contact[@"displayName"] = name;
                self.friendsName[uid] = contact;
            }
        }
    }
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:self.friendsName requiringSecureCoding:NO error:nil];
    if (data) {
        [[NSUserDefaults standardUserDefaults] setObject:data forKey:@"friendsName"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    waterFriendRefreshPending = NO;
    [self recordStage:[NSString stringWithFormat:@"浇水 · 好友列表刷新完成：%lu 位", (unsigned long)self.friendsRank.count]];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"WaterFriendListUpdated" object:nil];
}

- (void)releaseSelfPriorityForCycle:(NSUInteger)cycle reason:(NSString *)reason {
    if (!selfPriorityPending || selfPriorityCycle != cycle) return;
    selfPriorityPending = NO;
    NSArray<NSString *> *friendIds = deferredFriendRankIds.copy;
    [deferredFriendRankIds removeAllObjects];
    deferredRankedFriendIds = nil;
    [self recordStage:[NSString stringWithFormat:@"本人优先完成，开始好友扫描（%@）", reason]];
    for (NSString *friendId in friendIds) {
        dispatch_async(globalSerialQueueQuery, ^{
            [self queryFriendsBubbles:friendId];
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        if (self.enableAutoCollect && cycle == collectionCycle && self.isScanRunning) {
            [self startTakeLookContinuation];
        }
    });
}

+ (NSLock*)sharedLock {
    static NSLock *sharedLock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedLock = [[NSLock alloc] init];
    });
    return sharedLock;
}

- (void)recordStage:(NSString *)stage {
    if (!stage.length) return;
    if ([stage hasPrefix:@"诊断 ·"]) {
        NSLog(@"[AntForestPort][Diag] %@", stage);
        return;
    }
    NSString *cleanStage = stage;
    if ([cleanStage hasPrefix:@"收取 · "]) {
        cleanStage = [cleanStage substringFromIndex:@"收取 · ".length];
    } else if ([cleanStage hasPrefix:@"收取 ·"]) {
        cleanStage = [cleanStage substringFromIndex:@"收取 ·".length];
    }
    if (self.logRecord) [self addLog:[NSString stringWithFormat:@"%@\n%@", getCurrentDateTimeString(), cleanStage]];
}

static NSMutableArray<NSString *> *patrolProbeLogs = nil;

static BOOL isNoiseProbeLog(NSString *log) {
    if (!log) return YES;
    if ([log containsString:@"deliverByPageId"] ||
        [log containsString:@"ANTFOREST_GAME_CENTER_FLOW"] ||
        [log containsString:@"offlineResources"] ||
        [log containsString:@"manifest.json"] ||
        [log containsString:@"runtime."] ||
        [log containsString:@"all_vendor."] ||
        [log containsString:@"galacean_downgrade"] ||
        [log containsString:@"signInWarmCopyConfig"] ||
        [log containsString:@"swiper.min"] ||
        [log containsString:@"dataPrefetch"] ||
        [log containsString:@"contactsDicArray"] ||
        [log containsString:@"recentApps"] ||
        [log containsString:@"systemMemoryLevel"] ||
        [log containsString:@"screenReaderEnabled"] ||
        [log containsString:@"SHOULDUSENEWTOUCHEVENT"] ||
        [log containsString:@"\"safeArea\""] ||
        [log containsString:@"queryFriendHomePage"] ||
        [log containsString:@"setAPDataStorage"] ||
        [log containsString:@"getAPDataStorage"] ||
        [log containsString:@"batchQuerySendTreeItems"] ||
        [log containsString:@"querySendTreeFriendList"]) {
        return YES;
    }
    return NO;
}

+ (BOOL)isManorURL:(NSURL *)url {
    if (!url) return NO;
    NSString *text = [url.absoluteString lowercaseString];
    if ([text containsString:@"180020010001247580"] || [text containsString:@"home.html"]) return NO; // 森林首页
    if ([text containsString:@"180020010001263018"] || [text containsString:@"68687599"] || [text containsString:@"babafarm"] || [text containsString:@"alipayfarm"]) return NO; // 芭芭农场
    if ([text containsString:@"2021003115672468"] || [text containsString:@"antocean"]) return NO; // 神奇海洋
    return [text containsString:@"66666674"] ||
           [text containsString:@"2017090512380701"] ||
           [text containsString:@"antfarm"] ||
           [text containsString:@"ant_farm"];
}

+ (BOOL)isManorResponse:(id)value {
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *dict = (NSDictionary *)value;
    NSDictionary *resData = [dict[@"resData"] isKindOfClass:NSDictionary.class] ? dict[@"resData"] : dict;
    
    // 明确的森林与农场回包，绝不当做庄园处理！
    if (dict[@"bubbles"] || resData[@"bubbles"] ||
        dict[@"wateringBubbles"] || resData[@"wateringBubbles"] ||
        dict[@"totalDatas"] || resData[@"totalDatas"] ||
        dict[@"friendRanking"] || resData[@"friendRanking"] ||
        dict[@"combineHandlerVOMap"] || resData[@"combineHandlerVOMap"] ||
        dict[@"limitedTimeChallenge"] || resData[@"limitedTimeChallenge"] ||
        dict[@"manureFactory"] || resData[@"manureFactory"] ||
        dict[@"subplotsActivityList"] || resData[@"subplotsActivityList"]) {
        return NO;
    }
    
    NSString *opType = [NSString stringWithFormat:@"%@", (dict[@"operationType"] ?: resData[@"operationType"]) ?: @""];
    if ([opType containsString:@"com.alipay.antfarm"] || [opType containsString:@"antfarm."]) return YES;
    
    // 庄园进入主页核心结构：包含 subFarmVO 或 dynamicGlobalConfig 或 farmTaskList
    if (resData[@"subFarmVO"] || dict[@"subFarmVO"]) {
        return YES;
    }
    if (resData[@"dynamicGlobalConfig"] || dict[@"dynamicGlobalConfig"]) {
        return YES;
    }
    if (resData[@"farmTaskList"] || dict[@"farmTaskList"]) {
        return YES;
    }
    if (resData[@"antfarmP2POfflineTime"] || dict[@"antfarmP2POfflineTime"]) {
        return YES;
    }
    return NO;
}

- (void)recordProbeLog:(NSString *)log {
#if !ENABLE_PROBE_LOGS
    return;
#else
    if (!log.length) return;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        patrolProbeLogs = [NSMutableArray array];
    });
    NSString *timeStr = getCurrentDateTimeString();
    NSString *entry = [NSString stringWithFormat:@"[%@] %@", timeStr, log];
    @synchronized (patrolProbeLogs) {
        [patrolProbeLogs addObject:entry];
        if (patrolProbeLogs.count > 500) {
            [patrolProbeLogs removeObjectAtIndex:0];
        }
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        @try {
            NSString *docPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            NSString *filePath = [docPath stringByAppendingPathComponent:@"AntForestPatrolProbe.log"];
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:filePath];
            if (!handle) {
                [[NSFileManager defaultManager] createFileAtPath:filePath contents:nil attributes:nil];
                handle = [NSFileHandle fileHandleForWritingAtPath:filePath];
            }
            [handle seekToEndOfFile];
            [handle writeData:[[entry stringByAppendingString:@"\n\n"] dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        } @catch (NSException *e) {}
    });
#endif
}

- (void)clearProbeLogs {
    @synchronized (patrolProbeLogs) {
        [patrolProbeLogs removeAllObjects];
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        @try {
            NSString *docPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            NSString *filePath = [docPath stringByAppendingPathComponent:@"AntForestPatrolProbe.log"];
            [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
        } @catch (NSException *e) {}
    });
}

- (NSArray<NSString *> *)probeRecords {
#if !ENABLE_PROBE_LOGS
    return @[];
#else
    @synchronized (patrolProbeLogs) {
        if (patrolProbeLogs.count > 0) {
            return [patrolProbeLogs copy];
        }
    }
    @try {
        NSString *docPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *filePath = [docPath stringByAppendingPathComponent:@"AntForestPatrolProbe.log"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
            NSString *content = [NSString stringWithContentsOfFile:filePath encoding:NSUTF8StringEncoding error:nil];
            if (content.length) {
                NSArray *lines = [content componentsSeparatedByString:@"\n\n"];
                NSMutableArray *res = [NSMutableArray array];
                for (NSString *l in lines) {
                    NSString *trim = [l stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (trim.length) [res addObject:trim];
                }
                return res;
            }
        }
    } @catch (NSException *e) {}
    return @[];
#endif
}

static dispatch_source_t sBackgroundPulseTimer = nil;

-(void)ensureBackgroundPulseTimer {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_queue_t queue = dispatch_queue_create("com.antforest.backgroundPulse", DISPATCH_QUEUE_SERIAL);
        sBackgroundPulseTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        // 每 5 秒脉冲一次，在真后台与 RunLoop 挂起时也能精准守候整秒翻转与超时看门狗
        dispatch_source_set_timer(sBackgroundPulseTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 5 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(sBackgroundPulseTimer, ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf checkScheduledCollect];
                [weakSelf checkScanDeadlockWatchdog];
            });
        });
        dispatch_resume(sBackgroundPulseTimer);
    });
}

-(void)checkScanDeadlockWatchdog {
    if (self.isScanRunning) {
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (self.lastScanStartTime > 0 && now - self.lastScanStartTime > 35.0) {
            [self recordStage:@"诊断 · 后台看门狗发现扫描超时（>35s），强制解除锁死"];
            self.isScanRunning = NO;
            takeLookRunning = NO;
            takeLookWaitingForFriend = NO;
            takeLookCurrentFriendId = nil;
            selfPriorityPending = NO;
        }
    }
}

-(void)startAutoCollectTimerWithInterval:(NSTimeInterval)interval{
    if (interval <= 0) {
        interval = 300;
    }
    if (self.autoCollectTimer.isValid && self.collectInterval == interval) {
        return;
    }
    [self.autoCollectTimer invalidate];
    self.autoCollectTimer = nil;
    self.collectInterval = interval;
    self.failedTimes = 0; //每次重新启动定时器时 失败次数均要置 0
    [self recordStage:[NSString stringWithFormat:@"后台循环已启动（%ld 分钟）", (long)MAX(1, interval / 60)]];
    
    // 使用 NSRunLoopCommonModes 防止界面交互或真后台模式切换时定时器冻结
    self.autoCollectTimer = [NSTimer timerWithTimeInterval:interval
                                                    target:self
                                                  selector:@selector(autoCollectBubbles)
                                                  userInfo:nil
                                                   repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.autoCollectTimer forMode:NSRunLoopCommonModes];
    [self ensureBackgroundPulseTimer];
    [self.autoCollectTimer fire];
}

-(void)stopAutoCollectTimer {
    [self.autoCollectTimer invalidate];
    self.autoCollectTimer = nil;
}

-(void)startScheduledCollectTimer {
    [self.scheduledCollectTimer invalidate];
    // 提升为 1.0 秒高频轮询，精准命中整点 00 秒（无缝秒级抢跑）
    self.scheduledCollectTimer = [NSTimer timerWithTimeInterval:1.0
                                                         target:self
                                                       selector:@selector(checkScheduledCollect)
                                                       userInfo:nil
                                                        repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.scheduledCollectTimer forMode:NSRunLoopCommonModes];
    [self ensureBackgroundPulseTimer];
    [self checkScheduledCollect];
}

-(void)checkScheduledCollect {
    if (!self.enableAutoCollect) return;
    
    NSDate *nowDate = [NSDate date];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"HH:mm";
    NSString *time = [formatter stringFromDate:nowDate];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm";
    NSString *minute = [formatter stringFromDate:nowDate];
    
    BOOL isScheduledTime = self.enableScheduledCollect && [self.scheduledTimes containsObject:time];
    // 特别强化：早 07:00 作为蚂蚁森林全局能量成熟爆发期，无论用户是否在列表中添加，均在 07:00:00 准点全力触发极速冲刺
    BOOL is7AmRush = [time isEqualToString:@"07:00"];
    
    if (!isScheduledTime && !is7AmRush) return;
    if ([lastScheduledMinute isEqualToString:minute]) return;
    lastScheduledMinute = minute;
    
    if (is7AmRush) {
        [self recordStage:@"⚡️ 早间 07:00:00 黄金时段：启动全速秒级无延迟能量冲刺！"];
        [self autoCollectBubblesWithRush:YES];
    } else {
        [self recordStage:[NSString stringWithFormat:@"定时收取开始（%@）", time]];
        [self autoCollectBubblesWithRush:YES];
    }
}

NSString* getCurrentDateString() {
    // 获取当前日期
    NSDate *currentDate = [NSDate date];
    
    // 创建日期格式化器
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    
    // 设置日期格式
    [formatter setDateFormat:@"yyyy-MM-dd"];
    
    // 返回格式化后的日期字符串
    return [formatter stringFromDate:currentDate];
}

NSString* getCurrentDateTimeString() {
    // 获取当前日期
    NSDate *currentDate = [NSDate date];
    
    // 创建日期格式化器
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    
    // 设置日期格式
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    
    // 返回格式化后的日期字符串
    return [formatter stringFromDate:currentDate];
}


+(NSString*)getNumberRandom:(int)count
{
    NSString *strRandom = @"";
    
    for(int i=0; i<count; i++)
    {
        strRandom = [ strRandom stringByAppendingFormat:@"%i",(arc4random() % 9)];
    }
    return strRandom;
}

static const NSTimeInterval kPkInteractionAvoidanceDuration = 8.0;

static inline BOOL isStrictPkOperationName(NSString *opType) {
    if (!opType.length) return NO;
    NSString *lower = [opType lowercaseString];
    if ([lower containsString:@"energychallenge"] ||
        [lower containsString:@"challengerank"] ||
        [lower containsString:@"pvphome"] ||
        [lower containsString:@"energypvp"] ||
        [lower containsString:@"matchpvp"] ||
        [lower containsString:@"filluserrobflag"]) {
        return YES;
    }
    if ([lower hasSuffix:@".pk"] || [lower containsString:@".pk."] || [lower containsString:@"pkhome"]) {
        return YES;
    }
    return NO;
}

//随机一个有能量的好友
-(void)takeLook{
    NSString *version = @"20231208";
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:15];
    __block NSArray<NSString *> *visitedFriends = nil;
    @synchronized (self) {
        visitedFriends = takeLookRunning ? takeLookVisitedFriends.allObjects : @[];
    }
    NSMutableDictionary *skipUsers = [NSMutableDictionary dictionaryWithCapacity:visitedFriends.count];
    for (NSString *friendId in visitedFriends) skipUsers[friendId] = @YES;
    NSData *skipUsersData = [NSJSONSerialization dataWithJSONObject:skipUsers options:0 error:nil];
    NSString *skipUsersJSON = [[NSString alloc] initWithData:skipUsersData encoding:NSUTF8StringEncoding] ?: @"{}";
    NSString *callbackId = [NSString stringWithFormat:@"rpc_af_silent_takelook_%@.%@", timeStamp, randNum];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.takeLook\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"skipUsers\":%@,\"version\":\"%@\",\"contactsStatus\":\"N\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\"}],\"getResponse\":true},\"callbackId\":\"%@\"}]",skipUsersJSON,version,callbackId];
    NSString *arg2 = @"https://render.alipay.com/p/yuyan/180020010001247580/home.html?__webview_options__=bc%3D3194732";
    
    if([self jsBridge]) {
        [self recordStage:[NSString stringWithFormat:@"诊断 · 请求找能量续查：已跳过 %lu 位", (unsigned long)visitedFriends.count]];
        [self safeFlushBridge:[self jsBridge] message:arg1 url:arg2];
        //FileLog(@"anthook takeLook");
    }
}

// 按“找能量”的候选顺序补扫，避免首页排行榜只返回局部好友时遗漏成熟能量。
-(void)startTakeLookContinuation {
    @synchronized (self) {
        if (takeLookRunning) return;
        takeLookRunning = YES;
        takeLookWaitingForFriend = NO;
        takeLookCurrentFriendId = nil;
        takeLookRounds = 0;
        takeLookPass = 1;
        takeLookTotalRounds = 0;
        takeLookRequestToken++;
        [takeLookVisitedFriends removeAllObjects];
    }
    [self recordStage:@"诊断 · 排行榜扫描结束，开始找能量续查"];
    [self requestNextTakeLook];
}

-(void)requestNextTakeLook {
    __block NSUInteger requestToken = 0;
    @synchronized (self) {
        if (!takeLookRunning || !self.enableAutoCollect || !self.jsBridge || takeLookTotalRounds >= kTakeLookMaxRounds) {
            NSString *reason = takeLookTotalRounds >= kTakeLookMaxRounds ? @"达到安全上限" : @"任务已停止或桥接不可用";
            takeLookRunning = NO;
            takeLookWaitingForFriend = NO;
            takeLookCurrentFriendId = nil;
            self.isScanRunning = NO;
            selfPriorityPending = NO;
            [self recordStage:[NSString stringWithFormat:@"本轮扫描结束：%@", reason]];
            return;
        }
        takeLookRounds++;
        takeLookTotalRounds++;
        takeLookWaitingForFriend = YES;
        takeLookCurrentFriendId = nil;
        requestToken = ++takeLookRequestToken;
    }
    [self takeLook];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @synchronized (self) {
            if (!takeLookRunning || !takeLookWaitingForFriend || requestToken != takeLookRequestToken) return;
            takeLookRunning = NO;
            takeLookWaitingForFriend = NO;
            takeLookCurrentFriendId = nil;
            self.isScanRunning = NO;
            selfPriorityPending = NO;
            [self recordStage:@"本轮扫描完成"];
        }
    });
}

-(BOOL)consumeTakeLookFriend:(NSString *)friendId {
    @synchronized (self) {
        if (!takeLookRunning || !takeLookWaitingForFriend) return YES;
        takeLookWaitingForFriend = NO;
        if ([takeLookVisitedFriends containsObject:friendId]) {
            if (takeLookPass < kTakeLookMaxPasses && takeLookTotalRounds < kTakeLookMaxRounds) {
                takeLookPass++;
                takeLookRounds = 0;
                takeLookCurrentFriendId = nil;
                takeLookRequestToken++;
                [takeLookVisitedFriends removeAllObjects];
                [self recordStage:[NSString stringWithFormat:@"诊断 · 服务端重复候选，开始第 %lu 轮续查", (unsigned long)takeLookPass]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                    [self requestNextTakeLook];
                });
                return NO;
            }
            takeLookRunning = NO;
            takeLookWaitingForFriend = NO;
            takeLookCurrentFriendId = nil;
            self.isScanRunning = NO;
            selfPriorityPending = NO;
            [self recordStage:@"本轮扫描完成"];
            return NO;
        }
        [takeLookVisitedFriends addObject:friendId];
        takeLookCurrentFriendId = friendId;
        [self recordStage:[NSString stringWithFormat:@"诊断 · 找能量候选：第 %lu 轮第 %lu 位（累计 %lu 位）", (unsigned long)takeLookPass, (unsigned long)takeLookRounds, (unsigned long)takeLookTotalRounds]];
        
        // 关键保护：为每位找能量候选设置 3.5 秒看门狗！
        // 若该好友主页无气泡、回包丢失或挂起，自动推进至下一位，绝不陷入死锁！
        NSUInteger token = takeLookRequestToken;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @synchronized (self) {
                if (takeLookRunning && [takeLookCurrentFriendId isEqualToString:friendId] && token == takeLookRequestToken) {
                    [self recordStage:@"诊断 · 候选好友气泡查询超时或无气泡，自动推进下一位"];
                    [self advanceTakeLookForFriend:friendId];
                }
            }
        });
        
        return YES;
    }
}

-(void)advanceTakeLookForFriend:(NSString *)friendId {
    @synchronized (self) {
        if (!takeLookRunning) return;
        if (friendId.length && takeLookCurrentFriendId.length && ![takeLookCurrentFriendId isEqualToString:friendId]) return;
        takeLookCurrentFriendId = nil;
        takeLookWaitingForFriend = NO;
    }
    // 收取请求在全局串行队列中发送；以该队列的栅栏作为下一位候选的起点，避免与前一位的多颗气泡请求重叠。
    dispatch_async(globalSerialQueueCollect, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(350 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            [self recordStage:@"诊断 · 当前候选收取队列已完成，继续下一位"];
            [self requestNextTakeLook];
        });
    });
}

- (BOOL)isAnimalEnergyCollectedTodayForCode:(NSString *)code name:(NSString *)name {
    NSString *today = getCurrentDateString();
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    // 1. 全局单日已收标记
    NSString *savedAnimalDate = [defaults stringForKey:@"todayAnimalEnergyCollectedDate"];
    if ([today isEqualToString:savedAnimalDate]) {
        return YES;
    }
    
    // 2. 按动物名/Code 维度检查
    if (code.length) {
        NSString *kCode = [NSString stringWithFormat:@"animal_%@_%@", today, code];
        if ([todayCollectedAnimalKeys containsObject:kCode] || [defaults boolForKey:kCode]) {
            return YES;
        }
    }
    if (name.length) {
        NSString *kName = [NSString stringWithFormat:@"animal_%@_%@", today, name];
        if ([todayCollectedAnimalKeys containsObject:kName] || [defaults boolForKey:kName]) {
            return YES;
        }
    }
    return NO;
}

- (void)markAnimalEnergyCollectedTodayForCode:(NSString *)code name:(NSString *)name reason:(NSString *)reason {
    NSString *today = getCurrentDateString();
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:today forKey:@"todayAnimalEnergyCollectedDate"];
    
    if (!todayCollectedAnimalKeys) todayCollectedAnimalKeys = [NSMutableSet set];
    if (code.length) {
        NSString *kCode = [NSString stringWithFormat:@"animal_%@_%@", today, code];
        [todayCollectedAnimalKeys addObject:kCode];
        [defaults setBool:YES forKey:kCode];
    }
    if (name.length) {
        NSString *kName = [NSString stringWithFormat:@"animal_%@_%@", today, name];
        [todayCollectedAnimalKeys addObject:kName];
        [defaults setBool:YES forKey:kName];
    }
    [defaults synchronize];
    
    static NSTimeInterval lastLockLogTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - lastLockLogTime > 300.0) {
        lastLockLogTime = now;
        NSString *aName = name.length ? name : (code.length ? code : @"巡护伙伴");
        [self recordStage:[NSString stringWithFormat:@"保护地巡护 · %@今日能量已确认收取/不可收（%@），锁定单日防重", aName, reason ?: @"防重生效"]];
    }
}

-(void)queryUsingCreatureInfo {
    if (!self.jsBridge) return;
    // 若今日巡护动物能量已确认收取，跳过轮询，避免无意义的网络开销
    if ([self isAnimalEnergyCollectedTodayForCode:nil name:nil]) return;
    
    static NSTimeInterval lastQueryCreatureTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - lastQueryCreatureTime < 3.0) return;
    lastQueryCreatureTime = now;
    
    NSString *effectiveUid = self.myUserId.length ? self.myUserId : ([[NSUserDefaults standardUserDefaults] stringForKey:@"lastKnownUserId"] ?: @"");
    NSString *uuid = [[NSUUID UUID] UUIDString];
    NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)[[NSDate date] timeIntervalSince1970] * 1000];
    NSString *rand = [AntForestManager getNumberRandom:15];
    NSString *arg2 = @"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&__webview_options__=bc%3D3194732";
    
    NSString *arg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antisle.monopoly.h5.queryUsingCreatureInfo\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"uniqueId\":\"%@\",\"targetUserId\":\"%@\",\"version\":\"20260623\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", uuid, effectiveUid ?: @"", timeStamp, rand];
    [self.jsBridge _doFlushMessageQueue:arg url:arg2];
}

-(void)collectMonopolyCreatureEnergyWithCode:(NSString *)creatureCode shortDay:(NSString *)shortDay energy:(NSInteger)energy name:(NSString *)name {
    if (!self.jsBridge) return;
    NSString *code = creatureCode.length ? creatureCode : @"hongshandongwuyuan#dani";
    NSString *aName = name.length ? name : @"巡护伙伴";
    
    // 1. 核心防重：今日已锁定或已收过，严禁发送 RPC 并静默拦截
    if ([self isAnimalEnergyCollectedTodayForCode:code name:aName]) {
        static NSTimeInterval lastAnimalSkipLogTime = 0;
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - lastAnimalSkipLogTime > 300.0) {
            lastAnimalSkipLogTime = now;
            [self recordStage:[NSString stringWithFormat:@"保护地巡护：%@今日能量已收取（待明日产生）", aName]];
        }
        return;
    }
    
    NSString *sDay = shortDay;
    if (!sDay.length) {
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        [df setDateFormat:@"yyyyMMdd"];
        sDay = [df stringFromDate:[NSDate dateWithTimeIntervalSinceNow:-86400]];
    }
    
    // 2. 频次节流：对同一动物+同一 shortDay，30 秒内最多尝试一次 RPC，避免并发与高频刷屏
    NSString *attemptKey = [NSString stringWithFormat:@"%@_%@", code, sDay];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSNumber *lastAttempt = lastAnimalCollectAttemptTimes[attemptKey];
    if (lastAttempt && (now - [lastAttempt doubleValue] < 30.0)) {
        return;
    }
    lastAnimalCollectAttemptTimes[attemptKey] = @(now);
    
    NSString *energyDesc = (energy > 0) ? [NSString stringWithFormat:@"（%ldg）", (long)energy] : @"";
    [self recordStage:[NSString stringWithFormat:@"保护地巡护：正在通过官方专有接口收取%@能量%@...", aName, energyDesc]];
    
    NSString *uuid = [[NSUUID UUID] UUIDString];
    NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)[[NSDate date] timeIntervalSince1970] * 1000];
    NSString *rand = [AntForestManager getNumberRandom:15];
    NSString *arg2 = @"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&__webview_options__=bc%3D3194732";
    
    NSString *arg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antisle.monopoly.h5.collectMonopolyCreatureEnergy\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"uniqueId\":\"%@\",\"creatureCode\":\"%@\",\"shortDay\":\"%@\",\"version\":\"20260623\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", uuid, code, sDay, timeStamp, rand];
    [self.jsBridge _doFlushMessageQueue:arg url:arg2];
}

-(void)receiveAnimalEnergyWithPropId:(NSString *)propId propType:(NSString *)propType animalId:(NSString *)animalId energy:(NSInteger)energy name:(NSString *)name isCollected:(BOOL)isCollected {
    if ((!self.enableAutoCollect && !self.enableSelfCollect && !self.enableAutoPatrolNew) || !self.jsBridge) return;
    NSString *pType = propType ?: @"";
    NSString *aId = animalId ?: @"";
    NSString *pId = propId ?: @"";
    NSString *aName = name.length ? name : @"巡护伙伴";
    NSString *creatureCode = aId.length ? aId : (pType.length ? pType : @"hongshandongwuyuan#dani");
    
    // 如果今日已经确认成功收取完毕或入参标记已收，直接跳过并节流提示
    if (isCollected || [self isAnimalEnergyCollectedTodayForCode:creatureCode name:aName]) {
        [self markAnimalEnergyCollectedTodayForCode:creatureCode name:aName reason:@"入参或历史已收取"];
        static NSTimeInterval lastAnimalNoEnergyLogTime = 0;
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - lastAnimalNoEnergyLogTime > 300.0) { // 5分钟节流提示
            lastAnimalNoEnergyLogTime = now;
            [self recordStage:[NSString stringWithFormat:@"保护地巡护：%@今日能量已收取（待明日产生）", aName]];
        }
        return;
    }
    
    // 节流：两次尝试收取至少间隔 10 秒，避免高频并发
    static NSTimeInterval sLastAnimalAttemptTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - sLastAnimalAttemptTime < 10.0) return;
    sLastAnimalAttemptTime = now;
    
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"yyyyMMdd"];
    NSString *yesterdayShortDay = [df stringFromDate:[NSDate dateWithTimeIntervalSinceNow:-86400]];
    NSString *todayShortDay = [df stringFromDate:[NSDate date]];
    
    // 1. 针对新版保护地巡护动物（如南京红山动物园小熊猫、大鲵），发送官方原版 alipay.antisle.monopoly.h5.collectMonopolyCreatureEnergy
    // 先发送昨日 shortDay（正常巡护结算为昨日产出）
    [self collectMonopolyCreatureEnergyWithCode:creatureCode shortDay:yesterdayShortDay energy:energy name:aName];
    
    // 延时 1000ms 发送今日 shortDay 容错（先二次检查是否已在第一发中收取锁定）
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1000 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf isAnimalEnergyCollectedTodayForCode:creatureCode name:aName]) return;
        [strongSelf collectMonopolyCreatureEnergyWithCode:creatureCode shortDay:todayShortDay energy:energy name:aName];
    });
    
    // 2. 针对经典动物背包道具，发送官方原版 alipay.antforest.forest.h5.collectAnimalRobEnergy
    if (pId.length && ![pId isEqualToString:creatureCode]) {
        NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)[[NSDate date] timeIntervalSince1970] * 1000];
        NSString *rand = [AntForestManager getNumberRandom:15];
        NSString *arg2 = @"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&__webview_options__=bc%3D3194732";
        NSString *argClassic = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.collectAnimalRobEnergy\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"propId\":\"%@\",\"propType\":\"%@\",\"shortDay\":\"%@\",\"version\":\"20240322\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", pId, pType, yesterdayShortDay, timeStamp, rand];
        [self.jsBridge _doFlushMessageQueue:argClassic url:arg2];
    }
}

-(void)receiveAnimalEnergyWithPropId:(NSString *)propId propType:(NSString *)propType animalId:(NSString *)animalId {
    [self receiveAnimalEnergyWithPropId:propId propType:propType animalId:animalId energy:0 name:@"" isCollected:NO];
}

-(void)receiveAnimalPartnerEnergy {
    [self queryUsingCreatureInfo];
}

- (void)safeFlushBridge:(id)bridge message:(NSString *)msg url:(NSString *)url {
    if (!bridge || !msg.length) return;
    if ([NSThread isMainThread]) {
        if ([bridge respondsToSelector:@selector(_doFlushMessageQueue:url:)]) {
            [bridge _doFlushMessageQueue:msg url:url];
        }
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([bridge respondsToSelector:@selector(_doFlushMessageQueue:url:)]) {
                [bridge _doFlushMessageQueue:msg url:url];
            }
        });
    }
}

static NSTimeInterval lastMyBubblesQueryTime = 0;

-(void)queryMyBubbles {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - lastMyBubblesQueryTime < 10.0) return;
    lastMyBubblesQueryTime = now;
    
    [self recordStage:@"请求本人首页（含赠能）"];
    [[AntForestManager sharedLock] lock];
    
    NSString *version = @"20241025";
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:16];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.queryHomePage\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"version\":\"%@\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"configVersionMap\":{\"wateringBubbleConfig\":\"0\"},\"skipWhackMole\":false,\"activityParam\":{}}]},\"callbackId\":\"rpc_%@.%@\"}]",version,timeStamp,randNum];
    NSString *arg2 = @"https://render.alipay.com/p/yuyan/180020010001247580/home.html?__webview_options__=bc%3D3194732";
    
    if([self jsBridge]) {
        [self safeFlushBridge:[self jsBridge] message:arg1 url:arg2];
        [self queryUsingCreatureInfo];
    }
    
    [NSThread sleepForTimeInterval:0.18];
    [[AntForestManager sharedLock] unlock];
}

//查询能量球
-(void)queryFriendsBubbles:(NSString*)friendId {
    [[AntForestManager sharedLock] lock];
    
    NSString *version = @"20241025";
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:15];
    NSString *callbackId = [NSString stringWithFormat:@"rpc_af_silent_friend_%@.%@", timeStamp, randNum];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.queryFriendHomePage\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"userId\":\"%@\",\"version\":\"%@\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"fromAct\":\"TAKE_LOOK\",\"configVersionMap\":{\"wateringBubbleConfig\":\"0\"},\"skipWhackMole\":false,\"activityParam\":{},\"currentEnergy\":99999999,\"currentVitalityAmount\":8888888}]},\"callbackId\":\"%@\"}]",friendId,version,callbackId];
    NSString *arg2 = @"https://render.alipay.com/p/yuyan/180020010001247580/home.html?__webview_options__=bc%3D3194732";
    
    if([self jsBridge]) {
        [self recordStage:@"诊断 · 请求好友气泡"];
        [self safeFlushBridge:[self jsBridge] message:arg1 url:arg2];
        //FileLog(@"anthook queryFriendsBubbles: %@",friendId);
    }
    
    double randomDelay = 0.18 + (arc4random_uniform(140) / 1000.0);
    [NSThread sleepForTimeInterval:randomDelay];
    [[AntForestManager sharedLock] unlock];
}

//收集能量球
-(void)collectBubbles:(NSString*)uid bubblesId:(NSString*)bids {
    NSString *userId = [uid isKindOfClass:NSString.class] ? uid : [uid description];
    NSString *bubbleIds = [bids isKindOfClass:NSString.class] ? bids : [bids description];
    if (!self.enableAutoCollect || !userId.length || !bubbleIds.length) return;
    if (!self.myUserId.length) {
        [self recordStage:@"诊断 · 收取跳过：本人账户尚未识别"];
        return;
    }
    if ([userId isEqualToString:self.myUserId] && !self.enableSelfCollect) {
        [self recordStage:@"已跳过本人能量"];
        return;
    }
    NSString *collectKey = [NSString stringWithFormat:@"%@:%@", userId, bubbleIds];
    @synchronized (self) {
        if ([pendingCollectBubbles containsObject:collectKey]) {
            [self recordStage:@"诊断 · 收取跳过：重复气泡请求"];
            return;
        }
        [pendingCollectBubbles addObject:collectKey];
    }
    [[AntForestManager sharedLock] lock];
    NSString *version = @"20230501";
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:15];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antmember.forest.h5.collectEnergy\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"userId\":\"%@\",\"bubbleIds\":[%@],\"bizType\":\"\",\"fromAct\":\"TAKE_LOOK\",\"version\":\"%@\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]",userId,bubbleIds,version,timeStamp,randNum];
    NSString *arg2 = @"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&__webview_options__=bc%3D3194732";
    if([self jsBridge]) {
        [self recordStage:[NSString stringWithFormat:@"诊断 · 请求收取能量：第 %lu 轮，待确认 %lu 笔", (unsigned long)collectionCycle, (unsigned long)pendingCollectBubbles.count]];
        [self safeFlushBridge:[self jsBridge] message:arg1 url:arg2];
        //FileLog(@"anthook collectBubbles: %@ | [%@] ",uid,bids);
    }
    double collectRandomDelay = 0.12 + (arc4random_uniform(100) / 1000.0);
    [NSThread sleepForTimeInterval:collectRandomDelay];
    [[AntForestManager sharedLock] unlock];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @synchronized (self) {
            if (![pendingCollectBubbles containsObject:collectKey]) return;
            [pendingCollectBubbles removeObject:collectKey];
        }
    });
}

-(void)reportClickTime{
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:15];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"reportClickTime\",\"data\":{},\"callbackId\":\"reportClickTime_%@.%@\"}]",timeStamp,randNum];
    NSString *arg2 = [NSString stringWithFormat:@"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&__webview_options__=bc%%3D3194732"];
    if([self jsBridge]) {
        [[self jsBridge] _doFlushMessageQueue:arg1 url:arg2];
        //FileLog(@"anthook reportClickTime");
    }
}

-(void)reviveEnergy:(NSString*)uid signId:(NSString*)signId {
    if (!signId.length) return;
    [self signVitalityTask:signId sceneCode:@"ANTFOREST_ENERGY_SIGN"];
}

static NSInteger myOceanCleanCount = 0;
static NSMutableDictionary *friendOceanCleanCounts = nil;

-(void)cleanMyOceanThoroughly {
    if (!isWithinTaskActiveHours()) return;
    if (!self.enableCleanOcean || (!self.jsBridge && !self.oceanBridge)) return;
    myOceanCleanCount = 0;
    [self cleanMyOcean];
}

//清理自己的海域
-(void)cleanMyOcean{
    if (!isWithinTaskActiveHours()) return;
    if (!self.myUserId.length) return;
    self.lastCleanedOceanUserId = self.myUserId;
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:15];
    NSString *randNum2=[AntForestManager getNumberRandom:16];
    NSString *callbackId = [NSString stringWithFormat:@"rpc_af_silent_ocean_%@.%@", timeStamp, randNum2];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antocean.ocean.h5.cleanOcean\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"cleanedUserId\":\"%@\",\"userId\":\"%@\",\"source\":\"ANT_FOREST\",\"uniqueId\":\"%@%@\"}],\"appName\":\"antocean\",\"facadeName\":\"InteractController\",\"methodName\":\"cleanOcean\",\"getResponse\":true},\"callbackId\":\"%@\"}]",self.myUserId,self.myUserId,timeStamp,randNum,callbackId];
    id bridge = self.oceanBridge ?: self.jsBridge;
    NSString *arg2 = (bridge == self.oceanBridge && self.oceanH5Url.length) ? self.oceanH5Url : ([self effectiveUrlForBridge:bridge] ?: @"https://2021003115672468.h5app.alipay.com/www/index.html");
    if (bridge == self.jsBridge) {
        arg2 = [self effectiveUrlForBridge:bridge] ?: @"https://render.alipay.com/p/yuyan/180020010001247580/home.html";
    }
    if(bridge) {
        [bridge _doFlushMessageQueue:arg1 url:arg2];
    }
}

//清理朋友的海域
-(void)cleanFriendsOcean:(NSString*)uid{
    if (!isWithinTaskActiveHours()) return;
    if (!uid.length) return;
    self.lastCleanedOceanUserId = uid;
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:15];
    NSString *randNum2=[AntForestManager getNumberRandom:16];
    NSString *callbackId = [NSString stringWithFormat:@"rpc_af_silent_ocean_%@.%@", timeStamp, randNum2];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antocean.ocean.h5.cleanFriendOcean\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"cleanedUserId\":\"%@\",\"userId\":\"%@\",\"source\":\"ANT_FOREST\",\"uniqueId\":\"%@%@\"}],\"appName\":\"antocean\",\"facadeName\":\"InteractController\",\"methodName\":\"cleanFriendsOcean\",\"getResponse\":true},\"callbackId\":\"%@\"}]",uid,uid,timeStamp,randNum,callbackId];
    id bridge = self.oceanBridge ?: self.jsBridge;
    NSString *arg2 = [NSString stringWithFormat:@"https://2021003115672468.h5app.alipay.com/www/index.html?fromAct=SAIL_AWAY&userId=%@&interactFlags=&source=ANT_FOREST&__webview_options__=ttb%%3Dauto%%26pd%%3DNO%%26bc%%3D1324950",uid];
    if (bridge == self.oceanBridge && self.oceanH5Url.length) {
        arg2 = self.oceanH5Url;
    } else if (bridge == self.jsBridge) {
        arg2 = [self effectiveUrlForBridge:bridge] ?: @"https://render.alipay.com/p/yuyan/180020010001247580/home.html";
    }
    if(bridge) {
        [bridge _doFlushMessageQueue:arg1 url:arg2];
    }
}

-(void)queryOceanFriendList {
    if (!isWithinTaskActiveHours()) {
        static NSTimeInterval sLastSilentOceanLog = 0;
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - sLastSilentOceanLog > 1800.0) {
            sLastSilentOceanLog = now;
            [self recordStage:[NSString stringWithFormat:@"神奇海洋：当前处于静默期，海域垃圾拾取与清理等待 %@ 刷新后执行", getTaskActiveStartTimeString()]];
        }
        return;
    }
    if (!self.enableCleanOcean) return;
    NSString *today = getCurrentDateString();
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![[defaults stringForKey:@"oceanCleanedDate"] isEqualToString:today]) {
        [defaults setObject:today forKey:@"oceanCleanedDate"];
        [defaults setObject:@[] forKey:@"oceanCleanedFriendsToday"];
        [defaults setBool:NO forKey:@"oceanLimitReachedToday"];
    }
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:15];
    NSString *callbackId = [NSString stringWithFormat:@"rpc_af_silent_ocean_%@.%@", timeStamp, randNum];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antocean.ocean.h5.queryFriendList\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"source\":\"ANT_FOREST\",\"uniqueId\":\"%@%@\"}],\"appName\":\"antocean\",\"facadeName\":\"InteractController\",\"methodName\":\"queryFriendList\",\"getResponse\":true},\"callbackId\":\"%@\"}]", timeStamp, randNum, callbackId];
    id bridge = self.oceanBridge ?: self.jsBridge;
    NSString *arg2 = (bridge == self.oceanBridge && self.oceanH5Url.length) ? self.oceanH5Url : @"https://2021003115672468.h5app.alipay.com/www/index.html";
    if (bridge == self.jsBridge) {
        arg2 = [self effectiveUrlForBridge:bridge] ?: @"https://render.alipay.com/p/yuyan/180020010001247580/home.html";
    }
    if(bridge) {
        [self recordStage:@"请求神奇海洋好友列表"];
        [bridge _doFlushMessageQueue:arg1 url:arg2];
        dispatch_async(globalSerialQueueQuery, ^{
            [self cleanMyOcean];
        });
    }
    
    // 双保险：若已有好友排行榜或好友名称缓存，直接将候选好友加入海洋清理队列，杜绝因 queryFriendList 延迟或跨域导致不拾取好友垃圾
    NSMutableDictionary *fr = self.friendsRank;
    NSMutableOrderedSet<NSString *> *allCandidates = [NSMutableOrderedSet orderedSet];
    if (fr.allKeys.count > 0) {
        [allCandidates addObjectsFromArray:fr.allKeys];
    }
    if (self.friendsName.allKeys.count > 0) {
        [allCandidates addObjectsFromArray:self.friendsName.allKeys];
    }
    if (allCandidates.count > 0) {
        [self scanOceanForFriends:allCandidates.array];
    } else if (fr.allKeys.count > 0) {
        [self scanOceanForFriends:fr.allKeys];
    }
}

// ----------------------------------------------------
// 领奖励与森林寻宝（任务中心：签到、浏览任务、阶梯累计大奖）
// ----------------------------------------------------

static NSMutableArray<NSDictionary *> *vitalityTaskQueue = nil;
static BOOL vitalityTaskRunning = NO;
static NSMutableSet<NSString *> *gDailyCompletedTasks = nil;
static NSMutableSet<NSString *> *gDailyFailedTasks = nil;
static NSString *gDailyTaskDate = nil;
static NSString *gCurrentExecutingTaskKey = nil;
static BOOL gCurrentExecutingTaskIsMultiStage = NO;
static NSMutableDictionary<NSString *, NSNumber *> *gFarmTaskRetryCounts = nil;
static NSMutableDictionary<NSString *, NSNumber *> *gVitalityTaskRetryCounts = nil;

static void initDailyTaskCache(void) {
    NSString *today = getCurrentDateString();
    if (![gDailyTaskDate isEqualToString:today] || !gDailyCompletedTasks || !gDailyFailedTasks) {
        BOOL isCrossDay = (gDailyTaskDate.length > 0 && ![gDailyTaskDate isEqualToString:today]);
        gDailyTaskDate = today;
        if (!gFarmTaskRetryCounts) {
            gFarmTaskRetryCounts = [NSMutableDictionary dictionary];
        } else {
            [gFarmTaskRetryCounts removeAllObjects];
        }
        if (!gVitalityTaskRetryCounts) {
            gVitalityTaskRetryCounts = [NSMutableDictionary dictionary];
        } else {
            [gVitalityTaskRetryCounts removeAllObjects];
        }
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSString *savedDate = [defaults stringForKey:@"vitality_task_cache_date"];
        if ([savedDate isEqualToString:today] && !isCrossDay) {
            NSArray *completed = [defaults objectForKey:@"vitality_daily_completed"];
            gDailyCompletedTasks = [NSMutableSet setWithArray:completed ?: @[]];
            // 彻底清空历史持久化的误杀失败集合，保证所有正常任务在新会话中均能执行
            gDailyFailedTasks = [NSMutableSet set];
            [defaults setObject:@[] forKey:@"vitality_daily_failed"];
            [defaults synchronize];
        } else {
            gDailyCompletedTasks = [NSMutableSet set];
            gDailyFailedTasks = [NSMutableSet set];
            if (vitalityTaskQueue) {
                [vitalityTaskQueue removeAllObjects];
            }
            vitalityTaskRunning = NO;
            gCurrentExecutingTaskKey = nil;
            gCurrentExecutingTaskIsMultiStage = NO;
            [defaults setObject:today forKey:@"vitality_task_cache_date"];
            [defaults setObject:@[] forKey:@"vitality_daily_completed"];
            [defaults setObject:@[] forKey:@"vitality_daily_failed"];
            [defaults synchronize];
            NSLog(@"[AntForestPort] 日期已跨天（%@），彻底清空任务完成缓存与待执行队列", today);
        }
        if (isCrossDay) {
            // 跨天彻底释放昨日残留的抽屉子桥接，确保零点后100%使用森林首页主桥接进行签到
            AntForestManager *afm = [AntForestManager sharedInstance];
            afm.rewardTaskBridge = nil;
        }
    }
}

static void saveDailyTaskCache(void) {
    if (!gDailyTaskDate.length) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:gDailyTaskDate forKey:@"vitality_task_cache_date"];
    [defaults setObject:[gDailyCompletedTasks allObjects] forKey:@"vitality_daily_completed"];
    [defaults setObject:[gDailyFailedTasks allObjects] forKey:@"vitality_daily_failed"];
    [defaults synchronize];
}

static BOOL isSafeRewardTask(NSString *taskType, NSString *title) {
    if (!taskType.length) return NO;
    if ([taskType isEqualToString:@"ZHRW_haoyibaomzx_202601"] ||
        [taskType isEqualToString:@"ZHRW_haoyibaoseyl_202512"] ||
        [taskType isEqualToString:@"FOREST_CONTINUOUS_COLLECT_ENERGY_7"] ||
        [taskType isEqualToString:@"ENERGYRAIN"] ||
        [taskType isEqualToString:@"ENERGY_XUANJIAO"] ||
        [taskType isEqualToString:@"TEST_LEAF_TASK"] ||
        [taskType isEqualToString:@"TEST_LEAF_CONVERT_TASK"] ||
        [taskType isEqualToString:@"widget_0511"] ||
        [taskType isEqualToString:@"ONE_CLICK_WATERING_V1"] ||
        [taskType containsString:@"10THjiaoshui"] ||
        [taskType containsString:@"10ZN_JS"]) {
        return NO;
    }
    NSString *lowerType = taskType.lowercaseString;
    NSString *lowerTitle = title ? title.lowercaseString : @"";
    
    // 明确不做领奖励中的“进入新版保护地”跳转任务
    if ([lowerTitle containsString:@"新版保护地"] || [lowerTitle containsString:@"进入新版保护地"]) {
        return NO;
    }
    
    // 阶梯大奖类型安全可领
    if ([lowerType hasPrefix:@"acc_"] || [lowerType containsString:@"_acc_"] || [lowerType containsString:@"acc_"] || [lowerType containsString:@"stage_"] || [lowerType containsString:@"ladder"]) {
        return YES;
    }
    
    // AI摸鱼类任务安全可执行 (赠送每日摸鱼次数、看15s视频、去玩一玩森林小车车15s等)
    if ([lowerType containsString:@"aifish"] || [lowerType containsString:@"touch_fish"] || [lowerTitle containsString:@"摸鱼"]) {
        if ([lowerType containsString:@"kuaishou"] || [lowerTitle containsString:@"快手"] ||
            [lowerType containsString:@"zhuanhua"] || [lowerType containsString:@"cnxdy"] ||
            [lowerTitle containsString:@"击败"] || [lowerTitle containsString:@"打怪"] || [lowerTitle containsString:@"玩一玩超"]) {
            return NO;
        }
        return YES;
    }
    
    // 公益林任务为纯浏览（去看看），安全可执行
    if ([lowerType containsString:@"zhongshugongyilin"] || [lowerTitle containsString:@"公益林"]) {
        return YES;
    }
    // 支付宝会员中心任务为纯浏览，安全可执行
    if ([lowerType containsString:@"huiyuan"] || [lowerTitle containsString:@"会员中心"]) {
        return YES;
    }
    
    // 用户明确指定：逛农场得落叶肥料由用户手动执行，插件不自动做
    if ([lowerTitle containsString:@"落叶"] || [lowerType containsString:@"leaf"]) {
        return NO;
    }
    
    // 过滤真实付款与金融高危任务，注意避免误杀包含“支付宝”字样的安全浏览任务
    NSString *cleanTitle = [lowerTitle stringByReplacingOccurrencesOfString:@"支付宝" withString:@""];
    
    // 真实扣费、支付、借贷、开户、办卡、好友浇水等真实高危行为判定
    BOOL hasRealFinancialRisk = ([cleanTitle containsString:@"支付"] ||
                                 [cleanTitle containsString:@"付款"] ||
                                 [cleanTitle containsString:@"购买"] ||
                                 [cleanTitle containsString:@"下单"] ||
                                 [cleanTitle containsString:@"开户"] ||
                                 [cleanTitle containsString:@"办卡"] ||
                                 [cleanTitle containsString:@"借呗"] ||
                                 [cleanTitle containsString:@"花呗"] ||
                                 [cleanTitle containsString:@"信用卡"] ||
                                 [cleanTitle containsString:@"理财"] ||
                                 [cleanTitle containsString:@"基金"] ||
                                 [cleanTitle containsString:@"充值"] ||
                                 [cleanTitle containsString:@"缴费"] ||
                                 [cleanTitle containsString:@"出行"] ||
                                 [cleanTitle containsString:@"打车"] ||
                                 [cleanTitle containsString:@"外卖"] ||
                                 [cleanTitle containsString:@"自带杯"] ||
                                 [cleanTitle containsString:@"浇水"] ||
                                 [cleanTitle containsString:@"一键浇水"] ||
                                 [cleanTitle containsString:@"添加组件"] ||
                                 [cleanTitle containsString:@"给随机好友"]);
    
    // 搜索类与导流抽奖类任务（如“去淘宝签到领红包”、“搜‘宠物医保’养宠必备”、“搜‘好医保’得抽奖机会”、“搜‘今日热点’去看看”等），均为安全浏览/搜索导流，安全放行
    BOOL isPureSearchOrBrowseTask = ([lowerTitle containsString:@"搜"] ||
                                     [lowerTitle containsString:@"去看看"] ||
                                     [lowerTitle containsString:@"抽1次"] ||
                                     [lowerTitle containsString:@"逛"] ||
                                     [lowerTitle containsString:@"淘宝"] ||
                                     [lowerType containsString:@"search"] ||
                                     [lowerType containsString:@"taobao"] ||
                                     [lowerType hasPrefix:@"daoliu_"] ||
                                     [lowerType containsString:@"daoliu"]);
    if (isPureSearchOrBrowseTask && !hasRealFinancialRisk) {
        return YES;
    }
    
    // 严格过滤金融、保险、借贷、支付、荷包、好友随机浇水等高风险任务
    if ([lowerType containsString:@"haoyibao"] ||
        [lowerType containsString:@"insure"] ||
        [lowerType containsString:@"baoxian"] ||
        [lowerType containsString:@"jiebei"] ||
        [lowerType containsString:@"huabei"] ||
        [lowerType containsString:@"hebao"] ||
        [lowerType containsString:@"xiaohebao"] ||
        [lowerType containsString:@"jiaofei"] ||
        [lowerType containsString:@"chuxing"] ||
        [lowerType containsString:@"jiaoshui"] ||
        [lowerType containsString:@"continuous_collect"] ||
        [lowerType containsString:@"energy_xuanjiao"] ||
        [lowerType containsString:@"widget_"] ||
        [lowerType containsString:@"mhjlr"] ||
        [lowerType containsString:@"zhxf"] ||
        [lowerType containsString:@"yxzy"] ||
        [lowerType containsString:@"_zhwufu"]) {
        return NO;
    }
    
    // 金融与高危扣费/支付/保险/荷包开户类任务严格拦截
    if ([cleanTitle containsString:@"保障"] ||
        [cleanTitle containsString:@"保险"] ||
        [cleanTitle containsString:@"好医保"] ||
        [cleanTitle containsString:@"荷包"] ||
        [cleanTitle containsString:@"多人荷包"] ||
        hasRealFinancialRisk) {
        return NO;
    }
    
    // 纯浏览/停留计时类任务（如“去淘宝签到领红包”、“玩一玩向僵尸开炮 浏览15s”、“玩一玩我的花园世界 浏览30s”、“去神奇鱼塘得能量 逛一逛可得”、“看视频得能量”），安全放行
    BOOL isDurationBrowseTask = ([cleanTitle containsString:@"浏览"] || [cleanTitle containsString:@"30s"] || [cleanTitle containsString:@"15s"] || [cleanTitle containsString:@"秒"] || [cleanTitle containsString:@"逛"] || [cleanTitle containsString:@"看看"] || [cleanTitle containsString:@"淘宝"] || [cleanTitle containsString:@"鱼塘"] || [cleanTitle containsString:@"向僵尸开炮"] || [cleanTitle containsString:@"花园世界"] || [cleanTitle containsString:@"视频"]);
    if (isDurationBrowseTask) {
        return YES;
    }
    
    // 拦截需在游戏内深度操作的非浏览类任务
    if (([cleanTitle containsString:@"玩游戏得"] && ![cleanTitle containsString:@"机会"] && ![lowerType containsString:@"daoliu"] && ![lowerType containsString:@"draw"]) ||
        [cleanTitle containsString:@"居民订单"] ||
        [cleanTitle containsString:@"升级建筑"] ||
        [cleanTitle containsString:@"闯关"] ||
        [cleanTitle containsString:@"通过1关"] ||
        [cleanTitle containsString:@"梦幻经理人"] ||
        [cleanTitle containsString:@"造化仙府"] ||
        [cleanTitle containsString:@"源星战域"] ||
        [cleanTitle containsString:@"花园小镇"] ||
        [cleanTitle containsString:@"进入新版保护地"] ||
        [cleanTitle containsString:@"连续"] ||
        [cleanTitle containsString:@"垃圾"] ||
        [cleanTitle containsString:@"帮好友清理"]) {
        return NO;
    }
    return YES;
}

static BOOL isSafeOceanTask(NSString *taskType, NSString *title) {
    if (!taskType.length) return NO;
    NSString *lowerType = taskType.lowercaseString;
    NSString *lowerTitle = title ? title.lowercaseString : @"";
    
    // 明确不做神奇海洋“逛一逛惊喜市集”
    if ([lowerTitle containsString:@"惊喜市集"] || [lowerType containsString:@"jingxi"]) {
        return NO;
    }
    // 明确不做“进入新版保护地”与保护地跳转任务
    if ([lowerTitle containsString:@"进入新版保护地"]) {
        return NO;
    }
    // 明确不支持 finishTask RPC 的答题、捡垃圾、连续签到与外部小程序小游戏
    if ([lowerType containsString:@"dati"] || [lowerTitle containsString:@"答题"]) {
        return NO;
    }
    if ([lowerType containsString:@"rubbish"] || [lowerTitle containsString:@"垃圾"]) {
        return NO;
    }
    if ([lowerType containsString:@"visisit"] || [lowerType containsString:@"consecutive"] || [lowerTitle containsString:@"连续"] || [lowerTitle containsString:@"3天"]) {
        return NO;
    }
    if ([lowerType containsString:@"yxzy"] || [lowerTitle containsString:@"源星战域"]) {
        return NO;
    }
    if ([lowerType containsString:@"hydrw"] || [lowerTitle containsString:@"玩一玩得拼图"] || [lowerTitle containsString:@"专区游戏"]) {
        return NO;
    }
    
    // 带有导流前缀 DAOLIU_ 的即便是游戏也是纯跳转/浏览安全任务（如 DAOLIU_SLJYG_DJW_GAME）
    if ([lowerType hasPrefix:@"daoliu_"] || [lowerType containsString:@"daoliu"]) {
        return YES;
    }
    
    // 纯游戏类若无导流前缀则不支持 RPC
    if ([lowerType containsString:@"game"] && ![lowerType containsString:@"daoliu"]) {
        return NO;
    }
    
    return isSafeRewardTask(taskType, title);
}

static BOOL isSafeAIFishTask(NSString *taskType, NSString *title) {
    if (!taskType.length) return NO;
    NSString *lowerType = taskType.lowercaseString;
    NSString *lowerTitle = title ? title.lowercaseString : @"";
    if ([lowerType containsString:@"kuaishou"] || [lowerTitle containsString:@"快手"] ||
        [lowerType containsString:@"xianyu"] || [lowerTitle containsString:@"闲鱼"] ||
        [lowerTitle containsString:@"让闲置循环"] ||
        [lowerType containsString:@"zhuanhua"] || [lowerType containsString:@"cnxdy"] ||
        [lowerTitle containsString:@"击败"] || [lowerTitle containsString:@"打怪"] || [lowerTitle containsString:@"玩一玩超"] ||
        [lowerTitle containsString:@"安装"] || [lowerTitle containsString:@"下载"]) {
        return NO;
    }
    if ([lowerType containsString:@"aifish"] || [lowerType containsString:@"touch_fish"] || [lowerTitle containsString:@"摸鱼"]) {
        return YES;
    }
    return isSafeRewardTask(taskType, title);
}

static BOOL isSafeMonopolyTask(NSString *taskType, NSString *title) {
    if (!taskType.length) return NO;
    NSString *lowerType = taskType.lowercaseString;
    NSString *lowerTitle = title ? title.lowercaseString : @"";
    
    // 外部App跳转类（如闲鱼、淘宝、快手等）无法通过简单的 finishTask RPC 完成，由用户手动做，手动做完后自动领奖
    if ([lowerType containsString:@"xianyu"] || [lowerTitle containsString:@"闲鱼"] || [lowerTitle containsString:@"让闲置循环"] ||
        [lowerType containsString:@"kuaishou"] || [lowerTitle containsString:@"快手"] ||
        [lowerTitle containsString:@"安装"] || [lowerTitle containsString:@"下载"]) {
        return NO;
    }
    
    // 带有导流前缀 DAOLIU_ 的是纯跳转/浏览安全任务
    if ([lowerType hasPrefix:@"daoliu_"] || [lowerType containsString:@"daoliu"]) {
        return YES;
    }
    
    return isSafeRewardTask(taskType, title);
}

static BOOL isSafeManorTask(NSString *taskType, NSString *title, NSDictionary *task) {
    if (!taskType.length) return NO;
    NSString *lowerType = taskType.lowercaseString;
    NSString *lowerTitle = title ? title.lowercaseString : @"";
    
    // 1. 真实付款、充值、捐款、闪购下单
    if ([lowerType containsString:@"pay"] ||
        [lowerType containsString:@"donate"] ||
        [lowerType containsString:@"czrwz"] ||
        [lowerType containsString:@"shangou"] ||
        [lowerTitle containsString:@"付款"] ||
        [lowerTitle containsString:@"支付"] ||
        [lowerTitle containsString:@"捐"] ||
        [lowerTitle containsString:@"充值"] ||
        [lowerTitle containsString:@"实付"]) {
        return NO;
    }
    
    // 2. 外部第三方独立 App（美团、今日头条、快手、饿了么、一淘、淘宝视频等）
    if ([lowerType containsString:@"meituan"] ||
        [lowerType containsString:@"toutiao"] ||
        [lowerType containsString:@"kuaishou"] ||
        [lowerType containsString:@"elm"] ||
        [lowerType containsString:@"eleme"] ||
        [lowerType containsString:@"yitao"] ||
        [lowerType containsString:@"taobao"] ||
        [lowerTitle containsString:@"美团"] ||
        [lowerTitle containsString:@"头条"] ||
        [lowerTitle containsString:@"快手"] ||
        [lowerTitle containsString:@"饿了么"] ||
        [lowerTitle containsString:@"一淘"] ||
        [lowerTitle containsString:@"淘宝视频"]) {
        return NO;
    }
    
    // 3. 系统组件/首页宫格/挨饿提醒
    if ([lowerType containsString:@"widget"] ||
        [lowerType containsString:@"push"] ||
        [lowerType containsString:@"gongge"] ||
        [lowerType containsString:@"add_app"] ||
        [lowerTitle containsString:@"小组件"] ||
        [lowerTitle containsString:@"提醒"] ||
        [lowerTitle containsString:@"首页"]) {
        return NO;
    }
    
    // 4. 外部游戏与关卡打怪
    if ([lowerType containsString:@"game"] ||
        [lowerType containsString:@"wfzy"] ||
        [lowerType containsString:@"wfyx"] ||
        [lowerType containsString:@"ljzc"] ||
        [lowerType containsString:@"sgbhsd"] ||
        [lowerType containsString:@"guandan"] ||
        [lowerType containsString:@"xjskp"] ||
        [lowerTitle containsString:@"小游戏"] ||
        [lowerTitle containsString:@"新游"] ||
        [lowerTitle containsString:@"玩一玩"] ||
        [lowerTitle containsString:@"击杀"] ||
        [lowerTitle containsString:@"招募"] ||
        [lowerTitle containsString:@"关卡"]) {
        return NO;
    }
    
    // 5. 消耗饲料或雇佣
    if ([lowerType containsString:@"fish"] ||
        [lowerType containsString:@"hire"] ||
        [lowerTitle containsString:@"喂鱼"] ||
        [lowerTitle containsString:@"雇佣"]) {
        return NO;
    }
    
    if (task && [task isKindOfClass:NSDictionary.class]) {
        NSString *playType = task[@"taskPlayType"] ?: @"";
        if ([playType isEqualToString:@"CALL_APP_OUT_TASK"]) return NO;
    }
    
    return YES;
}

static BOOL isSafeFarmTask(NSString *taskType, NSString *title) {
    if (!taskType.length) return NO;
    NSString *lowerType = taskType.lowercaseString;
    NSString *lowerTitle = title ? title.lowercaseString : @"";
    
    // 1. 鸡粪收取与纯施肥动作已在专属流程处理，严禁作为待办浏览任务入队
    if ([lowerType containsString:@"collect_manure"] || [lowerType containsString:@"spread_manure"] ||
        [lowerType isEqualToString:@"antfarm_collect_manure"]) {
        return NO;
    }
    
    // 2. 弹窗引导与迁移类伪任务（如 ORCHARD_POP_MIGRATE_XLIGHT 引导弹窗），严禁自动执行
    if ([lowerType containsString:@"pop"] || [lowerType containsString:@"migrate"] ||
        [lowerType containsString:@"dialog"] || [lowerTitle containsString:@"轻量"] ||
        [lowerTitle containsString:@"迁移"]) {
        return NO;
    }
    
    // 3. 严禁自动执行的非浏览/高风险/社交类/下单类/第三方评价类/小游戏关卡/外部App唤醒类任务
    // （服务端对此类任务明确不支持前端通用 RPC finishTask，必须由端内小游戏业务回调、userGrowth 外部 Scheme 唤醒或手动交互完成）
    if ([lowerType containsString:@"zhifu"] || [lowerType containsString:@"pay"] || [lowerTitle containsString:@"支付"] || [lowerTitle containsString:@"付款"] ||
        [lowerType containsString:@"insure"] || [lowerType containsString:@"baoxian"] || [lowerTitle containsString:@"保险"] ||
        [lowerType containsString:@"loan"] || [lowerTitle containsString:@"借呗"] || [lowerTitle containsString:@"花呗"] ||
        [lowerType containsString:@"order"] || [lowerType containsString:@"xiadan"] || [lowerTitle containsString:@"下单"] || [lowerTitle containsString:@"购买"] || [lowerTitle containsString:@"订单"] ||
        [lowerType containsString:@"zadan"] || [lowerTitle containsString:@"砸蛋"] ||
        [lowerType containsString:@"mhxcz"] ||
        [lowerType containsString:@"wzzt"] || [lowerTitle containsString:@"王者征途"] || [lowerTitle containsString:@"做30个任务"] || [lowerTitle containsString:@"做任务"] ||
        [lowerType containsString:@"gaode"] || [lowerTitle containsString:@"高德"] || [lowerTitle containsString:@"评价"] ||
        [lowerTitle containsString:@"分享"] || [lowerType containsString:@"sharer"] || [lowerType containsString:@"p2p"] ||
        [lowerTitle containsString:@"组队"] || [lowerTitle containsString:@"合种"] || [lowerTitle containsString:@"帮帮种"] || [lowerType containsString:@"team"] ||
        [lowerTitle containsString:@"下载"] || [lowerType containsString:@"caifu"] || [lowerType containsString:@"download"] ||
        [lowerTitle containsString:@"砍树"] || [lowerTitle containsString:@"关卡"] || [lowerTitle containsString:@"闯关"] || [lowerTitle containsString:@"闯5关"] || [lowerTitle containsString:@"通过"] || [lowerType containsString:@"zh_nlgj"] || [lowerType containsString:@"fkssj"] ||
        [lowerTitle containsString:@"倒水"] || [lowerTitle containsString:@"击杀"] ||
        [lowerType containsString:@"floatball_app"] ||
        [lowerType containsString:@"kuaishou"] || [lowerTitle containsString:@"快手"] ||
        [lowerType containsString:@"meituan"] || [lowerTitle containsString:@"美团"] ||
        [lowerType containsString:@"taobaochengjiu"] || [lowerTitle containsString:@"淘宝成就"] || [lowerTitle containsString:@"周边"] ||
        [lowerType containsString:@"jindouduobao"] || [lowerTitle containsString:@"夺宝"] || [lowerTitle containsString:@"新手引导"] ||
        [lowerType containsString:@"group_1_step"]) {
        // 网商银行 / 网商贷看额度等官方安全浏览任务，予以放行（砍树、砸蛋等端内游戏内部动作严禁放行）
        if (!([lowerTitle containsString:@"网商"] || [lowerType containsString:@"wangshang"] || [lowerType containsString:@"wsyh"])) {
            return NO;
        }
    }
    
    // 4. 淘系商品导流任务（70000、104322等）在 antiep 网关无RPC配置，需在 Web 页面交互，禁止 RPC 直调
    if ([lowerType isEqualToString:@"70000"] || [lowerType isEqualToString:@"104322"]) {
        return NO;
    }
    
    // 5. 明确支持的白名单浏览与农场乐园小游戏特征（探针验证 100% 可通过 RPC 浏览时长完成并领奖）
    if (([lowerType containsString:@"floatball"] && ![lowerType containsString:@"floatball_app"]) ||
        [lowerType containsString:@"ncly"] ||
        [lowerType containsString:@"star30s"] ||
        [lowerType containsString:@"denghuo"] ||
        [lowerType containsString:@"chouchoule"] ||
        [lowerType containsString:@"jdly"] ||
        [lowerType containsString:@"qutoutiao"] ||
        [lowerType isEqualToString:@"58298"] || [lowerType containsString:@"defoliation"] ||
        [lowerType containsString:@"huiyuan"] ||
        [lowerType containsString:@"wsyh"] || [lowerType containsString:@"wangshang"] ||
        [lowerTitle containsString:@"网商"] || [lowerTitle containsString:@"会员"] ||
        [lowerTitle containsString:@"金豆乐园"] || [lowerTitle containsString:@"抽抽乐"] ||
        [lowerTitle containsString:@"精选商品"] ||
        [lowerTitle containsString:@"玩一玩"] ||
        [lowerTitle containsString:@"小游戏"] ||
        [lowerTitle containsString:@"寻道大千"] ||
        [lowerTitle containsString:@"保卫向日葵"] ||
        [lowerTitle containsString:@"烈焰觉醒"] ||
        [lowerTitle containsString:@"浪漫餐厅"] || [lowerType containsString:@"lmct"] ||
        [lowerTitle containsString:@"解螺丝"] ||
        [lowerTitle containsString:@"花园世界"] ||
        [lowerTitle containsString:@"消消消"] ||
        [lowerTitle containsString:@"助农"] || [lowerTitle containsString:@"好货"] || [lowerTitle containsString:@"好物"] ||
        [lowerTitle containsString:@"游戏"] ||
        [lowerTitle containsString:@"乐园"]) {
        return YES;
    }
    
    // 6. 其他常规纯浏览任务（排除上述黑名单后，标题带浏览/看等特征）
    if ([lowerTitle containsString:@"看精选"] || [lowerTitle containsString:@"浏览"] || [lowerTitle containsString:@"逛"] || [lowerTitle containsString:@"看"]) {
        return YES;
    }
    
    return NO;
}

- (NSString *)effectiveUrlForSceneCode:(NSString *)sceneCode {
    if ([sceneCode containsString:@"RESCUE"] || [sceneCode containsString:@"ANTOCEAN"] || [sceneCode containsString:@"OCEAN"]) {
        return self.oceanH5Url ?: @"https://2021003115672468.h5app.alipay.com/www/index.html?source=ANT_FOREST&showTaskPanel=yes";
    }
    if ([sceneCode containsString:@"AIFISH"] || [sceneCode containsString:@"ANTAIFISH"]) {
        return self.aiFishH5Url ?: @"https://render.alipay.com/p/yuyan/180020010001290531/index.html?caprMode=sync&source=ANT_OCEAN";
    }
    if ([sceneCode containsString:@"ANTFARM_FOOD"] || [sceneCode containsString:@"MANOR"]) {
        return self.manorH5Url ?: @"https://66666674.h5app.alipay.com/www/index.html";
    }
    if ([sceneCode containsString:@"FARM"] || [sceneCode containsString:@"ORCHARD"] || [sceneCode isEqualToString:@"10021"] || [sceneCode isEqualToString:@"3646"] || [sceneCode hasPrefix:@"BABA_"]) {
        return self.farmH5Url ?: @"https://render.alipay.com/p/yuyan/180020010001263018/game.html?caprMode=sync";
    }
    if ([sceneCode containsString:@"MONOPOLY"] || [sceneCode containsString:@"HSDWY"]) {
        return self.monopolyH5Url ?: @"https://render.alipay.com/p/yuyan/180020010001293606/index.html?caprMode=sync";
    }
    if ([sceneCode containsString:@"ACTIVITY_DRAW"]) {
        return self.lotteryH5Url ?: @"https://render.alipay.com/p/yuyan/180020010001279274/lotteryMachine.html?caprMode=sync&sceneCode=ANTFOREST_ACTIVITY_DRAW&source=task_entry&chInfo=task_entry";
    }
    if ([sceneCode containsString:@"DRAW"] || [sceneCode containsString:@"LOTTERY"] || [sceneCode containsString:@"VITALITY_EXCHANGE"]) {
        return self.lotteryH5Url ?: @"https://render.alipay.com/p/yuyan/180020010001279274/lotteryMachine.html?caprMode=sync&sceneCode=ANTFOREST_NORMAL_DRAW&source=task_entry&chInfo=task_entry";
    }
    return @"https://render.alipay.com/p/yuyan/180020010001247580/home.html";
}

- (NSString *)effectiveUrlForBridge:(PSDJsBridge *)bridge {
    if (bridge) {
        @try {
            id cv = [bridge respondsToSelector:@selector(contentView)] ? ((id (*)(id, SEL))objc_msgSend)(bridge, @selector(contentView)) : nil;
            if ([cv respondsToSelector:@selector(url)]) {
                id u = ((id (*)(id, SEL))objc_msgSend)(cv, @selector(url));
                if ([u isKindOfClass:NSURL.class] && [(NSURL *)u absoluteString].length) return [(NSURL *)u absoluteString];
                if ([u isKindOfClass:NSString.class] && [(NSString *)u length]) return (NSString *)u;
            }
            if ([cv respondsToSelector:@selector(URL)]) {
                id u = ((id (*)(id, SEL))objc_msgSend)(cv, @selector(URL));
                if ([u isKindOfClass:NSURL.class] && [(NSURL *)u absoluteString].length) return [(NSURL *)u absoluteString];
            }
            if ([cv respondsToSelector:@selector(webView)]) {
                id wv = ((id (*)(id, SEL))objc_msgSend)(cv, @selector(webView));
                if ([wv respondsToSelector:@selector(URL)]) {
                    NSURL *u = ((NSURL *(*)(id, SEL))objc_msgSend)(wv, @selector(URL));
                    if ([u isKindOfClass:NSURL.class] && u.absoluteString.length) return u.absoluteString;
                }
            }
            if ([bridge respondsToSelector:@selector(webView)]) {
                id wv = ((id (*)(id, SEL))objc_msgSend)(bridge, @selector(webView));
                if ([wv respondsToSelector:@selector(URL)]) {
                    NSURL *u = ((NSURL *(*)(id, SEL))objc_msgSend)(wv, @selector(URL));
                    if ([u isKindOfClass:NSURL.class] && u.absoluteString.length) return u.absoluteString;
                }
            }
        } @catch (NSException *e) {}
    }
    return nil;
}

- (void)registerBridge:(id)bridge withUrl:(NSString *)url {
    if (!bridge) return;
    
    NSString *effectiveUrl = url.length ? url : [self effectiveUrlForBridge:bridge];
    NSString *lowerUrl = effectiveUrl.lowercaseString;
    
    if (lowerUrl.length) {
        if ([lowerUrl containsString:@"180020010001293606"] || [lowerUrl containsString:@"monopoly"] || [lowerUrl containsString:@"hsdwy"] || [lowerUrl containsString:@"patrol"] || [lowerUrl containsString:@"guardian"]) {
            self.monopolyBridge = bridge;
            self.monopolyH5Url = effectiveUrl;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                [self claimAllVisibleMonopolyRewardsOnWebView];
            });
        } else if ([lowerUrl containsString:@"180020010001290531"] || [lowerUrl containsString:@"aifish"] || [lowerUrl containsString:@"antaifish"]) {
            self.aiFishBridge = bridge;
            self.aiFishH5Url = effectiveUrl;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                [self claimAllVisibleAIFishRewardsOnWebView];
            });
        } else if ([lowerUrl containsString:@"180020010001263018"] || [lowerUrl containsString:@"farm"] || [lowerUrl containsString:@"orchard"]) {
            self.farmBridge = bridge;
            self.farmH5Url = effectiveUrl;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                [self claimAllVisibleFarmRewardsOnWebView];
            });
        } else if ([lowerUrl containsString:@"2021003115672468"] || [lowerUrl containsString:@"ocean"]) {
            self.oceanBridge = bridge;
            self.oceanH5Url = effectiveUrl;
        } else if ([lowerUrl containsString:@"180020010001279274"] || [lowerUrl containsString:@"lotterymachine"] || [lowerUrl containsString:@"draw"]) {
            self.lotteryBridge = bridge;
            self.lotteryH5Url = effectiveUrl;
        } else if ([lowerUrl containsString:@"pvphome"] || [lowerUrl containsString:@"pvp"] || [lowerUrl containsString:@"pkcontest"] || [lowerUrl containsString:@"pkfind"] || [lowerUrl containsString:@"challenge"] || [lowerUrl containsString:@"arena"] || [lowerUrl containsString:@"listrank"]) {
            self.lastPkInteractionTime = [[NSDate date] timeIntervalSince1970];
        } else if (([lowerUrl containsString:@"180020010001247580"] && [lowerUrl containsString:@"home.html"]) || [lowerUrl containsString:@"vitality"] || [lowerUrl containsString:@"reward"] || [lowerUrl hasSuffix:@"home.html"]) {
            self.jsBridge = bridge;
            self.rewardTaskBridge = bridge;
            self.rewardTaskH5Url = effectiveUrl;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                [self claimAllVisibleRewardTaskRewardsOnWebView];
            });
        } else {
            if (!self.jsBridge) {
                self.jsBridge = bridge;
            }
        }
    } else {
        if (!self.jsBridge) {
            self.jsBridge = bridge;
        }
    }
}

- (void)checkAndTriggerPageActionsForUrl:(NSString *)urlStr {
    if (!urlStr.length) return;
    NSString *lowerUrl = urlStr.lowercaseString;
    if ([lowerUrl containsString:@"pvphome"] || [lowerUrl containsString:@"pvp"] || [lowerUrl containsString:@"pkcontest"] || [lowerUrl containsString:@"pkfind"] || [lowerUrl containsString:@"challenge"] || [lowerUrl containsString:@"arena"] || [lowerUrl containsString:@"listrank"]) {
        self.lastPkInteractionTime = [[NSDate date] timeIntervalSince1970];
        return;
    }
    
    if ([lowerUrl containsString:@"180020010001293606"] || [lowerUrl containsString:@"monopoly"] || [lowerUrl containsString:@"hsdwy"] || [lowerUrl containsString:@"patrol"] || [lowerUrl containsString:@"guardian"]) {
        if (self.enableAutoPatrolNew) {
            [self queryMonopolyTaskListWithForce:YES];
            [self claimAllVisibleMonopolyRewardsOnWebView];
        }
    } else if ([lowerUrl containsString:@"180020010001290531"] || [lowerUrl containsString:@"aifish"] || [lowerUrl containsString:@"antaifish"]) {
        if (self.enableAutoAIFish) {
            [self queryAIFishTaskListWithForce:YES];
            [self claimAllVisibleAIFishRewardsOnWebView];
        }
    } else if ([lowerUrl containsString:@"180020010001263018"] || [lowerUrl containsString:@"farm"] || [lowerUrl containsString:@"orchard"]) {
        if (self.enableAutoFarmTasks) {
            [self queryFarmTaskListWithForce:YES];
            [self claimAllVisibleFarmRewardsOnWebView];
        }
    } else if ([lowerUrl containsString:@"2021003115672468"] || [lowerUrl containsString:@"ocean"]) {
        if (self.enableAutoOceanTasks) {
            [self queryOceanTaskListWithForce:YES];
        }
    } else if (([lowerUrl containsString:@"180020010001247580"] && [lowerUrl containsString:@"home.html"]) || [lowerUrl containsString:@"vitality"] || [lowerUrl containsString:@"reward"]) {
        if (self.enableAutoRewardTasks) {
            [self queryVitalityTaskListWithForce:YES];
            [self claimAllVisibleRewardTaskRewardsOnWebView];
        }
    }
}

- (NSString *)urlForSceneCode:(NSString *)scene bridge:(PSDJsBridge *)bridge {
    NSString *bridgeUrl = [self effectiveUrlForBridge:bridge];
    BOOL isBridgeOnLottery = bridgeUrl && ([bridgeUrl containsString:@"180020010001279274"] || [bridgeUrl.lowercaseString containsString:@"lotterymachine"]);
    if ([scene containsString:@"ACTIVITY_DRAW"]) {
        if (isBridgeOnLottery) {
            return bridgeUrl;
        }
        return self.lotteryH5Url ?: [self effectiveUrlForSceneCode:@"ANTFOREST_ACTIVITY_DRAW_TASK"];
    }
    if ([scene containsString:@"DRAW"] || [scene containsString:@"LOTTERY"]) {
        if (isBridgeOnLottery) {
            return bridgeUrl;
        }
        return self.lotteryH5Url ?: [self effectiveUrlForSceneCode:@"ANTFOREST_NORMAL_DRAW_TASK"];
    }
    if ([scene containsString:@"MONOPOLY"] || [scene containsString:@"HSDWY"]) {
        return self.monopolyH5Url ?: bridgeUrl ?: [self effectiveUrlForSceneCode:@"ANTFOREST_MONOPOLY_TASK_HSDWY"];
    }
    return bridgeUrl ?: [self effectiveUrlForSceneCode:scene];
}

-(void)probeAndRestoreBridges {
    static BOOL sIsProbingBridges = NO;
    if (sIsProbingBridges) return;
    sIsProbingBridges = YES;
    @try {
        if (self.bridgeProbeHandler) {
            self.bridgeProbeHandler();
        }
        if (!self.rewardTaskBridge && self.jsBridge) {
            self.rewardTaskBridge = self.jsBridge;
        }
    } @finally {
        sIsProbingBridges = NO;
    }
}

-(void)queryVitalityTaskList {
    [self queryVitalityTaskListWithForce:NO];
}

-(void)queryVitalityTaskListWithForce:(BOOL)force {
    BOOL isWithinActive = isWithinTaskActiveHours();
    BOOL isSignedToday = NO;
    initDailyTaskCache();
    @synchronized(self) {
        isSignedToday = [gDailyCompletedTasks containsObject:@"SIGN_TODAY"];
    }
    
    // 零点后支持自动签到；若今日签到已完成且处于凌晨时段（00:00~07:00），常规做任务静默挂起等待早7点执行
    if (!isWithinActive && isSignedToday) {
        static NSTimeInterval sLastSilentLogTime = 0;
        NSTimeInterval nowTime = [[NSDate date] timeIntervalSince1970];
        if (nowTime - sLastSilentLogTime > 1800.0) {
            sLastSilentLogTime = nowTime;
            [self recordStage:[NSString stringWithFormat:@"领奖励：今日签到已完成，常规做任务处于静默期，%@ 后自动唤醒执行", getTaskActiveStartTimeString()]];
        }
        return;
    }
    
    static NSTimeInterval lastQueryVitalityTaskListTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (!force && (now - lastQueryVitalityTaskListTime < 2.0)) return;
    lastQueryVitalityTaskListTime = now;
    
    [self probeAndRestoreBridges];
    if (!self.rewardTaskBridge && self.jsBridge) {
        self.rewardTaskBridge = self.jsBridge;
    }
    PSDJsBridge *bridge = self.rewardTaskBridge;
    if (!bridge) {
        bridge = self.jsBridge ?: self.oceanBridge ?: self.aiFishBridge ?: self.farmBridge ?: self.monopolyBridge ?: self.lotteryBridge;
    }
    if (!self.enableAutoRewardTasks || !bridge) {
        if (self.enableAutoRewardTasks) [self recordStage:@"首页后台：等待领奖励任务桥接"];
        return;
    }
    initDailyTaskCache();
    // 严禁在此处清空 gVitalityTaskRetryCounts！force=YES 会在每批任务完成 2.5 秒后自动刷新调用，
    // 若在此处清空会导致失败任务在 2.5 秒后重试计数归零，形成无限死循环重试。
    // gVitalityTaskRetryCounts 仅在每轮 15 分钟定时全量扫描（autoCollectBubbles）启动时重置。
    
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *randNum2 = [AntForestManager getNumberRandom:15];
    
    // 严格使用森林原生 URL 派发任务 RPC，彻底杜绝跨 AppId 污染或被子页面误拦截
    NSString *fixedForestHomeUrl = @"https://render.alipay.com/p/yuyan/180020010001247580/home.html";
    PSDJsBridge *forestHomeBridge = self.jsBridge ?: bridge;
    NSString *urlForestHome = fixedForestHomeUrl;
    NSString *homeDynamic = [self effectiveUrlForBridge:forestHomeBridge];
    NSString *homeDynamicLower = homeDynamic.lowercaseString;
    if (homeDynamic.length && [homeDynamicLower containsString:@"home.html"] && ![homeDynamicLower containsString:@"pvphome"] && ![homeDynamicLower containsString:@"pk"] && ![homeDynamicLower containsString:@"challenge"] && ![homeDynamic containsString:@"180020010001293606"]) {
        urlForestHome = homeDynamic;
    }
    
    NSString *urlDynamic = [self effectiveUrlForBridge:bridge];
    NSString *urlDynamicLower = urlDynamic.lowercaseString;
    NSString *urlVitality = fixedForestHomeUrl;
    if (urlDynamic.length && [urlDynamicLower containsString:@"home.html"] && ![urlDynamicLower containsString:@"pvphome"] && ![urlDynamicLower containsString:@"pk"] && ![urlDynamicLower containsString:@"challenge"] && ![urlDynamic containsString:@"180020010001293606"]) {
        urlVitality = urlDynamic;
    }
    
    if (isWithinActive) {
        NSLog(@"[AntForestPort] 任务中心：正在拉取最新任务列表与阶段奖励...");
    } else {
        NSLog(@"[AntForestPort] 任务中心：正在拉取今日能量签到 (零点后自动签到，常规任务将在早7点开启)...");
    }
    
    // 1. 主线日常任务列表与每日能量签到 (主通道必须派发至森林首页 Bridge: forestHomeBridge，确保零点跨天100%成功拉取)
    // 1.1 主线日常任务列表与每日能量签到（必须携带 fromAct: home_task_list 与版本 20250821，服务端方会下发完整 forestSignVOList 与 signId）
    NSString *forestArg1 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.queryTaskList\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"version\":\"20250821\",\"fromAct\":\"home_task_list\",\"source\":\"ANTFOREST\"}],\"appName\":\"antforest\",\"getResponse\":true},\"callbackId\":\"rpc_%@.%@_htl\"}]", timeStamp, randNum2];
    [self safeFlushBridge:forestHomeBridge message:forestArg1 url:urlForestHome];
    if (bridge && bridge != forestHomeBridge) {
        [self safeFlushBridge:bridge message:forestArg1 url:urlVitality];
    }
    
    // 1.2 签到专区任务列表（fromAct: home_sign_task_list，双通道确保签到实体百分之百下发）
    NSString *forestArgSign = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.queryTaskList\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"version\":\"20250821\",\"fromAct\":\"home_sign_task_list\",\"source\":\"ANTFOREST\"}],\"appName\":\"antforest\",\"getResponse\":true},\"callbackId\":\"rpc_%@.%@_hst\"}]", timeStamp, [AntForestManager getNumberRandom:15]];
    [self safeFlushBridge:forestHomeBridge message:forestArgSign url:urlForestHome];
    if (bridge && bridge != forestHomeBridge) {
        [self safeFlushBridge:bridge message:forestArgSign url:urlVitality];
    }
    
    // 1.3 官方通用签到信息查询 (queryCommonSign，返回 forestSignVO)
    NSString *forestArgCommonSign = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.queryCommonSign\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"bizType\":\"ANTFOREST_ENERGY_TASK_SIGN\",\"withEntity\":true}],\"appName\":\"antforest\",\"getResponse\":true},\"callbackId\":\"rpc_%@.%@_cs\"}]", timeStamp, [AntForestManager getNumberRandom:15]];
    [self safeFlushBridge:forestHomeBridge message:forestArgCommonSign url:urlForestHome];
    if (bridge && bridge != forestHomeBridge) {
        [self safeFlushBridge:bridge message:forestArgCommonSign url:urlVitality];
    }
    
    // 1.4 若今日尚未完成签到，主动发送一次默认签到 RPC（双发保障：即使 queryTaskList 回包慢，也能直接签到成功）
    if (!isSignedToday) {
        [self signVitalityTask:@"" sceneCode:@"ANTFOREST_ENERGY_TASK_SIGN"];
    }
    
    // 2. 现代任务中心领奖励任务 (ANTFOREST_VITALITY_TASK，仅在早 07:00 活跃期执行，凌晨静默期严禁发送常规做任务 RPC)
    if (isWithinActive) {
        NSString *argVitality1 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.listTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"ANTFOREST_VITALITY_TASK\",\"source\":\"ANTFOREST\",\"requestType\":\"RPC\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, [AntForestManager getNumberRandom:15]];
        [self safeFlushBridge:bridge message:argVitality1 url:urlVitality];
        if (forestHomeBridge && forestHomeBridge != bridge) {
            [self safeFlushBridge:forestHomeBridge message:argVitality1 url:urlForestHome];
        }
    }
}

-(void)queryLotteryTaskList {
    [self queryLotteryTaskListWithForce:NO];
}

-(void)queryLotteryTaskListWithForce:(BOOL)force {
    if (!isWithinTaskActiveHours()) return;
    if (!self.enableAutoRewardTasks) return;
    PSDJsBridge *bridge = self.lotteryBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    if (!bridge) {
        [self recordStage:@"森林寻宝：等待寻宝界面桥接就绪..."];
        return;
    }
    initDailyTaskCache();
    
    static NSTimeInterval lastQueryLotteryTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (!force && (now - lastQueryLotteryTime < 2.0)) return;
    lastQueryLotteryTime = now;
    
    sLastQueriedSceneCode = @"ANTFOREST_NORMAL_DRAW_TASK";
    [self notifyActiveH5PageToRefresh];
    
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *urlDraw1 = self.lotteryH5Url ?: [self urlForSceneCode:@"ANTFOREST_NORMAL_DRAW_TASK" bridge:bridge];
    NSString *urlDraw2 = self.lotteryH5Url ?: [self urlForSceneCode:@"ANTFOREST_ACTIVITY_DRAW_TASK" bridge:bridge];
    
    NSLog(@"[AntForestPort] 森林寻宝：已进入寻宝界面，正在拉取寻宝日常与活动任务列表...");
    
    NSString *argDraw1 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.listTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"ANTFOREST_NORMAL_DRAW_TASK\",\"source\":\"ANTFOREST\",\"requestType\":\"RPC\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, [AntForestManager getNumberRandom:15]];
    [bridge _doFlushMessageQueue:argDraw1 url:urlDraw1];

    NSString *argDraw2 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.listTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"ANTFOREST_ACTIVITY_DRAW_TASK\",\"source\":\"ANTFOREST\",\"requestType\":\"RPC\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, [AntForestManager getNumberRandom:15]];
    [bridge _doFlushMessageQueue:argDraw2 url:urlDraw2];
}

-(void)queryMonopolyTaskList {
    [self queryMonopolyTaskListWithForce:NO];
}

-(void)queryMonopolyTaskListWithForce:(BOOL)force {
    if (!isWithinTaskActiveHours()) return;
    if (!self.enableAutoPatrolNew) return;
    PSDJsBridge *bridge = self.monopolyBridge;
    if (!bridge) return;
    initDailyTaskCache();
    
    static NSTimeInterval lastQueryMonopolyTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (!force && (now - lastQueryMonopolyTime < 2.0)) return;
    lastQueryMonopolyTime = now;
    
    sLastQueriedSceneCode = @"ANTFOREST_MONOPOLY_TASK_HSDWY";
    [self notifyActiveH5PageToRefresh];
    
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *monopolyScene = @"ANTFOREST_MONOPOLY_TASK_HSDWY";
    NSString *urlMonopoly = self.monopolyH5Url ?: [self effectiveUrlForBridge:bridge] ?: [self effectiveUrlForSceneCode:monopolyScene];
    NSString *argMonopoly1 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.listTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"%@\",\"source\":\"ANTFOREST\",\"requestType\":\"RPC\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", monopolyScene, timeStamp, [AntForestManager getNumberRandom:15]];
    NSLog(@"[AntForestPort] 新版保护地：已进入保护地界面，读取保护地巡护任务列表");
    [bridge _doFlushMessageQueue:argMonopoly1 url:urlMonopoly];
}

-(void)queryOceanTaskList {
    [self queryOceanTaskListWithForce:NO];
}

-(void)queryOceanTaskListWithForce:(BOOL)force {
    if (!isWithinTaskActiveHours()) return;
    if (!self.enableAutoOceanTasks) return;
    if (!self.oceanBridge || self.oceanBridge == self.jsBridge) return;
    PSDJsBridge *bridge = self.oceanBridge;
    if (!bridge) return;
    initDailyTaskCache();
    
    static NSTimeInterval lastQueryOceanTaskListTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (!force && (now - lastQueryOceanTaskListTime < 2.0)) return;
    lastQueryOceanTaskListTime = now;
    
    // 主动让 WebView 触发 pullRefresh 事件，刷新前端页面与抽屉组件
    [self notifyActiveH5PageToRefresh];
    
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *urlOcean = self.oceanH5Url ?: [self effectiveUrlForBridge:bridge] ?: [self effectiveUrlForSceneCode:@"ANTOCEAN_TASK"];
    
    // 1. ANTOCEAN_TASK (神奇海洋主任务与拼图，权威接口 alipay.antocean.ocean.h5.queryTaskList)
    NSString *randTask = [AntForestManager getNumberRandom:15];
    NSString *uniqueIdTask = [NSString stringWithFormat:@"%@%@", timeStamp, randTask];
    NSString *argOceanTask = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antocean.ocean.h5.queryTaskList\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"extend\":{},\"fromAct\":\"dynamic_task\",\"sceneCode\":\"ANTOCEAN_TASK\",\"source\":\"ANT_FOREST\",\"uniqueId\":\"%@\",\"version\":\"20241203\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", uniqueIdTask, timeStamp, randTask];
    NSLog(@"[AntForestPort] 神奇海洋：正在拉取主任务与拼图列表 (queryTaskList)...");
    [bridge _doFlushMessageQueue:argOceanTask url:urlOcean];
    
    // 2. ANTOCEAN_AVATAR_TASK (潘多拉海域副本任务)
    NSString *randAvatar = [AntForestManager getNumberRandom:15];
    NSString *uniqueIdAvatar = [NSString stringWithFormat:@"%@%@", timeStamp, randAvatar];
    NSString *argOceanAvatar = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antocean.ocean.h5.queryTaskList\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"fromAct\":\"dynamic_task\",\"sceneCode\":\"ANTOCEAN_AVATAR_TASK\",\"source\":\"seaAreaList\",\"uniqueId\":\"%@\",\"version\":\"20241203\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", uniqueIdAvatar, timeStamp, randAvatar];
    [bridge _doFlushMessageQueue:argOceanAvatar url:urlOcean];
    
    // 3. 神奇海洋主页状态 (queryHomePage)
    NSString *randHome = [AntForestManager getNumberRandom:15];
    NSString *uniqueIdHome = [NSString stringWithFormat:@"%@%@", timeStamp, randHome];
    NSString *argOceanHome = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antocean.ocean.h5.queryHomePage\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"source\":\"ANT_FOREST\",\"uniqueId\":\"%@\",\"version\":\"20241203\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", uniqueIdHome, timeStamp, randHome];
    [bridge _doFlushMessageQueue:argOceanHome url:urlOcean];
    
    // 4. ANTAIFISH_RESCUE_AND_RESTORE (海洋救助动物任务，如逛一逛惊喜市集等，补充 OpenGreen 任务网关)
    NSString *argOceanRescue = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.listTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"ANTAIFISH_RESCUE_AND_RESTORE\",\"source\":\"ANT_OCEAN\",\"requestType\":\"RPC\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, [AntForestManager getNumberRandom:15]];
    [bridge _doFlushMessageQueue:argOceanRescue url:urlOcean];
}

static NSString *sLastQueriedSceneCode = nil;

-(void)queryAIFishTaskList {
    [self queryAIFishTaskListWithForce:NO];
}

-(void)queryAIFishTaskListWithForce:(BOOL)force {
    if (!isWithinTaskActiveHours()) return;
    if (!self.enableAutoAIFish) return;
    PSDJsBridge *bridge = self.aiFishBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    if (!bridge) return;
    initDailyTaskCache();
    sLastQueriedSceneCode = @"ANTAIFISH";
    
    static NSTimeInterval lastQueryAIFishTaskListTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (!force && (now - lastQueryAIFishTaskListTime < 2.0)) return;
    lastQueryAIFishTaskListTime = now;
    
    [self notifyActiveH5PageToRefresh];
    
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *urlAIFish = self.aiFishH5Url ?: [self effectiveUrlForBridge:bridge] ?: [self effectiveUrlForSceneCode:@"ANTAIFISH"];
    
    NSLog(@"[AntForestPort] AI摸鱼：正在拉取摸鱼任务与涂鸦机会...");
    
    // ANTAIFISH (每日赠送摸鱼次数、看15s视频等真实摸鱼任务)
    NSString *argFish1 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.listTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"ANTAIFISH\",\"source\":\"ANT_OCEAN\",\"requestType\":\"RPC\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, [AntForestManager getNumberRandom:15]];
    [bridge _doFlushMessageQueue:argFish1 url:urlAIFish];
}

-(void)queryFarmTaskList {
    [self queryFarmTaskListWithForce:NO];
}

-(void)queryFarmTaskListWithForce:(BOOL)force {
    if (!isWithinTaskActiveHours()) return;
    if (!self.enableAutoFarmTasks) return;
    PSDJsBridge *bridge = self.farmBridge;
    if (!bridge) return;
    initDailyTaskCache();
    
    static NSTimeInterval lastQueryFarmTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval minInterval = force ? 1.0 : 6.0;
    if (now - lastQueryFarmTime < minInterval) return;
    lastQueryFarmTime = now;
    
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)(now * 1000)];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *urlDynamic = [self effectiveUrlForBridge:bridge];
    NSString *urlFarm = urlDynamic ?: [self effectiveUrlForSceneCode:@"ANTFARM_ORCHARD_TASK_V2"];
    
    NSLog(@"[AntForestPort] 芭芭农场：正在拉取最新肥料任务...");
    
    // 查询农场主任务列表 (ANTFARM_ORCHARD_TASK_V2)
    NSString *argFarm1 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.listTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"ANTFARM_ORCHARD_TASK_V2\",\"source\":\"BABA_FARM\",\"requestType\":\"RPC\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, randNum];
    [bridge _doFlushMessageQueue:argFarm1 url:urlFarm];
    
    // 同时触发 Web 页面自动化呼出“领肥料”面板并领奖
    [self openFarmTaskPanelOnWebView];
    [self claimAllVisibleFarmRewardsOnWebView];
}

-(void)signVitalityTask:(NSString *)signId {
    [self signVitalityTask:signId sceneCode:@"ANTFOREST_ENERGY_TASK_SIGN"];
}

-(void)signVitalityTask:(NSString *)signId sceneCode:(NSString *)sceneCode {
    [self probeAndRestoreBridges];
    if (!self.rewardTaskBridge && self.jsBridge) {
        self.rewardTaskBridge = self.jsBridge;
    }
    PSDJsBridge *forestHomeBridge = self.jsBridge ?: self.rewardTaskBridge;
    PSDJsBridge *bridge = self.rewardTaskBridge ?: self.jsBridge ?: self.oceanBridge ?: self.aiFishBridge ?: self.farmBridge ?: self.monopolyBridge ?: self.lotteryBridge;
    if (!forestHomeBridge && !bridge) return;
    
    self.lastRpcOperationType = @"com.alipay.antiep.sign";
    
    NSString *effectiveUid = self.myUserId.length ? self.myUserId : ([[NSUserDefaults standardUserDefaults] stringForKey:@"lastKnownUserId"] ?: @"");
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    
    NSString *forestUrl = @"https://render.alipay.com/p/yuyan/180020010001247580/home.html";
    NSString *bridgeUrl = [self effectiveUrlForBridge:forestHomeBridge ?: bridge];
    if (bridgeUrl.length && ([bridgeUrl containsString:@"180020010001247580"] || [bridgeUrl containsString:@"60000002"] || [bridgeUrl containsString:@"home.html"])) {
        forestUrl = bridgeUrl;
    }
    
    // 严格保留服务端的原生 sceneCode（如 ANTFOREST_ENERGY_TASK_SIGN），若为空则默认 ANTFOREST_ENERGY_TASK_SIGN
    // 严禁篡改为 ANTFOREST_ENERGY_SIGN，否则服务端报 1400000004 签到实例不存在！
    NSString *scene = sceneCode.length ? sceneCode : @"ANTFOREST_ENERGY_TASK_SIGN";
    NSString *effectiveSignId = signId.length ? signId : @"";
    
    // 1. 标准 antiep.sign RPC（能量任务签到实体）
    // 即使 effectiveSignId 暂时为空，也立即发送基础签到 RPC，确保服务端能触发默认签到或返回实例
    NSMutableDictionary *reqDict = [NSMutableDictionary dictionaryWithDictionary:@{
        @"source": @"ANTFOREST",
        @"sceneCode": scene,
        @"requestType": @"rpc",
        @"userId": effectiveUid ?: @""
    }];
    if (effectiveSignId.length) {
        reqDict[@"entityId"] = effectiveSignId;
    }
    NSData *reqJson = [NSJSONSerialization dataWithJSONObject:@[reqDict] options:0 error:nil];
    NSString *reqStr = reqJson ? [[NSString alloc] initWithData:reqJson encoding:NSUTF8StringEncoding] : @"";
    if (reqStr.length) {
        NSString *arg1 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antiep.sign\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":%@,\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", reqStr, timeStamp, randNum];
        [forestHomeBridge _doFlushMessageQueue:arg1 url:forestUrl];
        if (bridge && bridge != forestHomeBridge) {
            [bridge _doFlushMessageQueue:arg1 url:forestUrl];
        }
    }
    
    // 2. 连续签到与通用签到 RPC（sceneCode: ANTFOREST_LIANXU_SIGN_2025）
    NSString *argLianxu = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antiep.sign\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"source\":\"ANTFOREST\",\"sceneCode\":\"ANTFOREST_LIANXU_SIGN_2025\",\"requestType\":\"rpc\",\"userId\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@_lx\"}]", effectiveUid ?: @"", timeStamp, randNum];
    [forestHomeBridge _doFlushMessageQueue:argLianxu url:forestUrl];
    if (bridge && bridge != forestHomeBridge) {
        [bridge _doFlushMessageQueue:argLianxu url:forestUrl];
    }
    
    // 3. 若无 signId，同步发送 queryCommonSign 获取最新签到实体
    if (!effectiveSignId.length) {
        NSString *queryCs = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.queryCommonSign\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"bizType\":\"%@\",\"withEntity\":true}],\"appName\":\"antforest\",\"getResponse\":true},\"callbackId\":\"rpc_%@.%@_qcs\"}]", scene, timeStamp, [AntForestManager getNumberRandom:15]];
        [forestHomeBridge _doFlushMessageQueue:queryCs url:forestUrl];
        if (bridge && bridge != forestHomeBridge) {
            [bridge _doFlushMessageQueue:queryCs url:forestUrl];
        }
    }
    
    // 4. 端内 JSBridge 双发保障（直接通过页面上下文调用）
    NSString *jsSign = [NSString stringWithFormat:@"(()=>{try{"
                        "if(window.AlipayJSBridge&&window.AlipayJSBridge.call){"
                        "  var uid = '%@';"
                        "  var eid = '%@';"
                        "  var sc = '%@';"
                        "  var req = [{source:'ANTFOREST',sceneCode:sc,requestType:'rpc',userId:uid}];"
                        "  if(eid.length) req[0].entityId = eid;"
                        "  window.AlipayJSBridge.call('rpc',{"
                        "    operationType:'com.alipay.antiep.sign',"
                        "    requestData:req,"
                        "    headers:{'source':'chInfo_ch_appcenter__chsub_9patch','ags-source':'chInfo_ch_appcenter__chsub_9patch'},"
                        "    getResponse:true"
                        "  },function(res){"
                        "    console.log('[AntForestPort] AlipayJSBridge sign returned:',res);"
                        "  });"
                        "  window.AlipayJSBridge.call('rpc',{"
                        "    operationType:'com.alipay.antiep.sign',"
                        "    requestData:[{source:'ANTFOREST',sceneCode:'ANTFOREST_LIANXU_SIGN_2025',requestType:'rpc',userId:uid}],"
                        "    headers:{'source':'chInfo_ch_appcenter__chsub_9patch','ags-source':'chInfo_ch_appcenter__chsub_9patch'},"
                        "    getResponse:true"
                        "  },function(res){"
                        "    console.log('[AntForestPort] AlipayJSBridge lianxu sign returned:',res);"
                        "  });"
                        "}"
                        "}catch(e){}})();", effectiveUid ?: @"", effectiveSignId, scene];
    [self executeRewardTaskScriptOnWebView:jsSign];
}

-(void)applyVitalityTask:(NSString *)taskType sceneCode:(NSString *)sceneCode taskTitle:(NSString *)title {
    NSString *scene = sceneCode.length ? sceneCode : @"ANTFOREST_VITALITY_TASK";
    BOOL isFarmScene = [scene containsString:@"FARM"] || [scene containsString:@"ORCHARD"] || [scene isEqualToString:@"10021"] || [scene isEqualToString:@"3646"] || [scene hasPrefix:@"BABA_"];
    BOOL isMonopolyScene = [scene containsString:@"MONOPOLY"] || [scene containsString:@"HSDWY"];
    BOOL isLotteryScene = [scene containsString:@"DRAW"] || [scene containsString:@"LOTTERY"];
    BOOL isRescueScene = [scene containsString:@"RESCUE"];
    BOOL isOceanScene = [scene containsString:@"OCEAN"] || isRescueScene;
    BOOL isAIFishScene = [scene containsString:@"AIFISH"] && !isRescueScene;
    BOOL isOpenGreenScene = isFarmScene || isLotteryScene || isMonopolyScene || isOceanScene || isAIFishScene;
    PSDJsBridge *bridge = nil;
    if (isAIFishScene) {
        bridge = self.aiFishBridge ?: self.oceanBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    } else if (isOceanScene) {
        bridge = (self.oceanBridge && self.oceanBridge != self.jsBridge) ? self.oceanBridge : nil;
    } else if (isFarmScene) {
        bridge = self.farmBridge;
    } else if (isMonopolyScene) {
        bridge = self.monopolyBridge;
    } else if (isLotteryScene) {
        bridge = self.lotteryBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    } else {
        bridge = self.rewardTaskBridge ?: self.jsBridge;
    }
    if (!taskType.length || !bridge) return;
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *url = [self urlForSceneCode:scene bridge:bridge];
    NSString *source = (isRescueScene || isAIFishScene) ? @"ANT_OCEAN" : (isOceanScene ? @"ANT_FOREST" : (isFarmScene ? @"BABA_FARM" : @"ANTFOREST"));
    
    // 寻宝、保护地、神奇海洋、AI摸鱼与芭芭农场专属 OpenGreen 任务网关申请，以及导流/淘宝类任务
    BOOL isDaoliuTask = [taskType.lowercaseString containsString:@"daoliu"] ||
                        [taskType.lowercaseString containsString:@"taobao"] ||
                        [taskType.lowercaseString containsString:@"tb_"] ||
                        [taskType.lowercaseString containsString:@"kuaishou"] ||
                        [taskType.lowercaseString containsString:@"ks_"] ||
                        [taskType.lowercaseString containsString:@"xianyu"] ||
                        [taskType.lowercaseString containsString:@"uc"] ||
                        [title containsString:@"淘宝"] ||
                        [title containsString:@"逛"] ||
                        [title containsString:@"搜"];
    if (isOpenGreenScene || isDaoliuTask) {
        if (isFarmScene) {
            // 芭芭农场全场景任务在服务端不支持 applyTask（调用必报 3000 系统出错），直接跳过申请
            return;
        }
        NSString *argOg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.applyTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"%@\",\"taskType\":\"%@\",\"requestType\":\"RPC\",\"source\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", scene, taskType, source, timeStamp, randNum];
        [self safeFlushBridge:bridge message:argOg url:url];
        return;
    }
    
    // 1. 标准 antiep.applyTask
    NSString *arg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antiep.applyTask\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"%@\",\"taskType\":\"%@\",\"requestType\":\"RPC\",\"source\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", scene, taskType, source, timeStamp, randNum];
    [self safeFlushBridge:bridge message:arg url:url];
    
    // 2. OpenGreen 任务网关同步申请
    if ([scene containsString:@"VITALITY"] || [scene containsString:@"FOREST"]) {
        NSString *argOg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.applyTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"%@\",\"taskType\":\"%@\",\"requestType\":\"RPC\",\"source\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", scene, taskType, source, timeStamp, [AntForestManager getNumberRandom:15]];
        [self safeFlushBridge:bridge message:argOg url:url];
    }
}

-(void)applyVitalityTask:(NSString *)taskType sceneCode:(NSString *)sceneCode {
    [self applyVitalityTask:taskType sceneCode:sceneCode taskTitle:@""];
}

-(void)applyOceanTask:(NSString *)taskType sceneCode:(NSString *)sceneCode taskTitle:(NSString *)title {
    [self applyVitalityTask:taskType sceneCode:sceneCode.length ? sceneCode : @"ANTOCEAN_TASK" taskTitle:title];
}

-(void)exchangeVitalityTaskAsset:(NSString *)taskType sceneCode:(NSString *)sceneCode taskTitle:(NSString *)title caQuotaId:(NSString *)caQuotaId {
    if (!self.rewardTaskBridge && self.jsBridge) {
        self.rewardTaskBridge = self.jsBridge;
    }
    PSDJsBridge *bridge = self.rewardTaskBridge;
    if (!taskType.length || !bridge) return;
    NSString *quota = caQuotaId.length ? caQuotaId : @"ANT_FOREST_VITALITY_TO_LOTTERY";
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *scene = sceneCode.length ? sceneCode : @"ANTFOREST_VITALITY_TASK";
    NSString *url = [self urlForSceneCode:scene bridge:bridge];
    
    NSString *argForest = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.exchangeVitality\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"caQuotaId\":\"%@\",\"exchangeType\":\"LOTTERY_DRAW\",\"exchangeCount\":1,\"source\":\"ANTFOREST\",\"version\":\"20241025\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", quota, timeStamp, [AntForestManager getNumberRandom:15]];
    [bridge _doFlushMessageQueue:argForest url:url];
}

-(void)finishVitalityTask:(NSString *)taskType sceneCode:(NSString *)sceneCode taskTitle:(NSString *)title {
    NSString *scene = sceneCode.length ? sceneCode : @"ANTFOREST_VITALITY_TASK";
    BOOL isManorScene = [scene containsString:@"ANTFARM_FOOD"] || [scene containsString:@"MANOR"];
    BOOL isFarmScene = !isManorScene && ([scene containsString:@"FARM"] || [scene containsString:@"ORCHARD"] || [scene isEqualToString:@"10021"] || [scene isEqualToString:@"3646"] || [scene hasPrefix:@"BABA_"]);
    BOOL isMonopolyScene = [scene containsString:@"MONOPOLY"] || [scene containsString:@"HSDWY"];
    BOOL isLotteryScene = [scene containsString:@"DRAW"] || [scene containsString:@"LOTTERY"];
    BOOL isRescueScene = [scene containsString:@"RESCUE"];
    BOOL isOceanScene = [scene containsString:@"OCEAN"] || isRescueScene;
    BOOL isAIFishScene = [scene containsString:@"AIFISH"] && !isRescueScene;
    BOOL isOpenGreenScene = isLotteryScene || isMonopolyScene || isOceanScene || isAIFishScene;
    PSDJsBridge *bridge = nil;
    if (isManorScene) {
        bridge = (self.manorBridge && self.manorBridge != self.jsBridge) ? self.manorBridge : nil;
    } else if (isAIFishScene) {
        bridge = self.aiFishBridge ?: self.oceanBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    } else if (isOceanScene) {
        bridge = (self.oceanBridge && self.oceanBridge != self.jsBridge) ? self.oceanBridge : nil;
    } else if (isFarmScene) {
        bridge = self.farmBridge;
    } else if (isMonopolyScene) {
        bridge = self.monopolyBridge;
    } else if (isLotteryScene) {
        bridge = self.lotteryBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    } else {
        bridge = self.rewardTaskBridge ?: self.jsBridge;
    }
    if (!taskType.length || !bridge) return;
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *outBizNo = [NSString stringWithFormat:@"%@_%@_%@", taskType, timeStamp, [AntForestManager getNumberRandom:6]];
    NSString *url = [self urlForSceneCode:scene bridge:bridge];
    NSString *source = isManorScene ? @"antfarm" : ((isRescueScene || isAIFishScene) ? @"ANT_OCEAN" : (isOceanScene ? @"ANT_FOREST" : (isFarmScene ? @"BABA_FARM" : @"ANTFOREST")));
    
    // 寻宝、保护地、神奇海洋、AI摸鱼与芭芭农场专属 OpenGreen 任务网关完成，以及淘宝、导流、外链类任务，仅派发 OpenGreen，避免向不支持的旧版 antiep 发送导致 3000 / 400000040 报错
    BOOL isDaoliuTask = [taskType.lowercaseString containsString:@"daoliu"] ||
                        [taskType.lowercaseString containsString:@"taobao"] ||
                        [taskType.lowercaseString containsString:@"tb_"] ||
                        [taskType.lowercaseString containsString:@"kuaishou"] ||
                        [taskType.lowercaseString containsString:@"ks_"] ||
                        [taskType.lowercaseString containsString:@"xianyu"] ||
                        [taskType.lowercaseString containsString:@"uc"] ||
                        [title containsString:@"淘宝"] ||
                        [title containsString:@"逛"] ||
                        [title containsString:@"搜"];
    if (isOpenGreenScene || isDaoliuTask) {
        NSString *argOpenGreen = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.finishTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"%@\",\"taskType\":\"%@\",\"outBizNo\":\"%@_og\",\"requestType\":\"RPC\",\"source\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", scene, taskType, outBizNo, source, timeStamp, randNum];
        [self safeFlushBridge:bridge message:argOpenGreen url:url];
        return;
    }
    
    // 1. 标准 antiep.finishTask
    NSString *argGreen = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antiep.finishTask\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"%@\",\"taskType\":\"%@\",\"outBizNo\":\"%@\",\"requestType\":\"RPC\",\"source\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", scene, taskType, outBizNo, source, timeStamp, randNum];
    [self safeFlushBridge:bridge message:argGreen url:url];
    
    // 2. 农场非主场景（如 10021、BABA_FARM_TASK）同时补充主场景 ANTFARM_ORCHARD_TASK_V2 双向确认
    if (isFarmScene && ![scene isEqualToString:@"ANTFARM_ORCHARD_TASK_V2"] && ![scene isEqualToString:@"ORCHARD_LIMITED_TIME_CHALLENGE"]) {
        NSString *argGreenV2 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antiep.finishTask\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"ANTFARM_ORCHARD_TASK_V2\",\"taskType\":\"%@\",\"outBizNo\":\"%@_v2\",\"requestType\":\"RPC\",\"source\":\"BABA_FARM\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", taskType, outBizNo, timeStamp, [AntForestManager getNumberRandom:15]];
        [self safeFlushBridge:bridge message:argGreenV2 url:url];
    }
    
    // 3. 补充 antieptask.finishTaskopengreen 兼容 OpenGreen 任务网关（全场景支持）
    NSString *argOpenGreen = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.finishTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"%@\",\"taskType\":\"%@\",\"outBizNo\":\"%@_og\",\"requestType\":\"RPC\",\"source\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", scene, taskType, outBizNo, source, timeStamp, [AntForestManager getNumberRandom:15]];
    [self safeFlushBridge:bridge message:argOpenGreen url:url];
}

-(void)receiveVitalityTaskAward:(NSString *)taskType sceneCode:(NSString *)sceneCode taskTitle:(NSString *)title awardName:(NSString *)awardName {
    NSString *scene = sceneCode.length ? sceneCode : @"ANTFOREST_VITALITY_TASK";
    BOOL isManorScene = [scene containsString:@"ANTFARM_FOOD"] || [scene containsString:@"MANOR"];
    BOOL isFarmScene = !isManorScene && ([scene containsString:@"FARM"] || [scene containsString:@"ORCHARD"] || [scene isEqualToString:@"10021"] || [scene isEqualToString:@"3646"] || [scene hasPrefix:@"BABA_"]);
    BOOL isMonopolyScene = [scene containsString:@"MONOPOLY"] || [scene containsString:@"HSDWY"];
    BOOL isLotteryScene = [scene containsString:@"DRAW"] || [scene containsString:@"LOTTERY"];
    BOOL isRescueScene = [scene containsString:@"RESCUE"];
    BOOL isOceanScene = [scene containsString:@"OCEAN"] || isRescueScene;
    BOOL isAIFishScene = [scene containsString:@"AIFISH"] && !isRescueScene;
    BOOL isOpenGreenScene = isLotteryScene || isMonopolyScene || isOceanScene || isAIFishScene;
    PSDJsBridge *bridge = nil;
    if (isManorScene) {
        bridge = (self.manorBridge && self.manorBridge != self.jsBridge) ? self.manorBridge : nil;
    } else if (isAIFishScene) {
        bridge = self.aiFishBridge ?: self.oceanBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    } else if (isOceanScene) {
        bridge = (self.oceanBridge && self.oceanBridge != self.jsBridge) ? self.oceanBridge : nil;
    } else if (isFarmScene) {
        bridge = self.farmBridge;
    } else if (isMonopolyScene) {
        bridge = self.monopolyBridge;
    } else if (isLotteryScene) {
        bridge = self.lotteryBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    } else {
        bridge = self.rewardTaskBridge ?: self.jsBridge;
    }
    if (!taskType.length || !bridge) return;
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *url = [self urlForSceneCode:scene bridge:bridge];
    NSString *source = isManorScene ? @"antfarm" : ((isRescueScene || isAIFishScene) ? @"ANT_OCEAN" : (isOceanScene ? @"ANT_FOREST" : (isFarmScene ? @"BABA_FARM" : @"ANTFOREST")));
    
    NSString *pureTaskType = taskType;
    if ([taskType containsString:@"#"]) {
        NSArray *parts = [taskType componentsSeparatedByString:@"#"];
        if (parts.count > 1 && [parts.lastObject length] > 0) {
            pureTaskType = parts.lastObject;
        }
    }
    
    // 寻宝、保护地、神奇海洋、AI摸鱼与芭芭农场专属 OpenGreen 任务网关领奖，以及淘宝、导流、外链类任务（仅派发 OpenGreen，避免向不支持的旧版 antiep 发送导致 400000040 报错）
    BOOL isDaoliuTask = [taskType.lowercaseString containsString:@"daoliu"] ||
                        [taskType.lowercaseString containsString:@"taobao"] ||
                        [taskType.lowercaseString containsString:@"tb_"] ||
                        [taskType.lowercaseString containsString:@"kuaishou"] ||
                        [taskType.lowercaseString containsString:@"ks_"] ||
                        [taskType.lowercaseString containsString:@"xianyu"] ||
                        [taskType.lowercaseString containsString:@"uc"] ||
                        [title containsString:@"淘宝"] ||
                        [title containsString:@"逛"] ||
                        [title containsString:@"搜"];
    if (isOpenGreenScene || isDaoliuTask) {
        NSString *argOpenGreen = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.receiveTaskAwardopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"%@\",\"taskType\":\"%@\",\"ignoreLimit\":false,\"requestType\":\"RPC\",\"source\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", scene, taskType, source, timeStamp, randNum];
        [self safeFlushBridge:bridge message:argOpenGreen url:url];
        if (![pureTaskType isEqualToString:taskType]) {
            NSString *argOpenPure = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.receiveTaskAwardopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"%@\",\"taskType\":\"%@\",\"ignoreLimit\":false,\"requestType\":\"RPC\",\"source\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", scene, pureTaskType, source, timeStamp, [AntForestManager getNumberRandom:15]];
            [self safeFlushBridge:bridge message:argOpenPure url:url];
        }
        return;
    }
    
    // 1. 标准 antiep.receiveTaskAward
    NSString *argGreen = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antiep.receiveTaskAward\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"%@\",\"taskType\":\"%@\",\"ignoreLimit\":false,\"requestType\":\"RPC\",\"source\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", scene, taskType, source, timeStamp, randNum];
    [bridge _doFlushMessageQueue:argGreen url:url];
    if (![pureTaskType isEqualToString:taskType]) {
        NSString *argPure = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antiep.receiveTaskAward\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"%@\",\"taskType\":\"%@\",\"ignoreLimit\":false,\"requestType\":\"RPC\",\"source\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", scene, pureTaskType, source, timeStamp, [AntForestManager getNumberRandom:15]];
        [bridge _doFlushMessageQueue:argPure url:url];
    }
    
    // 2. 农场非主场景同时发送主场景领奖确认
    if (isFarmScene && ![scene isEqualToString:@"ANTFARM_ORCHARD_TASK_V2"]) {
        NSString *argGreenV2 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antiep.receiveTaskAward\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"ANTFARM_ORCHARD_TASK_V2\",\"taskType\":\"%@\",\"ignoreLimit\":false,\"requestType\":\"RPC\",\"source\":\"BABA_FARM\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", taskType, timeStamp, [AntForestManager getNumberRandom:15]];
        [bridge _doFlushMessageQueue:argGreenV2 url:url];
    }
    
    // 3. 补充 antieptask.receiveTaskAwardopengreen（全场景支持）
    NSString *argOpenGreen = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.receiveTaskAwardopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"%@\",\"taskType\":\"%@\",\"ignoreLimit\":false,\"requestType\":\"RPC\",\"source\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", scene, taskType, source, timeStamp, [AntForestManager getNumberRandom:15]];
    [bridge _doFlushMessageQueue:argOpenGreen url:url];
    if (![pureTaskType isEqualToString:taskType]) {
        NSString *argOpenPure = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.receiveTaskAwardopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"%@\",\"taskType\":\"%@\",\"ignoreLimit\":false,\"requestType\":\"RPC\",\"source\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", scene, pureTaskType, source, timeStamp, [AntForestManager getNumberRandom:15]];
        [bridge _doFlushMessageQueue:argOpenPure url:url];
    }
}

-(void)receiveOceanTaskAward:(NSString *)taskType sceneCode:(NSString *)sceneCode taskTitle:(NSString *)title awardName:(NSString *)awardName {
    [self receiveVitalityTaskAward:taskType sceneCode:sceneCode.length ? sceneCode : @"ANTOCEAN_TASK" taskTitle:title awardName:awardName];
}

-(void)claimVitalityStageAwardsIfNeeded {
    // 阶段累计奖励已在 handleVitalityTaskListResponse 中由服务端数据驱动精准加入队列并领取
    // 彻底停用无差别全量盲发 34 笔 RPC，杜绝网关堵塞、系统出错（3000）与 remoteLog（999）超限
}

- (void)notifyActiveH5PageToRefresh {
    dispatch_async(dispatch_get_main_queue(), ^{
        static NSTimeInterval lastRefreshTime = 0;
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - lastRefreshTime < 3.0) return; // 频率限制，避免狂刷
        lastRefreshTime = now;
        
        NSMutableSet *targets = [NSMutableSet set];
        // 关键保护：绝不向森林首页 bridge (self.jsBridge) 乱发刷新事件，避免导致首页排行榜或PK榜重新渲染/重置死锁！
        for (PSDJsBridge *b in @[self.farmBridge ?: (id)[NSNull null], self.oceanBridge ?: (id)[NSNull null], self.aiFishBridge ?: (id)[NSNull null], self.rewardTaskBridge ?: (id)[NSNull null], self.lotteryBridge ?: (id)[NSNull null], self.monopolyBridge ?: (id)[NSNull null]]) {
            if (b != (id)[NSNull null] && b != self.jsBridge && [b respondsToSelector:@selector(contentView)]) {
                id cv = [b contentView];
                if (cv) [targets addObject:cv];
                if ([cv respondsToSelector:@selector(webView)]) {
                    id wv = ((id (*)(id, SEL))objc_msgSend)(cv, @selector(webView));
                    if (wv) [targets addObject:wv];
                }
            }
        }
        if (!targets.count) return;
        
        // 关键修复：坚决移除 'pullRefresh'！严禁模拟下拉刷新重置页面视图与 Tab 选中状态！
        // 仅派发轻量级 pageResume / resume 事件通知任务抽屉列表更新
        NSString *js = @"(()=>{try{const evs=['pageResume','resume'];evs.forEach(t=>{try{document.dispatchEvent(new CustomEvent(t,{bubbles:true,cancelable:true,data:{}}));}catch(_){try{const e=document.createEvent('HTMLEvents');e.initEvent(t,true,true);document.dispatchEvent(e);}catch(__){}}try{window.dispatchEvent(new Event(t));}catch(_){}});}catch(_){}try{if(window.AlipayJSBridge){if(window.AlipayJSBridge.fireEvent){try{window.AlipayJSBridge.fireEvent('pageResume');}catch(_){}try{window.AlipayJSBridge.fireEvent('resume');}catch(_){}}if(window.AlipayJSBridge.call){try{window.AlipayJSBridge.call('pageResume');}catch(_){}}}}catch(_){}})();";
        SEL evalSel = @selector(evaluateJavaScript:completionHandler:);
        
        SEL resumeSel = NSSelectorFromString(@"contentViewDidResume");
        for (id target in targets) {
            if ([target respondsToSelector:resumeSel]) {
                @try { ((void (*)(id, SEL))objc_msgSend)(target, resumeSel); } @catch (NSException *e) {}
            }
            if ([target respondsToSelector:evalSel]) {
                @try {
                    ((void (*)(id, SEL, NSString *, void (^)(id, NSError *)))objc_msgSend)(target, evalSel, js, nil);
                } @catch (NSException *e) {}
            }
        }
    });
}

static BOOL sHasPerformedWorkInCurrentVitalityRound = NO;
static NSInteger sVitalityAutoRefreshRounds = 0;

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    NSString *scheme = url.scheme.lowercaseString;
    if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
        decisionHandler(WKNavigationActionPolicyAllow);
    } else {
        // 阻止拉起外部 App，保持前台稳定
        decisionHandler(WKNavigationActionPolicyCancel);
    }
}

static WKWebView *sSilentTaskWebView = nil;

static void silentlyPrefetchTaskUrl(NSString *jumpUrl) {
    if (!jumpUrl.length) return;
    NSString *cleanUrl = jumpUrl;
    if ([jumpUrl containsString:@"url="]) {
        NSRange r = [jumpUrl rangeOfString:@"url="];
        NSString *sub = [jumpUrl substringFromIndex:r.location + 4];
        NSRange amp = [sub rangeOfString:@"&"];
        if (amp.location != NSNotFound) {
            NSString *candidate = [sub substringToIndex:amp.location];
            NSString *dec = [candidate stringByRemovingPercentEncoding] ?: candidate;
            if ([dec hasPrefix:@"http://"] || [dec hasPrefix:@"https://"]) {
                cleanUrl = dec;
            } else {
                cleanUrl = [sub stringByRemovingPercentEncoding] ?: sub;
            }
        } else {
            cleanUrl = [sub stringByRemovingPercentEncoding] ?: sub;
        }
    }
    if ([cleanUrl hasPrefix:@"http://"] || [cleanUrl hasPrefix:@"https://"]) {
        NSURL *reqUrl = [NSURL URLWithString:cleanUrl];
        if (reqUrl) {
            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:reqUrl cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8.0];
            NSString *ua = @"Mozilla/5.0 (iPhone; CPU iPhone OS 16_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Nebula AlipayDefined(nt:WIFI,ws:393|759,fx:393|852) AliApp(AP/12.12.16.6000) AlipayClient/12.12.16.6000 Language/zh-Hans";
            [req setValue:ua forHTTPHeaderField:@"User-Agent"];
            [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(__unused NSData *d, __unused NSURLResponse *res, __unused NSError *err){}] resume];
            
            // 针对淘宝/导流等需执行前端鉴权的外链，在离屏纯静默微型 WebView 中加载（严禁 pushWindow 弹窗以防唤起外部 App 与绿屏卡死）
            BOOL isTaobaoOrDaoliu = [cleanUrl containsString:@"taobao.com"] || [cleanUrl containsString:@"starlink"] || [cleanUrl containsString:@"tmall.com"] || [cleanUrl containsString:@"goofish.com"] || [cleanUrl containsString:@"qiandao"] || [jumpUrl containsString:@"taobao"] || [jumpUrl containsString:@"starlink"];
            if (isTaobaoOrDaoliu) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    @try {
                        if (!sSilentTaskWebView) {
                            WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
                            config.applicationNameForUserAgent = @"Nebula AlipayDefined(nt:WIFI,ws:393|759,fx:393|852) AliApp(AP/12.12.16.6000) AlipayClient/12.12.16.6000 Language/zh-Hans";
                            sSilentTaskWebView = [[WKWebView alloc] initWithFrame:CGRectMake(0, 0, 1, 1) configuration:config];
                            sSilentTaskWebView.customUserAgent = ua;
                            sSilentTaskWebView.alpha = 0.01;
                            sSilentTaskWebView.hidden = YES;
                            sSilentTaskWebView.navigationDelegate = [AntForestManager sharedInstance];
                        }
                        [sSilentTaskWebView loadRequest:req];
                    } @catch (NSException *e) {}
                });
            }
        }
    }
}

- (void)executeNextVitalityTask {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!isWithinTaskActiveHours()) {
                // 凌晨 00:00 ~ 07:00 期间：仅允许执行每日签到（action == sign），常规做任务坚决挂起等待早7点
                NSDictionary *headItem = nil;
                @synchronized(self) {
                    headItem = vitalityTaskQueue.firstObject;
                }
                if (!headItem || ![headItem[@"action"] isEqualToString:@"sign"]) {
                    @synchronized(self) {
                        [vitalityTaskQueue removeAllObjects];
                        vitalityTaskRunning = NO;
                        gCurrentExecutingTaskKey = nil;
                        gCurrentExecutingTaskIsMultiStage = NO;
                    }
                    return;
                }
            }
            if (!self.rewardTaskBridge && self.jsBridge) {
                self.rewardTaskBridge = self.jsBridge;
            }
            BOOL anyTaskEnabled = self.enableAutoRewardTasks || self.enableAutoOceanTasks || self.enableAutoAIFish || self.enableAutoFarmTasks || self.enableAutoPatrolNew;
            PSDJsBridge *anyBridge = self.rewardTaskBridge ?: self.oceanBridge ?: self.aiFishBridge ?: self.farmBridge ?: self.monopolyBridge ?: self.jsBridge;
            if (!anyTaskEnabled || !anyBridge) {
                @synchronized(self) {
                    vitalityTaskRunning = NO;
                    gCurrentExecutingTaskKey = nil;
                    gCurrentExecutingTaskIsMultiStage = NO;
                }
                return;
            }
            
            static NSMutableSet<NSString *> *sExecutedScenesInCurrentRound = nil;
            static NSString *sLastExecutedSceneCode = nil;
            NSDictionary *item = nil;
            @synchronized(self) {
                if (!vitalityTaskQueue.count) {
                    vitalityTaskRunning = NO;
                    gCurrentExecutingTaskKey = nil;
                    gCurrentExecutingTaskIsMultiStage = NO;
                    NSSet<NSString *> *executedScenes = [sExecutedScenesInCurrentRound copy];
                    [sExecutedScenesInCurrentRound removeAllObjects];
                    
                    if (sHasPerformedWorkInCurrentVitalityRound && sVitalityAutoRefreshRounds < 2) {
                        sHasPerformedWorkInCurrentVitalityRound = NO;
                        sVitalityAutoRefreshRounds++;
                        
                        if ([executedScenes containsObject:@"FARM"]) {
                            [self recordStage:@"芭芭农场：本批次任务已执行完毕，2.5秒后刷新拉取农场任务最新进度..."];
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                [self queryFarmTaskListWithForce:YES];
                                [self notifyActiveH5PageToRefresh];
                            });
                        }
                        if ([executedScenes containsObject:@"MONOPOLY"]) {
                            [self recordStage:@"新版保护地：本批次任务已执行完毕，2.5秒后刷新保护地任务列表..."];
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                [self queryMonopolyTaskListWithForce:YES];
                                [self notifyActiveH5PageToRefresh];
                            });
                        }
                        if ([executedScenes containsObject:@"OCEAN"] || [sLastExecutedSceneCode containsString:@"OCEAN"]) {
                            [self recordStage:@"神奇海洋：本批次任务已执行完毕，2.5秒后刷新拉取海洋任务最新进度..."];
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                [self queryOceanTaskListWithForce:YES];
                                [self notifyActiveH5PageToRefresh];
                            });
                        }
                        if ([executedScenes containsObject:@"AIFISH"]) {
                            [self recordStage:@"AI摸鱼：本批次任务已执行完毕，2.5秒后刷新拉取摸鱼任务最新进度..."];
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                [self queryAIFishTaskListWithForce:YES];
                                [self notifyActiveH5PageToRefresh];
                            });
                        }
                        if ([executedScenes containsObject:@"DRAW"]) {
                            [self recordStage:@"森林寻宝：本批次任务已执行完毕，2.5秒后自动刷新寻宝与大奖..."];
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                [self queryLotteryTaskListWithForce:YES];
                                [self notifyActiveH5PageToRefresh];
                            });
                        }
                        if ([executedScenes containsObject:@"VITALITY"] || !executedScenes.count) {
                            if (self.enableAutoRewardTasks) {
                                if (isWithinTaskActiveHours()) {
                                    [self claimVitalityStageAwardsIfNeeded];
                                    [self recordStage:@"领奖励：本批次任务已执行完毕，2.5秒后自动刷新拉取新解锁任务与阶梯大奖..."];
                                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                        [self queryVitalityTaskListWithForce:YES];
                                        [self claimAllVisibleRewardTaskRewardsOnWebView];
                                        [self notifyActiveH5PageToRefresh];
                                    });
                                } else {
                                    [self recordStage:[NSString stringWithFormat:@"领奖励：今日能量签到已完成，常规做任务已挂起等待 %@ 后执行", getTaskActiveStartTimeString()]];
                                }
                            }
                        }
                    } else {
                        BOOL didWork = sHasPerformedWorkInCurrentVitalityRound;
                        sHasPerformedWorkInCurrentVitalityRound = NO;
                        // 严禁在此立即清零 sVitalityAutoRefreshRounds！保持上限状态，交由 autoCollectBubbles 新一轮扫描重置，彻底杜绝同周期自旋死循环
                        sVitalityAutoRefreshRounds = 2;
                        if (didWork) {
                            if ([executedScenes containsObject:@"FARM"]) {
                                [self recordStage:@"芭芭农场：当前所有任务奖励已全部领取完毕"];
                            }
                            if ([executedScenes containsObject:@"OCEAN"]) {
                                [self recordStage:@"神奇海洋：当前所有有效海洋任务与拼图已全部领取完毕"];
                            }
                            if ([executedScenes containsObject:@"AIFISH"]) {
                                [self recordStage:@"AI摸鱼：当前所有任务奖励已全部领取完毕"];
                            }
                            if ([executedScenes containsObject:@"MONOPOLY"]) {
                                [self recordStage:@"新版保护地：当前所有任务奖励已全部领取完毕"];
                            }
                            if ([executedScenes containsObject:@"DRAW"]) {
                                [self recordStage:@"森林寻宝：当前所有任务奖励已全部领取完毕"];
                            }
                            if ([executedScenes containsObject:@"VITALITY"] || !executedScenes.count) {
                                if (self.enableAutoRewardTasks) {
                                    if (isWithinTaskActiveHours()) {
                                        [self claimVitalityStageAwardsIfNeeded];
                                        [self recordStage:@"领奖励：本轮常规任务与阶梯大奖已全部调度执行完毕"];
                                    } else {
                                        [self recordStage:[NSString stringWithFormat:@"领奖励：今日能量签到已完成，常规做任务已挂起等待 %@ 后执行", getTaskActiveStartTimeString()]];
                                    }
                                }
                            }
                        }
                        [self notifyActiveH5PageToRefresh];
                    }
                    return;
                }
                vitalityTaskRunning = YES;
                item = [vitalityTaskQueue firstObject];
                if (item) {
                    [vitalityTaskQueue removeObjectAtIndex:0];
                }
            }
            
            if (![item isKindOfClass:NSDictionary.class]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                    [self executeNextVitalityTask];
                });
                return;
            }
            
            PSDJsBridge *bridge = self.rewardTaskBridge;
            NSString *sceneCode = [item[@"sceneCode"] isKindOfClass:NSString.class] ? [item[@"sceneCode"] copy] : @"ANTFOREST_VITALITY_TASK";
            NSString *itemPrefix = [item[@"scenePrefix"] isKindOfClass:NSString.class] ? [item[@"scenePrefix"] copy] : nil;
            BOOL isFarmScene = [itemPrefix isEqualToString:@"芭芭农场"] || [sceneCode containsString:@"FARM"] || [sceneCode containsString:@"ORCHARD"] || [sceneCode isEqualToString:@"10021"] || [sceneCode isEqualToString:@"3646"] || [sceneCode hasPrefix:@"BABA_"];
            BOOL isMonopolyScene = [sceneCode containsString:@"MONOPOLY"] || [sceneCode containsString:@"HSDWY"];
            BOOL isLotteryScene = [sceneCode containsString:@"NORMAL_DRAW"] || [sceneCode containsString:@"ACTIVITY_DRAW"] || [sceneCode containsString:@"DRAW"] || [sceneCode containsString:@"LOTTERY"];
            BOOL isOceanScene = [itemPrefix isEqualToString:@"神奇海洋"] || [sceneCode containsString:@"RESCUE"] || [sceneCode containsString:@"OCEAN"];
            if (isOceanScene) {
                bridge = (self.oceanBridge && self.oceanBridge != self.jsBridge) ? self.oceanBridge : nil;
            } else if ([sceneCode containsString:@"AIFISH"]) {
                bridge = self.aiFishBridge ?: self.oceanBridge ?: self.rewardTaskBridge ?: self.jsBridge;
            } else if (isFarmScene) {
                bridge = self.farmBridge ?: self.rewardTaskBridge ?: self.jsBridge;
            } else if (isMonopolyScene) {
                bridge = self.monopolyBridge;
            } else if (isLotteryScene) {
                bridge = self.lotteryBridge ?: self.rewardTaskBridge ?: self.jsBridge;
            } else if (!bridge) {
                bridge = self.jsBridge;
            }
            if (!bridge) {
                NSString *modTag = isMonopolyScene ? @"新版保护地" : (isLotteryScene ? @"森林寻宝" : (isOceanScene ? @"神奇海洋" : (isFarmScene ? @"芭芭农场" : ([sceneCode containsString:@"AIFISH"] ? @"AI摸鱼" : @"领奖励"))));
                [self recordStage:[NSString stringWithFormat:@"%@：当前未处于对应界面，跳过本任务调度", modTag]];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self executeNextVitalityTask];
                });
                return;
            }
            
            NSString *action = [item[@"action"] isKindOfClass:NSString.class] ? [item[@"action"] copy] : @"";
            NSString *title = [item[@"title"] isKindOfClass:NSString.class] ? [item[@"title"] copy] : @"任务";
            NSString *awardName = [item[@"awardName"] isKindOfClass:NSString.class] ? [item[@"awardName"] copy] : @"奖励";
            NSString *taskType = [item[@"taskType"] isKindOfClass:NSString.class] ? [item[@"taskType"] copy] : @"";
            NSString *sceneTag = isFarmScene ? @"FARM" :
                                (isMonopolyScene ? @"MONOPOLY" :
                                (isOceanScene ? @"OCEAN" :
                                ([sceneCode containsString:@"AIFISH"] ? @"AIFISH" :
                                (isLotteryScene ? @"DRAW" : @"VITALITY"))));
            sLastExecutedSceneCode = isFarmScene ? @"ANTFARM_ORCHARD_TASK_V2" : [sceneCode copy];
            @synchronized(self) {
                if (!sExecutedScenesInCurrentRound) {
                    sExecutedScenesInCurrentRound = [NSMutableSet set];
                }
                [sExecutedScenesInCurrentRound addObject:sceneTag];
            }
            BOOL isAcc = [item[@"isAcc"] respondsToSelector:@selector(boolValue)] ? [item[@"isAcc"] boolValue] : NO;
            
            NSString *taskKey = taskType.length ? [NSString stringWithFormat:@"%@:%@", sceneCode, taskType] : nil;
            gCurrentExecutingTaskKey = taskKey;
            BOOL isMultiIncomplete = isMultiStageIncompleteTask(title, 0, 0) || [item[@"isMultiStage"] boolValue];
            gCurrentExecutingTaskIsMultiStage = isMultiIncomplete;
            
            if (taskKey.length) {
                BOOL isDone = NO;
                @synchronized(self) {
                    if (!isMultiIncomplete) {
                        if (![action isEqualToString:@"receive"] && [gDailyFailedTasks containsObject:taskKey]) {
                            isDone = YES;
                        } else if (![action isEqualToString:@"receive"] && [gDailyCompletedTasks containsObject:taskKey] && !isFarmScene) {
                            // 农场任务在服务端确认已领取前不以本地缓存阻断
                            isDone = YES;
                        }
                    }
                }
                if (isDone) {
                    // 今日已完成或已确认不可做，异步出队处理下一个，彻底杜绝同步栈深递归与主线程假死
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self executeNextVitalityTask];
                    });
                    return;
                }
            }
            
            // 签到绝对前置锁：未完成签到前，挂起常规领奖励任务，杜绝未签到先做任务导致今日累计阶梯奖励被吞
            if (self.enableAutoRewardTasks && ![action isEqualToString:@"sign"] && ([sceneCode isEqualToString:@"ANTFOREST_VITALITY_TASK"] || [itemPrefix isEqualToString:@"领奖励"])) {
                BOOL isSigned = NO;
                @synchronized(self) {
                    isSigned = [gDailyCompletedTasks containsObject:@"SIGN_TODAY"];
                }
                if (!isSigned) {
                    static NSUInteger sSignWaitAttempts = 0;
                    if (sSignWaitAttempts < 10) {
                        sSignWaitAttempts++;
                        @synchronized(self) {
                            [vitalityTaskQueue insertObject:item atIndex:0];
                            vitalityTaskRunning = NO;
                        }
                        static NSTimeInterval sLastSignPromptTime = 0;
                        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                        if (now - sLastSignPromptTime > 5.0) {
                            sLastSignPromptTime = now;
                            [self recordStage:@"领奖励：签到尚未完成，常规任务暂挂起等待签到就绪（保护阶梯奖励）..."];
                            [self signVitalityTask:@"" sceneCode:@"ANTFOREST_ENERGY_TASK_SIGN"];
                            [self queryVitalityTaskListWithForce:YES];
                        }
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            @synchronized(self) {
                                if (!vitalityTaskRunning && vitalityTaskQueue.count > 0) {
                                    [self executeNextVitalityTask];
                                }
                            }
                        });
                        return;
                    }
                    // 超过重试上限仍未完成签到：严禁穿透强行执行常规任务！
                    sSignWaitAttempts = 0;
                    [self recordStage:@"领奖励：签到尚未就绪，为防止消耗任务次数导致阶梯奖励被吞，已清空待执行任务队列，等待签到完成后自动重拉..."];
                    @synchronized(self) {
                        [vitalityTaskQueue removeAllObjects];
                        vitalityTaskRunning = NO;
                    }
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [self signVitalityTask:@"" sceneCode:@"ANTFOREST_ENERGY_TASK_SIGN"];
                        [self queryVitalityTaskListWithForce:YES];
                    });
                    return;
                }
            }
            
            NSString *scenePrefix = itemPrefix ?: @"领奖励";
            if ([sceneCode containsString:@"RESCUE"] || [sceneCode containsString:@"OCEAN"]) {
                scenePrefix = @"神奇海洋";
            } else if ([sceneCode containsString:@"AIFISH"]) {
                scenePrefix = @"AI摸鱼";
            } else if (isFarmScene) {
                scenePrefix = @"芭芭农场";
            } else if ([sceneCode containsString:@"MONOPOLY"]) {
                scenePrefix = @"新版保护地";
            } else if ([sceneCode containsString:@"NORMAL_DRAW"] || [sceneCode containsString:@"ACTIVITY_DRAW"] || [sceneCode containsString:@"DRAW"]) {
                scenePrefix = @"森林寻宝";
            } else if (isAcc || [taskType hasPrefix:@"acc_task_energy_"]) {
                scenePrefix = @"阶梯大奖";
            }
            
            sHasPerformedWorkInCurrentVitalityRound = YES;
            
            if ([action isEqualToString:@"sign"]) {
                NSString *signId = [item[@"signId"] isKindOfClass:NSString.class] ? [item[@"signId"] copy] : @"";
                NSString *signScene = [item[@"sceneCode"] isKindOfClass:NSString.class] ? [item[@"sceneCode"] copy] : @"ANTFOREST_ENERGY_TASK_SIGN";
                if (!signId.length) {
                    [self recordStage:[NSString stringWithFormat:@"%@：正在获取签到实体并执行每日签到...", scenePrefix]];
                    [self signVitalityTask:@"" sceneCode:signScene];
                    [self queryVitalityTaskListWithForce:YES];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [self executeNextVitalityTask];
                    });
                    return;
                }
                [self recordStage:[NSString stringWithFormat:@"%@：正在完成每日签到...", scenePrefix]];
                [self signVitalityTask:signId sceneCode:signScene];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self executeNextVitalityTask];
                });
                return;
            } else if ([action isEqualToString:@"exchange"]) {
                NSString *caQuotaId = [item[@"caQuotaId"] isKindOfClass:NSString.class] ? [item[@"caQuotaId"] copy] : @"";
                [self recordStage:[NSString stringWithFormat:@"%@：正在兑换“%@”...", scenePrefix, title]];
                if (taskKey.length) {
                    @synchronized(self) {
                        if (!gVitalityTaskRetryCounts) gVitalityTaskRetryCounts = [NSMutableDictionary dictionary];
                        NSInteger curr = [gVitalityTaskRetryCounts[taskKey] integerValue];
                        gVitalityTaskRetryCounts[taskKey] = @(curr + 1);
                    }
                }
                [self exchangeVitalityTaskAsset:taskType sceneCode:sceneCode taskTitle:title caQuotaId:caQuotaId];
            } else if ([action isEqualToString:@"browse"]) {
                NSString *jumpUrl = [item[@"jumpUrl"] isKindOfClass:NSString.class] ? [item[@"jumpUrl"] copy] : @"";
                NSInteger seconds = [item[@"browseSeconds"] respondsToSelector:@selector(integerValue)] ? [item[@"browseSeconds"] integerValue] : 15;
                if (seconds <= 0) seconds = 15;
                [self recordStage:[NSString stringWithFormat:@"%@：正在后台自动执行“%@”（type=%@, 保持运行 %ld 秒）...", scenePrefix, title, taskType, (long)seconds]];
                
                if (taskKey.length) {
                    @synchronized(self) {
                        if (isFarmScene) {
                            if (!gFarmTaskRetryCounts) gFarmTaskRetryCounts = [NSMutableDictionary dictionary];
                            NSInteger stage = [item[@"stageIndex"] respondsToSelector:@selector(integerValue)] ? [item[@"stageIndex"] integerValue] : 0;
                            NSString *retryKey = isMultiIncomplete ? [NSString stringWithFormat:@"%@:stage_%ld", taskKey, (long)stage] : taskKey;
                            NSInteger curr = [gFarmTaskRetryCounts[retryKey] integerValue];
                            gFarmTaskRetryCounts[retryKey] = @(curr + 1);
                        } else {
                            if (!gVitalityTaskRetryCounts) gVitalityTaskRetryCounts = [NSMutableDictionary dictionary];
                            NSInteger curr = [gVitalityTaskRetryCounts[taskKey] integerValue];
                            gVitalityTaskRetryCounts[taskKey] = @(curr + 1);
                        }
                    }
                }
                
                // 1. 优先调用 applyTask 注册“去完成”激活状态（仅限非农场场景，农场场景不支持该 RPC）
                if (!isFarmScene) {
                    [self applyVitalityTask:taskType sceneCode:sceneCode taskTitle:title];
                }
                
                // 2. 如果有 jumpUrl，进行后台真实预取以满足服务端激活校验
                silentlyPrefetchTaskUrl(jumpUrl);
                
                NSString *capturedTaskType = [taskType copy];
                NSString *capturedSceneCode = [sceneCode copy];
                NSString *capturedTitle = [title copy];
                NSString *capturedAwardName = [awardName copy];
                NSString *capturedScenePrefix = [scenePrefix copy];
                BOOL isMulti = [item[@"isMultiStage"] boolValue];
                
                // 停留指定时长后完成任务，并等待 finishTask 写入后再提交领奖
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((seconds + 1.0) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    @try {
                        [self finishVitalityTask:capturedTaskType sceneCode:capturedSceneCode taskTitle:capturedTitle];
                    } @catch (NSException *e) {}
                    
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        // 浏览/导流类任务已后台预取 jumpUrl 并完成倒计时停留，始终提交 receiveVitalityTaskAward 尝试领奖，绝不被单个旧版 finishTask RPC 的 400000040 阻断
                        @try {
                            [self receiveVitalityTaskAward:capturedTaskType sceneCode:capturedSceneCode taskTitle:capturedTitle awardName:capturedAwardName];
                            [self recordStage:[NSString stringWithFormat:@"%@：浏览“%@”完成，正在提交领奖...", capturedScenePrefix, capturedTitle]];
                        } @catch (NSException *e) {}
                        
                        double delayAfter = 1.2 + (arc4random_uniform(500) / 1000.0);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayAfter * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            if (isMulti && taskKey.length) {
                                @synchronized(self) {
                                    [gDailyCompletedTasks removeObject:taskKey];
                                    [gDailyFailedTasks removeObject:taskKey];
                                    saveDailyTaskCache();
                                }
                            }
                            [self executeNextVitalityTask];
                        });
                    });
                });
                return;
            } else if ([action isEqualToString:@"finish"]) {
                [self recordStage:[NSString stringWithFormat:@"%@：正在完成“%@”...", scenePrefix, title]];
                if (taskKey.length) {
                    @synchronized(self) {
                        if (isFarmScene) {
                            if (!gFarmTaskRetryCounts) gFarmTaskRetryCounts = [NSMutableDictionary dictionary];
                            NSInteger stage = [item[@"stageIndex"] respondsToSelector:@selector(integerValue)] ? [item[@"stageIndex"] integerValue] : 0;
                            NSString *retryKey = isMultiIncomplete ? [NSString stringWithFormat:@"%@:stage_%ld", taskKey, (long)stage] : taskKey;
                            NSInteger curr = [gFarmTaskRetryCounts[retryKey] integerValue];
                            gFarmTaskRetryCounts[retryKey] = @(curr + 1);
                        } else {
                            if (!gVitalityTaskRetryCounts) gVitalityTaskRetryCounts = [NSMutableDictionary dictionary];
                            NSInteger curr = [gVitalityTaskRetryCounts[taskKey] integerValue];
                            gVitalityTaskRetryCounts[taskKey] = @(curr + 1);
                        }
                    }
                }
                NSString *targetJumpUrl = [item[@"jumpUrl"] isKindOfClass:NSString.class] ? item[@"jumpUrl"] : nil;
                if (targetJumpUrl.length) {
                    silentlyPrefetchTaskUrl(targetJumpUrl);
                }
                if (!isFarmScene) {
                    [self applyVitalityTask:taskType sceneCode:sceneCode taskTitle:title];
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self finishVitalityTask:taskType sceneCode:sceneCode taskTitle:title];
                });
            } else if ([action isEqualToString:@"receive"]) {
                if (taskKey.length) {
                    @synchronized(self) {
                        if (!gVitalityTaskRetryCounts) gVitalityTaskRetryCounts = [NSMutableDictionary dictionary];
                        NSInteger curr = [gVitalityTaskRetryCounts[taskKey] integerValue];
                        gVitalityTaskRetryCounts[taskKey] = @(curr + 1);
                    }
                }
                [self recordStage:[NSString stringWithFormat:@"%@：正在提交领取“%@”（%@）...", scenePrefix, title, awardName]];
                [self receiveVitalityTaskAward:taskType sceneCode:sceneCode taskTitle:title awardName:awardName];
            }
            
            double delaySec = 1.0 + (arc4random_uniform(800) / 1000.0);
            if ([action isEqualToString:@"finish"]) {
                delaySec = 2.5 + (arc4random_uniform(500) / 1000.0);
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (isMultiIncomplete && taskKey.length) {
                    @synchronized(self) {
                        [gDailyCompletedTasks removeObject:taskKey];
                        [gDailyFailedTasks removeObject:taskKey];
                        saveDailyTaskCache();
                    }
                }
                [self executeNextVitalityTask];
            });
        } @catch (NSException *e) {
            NSLog(@"[AntForestPort][VitalityTask] Exception in executeNextVitalityTask: %@", e);
            @synchronized(self) { vitalityTaskRunning = NO; }
        }
    });
}

static BOOL isMultiStageIncompleteTask(NSString *title, NSInteger progress, NSInteger require) {
    if (require > 1 && progress < require) return YES;
    if (!title.length) return NO;
    static NSRegularExpression *stageRegex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        stageRegex = [NSRegularExpression regularExpressionWithPattern:@"(?:\\(|（)?(\\d+)\\s*/\\s*(\\d+)(?:\\)|）)?" options:0 error:nil];
    });
    NSTextCheckingResult *match = [stageRegex firstMatchInString:title options:0 range:NSMakeRange(0, title.length)];
    if (match && match.numberOfRanges > 2) {
        NSInteger cur = [[title substringWithRange:[match rangeAtIndex:1]] integerValue];
        NSInteger total = [[title substringWithRange:[match rangeAtIndex:2]] integerValue];
        if (total > 1 && cur < total) {
            return YES;
        }
    }
    return NO;
}

static BOOL isMultiStageTaskFromDict(NSDictionary *taskDict, NSDictionary *baseInfo, NSDictionary *bizInfo) {
    if (![taskDict isKindOfClass:NSDictionary.class] && ![baseInfo isKindOfClass:NSDictionary.class]) return NO;
    
    // 1. 结构化 rightsTimesLimit 与已领/已完成次数判断
    NSDictionary *rights = [taskDict[@"taskRights"] isKindOfClass:NSDictionary.class] ? taskDict[@"taskRights"] : ([baseInfo[@"taskRights"] isKindOfClass:NSDictionary.class] ? baseInfo[@"taskRights"] : nil);
    NSInteger limit = [rights[@"rightsTimesLimit"] integerValue];
    NSInteger received = [rights[@"alreadyReceiveAwardCount"] integerValue];
    NSInteger rightsTimes = [rights[@"rightsTimes"] integerValue];
    if (limit <= 0) limit = [taskDict[@"rightsTimesLimit"] integerValue];
    if (limit <= 0) limit = [baseInfo[@"rightsTimesLimit"] integerValue];
    if (received <= 0) received = [taskDict[@"alreadyReceiveAwardCount"] integerValue];
    if (received <= 0) received = [baseInfo[@"alreadyReceiveAwardCount"] integerValue];
    if (rightsTimes <= 0) rightsTimes = [taskDict[@"rightsTimes"] integerValue];
    if (rightsTimes <= 0) rightsTimes = [baseInfo[@"rightsTimes"] integerValue];
    
    // 从 extend 解析 alreadyReceiveAwardCount
    if (received <= 0) {
        id extendVal = taskDict[@"extend"] ?: baseInfo[@"extend"];
        NSDictionary *extendDict = nil;
        if ([extendVal isKindOfClass:NSDictionary.class]) {
            extendDict = extendVal;
        } else if ([extendVal isKindOfClass:NSString.class]) {
            extendDict = [NSJSONSerialization JSONObjectWithData:[extendVal dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        }
        if (extendDict[@"alreadyReceiveAwardCount"]) {
            received = [extendDict[@"alreadyReceiveAwardCount"] integerValue];
        }
    }
    
    // 从 bizInfo 解析 canDoTaskTimesLimit 和 doneTimes
    id bizVal = taskDict[@"bizInfo"] ?: baseInfo[@"bizInfo"];
    NSDictionary *bDict = [bizInfo isKindOfClass:NSDictionary.class] ? bizInfo : nil;
    if (!bDict && [bizVal isKindOfClass:NSString.class]) {
        NSData *bd = [(NSString *)bizVal dataUsingEncoding:NSUTF8StringEncoding];
        if (bd) bDict = [NSJSONSerialization JSONObjectWithData:bd options:0 error:nil];
    }
    if ([bDict isKindOfClass:NSDictionary.class]) {
        if (limit <= 0 && bDict[@"canDoTaskTimesLimit"]) {
            limit = [bDict[@"canDoTaskTimesLimit"] integerValue];
        }
        if (bDict[@"doneTimes"]) {
            NSInteger dt = [bDict[@"doneTimes"] integerValue];
            if (dt > rightsTimes) rightsTimes = dt;
        }
        if (bDict[@"taskDoneTimes"]) {
            NSInteger tdt = [bDict[@"taskDoneTimes"] integerValue];
            if (tdt > rightsTimes) rightsTimes = tdt;
        }
    }
    NSString *bizStr = [bizVal isKindOfClass:NSString.class] ? (NSString *)bizVal : @"";
    if (bizStr.length > 0) {
        if (limit <= 0 && [bizStr containsString:@"canDoTaskTimesLimit="]) {
            static NSRegularExpression *limitRegex = nil;
            static dispatch_once_t onceLimit;
            dispatch_once(&onceLimit, ^{
                limitRegex = [NSRegularExpression regularExpressionWithPattern:@"canDoTaskTimesLimit=(\\d+)" options:0 error:nil];
            });
            NSTextCheckingResult *m = [limitRegex firstMatchInString:bizStr options:0 range:NSMakeRange(0, bizStr.length)];
            if (m && m.numberOfRanges > 1) {
                limit = [[bizStr substringWithRange:[m rangeAtIndex:1]] integerValue];
            }
        }
        if ([bizStr containsString:@"doneTimes="] || [bizStr containsString:@"taskDoneTimes="]) {
            static NSRegularExpression *doneRegex = nil;
            static dispatch_once_t onceDone;
            dispatch_once(&onceDone, ^{
                doneRegex = [NSRegularExpression regularExpressionWithPattern:@"(?:taskDoneTimes|doneTimes)=(\\d+)" options:0 error:nil];
            });
            NSTextCheckingResult *m = [doneRegex firstMatchInString:bizStr options:0 range:NSMakeRange(0, bizStr.length)];
            if (m && m.numberOfRanges > 1) {
                NSInteger dt = [[bizStr substringWithRange:[m rangeAtIndex:1]] integerValue];
                if (dt > rightsTimes) rightsTimes = dt;
            }
        }
    }
    
    NSInteger awardCount = [rights[@"awardCount"] integerValue];
    if (awardCount <= 0) awardCount = [taskDict[@"awardCount"] integerValue];
    if (awardCount <= 0) awardCount = [baseInfo[@"awardCount"] integerValue];
    
    if (limit > 1 && rightsTimes < limit) {
        return YES;
    }
    
    NSInteger taskRequire = [baseInfo[@"taskRequire"] integerValue];
    NSInteger taskProgress = [baseInfo[@"taskProgress"] integerValue];
    if (taskRequire > 1 && taskProgress < taskRequire) {
        return YES;
    }
    
    // 芭芭农场“逛好物”类多阶段连续浏览任务判断（副标题通常包含“多次”，单次500最高1500）
    NSDictionary *disp = [taskDict[@"taskDisplayConfig"] isKindOfClass:NSDictionary.class] ? taskDict[@"taskDisplayConfig"] : nil;
    NSString *tTitle = [disp[@"title"] isKindOfClass:NSString.class] ? disp[@"title"] : @"";
    NSString *subTitle = [disp[@"subTitle"] isKindOfClass:NSString.class] ? disp[@"subTitle"] : @"";
    id taskIdVal = taskDict[@"taskId"] ?: taskDict[@"taskType"];
    NSString *tId = [taskIdVal respondsToSelector:@selector(stringValue)] ? [taskIdVal stringValue] : (NSString *)taskIdVal;
    if ([tId isEqualToString:@"70000"] || [tTitle containsString:@"逛好物"] || [subTitle containsString:@"多次"]) {
        return YES;
    }
    
    return NO;
}

static NSInteger extractTaskBrowseSeconds(NSDictionary *baseInfo, NSDictionary *bizInfo, NSString *taskTitle) {
    NSString *title = taskTitle ?: @"";
    NSString *taskType = @"";
    if ([baseInfo isKindOfClass:NSDictionary.class]) {
        taskType = baseInfo[@"taskType"] ?: baseInfo[@"taskId"] ?: @"";
        if (!taskType.length && [baseInfo[@"taskBaseInfo"] isKindOfClass:NSDictionary.class]) {
            taskType = baseInfo[@"taskBaseInfo"][@"taskType"] ?: baseInfo[@"taskBaseInfo"][@"taskId"] ?: @"";
        }
        if (!taskType.length && [baseInfo[@"taobaoTaskParams"] isKindOfClass:NSDictionary.class]) {
            taskType = baseInfo[@"taobaoTaskParams"][@"deliveryId"] ?: baseInfo[@"taobaoTaskParams"][@"implId"] ?: @"";
        }
    }
    
    // 1. 优先从文案中动态正则扫描明确秒数要求 (如 "15s", "15秒", "30秒", "5秒", "10秒" 等)
    NSMutableArray<NSString *> *textCandidates = [NSMutableArray array];
    if (taskTitle.length) [textCandidates addObject:taskTitle];
    if ([bizInfo isKindOfClass:NSDictionary.class]) {
        if ([bizInfo[@"taskContent"] isKindOfClass:NSString.class]) [textCandidates addObject:bizInfo[@"taskContent"]];
        if ([bizInfo[@"taskDesc"] isKindOfClass:NSString.class]) [textCandidates addObject:bizInfo[@"taskDesc"]];
        if ([bizInfo[@"subTitle"] isKindOfClass:NSString.class]) [textCandidates addObject:bizInfo[@"subTitle"]];
        if ([bizInfo[@"desc"] isKindOfClass:NSString.class]) [textCandidates addObject:bizInfo[@"desc"]];
        if ([bizInfo[@"awardTitle"] isKindOfClass:NSString.class]) [textCandidates addObject:bizInfo[@"awardTitle"]];
    }
    if ([baseInfo isKindOfClass:NSDictionary.class] && [baseInfo[@"taskDisplayConfig"] isKindOfClass:NSDictionary.class]) {
        NSDictionary *disp = baseInfo[@"taskDisplayConfig"];
        if ([disp[@"desc"] isKindOfClass:NSString.class]) [textCandidates addObject:disp[@"desc"]];
        if ([disp[@"title"] isKindOfClass:NSString.class]) [textCandidates addObject:disp[@"title"]];
    }
    
    static NSRegularExpression *timeRegex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        timeRegex = [NSRegularExpression regularExpressionWithPattern:@"(\\d{1,3})\\s*(?:秒|s|S)" options:0 error:nil];
    });
    
    for (NSString *text in textCandidates) {
        if (!text.length) continue;
        NSTextCheckingResult *match = [timeRegex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
        if (match && match.numberOfRanges > 1) {
            NSString *numStr = [text substringWithRange:[match rangeAtIndex:1]];
            NSInteger sec = [numStr integerValue];
            if (sec > 0 && sec <= 120) {
                return sec;
            }
        }
        if ([text containsString:@"1分钟"] || [text containsString:@"一分钟"]) {
            return 60;
        }
    }
    
    // 2. 检查结构化秒数字段
    if ([bizInfo isKindOfClass:NSDictionary.class]) {
        if (bizInfo[@"browseSeconds"] && [bizInfo[@"browseSeconds"] integerValue] > 0) {
            return [bizInfo[@"browseSeconds"] integerValue];
        }
        if (bizInfo[@"browseTime"] && [bizInfo[@"browseTime"] integerValue] > 0) {
            return [bizInfo[@"browseTime"] integerValue];
        }
        if (bizInfo[@"staySeconds"] && [bizInfo[@"staySeconds"] integerValue] > 0) {
            return [bizInfo[@"staySeconds"] integerValue];
        }
        if (bizInfo[@"stayTime"] && [bizInfo[@"stayTime"] integerValue] > 0) {
            return [bizInfo[@"stayTime"] integerValue];
        }
        if (bizInfo[@"duration"] && [bizInfo[@"duration"] integerValue] > 0) {
            return [bizInfo[@"duration"] integerValue];
        }
    }
    if ([baseInfo isKindOfClass:NSDictionary.class]) {
        if (baseInfo[@"browseSeconds"] && [baseInfo[@"browseSeconds"] integerValue] > 0) {
            return [baseInfo[@"browseSeconds"] integerValue];
        }
    }
    
    // 3. 检查小游戏多阶段浮球配置 miniGameMultiVisitFloatBallConfigList (如保卫向日葵、寻道大千等多阶段浮球)
    id prodParam = baseInfo[@"prodPlayParam"] ?: bizInfo[@"prodPlayParam"];
    NSDictionary *prodDict = nil;
    if ([prodParam isKindOfClass:NSString.class]) {
        prodDict = [NSJSONSerialization JSONObjectWithData:[(NSString *)prodParam dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    } else if ([prodParam isKindOfClass:NSDictionary.class]) {
        prodDict = prodParam;
    }
    
    NSInteger rTimes = 0;
    if ([baseInfo[@"taskRights"] isKindOfClass:NSDictionary.class]) {
        rTimes = [baseInfo[@"taskRights"][@"rightsTimes"] integerValue];
    }
    if (rTimes <= 0 && baseInfo[@"rightsTimes"]) {
        rTimes = [baseInfo[@"rightsTimes"] integerValue];
    }
    
    if ([prodDict isKindOfClass:NSDictionary.class]) {
        NSArray *configList = prodDict[@"miniGameMultiVisitFloatBallConfigList"];
        if ([configList isKindOfClass:NSArray.class] && configList.count > 0) {
            NSInteger idx = rTimes;
            if (idx < 0) idx = 0;
            if (idx >= configList.count) idx = configList.count - 1;
            NSDictionary *stageConfig = configList[idx];
            if ([stageConfig isKindOfClass:NSDictionary.class] && stageConfig[@"timeCount"]) {
                NSInteger sec = [stageConfig[@"timeCount"] integerValue];
                if (sec > 0) {
                    return (sec > 65) ? 65 : sec;
                }
            }
        }
    }
    
    // 4. 检查常规浮球 floatBallConfig 中的 floatBallDuration
    id fbCfg = bizInfo[@"floatBallConfig"] ?: baseInfo[@"floatBallConfig"];
    if ([fbCfg isKindOfClass:NSDictionary.class]) {
        NSInteger dur = [fbCfg[@"floatBallDuration"] integerValue];
        if (dur > 0) {
            return (dur > 65) ? 65 : dur;
        }
    }
    
    // 5. 农场乐园小游戏多阶段浮球任务（如保卫向日葵、寻道大千等）按轮次默认阶梯倒计时
    NSString *upperType = taskType.uppercaseString;
    BOOL isFloatBallGame = [upperType containsString:@"FLOATBALL"] || [upperType containsString:@"NCLY"] ||
                           [[baseInfo objectForKey:@"actionType"] isEqualToString:@"MULTI_STAGE"];
    if (isFloatBallGame) {
        if (rTimes <= 2) {
            return 15;
        } else if (rTimes == 3) {
            return 30;
        } else if (rTimes >= 4 && rTimes <= 6) {
            return 60;
        } else if (rTimes >= 7) {
            return 65;
        }
        return 15;
    }
    
    // 6. 游戏类任务明确指定时长：用户明确指定“我的花园世界”需浏览30秒；玩游戏/小游戏类任务若无正则秒数默认30秒
    if ([title containsString:@"花园世界"] || [title containsString:@"我的花园世界"]) {
        return 30;
    }
    if ([title containsString:@"玩游戏"] || [title containsString:@"小游戏"] || [taskType containsString:@"GAME"]) {
        return 30;
    }
    if ([title containsString:@"向僵尸开炮"] || [taskType containsString:@"JSKP"]) {
        return 15;
    }
    
    // 7. 淘宝/导流外链任务明确需要静默加载并触发前端 mtop 鉴权，保留 6 秒确保后台脚本执行完毕
    NSString *upperTitle = [title uppercaseString];
    if ([upperType containsString:@"TAOBAO"] || [upperType containsString:@"TB_"] || [upperType containsString:@"TB"] || [upperTitle containsString:@"淘宝"] || [upperTitle containsString:@"去淘宝"] || [upperType containsString:@"QIANDAO"] || [upperTitle containsString:@"签到领红包"]) {
        return 6;
    }
    if ([upperType containsString:@"XIANYU"] || [upperType containsString:@"BBNC"] || [upperType containsString:@"SHENQIYUTANG"] || [upperType containsString:@"SQYT"] || [upperType containsString:@"XLIGHT"] || [upperTitle containsString:@"UC"] || [upperTitle containsString:@"芭芭农场"] || [upperTitle containsString:@"施肥"] || [upperTitle containsString:@"闲置"] || [upperTitle containsString:@"闲鱼"] || [upperTitle containsString:@"循环"] || [upperTitle containsString:@"市集"] || [upperTitle containsString:@"集市"] || [upperTitle containsString:@"鱼塘"] || [upperTitle containsString:@"逛一逛"] || [upperTitle containsString:@"去看看"]) {
        return 2;
    }
    
    // 8. 常规即时任务（如签到、领取等）：直接 0 秒秒做
    return 0;
}

-(void)handleVitalityTaskListResponse:(id)args {
    if ((!self.enableAutoRewardTasks && !self.enableAutoOceanTasks && !self.enableAutoAIFish && !self.enableAutoFarmTasks && !self.enableAutoPatrolNew) || ![args isKindOfClass:NSDictionary.class]) return;
    if ([AntForestManager isManorResponse:args]) return;
    @try {
        initDailyTaskCache();
        NSDictionary *data = args;
        if (data[@"resData"] && [data[@"resData"] isKindOfClass:NSDictionary.class]) {
            data = data[@"resData"];
        }
        
        // 检查是否有任务执行结果回包：只有在领取奖励（receiveTaskAward）成功或任务已完结时才记为已完成
        NSString *resCode = [NSString stringWithFormat:@"%@", data[@"code"] ?: (data[@"resultCode"] ?: @"")];
        NSString *resDesc = [NSString stringWithFormat:@"%@", data[@"desc"] ?: (data[@"resultDesc"] ?: @"")];
        NSString *errMsg = [NSString stringWithFormat:@"%@", data[@"errorMessage"] ?: @""];
        NSString *opType = [NSString stringWithFormat:@"%@", (args[@"operationType"] ?: data[@"operationType"]) ?: (self.lastRpcOperationType ?: @"")];
        id rawDataVal = args[@"data"] ?: data[@"data"];
        NSString *signDateStr = [rawDataVal isKindOfClass:NSString.class] ? (NSString *)rawDataVal : nil;
        BOOL isSignDate = (signDateStr.length >= 8 && signDateStr.length <= 15 && [signDateStr containsString:@"-"]);
        BOOL isAntiepSignOp = [opType containsString:@"antiep.sign"] || [opType isEqualToString:@"com.alipay.antiep.sign"];
        BOOL hasSignModel = (data[@"signModel"] != nil || args[@"signModel"] != nil);
        BOOL isSignResp = (isAntiepSignOp && isSignDate) || (isAntiepSignOp && (data[@"continuousCount"] || args[@"continuousCount"]));
        NSDictionary *finishVO = [data[@"finishAwardResultVO"] isKindOfClass:NSDictionary.class] ? data[@"finishAwardResultVO"] : ([data[@"finishVO"] isKindOfClass:NSDictionary.class] ? data[@"finishVO"] : nil);
        NSDictionary *receiveVO = [data[@"receiveAwardResultVO"] isKindOfClass:NSDictionary.class] ? data[@"receiveAwardResultVO"] : ([data[@"awardResultVO"] isKindOfClass:NSDictionary.class] ? data[@"awardResultVO"] : nil);
        BOOL finishHasNoNextStage = ([finishVO isKindOfClass:NSDictionary.class] && finishVO[@"hasNextStage"] && ![finishVO[@"hasNextStage"] boolValue]);
        NSString *respTaskType = [NSString stringWithFormat:@"%@", finishVO[@"taskType"] ?: (receiveVO[@"taskType"] ?: (data[@"taskType"] ?: (args[@"taskType"] ?: @"")))];
        NSString *respSceneCode = [NSString stringWithFormat:@"%@", finishVO[@"sceneCode"] ?: (receiveVO[@"sceneCode"] ?: (data[@"sceneCode"] ?: (args[@"sceneCode"] ?: @"")))];
        NSString *resolvedKey = (respTaskType.length && respSceneCode.length) ? [NSString stringWithFormat:@"%@:%@", respSceneCode, respTaskType] : gCurrentExecutingTaskKey;
        
        BOOL isTaskExecOp = ([opType containsString:@"finishTask"] || [opType containsString:@"receiveTaskAward"] || [opType containsString:@"applyTask"] || [opType containsString:@"exchangeVitality"]) && ![opType containsString:@"listTask"] && ![opType containsString:@"query"];
        if (isTaskExecOp) {
            BOOL isSuccess = [resCode isEqualToString:@"100000000"] || [resCode isEqualToString:@"1000"] || [resCode isEqualToString:@"SUCCESS"] || [data[@"success"] boolValue] || [args[@"success"] boolValue] || [resDesc containsString:@"处理成功"] || [resDesc containsString:@"成功"];
            if (!isSuccess && ![resCode isEqualToString:@"400000040"] && resCode.length) {
                [self recordStage:[NSString stringWithFormat:@"领奖励·执行回包：%@ (code=%@, desc=%@)", opType, resCode ?: @"-", resDesc ?: @"-"]];
            }
        }
        
        BOOL isRightsSuccess = [data[@"provideRightsSuccess"] boolValue] || [args[@"provideRightsSuccess"] boolValue] || [data[@"incAwardCount"] integerValue] > 0 || [args[@"incAwardCount"] integerValue] > 0 || (data[@"taskConfigResultVO"] != nil && [data[@"success"] boolValue]);
        if (receiveVO != nil || isRightsSuccess || [opType containsString:@"receiveTaskAward"] || [opType containsString:@"receive"] || [resDesc containsString:@"任务已完结"] || [resDesc containsString:@"已完结"] || [resDesc containsString:@"已领取"] || [resDesc containsString:@"无法重复领取"] || finishHasNoNextStage) {
            if ([resCode isEqualToString:@"100000000"] || [resCode isEqualToString:@"1000"] || [resCode isEqualToString:@"400000030"] || [resCode isEqualToString:@"400000005"] || [resCode isEqualToString:@"400000012"] || [resCode isEqualToString:@"B000000008"] || [resCode isEqualToString:@"SUCCESS"] || [data[@"success"] boolValue] || [args[@"success"] boolValue] ||
                [resDesc containsString:@"处理成功"] || [resDesc containsString:@"成功"] || [resDesc containsString:@"超过上限"] || [resDesc containsString:@"无法重复领取"] || [resDesc containsString:@"已完结"] || [resDesc containsString:@"已领取"] || isRightsSuccess) {
                if (resolvedKey.length) {
                    @synchronized(self) {
                        if (gCurrentExecutingTaskIsMultiStage && ![resDesc containsString:@"已完结"] && ![resDesc containsString:@"超过上限"] && !finishHasNoNextStage) {
                            // 多阶段任务本轮领奖成功，但未彻底做满全部次数，严禁锁入今日完成缓存，并主动移除
                            [gDailyCompletedTasks removeObject:resolvedKey];
                        } else {
                            [gDailyCompletedTasks addObject:resolvedKey];
                        }
                        [gVitalityTaskRetryCounts removeObjectForKey:resolvedKey];
                        saveDailyTaskCache();
                    }
                    NSString *moduleTag = ([resolvedKey containsString:@"FARM"] || [resolvedKey containsString:@"ORCHARD"]) ? @"芭芭农场" : (([resolvedKey containsString:@"DRAW"] || [resolvedKey containsString:@"LOTTERY"]) ? @"森林寻宝" : (([resolvedKey containsString:@"MONOPOLY"] || [resolvedKey containsString:@"HSDWY"]) ? @"新版保护地" : (([resolvedKey containsString:@"RESCUE"] || [resolvedKey containsString:@"OCEAN"]) ? @"神奇海洋" : ([resolvedKey containsString:@"AIFISH"] ? @"AI摸鱼" : @"领奖励"))));
                    if (isRightsSuccess) {
                        NSDictionary *tcVO = [data[@"taskConfigResultVO"] isKindOfClass:NSDictionary.class] ? data[@"taskConfigResultVO"] : ([args[@"taskConfigResultVO"] isKindOfClass:NSDictionary.class] ? args[@"taskConfigResultVO"] : nil);
                        NSString *awardType = tcVO[@"awardType"] ?: @"";
                        NSInteger count = [data[@"incAwardCount"] integerValue] ?: [args[@"incAwardCount"] integerValue];
                        if ([awardType isEqualToString:@"LUCKY_DRAW"] || [awardType containsString:@"DRAW"]) {
                            [self recordStage:[NSString stringWithFormat:@"%@：服务端已确认领取成功（获得 %ld 次抽奖机会）", moduleTag, (long)(count > 0 ? count : 1)]];
                        } else {
                            [self recordStage:[NSString stringWithFormat:@"%@：服务端已确认领取成功", moduleTag]];
                        }
                    } else {
                        [self recordStage:[NSString stringWithFormat:@"%@：服务端已确认领取成功", moduleTag]];
                    }
                }
            }
        } else if (isAntiepSignOp || hasSignModel || isSignResp) {
            NSDictionary *signModel = [data[@"signModel"] isKindOfClass:NSDictionary.class] ? data[@"signModel"] : ([args[@"signModel"] isKindOfClass:NSDictionary.class] ? args[@"signModel"] : nil);
            BOOL isSigned = [signModel[@"signed"] boolValue];
            BOOL isExplicitFailure = [resCode isEqualToString:@"1400000004"] || [resDesc containsString:@"不存在"] || [resDesc containsString:@"失败"] || (data[@"success"] != nil && ![data[@"success"] boolValue]);
            // 严禁将非签到操作（如 queryCommonSign 查询回包中 signed: false 的数据）误判为签到成功！
            // 仅在明确为 antiep.sign 操作成功，或回包 signed 明确为 true 时，方判定为今日已签到
            BOOL isSuccessSign = !isExplicitFailure && (
                isSigned ||
                (isAntiepSignOp && ([resCode isEqualToString:@"100000000"] || [resCode isEqualToString:@"SUCCESS"])) ||
                ([resDesc containsString:@"已签到"]) ||
                (isAntiepSignOp && [resCode isEqualToString:@"100000000"] && (data[@"continuousCount"] || args[@"continuousCount"]))
            );
            if (isSuccessSign) {
                BOOL alreadySigned = NO;
                @synchronized(self) {
                    alreadySigned = [gDailyCompletedTasks containsObject:@"SIGN_TODAY"];
                    if (!alreadySigned) {
                        [gDailyCompletedTasks addObject:@"SIGN_TODAY"];
                        saveDailyTaskCache();
                    }
                }
                if ([self.lastRpcOperationType containsString:@"sign"]) {
                    self.lastRpcOperationType = nil;
                }
                if (!alreadySigned) {
                    NSInteger contCount = [data[@"continuousCount"] integerValue];
                    if (!contCount && [args[@"continuousCount"] respondsToSelector:@selector(integerValue)]) {
                        contCount = [args[@"continuousCount"] integerValue];
                    }
                    NSDictionary *signAward = [signModel[@"signAward"] isKindOfClass:NSDictionary.class] ? signModel[@"signAward"] : nil;
                    NSInteger awardCount = [signAward[@"count"] integerValue];
                    if (awardCount > 0 && contCount > 0) {
                        [self recordStage:[NSString stringWithFormat:@"领奖励：今日能量签到成功（获得 %ld g 能量，已连签 %ld 天），已重置并激活今日累计阶梯奖励", (long)awardCount, (long)contCount]];
                    } else if (awardCount > 0) {
                        [self recordStage:[NSString stringWithFormat:@"领奖励：今日能量签到成功（获得 %ld g 能量），已重置并激活今日累计阶梯奖励", (long)awardCount]];
                    } else {
                        [self recordStage:@"领奖励：今日能量签到成功，已重置并激活今日累计阶梯奖励"];
                    }
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [self queryVitalityTaskListWithForce:YES];
                    });
                }
            } else if (signModel && !isSigned && !isAntiepSignOp) {
                // queryCommonSign 明确返回今日未签到，立即清除可能存在的本地误缓存，并提取 entityId 主动发起签到
                @synchronized(self) {
                    if ([gDailyCompletedTasks containsObject:@"SIGN_TODAY"]) {
                        [gDailyCompletedTasks removeObject:@"SIGN_TODAY"];
                        saveDailyTaskCache();
                    }
                }
                NSString *eid = [signModel[@"entityId"] isKindOfClass:NSString.class] ? signModel[@"entityId"] : ([signModel[@"signId"] isKindOfClass:NSString.class] ? signModel[@"signId"] : @"");
                NSString *sc = [signModel[@"sceneCode"] isKindOfClass:NSString.class] ? signModel[@"sceneCode"] : @"ANTFOREST_ENERGY_TASK_SIGN";
                [self recordStage:@"领奖励：检测到今日尚未签到，正在执行每日能量签到以激活阶梯大奖..."];
                [self signVitalityTask:eid sceneCode:sc];
            }
        } else if ([resCode isEqualToString:@"3000"] || [args[@"error"] integerValue] == 3000 || [data[@"error"] integerValue] == 3000 || [args[@"error"] integerValue] == 999) {
            BOOL isLegacyAntiepRpc = [opType hasPrefix:@"com.alipay.antiep."] && ![opType containsString:@"antieptask"];
            if (!isLegacyAntiepRpc) {
                static NSTimeInterval lastErrLogTime = 0;
                NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                if (now - lastErrLogTime > 4.0) {
                    lastErrLogTime = now;
                    NSLog(@"[AntForestPort] 任务中心：服务端提示开小差/繁忙（3000/999），已自动暂停当前重试防风控");
                }
            }
        } else if ([resCode isEqualToString:@"400000040"] || [resDesc containsString:@"不支持rpc调用"] || [resCode isEqualToString:@"400000001"] || [resDesc containsString:@"任务全局配置不存在"]) {
            BOOL isLegacyAntiepRpc = [opType hasPrefix:@"com.alipay.antiep."] && ![opType containsString:@"antieptask"];
            BOOL isDaoliuTaskKey = [resolvedKey.lowercaseString containsString:@"taobao"] || [resolvedKey.lowercaseString containsString:@"daoliu"] || [resolvedKey.lowercaseString containsString:@"tb_"] || [resolvedKey.lowercaseString containsString:@"uc"];
            if (isLegacyAntiepRpc || isDaoliuTaskKey) {
                // 旧版 antiep RPC 对导流/浏览/淘宝类任务不支持直接调用属于正常回包，已被 OpenGreen 覆盖，严禁误将任务加入失败黑名单
                return;
            }
            NSString *moduleTag = ([resolvedKey containsString:@"FARM"] || [resolvedKey containsString:@"ORCHARD"]) ? @"芭芭农场" : (([resolvedKey containsString:@"DRAW"] || [resolvedKey containsString:@"LOTTERY"]) ? @"森林寻宝" : (([resolvedKey containsString:@"MONOPOLY"] || [resolvedKey containsString:@"HSDWY"]) ? @"新版保护地" : (([resolvedKey containsString:@"RESCUE"] || [resolvedKey containsString:@"OCEAN"]) ? @"神奇海洋" : ([resolvedKey containsString:@"AIFISH"] ? @"AI摸鱼" : @"任务中心"))));
            BOOL alreadyFailed = NO;
            if (resolvedKey.length) {
                @synchronized(self) {
                    alreadyFailed = [gDailyFailedTasks containsObject:resolvedKey];
                    [gDailyFailedTasks addObject:resolvedKey];
                    [gVitalityTaskRetryCounts removeObjectForKey:resolvedKey];
                    [gFarmTaskRetryCounts removeObjectForKey:resolvedKey];
                    saveDailyTaskCache();
                }
            }
            if (!alreadyFailed) {
                [self recordStage:[NSString stringWithFormat:@"%@ · 当前任务需在对应界面手动操作完成（服务端不支持直接调用）", moduleTag]];
            }
        }
        
        @synchronized(self) {
            if (!vitalityTaskQueue) {
                vitalityTaskQueue = [NSMutableArray array];
            }
        }
        
        // 1. 签到处理 (仅在开启领奖励与寻宝时处理，优先适配现代协议 forestSignVOList，兼容 forestSignVO 及 legacy energySignVO)
        NSDictionary *signVO = nil;
        if ([data[@"forestSignVOList"] isKindOfClass:NSArray.class]) {
            NSArray *signList = data[@"forestSignVOList"];
            for (id item in signList) {
                if ([item isKindOfClass:NSDictionary.class]) {
                    signVO = item;
                    break;
                }
            }
        }
        if (!signVO && [data[@"forestSignVO"] isKindOfClass:NSDictionary.class]) {
            signVO = data[@"forestSignVO"];
        }
        if (!signVO && [args[@"forestSignVO"] isKindOfClass:NSDictionary.class]) {
            signVO = args[@"forestSignVO"];
        }
        if (!signVO && [data[@"energySignVO"] isKindOfClass:NSDictionary.class]) {
            signVO = data[@"energySignVO"];
        }
        if (!signVO && [args[@"energySignVO"] isKindOfClass:NSDictionary.class]) {
            signVO = args[@"energySignVO"];
        }
        if (!signVO && [data[@"signModel"] isKindOfClass:NSDictionary.class]) {
            signVO = data[@"signModel"];
        }
        if (!signVO && [args[@"signModel"] isKindOfClass:NSDictionary.class]) {
            signVO = args[@"signModel"];
        }
        if (self.enableAutoRewardTasks && signVO) {
            NSString *signId = [signVO[@"signId"] isKindOfClass:NSString.class] ? signVO[@"signId"] : ([signVO[@"entityId"] isKindOfClass:NSString.class] ? signVO[@"entityId"] : @"");
            NSString *currKey = [signVO[@"currentSignKey"] isKindOfClass:NSString.class] ? signVO[@"currentSignKey"] : @"";
            NSString *signSceneCode = [signVO[@"sceneCode"] isKindOfClass:NSString.class] ? signVO[@"sceneCode"] : @"ANTFOREST_ENERGY_TASK_SIGN";
            NSArray *records = [signVO[@"signRecords"] isKindOfClass:NSArray.class] ? signVO[@"signRecords"] : nil;
            BOOL isSignedToday = NO;
            if (signVO[@"signed"] != nil) {
                isSignedToday = [signVO[@"signed"] boolValue];
            }
            for (id r in records) {
                if ([r isKindOfClass:NSDictionary.class]) {
                    NSString *rk = r[@"signKey"];
                    if ([rk isEqualToString:currKey] || [rk isEqualToString:getCurrentDateString()]) {
                        isSignedToday = [r[@"signed"] boolValue];
                        break;
                    }
                }
            }
            NSString *signTaskKey = @"SIGN_TODAY";
            if (isSignedToday) {
                @synchronized(self) {
                    if (![gDailyCompletedTasks containsObject:signTaskKey]) {
                        [gDailyCompletedTasks addObject:signTaskKey];
                        saveDailyTaskCache();
                        [self recordStage:@"领奖励：检测到今日已完成能量签到，直接执行常规任务与阶梯大奖"];
                    }
                }
            } else if (signId.length) {
                // 服务端明确未签到，立即清除可能存在的本地误缓存
                @synchronized(self) {
                    if ([gDailyCompletedTasks containsObject:signTaskKey]) {
                        [gDailyCompletedTasks removeObject:signTaskKey];
                        saveDailyTaskCache();
                    }
                }
                // 优先执行能量签到以激活今日累计阶梯奖励，但绝不阻断后续常规任务解析入队，杜绝死锁与零点任务瘫痪
                BOOL alreadyInQueue = NO;
                @synchronized(self) {
                    for (NSDictionary *q in vitalityTaskQueue) {
                        if ([q[@"action"] isEqualToString:@"sign"]) { alreadyInQueue = YES; break; }
                    }
                }
                if (!alreadyInQueue) {
                    [self recordStage:@"领奖励：检测到今日尚未签到，优先执行能量签到以激活今日累计阶梯奖励..."];
                    @synchronized(self) {
                        [vitalityTaskQueue insertObject:@{
                            @"action": @"sign",
                            @"signId": signId,
                            @"sceneCode": signSceneCode,
                            @"title": @"每日签到",
                            @"awardName": @"能量"
                        } atIndex:0];
                    }
                } else if (signId.length) {
                    @synchronized(self) {
                        for (NSUInteger i = 0; i < vitalityTaskQueue.count; i++) {
                            NSDictionary *q = vitalityTaskQueue[i];
                            if ([q[@"action"] isEqualToString:@"sign"]) {
                                NSMutableDictionary *mq = [q mutableCopy];
                                mq[@"signId"] = signId;
                                if (signSceneCode.length) mq[@"sceneCode"] = signSceneCode;
                                [vitalityTaskQueue replaceObjectAtIndex:i withObject:mq];
                                break;
                            }
                        }
                    }
                }
            }
        }
        
        // 2. 收集任务列表
        NSMutableArray<NSDictionary *> *allTaskList = [NSMutableArray array];
        NSArray *candidateGroupKeys = @[@"forestTasksNew", @"stageTaskList", @"stageInfoList", @"stagePrizeList", @"stageAwards", @"accumulateTasks", @"ladderTasks", @"taskGroupList", @"forestTasks", @"challengeTasks", @"challengeTaskList", @"pkTaskList", @"pkTasks", @"subTaskList", @"taskList"];
        for (NSString *key in candidateGroupKeys) {
            NSArray *arr = [data[key] isKindOfClass:NSArray.class] ? data[key] : nil;
            if (arr.count > 0) {
                for (id g in arr) {
                    if ([g isKindOfClass:NSDictionary.class]) {
                        NSArray *subList = g[@"taskInfoList"] ?: g[@"taskList"] ?: g[@"subTaskList"] ?: g[@"tasks"];
                        if ([subList isKindOfClass:NSArray.class]) [allTaskList addObjectsFromArray:subList];
                        else if (g[@"taskBaseInfo"] || g[@"taskType"] || g[@"taskId"]) [allTaskList addObject:g];
                    }
                }
            }
        }
        NSArray *topList = [data[@"taskInfoList"] isKindOfClass:NSArray.class] ? data[@"taskInfoList"] : ([data[@"taskList"] isKindOfClass:NSArray.class] ? data[@"taskList"] : nil);
        if (topList.count > 0) {
            [allTaskList addObjectsFromArray:topList];
        }
        
        if (!respSceneCode.length || [respSceneCode isEqualToString:@"(null)"]) {
            for (id t in allTaskList) {
                if ([t isKindOfClass:NSDictionary.class]) {
                    NSDictionary *bi = [t[@"taskBaseInfo"] isKindOfClass:NSDictionary.class] ? t[@"taskBaseInfo"] : t;
                    NSString *sc = bi[@"sceneCode"] ?: t[@"sceneCode"] ?: t[@"iepSceneCode"];
                    if (sc.length) {
                        respSceneCode = sc;
                        break;
                    }
                }
            }
        }
        
        NSMutableArray<NSDictionary *> *newlyParsedTasks = [NSMutableArray array];
        NSMutableArray<NSDictionary *> *accTasks = [NSMutableArray array];
        
        for (id t in allTaskList) {
            if (![t isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *baseInfo = [t[@"taskBaseInfo"] isKindOfClass:NSDictionary.class] ? t[@"taskBaseInfo"] : t;
            NSString *taskType = [baseInfo[@"taskType"] isKindOfClass:NSString.class] ? baseInfo[@"taskType"] : ([t[@"taskId"] isKindOfClass:NSString.class] ? t[@"taskId"] : ([t[@"deliveryId"] isKindOfClass:NSString.class] ? t[@"deliveryId"] : @""));
            if (!taskType.length) continue;
            NSString *sceneCode = [baseInfo[@"sceneCode"] isKindOfClass:NSString.class] ? baseInfo[@"sceneCode"] : ([t[@"sceneCode"] isKindOfClass:NSString.class] ? t[@"sceneCode"] : ([t[@"iepSceneCode"] isKindOfClass:NSString.class] ? t[@"iepSceneCode"] : @"ANTFOREST_VITALITY_TASK"));
            NSString *taskStatus = [baseInfo[@"taskStatus"] isKindOfClass:NSString.class] ? baseInfo[@"taskStatus"] : ([t[@"taskStatus"] isKindOfClass:NSString.class] ? t[@"taskStatus"] : ([t[@"status"] isKindOfClass:NSString.class] ? t[@"status"] : @"")); // TODO, FINISHED, RECEIVED
            NSString *bizInfoStr = baseInfo[@"bizInfo"] ?: t[@"bizInfo"];
            
            NSDictionary *bizInfo = nil;
            if ([bizInfoStr isKindOfClass:NSString.class]) {
                NSData *bd = [bizInfoStr dataUsingEncoding:NSUTF8StringEncoding];
                if (bd) bizInfo = [NSJSONSerialization JSONObjectWithData:bd options:0 error:nil];
            } else if ([bizInfoStr isKindOfClass:NSDictionary.class]) {
                bizInfo = (NSDictionary *)bizInfoStr;
            }
            
            id rawTitle = bizInfo[@"taskTitle"] ?: bizInfo[@"title"] ?: t[@"title"] ?: t[@"taskTitle"] ?: baseInfo[@"taskTitle"] ?: taskType;
            NSString *taskTitle = [rawTitle isKindOfClass:NSString.class] ? (NSString *)rawTitle : ([rawTitle respondsToSelector:@selector(stringValue)] ? [rawTitle stringValue] : taskType);
            if (![taskTitle isKindOfClass:NSString.class]) taskTitle = taskType;
            BOOL autoCompleteTask = [bizInfo[@"autoCompleteTask"] boolValue];
            NSString *awardName = bizInfo[@"energy"] ?: bizInfo[@"vitality"] ?: ([taskTitle containsString:@"机会"] ? @"抽奖机会" : @"奖励");
            if (![awardName isKindOfClass:NSString.class]) awardName = @"奖励";
            
            NSDictionary *rights = [t[@"taskRights"] isKindOfClass:NSDictionary.class] ? t[@"taskRights"] : nil;
            NSInteger alreadyReceive = [rights[@"alreadyReceiveAwardCount"] integerValue];
            NSInteger rightsTimes = [rights[@"rightsTimes"] integerValue];
            NSInteger rightsTimesLimit = [rights[@"rightsTimesLimit"] integerValue];
            if (rightsTimesLimit <= 0) rightsTimesLimit = [baseInfo[@"rightsTimesLimit"] integerValue];
            if (rightsTimesLimit <= 0) rightsTimesLimit = [t[@"rightsTimesLimit"] integerValue];
            if (alreadyReceive <= 0) alreadyReceive = [baseInfo[@"alreadyReceiveAwardCount"] integerValue];
            if (alreadyReceive <= 0) alreadyReceive = [t[@"alreadyReceiveAwardCount"] integerValue];
            if (rightsTimes <= 0) rightsTimes = [baseInfo[@"rightsTimes"] integerValue];
            if (rightsTimes <= 0) rightsTimes = [t[@"rightsTimes"] integerValue];
            
            id extVal = t[@"extend"] ?: baseInfo[@"extend"];
            if ([extVal isKindOfClass:NSString.class] && [extVal containsString:@"alreadyReceiveAwardCount"]) {
                NSDictionary *ed = [NSJSONSerialization JSONObjectWithData:[extVal dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
                if (ed[@"alreadyReceiveAwardCount"]) alreadyReceive = [ed[@"alreadyReceiveAwardCount"] integerValue];
            } else if ([extVal isKindOfClass:NSDictionary.class] && extVal[@"alreadyReceiveAwardCount"]) {
                alreadyReceive = [extVal[@"alreadyReceiveAwardCount"] integerValue];
            }
            if ([bizInfo isKindOfClass:NSDictionary.class]) {
                if (rightsTimesLimit <= 0 && bizInfo[@"canDoTaskTimesLimit"]) {
                    rightsTimesLimit = [bizInfo[@"canDoTaskTimesLimit"] integerValue];
                }
                if (bizInfo[@"doneTimes"]) {
                    NSInteger dt = [bizInfo[@"doneTimes"] integerValue];
                    if (dt > rightsTimes) rightsTimes = dt;
                }
                if (bizInfo[@"taskDoneTimes"]) {
                    NSInteger tdt = [bizInfo[@"taskDoneTimes"] integerValue];
                    if (tdt > rightsTimes) rightsTimes = tdt;
                }
            }
            
            NSString *taskKey = [NSString stringWithFormat:@"%@:%@", sceneCode, taskType];
            NSInteger taskRequire = [baseInfo[@"taskRequire"] integerValue];
            NSInteger taskProgress = [baseInfo[@"taskProgress"] integerValue];
            NSInteger awardCount = [rights[@"awardCount"] integerValue];
            if (awardCount <= 0) awardCount = [t[@"awardCount"] integerValue];
            if (awardCount <= 0) awardCount = [baseInfo[@"awardCount"] integerValue];
            
            // 优先评估多阶段任务未完成状态
            BOOL isMultiIncomplete = isMultiStageIncompleteTask(taskTitle, taskProgress, taskRequire) || isMultiStageTaskFromDict(t, baseInfo, bizInfo);
            
            // 待领取状态判定：
            // 1. 服务端 taskStatus 明确为 FINISHED, CAN_RECEIVE, WAIT_AWARD, WAIT_RECEIVE 等；
            // 2. 进度已达标且未领完：taskRequire > 0 && taskProgress >= taskRequire && (rightsTimesLimit <= 0 || alreadyReceive < rightsTimesLimit)；
            // 3. 严禁将 TODO 或 INIT 状态的任务判定为待领取（TODO任务尚未完成，绝不能直接领奖，必须作为 browse 或 finish 执行）；
            // 4. 严禁使用 finishedBtnText！finishedBtnText 仅为任务完结后展示的静态文案模板，未完成时服务端也会下发。
            //    只有当前 active 按钮 btnText 明确表示可领取且 taskStatus 非 TODO 时，才作为待领依据。
            BOOL isTodoStatus = [taskStatus isEqualToString:@"TODO"] ||
                                [taskStatus isEqualToString:@"INIT"] ||
                                [taskStatus isEqualToString:@"WAIT_TODO"] ||
                                [taskStatus isEqualToString:@"NOT_START"] ||
                                [taskStatus isEqualToString:@"DOING"] ||
                                [taskStatus isEqualToString:@"IN_PROGRESS"];
            
            NSString *btnText = bizInfo[@"btnText"] ?: bizInfo[@"buttonText"] ?: baseInfo[@"btnText"] ?: t[@"btnText"] ?: @"";
            if (!btnText.length && [t[@"taskDisplayConfig"] isKindOfClass:NSDictionary.class]) {
                btnText = t[@"taskDisplayConfig"][@"buttonText"] ?: t[@"taskDisplayConfig"][@"btnText"] ?: @"";
            }
            BOOL isClaimBtn = ([btnText containsString:@"去领取"]) ||
                              ([btnText containsString:@"领"] && ![btnText containsString:@"去"]) ||
                              [btnText isEqualToString:@"领取"] || [btnText isEqualToString:@"领奖"] ||
                              [btnText isEqualToString:@"领步数"] || [btnText isEqualToString:@"立即领取"] ||
                              [btnText isEqualToString:@"领取奖励"] || [btnText isEqualToString:@"领饲料"] ||
                              [btnText isEqualToString:@"领机会"] || [btnText isEqualToString:@"领摸鱼次数"] ||
                              [btnText isEqualToString:@"领能量"] || [btnText isEqualToString:@"领取能量"] ||
                              [btnText isEqualToString:@"收下"] || [btnText isEqualToString:@"开心收下"];
            BOOL isStatusCanReceive = [taskStatus isEqualToString:@"FINISHED"] ||
                                      [taskStatus isEqualToString:@"CAN_RECEIVE"] ||
                                      [taskStatus isEqualToString:@"WAIT_AWARD"] ||
                                      [taskStatus isEqualToString:@"WAIT_RECEIVE"] ||
                                      [taskStatus isEqualToString:@"TO_RECEIVE"] ||
                                      [taskStatus isEqualToString:@"SUCCESS"];
            BOOL isProgressMet = (!isTodoStatus && taskRequire > 0 && taskProgress >= taskRequire && (rightsTimesLimit <= 0 || alreadyReceive < rightsTimesLimit));
            BOOL isDoneTimesMet = (!isTodoStatus && [bizInfo isKindOfClass:NSDictionary.class] && [bizInfo[@"doneTimes"] integerValue] > alreadyReceive && [bizInfo[@"doneTimes"] integerValue] > 0);
            
            BOOL hasPendingAward = NO;
            if (isClaimBtn || isStatusCanReceive || isProgressMet || isDoneTimesMet) {
                hasPendingAward = YES;
            }
            
            // 用户明确指定：逛农场得落叶肥料由用户手动执行，插件不自动做
            if ([taskTitle containsString:@"落叶"] || [taskType containsString:@"LEAF"] || [taskType containsString:@"leaf"]) {
                continue;
            }
            
            // 严禁将累积肥料数量（如1400肥）与次数限制（如8次）错误比较！
            // 只要存在未领取的奖励（hasPendingAward），或者属于多阶段未完结任务，绝不视为全部完成！
            // 仅在明确已领完（RECEIVED且已领>=限制，或alreadyReceive>=rightsTimesLimit且无未领奖）时才判定为全部完成
            BOOL isAllFinished = !hasPendingAward && !isMultiIncomplete && (
                ([taskStatus isEqualToString:@"RECEIVED"] && (rightsTimesLimit <= 0 || alreadyReceive >= rightsTimesLimit)) ||
                (rightsTimesLimit > 0 && alreadyReceive >= rightsTimesLimit)
            );
            if (isAllFinished) {
                @synchronized(self) {
                    [gDailyCompletedTasks addObject:taskKey];
                    saveDailyTaskCache();
                }
                continue;
            }
            
            // 如果存在待领奖且之前在失败列表中，仅在重试未超限时给予机会，绝不无限制抹除重试计数
            BOOL isTaobaoTask = [taskTitle containsString:@"淘宝"] || [taskType.lowercaseString containsString:@"taobao"] || [taskType.lowercaseString containsString:@"tb_"];
            if (isTaobaoTask && !isAllFinished) {
                // 淘宝任务只要服务端非已完结状态，立即清除历史已完成误缓存，确保稳定执行（失败缓存交由轮次熔断控制，严禁实时清除导致死循环）
                @synchronized(self) {
                    [gDailyCompletedTasks removeObject:taskKey];
                    saveDailyTaskCache();
                }
            } else if (hasPendingAward) {
                @synchronized(self) {
                    if ([gDailyFailedTasks containsObject:taskKey]) {
                        NSInteger currRetries = [gVitalityTaskRetryCounts[taskKey] integerValue];
                        if (currRetries < 3) {
                            [gDailyFailedTasks removeObject:taskKey];
                        }
                    }
                    saveDailyTaskCache();
                }
            } else if (isTodoStatus) {
                // 服务端明确为待完成状态，必须清除旧版残留的已完成误缓存，但严禁清除失败缓存避免死循环重试
                @synchronized(self) {
                    if ([gDailyCompletedTasks containsObject:taskKey]) {
                        [gDailyCompletedTasks removeObject:taskKey];
                        saveDailyTaskCache();
                    }
                }
            } else if (isMultiIncomplete) {
                // 服务端仍为 TODO 时必须撤销旧版留下的误缓存：只要任务未彻底完结，必须立即从已完成缓存中主动撤销移除
                @synchronized(self) {
                    if ([gDailyCompletedTasks containsObject:taskKey]) {
                        [gDailyCompletedTasks removeObject:taskKey];
                        saveDailyTaskCache();
                    }
                }
            }
            
            // 如果今日已完成且服务端状态非待完成，坚决跳过，绝不重复排队
            if ([gDailyCompletedTasks containsObject:taskKey] && !isMultiIncomplete && !isTodoStatus && !isTaobaoTask) {
                continue;
            }
            
            // 针对失败任务，坚决跳过，杜绝重复排队重试导致死循环
            if ([gDailyFailedTasks containsObject:taskKey]) {
                continue;
            }

            // 阶梯大奖 (阶段宝箱 / 额外累计奖励) 优先提取处理，坚决排除出普通任务过滤体系并设置独立防死循环
            NSDictionary *groupInfo = [t[@"taskGroupInfo"] isKindOfClass:NSDictionary.class] ? t[@"taskGroupInfo"] : nil;
            NSString *groupType = groupInfo[@"taskGroupType"] ?: @"";
            NSString *taskMode = baseInfo[@"taskMode"] ?: t[@"taskMode"] ?: @"";
            BOOL isAccTask = ([groupType containsString:@"ACC"] || [groupType containsString:@"STAGE"] || [groupType containsString:@"LADDER"] ||
                              [taskMode containsString:@"ACC"] ||
                              [taskType hasPrefix:@"acc_"] || [taskType containsString:@"_acc_"] || [taskType containsString:@"ACC_"] || [taskType containsString:@"_ACC_"] ||
                              [taskType containsString:@"stage_"] || [taskType containsString:@"STAGE_"]);
            
            if (isAccTask) {
                NSString *accTaskKey = [NSString stringWithFormat:@"%@:%@", sceneCode, taskType];
                NSInteger accRetries = [gVitalityTaskRetryCounts[accTaskKey] integerValue];
                if (accRetries >= 3 || [gDailyFailedTasks containsObject:accTaskKey]) {
                    @synchronized(self) {
                        if (![gDailyFailedTasks containsObject:accTaskKey]) {
                            [gDailyFailedTasks addObject:accTaskKey];
                            saveDailyTaskCache();
                        }
                    }
                    continue;
                }
                
                NSInteger awardCount = [rights[@"awardCount"] integerValue];
                if (awardCount <= 0) {
                    awardCount = [bizInfo[@"awardCount"] integerValue];
                }
                if (awardCount <= 0) {
                    awardCount = [bizInfo[@"energy"] integerValue];
                }
                
                BOOL isAccTodo = [taskStatus isEqualToString:@"TODO"] || [taskStatus isEqualToString:@"INIT"];
                BOOL isProgressMet = (taskRequire > 0 && taskProgress >= taskRequire);
                // 严禁将未达成门槛的锁死阶段误判为可领（杜绝 (alreadyReceive == 0 && rightsTimes > 0) 导致的虚假死循环领奖）
                BOOL canClaim = (![taskStatus isEqualToString:@"RECEIVED"] &&
                                 ([taskStatus isEqualToString:@"FINISHED"] ||
                                  [taskStatus isEqualToString:@"CAN_RECEIVE"] ||
                                  [taskStatus isEqualToString:@"WAIT_AWARD"] ||
                                  [taskStatus isEqualToString:@"WAIT_RECEIVE"] ||
                                  (!isAccTodo && isProgressMet) ||
                                  (!isAccTodo && rightsTimesLimit > 0 && alreadyReceive < rightsTimesLimit && rightsTimes > alreadyReceive)));
                
                if (canClaim) {
                    BOOL alreadyInAccQueue = NO;
                    @synchronized(self) {
                        for (NSDictionary *q in vitalityTaskQueue) {
                            if ([q[@"taskType"] isEqualToString:taskType] && [q[@"sceneCode"] isEqualToString:sceneCode]) {
                                alreadyInAccQueue = YES;
                                break;
                            }
                        }
                    }
                    if (!alreadyInAccQueue) {
                        for (NSDictionary *q in accTasks) {
                            if ([q[@"taskType"] isEqualToString:taskType] && [q[@"sceneCode"] isEqualToString:sceneCode]) {
                                alreadyInAccQueue = YES;
                                break;
                            }
                        }
                    }
                    if (!alreadyInAccQueue) {
                        [accTasks addObject:@{
                            @"action": @"receive",
                            @"taskType": taskType,
                            @"sceneCode": sceneCode,
                            @"title": taskTitle.length ? taskTitle : [NSString stringWithFormat:@"今日累计阶梯奖励（%ldg）", (long)awardCount],
                            @"awardName": (awardCount > 0) ? [NSString stringWithFormat:@"%ldg 能量", (long)awardCount] : @"阶梯能量",
                            @"isAcc": @YES
                        }];
                    }
                }
                continue;
            }

            // 防死循环熔断：如果该任务已连续尝试多次未成功，加入失败缓存并跳过（防死循环）
            NSInteger vRetries = [gVitalityTaskRetryCounts[taskKey] integerValue];
            NSInteger maxRetries = hasPendingAward ? 3 : 2;
            if (vRetries >= maxRetries || [gDailyFailedTasks containsObject:taskKey]) {
                @synchronized(self) {
                    if (![gDailyFailedTasks containsObject:taskKey]) {
                        [gDailyFailedTasks addObject:taskKey];
                        saveDailyTaskCache();
                    }
                }
                NSString *moduleTag = @"森林寻宝/任务中心";
                if ([sceneCode containsString:@"OCEAN"] || [sceneCode containsString:@"RESCUE"]) {
                    moduleTag = @"神奇海洋";
                } else if ([sceneCode containsString:@"FARM"] || [sceneCode containsString:@"ORCHARD"] || [sceneCode isEqualToString:@"10021"] || [sceneCode isEqualToString:@"3646"] || [sceneCode hasPrefix:@"BABA_"]) {
                    moduleTag = @"芭芭农场";
                } else if ([sceneCode containsString:@"AIFISH"]) {
                    moduleTag = @"AI摸鱼";
                } else if ([sceneCode containsString:@"MONOPOLY"] || [sceneCode containsString:@"HSDWY"]) {
                    moduleTag = @"新版保护地";
                }
                [self recordStage:[NSString stringWithFormat:@"%@：任务 [%@] 连续多次尝试未成功，判定需端内手动交互，跳过本轮", moduleTag, taskTitle]];
                continue;
            }
            
            NSString *taskNode = baseInfo[@"taskNode"] ?: @"";
            if ([taskNode isEqualToString:@"PARENT"] && !hasPendingAward && ![taskStatus isEqualToString:@"FINISHED"]) {
                continue;
            }
            
            // 仅拦截未完成的高风险任务与不可通过RPC自动完成的任务（已完成待领奖的任务绝不拦截，允许自动领奖）
            if ([sceneCode containsString:@"FARM"] || [sceneCode containsString:@"ORCHARD"] || [sceneCode isEqualToString:@"10021"] || [sceneCode isEqualToString:@"3646"] || [sceneCode hasPrefix:@"BABA_"]) {
                if (!self.enableAutoFarmTasks || !self.farmBridge) continue;
                if ([taskType containsString:@"ORCHARD_POP"] || [taskType containsString:@"MIGRATE"] || [taskType containsString:@"POP_MIGRATE"]) continue;
                if (!hasPendingAward && ![taskStatus isEqualToString:@"FINISHED"] && ![taskStatus isEqualToString:@"CAN_RECEIVE"] && !isSafeFarmTask(taskType, taskTitle)) continue;
            } else if ([sceneCode containsString:@"RESCUE"] || [sceneCode containsString:@"OCEAN"]) {
                if (!self.enableAutoOceanTasks) continue;
                if (!hasPendingAward && ![taskStatus isEqualToString:@"FINISHED"] && ![taskStatus isEqualToString:@"CAN_RECEIVE"] && !isSafeOceanTask(taskType, taskTitle)) continue;
            } else if ([sceneCode containsString:@"AIFISH"]) {
                if (!self.enableAutoAIFish) continue;
                if (!hasPendingAward && ![taskStatus isEqualToString:@"FINISHED"] && ![taskStatus isEqualToString:@"CAN_RECEIVE"] && !isSafeAIFishTask(taskType, taskTitle)) continue;
            } else if ([sceneCode containsString:@"MONOPOLY"] || [sceneCode containsString:@"HSDWY"]) {
                if (!self.enableAutoPatrolNew) continue;
                if (!hasPendingAward && ![taskStatus isEqualToString:@"FINISHED"] && ![taskStatus isEqualToString:@"CAN_RECEIVE"] && !isSafeMonopolyTask(taskType, taskTitle)) continue;
            } else {
                if (!self.enableAutoRewardTasks) continue;
                if (!hasPendingAward && ![taskStatus isEqualToString:@"CAN_RECEIVE"]) {
                    if (![taskStatus isEqualToString:@"FINISHED"] && !isSafeRewardTask(taskType, taskTitle)) continue;
                }
            }
            
            NSString *prodPlayType = baseInfo[@"taskProdPlayType"] ?: @"";
            NSString *prodParamStr = baseInfo[@"prodPlayParam"];
            NSString *caQuotaId = nil;
            if ([prodParamStr isKindOfClass:NSString.class]) {
                NSData *pd = [prodParamStr dataUsingEncoding:NSUTF8StringEncoding];
                if (pd) {
                    NSDictionary *pObj = [NSJSONSerialization JSONObjectWithData:pd options:0 error:nil];
                    if (pObj[@"caQuotaId"]) caQuotaId = pObj[@"caQuotaId"];
                }
            }
            
            // 检查队列中是否已经排队
            BOOL alreadyQueued = NO;
            @synchronized(self) {
                for (NSDictionary *q in vitalityTaskQueue) {
                    if ([q[@"taskType"] isEqualToString:taskType] && [q[@"sceneCode"] isEqualToString:sceneCode]) {
                        alreadyQueued = YES;
                        break;
                    }
                }
            }
            if (alreadyQueued) continue;
            
            NSString *jumpUrl = baseInfo[@"taskJumpUrl"] ?: bizInfo[@"taskJumpUrl"] ?: bizInfo[@"jumpUrl"] ?: bizInfo[@"targetUrl"] ?: t[@"taskJumpUrl"] ?: t[@"jumpUrl"] ?: t[@"targetUrl"] ?: bizInfo[@"url"] ?: bizInfo[@"actionUrl"] ?: bizInfo[@"h5Url"] ?: bizInfo[@"taskSchema"] ?: bizInfo[@"schema"] ?: bizInfo[@"jumpScheme"] ?: @"";
            if (![jumpUrl isKindOfClass:NSString.class]) jumpUrl = @"";
            
            NSInteger explicitBrowseSec = extractTaskBrowseSeconds(t ?: baseInfo, bizInfo, taskTitle);
            if (isTaobaoTask && explicitBrowseSec < 6) {
                explicitBrowseSec = 6;
            }
            BOOL requiresTimedBrowse = (explicitBrowseSec > 0);
            
            if ([prodPlayType isEqualToString:@"EXCHANGE_ASSET"] || [taskType containsString:@"VITALITY_EXCHANGE"] || [taskType isEqualToString:@"NORMAL_DRAW_EXCHANGE_VITALITY"]) {
                [newlyParsedTasks addObject:@{
                    @"action": @"exchange",
                    @"taskType": taskType,
                    @"sceneCode": sceneCode,
                    @"title": taskTitle,
                    @"caQuotaId": caQuotaId ?: @""
                }];
            } else if (hasPendingAward) {
                [newlyParsedTasks addObject:@{
                    @"action": @"receive",
                    @"taskType": taskType,
                    @"sceneCode": sceneCode,
                    @"title": taskTitle,
                    @"awardName": awardName,
                    @"isMultiStage": @(isMultiIncomplete)
                }];
            } else if (isTodoStatus || (rightsTimesLimit > 0 && rightsTimes < rightsTimesLimit) || isMultiIncomplete) {
                if (requiresTimedBrowse) {
                    // 仅对明确要求倒计时/停留指定时长的任务进行定时停留
                    [newlyParsedTasks addObject:@{
                        @"action": @"browse",
                        @"taskType": taskType,
                        @"sceneCode": sceneCode,
                        @"title": taskTitle,
                        @"awardName": awardName,
                        @"jumpUrl": jumpUrl,
                        @"browseSeconds": @(explicitBrowseSec),
                        @"isMultiStage": @(isMultiIncomplete)
                    }];
                } else {
                    // 常规逛一逛/浏览/去完成等即时任务，直接提交完成并领奖，无需停留15秒
                    [newlyParsedTasks addObject:@{
                        @"action": @"finish",
                        @"taskType": taskType,
                        @"sceneCode": sceneCode,
                        @"title": taskTitle,
                        @"jumpUrl": jumpUrl,
                        @"isMultiStage": @(isMultiIncomplete)
                    }];
                    [newlyParsedTasks addObject:@{
                        @"action": @"receive",
                        @"taskType": taskType,
                        @"sceneCode": sceneCode,
                        @"title": taskTitle,
                        @"awardName": awardName,
                        @"isMultiStage": @(isMultiIncomplete)
                    }];
                }
            }
        }
        
        BOOL shouldStartLoop = NO;
        NSUInteger totalQueuedCount = 0;
        @synchronized(self) {
            BOOL isWithinActive = isWithinTaskActiveHours();
            if (newlyParsedTasks.count > 0 && isWithinActive) {
                BOOL isMainVitality = [newlyParsedTasks.firstObject[@"sceneCode"] isEqualToString:@"ANTFOREST_VITALITY_TASK"];
                if (isMainVitality && vitalityTaskQueue.count > 0) {
                    // 主线领奖励任务优先插入队列前方执行（若队首为每日签到，保持签到在第 0 位优先执行）
                    NSInteger insertIdx = 0;
                    if ([vitalityTaskQueue.firstObject[@"action"] isEqualToString:@"sign"]) {
                        insertIdx = 1;
                    }
                    NSIndexSet *indexes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(insertIdx, newlyParsedTasks.count)];
                    [vitalityTaskQueue insertObjects:newlyParsedTasks atIndexes:indexes];
                } else {
                    [vitalityTaskQueue addObjectsFromArray:newlyParsedTasks];
                }
            }
            if (accTasks.count > 0 && isWithinActive) {
                [vitalityTaskQueue addObjectsFromArray:accTasks];
            }
            
            // 核心防抢跑保障：若开启领奖励且今日尚未完成签到，必须确保签到任务位于第 0 位优先执行（零点后即可自动签到）
            if (self.enableAutoRewardTasks && ![gDailyCompletedTasks containsObject:@"SIGN_TODAY"]) {
                BOOL hasSignAction = NO;
                for (NSDictionary *q in vitalityTaskQueue) {
                    NSString *act = q[@"action"];
                    if ([act isEqualToString:@"sign"]) { hasSignAction = YES; break; }
                }
                if (!hasSignAction) {
                    NSString *validSignId = [signVO[@"signId"] isKindOfClass:NSString.class] ? signVO[@"signId"] : @"";
                    [self recordStage:@"领奖励：检测到今日尚未签到，优先执行能量签到以激活今日累计阶梯奖励..."];
                    [vitalityTaskQueue insertObject:@{
                        @"action": @"sign",
                        @"signId": validSignId ?: @"",
                        @"sceneCode": @"ANTFOREST_ENERGY_TASK_SIGN",
                        @"title": @"每日签到",
                        @"awardName": @"能量"
                    } atIndex:0];
                }
            }
            
            totalQueuedCount = vitalityTaskQueue.count;
            if (totalQueuedCount > 0 && !vitalityTaskRunning) {
                if (sVitalityAutoRefreshRounds >= 2) {
                    vitalityTaskRunning = NO;
                    [vitalityTaskQueue removeAllObjects];
                    return;
                }
                shouldStartLoop = YES;
                vitalityTaskRunning = YES;
            }
        }
        
        if (shouldStartLoop) {
            NSString *targetScene = newlyParsedTasks.firstObject[@"sceneCode"] ?: (accTasks.firstObject[@"sceneCode"] ?: respSceneCode);
            NSString *planningPrefix = @"领奖励与森林寻宝";
            if ([targetScene containsString:@"RESCUE"] || [targetScene containsString:@"OCEAN"]) {
                planningPrefix = @"神奇海洋";
            } else if ([targetScene containsString:@"AIFISH"]) {
                planningPrefix = @"AI摸鱼";
            } else if ([targetScene containsString:@"FARM"] || [targetScene containsString:@"ORCHARD"]) {
                planningPrefix = @"芭芭农场";
            } else if ([targetScene containsString:@"MONOPOLY"] || [targetScene containsString:@"HSDWY"]) {
                planningPrefix = @"新版保护地";
            } else if ([targetScene containsString:@"DRAW"] || [targetScene containsString:@"LOTTERY"]) {
                planningPrefix = @"森林寻宝";
            }
            [self recordStage:[NSString stringWithFormat:@"%@：规划 %lu 项待完成与领奖操作", planningPrefix, (unsigned long)totalQueuedCount]];
            [self executeNextVitalityTask];
        } else if (totalQueuedCount == 0 && !vitalityTaskRunning && allTaskList.count > 0) {
            NSLog(@"[AntForestPort] %@：当前无待领待做任务", respSceneCode);
        }
    } @catch (NSException *e) {
        NSLog(@"[AntForestPort][VitalityTask] Exception in handleVitalityTaskListResponse: %@", e);
    }
}

-(void)handleOceanTaskListResponse:(id)args {
    if (![args isKindOfClass:NSDictionary.class]) return;
    @try {
        initDailyTaskCache();
        NSDictionary *data = args;
        if (data[@"resData"] && [data[@"resData"] isKindOfClass:NSDictionary.class]) {
            data = data[@"resData"];
        }
        NSArray *oceanList = [data[@"antOceanTaskVOList"] isKindOfClass:NSArray.class] ? data[@"antOceanTaskVOList"] : nil;
        if (!oceanList.count) return;
        
        NSLog(@"\n🌊 [神奇海洋·任务探测] ══════════════ 共发现 %lu 个海洋任务 ══════════════", (unsigned long)oceanList.count);
        [self recordStage:[NSString stringWithFormat:@"神奇海洋：探测到 %lu 个任务，正在解析列表...", (unsigned long)oceanList.count]];
        
        NSMutableArray<NSDictionary *> *tasksToQueue = [NSMutableArray array];
        
        for (NSUInteger idx = 0; idx < oceanList.count; idx++) {
            id t = oceanList[idx];
            if (![t isKindOfClass:NSDictionary.class]) continue;
            
            NSString *taskType = [t[@"taskType"] isKindOfClass:NSString.class] ? t[@"taskType"] : @"";
            NSString *sceneCode = [t[@"sceneCode"] isKindOfClass:NSString.class] ? t[@"sceneCode"] : @"ANTOCEAN_TASK";
            NSString *taskStatus = [t[@"taskStatus"] isKindOfClass:NSString.class] ? t[@"taskStatus"] : @"";
            NSString *awardType = [t[@"awardType"] isKindOfClass:NSString.class] ? t[@"awardType"] : @"";
            NSString *awardCount = [NSString stringWithFormat:@"%@", t[@"awardCount"] ?: @"1"];
            
            NSDictionary *bizInfo = nil;
            id rawBiz = t[@"bizInfo"];
            if ([rawBiz isKindOfClass:NSDictionary.class]) {
                bizInfo = rawBiz;
            } else if ([rawBiz isKindOfClass:NSString.class]) {
                NSData *bd = [(NSString *)rawBiz dataUsingEncoding:NSUTF8StringEncoding];
                if (bd) bizInfo = [NSJSONSerialization JSONObjectWithData:bd options:0 error:nil];
            }
            
            NSString *taskTitle = bizInfo[@"taskTitle"] ?: bizInfo[@"title"] ?: taskType;
            NSString *taskDesc = bizInfo[@"taskDesc"] ?: bizInfo[@"desc"] ?: @"";
            NSString *taskJumpBtn = bizInfo[@"taskJumpBtn"] ?: @"";
            
            NSString *awardDesc = [awardType isEqualToString:@"RIGHTS"] ? [NSString stringWithFormat:@"拼图碎片x%@", awardCount] : [NSString stringWithFormat:@"%@x%@", awardType, awardCount];
            
            // 逐条控制台格式化打印，杜绝系统底层单行超长截断
            NSLog(@"🌊 [海洋任务 %lu/%lu] 标题:【%@】| 标识: %@ | 状态: %@ | 按钮:【%@】| 奖励: %@ | 描述: %@",
                  (unsigned long)(idx + 1), (unsigned long)oceanList.count,
                  taskTitle, taskType, taskStatus, taskJumpBtn, awardDesc, taskDesc);
            
            [self recordProbeLog:[NSString stringWithFormat:@"[神奇海洋 %lu/%lu] 标题:%@ | 标识:%@ | 状态:%@ | 按钮:%@ | 奖励:%@",
                                  (unsigned long)(idx + 1), (unsigned long)oceanList.count,
                                  taskTitle, taskType, taskStatus, taskJumpBtn, awardDesc]];
            
            if (!self.enableAutoOceanTasks) continue;
            if (!self.oceanBridge || self.oceanBridge == self.jsBridge) continue;
            
            NSString *taskKey = [NSString stringWithFormat:@"%@:%@", sceneCode, taskType];
            BOOL isMultiIncomplete = isMultiStageIncompleteTask(taskTitle, 0, 0) || isMultiStageTaskFromDict(t, nil, bizInfo);
            
            BOOL canClaim = [taskStatus isEqualToString:@"FINISHED"] ||
                            [taskStatus isEqualToString:@"CAN_RECEIVE"] ||
                            ([taskJumpBtn containsString:@"领"] && ![taskStatus isEqualToString:@"RECEIVED"]);
            
            if (canClaim) {
                @synchronized(self) {
                    if ([gDailyCompletedTasks containsObject:taskKey]) {
                        [gDailyCompletedTasks removeObject:taskKey];
                    }
                    if ([gDailyFailedTasks containsObject:taskKey]) {
                        [gDailyFailedTasks removeObject:taskKey];
                    }
                    saveDailyTaskCache();
                }
                [tasksToQueue addObject:@{
                    @"action": @"receive",
                    @"taskType": taskType,
                    @"sceneCode": sceneCode,
                    @"title": taskTitle,
                    @"awardName": [awardType isEqualToString:@"RIGHTS"] ? @"拼图碎片" : @"海洋奖励",
                    @"scenePrefix": @"神奇海洋",
                    @"isMultiStage": @(isMultiIncomplete)
                }];
                continue;
            }
            
            NSDictionary *rights = [t[@"taskRights"] isKindOfClass:NSDictionary.class] ? t[@"taskRights"] : nil;
            NSInteger alreadyReceive = [rights[@"alreadyReceiveAwardCount"] integerValue];
            NSInteger rightsTimesLimit = [rights[@"rightsTimesLimit"] integerValue];
            NSInteger rightsTimes = [rights[@"rightsTimes"] integerValue];
            if (rightsTimesLimit <= 0) rightsTimesLimit = [t[@"rightsTimesLimit"] integerValue];
            if (rightsTimes <= 0) rightsTimes = [t[@"rightsTimes"] integerValue];
            if (alreadyReceive <= 0) {
                id ext = t[@"extend"];
                if ([ext isKindOfClass:NSString.class] && [ext containsString:@"alreadyReceiveAwardCount"]) {
                    NSDictionary *ed = [NSJSONSerialization JSONObjectWithData:[ext dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
                    alreadyReceive = [ed[@"alreadyReceiveAwardCount"] integerValue];
                }
            }
            BOOL isDoneAll = !isMultiIncomplete && ([taskStatus isEqualToString:@"RECEIVED"] || (rightsTimesLimit > 0 && rightsTimes >= rightsTimesLimit));
            if (isDoneAll) {
                @synchronized(self) {
                    [gDailyCompletedTasks addObject:taskKey];
                    saveDailyTaskCache();
                }
                continue;
            }
            
            if ([taskStatus isEqualToString:@"TODO"] || isMultiIncomplete) {
                @synchronized(self) {
                    if ([gDailyCompletedTasks containsObject:taskKey]) {
                        [gDailyCompletedTasks removeObject:taskKey];
                        saveDailyTaskCache();
                    }
                }
            }
            if ([gDailyFailedTasks containsObject:taskKey]) {
                continue;
            }
            if ([gDailyCompletedTasks containsObject:taskKey] && !isMultiIncomplete) {
                continue;
            }
            
            if ([taskStatus isEqualToString:@"TODO"]) {
                if (isSafeOceanTask(taskType, taskTitle)) {
                    NSInteger browseSec = extractTaskBrowseSeconds(t, bizInfo, taskTitle);
                    if (browseSec > 0) {
                        NSString *jumpUrl = bizInfo[@"targetUrl"] ?: bizInfo[@"jumpUrl"] ?: @"";
                        [tasksToQueue addObject:@{
                            @"action": @"browse",
                            @"taskType": taskType,
                            @"sceneCode": sceneCode,
                            @"title": taskTitle,
                            @"awardName": [awardType isEqualToString:@"RIGHTS"] ? @"拼图碎片" : @"海洋奖励",
                            @"scenePrefix": @"神奇海洋",
                            @"browseSeconds": @(browseSec),
                            @"jumpUrl": jumpUrl,
                            @"isMultiStage": @(isMultiIncomplete)
                        }];
                    } else {
                        [tasksToQueue addObject:@{
                            @"action": @"finish",
                            @"taskType": taskType,
                            @"sceneCode": sceneCode,
                            @"title": taskTitle,
                            @"isMultiStage": @(isMultiIncomplete)
                        }];
                        [tasksToQueue addObject:@{
                            @"action": @"receive",
                            @"taskType": taskType,
                            @"sceneCode": sceneCode,
                            @"title": taskTitle,
                            @"awardName": [awardType isEqualToString:@"RIGHTS"] ? @"拼图碎片" : @"海洋奖励",
                            @"scenePrefix": @"神奇海洋",
                            @"isMultiStage": @(isMultiIncomplete)
                        }];
                    }
                } else {
                    NSLog(@"🌊 [神奇海洋] 任务【%@】属于互动型/答题/连续签到/外部游戏任务，不支持直接RPC完成，已自动跳过", taskTitle);
                }
            }
        }
        NSLog(@"🌊 [神奇海洋·任务探测] ══════════════════════════════════════════════\n");
        
        if (!self.enableAutoOceanTasks) return;
        if (!tasksToQueue.count) {
            [self recordStage:@"神奇海洋：当前所有有效海洋任务与拼图已全部领取完毕"];
            return;
        }
        
        BOOL shouldStartLoop = NO;
        NSUInteger totalQueued = 0;
        @synchronized(self) {
            if (!vitalityTaskQueue) vitalityTaskQueue = [NSMutableArray array];
            for (NSDictionary *task in tasksToQueue) {
                NSString *tk = [NSString stringWithFormat:@"%@:%@:%@", task[@"sceneCode"], task[@"taskType"], task[@"action"]];
                BOOL alreadyInQueue = NO;
                for (NSDictionary *q in vitalityTaskQueue) {
                    NSString *qk = [NSString stringWithFormat:@"%@:%@:%@", q[@"sceneCode"], q[@"taskType"], q[@"action"]];
                    if ([qk isEqualToString:tk]) { alreadyInQueue = YES; break; }
                }
                if (!alreadyInQueue) {
                    [vitalityTaskQueue addObject:task];
                }
            }
            totalQueued = vitalityTaskQueue.count;
            if (!vitalityTaskRunning && totalQueued > 0) {
                vitalityTaskRunning = YES;
                shouldStartLoop = YES;
            }
        }
        if (shouldStartLoop) {
            [self recordStage:[NSString stringWithFormat:@"神奇海洋：规划 %lu 项待完成与领拼图操作", (unsigned long)tasksToQueue.count]];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(400 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                [self executeNextVitalityTask];
            });
        }
    } @catch (NSException *e) {
        NSLog(@"[AntForestPort][OceanTask] Exception in handleOceanTaskListResponse: %@", e);
    }
}

- (void)executeFarmScriptOnWebView:(NSString *)js {
    if (!js.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableSet *targets = [NSMutableSet set];
        SEL evalSel = @selector(evaluateJavaScript:completionHandler:);
        
        // 1. 如果有绑定的 farmBridge，且不是森林主页 bridge，提取其 webView
        id fb = self.farmBridge;
        if (fb && fb != self.jsBridge) {
            if ([fb respondsToSelector:@selector(contentView)]) {
                id cv = [fb contentView];
                if (cv && [cv respondsToSelector:evalSel]) [targets addObject:cv];
                if ([cv respondsToSelector:@selector(webView)]) {
                    id wv = ((id (*)(id, SEL))objc_msgSend)(cv, @selector(webView));
                    if (wv && [wv respondsToSelector:evalSel]) [targets addObject:wv];
                }
            }
            if ([fb respondsToSelector:@selector(webView)]) {
                id wv = ((id (*)(id, SEL))objc_msgSend)(fb, @selector(webView));
                if (wv && [wv respondsToSelector:evalSel]) [targets addObject:wv];
            }
        }
        
        // 2. 如果 targets 为空，仅扫描当前显示中的农场 WKWebView（严禁扫描任何森林主页或包含 60000002/home.html 的 WebView）
        if (targets.count == 0) {
            NSArray *windows = [UIApplication sharedApplication].windows;
            for (UIWindow *win in windows) {
                if (!win) continue;
                NSMutableArray *stack = [NSMutableArray arrayWithObject:win];
                while (stack.count > 0) {
                    UIView *v = stack.lastObject;
                    [stack removeLastObject];
                    if ([v respondsToSelector:evalSel]) {
                        if (!v.hidden && v.alpha > 0.01) {
                            // 严格核查 URL：如果是森林主页，坚决排除
                            if ([v respondsToSelector:@selector(URL)]) {
                                NSURL *u = ((id (*)(id, SEL))objc_msgSend)(v, @selector(URL));
                                if (u) {
                                    NSString *us = u.absoluteString.lowercaseString;
                                    if ([us containsString:@"60000002"] || [us containsString:@"180020010001247580"] || [us containsString:@"home.html"] || [us containsString:@"66666674"] || [us containsString:@"antfarm"] || [us containsString:@"manor"] || [us containsString:@"2017090512380701"]) {
                                        continue;
                                    }
                                }
                            }
                            [targets addObject:v];
                        }
                    }
                    [stack addObjectsFromArray:v.subviews];
                }
            }
        }
        
        for (id target in targets) {
            if ([target respondsToSelector:evalSel]) {
                @try {
                    ((void (*)(id, SEL, NSString *, void (^)(id, NSError *)))objc_msgSend)(target, evalSel, js, nil);
                } @catch (NSException *e) {}
            }
        }
    });
}

- (void)openFarmTaskPanelOnWebView {
    // 纯静默 RPC 驱动，禁用 DOM 模拟点击，彻底避免误触农场外链与跳转
}

- (void)claimAllVisibleFarmRewardsOnWebView {
    // 纯静默 RPC 驱动，禁用 DOM 模拟点击，彻底避免误触农场外链与跳转
}

- (void)executeMonopolyScriptOnWebView:(NSString *)js {
    if (!js.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableSet *targets = [NSMutableSet set];
        SEL evalSel = @selector(evaluateJavaScript:completionHandler:);
        
        // 1. 如果有绑定的 monopolyBridge，且不是森林主页 bridge，提取其 webView
        id mb = self.monopolyBridge;
        if (mb && mb != self.jsBridge) {
            if ([mb respondsToSelector:@selector(contentView)]) {
                id cv = [mb contentView];
                if (cv && [cv respondsToSelector:evalSel]) [targets addObject:cv];
                if ([cv respondsToSelector:@selector(webView)]) {
                    id wv = ((id (*)(id, SEL))objc_msgSend)(cv, @selector(webView));
                    if (wv && [wv respondsToSelector:evalSel]) [targets addObject:wv];
                }
            }
            if ([mb respondsToSelector:@selector(webView)]) {
                id wv = ((id (*)(id, SEL))objc_msgSend)(mb, @selector(webView));
                if (wv && [wv respondsToSelector:evalSel]) [targets addObject:wv];
            }
        }
        
        // 2. 如果 targets 为空，仅扫描当前显示中的保护地大富翁 WKWebView（排除任何森林主页或包含 60000002/home.html 的 WebView）
        if (targets.count == 0) {
            NSArray *windows = [UIApplication sharedApplication].windows;
            for (UIWindow *win in windows) {
                if (!win) continue;
                NSMutableArray *stack = [NSMutableArray arrayWithObject:win];
                while (stack.count > 0) {
                    UIView *v = stack.lastObject;
                    [stack removeLastObject];
                    if ([v respondsToSelector:evalSel]) {
                        if (!v.hidden && v.alpha > 0.01) {
                            if ([v respondsToSelector:@selector(URL)]) {
                                NSURL *u = ((id (*)(id, SEL))objc_msgSend)(v, @selector(URL));
                                if (u) {
                                    NSString *us = u.absoluteString.lowercaseString;
                                    if ([us containsString:@"60000002"] || [us containsString:@"180020010001247580"] || [us containsString:@"home.html"]) {
                                        continue;
                                    }
                                    if ([us containsString:@"180020010001293606"] || [us containsString:@"2060090000398301"] || [us containsString:@"monopoly"] || [us containsString:@"hsdwy"] || [us containsString:@"patrol"] || [us containsString:@"guardian"]) {
                                        [targets addObject:v];
                                    }
                                }
                            }
                        }
                    }
                    [stack addObjectsFromArray:v.subviews];
                }
            }
        }
        
        for (id target in targets) {
            if ([target respondsToSelector:evalSel]) {
                @try {
                    ((void (*)(id, SEL, NSString *, void (^)(id, NSError *)))objc_msgSend)(target, evalSel, js, nil);
                } @catch (NSException *e) {}
            }
        }
    });
}

- (void)openMonopolyTaskPanelOnWebView {
    // 纯静默 RPC 驱动，禁用 DOM 模拟点击，彻底避免误触外链与跳转
}

- (void)claimAllVisibleMonopolyRewardsOnWebView {
    // 纯静默 RPC 驱动，禁用 DOM 模拟点击，彻底避免误触外链与跳转
}

- (void)executeAIFishScriptOnWebView:(NSString *)js {
    if (!js.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableSet *targets = [NSMutableSet set];
        SEL evalSel = @selector(evaluateJavaScript:completionHandler:);
        id bridge = self.aiFishBridge;
        if (bridge && bridge != self.jsBridge) {
            if ([bridge respondsToSelector:@selector(contentView)]) {
                id cv = [bridge contentView];
                if (cv && [cv respondsToSelector:evalSel]) [targets addObject:cv];
                if ([cv respondsToSelector:@selector(webView)]) {
                    id wv = ((id (*)(id, SEL))objc_msgSend)(cv, @selector(webView));
                    if (wv && [wv respondsToSelector:evalSel]) [targets addObject:wv];
                }
            }
            if ([bridge respondsToSelector:@selector(webView)]) {
                id wv = ((id (*)(id, SEL))objc_msgSend)(bridge, @selector(webView));
                if (wv && [wv respondsToSelector:evalSel]) [targets addObject:wv];
            }
        }
        if (targets.count == 0) {
            NSArray *windows = [UIApplication sharedApplication].windows;
            for (UIWindow *win in windows) {
                if (!win) continue;
                NSMutableArray *stack = [NSMutableArray arrayWithObject:win];
                while (stack.count > 0) {
                    UIView *v = stack.lastObject;
                    [stack removeLastObject];
                    if ([v respondsToSelector:evalSel]) {
                        if (!v.hidden && v.alpha > 0.01) {
                            if ([v respondsToSelector:@selector(URL)]) {
                                NSURL *u = ((id (*)(id, SEL))objc_msgSend)(v, @selector(URL));
                                if (u) {
                                    NSString *us = u.absoluteString.lowercaseString;
                                    if ([us containsString:@"60000002"] || [us containsString:@"home.html"]) continue;
                                    if ([us containsString:@"180020010001290531"] || [us containsString:@"aifish"] || [us containsString:@"antaifish"]) {
                                        [targets addObject:v];
                                    }
                                }
                            }
                        }
                    }
                    [stack addObjectsFromArray:v.subviews];
                }
            }
        }
        for (id target in targets) {
            if ([target respondsToSelector:evalSel]) {
                @try {
                    ((void (*)(id, SEL, NSString *, void (^)(id, NSError *)))objc_msgSend)(target, evalSel, js, nil);
                } @catch (NSException *e) {}
            }
        }
    });
}

- (void)claimAllVisibleAIFishRewardsOnWebView {
    // 纯静默 RPC 驱动，禁用 DOM 模拟点击，彻底避免误触外链与跳转
}

- (void)executeRewardTaskScriptOnWebView:(NSString *)js {
    if (!js.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableSet *targets = [NSMutableSet set];
        SEL evalSel = @selector(evaluateJavaScript:completionHandler:);
        NSMutableArray *bridges = [NSMutableArray array];
        if (self.rewardTaskBridge) [bridges addObject:self.rewardTaskBridge];
        if (self.jsBridge && ![bridges containsObject:self.jsBridge]) [bridges addObject:self.jsBridge];
        for (id bridge in bridges) {
            if ([bridge respondsToSelector:@selector(contentView)]) {
                id cv = [bridge contentView];
                if (cv && [cv respondsToSelector:evalSel]) [targets addObject:cv];
                if ([cv respondsToSelector:@selector(webView)]) {
                    id wv = ((id (*)(id, SEL))objc_msgSend)(cv, @selector(webView));
                    if (wv && [wv respondsToSelector:evalSel]) [targets addObject:wv];
                }
            }
            if ([bridge respondsToSelector:@selector(webView)]) {
                id wv = ((id (*)(id, SEL))objc_msgSend)(bridge, @selector(webView));
                if (wv && [wv respondsToSelector:evalSel]) [targets addObject:wv];
            }
        }
        if (targets.count == 0) {
            NSArray *windows = [UIApplication sharedApplication].windows;
            for (UIWindow *win in windows) {
                if (!win) continue;
                NSMutableArray *stack = [NSMutableArray arrayWithObject:win];
                while (stack.count > 0) {
                    UIView *v = stack.lastObject;
                    [stack removeLastObject];
                    if ([v respondsToSelector:evalSel]) {
                        if (!v.hidden && v.alpha > 0.01) {
                            if ([v respondsToSelector:@selector(URL)]) {
                                NSURL *u = ((id (*)(id, SEL))objc_msgSend)(v, @selector(URL));
                                if (u) {
                                    NSString *us = u.absoluteString.lowercaseString;
                                    if ([us containsString:@"180020010001247580"] || [us containsString:@"vitality"] || [us containsString:@"reward"] || [us containsString:@"60000002"] || [us containsString:@"home.html"]) {
                                        [targets addObject:v];
                                    }
                                }
                            }
                        }
                    }
                    [stack addObjectsFromArray:v.subviews];
                }
            }
        }
        for (id target in targets) {
            if ([target respondsToSelector:evalSel]) {
                @try {
                    ((void (*)(id, SEL, NSString *, void (^)(id, NSError *)))objc_msgSend)(target, evalSel, js, nil);
                } @catch (NSException *e) {}
            }
        }
    });
}

- (void)claimAllVisibleRewardTaskRewardsOnWebView {
    // 纯静默 RPC 驱动，彻底禁用 DOM 模拟点击，从根本上消除页面跳转与外链循环风险
}

- (void)collectFarmChickenManure {
    static NSTimeInterval lastChickenCollectTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - lastChickenCollectTime < 10) return;
    lastChickenCollectTime = now;
    
    [self recordStage:@"芭芭农场：正在领取庄园小鸡生产的肥料..."];
    PSDJsBridge *bridge = (self.farmBridge && self.farmBridge != self.jsBridge) ? self.farmBridge : nil;
    if (bridge) {
        NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)(now * 1000)];
        NSString *randNum = [AntForestManager getNumberRandom:15];
        NSString *url = [self effectiveUrlForBridge:bridge] ?: [self effectiveUrlForSceneCode:@"BABA_FARM"];
        
        NSString *arg1 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.orchard.manure.collect\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"source\":\"alipayfarm\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, randNum];
        [bridge _doFlushMessageQueue:arg1 url:url];
    }
}

- (void)signFarmDailyWithKey:(NSString *)signKey {
    static NSString *lastSignKey = nil;
    if ([lastSignKey isEqualToString:signKey]) return;
    lastSignKey = [signKey copy];
    
    [self recordStage:[NSString stringWithFormat:@"芭芭农场：正在执行每日连续签到（%@）...", signKey ?: @"今日"]];
}

#pragma mark - 蚂蚁庄园全自动模块

- (void)executeManorScriptOnWebView:(NSString *)js {
    if (!js.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableSet *targets = [NSMutableSet set];
        SEL evalSel = @selector(evaluateJavaScript:completionHandler:);
        
        // 1. 如果有绑定的 manorBridge，提取其 webView
        id mb = self.manorBridge;
        if (mb && mb != self.jsBridge) {
            if ([mb respondsToSelector:@selector(contentView)]) {
                id cv = [mb contentView];
                if (cv && [cv respondsToSelector:evalSel]) [targets addObject:cv];
                if ([cv respondsToSelector:@selector(webView)]) {
                    id wv = ((id (*)(id, SEL))objc_msgSend)(cv, @selector(webView));
                    if (wv && [wv respondsToSelector:evalSel]) [targets addObject:wv];
                }
            }
            if ([mb respondsToSelector:@selector(webView)]) {
                id wv = ((id (*)(id, SEL))objc_msgSend)(mb, @selector(webView));
                if (wv && [wv respondsToSelector:evalSel]) [targets addObject:wv];
            }
        }
        
        // 2. 如果 targets 为空，扫描当前显示中的庄园 WKWebView
        if (targets.count == 0) {
            NSArray *windows = [UIApplication sharedApplication].windows;
            for (UIWindow *win in windows) {
                if (!win) continue;
                NSMutableArray *stack = [NSMutableArray arrayWithObject:win];
                while (stack.count > 0) {
                    UIView *v = stack.lastObject;
                    [stack removeLastObject];
                    if ([v respondsToSelector:evalSel]) {
                        if (!v.hidden && v.alpha > 0.01) {
                            if ([v respondsToSelector:@selector(URL)]) {
                                NSURL *u = ((id (*)(id, SEL))objc_msgSend)(v, @selector(URL));
                                if (u) {
                                    NSString *us = u.absoluteString.lowercaseString;
                                    if ([us containsString:@"60000002"] || [us containsString:@"180020010001247580"] || [us containsString:@"home.html"]) {
                                        continue;
                                    }
                                    if ([us containsString:@"66666674"] || [us containsString:@"2017090512380701"] || [us containsString:@"antfarm"] || [us containsString:@"manor"]) {
                                        [targets addObject:v];
                                    }
                                }
                            }
                        }
                    }
                    [stack addObjectsFromArray:v.subviews];
                }
            }
        }
        
        for (id target in targets) {
            if ([target respondsToSelector:evalSel]) {
                @try {
                    ((void (*)(id, SEL, NSString *, void (^)(id, NSError *)))objc_msgSend)(target, evalSel, js, ^(__unused id res, __unused NSError *err) {
                    });
                } @catch (NSException *e) {}
            }
        }
    });
}

- (void)signManorDaily {
    if (!self.enableAutoManor) return;
    
    NSString *today = getCurrentDateString();
    NSString *lastSignDate = [[NSUserDefaults standardUserDefaults] stringForKey:@"lastManorSignDate"];
    if ([lastSignDate isEqualToString:today]) {
        return;
    }
    
    [self recordStage:@"蚂蚁庄园：检测到今日未签到，正在自动签到领 180g 饲料..."];
    
    PSDJsBridge *bridge = (self.manorBridge && self.manorBridge != self.jsBridge) ? self.manorBridge : nil;
    if (bridge) {
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)(now * 1000)];
        NSString *randNum = [AntForestManager getNumberRandom:15];
        NSString *url = self.manorH5Url ?: @"https://66666674.h5app.alipay.com/www/index.html";
        
        // 真实标准庄园签到底层 RPC: com.alipay.antfarm.sign
        NSString *signArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.sign\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"H5\",\"version\":\"1.8.2302070202.46\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, randNum];
        [bridge _doFlushMessageQueue:signArg url:url];
    }
    
    [self executeManorScriptOnWebView:@"(()=>{try{"
     "function triggerClick(el){"
     "  if(!el)return false;"
     "  try{"
     "    const r=el.getBoundingClientRect();"
     "    if(r.width===0&&r.height===0)return false;"
     "    const x=r.left+r.width/2,y=r.top+r.height/2;"
     "    const opts={bubbles:true,cancelable:true,view:window,clientX:x,clientY:y};"
     "    try{el.dispatchEvent(new PointerEvent('pointerdown',opts));}catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('mousedown',opts));}catch(e){}"
     "    try{"
     "      const t=new Touch({identifier:Date.now(),target:el,clientX:x,clientY:y});"
     "      el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[t],targetTouches:[t],changedTouches:[t]}));"
     "    }catch(e){}"
     "    try{el.dispatchEvent(new PointerEvent('pointerup',opts));}catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('mouseup',opts));}catch(e){}"
     "    try{"
     "      const te=new Touch({identifier:Date.now(),target:el,clientX:x,clientY:y});"
     "      el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[te]}));"
     "    }catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('click',opts));}catch(e){}"
     "    try{el.click();}catch(e){}"
     "    return true;"
     "  }catch(e){try{el.click();return true;}catch(e2){return false;}}"
     "}"
     "const all=Array.from(document.querySelectorAll('*'));"
     "for(const el of all){"
     "  if(el.tagName==='A' || (el.closest && el.closest('a[href]'))) continue;"
     "  const t=(el.innerText||el.textContent||'').trim();"
     "  if(t==='签到'||t==='点击签到'||t==='今日签到'||t==='签到领饲料'||t.includes('签到领饲料')){"
     "    triggerClick(el.closest('button,[role=\"button\"],[class*=\"btn\"]')||el);"
     "    break;"
     "  }"
     "}"
     "setTimeout(()=>{"
     "  const close=Array.from(document.querySelectorAll('button,[role=\"button\"],[class*=\"btn\"],div,span'))"
     "    .find(c=>{"
     "      if(c.tagName==='A' || (c.closest && c.closest('a[href]'))) return false;"
     "      const ct=(c.innerText||'').trim();"
     "      return ct==='开心收下'||ct==='我知道了'||ct==='收下饲料'||ct==='好的';"
     "    });"
     "  if(close)triggerClick(close);"
     "},600);"
     "}catch(e){console.error(e);}})();"];
}

- (void)executeClassroomAnswerScript {
    [self executeManorScriptOnWebView:@"(()=>{try{"
     "const QA_DB=["
     "{k:'退避三舍',a:'九十里'},{k:'烂醉如泥',a:'一种虫子'},{k:'宣笔',a:'宣州'},{k:'秋冻',a:'并不是'},"
     "{k:'企鹅有翅膀',a:'有'},{k:'奶皮',a:'脂肪和蛋白质'},{k:'猫咪胡子',a:'感知'},{k:'美轮美奂',a:'高大华美'},"
     "{k:'弱冠',a:'20岁'},{k:'执子之手',a:'战友情'},{k:'忘忧草',a:'萱草'},{k:'目无全牛',a:'技艺'},"
     "{k:'小鸡也是有耳朵',a:'当然有'},{k:'促织',a:'蟋蟀'},{k:'东道主',a:'方向'},{k:'单腿站立',a:'减少热量'},"
     "{k:'海中霸王',a:'虎鲸'},{k:'司空见惯',a:'官职'},{k:'生辰八字',a:'八个字'},{k:'初出茅庐',a:'草房'},"
     "{k:'立夏',a:'夏季'},{k:'兰亭序',a:'王羲之'},{k:'向日葵成熟后头',a:'花盘太重'},{k:'蹴鞠',a:'足球'},"
     "{k:'小鸡的羽毛能防水',a:'不能'},{k:'纨绔子弟',a:'细绢'},{k:'电热毯',a:'睡前关闭'},{k:'五花八门',a:'兵法'},"
     "{k:'海中牛奶',a:'牡蛎'},{k:'七月流火',a:'恒星'},{k:'六艺',a:'驾驭'},{k:'海星有眼睛',a:'有'},"
     "{k:'逆风',a:'增加升力'},{k:'炙手可热',a:'权势'},{k:'三秋',a:'三个季度'},{k:'三宝殿',a:'佛教'},"
     "{k:'吃小石子',a:'帮助消化'},{k:'花中君子',a:'竹'},{k:'千金小姐',a:'男'},{k:'打哈欠',a:'真会'},"
     "{k:'冰皮月饼',a:'不用烘烤'},{k:'落汤鸡',a:'尾脂腺'},{k:'信手拈来',a:'随手'},{k:'骨骼数量',a:'会'},"
     "{k:'弄璋',a:'男孩'},{k:'弄瓦',a:'女孩'},{k:'汗流浃背',a:'大臣'},{k:'梁上君子',a:'窃贼'},"
     "{k:'银子',a:'并不是'},{k:'蜗牛',a:'黏液'},{k:'吃太咸',a:'多喝水'},{k:'昙花一现',a:'晚上'},"
     "{k:'兔子眼睛',a:'血液'},{k:'藕断丝连',a:'导管'},{k:'金榜题名',a:'进士'},{k:'阳春白雪',a:'高雅'},"
     "{k:'下里巴人',a:'民间'},{k:'桃李满天下',a:'学生'},{k:'白发三千丈',a:'夸张'},{k:'红娘',a:'西厢记'},"
     "{k:'豆蔻年华',a:'13'},{k:'及笄',a:'15'},{k:'而立',a:'30'},{k:'不惑',a:'40'},"
     "{k:'知天命',a:'50'},{k:'耳顺',a:'60'},{k:'古稀',a:'70'},{k:'期颐',a:'100'},"
     "{k:'大腹便便',a:'肚子'},{k:'金针菇',a:'真菌'},{k:'皮蛋',a:'鸭蛋'},{k:'松花蛋',a:'鸭蛋'},"
     "{k:'哈密瓜',a:'新疆'},{k:'吐鲁番',a:'葡萄'},{k:'文房四宝',a:'笔墨纸砚'},{k:'岁寒三友',a:'松竹梅'},"
     "{k:'出水芙蓉',a:'荷花'},{k:'国色天香',a:'牡丹'},{k:'破釜沉舟',a:'巨鹿'},{k:'草船借箭',a:'赤壁'},"
     "{k:'负荆请罪',a:'廉颇'},{k:'完璧归赵',a:'蔺相如'},{k:'望梅止渴',a:'曹操'},{k:'三顾茅庐',a:'刘备'},"
     "{k:'指鹿为马',a:'赵高'},{k:'四面楚歌',a:'项羽'},{k:'背水一战',a:'韩信'},{k:'煮豆燃萁',a:'曹植'},"
     "{k:'入木三分',a:'王羲之'},{k:'闻鸡起舞',a:'祖逖'},{k:'程门立雪',a:'杨时'},{k:'东施效颦',a:'西施'},"
     "{k:'守株待兔',a:'侥幸'},{k:'掩耳盗铃',a:'自欺欺人'},{k:'拔苗助长',a:'急于求成'},{k:'刻舟求剑',a:'拘泥'},"
     "{k:'滥竽充数',a:'南郭先生'},{k:'买椟还珠',a:'取舍不当'},{k:'杯弓蛇影',a:'疑神疑鬼'},{k:'狐假虎威',a:'借别人威势'}"
     "];"
     "function triggerClick(el){"
     "  if(!el)return;"
     "  try{"
     "    const r=el.getBoundingClientRect();"
     "    const x=r.left+r.width/2,y=r.top+r.height/2;"
     "    const opts={bubbles:true,cancelable:true,view:window,clientX:x,clientY:y};"
     "    try{el.dispatchEvent(new PointerEvent('pointerdown',opts));}catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('mousedown',opts));}catch(e){}"
     "    try{"
     "      const t=new Touch({identifier:Date.now(),target:el,clientX:x,clientY:y});"
     "      el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[t],targetTouches:[t],changedTouches:[t]}));"
     "    }catch(e){}"
     "    try{el.dispatchEvent(new PointerEvent('pointerup',opts));}catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('mouseup',opts));}catch(e){}"
     "    try{"
     "      const te=new Touch({identifier:Date.now(),target:el,clientX:x,clientY:y});"
     "      el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[te]}));"
     "    }catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('click',opts));}catch(e){}"
     "    try{el.click();}catch(e){}"
     "  }catch(e){try{el.click();}catch(e2){}}"
     "}"
     "const rewardBtns=Array.from(document.querySelectorAll('button,a,[role=\"button\"],[class*=\"btn\"],div,span'))"
     "  .filter(el=>{"
     "    const t=(el.innerText||el.textContent||'').trim();"
     "    return t==='去领取'||t==='开心收下'||t==='领取饲料'||t==='收下饲料'||t==='我知道了'||t==='去拿饲料';"
     "  });"
     "if(rewardBtns.length>0){"
     "  triggerClick(rewardBtns[0]);"
     "  console.log('[AntForestPort] Manor Classroom reward claimed');"
     "  return;"
     "}"
     "let qText='';"
     "let qEl=null;"
     "const allElements=Array.from(document.querySelectorAll('*'));"
     "for(const el of allElements){"
     "  if(el.children.length===0){"
     "    const t=(el.innerText||el.textContent||'').trim();"
     "    if((t.includes('？')||t.includes('?')||t.includes('猜一猜')||t.includes('下列')||t.includes('考考你')||t.includes('通常情况下')||t.includes('成语'))&&t.length>=6&&t.length<=120){"
     "      qText=t;qEl=el;break;"
     "    }"
     "  }"
     "}"
     "if(qText){"
     "  const parentContainer=qEl.closest('[class*=\"content\"],[class*=\"modal\"],[class*=\"dialog\"],[class*=\"card\"],div')||qEl.parentElement?.parentElement||document.body;"
     "  const candidateOptions=Array.from(parentContainer.querySelectorAll('button,[role=\"button\"],[class*=\"option\"],[class*=\"answer\"],[class*=\"btn\"],div'))"
     "    .filter(el=>{"
     "      if(el.children.length>2)return false;"
     "      const t=(el.innerText||el.textContent||'').trim();"
     "      if(t===qText||t.length===0||t.length>35)return false;"
     "      if(t.includes('小课堂')||t.includes('饲料')||t.includes('知道了')||t.includes('关闭')||t.includes('规则'))return false;"
     "      const rect=el.getBoundingClientRect();"
     "      return rect.width>40&&rect.height>18&&rect.height<140;"
     "    });"
     "  const uniqueOptions=[];"
     "  const seenTexts=new Set();"
     "  for(const opt of candidateOptions){"
     "    const t=(opt.innerText||opt.textContent||'').trim();"
     "    if(!seenTexts.has(t)&&t.length>=1){"
     "      seenTexts.add(t);uniqueOptions.push({el:opt,text:t});"
     "    }"
     "  }"
     "  if(uniqueOptions.length>=2&&uniqueOptions.length<=4){"
     "    let bestMatch=null;"
     "    for(const item of QA_DB){"
     "      if(qText.includes(item.k)){bestMatch=item;break;}"
     "    }"
     "    let selectedOption=null;"
     "    if(bestMatch){"
     "      for(const opt of uniqueOptions){"
     "        if(opt.text.includes(bestMatch.a)||bestMatch.a.includes(opt.text)){"
     "          selectedOption=opt;break;"
     "        }"
     "      }"
     "    }"
     "    if(!selectedOption){"
     "      selectedOption=uniqueOptions.find(o=>o.text.includes('正确')||o.text.includes('是的')||o.text.includes('可以')||o.text.includes('有'))||uniqueOptions[0];"
     "    }"
     "    if(selectedOption){"
     "      triggerClick(selectedOption.el);"
     "      console.log('[AntForestPort] Selected Manor option: '+selectedOption.text);"
     "      setTimeout(()=>{"
     "        const claim=Array.from(document.querySelectorAll('button,a,[role=\"button\"],[class*=\"btn\"],div,span'))"
     "          .find(el=>{"
     "            const t=(el.innerText||el.textContent||'').trim();"
     "            return t==='去领取'||t==='开心收下'||t==='领取饲料'||t==='收下饲料'||t==='我知道了';"
     "          });"
     "        if(claim)triggerClick(claim);"
     "      },800);"
     "    }"
     "  }"
     "}"
     "}catch(e){console.error(e);}})();"];
    
    NSString *today = getCurrentDateString();
    [[NSUserDefaults standardUserDefaults] setObject:today forKey:@"lastManorAnswerDate"];
    [self recordStage:@"蚂蚁庄园：庄园小课堂答题已提交（稳拿 180g 饲料）"];
}

- (void)answerManorClassroomQuestion {
    if (!self.enableAutoManor) return;
    
    NSString *today = getCurrentDateString();
    NSString *lastAnswerDate = [[NSUserDefaults standardUserDefaults] stringForKey:@"lastManorAnswerDate"];
    if ([lastAnswerDate isEqualToString:today]) {
        return;
    }
    
    [self recordStage:@"蚂蚁庄园：正在进入庄园小课堂自动答题（稳拿180g饲料）..."];
    
    [self executeManorScriptOnWebView:@"(()=>{try{"
     "function triggerClick(el){if(!el)return;try{el.click();}catch(e){}}"
     "const all=Array.from(document.querySelectorAll('*'));"
     "for(const el of all){"
     "  const t=(el.innerText||el.getAttribute('aria-label')||'').trim();"
     "  if((t==='庄园小课堂'||t==='小课堂'||t.includes('庄园小课堂'))&&el.children.length<=1){"
     "    triggerClick(el.closest('button,a,[role=\"button\"],[class*=\"btn\"]')||el);"
     "    break;"
     "  }"
     "}"
     "}catch(e){console.error(e);}})();"];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1200 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self executeClassroomAnswerScript];
    });
}

- (void)executeManorTaskProcessScript {
    // 纯静默弹窗关闭兜底：仅关闭全局奖励弹窗（如“开心收下”、“我知道了”、“确认”），严禁触碰任务列表或任何跳转链接
    [self executeManorScriptOnWebView:@"(()=>{try{"
     "function triggerClick(el){if(!el)return;try{el.click();}catch(e){}}"
     "const modals=Array.from(document.querySelectorAll('[role=\"dialog\"],.ant-modal,[class*=\"modal\"],[class*=\"popup\"],[class*=\"dialog\"],[class*=\"pop-window\"]'));"
     "for(const m of modals){"
     "  const btns=Array.from(m.querySelectorAll('button,[role=\"button\"],[class*=\"btn\"],div,span'));"
     "  for(const b of btns){"
     "    if(b.tagName==='A'||(b.closest&&b.closest('a[href]'))) continue;"
     "    const t=(b.innerText||b.textContent||'').trim();"
     "    if(t==='开心收下'||t==='我知道了'||t==='好的'||t==='确认'||t==='确定'||t==='收下'||t==='明白'){"
     "      triggerClick(b);break;"
     "    }"
     "  }"
     "}"
     "}catch(e){console.error(e);}})();"];
}

- (void)openManorTaskPanelOnWebView {
    if (!self.enableAutoManor) return;
    
    [self executeManorScriptOnWebView:@"(()=>{try{"
     "function triggerClick(el){"
     "  if(!el)return false;"
     "  try{"
     "    const r=el.getBoundingClientRect();"
     "    if(r.width===0&&r.height===0)return false;"
     "    const x=r.left+r.width/2,y=r.top+r.height/2;"
     "    const opts={bubbles:true,cancelable:true,view:window,clientX:x,clientY:y};"
     "    try{el.dispatchEvent(new PointerEvent('pointerdown',opts));}catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('mousedown',opts));}catch(e){}"
     "    try{"
     "      const t=new Touch({identifier:Date.now(),target:el,clientX:x,clientY:y});"
     "      el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[t],targetTouches:[t],changedTouches:[t]}));"
     "    }catch(e){}"
     "    try{el.dispatchEvent(new PointerEvent('pointerup',opts));}catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('mouseup',opts));}catch(e){}"
     "    try{"
     "      const te=new Touch({identifier:Date.now(),target:el,clientX:x,clientY:y});"
     "      el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[te]}));"
     "    }catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('click',opts));}catch(e){}"
     "    try{el.click();}catch(e){}"
     "    return true;"
     "  }catch(e){try{el.click();return true;}catch(e2){return false;}}"
     "}"
     "function findAndClick(){"
     "  const all=Array.from(document.querySelectorAll('*'));"
     "  for(const el of all){"
     "    const txt=(el.innerText||el.textContent||el.getAttribute('aria-label')||'').trim().replace(/\\s+/g,'');"
     "    if(txt==='领饲料'||txt==='赚饲料'||txt==='做任务领饲料'||txt==='集饲料'||txt==='领饲料任务'){"
     "      const target=el.closest('button,[role=button],div[class*=btn],div[class*=button],div[class*=feed]')||el;"
     "      if(triggerClick(target)){"
     "        console.log('[AntForestPort] Clicked manor task panel button:',txt);"
     "        return true;"
     "      }"
     "    }"
     "  }"
     "  return false;"
     "}"
     "findAndClick();"
     "}catch(e){}})();"];
}

- (void)closeManorTaskPanelOnWebView {
    [self executeManorScriptOnWebView:@"(()=>{try{"
     "function triggerClick(el){if(!el)return;try{el.click();}catch(e){}}"
     "const mask=document.querySelector('.ant-drawer-mask,[class*=\"mask\"],[class*=\"overlay\"]');"
     "if(mask){triggerClick(mask);}"
     "const pt=document.elementFromPoint(window.innerWidth*0.5,window.innerHeight*0.12);"
     "if(pt&&pt!==document.body&&pt!==document.documentElement){triggerClick(pt);}"
     "const closeBtns=Array.from(document.querySelectorAll('.ant-drawer-close,[aria-label*=\"关闭\"],[class*=\"close\"],button'));"
     "for(const b of closeBtns){"
     "  const cls=(b.className||'').toLowerCase();"
     "  const txt=(b.innerText||'').trim();"
     "  if(cls.includes('close')||txt==='×'||txt==='✕'||txt==='关闭'){"
     "    triggerClick(b);break;"
     "  }"
     "}"
     "try{window.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',code:'Escape',keyCode:27,bubbles:true}));}catch(e){}"
     "}catch(e){}})();"];
}

- (void)queryManorTaskList {
    if (!self.enableAutoManor) return;
    // 庄园常规推广任务服务端不支持RPC直接调用，无需强行呼出抽屉面板打扰用户
}

- (void)finishManorTask:(NSString *)taskType sceneCode:(NSString *)sceneCode taskTitle:(NSString *)title {
    if (!self.enableAutoManor || !taskType.length) return;
    [self doManorFarmTaskWithBizKey:taskType];
}

- (void)receiveManorTaskAward:(NSString *)taskType sceneCode:(NSString *)sceneCode taskTitle:(NSString *)title awardName:(NSString *)awardName {
    if (!self.enableAutoManor || !taskType.length) return;
    [self receiveManorFarmTaskAwardWithTaskId:taskType title:title];
}

- (void)queryManorFarmTasks {
    if (!isWithinTaskActiveHours()) return;
    if (!self.enableAutoManor) return;
    PSDJsBridge *bridge = (self.manorBridge && self.manorBridge != self.jsBridge) ? self.manorBridge : nil;
    if (!bridge) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)(now * 1000)];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *url = self.manorH5Url ?: @"https://66666674.h5app.alipay.com/www/index.html";
    NSString *taskArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.listFarmTask\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"H5\",\"version\":\"1.8.2302070202.46\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, randNum];
    [bridge _doFlushMessageQueue:taskArg url:url];
}

- (void)doManorFarmTaskWithBizKey:(NSString *)bizKey {
    if (!self.enableAutoManor || !bizKey.length) return;
    PSDJsBridge *bridge = (self.manorBridge && self.manorBridge != self.jsBridge) ? self.manorBridge : nil;
    if (!bridge) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)(now * 1000)];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *url = self.manorH5Url ?: @"https://66666674.h5app.alipay.com/www/index.html";
    NSString *doTaskArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.doFarmTask\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"bizKey\":\"%@\",\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"H5\",\"version\":\"1.8.2302070202.46\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", bizKey, timeStamp, randNum];
    [bridge _doFlushMessageQueue:doTaskArg url:url];
}

- (void)receiveManorFarmTaskAwardWithTaskId:(NSString *)taskId title:(NSString *)title {
    if (!self.enableAutoManor || !taskId.length) return;
    PSDJsBridge *bridge = (self.manorBridge && self.manorBridge != self.jsBridge) ? self.manorBridge : nil;
    if (!bridge) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)(now * 1000)];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *url = self.manorH5Url ?: @"https://66666674.h5app.alipay.com/www/index.html";
    NSString *claimArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.receiveFarmTaskAward\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"H5\",\"taskId\":\"%@\",\"version\":\"1.8.2302070202.46\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", taskId, timeStamp, randNum];
    [bridge _doFlushMessageQueue:claimArg url:url];
    [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：已提交领取“%@”（饲料奖励）...", title ?: taskId]];
}

- (void)handleManorTaskList:(NSArray *)taskList {
    if (!isWithinTaskActiveHours()) return;
    if (!self.enableAutoManor || !taskList.count) return;
    
    static NSTimeInterval lastProcessTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - lastProcessTime < 4.0) return;
    lastProcessTime = now;
    
    initDailyTaskCache();
    
    NSInteger taskDelayIndex = 0;
    NSInteger currentStock = self.lastManorFoodStock;
    NSInteger limit = self.lastManorFoodStockLimit > 0 ? self.lastManorFoodStockLimit : 1800;
    
    for (NSDictionary *task in taskList) {
        if (![task isKindOfClass:NSDictionary.class]) continue;
        NSString *bizKey = task[@"bizKey"] ?: @"";
        NSString *taskId = task[@"taskId"] ?: @"";
        NSString *status = task[@"taskStatus"] ?: @"";
        NSString *title = task[@"title"] ?: (bizKey.length ? bizKey : taskId);
        NSString *mode = task[@"taskMode"] ?: @"";
        NSInteger award = [task[@"awardCount"] integerValue] ?: ([task[@"canReceiveAwardCount"] integerValue] ?: 90);
        
        if ([status isEqualToString:@"RECEIVED"]) {
            if ([bizKey isEqualToString:@"ANSWER"]) {
                NSString *today = getCurrentDateString();
                [[NSUserDefaults standardUserDefaults] setObject:today forKey:@"lastManorAnswerDate"];
            }
            continue;
        }
        
        if ([status isEqualToString:@"FINISHED"]) {
            if (taskId.length) {
                // 如果当前存量已达上限，或领取本项会导致超出上限溢出被吞，坚决不盲目领取！
                if ((currentStock >= limit && limit > 0) || (limit > 0 && currentStock + award > limit)) {
                    static NSTimeInterval lastFullLogTime = 0;
                    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                    if (now - lastFullLogTime > 60) {
                        lastFullLogTime = now;
                        [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：饲料背包已满或将溢出（当前 %ldg/%ldg，待领 %ldg），暂不领取“%@”，待小鸡进食后再领", (long)currentStock, (long)limit, (long)award, title]];
                    }
                    continue;
                }
                NSString *claimKey = [NSString stringWithFormat:@"ANTFARM_CLAIM_TASK:%@", taskId];
                if (![gDailyCompletedTasks containsObject:claimKey]) {
                    [gDailyCompletedTasks addObject:claimKey];
                    saveDailyTaskCache();
                    // 立即预累加虚拟存量，防止同批次后续任务并发领取造成溢出浪费
                    currentStock += award;
                    self.lastManorFoodStock = currentStock;
                    [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：发现已完成任务“%@”，正在领取 %ldg 饲料（预估容量 %ldg/%ldg）...", title, (long)award, (long)currentStock, (long)limit]];
                    [self receiveManorFarmTaskAwardWithTaskId:taskId title:title];
                }
            }
            continue;
        }
        
        if ([status isEqualToString:@"TODO"]) {
            if ([bizKey isEqualToString:@"ANSWER"]) {
                NSString *today = getCurrentDateString();
                NSString *lastAnswerDate = [[NSUserDefaults standardUserDefaults] stringForKey:@"lastManorAnswerDate"];
                if (![lastAnswerDate isEqualToString:today]) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1000 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                        [self answerManorClassroomQuestion];
                    });
                }
                continue;
            }
            
            // 过滤捐款、支付、理财等需真实出资的任务，严禁自动化盲目调用
            NSString *desc = task[@"desc"] ?: task[@"taskDesc"] ?: @"";
            NSString *cat = task[@"categorizationSecondLevel"] ?: @"";
            if ([cat isEqualToString:@"Public_Welfare_Behavior"] ||
                [bizKey containsString:@"DONATE"] || [bizKey containsString:@"DONATION"] ||
                [bizKey containsString:@"PAY"] || [bizKey containsString:@"PURCHASE"] ||
                [bizKey containsString:@"ZhangDanTZ"] || [title containsString:@"信用卡"] ||
                [bizKey isEqualToString:@"JINGTAN_FEED_FISH"] ||
                [desc containsString:@"捐"] || [desc containsString:@"付款"] || [desc containsString:@"支付"] || [desc containsString:@"实付"]) {
                continue;
            }
            
            // 过滤纯游戏玩局类任务 (Game / Game_Charge)
            if ([cat isEqualToString:@"Game"] || [cat isEqualToString:@"Game_Charge"]) {
                continue;
            }
            
            // 针对 VIEW 或 TRIGGER 模式的浏览、逛一逛、功能开启类常规任务进行自动触发
            if ([mode isEqualToString:@"VIEW"] || [mode isEqualToString:@"TRIGGER"]) {
                NSString *taskKey = [NSString stringWithFormat:@"ANTFARM_FOOD_TASK:%@", bizKey];
                if (![gDailyCompletedTasks containsObject:taskKey]) {
                    [gDailyCompletedTasks addObject:taskKey];
                    saveDailyTaskCache();
                    [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：正在完成浏览任务“%@”...", title]];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(taskDelayIndex * 350 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                        [self doManorFarmTaskWithBizKey:bizKey];
                    });
                    taskDelayIndex++;
                }
            }
        }
    }
    
    // 如果有触发的任务，延时后重新查询任务列表，以便自动检测到 FINISHED 并领取饲料入包
    if (taskDelayIndex > 0) {
        int64_t refreshDelay = (int64_t)((taskDelayIndex * 350 + 2500) * NSEC_PER_MSEC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, refreshDelay), dispatch_get_main_queue(), ^{
            [self queryManorFarmTasks];
        });
    }
}

- (void)runManorTasks {
    if (!self.enableAutoManor) return;
    [self queryManorFarmTasks];
    [self executeManorTaskProcessScript];
}

@synthesize friendsRank = _friendsRank;

- (NSMutableDictionary *)friendsRank {
    if (!_friendsRank || !_friendsRank.count) {
        if (!_friendsRank) {
            _friendsRank = [NSMutableDictionary dictionary];
        }
        NSData *data = [[NSUserDefaults standardUserDefaults] objectForKey:@"cachedFriendsRank"];
        if (data) {
            @try {
                NSError *error = nil;
                NSSet *classes = [NSSet setWithArray:@[NSDictionary.class, NSString.class, NSNumber.class]];
                NSDictionary *cached = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:data error:&error];
                if (!cached) {
                    cached = [NSKeyedUnarchiver unarchiveObjectWithData:data];
                }
                if ([cached isKindOfClass:NSDictionary.class] && cached.count) {
                    [_friendsRank addEntriesFromDictionary:cached];
                }
            } @catch (__unused NSException *e) {}
        }
    }
    return _friendsRank;
}

- (void)setFriendsRank:(NSMutableDictionary *)friendsRank {
    _friendsRank = friendsRank ?: [NSMutableDictionary dictionary];
}

@synthesize friendsName = _friendsName;

- (NSMutableDictionary *)friendsName {
    if (!_friendsName || !_friendsName.count) {
        if (!_friendsName) {
            _friendsName = [NSMutableDictionary dictionary];
        }
        NSData *data = [[NSUserDefaults standardUserDefaults] objectForKey:@"friendsName"];
        if (data) {
            @try {
                NSError *error = nil;
                NSSet *classes = [NSSet setWithArray:@[NSDictionary.class, NSArray.class, NSString.class, NSNumber.class]];
                NSDictionary *cached = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:data error:&error];
                if (!cached) {
                    cached = [NSKeyedUnarchiver unarchiveObjectWithData:data];
                }
                if ([cached isKindOfClass:NSDictionary.class] && cached.count) {
                    [_friendsName addEntriesFromDictionary:cached];
                }
            } @catch (__unused NSException *e) {}
        }
    }
    return _friendsName;
}

- (void)setFriendsName:(NSMutableDictionary *)friendsName {
    _friendsName = friendsName ?: [NSMutableDictionary dictionary];
}

@synthesize myUserId = _myUserId;

- (NSString *)myUserId {
    if (_myUserId.length) return _myUserId;
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"lastKnownUserId"];
    if (saved.length) {
        _myUserId = [saved copy];
        return _myUserId;
    }
    return nil;
}

- (void)setMyUserId:(NSString *)myUserId {
    if (![myUserId isKindOfClass:NSString.class] || !myUserId.length) return;
    _myUserId = [myUserId copy];
    [[NSUserDefaults standardUserDefaults] setObject:_myUserId forKey:@"lastKnownUserId"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@synthesize lastManorFarmId = _lastManorFarmId;

- (NSString *)lastManorFarmId {
    if (_lastManorFarmId.length) return _lastManorFarmId;
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"antforest_lastManorFarmId"];
    if (saved.length) {
        _lastManorFarmId = [saved copy];
        return _lastManorFarmId;
    }
    return nil;
}

- (void)setLastManorFarmId:(NSString *)lastManorFarmId {
    _lastManorFarmId = [lastManorFarmId copy];
    if (_lastManorFarmId.length) {
        [[NSUserDefaults standardUserDefaults] setObject:_lastManorFarmId forKey:@"antforest_lastManorFarmId"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}

@synthesize lastManorFoodStock = _lastManorFoodStock;

- (NSInteger)lastManorFoodStock {
    if (_lastManorFoodStock > 0) return _lastManorFoodStock;
    NSInteger saved = [[NSUserDefaults standardUserDefaults] integerForKey:@"antforest_lastManorFoodStock"];
    if (saved > 0) {
        _lastManorFoodStock = saved;
        return _lastManorFoodStock;
    }
    return _lastManorFoodStock;
}

- (void)setLastManorFoodStock:(NSInteger)lastManorFoodStock {
    _lastManorFoodStock = lastManorFoodStock;
    if (lastManorFoodStock >= 0) {
        [[NSUserDefaults standardUserDefaults] setInteger:lastManorFoodStock forKey:@"antforest_lastManorFoodStock"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}

@synthesize lastManorFoodStockLimit = _lastManorFoodStockLimit;

- (NSInteger)lastManorFoodStockLimit {
    if (_lastManorFoodStockLimit > 0) return _lastManorFoodStockLimit;
    NSInteger saved = [[NSUserDefaults standardUserDefaults] integerForKey:@"antforest_lastManorFoodStockLimit"];
    if (saved > 0) {
        _lastManorFoodStockLimit = saved;
        return _lastManorFoodStockLimit;
    }
    return 1800;
}

- (void)setLastManorFoodStockLimit:(NSInteger)lastManorFoodStockLimit {
    _lastManorFoodStockLimit = lastManorFoodStockLimit;
    if (lastManorFoodStockLimit > 0) {
        [[NSUserDefaults standardUserDefaults] setInteger:lastManorFoodStockLimit forKey:@"antforest_lastManorFoodStockLimit"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}

- (void)enterManorFarm {
    if (!self.enableAutoManor) return;
    PSDJsBridge *bridge = (self.manorBridge && self.manorBridge != self.jsBridge) ? self.manorBridge : nil;
    if (!bridge) return;
    
    NSString *uid = self.myUserId.length ? self.myUserId : ([[NSUserDefaults standardUserDefaults] stringForKey:@"lastKnownUserId"] ?: @"");
    NSString *farmId = self.lastManorFarmId ?: @"";
    if (!uid.length && farmId.length > 2) {
        uid = [farmId substringFromIndex:farmId.length / 2];
    }
    
    NSString *url = self.manorH5Url ?: @"https://66666674.h5app.alipay.com/www/index.html";
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)(now * 1000)];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    
    // 真实标准底层 RPC: com.alipay.antfarm.enterFarm
    NSString *enterArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.enterFarm\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"animalId\":\"\",\"cityAdCode\":\"000000\",\"districtAdCode\":\"000000\",\"farmId\":\"%@\",\"masterFarmId\":\"\",\"queryLastRecordNum\":true,\"recall\":false,\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"H5\",\"touchRecordId\":\"\",\"userId\":\"%@\",\"version\":\"1.8.2302070202.46\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", farmId, uid, timeStamp, randNum];
    [bridge _doFlushMessageQueue:enterArg url:url];
}

- (void)feedManorChicken {
    if (!self.enableAutoManor) return;
    if (self.isManorChickenEating) {
        [self recordStage:@"蚂蚁庄园：小鸡当前正在进食中，暂无需投喂"];
        return;
    }
    
    static NSTimeInterval lastFeedTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - lastFeedTime < 4.0) return;
    lastFeedTime = now;
    
    // 1. 投喂前，先关闭抽屉面板，确保院子小鸡与饲料袋完全暴露
    [self closeManorTaskPanelOnWebView];
    
    [self recordStage:@"蚂蚁庄园：正在投喂小鸡（180g 饲料）..."];
    
    PSDJsBridge *bridge = (self.manorBridge && self.manorBridge != self.jsBridge) ? self.manorBridge : nil;
    if (bridge) {
        NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)(now * 1000)];
        NSString *randNum = [AntForestManager getNumberRandom:15];
        NSString *url = self.manorH5Url ?: @"https://66666674.h5app.alipay.com/www/index.html";
        
        NSString *farmId = self.lastManorFarmId ?: @"";
        // 真实标准底层 RPC: com.alipay.antfarm.feedAnimal
        NSString *feedArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.feedAnimal\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"animalType\":\"CHICK\",\"canMock\":true,\"farmId\":\"%@\",\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"H5\",\"version\":\"1.8.2302070202.46\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", farmId ?: @"", timeStamp, randNum];
        [bridge _doFlushMessageQueue:feedArg url:url];
        
        // 真实标准底层状态同步: com.alipay.antfarm.syncAnimalStatus
        NSString *syncUserId = self.myUserId;
        if (!syncUserId.length && farmId.length > 2) {
            syncUserId = [farmId substringFromIndex:farmId.length / 2];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1200 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            NSString *syncArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.syncAnimalStatus\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"farmId\":\"%@\",\"operType\":\"FEEDSYNC\",\"queryFoodStockInfo\":false,\"recall\":false,\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"H5\",\"userId\":\"%@\",\"version\":\"1.8.2302070202.46\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", farmId ?: @"", syncUserId ?: @"", [NSString stringWithFormat:@"%ld", (long)([[NSDate date] timeIntervalSince1970] * 1000)], [AntForestManager getNumberRandom:15]];
            [bridge _doFlushMessageQueue:syncArg url:url];
        });
        
        if (!farmId.length) {
            // 没有 farmId 时触发一次 enterManorFarm 以便探明 farmId 并拉取最新主页状态
            [self enterManorFarm];
        }
    }
    
    // 2. 界面触控模拟：针对 Canvas 与饲料袋精准投喂
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self executeManorScriptOnWebView:@"(()=>{try{"
         "function sendTouch(target, type, x, y){"
         "  if(!target) return;"
         "  let t = null;"
         "  try{"
         "    t = new Touch({identifier:Date.now(), target:target, clientX:x, clientY:y, pageX:x, pageY:y, screenX:x, screenY:y, radiusX:15, radiusY:15});"
         "  }catch(e){}"
         "  if(!t && document.createTouch){"
         "    try{ t = document.createTouch(window, target, 1, x, y, x, y); }catch(e){}"
         "  }"
         "  if(t){"
         "    try{"
         "      const evt = new TouchEvent(type, {bubbles:true, cancelable:true, view:window, touches:(type==='touchend'?[]:[t]), targetTouches:(type==='touchend'?[]:[t]), changedTouches:[t]});"
         "      target.dispatchEvent(evt);"
         "    }catch(e){"
         "      if(document.createTouchList){"
         "        try{"
         "          const evt = document.createEvent('TouchEvent');"
         "          const touchList = (type==='touchend'?document.createTouchList():document.createTouchList(t));"
         "          evt.initTouchEvent(type, true, true, window, 0, 0, 0, x, y, false, false, false, false, touchList, touchList, document.createTouchList(t), 1, 0);"
         "          target.dispatchEvent(evt);"
         "        }catch(ee){}"
         "      }"
         "    }"
         "  }"
         "  try{"
         "    const opts = {bubbles:true, cancelable:true, view:window, clientX:x, clientY:y, button:0};"
         "    if(type==='touchstart'){"
         "      target.dispatchEvent(new PointerEvent('pointerdown', opts));"
         "      target.dispatchEvent(new MouseEvent('mousedown', opts));"
         "    } else if(type==='touchend'){"
         "      target.dispatchEvent(new PointerEvent('pointerup', opts));"
         "      target.dispatchEvent(new MouseEvent('mouseup', opts));"
         "      target.dispatchEvent(new MouseEvent('click', opts));"
         "      try{ target.click(); }catch(ce){}"
         "    }"
         "  }catch(e){}"
         "}"
         "const W = window.innerWidth, H = window.innerHeight;"
         "const bagX = W * 0.86, bagY = H * 0.90;"
         "const bowlX = W * 0.58, bowlY = H * 0.72;"
         "const canvas = document.querySelector('canvas') || document.body;"
         "const elAtBag = document.elementFromPoint(bagX, bagY) || canvas;"
         "const isInsideDrawer = elAtBag.closest && elAtBag.closest('.ant-drawer, [class*=\"drawer\"], [class*=\"task\"]');"
         "if(!isInsideDrawer){"
         "  // A. 模拟点击饲料袋"
         "  sendTouch(elAtBag, 'touchstart', bagX, bagY);"
         "  setTimeout(()=>{ sendTouch(elAtBag, 'touchend', bagX, bagY); }, 80);"
         "  // B. 模拟将饲料袋拖拽至饭盆"
         "  setTimeout(()=>{"
         "    sendTouch(canvas, 'touchstart', bagX, bagY);"
         "    setTimeout(()=>{"
         "      sendTouch(canvas, 'touchmove', (bagX+bowlX)/2, (bagY+bowlY)/2);"
         "      setTimeout(()=>{"
         "        sendTouch(canvas, 'touchmove', bowlX, bowlY);"
         "        setTimeout(()=>{"
         "          sendTouch(canvas, 'touchend', bowlX, bowlY);"
         "        }, 60);"
         "      }, 60);"
         "    }, 60);"
         "  }, 200);"
         "}"
         "// C. 查找是否有独立的饲料袋 DOM（严格排除抽屉、弹窗与跳转链接）"
         "const all = Array.from(document.querySelectorAll('*'));"
         "for(const el of all){"
         "  if(el.closest && el.closest('.ant-drawer, [class*=\"drawer\"], [class*=\"modal\"], [class*=\"dialog\"], [class*=\"task\"], [role=\"dialog\"], ul, ol')) continue;"
         "  if(el.tagName==='A' || (el.closest && el.closest('a[href]'))) continue;"
         "  const r = el.getBoundingClientRect();"
         "  if(r.width>0 && r.height>0 && r.top > H*0.70 && r.left > W*0.60){"
         "    const t = (el.innerText||el.textContent||'').trim();"
         "    const cls = (el.className||'').toString().toLowerCase();"
         "    const aria = (el.getAttribute('aria-label')||'').toLowerCase();"
         "    if(t==='投喂' || t==='喂食' || t==='喂小鸡' || t.includes('饲料') || cls.includes('feed') || cls.includes('food') || cls.includes('stock') || aria.includes('喂食') || aria.includes('饲料')){"
         "      sendTouch(el, 'touchstart', r.left+r.width/2, r.top+r.height/2);"
         "      sendTouch(el, 'touchend', r.left+r.width/2, r.top+r.height/2);"
         "      break;"
         "    }"
         "  }"
         "}"
         "}catch(e){console.error(e);}})();"];
    });
}

- (void)collectManorChickenManurePot:(NSString *)potNo {
    if (!self.enableAutoManor || !potNo.length) return;
    PSDJsBridge *bridge = (self.manorBridge && self.manorBridge != self.jsBridge) ? self.manorBridge : nil;
    if (!bridge) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)(now * 1000)];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *url = self.manorH5Url ?: @"https://66666674.h5app.alipay.com/www/index.html";
    NSString *manureArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.collectManurePot\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"manurePotNOs\":\"%@\",\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"H5\",\"version\":\"1.8.2302070202.46\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", potNo, timeStamp, randNum];
    [bridge _doFlushMessageQueue:manureArg url:url];
}

- (void)collectManorChickenManure {
    if (!self.enableAutoManor) return;
    
    NSString *today = getCurrentDateString();
    if ([self.lastManorManureCollectDate isEqualToString:today]) {
        return;
    }
    
    static NSTimeInterval lastCollectTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - lastCollectTime < 15) return;
    lastCollectTime = now;
    
    [self executeManorScriptOnWebView:@"(()=>{try{"
     "function triggerClick(el){if(!el)return;try{el.click();}catch(e){}}"
     "const all=Array.from(document.querySelectorAll('*'));"
     "for(const el of all){"
     "  const t=(el.innerText||el.getAttribute('aria-label')||'').trim();"
     "  if(t.includes('肥料')||t.includes('收肥料')||t.includes('金色肥料')||el.className?.includes?.('manure')){"
     "    triggerClick(el);"
     "    console.log('[AntForestPort] Clicked chicken manure pile');break;"
     "  }"
     "}"
     "}catch(e){}})();"];
}

- (void)checkAndRunManorAutomations {
    if (!self.enableAutoManor) return;
    
    static NSTimeInterval lastCheckTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - lastCheckTime < 15.0) return;
    lastCheckTime = now;
    
    self.isManorChickenEating = NO;
    
    [self recordStage:@"蚂蚁庄园：正在执行日常自动化体检..."];
    
    // 0. 主动刷新庄园主页状态（获取小鸡进食、饭盆余粮、饲料存量等状态）
    [self enterManorFarm];
    
    // 1. 每日签到
    [self signManorDaily];
    
    // 2. 智能答题
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self answerManorClassroomQuestion];
    });
    
    // 3. 收取肥料（仅在今日未收取时尝试）
    NSString *today = getCurrentDateString();
    if (![self.lastManorManureCollectDate isEqualToString:today]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            [self collectManorChickenManure];
        });
    }
    
    // 4. 自动投喂小鸡
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3200 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self feedManorChicken];
    });
    
    // 5. 庄园任务体检与做任务
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4000 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self queryManorFarmTasks];
    });
}

- (void)handleManorResponse:(NSDictionary *)dict {
    if (!self.enableAutoManor) return;
    if (![dict isKindOfClass:NSDictionary.class]) return;
    
    @try {
        NSDictionary *resData = [dict[@"resData"] isKindOfClass:NSDictionary.class] ? dict[@"resData"] : dict;
        
        // A. 小鸡与饭盆状态检测 (subFarmVO / ownAnimal)
        NSDictionary *subFarm = [resData[@"subFarmVO"] isKindOfClass:NSDictionary.class] ? resData[@"subFarmVO"] : ([dict[@"subFarmVO"] isKindOfClass:NSDictionary.class] ? dict[@"subFarmVO"] : nil);
        NSDictionary *ownAnimal = [resData[@"ownAnimal"] isKindOfClass:NSDictionary.class] ? resData[@"ownAnimal"] : ([dict[@"ownAnimal"] isKindOfClass:NSDictionary.class] ? dict[@"ownAnimal"] : nil);
        
        if (subFarm || ownAnimal) {
            if (subFarm[@"farmId"]) {
                self.lastManorFarmId = [NSString stringWithFormat:@"%@", subFarm[@"farmId"]];
            } else if (ownAnimal[@"farmId"]) {
                self.lastManorFarmId = [NSString stringWithFormat:@"%@", ownAnimal[@"farmId"]];
            } else if (ownAnimal[@"masterFarmId"]) {
                self.lastManorFarmId = [NSString stringWithFormat:@"%@", ownAnimal[@"masterFarmId"]];
            }
            
            NSString *farmId = self.lastManorFarmId;
            NSArray *animals = [subFarm[@"animals"] isKindOfClass:NSArray.class] ? subFarm[@"animals"] : nil;
            if (animals.count > 0) {
                for (NSDictionary *animal in animals) {
                    if ([animal isKindOfClass:NSDictionary.class]) {
                        NSString *mFarmId = [NSString stringWithFormat:@"%@", animal[@"masterFarmId"] ?: @""];
                        NSString *aFarmId = [NSString stringWithFormat:@"%@", animal[@"farmId"] ?: @""];
                        if ((farmId.length && ([mFarmId isEqualToString:farmId] || [aFarmId isEqualToString:farmId])) ||
                            [animal[@"animalStatusVO"][@"animalInteractStatus"] isEqualToString:@"HOME"]) {
                            self.lastManorAnimalId = [NSString stringWithFormat:@"%@", animal[@"animalId"]];
                            break;
                        }
                    }
                }
                if (!self.lastManorAnimalId.length && animals.firstObject[@"animalId"]) {
                    self.lastManorAnimalId = [NSString stringWithFormat:@"%@", animals.firstObject[@"animalId"]];
                }
            } else if (ownAnimal[@"animalId"]) {
                self.lastManorAnimalId = [NSString stringWithFormat:@"%@", ownAnimal[@"animalId"]];
            }
            
            NSInteger foodStock = 0;
            if (subFarm[@"foodStock"]) {
                foodStock = [subFarm[@"foodStock"] integerValue];
            } else if (resData[@"foodStock"]) {
                foodStock = [resData[@"foodStock"] integerValue];
            } else if (dict[@"foodStock"]) {
                foodStock = [dict[@"foodStock"] integerValue];
            }
            NSInteger foodStockLimit = [subFarm[@"foodStockLimit"] respondsToSelector:@selector(integerValue)] ? [subFarm[@"foodStockLimit"] integerValue] : ([resData[@"foodStockLimit"] respondsToSelector:@selector(integerValue)] ? [resData[@"foodStockLimit"] integerValue] : 1800);
            if (foodStock > 0 || subFarm[@"foodStock"] != nil) {
                self.lastManorFoodStock = foodStock;
            }
            if (foodStockLimit > 0) {
                self.lastManorFoodStockLimit = foodStockLimit;
            }
            
            NSInteger foodInTrough = 0;
            if (subFarm[@"foodInTrough"]) {
                foodInTrough = [subFarm[@"foodInTrough"] integerValue];
            }
            NSInteger foodLimit = [subFarm[@"foodInTroughLimit"] respondsToSelector:@selector(integerValue)] ? [subFarm[@"foodInTroughLimit"] integerValue] : 180;
            NSInteger countdown = [subFarm[@"countdown"] respondsToSelector:@selector(integerValue)] ? [subFarm[@"countdown"] integerValue] : 0;
            
            // 真实判定：食盆余粮满了，或者倒计时大于0且盆内有粮，才算真正进食中
            BOOL isEating = (foodInTrough >= foodLimit) || (countdown > 0 && foodInTrough > 0);
            self.isManorChickenEating = isEating;
            
            if (isEating) {
                NSInteger hours = countdown / 3600;
                NSInteger minutes = (countdown % 3600) / 60;
                NSInteger seconds = countdown % 60;
                NSLog(@"🐔 [蚂蚁庄园·小鸡状态] 正在进食中 | 盆内:%ld/%ldg | 倒计时:%02ld:%02ld:%02ld | 饲料存量:%ldg", (long)foodInTrough, (long)foodLimit, (long)hours, (long)minutes, (long)seconds, (long)foodStock);
                
                static NSTimeInterval lastEatLogTime = 0;
                NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                if (now - lastEatLogTime > 30) {
                    lastEatLogTime = now;
                    if (countdown > 0) {
                        [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：小鸡正在进食中（盆内余粮 %ldg / 倒计时 %02ld:%02ld:%02ld / 背包存量 %ldg），暂无需喂食", (long)foodInTrough, (long)hours, (long)minutes, (long)seconds, (long)foodStock]];
                    } else {
                        [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：小鸡正在进食中（背包存量 %ldg），暂无需喂食", (long)foodStock]];
                    }
                }
            } else {
                NSLog(@"🐔 [蚂蚁庄园·小鸡状态] 饭盆空闲 | 盆内:%ld/%ldg | 饲料存量:%ldg", (long)foodInTrough, (long)foodLimit, (long)foodStock);
                if (foodStock >= 180) {
                    [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：检测到小鸡饭盆空闲（盆内 %ldg / 背包存量 %ldg），正在自动投喂 180g 饲料...", (long)foodInTrough, (long)foodStock]];
                    [self feedManorChicken];
                } else if (foodStock > 0) {
                    [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：检测到小鸡饭盆空闲，背包存量不足 180g（当前 %ldg），尝试投喂...", (long)foodStock]];
                    [self feedManorChicken];
                } else {
                    [self recordStage:@"蚂蚁庄园：小鸡饭盆空闲，但背包饲料存量为 0g，需先做任务赚饲料"];
                }
            }
            
            NSDictionary *manureVO = [subFarm[@"manureVO"] isKindOfClass:NSDictionary.class] ? subFarm[@"manureVO"] : nil;
            if (manureVO) {
                NSArray *potList = manureVO[@"manurePotList"];
                for (NSDictionary *pot in potList) {
                    if ([pot isKindOfClass:NSDictionary.class]) {
                        NSString *potNo = pot[@"manurePotNO"];
                        NSInteger potNum = [pot[@"manurePotNum"] integerValue];
                        if (potNo.length && potNum >= 100) {
                            [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：打扫鸡屎/肥料（罐内 %ldg），正在自动收取...", (long)potNum]];
                            [self collectManorChickenManurePot:potNo];
                        }
                    }
                }
            }
        }
        
        // B. 每日连续签到 (signList)
        NSDictionary *signDict = [resData[@"signList"] isKindOfClass:NSDictionary.class] ? resData[@"signList"] : ([dict[@"signList"] isKindOfClass:NSDictionary.class] ? dict[@"signList"] : nil);
        if (signDict) {
            NSArray *signs = [signDict[@"signList"] isKindOfClass:NSArray.class] ? signDict[@"signList"] : nil;
            NSString *today = getCurrentDateString();
            BOOL todaySigned = NO;
            NSInteger contDays = 0;
            NSInteger award = 180;
            for (NSDictionary *s in signs) {
                if ([s isKindOfClass:NSDictionary.class]) {
                    if ([s[@"signKey"] isEqualToString:today]) {
                        todaySigned = [s[@"signed"] boolValue];
                        award = [s[@"awardCount"] integerValue] ?: 180;
                    }
                    if (s[@"currentContinuousCount"]) {
                        contDays = [s[@"currentContinuousCount"] integerValue];
                    }
                }
            }
            if (todaySigned) {
                static NSString *lastLoggedSignKey = nil;
                if (![lastLoggedSignKey isEqualToString:today]) {
                    lastLoggedSignKey = [today copy];
                    [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：今日已连续签到（已连签 %ld 天），已稳拿 %ldg 饲料", (long)contDays, (long)award]];
                    [[NSUserDefaults standardUserDefaults] setObject:today forKey:@"lastManorSignDate"];
                }
            } else {
                [self signManorDaily];
            }
        }
        
        // C. 任务列表解析与驱动 (farmTaskList)
        NSArray *taskList = [resData[@"farmTaskList"] isKindOfClass:NSArray.class] ? resData[@"farmTaskList"] : ([dict[@"farmTaskList"] isKindOfClass:NSArray.class] ? dict[@"farmTaskList"] : nil);
        if (taskList.count > 0) {
            [self handleManorTaskList:taskList];
        }
        
        // D. 气泡检查 (bubbleConfig)
        id bubbleConfig = resData[@"bubbleConfig"] ?: dict[@"bubbleConfig"];
        if ([bubbleConfig isKindOfClass:NSDictionary.class]) {
            NSString *bubbleType = bubbleConfig[@"bubbleType"];
            if ([bubbleType isEqualToString:@"NEW_DAILY_MANURE"]) {
                NSDictionary *dailyManure = [resData[@"dailyManure"] isKindOfClass:NSDictionary.class] ? resData[@"dailyManure"] : ([dict[@"dailyManure"] isKindOfClass:NSDictionary.class] ? dict[@"dailyManure"] : nil);
                BOOL canCollect = dailyManure ? [dailyManure[@"canCollect"] boolValue] : YES;
                NSString *today = getCurrentDateString();
                if (!canCollect) {
                    self.lastManorManureCollectDate = today;
                    NSLog(@"🐔 [蚂蚁庄园] 小鸡今日肥料已全部领取完毕 (canCollect=NO)");
                } else if (![self.lastManorManureCollectDate isEqualToString:today]) {
                    [self recordStage:@"蚂蚁庄园：检测到小鸡已拉出农场肥料，正在自动收取..."];
                    [self collectManorChickenManure];
                }
            }
        }
        
        // E. 领饲料奖励回包处理 (receiveFarmTaskAward)
        NSString *opType = [NSString stringWithFormat:@"%@", dict[@"operationType"] ?: (resData[@"operationType"] ?: (self.lastRpcOperationType ?: @""))];
        if (resData[@"haveAddFoodStock"] || [opType containsString:@"receiveFarmTaskAward"]) {
            NSInteger addFood = [resData[@"haveAddFoodStock"] integerValue];
            NSInteger curFood = [resData[@"foodStock"] integerValue];
            if (addFood > 0) {
                if (curFood > 0) self.lastManorFoodStock = curFood;
                [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：成功领取饲料 +%ldg（背包存量 %ldg）", (long)addFood, (long)(curFood > 0 ? curFood : self.lastManorFoodStock)]];
            } else if ([resData[@"memo"] isEqualToString:@"SUCCESS"] || [dict[@"memo"] isEqualToString:@"SUCCESS"]) {
                if (curFood > 0) self.lastManorFoodStock = curFood;
                [self recordStage:@"蚂蚁庄园：成功领取饲料奖励"];
            }
        }
        
        // G. 投喂小鸡回包处理 (feedAnimal)
        if ([opType containsString:@"feedAnimal"] && ([resData[@"memo"] isEqualToString:@"SUCCESS"] || [dict[@"memo"] isEqualToString:@"SUCCESS"] || [resData[@"resultCode"] isEqualToString:@"100"] || [dict[@"resultCode"] isEqualToString:@"100"] || resData[@"foodStock"] != nil)) {
            self.isManorChickenEating = YES;
            NSInteger curFood = [resData[@"foodStock"] integerValue];
            if (curFood > 0 || resData[@"foodStock"] != nil) {
                NSInteger prevFood = self.lastManorFoodStock;
                self.lastManorFoodStock = curFood;
                NSInteger fed = (prevFood > curFood && prevFood > 0) ? (prevFood - curFood) : 180;
                [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：小鸡投喂成功（消耗 %ldg 饲料，背包剩余 %ldg）", (long)fed, (long)curFood]];
            } else {
                [self recordStage:@"蚂蚁庄园：小鸡投喂成功（已倒入 180g 饲料）"];
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[AntForestPort] Exception in handleManorResponse: %@", e);
    }
}

static void extractFarmTasksRecursive(id obj, int depth, NSMutableArray *outTasks) {
    if (depth > 6 || !obj || outTasks.count >= 150) return;
    if ([obj isKindOfClass:NSArray.class]) {
        NSArray *arr = (NSArray *)obj;
        for (id child in arr) {
            if ([child isKindOfClass:NSDictionary.class]) {
                NSDictionary *d = (NSDictionary *)child;
                if (d[@"ongoing"] && ![d[@"ongoing"] boolValue]) {
                    // 限时挑战步骤未解锁，跳过此步骤及其下所有子任务
                    continue;
                }
                if (d[@"taskBaseInfo"] && [d[@"taskBaseInfo"] isKindOfClass:NSDictionary.class]) {
                    if (![outTasks containsObject:d]) {
                        [outTasks addObject:d];
                    }
                } else if (d[@"taskType"] || d[@"taskId"] || d[@"iepTaskId"] || d[@"deliveryId"] ||
                    (d[@"actionType"] && (d[@"awardCount"] || d[@"bizInfo"] || d[@"awardNum"] || d[@"taskDisplayConfig"]))) {
                    if (![outTasks containsObject:d]) {
                        [outTasks addObject:d];
                    }
                }
                extractFarmTasksRecursive(d, depth + 1, outTasks);
            } else if ([child isKindOfClass:NSArray.class]) {
                extractFarmTasksRecursive(child, depth + 1, outTasks);
            }
        }
    } else if ([obj isKindOfClass:NSDictionary.class]) {
        NSDictionary *d = (NSDictionary *)obj;
        if (d[@"ongoing"] && ![d[@"ongoing"] boolValue]) {
            // 限时挑战未解锁分组/步骤，跳过
            return;
        }
        [d enumerateKeysAndObjectsUsingBlock:^(id key, id val, BOOL *stop) {
            if (!val || val == (id)kCFNull) return;
            if ([val isKindOfClass:NSDictionary.class] || [val isKindOfClass:NSArray.class]) {
                extractFarmTasksRecursive(val, depth + 1, outTasks);
            }
        }];
    }
}

- (void)handleFarmResponse:(NSDictionary *)dict {
    if (![dict isKindOfClass:NSDictionary.class]) return;
    @try {
        initDailyTaskCache();
        NSDictionary *data = dict;
        if (data[@"resData"] && [data[@"resData"] isKindOfClass:NSDictionary.class]) {
            data = data[@"resData"];
        }
        
        // 打印顶层主要特征 Key
        NSMutableArray<NSString *> *topKeys = [NSMutableArray array];
        for (id k in dict.allKeys) {
            if ([k isKindOfClass:NSString.class]) [topKeys addObject:k];
        }
        NSLog(@"🌾 [芭芭农场·回包探针] 顶层Keys: [%@]", [topKeys componentsJoinedByString:@", "]);
        
        NSString *memo = [NSString stringWithFormat:@"%@", dict[@"memo"] ?: (dict[@"resultDesc"] ?: (data[@"memo"] ?: (data[@"resultDesc"] ?: @"")))];
        NSString *resCode = [NSString stringWithFormat:@"%@", dict[@"resultCode"] ?: (dict[@"code"] ?: (data[@"resultCode"] ?: (data[@"code"] ?: @"")))];
        if ([resCode isEqualToString:@"WateringTimeLimitError"] || [memo containsString:@"施肥次数已经用完"]) {
            [self recordStage:@"芭芭农场：今日施肥次数已达上限，明日再来"];
        }
        
        // 1. 小鸡肥料探测与处理
        NSDictionary *factory = [data[@"manureFactory"] isKindOfClass:NSDictionary.class] ? data[@"manureFactory"] : ([dict[@"manureFactory"] isKindOfClass:NSDictionary.class] ? dict[@"manureFactory"] : nil);
        if ([factory isKindOfClass:NSDictionary.class]) {
            BOOL canCollect = [factory[@"canCollect"] respondsToSelector:@selector(boolValue)] ? [factory[@"canCollect"] boolValue] : NO;
            NSDictionary *manure = [factory[@"manure"] isKindOfClass:NSDictionary.class] ? factory[@"manure"] : nil;
            NSArray *potList = [manure[@"manurePotList"] isKindOfClass:NSArray.class] ? manure[@"manurePotList"] : ([data[@"manurePotList"] isKindOfClass:NSArray.class] ? data[@"manurePotList"] : nil);
            NSInteger totalManure = 0;
            for (NSDictionary *pot in potList) {
                if ([pot isKindOfClass:NSDictionary.class]) {
                    totalManure += [pot[@"manurePotNum"] respondsToSelector:@selector(integerValue)] ? [pot[@"manurePotNum"] integerValue] : 0;
                }
            }
            NSInteger displayManure = totalManure > 1000 ? (totalManure / 1000) : totalManure;
            NSLog(@"🌾 [芭芭农场·小鸡肥料] 状态:【%@】| 可收肥料: %ld 肥 | 肥料锅数: %lu", canCollect ? @"可收取" : @"生产中", (long)displayManure, (unsigned long)potList.count);
            [self recordStage:[NSString stringWithFormat:@"芭芭农场：庄园小鸡肥料状态【%@】，可收取约 %ld 肥", canCollect ? @"可领取" : @"生产中/未满", (long)displayManure]];
            
            if (canCollect && self.enableAutoFarmTasks) {
                [self collectFarmChickenManure];
            }
        }
        
        // 2. 连续签到探测与处理
        NSDictionary *signInfo = [data[@"signTaskInfo"] isKindOfClass:NSDictionary.class] ? data[@"signTaskInfo"] : ([dict[@"signTaskInfo"] isKindOfClass:NSDictionary.class] ? dict[@"signTaskInfo"] : nil);
        if ([signInfo isKindOfClass:NSDictionary.class]) {
            NSInteger contCount = [signInfo[@"continuousCount"] respondsToSelector:@selector(integerValue)] ? [signInfo[@"continuousCount"] integerValue] : 0;
            NSArray *list = [signInfo[@"list"] isKindOfClass:NSArray.class] ? signInfo[@"list"] : nil;
            NSLog(@"🌾 [芭芭农场·连续签到] 已连续签到 %ld 天，周期列表 %lu 项", (long)contCount, (unsigned long)list.count);
            for (NSUInteger i = 0; i < list.count; i++) {
                NSDictionary *sItem = list[i];
                if (![sItem isKindOfClass:NSDictionary.class]) continue;
                NSString *signKey = [sItem[@"signKey"] isKindOfClass:NSString.class] ? sItem[@"signKey"] : @"";
                BOOL signedToday = [sItem[@"signed"] respondsToSelector:@selector(boolValue)] ? [sItem[@"signed"] boolValue] : NO;
                id awardCount = sItem[@"awardCount"] ?: sItem[@"awardDesc"] ?: @"奖励";
                NSLog(@"🌾 [农场签到 %lu/%lu] 日期: %@ | 状态: %@ | 奖励: %@", (unsigned long)(i+1), (unsigned long)list.count, signKey, signedToday ? @"已签" : @"待签", awardCount);
                
                NSString *todayStr = getCurrentDateString();
                if (!signedToday && ([signKey isEqualToString:todayStr] || i == contCount || i == 0)) {
                    [self recordStage:[NSString stringWithFormat:@"芭芭农场：探测到今日连续签到（%@），正在自动签到...", signKey]];
                    if (self.enableAutoFarmTasks) {
                        [self signFarmDailyWithKey:signKey];
                    }
                }
            }
        }
        
        // 3. 淘宝农场热气球
        NSDictionary *balloon = [data[@"balloonCooper"] isKindOfClass:NSDictionary.class] ? data[@"balloonCooper"] : ([dict[@"balloonCooper"] isKindOfClass:NSDictionary.class] ? dict[@"balloonCooper"] : nil);
        if ([balloon isKindOfClass:NSDictionary.class]) {
            NSString *status = [balloon[@"status"] isKindOfClass:NSString.class] ? balloon[@"status"] : @"";
            NSString *actId = [balloon[@"activityId"] isKindOfClass:NSString.class] ? balloon[@"activityId"] : @"";
            NSString *awardCount = @"2400";
            id ext = balloon[@"extend"];
            if ([ext isKindOfClass:NSString.class]) {
                NSData *ed = [(NSString *)ext dataUsingEncoding:NSUTF8StringEncoding];
                NSDictionary *eDict = ed ? [NSJSONSerialization JSONObjectWithData:ed options:0 error:nil] : nil;
                if ([eDict isKindOfClass:NSDictionary.class] && eDict[@"awardCount"]) awardCount = [NSString stringWithFormat:@"%@", eDict[@"awardCount"]];
            }
            NSLog(@"🌾 [芭芭农场·淘宝热气球] 活动: %@ | 状态: %@ | 奖励: %@ 肥", actId, status, awardCount);
            [self recordStage:[NSString stringWithFormat:@"芭芭农场：淘宝热气球【%@】，奖励 %@ 肥", [status isEqualToString:@"TODO"] ? @"去逛逛" : status, awardCount]];
        }
        
        // 4. 深度扫描提取任务列表（彻底杜绝单行截断与 Block 递归野指针）
        NSMutableArray *allFoundTasks = [NSMutableArray array];
        extractFarmTasksRecursive(dict, 0, allFoundTasks);
        
        // 如果发现了任务，逐条格式化打印并调度
        if (allFoundTasks.count > 0) {
            NSLog(@"🌾 [芭芭农场·任务探测] ══════════════ 共发现 %lu 个农场任务 ══════════════", (unsigned long)allFoundTasks.count);
            [self recordStage:[NSString stringWithFormat:@"芭芭农场：探测到 %lu 个任务，正在解析列表...", (unsigned long)allFoundTasks.count]];
            
            NSMutableArray<NSDictionary *> *tasksToQueue = [NSMutableArray array];
            for (NSUInteger idx = 0; idx < allFoundTasks.count; idx++) {
                id rawTask = allFoundTasks[idx];
                if (![rawTask isKindOfClass:NSDictionary.class]) continue;
                NSDictionary *t = (NSDictionary *)rawTask;
                
                id baseInfo = [t[@"taskBaseInfo"] isKindOfClass:NSDictionary.class] ? t[@"taskBaseInfo"] : nil;
                id rawTaskType = t[@"taskType"] ?: t[@"taskId"] ?: t[@"iepTaskId"] ?: t[@"deliveryId"] ?: [baseInfo objectForKey:@"taskType"];
                if (!rawTaskType && [t[@"taobaoTaskParams"] isKindOfClass:NSDictionary.class]) {
                    rawTaskType = t[@"taobaoTaskParams"][@"deliveryId"] ?: t[@"taobaoTaskParams"][@"implId"];
                }
                NSString *taskType = @"";
                if ([rawTaskType isKindOfClass:NSString.class]) {
                    taskType = (NSString *)rawTaskType;
                } else if ([rawTaskType respondsToSelector:@selector(stringValue)]) {
                    taskType = [rawTaskType stringValue];
                }
                if ([taskType containsString:@"POP"] || [taskType containsString:@"MIGRATE"]) {
                    continue;
                }
                
                id rawScene = t[@"sceneCode"] ?: t[@"iepSceneCode"] ?: [baseInfo objectForKey:@"sceneCode"];
                if (!rawScene && [t[@"taobaoTaskParams"] isKindOfClass:NSDictionary.class]) {
                    rawScene = t[@"taobaoTaskParams"][@"sceneId"];
                }
                NSString *sceneCode = @"";
                if ([rawScene isKindOfClass:NSString.class]) {
                    sceneCode = (NSString *)rawScene;
                } else if ([rawScene respondsToSelector:@selector(stringValue)]) {
                    sceneCode = [rawScene stringValue];
                }
                if (!sceneCode.length) sceneCode = @"ANTFARM_ORCHARD_TASK_V2";
                
                NSString *taskStatus = [t[@"taskStatus"] isKindOfClass:NSString.class] ? t[@"taskStatus"] : ([t[@"status"] isKindOfClass:NSString.class] ? t[@"status"] : ([baseInfo[@"taskStatus"] isKindOfClass:NSString.class] ? baseInfo[@"taskStatus"] : @""));
                NSString *actionType = [t[@"actionType"] isKindOfClass:NSString.class] ? t[@"actionType"] : ([baseInfo[@"actionType"] isKindOfClass:NSString.class] ? baseInfo[@"actionType"] : @"");
                
                NSDictionary *displayConfig = [t[@"taskDisplayConfig"] isKindOfClass:NSDictionary.class] ? t[@"taskDisplayConfig"] : ([baseInfo[@"taskDisplayConfig"] isKindOfClass:NSDictionary.class] ? baseInfo[@"taskDisplayConfig"] : nil);
                
                NSString *awardCount = @"";
                id rawAward = displayConfig[@"confAwardCount"] ?: displayConfig[@"awardCount"] ?: t[@"awardCount"] ?: t[@"awardNum"] ?: [baseInfo objectForKey:@"awardCount"];
                if ([rawAward isKindOfClass:NSString.class]) {
                    awardCount = (NSString *)rawAward;
                } else if ([rawAward respondsToSelector:@selector(stringValue)]) {
                    awardCount = [rawAward stringValue];
                }
                
                NSDictionary *bizInfo = nil;
                id rawBiz = t[@"bizInfo"] ?: t[@"deliveryBenefitInfo"] ?: [baseInfo objectForKey:@"bizInfo"];
                if ([rawBiz isKindOfClass:NSDictionary.class]) {
                    bizInfo = rawBiz;
                } else if ([rawBiz isKindOfClass:NSString.class]) {
                    NSData *bd = [(NSString *)rawBiz dataUsingEncoding:NSUTF8StringEncoding];
                    if (bd) {
                        id parsed = [NSJSONSerialization JSONObjectWithData:bd options:0 error:nil];
                        if ([parsed isKindOfClass:NSDictionary.class]) bizInfo = parsed;
                    }
                }
                
                id rawTitle = displayConfig[@"title"] ?: bizInfo[@"taskTitle"] ?: bizInfo[@"title"] ?: t[@"title"] ?: t[@"taskTitle"] ?: [baseInfo objectForKey:@"taskTitle"] ?: taskType;
                NSString *taskTitle = [rawTitle isKindOfClass:NSString.class] ? (NSString *)rawTitle : ([rawTitle respondsToSelector:@selector(stringValue)] ? [rawTitle stringValue] : @"");
                if (!taskTitle.length) taskTitle = taskType;
                NSDictionary *taskRights = [t[@"taskRights"] isKindOfClass:NSDictionary.class] ? t[@"taskRights"] : ([baseInfo[@"taskRights"] isKindOfClass:NSDictionary.class] ? baseInfo[@"taskRights"] : nil);
                NSInteger rTimes = [taskRights[@"rightsTimes"] integerValue];
                if (rTimes <= 0 && t[@"rightsTimes"]) rTimes = [t[@"rightsTimes"] integerValue];
                if (rTimes <= 0 && baseInfo[@"rightsTimes"]) rTimes = [baseInfo[@"rightsTimes"] integerValue];
                NSInteger rLimit = [taskRights[@"rightsTimesLimit"] integerValue];
                if (rLimit <= 0 && t[@"rightsTimesLimit"]) rLimit = [t[@"rightsTimesLimit"] integerValue];
                if (rLimit <= 0 && baseInfo[@"rightsTimesLimit"]) rLimit = [baseInfo[@"rightsTimesLimit"] integerValue];
                if (rLimit > 1 && ![taskTitle containsString:@"/"]) {
                    taskTitle = [NSString stringWithFormat:@"%@ (%ld/%ld)", taskTitle, (long)MIN(rTimes + 1, rLimit), (long)rLimit];
                }
                
                id rawBtn = displayConfig[@"todoBtn"] ?: displayConfig[@"completeBtn"] ?: bizInfo[@"taskJumpBtn"] ?: t[@"btnText"] ?: t[@"buttonText"] ?: t[@"actionText"] ?: @"";
                NSString *taskJumpBtn = [rawBtn isKindOfClass:NSString.class] ? (NSString *)rawBtn : ([rawBtn respondsToSelector:@selector(stringValue)] ? [rawBtn stringValue] : @"");
                NSString *awardDesc = awardCount.length ? [NSString stringWithFormat:@"%@肥", awardCount] : @"肥料奖励";
                
                NSLog(@"🌾 [农场任务 %lu/%lu] 标题:【%@】| 标识: %@ | 状态: %@ | 按钮:【%@】| 奖励: %@",
                      (unsigned long)(idx + 1), (unsigned long)allFoundTasks.count,
                      taskTitle, taskType, taskStatus, taskJumpBtn, awardDesc);
                
                [self recordProbeLog:[NSString stringWithFormat:@"[芭芭农场 %lu/%lu] 标题:%@ | 标识:%@ | 状态:%@ | 按钮:%@ | 奖励:%@",
                                      (unsigned long)(idx + 1), (unsigned long)allFoundTasks.count,
                                      taskTitle, taskType, taskStatus, taskJumpBtn, awardDesc]];
                
                if (!self.enableAutoFarmTasks) continue;
                
                BOOL isContainer = ([t[@"childTaskList"] isKindOfClass:NSArray.class] && [(NSArray *)t[@"childTaskList"] count] > 0) ||
                                   ([t[@"subTaskList"] isKindOfClass:NSArray.class] && [(NSArray *)t[@"subTaskList"] count] > 0);
                
                NSString *taskKey = [NSString stringWithFormat:@"%@:%@", sceneCode, taskType];
                BOOL isMulti = [actionType isEqualToString:@"MULTI_STAGE"] || (rLimit > 1 && rTimes < rLimit) || isMultiStageIncompleteTask(taskTitle, 0, 0) || isMultiStageTaskFromDict(t, nil, bizInfo ?: displayConfig);
                
                if (isMulti || [taskType containsString:@"FLOATBALL"] || [taskType containsString:@"ncly"] || [taskTitle containsString:@"玩一玩"] || [taskTitle containsString:@"小游戏"] || [taskTitle containsString:@"游戏"] || [taskStatus isEqualToString:@"TODO"]) {
                    @synchronized(self) {
                        if ([gDailyCompletedTasks containsObject:taskKey]) {
                            [gDailyCompletedTasks removeObject:taskKey];
                        }
                        saveDailyTaskCache();
                    }
                }
                
                if ([taskStatus isEqualToString:@"RECEIVED"]) {
                    @synchronized(self) {
                        if (taskKey.length) {
                            [gDailyCompletedTasks addObject:taskKey];
                            if (gFarmTaskRetryCounts[taskKey]) {
                                [gFarmTaskRetryCounts removeObjectForKey:taskKey];
                            }
                            saveDailyTaskCache();
                        }
                    }
                    continue;
                }
                
                BOOL isTodo = [taskStatus isEqualToString:@"TODO"] || [taskStatus isEqualToString:@"INIT"] || [taskStatus isEqualToString:@"SIGN"];
                BOOL canClaim = !isTodo && ([taskStatus isEqualToString:@"FINISHED"] ||
                                [taskStatus isEqualToString:@"CAN_RECEIVE"] ||
                                (([taskJumpBtn containsString:@"领"] && ![taskJumpBtn containsString:@"去领"] && ![taskJumpBtn containsString:@"去逛"]) && ![taskStatus isEqualToString:@"RECEIVED"]));
                
                if (canClaim) {
                    @synchronized(self) {
                        if ([gDailyCompletedTasks containsObject:taskKey]) [gDailyCompletedTasks removeObject:taskKey];
                        if ([gDailyFailedTasks containsObject:taskKey]) [gDailyFailedTasks removeObject:taskKey];
                        if (gFarmTaskRetryCounts[taskKey]) {
                            [gFarmTaskRetryCounts removeObjectForKey:taskKey];
                        }
                        saveDailyTaskCache();
                    }
                    [tasksToQueue addObject:@{
                        @"action": @"receive",
                        @"taskType": taskType,
                        @"sceneCode": sceneCode,
                        @"title": taskTitle,
                        @"awardName": awardDesc,
                        @"scenePrefix": @"芭芭农场",
                        @"isMultiStage": @(isMulti),
                        @"stageIndex": @(rTimes)
                    }];
                } else if (!isContainer &&
                           ![actionType isEqualToString:@"SPREAD_MANURE"] &&
                           ![actionType isEqualToString:@"ANTFARM_COLLECT_MANURE"] &&
                           ![taskType isEqualToString:@"ANTFARM_COLLECT_MANURE"] &&
                           isTodo) {
                    BOOL isSafe = isSafeFarmTask(taskType, taskTitle);
                    if (isSafe) {
                        NSString *retryKey = isMulti ? [NSString stringWithFormat:@"%@:stage_%ld", taskKey, (long)rTimes] : taskKey;
                        @synchronized(self) {
                            if ([gDailyFailedTasks containsObject:taskKey]) {
                                continue;
                            }
                            NSInteger retries = [gFarmTaskRetryCounts[retryKey] integerValue];
                            if (retries >= 3) {
                                NSLog(@"🌾 [芭芭农场] 任务【%@】(%@) 已经尝试执行 %ld 次但服务端仍未完成，可能需要真实端内页面交互，自动标记跳过避免死循环", taskTitle, retryKey, (long)retries);
                                [self recordStage:[NSString stringWithFormat:@"芭芭农场：“%@”需在界面手动完成（服务端要求真实操作，已跳过）", taskTitle]];
                                [gDailyFailedTasks addObject:taskKey];
                                saveDailyTaskCache();
                                continue;
                            }
                            if (!isMulti && [gDailyCompletedTasks containsObject:taskKey] && ![taskStatus isEqualToString:@"TODO"]) {
                                continue;
                            }
                        }
                        NSInteger seconds = extractTaskBrowseSeconds(t, displayConfig ?: bizInfo, taskTitle);
                        if (seconds <= 0) seconds = 15;
                        id rawJump = displayConfig[@"targetUrl"] ?: bizInfo[@"targetUrl"] ?: bizInfo[@"jumpUrl"] ?: t[@"targetUrl"] ?: t[@"jumpUrl"];
                        NSString *jumpUrl = [rawJump isKindOfClass:NSString.class] ? (NSString *)rawJump : @"";
                        [tasksToQueue addObject:@{
                            @"action": @"browse",
                            @"taskType": taskType,
                            @"sceneCode": sceneCode,
                            @"title": taskTitle,
                            @"awardName": awardDesc,
                            @"browseSeconds": @(seconds),
                            @"jumpUrl": jumpUrl,
                            @"scenePrefix": @"芭芭农场",
                            @"isMultiStage": @(isMulti),
                            @"stageIndex": @(rTimes)
                        }];
                    }
                }
            }
            
            if (tasksToQueue.count > 0) {
                BOOL shouldStart = NO;
                @synchronized(self) {
                    if (!vitalityTaskQueue) vitalityTaskQueue = [NSMutableArray array];
                    for (NSDictionary *task in tasksToQueue) {
                        NSString *tk = [NSString stringWithFormat:@"%@:%@:%@", task[@"sceneCode"], task[@"taskType"], task[@"action"]];
                        BOOL already = NO;
                        for (NSDictionary *q in vitalityTaskQueue) {
                            NSString *qk = [NSString stringWithFormat:@"%@:%@:%@", q[@"sceneCode"], q[@"taskType"], q[@"action"]];
                            if ([qk isEqualToString:tk]) { already = YES; break; }
                        }
                        if (!already) [vitalityTaskQueue addObject:task];
                    }
                    if (!vitalityTaskRunning && vitalityTaskQueue.count > 0) {
                        vitalityTaskRunning = YES;
                        shouldStart = YES;
                    }
                }
                if (shouldStart) {
                    [self recordStage:[NSString stringWithFormat:@"芭芭农场：规划 %lu 项待完成与领肥料操作", (unsigned long)tasksToQueue.count]];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(400 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                        [self executeNextVitalityTask];
                    });
                } else {
                    [self recordStage:[NSString stringWithFormat:@"芭芭农场：已追加 %lu 项肥料任务至执行队列", (unsigned long)tasksToQueue.count]];
                }
            } else {
                if (allFoundTasks.count > 0) {
                    NSLog(@"[AntForestPort] 芭芭农场：当前所有任务奖励已全部领取完毕");
                }
            }
        }
        
        // 5. 自动在 Web 页面上领取当前所有可见的“领取”按钮
        if (self.enableAutoFarmTasks) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self claimAllVisibleFarmRewardsOnWebView];
            });
        }
    } @catch (NSException *e) {
        NSLog(@"[AntForestPort][FarmTask] Exception in handleFarmResponse: %@", e);
    }
}

    


static NSMutableArray<NSString *> *oceanQueue = nil;
static NSString *oceanCurrentUserId = nil;
static BOOL oceanRunning = NO;
static NSUInteger oceanRequestToken = 0;
static NSUInteger oceanCleanedInCurrentRound = 0;
static const NSUInteger kOceanMaxCleanPerRound = 5;

- (void)oceanStopWithReason:(NSString *)reason {
    oceanRunning = NO;
    oceanCurrentUserId = nil;
    oceanRequestToken++;
    [oceanQueue removeAllObjects];
    if (reason.length) [self recordStage:[NSString stringWithFormat:@"神奇海洋 · %@", reason]];
}

- (void)oceanSendNext {
    if (!isWithinTaskActiveHours()) {
        oceanRunning = NO;
        oceanCurrentUserId = nil;
        [oceanQueue removeAllObjects];
        return;
    }
    id bridge = self.oceanBridge ?: self.jsBridge;
    if (!self.enableCleanOcean || !bridge) {
        if (oceanRunning) [self oceanStopWithReason:@"任务已停止或桥接不可用"];
        return;
    }
    
    NSString *today = getCurrentDateString();
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![[defaults stringForKey:@"oceanCleanedDate"] isEqualToString:today]) {
        [defaults setObject:today forKey:@"oceanCleanedDate"];
        [defaults setObject:@[] forKey:@"oceanCleanedFriendsToday"];
        [defaults setBool:NO forKey:@"oceanLimitReachedToday"];
    }
    NSArray *cleanedArr = [defaults arrayForKey:@"oceanCleanedFriendsToday"] ?: @[];
    NSMutableSet *cleanedSet = [NSMutableSet setWithArray:cleanedArr];
    if (cleanedSet.count >= 20 || ([defaults boolForKey:@"oceanLimitReachedToday"] && cleanedSet.count >= 20)) {
        [defaults setBool:YES forKey:@"oceanLimitReachedToday"];
        [self recordStage:@"神奇海洋：今日已帮满 20 位好友清理，已达每日上限"];
        oceanRunning = NO;
        oceanCurrentUserId = nil;
        [oceanQueue removeAllObjects];
        return;
    }
    
    if (oceanCleanedInCurrentRound >= kOceanMaxCleanPerRound) {
        [self recordStage:[NSString stringWithFormat:@"神奇海洋：本轮已成功帮助 %lu 位好友清理，稍后下轮继续", (unsigned long)oceanCleanedInCurrentRound]];
        oceanRunning = NO;
        oceanCurrentUserId = nil;
        [oceanQueue removeAllObjects];
        return;
    }
    
    NSString *nextUid = nil;
    while (oceanQueue.count > 0) {
        NSString *candidate = oceanQueue.firstObject;
        [oceanQueue removeObjectAtIndex:0];
        if (candidate.length && ![candidate isEqualToString:self.myUserId] && ![cleanedSet containsObject:candidate]) {
            nextUid = candidate;
            break;
        }
    }
    
    if (!nextUid.length) {
        oceanRunning = NO;
        oceanCurrentUserId = nil;
        return;
    }
    
    oceanRunning = YES;
    oceanCurrentUserId = nextUid;
    NSUInteger token = ++oceanRequestToken;
    
    [self cleanFriendsOcean:nextUid];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (oceanRunning && token == oceanRequestToken) {
            oceanRunning = NO;
            oceanCurrentUserId = nil;
            double delaySec = 0.5 + (arc4random_uniform(500) / 1000.0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self.enableCleanOcean) [self oceanSendNext];
            });
        }
    });
}

static BOOL oceanPlanLoggedThisRound = NO;

-(void)scanOceanForFriends:(NSArray<NSString *> *)friendIds {
    if (!self.enableCleanOcean || !friendIds.count) return;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        oceanQueue = [NSMutableArray array];
    });
    
    NSString *today = getCurrentDateString();
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![[defaults stringForKey:@"oceanCleanedDate"] isEqualToString:today]) {
        [defaults setObject:today forKey:@"oceanCleanedDate"];
        [defaults setObject:@[] forKey:@"oceanCleanedFriendsToday"];
        [defaults setBool:NO forKey:@"oceanLimitReachedToday"];
    }
    NSArray *cleanedArr = [defaults arrayForKey:@"oceanCleanedFriendsToday"] ?: @[];
    NSMutableSet *cleanedSet = [NSMutableSet setWithArray:cleanedArr];
    if (cleanedSet.count >= 20 || ([defaults boolForKey:@"oceanLimitReachedToday"] && cleanedSet.count >= 20)) return;
    
    NSUInteger added = 0;
    for (NSString *uid in friendIds) {
        if (!uid.length || [uid isEqualToString:self.myUserId]) continue;
        if ([cleanedSet containsObject:uid]) continue;
        if (![oceanQueue containsObject:uid] && ![oceanCurrentUserId isEqualToString:uid]) {
            [oceanQueue addObject:uid];
            added++;
        }
    }
    
    if (!oceanRunning && oceanQueue.count > 0) {
        if (!oceanPlanLoggedThisRound) {
            oceanPlanLoggedThisRound = YES;
            [self recordStage:[NSString stringWithFormat:@"神奇海洋：今日已帮 %lu/20 位好友清理，已规划 %lu 位候选好友（安全随机间隔）", (unsigned long)cleanedSet.count, (unsigned long)oceanQueue.count]];
        }
        [self oceanSendNext];
    }
}

-(void)queryRankPage:(NSInteger)startIndex {
    if (!self.enableAutoCollect || !self.jsBridge) return;
    NSString *version = @"20241025";
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *randNum = [AntForestManager getNumberRandom:16];
    NSString *callbackId = [NSString stringWithFormat:@"rpc_af_silent_rank_%@.%@_p%ld", timeStamp, randNum, (long)startIndex];
    self.lastSilentRankCallbackId = callbackId;
    NSString *arg1 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antmember.forest.h5.queryEnergyRanking\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"rankType\":\"energyRank\",\"periodType\":\"total\",\"version\":\"%@\",\"startIndex\":%ld,\"pageSize\":200,\"contactsStatus\":\"N\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\"}],\"getResponse\":true},\"callbackId\":\"%@\"}]", version, (long)startIndex, callbackId];
    NSString *arg2 = @"https://render.alipay.com/p/yuyan/180020010001247580/home.html";
    [self recordStage:[NSString stringWithFormat:@"请求好友排行榜自动翻页（第 %ld-%ld 位）", (long)startIndex + 1, (long)startIndex + 200]];
    [self safeFlushBridge:[self jsBridge] message:arg1 url:arg2];
}

//查询总排行 可以获取所有人的ID
-(void)queryTotalRank{
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (self.lastPkInteractionTime > 0 && now - self.lastPkInteractionTime < 25.0) {
        [self recordStage:@"诊断 · 好友榜查询延后：用户正在浏览PK榜"];
        return;
    }
    NSString *version = @"20241025";
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:16];
    NSString *callbackId = [NSString stringWithFormat:@"rpc_af_silent_rank_%@.%@", timeStamp, randNum];
    self.lastSilentRankCallbackId = callbackId;
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antmember.forest.h5.queryEnergyRanking\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"rankType\":\"energyRank\",\"periodType\":\"total\",\"version\":\"%@\",\"startNum\":1,\"startIndex\":0,\"pageSize\":200,\"contactsStatus\":\"N\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\"}],\"getResponse\":true},\"callbackId\":\"%@\"}]",version,callbackId];
    NSString *arg2 = @"https://render.alipay.com/p/yuyan/180020010001247580/home.html";
    if([self jsBridge]) {
        [self recordStage:@"请求全量好友排行榜（200位/页）"];
        [self safeFlushBridge:[self jsBridge] message:arg1 url:arg2];
    }
}

//查询 20 个人是否有可领能量球
-(void)queryRobFlag:(NSString*)uids{
    [[AntForestManager sharedLock] lock];
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:16];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.fillUserRobFlag\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"userIdList\":[%@],\"source\":\"chInfo_ch_appcenter__chsub_9patch\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]",uids,timeStamp,randNum];
    NSString *arg2 = @"https://render.alipay.com/p/yuyan/180020010001247580/home.html";
    if([self jsBridge]) {
        [self safeFlushBridge:[self jsBridge] message:arg1 url:arg2];
    }
    double robFlagDelay = 0.15 + (arc4random_uniform(100) / 1000.0);
    [NSThread sleepForTimeInterval:robFlagDelay];
    [[AntForestManager sharedLock] unlock];
}

// 查询已存在的账户名称
-(void)queryAccount:(NSString*)uids{
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:16];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"APSocialNebulaPlugin.queryExistingAccounts\",\"data\":{\"uids\":[%@]},\"callbackId\":\"APSocialNebulaPlugin.queryExistingAccounts_%@.%@\"}]",uids,timeStamp,randNum];
    NSString *arg2 = @"https://render.alipay.com/p/yuyan/180020010001247580/home.html";
    if([self jsBridge]) {
        [self safeFlushBridge:[self jsBridge] message:arg1 url:arg2];
    }
}


-(NSMutableArray*)intArrToStr:(NSArray*)arr{
    // 将每个数字转换为带双引号的字符串
    NSMutableArray *quotedIds = [NSMutableArray array];
    for (NSNumber *number in arr) {
        NSString *quotedString = [NSString stringWithFormat:@"\"%@\"", number];  // 将数字加上双引号
        [quotedIds addObject:quotedString];
    }
    return quotedIds;
}

- (void)scanRankedFriends:(NSArray *)friendIds cycle:(NSUInteger)cycle {
    if (!friendIds.count || !self.enableAutoCollect || !self.jsBridge) {
        [self recordStage:@"诊断 · 排行榜无可扫描好友，转入找能量续查"];
        [self startTakeLookContinuation];
        return;
    }
    [self recordStage:[NSString stringWithFormat:@"诊断 · 排行榜好友扫描就绪（%lu 位），转入找能量续查", (unsigned long)friendIds.count]];
    // 剔除历史遗留的 50 轮 queryRobFlag/queryAccount 冗余请求轰炸，彻底释放 H5 容器并发槽位与 JSBridge 通道
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        if (self.enableAutoCollect && cycle == collectionCycle) {
            [self startTakeLookContinuation];
        }
    });
}


// 每隔300秒一次
-(void)autoCollectBubbles {
    [self autoCollectBubblesWithRush:NO];
}

-(void)autoCollectBubblesWithRush:(BOOL)isRush {
    @try {
        [self probeAndRestoreBridges];
        if (!self.enableAutoCollect || (!self.jsBridge && !self.oceanBridge)) {
            [self recordStage:[NSString stringWithFormat:@"诊断 · 收取未启动：自动收取=%d，森林桥接=%d，海洋桥接=%d", self.enableAutoCollect, self.jsBridge != nil, self.oceanBridge != nil]];
            return;
        }
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (self.isScanRunning) {
            if (self.lastScanStartTime > 0 && now - self.lastScanStartTime > 30.0) {
                [self recordStage:@"诊断 · 检测到前一轮扫描超时挂起（>30s），自动解除死锁并重置状态"];
                self.isScanRunning = NO;
                takeLookRunning = NO;
                takeLookWaitingForFriend = NO;
                takeLookCurrentFriendId = nil;
                selfPriorityPending = NO;
            } else {
                [self recordStage:@"诊断 · 收取跳过：本轮扫描正在执行中"];
                return;
            }
        }
        if (self.lastPkInteractionTime > 0 && now - self.lastPkInteractionTime < kPkInteractionAvoidanceDuration) {
            [self recordStage:@"诊断 · 收取延后：用户正在浏览PK榜，5秒后自动重试"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self.enableAutoCollect && !self.isScanRunning && self.jsBridge) {
                    [self autoCollectBubblesWithRush:isRush];
                }
            });
            return;
        }
        self.lastScanStartTime = now;
        self.isScanRunning = YES;
        
        NSDateFormatter *hourFmt = [[NSDateFormatter alloc] init];
        hourFmt.dateFormat = @"HH:mm";
        NSString *currentHHmm = [hourFmt stringFromDate:[NSDate date]];
        BOOL isMorningRush = isRush || [currentHHmm isEqualToString:@"07:00"];

        oceanCleanedInCurrentRound = 0;
        oceanPlanLoggedThisRound = NO;
        oceanRunning = NO;
        oceanCurrentUserId = nil;
        oceanRequestToken++;
        lastCollectStartedAt = NSDate.date;
        collectionCycle++;
        self.lastRankFetchedIndex = 0;
        sVitalityAutoRefreshRounds = 0;
        initDailyTaskCache();
        @synchronized(self) {
            if (gVitalityTaskRetryCounts) [gVitalityTaskRetryCounts removeAllObjects];
            if (gFarmTaskRetryCounts) [gFarmTaskRetryCounts removeAllObjects];
            for (NSString *key in [gDailyFailedTasks allObjects]) {
                if ([key.lowercaseString containsString:@"taobao"] || [key.lowercaseString containsString:@"tb_"]) {
                    [gDailyFailedTasks removeObject:key];
                }
            }
        }
        NSUInteger cycle = collectionCycle;
        selfPriorityPending = self.enableSelfCollect && (self.jsBridge != nil);
        selfPriorityCycle = cycle;
        [deferredFriendRankIds removeAllObjects];
        deferredRankedFriendIds = nil;
        @synchronized (self) {
            [pendingCollectBubbles removeAllObjects];
            if (!sDoubleCollectCheckedUsers) {
                sDoubleCollectCheckedUsers = [NSMutableSet set];
            } else {
                [sDoubleCollectCheckedUsers removeAllObjects];
            }
        }
        [shieldReportedFriendsInRound removeAllObjects];
        [self recordStage:isMorningRush ? @"⚡️ 早间 07:00 黄金时段：全速全量扫描好友能量" : @"本轮扫描开始"];

        // 1. 发起全量好友排行榜查询（早间 07:00 黄金时段绝对 0 延迟秒级触发！）
        static NSDate *lastRankFetchedDate = nil;
        BOOL isAppInBackground = ([UIApplication sharedApplication].applicationState != UIApplicationStateActive);
        BOOL hasCooldownPassed = (!lastRankFetchedDate || [[NSDate date] timeIntervalSinceDate:lastRankFetchedDate] > 120);
        BOOL isInteractingWithPk = (self.lastPkInteractionTime > 0 && (now - self.lastPkInteractionTime < 25.0));

        BOOL needsRankFetch = !isInteractingWithPk && (
                              isMorningRush || (self.friendsRank.count == 0) ||
                              (hasCooldownPassed && (isAppInBackground || (self.enableAutoRevive && isWithinReviveHours() && reviveDailyCount() < 6))));
        if (self.enableAutoCollect && needsRankFetch && self.jsBridge) {
            lastRankFetchedDate = [NSDate date];
            if (isMorningRush) {
                // 0ms 延迟，首位直接入队发出！
                [self queryTotalRank];
            } else {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                    if (self.enableAutoCollect && cycle == collectionCycle && self.isScanRunning) {
                        [self queryTotalRank];
                    }
                });
            }
        }

        // 2. 发起本人首页能量查询
        if (self.enableSelfCollect && self.jsBridge) {
            dispatch_async(globalSerialQueueQuery, ^{
                [[AntForestManager sharedInstance] queryMyBubbles];
            });
        }

        // 3. 找能量续查调度
        if (self.jsBridge) {
            if (selfPriorityPending) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self releaseSelfPriorityForCycle:cycle reason:@"本人首页回包超时"];
                });
            } else {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(350 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                    if (self.enableAutoCollect && cycle == collectionCycle && self.isScanRunning) {
                        [self startTakeLookContinuation];
                    }
                });
            }
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self.isScanRunning && cycle == collectionCycle) {
                    self.isScanRunning = NO;
                    takeLookRunning = NO;
                    [self recordStage:@"本轮海洋扫描完成"];
                }
            });
        }

        // 4. 日常非能量繁重任务调度（早间高峰期推迟 25 秒，确保能量抢收拥有 100% 独占网络带宽）
        void (^runRoutineTasksBlock)(void) = ^{
            if (!self.enableAutoCollect) return;
            NSString *today = getCurrentDateString();
            if (self.enableCleanOcean && isWithinTaskActiveHours()) {
                static NSString *sLastDayOceanActiveHoursTriggered = nil;
                if (![sLastDayOceanActiveHoursTriggered isEqualToString:today]) {
                    sLastDayOceanActiveHoursTriggered = today;
                    [self recordStage:[NSString stringWithFormat:@"神奇海洋：%@海域垃圾已刷新，正在拉取海洋好友列表与清理海域...", getTaskActiveStartTimeString()]];
                }
                [self cleanMyOceanThoroughly];
                [self queryOceanFriendList];
            }
            if (self.enableAutoOceanTasks && self.oceanBridge) {
                [self queryOceanTaskListWithForce:NO];
            }
            if (self.enableAutoRewardTasks) {
                static NSString *sLastDayActiveHoursTriggered = nil;
                if (isWithinTaskActiveHours()) {
                    if (![sLastDayActiveHoursTriggered isEqualToString:today]) {
                        sLastDayActiveHoursTriggered = today;
                        [self recordStage:[NSString stringWithFormat:@"领奖励：%@活跃期开启，正在刷新拉取今日全新任务与能量签到...", getTaskActiveStartTimeString()]];
                        [self notifyActiveH5PageToRefresh];
                        [self queryVitalityTaskListWithForce:YES];
                    } else {
                        [self queryVitalityTaskListWithForce:YES];
                    }
                } else {
                    BOOL isSignedToday = NO;
                    @synchronized(self) {
                        isSignedToday = [gDailyCompletedTasks containsObject:@"SIGN_TODAY"];
                    }
                    if (!isSignedToday) {
                        static NSTimeInterval sLastMidnightLogTime = 0;
                        NSTimeInterval nowTime = [[NSDate date] timeIntervalSince1970];
                        if (nowTime - sLastMidnightLogTime > 60.0) {
                            sLastMidnightLogTime = nowTime;
                            [self recordStage:@"领奖励：零点跨天检测到今日尚未签到，正在刷新拉取并执行能量签到..."];
                        }
                        [self notifyActiveH5PageToRefresh];
                        [self queryVitalityTaskListWithForce:YES];
                    } else {
                        [self queryVitalityTaskList];
                    }
                }
            }
            if (self.enableAutoAIFish) {
                [self queryAIFishTaskList];
            }
            if (self.enableAutoFarmTasks) {
                [self queryFarmTaskList];
            }
            if (self.enableAutoManor) {
                [self queryManorTaskList];
            }
        };

        if (isMorningRush) {
            [self recordStage:@"⚡️ 早间 07:00 黄金时段：优先极速抢收好友能量，日常繁重任务推迟 25 秒执行"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                runRoutineTasksBlock();
            });
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                runRoutineTasksBlock();
            });
        }

        // 5. 本轮扫描安全看门狗（超时重置所有锁）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.isScanRunning && cycle == collectionCycle) {
                self.isScanRunning = NO;
                takeLookRunning = NO;
                takeLookWaitingForFriend = NO;
                takeLookCurrentFriendId = nil;
                selfPriorityPending = NO;
                [self recordStage:@"诊断 · 本轮扫描达到 35 秒安全超时释放锁"];
            }
        });
        self.failedTimes++;
        
    } @catch (NSException *exception) {
        // 捕获异常的代码
        //FileLog(@"Exception caught: %@", exception);
        [Tool Alert:[exception description]];
    }
}

// 每隔300秒一次
-(void)autoCollectBubblesV1 {
    @try {
        // 查询总排行 获取 AllFriendId MySelfUserId
        [[AntForestManager sharedInstance] queryTotalRank];
        
        // 延时 2 秒，遍历 AllFrinedID 每 20 个一组
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // 查询账户名称
            NSArray *allFriendId = [[[AntForestManager sharedInstance] friendsRank] allKeys];
            NSString *alluid = [[self intArrToStr:allFriendId] componentsJoinedByString:@","];
            [[AntForestManager sharedInstance] queryAccount:alluid];
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                NSInteger count = 0;
                NSInteger delay = 0;
                NSMutableArray *arrUid = [NSMutableArray array];  // 确保初始化 arrUid
                
                // 遍历所有好友 ID，每 20 个为一组
                for (NSNumber *userId in allFriendId) {
                    [arrUid addObject:userId];
                    count++;
                    FileLog(@"count:%ld userId:%@", (long)count, userId);
                    
                    // 每 20 个为一组，开始延时执行
                    if (count % 20 == 0) {
                        delay++;
                        FileLog(@"delay:%d", delay);
                        // 创建 arrUid 的副本，并延迟执行任务
                        NSMutableArray *groupArrUid = [arrUid mutableCopy];
                        // 延迟 3 秒执行每组的任务
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((delay - 1) * 3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            if (arrUid.count > 0) {
                                NSString *uids = [[self intArrToStr:groupArrUid] componentsJoinedByString:@","];
                                FileLog(@"uids:%@", uids);
                                // 执行查询操作
                                [[AntForestManager sharedInstance] queryRobFlag:uids];
                            }
                        });
                        
                        // 清空 arrUid 数组
                        [arrUid removeAllObjects];
                    }
                }
                //最后一组
                if([arrUid count] > 0) {
                    delay++;
                    FileLog(@"last delay:%d", delay);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((delay - 1)* 3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        NSString *uids = [[self intArrToStr:arrUid] componentsJoinedByString:@","];
                        FileLog(@"最后一组uids:%@", uids);
                        // 执行查询操作
                        [[AntForestManager sharedInstance] queryRobFlag:uids];
                        [arrUid removeAllObjects];
                    });
                }
                
                
            });
        });
        
        // 主要是更新标题 失败次数与当前时间间隔
        self.failedTimes++;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"LogUpdated" object:nil];
    } @catch (NSException *exception) {
        // 捕获异常的代码
        FileLog(@"Exception caught: %@", exception);
        [Tool Alert:[exception description]];
    }
}


//自动收集能量每分钟执行一次
-(void)autoCollectBubblesOld{
    @try {
        //1.takeLook 也就是找到一个有能量球的好友 然后查询到这个人的所有能量球(queryFriendBubbles) 能收集的直接一键收集 不能收集的按 uid->bid->{} 存储到 friendBubbles 字典中
        [self takeLook];
        //延时两秒
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            //2.遍历字典树 friendBubbles 中 能领取的执行领取 领取完需要从字典树中移出
            // FileLog(@"anthook friendBubbles: %@",[[AntForestManager sharedInstance] friendsBubbles]);
            NSMutableDictionary *fb = [[AntForestManager sharedInstance] friendsBubbles];
            for(NSString *uid in fb){
                NSMutableDictionary *dict = [fb objectForKey:uid];
                for(NSString *bid in dict) {
                    NSString *overTime = [dict objectForKey:bid]; // 假设获取到的时间戳是字符串类型
                    long long overTimeValue = [overTime longLongValue];
                    // 获取当前时间的毫秒数
                    long long currentTime = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
                    if(overTimeValue < currentTime){
                        //可以执行领取
                        NSString *friendName = [self friendDisplayNameForUser:uid];
                        NSString *targetDesc = [uid isEqualToString:self.myUserId] ? @"自己" : [NSString stringWithFormat:@"好友“%@”", friendName];
                        [self recordStage:[NSString stringWithFormat:@"拾取%@定时成熟的能量球", targetDesc]];
                        [[AntForestManager sharedInstance] collectBubbles:uid bubblesId:bid];
                        [dict removeObjectForKey:bid]; //从字典树中移除
                    } else {
                        //可以考虑做个开关是否展示 数量有点多 更新频繁
                        //NSString *log = [NSString stringWithFormat:@"%@\n能量球等待中: %@|%@",[[AntForestManager sharedInstance] getUserName:uid],bid,convertTimestampToDateString(overTimeValue)];
                        //[[AntForestManager sharedInstance] addLog:log];
                    }
                }
            }
            //主要是更新标题 失败次数与当前时间间隔
            self.failedTimes++;
            [[NSNotificationCenter defaultCenter] postNotificationName:@"LogUpdated" object:nil];
        });
    } @catch (NSException *exception) {
        // 捕获异常的代码
        FileLog(@"Exception caught: %@", exception);
        [Tool Alert:[exception description]];
    }
}

-(NSString*)getUserName:(NSString*)uid {
    @try {
        NSString *name = [self friendDisplayNameForUser:uid];
        return name ?: (uid ?: @"");
    } @catch (NSException *exception) {
        return uid ?: @"";
    }
}

- (void)addLog:(NSString *)logMessage {
    if (!logMessage.length) return;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self addLog:logMessage];
        });
        return;
    }
    
    NSString *cleanMessage = [logMessage stringByReplacingOccurrencesOfString:@"\n收取 · " withString:@"\n"];
    cleanMessage = [cleanMessage stringByReplacingOccurrencesOfString:@"\n收取 ·" withString:@"\n"];
    if ([cleanMessage hasPrefix:@"收取 · "]) {
        cleanMessage = [cleanMessage substringFromIndex:@"收取 · ".length];
    } else if ([cleanMessage hasPrefix:@"收取 ·"]) {
        cleanMessage = [cleanMessage substringFromIndex:@"收取 ·".length];
    }
    
    //日志持久化
    @try {
        // 保留足够的一轮扫描记录，面板仍只显示最近几条。
        NSMutableArray *arrLog = [[AntForestManager sharedInstance] logRecord];
        while(arrLog.count > 100) {
            [arrLog removeObjectAtIndex:0];
        }
        // 添加日志信息到数组中
        [arrLog addObject:cleanMessage];
        
        // 发送通知通知更新文本视图
        [[NSNotificationCenter defaultCenter] postNotificationName:@"LogUpdated" object:nil];
        
        // 异步后台归档落盘，彻底移除主线程 synchronize 强行刷盘导致的 UI 卡顿死锁
        static dispatch_queue_t logSaveQueue = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            logSaveQueue = dispatch_queue_create("com.antforest.logsave", DISPATCH_QUEUE_SERIAL);
        });
        NSArray *copyLogs = [arrLog copy];
        dispatch_async(logSaveQueue, ^{
            @try {
                NSData *data = [NSKeyedArchiver archivedDataWithRootObject:copyLogs requiringSecureCoding:NO error:nil];
                if (data) {
                    [[NSUserDefaults standardUserDefaults] setObject:data forKey:@"logRecord"];
                }
            } @catch (NSException *e) {}
        });
    }
    @catch (NSException *exception) {
        // 捕获异常的代码
        FileLog(@"Exception caught: %@", exception);
        [Tool Alert:[exception description]];
    }
}

- (void)recordCollectedEnergyFromResponse:(id)args {
    if (![args isKindOfClass:NSDictionary.class] && ![args isKindOfClass:NSArray.class]) return;
    NSDictionary *rootDict = [args isKindOfClass:NSDictionary.class] ? args : nil;
    NSString *opType = [NSString stringWithFormat:@"%@", rootDict[@"operationType"] ?: @""];
    NSString *handler = [NSString stringWithFormat:@"%@", rootDict[@"handlerName"] ?: @""];
    BOOL isCollectRPC = [opType containsString:@"collect"] || 
                        [opType containsString:@"settlement"] ||
                        [opType containsString:@"revive"] ||
                        [handler containsString:@"collect"] ||
                        [handler containsString:@"settlement"];
    if (rootDict && opType.length > 0 && !isCollectRPC) return;

    NSMutableArray *pending = [NSMutableArray arrayWithObject:args];
    while (pending.count) {
        id value = pending.lastObject; [pending removeLastObject];
        if ([value isKindOfClass:NSArray.class]) { [pending addObjectsFromArray:value]; continue; }
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *bubble = value;
        for (id child in bubble.allValues) if ([child isKindOfClass:NSDictionary.class] || [child isKindOfClass:NSArray.class]) [pending addObject:child];
        NSNumber *energy = bubble[@"collectedEnergy"];
        BOOL isAnimalEnergy = NO;
        if (!energy || energy.integerValue <= 0) {
            if (isCollectRPC && [bubble[@"energy"] respondsToSelector:@selector(integerValue)]) {
                NSInteger val = [bubble[@"energy"] integerValue];
                if (val > 0 && val <= 2000) {
                    energy = @(val);
                    isAnimalEnergy = YES;
                }
            }
        }
        if (!energy || energy.integerValue <= 0 || energy.integerValue > 2000) continue;
        NSString *userId = [bubble[@"userId"] description] ?: (self.myUserId ?: @"");
        NSString *bubbleId = [bubble[@"id"] description] ?: (isAnimalEnergy ? [NSString stringWithFormat:@"SETTLE_%ld_%ld", (long)[[NSDate date] timeIntervalSince1970], (long)energy.integerValue] : @"");
        NSString *respId = [NSString stringWithFormat:@"%@", rootDict[@"responseId"] ?: (rootDict[@"callbackId"] ?: @"")];
        NSString *key = nil;
        if (respId.length > 0) {
            key = [NSString stringWithFormat:@"%@:%@:%@", respId, bubbleId, energy];
        } else {
            key = [NSString stringWithFormat:@"%@:%@:%ld", userId, bubbleId, (long)energy.integerValue];
        }
        if (bubbleId.length && [recordedCollectedBubbles containsObject:key]) continue;
        if (bubbleId.length) { if (recordedCollectedBubbles.count > 1000) [recordedCollectedBubbles removeAllObjects]; [recordedCollectedBubbles addObject:key]; }
        if (bubbleId.length) {
            @synchronized (self) {
                [pendingCollectBubbles removeObject:[NSString stringWithFormat:@"%@:%@", userId, bubbleId]];
            }
        }
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        if (![[defaults stringForKey:@"todayCollectedEnergyDate"] isEqualToString:getCurrentDateString()]) {
            self.todayCollectedEnergy = 0;
            [defaults setObject:getCurrentDateString() forKey:@"todayCollectedEnergyDate"];
        }
        self.totalCollectedEnergy += energy.integerValue;
        self.todayCollectedEnergy += energy.integerValue;
        [defaults setInteger:self.totalCollectedEnergy forKey:@"totalCollectedEnergy"];
        [defaults setInteger:self.todayCollectedEnergy forKey:@"todayCollectedEnergy"];
        [defaults synchronize];
        BOOL isSelf = [userId isEqualToString:self.myUserId] || isAnimalEnergy;
        NSString *source = @"自己";
        if (isAnimalEnergy) {
            source = @"保护地巡护动物/能量雨";
        } else if (!isSelf) {
            NSDictionary *contact = [self.friendsName[userId] isKindOfClass:NSDictionary.class] ? self.friendsName[userId] : nil;
            NSString *name = [contact[@"displayName"] isKindOfClass:NSString.class] ? contact[@"displayName"] : nil;
            if (!name.length) name = [contact[@"name"] isKindOfClass:NSString.class] ? contact[@"name"] : nil;
            source = name.length ? [NSString stringWithFormat:@"好友\u201c%@\u201d", name] : @"好友";
        }
        NSString *message = isAnimalEnergy
            ? [NSString stringWithFormat:@"成功收取保护地/能量雨能量：%ld g（今日累计 %ld g）", (long)energy.integerValue, (long)self.todayCollectedEnergy]
            : (isSelf
                ? [NSString stringWithFormat:@"成功收取自己能量：%ld g（今日累计 %ld g）", (long)energy.integerValue, (long)self.todayCollectedEnergy]
                : [NSString stringWithFormat:@"成功收取%@的能量：%ld g（今日累计 %ld g）", source, (long)energy.integerValue, (long)self.todayCollectedEnergy]);
        [self recordStage:message];
        
        // 关键增强：适配“能量双击卡”！
        // 若成功收取好友能量，且当前好友在本轮中未执行过双击卡复查，立即在 350ms 后安排二次气泡复查，确保单轮内收满两次！
        if (!isSelf && userId.length > 0 && !isAnimalEnergy && self.isScanRunning && self.enableAutoCollect) {
            BOOL shouldRecheck = NO;
            @synchronized (self) {
                if (!sDoubleCollectCheckedUsers) sDoubleCollectCheckedUsers = [NSMutableSet set];
                if (![sDoubleCollectCheckedUsers containsObject:userId]) {
                    [sDoubleCollectCheckedUsers addObject:userId];
                    shouldRecheck = YES;
                }
            }
            if (shouldRecheck) {
                [self recordStage:[NSString stringWithFormat:@"诊断 · 检测到%@能量收取成功，启动能量双击卡复查...", source]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(350 * NSEC_PER_MSEC)), globalSerialQueueQuery, ^{
                    if (self.enableAutoCollect && self.isScanRunning) {
                        [[AntForestManager sharedInstance] queryFriendsBubbles:userId];
                    }
                });
            }
        }
    }
}

-(void)matchFriendIdAndBubbles:(id)args {
    @try {
        BOOL isTotalRankResponse = NO;
        if ([args isKindOfClass:NSDictionary.class]) {
            NSDictionary *dict = args;
            NSDictionary *resData = [dict[@"resData"] isKindOfClass:NSDictionary.class] ? dict[@"resData"] : nil;
            NSString *respId = [NSString stringWithFormat:@"%@", dict[@"responseId"] ?: (dict[@"callbackId"] ?: @"")];
            NSString *resultCode = [NSString stringWithFormat:@"%@", resData[@"resultCode"] ?: dict[@"resultCode"] ?: resData[@"resultStatus"] ?: dict[@"resultStatus"] ?: @""];
            NSString *memo = [NSString stringWithFormat:@"%@", resData[@"memo"] ?: dict[@"memo"] ?: resData[@"resultMsg"] ?: dict[@"resultMsg"] ?: resData[@"errorMessage"] ?: @""];
            if ([memo containsString:@"操作存在异常"] || [memo containsString:@"请稍后再试"] || [memo containsString:@"频繁"] || [resultCode isEqualToString:@"SECURITY_RISK"] || [resultCode isEqualToString:@"USER_OPERATE_LIMIT"]) {
                static NSDate *lastForestRiskLogDate = nil;
                if (!lastForestRiskLogDate || [[NSDate date] timeIntervalSinceDate:lastForestRiskLogDate] > 300) {
                    lastForestRiskLogDate = [NSDate date];
                    [self recordStage:@"⚠️ 警告 · 服务端提示“近期操作存在异常”，已触发安全熔断暂停本轮扫描（保护账号安全）"];
                }
                self.isScanRunning = NO;
                return;
            }
            NSString *opType = [NSString stringWithFormat:@"%@", dict[@"operationType"] ?: (resData[@"operationType"] ?: (self.lastRpcOperationType ?: @""))];
            NSString *resDesc = [NSString stringWithFormat:@"%@", resData[@"resultDesc"] ?: dict[@"resultDesc"] ?: @""];
            BOOL isOceanSilentResp = [respId containsString:@"af_silent_ocean"];
            BOOL isOceanCleanOp = [dict[@"methodName"] isEqualToString:@"cleanFriendsOcean"] || [dict[@"operationType"] containsString:@"cleanFriendOcean"] || [dict[@"methodName"] isEqualToString:@"cleanOcean"] || [dict[@"operationType"] containsString:@"cleanOcean"] || [opType containsString:@"cleanFriendOcean"] || [opType containsString:@"cleanOcean"];
            BOOL isOceanCleanResp = isOceanSilentResp || isOceanCleanOp || resData[@"cleanRewardVOS"] || resData[@"canClearFriendSeaToday"];
            
            if (isOceanCleanResp && ([resultCode isEqualToString:@"LIMIT_EXCEEDED"] || [resultCode isEqualToString:@"ACCESS_DENIED"] || [resultCode isEqualToString:@"FORBIDDEN"] || [memo containsString:@"拒绝"] || [memo containsString:@"代理"] || [memo containsString:@"风控"])) {
                [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"oceanLimitReachedToday"];
                [self recordStage:@"神奇海洋：收到服务端安全风险拦截，已自动熔断暂停本日清理（保护账号安全）"];
            }
            
            BOOL isOceanLimit = isOceanCleanResp && ([resultCode isEqualToString:@"CLEAN_TIMES_EXCEED"] || [resultCode isEqualToString:@"USER_CLEAN_TIRED"] || [resultCode isEqualToString:@"HELP_CLEAN_LIMIT"] || [resDesc containsString:@"已达20次"] || ([resDesc containsString:@"上限"] && [opType containsString:@"antocean"]));
            if (resData && isOceanCleanResp) {
                NSNumber *canClearToday = resData[@"canClearFriendSeaToday"];
                if ((canClearToday && [canClearToday boolValue] == NO) || isOceanLimit) {
                    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"oceanLimitReachedToday"];
                    [self recordStage:@"神奇海洋：服务端确认今日海域清理已达上限（勤劳的你，明天见～）"];
                    [self oceanStopWithReason:nil];
                    return;
                }
                NSArray *rewards = resData[@"cleanRewardVOS"];
                NSString *cleanedUid = nil;
                if (oceanCurrentUserId.length > 0) {
                    cleanedUid = oceanCurrentUserId;
                } else if ([resData[@"cleanedUserId"] isKindOfClass:NSString.class] && [resData[@"cleanedUserId"] length] > 0) {
                    cleanedUid = resData[@"cleanedUserId"];
                } else if ([dict[@"cleanedUserId"] isKindOfClass:NSString.class] && [dict[@"cleanedUserId"] length] > 0) {
                    cleanedUid = dict[@"cleanedUserId"];
                } else if (self.lastCleanedOceanUserId.length > 0 && ![self.lastCleanedOceanUserId isEqualToString:self.myUserId]) {
                    cleanedUid = self.lastCleanedOceanUserId;
                } else if ([resData[@"userId"] isKindOfClass:NSString.class] && [resData[@"userId"] length] > 0) {
                    cleanedUid = resData[@"userId"];
                }
                self.lastCleanedOceanUserId = nil;
                BOOL isSelfOcean = (!cleanedUid.length || [cleanedUid isEqualToString:self.myUserId]);
                if (oceanCurrentUserId.length > 0 && ![oceanCurrentUserId isEqualToString:self.myUserId]) {
                    cleanedUid = oceanCurrentUserId;
                    isSelfOcean = NO;
                }
                if ([rewards isKindOfClass:NSArray.class] && rewards.count > 0) {
                    NSString *targetName = @"自己";
                    NSInteger currentCleanedCount = 0;
                    if (!isSelfOcean) {
                        NSString *displayName = [self waterDisplayNameForUser:cleanedUid];
                        targetName = displayName.length ? [NSString stringWithFormat:@"好友“%@”", displayName] : @"好友";
                        NSArray *cleanedArr = [[NSUserDefaults standardUserDefaults] arrayForKey:@"oceanCleanedFriendsToday"] ?: @[];
                        NSMutableSet *cleanedSet = [NSMutableSet setWithArray:cleanedArr];
                        if (cleanedUid.length) [cleanedSet addObject:cleanedUid];
                        currentCleanedCount = cleanedSet.count;
                        [[NSUserDefaults standardUserDefaults] setObject:cleanedSet.allObjects forKey:@"oceanCleanedFriendsToday"];
                        if (cleanedSet.count >= 20) {
                            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"oceanLimitReachedToday"];
                            [self recordStage:[NSString stringWithFormat:@"神奇海洋：今日已帮满 20 位好友清理，已达每日上限"]];
                            [self oceanStopWithReason:nil];
                        }
                        oceanCleanedInCurrentRound++;
                    }
                    NSDictionary *first = rewards.firstObject;
                    NSString *name = first[@"name"] ?: @"垃圾";
                    NSArray *attach = [first[@"attachRewardBOList"] isKindOfClass:NSArray.class] ? first[@"attachRewardBOList"] : nil;
                    if (!isSelfOcean) {
                        if (attach.count > 0) {
                            [self recordStage:[NSString stringWithFormat:@"神奇海洋：获得%@的拼图碎片与%@（今日帮 %ld/20 位）", targetName, name, (long)currentCleanedCount]];
                        } else {
                            [self recordStage:[NSString stringWithFormat:@"神奇海洋：清理%@的%@（今日帮 %ld/20 位）", targetName, name, (long)currentCleanedCount]];
                        }
                    } else {
                        if (attach.count > 0) {
                            [self recordStage:[NSString stringWithFormat:@"神奇海洋：获得自己的拼图碎片与%@", name]];
                        } else {
                            [self recordStage:[NSString stringWithFormat:@"神奇海洋：清理自己的%@", name]];
                        }
                    }
                    if (isSelfOcean) {
                        myOceanCleanCount++;
                        if (myOceanCleanCount < 8) {
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                                if (self.enableCleanOcean && (self.jsBridge || self.oceanBridge)) {
                                    [self cleanMyOcean];
                                }
                            });
                        }
                    } else {
                        oceanRunning = NO;
                        oceanCurrentUserId = nil;
                        oceanRequestToken++;
                        double delaySec = 2.5 + (arc4random_uniform(1500) / 1000.0);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            if (self.enableCleanOcean) [self oceanSendNext];
                        });
                    }
                } else if (!isSelfOcean && (oceanRunning || isOceanCleanOp || isOceanSilentResp)) {
                    NSString *displayName = [self waterDisplayNameForUser:cleanedUid];
                    NSString *name = displayName.length ? [NSString stringWithFormat:@"好友“%@”", displayName] : @"好友";
                    NSString *failMsg = resData[@"resultDesc"] ?: resData[@"resultMsg"] ?: dict[@"resultDesc"] ?: dict[@"resultMsg"] ?: @"海域暂无可清理垃圾，尝试下一位";
                    if ([failMsg containsString:@"上限"] || [failMsg containsString:@"已达"] || [failMsg containsString:@"20次"] || [resultCode isEqualToString:@"CLEAN_TIMES_EXCEED"] || [resultCode isEqualToString:@"USER_CLEAN_TIRED"] || [resultCode isEqualToString:@"HELP_CLEAN_LIMIT"]) {
                        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"oceanLimitReachedToday"];
                        [self recordStage:[NSString stringWithFormat:@"神奇海洋：服务端确认今日清理已达上限（%@）", failMsg]];
                        [self oceanStopWithReason:nil];
                    } else {
                        [self recordStage:[NSString stringWithFormat:@"神奇海洋：%@%@", name, failMsg]];
                        oceanRunning = NO;
                        oceanCurrentUserId = nil;
                        oceanRequestToken++;
                        double delaySec = 1.0 + (arc4random_uniform(800) / 1000.0);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            if (self.enableCleanOcean) [self oceanSendNext];
                        });
                    }
                }
            }
            if (!resData && isOceanCleanResp && oceanRunning && oceanCurrentUserId.length > 0) {
                oceanRunning = NO;
                oceanCurrentUserId = nil;
                oceanRequestToken++;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (self.enableCleanOcean) [self oceanSendNext];
                });
            }
            NSArray *list = nil;
            if ([resData isKindOfClass:NSDictionary.class]) {
                list = resData[@"friendList"] ?: resData[@"friendOceanList"] ?: resData[@"friendSeaList"] ?: resData[@"friendListVO"] ?: resData[@"friendInfoList"] ?: resData[@"friends"] ?: resData[@"oceanFriendList"] ?: resData[@"friendUserList"] ?: resData[@"oceanFriends"];
            }
            if (!list && [dict isKindOfClass:NSDictionary.class]) {
                list = dict[@"friendList"] ?: dict[@"friendOceanList"] ?: dict[@"friendSeaList"] ?: dict[@"friendListVO"] ?: dict[@"friendInfoList"] ?: dict[@"friends"] ?: dict[@"oceanFriendList"];
            }
            if (!opType.length) opType = [NSString stringWithFormat:@"%@", dict[@"operationType"] ?: (resData[@"operationType"] ?: (self.lastRpcOperationType ?: @""))];
            BOOL isOceanRespContext = isOceanSilentResp ||
                                      [opType containsString:@"antocean"] ||
                                      resData[@"canClearFriendSeaToday"] || resData[@"canCleanFriendSea"] ||
                                      resData[@"canClearFriendSea"] || resData[@"canClearSea"] ||
                                      resData[@"friendOceanList"] || resData[@"friendSeaList"] ||
                                      resData[@"oceanFriendList"] || resData[@"oceanFriends"] ||
                                      [dict[@"appName"] isEqualToString:@"antocean"] ||
                                      [dict[@"methodName"] isEqualToString:@"cleanFriendsOcean"] ||
                                      [dict[@"methodName"] isEqualToString:@"cleanOcean"];
            if (isOceanRespContext && [list isKindOfClass:NSArray.class] && list.count > 0) {
                NSNumber *canClearFriendSeaToday = resData[@"canClearFriendSeaToday"] ?: resData[@"canCleanFriendSea"] ?: resData[@"canClearFriendSea"] ?: resData[@"canClearSea"];
                NSInteger todayCleaned = [resData[@"todayCleanCount"] integerValue] ?: [resData[@"cleanedCount"] integerValue] ?: [resData[@"todayCleanedCount"] integerValue];
                if ((canClearFriendSeaToday && [canClearFriendSeaToday boolValue] == NO) || todayCleaned >= 20) {
                    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"oceanLimitReachedToday"];
                    [self recordStage:[NSString stringWithFormat:@"神奇海洋：服务端确认今日清理好友已达上限（%ld/20 位）", (long)MAX(20, todayCleaned)]];
                    [self oceanStopWithReason:nil];
                } else {
                    NSMutableArray<NSString *> *cleanableFriends = [NSMutableArray array];
                    for (id f in list) {
                        if ([f isKindOfClass:NSDictionary.class]) {
                            NSString *uid = [AntForestManager extractUserIdFromDictionary:f];
                            BOOL canClean = [f[@"seaCleanable"] boolValue] || [f[@"canClean"] boolValue] || ([f[@"rubbishNumber"] integerValue] > 0) || ([f[@"cleanStatus"] integerValue] == 1);
                            if (uid.length && (canClean || list.count <= 20)) [cleanableFriends addObject:uid];
                        } else if ([f isKindOfClass:NSString.class]) {
                            [cleanableFriends addObject:f];
                        }
                    }
                    if (cleanableFriends.count) {
                        [self scanOceanForFriends:cleanableFriends];
                    }
                }
            }
        }
        if ([args isKindOfClass:NSDictionary.class]) {
            NSDictionary *dict = args;
            NSDictionary *resData = [dict[@"resData"] isKindOfClass:NSDictionary.class] ? dict[@"resData"] : nil;
            [self updateWaterFriendListFromResponse:args];
            if (waterRunning) {
                [self handleWaterResponse:args];
            }
            NSString *opType = [NSString stringWithFormat:@"%@", dict[@"operationType"] ?: (resData[@"operationType"] ?: (self.lastRpcOperationType ?: @""))];
            NSString *respId = [NSString stringWithFormat:@"%@", dict[@"responseId"] ?: (dict[@"callbackId"] ?: @"")];
            BOOL isOurSilentRpc = [respId containsString:@"af_silent_"];
            BOOL isOurSilentRank = [respId containsString:@"af_silent_rank_"];
            
            BOOL isHomePagePayload = (resData[@"userEnergy"] != nil || dict[@"userEnergy"] != nil ||
                                      resData[@"combineHandlerVOMap"][@"userInfo"] != nil || dict[@"combineHandlerVOMap"][@"userInfo"] != nil ||
                                      resData[@"combineHandlerVOMap"][@"userBaseInfo"] != nil || dict[@"combineHandlerVOMap"][@"userBaseInfo"] != nil ||
                                      resData[@"bubbles"] != nil || dict[@"bubbles"] != nil ||
                                      resData[@"wateringBubbles"] != nil || dict[@"wateringBubbles"] != nil);

            BOOL isTaskListPayload = (resData[@"taskInfoList"] != nil || dict[@"taskInfoList"] != nil ||
                                      resData[@"taskList"] != nil || dict[@"taskList"] != nil ||
                                      resData[@"antOceanTaskVOList"] != nil || dict[@"antOceanTaskVOList"] != nil);

            NSString *periodType = resData[@"periodType"] ?: dict[@"periodType"];
            NSString *rankType = resData[@"rankType"] ?: dict[@"rankType"];
            BOOL isEnergyRankingOp = [opType containsString:@"queryEnergyRanking"] &&
                                     ![opType containsString:@"Challenge"] &&
                                     ![opType.lowercaseString containsString:@"pk"];

            // 1. 最高优先级保护：用户手动交互 PK 榜/黄金PK赛/排位赛/1v1能量挑战赛，必须优先识别并直接拦截返回！
            NSString *opTypeLower = [opType lowercaseString];
            NSArray *firstRankList = [resData[@"friendRanking"] isKindOfClass:NSArray.class] ? resData[@"friendRanking"] : ([dict[@"friendRanking"] isKindOfClass:NSArray.class] ? dict[@"friendRanking"] : nil);
            NSDictionary *firstRankItem = ([firstRankList.firstObject isKindOfClass:NSDictionary.class]) ? firstRankList.firstObject : nil;
            BOOL hasFirstItemPkFields = (firstRankItem[@"challengeExpectedSettlementResult"] != nil || firstRankItem[@"challengeRankLevel"] != nil);
            BOOL isPkOrPvp = !isOurSilentRpc && !isHomePagePayload && !isTaskListPayload && (
                              isStrictPkOperationName(opType) ||
                              [opTypeLower containsString:@"pk"] ||
                              [opTypeLower containsString:@"pvp"] ||
                              [opTypeLower containsString:@"challenge"] ||
                              [opTypeLower containsString:@"arena"] ||
                              hasFirstItemPkFields ||
                              resData[@"currentEnergyPvpBattleRecord"] != nil || dict[@"currentEnergyPvpBattleRecord"] != nil ||
                              resData[@"previousEnergyPvpBattleRecord"] != nil || dict[@"previousEnergyPvpBattleRecord"] != nil ||
                              resData[@"accumulativeWinProgress"] != nil || dict[@"accumulativeWinProgress"] != nil ||
                              resData[@"waitToReceiveRewardCount"] != nil || dict[@"waitToReceiveRewardCount"] != nil ||
                              resData[@"waitToReceiveRecordCount"] != nil || dict[@"waitToReceiveRecordCount"] != nil ||
                              resData[@"energyChallengeRank"] != nil || dict[@"energyChallengeRank"] != nil ||
                              resData[@"energyPvpInfo"] != nil || dict[@"energyPvpInfo"] != nil ||
                              resData[@"userPkInfo"] != nil || dict[@"userPkInfo"] != nil ||
                              resData[@"pkRanking"] != nil || dict[@"pkRanking"] != nil ||
                              resData[@"pkRankList"] != nil || dict[@"pkRankList"] != nil ||
                              resData[@"pkDatas"] != nil || dict[@"pkDatas"] != nil ||
                              resData[@"rankDisplayParamsVO"] != nil || dict[@"rankDisplayParamsVO"] != nil ||
                              resData[@"dynamicPromoteVO"] != nil || dict[@"dynamicPromoteVO"] != nil ||
                              resData[@"promoteLineEnergy"] != nil || dict[@"promoteLineEnergy"] != nil ||
                              resData[@"nextRankLevelName"] != nil || dict[@"nextRankLevelName"] != nil ||
                              resData[@"promoteCount"] != nil || dict[@"promoteCount"] != nil ||
                              resData[@"extendInfo"][@"rankHeadPortraitVOS"] != nil || dict[@"extendInfo"][@"rankHeadPortraitVOS"] != nil ||
                              resData[@"rankHeadPortraitVOS"] != nil || dict[@"rankHeadPortraitVOS"] != nil ||
                              resData[@"currentSeasonInfo"] != nil || dict[@"currentSeasonInfo"] != nil ||
                              resData[@"seasonInfo"] != nil || dict[@"seasonInfo"] != nil ||
                              resData[@"challengeRank"] != nil || dict[@"challengeRank"] != nil ||
                              resData[@"pkTaskList"] != nil || dict[@"pkTaskList"] != nil ||
                              resData[@"pkTasks"] != nil || dict[@"pkTasks"] != nil ||
                              (resData[@"myself"] && [resData[@"myself"][@"rank"] integerValue] > 0 && !resData[@"bubbles"] && !resData[@"wateringBubbles"] && !resData[@"userBaseInfo"]));

            if (isPkOrPvp) {
                self.lastPkInteractionTime = [[NSDate date] timeIntervalSince1970];
                // 用户在前端 H5 手动交互 PK 榜/黄金PK赛/排位赛/挑战赛：
                // 保持前端视图完全独立，绝不触发后台气泡匹配、任务刷新、签到、巡护等一切侧链逻辑，彻底杜绝死锁与卡顿！
                [self recordStage:@"诊断 · 捕获PK/排位赛交互回包，保持前端视图独立，跳过自动化逻辑"];
                return;
            }

            // 2. 严格识别真正的“总榜”（queryEnergyRanking + periodType=total，或包含纯净 totalDatas/friendRanking 的非PK榜单回包）：
            // 绝不包含任何 PK/排位/挑战/周榜 结构，既保证真机 transformResponseData 剥离 responseId 时也能自动复活(+5g)，又杜绝被非总榜覆盖
            BOOL hasPureRankData = (resData[@"totalDatas"] != nil || dict[@"totalDatas"] != nil || resData[@"friendRanking"] != nil || dict[@"friendRanking"] != nil);
            isTotalRankResponse = NO;
            if (isOurSilentRank || ((isEnergyRankingOp || hasPureRankData) && (!periodType.length || [periodType isEqualToString:@"total"]) && (!rankType.length || [rankType isEqualToString:@"energyRank"]))) {
                if (!isStrictPkOperationName(opType) &&
                    !hasFirstItemPkFields &&
                    !resData[@"energyChallengeRank"] && !dict[@"energyChallengeRank"] &&
                    !resData[@"energyPvpInfo"] && !dict[@"energyPvpInfo"] &&
                    !resData[@"userPkInfo"] && !dict[@"userPkInfo"] &&
                    !resData[@"pkRanking"] && !dict[@"pkRanking"] &&
                    !resData[@"challengeRank"] && !dict[@"challengeRank"] &&
                    !resData[@"rankDisplayParamsVO"] && !dict[@"rankDisplayParamsVO"] &&
                    !resData[@"dynamicPromoteVO"] && !dict[@"dynamicPromoteVO"] &&
                    !resData[@"promoteLineEnergy"] && !dict[@"promoteLineEnergy"] &&
                    !resData[@"nextRankLevelName"] && !dict[@"nextRankLevelName"] &&
                    !resData[@"promoteCount"] && !dict[@"promoteCount"] &&
                    !resData[@"extendInfo"][@"rankHeadPortraitVOS"] && !dict[@"extendInfo"][@"rankHeadPortraitVOS"] &&
                    !resData[@"rankHeadPortraitVOS"] && !dict[@"rankHeadPortraitVOS"]) {
                    isTotalRankResponse = YES;
                }
            }

            if ([respId containsString:@"revive_"] || [opType containsString:@"protectBubble"] || [dict[@"handlerName"] isEqualToString:@"protectBubble"] || resData[@"protectBubble"] || resData[@"userProtectResult"]) {
                [self handleAutoReviveResponse:args];
            }
            NSArray *taskInfoList = [resData[@"taskInfoList"] isKindOfClass:NSArray.class] ? resData[@"taskInfoList"] : ([dict[@"taskInfoList"] isKindOfClass:NSArray.class] ? dict[@"taskInfoList"] : nil);
            if (resData[@"antOceanTaskVOList"] || [dict[@"antOceanTaskVOList"] isKindOfClass:NSArray.class] || [opType containsString:@"antocean.ocean.h5.queryTaskList"]) {
                [self handleOceanTaskListResponse:resData ?: dict];
            }
            NSString *signStr = [dict[@"data"] isKindOfClass:NSString.class] ? dict[@"data"] : ([resData[@"data"] isKindOfClass:NSString.class] ? resData[@"data"] : nil);
            BOOL isSignDateStr = (signStr.length >= 8 && signStr.length <= 15 && [signStr containsString:@"-"]);
            BOOL isSignResp = (([opType containsString:@"antiep.sign"] || [self.lastRpcOperationType containsString:@"antiep.sign"]) && isSignDateStr);
            BOOL isManualRankRpc = (!isOurSilentRpc && (resData[@"friendRanking"] != nil || resData[@"totalDatas"] != nil || dict[@"friendRanking"] != nil || dict[@"totalDatas"] != nil || isPkOrPvp));
            if (![AntForestManager isManorResponse:args] && ![opType containsString:@"antocean"] && !isManualRankRpc) {
                if (resData[@"forestTasksNew"] || resData[@"energySignVO"] || resData[@"forestSignVOList"] || dict[@"forestSignVOList"] || resData[@"forestSignVO"] || dict[@"forestSignVO"] || resData[@"signModel"] || dict[@"signModel"] || taskInfoList || resData[@"taskList"] || dict[@"taskList"] || resData[@"drawAsset"] || resData[@"drawEntranceVO"] || resData[@"drawActivity"] || resData[@"drawPrize"] || resData[@"drawPrizes"] || resData[@"finishAwardResultVO"] || resData[@"receiveAwardResultVO"] || resData[@"awardResultVO"] || resData[@"finishVO"] || isSignResp || [opType containsString:@"antiep"] || [opType containsString:@"queryTaskList"] || [opType containsString:@"queryCommonSign"] || [opType containsString:@"finishTask"] || [opType containsString:@"receiveTaskAward"] || [opType containsString:@"draw"] || [opType containsString:@"exchangeVitality"] || [resData[@"code"] isEqualToString:@"400000040"] || [resData[@"code"] isEqualToString:@"400000004"] || [resData[@"code"] isEqualToString:@"400000030"] || [resData[@"code"] isEqualToString:@"B000000008"] || [resData[@"desc"] containsString:@"不支持rpc调用"] || [resData[@"desc"] containsString:@"无法领取"] || [dict[@"error"] integerValue] == 3000) {
                    [self handleVitalityTaskListResponse:dict];
                }
                BOOL isForestOp = [opType containsString:@"forest"] || [opType containsString:@"antmember.forest"];
                BOOL isFarmOpOrBridge = [opType containsString:@"farm"] || [opType containsString:@"orchard"] || [opType containsString:@"baba"] ||
                                        (self.farmBridge && self.farmBridge != self.jsBridge);
                BOOL hasFarmExplicitData = resData[@"manureFactory"] || dict[@"manureFactory"] ||
                                           resData[@"balloonCooper"] || dict[@"balloonCooper"] ||
                                           resData[@"helpFarmChannelConfig"] || dict[@"helpFarmChannelConfig"];
                if (self.enableAutoFarmTasks && !isForestOp && (isFarmOpOrBridge || hasFarmExplicitData)) {
                    [self handleFarmResponse:dict ?: resData];
                }
            } else if (self.enableAutoManor) {
                [self handleManorResponse:dict ?: resData];
            }
            
            // 自动识别本人ID
            NSString *curUid = resData[@"userBaseInfo"][@"userId"] ?: dict[@"userBaseInfo"][@"userId"] ?: resData[@"userEnergy"][@"userId"] ?: dict[@"userEnergy"][@"userId"] ?: resData[@"loginUserBaseInfo"][@"userId"] ?: dict[@"loginUserBaseInfo"][@"userId"] ?: resData[@"combineHandlerVOMap"][@"userInfo"][@"userBaseInfo"][@"userId"] ?: dict[@"combineHandlerVOMap"][@"userInfo"][@"userBaseInfo"][@"userId"];
            if (curUid.length) {
                if (!self.myUserId.length) {
                    self.myUserId = curUid;
                    [self recordStage:@"本人账户已识别"];
                }
                [[NSUserDefaults standardUserDefaults] setObject:curUid forKey:@"lastKnownUserId"];
            }
            
            // 巡护动物能量球成功回包校验 (支持新版 collectMonopolyCreatureEnergy 与经典 collectAnimalRobEnergy)
            NSInteger collected = [resData[@"collectedEnergy"] integerValue];
            if (!collected && [dict[@"collectedEnergy"] respondsToSelector:@selector(integerValue)]) {
                collected = [dict[@"collectedEnergy"] integerValue];
            }
            NSString *resResultCode = [NSString stringWithFormat:@"%@", resData[@"resultCode"] ?: dict[@"resultCode"] ?: @""];
            NSString *resMemo = [NSString stringWithFormat:@"%@", resData[@"memo"] ?: dict[@"memo"] ?: resData[@"resultMsg"] ?: dict[@"resultMsg"] ?: @""];
            BOOL isAnimalRpc = [opType containsString:@"collectMonopolyCreatureEnergy"] || 
                               [opType containsString:@"collectAnimalRobEnergy"] ||
                               resData[@"collectedEnergy"] != nil ||
                               dict[@"collectedEnergy"] != nil ||
                               resData[@"creatureCode"] != nil ||
                               dict[@"creatureCode"] != nil;
                               
            if (isAnimalRpc) {
                NSString *respCode = resData[@"creatureCode"] ?: dict[@"creatureCode"];
                BOOL isSuccess = ([resResultCode isEqualToString:@"SUCCESS"] || [resResultCode isEqualToString:@"100"] || [resData[@"success"] boolValue] || [dict[@"success"] boolValue] || collected > 0);
                if (isSuccess) {
                    [self markAnimalEnergyCollectedTodayForCode:respCode name:@"" reason:@"收取成功回包"];
                    NSInteger displayEnergy = (collected > 0) ? collected : 60;
                    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
                    if (![[defaults stringForKey:@"todayCollectedEnergyDate"] isEqualToString:getCurrentDateString()]) {
                        self.todayCollectedEnergy = 0;
                        [defaults setObject:getCurrentDateString() forKey:@"todayCollectedEnergyDate"];
                    }
                    self.totalCollectedEnergy += displayEnergy;
                    self.todayCollectedEnergy += displayEnergy;
                    [defaults setInteger:self.totalCollectedEnergy forKey:@"totalCollectedEnergy"];
                    [defaults setInteger:self.todayCollectedEnergy forKey:@"todayCollectedEnergy"];
                    [defaults synchronize];
                    [self recordStage:[NSString stringWithFormat:@"收取 · 保护地巡护动物能量球已成功收取：%ldg（今日累计 %ldg）", (long)displayEnergy, (long)self.todayCollectedEnergy]];
                } else if ([resResultCode isEqualToString:@"ENERGY_CAN_NOT_COLLECT"] || 
                           [resResultCode isEqualToString:@"ENERGY_HAS_COLLECTED"] || 
                           [resResultCode isEqualToString:@"ENERGY_NOT_EXIST"] ||
                           [resMemo containsString:@"已收"] ||
                           [resMemo containsString:@"不可收"] ||
                           [resMemo containsString:@"不存在"]) {
                    [self markAnimalEnergyCollectedTodayForCode:respCode name:@"" reason:resMemo.length ? resMemo : resResultCode];
                }
            }
            
            // 自动检测森林伙伴/巡护动物 (userCreatureVO，来自 queryUsingCreatureInfo 或 queryHomePage)
            NSDictionary *creatureVO = resData[@"userCreatureVO"] ?: dict[@"userCreatureVO"];
            if ([creatureVO isKindOfClass:NSDictionary.class]) {
                NSString *cCode = creatureVO[@"creatureCode"] ?: @"hongshandongwuyuan#dani";
                NSString *cName = creatureVO[@"displayInfo"][@"creatureNameText"] ?: @"大鲵";
                NSDictionary *robVO = [creatureVO[@"robEnergyVO"] isKindOfClass:NSDictionary.class] ? creatureVO[@"robEnergyVO"] : nil;
                NSInteger yesterdayEnergy = [robVO[@"yesterdayRobEnergy"] integerValue];
                NSString *yesterdayShortDay = [robVO[@"yesterdayShortDay"] isKindOfClass:NSString.class] ? robVO[@"yesterdayShortDay"] : @"";
                BOOL energyIsCollect = [robVO[@"energyIsCollect"] boolValue] || [robVO[@"isCollect"] boolValue] || [robVO[@"isCollected"] boolValue];
                
                NSInteger cEnergy = yesterdayEnergy ?: ([creatureVO[@"levelRobEnergy"] integerValue] ?: [creatureVO[@"initialRobEnergy"] integerValue]);
                if (cEnergy <= 0) cEnergy = 30;
                
                if (energyIsCollect || [self isAnimalEnergyCollectedTodayForCode:cCode name:cName]) {
                    // 今日已收，立即锁定防重
                    [self markAnimalEnergyCollectedTodayForCode:cCode name:cName reason:@"伙伴信息标记今日已收"];
                } else if (yesterdayEnergy > 0) {
                    [self recordStage:[NSString stringWithFormat:@"保护地巡护：探测到%@头顶巡护能量（%ldg），正在通过官方专有接口收取...", cName, (long)yesterdayEnergy]];
                    [self collectMonopolyCreatureEnergyWithCode:cCode shortDay:yesterdayShortDay energy:yesterdayEnergy name:cName];
                } else {
                    [self receiveAnimalEnergyWithPropId:cCode propType:cCode animalId:cCode energy:cEnergy name:cName isCollected:NO];
                }
            }
        }
        [self recordCollectedEnergyFromResponse:args];
        if (!self.enableAutoCollect) return;
        if (args != nil && [args isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dict = args;
            NSDictionary *resData = [dict[@"resData"] isKindOfClass:NSDictionary.class] ? dict[@"resData"] : nil;
            NSString *respId = [NSString stringWithFormat:@"%@", dict[@"responseId"] ?: (dict[@"callbackId"] ?: @"")];
            // 匹配 每日能量签到 (forestSignVOList 或 forestSignVO 或 signModel)
            NSArray *signList = [resData[@"forestSignVOList"] isKindOfClass:NSArray.class] ? resData[@"forestSignVOList"] : ([dict[@"forestSignVOList"] isKindOfClass:NSArray.class] ? dict[@"forestSignVOList"] : nil);
            if (!signList.count && [resData[@"forestSignVO"] isKindOfClass:NSDictionary.class]) {
                signList = @[resData[@"forestSignVO"]];
            } else if (!signList.count && [dict[@"forestSignVO"] isKindOfClass:NSDictionary.class]) {
                signList = @[dict[@"forestSignVO"]];
            }
            if(signList.count) {
                for(NSDictionary *sign in signList) {
                    if (![sign isKindOfClass:NSDictionary.class]) continue;
                    NSString *signId = [sign objectForKey:@"signId"];
                    NSString *sceneCode = [sign objectForKey:@"sceneCode"] ?: @"ANTFOREST_ENERGY_TASK_SIGN";
                    NSString *currSignKey = [sign objectForKey:@"currentSignKey"] ?: getCurrentDateString();
                    NSArray *signRecords = [sign objectForKey:@"signRecords"];
                    for(NSDictionary *record in signRecords){
                        if (![record isKindOfClass:NSDictionary.class]) continue;
                        NSString *signKey = [record objectForKey:@"signKey"];
                        BOOL isSigned = [record[@"signed"] boolValue];
                        if(([signKey isEqualToString:currSignKey] || [signKey isEqualToString:getCurrentDateString()]) && !isSigned){
                            if(signId.length){
                                static NSTimeInterval sLastSignAttemptTime = 0;
                                NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                                @synchronized(self) {
                                    if ([gDailyCompletedTasks containsObject:@"SIGN_TODAY"]) {
                                        [gDailyCompletedTasks removeObject:@"SIGN_TODAY"];
                                        saveDailyTaskCache();
                                    }
                                    if (now - sLastSignAttemptTime > 10.0) {
                                        sLastSignAttemptTime = now;
                                        [self recordStage:@"领奖励：检测到每日能量签到，正在执行签到..."];
                                        [self signVitalityTask:signId sceneCode:sceneCode];
                                    }
                                }
                            }
                        } else if (([signKey isEqualToString:currSignKey] || [signKey isEqualToString:getCurrentDateString()]) && isSigned) {
                            @synchronized(self) {
                                if (![gDailyCompletedTasks containsObject:@"SIGN_TODAY"]) {
                                    [gDailyCompletedTasks addObject:@"SIGN_TODAY"];
                                    saveDailyTaskCache();
                                }
                            }
                        }
                    }
                }
            }
            
            // 检测 combineHandlerVOMap 中的 energyContinuousSign (来自 queryHomePage，停留在森林首页无需打开抽屉即可感知签到状态)
            NSDictionary *combineVOMap = [resData[@"combineHandlerVOMap"] isKindOfClass:NSDictionary.class] ? resData[@"combineHandlerVOMap"] : ([dict[@"combineHandlerVOMap"] isKindOfClass:NSDictionary.class] ? dict[@"combineHandlerVOMap"] : nil);
            NSDictionary *contSignVO = [combineVOMap[@"energyContinuousSign"] isKindOfClass:NSDictionary.class] ? combineVOMap[@"energyContinuousSign"] : nil;
            NSDictionary *daysVO = [contSignVO[@"continuousSignDaysVO"] isKindOfClass:NSDictionary.class] ? contSignVO[@"continuousSignDaysVO"] : nil;
            if (daysVO) {
                BOOL isSigned = [daysVO[@"signed"] boolValue];
                if (!isSigned) {
                    @synchronized(self) {
                        if ([gDailyCompletedTasks containsObject:@"SIGN_TODAY"]) {
                            [gDailyCompletedTasks removeObject:@"SIGN_TODAY"];
                            saveDailyTaskCache();
                        }
                    }
                    if (self.enableAutoRewardTasks) {
                        static NSTimeInterval sLastContSignAttemptTime = 0;
                        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                        if (now - sLastContSignAttemptTime > 5.0) {
                            sLastContSignAttemptTime = now;
                            [self recordStage:@"领奖励：检测到今日尚未签到（首页状态），优先触发签到与任务列表拉取..."];
                            [self queryVitalityTaskListWithForce:YES];
                        }
                    }
                }
            }
            
            // 匹配 takelook 返回的 friendID（仅当插件正在执行后台找能量扫描时才由插件接管并查气泡，避免干扰用户手动找能量跳转）
            NSString *takeLookFriendId = [resData[@"friendId"] isKindOfClass:NSString.class] ? resData[@"friendId"] : ([dict[@"friendId"] isKindOfClass:NSString.class] ? dict[@"friendId"] : nil);
            if(takeLookRunning && takeLookFriendId.length) {
                NSString *friendId = takeLookFriendId;
                if (![self consumeTakeLookFriend:friendId]) return;
                NSMutableDictionary* fb = [[AntForestManager sharedInstance] friendsBubbles];
                //如果字典树中没有
                if(![fb objectForKey:friendId]){
                    [fb setObject:[NSMutableDictionary dictionary] forKey:friendId];
                    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:fb requiringSecureCoding:NO error:nil];
                    [[NSUserDefaults standardUserDefaults] setObject:data forKey:@"friendsBubbles"];
                    [[NSUserDefaults standardUserDefaults] synchronize];
                }
                //继续查这个人的能量球
                dispatch_async(globalSerialQueueQuery, ^{
                    [[AntForestManager sharedInstance] queryFriendsBubbles:friendId];
                });
            }
            // 匹配查询好的返回的所有能量球（兼容 userBaseInfo、userEnergy、loginUserBaseInfo 与 combineHandlerVOMap）
            id bubblesList = dict[@"bubbles"] ?: resData[@"bubbles"];
            id wateringBubblesList = dict[@"wateringBubbles"] ?: resData[@"wateringBubbles"];
            id userInfoMap = dict[@"userBaseInfo"] ?: resData[@"userBaseInfo"] ?: dict[@"loginUserBaseInfo"] ?: resData[@"loginUserBaseInfo"] ?: dict[@"userEnergy"] ?: resData[@"userEnergy"] ?: dict[@"combineHandlerVOMap"][@"userInfo"][@"userBaseInfo"] ?: resData[@"combineHandlerVOMap"][@"userInfo"][@"userBaseInfo"];
            
            if((bubblesList || wateringBubblesList) && userInfoMap) {
                // 1. 提取登录账户 UID (loginUserBaseInfo 恒等于当前登录用户)
                NSString *loginUid = dict[@"loginUserBaseInfo"][@"userId"] ?: resData[@"loginUserBaseInfo"][@"userId"];
                if (loginUid.length) {
                    if (!self.myUserId.length || ![self.myUserId isEqualToString:loginUid]) {
                        self.myUserId = loginUid;
                        [self recordStage:@"本人账户已识别"];
                        [[NSUserDefaults standardUserDefaults] setObject:loginUid forKey:@"lastKnownUserId"];
                    }
                }
                
                // 2. 提取当前气泡所属页面用户的 UID (好友页为好友 UID，本人首页为本人 UID)
                NSString *userId = nil;
                if([dict objectForKey:@"userBaseInfo"]) {
                    NSDictionary *pDic = [dict objectForKey:@"userBaseInfo"];
                    userId = [pDic objectForKey:@"userId"];
                } else if ([resData objectForKey:@"userBaseInfo"]) {
                    NSDictionary *pDic = [resData objectForKey:@"userBaseInfo"];
                    userId = [pDic objectForKey:@"userId"];
                } else if ([dict objectForKey:@"userEnergy"]) {
                    NSDictionary *pDic = [dict objectForKey:@"userEnergy"];
                    userId = [pDic objectForKey:@"userId"];
                } else if ([resData objectForKey:@"userEnergy"]) {
                    NSDictionary *pDic = [resData objectForKey:@"userEnergy"];
                    userId = [pDic objectForKey:@"userId"];
                } else if (resData[@"combineHandlerVOMap"][@"userInfo"][@"userBaseInfo"][@"userId"]) {
                    userId = resData[@"combineHandlerVOMap"][@"userInfo"][@"userBaseInfo"][@"userId"];
                } else if (dict[@"combineHandlerVOMap"][@"userInfo"][@"userBaseInfo"][@"userId"]) {
                    userId = dict[@"combineHandlerVOMap"][@"userInfo"][@"userBaseInfo"][@"userId"];
                }
                
                if (!userId.length) {
                    userId = loginUid ?: self.myUserId;
                }
                if (!userId.length) {
                    [self recordStage:@"诊断 · 气泡回包跳过：账户尚未识别"];
                    return;
                }
                
                NSString *dName = dict[@"userEnergy"][@"displayName"] ?: resData[@"userEnergy"][@"displayName"] ?: dict[@"userBaseInfo"][@"displayName"] ?: resData[@"userBaseInfo"][@"displayName"];
                if (userId.length && [dName isKindOfClass:NSString.class] && dName.length && !self.friendsName[userId]) {
                    self.friendsName[userId] = dName;
                }
                
                // 3. 严格判定是否为本人首页：
                // 如果回包为好友页面（包含 nextAction=="Friend"，或者 userBaseInfo/userEnergy 且不等于本人 UID），则绝非本人首页
                BOOL isFriendPage = [resData[@"nextAction"] isEqualToString:@"Friend"] || 
                                    [dict[@"nextAction"] isEqualToString:@"Friend"] ||
                                    (dict[@"userBaseInfo"][@"userId"] && self.myUserId.length && ![dict[@"userBaseInfo"][@"userId"] isEqualToString:self.myUserId]) ||
                                    (resData[@"userBaseInfo"][@"userId"] && self.myUserId.length && ![resData[@"userBaseInfo"][@"userId"] isEqualToString:self.myUserId]) ||
                                    (dict[@"userEnergy"][@"userId"] && self.myUserId.length && ![dict[@"userEnergy"][@"userId"] isEqualToString:self.myUserId]) ||
                                    (resData[@"userEnergy"][@"userId"] && self.myUserId.length && ![resData[@"userEnergy"][@"userId"] isEqualToString:self.myUserId]);
                
                BOOL mine = !isFriendPage && (
                    (userId.length && self.myUserId.length && [userId isEqualToString:self.myUserId]) ||
                    (!dict[@"userBaseInfo"] && !dict[@"userEnergy"] && !resData[@"userBaseInfo"] && !resData[@"userEnergy"])
                );
                
                if (self.enableAutoRevive && !mine && userId.length) {
                    NSDictionary *userInfo = [dict[@"userBaseInfo"] isKindOfClass:NSDictionary.class] ? dict[@"userBaseInfo"] : nil;
                    NSDictionary *userEnergy = [dict[@"userEnergy"] isKindOfClass:NSDictionary.class] ? dict[@"userEnergy"] : nil;
                    NSDictionary *userForest = [dict[@"userForest"] isKindOfClass:NSDictionary.class] ? dict[@"userForest"] : nil;
                    if (canReviveFriendBubble(dict) || canReviveFriendBubble(resData) || canReviveFriendBubble(userInfo) || canReviveFriendBubble(userEnergy) || canReviveFriendBubble(userForest)) {
                        [self queueAutoReviveForUser:userId];
                    }
                }
                
                //判断是否有能量保护罩
                if (!mine) {
                    NSArray *pArr = [dict objectForKey:@"usingUserProps"] ?: [dict objectForKey:@"usingUserPropsNew"];
                    if (pArr) {
                        for (NSDictionary *dic in pArr) {
                            NSString *type = [dic objectForKey:@"type"] ?: [dic objectForKey:@"propGroup"] ?: @"";
                            if ([type containsString:@"Shield"] || [type containsString:@"shield"]) {
                                [self recordStage:@"诊断 · 好友气泡回包：检测到保护罩，跳过该好友"];
                                static dispatch_once_t onceToken;
                                dispatch_once(&onceToken, ^{
                                    if (!shieldReportedFriendsInRound) {
                                        shieldReportedFriendsInRound = [NSMutableSet set];
                                    }
                                });
                                if (userId.length && ![shieldReportedFriendsInRound containsObject:userId]) {
                                    [shieldReportedFriendsInRound addObject:userId];
                                    NSString *friendName = nil;
                                    id fInfo = userId.length ? self.friendsName[userId] : nil;
                                    if ([fInfo isKindOfClass:NSString.class] && [(NSString *)fInfo length] > 0) {
                                        friendName = (NSString *)fInfo;
                                    } else if ([fInfo isKindOfClass:NSDictionary.class]) {
                                        friendName = [AntForestManager extractNameFromDictionary:fInfo];
                                    }
                                    if (!friendName.length) {
                                        friendName = dict[@"userEnergy"][@"displayName"] ?: dict[@"userBaseInfo"][@"displayName"];
                                    }
                                    if (!friendName.length) {
                                        friendName = @"好友";
                                    }
                                    [self recordStage:[NSString stringWithFormat:@"好友“%@”开启了能量保护罩，已跳过", friendName]];
                                }
                                [self advanceTakeLookForFriend:userId];
                                return;
                            }
                        }
                    }
                }
                
                NSMutableDictionary *dictBubbles = [dict objectForKey:@"bubbles"] ?: [resData objectForKey:@"bubbles"];
                NSUInteger available = 0, waiting = 0;
                for (NSDictionary *bubble in dictBubbles) {
                    if ([[bubble objectForKey:@"collectStatus"] isEqualToString:@"AVAILABLE"]) available++;
                    if ([[bubble objectForKey:@"collectStatus"] isEqualToString:@"WAITING"]) waiting++;
                }
                
                if (mine) {
                    // 经典道具形态的动物巡护 (usingUserPropsNew / usingUserProps)
                    NSArray *props = dict[@"usingUserPropsNew"] ?: dict[@"usingUserProps"] ?: dict[@"loginUserUsingPropNew"];
                    if ([props isKindOfClass:NSArray.class]) {
                        for (NSDictionary *prop in props) {
                            NSString *pGroup = [NSString stringWithFormat:@"%@", prop[@"propGroup"] ?: @""];
                            NSString *pType = [NSString stringWithFormat:@"%@", prop[@"propType"] ?: @""];
                            if ([pGroup isEqualToString:@"animal"] || [pType containsString:@"ANIMAL"] || [pType containsString:@"HANLI"] || [pType containsString:@"dani"] || [pType containsString:@"animal"]) {
                                NSString *propId = prop[@"propId"];
                                NSDictionary *extInfo = nil;
                                if ([prop[@"extInfo"] isKindOfClass:NSString.class]) {
                                    NSData *d = [prop[@"extInfo"] dataUsingEncoding:NSUTF8StringEncoding];
                                    if (d) extInfo = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
                                } else if ([prop[@"extInfo"] isKindOfClass:NSDictionary.class]) {
                                    extInfo = prop[@"extInfo"];
                                }
                                NSDictionary *animalDict = [extInfo[@"animal"] isKindOfClass:NSDictionary.class] ? extInfo[@"animal"] : nil;
                                NSString *animalId = animalDict[@"animalId"] ?: extInfo[@"animalId"] ?: @"";
                                NSString *animalName = animalDict[@"name"] ?: extInfo[@"name"] ?: prop[@"propName"] ?: @"巡护伙伴";
                                
                                // 全面检查已收状态
                                BOOL isCollected = [extInfo[@"isCollected"] boolValue] || 
                                                   [extInfo[@"collected"] boolValue] || 
                                                   [extInfo[@"hasCollected"] boolValue] || 
                                                   [animalDict[@"isCollected"] boolValue] ||
                                                   [animalDict[@"collected"] boolValue] ||
                                                   [animalDict[@"hasCollected"] boolValue] ||
                                                   [extInfo[@"status"] isEqualToString:@"COLLECTED"] ||
                                                   [extInfo[@"collectStatus"] isEqualToString:@"COLLECTED"] ||
                                                   [prop[@"status"] isEqualToString:@"COLLECTED"] ||
                                                   [prop[@"collectStatus"] isEqualToString:@"COLLECTED"] ||
                                                   ([extInfo[@"canCollect"] respondsToSelector:@selector(boolValue)] && ![extInfo[@"canCollect"] boolValue]);
                                
                                // 检查待收能量字段
                                NSNumber *uncollectedNum = extInfo[@"uncollectedEnergy"] ?: animalDict[@"uncollectedEnergy"];
                                if (uncollectedNum != nil && [uncollectedNum integerValue] == 0) {
                                    isCollected = YES;
                                }
                                
                                NSString *targetCode = animalId.length ? animalId : pType;
                                if (isCollected || [self isAnimalEnergyCollectedTodayForCode:targetCode name:animalName]) {
                                    [self markAnimalEnergyCollectedTodayForCode:targetCode name:animalName reason:@"首页道具标记已收取"];
                                    continue;
                                }
                                
                                NSInteger energy = [extInfo[@"energy"] integerValue];
                                if (energy <= 0) energy = [extInfo[@"leftEnergy"] integerValue];
                                if (energy <= 0 && uncollectedNum != nil) energy = [uncollectedNum integerValue];
                                if (energy <= 0) energy = [animalDict[@"energy"] integerValue];
                                
                                // 仅当未收过且无显式 0 能量时，才以能力容量兜底
                                if (energy <= 0) {
                                    NSInteger capacity = [extInfo[@"robEnergyInRound"] integerValue] ?: [animalDict[@"robAbility"][@"robEnergyInRound"] integerValue];
                                    if (capacity > 0) energy = capacity;
                                }
                                
                                [self receiveAnimalEnergyWithPropId:propId propType:pType animalId:animalId energy:energy name:animalName isCollected:NO];
                            }
                        }
                    }
                    // 独立气泡形态的动物巡护 (wateringBubbles / bubbles 中的 animal/creature)
                    NSArray *wbList = dict[@"wateringBubbles"] ?: resData[@"wateringBubbles"];
                    if ([wbList isKindOfClass:NSArray.class]) {
                        for (NSDictionary *wb in wbList) {
                            if (![wb isKindOfClass:NSDictionary.class]) continue;
                            NSString *bizType = [NSString stringWithFormat:@"%@", wb[@"bizType"] ?: @""];
                            NSString *bId = [NSString stringWithFormat:@"%@", wb[@"id"] ?: wb[@"bubbleId"] ?: @""];
                            if ([bizType containsString:@"animal"] || [bizType containsString:@"creature"] || [bId containsString:@"dani"] || [bId containsString:@"hongshan"]) {
                                if ([self isAnimalEnergyCollectedTodayForCode:@"hongshandongwuyuan#dani" name:@"大鲵"]) {
                                    continue;
                                }
                                NSInteger wEnergy = [wb[@"fullEnergy"] integerValue] ?: [wb[@"energy"] integerValue];
                                [self receiveAnimalEnergyWithPropId:bId propType:@"hongshandongwuyuan#dani" animalId:@"hongshandongwuyuan#dani" energy:wEnergy name:@"大鲵" isCollected:NO];
                            }
                        }
                    }
                }
                [self recordStage:[NSString stringWithFormat:@"诊断 · %@气泡回包：总 %lu 个，可收 %lu 个，等待 %lu 个", mine ? @"本人" : @"好友", (unsigned long)dictBubbles.count, (unsigned long)available, (unsigned long)waiting]];
                if (mine && !self.enableSelfCollect) {
                    [self recordStage:@"已跳过本人能量"];
                    [self releaseSelfPriorityForCycle:collectionCycle reason:@"本人收取已关闭"];
                    return;
                }
                // 初始化一个空的可变数组
                NSMutableArray *bidArr = [NSMutableArray array];
                for (NSDictionary *bubble in dictBubbles) {
                    NSString *bUserId = [bubble objectForKey:@"userId"] ?: userId;
                    NSString *bid = [bubble objectForKey:@"id"];
                    NSString *overTime = [bubble objectForKey:@"overTime"];
                    NSString *remainEnergy = [bubble objectForKey:@"remainEnergy"];
                    
                    //可收取直接收取
                    if([[bubble objectForKey:@"collectStatus"] isEqualToString:@"AVAILABLE"]){
                        [bidArr addObject:bid];
                        NSString *friendName = [self friendDisplayNameForUser:bUserId];
                        NSString *targetDesc = [bUserId isEqualToString:self.myUserId] ? @"自己" : [NSString stringWithFormat:@"好友“%@”", friendName];
                        [self recordStage:[NSString stringWithFormat:@"收取%@的能量球（%@g）", targetDesc, remainEnergy]];
                        dispatch_async(globalSerialQueueCollect, ^{
                            [[AntForestManager sharedInstance] collectBubbles:bUserId bubblesId:bid];
                        });
                        
                    }
                    if([[bubble objectForKey:@"collectStatus"] isEqualToString:@"INSUFFICIENT"]){
                        // 能量不足只记录调试日志，避免在主日志面板中刷屏
                        NSLog(@"[AntForestPort] 能量不足: %@, 剩%@g, %@", [self friendDisplayNameForUser:bUserId], remainEnergy, bid);
                    }
                    //等待中放入字典树中
                    if([[bubble objectForKey:@"collectStatus"] isEqualToString:@"WAITING"] && overTime){
                        NSMutableDictionary* fb = [[AntForestManager sharedInstance] friendsBubbles];
                        NSDictionary *myBubble = @{bid:overTime};
                        //无论有没有直接覆盖
                        [fb setObject:myBubble forKey:bUserId];
                        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:fb requiringSecureCoding:NO error:nil];
                        [[NSUserDefaults standardUserDefaults] setObject:data forKey:@"friendsBubbles"];
                        [[NSUserDefaults standardUserDefaults] synchronize];
                        // 等待能量球入库只进系统日志，避免每颗气泡挤爆用户面板
                        NSLog(@"[AntForestPort] 等待能量球入库: %@, %@g, %@", [self friendDisplayNameForUser:bUserId], remainEnergy, bid);
                    }
                    //可帮助直接帮助
                    if([[bubble objectForKey:@"canHelpCollect"] isEqualToNumber:@1]){
                        NSString *friendName = [self friendDisplayNameForUser:bUserId];
                        NSString *targetDesc = [bUserId isEqualToString:self.myUserId] ? @"自己" : [NSString stringWithFormat:@"好友“%@”", friendName];
                        [self recordStage:[NSString stringWithFormat:@"帮助%@收取能量球（%@g）", targetDesc, remainEnergy]];
                    }
                }
                
                // 匹配 wateringBubbles（包含好友浇水赠能、保护地巡护动物每日巡护能量球）
                NSArray *wateringBubbles = dict[@"wateringBubbles"] ?: resData[@"wateringBubbles"];
                if ([wateringBubbles isKindOfClass:NSArray.class]) {
                    static NSMutableSet *collectedWateringBids = nil;
                    static dispatch_once_t wbOnce;
                    dispatch_once(&wbOnce, ^{
                        collectedWateringBids = [NSMutableSet set];
                    });
                    
                    for (NSDictionary *wb in wateringBubbles) {
                        if (![wb isKindOfClass:NSDictionary.class]) continue;
                        NSNumber *bidNum = wb[@"id"] ?: wb[@"bubbleId"];
                        if (bidNum && [bidNum longLongValue] > 0) {
                            NSString *bid = [bidNum stringValue];
                            NSString *bizType = [NSString stringWithFormat:@"%@", wb[@"bizType"] ?: @""];
                            NSString *fullEnergy = [NSString stringWithFormat:@"%@", wb[@"fullEnergy"] ?: wb[@"energy"] ?: @""];
                            
                            // 严防误收与刷屏：
                            // 仅本人首页的赠能/巡护能量，或动物巡护能量，或好友页明确允许代收(canHelpCollect)才收
                            if (mine || [bizType containsString:@"animal"] || [wb[@"canHelpCollect"] isEqualToNumber:@1]) {
                                if ([collectedWateringBids containsObject:bid]) {
                                    continue;
                                }
                                if (collectedWateringBids.count > 500) {
                                    [collectedWateringBids removeAllObjects];
                                }
                                [collectedWateringBids addObject:bid];
                                
                                NSString *targetUid = (mine || [bizType containsString:@"animal"]) ? (self.myUserId.length ? self.myUserId : userId) : (userId ?: self.myUserId);
                                [self recordStage:[NSString stringWithFormat:@"发现赠能/巡护能量（%@g，ID：%@）并自动收取", fullEnergy, bid]];
                                dispatch_async(globalSerialQueueCollect, ^{
                                    [[AntForestManager sharedInstance] collectBubbles:targetUid bubblesId:bid];
                                });
                            }
                        }
                    }
                }
                
                if (mine && selfPriorityPending) {
                    // 这个串行队列中的屏障排在本人的 collect 请求之后，好友请求只能在此后入队。
                    NSUInteger cycle = selfPriorityCycle;
                    dispatch_async(globalSerialQueueCollect, ^{
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self releaseSelfPriorityForCycle:cycle reason:@"本人收取请求已提交"];
                        });
                    });
                }
                [self advanceTakeLookForFriend:userId];
                //                //一键收取 能量球多时 提示不合法
                //                if([bidArr count] > 0 && userId) {
                //                    NSString* bidStr = [bidArr componentsJoinedByString:@","];
                //                    NSString *log = [NSString stringWithFormat:@"%@\n一键收取能量球, %@",[[AntForestManager sharedInstance] getUserName:userId],bidStr];
                //                    [[AntForestManager sharedInstance] addLog:log];
                //                    [[AntForestManager sharedInstance] collectBubbles:userId bubblesId:bidStr];
                //                }
            } else if (takeLookRunning && [respId containsString:@"af_silent_friend_"]) {
                [self advanceTakeLookForFriend:takeLookCurrentFriendId];
            }
            // 匹配用户名
            if([dict objectForKey:@"contactsDicArray"]) {
                NSMutableDictionary* fn = [[AntForestManager sharedInstance] friendsName];
                NSArray *cArr = [dict objectForKey:@"contactsDicArray"];
                for(NSDictionary *cdict in cArr) {
                    NSString *userId = [AntForestManager extractUserIdFromDictionary:cdict];
                    if (userId.length) [fn setObject:cdict forKey:userId];
                }
                NSData *data = [NSKeyedArchiver archivedDataWithRootObject:fn requiringSecureCoding:NO error:nil];
                if (data) {
                    [[NSUserDefaults standardUserDefaults] setObject:data forKey:@"friendsName"];
                    [[NSUserDefaults standardUserDefaults] synchronize];
                }
            }
            // 先查询本人首页；严格的“本人收取完成后再查好友”由独立修复处理。
            if (!resData) resData = [dict[@"resData"] isKindOfClass:NSDictionary.class] ? dict[@"resData"] : nil;
            if(resData && resData[@"myself"]) {
                NSDictionary *myDict = resData[@"myself"];
                NSString *userIdMy = [AntForestManager extractUserIdFromDictionary:myDict] ?: [myDict objectForKey:@"userId"];
                BOOL hadUserIdBefore = (self.myUserId.length > 0);
                if (userIdMy.length) {
                    if (!hadUserIdBefore) {
                        [[AntForestManager sharedInstance] setMyUserId:userIdMy];
                        [self recordStage:@"收取 · 本人账户已识别"];
                        // 首次识别本人账户时，若开启本人收集且本轮扫描执行中，初次补查一次
                        if (self.isScanRunning) {
                            if (self.enableSelfCollect) {
                                dispatch_async(globalSerialQueueQuery, ^{
                                    [[AntForestManager sharedInstance] queryMyBubbles];
                                });
                            }
                            if (self.enableAutoRewardTasks) {
                                dispatch_async(globalSerialQueueQuery, ^{
                                    [[AntForestManager sharedInstance] queryVitalityTaskList];
                                });
                            }
                        }
                    } else {
                        [[AntForestManager sharedInstance] setMyUserId:userIdMy];
                    }
                }
                NSNumber *canCollectEnergy = [myDict objectForKey:@"canCollectEnergy"];
                [self recordStage:[NSString stringWithFormat:@"诊断 · 本人能量状态：%@", [canCollectEnergy isEqualToNumber:@1] ? @"可收" : @"暂无成熟能量"]];
            }
            // 严格隔离榜单类型：仅允许真正的“总榜”（queryEnergyRanking + periodType=total）进入好友总榜缓存与自动收取扫描
            // 彻底杜绝 PK榜/排位赛/挑战榜/周榜 污染总榜并引发循环分页与卡死
            if(isTotalRankResponse && (resData[@"totalDatas"] || dict[@"totalDatas"] || resData[@"friendRanking"] || dict[@"friendRanking"])) {
                NSArray *rankArr = ([resData[@"totalDatas"] isKindOfClass:NSArray.class] && [resData[@"totalDatas"] count] > 0) ? resData[@"totalDatas"] :
                                   (([dict[@"totalDatas"] isKindOfClass:NSArray.class] && [dict[@"totalDatas"] count] > 0) ? dict[@"totalDatas"] :
                                   ([resData[@"friendRanking"] isKindOfClass:NSArray.class] ? resData[@"friendRanking"] :
                                   ([dict[@"friendRanking"] isKindOfClass:NSArray.class] ? dict[@"friendRanking"] : nil)));
                NSUInteger collectable = 0;
                NSUInteger revivable = 0;
                for (NSDictionary *dictRank in rankArr) {
                    if ([[dictRank objectForKey:@"canCollectEnergy"] isEqualToNumber:@1]) collectable++;
                    if (canReviveFriendBubble(dictRank)) revivable++;
                }
                [self recordStage:[NSString stringWithFormat:@"诊断 · 排行榜校验回包：%lu 位，可收 %lu 位，待复活 %lu 位", (unsigned long)rankArr.count, (unsigned long)collectable, (unsigned long)revivable]];
                if (revivable > 0) {
                    [self recordStage:[NSString stringWithFormat:@"复活 · 排行榜扫描发现 %lu 位好友有待复活过期能量(+5g)", (unsigned long)revivable]];
                }
                if (self.enableAutoRevive) {
                    for(NSDictionary *dictRank in rankArr) {
                        NSString *userId = [AntForestManager extractUserIdFromDictionary:dictRank] ?: [dictRank objectForKey:@"userId"];
                        if (!userId.length) continue;
                        NSString *name = [AntForestManager extractNameFromDictionary:dictRank];
                        if (name.length) {
                            NSMutableDictionary *contact = [self.friendsName[userId] mutableCopy] ?: [NSMutableDictionary dictionary];
                            contact[@"displayName"] = name;
                            self.friendsName[userId] = contact;
                        }
                        if (canReviveFriendBubble(dictRank)) {
                            [self queueAutoReviveForUser:userId];
                        }
                    }
                }
                if (self.isScanRunning) {
                    for(NSDictionary *dictRank in rankArr) {
                        NSString *userId = [AntForestManager extractUserIdFromDictionary:dictRank] ?: [dictRank objectForKey:@"userId"];
                        if (!userId.length) continue;
                        BOOL isCollectable = [[dictRank objectForKey:@"canCollectEnergy"] isEqualToNumber:@1];
                        BOOL isReviveable = canReviveFriendBubble(dictRank);
                        if (isCollectable || isReviveable){
                            if (selfPriorityPending) {
                                [deferredFriendRankIds addObject:userId];
                            } else {
                                dispatch_async(globalSerialQueueQuery, ^{
                                    [[AntForestManager sharedInstance] queryFriendsBubbles:userId];
                                });
                            }
                        }
                    }
                }
            }
            //匹配排行（仅在确认是总榜回包时更新 friendsRank 与分页，绝不覆盖其他榜单）
            NSArray *rankTotalArr = isTotalRankResponse ? (([resData[@"totalDatas"] isKindOfClass:NSArray.class] && [resData[@"totalDatas"] count] > 0) ? resData[@"totalDatas"] : (([dict[@"totalDatas"] isKindOfClass:NSArray.class] && [dict[@"totalDatas"] count] > 0) ? dict[@"totalDatas"] : ([resData[@"friendRanking"] isKindOfClass:NSArray.class] ? resData[@"friendRanking"] : ([dict[@"friendRanking"] isKindOfClass:NSArray.class] ? dict[@"friendRanking"] : nil)))) : nil;
            if (rankTotalArr.count > 0) {
                NSMutableDictionary *fr = [[AntForestManager sharedInstance] friendsRank];
                NSMutableDictionary *fn = [[AntForestManager sharedInstance] friendsName];
                BOOL nameUpdated = NO;
                for(NSDictionary *dictTotalRank in rankTotalArr) {
                    NSString *userId = [AntForestManager extractUserIdFromDictionary:dictTotalRank] ?: [dictTotalRank objectForKey:@"userId"];
                    if (!userId.length) continue;
                    if (self.enableAutoRevive && canReviveFriendBubble(dictTotalRank)) {
                        [self queueAutoReviveForUser:userId];
                    }
                    NSString *rank = [dictTotalRank objectForKey:@"rank"];
                    NSString *uid = [AntForestManager extractUserIdFromDictionary:dictTotalRank];
                    if (uid.length) {
                        if (rank) [fr setObject:rank forKey:uid];
                        NSString *name = [AntForestManager extractNameFromDictionary:dictTotalRank];
                        if (name.length) {
                            NSMutableDictionary *contact = [fn[uid] mutableCopy] ?: [NSMutableDictionary dictionary];
                            contact[@"displayName"] = name;
                            fn[uid] = contact;
                            nameUpdated = YES;
                        }
                    }
                }
                NSDictionary *frSnapshot = [fr copy];
                NSDictionary *fnSnapshot = nameUpdated ? [fn copy] : nil;
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                    NSData *rankData = [NSKeyedArchiver archivedDataWithRootObject:frSnapshot requiringSecureCoding:NO error:nil];
                    if (rankData) {
                        [[NSUserDefaults standardUserDefaults] setObject:rankData forKey:@"cachedFriendsRank"];
                    }
                    if (fnSnapshot) {
                        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:fnSnapshot requiringSecureCoding:NO error:nil];
                        if (data) {
                            [[NSUserDefaults standardUserDefaults] setObject:data forKey:@"friendsName"];
                        }
                    }
                });
                if (self.isScanRunning) {
                    self.lastSilentRankCallbackId = nil;
                    if (self.enableCleanOcean && fr.allKeys.count > 0) {
                        [self scanOceanForFriends:fr.allKeys];
                    }
                    // 仅在设置页手动刷新浇水列表时执行分页补全，日常自动扫描绝不自动翻页覆盖
                    BOOL shouldPaginate = waterFriendRefreshPending;
                    if (shouldPaginate) {
                        BOOL hasMore = [resData[@"hasMore"] boolValue] || [resData[@"hasNext"] boolValue];
                        NSInteger nextIndex = [resData[@"nextStartIndex"] integerValue] ?: [resData[@"startIndex"] integerValue] + rankTotalArr.count;
                        if ((hasMore || rankTotalArr.count >= 200) && nextIndex > 0 && nextIndex < 1000) {
                            if (nextIndex > self.lastRankFetchedIndex) {
                                self.lastRankFetchedIndex = nextIndex;
                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1000 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                                    [self queryRankPage:nextIndex];
                                });
                            }
                        }
                    }
                }
            }
            
            
        }
    }
    @catch (NSException *exception) {
        //FileLog(@"Exception caught: %@, reason: %@, stack trace: %@", exception.name, exception.reason, exception.callStackSymbols);
        // 捕获异常的代码
        [Tool Alert:[exception description]];
    }
}



@end
