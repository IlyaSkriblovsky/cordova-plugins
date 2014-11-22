/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

#import "CDVLocalWebServer.h"
#import "GCDWebServerPrivate.h"
#import <Cordova/CDVViewController.h>
#import "CDVLocalFileSystem+NativeURL.h"
#import "CDVAssetLibraryFileSystem+NativeURL.h"
#import <AssetsLibrary/AssetsLibrary.h>
#import <MobileCoreServices/MobileCoreServices.h>

@interface GCDWebServer()
- (GCDWebServerResponse*)_responseWithContentsOfDirectory:(NSString*)path;
@end

@implementation CDVLocalWebServer

- (void) pluginInitialize {

    BOOL useLocalWebServer = NO;
    NSString* indexPage = @"index.html";
    NSString* appBasePath = @"www";
    NSUInteger port = 80;

    // check the content tag src
    CDVViewController* vc = (CDVViewController*)self.viewController;
    NSURL* startPageUrl = [NSURL URLWithString:vc.startPage];
    if (startPageUrl != nil) {
        if ([[startPageUrl scheme] isEqualToString:@"http"] && [[startPageUrl host] isEqualToString:@"localhost"]) {
            port = [[startPageUrl port] unsignedIntegerValue];
            useLocalWebServer = YES;
        }
    }
    
    // check setting
#if TARGET_IPHONE_SIMULATOR
    if (useLocalWebServer) {
        NSNumber* startOnSimulatorSetting = [[self.commandDelegate settings] objectForKey:[@"CordovaLocalWebServerStartOnSimulator" lowercaseString]];
        if (startOnSimulatorSetting) {
            useLocalWebServer = [startOnSimulatorSetting boolValue];
        }
    }
#endif
    if (useLocalWebServer) {
		// Create server
        self.server = [[GCDWebServer alloc] init];
		NSString* authToken = [NSString stringWithFormat:@"cdvToken=%@", [[NSProcessInfo processInfo] globallyUniqueString]];
        
        [self addAppFileSystemHandler:authToken basePath:[NSString stringWithFormat:@"/%@/", appBasePath] indexPage:indexPage];
        [self addFileSystemHandlers:authToken];
        
        [self.server startWithPort:port bonjourName:nil];
        [GCDWebServer setLogLevel:kGCDWebServerLoggingLevel_Error];
        
        // Update the startPage (supported in cordova-ios 3.7.0, see https://issues.apache.org/jira/browse/CB-7857)
		vc.startPage = [NSString stringWithFormat:@"http://localhost:%lu/%@/%@?%@", (unsigned long)self.server.port, appBasePath, indexPage, authToken];
        
    } else {
        NSLog(@"WARNING: CordovaLocalWebServer: <content> tag src is not http://localhost[:port] (is %@), local web server not started.", vc.startPage);
    }
}

-  (void) addFileSystemHandlers:(NSString*)authToken
{
    [self addLocalFileSystemHandler:authToken];
    [self addAssetLibraryFileSystemHandler:authToken];
    
    CDVFile* filePlugin = (CDVFile*)[self.commandDelegate getCommandInstance:@"File"];
    NSURL* localServerURL = [NSURL URLWithString:[NSString stringWithFormat:@"http://localhost:%lu", (unsigned long)self.server.port]];
    
    // set the localWebServerURL for the Obj-C categories
    if (filePlugin) {
        NSArray* fileSystems = filePlugin.fileSystems;
        for (NSObject<CDVFileSystem>* fileSystem in fileSystems) {
            SEL sel = NSSelectorFromString(@"setLocalWebServerURL:");
            if ([fileSystem respondsToSelector:sel]) {
                ((void (*)(id, SEL, id))[fileSystem methodForSelector:sel])(fileSystem, sel, localServerURL);
            }
        }
    }
}

- (void) addFileSystemHandler:(GCDWebServerAsyncProcessBlock)processRequestForResponseBlock basePath:(NSString*)basePath authToken:(NSString*)authToken cacheAge:(NSUInteger)cacheAge
{
    GCDWebServerMatchBlock matchBlock = ^GCDWebServerRequest *(NSString* requestMethod, NSURL* requestURL, NSDictionary* requestHeaders, NSString* urlPath, NSDictionary* urlQuery) {
        
        if (![requestMethod isEqualToString:@"GET"]) {
            return nil;
        }
        if (![urlPath hasPrefix:basePath]) {
            return nil;
        }
        return [[GCDWebServerRequest alloc] initWithMethod:requestMethod url:requestURL headers:requestHeaders path:urlPath query:urlQuery];
    };
    
    GCDWebServerAsyncProcessBlock asyncProcessBlock = ^void (GCDWebServerRequest* request, GCDWebServerCompletionBlock complete) {
        
        //check if it is a request from localhost
        NSString *host = [request.headers objectForKey:@"Host"];
        if (host==nil || [host hasPrefix:@"localhost"] == NO ) {
            complete([GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_Forbidden message:@"FORBIDDEN"]);
        }
        
        //check if the querystring or the cookie has the token
        BOOL hasToken = (request.URL.query && [request.URL.query containsString:authToken]);
        NSString *cookie = [request.headers objectForKey:@"Cookie"];
        BOOL hasCookie = (cookie && [cookie containsString:authToken]);
        if (!hasToken && !hasCookie) {
            complete([GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_Forbidden message:@"FORBIDDEN"]);
        }
        
        processRequestForResponseBlock(request, ^void(GCDWebServerResponse* response){
            if (response) {
                response.cacheControlMaxAge = cacheAge;
            } else {
                response = [GCDWebServerResponse responseWithStatusCode:kGCDWebServerHTTPStatusCode_NotFound];
            }
            
            if (hasToken && !hasCookie) {
                //set cookie
                [response setValue:authToken forAdditionalHeader:@"Set-Cookie"];
            }
            complete(response);
        });
    };
    
    [self.server addHandlerWithMatchBlock:matchBlock asyncProcessBlock:asyncProcessBlock];
}

