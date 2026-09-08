//
//  AntForestManager.h
//  antforest
//
//  Created by walt-chenp.
//

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import "PSDJsBridge.h"

NS_ASSUME_NONNULL_BEGIN

@interface AntForestManager : NSObject

+(AntForestManager *)sharedInstance;
+ (NSLock*)sharedLock;
+ (NSString *)extractNameFromDictionary:(NSDictionary *)dict;
+ (NSString *)extractUserIdFromDictionary:(NSDictionary *)dict;

@property(nonatomic,strong) PSDJsBridge* jsBridge;
// 领奖励/寻宝页专用桥接；若未独立打开则兜底复用森林首页桥接。
@property(nonatomic,strong) PSDJsBridge* rewardTaskBridge;
@property(nonatomic,strong,nullable) WKWebView *silentBrowseWebView;
@property(nonatomic,strong) NSMutableDictionary *friendsBubbles; //存储的是未到时间的能量球
@property(nonatomic,strong) NSMutableDictionary *friendsName; //
@property(nonatomic,strong) NSMutableDictionary *friendsRank; //
@property(nonatomic,strong) NSMutableArray *logRecord;
@property(atomic) NSInteger totalCollectedEnergy; //总收集能量
@property(atomic) NSInteger todayCollectedEnergy;

@property (nonatomic, strong) NSTimer *autoCollectTimer; //后台任务定时器
@property(nonatomic, copy) NSString *lastCleanedOceanUserId;
@property (nonatomic, strong) NSTimer *scheduledCollectTimer;
@property (nonatomic, strong) NSTimer *scheduledWaterTimer;

@property (assign, nonatomic) BOOL enableAutoCollect; //允许自动收集则自动开启后台模式
@property (assign, nonatomic) BOOL enableSelfCollect;
@property (assign, nonatomic) BOOL enableAutoRain;
@property (assign, nonatomic) BOOL enableAutoEarn;
@property (assign, nonatomic) BOOL enableAutoRevive;
@property (assign, nonatomic) BOOL enableBackgroundLoop;
@property (assign, nonatomic) BOOL enableScheduledCollect;
@property (nonatomic, strong) NSArray<NSString *> *scheduledTimes;
@property (assign, nonatomic) BOOL enableAutoWater;
@property (assign, nonatomic) BOOL enableWaterOnLaunch;
@property (assign, nonatomic) BOOL waterReminderEnabled;
@property (nonatomic) NSInteger waterEnergyId;
@property (nonatomic, strong) NSArray<NSString *> *waterFriendIds;
@property (nonatomic, strong) NSArray<NSString *> *waterScheduledTimes;

@property (assign, nonatomic) BOOL enableCleanOcean; // 神奇海洋自动清理海域与找拼图
@property (assign, nonatomic) BOOL enableAutoOceanTasks; // 神奇海洋自动做任务与领拼图
@property (nonatomic, weak) id oceanBridge; // 神奇海洋 H5 Bridge
@property (nonatomic, copy) NSString *oceanH5Url; // 神奇海洋当前 URL
@property (nonatomic, weak) id aiFishBridge; // AI摸鱼 H5 Bridge
@property (nonatomic, copy) NSString *aiFishH5Url; // AI摸鱼当前 URL
@property (nonatomic, weak) id farmBridge; // 芭芭农场 H5 Bridge
@property (nonatomic, copy) NSString *farmH5Url; // 芭芭农场当前 URL
@property (nonatomic, weak) id monopolyBridge; // 新版保护地大富翁 H5 Bridge
@property (nonatomic, copy) NSString *monopolyH5Url; // 新版保护地当前 URL
@property (nonatomic) BOOL monopolyDrawerOpened; // 本次进入保护地是否已呼出过步数抽屉
@property (nonatomic, weak) id lotteryBridge; // 森林寻宝 H5 Bridge
@property (nonatomic, copy) NSString *lotteryH5Url; // 森林寻宝当前 URL
@property (assign, nonatomic) BOOL enableAutoPatrol; // 旧版保护地自动巡护与物种合成派遣
@property (assign, nonatomic) BOOL enableAutoPatrolNew; // 新版保护地大富翁自动掷骰子与任务
@property (assign, nonatomic) BOOL enableAutoRewardTasks; // 任务中心自动签到、做任务与领奖励
@property (assign, nonatomic) BOOL enableAutoAIFish; // AI摸鱼自动任务与摸鱼次数
@property (assign, nonatomic) BOOL enableAutoFarmTasks; // 芭芭农场做任务集肥料与小鸡肥料自动领取
@property (assign, nonatomic) BOOL enableAutoManor; // 蚂蚁庄园全自动日常（签到、小课堂答题、领饲料、喂小鸡与收肥料）
@property (nonatomic, weak) id manorBridge; // 蚂蚁庄园 H5 Bridge
@property (nonatomic, copy) NSString *manorH5Url; // 蚂蚁庄园当前 URL
@property (nonatomic, copy) NSString *lastManorFarmId; // 庄园 ID
@property (nonatomic, copy) NSString *lastManorAnimalId; // 小鸡 ID
@property (nonatomic) BOOL isManorChickenEating; // 小鸡当前是否正在进食中
@property (nonatomic, copy) NSString *lastManorManureCollectDate; // 最近一次收取小鸡肥料的日期
@property (nonatomic) BOOL manorTaskPanelOpened; // 是否已打开领饲料面板
@property (atomic, assign) BOOL isScanRunning; // 扫描进行中独占锁
@property (assign, nonatomic) int failedTimes; //未成功收取能量的次数
@property(atomic) NSTimeInterval collectInterval; //takeLook时间间隔

