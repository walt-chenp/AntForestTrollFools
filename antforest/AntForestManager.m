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
        
    });
    return afm;
}

+ (NSLock*)sharedLock {
    static NSLock *sharedLock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedLock = [[NSLock alloc] init];
    });
    return sharedLock;
}

-(void)startAutoCollectTimerWithInterval:(NSTimeInterval)interval{
    // 如果已有定时器，先停止它
    [self.autoCollectTimer invalidate];
    self.autoCollectTimer = nil;
    self.collectInterval = interval;
    self.failedTimes = 0; //每次重新启动定时器时 失败次数均要置 0
    
    // 创建新的定时器
    self.autoCollectTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                             target:self
                                                           selector:@selector(autoCollectBubbles)
                                                           userInfo:nil
                                                            repeats:YES];
    [self.autoCollectTimer fire];
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
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.takeLook\",\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"skipUsers\":{},\"version\":\"%@\",\"contactsStatus\":\"N\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]",version,timeStamp,randNum];
    NSString *arg2 = @"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&__webview_options__=bc%3D3194732";
    
    if([self jsBridge]) {
        [[self jsBridge] _doFlushMessageQueue:arg1 url:arg2];
        //FileLog(@"anthook takeLook");
    }
}

-(void)queryMyBubbles {
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
        [[self jsBridge] _doFlushMessageQueue:arg1 url:arg2];
        //FileLog(@"anthook queryFriendsBubbles: %@",friendId);
    }
    
    [NSThread sleepForTimeInterval:0.5];
    [[AntForestManager sharedLock] unlock];
}

//收集能量球
-(void)collectBubbles:(NSString*)uid bubblesId:(NSString*)bids {
    [[AntForestManager sharedLock] lock];
    NSString *version = @"20230501";
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:15];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antmember.forest.h5.collectEnergy\",\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"userId\":\"%@\",\"bubbleIds\":[%@],\"bizType\":\"\",\"version\":\"%@\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]",uid,bids,version,timeStamp,randNum];
    NSString *arg2 = @"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&__webview_options__=bc%3D3194732";
    if([self jsBridge]) {
        [[self jsBridge] _doFlushMessageQueue:arg1 url:arg2];
        //FileLog(@"anthook collectBubbles: %@ | [%@] ",uid,bids);
    }
    [NSThread sleepForTimeInterval:0.3];
    [[AntForestManager sharedLock] unlock];
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

//清理自己的海域
-(void)cleanMyOcean{
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
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:15];
    NSString *randNum2=[AntForestManager getNumberRandom:16];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antocean.ocean.h5.cleanFriendOcean\",\"requestData\":[{\"cleanedUserId\":\"%@\",\"source\":\"ANT_FOREST_ly'\",\"uniqueId\":\"%@%@\"}],\"appName\":\"antocean\",\"facadeName\":\"InteractController\",\"methodName\":\"cleanFriendsOcean\",\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]",uid,timeStamp,randNum,timeStamp,randNum2];
    NSString *arg2 = [NSString stringWithFormat:@"https://2021003115672468.h5app.alipay.com/www/index.html?fromAct=SAIL_AWAY&userId=%@&interactFlags=&source=ANT_FOREST_ly%%27&__webview_options__=ttb%%3Dauto%%26pd%%3DNO%%26bc%%3D1324950",uid];
    if([self jsBridge]) {
        [[self jsBridge] _doFlushMessageQueue:arg1 url:arg2];
        //FileLog(@"anthook cleanFriendsOcean");
    }
}

