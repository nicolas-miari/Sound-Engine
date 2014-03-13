//
//  TTSoundEngine.m
//  ToutoulinaEngine2
//
//  Created by nicolasmiari on 9/17/10.
//  Copyright 2010 __MyCompanyName__. All rights reserved.
//

#import "TTSoundEngine.h"


// .............................................................................

#define BGM_SLOT_NUMBER		0u

#define BGM_BUS_NUMBER		0u


// Effect slots start after BGM-reserved slot:
#define SFX_FIRST_SLOT_NUMBER	(BGM_SLOT_NUMBER + 1u)

// Effect buses start after BGM-reserved bus:
#define SFX_FIRST_BUS_NUMBER	(BGM_BUS_NUMBER  + 1u)

#define MAX_FILES_IN_MEMORY         10u
#define MAX_CONCURRENT_SOUNDS        8u //16u

// Individual Volume When unspecified in play: Method
#define DEFAULT_SFX_VOLUME           0.25f

// Master Volume (Applies to ALL Effects)
#define DEFAULT_SFX_MASTER_VOLUME	1.0f

// BGM
#define DEFAULT_BGM_VOLUME	1.0f
#define DEFAULT_BGM_MASTER_VOLUME	0.25f


// .............................................................................
// Private Globals 

static TTSoundEngine*           sharedInstance = nil;

static AUGraph                  processingGraph;			// Graph Instance 
static AUNode                   mixerNode;                  // Mixer Instance

static SoundData*               loadedSoundPtrArray[MAX_FILES_IN_MEMORY];

static SoundInstance*           playingSoundPtrArray[MAX_CONCURRENT_SOUNDS];

static AURenderCallbackStruct   inputCallbackStructArray[MAX_CONCURRENT_SOUNDS];

static AudioStreamBasicDescription     stereoStreamFormat;
static AudioStreamBasicDescription     monoStreamFormat;

// .............................................................................
// C Function Forward Decls

void audioRouteChangeListenerCallback (void*                  inUserData,
									   AudioSessionPropertyID inPropertyID,
									   UInt32                 inPropertyValueSize,
									   const void*            inPropertyValue);


// .............................................................................

#pragma mark - C Audio Callbacks


#pragma mark Render Callback 

static OSStatus auRenderCallback (void*                         inRefCon,
								  AudioUnitRenderActionFlags*   ioActionFlags,
								  const AudioTimeStamp*         inTimeStamp,
								  UInt32						inBusNumber,
								  UInt32						inNumberFrames,
								  AudioBufferList*				ioData )
{
	// Called on every mixer bus every time the system needs more audio data
    //  to play (buffers).
	
	SoundInstance* soundInstance = playingSoundPtrArray[inBusNumber];
	
	if (!soundInstance) {
		return noErr;
	}
	
	SoundData* data = soundInstance->data;
	
	if (!data) {
		return noErr;
	}
	
    
	UInt32 frameTotalForSound = data->frameCount;
	BOOL   isStereo			  = data->isStereo;
	
	AudioUnitSampleType*	dataInLeft;
	AudioUnitSampleType*	dataInRight;
	
	dataInLeft                = data->audioDataLeft;
	if (isStereo) dataInRight = data->audioDataRight;
	
	AudioUnitSampleType*	outSamplesChannelLeft;
	AudioUnitSampleType*	outSamplesChannelRight;
	
	outSamplesChannelLeft  = (AudioUnitSampleType*) ioData->mBuffers[0].mData;
	outSamplesChannelRight = (AudioUnitSampleType*) ioData->mBuffers[1].mData;
	
	if (dataInLeft == NULL || soundInstance->playing == NO) {
        // Sound is not allocated yet.

		return noErr;
	}
	
	
    // Get the Sample Number, as an index into the sound stored in memory,
    //  to start reading data from.
    
	UInt32 sampleNumber = soundInstance->sample;
	
	BOOL isLoop = soundInstance->loop;
	
	
    
    // Fill the buffer(s) pointed at by ioData with the requested number of
    //  samples of audio from the sound stored in memory.
    
	if (isStereo) {
        // ( A ) STEREO
        
		for(UInt32 frameNumber = 0; frameNumber < inNumberFrames; ++frameNumber){
			outSamplesChannelLeft [frameNumber] = dataInLeft [sampleNumber];
			outSamplesChannelRight[frameNumber] = dataInRight[sampleNumber];
			
			sampleNumber++;
			
			/*
			  	After reaching the end of the sound in stored memory (i.e., 
			  	after frameTotalForSound/inNumberFrames invocations of this
			  	callback) loop back to the start of the sound so playback
			  	resumes from there (IF looping)
			 */
			if (sampleNumber >= frameTotalForSound) {
				// Reached End...
				
				if (isLoop) {
					// Start Over
					sampleNumber = 0;
				}
				else {
					// Stop
					soundInstance->playing = NO;
					[sharedInstance disableMixerBusNo:inBusNumber];
					break;
				}
			}
		}		
	}
	else {
        // (B) MONO - (Comments Omitted)
        
		for(UInt32 frameNumber = 0; frameNumber < inNumberFrames; ++frameNumber){
			
			outSamplesChannelLeft [frameNumber] = dataInLeft [sampleNumber];
			outSamplesChannelRight[frameNumber] = dataInLeft [sampleNumber];
			
			sampleNumber++;
			
			if (sampleNumber >= frameTotalForSound) {
				if (isLoop) {
					sampleNumber = 0;
				}
				else {
					soundInstance->playing = NO;
					[sharedInstance disableMixerBusNo:inBusNumber];
					break;
				}
			}
		}				
	}
	
	/*
	 	Update the stored sample number so the next time this callback is
    	invoked, playback resumes at the correct spot (Unless Deleted due
    	to Completion)
	 */
	
	if (soundInstance->playing) {
		// Bus is still alive; Update:
        
		soundInstance->sample = sampleNumber;
	}
	else{
        // NOT Playing; Disconnect.
        
		soundInstance->sample = 0;
		
		AUGraphDisconnectNodeInput(processingGraph, 
								   mixerNode, 
								   inBusNumber);
		
		if (data->usageCount > 0) {
			data->usageCount -= 1;
		}
	}
	
	return noErr;
}

// .............................................................................

#pragma mark Audio route change listener callback


/* 
  	Audio session callback function for responding to audio route changes. 
  	If playing back audio and the user unplugs a headset or headphones, or 
  	removes the device from a dock connector for hardware that supports audio 
  	playback, this callback detects that and stops playback. 
  	Refer to AudioSessionPropertyListener in Audio Session Services Reference.
 */

