#import "StepSimulator.h"
#import "AntForestManager.h"
#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const AFStepSimulatorEnabledKey = @"afStepSimulatorEnabled";
static NSString * const AFStepSimulatorMinKey = @"afStepSimulatorMin";
static NSString * const AFStepSimulatorMaxKey = @"afStepSimulatorMax";
static NSString * const AFStepSimulatorModeKey = @"afStepSimulatorMode";

static const uint32_t AFStepSimulatorFNVOffset = 2166136261u;
static const uint32_t AFStepSimulatorFNVPrime = 16777619u;

static NSInteger (*originalAPStepInfoNumberOfSteps)(id, SEL);
static id (*originalCMPedometerDataNumberOfSteps)(id, SEL);
static id (*originalHKStatisticsSumQuantity)(id, SEL);

@interface AFStepSimulator (Reporting)
- (void)reportReadFrom:(NSString *)api realStep:(NSInteger)realStep simulatedStep:(NSInteger)simulatedStep;
@end

static void stepSimulatorHookMarker(id self, SEL _cmd) {}

static NSInteger AFStepSimulatorValue(NSInteger realStep) {
    return [[AFStepSimulator shared] simulatedStepForRealStep:realStep];
}

static NSInteger stepSimulatorAPStepInfoNumberOfSteps(id self, SEL _cmd) {
    NSInteger realStep = originalAPStepInfoNumberOfSteps ? originalAPStepInfoNumberOfSteps(self, _cmd) : 0;
    NSInteger simulated = AFStepSimulatorValue(realStep);
    [[AFStepSimulator shared] reportReadFrom:@"APStepInfo.numberOfSteps" realStep:realStep simulatedStep:simulated];
    return simulated;
}

static id stepSimulatorCMPedometerDataNumberOfSteps(id self, SEL _cmd) {
    id realValue = originalCMPedometerDataNumberOfSteps ? originalCMPedometerDataNumberOfSteps(self, _cmd) : nil;
    if (![realValue respondsToSelector:@selector(integerValue)]) return realValue;
    AFStepSimulator *simulator = AFStepSimulator.shared;
    NSInteger realStep = [realValue integerValue];
    NSInteger simulated = AFStepSimulatorValue(realStep);
    [simulator reportReadFrom:@"CMPedometerData.numberOfSteps" realStep:realStep simulatedStep:simulated];
    return simulator.enabled ? @(simulated) : realValue;
}

static id stepSimulatorHKStatisticsSumQuantity(id self, SEL _cmd) {
    id realQuantity = originalHKStatisticsSumQuantity ? originalHKStatisticsSumQuantity(self, _cmd) : nil;
    AFStepSimulator *simulator = AFStepSimulator.shared;
    if (!simulator.enabled || ![realQuantity respondsToSelector:@selector(doubleValueForUnit:)]) return realQuantity;
    Class unitClass = NSClassFromString(@"HKUnit");
    Class quantityClass = NSClassFromString(@"HKQuantity");
    SEL countUnit = NSSelectorFromString(@"countUnit");
    SEL valueForUnit = NSSelectorFromString(@"doubleValueForUnit:");
    SEL quantityWithUnit = NSSelectorFromString(@"quantityWithUnit:doubleValue:");
    if (!unitClass || !quantityClass || ![unitClass respondsToSelector:countUnit] || ![quantityClass respondsToSelector:quantityWithUnit]) return realQuantity;
    id unit = ((id (*)(id, SEL))objc_msgSend)(unitClass, countUnit);
    if (!unit) return realQuantity;
    double realValue = ((double (*)(id, SEL, id))objc_msgSend)(realQuantity, valueForUnit, unit);
    NSInteger simulated = AFStepSimulatorValue((NSInteger)realValue);
    [simulator reportReadFrom:@"HKStatistics.sumQuantity" realStep:(NSInteger)realValue simulatedStep:simulated];
    return ((id (*)(id, SEL, id, double))objc_msgSend)(quantityClass, quantityWithUnit, unit, (double)simulated) ?: realQuantity;
}

@interface AFStepSimulator ()
@property (nonatomic) BOOL enabled;
@property (nonatomic) NSInteger minStep;
@property (nonatomic) NSInteger maxStep;
@property (nonatomic) AFStepSimulatorMode mode;
@property (nonatomic, strong) NSMutableSet<NSString *> *hookedAPIs;
@property (nonatomic, strong) NSMutableSet<NSString *> *reportedAPIs;
- (void)reportReadFrom:(NSString *)api realStep:(NSInteger)realStep simulatedStep:(NSInteger)simulatedStep;
@end

@implementation AFStepSimulator

+ (instancetype)shared {
    static AFStepSimulator *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] initPrivate]; });
    return instance;
}

