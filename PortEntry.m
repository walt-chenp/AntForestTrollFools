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
static void (*originalUpdateBridgeReadyStatus)(id, SEL, id);
static NSTimeInterval lastWaterGiftTapAt;
static const void *GiftFullProbeKey = &GiftFullProbeKey;

static id findWebViewInController(id controller);
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
static const void *ForestHomeBridgeKey = &ForestHomeBridgeKey;
static BOOL shouldRevealLeafOnNextForestAppearance = YES;

static BOOL isEnergyRain(NSURL *url, id controller) {
    if (controller) {
        for (NSString *sel in @[@"appId", @"appID", @"currentAppId", @"appName", @"name", @"title", @"defaultTitle"]) {
            SEL s = NSSelectorFromString(sel);
            if ([controller respondsToSelector:s]) {
                id val = ((id (*)(id, SEL))objc_msgSend)(controller, s);
                NSString *str = [val isKindOfClass:NSString.class] ? val : [val description];
                if ([str containsString:@"68687791"] || [str containsString:@"68687130"] || [str containsString:@"能量雨"]) {
                    return YES;
                }
            }
        }
    }
    if (url) {
        NSString *text = [url.absoluteString lowercaseString];
        if ([text containsString:@"energyrain"] || [text containsString:@"energy-rain"] || [text containsString:@"energy_rain"] ||
            [text containsString:@"68687791"] || [text containsString:@"68687130"] ||
            [text containsString:@"/p/c/18031y38qhq8"] || [text containsString:@"rain.html"] || [text containsString:@"energyrainhome"]) {
            return YES;
        }
    }
    return NO;
}

static BOOL isEnergyRainURL(NSURL *url) {
    return isEnergyRain(url, nil);
}

static BOOL isForestHomeURL(NSURL *url) {
    if (!url) return NO;
    if (isEnergyRainURL(url)) return NO;
    NSString *str = url.absoluteString ?: @"";
    if ([str containsString:@"exchange.html"] || [str containsString:@"listRank.html"] || [str containsString:@"cert.html"]) return NO;
    return [str containsString:@"180020010001247580"] || ([str containsString:@"60000002"] && [str containsString:@"home.html"]);
}

static BOOL isSelfForestHomeURL(NSURL *url) {
    if (!isForestHomeURL(url)) return NO;
    NSString *urlString = url.absoluteString ?: @"";
    if ([urlString containsString:@"userId="]) {
        NSString *myUid = [[AntForestManager sharedInstance] myUserId];
        if (myUid.length && [urlString containsString:[NSString stringWithFormat:@"userId=%@", myUid]]) {
            return YES;
        }
        return NO; // 包含非本人 userId 说明是好友森林页面
    }
    return YES; // 无 userId 参数即本人森林首页
}

static BOOL isEarnEnergyURL(NSURL *url) {
    NSString *text = [url.absoluteString lowercaseString];
    return [text containsString:@"forcewhackmole=y"] || [text containsString:@"whackmole"] || [text containsString:@"earnenergy"] || [text containsString:@"earn_energy"] || [text containsString:@"earn.html"] || [text containsString:@"60000002.h5app.alipay.com"];
}

static BOOL isLotteryURL(NSURL *url) {
    if (!url) return NO;
    NSString *text = [url.absoluteString lowercaseString];
    return [text containsString:@"180020010001279274"] ||
           [text containsString:@"lotterymachine"] ||
           [text containsString:@"antforestdraw"];
}

static BOOL isRewardTaskURL(NSURL *url) {
    if (!url) return NO;
    if (isEnergyRainURL(url)) return NO;
    if (isForestHomeURL(url)) return NO;
    if (isLotteryURL(url)) return NO;
    NSString *text = [url.absoluteString lowercaseString];
    return [text containsString:@"lottery"] ||
           [text containsString:@"draw"] ||
           [text containsString:@"vitality"] ||
           [text containsString:@"exchange.html"];
}

static BOOL isOceanURL(NSURL *url) {
    if (!url) return NO;
    NSString *text = [url.absoluteString lowercaseString];
    return [text containsString:@"2021003115672468"] || [text containsString:@"antocean"];
}

static BOOL isAIFishURL(NSURL *url) {
    if (!url) return NO;
    NSString *text = [url.absoluteString lowercaseString];
    return [text containsString:@"180020010001290531"] || [text containsString:@"aifish"] || [text containsString:@"antaifish"];
}

static BOOL isFarmURL(NSURL *url) {
    if (!url) return NO;
    if ([AntForestManager isManorURL:url]) return NO;
    NSString *text = [url.absoluteString lowercaseString];
    return [text containsString:@"alipayfarm"] ||
           [text containsString:@"tmfarm"] ||
           [text containsString:@"babafarm"] ||
           [text containsString:@"orchard"] ||
           [text containsString:@"180020010001263018"] ||
           [text containsString:@"68687599"];
}

static id rewardBridgeFromController(id controller) {
    if (!controller) return nil;
    NSMutableArray *objects = [NSMutableArray arrayWithObject:controller];
    for (NSString *name in @[ @"contentView", @"rvkContentView" ]) {
        SEL selector = NSSelectorFromString(name);
        if ([controller respondsToSelector:selector]) {
            id contentView = ((id (*)(id, SEL))objc_msgSend)(controller, selector);
            if (contentView) [objects addObject:contentView];
        }
    }
    for (id object in objects) {
        for (NSString *name in @[ @"jsBridge", @"bridge" ]) {
            SEL selector = NSSelectorFromString(name);
            if (![object respondsToSelector:selector]) continue;
            id bridge = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if (bridge && [bridge respondsToSelector:@selector(_doFlushMessageQueue:url:)]) return bridge;
        }
    }
    return nil;
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

static void startSilentRewardContext(id forestController) {
    AntForestManager *manager = AntForestManager.sharedInstance;
    if (!manager.enableAutoRewardTasks) return;
    if (manager.rewardTaskBridge) {
        [manager queryVitalityTaskList];
        return;
    }
    id session = nil;
    for (NSString *name in @[ @"rvkSession", @"session" ]) {
        SEL selector = NSSelectorFromString(name);
        if ([forestController respondsToSelector:selector]) {
            session = ((id (*)(id, SEL))objc_msgSend)(forestController, selector);
            if (session) break;
        }
    }
    SEL daemonSelector = NSSelectorFromString(@"daemonView");
    id daemonView = [session respondsToSelector:daemonSelector] ? ((id (*)(id, SEL))objc_msgSend)(session, daemonSelector) : nil;
    id bridge = rewardBridgeFromController(daemonView) ?: forestBridgeFromController(forestController) ?: manager.jsBridge;
    BOOL ready = bridge && (![bridge respondsToSelector:@selector(isBridgeReady)] || ((BOOL (*)(id, SEL))objc_msgSend)(bridge, @selector(isBridgeReady)));
    NSLog(@"[AntForestPort][RewardSessionProbe] controller=%@ session=%@ daemon=%@ bridge=%@ ready=%d", forestController ? NSStringFromClass([forestController class]) : @"nil", session ? NSStringFromClass([session class]) : @"nil", daemonView ? NSStringFromClass([daemonView class]) : @"nil", bridge ? NSStringFromClass([bridge class]) : @"nil", ready);
    [manager recordStage:[NSString stringWithFormat:@"首页后台：会话探针 session=%@ daemon=%@ bridge=%d ready=%d", session ? NSStringFromClass([session class]) : @"无", daemonView ? NSStringFromClass([daemonView class]) : @"无", bridge != nil, ready]];
    if (bridge) {
        manager.rewardTaskBridge = bridge;
        [manager recordStage:@"首页后台：后台会话奖励桥接已就绪"];
        [manager queryVitalityTaskList];
    }
}

static id forestControllerForBridge(id bridge) {
    id contentView = [bridge respondsToSelector:@selector(contentView)] ? ((id (*)(id, SEL))objc_msgSend)(bridge, @selector(contentView)) : nil;
    for (NSString *name in @[ @"rvkViewController", @"psdViewController" ]) {
        SEL selector = NSSelectorFromString(name);
        if ([contentView respondsToSelector:selector]) return ((id (*)(id, SEL))objc_msgSend)(contentView, selector);
    }
    return nil;
}

static void finishForestHomeStart(id controller, id bridge) {
    if (!controller || !bridge || !objc_getAssociatedObject(controller, ForestHomeStartKey)) return;
    AntForestManager *manager = AntForestManager.sharedInstance;
    manager.jsBridge = bridge;
    objc_setAssociatedObject(controller, ForestHomeStartKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [manager recordStage:@"收取 · 森林首页 H5 Bridge 已就绪"];
    startSilentRewardContext(controller);
    if (manager.enableWaterOnLaunch) [manager startLaunchWateringThenCollect];
    else if (manager.enableAutoCollect) {
        if (manager.isScanRunning) {
            [manager recordStage:@"诊断 · 首页桥接就绪：前一轮扫描执行中，跳过重复启动"];
            return;
        }
        [manager recordStage:@"收取 · 首页桥接就绪，立即补跑"];
        [manager autoCollectBubbles];
    }
}

static void startForestHomeWhenBridgeReady(id controller) {
    if (objc_getAssociatedObject(controller, ForestHomeStartKey)) return;
    objc_setAssociatedObject(controller, ForestHomeStartKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __unsafe_unretained id weakController = controller;
    __block NSUInteger attempts = 0;
    __block void (^waitForBridge)(void);
    waitForBridge = ^{
        id currentController = weakController;
        NSURL *url = [currentController respondsToSelector:@selector(url)] ? [currentController url] : nil;
        if (!currentController || !isForestHomeURL(url) || isEarnEnergyURL(url)) { waitForBridge = nil; return; }
        id bridge = forestBridgeFromController(currentController) ?: objc_getAssociatedObject(currentController, ForestHomeBridgeKey);
        if (bridge) {
            finishForestHomeStart(currentController, bridge);
            waitForBridge = nil;
            return;
        }
        if (++attempts >= 10) {
            objc_setAssociatedObject(currentController, ForestHomeStartKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [AntForestManager.sharedInstance recordStage:@"收取 · 森林首页 H5 Bridge 等待超时"];
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
    BOOL hasBubbles = (response[@"bubbles"] || response[@"wateringBubbles"] || data[@"bubbles"] || data[@"wateringBubbles"]);
    BOOL hasUser = (response[@"userBaseInfo"] || response[@"loginUserBaseInfo"] || response[@"userEnergy"] || data[@"userBaseInfo"] || data[@"loginUserBaseInfo"] || data[@"userEnergy"] || data[@"combineHandlerVOMap"]);
    return (hasBubbles && hasUser) || data[@"totalDatas"] || data[@"friendRanking"] || data[@"myself"] || data[@"friendId"] || data[@"combineHandlerVOMap"];
}

static BOOL isMyHomeResponse(id value, AntForestManager *manager) {
    NSDictionary *response = [value isKindOfClass:NSDictionary.class] ? value : nil;
    if (!response) return NO;
    NSDictionary *resData = [response[@"resData"] isKindOfClass:NSDictionary.class] ? response[@"resData"] : response;
    if (response[@"loginUserBaseInfo"] && !response[@"userBaseInfo"]) return YES;
    NSDictionary *base = [response[@"loginUserBaseInfo"] isKindOfClass:NSDictionary.class] ? response[@"loginUserBaseInfo"] :
                         ([response[@"userBaseInfo"] isKindOfClass:NSDictionary.class] ? response[@"userBaseInfo"] :
                         ([resData[@"userBaseInfo"] isKindOfClass:NSDictionary.class] ? resData[@"userBaseInfo"] :
                         ([resData[@"combineHandlerVOMap"][@"userInfo"][@"userBaseInfo"] isKindOfClass:NSDictionary.class] ? resData[@"combineHandlerVOMap"][@"userInfo"][@"userBaseInfo"] : nil)));
    return manager.myUserId.length && [base[@"userId"] isEqualToString:manager.myUserId];
}

static void tryAutoCollectWaterGift(void) {
    // 彻底停用 Canvas 盲点坐标触摸，杜绝误触巡护动物跳转保护地小程序(68687842)或误触庄园
    // 巡护动物能量已 100% 由 matchFriendIdAndBubbles 提取 propId/animalId 走原生 RPC 安全精准收割
    [[AntForestManager sharedInstance] receiveAnimalPartnerEnergy];
}

static id findWebViewRecursively(UIView *view, SEL evaluate) {
    if (!view) return nil;
    if ([view respondsToSelector:evaluate]) return view;
    for (UIView *sub in view.subviews) {
        id found = findWebViewRecursively(sub, evaluate);
        if (found) return found;
    }
    return nil;
}

static id findWebViewInController(id controller) {
    if (!controller) return nil;
    SEL evaluate = @selector(evaluateJavaScript:completionHandler:);
    for (NSString *selName in @[@"webView", @"psdContentView", @"h5WebView", @"contentView", @"rvkContentView"]) {
        SEL s = NSSelectorFromString(selName);
        if ([controller respondsToSelector:s]) {
            id obj = ((id (*)(id, SEL))objc_msgSend)(controller, s);
            if (obj && [obj respondsToSelector:evaluate]) return obj;
            if ([obj isKindOfClass:UIView.class]) {
                id found = findWebViewRecursively((UIView *)obj, evaluate);
                if (found) return found;
            }
        }
    }
    if ([controller respondsToSelector:@selector(view)]) {
        UIView *v = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(view));
        if ([v isKindOfClass:UIView.class]) {
            id found = findWebViewRecursively(v, evaluate);
            if (found) return found;
        }
    }
    return nil;
}

static NSURL *urlFromController(id controller) {
    if (!controller) return nil;
    if ([controller respondsToSelector:@selector(curUrl)]) {
        id u = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(curUrl));
        if ([u isKindOfClass:NSURL.class]) return u;
        if ([u isKindOfClass:NSString.class]) return [NSURL URLWithString:u];
    }
    if ([controller respondsToSelector:@selector(url)]) {
        id u = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(url));
        if ([u isKindOfClass:NSURL.class]) return u;
        if ([u isKindOfClass:NSString.class]) return [NSURL URLWithString:u];
    }
    if ([controller respondsToSelector:@selector(currentUrl)]) {
        id u = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(currentUrl));
        if ([u isKindOfClass:NSURL.class]) return u;
        if ([u isKindOfClass:NSString.class]) return [NSURL URLWithString:u];
    }
    id webView = findWebViewInController(controller);
    if (webView && [webView respondsToSelector:@selector(URL)]) {
        id u = ((id (*)(id, SEL))objc_msgSend)(webView, @selector(URL));
        if ([u isKindOfClass:NSURL.class]) return u;
    }
    return nil;
}

static void installEnergyRainCollector(id controller) {
    static const void *collectorKey = &collectorKey;
    if (objc_getAssociatedObject(controller, collectorKey)) return;
    
    id webView = [controller respondsToSelector:@selector(webView)] ? ((id (*)(id, SEL))objc_msgSend)(controller, @selector(webView)) : nil;
    if (!webView) webView = findWebViewInController(controller);
    SEL evaluate = @selector(evaluateJavaScript:completionHandler:);
    if (![webView respondsToSelector:evaluate]) {
        NSLog(@"[AntForestRain] collector unavailable");
        return;
    }
    objc_setAssociatedObject(controller, collectorKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    NSString *script = @"(()=>{const c=document.querySelector('canvas');if(!c)return 'canvas unavailable';if(window.__antForestRainCollectorHook)return 'already installed';window.__antForestRainCollectorHook=1;const state={frames:{}},rects=d=>{try{const b=d instanceof ArrayBuffer?d:d.buffer;if(!b)return[];const o=d.byteOffset||0;if(o%4!==0)return[];const len=Math.floor(d.byteLength/4);if(len<20)return[];const f=new Float32Array(b,o,len),a=[];for(let i=0;i+19<f.length;i+=20){const xs=[f[i],f[i+5],f[i+10],f[i+15]],ys=[f[i+1],f[i+6],f[i+11],f[i+16]];if(xs.every(Number.isFinite)&&ys.every(Number.isFinite)){const x=Math.min(...xs),y=Math.min(...ys),w=Math.max(...xs)-x,h=Math.max(...ys)-y;if(w>0&&h>0)a.push({x,y,w,h})}}return a}catch(_){return[]}},event=(type,t,active)=>{try{let e;try{const touch=new Touch(t);e=new TouchEvent(type,{bubbles:true,cancelable:true,touches:active?[touch]:[],targetTouches:active?[touch]:[],changedTouches:[touch]})}catch(_){e=new Event(type,{bubbles:true,cancelable:true});Object.defineProperties(e,{touches:{value:active?[t]:[]},targetTouches:{value:active?[t]:[]},changedTouches:{value:[t]}})}c.dispatchEvent(e)}catch(_){}},tap=(x,y)=>{const t={identifier:Date.now()%1000000,target:c,clientX:x,clientY:y,pageX:x,pageY:y,screenX:x,screenY:y};event('touchstart',t,true);setTimeout(()=>event('touchend',t,false),12)},hook=P=>{if(!P)return;const f=P.bufferSubData;if(f){P.bufferSubData=function(target,offset,data,...v){try{if(c&&this.canvas===c&&data&&data.byteLength>=80){const now=rects(data);if(now&&now.length){const key=data.byteLength+':'+now.slice(0,2).map(q=>[q.x,q.y,q.w,q.h].map(Math.round).join(',')).join('/'),old=state.frames[key],time=Date.now();if(old&&old.boxes.length===now.length){now.forEach((q,i)=>{const r=old.boxes[i],dy=q.y-r.y,cx=q.x+q.w/2,cy=q.y+q.h/2;if(Math.abs(q.x-r.x)<5&&dy>.2&&dy<30&&q.w>=25&&q.w<=180&&q.h>=25&&q.h<=180&&cx>10&&cx<383&&cy>80&&cy<780&&time-(old.taps[i]||0)>400){old.taps[i]=time;setTimeout(()=>tap(cx,cy),0)}})}state.frames[key]={boxes:now,taps:old?old.taps:{}}}}}catch(_){}return f.call(this,target,offset,data,...v)}}};hook(window.WebGLRenderingContext&&WebGLRenderingContext.prototype);hook(window.WebGL2RenderingContext&&WebGL2RenderingContext.prototype);return 'installed'})()";
    
    void (*runJavaScript)(id, SEL, NSString *, void (^)(id, NSError *)) = (void *)objc_msgSend;
    runJavaScript(webView, evaluate, script, ^(id result, NSError *error) {
        NSLog(@"[AntForestRain] collector: %@%@", result ?: @"", error ? [NSString stringWithFormat:@" error=%@", error] : @"");
        if ([result isEqual:@"canvas unavailable"]) {
            objc_setAssociatedObject(controller, collectorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                installEnergyRainCollector(controller);
            });
        }
    });
}

@interface UITouch (PrivateSynthesis)
- (void)setWindow:(UIWindow *)window;
- (void)setView:(UIView *)view;
- (void)setTapCount:(NSUInteger)tapCount;
- (void)setIsTap:(BOOL)isTap;
- (void)setTimestamp:(NSTimeInterval)timestamp;
- (void)setPhase:(UITouchPhase)phase;
- (void)setLocationInWindow:(CGPoint)location;
@end

static void simulateNativeTapOnView(UIView *view, CGPoint point) {
    if (!view) return;
    UIView *hitView = [view hitTest:point withEvent:nil] ?: view;
    UIWindow *window = view.window;
    if (!window) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { window = w; break; }
        }
    }
    if (!window) window = [UIApplication sharedApplication].windows.firstObject;
    CGPoint winPoint = [view convertPoint:point toView:window];
    
    UITouch *touch = [[NSClassFromString(@"UITouch") alloc] init];
    if ([touch respondsToSelector:@selector(setWindow:)]) [touch setWindow:window];
    if ([touch respondsToSelector:@selector(setView:)]) [touch setView:hitView];
    if ([touch respondsToSelector:@selector(setTapCount:)]) [touch setTapCount:1];
    if ([touch respondsToSelector:@selector(setIsTap:)]) [touch setIsTap:YES];
    if ([touch respondsToSelector:@selector(setTimestamp:)]) [touch setTimestamp:[[NSDate date] timeIntervalSince1970]];
    if ([touch respondsToSelector:@selector(setPhase:)]) [touch setPhase:UITouchPhaseBegan];
    if ([touch respondsToSelector:@selector(setLocationInWindow:)]) [touch setLocationInWindow:winPoint];
    
    NSSet *touches = [NSSet setWithObject:touch];
    
    NSMutableSet *recognizers = [NSMutableSet set];
    UIView *v = hitView;
    while (v) {
        if (v.gestureRecognizers) [recognizers addObjectsFromArray:v.gestureRecognizers];
        v = v.superview;
    }
    
    @try {
        [hitView touchesBegan:touches withEvent:nil];
        for (UIGestureRecognizer *gr in recognizers) {
            if ([gr respondsToSelector:@selector(touchesBegan:withEvent:)]) {
                [gr touchesBegan:touches withEvent:nil];
            }
        }
    } @catch (NSException *e) {}
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.04 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([touch respondsToSelector:@selector(setPhase:)]) [touch setPhase:UITouchPhaseEnded];
        if ([touch respondsToSelector:@selector(setTimestamp:)]) [touch setTimestamp:[[NSDate date] timeIntervalSince1970]];
        @try {
            [hitView touchesEnded:touches withEvent:nil];
            for (UIGestureRecognizer *gr in recognizers) {
                if ([gr respondsToSelector:@selector(touchesEnded:withEvent:)]) {
                    [gr touchesEnded:touches withEvent:nil];
                }
            }
        } @catch (NSException *e) {}
    });
}

