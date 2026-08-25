//
//  antforest.mm
//  antforest
//
//  Created by walt-chenp.
//  Copyright (c) 2024 ___ORGANIZATIONNAME___. All rights reserved.
//

// CaptainHook by Ryan Petrich
// see https://github.com/rpetrich/CaptainHook/

#if TARGET_OS_SIMULATOR
#error Do not support the simulator, please use the real iPhone Device.
#endif

#import <Foundation/Foundation.h>
#import "CaptainHook/CaptainHook.h"

#import <UIKit/UIKit.h>
#import <substrate.h>
#import <HBLog.h>

#import "AntForestManager.h"

#import "H5WebViewController.h"
#import "RVKContentView.h"

#import "PSDJsBridge.h"
#import "Tool.h"
#import "BgRun.h"

#import <UserNotifications/UserNotifications.h>

// Objective-C runtime hooking using CaptainHook:
//   1. declare class using CHDeclareClass()
//   2. load class using CHLoadClass() or CHLoadLateClass() in CHConstructor
//   3. hook method using CHOptimizedMethod()
//   4. register hook using CHHook() in CHConstructor
//   5. (optionally) call old method using CHSuper()

#pragma mark - 应用进入前台和后台 hook


CHDeclareClass(DFClientDelegate);

//- (void)applicationDidBecomeActive:(id)arg1;
CHOptimizedMethod(1, self, void, DFClientDelegate , applicationDidBecomeActive, id, arg1)
{
    CHSuper(1,DFClientDelegate,applicationDidBecomeActive ,arg1);
    //[[BgRun sharedInstance] endBackgroundMode];
    //if([[AntForestManager sharedInstance] enableAutoCollect]){
        //[Tool Toast: @"applicationDidBecomeActive"];
        //[[BgRun sharedInstance] endBadgeNumberCount];
    //}
}

//- (void)applicationDidEnterBackground:(id)arg1;
CHOptimizedMethod(1, self, void, DFClientDelegate , applicationDidEnterBackground, id, arg1)
{
    CHSuper(1,DFClientDelegate,applicationDidEnterBackground ,arg1);
    //if([[AntForestManager sharedInstance] enableAutoCollect]){
        //[Tool Toast: @"applicationDidEnterBackground"];
        //[[BgRun sharedInstance] beginBackgroundMode];
        //[[BgRun sharedInstance] beginBadgeNumberCount];
    //}
}

#pragma mark ---view

// (在implementation中写方法会直接卡死) 所以稳妥方式:(使用CHDeclareMethod新增方法,并在类扩展中声明)
@interface H5WebViewController() <UITableViewDelegate, UITableViewDataSource>
-(void)showIcon;
-(void)onClickShowLog;
-(void)onClickShowLog2;
-(void)onClickTest;
@end

CHDeclareClass(H5WebViewController); // declare class


