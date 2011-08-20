//
//  AACConverterViewController.m
//  AACConverter
//
//  Created by Michael Tyson on 02/04/2011.
//  Copyright 2011 A Tasty Pixel. All rights reserved.
//

#import "AACConverterViewController.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

#define checkResult(result,operation) (_checkResult((result),(operation),__FILE__,__LINE__))
static inline BOOL _checkResult(OSStatus result, const char *operation, const char* file, int line) {
    if ( result != noErr ) {
        NSLog(@"%s:%d: %s result %d %08X %4.4s\n", file, line, operation, (int)result, (int)result, (char*)&result); 
        return NO;
    }
    return YES;
}


@implementation AACConverterViewController
@synthesize convertButton;
@synthesize playConvertedButton;
@synthesize emailConvertedButton;
@synthesize progressView;
@synthesize spinner;

// Callback to be notified of audio session interruptions (which have an impact on the conversion process)
static void interruptionListener(void *inClientData, UInt32 inInterruption)
{
	AACConverterViewController *THIS = (AACConverterViewController *)inClientData;
	
	if (inInterruption == kAudioSessionEndInterruption) {
		// make sure we are again the active session
		checkResult(AudioSessionSetActive(true), "resume audio session");
        if ( THIS->audioConverter ) [THIS->audioConverter resume];
	}
	
	if (inInterruption == kAudioSessionBeginInterruption) {
        if ( THIS->audioConverter ) [THIS->audioConverter interrupt];
    }
}

- (void)dealloc
{
    [convertButton release];
    [playConvertedButton release];
    [emailConvertedButton release];
    [progressView release];
    [spinner release];
    [progressView release];
    [spinner release];
    [super dealloc];
}

#pragma mark - View lifecycle

- (void)viewDidUnload
{
    [self setConvertButton:nil];
    [self setPlayConvertedButton:nil];
    [self setEmailConvertedButton:nil];
    [progressView release];
    progressView = nil;
    [spinner release];
    spinner = nil;
    [self setProgressView:nil];
    [self setSpinner:nil];
    [super viewDidUnload];
}

#pragma mark - Responders

- (IBAction)playOriginal:(id)sender {
    if ( audioPlayer ) {
        [audioPlayer stop];
        [audioPlayer release];
        audioPlayer = nil;
        [(UIButton*)sender setTitle:@"Play original" forState:UIControlStateNormal];
    } else {
        audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[[NSBundle mainBundle] URLForResource:@"audio" withExtension:@"aiff"] error:NULL];
        [audioPlayer play];
        
        [(UIButton*)sender setTitle:@"Stop" forState:UIControlStateNormal];
    }
}

- (IBAction)convert:(id)sender {
    if ( ![TPAACAudioConverter AACConverterAvailable] ) {
        [[[[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Converting audio", @"")
                                     message:NSLocalizedString(@"Couldn't convert audio: Not supported on this device", @"")
                                    delegate:nil
                           cancelButtonTitle:nil
                           otherButtonTitles:NSLocalizedString(@"OK", @""), nil] autorelease] show];
        return;
    }
    
    // Initialise audio session, and register an interruption listener, important for AAC conversion
    if ( !checkResult(AudioSessionInitialize(NULL, NULL, interruptionListener, self), "initialise audio session") ) {
        [[[[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Converting audio", @"")
                                     message:NSLocalizedString(@"Couldn't initialise audio session!", @"")
                                    delegate:nil
                           cancelButtonTitle:nil
                           otherButtonTitles:NSLocalizedString(@"OK", @""), nil] autorelease] show];
        return;
    }
    
    
    // Set up an audio session compatible with AAC conversion.  Note that AAC conversion is incompatible with any session that provides mixing with other device audio.
    UInt32 audioCategory = kAudioSessionCategory_MediaPlayback;
    if ( !checkResult(AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(audioCategory), &audioCategory), "setup session category") ) {
        [[[[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Converting audio", @"")
                                     message:NSLocalizedString(@"Couldn't setup audio category!", @"")
                                    delegate:nil
                           cancelButtonTitle:nil
                           otherButtonTitles:NSLocalizedString(@"OK", @""), nil] autorelease] show];
        return;
    } 
    
    NSArray *documentsFolders = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    audioConverter = [[[TPAACAudioConverter alloc] initWithDelegate:self 
                                                             source:[[NSBundle mainBundle] pathForResource:@"audio" ofType:@"aiff"]
                                                        destination:[[documentsFolders objectAtIndex:0] stringByAppendingPathComponent:@"audio.m4a"]] autorelease];
    ((UIButton*)sender).enabled = NO;
    [self.spinner startAnimating];
    self.progressView.progress = 0.0;
    self.progressView.hidden = NO;
    
    [audioConverter start];
}

- (IBAction)playConverted:(id)sender {
    if ( audioPlayer ) {
        [audioPlayer stop];
        [audioPlayer release];
        audioPlayer = nil;
        [(UIButton*)sender setTitle:@"Play converted" forState:UIControlStateNormal];
    } else {
        NSArray *documentsFolders = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *path = [[documentsFolders objectAtIndex:0] stringByAppendingPathComponent:@"audio.m4a"];
        audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:NULL];
        [audioPlayer play];
        
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
    audioConverter = nil;
}

-(void)AACAudioConverter:(TPAACAudioConverter *)converter didFailWithError:(NSError *)error {
    [[[[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Converting audio", @"")
                                 message:[NSString stringWithFormat:NSLocalizedString(@"Couldn't convert audio: %@", @""), [error localizedDescription]]
                                delegate:nil
                       cancelButtonTitle:nil
                       otherButtonTitles:NSLocalizedString(@"OK", @""), nil] autorelease] show];
    self.convertButton.enabled = YES;
    audioConverter = nil;
}

#pragma mark - Mail composer delegate

-(void)mailComposeController:(MFMailComposeViewController *)controller didFinishWithResult:(MFMailComposeResult)result error:(NSError *)error {
    [self dismissModalViewControllerAnimated:YES];
}

@end