static __weak id currentForestHomeController = nil;

static void dismissFriendAnimalPopup(id controller) {
    if (!controller) return;
    id webView = findWebViewInController(controller);
    if (!webView) return;
    SEL evaluate = @selector(evaluateJavaScript:completionHandler:);
    if ([webView respondsToSelector:evaluate]) {
        NSString *js = @"(function(){"
        "var mask = document.querySelector('[class*=\"mask\"],[class*=\"modal\"],[class*=\"dialog\"],[class*=\"popup\"],[role=\"dialog\"]');"
        "if(!mask) return 'no_modal';"
        "var maskText = (mask.innerText || mask.textContent || '').trim();"
        "if(!maskText.includes('嗨，我是') && !maskText.includes('河姆渡福猪') && !maskText.includes('帮主人自动找能量')) return 'no_friend_animal_modal';"
        "var closeEls = Array.from(mask.querySelectorAll('button,a,div,span,img,svg,[role=\"button\"]')).filter(function(el){"
        "  var clz = (el.className || '').toString().toLowerCase();"
        "  var src = (el.src || el.getAttribute('src') || '').toLowerCase();"
        "  var aria = (el.getAttribute('aria-label') || '').toLowerCase();"
        "  var txt = (el.innerText || el.textContent || '').trim();"
        "  return clz.includes('close') || src.includes('close') || aria.includes('关') || aria.includes('close') || txt === '✕' || txt === '×' || txt === 'X' || txt === '我知道了';"
        "});"
        "if(closeEls.length > 0){"
        "  try{ closeEls[0].click(); }catch(_){}"
        "  return 'closed';"
        "}"
        "return 'no_close_btn';"
        "})();";
        void (*runJavaScript)(id, SEL, NSString *, void (^)(id, NSError *)) = (void *)objc_msgSend;
        runJavaScript(webView, evaluate, js, ^(id result, NSError *error) {});
    }
}

static void collectAnimalEnergyAtHome(__unused id controller) {
    // 保护地巡护能量由 AntForestManager 在后台通过官方静默 RPC (collectAnimalRobEnergy / collectAnimalEnergy / receiveAnimalEnergy) 安全收取，
    // 严禁在森林首页通过 DOM 盲扫点击气泡，彻底避免误触跳转其他页面（如活动卡片、排行榜等）。
}

static void installForestHomeCollector(__unused id controller) {
}

static BOOL isNewPatrolURL(NSURL *url, id controller) {
    NSString *str = url.absoluteString ? url.absoluteString : @"";
    NSString *lowerStr = [str lowercaseString];
    if ([str containsString:@"180020010001293606"] ||
        [str containsString:@"2060090000398301"] ||
        [lowerStr containsString:@"forest-guardian"] ||
        [lowerStr containsString:@"guardian"] ||
        [lowerStr containsString:@"monopoly"] ||
        [lowerStr containsString:@"patrol"] ||
        [lowerStr containsString:@"antisle"] ||
        [lowerStr containsString:@"hsdwy"]) {
        return YES;
    }
    for (NSString *sel in @[@"appId", @"appID", @"currentAppId", @"appName", @"name", @"title"]) {
        SEL s = NSSelectorFromString(sel);
        if ([controller respondsToSelector:s]) {
            id val = ((id (*)(id, SEL))objc_msgSend)(controller, s);
            NSString *valStr = [val isKindOfClass:NSString.class] ? val : [val description];
            NSString *lowerVal = [valStr lowercaseString];
            if ([valStr containsString:@"180020010001293606"] ||
                [valStr containsString:@"2060090000398301"] ||
                [lowerVal containsString:@"monopoly"] ||
                [lowerVal containsString:@"patrol"] ||
                [lowerVal containsString:@"antisle"] ||
                [lowerVal containsString:@"hsdwy"] ||
                [valStr containsString:@"保护地"] ||
                [valStr containsString:@"巡护"] ||
                [valStr containsString:@"大富翁"] ||
                [valStr containsString:@"南京红山"] ||
                [valStr containsString:@"红山动物园"]) return YES;
        }
    }
    return NO;
}

static BOOL isPatrolURL(NSURL *url, id controller) {
    return isNewPatrolURL(url, controller);
}

static void installMonopolyAutoPilot(id controller) {
    id webView = findWebViewInController(controller);
    SEL evaluate = @selector(evaluateJavaScript:completionHandler:);
    if (![webView respondsToSelector:evaluate]) return;
    
    NSString *script = @"(()=>{if(window.__afMonopolyInstalled)return'already';"
    "window.__afMonopolyInstalled=true;"
    "function sendLog(data){try{console.log('PATROL_LOG:'+JSON.stringify(data))}catch(e){}};"
    "let state={diceCount:-1,isBusy:false,lastActionTime:0,reportedDone:false};"
    "let openedDrawerOnce=false;"
    "function triggerTap(el){"
    "if(!el)return;"
    "const r=el.getBoundingClientRect();"
    "const x=Math.round(r.left+r.width/2);"
    "const y=Math.round(r.top+r.height/2);"
    "const clickTarget=el.closest('button,a,[role=\"button\"],[class*=\"btn\"],[class*=\"button\"]')||el;"
    "try{if(typeof clickTarget.click==='function'){clickTarget.click();return;}}catch(_){}"
    "try{"
    "if(window.TouchEvent&&window.Touch){"
    "const touch=new Touch({identifier:Date.now(),target:clickTarget,clientX:x,clientY:y,screenX:x,screenY:y,pageX:x,pageY:y});"
    "clickTarget.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[touch],targetTouches:[touch],changedTouches:[touch]}));"
    "clickTarget.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[touch]}));"
    "return;"
    "}"
    "}catch(_){}"
    "try{"
    "const mOpts={bubbles:true,cancelable:true,view:window,clientX:x,clientY:y,pageX:x,pageY:y,screenX:x,screenY:y};"
    "clickTarget.dispatchEvent(new MouseEvent('click',mOpts));"
    "}catch(_){}"
    "}"
    "function findAndClick(keywords,minTop,maxTop){"
    "const els=Array.from(document.querySelectorAll('button,a,[role=\"button\"],[class*=\"btn\"],[class*=\"button\"],div,span,p'));"
    "for(let kw of keywords){"
    "for(let el of els){"
    "const rect=el.getBoundingClientRect();"
    "if(rect.width<=0||rect.height<=0||rect.height>140||rect.top<(minTop||50))continue;"
    "if(maxTop&&rect.bottom>maxTop)continue;"
    "const txt=(el.innerText||el.textContent||'').trim();"
    "const aria=(el.getAttribute('aria-label')||'').trim();"
    "if(txt===kw||aria===kw||(kw.length>=2&&(txt===' '+kw||txt===kw+' '||txt==='【'+kw+'】'))){triggerTap(el);return kw;}"
    "if(kw.length>=2&&(txt.startsWith(kw)||txt.endsWith(kw)||(kw==='GO'&&txt.toUpperCase()==='GO')||(kw==='前进'&&txt==='前进'))){triggerTap(el);return kw;}"
    "}}"
    "return null;}"
    "function tryOpenDrawerOnce(){"
    "if(window.__afMonopolyDrawerEverOpened)return;"
    "const isDrawerOpen=Array.from(document.querySelectorAll('*')).some(el=>{"
    "const t=(el.innerText||el.textContent||'').trim();"
    "return t==='做任务领骰子'||t==='做任务得机会'||t==='更多巡护步数'||t==='巡护任务'||t==='做任务领步数'||t.includes('做任务领骰子')||t.includes('更多巡护步数');"
    "});"
    "if(isDrawerOpen){window.__afMonopolyDrawerEverOpened=true;return;}"
    "const kw=findAndClick(['更多步数','更多巡护步数','领步数','赚步数','做任务领步数','做任务领骰子','做任务得机会','领骰子','做任务','巡护步数','巡护任务'],50);"
    "if(kw){window.__afMonopolyDrawerEverOpened=true;sendLog({type:'STATUS',msg:'保护地大富翁：已自动点击【'+kw+'】展开步数任务抽屉'});}"
    "}"
    "function checkIsOutOfDice(){"
    "if(state.diceCount===0)return true;"
    "const isTaskDrawerVisible=Array.from(document.querySelectorAll('*')).some(el=>{"
    "const t=(el.innerText||el.textContent||'').trim();"
    "return t==='做任务领骰子'||t==='做任务得机会'||t==='更多巡护步数'||t==='巡护任务'||t==='领骰子'||t.includes('做任务领骰子')||t.includes('更多巡护步数');"
    "});"
    "if(isTaskDrawerVisible){state.diceCount=0;return true;}"
    "const h=window.innerHeight;"
    "const bottomEls=Array.from(document.querySelectorAll('*')).filter(el=>{"
    "const r=el.getBoundingClientRect();"
    "return r.top>h*0.4&&r.width>0&&r.height>0&&r.width<120&&r.height<60;"
    "});"
    "for(let el of bottomEls){"
    "const t=(el.innerText||el.textContent||'').trim();"
    "if(t==='0'||t==='0个'||t==='x0'||t==='X0'||t==='0/5'||t==='0次'||t==='0个骰子'){state.diceCount=0;return true;}"
    "const m=t.match(/^[xX]?(\\d+)(?:个|次)?$/);"
    "if(m){const c=parseInt(m[1],10);if(c===0){state.diceCount=0;return true;}else if(c>0&&c<100){state.diceCount=c;}}"
    "}"
    "return false;"
    "}"
    "function monopolyStep(){"
    "if(state.isBusy)return;"
    "const now=Date.now();"
    "if(now-state.lastActionTime<1200)return;"
    "const evBtn=findAndClick(['跳过','开心收下','立即收下','收下动物','收下勋章','我知道了','确定','好的'],70);"
    "if(evBtn){"
    "state.isBusy=true;state.lastActionTime=now;"
    "sendLog({type:'STATUS',msg:'保护地大富翁：自动点击【'+evBtn+'】推进事件'});"
    "setTimeout(()=>{state.isBusy=false;},1500);"
    "return;"
    "}"
    // 新版巡护地：不自动关闭弹窗，允许用户自由查看“更多步数”与任务列表
    "if(checkIsOutOfDice()){"
    "if(!state.reportedDone){"
    "state.reportedDone=true;"
    "sendLog({type:'STATUS',msg:'保护地大富翁：今日巡护骰子已全部用尽，巡护圆满完成！'});"
    "}"
    "return;"
    "}"
    // 新版巡护地：保留自动做任务与弹窗事件处理，GO 摇骰子由用户手动点击
    "}"
    "function hookBridge(){"
    "if(!window.AlipayJSBridge||!window.AlipayJSBridge.call)return;"
    "if(window.__afMonopolyHooked)return;"
    "window.__afMonopolyHooked=true;"
    "const _call=window.AlipayJSBridge.call;"
    "window.AlipayJSBridge.call=function(name,params,cb){"
    "if(name==='rpc'&&params&&params.operationType){"
    "const origCb=cb;"
    "cb=function(res){"
    "let dc=undefined;"
    "if(res){"
    "if(res.totalDiceCount!==undefined)dc=Number(res.totalDiceCount);"
    "else if(res.resData&&res.resData.totalDiceCount!==undefined)dc=Number(res.resData.totalDiceCount);"
    "else if(res.diceCount!==undefined)dc=Number(res.diceCount);"
    "else if(res.resData&&res.resData.diceCount!==undefined)dc=Number(res.resData.diceCount);"
    "}"
    "if(dc!==undefined){"
    "state.diceCount=dc;"
    "if(dc===0&&!state.reportedDone){state.reportedDone=true;sendLog({type:'STATUS',msg:'保护地大富翁：今日巡护骰子已全部用尽，巡护圆满完成！'});}"
    "}"
    "setTimeout(monopolyStep,500);"
    "if(origCb)origCb(res);"
    "};"
    "}"
    "return _call.apply(window.AlipayJSBridge,[name,params,cb]);"
    "};"
    "}"
    "hookBridge();"
    "setTimeout(tryOpenDrawerOnce,600);"
    "setTimeout(monopolyStep,600);"
    "setInterval(monopolyStep,1200);"
    "sendLog({type:'STATUS',msg:'保护地大富翁：自动掷骰巡护已就绪'});"
    "return'monopoly-autopilot-installed';})()";
    
    void (*runJavaScript)(id, SEL, NSString *, void (^)(id, NSError *)) = (void *)objc_msgSend;
    runJavaScript(webView, evaluate, script, ^(id result, NSError *error) {
        NSLog(@"[AntForestPatrol] monopoly hook result: %@ error: %@", result, error);
    });
}

static void installPatrolAutoPilot(id controller) {
    NSURL *curUrl = urlFromController(controller);
    if (isNewPatrolURL(curUrl, controller)) {
        if ([AntForestManager sharedInstance].enableAutoPatrolNew) {
            installMonopolyAutoPilot(controller);
        }
    }
}