void audioRouteChangeListenerCallback (void*                  inUserData,
									   AudioSessionPropertyID inPropertyID,
									   UInt32                 inPropertyValueSize,
									   const void*            inPropertyValue) 
{
    
    // Ensure that this callback was invoked because of an audio route change
    if (inPropertyID != kAudioSessionProperty_AudioRouteChange) return;
	
    /* 
	  	This callback, being outside the implementation block, needs a reference 
	  	to the TTSoundEngine object, which it receives in the inUserData parameter. 
	  	You provide this reference when registering this callback (see the call 
	  	to AudioSessionAddPropertyListener).
	 */
    TTSoundEngine *audioObject = (__bridge TTSoundEngine*) inUserData;
    
    // if application sound is not playing, there's nothing to do, so return.
    if ([audioObject isPlaying] == NO) {
		
        NSLog (@"Audio route change while application audio is stopped.");
        return;
    }
    else{
		
        // Determine the specific type of audio route change that occurred.
        
        CFDictionaryRef routeChangeDictionary = inPropertyValue;
        
        CFNumberRef routeChangeReasonRef = CFDictionaryGetValue(routeChangeDictionary,
                                                                CFSTR(kAudioSession_AudioRouteChangeKey_Reason));
		
        SInt32 routeChangeReason;
        
        CFNumberGetValue(routeChangeReasonRef,
						 kCFNumberSInt32Type,
						 &routeChangeReason);
        
        /* 
		 	"Old device unavailable" indicates that a headset or headphones were
		 	unplugged, or that the device was removed from a dock connector that
		 	supports audio output. In such a case, pause or stop audio (as advised
		 	by the iOS Human Interface Guidelines).
		 */
        
        if (routeChangeReason == kAudioSessionRouteChangeReason_OldDeviceUnavailable) {
			
            NSLog (@"Audio output device was removed; stopping audio playback.");
            NSString *MixerHostAudioObjectPlaybackStateDidChangeNotification = @"MixerHostAudioObjectPlaybackStateDidChangeNotification";
            [[NSNotificationCenter defaultCenter] postNotificationName: MixerHostAudioObjectPlaybackStateDidChangeNotification object: audioObject]; 
			
        } else {
            NSLog (@"A route change occurred that does not require stopping application audio.");
        }
    }
}

// .............................................................................

#pragma mark - SOUND ENGINE - Private Interface


@interface TTSoundEngine ()

- (void) initializeEngine;

- (void) registerNotifcations;

- (void) printErrorMessage:(NSString*) errorString withStatus:(OSStatus) result;

- (void) setMixerInput:(UInt32)inputBus gain:(AudioUnitParameterValue)newGain;

- (void) cleanUpBusNo:(uint) busNumber;

@end


// .............................................................................

#pragma mark - SOUND ENGINE - Implementation 


@implementation TTSoundEngine
{
	BOOL			_initialized;
    
	AudioUnit		_mixerUnit;
	
	// These could be static globals...
	//AudioStreamBasicDescription     stereoStreamFormat;
	//AudioStreamBasicDescription     monoStreamFormat;
	// (...now, theyt are!)
    
	BOOL			_playing;
	BOOL			_playingBGM;
	
	BOOL			_interruptedDuringPlayback;
	double			_graphSampleRate;
	NSTimeInterval	_ioBufferDuration;
	
	
	/*!
     
     Database of sounds loaded in memory.
     Each entry is accessed by a key (string) equal to the corresponding
     file name (without path or extension).
     
     Each entry in turn is an NSMutableDictionary with the following keys:
	 
     Key:kMemorySlotNumberKey
     Object:NSNumber object representing NSUInteger Value (Index in Array)
	 
     Key:kNumberOfActiveInstancesKey
     Object:NSNumber object representing NSUInteger Value (# of Instances Playing or Paused)
	 */
	NSMutableDictionary*	_dataBase;
	

    // Array containing the SAME objects as dataBase, in an MRU order.
    // Everytime a sound is played, it is moved to the top of the array.
	NSMutableArray* _ranking;
	
	
    // Overall sound effect volume. Each effect bus' individual volume is
    // modulated (multiplied) by this value.
	CGFloat _sfxVolume;
	
	
    // Volume of the BGM bus.
	CGFloat _bgmVolume;
	
	
	NSMutableArray* _busesToResume;
	
	BOOL			_fadingOutBGM;
	CGFloat			_bgmFadeOutDuration;
	CGFloat			_bgmFadeOutCount;
	
}


@synthesize interruptedDuringPlayback = _interruptedDuringPlayback;
// Boolean flag to indicate whether audio was
//  playing when an interruption arrived

@synthesize playing = _playing;


// .............................................................................
// DESIGNATED INITIALIZER

- (id) init
{
	if((self = [super init])){
	
        // 1. Initialize instance variables
        
		_dataBase = [[NSMutableDictionary alloc] init];

		_ranking  = [[NSMutableArray alloc] init];
		
        
		_sfxVolume = DEFAULT_SFX_MASTER_VOLUME;
		
        _bgmVolume = DEFAULT_BGM_MASTER_VOLUME;
		
        
		
        // 2. Initialize Data Arrays
        
		for (NSUInteger i=0; i < MAX_FILES_IN_MEMORY; i++) {
			
			loadedSoundPtrArray[i] = (SoundData*) calloc(1, sizeof(SoundData));
		}
        
		
		for (NSUInteger i=0; i < MAX_CONCURRENT_SOUNDS; i++) {
			
			playingSoundPtrArray[i] = (SoundInstance*) calloc(1, sizeof(SoundInstance));
		}
		
        
		_busesToResume = [[NSMutableArray alloc] init];
		
		
        // 3. Initialize Audio Units, Graph, etc.
        
        [self initializeEngine];
        
        
        
        // 4. Register for relevant notifications
        
        [self registerNotifcations];
	}
	
	return self;
}

// .............................................................................

- (void) registerNotifcations
{
    NSNotificationCenter* notificationCenter = [NSNotificationCenter defaultCenter];
    
    
    [notificationCenter addObserver:self
                           selector:@selector(applicationWillResignActive:)
                               name:UIApplicationWillResignActiveNotification
                             object:nil];
    
    [notificationCenter addObserver:self
                           selector:@selector(applicationDidBecomeActive:)
                               name:UIApplicationDidBecomeActiveNotification
                             object:nil];
}

// .............................................................................

