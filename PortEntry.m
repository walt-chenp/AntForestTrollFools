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
static const void *ForestHomeBridgeKey = &ForestHomeBridgeKey;
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
    __weak id weakController = controller;
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

static BOOL isPatrolURL(NSURL *url) {
    NSString *str = url.absoluteString;
    return [str containsString:@"68687842"] || [str containsString:@"protect.html"] || [str containsString:@"animalBook.html"] || [str containsString:@"protectedArea.html"];
}

static void installPatrolAutoPilot(id controller) {
    if (![AntForestManager sharedInstance].enableAutoPatrol) return;
    id webView = [controller respondsToSelector:@selector(webView)] ? ((id (*)(id, SEL))objc_msgSend)(controller, @selector(webView)) : nil;
    SEL evaluate = @selector(evaluateJavaScript:completionHandler:);
    if (![webView respondsToSelector:evaluate]) return;
    
    NSString *script = @"(()=>{if(window.__afPatrolInstalled)return'already';"
    "window.__afPatrolInstalled=true;"
    "function sendLog(data){try{prompt('PATROL_LOG:'+JSON.stringify(data))}catch(e){}};"
    "let patrolState={leftChance:-1,leftStep:0,usedStep:0,isBusy:false,lastPatrolTime:0};"
    "function findAndClick(keywords){"
    "const els=Array.from(document.querySelectorAll('button,div,span,a,p,img'));"
    "for(let el of els){"
    "const txt=(el.innerText||el.textContent||'').trim();"
    "const alt=(el.getAttribute('alt')||'').trim();"
    "const aria=(el.getAttribute('aria-label')||'').trim();"
    "for(let kw of keywords){"
    "if(txt===kw||alt===kw||aria===kw||(kw.length>2&&(txt.includes(kw)||alt.includes(kw)))){ "
    "const rect=el.getBoundingClientRect();"
    "if(rect.width>0&&rect.height>0&&el.offsetParent!==null){"
    "el.click();return true;"
    "}}}"
    "}return false;}"
    "function handleEvents(events){"
    "if(events&&Array.isArray(events)){"
    "for(let ev of events){"
    "if(ev.eventType==='material'&&ev.materialInfo&&ev.materialInfo.materialType==='quiz'){"
    "const detail=ev.materialDetail||{};const q=detail.N_question||{};const correctIdx=q.correct;"
    "sendLog({type:'AUTO-PATROL',action:'quiz_found',q:q.question,correct:correctIdx});"
    "setTimeout(()=>{"
    "const opts=document.querySelectorAll('.option,[class*=\"option\"],[class*=\"answer\"],[class*=\"item\"]');"
    "if(opts&&opts[correctIdx]){opts[correctIdx].click();"
    "setTimeout(()=>{findAndClick(['确定','确认','提交']);},400);}"
    "},600);}"
    "}}"
    "setTimeout(()=>{findAndClick(['开心收下','收下','我知道了','确定','领取','立即收下','好的']);},800);"
    "}"
    "function checkAllDoneAndExit(){"
    "if(patrolState.leftChance===0&&(patrolState.usedStep>=10000||patrolState.leftStep<2000)){"
    "sendLog({type:'AUTO-PATROL',action:'all_tasks_finished_auto_exit'});"
    "try{localStorage.setItem('__af_patrol_done_date',new Date().toISOString().slice(0,10));}catch(e){}"
    "setTimeout(()=>{"
    "if(window.AlipayJSBridge&&window.AlipayJSBridge.call){"
    "window.AlipayJSBridge.call('popWindow');"
    "window.AlipayJSBridge.call('exitApp');"
    "}"
    "},1500);"
    "}"
    "}"
    "function autoPatrolStep(){"
    "if(patrolState.isBusy)return;"
    "const now=Date.now();"
    "if(now-patrolState.lastPatrolTime<2500)return;"
    "if(patrolState.leftChance>0){"
    "patrolState.isBusy=true;patrolState.lastPatrolTime=now;"
    "sendLog({type:'AUTO-PATROL',action:'patrol_forward',leftChance:patrolState.leftChance});"
    "findAndClick(['开始巡护','继续巡护','巡护']);"
    "setTimeout(()=>{patrolState.isBusy=false;handleEvents(null);},3000);"
    "}else if(patrolState.leftChance===0&&patrolState.usedStep<10000&&patrolState.leftStep>=2000){"
    "patrolState.isBusy=true;patrolState.lastPatrolTime=now;"
    "sendLog({type:'AUTO-PATROL',action:'exchange_step',leftStep:patrolState.leftStep,usedStep:patrolState.usedStep});"
    "findAndClick(['兑换巡护机会','兑换步数','兑换']);"
    "setTimeout(()=>{"
    "findAndClick(['确认兑换','确定','兑换','我知道了']);"
    "setTimeout(()=>{patrolState.isBusy=false;},1000);"
    "},800);"
    "}else if(patrolState.leftChance===0){"
    "checkAllDoneAndExit();"
    "}"
    "}"
    "function dispatchSmartAnimal(){"
    "const bodyText=document.body?document.body.innerText||'':'';"
    "if(bodyText.includes('巡护中')||bodyText.includes('正在巡护')||bodyText.includes('已在巡护')||bodyText.includes('已派遣')){"
    "sendLog({type:'AUTO-PATROL',action:'skip_dispatch_already_active'});return;"
    "}"
    "const cards=Array.from(document.querySelectorAll('[class*=\"card\"],[class*=\"animal\"],[class*=\"item\"]'));"
    "const highYields=['88g','100g','云豹','亚洲金猫','金钱豹','雪豹','东北虎','荒漠猫'];"
    "const midYields=['60g','豺','赤斑羚','羚牛','藏羚羊','原羚','黑颈鹤'];"
    "for(let kw of highYields){"
    "for(let card of cards){"
    "const txt=card.innerText||card.textContent||'';"
    "if(txt.includes('巡护中')||txt.includes('已派遣'))return;"
    "if(txt.includes(kw)){card.click();sendLog({type:'AUTO-PATROL',action:'dispatch_animal',animal:kw});setTimeout(()=>{findAndClick(['派它巡护森林','立即派遣','派遣']);},300);return;}"
    "}"
    "}"
    "for(let kw of midYields){"
    "for(let card of cards){"
    "const txt=card.innerText||card.textContent||'';"
    "if(txt.includes('巡护中')||txt.includes('已派遣'))return;"
    "if(txt.includes(kw)){card.click();sendLog({type:'AUTO-PATROL',action:'dispatch_animal',animal:kw});setTimeout(()=>{findAndClick(['派它巡护森林','立即派遣','派遣']);},300);return;}"
    "}"
    "}"
    "}"
    "if(location.href.includes('animalBook.html')){"
    "sendLog({type:'AUTO-PATROL',action:'synthesize_animal'});"
    "findAndClick(['立即合成','合成物种','一键合成','合成']);"
    "setTimeout(dispatchSmartAnimal,600);"
    "}"
    "}"
    "function hookBridge(){"
    "if(!window.AlipayJSBridge||!window.AlipayJSBridge.call){setTimeout(hookBridge,150);return;}"
    "const _call=window.AlipayJSBridge.call;"
    "window.AlipayJSBridge.call=function(name,params,cb){"
    "if(name==='rpc'&&params){"
    "const op=params.operationType||'';const req=params.requestData||null;"
    "sendLog({type:'RPC-REQ',op:op,req:req});"
    "const origCb=cb;"
    "cb=function(res){"
    "sendLog({type:'RPC-RES',op:op,res:res});"
    "if(res){"
    "const up=res.userPatrol||(res.resData&&res.resData.userPatrol);"
    "if(up&&up.chance){"
    "patrolState.leftChance=up.chance.leftChance!==undefined?up.chance.leftChance:0;"
    "patrolState.leftStep=up.chance.leftStep||0;"
    "patrolState.usedStep=up.chance.usedStep||0;"
    "}"
    "if(res.events)handleEvents(res.events);"
    "}"
    "setTimeout(autoPatrolStep,1500);"
    "if(origCb)origCb(res);"
    "};"
    "return _call.call(this,name,params,cb);"
    "}"
    "return _call.apply(this,arguments);"
    "};"
    "sendLog({type:'STATUS',msg:'AlipayJSBridge Patrol Hooked & AutoPilot Active'});"
    "setInterval(autoPatrolStep,3500);"
    "};"
    "hookBridge();"
    "return'autopilot-injected';})()";

    void (*runJavaScript)(id, SEL, NSString *, void (^)(id, NSError *)) = (void *)objc_msgSend;
    runJavaScript(webView, evaluate, script, ^(id result, NSError *error) {
        NSLog(@"[AntForestPatrol] hook script result: %@ error: %@", result, error);
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
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 7, header.bounds.size.width - 110, 32)]; title.autoresizingMask = UIViewAutoresizingFlexibleWidth; title.text = [NSString stringWithFormat:@"好友列表（已选 %lu 位）", (unsigned long)AntForestManager.sharedInstance.waterFriendIds.count]; title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]; title.textColor = UIColor.secondaryLabelColor;
    UIButton *refresh = [UIButton buttonWithType:UIButtonTypeSystem]; refresh.frame = CGRectMake(header.bounds.size.width - 84, 4, 68, 36); refresh.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin; [refresh setTitle:@"刷新" forState:UIControlStateNormal]; refresh.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]; [refresh addTarget:self action:@selector(refreshFriends) forControlEvents:UIControlEventTouchUpInside];
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
    UIButton *patrol = [self settingsButtonWithTitle:@"保护地巡护（走步/答题/合成）" detail:@"自动走步、自动答题与步数兑换" icon:@"leaf.circle.fill" action:nil];
    UISwitch *patrolSwitch = [[UISwitch alloc] init]; patrolSwitch.on = AntForestManager.sharedInstance.enableAutoPatrol; patrolSwitch.translatesAutoresizingMaskIntoConstraints = NO; [patrolSwitch addTarget:self action:@selector(toggleAutoPatrol:) forControlEvents:UIControlEventValueChanged]; [patrol addSubview:patrolSwitch];
    
    [contentView addSubview:schedule]; [contentView addSubview:step]; [contentView addSubview:water]; [contentView addSubview:revive]; [contentView addSubview:earn]; [contentView addSubview:ocean]; [contentView addSubview:patrol];
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
        [patrol.topAnchor constraintEqualToAnchor:ocean.bottomAnchor constant:12], [patrol.leadingAnchor constraintEqualToAnchor:schedule.leadingAnchor], [patrol.trailingAnchor constraintEqualToAnchor:schedule.trailingAnchor], [patrol.heightAnchor constraintEqualToConstant:70],
        [patrol.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor constant:-24],
        
        [reviveSwitch.trailingAnchor constraintEqualToAnchor:revive.trailingAnchor constant:-18], [reviveSwitch.centerYAnchor constraintEqualToAnchor:revive.centerYAnchor],
        [earnSwitch.trailingAnchor constraintEqualToAnchor:earn.trailingAnchor constant:-18], [earnSwitch.centerYAnchor constraintEqualToAnchor:earn.centerYAnchor],
        [oceanSwitch.trailingAnchor constraintEqualToAnchor:ocean.trailingAnchor constant:-18], [oceanSwitch.centerYAnchor constraintEqualToAnchor:ocean.centerYAnchor],
        [patrolSwitch.trailingAnchor constraintEqualToAnchor:patrol.trailingAnchor constant:-18], [patrolSwitch.centerYAnchor constraintEqualToAnchor:patrol.centerYAnchor],
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
- (void)toggleAutoRevive:(UISwitch *)sender { AntForestManager.sharedInstance.enableAutoRevive = sender.on; [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:@"enableAutoRevive"]; [AntForestManager.sharedInstance recordStage:[NSString stringWithFormat:@"复活能量 · 功能已%@", sender.on ? @"开启" : @"关闭"]]; }
- (void)toggleAutoEarn:(UISwitch *)sender { AntForestManager.sharedInstance.enableAutoEarn = sender.on; [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:@"enableAutoEarn"]; [AntForestManager.sharedInstance recordStage:[NSString stringWithFormat:@"打地鼠 · 功能已%@", sender.on ? @"开启" : @"关闭"]]; }
- (void)toggleCleanOcean:(UISwitch *)sender { AntForestManager.sharedInstance.enableCleanOcean = sender.on; [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:@"enableCleanOcean"]; [AntForestManager.sharedInstance recordStage:[NSString stringWithFormat:@"神奇海洋 · 自动清理已%@", sender.on ? @"开启" : @"关闭"]]; }
- (void)toggleAutoPatrol:(UISwitch *)sender { AntForestManager.sharedInstance.enableAutoPatrol = sender.on; [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:@"enableAutoPatrol"]; [AntForestManager.sharedInstance recordStage:[NSString stringWithFormat:@"保护地巡护 · 功能已%@", sender.on ? @"开启" : @"关闭"]]; }
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
    UILabel *versionLabel = [[UILabel alloc] init];
    versionLabel.text = @"当前版本：保护地巡护全量抓包探针版 (Patrol Probe)";
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
        [self.tableView.bottomAnchor constraintEqualToAnchor:versionLabel.topAnchor constant:-6],
        [versionLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [versionLabel.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-4],
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
    NSString *header = [NSString stringWithFormat:@"AntForestPort 收取日志（含保护地巡护抓包探针）\n导出时间：%@\n配置：自动收取=%@，收取自己=%@，自动能量雨=%@，赚能量（打地鼠玩法）=%@，神奇海洋=%@，保护地巡护=%@，自动复活好友过期能量=%@，后台循环=%@，循环间隔=%ld 秒，定时收取=%@，打开蚂蚁森林自动浇水=%@，定时自动浇水=%@（%ld g，%lu 位好友），步数模拟=%@\n统计：今日=%ld g，累计=%ld g，日志条目=%lu\n\n",
                      getCurrentDateTimeString(), manager.enableAutoCollect ? @"开" : @"关", manager.enableSelfCollect ? @"开" : @"关", manager.enableAutoRain ? @"开" : @"关", manager.enableAutoEarn ? @"开" : @"关", manager.enableCleanOcean ? @"开" : @"关", manager.enableAutoPatrol ? @"开" : @"关", manager.enableAutoRevive ? @"开" : @"关", manager.enableBackgroundLoop ? @"开" : @"关", (long)manager.collectInterval, manager.enableScheduledCollect ? @"开" : @"关", manager.enableWaterOnLaunch ? @"开" : @"关", manager.enableAutoWater ? @"开" : @"关", (long)manager.waterGrams, (unsigned long)manager.waterFriendIds.count, AFStepSimulator.shared.enabled ? @"开" : @"关", (long)manager.todayCollectedEnergy, (long)manager.totalCollectedEnergy, (unsigned long)records.count];
    NSMutableString *fullOutput = [NSMutableString stringWithString:header];
    if (records.count) {
        [fullOutput appendString:[records componentsJoinedByString:@"\n\n"]];
    } else {
        [fullOutput appendString:@"没有常规收取日志\n"];
    }
    
    NSArray *probes = manager.probeRecords;
    [fullOutput appendFormat:@"\n\n========================================\n📋 保护地巡护 / 全量 H5 RPC 抓包探针数据（共 %lu 条）\n========================================\n\n", (unsigned long)probes.count];
    if (probes.count) {
        [fullOutput appendString:[probes componentsJoinedByString:@"\n\n"]];
    } else {
        [fullOutput appendString:@"暂未捕获到 H5 RPC 请求（请先打开保护地巡护页面进行操作）\n"];
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
    manager.enableAutoRevive = [defaults objectForKey:@"enableAutoRevive"] ? [defaults boolForKey:@"enableAutoRevive"] : YES;
    manager.enableCleanOcean = [defaults objectForKey:@"enableCleanOcean"] ? [defaults boolForKey:@"enableCleanOcean"] : YES;
    manager.enableAutoPatrol = [defaults objectForKey:@"enableAutoPatrol"] ? [defaults boolForKey:@"enableAutoPatrol"] : YES;
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
    if (forestHome && (manager.enableWaterOnLaunch || manager.enableAutoCollect)) startForestHomeWhenBridgeReady(self);
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
    if (isPatrolURL(url)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            installPatrolAutoPilot(self);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1000 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            installPatrolAutoPilot(self);
        });
    }
    if (earnEnergy && manager.enableAutoEarn) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            installEarnEnergyCollector(self);
        });
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
        [log containsString:@"\"safeArea\""]) {
        return YES;
    }
    return NO;
}

