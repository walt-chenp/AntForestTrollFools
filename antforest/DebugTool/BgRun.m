//
//  BgRun.m
//  antforest
//
//  Created by walt-chenp.
//

#import <UIKit/UIKit.h>
#import "BgRun.h"
// xxd -i blank.caf > blankcaf.h 通过这个命令生成的
// #import "beginwav.h"
#import "blankcaf.h"

@implementation BgRun

+ (instancetype)sharedInstance {
    static BgRun *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [BgRun new];
    });
    return sharedInstance;
}

#pragma mark - 音频播放

//播放无声音频
- (void)playBlankAudio{
    [self playAudioForResource:@"blank.caf"];
}

//播放有声音频
- (void)playVoiceAudio{
    [self playAudioForResource:@"begin.wav"];
}

//将音频文件写入沙盒目录
- (void)saveCAFToSandbox {
    // 获取沙盒路径（例如：Documents 目录）
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    //NSString *beginFilePath = [documentsDirectory stringByAppendingPathComponent:@"begin.wav"];
    NSString *blankFilePath = [documentsDirectory stringByAppendingPathComponent:@"blank.caf"];
    
    // 如果文件已经存在，直接返回
    if ([[NSFileManager defaultManager] fileExistsAtPath:blankFilePath]) {
        return;
    }
    
    // 将 CAF 文件的字节数组写入沙盒
    //NSData *audioData = [NSData dataWithBytes:begin_wav length:31906];
    NSData *audioData = [NSData dataWithBytes:blank_caf length:13876];
    [audioData writeToFile:blankFilePath atomically:YES];
}

//播放音频方法 声音文件名 声音文件类型
- (void)playAudioForResource:(NSString *)resource{
    NSError *setCategoryErr = nil;
    NSError *activationErr  = nil;
    [[AVAudioSession sharedInstance] setCategory: AVAudioSessionCategoryPlayback withOptions: AVAudioSessionCategoryOptionMixWithOthers error: &setCategoryErr];
    [[AVAudioSession sharedInstance] setActive: YES error: &activationErr];
    
    // 获取沙盒路径（例如：Documents 目录）
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *cafFilePath = [documentsDirectory stringByAppendingPathComponent:resource];
    
    NSURL *blankSoundURL = [[NSURL alloc] initWithString:cafFilePath];
    if(blankSoundURL){
        self.Player = [[AVAudioPlayer alloc] initWithContentsOfURL:blankSoundURL error:nil];
        // 设置为无限循环播放
        self.Player.numberOfLoops = -1;
        [self.Player play];
    }
}

#pragma mark - 后台任务

- (void)endBackgroundMode{
    [self.Player stop];
    [self.bgTaskTimer invalidate];
}
//程序进入后台处理 防止挂起
- (void)beginBackgroundMode{
    self.bgTaskIdentifier = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        [[UIApplication sharedApplication] endBackgroundTask:self.bgTaskIdentifier];
        self.bgTaskIdentifier = UIBackgroundTaskInvalid;
    }];
    self.bgTaskTimer = [NSTimer scheduledTimerWithTimeInterval:10.0 target:self selector:@selector(requestMoreTime) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.bgTaskTimer forMode:NSRunLoopCommonModes];
    [self.bgTaskTimer fire]; //立即触发定时器 即执行 requestMoreTime 方法
}

- (void)requestMoreTime{
    if ([UIApplication sharedApplication].backgroundTimeRemaining < 30) {
        [self playBlankAudio];
        //[self playVoiceAudio];
        [[UIApplication sharedApplication] endBackgroundTask:self.bgTaskIdentifier];
        self.bgTaskIdentifier = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
            [[UIApplication sharedApplication] endBackgroundTask:self.bgTaskIdentifier];
            self.bgTaskIdentifier = UIBackgroundTaskInvalid;
        }];
    }
}

//通过角标标记后台已运行多长时间(秒)
- (void)beginBadgeNumberCount{
    [UIApplication sharedApplication].applicationIconBadgeNumber = 0;
    self.bgTaskTimerbadge = [NSTimer scheduledTimerWithTimeInterval:1.f repeats:YES block:^(NSTimer * _Nonnull timer) {
        [UIApplication sharedApplication].applicationIconBadgeNumber++;
    }];
    //    self.bgTaskTimerbadge = [NSTimer scheduledTimerWithTimeInterval:1.f repeats:YES block:^(NSTimer * _Nonnull timer) {
    //        [UIApplication sharedApplication].applicationIconBadgeNumber = [[UIApplication sharedApplication] backgroundTimeRemaining];
    //    }];
}

- (void)endBadgeNumberCount{
    [UIApplication sharedApplication].applicationIconBadgeNumber = 0;
    [self.bgTaskTimerbadge invalidate];
}

@end
