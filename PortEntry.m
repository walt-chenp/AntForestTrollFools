#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "antforest/AntForestManager.h"

static void (*originalViewDidLoad)(id, SEL);
static void (*originalViewDidAppear)(id, SEL, BOOL);
static id (*originalTransformResponseData)(id, SEL, id);
static NSInteger const AntForestButtonTag = 941204;
static NSString * const AntForestButtonXKey = @"AntForestButtonX";
static NSString * const AntForestButtonYKey = @"AntForestButtonY";

@interface AntForestLogPanel : UIViewController <UITableViewDataSource>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *todayLabel;
@property (nonatomic, strong) UILabel *totalLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@end

@implementation AntForestLogPanel

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.97 green:0.98 blue:0.99 alpha:1.0];

    UIView *grabber = [[UIView alloc] init];
    grabber.backgroundColor = [UIColor systemGray3Color];
    grabber.layer.cornerRadius = 3;
    grabber.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *titleIcon = [self iconWithName:@"leaf.fill" size:30];
    titleIcon.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *title = [[UILabel alloc] init];
    title.text = @"收取记录";
    title.font = [UIFont boldSystemFontOfSize:26];
    title.textColor = [UIColor colorWithRed:0.09 green:0.23 blue:0.16 alpha:1.0];
    title.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *clearButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [clearButton setTitle:@"清空" forState:UIControlStateNormal];
    clearButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [clearButton addTarget:self action:@selector(clearLogs) forControlEvents:UIControlEventTouchUpInside];
    clearButton.translatesAutoresizingMaskIntoConstraints = NO;

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

    [self.view addSubview:grabber];
    [self.view addSubview:titleIcon];
    [self.view addSubview:title];
    [self.view addSubview:clearButton];
    [self.view addSubview:stats];
    [self.view addSubview:card];
    [card addSubview:autoRow];
    [card addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [grabber.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:10],
        [grabber.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [grabber.widthAnchor constraintEqualToConstant:44], [grabber.heightAnchor constraintEqualToConstant:6],
        [titleIcon.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [titleIcon.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [titleIcon.widthAnchor constraintEqualToConstant:30], [titleIcon.heightAnchor constraintEqualToConstant:30],
        [title.topAnchor constraintEqualToAnchor:grabber.bottomAnchor constant:18],
        [title.leadingAnchor constraintEqualToAnchor:titleIcon.trailingAnchor constant:10],
        [stats.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:18],
        [stats.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [stats.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [card.topAnchor constraintEqualToAnchor:stats.bottomAnchor constant:18],
        [card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [card.bottomAnchor constraintEqualToAnchor:clearButton.topAnchor constant:-10],
        [clearButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [clearButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8],
        [autoRow.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [autoRow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [autoRow.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [self.tableView.topAnchor constraintEqualToAnchor:autoRow.bottomAnchor constant:10],
        [self.tableView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:0],
        [self.tableView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:0],
        [self.tableView.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-4],
    ]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:@"LogUpdated" object:nil];
    [self refresh];
}

- (UIView *)iconWithName:(NSString *)name size:(CGFloat)size {
    UIImageView *imageView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:name]];
    imageView.tintColor = [UIColor colorWithRed:0.07 green:0.31 blue:0.18 alpha:1.0];
    imageView.contentMode = UIViewContentModeScaleAspectFit;
    if (size <= 26) {
        UIView *badge = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 48, 48)];
        badge.backgroundColor = [UIColor colorWithRed:0.90 green:0.95 blue:0.91 alpha:1.0];
        badge.layer.cornerRadius = 24;
        imageView.frame = CGRectMake(12, 12, 24, 24);
        [badge addSubview:imageView];
        [badge.widthAnchor constraintEqualToConstant:48].active = YES;
        [badge.heightAnchor constraintEqualToConstant:48].active = YES;
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
    if (sender.on) {
        [manager addLog:[NSString stringWithFormat:@"%@\n自动收集开始", getCurrentDateTimeString()]];
        [manager startAutoCollectTimerWithInterval:300];
    } else {
        [manager.autoCollectTimer invalidate];
        [manager addLog:[NSString stringWithFormat:@"%@\n自动收集关闭", getCurrentDateTimeString()]];
    }
}

- (void)clearLogs {
    [((AntForestManager *)[AntForestManager sharedInstance]).logRecord removeAllObjects];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"logRecord"];
    [self.tableView reloadData];
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
        panel.sheetPresentationController.detents = @[[UISheetPresentationControllerDetent customDetentWithIdentifier:@"log" resolver:^CGFloat(id<UISheetPresentationControllerDetentResolutionContext> context) { return 440; }]];
    } else if (@available(iOS 15.0, *)) {
        panel.sheetPresentationController.detents = @[[UISheetPresentationControllerDetent mediumDetent]];
    }
    [presenter presentViewController:panel animated:YES completion:nil];
}

static void handleButtonPan(id controller, SEL _cmd, UIPanGestureRecognizer *gesture) {
    UIButton *button = (UIButton *)gesture.view;
    UIView *view = button.superview;
    CGPoint translation = [gesture translationInView:view];
    if (gesture.state == UIGestureRecognizerStateChanged || gesture.state == UIGestureRecognizerStateEnded) {
        CGPoint center = CGPointMake(button.center.x + translation.x, button.center.y + translation.y);
        UIEdgeInsets safe = view.safeAreaInsets;
        center.x = MIN(MAX(center.x, safe.left + 28), view.bounds.size.width - safe.right - 28);
        center.y = MIN(MAX(center.y, safe.top + 28), view.bounds.size.height - safe.bottom - 28);
        button.center = center;
        [gesture setTranslation:CGPointZero inView:view];
    }
    if (gesture.state == UIGestureRecognizerStateEnded) {
        [[NSUserDefaults standardUserDefaults] setFloat:button.center.x / view.bounds.size.width forKey:AntForestButtonXKey];
        [[NSUserDefaults standardUserDefaults] setFloat:button.center.y / view.bounds.size.height forKey:AntForestButtonYKey];
    }
}

static void addLogButton(UIViewController *controller) {
    if ([controller.view viewWithTag:AntForestButtonTag]) return;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = AntForestButtonTag;
    button.tintColor = UIColor.whiteColor;
    button.backgroundColor = [UIColor colorWithRed:0.06 green:0.22 blue:0.14 alpha:0.92];
    button.layer.cornerRadius = 28;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.2;
    button.layer.shadowRadius = 8;
    button.frame = CGRectMake(controller.view.bounds.size.width - 72, controller.view.safeAreaInsets.top + 160, 56, 56);
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    UIImage *image = [UIImage systemImageNamed:@"leaf.fill"];
    [button setImage:image forState:UIControlStateNormal];
    [controller.view addSubview:button];
    [button addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) { showLogPanel(button); }] forControlEvents:UIControlEventTouchUpInside];
    CGFloat savedX = [[NSUserDefaults standardUserDefaults] floatForKey:AntForestButtonXKey];
    CGFloat savedY = [[NSUserDefaults standardUserDefaults] floatForKey:AntForestButtonYKey];
    if (savedX > 0 && savedY > 0) button.center = CGPointMake(savedX * controller.view.bounds.size.width, savedY * controller.view.bounds.size.height);
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:controller action:@selector(antforestHandlePan:)];
    [button addGestureRecognizer:pan];
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
    if (manager.enableAutoCollect) [manager startAutoCollectTimerWithInterval:300];
}

