//
//  TPAACAudioConverter.m
//
//  Created by Michael Tyson on 02/04/2011.
//  Copyright 2011 A Tasty Pixel. All rights reserved.
//

#import "TPAACAudioConverter.h"
#import <AudioToolbox/AudioToolbox.h>

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

static BOOL _available;
static BOOL _available_set = NO;

@interface TPAACAudioConverter ()
@property (nonatomic, readwrite, retain) NSString *source;
@property (nonatomic, readwrite, retain) NSString *destination;
@property (nonatomic, retain) id<TPAACAudioConverterDataSource> dataSource;
@end

@implementation TPAACAudioConverter
@synthesize source, destination, dataSource, audioFormat;

+ (BOOL)AACConverterAvailable {
    if ( _available_set ) return _available;
    
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
        _available_set = YES;
        _available = NO;
        return NO;
    }
    
    for (UInt32 i=0; i < numEncoders; ++i) {
        if ( encoderDescriptions[i].mSubType == kAudioFormatMPEG4AAC && encoderDescriptions[i].mManufacturer == kAppleHardwareAudioCodecManufacturer ) {
            _available_set = YES;
            _available = YES;
            return YES;
        }
    }
    
    _available_set = YES;
    _available = NO;
    return NO;
}

- (id)initWithDelegate:(id<TPAACAudioConverterDelegate>)_delegate source:(NSString*)sourcePath destination:(NSString*)destinationPath {
    if ( !(self = [super init]) ) return nil;
    
    delegate = _delegate;
    self.source = sourcePath;
    self.destination = destinationPath;
    condition = [[NSCondition alloc] init];
    
    return self;
}

- (id)initWithDelegate:(id<TPAACAudioConverterDelegate>)_delegate dataSource:(id<TPAACAudioConverterDataSource>)_dataSource
           audioFormat:(AudioStreamBasicDescription)_audioFormat destination:(NSString*)destinationPath {
    if ( !(self = [super init]) ) return nil;
    
    delegate = _delegate;
    self.dataSource = [_dataSource retain];
    self.destination = destinationPath;
    audioFormat = _audioFormat;
    condition = [[NSCondition alloc] init];
    
    return self;
}

- (void)dealloc {
    [condition release];
    condition = nil;
    self.source = nil;
    self.destination = nil;
    self.dataSource = nil;
    [super dealloc];
}

-(void)start {
    UInt32 size = sizeof(priorMixOverrideValue);
    checkResult(AudioSessionGetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, &size, &priorMixOverrideValue), 
                "AudioSessionGetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers)");
    
    if ( priorMixOverrideValue != NO ) {
        UInt32 allowMixing = NO;
        checkResult(AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, sizeof (allowMixing), &allowMixing),
                    "AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers)");
    }
    
    cancelled = NO;
    processing = YES;
    [self retain];
    [self performSelectorInBackground:@selector(processingThread) withObject:nil];
}

-(void)cancel {
    cancelled = YES;
    while ( processing ) {
        [NSThread sleepForTimeInterval:0.01];
    }
    if ( priorMixOverrideValue != NO ) {
        UInt32 allowMixing = priorMixOverrideValue;
        checkResult(AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, sizeof (allowMixing), &allowMixing),
                    "AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers)");
    }
    [self autorelease];
}

- (void)interrupt {
    [condition lock];
    interrupted = YES;
    [condition unlock];
}

- (void)resume {
    [condition lock];
    interrupted = NO;
    [condition signal];
    [condition unlock];
}

- (void)reportProgress:(NSNumber*)progress {
    [delegate AACAudioConverter:self didMakeProgress:[progress floatValue]];
}

- (void)reportCompletion {
    [delegate AACAudioConverterDidFinishConversion:self];
    if ( priorMixOverrideValue != NO ) {
        UInt32 allowMixing = priorMixOverrideValue;
        checkResult(AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, sizeof (allowMixing), &allowMixing),
                    "AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers)");
    }
    [self autorelease];
}

