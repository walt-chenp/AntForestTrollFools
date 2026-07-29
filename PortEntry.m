#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>

#import "antforest/AntForestManager.h"

static void (*originalViewDidLoad)(id, SEL);
static void (*originalViewDidAppear)(id, SEL, BOOL);
static id (*originalTransformResponseData)(id, SEL, id);

static void portInstallMarker(id self, SEL _cmd) {}
static NSInteger const AntForestButtonTag = 941204;
static NSString * const AntForestButtonXKey = @"AntForestButtonX";
static NSString * const AntForestButtonYKey = @"AntForestButtonY";
static NSString * const AntForestButtonSideKey = @"AntForestButtonSide";
static const void *AntForestButtonCollapsedKey = &AntForestButtonCollapsedKey;
static const void *AntForestButtonCollapseTokenKey = &AntForestButtonCollapseTokenKey;
static BOOL shouldRevealLeafOnNextForestAppearance = YES;

static BOOL isForestHomeURL(NSURL *url) {
    return [url.absoluteString containsString:@"180020010001247580"];
}

static BOOL isEnergyRainURL(NSURL *url) {
    NSString *text = [url.absoluteString lowercaseString];
    return [text containsString:@"energyrain"] || [text containsString:@"energy-rain"] || [text containsString:@"energy_rain"] || [text containsString:@"68687791.h5app.alipay.com"] || [text containsString:@"/p/c/18031y38qhq8"];
}

static id forestBridgeFromController(id controller) {
    for (NSString *name in @[@"jsBridge", @"bridge"]) {
        SEL selector = NSSelectorFromString(name);
        if (![controller respondsToSelector:selector]) continue;
        id bridge = ((id (*)(id, SEL))objc_msgSend)(controller, selector);
        if ([bridge isKindOfClass:NSClassFromString(@"PSDJsBridge")]) return bridge;
    }
    return nil;
}

static BOOL isForestResponse(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *response = value;
    NSDictionary *data = [response[@"resData"] isKindOfClass:NSDictionary.class] ? response[@"resData"] : nil;
    return (response[@"bubbles"] && response[@"userBaseInfo"]) || data[@"totalDatas"] || data[@"friendRanking"] || data[@"myself"] || data[@"friendId"];
}

static void installEnergyRainCollector(id controller) {
    static const void *collectorKey = &collectorKey;
    if (objc_getAssociatedObject(controller, collectorKey)) return;
    objc_setAssociatedObject(controller, collectorKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id webView = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(webView));
    SEL evaluate = @selector(evaluateJavaScript:completionHandler:);
    if (![webView respondsToSelector:evaluate]) {
        NSLog(@"[AntForestRain] collector unavailable");
        return;
    }
    NSString *script = @"(()=>{const c=document.querySelector('canvas'),state=window.__antForestRainCollector={frames:{}},rects=d=>{const b=d instanceof ArrayBuffer?d:d.buffer,o=d.byteOffset||0,f=new Float32Array(b,o,Math.floor(d.byteLength/4)),a=[];for(let i=0;i+19<f.length;i+=20){const xs=[f[i],f[i+5],f[i+10],f[i+15]],ys=[f[i+1],f[i+6],f[i+11],f[i+16]];if(xs.every(Number.isFinite)&&ys.every(Number.isFinite)){const x=Math.min(...xs),y=Math.min(...ys),w=Math.max(...xs)-x,h=Math.max(...ys)-y;if(w>0&&h>0)a.push({x,y,w,h})}}return a},event=(type,t,active)=>{let e;try{const touch=new Touch(t);e=new TouchEvent(type,{bubbles:true,cancelable:true,touches:active?[touch]:[],targetTouches:active?[touch]:[],changedTouches:[touch]})}catch(_){e=new Event(type,{bubbles:true,cancelable:true});Object.defineProperties(e,{touches:{value:active?[t]:[]},targetTouches:{value:active?[t]:[]},changedTouches:{value:[t]}})}c.dispatchEvent(e)},tap=(x,y)=>{const t={identifier:Date.now()%1000000,target:c,clientX:x,clientY:y,pageX:x,pageY:y,screenX:x,screenY:y};event('touchstart',t,true);setTimeout(()=>event('touchend',t,false),12)},hook=P=>{if(!P||P.__antForestRainCollectorHook)return;P.__antForestRainCollectorHook=1;const f=P.bufferSubData;if(f)P.bufferSubData=function(target,offset,data,...v){if(c&&this.canvas===c&&data&&data.byteLength){const now=rects(data),key=data.byteLength+':'+now.slice(0,2).map(q=>[q.x,q.y,q.w,q.h].map(Math.round).join(',')).join('/'),old=state.frames[key],time=Date.now();if(old&&old.boxes.length===now.length)now.forEach((q,i)=>{const r=old.boxes[i],dy=q.y-r.y,cx=q.x+q.w/2,cy=q.y+q.h/2;if(Math.abs(q.x-r.x)<5&&dy>.2&&dy<30&&q.w>=25&&q.w<=180&&q.h>=25&&q.h<=180&&cx>10&&cx<383&&cy>80&&cy<780&&time-(old.taps[i]||0)>400){old.taps[i]=time;setTimeout(()=>tap(cx,cy),0)}});state.frames[key]={boxes:now,taps:old?old.taps:{}}}return f.call(this,target,offset,data,...v)}};hook(window.WebGLRenderingContext&&WebGLRenderingContext.prototype);hook(window.WebGL2RenderingContext&&WebGL2RenderingContext.prototype);return c?'installed':'canvas unavailable'})()";
    void (*runJavaScript)(id, SEL, NSString *, void (^)(id, NSError *)) = (void *)objc_msgSend;
    runJavaScript(webView, evaluate, script, ^(id result, NSError *error) {
        NSLog(@"[AntForestRain] collector: %@%@", result ?: @"", error ? [NSString stringWithFormat:@" error=%@", error] : @"");
    });
}

@interface AntForestLogPanel : UIViewController <UITableViewDataSource>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *todayLabel;
@property (nonatomic, strong) UILabel *totalLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *intervalButton;
@end