@property (strong, nonatomic) NSString* myUserId; //我自己的ID
@property (nonatomic, copy) NSString *lastRpcOperationType; // 最近一次发起的 RPC operationType

-(BOOL)isAnimalEnergyCollectedTodayForCode:(NSString *)code name:(NSString *)name;
-(void)markAnimalEnergyCollectedTodayForCode:(NSString *)code name:(NSString *)name reason:(NSString *)reason;
-(void)startAutoCollectTimerWithInterval:(NSTimeInterval)interval;
-(void)startScheduledCollectTimer;
-(void)startScheduledWaterTimer;
-(void)receiveAnimalPartnerEnergy;
-(void)queryUsingCreatureInfo;
-(void)collectMonopolyCreatureEnergyWithCode:(NSString *)creatureCode shortDay:(NSString *)shortDay energy:(NSInteger)energy name:(NSString *)name;
-(void)receiveAnimalEnergyWithPropId:(NSString *)propId propType:(NSString *)propType animalId:(NSString *)animalId;
-(void)receiveAnimalEnergyWithPropId:(NSString *)propId propType:(NSString *)propType animalId:(NSString *)animalId energy:(NSInteger)energy name:(NSString *)name isCollected:(BOOL)isCollected;
-(void)stopAutoCollectTimer;

-(void)cleanFriendsOcean:(NSString*)uid;
-(void)cleanMyOcean;
-(void)cleanMyOceanThoroughly;
-(void)scanOceanForFriends:(NSArray<NSString *> *)friendIds;
-(void)queryOceanFriendList;
-(void)queryAIFishTaskList;
-(void)queryAIFishTaskListWithForce:(BOOL)force;
-(void)handleFarmResponse:(NSDictionary *)dict;
-(void)queryFarmTaskList;
-(void)queryFarmTaskListWithForce:(BOOL)force;
-(void)collectFarmChickenManure;
-(void)signFarmDailyWithKey:(NSString *)signKey;
-(void)executeFarmScriptOnWebView:(NSString *)js;
-(void)openFarmTaskPanelOnWebView;
-(void)claimAllVisibleFarmRewardsOnWebView;
-(void)executeMonopolyScriptOnWebView:(NSString *)js;
-(void)openMonopolyTaskPanelOnWebView;
-(void)claimAllVisibleMonopolyRewardsOnWebView;
-(void)executeAIFishScriptOnWebView:(NSString *)js;
-(void)claimAllVisibleAIFishRewardsOnWebView;
-(void)executeRewardTaskScriptOnWebView:(NSString *)js;
-(void)claimAllVisibleRewardTaskRewardsOnWebView;
+(BOOL)isManorURL:(NSURL *)url;
+(BOOL)isManorResponse:(id)value;
-(void)handleManorResponse:(NSDictionary *)dict;
-(void)queryManorTaskList;
-(void)handleManorTaskList:(NSArray *)taskList;
-(void)finishManorTask:(NSString *)taskType sceneCode:(NSString *)sceneCode taskTitle:(NSString *)title;
-(void)receiveManorTaskAward:(NSString *)taskType sceneCode:(NSString *)sceneCode taskTitle:(NSString *)title awardName:(NSString *)awardName;
-(void)executeManorScriptOnWebView:(NSString *)js;
-(void)openManorTaskPanelOnWebView;
-(void)closeManorTaskPanelOnWebView;
-(void)checkAndRunManorAutomations;
-(void)signManorDaily;
-(void)answerManorClassroomQuestion;
-(void)runManorTasks;
-(void)feedManorChicken;
-(void)collectManorChickenManure;

-(void)queryTotalRank;
-(void)queryRobFlag:(NSString*)uids;
-(void)queryAccount:(NSString*)uids;

