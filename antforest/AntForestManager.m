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

// 定义一个全局串行队列
dispatch_queue_t globalSerialQueueQuery;
dispatch_queue_t globalSerialQueueCollect;
dispatch_queue_t globalSerialQueueTest;

+(id)sharedInstance{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        afm=[[self alloc]init];
        
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

static BOOL canReviveFriendBubble(NSDictionary *dictRank) {
    if (![dictRank isKindOfClass:NSDictionary.class]) return NO;
    
    // 1. 检查 wateringBubbles 列表中的 fuhuo 气泡或 canProtect 气泡
    NSArray *wBubbles = dictRank[@"wateringBubbles"];
    if ([wBubbles isKindOfClass:NSArray.class]) {
        for (id b in wBubbles) {
            if ([b isKindOfClass:NSDictionary.class]) {
                NSDictionary *ext = [b[@"extInfo"] isKindOfClass:NSDictionary.class] ? b[@"extInfo"] : nil;
                if (ext && (ext[@"notProtectReason"] || (ext[@"restTimes"] && [ext[@"restTimes"] integerValue] <= 0))) {
                    return NO;
                }
                if (b[@"canProtect"] != nil && ![b[@"canProtect"] boolValue]) {
                    return NO;
                }
                if ([b[@"canProtect"] boolValue] || [b[@"canRevive"] boolValue] || [b[@"bizType"] isEqualToString:@"fuhuo"]) {
                    return YES;
                }
            }
        }
    }
    
    // 2. 检查 userEnergy 中的 canProtectBubble
    NSDictionary *ue = [dictRank[@"userEnergy"] isKindOfClass:NSDictionary.class] ? dictRank[@"userEnergy"] : nil;
    if (ue && ([ue[@"canProtectBubble"] boolValue] || [ue[@"canReviveBubble"] boolValue])) return YES;
    
    // 3. 检查常规字段
    for (NSString *key in @[ @"canProtectBubble", @"canProtect", @"protectBubble", @"canProtectEnergy", @"canRevive", @"canReviveBubble", @"giftingEnergy", @"giftEnergy", @"energyRevive", @"reviveBubble", @"hasProtectBubble" ]) {
        id val = dictRank[key];
        if (val && val != NSNull.null) {
            if ([val respondsToSelector:@selector(boolValue)] && [val boolValue]) return YES;
            if ([val isKindOfClass:NSString.class] && ([(NSString *)val length] > 0 && ![(NSString *)val isEqualToString:@"0"] && ([(NSString *)val caseInsensitiveCompare:@"false"] != NSOrderedSame))) return YES;
        }
    }
    id pStatus = dictRank[@"protectStatus"] ?: dictRank[@"reviveStatus"];
    if (pStatus && pStatus != NSNull.null) {
        if ([pStatus respondsToSelector:@selector(integerValue)] && [pStatus integerValue] == 1) return YES;
        if ([pStatus isKindOfClass:NSString.class] && ([(NSString *)pStatus containsString:@"PROTECT"] || [(NSString *)pStatus containsString:@"REVIVE"] || [(NSString *)pStatus containsString:@"CAN"])) return YES;
    }
    return NO;
}

static NSInteger extractRestTimesFromDict(NSDictionary *dict) {
    if (![dict isKindOfClass:NSDictionary.class]) return -1;
    NSArray *wBubbles = dict[@"wateringBubbles"];
    if ([wBubbles isKindOfClass:NSArray.class]) {
        for (id b in wBubbles) {
            if ([b isKindOfClass:NSDictionary.class]) {
                NSDictionary *ext = [b[@"extInfo"] isKindOfClass:NSDictionary.class] ? b[@"extInfo"] : nil;
                if (ext && ext[@"notProtectReason"]) {
                    return 0;
                }
                if (ext && ext[@"restTimes"] != nil) {
                    return [ext[@"restTimes"] integerValue];
                }
                if (b[@"canProtect"] != nil && ![b[@"canProtect"] boolValue]) {
                    return 0;
                }
            }
        }
    }
    return -1;
}

static NSInteger reviveDailyCount(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *today = getCurrentDateString();
    if (![[defaults stringForKey:@"autoReviveDate"] isEqualToString:today]) {
        [defaults setObject:today forKey:@"autoReviveDate"];
        [defaults setInteger:0 forKey:@"autoReviveCount"];
        [reviveQueue removeAllObjects];
        [reviveQueuedIds removeAllObjects];
    }
    return [defaults integerForKey:@"autoReviveCount"];
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
    if (!self.enableAutoRevive || !self.jsBridge) {
        if (reviveRunning) [self reviveStopWithReason:@"任务已停止或桥接不可用"];
        return;
    }
    if (reviveDailyCount() >= 6) {
        [NSUserDefaults.standardUserDefaults setInteger:6 forKey:@"autoReviveCount"];
        [self recordStage:@"复活 · 帮复活能量已达支付宝官方上限（6/6 次）"];
        reviveRunning = NO;
        reviveCurrentUserId = nil;
        [reviveQueue removeAllObjects];
        return;
    }
    if (!reviveQueue.count) { reviveRunning = NO; reviveCurrentUserId = nil; [self reviveRefreshRewardIfNeeded]; return; }
    reviveRunning = YES;
    reviveCurrentUserId = reviveQueue.firstObject;
    [reviveQueue removeObjectAtIndex:0];
    NSUInteger token = ++reviveRequestToken;
    NSString *timestamp = [NSString stringWithFormat:@"%ld", (long)(NSDate.date.timeIntervalSince1970 * 1000)];
    NSString *name = [AntForestManager extractNameFromDictionary:self.friendsName[reviveCurrentUserId]] ?: @"好友";
    NSDictionary *body = @{ @"targetUserId": reviveCurrentUserId, @"version": @"20241025", @"source": @"chInfo_ch_appcenter__chsub_9patch" };
    NSDictionary *data = @{ @"handlerName": @"rpc", @"data": @{ @"operationType": @"alipay.antforest.forest.h5.protectBubble", @"headers": @{ @"source": @"chInfo_ch_appcenter__chsub_9patch", @"ags-source": @"chInfo_ch_appcenter__chsub_9patch" }, @"requestData": @[body], @"getResponse": @YES }, @"callbackId": [NSString stringWithFormat:@"revive_%@.%@", timestamp, [AntForestManager getNumberRandom:12]] };
    NSString *queue1 = waterJSONString(@[data]);
    if (!queue1.length) { [self reviveStopWithReason:@"请求编码失败"]; return; }
    NSString *url = [NSString stringWithFormat:@"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&userId=%@&__webview_options__=bc%%3D3194732&source=chInfo_ch_appcenter__chsub_9patch", reviveCurrentUserId];
    [self recordStage:[NSString stringWithFormat:@"复活 · 请求帮助好友“%@”复活能量", name]];
    [self.jsBridge _doFlushMessageQueue:queue1 url:url];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (reviveRunning && token == reviveRequestToken) [self reviveStopWithReason:@"回包超时，已停止"];
    });
}

- (void)queueAutoReviveForUser:(NSString *)userId {
    if (!self.enableAutoRevive || !userId.length || [userId isEqualToString:self.myUserId]) return;
    if (reviveDailyCount() >= 6) return;
    if (reviveRunning && [reviveCurrentUserId isEqualToString:userId]) return;
    if ([reviveQueue containsObject:userId]) return;
    if ([reviveQueuedIds containsObject:userId]) return;
    NSString *name = [AntForestManager extractNameFromDictionary:self.friendsName[userId]] ?: @"好友";
    [self recordStage:[NSString stringWithFormat:@"复活 · 发现好友“%@”有待复活能量，加入复活队列", name]];
    [reviveQueue addObject:userId];
    if (!reviveRunning) [self reviveSendNext];
}

- (void)handleAutoReviveResponse:(id)args {
    if (!reviveRunning || ![args isKindOfClass:NSDictionary.class]) return;
    NSDictionary *resData = [(NSDictionary *)args[@"resData"] isKindOfClass:NSDictionary.class] ? args[@"resData"] : ([args isKindOfClass:NSDictionary.class] ? args : nil);
    if (!resData) return;
    NSString *name = [AntForestManager extractNameFromDictionary:self.friendsName[reviveCurrentUserId]] ?: @"好友";
    if (waterResponseSucceeded(resData) || [resData[@"success"] boolValue] || [[resData[@"resultCode"] description] isEqualToString:@"SUCCESS"]) {
        NSInteger count = reviveDailyCount();
        if (reviveCurrentUserId.length && ![reviveQueuedIds containsObject:reviveCurrentUserId]) {
            [reviveQueuedIds addObject:reviveCurrentUserId];
            count++;
            [NSUserDefaults.standardUserDefaults setInteger:MIN((NSInteger)6, count) forKey:@"autoReviveCount"];
        }
        [self recordStage:[NSString stringWithFormat:@"复活 · 成功帮助好友“%@”复活能量（今日 %ld/6 次）", name, (long)MIN((NSInteger)6, count)]];
        reviveRewardRefreshNeeded = YES;
        reviveRunning = NO;
        reviveCurrentUserId = nil;
        reviveRequestToken++;
        double delaySec = 1.5 + (arc4random_uniform(1500) / 1000.0);
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
            double delaySec = 1.2 + (arc4random_uniform(1000) / 1000.0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self.enableAutoRevive) [self reviveSendNext];
            });
            return;
        }
        if ([code containsString:@"LIMIT"] || [code containsString:@"EXCEED"] || [code containsString:@"OVER"] || [code containsString:@"TIRED"] || [code isEqualToString:@"PROTECT_REBORN_TIRED"]) {
            [NSUserDefaults.standardUserDefaults setInteger:6 forKey:@"autoReviveCount"];
            [self recordStage:[NSString stringWithFormat:@"复活 · 帮复活能量已达支付宝官方上限（今天已用完，明天再继续吧）"]];
            reviveRunning = NO;
            reviveCurrentUserId = nil;
            reviveRequestToken++;
            [reviveQueue removeAllObjects];
            return;
        }
        if (reviveCurrentUserId.length) [reviveQueuedIds addObject:reviveCurrentUserId];
        [self recordStage:[NSString stringWithFormat:@"复活 · 帮助好友“%@”复活回包：%@，尝试下一位", name, waterResponseSummary(resData)]];
        reviveRunning = NO;
        reviveCurrentUserId = nil;
        reviveRequestToken++;
        double delaySec = 1.2 + (arc4random_uniform(1000) / 1000.0);
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
    NSString *url = waterCurrentUserId.length ? [NSString stringWithFormat:@"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&userId=%@&__webview_options__=bc%%3D3194732&source=chInfo_ch_appcenter__chsub_9patch&fromAct=TAKE_LOOK", waterCurrentUserId] : @"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&__webview_options__=bc%3D3194732";
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
    self.scheduledWaterTimer = [NSTimer scheduledTimerWithTimeInterval:15 target:self selector:@selector(checkScheduledWater) userInfo:nil repeats:YES];
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
    NSArray *kept = [self.waterFriendIds filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *uid, __unused NSDictionary *bindings) { return self.friendsRank[uid] != nil; }]];
    if (kept.count != self.waterFriendIds.count) {
        self.waterFriendIds = kept;
        [[NSUserDefaults standardUserDefaults] setObject:kept forKey:@"waterFriendIds"];
        [self recordStage:@"浇水 · 已移除不在总榜内的好友选择"];
    }
    [self recordStage:[NSString stringWithFormat:@"浇水 · 好友列表刷新完成：%lu 位", (unsigned long)self.friendsRank.count]];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"WaterFriendListUpdated" object:nil];
}

- (void)releaseSelfPriorityForCycle:(NSUInteger)cycle reason:(NSString *)reason {
    if (!selfPriorityPending || selfPriorityCycle != cycle) return;
    selfPriorityPending = NO;
    NSArray<NSString *> *friendIds = deferredFriendRankIds.copy;
    NSArray<NSString *> *rankedIds = deferredRankedFriendIds;
    [deferredFriendRankIds removeAllObjects];
    deferredRankedFriendIds = nil;
    [self recordStage:[NSString stringWithFormat:@"本人优先完成，开始好友扫描（%@）", reason]];
    for (NSString *friendId in friendIds) {
        dispatch_async(globalSerialQueueQuery, ^{
            [self queryFriendsBubbles:friendId];
        });
    }
    if (rankedIds.count) [self scanRankedFriends:rankedIds cycle:cycle];
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
        [log containsString:@"\"safeArea\""]) {
        return YES;
    }
    return NO;
}

- (void)recordProbeLog:(NSString *)log {
    if (!log.length) return;
    if (isNoiseProbeLog(log)) return; // 过滤掉无关的营销游戏列表与系统UI探针
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        patrolProbeLogs = [NSMutableArray array];
    });
    NSString *timeStr = getCurrentDateTimeString();
    NSString *entry = [NSString stringWithFormat:@"[%@] %@", timeStr, log];
    @synchronized (patrolProbeLogs) {
        [patrolProbeLogs addObject:entry];
        if (patrolProbeLogs.count > 1000) {
            [patrolProbeLogs removeObjectsInRange:NSMakeRange(0, patrolProbeLogs.count - 1000)];
        }
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        @try {
            NSString *docPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            NSString *filePath = [docPath stringByAppendingPathComponent:@"AntForestPatrolProbe.log"];
            NSFileManager *fm = [NSFileManager defaultManager];
            
            // 文件大小超 10MB 时自动滚动裁剪，保证测试数据完整性的同时防止无限膨胀
            NSDictionary *attrs = [fm attributesOfItemAtPath:filePath error:nil];
            if (attrs && [attrs fileSize] > 10 * 1024 * 1024) {
                NSString *content = [NSString stringWithContentsOfFile:filePath encoding:NSUTF8StringEncoding error:nil];
                NSArray *lines = [content componentsSeparatedByString:@"\n\n"];
                if (lines.count > 500) {
                    NSArray *tailLines = [lines subarrayWithRange:NSMakeRange(lines.count - 500, 500)];
                    NSString *newContent = [tailLines componentsJoinedByString:@"\n\n"];
                    [newContent writeToFile:filePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
                }
            }
            
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:filePath];
            if (!handle) {
                [fm createFileAtPath:filePath contents:nil attributes:nil];
                handle = [NSFileHandle fileHandleForWritingAtPath:filePath];
            }
            [handle seekToEndOfFile];
            [handle writeData:[[entry stringByAppendingString:@"\n\n"] dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        } @catch (NSException *e) {}
    });
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
}