@interface AntForestSchedulePanel : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIDatePicker *picker;
@property (nonatomic, strong) UIButton *saveButton;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic) NSInteger editingIndex;
@end

@interface AntForestIntervalPanel : UIViewController
@end

@implementation AntForestIntervalPanel
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *title = [[UILabel alloc] init]; title.text = @"后台循环间隔"; title.font = [UIFont boldSystemFontOfSize:22]; title.translatesAutoresizingMaskIntoConstraints = NO;
    UISlider *slider = [[UISlider alloc] init]; slider.minimumValue = 1; slider.maximumValue = 60; slider.value = [NSUserDefaults.standardUserDefaults integerForKey:@"backgroundIntervalMinutes"] ?: 5; slider.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *value = [[UILabel alloc] init]; value.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold]; value.textColor = [UIColor colorWithRed:0.07 green:0.31 blue:0.18 alpha:1.0]; value.translatesAutoresizingMaskIntoConstraints = NO;
    void (^update)(void) = ^{ value.text = [NSString stringWithFormat:@"%d 分钟", (int)lroundf(slider.value)]; };
    update();
    [slider addAction:[UIAction actionWithHandler:^(__unused UIAction *action) { slider.value = roundf(slider.value); update(); }] forControlEvents:UIControlEventValueChanged];
    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem]; [save setTitle:@"保存" forState:UIControlStateNormal]; save.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]; save.translatesAutoresizingMaskIntoConstraints = NO;
    [save addAction:[UIAction actionWithHandler:^(__unused UIAction *action) { NSInteger minutes = lroundf(slider.value); AntForestManager *manager = AntForestManager.sharedInstance; manager.collectInterval = minutes * 60; [NSUserDefaults.standardUserDefaults setInteger:minutes forKey:@"backgroundIntervalMinutes"]; if (manager.enableAutoCollect && manager.enableBackgroundLoop) [manager startAutoCollectTimerWithInterval:manager.collectInterval]; [self dismissViewControllerAnimated:YES completion:nil]; }] forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:title]; [self.view addSubview:slider]; [self.view addSubview:value]; [self.view addSubview:save];
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:28], [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [value.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:20], [value.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [slider.topAnchor constraintEqualToAnchor:value.bottomAnchor constant:20], [slider.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:28], [slider.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-28],
        [save.topAnchor constraintEqualToAnchor:slider.bottomAnchor constant:24], [save.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    ]];
}
@end

@implementation AntForestSchedulePanel

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"定时收取设置";
    self.editingIndex = NSNotFound;
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    UIBarButtonItem *close = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = close;
    UIView *enabledCard = [[UIView alloc] init]; enabledCard.backgroundColor = UIColor.systemBackgroundColor; enabledCard.layer.cornerRadius = 16; enabledCard.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *enabledTitle = [[UILabel alloc] init]; enabledTitle.text = @"启用每日定时收取"; enabledTitle.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]; enabledTitle.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *enabledDetail = [[UILabel alloc] init]; enabledDetail.text = @"仅收取好友与自己的成熟能量"; enabledDetail.font = [UIFont systemFontOfSize:13]; enabledDetail.textColor = UIColor.secondaryLabelColor; enabledDetail.translatesAutoresizingMaskIntoConstraints = NO;
    UISwitch *enabled = [[UISwitch alloc] init]; enabled.on = [AntForestManager sharedInstance].enableScheduledCollect; [enabled addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged]; enabled.translatesAutoresizingMaskIntoConstraints = NO;
    [enabledCard addSubview:enabledTitle]; [enabledCard addSubview:enabledDetail]; [enabledCard addSubview:enabled];
    self.picker = [[UIDatePicker alloc] init];
    self.picker.datePickerMode = UIDatePickerModeTime;
    self.picker.preferredDatePickerStyle = UIDatePickerStyleCompact;
    self.saveButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.saveButton setTitle:@"添加时间" forState:UIControlStateNormal];
    self.saveButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [self.saveButton addTarget:self action:@selector(addTime) forControlEvents:UIControlEventTouchUpInside];
    UIView *addCard = [[UIView alloc] init]; addCard.backgroundColor = UIColor.systemBackgroundColor; addCard.layer.cornerRadius = 16; addCard.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *addTitle = [[UILabel alloc] init]; addTitle.text = @"添加收取时间"; addTitle.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]; addTitle.translatesAutoresizingMaskIntoConstraints = NO;
    UIStackView *bar = [[UIStackView alloc] initWithArrangedSubviews:@[self.picker, self.saveButton]];
    bar.spacing = 16; bar.alignment = UIStackViewAlignmentCenter; bar.translatesAutoresizingMaskIntoConstraints = NO;
    [addCard addSubview:addTitle]; [addCard addSubview:bar];
    UILabel *sectionTitle = [[UILabel alloc] init]; sectionTitle.text = @"已添加时间"; sectionTitle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]; sectionTitle.textColor = UIColor.secondaryLabelColor; sectionTitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.dataSource = self; self.tableView.delegate = self; self.tableView.backgroundColor = UIColor.clearColor; self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel = [[UILabel alloc] init]; self.emptyLabel.text = @"尚未添加定时任务"; self.emptyLabel.font = [UIFont systemFontOfSize:15]; self.emptyLabel.textColor = UIColor.secondaryLabelColor; self.emptyLabel.textAlignment = NSTextAlignmentCenter; self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:enabledCard]; [self.view addSubview:addCard]; [self.view addSubview:sectionTitle]; [self.view addSubview:self.tableView]; [self.view addSubview:self.emptyLabel];
    [NSLayoutConstraint activateConstraints:@[
        [enabledCard.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16], [enabledCard.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16], [enabledCard.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16], [enabledCard.heightAnchor constraintEqualToConstant:70],
        [enabledTitle.topAnchor constraintEqualToAnchor:enabledCard.topAnchor constant:14], [enabledTitle.leadingAnchor constraintEqualToAnchor:enabledCard.leadingAnchor constant:16],
        [enabledDetail.topAnchor constraintEqualToAnchor:enabledTitle.bottomAnchor constant:4], [enabledDetail.leadingAnchor constraintEqualToAnchor:enabledTitle.leadingAnchor],
        [enabled.centerYAnchor constraintEqualToAnchor:enabledCard.centerYAnchor], [enabled.trailingAnchor constraintEqualToAnchor:enabledCard.trailingAnchor constant:-16],
        [addCard.topAnchor constraintEqualToAnchor:enabledCard.bottomAnchor constant:12], [addCard.leadingAnchor constraintEqualToAnchor:enabledCard.leadingAnchor], [addCard.trailingAnchor constraintEqualToAnchor:enabledCard.trailingAnchor], [addCard.heightAnchor constraintEqualToConstant:74],
        [addTitle.topAnchor constraintEqualToAnchor:addCard.topAnchor constant:12], [addTitle.leadingAnchor constraintEqualToAnchor:addCard.leadingAnchor constant:16],
        [bar.topAnchor constraintEqualToAnchor:addTitle.bottomAnchor constant:6], [bar.leadingAnchor constraintEqualToAnchor:addCard.leadingAnchor constant:16],
        [sectionTitle.topAnchor constraintEqualToAnchor:addCard.bottomAnchor constant:18], [sectionTitle.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [self.tableView.topAnchor constraintEqualToAnchor:sectionTitle.bottomAnchor constant:2],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.emptyLabel.topAnchor constraintEqualToAnchor:sectionTitle.bottomAnchor constant:38], [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    ]];
    [self updateEmptyState];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)updateEmptyState { self.emptyLabel.hidden = [AntForestManager sharedInstance].scheduledTimes.count > 0; }
