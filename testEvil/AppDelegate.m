//
//  AppDelegate.m
//  testEvil
//
//  Created by Landon Fuller on 1/19/13.
//  Copyright (c) 2013 Landon Fuller. All rights reserved.
//

#import "AppDelegate.h"
#import "libevil.h"

void (*orig_NSLog)(NSString *fmt, ...) = NULL;

void my_NSLog (NSString *fmt, ...) {
    orig_NSLog(@"Haha you actually want me to print something? OK, fine: %d", 42);
}

void (*orig_exit)(int v) = NULL;

void my_exit (int v) {
    NSLog(@"I'm afraid I can't let you do that, Dave");
}

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    evil_init();
    
#if 1
    evil_override_ptr(exit, my_exit, (void **) &orig_exit);
    exit(1);
#endif

#if 0
    evil_override_ptr(NSLog, my_NSLog, (void **) &orig_NSLog);

    NSLog(@"Please print this sir");
#endif

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    // Override point for customization after application launch.
    self.window.backgroundColor = [UIColor whiteColor];
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application
{
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later. 
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    // Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
}

@end