- (void) addAppFileSystemHandler:(NSString*)authToken basePath:(NSString*)basePath indexPage:(NSString*)indexPage
{
    BOOL allowRangeRequests = YES;
    
    NSString* directoryPath = [[self.commandDelegate pathForResource:indexPage] stringByDeletingLastPathComponent];
;
    
    GCDWebServerAsyncProcessBlock processRequestBlock = ^void (GCDWebServerRequest* request, GCDWebServerCompletionBlock complete) {
        
        NSString* filePath = [directoryPath stringByAppendingPathComponent:[request.path substringFromIndex:basePath.length]];
        NSString* fileType = [[[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:NULL] fileType];
        GCDWebServerResponse* response = nil;

        if (fileType) {
            if ([fileType isEqualToString:NSFileTypeDirectory]) {
                if (indexPage) {
                    NSString* indexPath = [filePath stringByAppendingPathComponent:indexPage];
                    NSString* indexType = [[[NSFileManager defaultManager] attributesOfItemAtPath:indexPath error:NULL] fileType];
                    if ([indexType isEqualToString:NSFileTypeRegular]) {
                        complete([GCDWebServerFileResponse responseWithFile:indexPath]);
                    }
                }
                response = [self.server _responseWithContentsOfDirectory:filePath];
            } else if ([fileType isEqualToString:NSFileTypeRegular]) {
                if (allowRangeRequests) {
                    response = [GCDWebServerFileResponse responseWithFile:filePath byteRange:request.byteRange];
                    [response setValue:@"bytes" forAdditionalHeader:@"Accept-Ranges"];
                } else {
                    response = [GCDWebServerFileResponse responseWithFile:filePath];
                }
            }
        }
        
        complete(response);
    };
    
    [self addFileSystemHandler:processRequestBlock basePath:basePath authToken:authToken cacheAge:0];
}

- (void) addLocalFileSystemHandler:(NSString*)authToken
{
    NSString* basePath = @"/local-filesystem/";
    BOOL allowRangeRequests = YES;
    
    GCDWebServerAsyncProcessBlock processRequestBlock = ^void (GCDWebServerRequest* request, GCDWebServerCompletionBlock complete) {
        
        NSString* filePath = [request.path substringFromIndex:basePath.length];
        NSString* fileType = [[[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:NULL] fileType];
        GCDWebServerResponse* response = nil;
        
        if (fileType && [fileType isEqualToString:NSFileTypeRegular]) {
            if (allowRangeRequests) {
                response = [GCDWebServerFileResponse responseWithFile:filePath byteRange:request.byteRange];
                [response setValue:@"bytes" forAdditionalHeader:@"Accept-Ranges"];
            } else {
                response = [GCDWebServerFileResponse responseWithFile:filePath];
            }
        }
        
        complete(response);
    };
    
    [self addFileSystemHandler:processRequestBlock basePath:basePath authToken:authToken cacheAge:0];
}

- (void) addAssetLibraryFileSystemHandler:(NSString*)authToken
{
    NSString* basePath = @"/asset-library/";
    
    GCDWebServerAsyncProcessBlock processRequestBlock = ^void (GCDWebServerRequest* request, GCDWebServerCompletionBlock complete) {
        
        NSURL* assetUrl = [NSURL URLWithString:[NSString stringWithFormat:@"assets-library:/%@", [request.path substringFromIndex:basePath.length]]];
        
        ALAssetsLibrary* assetsLibrary = [[ALAssetsLibrary alloc] init];
        [assetsLibrary assetForURL:assetUrl
                       resultBlock:^(ALAsset* asset) {
                           if (asset) {
                               // We have the asset!  Get the data and send it off.
                               ALAssetRepresentation* assetRepresentation = [asset defaultRepresentation];
                               Byte* buffer = (Byte*)malloc([assetRepresentation size]);
                               NSUInteger bufferSize = [assetRepresentation getBytes:buffer fromOffset:0.0 length:[assetRepresentation size] error:nil];
                               NSData* data = [NSData dataWithBytesNoCopy:buffer length:bufferSize freeWhenDone:YES];
                               NSString* MIMEType = (__bridge_transfer NSString*)UTTypeCopyPreferredTagWithClass((__bridge CFStringRef)[assetRepresentation UTI], kUTTagClassMIMEType);
                               
                               complete([GCDWebServerDataResponse responseWithData:data contentType:MIMEType]);
                           } else {
                               complete(nil);
                           }
                       }
                      failureBlock:^(NSError* error) {
                          NSLog(@"Error: %@", error);
                          complete(nil);
                      }
         ];
    };
    
    [self addFileSystemHandler:processRequestBlock basePath:basePath authToken:authToken cacheAge:0];
}

@end