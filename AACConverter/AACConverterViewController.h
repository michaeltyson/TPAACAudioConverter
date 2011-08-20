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
@interface AACConverterViewController : UIViewController <TPAACAudioConverterDelegate, MFMailComposeViewControllerDelegate> {
    UIButton *convertButton;
    UIButton *playConvertedButton;
    UIButton *emailConvertedButton;
    UIProgressView *progressView;
    UIActivityIndicatorView *spinner;
    
    AVAudioPlayer *audioPlayer;
    TPAACAudioConverter *audioConverter;
}

- (IBAction)playOriginal:(id)sender;
- (IBAction)convert:(id)sender;
- (IBAction)playConverted:(id)sender;
- (IBAction)emailConverted:(id)sender;

@property (nonatomic, retain) IBOutlet UIButton *convertButton;
@property (nonatomic, retain) IBOutlet UIButton *playConvertedButton;
@property (nonatomic, retain) IBOutlet UIButton *emailConvertedButton;
@property (nonatomic, retain) IBOutlet UIProgressView *progressView;
@property (nonatomic, retain) IBOutlet UIActivityIndicatorView *spinner;
@end