- (void)toggle:(UISwitch *)sender {
    AntForestManager *manager = AntForestManager.sharedInstance;
    manager.enableScheduledCollect = sender.on;
    [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:@"enableScheduledCollect"];
    if (sender.on) [manager startScheduledCollectTimer]; else { [manager.scheduledCollectTimer invalidate]; manager.scheduledCollectTimer = nil; }
}
- (void)addTime {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init]; formatter.dateFormat = @"HH:mm";
    NSString *time = [formatter stringFromDate:self.picker.date];
    NSMutableArray *times = [[AntForestManager sharedInstance].scheduledTimes mutableCopy] ?: NSMutableArray.array;
    if (self.editingIndex != NSNotFound) [times removeObjectAtIndex:self.editingIndex];
    if (![times containsObject:time]) [times addObject:time];
    [times sortUsingSelector:@selector(compare:)];
    [AntForestManager sharedInstance].scheduledTimes = times;
    [NSUserDefaults.standardUserDefaults setObject:times forKey:@"scheduledCollectTimes"];
    self.editingIndex = NSNotFound;
    [self.saveButton setTitle:@"添加时间" forState:UIControlStateNormal];
    [self.tableView reloadData];
    [self updateEmptyState];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return [AntForestManager sharedInstance].scheduledTimes.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"time"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"time"];
    cell.textLabel.text = [AntForestManager sharedInstance].scheduledTimes[indexPath.row]; cell.textLabel.font = [UIFont monospacedDigitSystemFontOfSize:20 weight:UIFontWeightSemibold];
    cell.accessoryView = nil;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init]; formatter.dateFormat = @"HH:mm";
    self.picker.date = [formatter dateFromString:[AntForestManager sharedInstance].scheduledTimes[indexPath.row]] ?: NSDate.date;
    self.editingIndex = indexPath.row;
    [self.saveButton setTitle:@"保存修改" forState:UIControlStateNormal];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style != UITableViewCellEditingStyleDelete) return;
    NSMutableArray *times = [[AntForestManager sharedInstance].scheduledTimes mutableCopy]; [times removeObjectAtIndex:indexPath.row]; [AntForestManager sharedInstance].scheduledTimes = times; [NSUserDefaults.standardUserDefaults setObject:times forKey:@"scheduledCollectTimes"]; [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    [self updateEmptyState];
}
@end