//查询总排行 可以获取所有人的ID
-(void)queryTotalRank{
    NSString *version = @"20221001";
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:16];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antmember.forest.h5.queryEnergyRanking\",\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"rankType\":\"energyRank\",\"periodType\":\"total\",\"version\":\"%@\",\"contactsStatus\":\"N\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\"}],\"relationLocal\":{\"pathList\":[\"friendRanking\",\"myself\",\"totalDatas\"]},\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]",version,timeStamp,randNum];
    NSString *arg2 = [NSString stringWithFormat:@"https://render.alipay.com/p/yuyan/180020010001247580/listRank.html?caprMode=sync&init=energyRank&periodType=total"];
    if([self jsBridge]) {
        [[self jsBridge] _doFlushMessageQueue:arg1 url:arg2];
        //FileLog(@"anthook queryTotalRank");
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

// 每隔300秒一次
-(void)autoCollectBubbles {
    @try {
        
        // 查询总排行 获取 AllFriendId MySelfUserId
        [[AntForestManager sharedInstance] queryTotalRank];
        
        // 延时 2 秒，遍历 AllFrinedID 每 20 个一组
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // 查询账户名称
            NSArray *allFriendId = [[[AntForestManager sharedInstance] friendsRank] allKeys];
            NSString *alluid = [[self intArrToStr:allFriendId] componentsJoinedByString:@","];
            [[AntForestManager sharedInstance] queryAccount:alluid];
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                NSInteger count = 0;
                NSMutableArray *arrUid = [NSMutableArray array];  // 确保初始化 arrUid
                
                // 遍历所有好友 ID，每 20 个为一组
                for (NSNumber *userId in allFriendId) {
                    [arrUid addObject:userId];
                    count++;
                    //FileLog(@"count:%ld userId:%@", (long)count, userId);
                    
                    // 每 20 个为一组，开始延时执行
                    if (count % 20 == 0) {
                        // 创建 arrUid 的副本，并延迟执行任务
                        NSMutableArray *groupArrUid = [arrUid mutableCopy];
                        if (arrUid.count > 0) {
                            NSString *uids = [[self intArrToStr:groupArrUid] componentsJoinedByString:@","];
                            dispatch_async(globalSerialQueueTest, ^{
                                [[AntForestManager sharedInstance] queryRobFlag:uids];
                            });
                        }
                        
                        // 清空 arrUid 数组
                        [arrUid removeAllObjects];
                    }
                }
                //最后一组
                if([arrUid count] > 0) {
                    NSString *uids = [[self intArrToStr:arrUid] componentsJoinedByString:@","];
                    dispatch_async(globalSerialQueueTest, ^{
                        [[AntForestManager sharedInstance] queryRobFlag:uids];
                    });
                    [arrUid removeAllObjects];
                }
                
                // 主要是更新标题 失败次数与当前时间间隔
                self.failedTimes++;
            });
        });
        
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
    //日志持久化
    @try {
        // 如果日志数量超过 50 条，移除最早的日志
        NSMutableArray *arrLog = [[AntForestManager sharedInstance] logRecord];
        while(arrLog.count > 50) {
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

-(void)matchFriendIdAndBubbles:(id)args {
    @try {
        if (args != nil && [args isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dict = args;
            // 匹配 过期能量球 返回的  signId
            if([dict objectForKey:@"ariverRpcTraceId"] && [dict objectForKey:@"resData"] && [[dict objectForKey:@"resData"] objectForKey:@"forestSignVOList"]) {
                NSArray *signList =[[dict objectForKey:@"resData"] objectForKey:@"forestSignVOList"];
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
            if([dict objectForKey:@"ariverRpcTraceId"] && [dict objectForKey:@"resData"] && [[dict objectForKey:@"resData"] objectForKey:@"friendId"]) {
                NSString *friendId = [[dict objectForKey:@"resData"] objectForKey:@"friendId"];
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
            if([dict objectForKey:@"ariverRpcTraceId"] && [dict objectForKey:@"bubbles"] && [dict objectForKey:@"userBaseInfo"]) {
                NSString *userId;
                if([dict objectForKey:@"userBaseInfo"]) {
                    NSDictionary *pDic =[dict objectForKey:@"userBaseInfo"];
                    userId = [pDic objectForKey:@"userId"];
                }
                
                //判断是否有能量保护罩
                NSArray *pArr = [dict objectForKey:@"usingUserProps"] ?: [dict objectForKey:@"usingUserPropsNew"];
                if(pArr) {
                    for(NSDictionary *dic in pArr){
                        NSString *type = [dic objectForKey:@"type"];
                        NSString *myUserId = [[AntForestManager sharedInstance] myUserId]; //我自己的ID
                        if([type isEqualToString:@"energyShield"] && ![userId isEqualToString:myUserId]){
                            NSString *log = [NSString stringWithFormat:@"%@\n检测到保护罩,跳过拾取",[[AntForestManager sharedInstance] getUserName:userId]];
                            [[AntForestManager sharedInstance] addLog:log];
                            return;
                        }
                    }
                }
                NSMutableDictionary *dictBubbles = [dict objectForKey:@"bubbles"];
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
                //                //一键收取 能量球多时 提示不合法
                //                if([bidArr count] > 0 && userId) {
                //                    NSString* bidStr = [bidArr componentsJoinedByString:@","];
                //                    NSString *log = [NSString stringWithFormat:@"%@\n一键收取能量球, %@",[[AntForestManager sharedInstance] getUserName:userId],bidStr];
                //                    [[AntForestManager sharedInstance] addLog:log];
                //                    [[AntForestManager sharedInstance] collectBubbles:userId bubblesId:bidStr];
                //                }
            }
            // 匹配拾取日志
            if([dict objectForKey:@"ariverRpcTraceId"] && [dict objectForKey:@"resData"] && [[dict objectForKey:@"resData"] objectForKey:@"bubbles"]) {
                NSMutableDictionary *dictBubbles = [[dict objectForKey:@"resData"] objectForKey:@"bubbles"];
                for (NSDictionary *bubble in dictBubbles) {
                    NSNumber *energyValue = [bubble objectForKey:@"collectedEnergy"];
                    NSInteger num = [energyValue integerValue];
                    NSInteger total = [[AntForestManager sharedInstance] totalCollectedEnergy] + num;
                    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
                    if (![[defaults stringForKey:@"todayCollectedEnergyDate"] isEqualToString:getCurrentDateString()]) {
                        [[AntForestManager sharedInstance] setTodayCollectedEnergy:0];
                        [defaults setObject:getCurrentDateString() forKey:@"todayCollectedEnergyDate"];
                    }
                    NSInteger today = [[AntForestManager sharedInstance] todayCollectedEnergy] + num;
                    NSString *userId = [bubble objectForKey:@"userId"];
                    NSString *bid = [bubble objectForKey:@"id"];
                    NSString *remainEnergy = [bubble objectForKey:@"remainEnergy"];
                    NSString *fullEnery = [bubble objectForKey:@"fullEnergy"];
                    [[AntForestManager sharedInstance] setTotalCollectedEnergy:total];
                    [[AntForestManager sharedInstance] setTodayCollectedEnergy:today];
                    [defaults setInteger:total forKey:@"totalCollectedEnergy"];
                    [defaults setInteger:today forKey:@"todayCollectedEnergy"];
                    [defaults synchronize];
                    if(num > 0) {
                        NSString *log = [NSString stringWithFormat:@"%@\n成功收取能量:%ldg/%@g,剩%@g,总拾取%ldg %@",[[AntForestManager sharedInstance] getUserName:userId],num,fullEnery,remainEnergy,total,bid];
                        [[AntForestManager sharedInstance] addLog:log];
                        dispatch_async(globalSerialQueueQuery, ^{
                            [[AntForestManager sharedInstance] takeLook];
                        });
                    }
                    //[[AntForestManager sharedInstance] startAutoCollectTimerWithInterval:60];
                }
            }
            // 匹配用户名
            if([dict objectForKey:@"contactsDicArray"]) {
                NSMutableDictionary* fn = [[AntForestManager sharedInstance] friendsName];
                NSArray *cArr = [dict objectForKey:@"contactsDicArray"];
                for(NSDictionary *cdict in cArr) {
                    NSString *userId = [cdict objectForKey:@"userID"];
                    [fn setObject:cdict forKey:userId];
                }
                NSData *data = [NSKeyedArchiver archivedDataWithRootObject:fn requiringSecureCoding:NO error:nil];
                [[NSUserDefaults standardUserDefaults] setObject:data forKey:@"friendsName"];
                [[NSUserDefaults standardUserDefaults] synchronize];
                
            }
            //匹配是否要查询这个人的首页
            if([dict objectForKey:@"ariverRpcTraceId"] && [dict objectForKey:@"resData"] && [[dict objectForKey:@"resData"] objectForKey:@"friendRanking"]) {
                NSArray *rankArr = [[dict objectForKey:@"resData"] objectForKey:@"friendRanking"];
                for(NSDictionary *dictRank in rankArr) {
                    NSString *userId = [dictRank objectForKey:@"userId"];
                    NSNumber *canCollectEnergy = [dictRank objectForKey:@"canCollectEnergy"];
                    //FileLog(@"canCollectEnergy: %@ | %@",canCollectEnergy,userId);
                    if([canCollectEnergy isEqualToNumber:@1]){
                        dispatch_async(globalSerialQueueQuery, ^{
                            [[AntForestManager sharedInstance] queryFriendsBubbles:userId];
                        });
                    }
                }
            }
            //匹配我自己的
            if([dict objectForKey:@"ariverRpcTraceId"] && [dict objectForKey:@"resData"] && [[dict objectForKey:@"resData"] objectForKey:@"myself"] && [[dict objectForKey:@"resData"] objectForKey:@"totalDatas"]) {
                NSDictionary *myDict = [[dict objectForKey:@"resData"] objectForKey:@"myself"];
                NSString *userIdMy = [myDict objectForKey:@"userId"];
                //FileLog(@"myUserId: %@",userIdMy);
                [[AntForestManager sharedInstance] setMyUserId:userIdMy];
                NSNumber *canCollectEnergy = [myDict objectForKey:@"canCollectEnergy"];
                if([canCollectEnergy isEqualToNumber:@1]){
                    dispatch_async(globalSerialQueueQuery, ^{
                        [[AntForestManager sharedInstance] queryMyBubbles];
                    });
                }
            }
            //匹配排行
            if([dict objectForKey:@"ariverRpcTraceId"] && [dict objectForKey:@"resData"] && [[dict objectForKey:@"resData"] objectForKey:@"totalDatas"]) {
                NSArray *rankTotalArr = [[dict objectForKey:@"resData"] objectForKey:@"totalDatas"];
                NSMutableDictionary *fr = [[AntForestManager sharedInstance] friendsRank];
                for(NSDictionary *dictTotalRank in rankTotalArr) {
                    NSString *rank = [dictTotalRank objectForKey:@"rank"];
                    NSString *uid = [dictTotalRank objectForKey:@"userId"];
                    //FileLog(@"rankTotalArr: %@ => %@",uid,rank);
                    [fr setObject:rank forKey:uid];
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
