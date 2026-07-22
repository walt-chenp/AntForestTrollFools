//
//  AntForestManager.h
//  antforest
//
//  Created by qsir on 2024/11/9.
//

#import <Foundation/Foundation.h>

#import "PSDJsBridge.h"

NS_ASSUME_NONNULL_BEGIN

@interface AntForestManager : NSObject

+(id)sharedInstance;
+ (NSLock*)sharedLock;

@property(nonatomic,strong) PSDJsBridge* jsBridge;
@property(nonatomic,strong) NSMutableDictionary *friendsBubbles; //存储的是未到时间的能量球
@property(nonatomic,strong) NSMutableDictionary *friendsName; //
@property(nonatomic,strong) NSMutableDictionary *friendsRank; //
@property(nonatomic,strong) NSMutableArray *logRecord;
@property(atomic) NSInteger totalCollectedEnergy; //总收集能量
@property(atomic) NSInteger todayCollectedEnergy;

@property (nonatomic, strong) NSTimer *autoCollectTimer; //后台任务定时器

@property (assign, nonatomic) BOOL enableAutoCollect; //允许自动收集则自动开启后台模式

@property (assign, nonatomic) int failedTimes; //未成功收取能量的次数
@property(atomic) NSTimeInterval collectInterval; //takeLook时间间隔

@property (strong, nonatomic) NSString* myUserId; //我自己的ID

-(void)startAutoCollectTimerWithInterval:(NSTimeInterval)interval;

-(void)cleanFriendsOcean:(NSString*)uid;
-(void)cleanMyOcean;

-(void)queryTotalRank;
-(void)queryRobFlag:(NSString*)uids;
-(void)queryAccount:(NSString*)uids;

-(void)takeLook;
-(void)queryFriendsBubbles:(NSString*)friendId;
-(void)collectBubbles:(NSString*)uid bubblesId:(NSString*)bids;
-(void)reviveEnergy:(NSString*)uid signId:(NSString*)signId; //貌似查询
-(void)autoCollectBubbles;
-(void)matchFriendIdAndBubbles:(id)args;
-(NSString*)getUserName:(NSString*)uid;
-(void)addLog:(NSString *)logMessage;

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