-(void)startAutoCollectTimerWithInterval:(NSTimeInterval)interval{
    if (self.autoCollectTimer.isValid && self.collectInterval == interval) {
        return;
    }
    [self.autoCollectTimer invalidate];
    self.autoCollectTimer = nil;
    self.collectInterval = interval;
    self.failedTimes = 0; //每次重新启动定时器时 失败次数均要置 0
    [self recordStage:[NSString stringWithFormat:@"后台循环已启动（%ld 分钟）", (long)MAX(1, interval / 60)]];
    
    // 创建新的定时器
    self.autoCollectTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                             target:self
                                                           selector:@selector(autoCollectBubbles)
                                                           userInfo:nil
                                                            repeats:YES];
    [self.autoCollectTimer fire];
}

-(void)stopAutoCollectTimer {
    [self.autoCollectTimer invalidate];
    self.autoCollectTimer = nil;
}

-(void)startScheduledCollectTimer {
    [self.scheduledCollectTimer invalidate];
    self.scheduledCollectTimer = [NSTimer scheduledTimerWithTimeInterval:15
                                                                    target:self
                                                                  selector:@selector(checkScheduledCollect)
                                                                  userInfo:nil
                                                                   repeats:YES];
    [self checkScheduledCollect];
}

-(void)checkScheduledCollect {
    if (!self.enableAutoCollect || !self.enableScheduledCollect) return;
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"HH:mm";
    NSString *time = [formatter stringFromDate:NSDate.date];
    if (![self.scheduledTimes containsObject:time]) return;
    formatter.dateFormat = @"yyyy-MM-dd HH:mm";
    NSString *minute = [formatter stringFromDate:NSDate.date];
    if ([lastScheduledMinute isEqualToString:minute]) return;
    lastScheduledMinute = minute;
    [self recordStage:@"定时收取开始"];
    [self autoCollectBubbles];
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
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.takeLook\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"skipUsers\":%@,\"version\":\"%@\",\"contactsStatus\":\"N\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]",skipUsersJSON,version,timeStamp,randNum];
    NSString *arg2 = @"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&__webview_options__=bc%3D3194732";
    
    if([self jsBridge]) {
        [self recordStage:[NSString stringWithFormat:@"诊断 · 请求找能量续查：已跳过 %lu 位", (unsigned long)visitedFriends.count]];
        [[self jsBridge] _doFlushMessageQueue:arg1 url:arg2];
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
            self.isScanRunning = NO;
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
            self.isScanRunning = NO;
            [self recordStage:@"本轮扫描完成"];
            return NO;
        }
        [takeLookVisitedFriends addObject:friendId];
        takeLookCurrentFriendId = friendId;
        [self recordStage:[NSString stringWithFormat:@"诊断 · 找能量候选：第 %lu 轮第 %lu 位（累计 %lu 位）", (unsigned long)takeLookPass, (unsigned long)takeLookRounds, (unsigned long)takeLookTotalRounds]];
        return YES;
    }
}

-(void)advanceTakeLookForFriend:(NSString *)friendId {
    @synchronized (self) {
        if (!takeLookRunning || ![takeLookCurrentFriendId isEqualToString:friendId]) return;
        takeLookCurrentFriendId = nil;
    }
    // 收取请求在全局串行队列中发送；以该队列的栅栏作为下一位候选的起点，避免与前一位的多颗气泡请求重叠。
    dispatch_async(globalSerialQueueCollect, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            [self recordStage:@"诊断 · 当前候选收取队列已完成，继续下一位"];
            [self requestNextTakeLook];
        });
    });
}

static NSString *sLastAnimalEnergyCollectedDate = nil;

-(void)receiveAnimalEnergyWithPropId:(NSString *)propId propType:(NSString *)propType animalId:(NSString *)animalId energy:(NSInteger)energy name:(NSString *)name isCollected:(BOOL)isCollected {
    if ((!self.enableAutoCollect && !self.enableSelfCollect && !self.enableAutoPatrolNew) || !self.jsBridge) return;
    NSString *pType = propType ?: @"";
    NSString *aId = animalId ?: @"";
    NSString *pId = propId ?: @"";
    NSString *aName = name.length ? name : @"巡护伙伴";
    
    // 如果今日已经确认成功收取完毕，直接跳过并节流提示
    NSString *today = getCurrentDateString();
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *savedAnimalDate = [defaults stringForKey:@"todayAnimalEnergyCollectedDate"];
    if (isCollected || [today isEqualToString:savedAnimalDate]) {
        static NSTimeInterval lastAnimalNoEnergyLogTime = 0;
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - lastAnimalNoEnergyLogTime > 300.0) { // 5分钟节流提示
            lastAnimalNoEnergyLogTime = now;
            [self recordStage:[NSString stringWithFormat:@"保护地巡护：%@今日能量已收取（待明日产生）", aName]];
        }
        return;
    }
    
    // 节流：两次尝试收取至少间隔 5 秒，避免高频并发
    static NSTimeInterval sLastAnimalAttemptTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - sLastAnimalAttemptTime < 5.0) return;
    sLastAnimalAttemptTime = now;
    
    // 待收巡护伙伴能量
    NSString *energyDesc = (energy > 0) ? [NSString stringWithFormat:@"（%ldg）", (long)energy] : @"";
    [self recordStage:[NSString stringWithFormat:@"保护地巡护：正在收取%@能量%@...", aName, energyDesc]];
    
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *rand1 = [AntForestManager getNumberRandom:15];
    NSString *rand2 = [AntForestManager getNumberRandom:15];
    NSString *arg2 = @"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&__webview_options__=bc%3D3194732";
    
    NSString *targetId = aId.length ? aId : (pId.length ? pId : (pType.length ? pType : @"hongshandongwuyuan#dani"));
    if (![targetId containsString:@"#"]) {
        targetId = @"hongshandongwuyuan#dani";
    }
    NSString *actualPropId = pId.length ? pId : targetId;
    NSString *actualAnimalId = aId.length ? aId : targetId;
    NSString *actualCreatureCode = pType.length ? pType : targetId;
    NSString *effectiveUid = self.myUserId.length ? self.myUserId : ([defaults stringForKey:@"lastKnownUserId"] ?: @"");
    
    // 采用官方安全气泡收取接口，并添加 showError:false 与 showLoading:false 杜绝任何原生错误弹窗
    NSString *argCol = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antmember.forest.h5.collectEnergy\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"userId\":\"%@\",\"bubbleIds\":[\"%@\"],\"propId\":\"%@\",\"animalId\":\"%@\",\"creatureCode\":\"%@\",\"bizType\":\"animal\",\"fromAct\":\"HOME\",\"version\":\"20241025\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", effectiveUid, targetId, actualPropId, actualAnimalId, actualCreatureCode, timeStamp, rand2];
    [self.jsBridge _doFlushMessageQueue:argCol url:arg2];
}

-(void)receiveAnimalEnergyWithPropId:(NSString *)propId propType:(NSString *)propType animalId:(NSString *)animalId {
    [self receiveAnimalEnergyWithPropId:propId propType:propType animalId:animalId energy:0 name:@"" isCollected:NO];
}

-(void)receiveAnimalPartnerEnergy {
    // 留空由 queryHomePage 回包中的 usingUserPropsNew 精准驱动
}

static NSTimeInterval lastMyBubblesQueryTime = 0;

-(void)queryMyBubbles {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - lastMyBubblesQueryTime < 3.0) return;
    lastMyBubblesQueryTime = now;
    
    [self recordStage:@"请求本人首页（含赠能）"];
    [[AntForestManager sharedLock] lock];
    
    NSString *version = @"20241025";
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:16];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.queryHomePage\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"version\":\"%@\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"configVersionMap\":{\"wateringBubbleConfig\":\"0\"},\"skipWhackMole\":false,\"activityParam\":{}}]},\"callbackId\":\"rpc_%@.%@\"}]",version,timeStamp,randNum];
    NSString *arg2 = [NSString stringWithFormat:@"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&__webview_options__=bc%%3D3194732"];
    
    if([self jsBridge]) {
        [[self jsBridge] _doFlushMessageQueue:arg1 url:arg2];
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
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.queryFriendHomePage\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"userId\":\"%@\",\"version\":\"%@\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"fromAct\":\"TAKE_LOOK\",\"configVersionMap\":{\"wateringBubbleConfig\":\"0\"},\"skipWhackMole\":false,\"activityParam\":{},\"currentEnergy\":99999999,\"currentVitalityAmount\":8888888}]},\"callbackId\":\"rpc_%@.%@\"}]",friendId,version,timeStamp,randNum];
    NSString *arg2 = [NSString stringWithFormat:@"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&userId=%@&__webview_options__=bc%%3D3194732&source=chInfo_ch_appcenter__chsub_9patch&fromAct=TAKE_LOOK",friendId];
    
    if([self jsBridge]) {
        [self recordStage:@"诊断 · 请求好友气泡"];
        [[self jsBridge] _doFlushMessageQueue:arg1 url:arg2];
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
    NSString *arg2 = [NSString stringWithFormat:@"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&userId=%@&__webview_options__=bc%%3D3194732&source=chInfo_ch_appcenter__chsub_9patch&fromAct=TAKE_LOOK", userId];
    if([self jsBridge]) {
        [self recordStage:[NSString stringWithFormat:@"诊断 · 请求收取能量：第 %lu 轮，待确认 %lu 笔", (unsigned long)collectionCycle, (unsigned long)pendingCollectBubbles.count]];
        [[self jsBridge] _doFlushMessageQueue:arg1 url:arg2];
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

//复活能量 执行不成功 不知道是不是 检测了什么事件
-(void)reviveEnergy:(NSString*)uid signId:(NSString*)signId {
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:15];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antiep.sign\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"source\":\"ANTFOREST\",\"sceneCode\":\"ANTFOREST_ENERGY_SIGN\",\"requestType\":\"rpc\",\"userId\":\"%@\",\"entityId\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]",uid,signId,timeStamp,randNum];
    NSString *arg2 = [NSString stringWithFormat:@"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&__webview_options__=bc%%3D3194732"];
    if([self jsBridge]) {
        [self reportClickTime];
        [[self jsBridge] _doFlushMessageQueue:arg1 url:arg2];
        //FileLog(@"anthook reviveEnergy: %@ | [%@] ",uid,signId);
    }
}

static NSInteger myOceanCleanCount = 0;
static NSMutableDictionary *friendOceanCleanCounts = nil;

-(void)cleanMyOceanThoroughly {
    if (!self.enableCleanOcean || !self.jsBridge) return;
    myOceanCleanCount = 0;
    [self cleanMyOcean];
}

//清理自己的海域
-(void)cleanMyOcean{
    if (!self.myUserId.length) return;
    self.lastCleanedOceanUserId = self.myUserId;
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:15];
    NSString *randNum2=[AntForestManager getNumberRandom:16];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antocean.ocean.h5.cleanOcean\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"cleanedUserId\":\"%@\",\"source\":\"ANT_FOREST\",\"uniqueId\":\"%@%@\"}],\"appName\":\"antocean\",\"facadeName\":\"InteractController\",\"methodName\":\"cleanOcean\",\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]",self.myUserId,timeStamp,randNum,timeStamp,randNum2];
    NSString *arg2 = [NSString stringWithFormat:@"https://2021003115672468.h5app.alipay.com/www/index.html"];
    id bridge = self.oceanBridge ?: self.jsBridge;
    if(bridge) {
        [bridge _doFlushMessageQueue:arg1 url:arg2];
    }
}

//清理朋友的海域
-(void)cleanFriendsOcean:(NSString*)uid{
    if (!uid.length) return;
    self.lastCleanedOceanUserId = uid;
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:15];
    NSString *randNum2=[AntForestManager getNumberRandom:16];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antocean.ocean.h5.cleanFriendOcean\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"cleanedUserId\":\"%@\",\"source\":\"ANT_FOREST\",\"uniqueId\":\"%@%@\"}],\"appName\":\"antocean\",\"facadeName\":\"InteractController\",\"methodName\":\"cleanFriendsOcean\",\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]",uid,timeStamp,randNum,timeStamp,randNum2];
    NSString *arg2 = [NSString stringWithFormat:@"https://2021003115672468.h5app.alipay.com/www/index.html?fromAct=SAIL_AWAY&userId=%@&interactFlags=&source=ANT_FOREST&__webview_options__=ttb%%3Dauto%%26pd%%3DNO%%26bc%%3D1324950",uid];
    id bridge = self.oceanBridge ?: self.jsBridge;
    if(bridge) {
        [bridge _doFlushMessageQueue:arg1 url:arg2];
    }
}

