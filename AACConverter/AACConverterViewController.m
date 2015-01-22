//
//  AACConverterViewController.m
//  AACConverter
//
//  Created by Michael Tyson on 02/04/2011.
//  Copyright 2011 A Tasty Pixel. All rights reserved.
//

#import "AACConverterViewController.h"
#import <AVFoundation/AVFoundation.h>

@interface AACConverterViewController ()
@property (nonatomic) AVAudioPlayer *audioPlayer;
@property (nonatomic) TPAACAudioConverter *audioConverter;
@end

@implementation AACConverterViewController

#pragma mark - Responders

- (IBAction)playOriginal:(id)sender {
    if ( _audioPlayer ) {
        [_audioPlayer stop];
        self.audioPlayer = nil;
        [(UIButton*)sender setTitle:@"Play original" forState:UIControlStateNormal];
    } else {
        _audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[[NSBundle mainBundle] URLForResource:@"audio" withExtension:@"aiff"] error:NULL];
        [_audioPlayer play];
        
        [(UIButton*)sender setTitle:@"Stop" forState:UIControlStateNormal];
    }
}

- (IBAction)convert:(id)sender {
    if ( ![TPAACAudioConverter AACConverterAvailable] ) {
        [[[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Converting audio", @"")
                                    message:NSLocalizedString(@"Couldn't convert audio: Not supported on this device", @"")
                                   delegate:nil
                          cancelButtonTitle:nil
                          otherButtonTitles:NSLocalizedString(@"OK", @""), nil] show];
        return;
    }
    
    // Register an Audio Session interruption listener, important for AAC conversion
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(audioSessionInterrupted:)
                                                 name:AVAudioSessionInterruptionNotification
                                               object:nil];
    
    // Set up an audio session compatible with AAC conversion.  Note that AAC conversion is incompatible with any session that provides mixing with other device audio.
    NSError *error = nil;
    if ( ![[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                           withOptions:0
                                                 error:&error] ) {
        [[[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Converting audio", @"")
                                    message:[NSString stringWithFormat:NSLocalizedString(@"Couldn't setup audio category: %@", @""), error.localizedDescription]
                                   delegate:nil
                          cancelButtonTitle:nil
                          otherButtonTitles:NSLocalizedString(@"OK", @""), nil] show];
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        return;
    }
    
    // Activate audio session
    if ( ![[AVAudioSession sharedInstance] setActive:YES error:NULL] ) {
        [[[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Converting audio", @"")
                                    message:[NSString stringWithFormat:NSLocalizedString(@"Couldn't activate audio category: %@", @""), error.localizedDescription]
                                   delegate:nil
                          cancelButtonTitle:nil
                          otherButtonTitles:NSLocalizedString(@"OK", @""), nil] show];
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        return;

    }
    
    NSArray *documentsFolders = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    self.audioConverter = [[TPAACAudioConverter alloc] initWithDelegate:self
                                                                 source:[[NSBundle mainBundle] pathForResource:@"audio" ofType:@"aiff"]
                                                        destination:[[documentsFolders objectAtIndex:0] stringByAppendingPathComponent:@"audio.m4a"]];
    ((UIButton*)sender).enabled = NO;
    [self.spinner startAnimating];
    self.progressView.progress = 0.0;
    self.progressView.hidden = NO;
    [_audioConverter start];
}

- (IBAction)playConverted:(id)sender {
    if ( _audioPlayer ) {
        [_audioPlayer stop];
        self.audioPlayer = nil;
        [(UIButton*)sender setTitle:@"Play converted" forState:UIControlStateNormal];
    } else {
        NSArray *documentsFolders = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *path = [[documentsFolders objectAtIndex:0] stringByAppendingPathComponent:@"audio.m4a"];
        self.audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:NULL];
        [_audioPlayer play];
        
        [(UIButton*)sender setTitle:@"Stop" forState:UIControlStateNormal];
    }
}

- (IBAction)emailConverted:(id)sender {
    NSArray *documentsFolders = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *path = [[documentsFolders objectAtIndex:0] stringByAppendingPathComponent:@"audio.m4a"];
    
    MFMailComposeViewController *mailController = [[MFMailComposeViewController alloc] init];
    mailController.mailComposeDelegate = self;
    [mailController setSubject:NSLocalizedString(@"Recording", @"")];
    [mailController addAttachmentData:[NSData dataWithContentsOfMappedFile:path] 
                             mimeType:@"audio/mp4a-latm"
                             fileName:[path lastPathComponent]];
    
    [self presentModalViewController:mailController animated:YES];
}

#pragma mark - Audio converter delegate

-(void)AACAudioConverter:(TPAACAudioConverter *)converter didMakeProgress:(CGFloat)progress {
    self.progressView.progress = progress;
}

-(void)AACAudioConverterDidFinishConversion:(TPAACAudioConverter *)converter {
    self.progressView.hidden = YES;
    [self.spinner stopAnimating];
    self.convertButton.enabled = YES;
    self.playConvertedButton.enabled = YES;
    self.emailConvertedButton.enabled = YES;
    self.audioConverter = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

-(void)AACAudioConverter:(TPAACAudioConverter *)converter didFailWithError:(NSError *)error {
    [[[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Converting audio", @"")
                                message:[NSString stringWithFormat:NSLocalizedString(@"Couldn't convert audio: %@", @""), [error localizedDescription]]
                               delegate:nil
                      cancelButtonTitle:nil
                      otherButtonTitles:NSLocalizedString(@"OK", @""), nil] show];
    self.convertButton.enabled = YES;
    self.audioConverter = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Mail composer delegate

-(void)mailComposeController:(MFMailComposeViewController *)controller didFinishWithResult:(MFMailComposeResult)result error:(NSError *)error {
    [self dismissModalViewControllerAnimated:YES];
}

#pragma mark - Audio session interruption

- (void)audioSessionInterrupted:(NSNotification*)notification {
    AVAudioSessionInterruptionType type = [notification.userInfo[AVAudioSessionInterruptionTypeKey] integerValue];
    
    if ( type == AVAudioSessionInterruptionTypeEnded) {
        [[AVAudioSession sharedInstance] setActive:YES error:NULL];
        if ( _audioConverter ) [_audioConverter resume];
    } else if ( type == AVAudioSessionInterruptionTypeBegan ) {
        if ( _audioConverter ) [_audioConverter interrupt];
    }
}

@end
