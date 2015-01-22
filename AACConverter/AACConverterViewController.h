//
//  AACConverterViewController.h
//  AACConverter
//
//  Created by Michael Tyson on 02/04/2011.
//  Copyright 2011 A Tasty Pixel. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <MessageUI/MessageUI.h>
#import "TPAACAudioConverter.h"

@class AVAudioPlayer;
@interface AACConverterViewController : UIViewController <TPAACAudioConverterDelegate, MFMailComposeViewControllerDelegate>
- (IBAction)playOriginal:(id)sender;
- (IBAction)convert:(id)sender;
- (IBAction)playConverted:(id)sender;
- (IBAction)emailConverted:(id)sender;

@property (nonatomic, strong) IBOutlet UIButton *convertButton;
@property (nonatomic, strong) IBOutlet UIButton *playConvertedButton;
@property (nonatomic, strong) IBOutlet UIButton *emailConvertedButton;
@property (nonatomic, strong) IBOutlet UIProgressView *progressView;
@property (nonatomic, strong) IBOutlet UIActivityIndicatorView *spinner;
@end
