#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>

#import "antforest/AntForestManager.h"
#import "antforest/StepSimulator.h"

static void (*originalViewDidLoad)(id, SEL);
static void (*originalViewDidAppear)(id, SEL, BOOL);
static id (*originalTransformResponseData)(id, SEL, id);
static NSTimeInterval lastWaterGiftTapAt;
static const void *GiftFullProbeKey = &GiftFullProbeKey;
static __weak id giftProbeWebView;

static BOOL hookMethod(Class cls, SEL selector, IMP replacement, IMP *original);
static void tryAutoCollectWaterGift(void);
static void reportWaterGiftTapResult(void);

static void portInstallMarker(id self, SEL _cmd) {}
static NSInteger const AntForestButtonTag = 941204;
static NSString * const AntForestButtonXKey = @"AntForestButtonX";
static NSString * const AntForestButtonYKey = @"AntForestButtonY";
static NSString * const AntForestButtonSideKey = @"AntForestButtonSide";
static const void *AntForestButtonCollapsedKey = &AntForestButtonCollapsedKey;
static const void *AntForestButtonCollapseTokenKey = &AntForestButtonCollapseTokenKey;
static const void *ForestHomeStartKey = &ForestHomeStartKey;
static BOOL shouldRevealLeafOnNextForestAppearance = YES;

static BOOL isForestHomeURL(NSURL *url) {
    return [url.absoluteString containsString:@"180020010001247580"];
}

static BOOL isEnergyRainURL(NSURL *url) {
    NSString *text = [url.absoluteString lowercaseString];
    return [text containsString:@"energyrain"] || [text containsString:@"energy-rain"] || [text containsString:@"energy_rain"] || [text containsString:@"68687791.h5app.alipay.com"] || [text containsString:@"/p/c/18031y38qhq8"];
}