static void installEarnEnergyCollector(id controller) {
    static const void *collectorKey = &collectorKey;
    if (objc_getAssociatedObject(controller, collectorKey)) return;
    objc_setAssociatedObject(controller, collectorKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id webView = [controller respondsToSelector:@selector(webView)] ? ((id (*)(id, SEL))objc_msgSend)(controller, @selector(webView)) : findWebViewInController(controller);
    SEL evaluate = @selector(evaluateJavaScript:completionHandler:);
    if (![webView respondsToSelector:evaluate]) return;
    NSString *script = @"(()=>{if(window.__antForestEarnCollectorInstalled)return 'installed';window.__antForestEarnCollectorInstalled=1;function initEarn(){const c=document.getElementById('J_treeCanvas')||document.querySelector('canvas');if(!c)return false;const p={active:true,hits:[]};window.__antForestEarnCollector=p;const tap=r=>{if(!p.active)return;const now=Date.now(),x=r.x+r.w/2,y=r.y+r.h/2,old=p.hits.find(q=>Math.abs(q.x-x)<55&&Math.abs(q.y-y)<80&&now-q.t<850);if(old)return;p.hits=p.hits.filter(q=>now-q.t<850);p.hits.push({x,y,t:now});const b=c.getBoundingClientRect(),cx=b.left+x*b.width/c.width,cy=b.top+y*b.height/c.height,t={identifier:now%1000000,target:c,clientX:cx,clientY:cy,pageX:cx,pageY:cy,screenX:cx,screenY:cy};try{const q=new Touch(t);c.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[q],targetTouches:[q],changedTouches:[q]}));setTimeout(()=>c.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[q]})),12)}catch(_){}};const rect=d=>{try{if(!d||d.byteLength!==192)return null;const f=new Float32Array(d.buffer||d,d.byteOffset||0,24),xs=[f[0],f[6],f[12],f[18]],ys=[f[1],f[7],f[13],f[19]];if(!xs.every(Number.isFinite)||!ys.every(Number.isFinite))return null;const x=Math.min(...xs),y=Math.min(...ys),w=Math.max(...xs)-x,h=Math.max(...ys)-y;return w>=70&&w<=130&&h>=70&&h<=130?{x,y,w,h}:null}catch(_){return null}};const b=window.AlipayJSBridge;if(b&&b.call&&!b.__afEarnCollector){b.__afEarnCollector=1;const f=b.call;b.call=function(handler,data){if(/settlementWhackMole/.test(String(data&&data.operationType||'')))p.active=false;return f.apply(this,arguments)}}const hook=P=>{if(!P||P.__afEarnCollector)return;P.__afEarnCollector=1;const f=P.bufferSubData;if(f)P.bufferSubData=function(target,offset,data,...a){const r=this.canvas===c&&rect(data);if(r)tap(r);return f.call(this,target,offset,data,...a)}};hook(window.WebGLRenderingContext&&WebGLRenderingContext.prototype);hook(window.WebGL2RenderingContext&&WebGL2RenderingContext.prototype);return true}if(!initEarn()){const timer=setInterval(()=>{if(initEarn())clearInterval(timer)},300)}return 'installed'})()";
    void (*runJavaScript)(id, SEL, NSString *, void (^)(id, NSError *)) = (void *)objc_msgSend;
    runJavaScript(webView, evaluate, script, ^(id result, NSError *error) {
        if (error || ![result isEqual:@"installed"]) {
            objc_setAssociatedObject(controller, collectorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ installEarnEnergyCollector(controller); });
        }
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

    UIView *enabledCard = [[UIView alloc] init]; enabledCard.backgroundColor = UIColor.systemBackgroundColor; enabledCard.layer.cornerRadius = 16; enabledCard.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *enabledTitle = [[UILabel alloc] init]; enabledTitle.text = @"启用每日定时收取"; enabledTitle.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]; enabledTitle.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *enabledDetail = [[UILabel alloc] init]; enabledDetail.text = @"仅收取好友与自己的成熟能量"; enabledDetail.font = [UIFont systemFontOfSize:12]; enabledDetail.textColor = UIColor.secondaryLabelColor; enabledDetail.translatesAutoresizingMaskIntoConstraints = NO;
    UISwitch *enabled = [[UISwitch alloc] init]; enabled.on = [AntForestManager sharedInstance].enableScheduledCollect; [enabled addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged]; enabled.translatesAutoresizingMaskIntoConstraints = NO;
    [enabledCard addSubview:enabledTitle]; [enabledCard addSubview:enabledDetail]; [enabledCard addSubview:enabled];

    self.picker = [[UIDatePicker alloc] init];
    self.picker.datePickerMode = UIDatePickerModeTime;
    if (@available(iOS 13.4, *)) {
        self.picker.preferredDatePickerStyle = UIDatePickerStyleCompact;
    }
    self.saveButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.saveButton setTitle:@"添加时间" forState:UIControlStateNormal];
    self.saveButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    self.saveButton.backgroundColor = [UIColor colorWithRed:0.07 green:0.31 blue:0.18 alpha:1.0];
    [self.saveButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.saveButton.layer.cornerRadius = 8;
    self.saveButton.contentEdgeInsets = UIEdgeInsetsMake(6, 14, 6, 14);
    [self.saveButton addTarget:self action:@selector(addTime) forControlEvents:UIControlEventTouchUpInside];

    UIView *addCard = [[UIView alloc] init]; addCard.backgroundColor = UIColor.systemBackgroundColor; addCard.layer.cornerRadius = 16; addCard.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *addTitle = [[UILabel alloc] init]; addTitle.text = @"添加定时收取时间"; addTitle.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]; addTitle.translatesAutoresizingMaskIntoConstraints = NO;
    UIStackView *bar = [[UIStackView alloc] initWithArrangedSubviews:@[self.picker, self.saveButton]];
    bar.spacing = 16; bar.alignment = UIStackViewAlignmentCenter; bar.translatesAutoresizingMaskIntoConstraints = NO;
    [addCard addSubview:addTitle]; [addCard addSubview:bar];

    UILabel *sectionTitle = [[UILabel alloc] init]; sectionTitle.text = @"已添加的定时时间"; sectionTitle.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]; sectionTitle.textColor = UIColor.secondaryLabelColor; sectionTitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.dataSource = self; self.tableView.delegate = self; self.tableView.backgroundColor = UIColor.clearColor; self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel = [[UILabel alloc] init]; self.emptyLabel.text = @"尚未添加定时任务"; self.emptyLabel.font = [UIFont systemFontOfSize:14]; self.emptyLabel.textColor = UIColor.secondaryLabelColor; self.emptyLabel.textAlignment = NSTextAlignmentCenter; self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
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
    NSString *timeStr = [AntForestManager sharedInstance].scheduledTimes[indexPath.row];
    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:timeStr attributes:@{
        NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:18 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: UIColor.labelColor
    }];
    NSAttributedString *hint = [[NSAttributedString alloc] initWithString:@"   点击修改" attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightRegular],
        NSForegroundColorAttributeName: UIColor.secondaryLabelColor
    }];
    [attr appendAttributedString:hint];
    cell.textLabel.attributedText = attr;
    cell.imageView.image = [UIImage systemImageNamed:@"clock.fill"];
    cell.imageView.tintColor = [UIColor colorWithRed:0.07 green:0.31 blue:0.18 alpha:1.0];
    
    UIButton *trashBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    trashBtn.frame = CGRectMake(0, 0, 36, 36);
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightRegular];
    [trashBtn setImage:[UIImage systemImageNamed:@"trash" withConfiguration:config] forState:UIControlStateNormal];
    trashBtn.tintColor = [UIColor colorWithRed:0.90 green:0.25 blue:0.25 alpha:1.0];
    trashBtn.tag = indexPath.row;
    [trashBtn addTarget:self action:@selector(handleDeleteButton:) forControlEvents:UIControlEventTouchUpInside];
    cell.accessoryView = trashBtn;
    return cell;
}
- (void)handleDeleteButton:(UIButton *)sender {
    NSInteger row = sender.tag;
    NSMutableArray *times = [[AntForestManager sharedInstance].scheduledTimes mutableCopy];
    if (row < times.count) {
        [times removeObjectAtIndex:row];
        [AntForestManager sharedInstance].scheduledTimes = times;
        [NSUserDefaults.standardUserDefaults setObject:times forKey:@"scheduledCollectTimes"];
        [self.tableView reloadData];
        [self updateEmptyState];
    }
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *currentTime = [AntForestManager sharedInstance].scheduledTimes[indexPath.row];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"HH:mm";
    NSDate *currentDate = [formatter dateFromString:currentTime] ?: [NSDate date];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"修改定时收取时间"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    UIViewController *vc = [[UIViewController alloc] init];
    vc.preferredContentSize = CGSizeMake(270, 160);
    UIDatePicker *picker = [[UIDatePicker alloc] initWithFrame:CGRectMake(0, 0, 270, 160)];
    picker.datePickerMode = UIDatePickerModeTime;
    if (@available(iOS 13.4, *)) {
        picker.preferredDatePickerStyle = UIDatePickerStyleWheels;
    }
    picker.date = currentDate;
    [vc.view addSubview:picker];
    [alert setValue:vc forKey:@"contentViewController"];
    
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存修改" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *newTime = [formatter stringFromDate:picker.date];
        NSMutableArray *times = [[AntForestManager sharedInstance].scheduledTimes mutableCopy] ?: NSMutableArray.array;
        if (indexPath.row < times.count) {
            [times removeObjectAtIndex:indexPath.row];
        }
        if (![times containsObject:newTime]) {
            [times addObject:newTime];
        }
        [times sortUsingSelector:@selector(compare:)];
        [AntForestManager sharedInstance].scheduledTimes = times;
        [NSUserDefaults.standardUserDefaults setObject:times forKey:@"scheduledCollectTimes"];
        [weakSelf.tableView reloadData];
        [weakSelf updateEmptyState];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
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
    self.title = @"定时浇水设置";
    self.editingIndex = NSNotFound;
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    
    UIView *addCard = [[UIView alloc] init]; addCard.backgroundColor = UIColor.systemBackgroundColor; addCard.layer.cornerRadius = 16; addCard.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *addTitle = [[UILabel alloc] init]; addTitle.text = @"添加定时浇水时间"; addTitle.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]; addTitle.translatesAutoresizingMaskIntoConstraints = NO;
    
    self.picker = [[UIDatePicker alloc] init]; self.picker.datePickerMode = UIDatePickerModeTime;
    if (@available(iOS 13.4, *)) {
        self.picker.preferredDatePickerStyle = UIDatePickerStyleCompact;
    }
    self.saveButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.saveButton setTitle:@"添加时间" forState:UIControlStateNormal];
    self.saveButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    self.saveButton.backgroundColor = [UIColor colorWithRed:0.07 green:0.31 blue:0.18 alpha:1.0];
    [self.saveButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.saveButton.layer.cornerRadius = 8;
    self.saveButton.contentEdgeInsets = UIEdgeInsetsMake(6, 14, 6, 14);
    [self.saveButton addTarget:self action:@selector(addTime) forControlEvents:UIControlEventTouchUpInside];
    
    UIStackView *bar = [[UIStackView alloc] initWithArrangedSubviews:@[self.picker, self.saveButton]];
    bar.spacing = 16; bar.alignment = UIStackViewAlignmentCenter; bar.translatesAutoresizingMaskIntoConstraints = NO;
    [addCard addSubview:addTitle]; [addCard addSubview:bar];
    
    UILabel *sectionTitle = [[UILabel alloc] init]; sectionTitle.text = @"已添加的定时时间"; sectionTitle.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]; sectionTitle.textColor = UIColor.secondaryLabelColor; sectionTitle.translatesAutoresizingMaskIntoConstraints = NO;
    
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.dataSource = self; self.tableView.delegate = self; self.tableView.backgroundColor = UIColor.clearColor; self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    
    [self.view addSubview:addCard]; [self.view addSubview:sectionTitle]; [self.view addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [addCard.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
        [addCard.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [addCard.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [addCard.heightAnchor constraintEqualToConstant:74],
        [addTitle.topAnchor constraintEqualToAnchor:addCard.topAnchor constant:12],
        [addTitle.leadingAnchor constraintEqualToAnchor:addCard.leadingAnchor constant:16],
        [bar.topAnchor constraintEqualToAnchor:addTitle.bottomAnchor constant:6],
        [bar.leadingAnchor constraintEqualToAnchor:addCard.leadingAnchor constant:16],
        [sectionTitle.topAnchor constraintEqualToAnchor:addCard.bottomAnchor constant:18],
        [sectionTitle.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [self.tableView.topAnchor constraintEqualToAnchor:sectionTitle.bottomAnchor constant:2],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
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
    self.editingIndex = NSNotFound;
    [self.saveButton setTitle:@"添加时间" forState:UIControlStateNormal];
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return AntForestManager.sharedInstance.waterScheduledTimes.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"waterTime"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"waterTime"];
    NSString *timeStr = AntForestManager.sharedInstance.waterScheduledTimes[indexPath.row];
    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:timeStr attributes:@{
        NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:18 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: UIColor.labelColor
    }];
    NSAttributedString *hint = [[NSAttributedString alloc] initWithString:@"   点击修改" attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightRegular],
        NSForegroundColorAttributeName: UIColor.secondaryLabelColor
    }];
    [attr appendAttributedString:hint];
    cell.textLabel.attributedText = attr;
    cell.imageView.image = [UIImage systemImageNamed:@"clock.fill"];
    cell.imageView.tintColor = [UIColor colorWithRed:0.07 green:0.31 blue:0.18 alpha:1.0];
    
    UIButton *trashBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    trashBtn.frame = CGRectMake(0, 0, 36, 36);
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightRegular];
    [trashBtn setImage:[UIImage systemImageNamed:@"trash" withConfiguration:config] forState:UIControlStateNormal];
    trashBtn.tintColor = [UIColor colorWithRed:0.90 green:0.25 blue:0.25 alpha:1.0];
    trashBtn.tag = indexPath.row;
    [trashBtn addTarget:self action:@selector(handleDeleteButton:) forControlEvents:UIControlEventTouchUpInside];
    cell.accessoryView = trashBtn;
    return cell;
}
- (void)handleDeleteButton:(UIButton *)sender {
    NSInteger row = sender.tag;
    NSMutableArray *times = [AntForestManager.sharedInstance.waterScheduledTimes mutableCopy];
    if (row < times.count) {
        [times removeObjectAtIndex:row];
        AntForestManager.sharedInstance.waterScheduledTimes = times;
        [NSUserDefaults.standardUserDefaults setObject:times forKey:@"waterScheduledTimes"];
        [self.tableView reloadData];
    }
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *currentTime = AntForestManager.sharedInstance.waterScheduledTimes[indexPath.row];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"HH:mm";
    NSDate *currentDate = [formatter dateFromString:currentTime] ?: [NSDate date];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"修改定时浇水时间"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    UIViewController *vc = [[UIViewController alloc] init];
    vc.preferredContentSize = CGSizeMake(270, 160);
    UIDatePicker *picker = [[UIDatePicker alloc] initWithFrame:CGRectMake(0, 0, 270, 160)];
    picker.datePickerMode = UIDatePickerModeTime;
    if (@available(iOS 13.4, *)) {
        picker.preferredDatePickerStyle = UIDatePickerStyleWheels;
    }
    picker.date = currentDate;
    [vc.view addSubview:picker];
    [alert setValue:vc forKey:@"contentViewController"];
    
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存修改" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *newTime = [formatter stringFromDate:picker.date];
        NSMutableArray *times = [AntForestManager.sharedInstance.waterScheduledTimes mutableCopy] ?: NSMutableArray.array;
        if (indexPath.row < times.count) {
            [times removeObjectAtIndex:indexPath.row];
        }
        if (![times containsObject:newTime]) {
            [times addObject:newTime];
        }
        [times sortUsingSelector:@selector(compare:)];
        AntForestManager.sharedInstance.waterScheduledTimes = times;
        [NSUserDefaults.standardUserDefaults setObject:times forKey:@"waterScheduledTimes"];
        [weakSelf.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
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
    
    UIView *options = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 240)];
    
    UIView *card1 = [[UIView alloc] init];
    card1.backgroundColor = UIColor.systemBackgroundColor;
    card1.layer.cornerRadius = 16;
    card1.translatesAutoresizingMaskIntoConstraints = NO;
    
    UILabel *launchLabel = [[UILabel alloc] init]; launchLabel.text = @"打开蚂蚁森林自动浇水"; launchLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]; launchLabel.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *launchDetail = [[UILabel alloc] init]; launchDetail.text = @"进入森林首页时触发一次"; launchDetail.font = [UIFont systemFontOfSize:12]; launchDetail.textColor = UIColor.secondaryLabelColor; launchDetail.translatesAutoresizingMaskIntoConstraints = NO;
    UISwitch *launchSwitch = [[UISwitch alloc] init]; launchSwitch.on = AntForestManager.sharedInstance.enableWaterOnLaunch; [launchSwitch addTarget:self action:@selector(toggleWaterOnLaunch:) forControlEvents:UIControlEventValueChanged]; launchSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    
    UIView *div1 = [[UIView alloc] init]; div1.backgroundColor = UIColor.systemGray5Color; div1.translatesAutoresizingMaskIntoConstraints = NO;
    
    UILabel *autoLabel = [[UILabel alloc] init]; autoLabel.text = @"启用定时自动浇水"; autoLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]; autoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *autoDetail = [[UILabel alloc] init]; autoDetail.text = @"按设定时刻在后台定时浇水"; autoDetail.font = [UIFont systemFontOfSize:12]; autoDetail.textColor = UIColor.secondaryLabelColor; autoDetail.translatesAutoresizingMaskIntoConstraints = NO;
    UISwitch *autoSwitch = [[UISwitch alloc] init]; autoSwitch.on = AntForestManager.sharedInstance.enableAutoWater; [autoSwitch addTarget:self action:@selector(toggleAutoWater:) forControlEvents:UIControlEventValueChanged]; autoSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    
    [card1 addSubview:launchLabel]; [card1 addSubview:launchDetail]; [card1 addSubview:launchSwitch];
    [card1 addSubview:div1];
    [card1 addSubview:autoLabel]; [card1 addSubview:autoDetail]; [card1 addSubview:autoSwitch];
    
    UIView *card2 = [[UIView alloc] init];
    card2.backgroundColor = UIColor.systemBackgroundColor;
    card2.layer.cornerRadius = 16;
    card2.translatesAutoresizingMaskIntoConstraints = NO;
    
    UILabel *amountTitle = [[UILabel alloc] init]; amountTitle.text = @"每次浇水量"; amountTitle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]; amountTitle.translatesAutoresizingMaskIntoConstraints = NO;
    UISegmentedControl *amount = [[UISegmentedControl alloc] initWithItems:@[@"10g", @"18g", @"33g", @"66g"]];
    NSInteger index = MAX(0, MIN(3, AntForestManager.sharedInstance.waterEnergyId - 39));
    amount.selectedSegmentIndex = index;
    [amount addTarget:self action:@selector(changeAmount:) forControlEvents:UIControlEventValueChanged];
    amount.translatesAutoresizingMaskIntoConstraints = NO;
    
    UIView *div2 = [[UIView alloc] init]; div2.backgroundColor = UIColor.systemGray5Color; div2.translatesAutoresizingMaskIntoConstraints = NO;
    
    UIButton *scheduleBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [scheduleBtn setTitle:@"定时浇水设置" forState:UIControlStateNormal];
    scheduleBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    scheduleBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [scheduleBtn addTarget:self action:@selector(showSchedule) forControlEvents:UIControlEventTouchUpInside];
    scheduleBtn.translatesAutoresizingMaskIntoConstraints = NO;
    
    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chevron.tintColor = UIColor.systemGray3Color;
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    
    [card2 addSubview:amountTitle]; [card2 addSubview:amount];
    [card2 addSubview:div2];
    [card2 addSubview:scheduleBtn]; [card2 addSubview:chevron];
    
    [options addSubview:card1]; [options addSubview:card2];
    
    [NSLayoutConstraint activateConstraints:@[
        [card1.topAnchor constraintEqualToAnchor:options.topAnchor constant:10],
        [card1.leadingAnchor constraintEqualToAnchor:options.leadingAnchor constant:16],
        [card1.trailingAnchor constraintEqualToAnchor:options.trailingAnchor constant:-16],
        [card1.heightAnchor constraintEqualToConstant:120],
        
        [launchLabel.topAnchor constraintEqualToAnchor:card1.topAnchor constant:12],
        [launchLabel.leadingAnchor constraintEqualToAnchor:card1.leadingAnchor constant:16],
        [launchDetail.topAnchor constraintEqualToAnchor:launchLabel.bottomAnchor constant:3],
        [launchDetail.leadingAnchor constraintEqualToAnchor:launchLabel.leadingAnchor],
        [launchSwitch.centerYAnchor constraintEqualToAnchor:launchLabel.bottomAnchor constant:1],
        [launchSwitch.trailingAnchor constraintEqualToAnchor:card1.trailingAnchor constant:-16],
        
        [div1.topAnchor constraintEqualToAnchor:card1.topAnchor constant:60],
        [div1.leadingAnchor constraintEqualToAnchor:card1.leadingAnchor constant:16],
        [div1.trailingAnchor constraintEqualToAnchor:card1.trailingAnchor constant:-16],
        [div1.heightAnchor constraintEqualToConstant:1],
        
        [autoLabel.topAnchor constraintEqualToAnchor:div1.bottomAnchor constant:10],
        [autoLabel.leadingAnchor constraintEqualToAnchor:card1.leadingAnchor constant:16],
        [autoDetail.topAnchor constraintEqualToAnchor:autoLabel.bottomAnchor constant:3],
        [autoDetail.leadingAnchor constraintEqualToAnchor:autoLabel.leadingAnchor],
        [autoSwitch.centerYAnchor constraintEqualToAnchor:autoLabel.bottomAnchor constant:1],
        [autoSwitch.trailingAnchor constraintEqualToAnchor:card1.trailingAnchor constant:-16],
        
        [card2.topAnchor constraintEqualToAnchor:card1.bottomAnchor constant:10],
        [card2.leadingAnchor constraintEqualToAnchor:options.leadingAnchor constant:16],
        [card2.trailingAnchor constraintEqualToAnchor:options.trailingAnchor constant:-16],
        [card2.heightAnchor constraintEqualToConstant:98],
        
        [amountTitle.topAnchor constraintEqualToAnchor:card2.topAnchor constant:12],
        [amountTitle.leadingAnchor constraintEqualToAnchor:card2.leadingAnchor constant:16],
        [amount.centerYAnchor constraintEqualToAnchor:amountTitle.centerYAnchor],
        [amount.trailingAnchor constraintEqualToAnchor:card2.trailingAnchor constant:-16],
        [amount.widthAnchor constraintEqualToConstant:200],
        
        [div2.topAnchor constraintEqualToAnchor:card2.topAnchor constant:48],
        [div2.leadingAnchor constraintEqualToAnchor:card2.leadingAnchor constant:16],
        [div2.trailingAnchor constraintEqualToAnchor:card2.trailingAnchor constant:-16],
        [div2.heightAnchor constraintEqualToConstant:1],
        
        [scheduleBtn.topAnchor constraintEqualToAnchor:div2.bottomAnchor constant:8],
        [scheduleBtn.leadingAnchor constraintEqualToAnchor:card2.leadingAnchor constant:16],
        [scheduleBtn.trailingAnchor constraintEqualToAnchor:card2.trailingAnchor constant:-36],
        [scheduleBtn.heightAnchor constraintEqualToConstant:34],
        
        [chevron.centerYAnchor constraintEqualToAnchor:scheduleBtn.centerYAnchor],
        [chevron.trailingAnchor constraintEqualToAnchor:card2.trailingAnchor constant:-16],
    ]];
    
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
    self.filteredFriendIds = query.length ? [self.friendIds filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *uid, __unused NSDictionary *bindings) { NSDictionary *c = manager.friendsName[uid]; NSString *name = [AntForestManager extractNameFromDictionary:c] ?: @""; return [name.lowercaseString containsString:query]; }]] : self.friendIds;
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
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 7, header.bounds.size.width - 110, 32)]; title.autoresizingMask = UIViewAutoresizingFlexibleWidth; title.text = [NSString stringWithFormat:@"好友列表（已选 %lu 位）", (unsigned long)AntForestManager.sharedInstance.waterFriendIds.count]; title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]; title.textColor = UIColor.secondaryLabelColor;
    UIButton *refresh = [UIButton buttonWithType:UIButtonTypeSystem]; refresh.frame = CGRectMake(header.bounds.size.width - 84, 4, 68, 36); refresh.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin; [refresh setTitle:@"刷新" forState:UIControlStateNormal]; refresh.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]; [refresh addTarget:self action:@selector(refreshFriends) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:title]; [header addSubview:refresh]; return header;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"waterFriend"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"waterFriend"];
    NSString *uid = self.filteredFriendIds[indexPath.row]; NSDictionary *contact = AntForestManager.sharedInstance.friendsName[uid]; NSString *name = [AntForestManager extractNameFromDictionary:contact]; cell.textLabel.text = name.length ? name : @"好友"; cell.accessoryType = [AntForestManager.sharedInstance.waterFriendIds containsObject:uid] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone; return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *uid = self.filteredFriendIds[indexPath.row]; NSMutableArray *selected = [AntForestManager.sharedInstance.waterFriendIds mutableCopy] ?: NSMutableArray.array; if ([selected containsObject:uid]) [selected removeObject:uid]; else [selected addObject:uid]; AntForestManager.sharedInstance.waterFriendIds = selected; [NSUserDefaults.standardUserDefaults setObject:selected forKey:@"waterFriendIds"]; [tableView deselectRowAtIndexPath:indexPath animated:YES]; [self.tableView reloadData];
}
@end

