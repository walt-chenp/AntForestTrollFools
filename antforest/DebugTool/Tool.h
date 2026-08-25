//
//  Tool.h
//  wechat
//
//  Created by walt-chenp.
//

#import <Foundation/Foundation.h>

//#define NSLog(format, ...) printf("TIME:%s FILE:%s(%d行) FUNCTION:%s \n %s\n\n",__TIME__, [[[NSString stringWithUTF8String:__FILE__] lastPathComponent] UTF8String], __LINE__, __PRETTY_FUNCTION__, [[NSString stringWithFormat:(format), ##__VA_ARGS__] UTF8String])

#ifdef DEBUG
#define NSLog(format, ...) printf("[%s] %s [第%d行] %s\n", __TIME__, __FUNCTION__, __LINE__, [[NSString stringWithFormat:format, ## __VA_ARGS__] UTF8String]);
#else
#define NSLog(format, ...)
#endif



NS_ASSUME_NONNULL_BEGIN

@interface Tool : NSObject

+(void)Alert:(NSString*)msg;
+(void)Toast:(NSString*)msg;

+(NSString*)CurTimeFormatStr;
+(long)CurTimestamp;
+ (NSString *)extractTitleFromXMLString:(NSString *)xmlString;



@end

NS_ASSUME_NONNULL_END