static BOOL isEarnEnergyURL(NSURL *url) {
    return [url.absoluteString containsString:@"forceWhackMole=Y"];
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

static void startForestHomeWhenBridgeReady(id controller) {
    if (objc_getAssociatedObject(controller, ForestHomeStartKey)) return;
    objc_setAssociatedObject(controller, ForestHomeStartKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak id weakController = controller;
    __block NSUInteger attempts = 0;
    __block void (^waitForBridge)(void);
    waitForBridge = ^{
        id currentController = weakController;
        NSURL *url = [currentController respondsToSelector:@selector(url)] ? [currentController url] : nil;
        if (!currentController || !isForestHomeURL(url) || isEarnEnergyURL(url)) { waitForBridge = nil; return; }
        AntForestManager *manager = AntForestManager.sharedInstance;
        id bridge = forestBridgeFromController(currentController);
        if (bridge) {
            if (manager.jsBridge != bridge) {
                manager.jsBridge = bridge;
                [manager recordStage:@"收取 · 森林首页 H5 Bridge 已就绪"];
            }
            if (manager.enableWaterOnLaunch) [manager startLaunchWateringThenCollect];
            else if (manager.enableAutoCollect && manager.enableBackgroundLoop) {
                [manager recordStage:@"收取 · 首页桥接就绪，立即补跑"];
                [manager autoCollectBubbles];
            }
            waitForBridge = nil;
            return;
        }
        if (++attempts >= 10) {
            objc_setAssociatedObject(currentController, ForestHomeStartKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [manager recordStage:@"收取 · 森林首页 H5 Bridge 等待超时"];
            waitForBridge = nil;
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), waitForBridge);
    };
    waitForBridge();
}

static BOOL isForestResponse(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *response = value;
    NSDictionary *data = [response[@"resData"] isKindOfClass:NSDictionary.class] ? response[@"resData"] : nil;
    return (response[@"bubbles"] && response[@"userBaseInfo"]) || data[@"totalDatas"] || data[@"friendRanking"] || data[@"myself"] || data[@"friendId"];
}

static BOOL isMyHomeResponse(id value, AntForestManager *manager) {
    NSDictionary *response = [value isKindOfClass:NSDictionary.class] ? value : nil;
    NSDictionary *base = [response[@"userBaseInfo"] isKindOfClass:NSDictionary.class] ? response[@"userBaseInfo"] : nil;
    return manager.myUserId.length && [base[@"userId"] isEqualToString:manager.myUserId];
}

static void tryAutoCollectWaterGift(void) {
    AntForestManager *manager = AntForestManager.sharedInstance;
    if (!manager.enableAutoCollect || !manager.enableSelfCollect || !giftProbeWebView || NSDate.date.timeIntervalSince1970 - lastWaterGiftTapAt < 45) return;
    SEL evaluate = @selector(evaluateJavaScript:completionHandler:);
    if (![giftProbeWebView respondsToSelector:evaluate]) return;
    // ponytail: one 4-second recheck covers delayed Canvas rendering; attempt cap still bounds a pathological page.
    NSString *script = @"(()=>{if(window.__afGiftAutoRunning)return 'busy';const c=document.querySelector('canvas');if(!c)return 'no-canvas';const r=c.getBoundingClientRect();if(!r.width||!r.height)return 'empty-canvas';const x=Math.round(r.left+r.width*.242),y=Math.round(r.top+r.height*.218);if(!window.__afGiftAutoCallHook){const b=window.AlipayJSBridge;if(!b||!b.call)return 'no-bridge';const f=b.call;window.__afGiftAutoCallHook=1;b.call=function(n,d){const q=d&&typeof d==='object'?(Array.isArray(d.requestData)?d.requestData[0]:d.requestData):null;if(window.__afGiftAutoWaiting&&n==='rpc'&&d&&String(d.operationType||'').includes('collectEnergy')&&q&&!q.fromAct)window.__afGiftAutoHits=(window.__afGiftAutoHits||0)+1;return f.apply(this,arguments)}}const tap=()=>{const t={identifier:Date.now()%1000000,target:c,clientX:x,clientY:y,pageX:x,pageY:y,screenX:x,screenY:y};const send=(type,active)=>{let e;try{const q=new Touch(t);e=new TouchEvent(type,{bubbles:true,cancelable:true,touches:active?[q]:[],targetTouches:active?[q]:[],changedTouches:[q]})}catch(_){e=new Event(type,{bubbles:true,cancelable:true});Object.defineProperties(e,{touches:{value:active?[t]:[]},targetTouches:{value:active?[t]:[]},changedTouches:{value:[t]}})}c.dispatchEvent(e)};send('touchstart',true);setTimeout(()=>send('touchend',false),12)};let attempts=0,misses=0,rechecked=0;window.__afGiftAutoHits=0;window.__afGiftAutoTapResult='';window.__afGiftAutoRunning=1;const done=()=>{window.__afGiftAutoWaiting=0;window.__afGiftAutoRunning=0;window.__afGiftAutoTapResult='done:'+attempts+':'+(window.__afGiftAutoHits||0)};const probe=(confirm)=>{const before=window.__afGiftAutoHits||0;attempts++;window.__afGiftAutoWaiting=1;tap();setTimeout(()=>{window.__afGiftAutoWaiting=0;if((window.__afGiftAutoHits||0)>before){misses=0;step()}else if(confirm)done();else{misses++;step()}},1800)};const step=()=>{if(attempts>=60)return done();if(misses>=3){if(rechecked)return done();rechecked=1;return setTimeout(()=>probe(1),4000)}probe(0)};step();return 'started:'+x+','+y})()";
    void (*runJavaScript)(id, SEL, NSString *, void (^)(id, NSError *)) = (void *)objc_msgSend;
    runJavaScript(giftProbeWebView, evaluate, script, ^(id result, NSError *error) {
        if (error || ![(NSString *)result hasPrefix:@"started:"]) return;
        lastWaterGiftTapAt = NSDate.date.timeIntervalSince1970;
        [manager recordStage:@"收取 · 浇水赠能：开始智能连续领取"];
        reportWaterGiftTapResult();
    });
}

static void reportWaterGiftTapResult(void) {
    if (!giftProbeWebView || NSDate.date.timeIntervalSince1970 - lastWaterGiftTapAt > 65) return;
    SEL evaluate = @selector(evaluateJavaScript:completionHandler:);
    if (![giftProbeWebView respondsToSelector:evaluate]) return;
    void (*runJavaScript)(id, SEL, NSString *, void (^)(id, NSError *)) = (void *)objc_msgSend;
    runJavaScript(giftProbeWebView, evaluate, @"String(window.__afGiftAutoTapResult||'running')", ^(id result, NSError *error) {
        NSString *status = [result isKindOfClass:NSString.class] ? result : @"";
        if (!error && [status hasPrefix:@"done:"]) {
            NSArray<NSString *> *parts = [[status substringFromIndex:5] componentsSeparatedByString:@":"];
            NSString *attempts = parts.count > 0 ? parts[0] : @"0";
            NSString *hits = parts.count > 1 ? parts[1] : @"0";
            [[AntForestManager sharedInstance] recordStage:[NSString stringWithFormat:@"收取 · 浇水赠能：智能领取结束（命中 %@ 个，点击 %@ 次）", hits, attempts]];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ reportWaterGiftTapResult(); });
    });
}

static void installGiftFullProbe(id controller) {
    if (objc_getAssociatedObject(controller, GiftFullProbeKey)) return;
    id webView = [controller respondsToSelector:@selector(webView)] ? ((id (*)(id, SEL))objc_msgSend)(controller, @selector(webView)) : nil;
    SEL evaluate = @selector(evaluateJavaScript:completionHandler:);
    if (![webView respondsToSelector:evaluate]) {
        NSLog(@"[AntForestWaterGiftProbe] fullProbe webView unavailable");
        return;
    }
    objc_setAssociatedObject(controller, GiftFullProbeKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    giftProbeWebView = webView;
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

static void installEarnEnergyCollector(id controller) {
    static const void *collectorKey = &collectorKey;
    if (objc_getAssociatedObject(controller, collectorKey)) return;
    objc_setAssociatedObject(controller, collectorKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id webView = [controller respondsToSelector:@selector(webView)] ? ((id (*)(id, SEL))objc_msgSend)(controller, @selector(webView)) : nil;
    SEL evaluate = @selector(evaluateJavaScript:completionHandler:);
    if (![webView respondsToSelector:evaluate]) return;
    NSString *script = @"(()=>{let p=window.__antForestEarnCollector;if(p)return 'installed';const c=document.getElementById('J_treeCanvas');if(!c)return 'no-canvas';p={active:/[?&]forceWhackMole=Y(?:&|$)/.test(location.href),hits:[]};window.__antForestEarnCollector=p;const tap=r=>{if(!p.active)return;const now=Date.now(),x=r.x+r.w/2,y=r.y+r.h/2,old=p.hits.find(q=>Math.abs(q.x-x)<55&&Math.abs(q.y-y)<80&&now-q.t<850);if(old)return;p.hits=p.hits.filter(q=>now-q.t<850);p.hits.push({x,y,t:now});const b=c.getBoundingClientRect(),cx=b.left+x*b.width/c.width,cy=b.top+y*b.height/c.height,t={identifier:now%1000000,target:c,clientX:cx,clientY:cy,pageX:cx,pageY:cy,screenX:cx,screenY:cy};try{const q=new Touch(t);c.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[q],targetTouches:[q],changedTouches:[q]}));setTimeout(()=>c.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[q]})),12)}catch(_){}};const rect=d=>{try{if(!d||d.byteLength!==192)return null;const f=new Float32Array(d.buffer||d,d.byteOffset||0,24),xs=[f[0],f[6],f[12],f[18]],ys=[f[1],f[7],f[13],f[19]];if(!xs.every(Number.isFinite)||!ys.every(Number.isFinite))return null;const x=Math.min(...xs),y=Math.min(...ys),w=Math.max(...xs)-x,h=Math.max(...ys)-y;return w>=70&&w<=130&&h>=70&&h<=130?{x,y,w,h}:null}catch(_){return null}};const b=window.AlipayJSBridge;if(b&&b.call&&!b.__afEarnCollector){b.__afEarnCollector=1;const f=b.call;b.call=function(handler,data){if(/settlementWhackMole/.test(String(data&&data.operationType||'')))p.active=false;return f.apply(this,arguments)}}const hook=P=>{if(!P||P.__afEarnCollector)return;P.__afEarnCollector=1;const f=P.bufferSubData;if(f)P.bufferSubData=function(target,offset,data,...a){const r=this.canvas===c&&rect(data);if(r)tap(r);return f.call(this,target,offset,data,...a)}};hook(window.WebGLRenderingContext&&WebGLRenderingContext.prototype);hook(window.WebGL2RenderingContext&&WebGL2RenderingContext.prototype);return 'installed'})()";
    void (*runJavaScript)(id, SEL, NSString *, void (^)(id, NSError *)) = (void *)objc_msgSend;
    runJavaScript(webView, evaluate, script, ^(id result, NSError *error) {
        if (error || ![result isEqual:@"no-canvas"]) return;
        objc_setAssociatedObject(controller, collectorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ installEarnEnergyCollector(controller); });
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

@interface AntForestStepSimulatorPanel : UIViewController
@property (nonatomic, strong) UISwitch *enabledSwitch;
@property (nonatomic, strong) UITextField *minField;
@property (nonatomic, strong) UITextField *maxField;
@property (nonatomic, strong) UISegmentedControl *modeControl;
@property (nonatomic, strong) UILabel *statusLabel;
@end

@interface AntForestSettingsPanel : UIViewController
@end

@interface AntForestWaterPanel : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<NSString *> *friendIds;
@property (nonatomic, strong) NSArray<NSString *> *filteredFriendIds;
@property (nonatomic, strong) UISearchController *searchController;
@end

@interface AntForestWaterSchedulePanel : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIDatePicker *picker;
@property (nonatomic, strong) UIButton *saveButton;
@property (nonatomic) NSInteger editingIndex;
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

- (void)close {
    if (self.navigationController.viewControllers.count > 1) [self.navigationController popViewControllerAnimated:YES];
    else [self dismissViewControllerAnimated:YES completion:nil];
}
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

@implementation AntForestWaterSchedulePanel

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"定时浇水";
    self.editingIndex = NSNotFound;
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.picker = [[UIDatePicker alloc] init]; self.picker.datePickerMode = UIDatePickerModeTime; self.picker.preferredDatePickerStyle = UIDatePickerStyleCompact;
    self.saveButton = [UIButton buttonWithType:UIButtonTypeSystem]; [self.saveButton setTitle:@"添加时间" forState:UIControlStateNormal]; self.saveButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]; [self.saveButton addTarget:self action:@selector(addTime) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *add = [[UIStackView alloc] initWithArrangedSubviews:@[self.picker, self.saveButton]]; add.spacing = 16; add.alignment = UIStackViewAlignmentCenter; add.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped]; self.tableView.dataSource = self; self.tableView.delegate = self; self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:add]; [self.view addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [add.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16], [add.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.tableView.topAnchor constraintEqualToAnchor:add.bottomAnchor constant:12], [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor], [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)close { [self.navigationController popViewControllerAnimated:YES]; }
- (void)addTime {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init]; formatter.dateFormat = @"HH:mm";
    NSString *time = [formatter stringFromDate:self.picker.date];
    NSMutableArray *times = [AntForestManager.sharedInstance.waterScheduledTimes mutableCopy] ?: NSMutableArray.array;
    if (self.editingIndex != NSNotFound) [times removeObjectAtIndex:self.editingIndex];
    if (![times containsObject:time]) [times addObject:time];
    [times sortUsingSelector:@selector(compare:)];
    AntForestManager.sharedInstance.waterScheduledTimes = times;
    [NSUserDefaults.standardUserDefaults setObject:times forKey:@"waterScheduledTimes"];
    self.editingIndex = NSNotFound; [self.saveButton setTitle:@"添加时间" forState:UIControlStateNormal]; [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return AntForestManager.sharedInstance.waterScheduledTimes.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"waterTime"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"waterTime"];
    cell.textLabel.text = AntForestManager.sharedInstance.waterScheduledTimes[indexPath.row]; cell.textLabel.font = [UIFont monospacedDigitSystemFontOfSize:20 weight:UIFontWeightSemibold]; return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init]; formatter.dateFormat = @"HH:mm";
    self.picker.date = [formatter dateFromString:AntForestManager.sharedInstance.waterScheduledTimes[indexPath.row]] ?: NSDate.date;
    self.editingIndex = indexPath.row; [self.saveButton setTitle:@"保存修改" forState:UIControlStateNormal]; [tableView deselectRowAtIndexPath:indexPath animated:YES];
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style != UITableViewCellEditingStyleDelete) return;
    NSMutableArray *times = [AntForestManager.sharedInstance.waterScheduledTimes mutableCopy]; [times removeObjectAtIndex:indexPath.row]; AntForestManager.sharedInstance.waterScheduledTimes = times; [NSUserDefaults.standardUserDefaults setObject:times forKey:@"waterScheduledTimes"]; [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
}
@end

@implementation AntForestWaterPanel

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"好友浇水设置";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"开始浇水" style:UIBarButtonItemStyleDone target:self action:@selector(confirmStart)];
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil]; self.searchController.searchResultsUpdater = self; self.searchController.obscuresBackgroundDuringPresentation = NO; self.searchController.searchBar.placeholder = @"搜索好友"; self.navigationItem.searchController = self.searchController;
    UIView *options = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 224)];
    UILabel *launchLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 12, 260, 25)]; launchLabel.text = @"打开蚂蚁森林自动浇水"; launchLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    UISwitch *launchSwitch = [[UISwitch alloc] initWithFrame:CGRectZero]; launchSwitch.on = AntForestManager.sharedInstance.enableWaterOnLaunch; launchSwitch.center = CGPointMake(options.bounds.size.width - 46, 24); launchSwitch.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin; [launchSwitch addTarget:self action:@selector(toggleWaterOnLaunch:) forControlEvents:UIControlEventValueChanged];
    UILabel *autoLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 50, 180, 25)]; autoLabel.text = @"启用定时自动浇水"; autoLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    UISwitch *autoSwitch = [[UISwitch alloc] initWithFrame:CGRectZero]; autoSwitch.on = AntForestManager.sharedInstance.enableAutoWater; autoSwitch.center = CGPointMake(options.bounds.size.width - 46, 62); autoSwitch.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin; [autoSwitch addTarget:self action:@selector(toggleAutoWater:) forControlEvents:UIControlEventValueChanged];
    UISegmentedControl *amount = [[UISegmentedControl alloc] initWithItems:@[@"10g", @"18g", @"33g", @"66g"]]; NSInteger index = MAX(0, MIN(3, AntForestManager.sharedInstance.waterEnergyId - 39)); amount.selectedSegmentIndex = index; amount.frame = CGRectMake(20, 87, options.bounds.size.width - 40, 32); amount.autoresizingMask = UIViewAutoresizingFlexibleWidth; [amount addTarget:self action:@selector(changeAmount:) forControlEvents:UIControlEventValueChanged];
    UILabel *reminderLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 130, 220, 25)]; reminderLabel.text = @"提醒 TA 来收（7 天未收退回）"; reminderLabel.font = [UIFont systemFontOfSize:15];
    UISwitch *reminder = [[UISwitch alloc] initWithFrame:CGRectZero]; reminder.on = AntForestManager.sharedInstance.waterReminderEnabled; reminder.center = CGPointMake(options.bounds.size.width - 46, 142); reminder.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin; [reminder addTarget:self action:@selector(toggleReminder:) forControlEvents:UIControlEventValueChanged];
    UIButton *schedule = [UIButton buttonWithType:UIButtonTypeSystem]; [schedule setTitle:@"定时浇水设置" forState:UIControlStateNormal]; schedule.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]; schedule.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft; schedule.frame = CGRectMake(20, 166, options.bounds.size.width - 40, 40); schedule.autoresizingMask = UIViewAutoresizingFlexibleWidth; [schedule addTarget:self action:@selector(showSchedule) forControlEvents:UIControlEventTouchUpInside];
    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(220, 166, options.bounds.size.width - 240, 40)]; hint.text = @"每位好友每日最多 3 次"; hint.textAlignment = NSTextAlignmentRight; hint.textColor = UIColor.secondaryLabelColor; hint.font = [UIFont systemFontOfSize:13]; hint.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [options addSubview:launchLabel]; [options addSubview:launchSwitch]; [options addSubview:autoLabel]; [options addSubview:autoSwitch]; [options addSubview:amount]; [options addSubview:reminderLabel]; [options addSubview:reminder]; [options addSubview:schedule]; [options addSubview:hint];
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped]; self.tableView.dataSource = self; self.tableView.delegate = self; self.tableView.tableHeaderView = options; self.tableView.allowsMultipleSelection = YES; self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.tableView]; [NSLayoutConstraint activateConstraints:@[[self.tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor], [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor], [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadFriends) name:@"WaterFriendListUpdated" object:nil];
    [self reloadFriends];
}

- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadFriends]; }
- (void)reloadFriends {
    AntForestManager *manager = AntForestManager.sharedInstance;
    self.friendIds = [[manager.friendsRank allKeys] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *uid, __unused NSDictionary *bindings) { return uid.length > 0 && ![uid isEqualToString:manager.myUserId]; }]];
    self.friendIds = [self.friendIds sortedArrayUsingComparator:^NSComparisonResult(NSString *left, NSString *right) { return [manager.friendsRank[left] integerValue] < [manager.friendsRank[right] integerValue] ? NSOrderedAscending : NSOrderedDescending; }];
    [self updateSearchResultsForSearchController:self.searchController];
}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = searchController.searchBar.text.lowercaseString;
    AntForestManager *manager = AntForestManager.sharedInstance;
    self.filteredFriendIds = query.length ? [self.friendIds filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *uid, __unused NSDictionary *bindings) { NSDictionary *c = manager.friendsName[uid]; NSString *name = [c[@"displayName"] description] ?: [c[@"name"] description] ?: @""; return [name.lowercaseString containsString:query]; }]] : self.friendIds;
    [self.tableView reloadData];
}
- (void)refreshFriends { [AntForestManager.sharedInstance refreshWaterFriends]; }
- (void)toggleWaterOnLaunch:(UISwitch *)sender { AntForestManager.sharedInstance.enableWaterOnLaunch = sender.on; [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:@"enableWaterOnLaunch"]; [AntForestManager.sharedInstance recordStage:[NSString stringWithFormat:@"收取 · 打开蚂蚁森林自动浇水已%@", sender.on ? @"开启" : @"关闭"]]; }
- (void)toggleAutoWater:(UISwitch *)sender { AntForestManager *m = AntForestManager.sharedInstance; m.enableAutoWater = sender.on; [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:@"enableAutoWater"]; if (sender.on) [m startScheduledWaterTimer]; else { [m.scheduledWaterTimer invalidate]; m.scheduledWaterTimer = nil; } }
- (void)changeAmount:(UISegmentedControl *)sender { AntForestManager.sharedInstance.waterEnergyId = 39 + sender.selectedSegmentIndex; [NSUserDefaults.standardUserDefaults setInteger:AntForestManager.sharedInstance.waterEnergyId forKey:@"waterEnergyId"]; }
- (void)toggleReminder:(UISwitch *)sender { AntForestManager.sharedInstance.waterReminderEnabled = sender.on; [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:@"waterReminderEnabled"]; }
- (void)showSchedule { [self.navigationController pushViewController:[[AntForestWaterSchedulePanel alloc] init] animated:YES]; }
- (void)confirmStart {
    AntForestManager *manager = AntForestManager.sharedInstance;
    NSUInteger count = manager.waterFriendIds.count; NSInteger grams = manager.waterGrams;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认开始浇水？" message:[NSString stringWithFormat:@"已选 %lu 位好友，按每人最多 3 次、每次 %ld g 计算，最多消耗 %ld g。", (unsigned long)count, (long)grams, (long)(count * 3 * grams)] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"开始浇水" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) { [manager startWateringSelectedFriendsWithReason:@"手动浇水"]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.filteredFriendIds.count; }
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section { return 46; }
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 46)];
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 7, header.bounds.size.width - 110, 32)]; title.autoresizingMask = UIViewAutoresizingFlexibleWidth; title.text = [NSString stringWithFormat:@"好友列表（已选 %lu 位）", (unsigned long)AntForestManager.sharedInstance.waterFriendIds.count]; title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]; title.textColor = UIColor.secondaryLabelColor;
    UIButton *refresh = [UIButton buttonWithType:UIButtonTypeSystem]; refresh.frame = CGRectMake(header.bounds.size.width - 84, 4, 68, 36); refresh.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin; [refresh setTitle:@"刷新" forState:UIControlStateNormal]; refresh.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]; [refresh addTarget:self action:@selector(refreshFriends) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:title]; [header addSubview:refresh]; return header;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"waterFriend"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"waterFriend"];
    NSString *uid = self.filteredFriendIds[indexPath.row]; NSDictionary *contact = AntForestManager.sharedInstance.friendsName[uid]; cell.textLabel.text = [contact[@"displayName"] description] ?: [contact[@"name"] description] ?: @"好友"; cell.accessoryType = [AntForestManager.sharedInstance.waterFriendIds containsObject:uid] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone; return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *uid = self.filteredFriendIds[indexPath.row]; NSMutableArray *selected = [AntForestManager.sharedInstance.waterFriendIds mutableCopy] ?: NSMutableArray.array; if ([selected containsObject:uid]) [selected removeObject:uid]; else [selected addObject:uid]; AntForestManager.sharedInstance.waterFriendIds = selected; [NSUserDefaults.standardUserDefaults setObject:selected forKey:@"waterFriendIds"]; [tableView deselectRowAtIndexPath:indexPath animated:YES]; [self.tableView reloadData];
}
@end

