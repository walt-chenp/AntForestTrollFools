//
//  Tool.m
//  wechat
//
//  Created by 王友坤 on 2023/4/12.
//

#import "Tool.h"
#import <UIKit/UIKit.h>
#import "UIView+Toast.h"

#import <objc/runtime.h>

@implementation Tool

#pragma clang diagnostic push
#pragma clang diagnostic ignored"-Wdeprecated-declarations"

//弹窗消息
+(void)Alert:(NSString*)msg {
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:msg message:nil delegate:self cancelButtonTitle:@"Ok" otherButtonTitles:nil];
    NSLog(@"hook alert:%@",msg);
    [alert show];
}

//Toast消息
+(void)Toast:(NSString*)msg {
    [[UIApplication sharedApplication].keyWindow.rootViewController.view makeToast:msg];
}

//获取当前时间 
+(NSString*)CurTimeFormatStr {
    NSDateFormatter *formatter =[NSDateFormatter new];
    [formatter setDateFormat:@"YYYY-MM-dd HH:mm:ss"];
    NSString *currentTimeString = [formatter stringFromDate:[NSDate date]];
    return currentTimeString;
}

//获取当前时间戳
+(long)CurTimestamp {
    return [[NSDate date] timeIntervalSince1970];
}

+ (NSString *)extractTitleFromXMLString:(NSString *)xmlString {
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"<title>(.*?)</title>" options:NSRegularExpressionCaseInsensitive error:&error];
    
    if (regex != nil) {
        NSTextCheckingResult *firstMatch = [regex firstMatchInString:xmlString options:0 range:NSMakeRange(0, [xmlString length])];
        
        if (firstMatch) {
            NSRange resultRange = [firstMatch rangeAtIndex:1];
            NSString *title = [xmlString substringWithRange:resultRange];
            return title;
        }
    }
    
    return nil;
}

#pragma clang diagnostic pop

@end