static void portViewDidLoad(id self, SEL _cmd) {
    originalViewDidLoad(self, _cmd);
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ initializeManager(); });
}

static void portViewDidAppear(id self, SEL _cmd, BOOL animated) {
    originalViewDidAppear(self, _cmd, animated);
    addLogButton(self);
}

static id portTransformResponseData(id self, SEL _cmd, id value) {
    ((AntForestManager *)[AntForestManager sharedInstance]).jsBridge = self;
    [[AntForestManager sharedInstance] matchFriendIdAndBubbles:value];
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
        Class webController = NSClassFromString(@"H5WebViewController");
        class_addMethod(webController, @selector(antforestHandlePan:), (IMP)handleButtonPan, "v@:@");
        BOOL viewHooked = hookMethod(webController, @selector(viewDidLoad), (IMP)portViewDidLoad, (IMP *)&originalViewDidLoad);
        BOOL appearanceHooked = hookMethod(webController, @selector(viewDidAppear:), (IMP)portViewDidAppear, (IMP *)&originalViewDidAppear);
        BOOL responseHooked = hookMethod(NSClassFromString(@"PSDJsBridge"), @selector(transformResponseData:), (IMP)portTransformResponseData, (IMP *)&originalTransformResponseData);
        NSLog(@"[AntForestPort] installed: view=%d appearance=%d response=%d", viewHooked, appearanceHooked, responseHooked);
    }
}