-(void)takeLook;
-(void)queryFriendsBubbles:(NSString*)friendId;
-(void)queryMyBubbles;
-(void)collectBubbles:(NSString*)uid bubblesId:(NSString*)bids;
-(void)reviveEnergy:(NSString*)uid signId:(NSString*)signId; //貌似查询
-(void)autoCollectBubbles;
-(void)matchFriendIdAndBubbles:(id)args;
-(void)recordCollectedEnergyFromResponse:(id)args;
-(NSString*)getUserName:(NSString*)uid;
-(void)addLog:(NSString *)logMessage;
-(void)recordStage:(NSString *)stage;
-(void)recordProbeLog:(NSString *)log;
-(void)clearProbeLogs;
@property (nonatomic, readonly) NSArray<NSString *> *probeRecords;

// 任务中心：自动签到与领奖励
-(void)queryVitalityTaskList;
-(void)queryVitalityTaskListWithForce:(BOOL)force;
-(void)queryLotteryTaskList;
-(void)queryLotteryTaskListWithForce:(BOOL)force;
-(void)queryMonopolyTaskList;
-(void)queryMonopolyTaskListWithForce:(BOOL)force;
-(void)executeMonopolyScriptOnWebView:(NSString *)js;
-(void)registerBridge:(id)bridge withUrl:(NSString *)url;
-(void)checkAndTriggerPageActionsForUrl:(NSString *)urlStr;
-(void)openMonopolyTaskPanelOnWebView;
-(void)handleVitalityTaskListResponse:(id)args;
-(void)signVitalityTask:(NSString *)signId;
-(void)finishVitalityTask:(NSString *)taskType sceneCode:(NSString *)sceneCode taskTitle:(NSString *)title;
-(void)notifyActiveH5PageToRefresh;
-(void)receiveVitalityTaskAward:(NSString *)taskType sceneCode:(NSString *)sceneCode taskTitle:(NSString *)title awardName:(NSString *)awardName;

// 神奇海洋：任务与拼图领奖
-(void)queryOceanTaskList;
-(void)queryOceanTaskListWithForce:(BOOL)force;
-(void)handleOceanTaskListResponse:(id)args;
-(void)receiveOceanTaskAward:(NSString *)taskType sceneCode:(NSString *)sceneCode taskTitle:(NSString *)title awardName:(NSString *)awardName;
-(void)applyOceanTask:(NSString *)taskType sceneCode:(NSString *)sceneCode taskTitle:(NSString *)title;

// 好友浇水：仅由“好友浇水设置”手动或定时触发，与自动收取独立。
-(void)refreshWaterFriends;
-(void)startWateringSelectedFriendsWithReason:(NSString *)reason;
-(void)startLaunchWateringThenCollect;
-(void)handleWaterResponse:(id)args;
-(NSString *)waterDisplayNameForUser:(NSString *)uid;
-(NSInteger)waterGrams;

@end

NSString *getCurrentDateTimeString(void);

static NSString *convertTimestampToDateString(long long timestamp) {
    // 将时间戳从毫秒转换为秒
    NSTimeInterval seconds = timestamp / 1000.0;
    
    // 创建 NSDate 对象
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:seconds];
    
    // 设置日期格式
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"]; // 可根据需要调整格式
    
    // 转换为字符串
    NSString *dateString = [formatter stringFromDate:date];
    return dateString;
}

static void FileLog(NSString *format, ...) {
    //不用了就屏蔽掉
    //return;
//    // 获取应用的沙盒 Documents 目录路径
//    NSString *documentsDirectory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
//    NSString *logFilePath = [documentsDirectory stringByAppendingPathComponent:@"alipay.txt"];
    
    // 获取应用的沙盒 Tmp 目录路径
    NSString *tmpDirectory = NSTemporaryDirectory();
    NSString *logFilePath = [tmpDirectory stringByAppendingPathComponent:@"alipay_log.txt"];
    
    // 获取当前时间
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];
    
    // 使用可变参数构建日志内容
    va_list args;
    va_start(args, format);
    NSString *logMessage = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    // 格式化日志内容，添加时间戳
    NSString *logEntry = [NSString stringWithFormat:@"[%@] %@\n", timestamp, logMessage];
    
    // 将日志内容写入文件（追加方式）
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logFilePath];
    if (!fileHandle) {
        // 如果文件不存在，创建文件
        [[NSFileManager defaultManager] createFileAtPath:logFilePath contents:nil attributes:nil];
        fileHandle = [NSFileHandle fileHandleForWritingAtPath:logFilePath];
    }
    
    // 将文件指针移到文件末尾，以便追加内容
    [fileHandle seekToEndOfFile];
    [fileHandle writeData:[logEntry dataUsingEncoding:NSUTF8StringEncoding]];
    [fileHandle closeFile];
}

NS_ASSUME_NONNULL_END