@implementation AntForestStepSimulatorPanel

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"步数模拟设置";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    AFStepSimulator *simulator = AFStepSimulator.shared;
    [simulator installAvailableHooks];
    
    UIView *card = [[UIView alloc] init]; card.backgroundColor = UIColor.systemBackgroundColor; card.layer.cornerRadius = 16; card.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *enabledTitle = [[UILabel alloc] init]; enabledTitle.text = @"启用步数模拟"; enabledTitle.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]; enabledTitle.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *enabledDetail = [[UILabel alloc] init]; enabledDetail.text = @"关闭后立即恢复支付宝读取到的真实步数"; enabledDetail.font = [UIFont systemFontOfSize:12]; enabledDetail.textColor = UIColor.secondaryLabelColor; enabledDetail.translatesAutoresizingMaskIntoConstraints = NO;
    self.enabledSwitch = [[UISwitch alloc] init]; self.enabledSwitch.on = simulator.enabled; self.enabledSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    [self.enabledSwitch addTarget:self action:@selector(toggleEnabled:) forControlEvents:UIControlEventValueChanged];
    
    UIView *rangeCard = [[UIView alloc] init]; rangeCard.backgroundColor = UIColor.systemBackgroundColor; rangeCard.layer.cornerRadius = 16; rangeCard.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *rangeTitle = [[UILabel alloc] init]; rangeTitle.text = @"步数范围"; rangeTitle.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]; rangeTitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.minField = [self numberFieldWithText:[NSString stringWithFormat:@"%ld", (long)simulator.minStep] placeholder:@"最小值"];
    self.maxField = [self numberFieldWithText:[NSString stringWithFormat:@"%ld", (long)simulator.maxStep] placeholder:@"最大值"];
    UILabel *separator = [[UILabel alloc] init]; separator.text = @"至"; separator.textColor = UIColor.secondaryLabelColor; separator.font = [UIFont systemFontOfSize:14]; separator.translatesAutoresizingMaskIntoConstraints = NO;
    UIStackView *range = [[UIStackView alloc] initWithArrangedSubviews:@[self.minField, separator, self.maxField]]; range.axis = UILayoutConstraintAxisHorizontal; range.spacing = 10; range.alignment = UIStackViewAlignmentCenter; range.translatesAutoresizingMaskIntoConstraints = NO;
    [self.minField.widthAnchor constraintEqualToConstant:112].active = YES; [self.maxField.widthAnchor constraintEqualToConstant:112].active = YES;
    
    UIView *rangeDiv = [[UIView alloc] init]; rangeDiv.backgroundColor = UIColor.systemGray5Color; rangeDiv.translatesAutoresizingMaskIntoConstraints = NO;
    
    UILabel *modeTitle = [[UILabel alloc] init]; modeTitle.text = @"生成方式"; modeTitle.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]; modeTitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.modeControl = [[UISegmentedControl alloc] initWithItems:@[@"日稳定", @"每次随机"]]; self.modeControl.selectedSegmentIndex = simulator.mode; self.modeControl.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *hint = [[UILabel alloc] init]; hint.text = @"日稳定：同一天读数一致；每次随机：每次读取实时变动。"; hint.font = [UIFont systemFontOfSize:12]; hint.textColor = UIColor.secondaryLabelColor; hint.numberOfLines = 0; hint.translatesAutoresizingMaskIntoConstraints = NO;
    
    UIView *modeDiv = [[UIView alloc] init]; modeDiv.backgroundColor = UIColor.systemGray5Color; modeDiv.translatesAutoresizingMaskIntoConstraints = NO;
    
    self.statusLabel = [[UILabel alloc] init]; self.statusLabel.font = [UIFont systemFontOfSize:12]; self.statusLabel.textColor = UIColor.secondaryLabelColor; self.statusLabel.numberOfLines = 0; self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self refreshStatus];
    
    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
    [save setTitle:@"保存设置" forState:UIControlStateNormal];
    save.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    save.backgroundColor = [UIColor colorWithRed:0.07 green:0.31 blue:0.18 alpha:1.0];
    [save setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    save.layer.cornerRadius = 14;
    save.layer.masksToBounds = YES;
    [save addTarget:self action:@selector(save) forControlEvents:UIControlEventTouchUpInside];
    save.translatesAutoresizingMaskIntoConstraints = NO;
    
    [self.view addSubview:card]; [self.view addSubview:rangeCard]; [card addSubview:enabledTitle]; [card addSubview:enabledDetail]; [card addSubview:self.enabledSwitch];
    [rangeCard addSubview:rangeTitle]; [rangeCard addSubview:range];
    [rangeCard addSubview:rangeDiv];
    [rangeCard addSubview:modeTitle]; [rangeCard addSubview:self.modeControl]; [rangeCard addSubview:hint];
    [rangeCard addSubview:modeDiv];
    [rangeCard addSubview:self.statusLabel]; [self.view addSubview:save];
    
    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16], [card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16], [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16], [card.heightAnchor constraintEqualToConstant:70],
        [enabledTitle.topAnchor constraintEqualToAnchor:card.topAnchor constant:14], [enabledTitle.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16], [enabledDetail.topAnchor constraintEqualToAnchor:enabledTitle.bottomAnchor constant:4], [enabledDetail.leadingAnchor constraintEqualToAnchor:enabledTitle.leadingAnchor], [self.enabledSwitch.centerYAnchor constraintEqualToAnchor:card.centerYAnchor], [self.enabledSwitch.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        
        [rangeCard.topAnchor constraintEqualToAnchor:card.bottomAnchor constant:12], [rangeCard.leadingAnchor constraintEqualToAnchor:card.leadingAnchor], [rangeCard.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [rangeTitle.topAnchor constraintEqualToAnchor:rangeCard.topAnchor constant:14], [rangeTitle.leadingAnchor constraintEqualToAnchor:rangeCard.leadingAnchor constant:16], [range.topAnchor constraintEqualToAnchor:rangeTitle.bottomAnchor constant:10], [range.leadingAnchor constraintEqualToAnchor:rangeCard.leadingAnchor constant:16],
        
        [rangeDiv.topAnchor constraintEqualToAnchor:range.bottomAnchor constant:14], [rangeDiv.leadingAnchor constraintEqualToAnchor:rangeCard.leadingAnchor constant:16], [rangeDiv.trailingAnchor constraintEqualToAnchor:rangeCard.trailingAnchor constant:-16], [rangeDiv.heightAnchor constraintEqualToConstant:1],
        
        [modeTitle.topAnchor constraintEqualToAnchor:rangeDiv.bottomAnchor constant:14], [modeTitle.leadingAnchor constraintEqualToAnchor:rangeCard.leadingAnchor constant:16],
        [self.modeControl.topAnchor constraintEqualToAnchor:modeTitle.bottomAnchor constant:10], [self.modeControl.leadingAnchor constraintEqualToAnchor:rangeCard.leadingAnchor constant:16], [self.modeControl.trailingAnchor constraintEqualToAnchor:rangeCard.trailingAnchor constant:-16],
        [hint.topAnchor constraintEqualToAnchor:self.modeControl.bottomAnchor constant:8], [hint.leadingAnchor constraintEqualToAnchor:rangeCard.leadingAnchor constant:16], [hint.trailingAnchor constraintEqualToAnchor:rangeCard.trailingAnchor constant:-16],
        
        [modeDiv.topAnchor constraintEqualToAnchor:hint.bottomAnchor constant:12], [modeDiv.leadingAnchor constraintEqualToAnchor:rangeCard.leadingAnchor constant:16], [modeDiv.trailingAnchor constraintEqualToAnchor:rangeCard.trailingAnchor constant:-16], [modeDiv.heightAnchor constraintEqualToConstant:1],
        
        [self.statusLabel.topAnchor constraintEqualToAnchor:modeDiv.bottomAnchor constant:10], [self.statusLabel.leadingAnchor constraintEqualToAnchor:rangeCard.leadingAnchor constant:16], [self.statusLabel.trailingAnchor constraintEqualToAnchor:rangeCard.trailingAnchor constant:-16], [self.statusLabel.bottomAnchor constraintEqualToAnchor:rangeCard.bottomAnchor constant:-14],
        
        [save.topAnchor constraintEqualToAnchor:rangeCard.bottomAnchor constant:24], [save.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20], [save.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20], [save.heightAnchor constraintEqualToConstant:48],
    ]];
}

- (UITextField *)numberFieldWithText:(NSString *)text placeholder:(NSString *)placeholder {
    UITextField *field = [[UITextField alloc] init]; field.text = text; field.placeholder = placeholder; field.keyboardType = UIKeyboardTypeNumberPad; field.textAlignment = NSTextAlignmentCenter; field.borderStyle = UITextBorderStyleRoundedRect; field.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightMedium]; field.translatesAutoresizingMaskIntoConstraints = NO; return field;
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
    UIAlertController *okAlert = [UIAlertController alertControllerWithTitle:@"保存成功" message:@"步数模拟配置已生效" preferredStyle:UIAlertControllerStyleAlert];
    [okAlert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:okAlert animated:YES completion:nil];
}

@end

@implementation AntForestSettingsPanel

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"功能设置";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"返回" style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    
    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:scrollView];
    
    UIView *contentView = [[UIView alloc] init];
    contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:contentView];
    
    UIButton *schedule = [self settingsButtonWithTitle:@"定时收取设置" detail:@"管理每日固定收取时刻" icon:@"calendar" action:@selector(showSchedule)];
    UIButton *step = [self settingsButtonWithTitle:@"步数模拟设置" detail:@"独立配置支付宝可见步数" icon:@"figure.walk" action:@selector(showStepSimulator)];
    UIButton *water = [self settingsButtonWithTitle:@"好友浇水设置" detail:@"选择好友、克数与定时任务" icon:@"drop.fill" action:@selector(showWater)];
    UIButton *revive = [self settingsButtonWithTitle:@"自动复活好友过期能量" detail:@"每日最多帮助 6 位可复活好友" icon:@"heart.circle.fill" action:nil];
    UISwitch *reviveSwitch = [[UISwitch alloc] init]; reviveSwitch.on = AntForestManager.sharedInstance.enableAutoRevive; reviveSwitch.translatesAutoresizingMaskIntoConstraints = NO; [reviveSwitch addTarget:self action:@selector(toggleAutoRevive:) forControlEvents:UIControlEventValueChanged]; [revive addSubview:reviveSwitch];
    UIButton *earn = [self settingsButtonWithTitle:@"赚能量（打地鼠玩法）" detail:@"手动进入活动后自动点击好友头像" icon:@"hand.tap.fill" action:nil];
    UISwitch *earnSwitch = [[UISwitch alloc] init]; earnSwitch.on = AntForestManager.sharedInstance.enableAutoEarn; earnSwitch.translatesAutoresizingMaskIntoConstraints = NO; [earnSwitch addTarget:self action:@selector(toggleAutoEarn:) forControlEvents:UIControlEventValueChanged]; [earn addSubview:earnSwitch];
    UIButton *ocean = [self settingsButtonWithTitle:@"神奇海洋（清理与拼图）" detail:@"自动清理海域与收集拼图" icon:@"sparkles" action:nil];
    UISwitch *oceanSwitch = [[UISwitch alloc] init]; oceanSwitch.on = AntForestManager.sharedInstance.enableCleanOcean; oceanSwitch.translatesAutoresizingMaskIntoConstraints = NO; [oceanSwitch addTarget:self action:@selector(toggleCleanOcean:) forControlEvents:UIControlEventValueChanged]; [ocean addSubview:oceanSwitch];
    UIButton *oceanTasks = [self settingsButtonWithTitle:@"神奇海洋（自动任务）" detail:@"自动完成海洋日常任务与拼图领奖" icon:@"sparkles.rectangle.stack.fill" action:nil];
    UISwitch *oceanTasksSwitch = [[UISwitch alloc] init]; oceanTasksSwitch.on = AntForestManager.sharedInstance.enableAutoOceanTasks; oceanTasksSwitch.translatesAutoresizingMaskIntoConstraints = NO; [oceanTasksSwitch addTarget:self action:@selector(toggleAutoOceanTasks:) forControlEvents:UIControlEventValueChanged]; [oceanTasks addSubview:oceanTasksSwitch];
    UIButton *reward = [self settingsButtonWithTitle:@"领奖励 & 森林寻宝" detail:@"自动浏览任务、奖励领取、森林寻宝需手动进入才能触发自动浏览任务。" icon:@"gift.fill" action:nil];
    UISwitch *rewardSwitch = [[UISwitch alloc] init]; rewardSwitch.on = AntForestManager.sharedInstance.enableAutoRewardTasks; rewardSwitch.translatesAutoresizingMaskIntoConstraints = NO; [rewardSwitch addTarget:self action:@selector(toggleAutoRewardTasks:) forControlEvents:UIControlEventValueChanged]; [reward addSubview:rewardSwitch];
    
    UIButton *aiFish = [self settingsButtonWithTitle:@"AI摸鱼（任务与机会）" detail:@"手动进入AI摸鱼自动完成奖励任务并领取" icon:@"fish.fill" action:nil];
    UISwitch *aiFishSwitch = [[UISwitch alloc] init]; aiFishSwitch.on = AntForestManager.sharedInstance.enableAutoAIFish; aiFishSwitch.translatesAutoresizingMaskIntoConstraints = NO; [aiFishSwitch addTarget:self action:@selector(toggleAutoAIFish:) forControlEvents:UIControlEventValueChanged]; [aiFish addSubview:aiFishSwitch];
    
    UIButton *farmTasks = [self settingsButtonWithTitle:@"芭芭农场（做任务集肥料）" detail:@"手动进入芭芭农场后自动做部分浏览任务、游戏、连续签到和肥料领取。" icon:@"leaf.circle.fill" action:nil];
    UISwitch *farmTasksSwitch = [[UISwitch alloc] init]; farmTasksSwitch.on = AntForestManager.sharedInstance.enableAutoFarmTasks; farmTasksSwitch.translatesAutoresizingMaskIntoConstraints = NO; [farmTasksSwitch addTarget:self action:@selector(toggleAutoFarmTasks:) forControlEvents:UIControlEventValueChanged]; [farmTasks addSubview:farmTasksSwitch];
    
    UIButton *manorTasks = [self settingsButtonWithTitle:@"蚂蚁庄园" detail:@"手动进入蚂蚁庄园后点击领饲料自动做部分任务、喂养与收饲料" icon:@"oval.portrait.fill" action:nil];
    UISwitch *manorTasksSwitch = [[UISwitch alloc] init]; manorTasksSwitch.on = AntForestManager.sharedInstance.enableAutoManor; manorTasksSwitch.translatesAutoresizingMaskIntoConstraints = NO; [manorTasksSwitch addTarget:self action:@selector(toggleAutoManor:) forControlEvents:UIControlEventValueChanged]; [manorTasks addSubview:manorTasksSwitch];
    
    UIButton *patrolNew = [self settingsButtonWithTitle:@"新版保护地（大富翁）" detail:@"手动进入保护地后自动完成更多巡护步数任务" icon:@"dice.fill" action:nil];
    UISwitch *patrolNewSwitch = [[UISwitch alloc] init]; patrolNewSwitch.on = AntForestManager.sharedInstance.enableAutoPatrolNew; patrolNewSwitch.translatesAutoresizingMaskIntoConstraints = NO; [patrolNewSwitch addTarget:self action:@selector(toggleAutoPatrolNew:) forControlEvents:UIControlEventValueChanged]; [patrolNew addSubview:patrolNewSwitch];
    
    [contentView addSubview:schedule]; [contentView addSubview:step]; [contentView addSubview:water]; [contentView addSubview:revive]; [contentView addSubview:earn]; [contentView addSubview:ocean]; [contentView addSubview:oceanTasks]; [contentView addSubview:reward]; [contentView addSubview:aiFish]; [contentView addSubview:farmTasks]; [contentView addSubview:manorTasks]; [contentView addSubview:patrolNew];
    [NSLayoutConstraint activateConstraints:@[
        [contentView.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor],
        [contentView.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor],
        [contentView.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor],
        [contentView.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor],
        [contentView.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor],
        
        [schedule.topAnchor constraintEqualToAnchor:contentView.topAnchor constant:16], [schedule.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:16], [schedule.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-16], [schedule.heightAnchor constraintEqualToConstant:70],
        [step.topAnchor constraintEqualToAnchor:schedule.bottomAnchor constant:12], [step.leadingAnchor constraintEqualToAnchor:schedule.leadingAnchor], [step.trailingAnchor constraintEqualToAnchor:schedule.trailingAnchor], [step.heightAnchor constraintEqualToConstant:70],
        [water.topAnchor constraintEqualToAnchor:step.bottomAnchor constant:12], [water.leadingAnchor constraintEqualToAnchor:schedule.leadingAnchor], [water.trailingAnchor constraintEqualToAnchor:schedule.trailingAnchor], [water.heightAnchor constraintEqualToConstant:70],
        [revive.topAnchor constraintEqualToAnchor:water.bottomAnchor constant:12], [revive.leadingAnchor constraintEqualToAnchor:schedule.leadingAnchor], [revive.trailingAnchor constraintEqualToAnchor:schedule.trailingAnchor], [revive.heightAnchor constraintEqualToConstant:70],
        [earn.topAnchor constraintEqualToAnchor:revive.bottomAnchor constant:12], [earn.leadingAnchor constraintEqualToAnchor:schedule.leadingAnchor], [earn.trailingAnchor constraintEqualToAnchor:schedule.trailingAnchor], [earn.heightAnchor constraintEqualToConstant:70],
        [ocean.topAnchor constraintEqualToAnchor:earn.bottomAnchor constant:12], [ocean.leadingAnchor constraintEqualToAnchor:schedule.leadingAnchor], [ocean.trailingAnchor constraintEqualToAnchor:schedule.trailingAnchor], [ocean.heightAnchor constraintEqualToConstant:70],
        [oceanTasks.topAnchor constraintEqualToAnchor:ocean.bottomAnchor constant:12], [oceanTasks.leadingAnchor constraintEqualToAnchor:schedule.leadingAnchor], [oceanTasks.trailingAnchor constraintEqualToAnchor:schedule.trailingAnchor], [oceanTasks.heightAnchor constraintEqualToConstant:70],
        [reward.topAnchor constraintEqualToAnchor:oceanTasks.bottomAnchor constant:12], [reward.leadingAnchor constraintEqualToAnchor:schedule.leadingAnchor], [reward.trailingAnchor constraintEqualToAnchor:schedule.trailingAnchor], [reward.heightAnchor constraintEqualToConstant:70],
        [aiFish.topAnchor constraintEqualToAnchor:reward.bottomAnchor constant:12], [aiFish.leadingAnchor constraintEqualToAnchor:schedule.leadingAnchor], [aiFish.trailingAnchor constraintEqualToAnchor:schedule.trailingAnchor], [aiFish.heightAnchor constraintEqualToConstant:70],
        [farmTasks.topAnchor constraintEqualToAnchor:aiFish.bottomAnchor constant:12], [farmTasks.leadingAnchor constraintEqualToAnchor:schedule.leadingAnchor], [farmTasks.trailingAnchor constraintEqualToAnchor:schedule.trailingAnchor], [farmTasks.heightAnchor constraintEqualToConstant:70],
        [manorTasks.topAnchor constraintEqualToAnchor:farmTasks.bottomAnchor constant:12], [manorTasks.leadingAnchor constraintEqualToAnchor:schedule.leadingAnchor], [manorTasks.trailingAnchor constraintEqualToAnchor:schedule.trailingAnchor], [manorTasks.heightAnchor constraintEqualToConstant:70],
        [patrolNew.topAnchor constraintEqualToAnchor:manorTasks.bottomAnchor constant:12], [patrolNew.leadingAnchor constraintEqualToAnchor:schedule.leadingAnchor], [patrolNew.trailingAnchor constraintEqualToAnchor:schedule.trailingAnchor], [patrolNew.heightAnchor constraintEqualToConstant:70],
        [patrolNew.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor constant:-24],
        
        [reviveSwitch.trailingAnchor constraintEqualToAnchor:revive.trailingAnchor constant:-18], [reviveSwitch.centerYAnchor constraintEqualToAnchor:revive.centerYAnchor],
        [earnSwitch.trailingAnchor constraintEqualToAnchor:earn.trailingAnchor constant:-18], [earnSwitch.centerYAnchor constraintEqualToAnchor:earn.centerYAnchor],
        [oceanSwitch.trailingAnchor constraintEqualToAnchor:ocean.trailingAnchor constant:-18], [oceanSwitch.centerYAnchor constraintEqualToAnchor:ocean.centerYAnchor],
        [oceanTasksSwitch.trailingAnchor constraintEqualToAnchor:oceanTasks.trailingAnchor constant:-18], [oceanTasksSwitch.centerYAnchor constraintEqualToAnchor:oceanTasks.centerYAnchor],
        [rewardSwitch.trailingAnchor constraintEqualToAnchor:reward.trailingAnchor constant:-18], [rewardSwitch.centerYAnchor constraintEqualToAnchor:reward.centerYAnchor],
        [aiFishSwitch.trailingAnchor constraintEqualToAnchor:aiFish.trailingAnchor constant:-18], [aiFishSwitch.centerYAnchor constraintEqualToAnchor:aiFish.centerYAnchor],
        [farmTasksSwitch.trailingAnchor constraintEqualToAnchor:farmTasks.trailingAnchor constant:-18], [farmTasksSwitch.centerYAnchor constraintEqualToAnchor:farmTasks.centerYAnchor],
        [manorTasksSwitch.trailingAnchor constraintEqualToAnchor:manorTasks.trailingAnchor constant:-18], [manorTasksSwitch.centerYAnchor constraintEqualToAnchor:manorTasks.centerYAnchor],
        [patrolNewSwitch.trailingAnchor constraintEqualToAnchor:patrolNew.trailingAnchor constant:-18], [patrolNewSwitch.centerYAnchor constraintEqualToAnchor:patrolNew.centerYAnchor],
    ]];
}