- (void) initializeEngine
{
    // Must Call Once BEFORE Playing any Sound
	
	if (_initialized == NO) {
		
		// .....................................................................
		// [ 1 ] Configure Audio Session
		
		NSError* audioSessionError = nil;
		
		AVAudioSession * session = [AVAudioSession sharedInstance];
		[session setDelegate:self];
		
		_graphSampleRate = 44100.0; // [Hertz]
		[session setPreferredHardwareSampleRate:_graphSampleRate error:&audioSessionError];
		if (audioSessionError) { NSLog(@"Error Setting Audio Session Preferred Hardware Smple Rate"); return;}

		//[session setCategory:AVAudioSessionCategoryPlayback error:&audioSessionError];
		[session setCategory:AVAudioSessionCategoryAmbient error:&audioSessionError];
		
        if (audioSessionError) { NSLog(@"Error Setting Audio Session Category"); return;}
		
		[session setActive:YES error:&audioSessionError];
		if (audioSessionError) { NSLog(@"Error Setting Audio Session Active"); return;}
		
		_graphSampleRate = [session currentHardwareSampleRate];
		
		_ioBufferDuration = 0.005;	// [seconds] Default:23ms (=1024 Samples @ 44.1 kHz)
		[session setPreferredIOBufferDuration:_ioBufferDuration error:&audioSessionError];
        
        
        OSStatus propertySetError = 0;
        Float32 preferredBufferDuration = _ioBufferDuration;
        propertySetError = AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(preferredBufferDuration), &preferredBufferDuration);

        
		if (audioSessionError && propertySetError) { NSLog(@"Error Setting Audio Session Preferred IO Buffer Duration"); return;}

		AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange,
                                        audioRouteChangeListenerCallback,
                                        (__bridge void *)(self));
		
		
		// .....................................................................
		// [ 2 ] Setup MONO and STEREO Stream Formats
		
		/* 
		 	The AudioUnitSampleType data type is the recommended type for sample
		 	data in audio units. This obtains the byte size of the type for use
		 	in filling in the ASBD.
		 */
		size_t bytesPerSample = sizeof (AudioUnitSampleType);
		
        
		/* 
		 	Fill the application audio format struct's fields to define a linear
		 	PCM, stereo, noninterleaved stream at the hardware sample rate.
		 */
		stereoStreamFormat.mFormatID          = kAudioFormatLinearPCM;
		stereoStreamFormat.mFormatFlags       = kAudioFormatFlagsAudioUnitCanonical;
		stereoStreamFormat.mBytesPerPacket    = bytesPerSample;
		stereoStreamFormat.mFramesPerPacket   = 1;
		stereoStreamFormat.mBytesPerFrame     = bytesPerSample;
		stereoStreamFormat.mChannelsPerFrame  = 2;                    // 2 indicates stereo
		stereoStreamFormat.mBitsPerChannel    = 8 * bytesPerSample;
		stereoStreamFormat.mSampleRate        = _graphSampleRate;
		
		monoStreamFormat.mFormatID            = kAudioFormatLinearPCM;
		monoStreamFormat.mFormatFlags         = kAudioFormatFlagsAudioUnitCanonical;
		monoStreamFormat.mBytesPerPacket      = bytesPerSample;
		monoStreamFormat.mFramesPerPacket     = 1;
		monoStreamFormat.mBytesPerFrame       = bytesPerSample;
		monoStreamFormat.mChannelsPerFrame    = 1;					  // 1 indicates mono
		monoStreamFormat.mBitsPerChannel      = 8 * bytesPerSample;
		monoStreamFormat.mSampleRate          = _graphSampleRate;
		
		
		// .....................................................................
		// [ 3 ] Configure Audio Processing Graph
		
		OSStatus result = noErr;
		
		
        // Create Graph
        
		result = NewAUGraph(&processingGraph);
		
		if (result != noErr) {[self printErrorMessage: @"NewAUGraph" withStatus: result]; return;}
		
		
		/*
		 	Specify the audio unit component descriptions for the audio units to 
		 	be added to the graph.
		 */
		
		// Remote I/O Unit
		AudioComponentDescription ioUnitDescription;
		ioUnitDescription.componentType         = kAudioUnitType_Output;
		ioUnitDescription.componentSubType      = kAudioUnitSubType_RemoteIO;
		ioUnitDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
		ioUnitDescription.componentFlags	    = 0;
		ioUnitDescription.componentFlagsMask    = 0;
		
		// Multichannel Mixer Unit		
		AudioComponentDescription mixerUnitDescription;
		mixerUnitDescription.componentType         = kAudioUnitType_Mixer;
		mixerUnitDescription.componentSubType      = kAudioUnitSubType_MultiChannelMixer;
		mixerUnitDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
		mixerUnitDescription.componentFlags		   = 0;
		mixerUnitDescription.componentFlagsMask    = 0;
		
		
        // Add Nodes to the Processing Graph

		AUNode ioNode;
		
		result = AUGraphAddNode(
						processingGraph, 
						&ioUnitDescription, 
						&ioNode);
		
		if (result != noErr) {[self printErrorMessage: @"AUGraphNewNode failed for I/O unit" withStatus: result]; return;}
		
		
		result = AUGraphAddNode(
						processingGraph, 
						&mixerUnitDescription, 
						&mixerNode);
		
		if (result != noErr) {[self printErrorMessage: @"AUGraphNewNode failed for Mixer unit" withStatus: result]; return;}
		
		/*
		 	Open the Audio Processing Graph.
		 	Following this call, the audio units are instantiated but not
		 	initialized (no resource allocation occurs and the audio units are
		 	not in a state to process audio).
		 */
		result = AUGraphOpen(processingGraph);
		
		if (result != noErr) {[self printErrorMessage: @"AUGraphOpen" withStatus: result]; return;}
		
		
        // Obtain mixer unit instance from its corresponding node.
        
		result = AUGraphNodeInfo(processingGraph,
                                 mixerNode,
                                 NULL,
                                 &_mixerUnit);
		
		if ( result != noErr ){
            [self printErrorMessage: @"AUGraphNodeInfo" withStatus: result];
            return;
        }
		
		// .....................................................................
		// Multichannel Mixer unit Setup
		
		UInt32	busCount  = MAX_CONCURRENT_SOUNDS;
		
		// Number of Buses (Stereo Channels in the Mixer)
		
		result = AudioUnitSetProperty(_mixerUnit, 
									  kAudioUnitProperty_ElementCount, 
									  kAudioUnitScope_Input, 
									  0, 
									  &busCount, 
									  sizeof(busCount)
									  );
		
		if (result != noErr){
            [self printErrorMessage: @"AudioUnitSetProperty (set mixer unit bus count)" withStatus: result];
            return;
        }

        
		/*
		 	Increase the maximum frames per slice allows the mixer unit to 
		 	accommodate the larger slice size used when the screen is locked.
		 */
		
		UInt32 maximumFramesPerSlice = 4096;
		
		result = AudioUnitSetProperty(_mixerUnit, 
									  kAudioUnitProperty_MaximumFramesPerSlice, 
									  kAudioUnitScope_Global, 
									  0, 
									  &maximumFramesPerSlice, 
									  sizeof(maximumFramesPerSlice));
		
		if (result != noErr) {[self printErrorMessage: @"AudioUnitSetProperty (set mixer unit input stream format)" withStatus: result]; return;}

		
        // Disable and Mute All Buses:
        
		for (UInt32 busNumber = 0; busNumber < busCount; busNumber++) {
			
			// Start Disabled (No Data)
			
			[self setMixerInput:busNumber gain:0];
			[self disableMixerBusNo:busNumber];
			
		}
		
    
        // Attach the input render callback and context to each input bus.
				 
		for (UInt32 busNumber = 0; busNumber < busCount; ++busNumber) {
		
			inputCallbackStructArray[busNumber].inputProc       = &auRenderCallback;
			inputCallbackStructArray[busNumber].inputProcRefCon = playingSoundPtrArray;
			
			result = AUGraphSetNodeInputCallback(processingGraph,
                                                 mixerNode,
                                                 busNumber,
                                                 &inputCallbackStructArray[busNumber]);
			
			if (result != noErr) {[self printErrorMessage: @"AUGraphSetNodeInputCallback" withStatus: result]; return;}
		}
		 
        //	Set All Buses to Stereo. For Mono Files, Replicate the only channel
        //	into L and R
        
		for (UInt32 busNumber = 0; busNumber < busCount; ++busNumber) {
			
			result = AudioUnitSetProperty (_mixerUnit,
										   kAudioUnitProperty_StreamFormat,
										   kAudioUnitScope_Input,
										   busNumber,
										   &stereoStreamFormat,
										   sizeof (stereoStreamFormat));
			
			if ( result != noErr ){
                [self printErrorMessage: @"AudioUnitSetProperty (set mixer unit input bus stream format)" withStatus: result];
                return;
            }
		}
		
		/*
		 	Set the mixer unit's output sample rate format. This is the only 
		 	aspect of the output stream format that must be explicitly set.
		 */
		result = AudioUnitSetProperty (_mixerUnit,
									   kAudioUnitProperty_SampleRate,
									   kAudioUnitScope_Output,
									   0,
									   &_graphSampleRate,
									   sizeof (_graphSampleRate));
		
		if ( result != noErr ){
            [self printErrorMessage: @"AudioUnitSetProperty (set mixer unit output stream format)" withStatus: result];
            return;
        }
		
		
		// .....................................................................
		// [ 6 ] Connect the Audio Unit Nodes

		AudioUnitElement mixerUnitOutputBus  = 0;
		AudioUnitElement ioUnitOutputElement = 0;
		
		result = AUGraphConnectNodeInput (processingGraph, 
                                          mixerNode,			// source node 
                                          mixerUnitOutputBus,	// source node bus
                                          ioNode,				// destination node
                                          ioUnitOutputElement	// destination node element
                                          );
		
		if ( result != noErr ){
			[self printErrorMessage: @"AUGraphConnectNodeInput" withStatus: result];
            return;
		}

		// .....................................................................
		// [ 7 ] Provide a User Interface

		// (skip)
		
		// .....................................................................
		// [ 8 ] Initialize and Start the Audio Processing Graph

		// Diagnostic code
		// Call CAShow if you want to look at the state of the audio processing 
		//    graph.
		
		result = AUGraphInitialize(processingGraph);
		
		/*
		 	The graph is started from applicationDidBecomeActive.
		 	If we also activate it here, it wont stop when locking the phone.
		 */
		
		if (result == noErr) {
			_initialized = YES;
		}
		else {
			_initialized = NO;
		}
	}
}

