//
//  AntForestManager.m
//  antforest
//
//  Created by qsir on 2024/11/9.
//

#import "AntForestManager.h"
#import <UIKit/UIKit.h>
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
            [self recordStage:@"收取 · 复活奖励：请求本人首页"];
            [self queryMyBubbles];
        }
    });
}

- (void)reviveStopWithReason:(NSString *)reason {
    reviveRunning = NO;
    reviveCurrentUserId = nil;
    reviveRequestToken++;
    [reviveQueue removeAllObjects];
    if (reason.length) [self recordStage:[NSString stringWithFormat:@"收取 · 复活 · %@", reason]];
    [self reviveRefreshRewardIfNeeded];
}

- (void)reviveSendNext {
    if (!self.enableAutoRevive || !self.jsBridge) {
        if (reviveRunning) [self reviveStopWithReason:@"任务已停止或桥接不可用"];
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
    NSDictionary *dataOld = @{ @"handlerName": @"rpc", @"data": @{ @"operationType": @"alipay.antmember.forest.h5.protectBubble", @"headers": @{ @"source": @"chInfo_ch_appcenter__chsub_9patch", @"ags-source": @"chInfo_ch_appcenter__chsub_9patch" }, @"requestData": @[body], @"getResponse": @YES }, @"callbackId": [NSString stringWithFormat:@"revive_%@.%@_old", timestamp, [AntForestManager getNumberRandom:12]] };
    NSString *queue1 = waterJSONString(@[data]);
    NSString *queue2 = waterJSONString(@[dataOld]);
    if (!queue1.length) { [self reviveStopWithReason:@"请求编码失败"]; return; }
    NSString *url = [NSString stringWithFormat:@"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&userId=%@&__webview_options__=bc%%3D3194732&source=chInfo_ch_appcenter__chsub_9patch", reviveCurrentUserId];
    [self recordStage:[NSString stringWithFormat:@"收取 · 复活 · 请求帮助好友“%@”复活能量", name]];
    [self.jsBridge _doFlushMessageQueue:queue1 url:url];
    if (queue2.length) [self.jsBridge _doFlushMessageQueue:queue2 url:url];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (reviveRunning && token == reviveRequestToken) [self reviveStopWithReason:@"回包超时，已停止"];
    });
}

- (void)queueAutoReviveForUser:(NSString *)userId {
    if (!self.enableAutoRevive || !userId.length || [userId isEqualToString:self.myUserId]) return;
    if (reviveRunning && [reviveCurrentUserId isEqualToString:userId]) return;
    if ([reviveQueue containsObject:userId] || [reviveQueuedIds containsObject:userId]) return;
    NSString *name = [AntForestManager extractNameFromDictionary:self.friendsName[userId]] ?: @"好友";
    [self recordStage:[NSString stringWithFormat:@"收取 · 复活 · 发现好友“%@”有待复活能量，加入复活队列", name]];
    [reviveQueue addObject:userId];
    if (!reviveRunning) [self reviveSendNext];
}

- (void)handleAutoReviveResponse:(id)args {
    if (!reviveRunning || ![args isKindOfClass:NSDictionary.class]) return;
    NSDictionary *resData = [(NSDictionary *)args[@"resData"] isKindOfClass:NSDictionary.class] ? args[@"resData"] : nil;
    if (!resData) return;
    NSString *name = [AntForestManager extractNameFromDictionary:self.friendsName[reviveCurrentUserId]] ?: @"好友";
    if (waterResponseSucceeded(resData) || [resData[@"success"] boolValue] || [[resData[@"resultCode"] description] isEqualToString:@"SUCCESS"]) {
        NSInteger count = reviveDailyCount() + 1;
        [NSUserDefaults.standardUserDefaults setInteger:count forKey:@"autoReviveCount"];
        if (reviveCurrentUserId.length) [reviveQueuedIds addObject:reviveCurrentUserId];
        [self recordStage:[NSString stringWithFormat:@"收取 · 复活 · 成功帮助好友“%@”复活能量（今日 %ld/6 次）", name, (long)count]];
        reviveRewardRefreshNeeded = YES;
        reviveRunning = NO;
        reviveCurrentUserId = nil;
        reviveRequestToken++;
        [self reviveSendNext];
    } else {
        NSString *code = waterResponseCode(resData);
        if ([code isEqualToString:@"TARGET_USER_PROTECT_BY_ENERGY_SHIELD"]) {
            if (reviveCurrentUserId.length) [reviveQueuedIds addObject:reviveCurrentUserId];
            [self recordStage:[NSString stringWithFormat:@"收取 · 复活 · 好友“%@”已有能量保护罩，已跳过", name]];
            reviveRunning = NO;
            reviveCurrentUserId = nil;
            reviveRequestToken++;
            [self reviveSendNext];
            return;
        }
        if ([code containsString:@"LIMIT"] || [code containsString:@"EXCEED"] || [code containsString:@"OVER"] || [code containsString:@"TIRED"] || [code isEqualToString:@"PROTECT_REBORN_TIRED"]) {
            [NSUserDefaults.standardUserDefaults setInteger:6 forKey:@"autoReviveCount"];
            [self recordStage:[NSString stringWithFormat:@"收取 · 复活 · 帮复活能量已达支付宝官方上限（今天已用完，明天再继续吧）"]];
            reviveRunning = NO;
            reviveCurrentUserId = nil;
            reviveRequestToken++;
            [reviveQueue removeAllObjects];
            return;
        }
        [self recordStage:[NSString stringWithFormat:@"收取 · 复活 · 帮助好友“%@”复活回包：%@，尝试下一位", name, waterResponseSummary(resData)]];
        reviveRunning = NO;
        reviveCurrentUserId = nil;
        reviveRequestToken++;
        [self reviveSendNext];
    }
}