- (UIButton *)settingsButtonWithTitle:(NSString *)title detail:(NSString *)detail icon:(NSString *)icon action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem]; button.backgroundColor = UIColor.systemBackgroundColor; button.layer.cornerRadius = 16; button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft; button.translatesAutoresizingMaskIntoConstraints = NO; if (action) [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    UIImageView *image = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:icon]]; image.tintColor = [UIColor colorWithRed:0.07 green:0.31 blue:0.18 alpha:1.0]; image.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *titleLabel = [[UILabel alloc] init]; titleLabel.text = title; titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]; titleLabel.textColor = UIColor.labelColor; titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *detailLabel = [[UILabel alloc] init]; detailLabel.text = detail; detailLabel.font = [UIFont systemFontOfSize:11]; detailLabel.textColor = UIColor.secondaryLabelColor; detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    detailLabel.numberOfLines = 2;
    detailLabel.adjustsFontSizeToFitWidth = YES;
    detailLabel.minimumScaleFactor = 0.75;
    UIImageView *chevron = action ? [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]] : nil; chevron.tintColor = UIColor.systemGray3Color; chevron.translatesAutoresizingMaskIntoConstraints = NO;
    [button addSubview:image]; [button addSubview:titleLabel]; [button addSubview:detailLabel]; if (chevron) [button addSubview:chevron];
    [NSLayoutConstraint activateConstraints:@[
        [image.leadingAnchor constraintEqualToAnchor:button.leadingAnchor constant:18], [image.centerYAnchor constraintEqualToAnchor:button.centerYAnchor], [image.widthAnchor constraintEqualToConstant:22], [image.heightAnchor constraintEqualToConstant:22],
        [titleLabel.topAnchor constraintEqualToAnchor:button.topAnchor constant:12], [titleLabel.leadingAnchor constraintEqualToAnchor:image.trailingAnchor constant:12],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:button.trailingAnchor constant:-76],
        [detailLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:3], [detailLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [detailLabel.trailingAnchor constraintLessThanOrEqualToAnchor:button.trailingAnchor constant:-76],
    ]];
    if (chevron) [NSLayoutConstraint activateConstraints:@[[chevron.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-18], [chevron.centerYAnchor constraintEqualToAnchor:button.centerYAnchor]]];
    return button;
}