static void (*originalCallRPC)(id, SEL, id, id);
static void portCallRPC(id self, SEL _cmd, id rpcConfig, id completeBlock) {
    @try {
        NSString *str = nil;
        if ([rpcConfig isKindOfClass:NSString.class]) str = rpcConfig;
        else if ([NSJSONSerialization isValidJSONObject:rpcConfig]) {
            NSData *d = [NSJSONSerialization dataWithJSONObject:rpcConfig options:0 error:nil];
            if (d) str = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        }
        if (!str) str = [rpcConfig description];
        
        if (str.length && !isNoiseProbeLog(str)) {
            NSLog(@"\n🔍 [PatrolProbe-RPC-REQ]\n📦 %@", str);
            [[AntForestManager sharedInstance] recordProbeLog:[NSString stringWithFormat:@"[RPC-REQ] %@", str]];
        }
    } @catch (NSException *e) {}
    
    if (originalCallRPC) originalCallRPC(self, _cmd, rpcConfig, completeBlock);
}

static void (*originalDoFlushMessageQueue)(id, SEL, id, id);
static void portDoFlushMessageQueue(id self, SEL _cmd, id msg, id url) {
    @try {
        NSString *urlStr = [url isKindOfClass:NSString.class] ? url : ([url respondsToSelector:@selector(absoluteString)] ? [url absoluteString] : @"");
        NSString *msgStr = nil;
        if ([msg isKindOfClass:NSString.class]) {
            msgStr = msg;
        } else if ([NSJSONSerialization isValidJSONObject:msg]) {
            NSData *d = [NSJSONSerialization dataWithJSONObject:msg options:0 error:nil];
            if (d) msgStr = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        }
        if (!msgStr) msgStr = [msg description];
        
        if (msgStr.length) {
            NSLog(@"\n🔍 [PatrolProbe-REQ]\n📍 URL: %@\n📦 Request: %@\n", urlStr, msgStr);
            [[AntForestManager sharedInstance] recordProbeLog:[NSString stringWithFormat:@"[REQ] URL: %@\nData: %@", urlStr, msgStr]];
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
        NSString *msgStr = nil;
        if ([msg isKindOfClass:NSString.class]) msgStr = msg;
        else if ([NSJSONSerialization isValidJSONObject:msg]) {
            NSData *d = [NSJSONSerialization dataWithJSONObject:msg options:0 error:nil];
            if (d) msgStr = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        }
        if (!msgStr) msgStr = [msg description];
        if (msgStr.length) {
            [[AntForestManager sharedInstance] recordProbeLog:[NSString stringWithFormat:@"[REQ] URL: %@\nData: %@", urlStr, msgStr]];
        }
    } @catch (NSException *e) {}
    if (originalFlushMessageQueueWithMessage) originalFlushMessageQueueWithMessage(self, _cmd, msg, url);
}

static id (*originalDeserializeMessageJSON)(id, SEL, id);
static id portDeserializeMessageJSON(id self, SEL _cmd, id json) {
    @try {
        NSString *str = [json isKindOfClass:NSString.class] ? json : [json description];
        if (str.length && !isNoiseProbeLog(str)) {
            NSLog(@"\n🔍 [PatrolProbe-H5REQ]\n📦 %@", str);
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
        if ([str hasPrefix:@"PATROL_LOG:"]) {
            NSString *payload = [str substringFromIndex:11];
            NSLog(@"\n🔍 [PatrolProbe-HOOK]\n📦 %@", payload);
            [[AntForestManager sharedInstance] recordProbeLog:[NSString stringWithFormat:@"[PATROL-HOOK] %@", payload]];
            
            NSDictionary *dict = nil;
            NSData *d = [payload dataUsingEncoding:NSUTF8StringEncoding];
            if (d) dict = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            NSString *action = [dict isKindOfClass:NSDictionary.class] ? dict[@"action"] : nil;
            AntForestManager *manager = [AntForestManager sharedInstance];
            
            if ([action isEqualToString:@"patrol_forward"]) {
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
            } else if ([action isEqualToString:@"all_tasks_finished_auto_exit"]) {
                NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
                fmt.dateFormat = @"yyyy-MM-dd";
                NSString *today = [fmt stringFromDate:[NSDate date]];
                [[NSUserDefaults standardUserDefaults] setObject:today forKey:@"lastAutoPatrolDoneDate"];
                [manager recordStage:@"保护地巡护 · 今日任务已全部自动完成并返回森林"];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    UIViewController *topVC = [UIApplication sharedApplication].keyWindow.rootViewController;
                    while (topVC.presentedViewController) topVC = topVC.presentedViewController;
                    if ([topVC isKindOfClass:[UINavigationController class]]) {
                        topVC = [(UINavigationController *)topVC topViewController];
                    }
                    if (topVC.navigationController && topVC.navigationController.viewControllers.count > 1) {
                        [topVC.navigationController popViewControllerAnimated:YES];
                    } else if (topVC.presentingViewController) {
                        [topVC dismissViewControllerAnimated:YES completion:nil];
                    }
                });
            }
            if (handler) {
                void (^completionBlock)(NSString *) = handler;
                completionBlock(nil);
            }
            return;
        }
        if (str.length && !isNoiseProbeLog(str)) {
            NSLog(@"\n🔍 [PatrolProbe-PROMPT]\n📦 %@", str);
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
        if (msgStr.length) {
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
        [[AntForestManager sharedInstance] recordProbeLog:[NSString stringWithFormat:@"[HANDLER: %@] %@", name, dataStr]];
    } @catch (NSException *e) {}
    if (originalCallHandler) originalCallHandler(self, _cmd, name, data, cb);
}

static void (*originalCallJsApi)(id, SEL, id, id, id, id);
static void portCallJsApi(id self, SEL _cmd, id name, id url, id data, id cb) {
    @try {
        NSString *urlStr = [url isKindOfClass:NSString.class] ? url : ([url respondsToSelector:@selector(absoluteString)] ? [url absoluteString] : @"");
        NSString *dataStr = nil;
        if ([data isKindOfClass:NSString.class]) dataStr = data;
        else if ([NSJSONSerialization isValidJSONObject:data]) {
            NSData *d = [NSJSONSerialization dataWithJSONObject:data options:0 error:nil];
            if (d) dataStr = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        }
        if (!dataStr) dataStr = [data description];
        
        NSLog(@"\n🔍 [PatrolProbe-JSAPI]\n📍 API: %@ | URL: %@\n📦 Data: %@\n", name, urlStr, dataStr);
        [[AntForestManager sharedInstance] recordProbeLog:[NSString stringWithFormat:@"[JSAPI: %@] URL: %@\nData: %@", name, urlStr, dataStr]];
    } @catch (NSException *e) {}
    
    if (originalCallJsApi) originalCallJsApi(self, _cmd, name, url, data, cb);
}

static id portTransformResponseData(id self, SEL _cmd, id value) {
    @try {
        NSString *resStr = nil;
        if ([NSJSONSerialization isValidJSONObject:value]) {
            NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
            if (data) resStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        }
        if (!resStr) resStr = [value description];
        
        if (resStr.length) {
            NSLog(@"\n📥 [PatrolProbe-RES]\n📦 Response: %@\n", resStr);
            [[AntForestManager sharedInstance] recordProbeLog:[NSString stringWithFormat:@"[RES] %@", resStr]];
        }
    } @catch (NSException *e) {}

    AntForestManager *manager = [AntForestManager sharedInstance];
    if (isForestResponse(value)) {
        if (manager.jsBridge != self) {
            manager.jsBridge = self;
            [manager recordStage:@"诊断 · 已绑定森林响应 H5 Bridge"];
        }
    }
    [manager matchFriendIdAndBubbles:value];
    if (manager.enableAutoCollect && manager.enableSelfCollect && isMyHomeResponse(value, manager)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(700 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{ tryAutoCollectWaterGift(); });
    }
    return originalTransformResponseData(self, _cmd, value);
}

static void portUpdateBridgeReadyStatus(id self, SEL _cmd, id value) {
    originalUpdateBridgeReadyStatus(self, _cmd, value);
    if ([self respondsToSelector:@selector(isBridgeReady)] && !((BOOL (*)(id, SEL))objc_msgSend)(self, @selector(isBridgeReady))) return;
    id controller = forestControllerForBridge(self);
    NSURL *url = [controller respondsToSelector:@selector(url)] ? [controller url] : nil;
    if (isForestHomeURL(url) && !isEarnEnergyURL(url)) {
        objc_setAssociatedObject(controller, ForestHomeBridgeKey, self, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        finishForestHomeStart(controller, self);
    }
}

static BOOL hookMethod(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    *original = method_setImplementation(method, replacement);
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
        Class targetBridgeClass = psdClass ?: rvkClass;
        if (targetBridgeClass) {
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
        
        Class h5RpcClass = NSClassFromString(@"H5RPCCaller") ?: NSClassFromString(@"RVKRPCCaller") ?: NSClassFromString(@"PSDRPCCaller");
        if (h5RpcClass) {
            hookMethod(h5RpcClass, @selector(callRPC:completeBlock:), (IMP)portCallRPC, (IMP *)&originalCallRPC);
        }
        NSLog(@"[AntForestPort] Bridge and controllers hooked safely.");
    }
}
