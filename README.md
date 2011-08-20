Objective-C wrapper for AAC audio conversion
============================================

TPAACAudioConverter is a simple Objective-C class that performs the conversion of any audio file to an AAC-encoded m4a, asynchronously with a delegate, or converts any audio provided by a data source class (which provides for recording straight to AAC).


Introduction
------------

From the iPhone 3Gs up, it's possible to encode compressed AAC audio from PCM audio data.  That means great things for apps that deal with audio sharing and transmission, as the audio can be sent in compressed form, rather than sending huge PCM audio files over the network.

Apple's produced some [sample code (iPhoneExtAudioFileConvertTest)](http://developer.apple.com/library/ios/samplecode/iPhoneExtAudioFileConvertTest/Introduction/Intro.html), which demonstrates how it's done, but their implementation isn't particularly easy to use in existing projects, as it requires some wrapping to make it play nice.

Hence, TPAACAudioConverter: A simple to use Objective-C wrapper.

Usage
-----

- Include the class in your project, and make sure you've got the *AudioToolbox* framework added, too.
- Audio session setup: 

If you already have an audio session set up in your app, make sure you disable mixing with other device audio for the duration of the copy operation, as this stops the hardware encoder from working (you'll see funny errors like `kAudioQueueErr_InvalidCodecAccess` (Error 66672)).  I know that `AVAudioSessionCategoryPlayAndRecord`, `AVAudioSessionCategorySoloAmbient` and `AVAudioSessionCategoryAudioProcessing` work for sure.  `TPAACAudioConverter` will automatically disable `kAudioSessionProperty_OverrideCategoryMixWithOthers`, if it's set.

If you're not already setting up an audio session, you could do so just before you start the conversion process.

You'll need to provide an interruption handler to be notified of audio session interruptions, which impact the encoding process.  You'll also need to create a member variable to store the converter instance, so you can tell it when interruptions begin and end (via `interrupt` and `resume`).

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

    /*snip*/

    -(void)startConverting {

        /*snip*/

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


        /*snip*/
    }


- Make the relevant view controller implement the `TPAACAudioConverterDelegate` protocol: That means implementing `AACAudioConverterDidFinishConversion:`, and  `AACAudioConverter:didFailWithError:`, and optionally `AACAudioConverter:didMakeProgress:` to receive progress updates.
- Create an instance of the converter, pass it the view controller as the delegate, and call `start`:


    audioConverter = [[[TPAACAudioConverter alloc] initWithDelegate:self 
                                                             source:mySourcePath
                                                        destination:myDestinationPath] autorelease];

    [audioConverter start];


Alternatively, if you wish to encode live audio, or provide another source of audio data, you can implement the `TPAACAudioConverterDataSource` protocol, which defines `AACAudioConverter:nextBytes:length:`, which provides a buffer to copy at most "length" bytes of audio into, and then expects you to update "length" to the amount of bytes provided.  For that you'll need to use the second initialiser, `initWithDelegate:dataSource:audioFormat:destination:`.



License
-------

This code is licensed under the terms of the MIT license.

Michael Tyson  
A Tasty Pixel