@implementation AntForestLogPanel

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.97 green:0.98 blue:0.99 alpha:1.0];

    UIView *grabber = [[UIView alloc] init];
    grabber.backgroundColor = [UIColor systemGray3Color];
    grabber.layer.cornerRadius = 3;
    grabber.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *titleIcon = [self iconWithName:@"leaf.fill" size:24];
    titleIcon.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *title = [[UILabel alloc] init];
    title.text = @"收取记录";
    title.font = [UIFont boldSystemFontOfSize:24];
    title.textColor = [UIColor colorWithRed:0.09 green:0.23 blue:0.16 alpha:1.0];
    title.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *clearButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [clearButton setTitle:@"清空日志" forState:UIControlStateNormal];
    clearButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [clearButton addTarget:self action:@selector(clearLogs) forControlEvents:UIControlEventTouchUpInside];
    clearButton.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *copyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [copyButton setTitle:@"复制日志" forState:UIControlStateNormal];
    copyButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [copyButton addTarget:self action:@selector(copyDiagnosticLogs:) forControlEvents:UIControlEventTouchUpInside];
    copyButton.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *stats = [[UIStackView alloc] init];
    stats.axis = UILayoutConstraintAxisHorizontal;
    stats.distribution = UIStackViewDistributionFill;
    stats.alignment = UIStackViewAlignmentCenter;
    stats.translatesAutoresizingMaskIntoConstraints = NO;
    self.todayLabel = [self statLabelWithPrefix:@"今日\n"];
    self.totalLabel = [self statLabelWithPrefix:@"累计\n"];
    UIStackView *todayStat = [self statWithIcon:@"tray.full.fill" label:self.todayLabel];
    UIStackView *totalStat = [self statWithIcon:@"house.fill" label:self.totalLabel];
    UIView *divider = [[UIView alloc] init];
    divider.backgroundColor = [UIColor systemGray5Color];
    [divider.widthAnchor constraintEqualToConstant:1].active = YES;
    [divider.heightAnchor constraintEqualToConstant:52].active = YES;
    [stats addArrangedSubview:todayStat];
    [stats addArrangedSubview:divider];
    [stats addArrangedSubview:totalStat];
    [todayStat.widthAnchor constraintEqualToAnchor:totalStat.widthAnchor].active = YES;

    UIView *autoIcon = [self iconWithName:@"bag.fill" size:24];
    UILabel *autoLabel = [[UILabel alloc] init];
    autoLabel.text = @"自动收取";
    autoLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    UISwitch *autoSwitch = [[UISwitch alloc] init];
    autoSwitch.on = ((AntForestManager *)[AntForestManager sharedInstance]).enableAutoCollect;
    [autoSwitch addTarget:self action:@selector(toggleAutoCollect:) forControlEvents:UIControlEventValueChanged];
    UIStackView *autoLeading = [[UIStackView alloc] initWithArrangedSubviews:@[autoIcon, autoLabel]];
    autoLeading.spacing = 12;
    autoLeading.alignment = UIStackViewAlignmentCenter;
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.text = autoSwitch.on ? @"运行中" : @"已关闭";
    self.statusLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    UIStackView *autoTrailing = [[UIStackView alloc] initWithArrangedSubviews:@[autoSwitch, self.statusLabel]];
    autoTrailing.axis = UILayoutConstraintAxisVertical;
    autoTrailing.alignment = UIStackViewAlignmentCenter;
    autoTrailing.spacing = 2;
    UIStackView *autoRow = [[UIStackView alloc] initWithArrangedSubviews:@[autoLeading, autoTrailing]];
    autoRow.alignment = UIStackViewAlignmentCenter;
    autoRow.distribution = UIStackViewDistributionEqualSpacing;
    autoRow.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *rainIcon = [self iconWithName:@"cloud.rain.fill" size:24];
    UILabel *rainLabel = [[UILabel alloc] init];
    rainLabel.text = @"自动能量雨";
    rainLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    UISwitch *rainSwitch = [[UISwitch alloc] init];
    rainSwitch.on = ((AntForestManager *)[AntForestManager sharedInstance]).enableAutoRain;
    [rainSwitch addTarget:self action:@selector(toggleAutoRain:) forControlEvents:UIControlEventValueChanged];
    UIStackView *rainLeading = [[UIStackView alloc] initWithArrangedSubviews:@[rainIcon, rainLabel]];
    rainLeading.spacing = 12;
    rainLeading.alignment = UIStackViewAlignmentCenter;
    UIStackView *rainRow = [[UIStackView alloc] initWithArrangedSubviews:@[rainLeading, rainSwitch]];
    rainRow.alignment = UIStackViewAlignmentCenter;
    rainRow.distribution = UIStackViewDistributionEqualSpacing;
    rainRow.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *loopIcon = [self iconWithName:@"clock.arrow.circlepath" size:24];
    UILabel *loopLabel = [[UILabel alloc] init];
    loopLabel.text = @"后台循环";
    loopLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    UIButton *intervalButton = [UIButton buttonWithType:UIButtonTypeSystem];
    intervalButton.layer.borderWidth = 1; intervalButton.layer.borderColor = UIColor.systemGray5Color.CGColor; intervalButton.layer.cornerRadius = 10;
    intervalButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [intervalButton addTarget:self action:@selector(showIntervalSettings) forControlEvents:UIControlEventTouchUpInside];
    self.intervalButton = intervalButton;
    [self updateIntervalLabel];
    UISwitch *loopSwitch = [[UISwitch alloc] init];
    loopSwitch.on = [AntForestManager sharedInstance].enableBackgroundLoop;
    [loopSwitch addTarget:self action:@selector(toggleBackgroundLoop:) forControlEvents:UIControlEventValueChanged];
    UIStackView *loopLeading = [[UIStackView alloc] initWithArrangedSubviews:@[loopIcon, loopLabel]];
    loopLeading.spacing = 12; loopLeading.alignment = UIStackViewAlignmentCenter;
    [intervalButton.widthAnchor constraintEqualToConstant:70].active = YES;
    UIStackView *loopControls = [[UIStackView alloc] initWithArrangedSubviews:@[intervalButton, loopSwitch]];
    loopControls.spacing = 8; loopControls.alignment = UIStackViewAlignmentCenter;
    UIStackView *loopRow = [[UIStackView alloc] initWithArrangedSubviews:@[loopLeading, loopControls]];
    loopRow.alignment = UIStackViewAlignmentCenter; loopRow.distribution = UIStackViewDistributionEqualSpacing; loopRow.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *scheduleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [scheduleButton setTitle:@"定时收取设置" forState:UIControlStateNormal];
    [scheduleButton setImage:[UIImage systemImageNamed:@"calendar"] forState:UIControlStateNormal];
    scheduleButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    scheduleButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    scheduleButton.tintColor = [UIColor colorWithRed:0.07 green:0.31 blue:0.18 alpha:1.0];
    scheduleButton.imageEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 10);
    [scheduleButton addTarget:self action:@selector(showScheduleSettings) forControlEvents:UIControlEventTouchUpInside];
    scheduleButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chevron.tintColor = UIColor.systemGray3Color;
    UIStackView *scheduleRow = [[UIStackView alloc] initWithArrangedSubviews:@[scheduleButton, chevron]];
    scheduleRow.alignment = UIStackViewAlignmentCenter;
    scheduleRow.translatesAutoresizingMaskIntoConstraints = NO;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.rowHeight = 52;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorColor = [UIColor systemGray5Color];
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 20, 0, 20);
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor whiteColor];
    card.layer.cornerRadius = 20;
    card.layer.borderWidth = 1;
    card.layer.borderColor = [UIColor systemGray5Color].CGColor;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *scheduleCard = [[UIView alloc] init];
    scheduleCard.backgroundColor = UIColor.whiteColor; scheduleCard.layer.cornerRadius = 16; scheduleCard.layer.borderWidth = 1; scheduleCard.layer.borderColor = UIColor.systemGray5Color.CGColor; scheduleCard.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *divider1 = [[UIView alloc] init]; divider1.backgroundColor = UIColor.systemGray5Color; divider1.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *divider2 = [[UIView alloc] init]; divider2.backgroundColor = UIColor.systemGray5Color; divider2.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:grabber];
    [self.view addSubview:titleIcon];
    [self.view addSubview:title];
    [self.view addSubview:copyButton];
    [self.view addSubview:clearButton];
    [self.view addSubview:stats];
    [self.view addSubview:card];
    [self.view addSubview:scheduleCard];
    [self.view addSubview:self.tableView];
    [card addSubview:autoRow];
    [card addSubview:rainRow];
    [card addSubview:loopRow];
    [card addSubview:divider1]; [card addSubview:divider2];
    [scheduleCard addSubview:scheduleRow];
    [NSLayoutConstraint activateConstraints:@[
        [grabber.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:10],
        [grabber.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [grabber.widthAnchor constraintEqualToConstant:44], [grabber.heightAnchor constraintEqualToConstant:6],
        [titleIcon.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [titleIcon.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [titleIcon.widthAnchor constraintEqualToConstant:34], [titleIcon.heightAnchor constraintEqualToConstant:34],
        [title.topAnchor constraintEqualToAnchor:grabber.bottomAnchor constant:18],
        [title.leadingAnchor constraintEqualToAnchor:titleIcon.trailingAnchor constant:10],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:copyButton.leadingAnchor constant:-8],
        [copyButton.trailingAnchor constraintEqualToAnchor:clearButton.leadingAnchor constant:-10],
        [copyButton.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [clearButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [clearButton.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [stats.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:18],
        [stats.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [stats.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [card.topAnchor constraintEqualToAnchor:stats.bottomAnchor constant:18],
        [card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [autoRow.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [autoRow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [autoRow.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [rainRow.topAnchor constraintEqualToAnchor:autoRow.bottomAnchor constant:10],
        [rainRow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [rainRow.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [divider1.topAnchor constraintEqualToAnchor:rainRow.topAnchor constant:-5],
        [divider1.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16], [divider1.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16], [divider1.heightAnchor constraintEqualToConstant:1],
        [loopRow.topAnchor constraintEqualToAnchor:rainRow.bottomAnchor constant:10],
        [loopRow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [loopRow.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [divider2.topAnchor constraintEqualToAnchor:loopRow.topAnchor constant:-5],
        [divider2.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16], [divider2.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16], [divider2.heightAnchor constraintEqualToConstant:1],
        [card.bottomAnchor constraintEqualToAnchor:loopRow.bottomAnchor constant:16],
        [scheduleCard.topAnchor constraintEqualToAnchor:card.bottomAnchor constant:12],
        [scheduleCard.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16], [scheduleCard.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [scheduleRow.topAnchor constraintEqualToAnchor:scheduleCard.topAnchor constant:12],
        [scheduleRow.leadingAnchor constraintEqualToAnchor:scheduleCard.leadingAnchor constant:20],
        [scheduleRow.trailingAnchor constraintEqualToAnchor:scheduleCard.trailingAnchor constant:-20],
        [scheduleRow.heightAnchor constraintEqualToConstant:34],
        [scheduleCard.bottomAnchor constraintEqualToAnchor:scheduleRow.bottomAnchor constant:12],
        [self.tableView.topAnchor constraintEqualToAnchor:scheduleCard.bottomAnchor constant:8],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.tableView.heightAnchor constraintEqualToConstant:156],
    ]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:@"LogUpdated" object:nil];
    [self refresh];
}

- (UIView *)iconWithName:(NSString *)name size:(CGFloat)size {
    UIImageView *imageView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:name]];
    imageView.tintColor = [UIColor colorWithRed:0.07 green:0.31 blue:0.18 alpha:1.0];
    imageView.contentMode = UIViewContentModeScaleAspectFit;
    if (size <= 26) {
        UIView *badge = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 34, 34)];
        badge.backgroundColor = [UIColor colorWithRed:0.90 green:0.95 blue:0.91 alpha:1.0];
        badge.layer.cornerRadius = 17;
        imageView.frame = CGRectMake(9, 9, 16, 16);
        [badge addSubview:imageView];
        [badge.widthAnchor constraintEqualToConstant:34].active = YES;
        [badge.heightAnchor constraintEqualToConstant:34].active = YES;
        return badge;
    }
    return imageView;
}

- (UILabel *)statLabelWithPrefix:(NSString *)prefix {
    UILabel *label = [[UILabel alloc] init];
    label.numberOfLines = 2;
    label.font = [UIFont monospacedDigitSystemFontOfSize:20 weight:UIFontWeightBold];
    label.textColor = [UIColor colorWithRed:0.09 green:0.23 blue:0.16 alpha:1.0];
    return label;
}

- (UIStackView *)statWithIcon:(NSString *)icon label:(UILabel *)label {
    UIView *badge = [self iconWithName:icon size:24];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[badge, label]];
    stack.spacing = 10;
    stack.alignment = UIStackViewAlignmentCenter;
    return stack;
}

- (void)refresh {
    AntForestManager *manager = [AntForestManager sharedInstance];
    self.todayLabel.text = [NSString stringWithFormat:@"今日\n%ld g", (long)manager.todayCollectedEnergy];
    if (manager.totalCollectedEnergy >= 1000) {
        self.totalLabel.text = [NSString stringWithFormat:@"累计\n%.2f kg", manager.totalCollectedEnergy / 1000.0];
    } else {
        self.totalLabel.text = [NSString stringWithFormat:@"累计\n%ld g", (long)manager.totalCollectedEnergy];
    }
    [self.tableView reloadData];
}

- (void)toggleAutoCollect:(UISwitch *)sender {
    AntForestManager *manager = [AntForestManager sharedInstance];
    manager.enableAutoCollect = sender.on;
    self.statusLabel.text = sender.on ? @"运行中" : @"已关闭";
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:@"enableAutoCollect"];
    [manager recordStage:[NSString stringWithFormat:@"收取 · 自动收取已%@", sender.on ? @"开启" : @"关闭"]];
    if (sender.on) {
        if (manager.enableBackgroundLoop) [manager startAutoCollectTimerWithInterval:manager.collectInterval ?: 300];
        if (manager.enableScheduledCollect) [manager startScheduledCollectTimer];
    } else {
        [manager stopAutoCollectTimer];
        [manager.scheduledCollectTimer invalidate];
        manager.scheduledCollectTimer = nil;
    }
}

- (void)toggleAutoRain:(UISwitch *)sender {
    AntForestManager *manager = [AntForestManager sharedInstance];
    manager.enableAutoRain = sender.on;
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:@"enableAutoRain"];
}

- (void)updateIntervalLabel {
    NSInteger minutes = MAX(1, [NSUserDefaults.standardUserDefaults integerForKey:@"backgroundIntervalMinutes"] ?: 5);
    [self.intervalButton setTitle:[NSString stringWithFormat:@"%ld 分钟", (long)minutes] forState:UIControlStateNormal];
}

- (void)showIntervalSettings {
    AntForestIntervalPanel *settings = [[AntForestIntervalPanel alloc] init];
    settings.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) settings.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.mediumDetent];
    [self presentViewController:settings animated:YES completion:nil];
}

- (void)toggleBackgroundLoop:(UISwitch *)sender {
    AntForestManager *manager = AntForestManager.sharedInstance;
    manager.enableBackgroundLoop = sender.on;
    [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:@"enableBackgroundLoop"];
    [manager recordStage:[NSString stringWithFormat:@"收取 · 后台循环已%@", sender.on ? @"开启" : @"关闭"]];
    if (sender.on && manager.enableAutoCollect) [manager startAutoCollectTimerWithInterval:manager.collectInterval ?: 300]; else [manager stopAutoCollectTimer];
}

- (void)toggleScheduledCollect:(UISwitch *)sender {
    AntForestManager *manager = AntForestManager.sharedInstance;
    manager.enableScheduledCollect = sender.on;
    [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:@"enableScheduledCollect"];
    if (sender.on && manager.enableAutoCollect) [manager startScheduledCollectTimer]; else { [manager.scheduledCollectTimer invalidate]; manager.scheduledCollectTimer = nil; }
}

- (void)showScheduleSettings {
    AntForestSchedulePanel *settings = [[AntForestSchedulePanel alloc] init];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:settings];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)clearLogs {
    [((AntForestManager *)[AntForestManager sharedInstance]).logRecord removeAllObjects];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"logRecord"];
    [self.tableView reloadData];
}

- (void)copyDiagnosticLogs:(UIButton *)sender {
    AntForestManager *manager = AntForestManager.sharedInstance;
    NSArray *logs = manager.logRecord.reverseObjectEnumerator.allObjects;
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSString *log, __unused NSDictionary *bindings) {
        return [log containsString:@"收取 ·"];
    }];
    NSArray *records = [logs filteredArrayUsingPredicate:predicate];
    NSString *header = [NSString stringWithFormat:@"AntForestPort 收取日志\n导出时间：%@\n配置：自动收取=%@，后台循环=%@，循环间隔=%ld 秒，定时收取=%@\n统计：今日=%ld g，累计=%ld g，日志条目=%lu\n\n",
                      getCurrentDateTimeString(), manager.enableAutoCollect ? @"开" : @"关", manager.enableBackgroundLoop ? @"开" : @"关", (long)manager.collectInterval, manager.enableScheduledCollect ? @"开" : @"关", (long)manager.todayCollectedEnergy, (long)manager.totalCollectedEnergy, (unsigned long)records.count];
    UIPasteboard.generalPasteboard.string = records.count ? [header stringByAppendingString:[records componentsJoinedByString:@"\n\n"]] : [header stringByAppendingString:@"没有可复制的收取日志"];
    [sender setTitle:@"已复制" forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [sender setTitle:@"复制日志" forState:UIControlStateNormal];
    });
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return ((AntForestManager *)[AntForestManager sharedInstance]).logRecord.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"LogCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    cell.imageView.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
    cell.imageView.tintColor = [UIColor colorWithRed:0.07 green:0.31 blue:0.18 alpha:1.0];
    NSArray *logs = ((AntForestManager *)[AntForestManager sharedInstance]).logRecord;
    cell.textLabel.text = logs[logs.count - indexPath.row - 1];
    cell.textLabel.font = [UIFont systemFontOfSize:14];
    cell.textLabel.numberOfLines = 2;
    cell.backgroundColor = [UIColor clearColor];
    return cell;
}