-(void)queryOceanFriendList {
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
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antocean.ocean.h5.queryFriendList\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"source\":\"ANT_FOREST\"}],\"appName\":\"antocean\",\"facadeName\":\"InteractController\",\"methodName\":\"queryFriendList\",\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, randNum];
    NSString *arg2 = @"https://2021003115672468.h5app.alipay.com/www/index.html";
    id bridge = self.oceanBridge ?: self.jsBridge;
    if(bridge) {
        [self recordStage:@"请求神奇海洋好友列表"];
        [bridge _doFlushMessageQueue:arg1 url:arg2];
        dispatch_async(globalSerialQueueQuery, ^{
            [self cleanMyOcean];
        });
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

static void initDailyTaskCache(void) {
    NSString *today = getCurrentDateString();
    if (![gDailyTaskDate isEqualToString:today] || !gDailyCompletedTasks || !gDailyFailedTasks) {
        gDailyTaskDate = today;
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSString *savedDate = [defaults stringForKey:@"vitality_task_cache_date"];
        if ([savedDate isEqualToString:today]) {
            NSArray *completed = [defaults objectForKey:@"vitality_daily_completed"];
            gDailyCompletedTasks = [NSMutableSet setWithArray:completed ?: @[]];
            NSArray *failed = [defaults objectForKey:@"vitality_daily_failed"];
            NSMutableSet *clearedFailed = [NSMutableSet set];
            for (NSString *key in failed ?: @[]) {
                if (![key containsString:@"XIANYU"] &&
                    ![key containsString:@"xianyu"] &&
                    ![key containsString:@"taobao"] &&
                    ![key containsString:@"BUSINESS"] &&
                    ![key containsString:@"LIGHTS"] &&
                    ![key containsString:@"ANTOCEAN"] &&
                    ![key containsString:@"AIFISH"] &&
                    ![key containsString:@"aifish"]) {
                    [clearedFailed addObject:key];
                }
            }
            gDailyFailedTasks = clearedFailed;
        } else {
            gDailyCompletedTasks = [NSMutableSet set];
            gDailyFailedTasks = [NSMutableSet set];
            [defaults setObject:today forKey:@"vitality_task_cache_date"];
            [defaults setObject:@[] forKey:@"vitality_daily_completed"];
            [defaults setObject:@[] forKey:@"vitality_daily_failed"];
            [defaults synchronize];
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
        [taskType containsString:@"taobaoqiandao"] ||
        [taskType containsString:@"FOREST_ACTIVITY_DRAW_SQYT"] ||
        [taskType containsString:@"10THjiaoshui"] ||
        [taskType containsString:@"10ZN_JS"]) {
        return NO;
    }
    NSString *lowerType = taskType.lowercaseString;
    NSString *lowerTitle = title ? title.lowercaseString : @"";
    
    // 阶梯大奖类型安全可领
    if ([lowerType hasPrefix:@"acc_"] || [lowerType containsString:@"_acc_"] || [lowerType containsString:@"acc_"] || [lowerType containsString:@"stage_"] || [lowerType containsString:@"ladder"]) {
        return YES;
    }
    
    // AI摸鱼类任务安全可执行 (赠送每日摸鱼次数、看15s视频、去玩一玩森林小车车15s等)
    if ([lowerType containsString:@"aifish"] || [lowerType containsString:@"touch_fish"] || [lowerTitle containsString:@"摸鱼"]) {
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
    
    // 严格过滤金融、保险、借贷、支付、好友随机浇水、游戏试玩通关等风险任务及无法通过RPC完成的任务
    if ([lowerType containsString:@"haoyibao"] ||
        [lowerType containsString:@"insure"] ||
        [lowerType containsString:@"baoxian"] ||
        [lowerType containsString:@"jiebei"] ||
        [lowerType containsString:@"huabei"] ||
        [lowerType containsString:@"jiaoshui"] ||
        [lowerType containsString:@"continuous_collect"] ||
        [lowerType containsString:@"energy_xuanjiao"] ||
        [lowerType containsString:@"widget_"] ||
        [lowerType containsString:@"mhjlr"] ||
        [lowerType containsString:@"xjskp"] ||
        [lowerType containsString:@"_zhwufu"]) {
        return NO;
    }
    
    // 过滤真实付款与金融高危任务，注意避免误杀包含“支付宝”字样的安全浏览任务
    NSString *cleanTitle = [lowerTitle stringByReplacingOccurrencesOfString:@"支付宝" withString:@""];
    if ([cleanTitle containsString:@"保障"] ||
        [cleanTitle containsString:@"保险"] ||
        [cleanTitle containsString:@"好医保"] ||
        [cleanTitle containsString:@"借呗"] ||
        [cleanTitle containsString:@"花呗"] ||
        [cleanTitle containsString:@"信用卡"] ||
        [cleanTitle containsString:@"理财"] ||
        [cleanTitle containsString:@"基金"] ||
        [cleanTitle containsString:@"支付"] ||
        [cleanTitle containsString:@"付款"] ||
        [cleanTitle containsString:@"购买"] ||
        [cleanTitle containsString:@"下单"] ||
        [cleanTitle containsString:@"充值"] ||
        [cleanTitle containsString:@"浇水"] ||
        [cleanTitle containsString:@"一键浇水"] ||
        [cleanTitle containsString:@"添加组件"] ||
        [cleanTitle containsString:@"淘宝签到"] ||
        [cleanTitle containsString:@"向僵尸开炮"] ||
        [cleanTitle containsString:@"梦幻经理人"] ||
        [cleanTitle containsString:@"连续"] ||
        [cleanTitle containsString:@"清理垃圾"] ||
        [cleanTitle containsString:@"帮好友清理"] ||
        [cleanTitle containsString:@"给随机好友"]) {
        return NO;
    }
    return YES;
}

static BOOL isSafeOceanTask(NSString *taskType, NSString *title) {
    if (!taskType.length) return NO;
    NSString *lowerType = taskType.lowercaseString;
    NSString *lowerTitle = title ? title.lowercaseString : @"";
    
    // 明确不支持 finishTask RPC 的答题、捡垃圾、连续签到与外部小程序小游戏
    if ([lowerType containsString:@"dati"] || [lowerTitle containsString:@"答题"]) {
        return NO;
    }
    if ([lowerType containsString:@"rubbishclean"] || [lowerTitle containsString:@"清理垃圾"]) {
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
    if ([lowerType containsString:@"aifish"] || [lowerType containsString:@"touch_fish"] || [lowerTitle containsString:@"摸鱼"]) {
        return YES;
    }
    return isSafeRewardTask(taskType, title);
}

- (NSString *)effectiveUrlForSceneCode:(NSString *)sceneCode {
    if ([sceneCode containsString:@"AIFISH"] || [sceneCode containsString:@"ANTAIFISH"]) {
        return self.aiFishH5Url ?: @"https://render.alipay.com/p/yuyan/180020010001290531/index.html?caprMode=sync&source=ANT_OCEAN";
    }
    if ([sceneCode containsString:@"ANTOCEAN"] || [sceneCode containsString:@"OCEAN"]) {
        return self.oceanH5Url ?: @"https://2021003115672468.h5app.alipay.com/www/index.html?source=ANT_FOREST&showTaskPanel=yes";
    }
    if ([sceneCode containsString:@"MONOPOLY"] || [sceneCode containsString:@"HSDWY"]) {
        return @"https://render.alipay.com/p/yuyan/180020010001293606/index.html?caprMode=sync";
    }
    if ([sceneCode containsString:@"ACTIVITY_DRAW"]) {
        return @"https://render.alipay.com/p/yuyan/180020010001279274/lotteryMachine.html?caprMode=sync&sceneCode=ANTFOREST_ACTIVITY_DRAW&source=task_entry&chInfo=task_entry";
    }
    if ([sceneCode containsString:@"DRAW"] || [sceneCode containsString:@"LOTTERY"] || [sceneCode containsString:@"VITALITY_EXCHANGE"]) {
        return @"https://render.alipay.com/p/yuyan/180020010001279274/lotteryMachine.html?caprMode=sync&sceneCode=ANTFOREST_NORMAL_DRAW&source=task_entry&chInfo=task_entry";
    }
    return @"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&__webview_options__=bc%3D3194732";
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
        } @catch (NSException *e) {}
    }
    return nil;
}

-(void)queryVitalityTaskList {
    [self queryVitalityTaskListWithForce:NO];
}

-(void)queryVitalityTaskListWithForce:(BOOL)force {
    if (!self.rewardTaskBridge && self.jsBridge) {
        self.rewardTaskBridge = self.jsBridge;
    }
    PSDJsBridge *bridge = self.rewardTaskBridge;
    if (!self.enableAutoRewardTasks || !bridge) {
        if (self.enableAutoRewardTasks) [self recordStage:@"首页后台：等待领奖励任务桥接"];
        return;
    }
    initDailyTaskCache();
    
    static NSTimeInterval lastQueryVitalityTaskListTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (!force && (now - lastQueryVitalityTaskListTime < 2.0)) return;
    lastQueryVitalityTaskListTime = now;
    
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *randNum2 = [AntForestManager getNumberRandom:15];
    NSString *urlDynamic = [self effectiveUrlForBridge:bridge];
    NSString *urlVitality = urlDynamic ?: [self effectiveUrlForSceneCode:@"ANTFOREST_VITALITY_TASK"];
    
    [self recordStage:@"任务中心：正在拉取最新任务列表与阶段奖励..."];
    
    BOOL isForestHomeUrl = (urlVitality.length > 0 && ([urlVitality containsString:@"180020010001247580"] || [urlVitality containsString:@"home.html"]) && ![urlVitality containsString:@"180020010001293606"]);
    
    // 1. 主线日常任务列表 (仅在森林主页有效，保护地或其他页面严禁调用避免 100000008 非法请求报错)
    if (isForestHomeUrl) {
        NSString *forestArg1 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.queryTaskList\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"version\":\"20241025\",\"source\":\"ANTFOREST\"}],\"appName\":\"antforest\",\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, randNum2];
        [bridge _doFlushMessageQueue:forestArg1 url:urlVitality];
    }
    
    // 2. 现代任务中心领奖励任务 (ANTFOREST_VITALITY_TASK)
    NSString *argVitality1 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.listTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"ANTFOREST_VITALITY_TASK\",\"source\":\"ANTFOREST\",\"requestType\":\"RPC\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, [AntForestManager getNumberRandom:15]];
    [bridge _doFlushMessageQueue:argVitality1 url:urlVitality];
    
    // 3. 森林寻宝抽奖任务 (普通版 ANTFOREST_NORMAL_DRAW_TASK 与 活动版 ANTFOREST_ACTIVITY_DRAW_TASK)
    NSString *urlDraw = urlDynamic ?: [self effectiveUrlForSceneCode:@"ANTFOREST_NORMAL_DRAW_TASK"];
    NSString *argDraw1 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.listTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"ANTFOREST_NORMAL_DRAW_TASK\",\"source\":\"ANTFOREST\",\"requestType\":\"RPC\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, [AntForestManager getNumberRandom:15]];
    [bridge _doFlushMessageQueue:argDraw1 url:urlDraw];

    NSString *argDraw2 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.listTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"ANTFOREST_ACTIVITY_DRAW_TASK\",\"source\":\"ANTFOREST\",\"requestType\":\"RPC\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, [AntForestManager getNumberRandom:15]];
    [bridge _doFlushMessageQueue:argDraw2 url:urlDraw];
}

-(void)queryMonopolyTaskList {
    if (!self.enableAutoPatrolNew) return;
    if (!self.rewardTaskBridge && self.jsBridge) {
        self.rewardTaskBridge = self.jsBridge;
    }
    PSDJsBridge *bridge = self.rewardTaskBridge;
    if (!bridge) return;
    initDailyTaskCache();
    
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *monopolyScene = @"ANTFOREST_MONOPOLY_TASK_HSDWY";
    NSString *urlMonopoly = [self effectiveUrlForBridge:bridge] ?: [self effectiveUrlForSceneCode:monopolyScene];
    NSString *argMonopoly1 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.listTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"%@\",\"source\":\"ANTFOREST\",\"requestType\":\"RPC\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", monopolyScene, timeStamp, [AntForestManager getNumberRandom:15]];
    [self recordStage:@"新版保护地：已进入保护地界面，读取保护地巡护任务列表"];
    [bridge _doFlushMessageQueue:argMonopoly1 url:urlMonopoly];
}

-(void)queryOceanTaskList {
    [self queryOceanTaskListWithForce:NO];
}

-(void)queryOceanTaskListWithForce:(BOOL)force {
    if (!self.enableAutoOceanTasks) return;
    PSDJsBridge *bridge = self.oceanBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    if (!bridge) return;
    initDailyTaskCache();
    
    static NSTimeInterval lastQueryOceanTaskListTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (!force && (now - lastQueryOceanTaskListTime < 2.0)) return;
    lastQueryOceanTaskListTime = now;
    
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *urlOcean = self.oceanH5Url ?: [self effectiveUrlForBridge:bridge] ?: [self effectiveUrlForSceneCode:@"ANTOCEAN_TASK"];
    NSString *argOcean = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.listTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"ANTOCEAN_TASK\",\"source\":\"ANT_FOREST\",\"requestType\":\"RPC\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, [AntForestManager getNumberRandom:15]];
    [self recordStage:@"神奇海洋：正在拉取最新海洋任务与拼图奖励..."];
    [bridge _doFlushMessageQueue:argOcean url:urlOcean];
    
    // 同步拉取 AI 摸鱼奖励任务
    [self queryAIFishTaskListWithForce:force];
}

-(void)queryAIFishTaskList {
    [self queryAIFishTaskListWithForce:NO];
}

-(void)queryAIFishTaskListWithForce:(BOOL)force {
    if (!self.enableAutoOceanTasks && !self.enableAutoRewardTasks) return;
    PSDJsBridge *bridge = self.aiFishBridge ?: self.oceanBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    if (!bridge) return;
    initDailyTaskCache();
    
    static NSTimeInterval lastQueryAIFishTaskListTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (!force && (now - lastQueryAIFishTaskListTime < 2.0)) return;
    lastQueryAIFishTaskListTime = now;
    
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *urlAIFish = self.aiFishH5Url ?: [self effectiveUrlForBridge:bridge] ?: [self effectiveUrlForSceneCode:@"ANTAIFISH"];
    
    [self recordStage:@"AI摸鱼：正在拉取摸鱼任务与涂鸦机会..."];
    
    // 1. ANTAIFISH (每日赠送摸鱼次数、看15s视频等)
    NSString *argFish1 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.listTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"ANTAIFISH\",\"source\":\"ANT_OCEAN\",\"requestType\":\"RPC\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, [AntForestManager getNumberRandom:15]];
    [bridge _doFlushMessageQueue:argFish1 url:urlAIFish];
    
    // 2. ANTAIFISH_RESCUE_AND_RESTORE (去玩一玩森林小车车15s等)
    NSString *argFish2 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.listTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"ANTAIFISH_RESCUE_AND_RESTORE\",\"source\":\"ANT_OCEAN\",\"requestType\":\"RPC\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, [AntForestManager getNumberRandom:15]];
    [bridge _doFlushMessageQueue:argFish2 url:urlAIFish];
}

-(void)signVitalityTask:(NSString *)signId {
    if (!self.rewardTaskBridge && self.jsBridge) {
        self.rewardTaskBridge = self.jsBridge;
    }
    PSDJsBridge *bridge = self.rewardTaskBridge;
    if (!signId.length || !bridge) return;
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *url = [self effectiveUrlForBridge:bridge] ?: [self effectiveUrlForSceneCode:@"ANTFOREST_VITALITY_TASK"];
    NSString *arg1 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antiep.sign\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"source\":\"ANTFOREST\",\"sceneCode\":\"ANTFOREST_ENERGY_TASK_SIGN\",\"requestType\":\"RPC\",\"userId\":\"%@\",\"entityId\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", self.myUserId ?: @"", signId, timeStamp, randNum];
    [bridge _doFlushMessageQueue:arg1 url:url];
}

-(void)applyVitalityTask:(NSString *)taskType sceneCode:(NSString *)sceneCode {
    NSString *scene = sceneCode.length ? sceneCode : @"ANTFOREST_VITALITY_TASK";
    PSDJsBridge *bridge = nil;
    if ([scene containsString:@"AIFISH"]) {
        bridge = self.aiFishBridge ?: self.oceanBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    } else if ([scene containsString:@"OCEAN"]) {
        bridge = self.oceanBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    } else {
        bridge = self.rewardTaskBridge ?: self.jsBridge;
    }
    if (!taskType.length || !bridge) return;
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *url = [self effectiveUrlForBridge:bridge] ?: [self effectiveUrlForSceneCode:scene];
    NSString *source = [scene containsString:@"AIFISH"] ? @"ANT_OCEAN" : ([scene containsString:@"OCEAN"] ? @"ANT_FOREST" : @"ANTFOREST");
    NSString *arg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antiep.applyTask\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"%@\",\"taskType\":\"%@\",\"requestType\":\"RPC\",\"source\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", scene, taskType, source, timeStamp, randNum];
    [bridge _doFlushMessageQueue:arg url:url];
}

