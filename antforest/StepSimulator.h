#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, AFStepSimulatorMode) {
    AFStepSimulatorModeDailyStable = 0,
    AFStepSimulatorModeRandomOnRead = 1,
};

@interface AFStepSimulator : NSObject

@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) NSInteger minStep;
@property (nonatomic, readonly) NSInteger maxStep;
@property (nonatomic, readonly) AFStepSimulatorMode mode;

+ (instancetype)shared;
- (void)updateEnabled:(BOOL)enabled minStep:(NSInteger)minStep maxStep:(NSInteger)maxStep mode:(AFStepSimulatorMode)mode;
- (NSInteger)simulatedStepForRealStep:(NSInteger)realStep;
- (void)installAvailableHooks;
- (NSString *)hookStatusText;

@end