// .............................................................................

- (void) cleanUpBusNo:(uint) busNumber
{
	/*
	 *	Free Memory Associated with the Sound in Bus no. 'busNumber'.
	 *  Called when a non-looping sound reaches EOF.
	 */
	
	/*
	if (busNumber >= MAX_CONCURRENT_SOUNDS) {
		// Out of Array Bounds
		return;
	}
	
	SoundInstance* pSoundInstance = playingSoundPtrArray[busNumber];
	
	//	Delete Audio Data
	
	
	if (pSoundStruct->audioDataLeft)  {
		free(pSoundStruct->audioDataLeft);
		pSoundStruct->audioDataLeft = NULL;
	}
	if (pSoundStruct->audioDataRight) {
		free(pSoundStruct->audioDataRight);
		pSoundStruct->audioDataRight = NULL;
	}
	
	
	//	Flag Slot as unused
	 
	pSoundStruct->isPlaying = NO;	
	pSoundStruct->didLoad   = NO;
	*/
}

// .............................................................................

- (void) purgeUnusedSounds
{
	/*
	 	Called by Scene Director (=Main View Controller)
	   or App Delegate (TODO: DECIDE) when receiving a Memory Warning.
	 	Release all Audio Data that is not being played.
	 */
	
	
    
    // Remove least recently used half of sounds
    
	NSUInteger count = [_ranking count];
	
	NSUInteger halfCount = count;// / 2;
	
	NSMutableArray* soundsToRemove = [[NSMutableArray alloc] init];
	
	for (NSUInteger i=0; i < halfCount; i++) {
		
		NSMutableDictionary* dictionary = (NSMutableDictionary*)[_ranking objectAtIndex:i];

		[soundsToRemove addObject:dictionary];
		
		NSUInteger slotNumber = [[dictionary objectForKey:kMemorySlotNumberKey] unsignedIntValue];
		
		SoundData* data = loadedSoundPtrArray[slotNumber];
		
		if (data ) {
			if (data->usageCount == 0) {
				if (data->audioDataLeft) {
					free(data->audioDataLeft);
					data->audioDataLeft = NULL;
				}
				if (data->audioDataRight) {
					free(data->audioDataRight);
					data->audioDataRight = NULL;
				}
                
                //NSLog(@"Purge Sound in Slot no. [%2d] - SUCCEEDED.\n", slotNumber);
			}
			else {
				//NSLog(@"Purge Sound in Slot no. [%2d] - FAILED (use count: %lu).\n", slotNumber, data->usageCount);
			}
		}
		
		[_dataBase removeObjectForKey:[dictionary objectForKey:kSoundFileNameKey]];
	}
	
	[_ranking removeObjectsInArray:soundsToRemove];

}

// .............................................................................

- (void) printErrorMessage: (NSString *) errorString withStatus: (OSStatus) result 
{
	
    char resultString[5];
    UInt32 swappedResult = CFSwapInt32HostToBig (result);
    bcopy (&swappedResult, resultString, 4);
    resultString[4] = '\0';
	
    NSLog ( @"*** %@ error: %s\n", errorString, (char*) &resultString);
}

// .............................................................................

- (void)startAUGraph
{
    // Starts Render.
    
	OSStatus result = AUGraphStart(processingGraph);
    
	if (result != noErr) {
		[self printErrorMessage: @"AUGraphStart" withStatus: result];
		return; 
	}
	
	_playing = YES;
}

// .............................................................................

- (void)stopAUGraph
{
	// Stops Render.
    
    Boolean isRunning = NO;
    
    OSStatus result = AUGraphIsRunning(processingGraph, &isRunning);
    
	if (result != noErr) { 
		[self printErrorMessage: @"AUGraphIsRunning" withStatus: result];
		return; 
	}
    
    if (isRunning) {
        
		result = AUGraphStop(processingGraph);
        
		if (result != noErr) { 
			[self printErrorMessage: @"AUGraphStop" withStatus: result];
			return; 
		}
        
        _playing = NO;
    }
}


// .............................................................................

- (void) enableMixerBusNo:(UInt32) busNumber
{
	OSStatus result;
	
	result = AudioUnitSetParameter(_mixerUnit, 
								   kMultiChannelMixerParam_Enable, 
								   kAudioUnitScope_Input, 
								   busNumber, 
								   1, 
								   0);
	
	if (result != noErr) {
		[self printErrorMessage: @"EnableMixerBusNo" withStatus: result]; 
		return;
	}
	
	playingSoundPtrArray[busNumber]->playing = YES;
}

// .............................................................................

- (void) disableMixerBusNo:(UInt32) busNumber
{
	OSStatus result;
	
	result = AudioUnitSetParameter(_mixerUnit, 
								   kMultiChannelMixerParam_Enable, 
								   kAudioUnitScope_Input, 
								   busNumber, 
								   0, 
								   0);
	
	if (result != noErr) {
		{[self printErrorMessage: @"DisableMixerBusNo" withStatus: result]; return;}
	}
	
	playingSoundPtrArray[busNumber]->playing = NO;
}

// .............................................................................

- (void) setMixerInput:(UInt32) inputBus gain:(AudioUnitParameterValue) newGain
{
	
	OSStatus result = AudioUnitSetParameter (
											 _mixerUnit,
											 kMultiChannelMixerParam_Volume,
											 kAudioUnitScope_Input,
											 inputBus,
											 newGain,
											 0
											 );
	
    if (result != noErr) {
        [self printErrorMessage: @"AudioUnitSetParameter (set mixer unit input volume)" withStatus: result];
        return;
    }
}

// .............................................................................

- (void) setMixerOutputGain: (AudioUnitParameterValue) newGain {
	
    OSStatus result = AudioUnitSetParameter (
											 _mixerUnit,
											 kMultiChannelMixerParam_Volume,
											 kAudioUnitScope_Output,
											 0,
											 newGain,
											 0
											 );
	
    if (result != noErr) {
        [self printErrorMessage: @"AudioUnitSetParameter (set mixer unit output volume)" withStatus: result];
        return;
    }
}