- (instancetype)init { return [AFStepSimulator shared]; }

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        _enabled = [defaults boolForKey:AFStepSimulatorEnabledKey];
        _minStep = [defaults objectForKey:AFStepSimulatorMinKey] ? [defaults integerForKey:AFStepSimulatorMinKey] : 8000;
        _maxStep = [defaults objectForKey:AFStepSimulatorMaxKey] ? [defaults integerForKey:AFStepSimulatorMaxKey] : 10000;
        _mode = [defaults integerForKey:AFStepSimulatorModeKey];
        _hookedAPIs = NSMutableSet.set;
        _reportedAPIs = NSMutableSet.set;
    }
    return self;
}

- (void)updateEnabled:(BOOL)enabled minStep:(NSInteger)minStep maxStep:(NSInteger)maxStep mode:(AFStepSimulatorMode)mode {
    self.enabled = enabled;
    self.minStep = minStep;
    self.maxStep = maxStep;
    self.mode = mode;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:enabled forKey:AFStepSimulatorEnabledKey];
    [defaults setInteger:minStep forKey:AFStepSimulatorMinKey];
    [defaults setInteger:maxStep forKey:AFStepSimulatorMaxKey];
    [defaults setInteger:mode forKey:AFStepSimulatorModeKey];
    NSLog(@"[AntForestStepSim] %@ mode=%ld range=%ld-%ld", enabled ? @"enabled" : @"disabled", (long)mode, (long)minStep, (long)maxStep);
    [self installAvailableHooks];
}

- (NSInteger)simulatedStepForRealStep:(NSInteger)realStep {
    if (!self.enabled || self.minStep < 1 || self.maxStep < self.minStep || self.maxStep > 1000000) return realStep;
    uint32_t range = (uint32_t)(self.maxStep - self.minStep + 1);
    if (self.mode == AFStepSimulatorModeRandomOnRead) return self.minStep + (NSInteger)arc4random_uniform(range);
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd";
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = NSTimeZone.localTimeZone;
    NSString *seed = [NSString stringWithFormat:@"%@|%ld|%ld", [formatter stringFromDate:NSDate.date], (long)self.minStep, (long)self.maxStep];
    uint32_t hash = AFStepSimulatorFNVOffset;
    for (const unsigned char *p = (const unsigned char *)seed.UTF8String; p && *p; p++) { hash ^= *p; hash *= AFStepSimulatorFNVPrime; }
    return self.minStep + (NSInteger)(hash % range);
}

- (BOOL)installHookForClass:(Class)cls selector:(SEL)selector replacement:(IMP)replacement original:(IMP *)original name:(NSString *)name {
    if (!cls || !class_getInstanceMethod(cls, selector)) return NO;
    SEL marker = NSSelectorFromString([@"afStepSimulatorHook_" stringByAppendingString:[name stringByReplacingOccurrencesOfString:@"." withString:@"_"]]);
    if (!class_addMethod(cls, marker, (IMP)stepSimulatorHookMarker, "v@:")) return YES;
    Method method = class_getInstanceMethod(cls, selector);
    *original = method_setImplementation(method, replacement);
    [self.hookedAPIs addObject:name];
    NSLog(@"[AntForestStepSim] hooked %@", name);
    return YES;
}

- (void)installAvailableHooks {
    @synchronized (self) {
        if ([self installHookForClass:NSClassFromString(@"APStepInfo") selector:@selector(numberOfSteps) replacement:(IMP)stepSimulatorAPStepInfoNumberOfSteps original:(IMP *)&originalAPStepInfoNumberOfSteps name:@"APStepInfo.numberOfSteps"]) return;
        [self installHookForClass:NSClassFromString(@"CMPedometerData") selector:@selector(numberOfSteps) replacement:(IMP)stepSimulatorCMPedometerDataNumberOfSteps original:(IMP *)&originalCMPedometerDataNumberOfSteps name:@"CMPedometerData.numberOfSteps"];
        [self installHookForClass:NSClassFromString(@"HKStatistics") selector:@selector(sumQuantity) replacement:(IMP)stepSimulatorHKStatisticsSumQuantity original:(IMP *)&originalHKStatisticsSumQuantity name:@"HKStatistics.sumQuantity"];
    }
}

- (void)reportReadFrom:(NSString *)api realStep:(NSInteger)realStep simulatedStep:(NSInteger)simulatedStep {
    if (!self.enabled) return;
    @synchronized (self) {
        if ([self.reportedAPIs containsObject:api]) return;
        [self.reportedAPIs addObject:api];
        NSLog(@"[AntForestStepSim] hit %@ real=%ld simulated=%ld", api, (long)realStep, (long)simulatedStep);
        [[AntForestManager sharedInstance] recordStage:[NSString stringWithFormat:@"收取 · 步数模拟：真实 %ld 步 → 模拟 %ld 步", (long)realStep, (long)simulatedStep]];
    }
}

- (NSString *)hookStatusText {
    if (!self.hookedAPIs.count) return @"等待支付宝计步接口加载";
    return [NSString stringWithFormat:@"已挂钩：%@", [[self.hookedAPIs.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@"、"]];
}

@end