@end

static void showLogPanel(UIButton *button) {
    UIResponder *responder = button;
    while (responder && ![responder isKindOfClass:[UIViewController class]]) responder = responder.nextResponder;
    UIViewController *presenter = (UIViewController *)responder;
    if (!presenter || presenter.presentedViewController) return;
    AntForestLogPanel *panel = [[AntForestLogPanel alloc] init];
    panel.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 16.0, *)) {
        panel.sheetPresentationController.detents = @[[UISheetPresentationControllerDetent customDetentWithIdentifier:@"log" resolver:^CGFloat(id<UISheetPresentationControllerDetentResolutionContext> context) { return 600; }]];
    } else if (@available(iOS 15.0, *)) {
        panel.sheetPresentationController.detents = @[[UISheetPresentationControllerDetent mediumDetent]];
    }
    [presenter presentViewController:panel animated:YES completion:nil];
}

static BOOL buttonIsCollapsed(UIButton *button) {
    return [objc_getAssociatedObject(button, AntForestButtonCollapsedKey) boolValue];
}

static BOOL buttonIsOnLeft(UIButton *button) {
    NSNumber *side = [[NSUserDefaults standardUserDefaults] objectForKey:AntForestButtonSideKey];
    return side ? side.boolValue : button.center.x <= button.superview.bounds.size.width / 2;
}