- (void)showSchedule { [self.navigationController pushViewController:[[AntForestSchedulePanel alloc] init] animated:YES]; }
- (void)showStepSimulator { [self.navigationController pushViewController:[[AntForestStepSimulatorPanel alloc] init] animated:YES]; }
- (void)showWater { [self.navigationController pushViewController:[[AntForestWaterPanel alloc] init] animated:YES]; }
- (void)toggleAutoRevive:(UISwitch *)sender { AntForestManager.sharedInstance.enableAutoRevive = sender.on; [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:@"enableAutoRevive"]; [AntForestManager.sharedInstance recordStage:[NSString stringWithFormat:@"复活能量 · 功能已%@", sender.on ? @"开启" : @"关闭"]]; }
- (void)toggleAutoEarn:(UISwitch *)sender { AntForestManager.sharedInstance.enableAutoEarn = sender.on; [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:@"enableAutoEarn"]; [AntForestManager.sharedInstance recordStage:[NSString stringWithFormat:@"打地鼠 · 功能已%@", sender.on ? @"开启" : @"关闭"]]; }
- (void)toggleCleanOcean:(UISwitch *)sender { AntForestManager.sharedInstance.enableCleanOcean = sender.on; [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:@"enableCleanOcean"]; [AntForestManager.sharedInstance recordStage:[NSString stringWithFormat:@"神奇海洋 · 自动清理已%@", sender.on ? @"开启" : @"关闭"]]; }
- (void)toggleAutoOceanTasks:(UISwitch *)sender { AntForestManager.sharedInstance.enableAutoOceanTasks = sender.on; [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:@"enableAutoOceanTasks"]; [AntForestManager.sharedInstance recordStage:[NSString stringWithFormat:@"神奇海洋 · 自动任务已%@", sender.on ? @"开启" : @"关闭"]]; }
- (void)toggleAutoRewardTasks:(UISwitch *)sender { AntForestManager.sharedInstance.enableAutoRewardTasks = sender.on; [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:@"enableAutoRewardTasks"]; [AntForestManager.sharedInstance recordStage:[NSString stringWithFormat:@"领奖励与森林寻宝 · 自动处理已%@", sender.on ? @"开启" : @"关闭"]]; }
- (void)toggleAutoAIFish:(UISwitch *)sender { AntForestManager.sharedInstance.enableAutoAIFish = sender.on; [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:@"enableAutoAIFish"]; [AntForestManager.sharedInstance recordStage:[NSString stringWithFormat:@"AI摸鱼 · 功能已%@", sender.on ? @"开启" : @"关闭"]]; }
- (void)toggleAutoFarmTasks:(UISwitch *)sender { AntForestManager.sharedInstance.enableAutoFarmTasks = sender.on; [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:@"enableAutoFarmTasks"]; [AntForestManager.sharedInstance recordStage:[NSString stringWithFormat:@"芭芭农场 · 做任务集肥料已%@", sender.on ? @"开启" : @"关闭"]]; }
- (void)toggleAutoManor:(UISwitch *)sender { AntForestManager.sharedInstance.enableAutoManor = sender.on; [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:@"enableAutoManor"]; [AntForestManager.sharedInstance recordStage:[NSString stringWithFormat:@"蚂蚁庄园 · 功能已%@", sender.on ? @"开启" : @"关闭"]]; }
- (void)toggleAutoPatrolNew:(UISwitch *)sender { AntForestManager.sharedInstance.enableAutoPatrolNew = sender.on; [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:@"enableAutoPatrolNew"]; [AntForestManager.sharedInstance recordStage:[NSString stringWithFormat:@"新版保护地（大富翁） · 功能已%@", sender.on ? @"开启" : @"关闭"]]; }
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

    UIButton *settingsButton = [self topBarButtonWithIcon:@"gearshape.fill" action:@selector(showSettings) accessibilityLabel:@"功能设置"];
    UIButton *copyButton = [self topBarButtonWithIcon:@"doc.on.doc.fill" action:@selector(copyDiagnosticLogs:) accessibilityLabel:@"复制日志"];
    UIButton *clearButton = [self topBarButtonWithIcon:@"trash.fill" action:@selector(clearLogs) accessibilityLabel:@"清空日志"];

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
    autoLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    autoLabel.textColor = UIColor.labelColor;
    UILabel *autoDetail = [[UILabel alloc] init];
    autoDetail.text = @"智能扫描成熟能量并自动拾取";
    autoDetail.font = [UIFont systemFontOfSize:12];
    autoDetail.textColor = UIColor.secondaryLabelColor;
    autoDetail.adjustsFontSizeToFitWidth = YES;
    autoDetail.minimumScaleFactor = 0.8;
    UIStackView *autoText = [[UIStackView alloc] initWithArrangedSubviews:@[autoLabel, autoDetail]];
    autoText.axis = UILayoutConstraintAxisVertical;
    autoText.spacing = 3;
    UISwitch *autoSwitch = [[UISwitch alloc] init];
    autoSwitch.on = ((AntForestManager *)[AntForestManager sharedInstance]).enableAutoCollect;
    [autoSwitch addTarget:self action:@selector(toggleAutoCollect:) forControlEvents:UIControlEventValueChanged];
    UIStackView *autoLeading = [[UIStackView alloc] initWithArrangedSubviews:@[autoIcon, autoText]];
    autoLeading.spacing = 10;
    autoLeading.alignment = UIStackViewAlignmentCenter;
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.text = autoSwitch.on ? @"运行中" : @"已关闭";
    self.statusLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    UIStackView *autoTrailing = [[UIStackView alloc] initWithArrangedSubviews:@[autoSwitch, self.statusLabel]];
    autoTrailing.axis = UILayoutConstraintAxisVertical;
    autoTrailing.alignment = UIStackViewAlignmentCenter;
    autoTrailing.spacing = 2;
    [autoTrailing.widthAnchor constraintEqualToConstant:51].active = YES;
    UIStackView *autoRow = [[UIStackView alloc] initWithArrangedSubviews:@[autoLeading, autoTrailing]];
    autoRow.alignment = UIStackViewAlignmentCenter;
    autoRow.distribution = UIStackViewDistributionEqualSpacing;
    autoRow.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *selfIcon = [self iconWithName:@"person.fill" size:24];
    UILabel *selfLabel = [[UILabel alloc] init];
    selfLabel.text = @"收取自己能量";
    selfLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    selfLabel.textColor = UIColor.labelColor;
    UILabel *selfDetail = [[UILabel alloc] init];
    selfDetail.text = @"优先收取本人森林产生的成熟能量";
    selfDetail.font = [UIFont systemFontOfSize:12];
    selfDetail.textColor = UIColor.secondaryLabelColor;
    selfDetail.adjustsFontSizeToFitWidth = YES;
    selfDetail.minimumScaleFactor = 0.8;
    UIStackView *selfText = [[UIStackView alloc] initWithArrangedSubviews:@[selfLabel, selfDetail]];
    selfText.axis = UILayoutConstraintAxisVertical;
    selfText.spacing = 3;
    UISwitch *selfSwitch = [[UISwitch alloc] init];
    selfSwitch.on = [AntForestManager sharedInstance].enableSelfCollect;
    [selfSwitch addTarget:self action:@selector(toggleSelfCollect:) forControlEvents:UIControlEventValueChanged];
    UIStackView *selfLeading = [[UIStackView alloc] initWithArrangedSubviews:@[selfIcon, selfText]];
    selfLeading.spacing = 10; selfLeading.alignment = UIStackViewAlignmentCenter;
    UIStackView *selfRow = [[UIStackView alloc] initWithArrangedSubviews:@[selfLeading, selfSwitch]];
    selfRow.alignment = UIStackViewAlignmentCenter; selfRow.distribution = UIStackViewDistributionEqualSpacing; selfRow.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *rainIcon = [self iconWithName:@"cloud.rain.fill" size:24];
    UILabel *rainLabel = [[UILabel alloc] init];
    rainLabel.text = @"自动能量雨";
    rainLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    rainLabel.textColor = UIColor.labelColor;
    UILabel *rainDetail = [[UILabel alloc] init];
    rainDetail.text = @"手动进入能量雨后自动点击能量雨滴";
    rainDetail.font = [UIFont systemFontOfSize:12];
    rainDetail.textColor = UIColor.secondaryLabelColor;
    rainDetail.adjustsFontSizeToFitWidth = YES;
    rainDetail.minimumScaleFactor = 0.8;
    UIStackView *rainText = [[UIStackView alloc] initWithArrangedSubviews:@[rainLabel, rainDetail]];
    rainText.axis = UILayoutConstraintAxisVertical;
    rainText.spacing = 3;
    UISwitch *rainSwitch = [[UISwitch alloc] init];
    rainSwitch.on = ((AntForestManager *)[AntForestManager sharedInstance]).enableAutoRain;
    [rainSwitch addTarget:self action:@selector(toggleAutoRain:) forControlEvents:UIControlEventValueChanged];
    UIStackView *rainLeading = [[UIStackView alloc] initWithArrangedSubviews:@[rainIcon, rainText]];
    rainLeading.spacing = 10;
    rainLeading.alignment = UIStackViewAlignmentCenter;
    UIStackView *rainRow = [[UIStackView alloc] initWithArrangedSubviews:@[rainLeading, rainSwitch]];
    rainRow.alignment = UIStackViewAlignmentCenter;
    rainRow.distribution = UIStackViewDistributionEqualSpacing;
    rainRow.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *loopIcon = [self iconWithName:@"clock.arrow.circlepath" size:24];
    UILabel *loopLabel = [[UILabel alloc] init];
    loopLabel.text = @"后台循环";
    loopLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    loopLabel.textColor = UIColor.labelColor;
    UILabel *loopDetail = [[UILabel alloc] init];
    loopDetail.text = @"按设定间隔在后台定时静默轮询";
    loopDetail.font = [UIFont systemFontOfSize:12];
    loopDetail.textColor = UIColor.secondaryLabelColor;
    loopDetail.adjustsFontSizeToFitWidth = YES;
    loopDetail.minimumScaleFactor = 0.8;
    UIStackView *loopText = [[UIStackView alloc] initWithArrangedSubviews:@[loopLabel, loopDetail]];
    loopText.axis = UILayoutConstraintAxisVertical;
    loopText.spacing = 3;
    UIButton *intervalButton = [UIButton buttonWithType:UIButtonTypeSystem];
    intervalButton.layer.borderWidth = 1; intervalButton.layer.borderColor = UIColor.systemGray5Color.CGColor; intervalButton.layer.cornerRadius = 10;
    intervalButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [intervalButton addTarget:self action:@selector(showIntervalSettings) forControlEvents:UIControlEventTouchUpInside];
    self.intervalButton = intervalButton;
    [self updateIntervalLabel];
    UISwitch *loopSwitch = [[UISwitch alloc] init];
    loopSwitch.on = [AntForestManager sharedInstance].enableBackgroundLoop;
    [loopSwitch addTarget:self action:@selector(toggleBackgroundLoop:) forControlEvents:UIControlEventValueChanged];
    UIStackView *loopLeading = [[UIStackView alloc] initWithArrangedSubviews:@[loopIcon, loopText]];
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
    UILabel *versionLabel = [[UILabel alloc] init];
    versionLabel.text = @"当前版本：v3.0 正式版";
    versionLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    versionLabel.textColor = [UIColor systemGray2Color];
    versionLabel.textAlignment = NSTextAlignmentCenter;
    versionLabel.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:titleIcon];
    [self.view addSubview:title];
    [self.view addSubview:settingsButton];
    [self.view addSubview:copyButton];
    [self.view addSubview:clearButton];
    [self.view addSubview:stats];
    [self.view addSubview:card];
    [self.view addSubview:self.tableView];
    [self.view addSubview:versionLabel];
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
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:settingsButton.leadingAnchor constant:-10],
        [settingsButton.trailingAnchor constraintEqualToAnchor:copyButton.leadingAnchor constant:-8],
        [settingsButton.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [copyButton.trailingAnchor constraintEqualToAnchor:clearButton.leadingAnchor constant:-8],
        [copyButton.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [clearButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [clearButton.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [stats.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:18],
        [stats.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [stats.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [card.topAnchor constraintEqualToAnchor:stats.bottomAnchor constant:18],
        [card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        
        [autoRow.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [autoRow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [autoRow.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [autoLeading.trailingAnchor constraintLessThanOrEqualToAnchor:autoTrailing.leadingAnchor constant:-10],
        
        [selfRow.topAnchor constraintEqualToAnchor:autoRow.bottomAnchor constant:14],
        [selfRow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [selfRow.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [selfLeading.trailingAnchor constraintLessThanOrEqualToAnchor:selfSwitch.leadingAnchor constant:-10],
        
        [divider0.topAnchor constraintEqualToAnchor:selfRow.topAnchor constant:-7],
        [divider0.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16], [divider0.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16], [divider0.heightAnchor constraintEqualToConstant:1],
        
        [rainRow.topAnchor constraintEqualToAnchor:selfRow.bottomAnchor constant:14],
        [rainRow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [rainRow.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [rainLeading.trailingAnchor constraintLessThanOrEqualToAnchor:rainSwitch.leadingAnchor constant:-10],
        
        [divider1.topAnchor constraintEqualToAnchor:rainRow.topAnchor constant:-7],
        [divider1.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16], [divider1.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16], [divider1.heightAnchor constraintEqualToConstant:1],
        
        [loopRow.topAnchor constraintEqualToAnchor:rainRow.bottomAnchor constant:14],
        [loopRow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [loopRow.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [loopLeading.trailingAnchor constraintLessThanOrEqualToAnchor:loopControls.leadingAnchor constant:-10],
        
        [divider2.topAnchor constraintEqualToAnchor:loopRow.topAnchor constant:-7],
        [divider2.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16], [divider2.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16], [divider2.heightAnchor constraintEqualToConstant:1],
        
        [card.bottomAnchor constraintEqualToAnchor:loopRow.bottomAnchor constant:12],
        [self.tableView.topAnchor constraintEqualToAnchor:card.bottomAnchor constant:8],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.tableView.bottomAnchor constraintEqualToAnchor:versionLabel.topAnchor constant:-6],
        [versionLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [versionLabel.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-4],
    ]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onLogUpdated) name:@"LogUpdated" object:nil];
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

- (UIButton *)topBarButtonWithIcon:(NSString *)iconName action:(SEL)action accessibilityLabel:(NSString *)label {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
    UIImage *img = [UIImage systemImageNamed:iconName withConfiguration:config];
    [btn setImage:img forState:UIControlStateNormal];
    btn.tintColor = [UIColor colorWithRed:0.07 green:0.31 blue:0.18 alpha:1.0];
    btn.backgroundColor = [UIColor colorWithRed:0.07 green:0.31 blue:0.18 alpha:0.08];
    btn.layer.cornerRadius = 17;
    btn.layer.masksToBounds = YES;
    btn.accessibilityLabel = label;
    if (action) [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    [btn.widthAnchor constraintEqualToConstant:34].active = YES;
    [btn.heightAnchor constraintEqualToConstant:34].active = YES;
    return btn;
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

- (void)onLogUpdated {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(refresh) object:nil];
    [self performSelector:@selector(refresh) withObject:nil afterDelay:0.15];
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清理选项" message:@"请选择您需要执行的清理操作：" preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"仅清空运行日志（保留今日/累计克数）" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        AntForestManager *manager = [AntForestManager sharedInstance];
        [manager.logRecord removeAllObjects];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"logRecord"];
        [manager clearProbeLogs];
        [self refresh];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"清空日志并重置能量统计克数" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        AntForestManager *manager = [AntForestManager sharedInstance];
        [manager.logRecord removeAllObjects];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"logRecord"];
        [manager clearProbeLogs];
        manager.todayCollectedEnergy = 0;
        manager.totalCollectedEnergy = 0;
        [[NSUserDefaults standardUserDefaults] setInteger:0 forKey:@"todayCollectedEnergy"];
        [[NSUserDefaults standardUserDefaults] setInteger:0 forKey:@"totalCollectedEnergy"];
        [self refresh];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    }
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)copyDiagnosticLogs:(UIButton *)sender {
    AntForestManager *manager = AntForestManager.sharedInstance;
    NSArray *logs = manager.logRecord.reverseObjectEnumerator.allObjects;
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSString *log, __unused NSDictionary *bindings) {
        return log.length > 0 && ![log containsString:@"[Diag]"] && ![log containsString:@"诊断 ·"];
    }];
    NSArray *records = [logs filteredArrayUsingPredicate:predicate];
    NSString *header = [NSString stringWithFormat:@"AntForestPort-Ocean 收取日志\n导出时间：%@\n配置：自动收取=%@，收取自己=%@，自动能量雨=%@，赚能量（打地鼠玩法）=%@，神奇海洋清理=%@，神奇海洋任务=%@，领奖励与森林寻宝=%@，AI摸鱼=%@，芭芭农场做任务集肥料=%@，蚂蚁庄园=%@，新版保护地（大富翁）=%@，自动复活好友过期能量=%@，后台循环=%@，循环间隔=%ld 秒，定时收取=%@，打开蚂蚁森林自动浇水=%@，定时自动浇水=%@（%ld g，%lu 位好友），步数模拟=%@\n统计：今日=%ld g，累计=%ld g，日志条目=%lu\n\n",
                      getCurrentDateTimeString(), manager.enableAutoCollect ? @"开" : @"关", manager.enableSelfCollect ? @"开" : @"关", manager.enableAutoRain ? @"开" : @"关", manager.enableAutoEarn ? @"开" : @"关", manager.enableCleanOcean ? @"开" : @"关", manager.enableAutoOceanTasks ? @"开" : @"关", manager.enableAutoRewardTasks ? @"开" : @"关", manager.enableAutoAIFish ? @"开" : @"关", manager.enableAutoFarmTasks ? @"开" : @"关", manager.enableAutoManor ? @"开" : @"关", manager.enableAutoPatrolNew ? @"开" : @"关", manager.enableAutoRevive ? @"开" : @"关", manager.enableBackgroundLoop ? @"开" : @"关", (long)manager.collectInterval, manager.enableScheduledCollect ? @"开" : @"关", manager.enableWaterOnLaunch ? @"开" : @"关", manager.enableAutoWater ? @"开" : @"关", (long)manager.waterGrams, (unsigned long)manager.waterFriendIds.count, AFStepSimulator.shared.enabled ? @"开" : @"关", (long)manager.todayCollectedEnergy, (long)manager.totalCollectedEnergy, (unsigned long)records.count];
    NSMutableString *fullOutput = [NSMutableString stringWithString:header];
    if (records.count) {
        [fullOutput appendString:[records componentsJoinedByString:@"\n\n"]];
    } else {
        [fullOutput appendString:@"没有常规收取日志\n"];
    }
    
    NSArray *probes = manager.probeRecords;
    if (probes.count) {
        [fullOutput appendFormat:@"\n\n========================================\n📋 全量抓包探针数据（共 %lu 条）\n========================================\n\n", (unsigned long)probes.count];
        [fullOutput appendString:[probes componentsJoinedByString:@"\n\n"]];
    }
    
    UIPasteboard.generalPasteboard.string = fullOutput;
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
    if (!presenter) presenter = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter) return;
    AntForestLogPanel *panel = [[AntForestLogPanel alloc] init];
    panel.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 16.0, *)) {
        panel.sheetPresentationController.detents = @[[UISheetPresentationControllerDetent customDetentWithIdentifier:@"log" resolver:^CGFloat(id<UISheetPresentationControllerDetentResolutionContext> context) { return 600; }]];
    } else if (@available(iOS 15.0, *)) {
        panel.sheetPresentationController.detents = @[[UISheetPresentationControllerDetent mediumDetent], [UISheetPresentationControllerDetent largeDetent]];
        if ([UIScreen mainScreen].bounds.size.height <= 736) {
            panel.sheetPresentationController.selectedDetentIdentifier = UISheetPresentationControllerDetentIdentifierLarge;
        }
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
    if (!controller.view) return;
    
    UIWindow *window = controller.view.window;
    if (!window) window = [UIApplication sharedApplication].keyWindow;
    if (!window && [UIApplication sharedApplication].windows.count > 0) {
        window = [UIApplication sharedApplication].windows.firstObject;
    }
    
    // 全局 Window 层级防重：保证全局有且仅有一个叶子按钮
    UIButton *existingButton = nil;
    if (window) {
        existingButton = (UIButton *)[window viewWithTag:AntForestButtonTag];
    }
    if (!existingButton && controller.view) {
        existingButton = (UIButton *)[controller.view viewWithTag:AntForestButtonTag];
    }
    
    if (existingButton) {
        if (reveal) {
            expandButton(existingButton);
            scheduleButtonCollapse(existingButton);
        }
        return;
    }
    
    NSString *clsName = NSStringFromClass(controller.class);
    if (![controller isKindOfClass:NSClassFromString(@"H5WebViewController")] &&
        ![clsName containsString:@"Launcher"] &&
        ![clsName isEqualToString:@"DTViewController"]) {
        return;
    }
    
    UIView *parentView = window ?: controller.view;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = AntForestButtonTag;
    button.tintColor = UIColor.whiteColor;
    button.backgroundColor = [UIColor colorWithRed:0.06 green:0.22 blue:0.14 alpha:0.92];
    button.layer.cornerRadius = 24;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.2;
    button.layer.shadowRadius = 8;
    button.frame = CGRectMake(parentView.bounds.size.width - 64, parentView.safeAreaInsets.top + 160, 48, 48);
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    UIImage *image = [UIImage systemImageNamed:@"leaf.fill"];
    [button setImage:image forState:UIControlStateNormal];
    [parentView addSubview:button];
    [button addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        if (buttonIsCollapsed(button)) { expandButton(button); scheduleButtonCollapse(button); }
        else showLogPanel(button);
    }] forControlEvents:UIControlEventTouchUpInside];
    CGFloat savedX = [[NSUserDefaults standardUserDefaults] floatForKey:AntForestButtonXKey];
    CGFloat savedY = [[NSUserDefaults standardUserDefaults] floatForKey:AntForestButtonYKey];
    if (savedX > 0 && savedY > 0) button.center = CGPointMake(savedX * parentView.bounds.size.width, savedY * parentView.bounds.size.height);
    
    Class targetClass = parentView.class;
    if (!class_getInstanceMethod(targetClass, @selector(antforestHandlePan:))) {
        class_addMethod(targetClass, @selector(antforestHandlePan:), (IMP)handleButtonPan, "v@:@");
    }
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:parentView action:@selector(antforestHandlePan:)];
    [button addGestureRecognizer:pan];
    if (reveal) scheduleButtonCollapse(button);
    else setButtonCollapsed(button, YES, NO);
}

static id unarchiveDataSafe(NSData *data, Class primaryClass) {
    if (!data) return nil;
    NSError *error = nil;
    NSSet *classes = [NSSet setWithArray:@[NSDictionary.class, NSArray.class, NSString.class, NSNumber.class]];
    id obj = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:data error:&error];
    if (!obj) {
        @try {
            obj = [NSKeyedUnarchiver unarchiveObjectWithData:data];
        } @catch (__unused NSException *e) {}
    }
    return [obj isKindOfClass:primaryClass] ? obj : nil;
}

static void initializeManager(void) {
    AntForestManager *manager = [AntForestManager sharedInstance];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSData *bubbles = [defaults objectForKey:@"friendsBubbles"];
    NSData *names = [defaults objectForKey:@"friendsName"];
    NSData *logs = [defaults objectForKey:@"logRecord"];
    NSData *ranks = [defaults objectForKey:@"cachedFriendsRank"];
    manager.friendsBubbles = [unarchiveDataSafe(bubbles, NSDictionary.class) mutableCopy] ?: [NSMutableDictionary dictionary];
    manager.friendsName = [unarchiveDataSafe(names, NSDictionary.class) mutableCopy] ?: [NSMutableDictionary dictionary];
    manager.friendsRank = [unarchiveDataSafe(ranks, NSDictionary.class) mutableCopy] ?: [NSMutableDictionary dictionary];
    manager.logRecord = [unarchiveDataSafe(logs, NSArray.class) mutableCopy] ?: [NSMutableArray array];
    manager.totalCollectedEnergy = [defaults integerForKey:@"totalCollectedEnergy"];
    if (manager.totalCollectedEnergy > 1000000) {
        manager.totalCollectedEnergy = 0;
        [defaults setInteger:0 forKey:@"totalCollectedEnergy"];
    }
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd";
    NSString *today = [formatter stringFromDate:NSDate.date];
    if ([[defaults stringForKey:@"todayCollectedEnergyDate"] isEqualToString:today]) {
        manager.todayCollectedEnergy = [defaults integerForKey:@"todayCollectedEnergy"];
        if (manager.todayCollectedEnergy > 50000) {
            manager.todayCollectedEnergy = 0;
            [defaults setInteger:0 forKey:@"todayCollectedEnergy"];
        }
    } else {
        manager.todayCollectedEnergy = 0;
        [defaults setInteger:0 forKey:@"todayCollectedEnergy"];
        [defaults setObject:today forKey:@"todayCollectedEnergyDate"];
    }
    manager.enableAutoCollect = [defaults boolForKey:@"enableAutoCollect"];
    manager.enableSelfCollect = [defaults objectForKey:@"enableSelfCollect"] ? [defaults boolForKey:@"enableSelfCollect"] : YES;
    manager.enableAutoRain = [defaults objectForKey:@"enableAutoRain"] ? [defaults boolForKey:@"enableAutoRain"] : manager.enableAutoCollect;
    manager.enableAutoEarn = [defaults objectForKey:@"enableAutoEarn"] ? [defaults boolForKey:@"enableAutoEarn"] : YES;
    manager.enableAutoRevive = [defaults objectForKey:@"enableAutoRevive"] ? [defaults boolForKey:@"enableAutoRevive"] : YES;
    manager.enableCleanOcean = [defaults objectForKey:@"enableCleanOcean"] ? [defaults boolForKey:@"enableCleanOcean"] : YES;
    manager.enableAutoOceanTasks = [defaults objectForKey:@"enableAutoOceanTasks"] ? [defaults boolForKey:@"enableAutoOceanTasks"] : YES;
    manager.enableAutoRewardTasks = [defaults objectForKey:@"enableAutoRewardTasks"] ? [defaults boolForKey:@"enableAutoRewardTasks"] : YES;
    manager.enableAutoAIFish = [defaults objectForKey:@"enableAutoAIFish"] ? [defaults boolForKey:@"enableAutoAIFish"] : YES;
    manager.enableAutoFarmTasks = [defaults objectForKey:@"enableAutoFarmTasks"] ? [defaults boolForKey:@"enableAutoFarmTasks"] : YES;
    manager.enableAutoManor = [defaults objectForKey:@"enableAutoManor"] ? [defaults boolForKey:@"enableAutoManor"] : YES;
    manager.enableAutoPatrol = NO;
    manager.enableAutoPatrolNew = [defaults objectForKey:@"enableAutoPatrolNew"] ? [defaults boolForKey:@"enableAutoPatrolNew"] : YES;
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
    NSURL *url = urlFromController(self);
    AntForestManager *manager = [AntForestManager sharedInstance];
    
    // 第一优先级：能量雨快速判定并彻底返回，绝不执行任何森林首页、巡护、寻宝逻辑
    if (isEnergyRain(url, self)) {
        if (manager.enableAutoRain) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                installEnergyRainCollector(self);
            });
        }
        addLogButton(self, NO);
        return;
    }

    BOOL earnEnergy = isEarnEnergyURL(url);
    BOOL forestHome = isForestHomeURL(url) && !earnEnergy;
    BOOL isSelfHome = isSelfForestHomeURL(url) && !earnEnergy;
    id pageBridge = isSelfHome ? forestBridgeFromController(self) : nil;
    if (pageBridge && manager.jsBridge != pageBridge) {
        manager.jsBridge = pageBridge;
        [manager recordStage:@"诊断 · 已绑定森林首页 H5 Bridge"];
    }
    if (isSelfHome) {
        currentForestHomeController = self;
        [manager recordStage:[NSString stringWithFormat:@"诊断 · 森林首页出现：桥接=%d", manager.jsBridge != nil]];
    }
    BOOL revealLeaf = isSelfHome && shouldRevealLeafOnNextForestAppearance;
    if (revealLeaf) shouldRevealLeafOnNextForestAppearance = NO;
    if (isSelfHome && (manager.enableWaterOnLaunch || manager.enableAutoCollect)) {
        startForestHomeWhenBridgeReady(self);
    } else if (forestHome && !isSelfHome) {
        // 在好友森林页面：严禁运行首页动物收集脉冲，自动扫描并关闭“河姆渡福猪”等动物引导弹窗
        NSArray<NSNumber *> *delays = @[@200, @600, @1200, @2000, @3200];
        for (NSNumber *d in delays) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([d integerValue] * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                dismissFriendAnimalPopup(self);
            });
        }
    }
    if (isPatrolURL(url, self) && manager.enableAutoPatrolNew) {
        manager.monopolyDrawerOpened = NO;
        id bridge = rewardBridgeFromController(self) ?: forestBridgeFromController(self);
        if (bridge && [bridge respondsToSelector:@selector(_doFlushMessageQueue:url:)]) {
            manager.monopolyBridge = bridge;
            manager.monopolyH5Url = url.absoluteString;
            [manager recordStage:@"新版保护地：进入保护地界面，已绑定 Bridge"];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            [manager queryMonopolyTaskListWithForce:YES];
            if (!manager.monopolyDrawerOpened) {
                [manager openMonopolyTaskPanelOnWebView];
            }
        });
        NSArray<NSNumber *> *delays = @[@800, @1500, @2500, @4000, @6000];
        for (NSNumber *d in delays) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([d integerValue] * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                NSURL *cur = urlFromController(self);
                if (isPatrolURL(cur, self)) {
                    id b = rewardBridgeFromController(self) ?: forestBridgeFromController(self);
                    if (b && [b respondsToSelector:@selector(_doFlushMessageQueue:url:)]) {
                        if (manager.monopolyBridge != b) {
                            manager.monopolyBridge = b;
                            manager.monopolyH5Url = cur.absoluteString ?: url.absoluteString;
                            [manager recordStage:@"新版保护地：轮询中成功就绪并绑定 Bridge"];
                        }
                    }
                    [manager queryMonopolyTaskListWithForce:YES];
                    if (!manager.monopolyDrawerOpened) {
                        [manager openMonopolyTaskPanelOnWebView];
                    }
                    installPatrolAutoPilot(self);
                }
            });
        }
    }
    if (earnEnergy && manager.enableAutoEarn) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            installEarnEnergyCollector(self);
        });
    }
    if (isLotteryURL(url) && manager.enableAutoRewardTasks) {
        id bridge = rewardBridgeFromController(self) ?: forestBridgeFromController(self);
        if (bridge && [bridge respondsToSelector:@selector(_doFlushMessageQueue:url:)]) {
            manager.lotteryBridge = bridge;
            manager.lotteryH5Url = url.absoluteString;
        }
        NSLog(@"[AntForestPort] 🎰 进入森林寻宝，已就绪 Bridge: %@", bridge);
        [manager recordStage:@"森林寻宝：进入寻宝界面，已就绪 Bridge，开始拉取寻宝任务与抽奖机会..."];
        NSArray<NSNumber *> *delays = @[@400, @1200, @2500];
        for (NSNumber *d in delays) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([d integerValue] * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                NSURL *cur = urlFromController(self);
                if (isLotteryURL(cur)) {
                    id b = rewardBridgeFromController(self) ?: forestBridgeFromController(self);
                    if (b && [b respondsToSelector:@selector(_doFlushMessageQueue:url:)]) {
                        manager.lotteryBridge = b;
                        manager.lotteryH5Url = cur.absoluteString;
                    }
                    [manager queryLotteryTaskListWithForce:YES];
                }
            });
        }
    }
    if (isRewardTaskURL(url) && manager.enableAutoRewardTasks) {
        id bridge = rewardBridgeFromController(self) ?: forestBridgeFromController(self);
        if (bridge && [bridge respondsToSelector:@selector(_doFlushMessageQueue:url:)]) {
            manager.rewardTaskBridge = bridge;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(400 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            [manager queryVitalityTaskListWithForce:YES];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1200 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            [manager queryVitalityTaskListWithForce:YES];
        });
    }
    if (isOceanURL(url)) {
        id bridge = rewardBridgeFromController(self) ?: forestBridgeFromController(self);
        if (bridge && [bridge respondsToSelector:@selector(_doFlushMessageQueue:url:)]) {
            manager.oceanBridge = bridge;
            manager.oceanH5Url = url.absoluteString;
        }
        if (manager.enableAutoOceanTasks) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                [manager queryOceanTaskListWithForce:YES];
            });
        }
    }
    if (isAIFishURL(url)) {
        id bridge = rewardBridgeFromController(self) ?: forestBridgeFromController(self);
        if (bridge && [bridge respondsToSelector:@selector(_doFlushMessageQueue:url:)]) {
            manager.aiFishBridge = bridge;
            manager.aiFishH5Url = url.absoluteString;
        }
        if (manager.enableAutoAIFish) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                [manager queryAIFishTaskListWithForce:YES];
            });
        }
    }
    if (isFarmURL(url)) {
        id bridge = rewardBridgeFromController(self) ?: forestBridgeFromController(self);
        if (bridge && [bridge respondsToSelector:@selector(_doFlushMessageQueue:url:)]) {
            manager.farmBridge = bridge;
            manager.farmH5Url = url.absoluteString;
        }
        if (manager.enableAutoFarmTasks) {
            NSLog(@"[AntForestPort] 🌾 进入芭芭农场，已就绪 Bridge: %@", bridge);
            [manager recordStage:@"芭芭农场：进入农场，已就绪 Bridge，开始监听与调度任务/肥料..."];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(800 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                [manager queryFarmTaskListWithForce:YES];
                [manager openFarmTaskPanelOnWebView];
                [manager claimAllVisibleFarmRewardsOnWebView];
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                [manager openFarmTaskPanelOnWebView];
                [manager claimAllVisibleFarmRewardsOnWebView];
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                [manager openFarmTaskPanelOnWebView];
                [manager claimAllVisibleFarmRewardsOnWebView];
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                [manager claimAllVisibleFarmRewardsOnWebView];
            });
        }
    }
    addLogButton(self, revealLeaf);
}