//首次加载时初始化实例
CHOptimizedMethod(0, self, void, H5WebViewController, viewDidLoad) {
    CHSuper(0,H5WebViewController, viewDidLoad);
//    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"logRecord"];
//    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"friendsBubbles"];
//    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"friendsName"];
//    [[NSUserDefaults standardUserDefaults] synchronize];
    @try{
        AntForestManager *afm = [AntForestManager sharedInstance];
        [[BgRun sharedInstance] saveCAFToSandbox];
        if(![[NSUserDefaults standardUserDefaults] objectForKey:@"friendsBubbles"]){
            afm.friendsBubbles = [NSMutableDictionary dictionaryWithCapacity:100];
        }else{
            // 获取存储的数据并解档
            NSData *storedData = [[NSUserDefaults standardUserDefaults] objectForKey:@"friendsBubbles"];
            NSDictionary *retrievedDict = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSDictionary class] fromData:storedData error:nil];
            afm.friendsBubbles = [retrievedDict mutableCopy];
        }
        if(![[NSUserDefaults standardUserDefaults] objectForKey:@"friendsName"]){
            afm.friendsName = [NSMutableDictionary dictionaryWithCapacity:100];
        }else{
            // 获取存储的数据并解档
            NSData *storedData2 = [[NSUserDefaults standardUserDefaults] objectForKey:@"friendsName"];
            NSDictionary *retrievedDict2 = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSDictionary class] fromData:storedData2 error:nil];
            afm.friendsName = [retrievedDict2 mutableCopy];
        }
        if(![[NSUserDefaults standardUserDefaults] objectForKey:@"logRecord"]){
            afm.logRecord = [NSMutableArray arrayWithCapacity:50];
        }else{
            // 获取存储的数据并解档
            NSData *storedData3 = [[NSUserDefaults standardUserDefaults] objectForKey:@"logRecord"];
            NSArray *retrievedDict3 = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSArray class] fromData:storedData3 error:nil];
            afm.logRecord = [retrievedDict3 mutableCopy];
        }
        afm.friendsRank = [NSMutableDictionary dictionary]; //必须要初始化 否则设置不成功
        afm.totalCollectedEnergy =[[NSUserDefaults standardUserDefaults] integerForKey:@"totalCollectedEnergy"];
        afm.enableAutoCollect = [[NSUserDefaults standardUserDefaults] boolForKey:@"enableAutoCollect"];
        afm.failedTimes = 0;
        //if(afm.enableAutoCollect){
        [[AntForestManager sharedInstance] startAutoCollectTimerWithInterval:300];
        //}
        
        //FileLog(@"anthook viewDidLoad");
    } @catch (NSException *exception) {
        // 捕获异常的代码
        //FileLog(@"Exception caught: %@", exception);
        [Tool Alert:[exception description]];
    }
}

// 处理拖动逻辑
CHDeclareMethod(1,void, H5WebViewController,handlePan,UIPanGestureRecognizer *,gestureRecognizer) {
    UIButton *draggedButton = (UIButton *)gestureRecognizer.view;
    CGPoint translation = [gestureRecognizer translationInView:self.view]; // 获取手势的移动距离
    CGPoint newCenter = CGPointMake(draggedButton.center.x + translation.x, draggedButton.center.y + translation.y);
    // 更新按钮位置
    draggedButton.center = newCenter;
    // 重置手势的移动距离
    [gestureRecognizer setTranslation:CGPointZero inView:self.view];
}

//这个方法必须要在 interface 里面声明
CHDeclareMethod(0,void,H5WebViewController,showIcon){
    UIButton *btnShowLog = [[UIButton alloc] initWithFrame: CGRectMake([UIScreen mainScreen].bounds.size.width - 80, 150, 80, 40)];
    [btnShowLog setTitle:@"拾取日志" forState:UIControlStateNormal];
    btnShowLog.titleLabel.font = [UIFont systemFontOfSize:15.0];
    btnShowLog.layer.cornerRadius = 8.0;
    [btnShowLog addTarget:self action:@selector(onClickShowLog2) forControlEvents:UIControlEventTouchUpInside];
    [btnShowLog setBackgroundColor:[UIColor orangeColor]];
    [[self h5WebView] addSubview:btnShowLog];
    
    static UIPanGestureRecognizer *panGesture;
    // 添加拖动手势识别器（确保只添加一次）
    if (![btnShowLog.gestureRecognizers containsObject:panGesture]) {
        panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [btnShowLog addGestureRecognizer:panGesture];
    }
    //    UIButton *btnTest = [[UIButton alloc] initWithFrame: CGRectMake([UIScreen mainScreen].bounds.size.width - 80, 210, 80, 40)];
    //    [btnTest setTitle:@"测试" forState:UIControlStateNormal];
    //    btnTest.titleLabel.font = [UIFont systemFontOfSize:15.0];
    //    [btnTest addTarget:self action:@selector(onClickTest) forControlEvents:UIControlEventTouchUpInside];
    //    [btnTest setBackgroundColor:[UIColor orangeColor]];
    //    btnTest.layer.cornerRadius = 8.0;
    //    [[self h5WebView] addSubview:btnTest];
}