- (void)waterFinishCurrentFriendWithStatus:(NSString *)status {
    NSString *name = [self waterDisplayNameForUser:waterCurrentUserId];
    if (status.length) [self recordStage:[NSString stringWithFormat:@"收取 · 浇水 · %@：%@", name, status]];
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
    [self recordStage:[NSString stringWithFormat:@"收取 · 浇水 · 任务结束：%@", reason]];
    waterQueue = nil;
    waterCurrentUserId = nil;
    waterCurrentBizNo = nil;
    if (!collectAfterLaunchWater) return;
    collectAfterLaunchWater = NO;
    if (!self.enableAutoCollect || !self.jsBridge) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self recordStage:@"收取 · 蚂蚁森林自动浇水结束，开始自动收取"];
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
    [self recordStage:[NSString stringWithFormat:@"收取 · 浇水 · 诊断：请求第 %lu/%lu 次浇水（提醒=%@）", (unsigned long)(waterSucceededCount + 1), (unsigned long)waterTargetCount, self.waterReminderEnabled ? @"开" : @"关"]];
    [self waterSendRPC:@"alipay.antforest.forest.h5.transferEnergy" body:body];
    [self waterSendRPC:@"alipay.antmember.forest.h5.transferEnergy" body:body];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!waterRunning || requestToken != waterRequestToken || !waterAwaitingTransfer) return;
        if (waterTransferRetryCount++ == 0) {
            waterAwaitingTransfer = NO;
            waterRetryCount = 0;
            [self recordStage:@"收取 · 浇水 · 收取回包超时，重新获取好友凭据后重试"];
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
    if (waterRunning) { [self recordStage:@"收取 · 浇水 · 当前任务仍在执行"]; return; }
    NSArray *friends = [[NSOrderedSet orderedSetWithArray:self.waterFriendIds ?: @[]].array filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *uid, __unused NSDictionary *bindings) { return uid.length > 0; }]];
    if (!friends.count) { [self recordStage:@"收取 · 浇水 · 未选择好友"]; return; }
    if (!self.jsBridge) { [self recordStage:@"收取 · 浇水 · H5 Bridge 未连接"]; return; }
    waterRunning = YES;
    waterQueue = friends;
    waterQueueIndex = 0;
    waterRunReason = reason ?: @"手动浇水";
    [self recordStage:[NSString stringWithFormat:@"收取 · 浇水 · %@开始：%lu 位好友，%ld g，每人补足至每日 3 次", waterRunReason, (unsigned long)friends.count, (long)self.waterGrams]];
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
        [self recordStage:@"收取 · 蚂蚁森林自动浇水跳过：已有浇水任务运行中"];
        if (shouldCollect) [self autoCollectBubbles];
        return;
    }
    if (!self.waterFriendIds.count) {
        [self recordStage:@"收取 · 蚂蚁森林自动浇水跳过：未选择好友"];
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
        [self recordStage:@"收取 · 浇水 · 已获取好友主页凭据"];
        [self waterRequestLimit];
        return;
    }
    if (waterAwaitingLimit) {
        if (!waterFindValue(args, @"waterLimit", 0)) return;
        [self recordStage:@"收取 · 浇水 · 已通过浇水限额校验"];
        [self waterTransferOnce];
        return;
    }
    if (!waterAwaitingTransfer) return;
    [self recordStage:[NSString stringWithFormat:@"收取 · 浇水 · 诊断：收取回包 %@", waterResponseSummary(args)]];
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
                [self recordStage:[NSString stringWithFormat:@"收取 · 浇水 · %@，%.0f 秒后重新获取凭据重试", [code isEqualToString:@"WATER_NOT_GET_LOCK"] ? @"服务端限流" : @"服务端参数异常", delay]];
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
    [self recordStage:[NSString stringWithFormat:@"收取 · 浇水 · %@：成功 %lu/%lu，%ld g", [self waterDisplayNameForUser:waterCurrentUserId], (unsigned long)waterSucceededCount, (unsigned long)waterTargetCount, (long)self.waterGrams]];
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
    [self recordStage:@"收取 · 浇水 · 已请求刷新好友列表"];
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
        [self recordStage:@"收取 · 浇水 · 已移除不在总榜内的好友选择"];
    }
    [self recordStage:[NSString stringWithFormat:@"收取 · 浇水 · 好友列表刷新完成：%lu 位", (unsigned long)self.friendsRank.count]];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"WaterFriendListUpdated" object:nil];
}