static CGFloat buttonCenterY(UIButton *button) {
    UIView *view = button.superview;
    UIEdgeInsets safe = view.safeAreaInsets;
    return MIN(MAX(button.center.y, safe.top + 24), view.bounds.size.height - safe.bottom - 24);
}

static void saveButtonPosition(UIButton *button, BOOL left) {
    UIView *view = button.superview;
    if (!view.bounds.size.width || !view.bounds.size.height) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setFloat:button.center.x / view.bounds.size.width forKey:AntForestButtonXKey];
    [defaults setFloat:button.center.y / view.bounds.size.height forKey:AntForestButtonYKey];
    [defaults setBool:left forKey:AntForestButtonSideKey];
}

static void setButtonCollapsed(UIButton *button, BOOL collapsed, BOOL animated) {
    UIView *view = button.superview;
    if (!view) return;
    BOOL left = buttonIsOnLeft(button);
    UIEdgeInsets safe = view.safeAreaInsets;
    CGFloat scale = 0.72;
    CGFloat visibleWidth = 14;
    CGFloat halfWidth = button.bounds.size.width * scale / 2;
    CGPoint center = CGPointMake(left ? safe.left - halfWidth + visibleWidth : view.bounds.size.width - safe.right + halfWidth - visibleWidth, buttonCenterY(button));
    if (!collapsed) center.x = left ? safe.left + 24 : view.bounds.size.width - safe.right - 24;
    void (^changes)(void) = ^{
        button.transform = collapsed ? CGAffineTransformMakeScale(scale, scale) : CGAffineTransformIdentity;
        button.alpha = collapsed ? 0.88 : 1.0;
        button.center = center;
    };
    if (animated) [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut animations:changes completion:nil];
    else changes();
    objc_setAssociatedObject(button, AntForestButtonCollapsedKey, @(collapsed), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void scheduleButtonCollapse(UIButton *button) {
    NSInteger token = [objc_getAssociatedObject(button, AntForestButtonCollapseTokenKey) integerValue] + 1;
    objc_setAssociatedObject(button, AntForestButtonCollapseTokenKey, @(token), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (button.superview && [objc_getAssociatedObject(button, AntForestButtonCollapseTokenKey) integerValue] == token) {
            setButtonCollapsed(button, YES, YES);
        }
    });
}

static void expandButton(UIButton *button) {
    NSInteger token = [objc_getAssociatedObject(button, AntForestButtonCollapseTokenKey) integerValue] + 1;
    objc_setAssociatedObject(button, AntForestButtonCollapseTokenKey, @(token), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (buttonIsCollapsed(button)) setButtonCollapsed(button, NO, YES);
}

static void dockButton(UIButton *button) {
    UIView *view = button.superview;
    BOOL left = button.center.x <= view.bounds.size.width / 2;
    [[NSUserDefaults standardUserDefaults] setBool:left forKey:AntForestButtonSideKey];
    setButtonCollapsed(button, NO, YES);
    saveButtonPosition(button, left);
    scheduleButtonCollapse(button);
}

static void handleButtonPan(id controller, SEL _cmd, UIPanGestureRecognizer *gesture) {
    UIButton *button = (UIButton *)gesture.view;
    UIView *view = button.superview;
    if (!view) return;
    CGPoint translation = [gesture translationInView:view];
    if (buttonIsCollapsed(button)) {
        BOOL inward = buttonIsOnLeft(button) ? translation.x > 10 : translation.x < -10;
        if (inward) {
            expandButton(button);
            [gesture setTranslation:CGPointZero inView:view];
        } else if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
            scheduleButtonCollapse(button);
        }
        return;
    }
    if (gesture.state == UIGestureRecognizerStateBegan) expandButton(button);
    if (gesture.state == UIGestureRecognizerStateChanged || gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        CGPoint center = CGPointMake(button.center.x + translation.x, button.center.y + translation.y);
        UIEdgeInsets safe = view.safeAreaInsets;
        center.x = MIN(MAX(center.x, safe.left + 24), view.bounds.size.width - safe.right - 24);
        center.y = MIN(MAX(center.y, safe.top + 24), view.bounds.size.height - safe.bottom - 24);
        button.center = center;
        [gesture setTranslation:CGPointZero inView:view];
    }
    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) dockButton(button);
}