// 实现 UITableViewDataSource 协议方法
CHDeclareMethod(2, NSInteger, H5WebViewController, tableView, UITableView *,tableView, numberOfRowsInSection, NSInteger, section) {
    return [[AntForestManager sharedInstance] logRecord].count; // 返回日志的行数
}

//- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
CHDeclareMethod(2, UITableViewCell *, H5WebViewController, tableView, UITableView *,tableView, cellForRowAtIndexPath, NSIndexPath *, indexPath) {
    static NSString *cellIdentifier = @"LogCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellIdentifier];
    }
    // 确保每次都设置新的文本
    cell.textLabel.numberOfLines = 0;  // 支持多行
    cell.textLabel.lineBreakMode = NSLineBreakByWordWrapping;  // 换行模式
    cell.textLabel.text = [[AntForestManager sharedInstance] logRecord][indexPath.row]; // 设置日志文本
    cell.textLabel.font =[UIFont systemFontOfSize:12];
    
    return cell;
}

//- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
CHDeclareMethod(2, CGFloat, H5WebViewController, tableView, UITableView *, tableView, heightForRowAtIndexPath, NSIndexPath *, indexPath) {
    static NSMutableDictionary *heightCache;
    if (!heightCache) {
        heightCache = [NSMutableDictionary dictionary];
    }
    
    NSString *logEntry = [[[AntForestManager sharedInstance] logRecord] objectAtIndex:indexPath.row];
    NSNumber *cachedHeight = heightCache[logEntry];
    if (!cachedHeight) {
        CGSize maxSize = CGSizeMake(tableView.frame.size.width - 40, CGFLOAT_MAX);
        NSDictionary *attributes = @{NSFontAttributeName: [UIFont systemFontOfSize:12]};
        CGRect textRect = [logEntry boundingRectWithSize:maxSize options:NSStringDrawingUsesLineFragmentOrigin attributes:attributes context:nil];
        cachedHeight = @(textRect.size.height + 20);
        heightCache[logEntry] = cachedHeight;
    }
    
    return cachedHeight.floatValue;
}