- (void)releaseSelfPriorityForCycle:(NSUInteger)cycle reason:(NSString *)reason {
    if (!selfPriorityPending || selfPriorityCycle != cycle) return;
    selfPriorityPending = NO;
    NSArray<NSString *> *friendIds = deferredFriendRankIds.copy;
    NSArray<NSString *> *rankedIds = deferredRankedFriendIds;
    [deferredFriendRankIds removeAllObjects];
    deferredRankedFriendIds = nil;
    [self recordStage:[NSString stringWithFormat:@"收取 · 本人优先完成，开始好友扫描（%@）", reason]];
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
    if (![stage hasPrefix:@"收取 ·"]) {
        return;
    }
    if (self.logRecord) [self addLog:[NSString stringWithFormat:@"%@\n%@", getCurrentDateTimeString(), stage]];
}

-(void)startAutoCollectTimerWithInterval:(NSTimeInterval)interval{
    if (self.autoCollectTimer.isValid && self.collectInterval == interval) {
        return;
    }
    [self.autoCollectTimer invalidate];
    self.autoCollectTimer = nil;
    self.collectInterval = interval;
    self.failedTimes = 0; //每次重新启动定时器时 失败次数均要置 0
    [self recordStage:[NSString stringWithFormat:@"收取 · 后台循环已启动（%ld 分钟）", (long)MAX(1, interval / 60)]];
    
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
    [self recordStage:@"收取 · 定时收取开始"];
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
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.takeLook\",\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"skipUsers\":%@,\"version\":\"%@\",\"contactsStatus\":\"N\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]",skipUsersJSON,version,timeStamp,randNum];
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
            [self recordStage:[NSString stringWithFormat:@"收取 · 本轮扫描结束：%@", reason]];
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
            [self recordStage:@"收取 · 本轮扫描完成"];
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
            [self recordStage:@"收取 · 本轮扫描完成"];
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

static NSTimeInterval lastMyBubblesQueryTime = 0;

-(void)queryMyBubbles {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - lastMyBubblesQueryTime < 3.0) return;
    lastMyBubblesQueryTime = now;
    
    [self recordStage:@"收取 · 请求本人首页（含赠能）"];
    [[AntForestManager sharedLock] lock];
    
    NSString *version = @"20241025";
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:16];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.queryHomePage\",\"requestData\":[{\"version\":\"%@\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"configVersionMap\":{\"wateringBubbleConfig\":\"0\"},\"skipWhackMole\":false,\"activityParam\":{}}]},\"callbackId\":\"rpc_%@.%@\"}]",version,timeStamp,randNum];
    NSString *arg2 = [NSString stringWithFormat:@"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&__webview_options__=bc%%3D3194732"];
    
    if([self jsBridge]) {
        [[self jsBridge] _doFlushMessageQueue:arg1 url:arg2];
        //FileLog(@"anthook queryMyBubbles");
    }
    
    [NSThread sleepForTimeInterval:0.5];
    [[AntForestManager sharedLock] unlock];
}