- (void)reportErrorAndCleanup:(NSError*)error {
    [[NSFileManager defaultManager] removeItemAtPath:destination error:NULL];
    if ( priorMixOverrideValue != NO ) {
        UInt32 allowMixing = priorMixOverrideValue;
        checkResult(AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, sizeof (allowMixing), &allowMixing),
                    "AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers)");
    }
    [self autorelease];
    [delegate AACAudioConverter:self didFailWithError:error];
}

- (void)processingThread {
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    
    [[NSThread currentThread] setThreadPriority:0.9];
    
    ExtAudioFileRef sourceFile = NULL;
    AudioStreamBasicDescription sourceFormat;
    if ( source ) {
        if ( !checkResult(ExtAudioFileOpenURL((CFURLRef)[NSURL fileURLWithPath:source], &sourceFile), "ExtAudioFileOpenURL") ) {
            [self performSelectorOnMainThread:@selector(reportErrorAndCleanup:)
                                   withObject:[NSError errorWithDomain:TPAACAudioConverterErrorDomain
                                                                  code:TPAACAudioConverterFileError
                                                              userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Couldn't open the source file", @"") forKey:NSLocalizedDescriptionKey]]
                                waitUntilDone:NO];
            [pool release];
            processing = NO;
            return;
        }
        
        
        UInt32 size = sizeof(sourceFormat);
        if ( !checkResult(ExtAudioFileGetProperty(sourceFile, kExtAudioFileProperty_FileDataFormat, &size, &sourceFormat), 
                          "ExtAudioFileGetProperty(kExtAudioFileProperty_FileDataFormat)") ) {
            [self performSelectorOnMainThread:@selector(reportErrorAndCleanup:)
                                   withObject:[NSError errorWithDomain:TPAACAudioConverterErrorDomain
                                                                  code:TPAACAudioConverterFormatError
                                                              userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Couldn't read the source file", @"") forKey:NSLocalizedDescriptionKey]]
                                waitUntilDone:NO];
            [pool release];
            processing = NO;
            return;
        }
    } else {
        sourceFormat = audioFormat;
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
                                                          userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Couldn't setup destination format", @"") forKey:NSLocalizedDescriptionKey]]
                            waitUntilDone:NO];
        [pool release];
        processing = NO;
        return;
    }
    
    ExtAudioFileRef destinationFile;
    if ( !checkResult(ExtAudioFileCreateWithURL((CFURLRef)[NSURL fileURLWithPath:destination], kAudioFileM4AType, &destinationFormat, NULL, kAudioFileFlags_EraseFile, &destinationFile), "ExtAudioFileCreateWithURL") ) {
        [self performSelectorOnMainThread:@selector(reportErrorAndCleanup:)
                               withObject:[NSError errorWithDomain:TPAACAudioConverterErrorDomain
                                                              code:TPAACAudioConverterFileError
                                                          userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Couldn't open the source file", @"") forKey:NSLocalizedDescriptionKey]]
                            waitUntilDone:NO];
        [pool release];
        processing = NO;
        return;
    }
    
    AudioStreamBasicDescription clientFormat;
    if ( sourceFormat.mFormatID == kAudioFormatLinearPCM ) {
        clientFormat = sourceFormat;
    } else {
        memset(&clientFormat, 0, sizeof(clientFormat));
        int sampleSize = sizeof(AudioSampleType);
        clientFormat.mFormatID = kAudioFormatLinearPCM;
        clientFormat.mFormatFlags = kAudioFormatFlagsCanonical;
        clientFormat.mBitsPerChannel = 8 * sampleSize;
        clientFormat.mChannelsPerFrame = sourceFormat.mChannelsPerFrame;
        clientFormat.mFramesPerPacket = 1;
        clientFormat.mBytesPerPacket = clientFormat.mBytesPerFrame = sourceFormat.mChannelsPerFrame * sampleSize;
        clientFormat.mSampleRate = sourceFormat.mSampleRate;
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
                                                          userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Couldn't setup intermediate conversion format", @"") forKey:NSLocalizedDescriptionKey]]
                            waitUntilDone:NO];
        [pool release];
        processing = NO;
        return;
    }
    
    BOOL canResumeFromInterruption = YES;
    AudioConverterRef converter;
    size = sizeof(converter);
    if ( checkResult(ExtAudioFileGetProperty(destinationFile, kExtAudioFileProperty_AudioConverter, &size, &converter), 
                      "ExtAudioFileGetProperty(kExtAudioFileProperty_AudioConverter;)") ) {
        UInt32 canResume = 0;
        size = sizeof(canResume);
        if ( checkResult(AudioConverterGetProperty(converter, kAudioConverterPropertyCanResumeFromInterruption, &size, &canResume), 
                         "AudioConverterGetProperty(kAudioConverterPropertyCanResumeFromInterruption") ) {
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
    BOOL reportProgress = lengthInFrames > 0 && [delegate respondsToSelector:@selector(AACAudioConverter:didMakeProgress:)];
    NSTimeInterval lastProgressReport = [NSDate timeIntervalSinceReferenceDate];
    
    while ( !cancelled ) {
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
                                                                  userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Error reading the source file", @"") forKey:NSLocalizedDescriptionKey]]
                                    waitUntilDone:NO];
                [pool release];
                processing = NO;
                return;
            }
        } else {
            NSUInteger length = bufferByteSize;
            [dataSource AACAudioConverter:self nextBytes:srcBuffer length:&length];
            numFrames = length / clientFormat.mBytesPerFrame;
            fillBufList.mBuffers[0].mDataByteSize = length;
        }
        
        if ( !numFrames ) {
            break;
        }
        
        sourceFrameOffset += numFrames;
        
        [condition lock];
        BOOL wasInterrupted = interrupted;
        while ( interrupted ) {
            [condition wait];
        }
        [condition unlock];
        
        if ( wasInterrupted && !canResumeFromInterruption ) {
            if ( sourceFile ) ExtAudioFileDispose(sourceFile);
            ExtAudioFileDispose(destinationFile);
            [self performSelectorOnMainThread:@selector(reportErrorAndCleanup:)
                                   withObject:[NSError errorWithDomain:TPAACAudioConverterErrorDomain
                                                                  code:TPAACAudioConverterUnrecoverableInterruptionError
                                                              userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Interrupted", @"") forKey:NSLocalizedDescriptionKey]]
                                waitUntilDone:NO];
            [pool release];
            processing = NO;
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
            } else if ( [dataSource respondsToSelector:@selector(AACAudioConverter:seekToPosition:)] ) {
                [dataSource AACAudioConverter:self seekToPosition:sourceFrameOffset * clientFormat.mBytesPerFrame];
            }
        } else if ( !checkResult(status, "ExtAudioFileWrite") ) {
            if ( sourceFile ) ExtAudioFileDispose(sourceFile);
            ExtAudioFileDispose(destinationFile);
            [self performSelectorOnMainThread:@selector(reportErrorAndCleanup:)
                                   withObject:[NSError errorWithDomain:TPAACAudioConverterErrorDomain
                                                                  code:TPAACAudioConverterFormatError
                                                              userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"Error writing the destination file", @"") forKey:NSLocalizedDescriptionKey]]
                                waitUntilDone:NO];
            [pool release];
            processing = NO;
            return;
        }
        
        if ( reportProgress && [NSDate timeIntervalSinceReferenceDate]-lastProgressReport > 0.1 ) {
            lastProgressReport = [NSDate timeIntervalSinceReferenceDate];
            [self performSelectorOnMainThread:@selector(reportProgress:) withObject:[NSNumber numberWithFloat:(double)sourceFrameOffset/lengthInFrames] waitUntilDone:NO];
        }
    }

    if ( sourceFile ) ExtAudioFileDispose(sourceFile);
    ExtAudioFileDispose(destinationFile);
    
    if ( cancelled ) {
        [[NSFileManager defaultManager] removeItemAtPath:destination error:NULL];
    } else {
        [self performSelectorOnMainThread:@selector(reportCompletion) withObject:nil waitUntilDone:NO];
    }
    
    processing = NO;
    
    [pool release];
}

@end