@implementation AntForestStepSimulatorPanel

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"步数模拟设置（测试）";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    AFStepSimulator *simulator = AFStepSimulator.shared;
    [simulator installAvailableHooks];
    UIView *card = [[UIView alloc] init]; card.backgroundColor = UIColor.systemBackgroundColor; card.layer.cornerRadius = 16; card.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *enabledTitle = [[UILabel alloc] init]; enabledTitle.text = @"启用步数模拟"; enabledTitle.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]; enabledTitle.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *enabledDetail = [[UILabel alloc] init]; enabledDetail.text = @"关闭后立即恢复支付宝读取到的真实步数"; enabledDetail.font = [UIFont systemFontOfSize:13]; enabledDetail.textColor = UIColor.secondaryLabelColor; enabledDetail.translatesAutoresizingMaskIntoConstraints = NO;
    self.enabledSwitch = [[UISwitch alloc] init]; self.enabledSwitch.on = simulator.enabled; self.enabledSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    [self.enabledSwitch addTarget:self action:@selector(toggleEnabled:) forControlEvents:UIControlEventValueChanged];
    UIView *rangeCard = [[UIView alloc] init]; rangeCard.backgroundColor = UIColor.systemBackgroundColor; rangeCard.layer.cornerRadius = 16; rangeCard.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *rangeTitle = [[UILabel alloc] init]; rangeTitle.text = @"步数范围"; rangeTitle.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]; rangeTitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.minField = [self numberFieldWithText:[NSString stringWithFormat:@"%ld", (long)simulator.minStep] placeholder:@"最小值"];
    self.maxField = [self numberFieldWithText:[NSString stringWithFormat:@"%ld", (long)simulator.maxStep] placeholder:@"最大值"];
    UILabel *separator = [[UILabel alloc] init]; separator.text = @"至"; separator.textColor = UIColor.secondaryLabelColor; separator.translatesAutoresizingMaskIntoConstraints = NO;
    UIStackView *range = [[UIStackView alloc] initWithArrangedSubviews:@[self.minField, separator, self.maxField]]; range.axis = UILayoutConstraintAxisHorizontal; range.spacing = 10; range.alignment = UIStackViewAlignmentCenter; range.translatesAutoresizingMaskIntoConstraints = NO;
    [self.minField.widthAnchor constraintEqualToConstant:112].active = YES; [self.maxField.widthAnchor constraintEqualToConstant:112].active = YES;
    UILabel *modeTitle = [[UILabel alloc] init]; modeTitle.text = @"生成方式"; modeTitle.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]; modeTitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.modeControl = [[UISegmentedControl alloc] initWithItems:@[@"日稳定", @"每次随机"]]; self.modeControl.selectedSegmentIndex = simulator.mode; self.modeControl.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *hint = [[UILabel alloc] init]; hint.text = @"日稳定：同一天读数一致；随机：每次读取变化。"; hint.font = [UIFont systemFontOfSize:13]; hint.textColor = UIColor.secondaryLabelColor; hint.numberOfLines = 0; hint.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel = [[UILabel alloc] init]; self.statusLabel.font = [UIFont systemFontOfSize:13]; self.statusLabel.textColor = UIColor.secondaryLabelColor; self.statusLabel.numberOfLines = 0; self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self refreshStatus];
    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem]; [save setTitle:@"保存设置" forState:UIControlStateNormal]; save.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]; [save addTarget:self action:@selector(save) forControlEvents:UIControlEventTouchUpInside]; save.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:card]; [self.view addSubview:rangeCard]; [card addSubview:enabledTitle]; [card addSubview:enabledDetail]; [card addSubview:self.enabledSwitch]; [rangeCard addSubview:rangeTitle]; [rangeCard addSubview:range]; [rangeCard addSubview:modeTitle]; [rangeCard addSubview:self.modeControl]; [rangeCard addSubview:hint]; [rangeCard addSubview:self.statusLabel]; [self.view addSubview:save];
    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16], [card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16], [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16], [card.heightAnchor constraintEqualToConstant:76],
        [enabledTitle.topAnchor constraintEqualToAnchor:card.topAnchor constant:15], [enabledTitle.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16], [enabledDetail.topAnchor constraintEqualToAnchor:enabledTitle.bottomAnchor constant:5], [enabledDetail.leadingAnchor constraintEqualToAnchor:enabledTitle.leadingAnchor], [self.enabledSwitch.centerYAnchor constraintEqualToAnchor:card.centerYAnchor], [self.enabledSwitch.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [rangeCard.topAnchor constraintEqualToAnchor:card.bottomAnchor constant:12], [rangeCard.leadingAnchor constraintEqualToAnchor:card.leadingAnchor], [rangeCard.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [rangeTitle.topAnchor constraintEqualToAnchor:rangeCard.topAnchor constant:16], [rangeTitle.leadingAnchor constraintEqualToAnchor:rangeCard.leadingAnchor constant:16], [range.topAnchor constraintEqualToAnchor:rangeTitle.bottomAnchor constant:12], [range.leadingAnchor constraintEqualToAnchor:rangeCard.leadingAnchor constant:16],
        [modeTitle.topAnchor constraintEqualToAnchor:range.bottomAnchor constant:20], [modeTitle.leadingAnchor constraintEqualToAnchor:rangeCard.leadingAnchor constant:16], [self.modeControl.topAnchor constraintEqualToAnchor:modeTitle.bottomAnchor constant:10], [self.modeControl.leadingAnchor constraintEqualToAnchor:rangeCard.leadingAnchor constant:16], [self.modeControl.trailingAnchor constraintEqualToAnchor:rangeCard.trailingAnchor constant:-16],
        [hint.topAnchor constraintEqualToAnchor:self.modeControl.bottomAnchor constant:12], [hint.leadingAnchor constraintEqualToAnchor:rangeCard.leadingAnchor constant:16], [hint.trailingAnchor constraintEqualToAnchor:rangeCard.trailingAnchor constant:-16],
        [self.statusLabel.topAnchor constraintEqualToAnchor:hint.bottomAnchor constant:10], [self.statusLabel.leadingAnchor constraintEqualToAnchor:hint.leadingAnchor], [self.statusLabel.trailingAnchor constraintEqualToAnchor:hint.trailingAnchor], [self.statusLabel.bottomAnchor constraintEqualToAnchor:rangeCard.bottomAnchor constant:-16],
        [save.topAnchor constraintEqualToAnchor:rangeCard.bottomAnchor constant:22], [save.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    ]];
}