//查询能量球
-(void)queryFriendsBubbles:(NSString*)friendId {
    [[AntForestManager sharedLock] lock];
    
    NSString *version = @"20241025";
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:15];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.queryFriendHomePage\",\"requestData\":[{\"userId\":\"%@\",\"version\":\"%@\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"fromAct\":\"TAKE_LOOK\",\"configVersionMap\":{\"wateringBubbleConfig\":\"0\"},\"skipWhackMole\":false,\"activityParam\":{},\"currentEnergy\":99999999,\"currentVitalityAmount\":8888888}]},\"callbackId\":\"rpc_%@.%@\"}]",friendId,version,timeStamp,randNum];
    NSString *arg2 = [NSString stringWithFormat:@"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&userId=%@&__webview_options__=bc%%3D3194732&source=chInfo_ch_appcenter__chsub_9patch&fromAct=TAKE_LOOK",friendId];
    
    if([self jsBridge]) {
        [self recordStage:@"诊断 · 请求好友气泡"];
        [[self jsBridge] _doFlushMessageQueue:arg1 url:arg2];
        //FileLog(@"anthook queryFriendsBubbles: %@",friendId);
    }
    
    double randomDelay = 0.45 + (arc4random_uniform(400) / 1000.0);
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
        [self recordStage:@"收取 · 已跳过本人能量"];
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
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antmember.forest.h5.collectEnergy\",\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"userId\":\"%@\",\"bubbleIds\":[%@],\"bizType\":\"\",\"fromAct\":\"TAKE_LOOK\",\"version\":\"%@\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]",userId,bubbleIds,version,timeStamp,randNum];
    NSString *arg2 = [NSString stringWithFormat:@"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&userId=%@&__webview_options__=bc%%3D3194732&source=chInfo_ch_appcenter__chsub_9patch&fromAct=TAKE_LOOK", userId];
    if([self jsBridge]) {
        [self recordStage:[NSString stringWithFormat:@"诊断 · 请求收取能量：第 %lu 轮，待确认 %lu 笔", (unsigned long)collectionCycle, (unsigned long)pendingCollectBubbles.count]];
        [[self jsBridge] _doFlushMessageQueue:arg1 url:arg2];
        //FileLog(@"anthook collectBubbles: %@ | [%@] ",uid,bids);
    }
    double collectRandomDelay = 0.35 + (arc4random_uniform(400) / 1000.0);
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
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antiep.sign\",\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"source\":\"ANTFOREST\",\"sceneCode\":\"ANTFOREST_ENERGY_SIGN\",\"requestType\":\"rpc\",\"userId\":\"%@\",\"entityId\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}",uid,signId,timeStamp,randNum];
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
    if (self.myUserId.length) self.lastCleanedOceanUserId = self.myUserId;
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:15];
    NSString *randNum2=[AntForestManager getNumberRandom:16];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antocean.ocean.h5.cleanOcean\",\"requestData\":[{\"cleanedUserId\":\"%@\",\"source\":\"ANT_FOREST_ly'\",\"uniqueId\":\"%@%@\"}],\"appName\":\"antocean\",\"facadeName\":\"InteractController\",\"methodName\":\"cleanOcean\",\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]",[[AntForestManager sharedInstance] myUserId],timeStamp,randNum,timeStamp,randNum2];
    NSString *arg2 = [NSString stringWithFormat:@"https://2021003115672468.h5app.alipay.com/www/index.html"];
    if([self jsBridge]) {
        [[self jsBridge] _doFlushMessageQueue:arg1 url:arg2];
        //FileLog(@"anthook cleanMyOcean");
    }
}

//清理朋友的海域
-(void)cleanFriendsOcean:(NSString*)uid{
    if (!uid.length) return;
    self.lastCleanedOceanUserId = uid;
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:15];
    NSString *randNum2=[AntForestManager getNumberRandom:16];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antocean.ocean.h5.cleanFriendOcean\",\"requestData\":[{\"cleanedUserId\":\"%@\",\"source\":\"ANT_FOREST_ly'\",\"uniqueId\":\"%@%@\"}],\"appName\":\"antocean\",\"facadeName\":\"InteractController\",\"methodName\":\"cleanFriendsOcean\",\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]",uid,timeStamp,randNum,timeStamp,randNum2];
    NSString *arg2 = [NSString stringWithFormat:@"https://2021003115672468.h5app.alipay.com/www/index.html?fromAct=SAIL_AWAY&userId=%@&interactFlags=&source=ANT_FOREST_ly%%27&__webview_options__=ttb%%3Dauto%%26pd%%3DNO%%26bc%%3D1324950",uid];
    if([self jsBridge]) {
        [[self jsBridge] _doFlushMessageQueue:arg1 url:arg2];
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
    if ([defaults boolForKey:@"oceanLimitReachedToday"]) return;
    
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:15];
    NSString *randNum2=[AntForestManager getNumberRandom:16];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antocean.ocean.h5.queryFriendList\",\"requestData\":[{\"source\":\"ANT_FOREST_ly'\"}],\"appName\":\"antocean\",\"facadeName\":\"InteractController\",\"methodName\":\"queryFriendList\",\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, randNum];
    NSString *arg2 = @"https://2021003115672468.h5app.alipay.com/www/index.html";
    if([self jsBridge]) {
        [self recordStage:@"收取 · 请求神奇海洋好友列表"];
        [[self jsBridge] _doFlushMessageQueue:arg1 url:arg2];
        dispatch_async(globalSerialQueueQuery, ^{
            [self cleanMyOcean];
        });
    }
}

static NSMutableSet<NSString *> *inFlightOceanUids = nil;

