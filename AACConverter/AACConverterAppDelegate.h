//
//  AACConverterAppDelegate.h
//  AACConverter
//
//  Created by Michael Tyson on 02/04/2011.
//  Copyright 2011 A Tasty Pixel. All rights reserved.
//

#import <UIKit/UIKit.h>

@class AACConverterViewController;

@interface AACConverterAppDelegate : NSObject <UIApplicationDelegate>
@property (nonatomic, strong) IBOutlet UIWindow *window;
@property (nonatomic, strong) IBOutlet AACConverterViewController *viewController;
@end