// .............................................................................

- (NSUInteger) firstFreeMemorySlot
{
    // Return the first available slot (index) in the loaded sounds array, using
    // the following criterion:

	
	// First, Search for Empty Slot
	for (NSUInteger i = SFX_FIRST_SLOT_NUMBER; i < MAX_FILES_IN_MEMORY; i++) {
        
		if (loadedSoundPtrArray[i]->audioDataLeft == NULL) {
			// No Sound Loaded on Slot; FOUND
			return i;
		}
	}
	
	// ...All Slots are Loaded. Check Usage Counts
    
    // Start with the maximum possible value (all buses playing the same sound),
    //  and work down from there:
	NSUInteger smallestUsageCount = MAX_CONCURRENT_SOUNDS;
	
    // Start with the maximum possible value (last slot),
    //  and work down from there:
	NSUInteger leastUsedIndex = MAX_FILES_IN_MEMORY;
	
	
    for (NSUInteger i = SFX_FIRST_SLOT_NUMBER; i < MAX_FILES_IN_MEMORY; i++) {
	
        SoundData* soundData = loadedSoundPtrArray[ i ];
		
		if (soundData->usageCount < smallestUsageCount ) {
			// Found lower value; Update minimum:
			
            smallestUsageCount = soundData->usageCount;

			leastUsedIndex = i;
		}
	}
	
	if (smallestUsageCount == 0) {
        
        // Purge existing sound
        [self unloadSoundEffectOnSlotNumber:leastUsedIndex];
        
        // Return slot number
		return leastUsedIndex;
	}
	
	// Flags Failure: (All Slots are Loaded AND Playing)
	return MAX_FILES_IN_MEMORY;
}

// .............................................................................

- (NSUInteger) firstFreeMixerBus
{
    // Return the first available Mixer Bus
	
	for (NSUInteger i = SFX_FIRST_BUS_NUMBER; i< MAX_CONCURRENT_SOUNDS; i++) {
		SoundInstance* pInstance = playingSoundPtrArray[i];
		
		if (pInstance == NULL || pInstance->playing == FALSE) {
			return i;
		}
	}
	
	// Flags Failure: (All Buses Occupied AND Playing)
	return MAX_CONCURRENT_SOUNDS;
	
	// Optionally, Override the bus which has been playing the longest
	// Or has the highest ratio of played duration/total duration.
}

// .............................................................................

#pragma mark - Notification Handlers


- (void) applicationWillResignActive:(NSNotification*) notification
{
    [self pauseEngine];
}

// .............................................................................

- (void) applicationDidBecomeActive:(NSNotification*) notification
{
    [self resumeEngine];
}

// .............................................................................

#pragma mark - ENGINE INTERFACE METHODS (public)

#pragma mark Loading of Sounds 

- (void) unloadSoundEffectOnSlotNumber:(NSUInteger) slotNumber
{
    // Remove all entries that point to this slot number
    
    
    NSArray* keys = [[_dataBase allKeys] copy];
    NSDictionary* dbCopy = [_dataBase copy];
    
    for ( NSString* key in keys ) {
        
        NSDictionary* entry = [dbCopy objectForKey:key];
        
        NSUInteger slot = [[entry objectForKey:kMemorySlotNumberKey] unsignedIntegerValue];
        
        if (slot == slotNumber) {
            [_dataBase removeObjectForKey:key];
        }
    }
}

// .............................................................................

