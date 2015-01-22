//
//  TPAACAudioConverter.m
//
//  Created by Michael Tyson on 02/04/2011.
//  Copyright 2011 A Tasty Pixel. All rights reserved.
//

#import "TPAACAudioConverter.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

#if !__has_feature(objc_arc)
#error This file must be compiled with ARC. Use -fobjc-arc flag (or convert project to ARC).
#endif

NSString * TPAACAudioConverterWillSwitchAudioSessionCategoryNotification = @"TPAACAudioConverterWillSwitchAudioSessionCategoryNotification";
NSString * TPAACAudioConverterDidRestoreAudioSessionCategoryNotification = @"TPAACAudioConverterDidRestoreAudioSessionCategoryNotification";

NSString * TPAACAudioConverterErrorDomain = @"com.atastypixel.TPAACAudioConverterErrorDomain";

#define checkResult(result,operation) (_checkResultLite((result),(operation),__FILE__,__LINE__))

static inline BOOL _checkResultLite(OSStatus result, const char *operation, const char* file, int line) {
    if ( result != noErr ) {
        NSLog(@"%s:%d: %s result %d %08X %4.4s\n", file, line, operation, (int)result, (int)result, (char*)&result); 
        return NO;
    }
    return YES;
}

@interface TPAACAudioConverter ()  {
    BOOL            _processing;
    BOOL            _cancelled;
    BOOL            _interrupted;
    AVAudioSessionCategoryOptions _priorCategoryOptions;
}
@property (nonatomic, readwrite, strong) NSString *source;
@property (nonatomic, readwrite, strong) NSString *destination;
@property (nonatomic, assign) id<TPAACAudioConverterDelegate> delegate;
@property (nonatomic, strong) id<TPAACAudioConverterDataSource> dataSource;
@property (nonatomic, strong) NSCondition *condition;
@end

@implementation TPAACAudioConverter

+ (BOOL)AACConverterAvailable {
#if TARGET_IPHONE_SIMULATOR
    return YES;
#else
    static BOOL available;
    static BOOL available_set = NO;

    if ( available_set ) return available;
    
    // get an array of AudioClassDescriptions for all installed encoders for the given format 
    // the specifier is the format that we are interested in - this is 'aac ' in our case
    UInt32 encoderSpecifier = kAudioFormatMPEG4AAC;
    UInt32 size;
    
    if ( !checkResult(AudioFormatGetPropertyInfo(kAudioFormatProperty_Encoders, sizeof(encoderSpecifier), &encoderSpecifier, &size),
                      "AudioFormatGetPropertyInfo(kAudioFormatProperty_Encoders") ) return NO;
    
    UInt32 numEncoders = size / sizeof(AudioClassDescription);
    AudioClassDescription encoderDescriptions[numEncoders];
    
    if ( !checkResult(AudioFormatGetProperty(kAudioFormatProperty_Encoders, sizeof(encoderSpecifier), &encoderSpecifier, &size, encoderDescriptions),
                      "AudioFormatGetProperty(kAudioFormatProperty_Encoders") ) {
        available_set = YES;
        available = NO;
        return NO;
    }
    
    for (UInt32 i=0; i < numEncoders; ++i) {
        if ( encoderDescriptions[i].mSubType == kAudioFormatMPEG4AAC ) {
            available_set = YES;
            available = YES;
            return YES;
        }
    }
    
    available_set = YES;
    available = NO;
    return NO;
#endif
}

- (id)initWithDelegate:(id<TPAACAudioConverterDelegate>)delegate source:(NSString*)source destination:(NSString*)destination {
    if ( !(self = [super init]) ) return nil;
    
    self.delegate = delegate;
    self.source = source;
    self.destination = destination;
    _condition = [[NSCondition alloc] init];
    
    return self;
}