-(void)applyOceanTask:(NSString *)taskType sceneCode:(NSString *)sceneCode taskTitle:(NSString *)title {
    [self applyVitalityTask:taskType sceneCode:sceneCode.length ? sceneCode : @"ANTOCEAN_TASK"];
}

-(void)exchangeVitalityTaskAsset:(NSString *)taskType sceneCode:(NSString *)sceneCode taskTitle:(NSString *)title caQuotaId:(NSString *)caQuotaId {
    if (!self.rewardTaskBridge && self.jsBridge) {
        self.rewardTaskBridge = self.jsBridge;
    }
    PSDJsBridge *bridge = self.rewardTaskBridge;
    if (!taskType.length || !bridge) return;
    NSString *quota = caQuotaId.length ? caQuotaId : @"ANT_FOREST_VITALITY_TO_LOTTERY";
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *url = [self effectiveUrlForBridge:bridge] ?: [self effectiveUrlForSceneCode:@"ANTFOREST_VITALITY_TASK"];
    
    NSString *argForest = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.exchangeVitality\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"caQuotaId\":\"%@\",\"exchangeType\":\"LOTTERY_DRAW\",\"exchangeCount\":1,\"source\":\"ANTFOREST\",\"version\":\"20241025\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", quota, timeStamp, [AntForestManager getNumberRandom:15]];
    [bridge _doFlushMessageQueue:argForest url:url];
}

-(void)finishVitalityTask:(NSString *)taskType sceneCode:(NSString *)sceneCode taskTitle:(NSString *)title {
    NSString *scene = sceneCode.length ? sceneCode : @"ANTFOREST_VITALITY_TASK";
    PSDJsBridge *bridge = nil;
    if ([scene containsString:@"AIFISH"]) {
        bridge = self.aiFishBridge ?: self.oceanBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    } else if ([scene containsString:@"OCEAN"]) {
        bridge = self.oceanBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    } else {
        bridge = self.rewardTaskBridge ?: self.jsBridge;
    }
    if (!taskType.length || !bridge) return;
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *outBizNo = [NSString stringWithFormat:@"%@_%@_%@", taskType, timeStamp, [AntForestManager getNumberRandom:6]];
    NSString *url = [self effectiveUrlForBridge:bridge] ?: [self effectiveUrlForSceneCode:scene];
    NSString *source = [scene containsString:@"AIFISH"] ? @"ANT_OCEAN" : ([scene containsString:@"OCEAN"] ? @"ANT_FOREST" : @"ANTFOREST");
    
    NSString *argGreen = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antiep.finishTask\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"%@\",\"taskType\":\"%@\",\"outBizNo\":\"%@\",\"requestType\":\"RPC\",\"source\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", scene, taskType, outBizNo, source, timeStamp, randNum];
    [bridge _doFlushMessageQueue:argGreen url:url];
}

-(void)receiveVitalityTaskAward:(NSString *)taskType sceneCode:(NSString *)sceneCode taskTitle:(NSString *)title awardName:(NSString *)awardName {
    NSString *scene = sceneCode.length ? sceneCode : @"ANTFOREST_VITALITY_TASK";
    PSDJsBridge *bridge = nil;
    if ([scene containsString:@"AIFISH"]) {
        bridge = self.aiFishBridge ?: self.oceanBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    } else if ([scene containsString:@"OCEAN"]) {
        bridge = self.oceanBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    } else {
        bridge = self.rewardTaskBridge ?: self.jsBridge;
    }
    if (!taskType.length || !bridge) return;
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *url = [self effectiveUrlForBridge:bridge] ?: [self effectiveUrlForSceneCode:scene];
    NSString *source = [scene containsString:@"AIFISH"] ? @"ANT_OCEAN" : ([scene containsString:@"OCEAN"] ? @"ANT_FOREST" : @"ANTFOREST");
    
    NSString *argGreen = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antiep.receiveTaskAward\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"%@\",\"taskType\":\"%@\",\"ignoreLimit\":false,\"requestType\":\"RPC\",\"source\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", scene, taskType, source, timeStamp, randNum];
    [bridge _doFlushMessageQueue:argGreen url:url];
}

-(void)receiveOceanTaskAward:(NSString *)taskType sceneCode:(NSString *)sceneCode taskTitle:(NSString *)title awardName:(NSString *)awardName {
    [self receiveVitalityTaskAward:taskType sceneCode:sceneCode.length ? sceneCode : @"ANTOCEAN_TASK" taskTitle:title awardName:awardName];
}

- (void)notifyActiveH5PageToRefresh {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableSet *targets = [NSMutableSet set];
        if (self.rewardTaskBridge && [self.rewardTaskBridge respondsToSelector:@selector(contentView)]) {
            id cv = [self.rewardTaskBridge contentView];
            if (cv) [targets addObject:cv];
            if ([cv respondsToSelector:@selector(webView)]) {
                id wv = ((id (*)(id, SEL))objc_msgSend)(cv, @selector(webView));
                if (wv) [targets addObject:wv];
            }
        }
        if (!targets.count) return;
        
        NSString *js = @"(()=>{try{const e=new CustomEvent('resume',{bubbles:true,cancelable:true,data:{}});document.dispatchEvent(e);}catch(_){try{const e=document.createEvent('HTMLEvents');e.initEvent('resume',true,true);document.dispatchEvent(e);}catch(__){}}try{if(window.AlipayJSBridge&&window.AlipayJSBridge.fireEvent){window.AlipayJSBridge.fireEvent('resume');}}catch(_){};try{window.dispatchEvent(new Event('pageshow'));document.dispatchEvent(new Event('pageshow'));}catch(_){}})();";
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

- (void)executeNextVitalityTask {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!self.rewardTaskBridge && self.jsBridge) {
                self.rewardTaskBridge = self.jsBridge;
            }
            if (!self.enableAutoRewardTasks || !self.rewardTaskBridge) {
                @synchronized(self) {
                    vitalityTaskRunning = NO;
                    [vitalityTaskQueue removeAllObjects];
                    gCurrentExecutingTaskKey = nil;
                }
                return;
            }
            
            static NSString *sLastExecutedSceneCode = nil;
            NSDictionary *item = nil;
            @synchronized(self) {
                if (!vitalityTaskQueue.count) {
                    vitalityTaskRunning = NO;
                    gCurrentExecutingTaskKey = nil;
                    if (sHasPerformedWorkInCurrentVitalityRound) {
                        sHasPerformedWorkInCurrentVitalityRound = NO;
                        if ([sLastExecutedSceneCode containsString:@"MONOPOLY"]) {
                            [self recordStage:@"新版保护地：本批次任务已执行完毕，2.5秒后刷新保护地任务列表..."];
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                [self queryMonopolyTaskList];
                                [self notifyActiveH5PageToRefresh];
                            });
                        } else if ([sLastExecutedSceneCode containsString:@"AIFISH"]) {
                            [self recordStage:@"AI摸鱼：本批次任务已执行完毕，2.5秒后刷新拉取摸鱼任务最新进度..."];
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                [self queryAIFishTaskListWithForce:YES];
                                [self notifyActiveH5PageToRefresh];
                            });
                        } else if ([sLastExecutedSceneCode containsString:@"OCEAN"]) {
                            [self recordStage:@"神奇海洋：本批次任务已执行完毕，2.5秒后刷新拉取海洋任务最新进度..."];
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                [self queryOceanTaskListWithForce:YES];
                                [self notifyActiveH5PageToRefresh];
                            });
                        } else if ([sLastExecutedSceneCode containsString:@"DRAW"]) {
                            [self recordStage:@"森林寻宝：本批次任务已执行完毕，2.5秒后自动刷新寻宝与大奖..."];
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                [self queryVitalityTaskListWithForce:YES];
                                [self notifyActiveH5PageToRefresh];
                            });
                        } else {
                            [self recordStage:@"领奖励：本批次任务已执行完毕，2.5秒后自动刷新拉取新解锁任务与阶梯大奖..."];
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                [self queryVitalityTaskListWithForce:YES];
                                [self notifyActiveH5PageToRefresh];
                            });
                        }
                    } else {
                        if ([sLastExecutedSceneCode containsString:@"AIFISH"]) {
                            [self recordStage:@"AI摸鱼：本轮所有摸鱼任务与涂鸦机会已全部处理完毕"];
                        } else if ([sLastExecutedSceneCode containsString:@"OCEAN"]) {
                            [self recordStage:@"神奇海洋：本轮所有任务与领拼图操作已全部处理完毕"];
                        } else {
                            [self recordStage:@"领奖励与森林寻宝：本轮所有任务与奖励已全部处理完毕"];
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
            if (!bridge) {
                @synchronized(self) { vitalityTaskRunning = NO; }
                return;
            }
            
            NSString *action = [item[@"action"] isKindOfClass:NSString.class] ? [item[@"action"] copy] : @"";
            NSString *title = [item[@"title"] isKindOfClass:NSString.class] ? [item[@"title"] copy] : @"任务";
            NSString *awardName = [item[@"awardName"] isKindOfClass:NSString.class] ? [item[@"awardName"] copy] : @"奖励";
            NSString *taskType = [item[@"taskType"] isKindOfClass:NSString.class] ? [item[@"taskType"] copy] : @"";
            NSString *sceneCode = [item[@"sceneCode"] isKindOfClass:NSString.class] ? [item[@"sceneCode"] copy] : @"ANTFOREST_VITALITY_TASK";
            sLastExecutedSceneCode = [sceneCode copy];
            BOOL isAcc = [item[@"isAcc"] respondsToSelector:@selector(boolValue)] ? [item[@"isAcc"] boolValue] : NO;
            
            NSString *taskKey = taskType.length ? [NSString stringWithFormat:@"%@:%@", sceneCode, taskType] : nil;
            gCurrentExecutingTaskKey = taskKey;
            
            initDailyTaskCache();
            // finishTask 的成功只代表任务动作已提交，后续 receive 仍必须执行。
            if (taskKey.length && ![action isEqualToString:@"receive"]) {
                BOOL isDone = NO;
                @synchronized(self) {
                    BOOL isMultiIncomplete = isMultiStageIncompleteTask(title, 0, 0) || [item[@"isMultiStage"] boolValue];
                    if (!isMultiIncomplete) {
                        isDone = ([gDailyCompletedTasks containsObject:taskKey] || [gDailyFailedTasks containsObject:taskKey]);
                    }
                }
                if (isDone) {
                    // 今日已完成或已确认不可做，直接处理下一个
                    [self executeNextVitalityTask];
                    return;
                }
            }
            
            NSString *scenePrefix = @"领奖励";
            if ([sceneCode containsString:@"AIFISH"]) {
                scenePrefix = @"AI摸鱼";
            } else if ([sceneCode containsString:@"MONOPOLY"]) {
                scenePrefix = @"新版保护地";
            } else if ([sceneCode containsString:@"NORMAL_DRAW"] || [sceneCode containsString:@"ACTIVITY_DRAW"] || [sceneCode containsString:@"DRAW"]) {
                scenePrefix = @"森林寻宝";
            } else if ([sceneCode containsString:@"OCEAN"]) {
                scenePrefix = @"神奇海洋";
            } else if (isAcc || [taskType hasPrefix:@"acc_task_energy_"]) {
                scenePrefix = @"阶梯大奖";
            }
            
            sHasPerformedWorkInCurrentVitalityRound = YES;
            
            if ([action isEqualToString:@"sign"]) {
                NSString *signId = [item[@"signId"] isKindOfClass:NSString.class] ? [item[@"signId"] copy] : @"";
                [self recordStage:[NSString stringWithFormat:@"%@：正在完成每日签到...", scenePrefix]];
                [self signVitalityTask:signId];
                if (taskKey.length) {
                    @synchronized(self) {
                        [gDailyCompletedTasks addObject:taskKey];
                        saveDailyTaskCache();
                    }
                }
            } else if ([action isEqualToString:@"exchange"]) {
                NSString *caQuotaId = [item[@"caQuotaId"] isKindOfClass:NSString.class] ? [item[@"caQuotaId"] copy] : @"";
                [self recordStage:[NSString stringWithFormat:@"%@：正在兑换“%@”...", scenePrefix, title]];
                [self exchangeVitalityTaskAsset:taskType sceneCode:sceneCode taskTitle:title caQuotaId:caQuotaId];
                if (taskKey.length) {
                    @synchronized(self) {
                        [gDailyCompletedTasks addObject:taskKey];
                        saveDailyTaskCache();
                    }
                }
            } else if ([action isEqualToString:@"browse"]) {
                NSString *jumpUrl = [item[@"jumpUrl"] isKindOfClass:NSString.class] ? [item[@"jumpUrl"] copy] : @"";
                NSInteger seconds = [item[@"browseSeconds"] respondsToSelector:@selector(integerValue)] ? [item[@"browseSeconds"] integerValue] : 15;
                if (seconds <= 0) seconds = 15;
                [self recordStage:[NSString stringWithFormat:@"%@：正在后台自动执行“%@”（保持运行 %ld 秒）...", scenePrefix, title, (long)seconds]];
                
                // 1. 优先调用 applyTask 注册“去完成”激活状态
                [self applyVitalityTask:taskType sceneCode:sceneCode];
                
                // 2. 如果有 jumpUrl，进行后台真实预取以满足服务端激活校验
                if (jumpUrl.length) {
                    NSString *cleanUrl = jumpUrl;
                    if ([jumpUrl containsString:@"url="]) {
                        NSRange r = [jumpUrl rangeOfString:@"url="];
                        cleanUrl = [jumpUrl substringFromIndex:r.location + 4];
                        cleanUrl = [cleanUrl stringByRemovingPercentEncoding] ?: cleanUrl;
                    }
                    if ([cleanUrl hasPrefix:@"http://"] || [cleanUrl hasPrefix:@"https://"]) {
                        NSURL *reqUrl = [NSURL URLWithString:cleanUrl];
                        if (reqUrl) {
                            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:reqUrl cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8.0];
                            [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Nebula AlipayDefined(nt:WIFI,ws:393|759,fx:393|852) AliApp(AP/12.12.16.6000) AlipayClient/12.12.16.6000 Language/zh-Hans" forHTTPHeaderField:@"User-Agent"];
                            [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(__unused NSData *d, __unused NSURLResponse *res, __unused NSError *err){}] resume];
                        }
                    }
                }
                
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
                    
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        @try {
                            [self receiveVitalityTaskAward:capturedTaskType sceneCode:capturedSceneCode taskTitle:capturedTitle awardName:capturedAwardName];
                            [self recordStage:[NSString stringWithFormat:@"%@：已完成“%@”并提交领奖", capturedScenePrefix, capturedTitle]];
                        } @catch (NSException *e) {}
                        
                        double delayAfter = 1.2 + (arc4random_uniform(500) / 1000.0);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayAfter * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            if (isMulti && taskKey.length) {
                                @synchronized(self) {
                                    [gDailyCompletedTasks removeObject:taskKey];
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
                [self applyVitalityTask:taskType sceneCode:sceneCode];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self finishVitalityTask:taskType sceneCode:sceneCode taskTitle:title];
                });
            } else if ([action isEqualToString:@"receive"]) {
                [self recordStage:[NSString stringWithFormat:@"%@：正在领取“%@”（%@）...", scenePrefix, title, awardName]];
                [self receiveVitalityTaskAward:taskType sceneCode:sceneCode taskTitle:title awardName:awardName];
            }
            
            double delaySec = 1.0 + (arc4random_uniform(800) / 1000.0);
            if ([action isEqualToString:@"finish"]) {
                delaySec = 2.5 + (arc4random_uniform(500) / 1000.0);
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
    
    // 1. 结构化 rightsTimesLimit 与已领次数判断
    NSDictionary *rights = [taskDict[@"taskRights"] isKindOfClass:NSDictionary.class] ? taskDict[@"taskRights"] : nil;
    NSInteger limit = [rights[@"rightsTimesLimit"] integerValue];
    NSInteger received = [rights[@"alreadyReceiveAwardCount"] integerValue];
    if (limit <= 0) limit = [taskDict[@"rightsTimesLimit"] integerValue];
    if (received <= 0) received = [taskDict[@"rightsTimes"] integerValue];
    
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
                received = [[bizStr substringWithRange:[m rangeAtIndex:1]] integerValue];
            }
        }
    }
    
    if (limit > 1 && received < limit) {
        return YES;
    }
    return NO;
}