- (UITextField *)numberFieldWithText:(NSString *)text placeholder:(NSString *)placeholder {
    UITextField *field = [[UITextField alloc] init]; field.text = text; field.placeholder = placeholder; field.keyboardType = UIKeyboardTypeNumberPad; field.textAlignment = NSTextAlignmentCenter; field.borderStyle = UITextBorderStyleRoundedRect; field.translatesAutoresizingMaskIntoConstraints = NO; return field;
}

- (void)refreshStatus { self.statusLabel.text = [NSString stringWithFormat:@"Hook 状态：%@", AFStepSimulator.shared.hookStatusText]; }
- (void)close { [self.navigationController popViewControllerAnimated:YES]; }
- (void)toggleEnabled:(UISwitch *)sender {
    AFStepSimulator *simulator = AFStepSimulator.shared;
    [simulator updateEnabled:sender.on minStep:simulator.minStep maxStep:simulator.maxStep mode:simulator.mode];
    [self refreshStatus];
}
- (void)save {
    NSInteger minStep = self.minField.text.integerValue;
    NSInteger maxStep = self.maxField.text.integerValue;
    if (minStep < 1 || maxStep < minStep || maxStep > 1000000) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"范围无效" message:@"请输入 1 至 1,000,000 之间、且最大值不小于最小值的步数范围。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    AFStepSimulator *simulator = AFStepSimulator.shared;
    [simulator updateEnabled:simulator.enabled minStep:minStep maxStep:maxStep mode:(AFStepSimulatorMode)self.modeControl.selectedSegmentIndex];
    [self refreshStatus];
}

@end

@implementation AntForestSettingsPanel

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"功能设置";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"返回" style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    UIButton *schedule = [self settingsButtonWithTitle:@"定时收取设置" detail:@"管理每日固定收取时刻" icon:@"calendar" action:@selector(showSchedule)];
    UIButton *step = [self settingsButtonWithTitle:@"步数模拟设置（测试）" detail:@"独立配置支付宝可见步数" icon:@"figure.walk" action:@selector(showStepSimulator)];
    UIButton *water = [self settingsButtonWithTitle:@"好友浇水设置" detail:@"选择好友、克数与定时任务" icon:@"drop.fill" action:@selector(showWater)];
    UIButton *earn = [self settingsButtonWithTitle:@"赚能量（打地鼠玩法）" detail:@"手动进入活动后自动点击好友头像" icon:@"hand.tap.fill" action:nil];
    UISwitch *earnSwitch = [[UISwitch alloc] init]; earnSwitch.on = AntForestManager.sharedInstance.enableAutoEarn; earnSwitch.translatesAutoresizingMaskIntoConstraints = NO; [earnSwitch addTarget:self action:@selector(toggleAutoEarn:) forControlEvents:UIControlEventValueChanged]; [earn addSubview:earnSwitch];
    [self.view addSubview:schedule]; [self.view addSubview:step]; [self.view addSubview:water]; [self.view addSubview:earn];
    [NSLayoutConstraint activateConstraints:@[
        [schedule.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16], [schedule.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16], [schedule.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16], [schedule.heightAnchor constraintEqualToConstant:70],
        [step.topAnchor constraintEqualToAnchor:schedule.bottomAnchor constant:12], [step.leadingAnchor constraintEqualToAnchor:schedule.leadingAnchor], [step.trailingAnchor constraintEqualToAnchor:schedule.trailingAnchor], [step.heightAnchor constraintEqualToConstant:70],
        [water.topAnchor constraintEqualToAnchor:step.bottomAnchor constant:12], [water.leadingAnchor constraintEqualToAnchor:schedule.leadingAnchor], [water.trailingAnchor constraintEqualToAnchor:schedule.trailingAnchor], [water.heightAnchor constraintEqualToConstant:70],
        [earn.topAnchor constraintEqualToAnchor:water.bottomAnchor constant:12], [earn.leadingAnchor constraintEqualToAnchor:schedule.leadingAnchor], [earn.trailingAnchor constraintEqualToAnchor:schedule.trailingAnchor], [earn.heightAnchor constraintEqualToConstant:70],
        [earnSwitch.trailingAnchor constraintEqualToAnchor:earn.trailingAnchor constant:-18], [earnSwitch.centerYAnchor constraintEqualToAnchor:earn.centerYAnchor],
    ]];
}