- (id)initWithDelegate:(id<TPAACAudioConverterDelegate>)delegate dataSource:(id<TPAACAudioConverterDataSource>)dataSource
           audioFormat:(AudioStreamBasicDescription)audioFormat destination:(NSString*)destination {
    if ( !(self = [super init]) ) return nil;
    
    self.delegate = delegate;
    self.dataSource = dataSource;
    self.destination = destination;
    _audioFormat = audioFormat;
    _condition = [[NSCondition alloc] init];
    
    return self;
}

-(void)start {
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    
    _priorCategoryOptions = audioSession.categoryOptions;
    
    if ( _priorCategoryOptions & AVAudioSessionCategoryOptionMixWithOthers ) {
        NSError *error = nil;
        if ( ![audioSession setCategory:audioSession.category
                            withOptions:_priorCategoryOptions & ~AVAudioSessionCategoryOptionMixWithOthers
                                  error:&error] ) {
            NSLog(@"Couldn't disable mix with others Audio Session option for AAC conversion: %@", error.localizedDescription);
        }
    }
    
    _cancelled = NO;
    _processing = YES;
    [self performSelectorInBackground:@selector(processingThread) withObject:nil];
}

-(void)cancel {
    _cancelled = YES;
    while ( _processing ) {
        [NSThread sleepForTimeInterval:0.01];
    }
    if ( _priorCategoryOptions & AVAudioSessionCategoryOptionMixWithOthers ) {
        NSError *error = nil;
        if ( ![[AVAudioSession sharedInstance] setCategory:[AVAudioSession sharedInstance].category
                                               withOptions:_priorCategoryOptions
                                                     error:&error] ) {
            NSLog(@"Couldn't reinstate Audio Session options for AAC conversion: %@", error.localizedDescription);
        }
    }
}

- (void)interrupt {
    [_condition lock];
    _interrupted = YES;
    [_condition unlock];
}

- (void)resume {
    [_condition lock];
    _interrupted = NO;
    [_condition signal];
    [_condition unlock];
}

- (void)reportProgress:(NSNumber*)progress {
    if ( _cancelled ) return;
    [_delegate AACAudioConverter:self didMakeProgress:[progress floatValue]];
}

- (void)reportCompletion {
    if ( _cancelled ) return;
    [_delegate AACAudioConverterDidFinishConversion:self];
    if ( _priorCategoryOptions & AVAudioSessionCategoryOptionMixWithOthers ) {
        NSError *error = nil;
        if ( ![[AVAudioSession sharedInstance] setCategory:[AVAudioSession sharedInstance].category
                                               withOptions:_priorCategoryOptions
                                                     error:&error] ) {
            NSLog(@"Couldn't reinstate Audio Session options for AAC conversion: %@", error.localizedDescription);
        }
    }
}

- (void)reportErrorAndCleanup:(NSError*)error {
    if ( _cancelled ) return;
    [[NSFileManager defaultManager] removeItemAtPath:_destination error:NULL];
    if ( _priorCategoryOptions & AVAudioSessionCategoryOptionMixWithOthers ) {
        NSError *error = nil;
        if ( ![[AVAudioSession sharedInstance] setCategory:[AVAudioSession sharedInstance].category
                                               withOptions:_priorCategoryOptions
                                                     error:&error] ) {
            NSLog(@"Couldn't reinstate Audio Session options for AAC conversion: %@", error.localizedDescription);
        }
    }
    [_delegate AACAudioConverter:self didFailWithError:error];
}