static NSInteger extractTaskBrowseSeconds(NSDictionary *baseInfo, NSDictionary *bizInfo, NSString *taskTitle) {
    NSString *title = taskTitle ?: @"";
    NSString *taskType = [baseInfo[@"taskType"] isKindOfClass:NSString.class] ? baseInfo[@"taskType"] : @"";
    
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
    
    // 3. 无明确倒计时要求时，外链任务需保持运行 2 秒以满足外部服务端的唤起与有效激活校验
    if ([taskType containsString:@"XIANYU"] || [taskType containsString:@"BBNC"] || [taskType containsString:@"shenqiyutang"] || [taskType containsString:@"XLIGHT"] || [taskType containsString:@"JSKP"] || [title containsString:@"UC"] || [title containsString:@"芭芭农场"] || [title containsString:@"施肥"] || [title containsString:@"闲置"] || [title containsString:@"闲鱼"] || [title containsString:@"循环"] || [title containsString:@"市集"] || [title containsString:@"集市"]) {
        return 2;
    }
    
    // 4. 常规即时任务（如打开快手/淘宝、逛一逛各类专区等）：直接 0 秒秒做
    return 0;
}

-(void)handleVitalityTaskListResponse:(id)args {
    if ((!self.enableAutoRewardTasks && !self.enableAutoOceanTasks) || ![args isKindOfClass:NSDictionary.class]) return;
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
        NSString *opType = [NSString stringWithFormat:@"%@", (args[@"operationType"] ?: data[@"operationType"]) ?: @""];
        if ([opType containsString:@"receiveTaskAward"] || [resDesc containsString:@"任务已完结"]) {
            if ([resCode isEqualToString:@"100000000"] || [resCode isEqualToString:@"400000030"] || [resCode isEqualToString:@"400000012"] || [resCode isEqualToString:@"B000000008"] || [resCode isEqualToString:@"SUCCESS"] || [data[@"success"] boolValue] || [args[@"success"] boolValue] ||
                [resDesc containsString:@"处理成功"] || [resDesc containsString:@"成功"] || [resDesc containsString:@"超过上限"]) {
                if (gCurrentExecutingTaskKey.length) {
                    @synchronized(self) {
                        [gDailyCompletedTasks addObject:gCurrentExecutingTaskKey];
                        saveDailyTaskCache();
                    }
                }
            }
        } else if ([resCode isEqualToString:@"400000040"] || [resCode isEqualToString:@"400000001"] || [resCode isEqualToString:@"3000"] || [data[@"error"] integerValue] == 3000 ||
            [resDesc containsString:@"不支持rpc调用"] || [resDesc containsString:@"不存在"] || [errMsg containsString:@"系统出错"]) {
            if (gCurrentExecutingTaskKey.length) {
                @synchronized(self) {
                    [gDailyFailedTasks addObject:gCurrentExecutingTaskKey];
                    saveDailyTaskCache();
                }
            }
        }
        
        @synchronized(self) {
            if (!vitalityTaskQueue) {
                vitalityTaskQueue = [NSMutableArray array];
            }
        }
        
        // 1. 签到处理
        NSDictionary *signVO = [data[@"energySignVO"] isKindOfClass:NSDictionary.class] ? data[@"energySignVO"] : nil;
        if (signVO) {
            NSString *signId = [signVO[@"signId"] isKindOfClass:NSString.class] ? signVO[@"signId"] : @"";
            NSString *currKey = [signVO[@"currentSignKey"] isKindOfClass:NSString.class] ? signVO[@"currentSignKey"] : @"";
            NSArray *records = [signVO[@"signRecords"] isKindOfClass:NSArray.class] ? signVO[@"signRecords"] : nil;
            BOOL isSignedToday = NO;
            for (id r in records) {
                if ([r isKindOfClass:NSDictionary.class] && [r[@"signKey"] isEqualToString:currKey]) {
                    isSignedToday = [r[@"signed"] boolValue];
                    break;
                }
            }
            NSString *signTaskKey = @"SIGN_TODAY";
            if (isSignedToday) {
                @synchronized(self) {
                    [gDailyCompletedTasks addObject:signTaskKey];
                }
            } else if (signId.length) {
                BOOL alreadyInQueue = NO;
                @synchronized(self) {
                    if ([gDailyCompletedTasks containsObject:signTaskKey]) {
                        alreadyInQueue = YES;
                    } else {
                        for (NSDictionary *q in vitalityTaskQueue) {
                            if ([q[@"action"] isEqualToString:@"sign"]) { alreadyInQueue = YES; break; }
                        }
                    }
                }
                if (!alreadyInQueue) {
                    @synchronized(self) {
                        [vitalityTaskQueue addObject:@{
                            @"action": @"sign",
                            @"signId": signId,
                            @"title": @"每日签到",
                            @"awardName": @"能量",
                            @"sceneCode": @"ANTFOREST_VITALITY_TASK"
                        }];
                    }
                }
            }
        }
        
        // 2. 收集任务列表
        NSMutableArray<NSDictionary *> *allTaskList = [NSMutableArray array];
        NSArray *forestTasksNew = [data[@"forestTasksNew"] isKindOfClass:NSArray.class] ? data[@"forestTasksNew"] : nil;
        if (forestTasksNew.count > 0) {
            for (id g in forestTasksNew) {
                if ([g isKindOfClass:NSDictionary.class]) {
                    NSArray *subList = g[@"taskInfoList"];
                    if ([subList isKindOfClass:NSArray.class]) [allTaskList addObjectsFromArray:subList];
                }
            }
        }
        NSArray *topList = [data[@"taskInfoList"] isKindOfClass:NSArray.class] ? data[@"taskInfoList"] : nil;
        if (topList.count > 0) {
            [allTaskList addObjectsFromArray:topList];
        }
        
        NSMutableArray<NSDictionary *> *newlyParsedTasks = [NSMutableArray array];
        NSMutableArray<NSDictionary *> *accTasks = [NSMutableArray array];
        
        for (id t in allTaskList) {
            if (![t isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *baseInfo = [t[@"taskBaseInfo"] isKindOfClass:NSDictionary.class] ? t[@"taskBaseInfo"] : nil;
            if (!baseInfo) continue;
            NSString *taskType = [baseInfo[@"taskType"] isKindOfClass:NSString.class] ? baseInfo[@"taskType"] : @"";
            if (!taskType.length) continue;
            NSString *sceneCode = [baseInfo[@"sceneCode"] isKindOfClass:NSString.class] ? baseInfo[@"sceneCode"] : @"ANTFOREST_VITALITY_TASK";
            NSString *taskStatus = [baseInfo[@"taskStatus"] isKindOfClass:NSString.class] ? baseInfo[@"taskStatus"] : @""; // TODO, FINISHED, RECEIVED
            NSString *bizInfoStr = baseInfo[@"bizInfo"];
            
            NSDictionary *bizInfo = nil;
            if ([bizInfoStr isKindOfClass:NSString.class]) {
                NSData *bd = [bizInfoStr dataUsingEncoding:NSUTF8StringEncoding];
                if (bd) bizInfo = [NSJSONSerialization JSONObjectWithData:bd options:0 error:nil];
            }
            
            NSString *taskTitle = bizInfo[@"taskTitle"] ?: bizInfo[@"title"] ?: taskType;
            if (![taskTitle isKindOfClass:NSString.class]) taskTitle = taskType;
            BOOL autoCompleteTask = [bizInfo[@"autoCompleteTask"] boolValue];
            NSString *awardName = bizInfo[@"energy"] ?: bizInfo[@"vitality"] ?: ([taskTitle containsString:@"机会"] ? @"抽奖机会" : @"奖励");
            if (![awardName isKindOfClass:NSString.class]) awardName = @"奖励";
            
            NSDictionary *rights = [t[@"taskRights"] isKindOfClass:NSDictionary.class] ? t[@"taskRights"] : nil;
            NSInteger alreadyReceive = [rights[@"alreadyReceiveAwardCount"] integerValue];
            NSInteger rightsTimesLimit = [rights[@"rightsTimesLimit"] integerValue];
            
            NSString *taskKey = [NSString stringWithFormat:@"%@:%@", sceneCode, taskType];
            if ([taskStatus isEqualToString:@"RECEIVED"] || (rightsTimesLimit > 0 && alreadyReceive >= rightsTimesLimit)) {
                @synchronized(self) {
                    [gDailyCompletedTasks addObject:taskKey];
                    saveDailyTaskCache();
                }
                continue;
            }
            // 查询/受理成功不是任务完成；服务端仍为 TODO 时必须撤销旧版留下的误缓存，进度尚未达标时亦不可缓存。
            NSInteger taskRequire = [baseInfo[@"taskRequire"] integerValue];
            NSInteger taskProgress = [baseInfo[@"taskProgress"] integerValue];
            BOOL isMultiIncomplete = isMultiStageIncompleteTask(taskTitle, taskProgress, taskRequire) || isMultiStageTaskFromDict(t, baseInfo, bizInfo);
            if ([taskStatus isEqualToString:@"TODO"] || isMultiIncomplete) {
                @synchronized(self) {
                    if ([gDailyCompletedTasks containsObject:taskKey]) {
                        [gDailyCompletedTasks removeObject:taskKey];
                    }
                    if ([gDailyFailedTasks containsObject:taskKey]) {
                        [gDailyFailedTasks removeObject:taskKey];
                    }
                    saveDailyTaskCache();
                }
            }
            
            if ([gDailyFailedTasks containsObject:taskKey] && ![taskStatus isEqualToString:@"FINISHED"]) {
                continue;
            }
            
            NSString *taskNode = baseInfo[@"taskNode"] ?: @"";
            if ([taskNode isEqualToString:@"PARENT"] && ![taskStatus isEqualToString:@"FINISHED"]) {
                continue;
            }
            
            // 仅拦截未完成的高风险任务与不可通过RPC自动完成的任务
            if (![taskStatus isEqualToString:@"FINISHED"] && !isSafeRewardTask(taskType, taskTitle)) continue;
            if (![taskStatus isEqualToString:@"FINISHED"] && [sceneCode containsString:@"OCEAN"] && !isSafeOceanTask(taskType, taskTitle)) continue;
            if (![taskStatus isEqualToString:@"FINISHED"] && [sceneCode containsString:@"AIFISH"] && !isSafeAIFishTask(taskType, taskTitle)) continue;
            
            // 阶梯大奖 (阶段宝箱 / 额外累计奖励)
            NSDictionary *groupInfo = [t[@"taskGroupInfo"] isKindOfClass:NSDictionary.class] ? t[@"taskGroupInfo"] : nil;
            NSString *groupType = groupInfo[@"taskGroupType"] ?: @"";
            BOOL isAccTask = ([groupType containsString:@"ACC"] || [groupType containsString:@"STAGE"] || [groupType containsString:@"LADDER"] ||
                              [taskType hasPrefix:@"acc_"] || [taskType containsString:@"_acc_"] || [taskType containsString:@"ACC_"] || [taskType containsString:@"_ACC_"] ||
                              [taskType containsString:@"stage_"] || [taskType containsString:@"STAGE_"]);
            
            if (isAccTask) {
                NSInteger rightsTimes = [rights[@"rightsTimes"] integerValue];
                NSInteger awardCount = [rights[@"awardCount"] integerValue];
                if (awardCount <= 0) {
                    awardCount = [bizInfo[@"awardCount"] integerValue];
                }
                if (awardCount <= 0) {
                    awardCount = [bizInfo[@"energy"] integerValue];
                }
                
                BOOL canClaim = (![taskStatus isEqualToString:@"RECEIVED"] &&
                                 ([taskStatus isEqualToString:@"FINISHED"] ||
                                  [taskStatus isEqualToString:@"CAN_RECEIVE"] ||
                                  (rightsTimesLimit > 0 && alreadyReceive < rightsTimesLimit && rightsTimes > alreadyReceive) ||
                                  (alreadyReceive == 0 && rightsTimes > 0)));
                
                if (canClaim) {
                    [accTasks addObject:@{
                        @"action": @"receive",
                        @"taskType": taskType,
                        @"sceneCode": sceneCode,
                        @"title": taskTitle.length ? taskTitle : [NSString stringWithFormat:@"阶段累计额外奖励（%ldg）", (long)awardCount],
                        @"awardName": (awardCount > 0) ? [NSString stringWithFormat:@"%ldg 能量", (long)awardCount] : @"额外奖励",
                        @"isAcc": @YES
                    }];
                }
                continue;
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
            
            NSString *jumpUrl = baseInfo[@"taskJumpUrl"] ?: bizInfo[@"taskJumpUrl"] ?: bizInfo[@"targetUrl"] ?: t[@"taskJumpUrl"] ?: bizInfo[@"url"] ?: @"";
            if (![jumpUrl isKindOfClass:NSString.class]) jumpUrl = @"";
            
            NSInteger explicitBrowseSec = extractTaskBrowseSeconds(baseInfo, bizInfo, taskTitle);
            BOOL requiresTimedBrowse = (explicitBrowseSec > 0);
            
            if ([prodPlayType isEqualToString:@"EXCHANGE_ASSET"] || [taskType containsString:@"VITALITY_EXCHANGE"] || [taskType isEqualToString:@"NORMAL_DRAW_EXCHANGE_VITALITY"]) {
                [newlyParsedTasks addObject:@{
                    @"action": @"exchange",
                    @"taskType": taskType,
                    @"sceneCode": sceneCode,
                    @"title": taskTitle,
                    @"caQuotaId": caQuotaId ?: @""
                }];
            } else if ([taskStatus isEqualToString:@"FINISHED"]) {
                [newlyParsedTasks addObject:@{
                    @"action": @"receive",
                    @"taskType": taskType,
                    @"sceneCode": sceneCode,
                    @"title": taskTitle,
                    @"awardName": awardName,
                    @"isMultiStage": @(isMultiIncomplete)
                }];
            } else if ([taskStatus isEqualToString:@"TODO"]) {
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
                        @"isMultiStage": @(isMultiIncomplete)
                    }];
                    [newlyParsedTasks addObject:@{
                        @"action": @"receive",
                        @"taskType": taskType,
                        @"sceneCode": sceneCode,
                        @"title": taskTitle,
                        @"awardName": awardName
                    }];
                }
            }
        }
        
        BOOL shouldStartLoop = NO;
        NSUInteger totalQueuedCount = 0;
        @synchronized(self) {
            if (newlyParsedTasks.count > 0) {
                BOOL isMainVitality = [newlyParsedTasks.firstObject[@"sceneCode"] isEqualToString:@"ANTFOREST_VITALITY_TASK"];
                if (isMainVitality && vitalityTaskQueue.count > 0) {
                    // 主线领奖励任务优先插入队列前方执行
                    NSIndexSet *indexes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, newlyParsedTasks.count)];
                    [vitalityTaskQueue insertObjects:newlyParsedTasks atIndexes:indexes];
                } else {
                    [vitalityTaskQueue addObjectsFromArray:newlyParsedTasks];
                }
            }
            if (accTasks.count > 0) {
                [vitalityTaskQueue addObjectsFromArray:accTasks];
            }
            totalQueuedCount = vitalityTaskQueue.count;
            if (totalQueuedCount > 0 && !vitalityTaskRunning) {
                shouldStartLoop = YES;
                vitalityTaskRunning = YES;
            }
        }
        
        if (shouldStartLoop) {
            [self recordStage:[NSString stringWithFormat:@"领奖励与森林寻宝：规划 %lu 项待完成与领奖操作", (unsigned long)totalQueuedCount]];
            [self executeNextVitalityTask];
        } else if (totalQueuedCount == 0 && !vitalityTaskRunning) {
            static NSTimeInterval lastFinishedLogTime = 0;
            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
            if (now - lastFinishedLogTime > 5.0) {
                lastFinishedLogTime = now;
                [self recordStage:@"领奖励：所有常规任务与阶梯大奖已全部处理完毕"];
            }
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
            
            NSString *taskKey = [NSString stringWithFormat:@"%@:%@", sceneCode, taskType];
            NSDictionary *rights = [t[@"taskRights"] isKindOfClass:NSDictionary.class] ? t[@"taskRights"] : nil;
            NSInteger alreadyReceive = [rights[@"alreadyReceiveAwardCount"] integerValue];
            NSInteger rightsTimesLimit = [rights[@"rightsTimesLimit"] integerValue];
            if (rightsTimesLimit <= 0) rightsTimesLimit = [t[@"rightsTimesLimit"] integerValue];
            if (alreadyReceive <= 0) alreadyReceive = [t[@"rightsTimes"] integerValue];
            if (alreadyReceive <= 0) {
                id ext = t[@"extend"];
                if ([ext isKindOfClass:NSString.class] && [ext containsString:@"alreadyReceiveAwardCount"]) {
                    NSDictionary *ed = [NSJSONSerialization JSONObjectWithData:[ext dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
                    alreadyReceive = [ed[@"alreadyReceiveAwardCount"] integerValue];
                }
            }
            BOOL isDoneAll = [taskStatus isEqualToString:@"RECEIVED"] || (rightsTimesLimit > 0 && alreadyReceive >= rightsTimesLimit);
            if (isDoneAll) {
                @synchronized(self) {
                    [gDailyCompletedTasks addObject:taskKey];
                    saveDailyTaskCache();
                }
                continue;
            }
            
            BOOL isMultiIncomplete = isMultiStageIncompleteTask(taskTitle, 0, 0) || isMultiStageTaskFromDict(t, nil, bizInfo);
            if ([taskStatus isEqualToString:@"TODO"] || isMultiIncomplete) {
                @synchronized(self) {
                    if ([gDailyCompletedTasks containsObject:taskKey]) {
                        [gDailyCompletedTasks removeObject:taskKey];
                    }
                    if ([gDailyFailedTasks containsObject:taskKey]) {
                        [gDailyFailedTasks removeObject:taskKey];
                    }
                    saveDailyTaskCache();
                }
            }
            if ([gDailyFailedTasks containsObject:taskKey] && ![taskStatus isEqualToString:@"FINISHED"]) {
                continue;
            }
            
            BOOL canClaim = [taskStatus isEqualToString:@"FINISHED"] ||
                            [taskStatus isEqualToString:@"CAN_RECEIVE"] ||
                            ([taskJumpBtn containsString:@"领"] && ![taskStatus isEqualToString:@"RECEIVED"]);
            
            if (canClaim) {
                [tasksToQueue addObject:@{
                    @"action": @"receive",
                    @"taskType": taskType,
                    @"sceneCode": sceneCode,
                    @"title": taskTitle,
                    @"awardName": [awardType isEqualToString:@"RIGHTS"] ? @"拼图碎片" : @"海洋奖励",
                    @"scenePrefix": @"神奇海洋",
                    @"isMultiStage": @(isMultiIncomplete)
                }];
            } else if ([taskStatus isEqualToString:@"TODO"]) {
                if (isSafeOceanTask(taskType, taskTitle)) {
                    NSInteger browseSec = extractTaskBrowseSeconds(t, bizInfo, taskTitle);
                    NSString *action = (browseSec > 0) ? @"browse" : @"finish";
                    NSString *jumpUrl = bizInfo[@"targetUrl"] ?: bizInfo[@"jumpUrl"] ?: @"";
                    [tasksToQueue addObject:@{
                        @"action": action,
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
                    NSLog(@"🌊 [神奇海洋] 任务【%@】属于互动型/答题/连续签到/外部游戏任务，不支持直接RPC完成，已自动跳过", taskTitle);
                }
            }
        }
        NSLog(@"🌊 [神奇海洋·任务探测] ══════════════════════════════════════════════\n");
        
        if (!self.enableAutoOceanTasks || !tasksToQueue.count) return;
        
        BOOL shouldStartLoop = NO;
        NSUInteger totalQueued = 0;
        @synchronized(self) {
            if (!vitalityTaskQueue) vitalityTaskQueue = [NSMutableArray array];
            for (NSDictionary *task in tasksToQueue) {
                NSString *tk = [NSString stringWithFormat:@"%@:%@", task[@"sceneCode"], task[@"taskType"]];
                BOOL alreadyInQueue = NO;
                for (NSDictionary *q in vitalityTaskQueue) {
                    NSString *qk = [NSString stringWithFormat:@"%@:%@", q[@"sceneCode"], q[@"taskType"]];
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
    if (!self.enableCleanOcean || !self.jsBridge) {
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
    if ([defaults boolForKey:@"oceanLimitReachedToday"]) {
        oceanRunning = NO;
        oceanCurrentUserId = nil;
        [oceanQueue removeAllObjects];
        return;
    }
    
    NSArray *cleanedArr = [defaults arrayForKey:@"oceanCleanedFriendsToday"] ?: @[];
    NSMutableSet *cleanedSet = [NSMutableSet setWithArray:cleanedArr];
    if (cleanedSet.count >= 20) {
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
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (oceanRunning && token == oceanRequestToken) {
            oceanRunning = NO;
            oceanCurrentUserId = nil;
            double delaySec = 1.0 + (arc4random_uniform(1000) / 1000.0);
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
    if ([defaults boolForKey:@"oceanLimitReachedToday"]) return;
    
    NSArray *cleanedArr = [defaults arrayForKey:@"oceanCleanedFriendsToday"] ?: @[];
    NSMutableSet *cleanedSet = [NSMutableSet setWithArray:cleanedArr];
    if (cleanedSet.count >= 20) return;
    
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
    NSString *version = @"20230501";
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *randNum = [AntForestManager getNumberRandom:16];
    NSString *arg1 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antmember.forest.h5.queryEnergyRanking\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"rankType\":\"energyRank\",\"periodType\":\"total\",\"version\":\"%@\",\"startIndex\":%ld,\"pageSize\":200,\"contactsStatus\":\"N\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\"}],\"relationLocal\":{\"pathList\":[\"friendRanking\",\"myself\",\"totalDatas\"]},\"getResponse\":true},\"callbackId\":\"rpc_%@.%@_p%ld\"}]", version, (long)startIndex, timeStamp, randNum, (long)startIndex];
    NSString *arg2 = @"https://render.alipay.com/p/yuyan/180020010001247580/listRank.html?caprMode=sync&init=energyRank&periodType=total";
    [self recordStage:[NSString stringWithFormat:@"请求好友排行榜自动翻页（第 %ld-%ld 位）", (long)startIndex + 1, (long)startIndex + 200]];
    [[self jsBridge] _doFlushMessageQueue:arg1 url:arg2];
}

//查询总排行 可以获取所有人的ID
-(void)queryTotalRank{
    NSString *version = @"20230501";
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:16];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antmember.forest.h5.queryEnergyRanking\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"rankType\":\"energyRank\",\"periodType\":\"total\",\"version\":\"%@\",\"startNum\":1,\"startIndex\":0,\"pageSize\":200,\"contactsStatus\":\"N\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\"}],\"relationLocal\":{\"pathList\":[\"friendRanking\",\"myself\",\"totalDatas\"]},\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]",version,timeStamp,randNum];
    NSString *arg2 = @"https://render.alipay.com/p/yuyan/180020010001247580/listRank.html?caprMode=sync&init=energyRank&periodType=total";
    if([self jsBridge]) {
        [self recordStage:@"请求全量好友排行榜（200位/页）"];
        [[self jsBridge] _doFlushMessageQueue:arg1 url:arg2];
    }
}

//查询 20 个人是否有可领能量球
-(void)queryRobFlag:(NSString*)uids{
    [[AntForestManager sharedLock] lock];
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:16];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.fillUserRobFlag\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"userIdList\":[%@],\"source\":\"chInfo_ch_appcenter__chsub_9patch\"}],\"relationLocal\":{\"pathList\":[\"friendRanking\"]},\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]",uids,timeStamp,randNum];
    NSString *arg2 = [NSString stringWithFormat:@"https://render.alipay.com/p/yuyan/180020010001247580/listRank.html?caprMode=sync&init=energyRank&periodType=total"];
    if([self jsBridge]) {
        [[self jsBridge] _doFlushMessageQueue:arg1 url:arg2];
        //FileLog(@"uids:%@", uids);
        //FileLog(@"anthook queryRobFlag");
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
    NSString *arg2 = [NSString stringWithFormat:@"https://render.alipay.com/p/yuyan/180020010001247580/listRank.html?caprMode=sync&init=energyRank&periodType=total"];
    if([self jsBridge]) {
        [[self jsBridge] _doFlushMessageQueue:arg1 url:arg2];
        //FileLog(@"uids:%@", uids);
        //FileLog(@"anthook queryAccount");
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
    NSUInteger groupCount = (friendIds.count + 19) / 20;
    [self recordStage:[NSString stringWithFormat:@"诊断 · 排行榜全量回包：%lu 位好友，分 %lu 组校验", (unsigned long)friendIds.count, (unsigned long)groupCount]];
    [self queryAccount:[[self intArrToStr:friendIds] componentsJoinedByString:@","]];
    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    for (NSUInteger index = 0; index < friendIds.count; index += 20) {
        NSRange range = NSMakeRange(index, MIN((NSUInteger)20, friendIds.count - index));
        [groups addObject:[[self intArrToStr:[friendIds subarrayWithRange:range]] componentsJoinedByString:@","]];
    }
    dispatch_async(globalSerialQueueTest, ^{
        for (NSUInteger index = 0; index < groups.count; index++) {
            if (!self.enableAutoCollect || cycle != collectionCycle) break;
            [self recordStage:[NSString stringWithFormat:@"诊断 · 排行榜校验：第 %lu/%lu 组", (unsigned long)(index + 1), (unsigned long)groups.count]];
            [self queryRobFlag:groups[index]];
            double rankGroupDelay = 0.18 + (arc4random_uniform(200) / 1000.0);
            [NSThread sleepForTimeInterval:rankGroupDelay];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.enableAutoCollect && cycle == collectionCycle) [self startTakeLookContinuation];
        });
    });
}


// 每隔300秒一次
-(void)autoCollectBubbles {
    @try {
        if (!self.enableAutoCollect || !self.jsBridge) {
            [self recordStage:[NSString stringWithFormat:@"诊断 · 收取未启动：自动收取=%d，桥接=%d", self.enableAutoCollect, self.jsBridge != nil]];
            return;
        }
        if (self.isScanRunning) {
            [self recordStage:@"诊断 · 收取跳过：本轮扫描正在执行中"];
            return;
        }
        self.isScanRunning = YES;
        oceanCleanedInCurrentRound = 0;
        oceanPlanLoggedThisRound = NO;
        lastCollectStartedAt = NSDate.date;
        collectionCycle++;
        NSUInteger cycle = collectionCycle;
        selfPriorityPending = self.enableSelfCollect;
        selfPriorityCycle = cycle;
        [deferredFriendRankIds removeAllObjects];
        deferredRankedFriendIds = nil;
        rankScanPending = YES;
        @synchronized (self) { [pendingCollectBubbles removeAllObjects]; }
        [self recordStage:@"本轮扫描开始"];
        [self queryTotalRank];
        if (self.enableCleanOcean) {
            [self cleanMyOceanThoroughly];
            [self queryOceanFriendList];
        }
        if (self.enableAutoRewardTasks) {
            [self queryVitalityTaskList];
        }
        if (selfPriorityPending) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self releaseSelfPriorityForCycle:cycle reason:@"本人首页回包超时"];
            });
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (rankScanPending && cycle == collectionCycle) {
                rankScanPending = NO;
                [self recordStage:@"诊断 · 排行榜回包超时，转入找能量续查"];
                [self startTakeLookContinuation];
            }
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.isScanRunning && cycle == collectionCycle) {
                self.isScanRunning = NO;
                [self recordStage:@"诊断 · 本轮扫描达到 45 秒安全超时释放锁"];
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
                        NSString *log = [NSString stringWithFormat:@"%@\n能量球等待结束 拾取: %@|%@",[[AntForestManager sharedInstance] getUserName:uid],bid,convertTimestampToDateString(overTimeValue)];
                        [[AntForestManager sharedInstance] addLog:log];
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
        NSDate *currentDate = [NSDate date];
        NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
        [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
        NSString *formattedDateString = [dateFormatter stringFromDate:currentDate];
        
        NSDictionary *dict = [[AntForestManager sharedInstance] friendsName];
        NSString *displayName =[[dict objectForKey:uid] objectForKey:@"displayName"];
        NSString *name =[[dict objectForKey:uid] objectForKey:@"name"];
        NSString *label = [NSString stringWithFormat:@"[%@]\n[%@,%@,%@]",formattedDateString,displayName,name,uid];
        return label;
    } @catch (NSException *exception) {
        // 捕获异常的代码
        FileLog(@"Exception caught: %@", exception);
        [Tool Alert:[exception description]];
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
        while(arrLog.count > 200) {
            [arrLog removeObjectAtIndex:0];
        }
        // 添加日志信息到数组中
        [arrLog addObject:cleanMessage];
        //[arrLog addObject:@""];
        
        // 发送通知通知更新文本视图
        [[NSNotificationCenter defaultCenter] postNotificationName:@"LogUpdated" object:nil];
        
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:arrLog requiringSecureCoding:NO error:nil];
        [[NSUserDefaults standardUserDefaults] setObject:data forKey:@"logRecord"];
        [[NSUserDefaults standardUserDefaults] synchronize];
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
        NSString *key = [NSString stringWithFormat:@"%@:%@:%ld", userId, bubbleId, (long)energy.integerValue];
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
    }
}

-(void)matchFriendIdAndBubbles:(id)args {
    @try {
        if ([args isKindOfClass:NSDictionary.class]) {
            NSDictionary *dict = args;
            NSDictionary *resData = [dict[@"resData"] isKindOfClass:NSDictionary.class] ? dict[@"resData"] : nil;
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
            if ([resultCode isEqualToString:@"LIMIT_EXCEEDED"] || [resultCode isEqualToString:@"ACCESS_DENIED"] || [resultCode isEqualToString:@"FORBIDDEN"] || [memo containsString:@"拒绝"] || [memo containsString:@"代理"] || [memo containsString:@"风控"]) {
                [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"oceanLimitReachedToday"];
                [self recordStage:@"神奇海洋：收到服务端安全风险拦截，已自动熔断暂停本日清理（保护账号安全）"];
            }
            if (resData && (resData[@"cleanRewardVOS"] || resData[@"canClearFriendSeaToday"] || [dict[@"methodName"] isEqualToString:@"cleanFriendsOcean"] || [dict[@"operationType"] containsString:@"cleanFriendOcean"] || [resultCode isEqualToString:@"HELP_CLEAN_LIMIT"] || [resData[@"resultCode"] isEqualToString:@"HELP_CLEAN_LIMIT"] || [resData[@"resultDesc"] containsString:@"今日清理好友海域的次数已达上限"])) {
                NSNumber *canClearToday = resData[@"canClearFriendSeaToday"];
                if ((canClearToday && [canClearToday boolValue] == NO) || [resultCode isEqualToString:@"HELP_CLEAN_LIMIT"] || [resData[@"resultCode"] isEqualToString:@"HELP_CLEAN_LIMIT"] || [resData[@"resultDesc"] containsString:@"今日清理好友海域的次数已达上限"]) {
                    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"oceanLimitReachedToday"];
                    [self recordStage:@"神奇海洋：服务端确认今日海域清理已达上限（勤劳的你，明天见～）"];
                    [self oceanStopWithReason:nil];
                    return;
                }
                NSArray *rewards = resData[@"cleanRewardVOS"];
                NSString *cleanedUid = resData[@"cleanedUserId"] ?: resData[@"userId"] ?: dict[@"cleanedUserId"] ?: oceanCurrentUserId ?: self.lastCleanedOceanUserId;
                BOOL isSelfOcean = !cleanedUid.length || [cleanedUid isEqualToString:self.myUserId];
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
                                if (self.enableCleanOcean && self.jsBridge) {
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
                } else if (!isSelfOcean && (oceanRunning || [dict[@"methodName"] isEqualToString:@"cleanFriendsOcean"] || [dict[@"operationType"] containsString:@"cleanFriendOcean"])) {
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
            NSArray *list = nil;
            if ([resData isKindOfClass:NSDictionary.class]) {
                list = resData[@"friendList"] ?: resData[@"friendOceanList"] ?: resData[@"friendSeaList"] ?: resData[@"friendListVO"] ?: resData[@"friendInfoList"] ?: resData[@"friends"] ?: resData[@"oceanFriendList"] ?: resData[@"friendUserList"] ?: resData[@"oceanFriends"];
            }
            if (!list && [dict isKindOfClass:NSDictionary.class]) {
                list = dict[@"friendList"] ?: dict[@"friendOceanList"] ?: dict[@"friendSeaList"] ?: dict[@"friendListVO"] ?: dict[@"friendInfoList"] ?: dict[@"friends"] ?: dict[@"oceanFriendList"];
            }
            if ([list isKindOfClass:NSArray.class] && list.count > 0) {
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
            NSString *opType = [NSString stringWithFormat:@"%@", dict[@"operationType"] ?: @""];
            if ([opType containsString:@"protectBubble"] || [dict[@"handlerName"] isEqualToString:@"protectBubble"] || resData[@"protectBubble"] || resData[@"userProtectResult"]) {
                [self handleAutoReviveResponse:args];
            }
            NSArray *taskInfoList = [resData[@"taskInfoList"] isKindOfClass:NSArray.class] ? resData[@"taskInfoList"] : ([dict[@"taskInfoList"] isKindOfClass:NSArray.class] ? dict[@"taskInfoList"] : nil);
            if (resData[@"antOceanTaskVOList"] || [dict[@"antOceanTaskVOList"] isKindOfClass:NSArray.class]) {
                [self handleOceanTaskListResponse:resData ?: dict];
            }
            if (resData[@"forestTasksNew"] || resData[@"energySignVO"] || taskInfoList || resData[@"drawAsset"] || resData[@"drawEntranceVO"] || resData[@"drawActivity"] || resData[@"drawPrize"] || resData[@"drawPrizes"] || [opType containsString:@"antiep"] || [opType containsString:@"queryTaskList"] || [opType containsString:@"draw"] || [opType containsString:@"exchangeVitality"] || [resData[@"code"] isEqualToString:@"400000040"] || [resData[@"code"] isEqualToString:@"400000004"] || [resData[@"code"] isEqualToString:@"400000030"] || [resData[@"code"] isEqualToString:@"B000000008"] || [resData[@"desc"] containsString:@"不支持rpc调用"] || [resData[@"desc"] containsString:@"无法领取"] || [dict[@"error"] integerValue] == 3000) {
                [self handleVitalityTaskListResponse:resData ?: dict];
            }
            
            // 自动识别本人ID
            NSString *curUid = resData[@"userBaseInfo"][@"userId"] ?: dict[@"userBaseInfo"][@"userId"] ?: resData[@"userEnergy"][@"userId"] ?: dict[@"userEnergy"][@"userId"] ?: resData[@"loginUserBaseInfo"][@"userId"] ?: dict[@"loginUserBaseInfo"][@"userId"];
            if (curUid.length) {
                if (!self.myUserId.length) {
                    self.myUserId = curUid;
                    [self recordStage:@"本人账户已识别"];
                }
                [[NSUserDefaults standardUserDefaults] setObject:curUid forKey:@"lastKnownUserId"];
            }
            
            // 巡护动物能量球成功回包校验 (只要回包带 collectedEnergy > 0 或匹配相关 opType)
            NSInteger collected = [resData[@"collectedEnergy"] integerValue];
            if (collected > 0 || [opType containsString:@"collectAnimalRobEnergy"] || ([opType containsString:@"collectEnergy"] && [dict[@"bizType"] isEqualToString:@"animal"])) {
                NSString *resResultCode = resData[@"resultCode"] ?: dict[@"resultCode"];
                if ([resResultCode isEqualToString:@"SUCCESS"] || [resData[@"success"] boolValue] || collected > 0) {
                    NSString *today = getCurrentDateString();
                    [[NSUserDefaults standardUserDefaults] setObject:today forKey:@"todayAnimalEnergyCollectedDate"];
                    [[NSUserDefaults standardUserDefaults] synchronize];
                    [self recordStage:[NSString stringWithFormat:@"收取 · 巡护动物（大鲵）能量球已成功收取（%ldg）！", (long)(collected > 0 ? collected : 30)]];
                } else if ([resResultCode isEqualToString:@"SYSTEM_FAILURE"] || [dict[@"resultDesc"] containsString:@"开小差"] || [resData[@"resultDesc"] containsString:@"开小差"] || [resResultCode isEqualToString:@"ENERGY_CAN_NOT_COLLECT"]) {
                    NSString *today = getCurrentDateString();
                    [[NSUserDefaults standardUserDefaults] setObject:today forKey:@"todayAnimalEnergyCollectedDate"];
                    [[NSUserDefaults standardUserDefaults] synchronize];
                    [self recordStage:@"保护地巡护 · 今日动物巡护能量已收过或不可收，锁定今日防重"];
                }
            }
            
            // 自动检测森林伙伴/巡护动物 (userCreatureVO)
            NSDictionary *creatureVO = resData[@"userCreatureVO"] ?: dict[@"userCreatureVO"];
            if ([creatureVO isKindOfClass:NSDictionary.class]) {
                NSString *cCode = creatureVO[@"creatureCode"] ?: @"hongshandongwuyuan#dani";
                NSString *cName = creatureVO[@"displayInfo"][@"creatureNameText"] ?: @"大鲵";
                NSInteger cEnergy = [creatureVO[@"levelRobEnergy"] integerValue] ?: [creatureVO[@"initialRobEnergy"] integerValue];
                if (cEnergy <= 0) cEnergy = 40;
                
                NSString *today = getCurrentDateString();
                NSString *savedAnimalDate = [[NSUserDefaults standardUserDefaults] stringForKey:@"todayAnimalEnergyCollectedDate"];
                if (![today isEqualToString:savedAnimalDate]) {
                    [self receiveAnimalEnergyWithPropId:cCode propType:cCode animalId:cCode energy:cEnergy name:cName isCollected:NO];
                    
                    // 动物模型加载并渲染后，延迟脉冲模拟触发气泡点击
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [[NSNotificationCenter defaultCenter] postNotificationName:@"AntForestCollectAnimalEnergyNotification" object:nil];
                    });
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [[NSNotificationCenter defaultCenter] postNotificationName:@"AntForestCollectAnimalEnergyNotification" object:nil];
                    });
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [[NSNotificationCenter defaultCenter] postNotificationName:@"AntForestCollectAnimalEnergyNotification" object:nil];
                    });
                }
            }
        }
        [self recordCollectedEnergyFromResponse:args];
        if (!self.enableAutoCollect) return;
        if (args != nil && [args isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dict = args;
            NSDictionary *resData = [dict[@"resData"] isKindOfClass:NSDictionary.class] ? dict[@"resData"] : nil;
            // 匹配 过期能量球 返回的  signId
            if(resData && resData[@"forestSignVOList"]) {
                NSArray *signList = resData[@"forestSignVOList"];
                for( NSDictionary *sign in signList) {
                    NSString *signId = [sign objectForKey:@"signId"];
                    NSString *userId = [[AntForestManager sharedInstance] myUserId]; //我自己的ID
                    NSArray *signRecords = [sign objectForKey:@"signRecords"];
                    for(NSDictionary *record in signRecords){
                        NSString *signKey = [record objectForKey:@"signKey"];
                        NSString *isSigned = [NSString stringWithFormat:@"%@", [record objectForKey:@"signed"]];
                        if([signKey isEqualToString:getCurrentDateString()] && [isSigned isEqualToString:@"0"]){
                            if(signId){
                                NSString *log = [NSString stringWithFormat:@"%@\n找到复活能量球:%@ 复活",[[AntForestManager sharedInstance] getUserName:userId],signId];
                                [[AntForestManager sharedInstance] addLog:log];
                                [[AntForestManager sharedInstance] reviveEnergy:userId signId:signId];
                            }
                        }
                    }
                }
            }
            
            // 匹配 takelook 返回的 friendID（仅当插件正在执行后台找能量扫描时才由插件接管并查气泡，避免干扰用户手动找能量跳转）
            if(takeLookRunning && resData && resData[@"friendId"]) {
                NSString *friendId = resData[@"friendId"];
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
            // 匹配查询好的返回的所有能量球（兼容 userBaseInfo、userEnergy 与 loginUserBaseInfo）
            if((dict[@"bubbles"] || dict[@"wateringBubbles"]) && (dict[@"userBaseInfo"] || dict[@"loginUserBaseInfo"] || dict[@"userEnergy"])) {
                NSString *userId = nil;
                if([dict objectForKey:@"userBaseInfo"]) {
                    NSDictionary *pDic = [dict objectForKey:@"userBaseInfo"];
                    userId = [pDic objectForKey:@"userId"];
                } else if ([dict objectForKey:@"userEnergy"]) {
                    NSDictionary *pDic = [dict objectForKey:@"userEnergy"];
                    userId = [pDic objectForKey:@"userId"];
                } else if ([dict objectForKey:@"loginUserBaseInfo"]) {
                    NSDictionary *pDic = [dict objectForKey:@"loginUserBaseInfo"];
                    userId = [pDic objectForKey:@"userId"];
                    if (userId.length && !self.myUserId.length) {
                        self.myUserId = userId;
                        [self recordStage:@"本人账户已识别"];
                    }
                }
                if (!userId.length) userId = self.myUserId;
                if (!userId.length && !self.myUserId.length) {
                    [self recordStage:@"诊断 · 气泡回包跳过：本人账户尚未识别"];
                    return;
                }
                
                NSString *dName = dict[@"userEnergy"][@"displayName"] ?: dict[@"userBaseInfo"][@"displayName"];
                if (userId.length && [dName isKindOfClass:NSString.class] && dName.length && !self.friendsName[userId]) {
                    self.friendsName[userId] = dName;
                }
                
                BOOL mine = (dict[@"loginUserBaseInfo"] && !dict[@"userBaseInfo"] && !dict[@"userEnergy"]) || (userId.length && [userId isEqualToString:self.myUserId]);
                
                if (self.enableAutoRevive && !mine && userId.length) {
                    NSDictionary *userInfo = [dict[@"userBaseInfo"] isKindOfClass:NSDictionary.class] ? dict[@"userBaseInfo"] : nil;
                    NSDictionary *userEnergy = [dict[@"userEnergy"] isKindOfClass:NSDictionary.class] ? dict[@"userEnergy"] : nil;
                    NSDictionary *userForest = [dict[@"userForest"] isKindOfClass:NSDictionary.class] ? dict[@"userForest"] : nil;
                    NSInteger restTimes = extractRestTimesFromDict(dict);
                    if (restTimes >= 0) {
                        NSInteger used = MAX(0, 6 - restTimes);
                        [NSUserDefaults.standardUserDefaults setInteger:used forKey:@"autoReviveCount"];
                    }
                    if (canReviveFriendBubble(dict) || canReviveFriendBubble(userInfo) || canReviveFriendBubble(userEnergy) || canReviveFriendBubble(userForest) || [dict[@"forestSignVOList"] isKindOfClass:NSArray.class]) {
                        [self queueAutoReviveForUser:userId];
                    }
                }
                
                //判断是否有能量保护罩
                if (!mine) {
                    NSArray *pArr = [dict objectForKey:@"usingUserProps"] ?: [dict objectForKey:@"usingUserPropsNew"];
                    if(pArr) {
                        for(NSDictionary *dic in pArr){
                            NSString *type = [dic objectForKey:@"type"] ?: [dic objectForKey:@"propGroup"] ?: @"";
                            if([type containsString:@"Shield"] || [type containsString:@"shield"]){
                                [self recordStage:@"诊断 · 好友气泡回包：检测到保护罩，跳过该好友"];
                                NSString *log = [NSString stringWithFormat:@"%@\n检测到保护罩,跳过拾取",[[AntForestManager sharedInstance] getUserName:userId]];
                                [[AntForestManager sharedInstance] addLog:log];
                                [self advanceTakeLookForFriend:userId];
                                return;
                            }
                        }
                    }
                }
                
                NSMutableDictionary *dictBubbles = [dict objectForKey:@"bubbles"];
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
                                NSString *animalId = extInfo[@"animal"][@"animalId"] ?: extInfo[@"animalId"] ?: @"";
                                NSString *animalName = extInfo[@"animal"][@"name"] ?: extInfo[@"name"] ?: prop[@"propName"] ?: @"巡护伙伴";
                                BOOL isCollected = [extInfo[@"isCollected"] boolValue];
                                NSInteger energy = [extInfo[@"energy"] integerValue];
                                if (energy <= 0) energy = [extInfo[@"leftEnergy"] integerValue];
                                if (energy <= 0) energy = [extInfo[@"uncollectedEnergy"] integerValue];
                                if (energy <= 0) energy = [extInfo[@"robEnergyInRound"] integerValue];
                                if (energy <= 0) energy = [extInfo[@"animal"][@"energy"] integerValue];
                                if (energy <= 0) energy = [extInfo[@"animal"][@"robAbility"][@"robEnergyInRound"] integerValue];
                                [self receiveAnimalEnergyWithPropId:propId propType:pType animalId:animalId energy:energy name:animalName isCollected:isCollected];
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
                                NSInteger wEnergy = [wb[@"fullEnergy"] integerValue] ?: [wb[@"energy"] integerValue];
                                [self receiveAnimalEnergyWithPropId:bId propType:@"hongshandongwuyuan#dani" animalId:@"hongshandongwuyuan#dani" energy:wEnergy name:@"大鲵" isCollected:NO];
                            }
                        }
                    }
                }
                [self recordStage:[NSString stringWithFormat:@"诊断 · %@气泡回包：总 %lu 个，可收 %lu 个，等待 %lu 个", mine ? @"本人" : @"好友", (unsigned long)dictBubbles.count, (unsigned long)available, (unsigned long)waiting]];
                if (mine) [self recordStage:[NSString stringWithFormat:@"本人首页回包：总 %lu 个，可收 %lu 个，等待 %lu 个", (unsigned long)dictBubbles.count, (unsigned long)available, (unsigned long)waiting]];
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
                        NSString *log = [NSString stringWithFormat:@"%@\n找到可领能量球(%@g) 收取, %@",[[AntForestManager sharedInstance] getUserName:bUserId],remainEnergy,bid];
                        [[AntForestManager sharedInstance] addLog:log];
                        dispatch_async(globalSerialQueueCollect, ^{
                            [[AntForestManager sharedInstance] collectBubbles:bUserId bubblesId:bid];
                        });
                        
                    }
                    if([[bubble objectForKey:@"collectStatus"] isEqualToString:@"INSUFFICIENT"]){
                        NSString *log = [NSString stringWithFormat:@"%@\n能量不足,剩%@g, %@",[[AntForestManager sharedInstance] getUserName:bUserId],remainEnergy,bid];
                        [[AntForestManager sharedInstance] addLog:log];
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
                        NSString *log = [NSString stringWithFormat:@"%@\n找到等待能量球(%@g) 入库, %@",[[AntForestManager sharedInstance] getUserName:bUserId],remainEnergy,bid];
                        [[AntForestManager sharedInstance] addLog:log];
                    }
                    //可帮助直接帮助
                    if([[bubble objectForKey:@"canHelpCollect"] isEqualToNumber:@1]){
                        NSString *log = [NSString stringWithFormat:@"%@\n找到帮助能量球(%@g) 帮助, %@",[[AntForestManager sharedInstance] getUserName:bUserId],remainEnergy,bid];
                        [[AntForestManager sharedInstance] addLog:log];
                    }
                }
                
                // 匹配 wateringBubbles（包含好友浇水赠能、保护地巡护动物每日巡护能量球）
                NSArray *wateringBubbles = [dict objectForKey:@"wateringBubbles"];
                if ([wateringBubbles isKindOfClass:NSArray.class]) {
                    for (NSDictionary *wb in wateringBubbles) {
                        if (![wb isKindOfClass:NSDictionary.class]) continue;
                        NSNumber *bidNum = wb[@"id"];
                        if (bidNum && [bidNum longLongValue] > 0) {
                            NSString *bid = [bidNum stringValue];
                            NSString *bizType = wb[@"bizType"] ?: @"";
                            NSString *fullEnergy = [NSString stringWithFormat:@"%@", wb[@"fullEnergy"] ?: @""];
                            NSString *giverUid = wb[@"userId"] ?: @"";
                            
                            // 仅本人首页的赠能/巡护能量，或好友页明确允许代收(canHelpCollect)才收
                            if (mine || [wb[@"canHelpCollect"] isEqualToNumber:@1]) {
                                NSString *targetUid = mine ? self.myUserId : (userId ?: self.myUserId);
                                NSString *log = [NSString stringWithFormat:@"%@\n找到赠能/巡护能量球(%@g) 收取, %@", giverUid.length ? [[AntForestManager sharedInstance] getUserName:giverUid] : [[AntForestManager sharedInstance] getUserName:targetUid], fullEnergy, bid];
                                [[AntForestManager sharedInstance] addLog:log];
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
                if (userIdMy.length) {
                    if (!self.myUserId.length) {
                        [[AntForestManager sharedInstance] setMyUserId:userIdMy];
                        [self recordStage:@"收取 · 本人账户已识别"];
                    } else {
                        [[AntForestManager sharedInstance] setMyUserId:userIdMy];
                    }
                }
                NSNumber *canCollectEnergy = [myDict objectForKey:@"canCollectEnergy"];
                [self recordStage:[NSString stringWithFormat:@"诊断 · 本人能量状态：%@", [canCollectEnergy isEqualToNumber:@1] ? @"可收" : @"暂无成熟能量"]];
                if(self.enableSelfCollect) {
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
            if(resData && (resData[@"friendRanking"] || resData[@"totalDatas"])) {
                NSArray *rankArr = [resData[@"friendRanking"] isKindOfClass:NSArray.class] ? resData[@"friendRanking"] : resData[@"totalDatas"];
                NSUInteger collectable = 0;
                for (NSDictionary *dictRank in rankArr) if ([[dictRank objectForKey:@"canCollectEnergy"] isEqualToNumber:@1]) collectable++;
                [self recordStage:[NSString stringWithFormat:@"诊断 · 排行榜校验回包：%lu 位，可收 %lu 位", (unsigned long)rankArr.count, (unsigned long)collectable]];
                for(NSDictionary *dictRank in rankArr) {
                    NSString *userId = [AntForestManager extractUserIdFromDictionary:dictRank] ?: [dictRank objectForKey:@"userId"];
                    if (!userId.length) continue;
                    BOOL isCollectable = [[dictRank objectForKey:@"canCollectEnergy"] isEqualToNumber:@1];
                    BOOL isReviveable = canReviveFriendBubble(dictRank);
                    if (isReviveable) {
                        [self queueAutoReviveForUser:userId];
                    }
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
            //匹配排行
            NSArray *rankTotalArr = [resData[@"totalDatas"] isKindOfClass:NSArray.class] ? resData[@"totalDatas"] : ([resData[@"friendRanking"] isKindOfClass:NSArray.class] ? resData[@"friendRanking"] : nil);
            if (rankTotalArr.count > 0) {
                NSMutableDictionary *fr = [[AntForestManager sharedInstance] friendsRank];
                NSMutableDictionary *fn = [[AntForestManager sharedInstance] friendsName];
                BOOL nameUpdated = NO;
                for(NSDictionary *dictTotalRank in rankTotalArr) {
                    NSString *userId = [AntForestManager extractUserIdFromDictionary:dictTotalRank] ?: [dictTotalRank objectForKey:@"userId"];
                    if (!userId.length) continue;
                    if (canReviveFriendBubble(dictTotalRank)) {
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
                NSData *rankData = [NSKeyedArchiver archivedDataWithRootObject:fr requiringSecureCoding:NO error:nil];
                if (rankData) {
                    [[NSUserDefaults standardUserDefaults] setObject:rankData forKey:@"cachedFriendsRank"];
                    [[NSUserDefaults standardUserDefaults] synchronize];
                }
                if (nameUpdated) {
                    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:fn requiringSecureCoding:NO error:nil];
                    if (data) {
                        [[NSUserDefaults standardUserDefaults] setObject:data forKey:@"friendsName"];
                        [[NSUserDefaults standardUserDefaults] synchronize];
                    }
                }
                if (rankScanPending) {
                    rankScanPending = NO;
                    if (selfPriorityPending) {
                        deferredRankedFriendIds = fr.allKeys;
                    } else {
                        [self scanRankedFriends:fr.allKeys cycle:collectionCycle];
                    }
                }
                if (self.enableCleanOcean && fr.allKeys.count > 0) {
                    [self scanOceanForFriends:fr.allKeys];
                }
                BOOL hasMore = [resData[@"hasMore"] boolValue] || [resData[@"hasNext"] boolValue];
                NSInteger nextIndex = [resData[@"nextStartIndex"] integerValue] ?: [resData[@"startIndex"] integerValue] + rankTotalArr.count;
                if ((hasMore || rankTotalArr.count >= 200) && nextIndex > 0 && nextIndex < 1000) {
                    static NSInteger lastFetchedIndex = 0;
                    if (nextIndex > lastFetchedIndex) {
                        lastFetchedIndex = nextIndex;
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(800 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                            [self queryRankPage:nextIndex];
                        });
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