static long barStyle;
static id observer;
//这个方法必须要在 interface 里面声明
CHDeclareMethod(0,void,H5WebViewController,onClickShowLog2){
    @try{
        // 获取屏幕宽度以自适应屏幕大小
        CGFloat screenWidth = UIScreen.mainScreen.bounds.size.width;
        CGFloat screenHeight = UIScreen.mainScreen.bounds.size.height;
        
        // 弹窗宽高自适应
        CGFloat alertWidth = screenWidth * 0.8;
        CGFloat alertHeight = screenHeight * 0.6;
        
        // 创建一个自定义的 UIViewController 用于弹窗
        UIViewController *alertController = [[UIViewController alloc] init];
        alertController.view.backgroundColor = [UIColor whiteColor];
        alertController.modalPresentationStyle = UIModalPresentationPopover;
        alertController.preferredContentSize = CGSizeMake(alertWidth, alertHeight);
        
        // 创建一个标题标签
        UILabel *titleLabel = [[UILabel alloc] init];
        titleLabel.text = [NSString stringWithFormat:@"拾取日志(%ldg|%0.fs|%d次)",[[AntForestManager sharedInstance] totalCollectedEnergy],[[AntForestManager sharedInstance] collectInterval],[[AntForestManager sharedInstance] failedTimes]];
        titleLabel.textAlignment = NSTextAlignmentCenter;
        titleLabel.font = [UIFont boldSystemFontOfSize:18];
        titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        
        // 创建 UITableView
        UITableView *logTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
        logTableView.delegate = self;
        logTableView.dataSource = self;
        logTableView.rowHeight = UITableViewAutomaticDimension; // 自动计算行高
        logTableView.estimatedRowHeight = 44.0; // 设置预估行高
        logTableView.translatesAutoresizingMaskIntoConstraints = NO;
        
        // 创建开关和标签
        UILabel *autoCollectLabel = [[UILabel alloc] init];
        autoCollectLabel.text = @"开启自动收集";
        autoCollectLabel.translatesAutoresizingMaskIntoConstraints = NO;
        
        UISwitch *autoCollectSwitch = [[UISwitch alloc] init];
        autoCollectSwitch.on = [[AntForestManager sharedInstance] enableAutoCollect];  // 默认开启
        autoCollectSwitch.translatesAutoresizingMaskIntoConstraints = NO;
        [autoCollectSwitch addTarget:self action:@selector(switchAutoCollect:) forControlEvents:UIControlEventValueChanged];
        
        // 创建确定按钮
        UIButton *confirmButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [confirmButton setTitle:@"关闭" forState:UIControlStateNormal];
        confirmButton.titleLabel.font = [UIFont boldSystemFontOfSize:20];
        confirmButton.layer.cornerRadius = 8.0;
        confirmButton.translatesAutoresizingMaskIntoConstraints = NO;
        [confirmButton addTarget:self action:@selector(dismissAlert:) forControlEvents:UIControlEventTouchUpInside];
        
        // 创建一个水平的 UIStackView 放置 标签、开关、按钮
        UIStackView *controlStackView = [[UIStackView alloc] init];
        controlStackView.axis = UILayoutConstraintAxisHorizontal;  // 水平排列
        controlStackView.spacing = 10;
        controlStackView.alignment = UIStackViewAlignmentCenter;  // 居中
        controlStackView.distribution = UIStackViewDistributionFillEqually;  // 各控件平分宽度
        controlStackView.translatesAutoresizingMaskIntoConstraints = NO;
        
        //[controlStackView addArrangedSubview:autoCollectLabel];
        //[controlStackView addArrangedSubview:autoCollectSwitch];
        [controlStackView addArrangedSubview:confirmButton];
        
        // 使用 UIStackView 布局所有元素
        UIStackView *stackView = [[UIStackView alloc] init];
        stackView.axis = UILayoutConstraintAxisVertical;  // 垂直排列
        stackView.spacing = 10;  // 元素间距
        stackView.alignment = UIStackViewAlignmentFill;  // 填充
        stackView.translatesAutoresizingMaskIntoConstraints = NO;
        
        [stackView addArrangedSubview:titleLabel];
        [stackView addArrangedSubview:logTableView];
        [stackView addArrangedSubview:controlStackView];
        
        [alertController.view addSubview:stackView];
        
        // 设置 stackView 的约束
        [NSLayoutConstraint activateConstraints:@[
            [stackView.topAnchor constraintEqualToAnchor:alertController.view.topAnchor constant:20],
            [stackView.leadingAnchor constraintEqualToAnchor:alertController.view.leadingAnchor constant:20],
            [stackView.trailingAnchor constraintEqualToAnchor:alertController.view.trailingAnchor constant:-20],
            [stackView.bottomAnchor constraintEqualToAnchor:alertController.view.bottomAnchor constant:-20]
        ]];
        
        // 设置通知监听
        observer = [[NSNotificationCenter defaultCenter] addObserverForName:@"LogUpdated"
                                                                     object:nil
                                                                      queue:[NSOperationQueue mainQueue]
                                                                 usingBlock:^(NSNotification * _Nonnull note) {
            
            //            if([[AntForestManager sharedInstance] failedTimes] > 21) {
            //                [[AntForestManager sharedInstance] startAutoCollectTimerWithInterval:60];
            //            }
            // 滚动到最新日志
            if (!logTableView.isDragging && !logTableView.isDecelerating) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [logTableView reloadData];
                    if([[AntForestManager sharedInstance] logRecord].count > 0){
                        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:[[AntForestManager sharedInstance] logRecord].count - 1 inSection:0];
                        [logTableView scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionBottom animated:YES];
                    }
                    titleLabel.text = [NSString stringWithFormat:@"拾取日志(%ldg|%0.fs|%d次)",[[AntForestManager sharedInstance] totalCollectedEnergy],[[AntForestManager sharedInstance] collectInterval],[[AntForestManager sharedInstance] failedTimes]] ;
                });
                
            }
        }];
        
        barStyle = [[UIApplication sharedApplication] statusBarStyle];
        [[UIApplication sharedApplication] setStatusBarStyle:0]; //状态栏文字设置为黑色
        
        // 显示弹窗
        [self presentViewController:alertController animated:YES completion:^{
            if (!logTableView.isDragging && !logTableView.isDecelerating) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [logTableView reloadData];
                    if([[AntForestManager sharedInstance] logRecord].count > 0){
                        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:[[AntForestManager sharedInstance] logRecord].count - 1 inSection:0];
                        [logTableView scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionBottom animated:YES];
                    }
                    titleLabel.text = [NSString stringWithFormat:@"拾取日志(%ldg|%0.fs|%d次)",[[AntForestManager sharedInstance] totalCollectedEnergy],[[AntForestManager sharedInstance] collectInterval],[[AntForestManager sharedInstance] failedTimes]] ;
                });
            }
        }];
    } @catch (NSException *exception) {
        // 捕获异常的代码
        FileLog(@"Exception caught: %@", exception);
        [Tool Alert:[exception description]];
    }
    
}
//这个方法必须要在 interface 里面声明
CHDeclareMethod(0,void,H5WebViewController,onClickShowLog){
    // 将日志内容组合成一个字符串
    NSString *logText = [[[AntForestManager sharedInstance] logRecord] componentsJoinedByString:@"\n"];
    
    // 获取屏幕宽度以自适应屏幕大小
    CGFloat screenWidth = UIScreen.mainScreen.bounds.size.width;
    CGFloat screenHeight = UIScreen.mainScreen.bounds.size.height;
    
    // 弹窗宽高自适应
    CGFloat alertWidth = screenWidth * 0.8;
    CGFloat alertHeight = screenHeight * 0.6;
    
    // 创建一个自定义的 UIViewController 用于弹窗
    UIViewController *alertController = [[UIViewController alloc] init];
    alertController.view.backgroundColor = [UIColor whiteColor];
    alertController.modalPresentationStyle = UIModalPresentationPopover;
    alertController.preferredContentSize = CGSizeMake(alertWidth, alertHeight);
    
    // 创建一个标题标签
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = [NSString stringWithFormat:@"拾取日志(%ldg|%0.fs|%d次)",[[AntForestManager sharedInstance] totalCollectedEnergy],[[AntForestManager sharedInstance] collectInterval],[[AntForestManager sharedInstance] failedTimes]] ;
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.font = [UIFont boldSystemFontOfSize:18];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [alertController.view addSubview:titleLabel];
    
    // 创建一个可滚动的 UITextView 用于显示日志
    UITextView *textView = [[UITextView alloc] init];
    textView.text = logText;
    textView.editable = NO;  // 禁止编辑
    textView.layer.borderWidth = 1.0;
    textView.layer.borderColor = [UIColor lightGrayColor].CGColor;
    textView.layer.cornerRadius = 8.0; // 圆角
    textView.layer.shadowColor = [UIColor blackColor].CGColor;
    textView.layer.shadowOffset = CGSizeMake(0, 2);
    textView.layer.shadowOpacity = 0.3;
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    if (textView.text.length > 0) {
        NSRange range = NSMakeRange(textView.text.length - 1, 1);
        [textView scrollRangeToVisible:range];
        dispatch_async(dispatch_get_main_queue(), ^{
            [textView scrollRangeToVisible:range];
        });
    }
    [alertController.view addSubview:textView];
    
    // 添加开关来控制自动收集
    UILabel *autoCollectLabel = [[UILabel alloc] init];
    autoCollectLabel.text = @"开启自动收集";
    autoCollectLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [alertController.view addSubview:autoCollectLabel];
    
    UISwitch *autoCollectSwitch = [[UISwitch alloc] init];
    autoCollectSwitch.on = [[AntForestManager sharedInstance] enableAutoCollect] ;  // 默认开启
    autoCollectSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    // 添加开关的状态变化监听
    [autoCollectSwitch addTarget:self action:@selector(switchAutoCollect:) forControlEvents:UIControlEventValueChanged];
    [alertController.view addSubview:autoCollectSwitch];
    
    // 添加确定按钮
    UIButton *confirmButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [confirmButton setTitle:@"确定" forState:UIControlStateNormal];
    confirmButton.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    //confirmButton.backgroundColor = [UIColor orangeColor];  // 背景颜色
    confirmButton.layer.cornerRadius = 8.0;  // 圆角
    confirmButton.translatesAutoresizingMaskIntoConstraints = NO;
    [confirmButton addTarget:self action:@selector(dismissAlert:) forControlEvents:UIControlEventTouchUpInside];
    [alertController.view addSubview:confirmButton];
    
    // 添加约束
    [NSLayoutConstraint activateConstraints:@[
        // 标题在顶部居中
        [titleLabel.topAnchor constraintEqualToAnchor:alertController.view.topAnchor constant:20],
        [titleLabel.centerXAnchor constraintEqualToAnchor:alertController.view.centerXAnchor],
        
        // UITextView 占据大部分空间并居中
        [textView.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10],
        [textView.leadingAnchor constraintEqualToAnchor:alertController.view.leadingAnchor constant:20],
        [textView.trailingAnchor constraintEqualToAnchor:alertController.view.trailingAnchor constant:-20],
        [textView.bottomAnchor constraintEqualToAnchor:confirmButton.topAnchor constant:-10],
        
        // 开关和标签放置
        [autoCollectLabel.topAnchor constraintEqualToAnchor:textView.bottomAnchor constant:20],
        [autoCollectLabel.leadingAnchor constraintEqualToAnchor:alertController.view.leadingAnchor constant:20],
        
        [autoCollectSwitch.centerYAnchor constraintEqualToAnchor:autoCollectLabel.centerYAnchor],
        [autoCollectSwitch.trailingAnchor constraintEqualToAnchor:alertController.view.trailingAnchor constant:-20],
        
        // 确定按钮在底部居中
        [confirmButton.bottomAnchor constraintEqualToAnchor:alertController.view.bottomAnchor constant:-20],
        [confirmButton.centerXAnchor constraintEqualToAnchor:alertController.view.centerXAnchor],
        [confirmButton.topAnchor constraintEqualToAnchor:textView.bottomAnchor constant:20]
    ]];
    
    // 监听通知更新日志
    observer = [[NSNotificationCenter defaultCenter] addObserverForName:@"LogUpdated"
                                                                 object:nil
                                                                  queue:[NSOperationQueue mainQueue]
                                                             usingBlock:^(NSNotification * _Nonnull note) {
        textView.text = [[[AntForestManager sharedInstance] logRecord] componentsJoinedByString:@"\n"];
        // 滚动到最后一条日志
        if (textView.text.length > 0) {
            //            NSRange range = NSMakeRange(textView.text.length - 1, 1);
            //            [textView scrollRangeToVisible:range];
            titleLabel.text = [NSString stringWithFormat:@"拾取日志(%ldg|%0.fs|%d次)",[[AntForestManager sharedInstance] totalCollectedEnergy],[[AntForestManager sharedInstance] collectInterval],[[AntForestManager sharedInstance] failedTimes]] ;
        }
    }];
    
    barStyle = [[UIApplication sharedApplication] statusBarStyle];
    [[UIApplication sharedApplication] setStatusBarStyle:0]; //状态栏文字设置为黑色
    
    // 显示弹窗
    [self presentViewController:alertController animated:YES completion:^{
        if (textView.text.length > 0) {
            NSRange range = NSMakeRange(textView.text.length - 1, 1);
            [textView scrollRangeToVisible:range];
        }
    }];
}