- (void)processingThread {
    [[NSThread currentThread] setThreadPriority:0.9];
    
    ExtAudioFileRef sourceFile = NULL;
    AudioStreamBasicDescription sourceFormat;
    if ( _source ) {
        if ( !checkResult(ExtAudioFileOpenURL((__bridge CFURLRef)[NSURL fileURLWithPath:_source], &sourceFile), "ExtAudioFileOpenURL") ) {
            [self performSelectorOnMainThread:@selector(reportErrorAndCleanup:)
                                   withObject:[NSError errorWithDomain:TPAACAudioConverterErrorDomain
                                                                  code:TPAACAudioConverterFileError
                                                              userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Couldn't open the source file", @"Error message") forKey:NSLocalizedDescriptionKey]]
                                waitUntilDone:NO];
            _processing = NO;
            return;
        }
        
        
        UInt32 size = sizeof(sourceFormat);
        if ( !checkResult(ExtAudioFileGetProperty(sourceFile, kExtAudioFileProperty_FileDataFormat, &size, &sourceFormat), 
                          "ExtAudioFileGetProperty(kExtAudioFileProperty_FileDataFormat)") ) {
            [self performSelectorOnMainThread:@selector(reportErrorAndCleanup:)
                                   withObject:[NSError errorWithDomain:TPAACAudioConverterErrorDomain
                                                                  code:TPAACAudioConverterFormatError
                                                              userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Couldn't read the source file", @"Error message") forKey:NSLocalizedDescriptionKey]]
                                waitUntilDone:NO];
            _processing = NO;
            return;
        }
    } else {
        sourceFormat = _audioFormat;
    }
    
    AudioStreamBasicDescription destinationFormat;
    memset(&destinationFormat, 0, sizeof(destinationFormat));
    destinationFormat.mChannelsPerFrame = sourceFormat.mChannelsPerFrame;
    destinationFormat.mFormatID = kAudioFormatMPEG4AAC;
    UInt32 size = sizeof(destinationFormat);
    if ( !checkResult(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, NULL, &size, &destinationFormat), 
                      "AudioFormatGetProperty(kAudioFormatProperty_FormatInfo)") ) {
        [self performSelectorOnMainThread:@selector(reportErrorAndCleanup:)
                               withObject:[NSError errorWithDomain:TPAACAudioConverterErrorDomain
                                                              code:TPAACAudioConverterFormatError
                                                          userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Couldn't setup destination format", @"Error message") forKey:NSLocalizedDescriptionKey]]
                            waitUntilDone:NO];
        _processing = NO;
        return;
    }
    
    ExtAudioFileRef destinationFile;
    if ( !checkResult(ExtAudioFileCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:_destination],
                                                kAudioFileM4AType,
                                                &destinationFormat,
                                                NULL,
                                                kAudioFileFlags_EraseFile,
                                                &destinationFile), "ExtAudioFileCreateWithURL") ) {
        [self performSelectorOnMainThread:@selector(reportErrorAndCleanup:)
                               withObject:[NSError errorWithDomain:TPAACAudioConverterErrorDomain
                                                              code:TPAACAudioConverterFileError
                                                          userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Couldn't open the source file", @"Error message") forKey:NSLocalizedDescriptionKey]]
                            waitUntilDone:NO];
        _processing = NO;
        return;
    }
    
    AudioStreamBasicDescription clientFormat;
    if ( sourceFormat.mFormatID == kAudioFormatLinearPCM ) {
        clientFormat = sourceFormat;
    } else {
        memset(&clientFormat, 0, sizeof(clientFormat));
        clientFormat.mFormatID          = kAudioFormatLinearPCM;
        clientFormat.mFormatFlags       = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
        clientFormat.mChannelsPerFrame  = sourceFormat.mChannelsPerFrame;
        clientFormat.mBytesPerPacket    = sizeof(float);
        clientFormat.mFramesPerPacket   = 1;
        clientFormat.mBytesPerFrame     = sizeof(float);
        clientFormat.mBitsPerChannel    = 8 * sizeof(float);
        clientFormat.mSampleRate        = sourceFormat.mSampleRate;
    }
    
    size = sizeof(clientFormat);
    if ( (sourceFile && !checkResult(ExtAudioFileSetProperty(sourceFile, kExtAudioFileProperty_ClientDataFormat, size, &clientFormat), 
                      "ExtAudioFileSetProperty(sourceFile, kExtAudioFileProperty_ClientDataFormat")) ||
         !checkResult(ExtAudioFileSetProperty(destinationFile, kExtAudioFileProperty_ClientDataFormat, size, &clientFormat), 
                      "ExtAudioFileSetProperty(destinationFile, kExtAudioFileProperty_ClientDataFormat")) {
        if ( sourceFile ) ExtAudioFileDispose(sourceFile);
        ExtAudioFileDispose(destinationFile);
        [self performSelectorOnMainThread:@selector(reportErrorAndCleanup:)
                               withObject:[NSError errorWithDomain:TPAACAudioConverterErrorDomain
                                                              code:TPAACAudioConverterFormatError
                                                          userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Couldn't setup intermediate conversion format", @"Error message") forKey:NSLocalizedDescriptionKey]]
                            waitUntilDone:NO];
        _processing = NO;
        return;
    }
    
    BOOL canResumeFromInterruption = YES;
    AudioConverterRef converter;
    size = sizeof(converter);
    if ( checkResult(ExtAudioFileGetProperty(destinationFile, kExtAudioFileProperty_AudioConverter, &size, &converter), 
                      "ExtAudioFileGetProperty(kExtAudioFileProperty_AudioConverter;)") ) {
        UInt32 canResume = 0;
        size = sizeof(canResume);
        if ( AudioConverterGetProperty(converter, kAudioConverterPropertyCanResumeFromInterruption, &size, &canResume) == noErr ) {
            canResumeFromInterruption = (BOOL)canResume;
        }
    }
    
    SInt64 lengthInFrames = 0;
    if ( sourceFile ) {
        size = sizeof(lengthInFrames);
        ExtAudioFileGetProperty(sourceFile, kExtAudioFileProperty_FileLengthFrames, &size, &lengthInFrames);
    }
    
    UInt32 bufferByteSize = 32768;
    char srcBuffer[bufferByteSize];
    SInt64 sourceFrameOffset = 0;
    BOOL reportProgress = lengthInFrames > 0 && [_delegate respondsToSelector:@selector(AACAudioConverter:didMakeProgress:)];
    NSTimeInterval lastProgressReport = [NSDate timeIntervalSinceReferenceDate];
    
    while ( !_cancelled ) {
        AudioBufferList fillBufList;
        fillBufList.mNumberBuffers = 1;
        fillBufList.mBuffers[0].mNumberChannels = clientFormat.mChannelsPerFrame;
        fillBufList.mBuffers[0].mDataByteSize = bufferByteSize;
        fillBufList.mBuffers[0].mData = srcBuffer;
        
        UInt32 numFrames = bufferByteSize / clientFormat.mBytesPerFrame;
        
        if ( sourceFile ) {
            if ( !checkResult(ExtAudioFileRead(sourceFile, &numFrames, &fillBufList), "ExtAudioFileRead") ) {
                ExtAudioFileDispose(sourceFile);
                ExtAudioFileDispose(destinationFile);
                [self performSelectorOnMainThread:@selector(reportErrorAndCleanup:)
                                       withObject:[NSError errorWithDomain:TPAACAudioConverterErrorDomain
                                                                      code:TPAACAudioConverterFormatError
                                                                  userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Error reading the source file", @"Error message") forKey:NSLocalizedDescriptionKey]]
                                    waitUntilDone:NO];
                _processing = NO;
                return;
            }
        } else {
            NSUInteger length = bufferByteSize;
            [_dataSource AACAudioConverter:self nextBytes:srcBuffer length:&length];
            numFrames = length / clientFormat.mBytesPerFrame;
            fillBufList.mBuffers[0].mDataByteSize = length;
        }
        
        if ( !numFrames ) {
            break;
        }
        
        sourceFrameOffset += numFrames;
        
        [_condition lock];
        BOOL wasInterrupted = _interrupted;
        while ( _interrupted ) {
            [_condition wait];
        }
        [_condition unlock];
        
        if ( wasInterrupted && !canResumeFromInterruption ) {
            if ( sourceFile ) ExtAudioFileDispose(sourceFile);
            ExtAudioFileDispose(destinationFile);
            [self performSelectorOnMainThread:@selector(reportErrorAndCleanup:)
                                   withObject:[NSError errorWithDomain:TPAACAudioConverterErrorDomain
                                                                  code:TPAACAudioConverterUnrecoverableInterruptionError
                                                              userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Interrupted", @"Error message") forKey:NSLocalizedDescriptionKey]]
                                waitUntilDone:NO];
            _processing = NO;
            return;
        }
        
        OSStatus status = ExtAudioFileWrite(destinationFile, numFrames, &fillBufList);
        
        if ( status == kExtAudioFileError_CodecUnavailableInputConsumed) {
            /*
             Returned when ExtAudioFileWrite was interrupted. You must stop calling
             ExtAudioFileWrite. If the underlying audio converter can resume after an
             interruption (see kAudioConverterPropertyCanResumeFromInterruption), you must
             wait for an EndInterruption notification from AudioSession, and call AudioSessionSetActive(true)
             before resuming. In this situation, the buffer you provided to ExtAudioFileWrite was successfully
             consumed and you may proceed to the next buffer
             */
        } else if ( status == kExtAudioFileError_CodecUnavailableInputNotConsumed ) {
            /*
             Returned when ExtAudioFileWrite was interrupted. You must stop calling
             ExtAudioFileWrite. If the underlying audio converter can resume after an
             interruption (see kAudioConverterPropertyCanResumeFromInterruption), you must
             wait for an EndInterruption notification from AudioSession, and call AudioSessionSetActive(true)
             before resuming. In this situation, the buffer you provided to ExtAudioFileWrite was not
             successfully consumed and you must try to write it again
             */
                
            // seek back to last offset before last read so we can try again after the interruption
            sourceFrameOffset -= numFrames;
            if ( sourceFile ) {
                checkResult(ExtAudioFileSeek(sourceFile, sourceFrameOffset), "ExtAudioFileSeek");
            } else if ( [_dataSource respondsToSelector:@selector(AACAudioConverter:seekToPosition:)] ) {
                [_dataSource AACAudioConverter:self seekToPosition:sourceFrameOffset * clientFormat.mBytesPerFrame];
            }
        } else if ( !checkResult(status, "ExtAudioFileWrite") ) {
            if ( sourceFile ) ExtAudioFileDispose(sourceFile);
            ExtAudioFileDispose(destinationFile);
            [self performSelectorOnMainThread:@selector(reportErrorAndCleanup:)
                                   withObject:[NSError errorWithDomain:TPAACAudioConverterErrorDomain
                                                                  code:TPAACAudioConverterFormatError
                                                              userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Error writing the destination file", @"Error message") forKey:NSLocalizedDescriptionKey]]
                                waitUntilDone:NO];
            _processing = NO;
            return;
        }
        
        if ( reportProgress && [NSDate timeIntervalSinceReferenceDate]-lastProgressReport > 0.1 ) {
            lastProgressReport = [NSDate timeIntervalSinceReferenceDate];
            [self performSelectorOnMainThread:@selector(reportProgress:) withObject:[NSNumber numberWithDouble:(double)sourceFrameOffset/lengthInFrames] waitUntilDone:NO];
        }
    }

    if ( sourceFile ) ExtAudioFileDispose(sourceFile);
    ExtAudioFileDispose(destinationFile);
    
    if ( _cancelled ) {
        [[NSFileManager defaultManager] removeItemAtPath:_destination error:NULL];
    } else {
        [self performSelectorOnMainThread:@selector(reportCompletion) withObject:nil waitUntilDone:NO];
    }
    
    _processing = NO;
}

@end