static void addLogButton(UIViewController *controller, BOOL reveal) {
    UIButton *existingButton = (UIButton *)[controller.view viewWithTag:AntForestButtonTag];
    if (existingButton) {
        if (reveal) {
            expandButton(existingButton);
            scheduleButtonCollapse(existingButton);
        }
        return;
    }
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = AntForestButtonTag;
    button.tintColor = UIColor.whiteColor;
    button.backgroundColor = [UIColor colorWithRed:0.06 green:0.22 blue:0.14 alpha:0.92];
    button.layer.cornerRadius = 24;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.2;
    button.layer.shadowRadius = 8;
    button.frame = CGRectMake(controller.view.bounds.size.width - 64, controller.view.safeAreaInsets.top + 160, 48, 48);
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    UIImage *image = [UIImage systemImageNamed:@"leaf.fill"];
    [button setImage:image forState:UIControlStateNormal];
    [controller.view addSubview:button];
    [button addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        if (buttonIsCollapsed(button)) { expandButton(button); scheduleButtonCollapse(button); }
        else showLogPanel(button);
    }] forControlEvents:UIControlEventTouchUpInside];
    CGFloat savedX = [[NSUserDefaults standardUserDefaults] floatForKey:AntForestButtonXKey];
    CGFloat savedY = [[NSUserDefaults standardUserDefaults] floatForKey:AntForestButtonYKey];
    if (savedX > 0 && savedY > 0) button.center = CGPointMake(savedX * controller.view.bounds.size.width, savedY * controller.view.bounds.size.height);
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:controller action:@selector(antforestHandlePan:)];
    [button addGestureRecognizer:pan];
    if (reveal) scheduleButtonCollapse(button);
    else setButtonCollapsed(button, YES, NO);
    NSLog(@"[AntForestPort] button added");
}