- (void) preloadEffect:(NSString*) audioFileName
{
    /*
        Loads the specified audio file in the first available memory slot.
        If no slot is available, log a warning and ignore.
     */
    
    
    
    // 0. Validate input file/file name
    
    if (!audioFileName) {
        NSLog(@"-[TTSoundEngine preloadEffect:] Called with nil string!");
        return;
    }
    
    if ([audioFileName length] == 0) {
        NSLog(@"-[TTSoundEngine preloadEffect:] Called with empty string!");
        return;
    }
    
    NSString* path;
    
    if ((path = [[NSBundle mainBundle] pathForResource:audioFileName ofType:@"caf"]) == nil) {
        NSLog(@"-[TTSoundEngine preloadEffect:] Called with non-existing file!");
        return;
    }
    
    
    
    // 1. Check if sound is already loaded
    
    NSMutableDictionary* existingEntry = [_dataBase objectForKey:audioFileName];
	
    if (existingEntry) {
        
        NSUInteger slotNumber = [[existingEntry objectForKey:kMemorySlotNumberKey] unsignedIntegerValue];
        
		NSLog(@"-[TTSoundEngine preloadEffect:] File '%@' already loaded (slot no. %u); Ignoring.", audioFileName, slotNumber);
        
        return;
	}
    
    
    // 2. Pick first available slot
    
	NSUInteger freeSlot = [self firstFreeMemorySlot];
	
	if (freeSlot >= MAX_FILES_IN_MEMORY) {
		// No slot available
		NSLog(@"-[TTSoundEngine preloadEffect:] Failed to preload sound %@ (All slots occupied and used)", audioFileName);
		return;
	}
	
    
    // ...aaaand, 3. Load file:
    
    NSURL* url = [NSURL fileURLWithPath:path];	// iOS 3.1.3
    
    CFURLRef urlRef = (__bridge CFURLRef)url; // __bridge_retained?
	
	ExtAudioFileRef audioFileObject = 0;
	
	// Open an audio file and associate it with the extended audio file object.
	OSStatus result = ExtAudioFileOpenURL(urlRef, &audioFileObject);
	
	if (result != noErr || audioFileObject == NULL) {
		[self printErrorMessage: @"ExtAudioFileOpenURL" withStatus: result]; 
		return;
	}
	
	// Get the audio file's length in frames.
	UInt64 totalFramesInFile = 0;
	UInt32 frameLengthPropertySize = sizeof (totalFramesInFile);
	
	result =    ExtAudioFileGetProperty (audioFileObject,
										 kExtAudioFileProperty_FileLengthFrames,
										 &frameLengthPropertySize,
										 &totalFramesInFile);
	
	if (noErr != result) {
		[self printErrorMessage: @"ExtAudioFileGetProperty (audio file length in frames)" withStatus: result]; 
		ExtAudioFileDispose (audioFileObject); 
		return;
	}
	
	SoundData* data = loadedSoundPtrArray[freeSlot];
	
	if (data) {
		
        // Recycle SoundData object, but empty audio data
        
		if (data->audioDataLeft){
            free(data->audioDataLeft);
        }
		if (data->audioDataRight){
            free(data->audioDataRight);
        }
	}
	else {
		// Create new SoundData and insert into array:
		
        data = (SoundData*) malloc(sizeof(SoundData));
		loadedSoundPtrArray[freeSlot] = data;
	}

	// Set number of frames:
	data->frameCount = totalFramesInFile;
	
	// Get the Audio File's number of channels:	
	AudioStreamBasicDescription fileAudioFormat = { 0 };
	UInt32 formatPropertySize = sizeof(fileAudioFormat);
	
	result = ExtAudioFileGetProperty(audioFileObject, 
									 kExtAudioFileProperty_FileDataFormat, 
									 &formatPropertySize, 
									 &fileAudioFormat);
	
	if (result != noErr) {
		[self printErrorMessage: @"ExtAudioFileGetProperty (file audio format)" withStatus: result]; 
		ExtAudioFileDispose (audioFileObject); 
		return;
	}
	
	UInt32 channelCount = fileAudioFormat.mChannelsPerFrame;
	

    // Allocate memory in the sound structure to hold the left channel
	
	AudioStreamBasicDescription importFormat = { 0 };
	
	if (channelCount == 1) {
		// MONO
		
		data->isStereo = NO;
		importFormat = monoStreamFormat;
	}
	else if( channelCount == 2 ) {
		// STEREO - Allocate Right Channel as well
		
		data->isStereo = YES;
		
        importFormat = stereoStreamFormat;		
	}
	else {
		NSLog (@"*** WARNING: File format not supported - wrong number of channels");
		
		ExtAudioFileDispose (audioFileObject);
		return;
	}


	/*
	  	Assign the appropriate mixer input bus stream data format to the 
	  	extended audio file object. This is the format used for the audio data 
	    placed into the audio buffer in the SoundStruct data structure, which is
	  	in turn used in the render callback function.
	 */
    
	result = ExtAudioFileSetProperty(audioFileObject,
									 kExtAudioFileProperty_ClientDataFormat,
									 sizeof(importFormat),
									 &importFormat
									 );
	
	if (result != noErr) {
		[self printErrorMessage: @"ExtAudioFileSetProperty (client data format)" withStatus: result]; 
		
		ExtAudioFileDispose (audioFileObject); 
		return;
	}
	
    
	/*
	  	Setup an AudioBufferList struct, which has two roles:
	  
	  		1. It gives the ExtAudioFileRead function the configuration it needs
	  			to correctly provide the data to the buffer.
	  
	  		2. It points to the Sound Structure's audioDataLeft buffer, so that
	  			audio data obtained from disk using the ExtAudioFileRead
	  			function goes to that buffer.
	 */
    
	AudioBufferList*	bufferList;
	
	bufferList = (AudioBufferList*) malloc(sizeof(AudioBufferList) + sizeof(AudioBuffer)*(channelCount - 1));
	
	if (bufferList == NULL) {
		NSLog (@"*** malloc failure for allocating bufferList memory"); 

		ExtAudioFileDispose (audioFileObject); 
		return;
	}
	
	bufferList->mNumberBuffers = channelCount;
	
	AudioBuffer emptyBuffer = { 0 };
	size_t arrayIndex;
	for ( arrayIndex = 0; arrayIndex < channelCount; arrayIndex++ ) {
		bufferList->mBuffers[arrayIndex] = emptyBuffer;
	}
	
	
	
    // Allocate Data Buffers (Deferred until now to simplify abortion)
    
	data->audioDataLeft = (AudioUnitSampleType*) calloc(totalFramesInFile, sizeof(AudioUnitSampleType));
	
	if (channelCount == 2) {
		data->audioDataRight = (AudioUnitSampleType*) calloc(totalFramesInFile, sizeof(AudioUnitSampleType));
	}
	
	
    // Setup the AudioBuffer structs in the buffer list
    
	bufferList->mBuffers[0].mNumberChannels   = 1;
	bufferList->mBuffers[0].mDataByteSize     = totalFramesInFile * sizeof(AudioUnitSampleType);
	bufferList->mBuffers[0].mData             = data->audioDataLeft;
	
	if (channelCount == 2) {
		bufferList->mBuffers[1].mNumberChannels  = 1;
		bufferList->mBuffers[1].mDataByteSize    = totalFramesInFile * sizeof (AudioUnitSampleType);
		bufferList->mBuffers[1].mData            = data->audioDataRight;
	}
	
     
    // Perform a synchronous, sequential read of the audio data out of the file
    //  and into the Sound Struct's audioDataLeft (and Right if Stereo)
    
	UInt32 numberOfPacketsToRead = (UInt32) totalFramesInFile;
	
	result = ExtAudioFileRead(audioFileObject, 
							  &numberOfPacketsToRead, 
							  bufferList);
	free(bufferList);
	
	if (result != noErr) {
		
		[self printErrorMessage: @"ExtAudioFileRead failure - " withStatus: result];
		
        // If reading from the file failed, then free the memory for
        //  the sound buffer.
        
		free (data->audioDataLeft);
		data->audioDataLeft = NULL;
		
		if (channelCount == 2) { 
			free (data->audioDataRight); 
			data->audioDataRight = NULL;
		}
		ExtAudioFileDispose (audioFileObject);            
		return;
	}
	
	// Start at the beginning:
	data->usageCount = 0;
	
	ExtAudioFileDispose(audioFileObject);

	// File Read Succeeded...
	
	
	// ...Next, Cache in Data Base:
	NSNumber* slotNumber    = [NSNumber numberWithUnsignedInt:freeSlot];
	NSNumber* instanceCount = [NSNumber numberWithUnsignedInt:0];
	
	NSMutableDictionary* dbEntry = [[NSMutableDictionary alloc] initWithCapacity:2];
	[dbEntry setObject:slotNumber    forKey:kMemorySlotNumberKey];
	[dbEntry setObject:instanceCount forKey:kNumberOfActiveInstancesKey];
	[dbEntry setObject:audioFileName forKey:kSoundFileNameKey];
	
	[_dataBase setObject:dbEntry forKey:audioFileName];
	
	[_ranking addObject:dbEntry];
	
	NSLog(@"TTSoundEngine: Preloaded effect \"%@\" into slot no. [%u]",
          audioFileName,
          freeSlot);
    
	// DONE ***
}

// .............................................................................

