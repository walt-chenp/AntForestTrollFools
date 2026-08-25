//
//  BgRun.h
//  antforest
//
//  Created by walt-chenp.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h> //注意还要引入framework

NS_ASSUME_NONNULL_BEGIN

@interface BgRun : NSObject

@property (nonatomic, strong) AVAudioPlayer *Player; //音频播放器

@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTaskIdentifier; //后台任务标识符

@property (nonatomic, strong) NSTimer *bgTaskTimer; //后台任务定时器
@property (nonatomic, strong) NSTimer *bgTaskTimerbadge; //角标定时器 用来测试

+ (instancetype)sharedInstance;

- (void)playBlankAudio; //播放无声音频
- (void)playVoiceAudio; //播放有声音频 测试用
- (void)playAudioForResource:(NSString *)resource;

- (void)saveCAFToSandbox;

// 需要保持后台运行调用这个
- (void)beginBackgroundMode;
- (void)endBackgroundMode;

//用来调试后台运行任务的
- (void)beginBadgeNumberCount;
- (void)endBadgeNumberCount;

@end

NS_ASSUME_NONNULL_END