static BOOL isNoiseProbeLog(NSString *log) {
    if (!log) return YES;
    if ([log containsString:@"deliverByPageId"] ||
        [log containsString:@"ANTFOREST_GAME_CENTER_FLOW"] ||
        [log containsString:@"offlineResources"] ||
        [log containsString:@"manifest.json"] ||
        [log containsString:@"runtime."] ||
        [log containsString:@"all_vendor."] ||
        [log containsString:@"galacean_downgrade"] ||
        [log containsString:@"signInWarmCopyConfig"] ||
        [log containsString:@"swiper.min"] ||
        [log containsString:@"dataPrefetch"] ||
        [log containsString:@"contactsDicArray"] ||
        [log containsString:@"recentApps"] ||
        [log containsString:@"systemMemoryLevel"] ||
        [log containsString:@"screenReaderEnabled"] ||
        [log containsString:@"SHOULDUSENEWTOUCHEVENT"] ||
        [log containsString:@"\"safeArea\""] ||
        [log containsString:@"queryFriendHomePage"] ||
        [log containsString:@"setAPDataStorage"] ||
        [log containsString:@"getAPDataStorage"] ||
        [log containsString:@"batchQuerySendTreeItems"] ||
        [log containsString:@"querySendTreeFriendList"]) {
        return YES;
    }
    return NO;
}

static inline BOOL isRelevantPluginURL(NSString *urlStr) {
    if (!urlStr.length) return NO;
    NSString *u = [urlStr lowercaseString];
    return [u containsString:@"forest"] || [u containsString:@"orchard"] || [u containsString:@"farm"] ||
           [u containsString:@"ocean"] || [u containsString:@"aifish"] || [u containsString:@"patrol"] ||
           [u containsString:@"monopoly"] || [u containsString:@"lottery"] || [u containsString:@"draw"] ||
           [u containsString:@"vitality"] || [u containsString:@"antisle"] || [u containsString:@"hsdwy"] ||
           [u containsString:@"manor"] || [u containsString:@"antfarm"] || [u containsString:@"66666674"] || [u containsString:@"2017090512380701"] ||
           [u containsString:@"180020010001247580"] ||
           [u containsString:@"180020010001263018"] || [u containsString:@"180020010001279274"] ||
           [u containsString:@"180020010001290531"] || [u containsString:@"180020010001293606"] ||
           [u containsString:@"2060090000398301"] ||
           [u containsString:@"2021003115672468"];
}

#define ENABLE_PROBE_LOGS 1
#define AFProbeLog(...) do { if (ENABLE_PROBE_LOGS) NSLog(__VA_ARGS__); } while(0)

static const void *PortRPCOriginalIMPKey = &PortRPCOriginalIMPKey;
static id portCallRPC(id self, SEL _cmd, id rpcConfig, id completeBlock) {
    @try {
        NSString *str = nil;
        if ([rpcConfig isKindOfClass:NSString.class]) str = rpcConfig;
        else if ([NSJSONSerialization isValidJSONObject:rpcConfig]) {
            NSData *d = [NSJSONSerialization dataWithJSONObject:rpcConfig options:0 error:nil];
            if (d) str = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        }
        if (!str) str = [rpcConfig description];
        
        if (str.length && !isNoiseProbeLog(str)) {
            AFProbeLog(@"\n🔍 [PatrolProbe-RPC-REQ]\n📦 %@", str);
            [[AntForestManager sharedInstance] recordProbeLog:[NSString stringWithFormat:@"[RPC-REQ] %@", str]];
        }
    } @catch (NSException *e) {}
    
    IMP original = NULL;
    for (Class cls = object_getClass(self); cls && !original; cls = class_getSuperclass(cls)) {
        original = [objc_getAssociatedObject(cls, PortRPCOriginalIMPKey) pointerValue];
    }
    if (original) {
        return ((id (*)(id, SEL, id, id))original)(self, _cmd, rpcConfig, completeBlock);
    }
    return nil;
}

static BOOL hookRPCProbeMethod(Class cls) {
    return NO;
}

static void (*originalDoFlushMessageQueue)(id, SEL, id, id);
static void portDoFlushMessageQueue(id self, SEL _cmd, id msg, id url) {
    @try {
        NSString *urlStr = [url isKindOfClass:NSString.class] ? url : ([url respondsToSelector:@selector(absoluteString)] ? [url absoluteString] : @"");
        if (isRelevantPluginURL(urlStr)) {
            NSString *msgStr = nil;
            if ([msg isKindOfClass:NSString.class]) {
                msgStr = msg;
            } else if ([NSJSONSerialization isValidJSONObject:msg]) {
                NSData *d = [NSJSONSerialization dataWithJSONObject:msg options:0 error:nil];
                if (d) msgStr = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
            }
            if (!msgStr) msgStr = [msg description];
            
            if (msgStr.length) {
                AFProbeLog(@"\n🔍 [PatrolProbe-REQ]\n📍 URL: %@\n📦 Request: %@\n", urlStr, msgStr);
                [[AntForestManager sharedInstance] recordProbeLog:[NSString stringWithFormat:@"[REQ] URL: %@\nData: %@", urlStr, msgStr]];
            }
        }
    } @catch (NSException *e) {}
    
    if (originalDoFlushMessageQueue) {
        originalDoFlushMessageQueue(self, _cmd, msg, url);
    }
}

static void (*originalFlushMessageQueueWithMessage)(id, SEL, id, id);
static void portFlushMessageQueueWithMessage(id self, SEL _cmd, id msg, id url) {
    @try {
        NSString *urlStr = [url isKindOfClass:NSString.class] ? url : ([url respondsToSelector:@selector(absoluteString)] ? [url absoluteString] : @"");
        if (isRelevantPluginURL(urlStr)) {
            NSString *msgStr = nil;
            if ([msg isKindOfClass:NSString.class]) msgStr = msg;
            else if ([NSJSONSerialization isValidJSONObject:msg]) {
                NSData *d = [NSJSONSerialization dataWithJSONObject:msg options:0 error:nil];
                if (d) msgStr = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
            }
            if (!msgStr) msgStr = [msg description];
            if (msgStr.length) {
                AFProbeLog(@"\n🔍 [PatrolProbe-REQ]\n📍 URL: %@\n📦 Request: %@\n", urlStr, msgStr);
                [[AntForestManager sharedInstance] recordProbeLog:[NSString stringWithFormat:@"[REQ] URL: %@\nData: %@", urlStr, msgStr]];
            }
        }
    } @catch (NSException *e) {}
    if (originalFlushMessageQueueWithMessage) originalFlushMessageQueueWithMessage(self, _cmd, msg, url);
}

static id (*originalDeserializeMessageJSON)(id, SEL, id);
static id portDeserializeMessageJSON(id self, SEL _cmd, id json) {
    @try {
        NSString *str = [json isKindOfClass:NSString.class] ? json : [json description];
        if (str.length && !isNoiseProbeLog(str)) {
            AFProbeLog(@"\n🔍 [PatrolProbe-H5REQ]\n📦 %@", str);
            [[AntForestManager sharedInstance] recordProbeLog:[NSString stringWithFormat:@"[H5REQ] %@", str]];
        }
    } @catch (NSException *e) {}
    if (originalDeserializeMessageJSON) return originalDeserializeMessageJSON(self, _cmd, json);
    return nil;
}

static void (*originalRunJsTextInput)(id, SEL, id, id, id, id, id);
static void portRunJsTextInput(id self, SEL _cmd, id webView, id prompt, id defText, id frame, id handler) {
    @try {
        NSString *str = [prompt isKindOfClass:NSString.class] ? prompt : [prompt description];
        if ([str hasPrefix:@"NATIVE_TAP:"]) {
            NSString *coordStr = [str substringFromIndex:11];
            NSArray *parts = [coordStr componentsSeparatedByString:@","];
            if (parts.count == 2 && [webView isKindOfClass:UIView.class]) {
                CGFloat x = [parts[0] doubleValue];
                CGFloat y = [parts[1] doubleValue];
                dispatch_async(dispatch_get_main_queue(), ^{
                    simulateNativeTapOnView((UIView *)webView, CGPointMake(x, y));
                });
            }
            if (handler) {
                void (^completionBlock)(NSString *) = handler;
                completionBlock(nil);
            }
            return;
        }
        if ([str hasPrefix:@"PATROL_LOG:"]) {
            NSString *payload = [str substringFromIndex:11];
            AFProbeLog(@"\n🔍 [PatrolProbe-HOOK]\n📦 %@", payload);
            [[AntForestManager sharedInstance] recordProbeLog:[NSString stringWithFormat:@"[PATROL-HOOK] %@", payload]];
            
            NSDictionary *dict = nil;
            NSData *d = [payload dataUsingEncoding:NSUTF8StringEncoding];
            if (d) dict = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            NSString *type = [dict isKindOfClass:NSDictionary.class] ? dict[@"type"] : nil;
            NSString *msg = [dict isKindOfClass:NSDictionary.class] ? dict[@"msg"] : nil;
            NSString *action = [dict isKindOfClass:NSDictionary.class] ? dict[@"action"] : nil;
            AntForestManager *manager = [AntForestManager sharedInstance];
            
            if ([type isEqualToString:@"STATUS"] && msg.length) {
                if (![msg containsString:@"AlipayJSBridge"]) {
                    [manager recordStage:msg];
                }
                if ([msg containsString:@"展开步数任务抽屉"] || [msg containsString:@"步数任务抽屉"] || [msg containsString:@"更多步数"]) {
                    manager.monopolyDrawerOpened = YES;
                }
            } else if ([action isEqualToString:@"patrol_forward"]) {
                [manager recordStage:[NSString stringWithFormat:@"保护地巡护 · 自动走步（剩余机会 %@ 次）", dict[@"leftChance"] ?: @"1"]];
            } else if ([action isEqualToString:@"quiz_found"]) {
                [manager recordStage:[NSString stringWithFormat:@"保护地巡护 · 智能满分答题（题目：%@）", dict[@"q"] ?: @"科普问答"]];
            } else if ([action isEqualToString:@"exchange_step"]) {
                [manager recordStage:[NSString stringWithFormat:@"保护地巡护 · 自动兑换步数（剩余 %ld 步，今日已兑 %ld 步）", (long)[dict[@"leftStep"] integerValue], (long)[dict[@"usedStep"] integerValue]]];
            } else if ([action isEqualToString:@"skip_dispatch_already_active"]) {
                [manager recordStage:@"保护地巡护 · 已有动物在岗巡护中，自动保护当前动物"];
            } else if ([action isEqualToString:@"dispatch_animal"]) {
                [manager recordStage:[NSString stringWithFormat:@"保护地巡护 · 智能高收益派遣动物（%@）", dict[@"animal"] ?: @"最优物种"]];
            } else if ([action isEqualToString:@"synthesize_animal"]) {
                [manager recordStage:@"保护地巡护 · 自动一键合成物种碎片"];
            } else if ([action isEqualToString:@"all_tasks_finished"]) {
                [manager recordStage:@"保护地巡护 · 今日巡护与步数已全部完成"];
            }
            if (handler) {
                void (^completionBlock)(NSString *) = handler;
                completionBlock(nil);
            }
            return;
        }
        if (str.length && !isNoiseProbeLog(str)) {
            AFProbeLog(@"\n🔍 [PatrolProbe-PROMPT]\n📦 %@", str);
            [[AntForestManager sharedInstance] recordProbeLog:[NSString stringWithFormat:@"[PROMPT] %@", str]];
        }
    } @catch (NSException *e) {}
    if (originalRunJsTextInput) originalRunJsTextInput(self, _cmd, webView, prompt, defText, frame, handler);
}

static void (*originalDispatchMessage)(id, SEL, id);
static void portDispatchMessage(id self, SEL _cmd, id msg) {
    @try {
        NSString *msgStr = nil;
        if ([msg isKindOfClass:NSString.class]) msgStr = msg;
        else if ([NSJSONSerialization isValidJSONObject:msg]) {
            NSData *d = [NSJSONSerialization dataWithJSONObject:msg options:0 error:nil];
            if (d) msgStr = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        }
        if (!msgStr) msgStr = [msg description];
        if (msgStr.length && !isNoiseProbeLog(msgStr)) {
            AFProbeLog(@"\n🔍 [PatrolProbe-DISPATCH]\n📦 %@", msgStr);
            [[AntForestManager sharedInstance] recordProbeLog:[NSString stringWithFormat:@"[DISPATCH] %@", msgStr]];
        }
    } @catch (NSException *e) {}
    if (originalDispatchMessage) originalDispatchMessage(self, _cmd, msg);
}

static void (*originalCallHandler)(id, SEL, id, id, id);
static void portCallHandler(id self, SEL _cmd, id name, id data, id cb) {
    @try {
        NSString *dataStr = nil;
        if ([data isKindOfClass:NSString.class]) dataStr = data;
        else if ([NSJSONSerialization isValidJSONObject:data]) {
            NSData *d = [NSJSONSerialization dataWithJSONObject:data options:0 error:nil];
            if (d) dataStr = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        }
        if (!dataStr) dataStr = [data description];
        if (dataStr.length && !isNoiseProbeLog(dataStr)) {
            AFProbeLog(@"\n🔍 [PatrolProbe-HANDLER: %@]\n📦 %@", name, dataStr);
        }
        [[AntForestManager sharedInstance] recordProbeLog:[NSString stringWithFormat:@"[HANDLER: %@] %@", name, dataStr]];
    } @catch (NSException *e) {}
    if (originalCallHandler) originalCallHandler(self, _cmd, name, data, cb);
}

static NSString *gLastRpcOperationType = nil;
static void (*originalCallJsApi)(id, SEL, id, id, id, id);
static void portCallJsApi(id self, SEL _cmd, id name, id url, id data, id cb) {
    @try {
        NSString *urlStr = [url isKindOfClass:NSString.class] ? url : ([url respondsToSelector:@selector(absoluteString)] ? [url absoluteString] : @"");
        NSString *opType = nil;
        if ([name isEqualToString:@"rpc"]) {
            if ([data isKindOfClass:NSDictionary.class]) {
                opType = data[@"operationType"];
            } else if ([data isKindOfClass:NSArray.class]) {
                NSDictionary *first = [((NSArray *)data).firstObject isKindOfClass:NSDictionary.class] ? ((NSArray *)data).firstObject : nil;
                opType = first[@"operationType"] ?: first[@"data"][@"operationType"];
            }
        }
        if (opType.length) {
            gLastRpcOperationType = [opType copy];
            [AntForestManager sharedInstance].lastRpcOperationType = [opType copy];
        }
        
        BOOL isRelevant = isRelevantPluginURL(urlStr) ||
                          (opType.length && ([opType containsString:@"forest"] || [opType containsString:@"orchard"] || [opType containsString:@"farm"] || [opType containsString:@"antiep"] || [opType containsString:@"ocean"] || [opType containsString:@"patrol"] || [opType containsString:@"manure"] || [opType containsString:@"draw"] || [opType containsString:@"lottery"] || [opType containsString:@"vitality"] || [opType containsString:@"monopoly"] || [opType containsString:@"antisle"] || [opType containsString:@"hsdwy"] || [opType containsString:@"antfarm"] || [opType containsString:@"manor"]));
        
        AntForestManager *manager = [AntForestManager sharedInstance];
        BOOL isMonopolyRpc = (opType.length && ([opType containsString:@"monopoly"] || [opType containsString:@"antisle"] || [opType containsString:@"hsdwy"])) ||
                             ([urlStr.lowercaseString containsString:@"180020010001293606"] || [urlStr.lowercaseString containsString:@"2060090000398301"] || [urlStr.lowercaseString containsString:@"monopoly"] || [urlStr.lowercaseString containsString:@"hsdwy"]);
        if (isMonopolyRpc && manager.enableAutoPatrolNew && self != manager.jsBridge) {
            BOOL isFirstBind = (manager.monopolyBridge != self);
            if (isFirstBind) {
                manager.monopolyBridge = self;
                if (urlStr.length) manager.monopolyH5Url = urlStr;
                [manager recordStage:@"新版保护地 · 已捕获大富翁 RPC 并绑定 Bridge"];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                    [manager queryMonopolyTaskListWithForce:YES];
                    if (!manager.monopolyDrawerOpened) {
                        [manager openMonopolyTaskPanelOnWebView];
                    }
                });
            }
        }
        
        NSURL *callUrl = [url isKindOfClass:NSURL.class] ? (NSURL *)url : ([urlStr length] ? [NSURL URLWithString:urlStr] : nil);
        BOOL isForestUrl = [urlStr containsString:@"180020010001247580"] || [urlStr containsString:@"60000002"];
        BOOL isFarmUrl = [urlStr containsString:@"alipayfarm"] || [urlStr containsString:@"babafarm"] || [urlStr containsString:@"orchard"] || [urlStr containsString:@"180020010001263018"] || [urlStr containsString:@"68687599"];
        
        BOOL isManorRpc = [AntForestManager isManorURL:callUrl] || 
                          (!isForestUrl && !isFarmUrl &&
                           (opType.length && ([opType containsString:@"com.alipay.antfarm"] || [opType containsString:@"antfarm."])));
        if (isManorRpc && manager.enableAutoManor) {
            if (manager.jsBridge == self) {
                manager.jsBridge = nil;
            }
            BOOL isFirstBind = (manager.manorBridge != self);
            if (isFirstBind) {
                manager.manorBridge = self;
                if (urlStr.length) manager.manorH5Url = urlStr;
                [manager recordStage:@"蚂蚁庄园 · 已捕获庄园 RPC 并绑定 Bridge"];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                    [manager checkAndRunManorAutomations];
                });
            }
        }
        
        if (isRelevant) {
            NSString *dataStr = nil;
            if ([data isKindOfClass:NSString.class]) dataStr = data;
            else if ([NSJSONSerialization isValidJSONObject:data]) {
                NSData *d = [NSJSONSerialization dataWithJSONObject:data options:0 error:nil];
                if (d) dataStr = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
            }
            if (!dataStr) dataStr = [data description];
            
            BOOL isFarm = [urlStr containsString:@"farm"] || [urlStr containsString:@"orchard"] || [opType containsString:@"farm"] || [opType containsString:@"orchard"] || [opType containsString:@"manure"];
            BOOL isManor = [urlStr containsString:@"manor"] || [urlStr containsString:@"antfarm"] || [urlStr containsString:@"66666674"] || [opType containsString:@"antfarm"] || [opType containsString:@"manor"];
            if (isManor) {
                AFProbeLog(@"\n🐔 [ManorProbe-RPC-REQ]\n📍 RPC: %@ | URL: %@\n📦 Request: %@\n", opType ?: name, urlStr, dataStr);
                [[AntForestManager sharedInstance] recordProbeLog:[NSString stringWithFormat:@"[蚂蚁庄园RPC-REQ: %@] %@", opType ?: name, dataStr]];
            } else if (isFarm) {
                AFProbeLog(@"\n🌾 [FarmProbe-RPC-REQ]\n📍 RPC: %@ | URL: %@\n📦 Request: %@\n", opType ?: name, urlStr, dataStr);
                AFProbeLog(@"\n📥 [PatrolProbe-RES] 📍 芭芭农场发起RPC: %@\n", opType ?: name);
                [[AntForestManager sharedInstance] recordProbeLog:[NSString stringWithFormat:@"[芭芭农场RPC-REQ: %@] %@", opType ?: name, dataStr]];
            } else {
                AFProbeLog(@"\n🔍 [PatrolProbe-JSAPI]\n📍 API: %@ | URL: %@\n📦 Data: %@\n", name, urlStr, dataStr);
                [[AntForestManager sharedInstance] recordProbeLog:[NSString stringWithFormat:@"[JSAPI: %@] URL: %@\nData: %@", name, urlStr, dataStr]];
            }
        }
    } @catch (NSException *e) {}
    
    if (originalCallJsApi) originalCallJsApi(self, _cmd, name, url, data, cb);
}