- (UIButton *)settingsButtonWithTitle:(NSString *)title detail:(NSString *)detail icon:(NSString *)icon action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem]; button.backgroundColor = UIColor.systemBackgroundColor; button.layer.cornerRadius = 16; button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft; button.translatesAutoresizingMaskIntoConstraints = NO; if (action) [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    UIImageView *image = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:icon]]; image.tintColor = [UIColor colorWithRed:0.07 green:0.31 blue:0.18 alpha:1.0]; image.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *titleLabel = [[UILabel alloc] init]; titleLabel.text = title; titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]; titleLabel.textColor = UIColor.labelColor; titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *detailLabel = [[UILabel alloc] init]; detailLabel.text = detail; detailLabel.font = [UIFont systemFontOfSize:13]; detailLabel.textColor = UIColor.secondaryLabelColor; detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageView *chevron = action ? [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]] : nil; chevron.tintColor = UIColor.systemGray3Color; chevron.translatesAutoresizingMaskIntoConstraints = NO;
    [button addSubview:image]; [button addSubview:titleLabel]; [button addSubview:detailLabel]; if (chevron) [button addSubview:chevron];
    [NSLayoutConstraint activateConstraints:@[
        [image.leadingAnchor constraintEqualToAnchor:button.leadingAnchor constant:18], [image.centerYAnchor constraintEqualToAnchor:button.centerYAnchor], [image.widthAnchor constraintEqualToConstant:22], [image.heightAnchor constraintEqualToConstant:22],
        [titleLabel.topAnchor constraintEqualToAnchor:button.topAnchor constant:14], [titleLabel.leadingAnchor constraintEqualToAnchor:image.trailingAnchor constant:12],
        [detailLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:5], [detailLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
    ]];
    if (chevron) [NSLayoutConstraint activateConstraints:@[[chevron.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-18], [chevron.centerYAnchor constraintEqualToAnchor:button.centerYAnchor]]];
    return button;
}

- (void)showSchedule { [self.navigationController pushViewController:[[AntForestSchedulePanel alloc] init] animated:YES]; }
- (void)showStepSimulator { [self.navigationController pushViewController:[[AntForestStepSimulatorPanel alloc] init] animated:YES]; }
- (void)showWater { [self.navigationController pushViewController:[[AntForestWaterPanel alloc] init] animated:YES]; }
- (void)toggleAutoEarn:(UISwitch *)sender { AntForestManager.sharedInstance.enableAutoEarn = sender.on; [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:@"enableAutoEarn"]; [AntForestManager.sharedInstance recordStage:[NSString stringWithFormat:@"收取 · 赚能量（打地鼠玩法）已%@", sender.on ? @"开启" : @"关闭"]]; }
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

@end