-(void)scanOceanForFriends:(NSArray<NSString *> *)friendIds {
    if (!self.enableCleanOcean || !friendIds.count) return;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inFlightOceanUids = [NSMutableSet set];
    });
    
    NSString *today = getCurrentDateString();
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![[defaults stringForKey:@"oceanCleanedDate"] isEqualToString:today]) {
        [defaults setObject:today forKey:@"oceanCleanedDate"];
        [defaults setObject:@[] forKey:@"oceanCleanedFriendsToday"];
        [defaults setBool:NO forKey:@"oceanLimitReachedToday"];
        @synchronized(inFlightOceanUids) {
            [inFlightOceanUids removeAllObjects];
        }
    }
    if ([defaults boolForKey:@"oceanLimitReachedToday"]) {
        static NSString *lastOceanLimitLogDate = nil;
        if (![lastOceanLimitLogDate isEqualToString:today]) {
            lastOceanLimitLogDate = today;
            [self recordStage:@"收取 · 神奇海洋：今日自动清理海域与收集拼图已达每日上限（10/10 位）"];
        }
        return;
    }
    
    NSArray *cleanedArr = [defaults arrayForKey:@"oceanCleanedFriendsToday"] ?: @[];
    NSMutableSet *cleanedSet = [NSMutableSet setWithArray:cleanedArr];
    if (cleanedSet.count >= 10) {
        [defaults setBool:YES forKey:@"oceanLimitReachedToday"];
        [self recordStage:@"收取 · 神奇海洋：今日已帮满 10 位好友清理，已达每日上限"];
        return;
    }
    
    NSMutableArray<NSString *> *toClean = [NSMutableArray array];
    @synchronized(inFlightOceanUids) {
        for (NSString *uid in friendIds) {
            if (!uid.length || [uid isEqualToString:self.myUserId]) continue;
            if ([cleanedSet containsObject:uid]) continue;
            if ([inFlightOceanUids containsObject:uid]) continue;
            [toClean addObject:uid];
            [inFlightOceanUids addObject:uid];
            if (toClean.count >= 2 || (cleanedSet.count + inFlightOceanUids.count >= 10)) break;
        }
    }
    
    if (toClean.count == 0) return;
    
    [self recordStage:[NSString stringWithFormat:@"收取 · 神奇海洋：今日已帮 %lu/10 位好友清理，本轮安排 %lu 位好友（安全随机间隔）", (unsigned long)cleanedSet.count, (unsigned long)toClean.count]];
    
    int64_t idx = 0;
    for (NSString *uid in toClean) {
        int64_t delayMs = (idx + 1) * 2500 + arc4random_uniform(1500);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayMs * NSEC_PER_MSEC)), globalSerialQueueQuery, ^{
            if ([[NSUserDefaults standardUserDefaults] boolForKey:@"oceanLimitReachedToday"]) return;
            [self cleanFriendsOcean:uid];
        });
        idx++;
    }
}

-(void)queryRankPage:(NSInteger)startIndex {
    if (!self.enableAutoCollect || !self.jsBridge) return;
    NSString *version = @"20230501";
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *randNum = [AntForestManager getNumberRandom:16];
    NSString *arg1 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antmember.forest.h5.queryEnergyRanking\",\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"rankType\":\"energyRank\",\"periodType\":\"total\",\"version\":\"%@\",\"startIndex\":%ld,\"pageSize\":200,\"contactsStatus\":\"N\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\"}],\"relationLocal\":{\"pathList\":[\"friendRanking\",\"myself\",\"totalDatas\"]},\"getResponse\":true},\"callbackId\":\"rpc_%@.%@_p%ld\"}]", version, (long)startIndex, timeStamp, randNum, (long)startIndex];
    NSString *arg2 = @"https://render.alipay.com/p/yuyan/180020010001247580/listRank.html?caprMode=sync&init=energyRank&periodType=total";
    [self recordStage:[NSString stringWithFormat:@"收取 · 请求好友排行榜自动翻页（第 %ld-%ld 位）", (long)startIndex + 1, (long)startIndex + 200]];
    [[self jsBridge] _doFlushMessageQueue:arg1 url:arg2];
}

//查询总排行 可以获取所有人的ID
-(void)queryTotalRank{
    NSString *version = @"20230501";
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:16];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antmember.forest.h5.queryEnergyRanking\",\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"rankType\":\"energyRank\",\"periodType\":\"total\",\"version\":\"%@\",\"startNum\":1,\"startIndex\":0,\"pageSize\":200,\"contactsStatus\":\"N\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\"}],\"relationLocal\":{\"pathList\":[\"friendRanking\",\"myself\",\"totalDatas\"]},\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]",version,timeStamp,randNum];
    NSString *arg2 = @"https://render.alipay.com/p/yuyan/180020010001247580/listRank.html?caprMode=sync&init=energyRank&periodType=total";
    NSString *arg1_home=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antmember.forest.h5.queryEnergyRanking\",\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"rankType\":\"energyRank\",\"periodType\":\"total\",\"version\":\"%@\",\"contactsStatus\":\"N\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\"}],\"relationLocal\":{\"pathList\":[\"friendRanking\",\"myself\",\"totalDatas\"]},\"getResponse\":true},\"callbackId\":\"rpc_%@.%@_home\"}]",version,timeStamp,randNum];
    NSString *arg2_home = @"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&__webview_options__=bc%3D3194732";
    if([self jsBridge]) {
        [self recordStage:@"收取 · 请求全量好友排行榜（200位/页）"];
        [[self jsBridge] _doFlushMessageQueue:arg1 url:arg2];
        [[self jsBridge] _doFlushMessageQueue:arg1_home url:arg2_home];
    }
}