- (void) preloadBGM:(NSString *)audioFileName
{
	/*
	 	Loads specified audio file for use as BGM. If an audio file is already
    	 loaded, the data is discarded. If the previously loaded BGM is 
         currently playing, it is stopped and playback resumes after the new 
         file is loaded.
	 */
	
	BOOL restore = NO;
	
	if ([self isPlayingBGM]) {
		[self pauseBGM];
		restore = YES;
	}
	
	
	NSURL* url = [[NSBundle mainBundle] URLForResource:audioFileName withExtension:@"caf"];               // iOS 4.x
	
    if (!url) {
		url = [[NSBundle mainBundle] URLForResource:audioFileName withExtension:@"mp3"];                  // iOS 4.x
	}
	
	CFURLRef urlRef = (__bridge CFURLRef)url;  // __bridge_retained?
	
	ExtAudioFileRef audioFileObject = 0;
	
	// Open an audio file and associate it with the extended audio file object.
	OSStatus result = ExtAudioFileOpenURL(urlRef, &audioFileObject);
	
	if (result != noErr || audioFileObject == NULL) {
		[self printErrorMessage: @"ExtAudioFileOpenURL" withStatus: result]; 
		return;
	}
	
	// Get the audio file's length in frames.
	UInt64 totalFramesInFile = 0;
	UInt32 frameLengthPropertySize = sizeof (totalFramesInFile);
	
	result = ExtAudioFileGetProperty(audioFileObject,
									 kExtAudioFileProperty_FileLengthFrames,
									 &frameLengthPropertySize,
									 &totalFramesInFile);
	
	if (result != noErr) {
		[self printErrorMessage: @"ExtAudioFileGetProperty (audio file length in frames)" withStatus: result]; 
		ExtAudioFileDispose (audioFileObject);
		return;
	}
	
	// Get the Available SoundStructure Object:
    
	SoundData* pSoundData = loadedSoundPtrArray[BGM_SLOT_NUMBER];
	

    // Assign the frame count to the soundStruct instance variable
    
	pSoundData->frameCount = totalFramesInFile;
	
	

    // Get the Audio File's number of channels
    
	AudioStreamBasicDescription fileAudioFormat = { 0 };
	UInt32 formatPropertySize = sizeof(fileAudioFormat);
	
	result = ExtAudioFileGetProperty(audioFileObject, 
									 kExtAudioFileProperty_FileDataFormat, 
									 &formatPropertySize, 
									 &fileAudioFormat);
	
	if (result != noErr) {
		[self printErrorMessage: @"ExtAudioFileGetProperty (file audio format)" withStatus: result]; 
		ExtAudioFileDispose (audioFileObject);
		return;
	}
	
	UInt32 channelCount = fileAudioFormat.mChannelsPerFrame;
	
	AudioStreamBasicDescription importFormat = { 0 };
	
	if (channelCount == 1) {
		// MONO
		pSoundData->isStereo = NO;
		importFormat = monoStreamFormat;
	}
	else if( channelCount == 2 ) {
		// STEREO; Allocate Right Channel as well
		pSoundData->isStereo = YES;
		
		importFormat = stereoStreamFormat;
	}
	else {
		NSLog (@"*** WARNING: File format not supported - wrong number of channels");
		ExtAudioFileDispose (audioFileObject);
		return;
	}
	
	
	/*
	  	Assign the appropriate mixer input bus stream data format to the 
	  	 extended audio file object. This is the format used for the audio data 
	     placed into the audio buffer in the SoundStruct data structure, which 
         is in turn used in the render callback function.
	 */
    
	result = ExtAudioFileSetProperty(audioFileObject,
									 kExtAudioFileProperty_ClientDataFormat,
									 sizeof(importFormat),
									 &importFormat
									 );
	
	if (result != noErr) {
		[self printErrorMessage: @"ExtAudioFileSetProperty (client data format)" withStatus: result]; 
		
		ExtAudioFileDispose (audioFileObject); 	
		return;
	}
	
	/*
	  	Setup an AudioBufferList struct, which has two roles:
	  
	  		1. It gives the ExtAudioFileRead function the configuration it needs
	  			to correctly provide the data to the buffer.
	  
	  		2. It points to the Sound Structure's audioDataLeft buffer, so that
	  			audio data obtained from disk using the ExtAudioFileRead
	  			function goes to that buffer.
	 */
    
	AudioBufferList*	bufferList;
	
	bufferList = (AudioBufferList*) malloc(sizeof(AudioBufferList) + sizeof(AudioBuffer)*(channelCount - 1));
	
	if (bufferList == NULL) {
		NSLog (@"*** malloc failure for allocating bufferList memory"); 
		
		ExtAudioFileDispose (audioFileObject); 		
		return;
	}
	
	bufferList->mNumberBuffers = channelCount;
	
	AudioBuffer emptyBuffer = { 0 };
	size_t arrayIndex;
	for ( arrayIndex = 0; arrayIndex < channelCount; arrayIndex++ ) {
		bufferList->mBuffers[arrayIndex] = emptyBuffer;
	}
	
	
    // Allocate Audio Data Buffers (Deferred to simplify abortion)
    
	pSoundData->audioDataLeft = (AudioUnitSampleType*) calloc(totalFramesInFile, sizeof(AudioUnitSampleType));
	
	if (channelCount == 2) {
		pSoundData->audioDataRight = (AudioUnitSampleType*) calloc(totalFramesInFile, sizeof(AudioUnitSampleType));
	}
	
	
    // Setup the AudioBuffer structs in the buffer list
    
	bufferList->mBuffers[0].mNumberChannels   = 1;
	bufferList->mBuffers[0].mDataByteSize     = totalFramesInFile * sizeof(AudioUnitSampleType);
	bufferList->mBuffers[0].mData             = pSoundData->audioDataLeft;
	
	if (channelCount == 2) {
		bufferList->mBuffers[1].mNumberChannels  = 1;
		bufferList->mBuffers[1].mDataByteSize    = totalFramesInFile * sizeof (AudioUnitSampleType);
		bufferList->mBuffers[1].mData            = pSoundData->audioDataRight;
	}
	
	
    // Perform a synchronous, sequential read of the audio data out of the file
    //  and into the Sound Struct's audioDataLeft (and Right if Stereo)
    
	UInt32 numberOfPacketsToRead = (UInt32) totalFramesInFile;
	
	result = ExtAudioFileRead(audioFileObject, 
							  &numberOfPacketsToRead, 
							  bufferList);
	free(bufferList);
	
	if (result != noErr) {
		
		[self printErrorMessage: @"ExtAudioFileRead failure - " withStatus: result];
		
		/*
		 *	If reading from the file failed, then free the memory for 
		 *	the sound buffer.
		 */
		free (pSoundData->audioDataLeft);
		pSoundData->audioDataLeft = NULL;
		
		if (channelCount == 2) { 
			free (pSoundData->audioDataRight); 
			pSoundData->audioDataRight = NULL;
		}
		
		ExtAudioFileDispose (audioFileObject);            
		
		return;
	}
	
	ExtAudioFileDispose(audioFileObject);
	
	
    // File Read Succeeded;
    
	
	// Initialize Sound Instance 
	
	SoundInstance* pSoundInstance = playingSoundPtrArray[BGM_BUS_NUMBER];
	
	if(!pSoundInstance){
		// Allocate (First Time)
		pSoundInstance = (SoundInstance*) malloc(sizeof(SoundInstance));
		
		pSoundInstance->isEffect = NO;
		pSoundInstance->playing  = NO;
		pSoundInstance->loop     = YES;
		pSoundInstance->volume   = 1.0f;
		
		playingSoundPtrArray[BGM_BUS_NUMBER] = pSoundInstance;
	}
	
	// Start at the beginning:
	pSoundInstance->sample = 0u;
	
	pSoundInstance->data = pSoundData;
	
	
	if (restore) {
		// Was playing; Restore:
		[self playBGM];
	}
}

// .............................................................................

#pragma mark Playback Configuration


- (void) setEffectVolume:(CGFloat) volume
{
    // Sets Master SFX Volume. Modulates each individual Effect's
    // Volume (Specified on play)
	
	_sfxVolume = volume;
}

// .............................................................................

- (void) setBGMVolume:(CGFloat) volume
{
	_bgmVolume = volume;
}

// .............................................................................

#pragma mark Playback of Sounds