@implementation AntForestLogPanel

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.97 green:0.98 blue:0.99 alpha:1.0];

    UIView *grabber = [[UIView alloc] init];
    grabber.backgroundColor = [UIColor systemGray3Color];
    grabber.layer.cornerRadius = 3;
    grabber.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *titleIcon = [self iconWithName:@"leaf.fill" size:22];
    titleIcon.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *title = [[UILabel alloc] init];
    title.text = @"收取记录";
    title.font = [UIFont boldSystemFontOfSize:22];
    title.textColor = [UIColor colorWithRed:0.09 green:0.23 blue:0.16 alpha:1.0];
    title.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *clearButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [clearButton setTitle:@"清空日志" forState:UIControlStateNormal];
    clearButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [clearButton addTarget:self action:@selector(clearLogs) forControlEvents:UIControlEventTouchUpInside];
    clearButton.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *copyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [copyButton setImage:[UIImage systemImageNamed:@"doc.on.doc"] forState:UIControlStateNormal];
    copyButton.accessibilityLabel = @"复制日志";
    [copyButton addTarget:self action:@selector(copyDiagnosticLogs:) forControlEvents:UIControlEventTouchUpInside];
    copyButton.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *settingsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [settingsButton setImage:[UIImage systemImageNamed:@"gearshape"] forState:UIControlStateNormal];
    settingsButton.accessibilityLabel = @"功能设置";
    [settingsButton addTarget:self action:@selector(showSettings) forControlEvents:UIControlEventTouchUpInside];
    settingsButton.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *stats = [[UIStackView alloc] init];
    stats.axis = UILayoutConstraintAxisHorizontal;
    stats.distribution = UIStackViewDistributionFill;
    stats.alignment = UIStackViewAlignmentCenter;
    stats.translatesAutoresizingMaskIntoConstraints = NO;
    self.todayLabel = [self statLabelWithPrefix:@"今日\n"];
    self.totalLabel = [self statLabelWithPrefix:@"累计\n"];
    UIStackView *todayStat = [self statWithIcon:@"tray.full.fill" label:self.todayLabel];
    UIStackView *totalStat = [self statWithIcon:@"house.fill" label:self.totalLabel];
    totalStat.layoutMargins = UIEdgeInsetsMake(0, 20, 0, 0);
    totalStat.layoutMarginsRelativeArrangement = YES;
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
    autoLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    UISwitch *autoSwitch = [[UISwitch alloc] init];
    autoSwitch.on = ((AntForestManager *)[AntForestManager sharedInstance]).enableAutoCollect;
    [autoSwitch addTarget:self action:@selector(toggleAutoCollect:) forControlEvents:UIControlEventValueChanged];
    UIStackView *autoLeading = [[UIStackView alloc] initWithArrangedSubviews:@[autoIcon, autoLabel]];
    autoLeading.spacing = 10;
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

    UIView *selfIcon = [self iconWithName:@"person.fill" size:24];
    UILabel *selfLabel = [[UILabel alloc] init];
    selfLabel.text = @"收取自己能量";
    selfLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    UISwitch *selfSwitch = [[UISwitch alloc] init];
    selfSwitch.on = [AntForestManager sharedInstance].enableSelfCollect;
    [selfSwitch addTarget:self action:@selector(toggleSelfCollect:) forControlEvents:UIControlEventValueChanged];
    UIStackView *selfLeading = [[UIStackView alloc] initWithArrangedSubviews:@[selfIcon, selfLabel]];
    selfLeading.spacing = 10; selfLeading.alignment = UIStackViewAlignmentCenter;
    UIStackView *selfRow = [[UIStackView alloc] initWithArrangedSubviews:@[selfLeading, selfSwitch]];
    selfRow.alignment = UIStackViewAlignmentCenter; selfRow.distribution = UIStackViewDistributionEqualSpacing; selfRow.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *rainIcon = [self iconWithName:@"cloud.rain.fill" size:24];
    UILabel *rainLabel = [[UILabel alloc] init];
    rainLabel.text = @"自动能量雨";
    rainLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    UISwitch *rainSwitch = [[UISwitch alloc] init];
    rainSwitch.on = ((AntForestManager *)[AntForestManager sharedInstance]).enableAutoRain;
    [rainSwitch addTarget:self action:@selector(toggleAutoRain:) forControlEvents:UIControlEventValueChanged];
    UIStackView *rainLeading = [[UIStackView alloc] initWithArrangedSubviews:@[rainIcon, rainLabel]];
    rainLeading.spacing = 10;
    rainLeading.alignment = UIStackViewAlignmentCenter;
    UIStackView *rainRow = [[UIStackView alloc] initWithArrangedSubviews:@[rainLeading, rainSwitch]];
    rainRow.alignment = UIStackViewAlignmentCenter;
    rainRow.distribution = UIStackViewDistributionEqualSpacing;
    rainRow.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *loopIcon = [self iconWithName:@"clock.arrow.circlepath" size:24];
    UILabel *loopLabel = [[UILabel alloc] init];
    loopLabel.text = @"后台循环";
    loopLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    UIButton *intervalButton = [UIButton buttonWithType:UIButtonTypeSystem];
    intervalButton.layer.borderWidth = 1; intervalButton.layer.borderColor = UIColor.systemGray5Color.CGColor; intervalButton.layer.cornerRadius = 10;
    intervalButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [intervalButton addTarget:self action:@selector(showIntervalSettings) forControlEvents:UIControlEventTouchUpInside];
    self.intervalButton = intervalButton;
    [self updateIntervalLabel];
    UISwitch *loopSwitch = [[UISwitch alloc] init];
    loopSwitch.on = [AntForestManager sharedInstance].enableBackgroundLoop;
    [loopSwitch addTarget:self action:@selector(toggleBackgroundLoop:) forControlEvents:UIControlEventValueChanged];
    UIStackView *loopLeading = [[UIStackView alloc] initWithArrangedSubviews:@[loopIcon, loopLabel]];
    loopLeading.spacing = 10; loopLeading.alignment = UIStackViewAlignmentCenter;
    [intervalButton.widthAnchor constraintEqualToConstant:70].active = YES;
    UIStackView *loopControls = [[UIStackView alloc] initWithArrangedSubviews:@[intervalButton, loopSwitch]];
    loopControls.spacing = 8; loopControls.alignment = UIStackViewAlignmentCenter;
    UIStackView *loopRow = [[UIStackView alloc] initWithArrangedSubviews:@[loopLeading, loopControls]];
    loopRow.alignment = UIStackViewAlignmentCenter; loopRow.distribution = UIStackViewDistributionEqualSpacing; loopRow.translatesAutoresizingMaskIntoConstraints = NO;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 60;
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
    UIView *divider0 = [[UIView alloc] init]; divider0.backgroundColor = UIColor.systemGray5Color; divider0.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *divider1 = [[UIView alloc] init]; divider1.backgroundColor = UIColor.systemGray5Color; divider1.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *divider2 = [[UIView alloc] init]; divider2.backgroundColor = UIColor.systemGray5Color; divider2.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:grabber];
    [self.view addSubview:titleIcon];
    [self.view addSubview:title];
    [self.view addSubview:settingsButton];
    [self.view addSubview:copyButton];
    [self.view addSubview:clearButton];
    [self.view addSubview:stats];
    [self.view addSubview:card];
    [self.view addSubview:self.tableView];
    [card addSubview:autoRow];
    [card addSubview:selfRow];
    [card addSubview:rainRow];
    [card addSubview:loopRow];
    [card addSubview:divider0]; [card addSubview:divider1]; [card addSubview:divider2];
    [NSLayoutConstraint activateConstraints:@[
        [grabber.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:10],
        [grabber.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [grabber.widthAnchor constraintEqualToConstant:44], [grabber.heightAnchor constraintEqualToConstant:6],
        [titleIcon.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [titleIcon.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [titleIcon.widthAnchor constraintEqualToConstant:30], [titleIcon.heightAnchor constraintEqualToConstant:30],
        [title.topAnchor constraintEqualToAnchor:grabber.bottomAnchor constant:18],
        [title.leadingAnchor constraintEqualToAnchor:titleIcon.trailingAnchor constant:10],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:settingsButton.leadingAnchor constant:-8],
        [settingsButton.trailingAnchor constraintEqualToAnchor:copyButton.leadingAnchor constant:-10],
        [settingsButton.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
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
        [selfRow.topAnchor constraintEqualToAnchor:autoRow.bottomAnchor constant:10],
        [selfRow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [selfRow.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [divider0.topAnchor constraintEqualToAnchor:selfRow.topAnchor constant:-5],
        [divider0.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16], [divider0.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16], [divider0.heightAnchor constraintEqualToConstant:1],
        [rainRow.topAnchor constraintEqualToAnchor:selfRow.bottomAnchor constant:10],
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
        [self.tableView.topAnchor constraintEqualToAnchor:card.bottomAnchor constant:8],
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
        UIView *badge = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
        badge.backgroundColor = [UIColor colorWithRed:0.90 green:0.95 blue:0.91 alpha:1.0];
        badge.layer.cornerRadius = 15;
        imageView.frame = CGRectMake(8, 8, 14, 14);
        [badge addSubview:imageView];
        [badge.widthAnchor constraintEqualToConstant:30].active = YES;
        [badge.heightAnchor constraintEqualToConstant:30].active = YES;
        return badge;
    }
    return imageView;
}

- (UILabel *)statLabelWithPrefix:(NSString *)prefix {
    UILabel *label = [[UILabel alloc] init];
    label.numberOfLines = 2;
    label.font = [UIFont monospacedDigitSystemFontOfSize:18 weight:UIFontWeightBold];
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.72;
    label.textColor = [UIColor colorWithRed:0.09 green:0.23 blue:0.16 alpha:1.0];
    return label;
}

- (UIStackView *)statWithIcon:(NSString *)icon label:(UILabel *)label {
    UIView *badge = [self iconWithName:icon size:24];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[badge, label]];
    stack.spacing = 8;
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
        if (!manager.enableBackgroundLoop && manager.jsBridge) [manager autoCollectBubbles];
    } else {
        [manager stopAutoCollectTimer];
        [manager.scheduledCollectTimer invalidate];
        manager.scheduledCollectTimer = nil;
    }
}

- (void)toggleSelfCollect:(UISwitch *)sender {
    AntForestManager *manager = AntForestManager.sharedInstance;
    manager.enableSelfCollect = sender.on;
    [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:@"enableSelfCollect"];
    [manager recordStage:[NSString stringWithFormat:@"收取 · 收取自己能量已%@", sender.on ? @"开启" : @"关闭"]];
    if (sender.on && manager.enableAutoCollect && manager.jsBridge && manager.myUserId.length) {
        [manager recordStage:@"收取 · 请求本人首页（含赠能）"];
        [manager queryMyBubbles];
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

- (void)showSettings {
    AntForestSettingsPanel *settings = [[AntForestSettingsPanel alloc] init];
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
    NSString *header = [NSString stringWithFormat:@"AntForestPort 收取日志\n导出时间：%@\n配置：自动收取=%@，收取自己=%@，自动能量雨=%@，赚能量（打地鼠玩法）=%@，后台循环=%@，循环间隔=%ld 秒，定时收取=%@，打开蚂蚁森林自动浇水=%@，定时自动浇水=%@（%ld g，%lu 位好友），步数模拟=%@\n统计：今日=%ld g，累计=%ld g，日志条目=%lu\n\n",
                      getCurrentDateTimeString(), manager.enableAutoCollect ? @"开" : @"关", manager.enableSelfCollect ? @"开" : @"关", manager.enableAutoRain ? @"开" : @"关", manager.enableAutoEarn ? @"开" : @"关", manager.enableBackgroundLoop ? @"开" : @"关", (long)manager.collectInterval, manager.enableScheduledCollect ? @"开" : @"关", manager.enableWaterOnLaunch ? @"开" : @"关", manager.enableAutoWater ? @"开" : @"关", (long)manager.waterGrams, (unsigned long)manager.waterFriendIds.count, AFStepSimulator.shared.enabled ? @"开" : @"关", (long)manager.todayCollectedEnergy, (long)manager.totalCollectedEnergy, (unsigned long)records.count];
    UIPasteboard.generalPasteboard.string = records.count ? [header stringByAppendingString:[records componentsJoinedByString:@"\n\n"]] : [header stringByAppendingString:@"没有可复制的收取日志"];
    [sender setImage:[UIImage systemImageNamed:@"checkmark"] forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [sender setImage:[UIImage systemImageNamed:@"doc.on.doc"] forState:UIControlStateNormal];
    });
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return ((AntForestManager *)[AntForestManager sharedInstance]).logRecord.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"LogCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    UIImageView *icon;
    UILabel *label;
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle.fill"]];
        icon.tag = 1;
        icon.tintColor = [UIColor colorWithRed:0.07 green:0.31 blue:0.18 alpha:1.0];
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        label = [[UILabel alloc] init];
        label.tag = 2;
        label.font = [UIFont systemFontOfSize:14];
        label.numberOfLines = 0;
        label.lineBreakMode = NSLineBreakByWordWrapping;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:icon];
        [cell.contentView addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:20],
            [icon.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:24], [icon.heightAnchor constraintEqualToConstant:24],
            [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:12],
            [label.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8],
            [label.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-20],
            [label.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
        ]];
    } else {
        icon = [cell.contentView viewWithTag:1];
        label = [cell.contentView viewWithTag:2];
    }
    NSArray *logs = ((AntForestManager *)[AntForestManager sharedInstance]).logRecord;
    label.text = logs[logs.count - indexPath.row - 1];
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
    manager.enableSelfCollect = [defaults objectForKey:@"enableSelfCollect"] ? [defaults boolForKey:@"enableSelfCollect"] : YES;
    manager.enableAutoRain = [defaults objectForKey:@"enableAutoRain"] ? [defaults boolForKey:@"enableAutoRain"] : manager.enableAutoCollect;
    manager.enableAutoEarn = [defaults objectForKey:@"enableAutoEarn"] ? [defaults boolForKey:@"enableAutoEarn"] : YES;
    manager.enableBackgroundLoop = [defaults objectForKey:@"enableBackgroundLoop"] ? [defaults boolForKey:@"enableBackgroundLoop"] : YES;
    manager.enableScheduledCollect = [defaults boolForKey:@"enableScheduledCollect"];
    manager.scheduledTimes = [defaults arrayForKey:@"scheduledCollectTimes"] ?: @[];
    manager.enableAutoWater = [defaults boolForKey:@"enableAutoWater"];
    manager.enableWaterOnLaunch = [defaults boolForKey:@"enableWaterOnLaunch"];
    manager.waterReminderEnabled = [defaults objectForKey:@"waterReminderEnabled"] ? [defaults boolForKey:@"waterReminderEnabled"] : YES;
    NSInteger waterEnergyId = [defaults integerForKey:@"waterEnergyId"];
    manager.waterEnergyId = (waterEnergyId >= 39 && waterEnergyId <= 42) ? waterEnergyId : 39;
    manager.waterFriendIds = [defaults arrayForKey:@"waterFriendIds"] ?: @[];
    manager.waterScheduledTimes = [defaults arrayForKey:@"waterScheduledTimes"] ?: @[];
    manager.collectInterval = MAX(1, [defaults integerForKey:@"backgroundIntervalMinutes"] ?: 5) * 60;
    [manager recordStage:[NSString stringWithFormat:@"诊断 · 初始化：自动=%d，循环=%d", manager.enableAutoCollect, manager.enableBackgroundLoop]];
    if (manager.enableAutoCollect && manager.enableBackgroundLoop) [manager startAutoCollectTimerWithInterval:manager.collectInterval];
    if (manager.enableAutoCollect && manager.enableScheduledCollect) [manager startScheduledCollectTimer];
    if (manager.enableAutoWater) [manager startScheduledWaterTimer];
}

static void portViewDidLoad(id self, SEL _cmd) {
    originalViewDidLoad(self, _cmd);
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ initializeManager(); });
}