//这个方法必须要在 interface 里面声明
CHDeclareMethod(1,void,H5WebViewController,dismissAlert,UIButton *,sender ){
    [[UIApplication sharedApplication] setStatusBarStyle:barStyle];
    [self dismissViewControllerAnimated:YES completion:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
}

//这个方法必须要在 interface 里面声明
CHDeclareMethod(1,void,H5WebViewController,switchAutoCollect,UISwitch *,sender ){
    if(sender.isOn) {
        [[AntForestManager sharedInstance] setEnableAutoCollect:true];
        [[AntForestManager sharedInstance] startAutoCollectTimerWithInterval:300];
    }else{
        [[AntForestManager sharedInstance] setEnableAutoCollect:false];
        [[[AntForestManager sharedInstance] autoCollectTimer] invalidate];
    }
    [[NSUserDefaults standardUserDefaults] setBool:[[AntForestManager sharedInstance] enableAutoCollect] forKey:@"enableAutoCollect"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

//这个方法必须要在 interface 里面声明
CHDeclareMethod(0,void,H5WebViewController,onClickTest){
    //[[AntForestManager sharedInstance] reviveEnergy:@"xxx" signId:@"083zv4g1mnklwr18j9cbi1gfwpoq849SIGN0"];
    //[[AntForestManager sharedInstance] cleanFriendsOcean:@"xxx"];
}

//添加一个显示和关闭自动拾取日志的按钮
//- (void)viewDidAppear:(_Bool)arg1;
CHOptimizedMethod(1, self, void, H5WebViewController, viewDidAppear, _Bool,arg1) {
    CHSuper(1,H5WebViewController, viewDidAppear,arg1);
    //NSLog(@"nslog anthook viewDidAppear");
    //添加一个显示日志的按钮
    [self showIcon];
    
}

#pragma mark ---control

CHDeclareClass(PSDJsBridge); // declare class

// - (void)_doFlushMessageQueue:(id)arg1 url:(id)arg2;
CHOptimizedMethod(2, self,void,PSDJsBridge,_doFlushMessageQueue,id,arg1,url,id,arg2) {
    CHSuper(2, PSDJsBridge,_doFlushMessageQueue,arg1,url,arg2);
    //FileLog(@"anthook _doFlushMessageQueue:\narg1: %@\narg2: %@\n",arg1,arg2);
    //FileLog(@"anthook _doFlushMessageQueue 调用\n",arg1,arg2);
}

// - (id)transformResponseData:(id)arg1;
CHOptimizedMethod(1, self,id,PSDJsBridge,transformResponseData,id,arg1) {
    //FileLog(@"anthook transformResponseData:\n%@\n",arg1);
    //FileLog(@"anthook transformResponseData 调用\n",arg1);
    [[AntForestManager sharedInstance] setJsBridge:self];
    //拦截返回数据判断
    [[AntForestManager sharedInstance] matchFriendIdAndBubbles:arg1];
    return CHSuper(1, PSDJsBridge,transformResponseData,arg1);
}

CHConstructor // code block that runs immediately upon load
{
    @autoreleasepool
    {
        CHLoadLateClass(H5WebViewController);
        CHHook(0,H5WebViewController, viewDidLoad);
        CHHook(1,H5WebViewController, viewDidAppear);
        
        CHLoadLateClass(PSDJsBridge);
        //CHHook2(PSDJsBridge,_doFlushMessageQueue,url);
        CHHook1(PSDJsBridge,transformResponseData);
        
        //CHLoadLateClass(DFClientDelegate);
        //应用进入前台
        //CHHook(1, DFClientDelegate, applicationDidBecomeActive); // register hook
        //应用进入后台
        //CHHook(1, DFClientDelegate, applicationDidEnterBackground); // register hook
    }
}