static id portTransformResponseData(id self, SEL _cmd, id value) {
    id controller = forestControllerForBridge(self);
    if (isEnergyRain(nil, controller)) {
        if (originalTransformResponseData) {
            return originalTransformResponseData(self, _cmd, value);
        }
        return value;
    }

    AntForestManager *manager = [AntForestManager sharedInstance];
    NSDictionary *dict = [value isKindOfClass:NSDictionary.class] ? value : nil;
    NSDictionary *resData = [dict[@"resData"] isKindOfClass:NSDictionary.class] ? dict[@"resData"] : nil;

    NSURL *ctrlUrl = [controller respondsToSelector:@selector(url)] ? [controller url] : nil;

    // 1. 庄园与农场特征检测优先判定，避免森林 Bridge 缓存误判
    BOOL isManorByUrl = ctrlUrl && [AntForestManager isManorURL:ctrlUrl];
    BOOL isManorByData = [AntForestManager isManorResponse:value];
    BOOL isManor = isManorByUrl || isManorByData || (manager.manorBridge == self);

    BOOL isFarmByUrl = ctrlUrl && isFarmURL(ctrlUrl);
    BOOL isFarmByData = (resData[@"limitedTimeChallenge"] || dict[@"limitedTimeChallenge"] ||
                         resData[@"taskList"] || dict[@"taskList"] ||
                         resData[@"manureFactory"] || dict[@"manureFactory"] ||
                         resData[@"signTaskInfo"] || dict[@"signTaskInfo"] ||
                         resData[@"balloonCooper"] || dict[@"balloonCooper"] ||
                         resData[@"helpFarmChannelConfig"] || dict[@"helpFarmChannelConfig"] ||
                         resData[@"subplotsActivityList"] || dict[@"subplotsActivityList"] ||
                         resData[@"indexDeliveryList"] || dict[@"indexDeliveryList"]);
    BOOL isFarmResp = !isManor && (isFarmByUrl || isFarmByData || (manager.farmBridge == self));

    // 2. 森林判定：只有在明确不是庄园且不是农场的前提下，才判定为森林
    BOOL isForest = NO;
    if (!isManor && !isFarmResp) {
        isForest = isForestResponse(value) || (ctrlUrl && isForestHomeURL(ctrlUrl));
        if (!isForest && manager.jsBridge == self) {
            isForest = YES;
        }
    }

    if (isForest) {
        if (manager.manorBridge == self) manager.manorBridge = nil;
        if (manager.farmBridge == self) manager.farmBridge = nil;
    } else if (isFarmResp) {
        if (manager.manorBridge == self) manager.manorBridge = nil;
    } else if (isManor) {
        if (manager.farmBridge == self) manager.farmBridge = nil;
        if (manager.jsBridge == self) manager.jsBridge = nil;
    }

    BOOL isOceanResp = resData[@"antOceanTaskVOList"] || [dict[@"antOceanTaskVOList"] isKindOfClass:NSArray.class];
    BOOL isTargetPluginResp = isForest || isFarmResp || isOceanResp || isManor ||
                              (gLastRpcOperationType.length && ([gLastRpcOperationType containsString:@"forest"] || [gLastRpcOperationType containsString:@"orchard"] || [gLastRpcOperationType containsString:@"antiep"] || [gLastRpcOperationType containsString:@"ocean"] || [gLastRpcOperationType containsString:@"patrol"] || [gLastRpcOperationType containsString:@"manure"] || [gLastRpcOperationType containsString:@"draw"] || [gLastRpcOperationType containsString:@"lottery"] || [gLastRpcOperationType containsString:@"vitality"] || [gLastRpcOperationType containsString:@"antfarm"] || [gLastRpcOperationType containsString:@"manor"]));

    if (isTargetPluginResp) {
        @try {
            NSString *resStr = nil;
            if ([NSJSONSerialization isValidJSONObject:value]) {
                NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
                if (data) resStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            }
            if (!resStr) resStr = [value description];
            
            if (resStr.length && !isNoiseProbeLog(resStr)) {
                if (gLastRpcOperationType.length) {
                    AFProbeLog(@"\n📥 [PatrolProbe-RES] 📍 对应RPC: %@\n📦 Response: %@\n", gLastRpcOperationType, resStr);
                } else {
                    AFProbeLog(@"\n📥 [PatrolProbe-RES]\n📦 Response: %@\n", resStr);
                }
                [[AntForestManager sharedInstance] recordProbeLog:[NSString stringWithFormat:@"[RES] %@", resStr]];
            }
        } @catch (NSException *e) {}
    }
    if (isForest) {
        if (manager.jsBridge != self) {
            manager.jsBridge = self;
            [manager recordStage:@"诊断 · 已绑定森林响应 H5 Bridge"];
        }
    }
    if ([self respondsToSelector:@selector(_doFlushMessageQueue:url:)]) {
        if (isFarmResp) {
            BOOL isFirstBind = (manager.farmBridge != self);
            if (isFirstBind) {
                manager.farmBridge = self;
                [manager recordStage:@"芭芭农场 · 已绑定农场 H5 Bridge"];
                if (manager.enableAutoFarmTasks) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1000 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                        [manager queryFarmTaskList];
                        [manager openFarmTaskPanelOnWebView];
                        [manager claimAllVisibleFarmRewardsOnWebView];
                    });
                }
            }
            [manager handleFarmResponse:dict ?: resData];
        }
        if (isManor && manager.enableAutoManor) {
            if (manager.jsBridge == self) {
                manager.jsBridge = nil;
            }
            BOOL isFirstBind = (manager.manorBridge != self);
            if (isFirstBind) {
                manager.manorBridge = self;
                [manager recordStage:@"蚂蚁庄园 · 已绑定庄园 H5 Bridge"];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                    [manager checkAndRunManorAutomations];
                });
            }
            [manager handleManorResponse:dict ?: resData];
        }
        if (resData[@"antOceanTaskVOList"] || [dict[@"antOceanTaskVOList"] isKindOfClass:NSArray.class]) {
            if (manager.oceanBridge != self) {
                manager.oceanBridge = self;
                [manager recordStage:@"神奇海洋 · 已绑定海洋 H5 Bridge"];
            }
        }
        BOOL isMonopolyRpcResp = (gLastRpcOperationType.length && ([gLastRpcOperationType containsString:@"monopoly"] || [gLastRpcOperationType containsString:@"antisle"] || [gLastRpcOperationType containsString:@"hsdwy"]));
        BOOL hasMonopolyData = resData[@"usingCreatureInfo"] || dict[@"usingCreatureInfo"] || resData[@"creatureCode"] || dict[@"creatureCode"] || resData[@"monopoly"] || dict[@"monopoly"] || resData[@"totalDiceCount"] || dict[@"totalDiceCount"] || resData[@"diceCount"] || dict[@"diceCount"];
        if ((isMonopolyRpcResp || hasMonopolyData) && manager.enableAutoPatrolNew && self != manager.jsBridge) {
            BOOL isFirstBind = (manager.monopolyBridge != self);
            if (isFirstBind) {
                manager.monopolyBridge = self;
                [manager recordStage:@"新版保护地 · 已绑定大富翁 H5 Bridge (RPC响应)"];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                    [manager queryMonopolyTaskListWithForce:YES];
                    if (!manager.monopolyDrawerOpened) {
                        [manager openMonopolyTaskPanelOnWebView];
                    }
                });
            }
        }
        NSArray *taskInfoList = [resData[@"taskInfoList"] isKindOfClass:NSArray.class] ? resData[@"taskInfoList"] : ([dict[@"taskInfoList"] isKindOfClass:NSArray.class] ? dict[@"taskInfoList"] : nil);
        if (resData[@"forestTasksNew"] || taskInfoList || resData[@"drawAsset"] || resData[@"drawEntranceVO"] || resData[@"drawActivity"] || resData[@"drawPrize"] || resData[@"drawPrizes"] || [dict[@"currentSeasonInfo"] isKindOfClass:NSDictionary.class]) {
            BOOL isMonopoly = (manager.monopolyBridge == self);
            BOOL isAIFish = (manager.aiFishBridge == self) || [dict[@"currentSeasonInfo"] isKindOfClass:NSDictionary.class];
            BOOL isOcean = (manager.oceanBridge == self);
            BOOL isFarm = (manager.farmBridge == self);
            BOOL isLottery = (manager.lotteryBridge == self);
            for (id t in taskInfoList) {
                if ([t isKindOfClass:NSDictionary.class]) {
                    NSString *sc = t[@"taskBaseInfo"][@"sceneCode"];
                    if ([sc containsString:@"MONOPOLY"] || [sc containsString:@"HSDWY"]) {
                        isMonopoly = YES;
                    } else if ([sc containsString:@"AIFISH"]) {
                        isAIFish = YES;
                    } else if ([sc containsString:@"OCEAN"]) {
                        isOcean = YES;
                    } else if ([sc containsString:@"FARM"] || [sc containsString:@"ORCHARD"] || [sc isEqualToString:@"10021"] || [sc isEqualToString:@"3646"] || [sc hasPrefix:@"BABA_"]) {
                        if (!isManor) {
                            isFarm = YES;
                        }
                    } else if ([sc containsString:@"DRAW"] || [sc containsString:@"LOTTERY"]) {
                        isLottery = YES;
                    }
                }
            }
            if (resData[@"drawAsset"] || resData[@"drawEntranceVO"] || resData[@"drawActivity"] || resData[@"drawPrize"] || resData[@"drawPrizes"]) {
                isLottery = YES;
            }
            if (isMonopoly) {
                BOOL isFirstBind = (manager.monopolyBridge != self);
                manager.monopolyBridge = self;
                if (isFirstBind) {
                    [manager recordStage:@"新版保护地 · 已绑定大富翁 H5 Bridge (任务列表)"];
                }
                manager.monopolyDrawerOpened = YES;
            }
            if (isAIFish) {
                manager.aiFishBridge = self;
            }
            if (isOcean) {
                manager.oceanBridge = self;
            }
            if (isFarm && !isManor && !isForest) {
                manager.farmBridge = self;
            }
            if (isLottery) {
                manager.lotteryBridge = self;
            }
            if (!isMonopoly && !isAIFish && !isOcean && !isFarm && !isLottery && !isManor && !isForest) {
                if (manager.rewardTaskBridge != self) {
                    manager.rewardTaskBridge = self;
                }
            }
        }
    }
    if (!isManor) {
        [manager matchFriendIdAndBubbles:value];
    }
    if (manager.enableAutoCollect && manager.enableSelfCollect && isMyHomeResponse(value, manager)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(700 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{ tryAutoCollectWaterGift(); });
    }
    if (originalTransformResponseData) {
        return originalTransformResponseData(self, _cmd, value);
    }
    return value;
}

static void portUpdateBridgeReadyStatus(id self, SEL _cmd, id value) {
    if (originalUpdateBridgeReadyStatus) {
        originalUpdateBridgeReadyStatus(self, _cmd, value);
    }
    id controller = forestControllerForBridge(self);
    if (isEnergyRain(nil, controller)) {
        return;
    }
    static BOOL isUpdatingBridge = NO;
    if (isUpdatingBridge) return;
    isUpdatingBridge = YES;
    @try {
        if ([self respondsToSelector:@selector(isBridgeReady)] && !((BOOL (*)(id, SEL))objc_msgSend)(self, @selector(isBridgeReady))) {
            isUpdatingBridge = NO;
            return;
        }
        id controller = forestControllerForBridge(self);
        NSURL *url = [controller respondsToSelector:@selector(url)] ? [controller url] : nil;
        if (isForestHomeURL(url) && !isEarnEnergyURL(url)) {
            objc_setAssociatedObject(controller, ForestHomeBridgeKey, self, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            dispatch_async(dispatch_get_main_queue(), ^{
                finishForestHomeStart(controller, self);
            });
        }
    } @catch (NSException *e) {
    } @finally {
        isUpdatingBridge = NO;
    }
}

static BOOL hookMethod(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (!cls || !selector || !replacement) return NO;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    IMP existing = method_getImplementation(method);
    if (existing == replacement) return NO; // Already hooked!
    IMP prev = method_setImplementation(method, replacement);
    if (original && !*original) {
        *original = prev;
    }
    return YES;
}

static void (*originalDTViewDidAppear)(UIViewController *self, SEL _cmd, BOOL animated);
static void portDTViewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    if (originalDTViewDidAppear) originalDTViewDidAppear(self, _cmd, animated);
    NSString *clsName = NSStringFromClass(self.class);
    if ([clsName containsString:@"Launcher"] || [clsName isEqualToString:@"DTViewController"]) {
        addLogButton(self, NO);
    }
}

__attribute__((constructor))
static void installHooks(void) {
    @autoreleasepool {
        BOOL shouldInstall = NO;
        @synchronized (NSProcessInfo.class) {
            shouldInstall = class_addMethod(NSProcessInfo.class, sel_registerName("antforestPortHooksInstalled"), (IMP)portInstallMarker, "v@:");
        }
        if (!shouldInstall) return;
        initializeManager();
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *notification) {
            shouldRevealLeafOnNextForestAppearance = YES;
            [[AFStepSimulator shared] installAvailableHooks];
        }];
        [[AFStepSimulator shared] installAvailableHooks];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [[AFStepSimulator shared] installAvailableHooks]; });
        Class webController = NSClassFromString(@"H5WebViewController");
        if (webController) {
            class_addMethod(webController, @selector(antforestHandlePan:), (IMP)handleButtonPan, "v@:@");
            hookMethod(webController, @selector(viewDidLoad), (IMP)portViewDidLoad, (IMP *)&originalViewDidLoad);
            hookMethod(webController, @selector(viewDidAppear:), (IMP)portViewDidAppear, (IMP *)&originalViewDidAppear);
        }
        
        Class dtController = NSClassFromString(@"DTViewController");
        if (dtController) {
            class_addMethod(dtController, @selector(antforestHandlePan:), (IMP)handleButtonPan, "v@:@");
            hookMethod(dtController, @selector(viewDidAppear:), (IMP)portDTViewDidAppear, (IMP *)&originalDTViewDidAppear);
        }
        
        Class psdClass = NSClassFromString(@"PSDJsBridge");
        Class rvkClass = NSClassFromString(@"RVKJsBridge");
        NSArray *bridgeClasses = @[psdClass ?: [NSObject class], rvkClass ?: [NSObject class]];
        for (Class targetBridgeClass in bridgeClasses) {
            if (targetBridgeClass != [NSObject class]) {
                hookMethod(targetBridgeClass, @selector(transformResponseData:), (IMP)portTransformResponseData, (IMP *)&originalTransformResponseData);
                hookMethod(targetBridgeClass, @selector(updateBridgeReadyStatus:), (IMP)portUpdateBridgeReadyStatus, (IMP *)&originalUpdateBridgeReadyStatus);
                hookMethod(targetBridgeClass, @selector(_doFlushMessageQueue:url:), (IMP)portDoFlushMessageQueue, (IMP *)&originalDoFlushMessageQueue);
                hookMethod(targetBridgeClass, @selector(_flushMessageQueueWithMessage:url:), (IMP)portFlushMessageQueueWithMessage, (IMP *)&originalFlushMessageQueueWithMessage);
                hookMethod(targetBridgeClass, @selector(_dispatchMessage:), (IMP)portDispatchMessage, (IMP *)&originalDispatchMessage);
                hookMethod(targetBridgeClass, @selector(callHandler:data:responseCallback:), (IMP)portCallHandler, (IMP *)&originalCallHandler);
                hookMethod(targetBridgeClass, @selector(_deserializeMessageJSON:), (IMP)portDeserializeMessageJSON, (IMP *)&originalDeserializeMessageJSON);
                hookMethod(targetBridgeClass, @selector(webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:), (IMP)portRunJsTextInput, (IMP *)&originalRunJsTextInput);
                hookMethod(targetBridgeClass, @selector(callJsApi:url:data:responseCallback:), (IMP)portCallJsApi, (IMP *)&originalCallJsApi);
            }
        }
        
        int classCount = objc_getClassList(NULL, 0);
        if (classCount > 0) {
            Class *classes = (Class *)malloc(sizeof(Class) * classCount);
            if (classes) {
                classCount = objc_getClassList(classes, classCount);
                for (int i = 0; i < classCount; i++) {
                    hookRPCProbeMethod(classes[i]);
                }
                free(classes);
            }
        }
        NSLog(@"[AntForestPort] Bridge and controllers hooked safely.");
    }
}
