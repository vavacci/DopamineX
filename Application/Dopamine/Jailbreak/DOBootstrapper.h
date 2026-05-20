//
//  Bootstrapper.h
//  Dopamine
//
//  Created by Lars Fröder on 09.01.24.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DOBootstrapper : NSObject <NSURLSessionDelegate, NSURLSessionDownloadDelegate>
{
    NSURLSession *_urlSession;
    NSURLSessionDownloadTask *_bootstrapDownloadTask;
    void (^_downloadCompletionBlock)(NSURL * _Nullable location, NSError * _Nullable error);
}

- (void)prepareBootstrapWithCompletion:(void (^)(NSError *))completion;
- (NSError *)ensurePrivatePrebootIsWritable;
- (NSError *)installPackageManagers;
- (NSError *)finalizeBootstrap;
- (NSError *)deleteBootstrap;

// 可选 preload 组列表，每项 = {@"id", @"label", @"default"(NSNumber BOOL)}。
+ (NSArray<NSDictionary *> *)preloadGroups;

@end

NS_ASSUME_NONNULL_END