- (void) playEffect:(NSString *)audioFileName withVolume:(CGFloat) volume
{
    // Play Effect. Preload if Necessary.
	
	if (!audioFileName) {
		return;
	}
	
	[self preloadEffect:audioFileName]; // Returns Immediately if Already Loaded
	
	NSMutableDictionary* effectDictionary = (NSMutableDictionary*)[_dataBase objectForKey:audioFileName];
	

    // Play (un-mute)    
	
	if (!effectDictionary) {
		NSLog(@"ERROR: Effect not Cached!!!");
		return;
	}
	
	// Rank
	NSUInteger index = [_ranking indexOfObject:effectDictionary];
	
	if (index != NSNotFound && index != [_ranking count] - 1) {

		// Re-append at the END of the Array
		[_ranking removeObjectAtIndex:[_ranking indexOfObject:effectDictionary]];
		[_ranking addObject:effectDictionary];
	}
	
	// Create an Instance in the first available Mixer Bus and Play
	
	UInt32 busNumber = (UInt32)[self firstFreeMixerBus];
	
	if (busNumber >= MAX_CONCURRENT_SOUNDS) {
		// Error; All Buses Full
		return;
	}

	SoundInstance* pSoundInstance = playingSoundPtrArray[busNumber];
	
	if (!pSoundInstance) {
		// Create instance
		pSoundInstance = (SoundInstance*)malloc(sizeof(SoundInstance));
        
        // Insert into array
		playingSoundPtrArray[busNumber] = pSoundInstance;
	}
	
	NSUInteger slotNumber = [[effectDictionary objectForKey:kMemorySlotNumberKey] unsignedIntValue];
	
	SoundData* data = loadedSoundPtrArray[slotNumber];
	data->usageCount += 1;
	
	pSoundInstance->data = data;

	pSoundInstance->playing = YES;
	pSoundInstance->sample  = 0;
	pSoundInstance->volume  = 1.0;
	pSoundInstance->loop    = NO;
	
	
	[self enableMixerBusNo:busNumber];
	[self setMixerInput:busNumber gain:(_sfxVolume*volume)];
}

// .............................................................................

- (void) playEffect:(NSString*) audioFileName
{
    // Used for Short Sound Effects
    
	[self playEffect:audioFileName withVolume:DEFAULT_SFX_VOLUME];
}

// .............................................................................

- (void) playBGM
{
	/*
	    Plays (resumes) currently loaded BGM (if any), with current settings
	 	(Volume, looping, etc)
	 */
	
	if (!_playingBGM) {
		
		// Play
		
		SoundInstance* pInstance = playingSoundPtrArray[BGM_BUS_NUMBER];
		
		pInstance->playing = YES;
		pInstance->loop    = YES;
		[self enableMixerBusNo:BGM_BUS_NUMBER];
		[self setMixerInput:BGM_BUS_NUMBER gain:_bgmVolume];
		
		_playingBGM = YES;
	}	
}

// .............................................................................

- (void) pauseBGM
{
	if (_playingBGM) {
		
		// Pause
		
		SoundInstance* pInstance = playingSoundPtrArray[BGM_BUS_NUMBER];
		
		pInstance->playing = NO;
		
		[self disableMixerBusNo:BGM_BUS_NUMBER];
		[self setMixerInput:BGM_BUS_NUMBER gain:0];
		
		_playingBGM = NO;
	}	
}

// .............................................................................

- (void) stopBGM
{
	if (_playingBGM) {
		
		// Stop playback
		
		[self disableMixerBusNo:BGM_BUS_NUMBER];
		[self setMixerInput:BGM_BUS_NUMBER gain:0];
		
		_playingBGM = NO;
	}	
    
    
    // Rewind to beginning, regardless of playback state
    
    SoundInstance* pInstance = playingSoundPtrArray[BGM_BUS_NUMBER];
    
    pInstance->playing = NO;
    pInstance->sample  = 0u;
    
}

// .............................................................................

- (void) resumeBGM
{
	return [self playBGM];
}

// .............................................................................

- (void) fadeOutBGMWithDuration:(CGFloat) duration
{
	if (_playingBGM && !_fadingOutBGM) {
		
		_fadingOutBGM = YES;
		
		_bgmFadeOutDuration = duration;
		_bgmFadeOutCount    = 0.0f;
		
	}
}

// .............................................................................

- (void) delayedPlaybackTimerFired:(NSTimer*) timer
{
    NSDictionary* userInfo = [timer userInfo];
    
    NSString* effectName = [userInfo objectForKey:@"Effect Name"];
    CGFloat volume = [[userInfo objectForKey:@"Effect Volume"] floatValue];
    
    [self playEffect:effectName
          withVolume:volume];
}

// .............................................................................

- (void) playEffect:(NSString *)audioFileName
         withVolume:(CGFloat)volume
         afterDelay:(CGFloat) delay
{
    if (delay == 0.0) {
        [self playEffect:audioFileName
              withVolume:volume];
    }
    else{
        NSDictionary* userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
                                  audioFileName,
                                  @"Effect Name",
                                  [NSNumber numberWithFloat:volume],
                                  @"Effect Volume",
                                  nil];
        
        [NSTimer scheduledTimerWithTimeInterval:delay
                                         target:self
                                       selector:@selector(delayedPlaybackTimerFired:)
                                       userInfo:userInfo
                                        repeats:NO];
    }
}

// .............................................................................

#pragma mark Query Engine State

- (BOOL) isPlayingBGM
{
	return _playingBGM;
}


// .............................................................................

- (void) update:(CGFloat) dt
{
	if (_playingBGM && _fadingOutBGM)
	{
		_bgmFadeOutCount += dt;
		
		if (_bgmFadeOutCount < _bgmFadeOutDuration) {
			
			CGFloat gain = _bgmVolume*(1.0f - (_bgmFadeOutCount/_bgmFadeOutDuration));
			[self setMixerInput:BGM_BUS_NUMBER gain:gain];
		}
		else {
			[self stopBGM];
			_fadingOutBGM = NO;
			_bgmFadeOutCount = 0.0f;
		}		
	}
}

// .............................................................................

#pragma mark Engine Control

- (void) pauseEngine
{
	/*
	 	  Pauses the whole engine (all sounds playing).
          No new sound can play until the Engine is resumed.
	 */
	
	[self stopAUGraph];
}

// .............................................................................

- (void) resumeEngine
{
	/*
	 	  Resumes the whole engine; i.e., undoes the effect of
	 	   -(void) pauseEngine
	 */
	
	[self startAUGraph];
}

// .............................................................................

- (void) pauseAllPlayingSounds
{
	/*
	 	  Pauses all sounds currently playing at their current position,
	 	  but still allows for new sounds to be played.
	 	  Used to freeze game sounds when pausing the game.
	 */
	
	[_busesToResume removeAllObjects];
	
	for (NSUInteger i=0; i < MAX_CONCURRENT_SOUNDS; i++) {
		
		SoundInstance* pInstance = playingSoundPtrArray[i];
		
		if (pInstance->playing) {
			pInstance->playing = NO;
			[_busesToResume addObject:[NSNumber numberWithUnsignedInt:i]];
			[self disableMixerBusNo:i];
		}
	}
}

// .............................................................................

- (void) resumeAllPausedSounds
{
	/*
	 	  Resumes all sounds that were paused last time
	 	  
	 	   -(void) pauseAllPlayingSounds
	 
	 	   was invoked.
	      
          Used to resume playback of game sounds when resuming game
	 	  after a pause.
	 */
	
	for (NSNumber* number in _busesToResume) {
		
		NSUInteger i = [number unsignedIntValue];
		
		SoundInstance* pInstance = playingSoundPtrArray[i];
		
		pInstance->playing = YES;
		[self enableMixerBusNo:i];
	}
	
	[_busesToResume removeAllObjects];
}

// .............................................................................

#pragma mark - Audio Session Delegate Methods

- (void) beginInterruption
{
	NSLog (@"Audio session was interrupted.");
    
    if (_playing) {
		
		self.interruptedDuringPlayback = YES;
		
		// Stop Graph
		[self stopAUGraph];
	}
}

// .............................................................................

#pragma mark - Singleton Methods


+ (TTSoundEngine*) sharedEngine
{
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        
        sharedInstance = [[TTSoundEngine alloc] init];
    });
    
    return sharedInstance;
}

// .............................................................................

@end