static void initializeManager(void) {
    AntForestManager *manager = [AntForestManager sharedInstance];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSData *bubbles = [defaults objectForKey:@"friendsBubbles"];
    NSData *names = [defaults objectForKey:@"friendsName"];
    NSData *logs = [defaults objectForKey:@"logRecord"];
    manager.friendsBubbles = bubbles ? [[NSKeyedUnarchiver unarchivedObjectOfClass:NSDictionary.class fromData:bubbles error:nil] mutableCopy] : [NSMutableDictionary dictionary];
    manager.friendsName = names ? [[NSKeyedUnarchiver unarchivedObjectOfClass:NSDictionary.class fromData:names error:nil] mutableCopy] : [NSMutableDictionary dictionary];
    manager.logRecord = logs ? [[NSKeyedUnarchiver unarchivedObjectOfClass:NSArray.class fromData:logs error:nil] mutableCopy] : [NSMutableArray array];
    manager.friendsRank = [NSMutableDictionary dictionary];
    manager.totalCollectedEnergy = [defaults integerForKey:@"totalCollectedEnergy"];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd";
    NSString *today = [formatter stringFromDate:NSDate.date];
    if ([[defaults stringForKey:@"todayCollectedEnergyDate"] isEqualToString:today]) {
        manager.todayCollectedEnergy = [defaults integerForKey:@"todayCollectedEnergy"];
    } else {
        manager.todayCollectedEnergy = 0;
        [defaults setInteger:0 forKey:@"todayCollectedEnergy"];
        [defaults setObject:today forKey:@"todayCollectedEnergyDate"];
    }
    manager.enableAutoCollect = [defaults boolForKey:@"enableAutoCollect"];
    manager.enableAutoRain = [defaults objectForKey:@"enableAutoRain"] ? [defaults boolForKey:@"enableAutoRain"] : manager.enableAutoCollect;
    manager.enableBackgroundLoop = [defaults objectForKey:@"enableBackgroundLoop"] ? [defaults boolForKey:@"enableBackgroundLoop"] : YES;
    manager.enableScheduledCollect = [defaults boolForKey:@"enableScheduledCollect"];
    manager.scheduledTimes = [defaults arrayForKey:@"scheduledCollectTimes"] ?: @[];
    manager.collectInterval = MAX(1, [defaults integerForKey:@"backgroundIntervalMinutes"] ?: 5) * 60;
    [manager recordStage:[NSString stringWithFormat:@"诊断 · 初始化：自动=%d，循环=%d", manager.enableAutoCollect, manager.enableBackgroundLoop]];
    if (manager.enableAutoCollect && manager.enableBackgroundLoop) [manager startAutoCollectTimerWithInterval:manager.collectInterval];
    if (manager.enableAutoCollect && manager.enableScheduledCollect) [manager startScheduledCollectTimer];
}

static void portViewDidLoad(id self, SEL _cmd) {
    originalViewDidLoad(self, _cmd);
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ initializeManager(); });
}

static void portViewDidAppear(id self, SEL _cmd, BOOL animated) {
    originalViewDidAppear(self, _cmd, animated);
    NSURL *url = [self respondsToSelector:@selector(url)] ? [self url] : nil;
    AntForestManager *manager = [AntForestManager sharedInstance];
    BOOL forestHome = isForestHomeURL(url);
    id pageBridge = forestHome ? forestBridgeFromController(self) : nil;
    if (pageBridge && manager.jsBridge != pageBridge) {
        manager.jsBridge = pageBridge;
        [manager recordStage:@"诊断 · 已绑定森林首页 H5 Bridge"];
    }
    if (forestHome) [manager recordStage:[NSString stringWithFormat:@"诊断 · 森林首页出现：桥接=%d", manager.jsBridge != nil]];
    BOOL revealLeaf = forestHome && shouldRevealLeafOnNextForestAppearance;
    if (revealLeaf) shouldRevealLeafOnNextForestAppearance = NO;
    if (forestHome && manager.enableAutoCollect && manager.enableBackgroundLoop) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (manager.jsBridge) {
                [manager recordStage:@"诊断 · 首页桥接就绪，立即补跑"];
                [manager autoCollectBubbles];
            }
        });
    }
    if (isEnergyRainURL(url) && manager.enableAutoRain) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            installEnergyRainCollector(self);
        });
    }
    addLogButton(self, revealLeaf);
}

static id portTransformResponseData(id self, SEL _cmd, id value) {
    AntForestManager *manager = [AntForestManager sharedInstance];
    if (isForestResponse(value) && manager.jsBridge != self) {
        manager.jsBridge = self;
        [manager recordStage:@"诊断 · 已绑定森林响应 H5 Bridge"];
    }
    [manager matchFriendIdAndBubbles:value];
    return originalTransformResponseData(self, _cmd, value);
}

static BOOL hookMethod(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    *original = method_setImplementation(method, replacement);
    return YES;
}

__attribute__((constructor))
static void installHooks(void) {
    @autoreleasepool {
        BOOL shouldInstall = NO;
        @synchronized (NSProcessInfo.class) {
            shouldInstall = class_addMethod(NSProcessInfo.class, sel_registerName("antforestPortHooksInstalled"), (IMP)portInstallMarker, "v@:");
        }
        if (!shouldInstall) return;
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *notification) {
            shouldRevealLeafOnNextForestAppearance = YES;
        }];
        Class webController = NSClassFromString(@"H5WebViewController");
        class_addMethod(webController, @selector(antforestHandlePan:), (IMP)handleButtonPan, "v@:@");
        BOOL viewHooked = hookMethod(webController, @selector(viewDidLoad), (IMP)portViewDidLoad, (IMP *)&originalViewDidLoad);
        BOOL appearanceHooked = hookMethod(webController, @selector(viewDidAppear:), (IMP)portViewDidAppear, (IMP *)&originalViewDidAppear);
        BOOL responseHooked = hookMethod(NSClassFromString(@"PSDJsBridge"), @selector(transformResponseData:), (IMP)portTransformResponseData, (IMP *)&originalTransformResponseData);
        NSLog(@"[AntForestPort] installed: view=%d appearance=%d response=%d", viewHooked, appearanceHooked, responseHooked);
    }
}