//查询 20 个人是否有可领能量球
-(void)queryRobFlag:(NSString*)uids{
    [[AntForestManager sharedLock] lock];
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:16];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.fillUserRobFlag\",\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"userIdList\":[%@],\"source\":\"chInfo_ch_appcenter__chsub_9patch\"}],\"relationLocal\":{\"pathList\":[\"friendRanking\"]},\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]",uids,timeStamp,randNum];
    NSString *arg2 = [NSString stringWithFormat:@"https://render.alipay.com/p/yuyan/180020010001247580/listRank.html?caprMode=sync&init=energyRank&periodType=total"];
    if([self jsBridge]) {
        [[self jsBridge] _doFlushMessageQueue:arg1 url:arg2];
        //FileLog(@"uids:%@", uids);
        //FileLog(@"anthook queryRobFlag");
    }
    [NSThread sleepForTimeInterval:0.5];
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
        lastCollectStartedAt = NSDate.date;
        collectionCycle++;
        NSUInteger cycle = collectionCycle;
        selfPriorityPending = self.enableSelfCollect;
        selfPriorityCycle = cycle;
        [deferredFriendRankIds removeAllObjects];
        deferredRankedFriendIds = nil;
        rankScanPending = YES;
        @synchronized (self) { [pendingCollectBubbles removeAllObjects]; }
        [self recordStage:@"收取 · 本轮扫描开始"];
        [self queryTotalRank];
        if (self.enableCleanOcean) {
            [self cleanMyOceanThoroughly];
            [self queryOceanFriendList];
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
    if (![logMessage containsString:@"收取 ·"]) return;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self addLog:logMessage];
        });
        return;
    }
    //日志持久化
    @try {
        // 保留足够的一轮扫描记录，面板仍只显示最近几条。
        NSMutableArray *arrLog = [[AntForestManager sharedInstance] logRecord];
        while(arrLog.count > 200) {
            [arrLog removeObjectAtIndex:0];
        }
        // 添加日志信息到数组中
        [arrLog addObject:logMessage];
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
    NSMutableArray *pending = [NSMutableArray arrayWithObject:args];
    while (pending.count) {
        id value = pending.lastObject; [pending removeLastObject];
        if ([value isKindOfClass:NSArray.class]) { [pending addObjectsFromArray:value]; continue; }
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *bubble = value;
        for (id child in bubble.allValues) if ([child isKindOfClass:NSDictionary.class] || [child isKindOfClass:NSArray.class]) [pending addObject:child];
        NSNumber *energy = bubble[@"collectedEnergy"];
        if (!energy || energy.integerValue <= 0) continue;
        NSString *userId = [bubble[@"userId"] description] ?: @"";
        NSString *bubbleId = [bubble[@"id"] description] ?: @"";
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
        BOOL isSelf = [userId isEqualToString:self.myUserId];
        NSString *source = @"自己";
        if (!isSelf) {
            NSDictionary *contact = [self.friendsName[userId] isKindOfClass:NSDictionary.class] ? self.friendsName[userId] : nil;
            NSString *name = [contact[@"displayName"] isKindOfClass:NSString.class] ? contact[@"displayName"] : nil;
            if (!name.length) name = [contact[@"name"] isKindOfClass:NSString.class] ? contact[@"name"] : nil;
            source = name.length ? [NSString stringWithFormat:@"好友\u201c%@\u201d", name] : @"好友";
        }
        NSString *message = isSelf
            ? [NSString stringWithFormat:@"成功收取自己能量：%ld g（今日累计 %ld g）", (long)energy.integerValue, (long)self.todayCollectedEnergy]
            : [NSString stringWithFormat:@"成功收取%@的能量：%ld g（今日累计 %ld g）", source, (long)energy.integerValue, (long)self.todayCollectedEnergy];
        [self recordStage:[@"收取 · " stringByAppendingString:message]];
        NSString *log = [NSString stringWithFormat:@"%@\n%@", getCurrentDateTimeString(), message];
        [self addLog:log];
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
                [self recordStage:@"收取 · 神奇海洋：收到服务端安全风险拦截，已自动熔断暂停本日清理（保护账号安全）"];
            }
            if (resData && (resData[@"cleanRewardVOS"] || resData[@"canClearFriendSeaToday"])) {
                NSNumber *canClearToday = resData[@"canClearFriendSeaToday"];
                if (canClearToday && [canClearToday boolValue] == NO) {
                    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"oceanLimitReachedToday"];
                    [self recordStage:@"收取 · 神奇海洋：服务端确认今日清理已达上限"];
                }
                NSArray *rewards = resData[@"cleanRewardVOS"];
                if ([rewards isKindOfClass:NSArray.class] && rewards.count > 0) {
                    NSString *cleanedUid = resData[@"cleanedUserId"] ?: resData[@"userId"] ?: dict[@"cleanedUserId"] ?: self.lastCleanedOceanUserId;
                    BOOL isSelfOcean = !cleanedUid.length || [cleanedUid isEqualToString:self.myUserId];
                    NSString *targetName = @"自己";
                    if (!isSelfOcean) {
                        NSString *displayName = [self waterDisplayNameForUser:cleanedUid];
                        targetName = displayName.length ? [NSString stringWithFormat:@"好友“%@”", displayName] : @"好友";
                        NSArray *cleanedArr = [[NSUserDefaults standardUserDefaults] arrayForKey:@"oceanCleanedFriendsToday"] ?: @[];
                        NSMutableSet *cleanedSet = [NSMutableSet setWithArray:cleanedArr];
                        [cleanedSet addObject:cleanedUid];
                        [[NSUserDefaults standardUserDefaults] setObject:cleanedSet.allObjects forKey:@"oceanCleanedFriendsToday"];
                        if (cleanedSet.count >= 10) {
                            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"oceanLimitReachedToday"];
                            [self recordStage:[NSString stringWithFormat:@"收取 · 神奇海洋：今日已帮满 10 位好友清理，已达每日上限"]];
                        }
                    }
                    NSDictionary *first = rewards.firstObject;
                    NSString *name = first[@"name"] ?: @"垃圾";
                    NSArray *attach = [first[@"attachRewardBOList"] isKindOfClass:NSArray.class] ? first[@"attachRewardBOList"] : nil;
                    if (attach.count > 0) {
                        [self recordStage:[NSString stringWithFormat:@"收取 · 神奇海洋：获得%@的拼图碎片与%@", targetName, name]];
                    } else {
                        [self recordStage:[NSString stringWithFormat:@"收取 · 神奇海洋：清理%@的%@", targetName, name]];
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
                if ((canClearFriendSeaToday && [canClearFriendSeaToday boolValue] == NO) || todayCleaned >= 10) {
                    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"oceanLimitReachedToday"];
                    [self recordStage:[NSString stringWithFormat:@"收取 · 神奇海洋：服务端确认今日清理好友已达上限（%ld/10 位）", (long)MAX(10, todayCleaned)]];
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
        // 浇水与自动复活可独立于自动收取手动执行，必须先处理它们的回包。
        [self handleWaterResponse:args];
        [self handleAutoReviveResponse:args];
        if ([args isKindOfClass:NSDictionary.class]) [self updateWaterFriendListFromResponse:args];
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
            
            // 匹配 takelook 返回的 friendID
            if(resData && resData[@"friendId"]) {
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
            // 匹配查询好的返回的所有能量球
            if(dict[@"bubbles"] && dict[@"userBaseInfo"]) {
                NSString *userId;
                if([dict objectForKey:@"userBaseInfo"]) {
                    NSDictionary *pDic =[dict objectForKey:@"userBaseInfo"];
                    userId = [pDic objectForKey:@"userId"];
                }
                if (!userId.length || !self.myUserId.length) {
                    [self recordStage:@"诊断 · 气泡回包跳过：本人账户尚未识别"];
                    return;
                }
                if (self.enableAutoRevive && userId.length && ![userId isEqualToString:self.myUserId]) {
                    NSDictionary *userInfo = [dict[@"userBaseInfo"] isKindOfClass:NSDictionary.class] ? dict[@"userBaseInfo"] : nil;
                    NSDictionary *userForest = [dict[@"userForest"] isKindOfClass:NSDictionary.class] ? dict[@"userForest"] : nil;
                    if (canReviveFriendBubble(dict) || canReviveFriendBubble(userInfo) || canReviveFriendBubble(userForest) || [dict[@"forestSignVOList"] isKindOfClass:NSArray.class]) {
                        [self queueAutoReviveForUser:userId];
                    }
                }
                
                //判断是否有能量保护罩
                NSArray *pArr = [dict objectForKey:@"usingUserProps"] ?: [dict objectForKey:@"usingUserPropsNew"];
                if(pArr) {
                    for(NSDictionary *dic in pArr){
                        NSString *type = [dic objectForKey:@"type"];
                        NSString *myUserId = [[AntForestManager sharedInstance] myUserId]; //我自己的ID
                        if([type isEqualToString:@"energyShield"] && ![userId isEqualToString:myUserId]){
                            [self recordStage:@"诊断 · 好友气泡回包：检测到保护罩，跳过该好友"];
                            NSString *log = [NSString stringWithFormat:@"%@\n检测到保护罩,跳过拾取",[[AntForestManager sharedInstance] getUserName:userId]];
                            [[AntForestManager sharedInstance] addLog:log];
                            [self advanceTakeLookForFriend:userId];
                            return;
                        }
                    }
                }
                NSMutableDictionary *dictBubbles = [dict objectForKey:@"bubbles"];
                NSUInteger available = 0, waiting = 0;
                for (NSDictionary *bubble in dictBubbles) {
                    if ([[bubble objectForKey:@"collectStatus"] isEqualToString:@"AVAILABLE"]) available++;
                    if ([[bubble objectForKey:@"collectStatus"] isEqualToString:@"WAITING"]) waiting++;
                }
                BOOL mine = [userId isEqualToString:self.myUserId];
                [self recordStage:[NSString stringWithFormat:@"诊断 · %@气泡回包：总 %lu 个，可收 %lu 个，等待 %lu 个", mine ? @"本人" : @"好友", (unsigned long)dictBubbles.count, (unsigned long)available, (unsigned long)waiting]];
                if (mine) [self recordStage:[NSString stringWithFormat:@"收取 · 本人首页回包：总 %lu 个，可收 %lu 个，等待 %lu 个", (unsigned long)dictBubbles.count, (unsigned long)available, (unsigned long)waiting]];
                if (mine && !self.enableSelfCollect) {
                    [self recordStage:@"收取 · 已跳过本人能量"];
                    [self releaseSelfPriorityForCycle:collectionCycle reason:@"本人收取已关闭"];
                    return;
                }
                // 初始化一个空的可变数组
                NSMutableArray *bidArr = [NSMutableArray array];
                for (NSDictionary *bubble in dictBubbles) {
                    userId = [bubble objectForKey:@"userId"];
                    NSString *bid = [bubble objectForKey:@"id"];
                    NSString *overTime = [bubble objectForKey:@"overTime"];
                    NSString *remainEnergy = [bubble objectForKey:@"remainEnergy"];
                    
                    //可收取直接收取
                    if([[bubble objectForKey:@"collectStatus"] isEqualToString:@"AVAILABLE"]){
                        [bidArr addObject:bid];
                        NSString *log = [NSString stringWithFormat:@"%@\n找到可领能量球(%@g) 收取, %@",[[AntForestManager sharedInstance] getUserName:userId],remainEnergy,bid];
                        [[AntForestManager sharedInstance] addLog:log];
                        dispatch_async(globalSerialQueueCollect, ^{
                            [[AntForestManager sharedInstance] collectBubbles:userId bubblesId:bid];
                        });
                        
                    }
                    if([[bubble objectForKey:@"collectStatus"] isEqualToString:@"INSUFFICIENT"]){
                        NSString *log = [NSString stringWithFormat:@"%@\n能量不足,剩%@g, %@",[[AntForestManager sharedInstance] getUserName:userId],remainEnergy,bid];
                        [[AntForestManager sharedInstance] addLog:log];
                    }
                    //等待中放入字典树中
                    if([[bubble objectForKey:@"collectStatus"] isEqualToString:@"WAITING"] && overTime){
                        NSMutableDictionary* fb = [[AntForestManager sharedInstance] friendsBubbles];
                        NSDictionary *myBubble = @{bid:overTime};
                        //无论有没有直接覆盖
                        [fb setObject:myBubble forKey:userId];
                        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:fb requiringSecureCoding:NO error:nil];
                        [[NSUserDefaults standardUserDefaults] setObject:data forKey:@"friendsBubbles"];
                        [[NSUserDefaults standardUserDefaults] synchronize];
                        NSString *log = [NSString stringWithFormat:@"%@\n找到等待能量球(%@g) 入库, %@",[[AntForestManager sharedInstance] getUserName:userId],remainEnergy,bid];
                        [[AntForestManager sharedInstance] addLog:log];
                    }
                    //可帮助直接帮助
                    if([[bubble objectForKey:@"canHelpCollect"] isEqualToNumber:@1]){
                        NSString *log = [NSString stringWithFormat:@"%@\n找到帮助能量球(%@g) 帮助, %@",[[AntForestManager sharedInstance] getUserName:userId],remainEnergy,bid];
                        [[AntForestManager sharedInstance] addLog:log];
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