static void portViewDidAppear(id self, SEL _cmd, BOOL animated) {
    originalViewDidAppear(self, _cmd, animated);
    [[AFStepSimulator shared] installAvailableHooks];
    NSURL *url = [self respondsToSelector:@selector(url)] ? [self url] : nil;
    AntForestManager *manager = [AntForestManager sharedInstance];
    BOOL earnEnergy = isEarnEnergyURL(url);
    BOOL forestHome = isForestHomeURL(url) && !earnEnergy;
    id pageBridge = forestHome ? forestBridgeFromController(self) : nil;
    if (pageBridge && manager.jsBridge != pageBridge) {
        manager.jsBridge = pageBridge;
        [manager recordStage:@"诊断 · 已绑定森林首页 H5 Bridge"];
    }
    if (forestHome) [manager recordStage:[NSString stringWithFormat:@"诊断 · 森林首页出现：桥接=%d", manager.jsBridge != nil]];
    BOOL revealLeaf = forestHome && shouldRevealLeafOnNextForestAppearance;
    if (revealLeaf) shouldRevealLeafOnNextForestAppearance = NO;
    if (forestHome && (manager.enableWaterOnLaunch || (manager.enableAutoCollect && manager.enableBackgroundLoop))) startForestHomeWhenBridgeReady(self);
    if (forestHome) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            installGiftFullProbe(self);
        });
    }
    if (isEnergyRainURL(url) && manager.enableAutoRain) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            installEnergyRainCollector(self);
        });
    }
    if (earnEnergy && manager.enableAutoEarn) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            installEarnEnergyCollector(self);
        });
    }
    addLogButton(self, revealLeaf);
}

static id portTransformResponseData(id self, SEL _cmd, id value) {
    AntForestManager *manager = [AntForestManager sharedInstance];
    if (isForestResponse(value)) {
        if (manager.jsBridge != self) {
            manager.jsBridge = self;
            [manager recordStage:@"诊断 · 已绑定森林响应 H5 Bridge"];
        }
    }
    [manager matchFriendIdAndBubbles:value];
    if (manager.enableAutoCollect && manager.enableSelfCollect && isMyHomeResponse(value, manager)) {
        // The canvas may still be drawing when the native home response arrives.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(700 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{ tryAutoCollectWaterGift(); });
    }
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
            [[AFStepSimulator shared] installAvailableHooks];
        }];
        [[AFStepSimulator shared] installAvailableHooks];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [[AFStepSimulator shared] installAvailableHooks]; });
        Class webController = NSClassFromString(@"H5WebViewController");
        class_addMethod(webController, @selector(antforestHandlePan:), (IMP)handleButtonPan, "v@:@");
        BOOL viewHooked = hookMethod(webController, @selector(viewDidLoad), (IMP)portViewDidLoad, (IMP *)&originalViewDidLoad);
        BOOL appearanceHooked = hookMethod(webController, @selector(viewDidAppear:), (IMP)portViewDidAppear, (IMP *)&originalViewDidAppear);
        BOOL responseHooked = hookMethod(NSClassFromString(@"PSDJsBridge"), @selector(transformResponseData:), (IMP)portTransformResponseData, (IMP *)&originalTransformResponseData);
        NSLog(@"[AntForestPort] installed: view=%d appearance=%d response=%d", viewHooked, appearanceHooked, responseHooked);
    }
}
