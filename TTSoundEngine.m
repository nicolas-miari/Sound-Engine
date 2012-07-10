//
//  TTSoundEngine.m
//  
//
//  Created by nicolasmiari on 9/17/10.
//  Copyright 2010 Nicolás Miari. All rights reserved.
//

#import "TTSoundEngine.h"

#define BGM_SLOT_NUMBER		0u
#define BGM_BUS_NUMBER		0u

#define SFX_FIRST_SLOT_NUMBER	(BGM_SLOT_NUMBER + 1u)
#define SFX_FIRST_BUS_NUMBER	(BGM_BUS_NUMBER  + 1u)

#define MAX_FILES_IN_MEMORY		20u
#define MAX_CONCURRENT_SOUNDS	 8u //16u

// Individual Volume When unspecified in play: Method
#define DEFAULT_SFX_VOLUME	1.0f

// Master Volume (Applies to ALL Effects)
#define DEFAULT_SFX_MASTER_VOLUME	1.0f

// BGM
#define DEFAULT_BGM_VOLUME	1.0f
#define DEFAULT_BGM_MASTER_VOLUME	0.25f

// .............................................................................

// Private Globals 

static TTSoundEngine*  sharedInstance = nil;	// Engine Singleton

static AUGraph		   processingGraph;			// Graph Instance 
static AUNode		   mixerNode;				// Mixer Instance

static SoundData*             loadedSoundPtrArray[MAX_FILES_IN_MEMORY];
static SoundInstance*         playingSoundPtrArray[MAX_CONCURRENT_SOUNDS];
static AURenderCallbackStruct inputCallbackStructArray[MAX_CONCURRENT_SOUNDS];

// .............................................................................

// Forward Decls 
void audioRouteChangeListenerCallback (void*                  inUserData,
                                       AudioSessionPropertyID inPropertyID,
                                       UInt32                 inPropertyValueSize,
                                       const void*            inPropertyValue);


#pragma mark - C Audio Callbacks

// .............................................................................

#pragma mark Render Callback 


static OSStatus auRenderCallback (void*                        inRefCon,
                                  AudioUnitRenderActionFlags*  ioActionFlags,
                                  const AudioTimeStamp*        inTimeStamp,
                                  UInt32                       inBusNumber,
                                  UInt32                       inNumberFrames,
                                  AudioBufferList*             ioData)
{
	/*
	 *	@ Description
	 *
	 *	  Called on every mixer bus every time the system needs more audio data 
	 *	  to play (buffers).
	 */
	
	SoundInstance* soundInstance = playingSoundPtrArray[inBusNumber];
	
	if (!soundInstance) {
		return noErr;
	}
	
	SoundData* data = soundInstance->data;
	
	if (!data) {
		return noErr;
	}
	
	UInt32 frameTotalForSound = data->frameCount;
	BOOL   isStereo           = data->isStereo;
	
	AudioUnitSampleType* dataInLeft;
	AudioUnitSampleType* dataInRight;
	
	dataInLeft = data->audioDataLeft;
	
    if (isStereo){
        dataInRight = data->audioDataRight;
	}

	AudioUnitSampleType* outSamplesChannelLeft;
	AudioUnitSampleType* outSamplesChannelRight;
	
	outSamplesChannelLeft  = (AudioUnitSampleType*) ioData->mBuffers[0].mData;
	outSamplesChannelRight = (AudioUnitSampleType*) ioData->mBuffers[1].mData;
	
	if (dataInLeft == NULL || soundInstance->playing == NO) {
		
		/*
		 *	Sound is not allocated yet.
		 */
		
		return noErr;
	}
	
	/*
	 *	Get the Sample Number, as an index into the sound stored in memory,
	 *	to start reading data from.
	 */	
	UInt32 sampleNumber = soundInstance->sample;
	
	BOOL isLoop = soundInstance->loop;
	
	/*
	 *	Fill the buffer(s) pointed at by ioData with the requested number of
	 *	samples of audio from the sound stored in memory.
	 */
	
	if (isStereo) {
		/*
		 *	STEREO
		 */
		for(UInt32 frameNumber = 0; frameNumber < inNumberFrames; ++frameNumber){
            
			outSamplesChannelLeft [frameNumber] = dataInLeft [sampleNumber];
			outSamplesChannelRight[frameNumber] = dataInRight[sampleNumber];
			
			sampleNumber++;
			
			/*
			 *	After reaching the end of the sound in stored memory (i.e., 
			 *	after frameTotalForSound/inNumberFrames invocations of this
			 *	callback) loop back to the start of the sound so playback 
			 *	resumes from there (IF looping)
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
		/*
		 *	MONO - (Comments Omitted)
		 */
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
	 *	Update the stored sample number so the next time this callback is 
	 *	invoked, playback resumes at the correct spot (Unless Deleted due
	 *	to Completion)
	 */
	
	if (soundInstance->playing) {
		// Bus is still alive; Update:
		soundInstance->sample = sampleNumber;
	}
	else {
		/*
		 *	NOT Playing; Disconnect.
		 */
		soundInstance->sample = 0;
		
		AUGraphDisconnectNodeInput(processingGraph, mixerNode, inBusNumber);
		
		if (data->usageCount > 0) {
			data->usageCount -= 1;
		}
	}
	
	return noErr;
	
}

// .............................................................................

#pragma mark Audio Route Change Listener Callback


/* 
 *	Audio session callback function for responding to audio route changes. 
 *	If playing back audio and the user unplugs a headset or headphones, or 
 *	removes the device from a dock connector for hardware that supports audio 
 *	playback, this callback detects that and stops playback. 
 *	Refer to AudioSessionPropertyListener in Audio Session Services Reference.
 */
void audioRouteChangeListenerCallback (void*                  inUserData,
                                       AudioSessionPropertyID inPropertyID,
                                       UInt32                 inPropertyValueSize,
                                       const void*            inPropertyValue) 
{
    // Ensure that this callback was invoked because of an audio route change
    if (inPropertyID != kAudioSessionProperty_AudioRouteChange) return;
	
    /* 
	 *	This callback, being outside the implementation block, needs a reference 
	 *	to the TTSoundEngine object, which it receives in the inUserData parameter. 
	 *	You provide this reference when registering this callback (see the call 
	 *	to AudioSessionAddPropertyListener).
	 */
    TTSoundEngine *audioObject = (__bridge TTSoundEngine*) inUserData;
    
    // if application sound is not playing, there's nothing to do, so return.
    if (audioObject.isPlaying == NO){
		
        NSLog(@"Audio route change while application audio is stopped.");
        return;
        
    }
    else{
		
        /*
		 *	Determine the specific type of audio route change that occurred.
		 */
        CFDictionaryRef routeChangeDictionary = inPropertyValue;
        
        CFNumberRef routeChangeReasonRef =
		
        CFDictionaryGetValue(routeChangeDictionary,
                             CFSTR (kAudioSession_AudioRouteChangeKey_Reason));
		
        SInt32 routeChangeReason;
        
        CFNumberGetValue (routeChangeReasonRef, kCFNumberSInt32Type, &routeChangeReason);
        
        /* 
		 *	"Old device unavailable" indicates that a headset or headphones were 
		 *	unplugged, or that the device was removed from a dock connector that 
		 *	supports audio output. In such a case, pause or stop audio (as advised 
		 *	by the iOS Human Interface Guidelines).
		 */
        if (routeChangeReason == kAudioSessionRouteChangeReason_OldDeviceUnavailable){
			
            NSLog(@"Audio output device was removed; stopping audio playback.");
            NSString *MixerHostAudioObjectPlaybackStateDidChangeNotification = @"MixerHostAudioObjectPlaybackStateDidChangeNotification";
            [[NSNotificationCenter defaultCenter] postNotificationName: MixerHostAudioObjectPlaybackStateDidChangeNotification object: audioObject]; 
			
        }
        else{
            NSLog(@"A route change occurred that does not require stopping application audio.");
        }
    }
}

// .............................................................................

#pragma mark - SOUND ENGINE - Private Interface


@interface TTSoundEngine (Private)

- (void) initEngine;

- (void) printErrorMessage: (NSString *) errorString 
                withStatus: (OSStatus) result;

- (void) setMixerInput:(UInt32)inputBus 
                  gain:(AudioUnitParameterValue)newGain;

- (void) cleanUpBusNo:(uint) busNumber;

@end

// .............................................................................

#pragma mark - SOUND ENGINE - Implementation 


@implementation TTSoundEngine

@synthesize interruptedDuringPlayback;  
// Boolean flag to indicate whether audio was playing when an interruption arrived

@synthesize playing;

- (id) init
{
	if((self = [super init])){
	
		dataBase = [[NSMutableDictionary alloc] init];

		ranking = [[NSMutableArray alloc] init];
		
		sfxVolume = DEFAULT_SFX_MASTER_VOLUME;
		bgmVolume = DEFAULT_BGM_MASTER_VOLUME;
		
		/*
		 *	Initialize Arrays
		 */
		
		for (NSUInteger i=0; i < MAX_FILES_IN_MEMORY; i++) {
			
			loadedSoundPtrArray[i] = (SoundData*) calloc(1, sizeof(SoundData));
		}
		
		for (NSUInteger i=0; i < MAX_CONCURRENT_SOUNDS; i++) {
			
			playingSoundPtrArray[i] = (SoundInstance*) calloc(1, sizeof(SoundInstance));
		}
		
		busesToResume = [[NSMutableArray alloc] init];
		
		[self initEngine];
	}
	
	return self;
}

// .............................................................................

- (void) initEngine
{
	/*
	 *	Must Call Once BEFORE Playing any Sound
	 */
	
	if (initialized == NO) {
		
		// .....................................................................
		// [ 1 ] Configure Audio Session
		
		NSError* audioSessionError = nil;
		
		AVAudioSession * session = [AVAudioSession sharedInstance];
		[session setDelegate:self];
		
		graphSampleRate = 44100.0; // [Hertz]
		
        [session setPreferredHardwareSampleRate:graphSampleRate error:&audioSessionError];
		
        if (audioSessionError){ 
            NSLog(@"Error Setting Audio Session Preferred Hardware Smple Rate"); 
            return;
        }

		//[session setCategory:AVAudioSessionCategoryPlayback error:&audioSessionError];
		[session setCategory:AVAudioSessionCategoryAmbient error:&audioSessionError];
		
        if (audioSessionError){ 
            NSLog(@"Error Setting Audio Session Category"); 
            return;
        }
		
		[session setActive:YES error:&audioSessionError];
		
        if (audioSessionError){ 
            NSLog(@"Error Setting Audio Session Active"); 
            return;
        }
		
		graphSampleRate = [session currentHardwareSampleRate];
		
		ioBufferDuration = 0.005;	// [seconds] Default:23ms (=1024 Samples @ 44.1 kHz)
		[session setPreferredIOBufferDuration:ioBufferDuration error:&audioSessionError];
        
        // TEST
        OSStatus propertySetError = 0;
        Float32 preferredBufferDuration = ioBufferDuration;
        propertySetError = AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(preferredBufferDuration), &preferredBufferDuration);
        // TEST
        
		if (audioSessionError && propertySetError){ 
            NSLog(@"Error Setting Audio Session Preferred IO Buffer Duration"); 
            return;
        }

		AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange, 
		                                audioRouteChangeListenerCallback, 
		                                self);
		
		// .....................................................................
		// [ 2 ] Setup MONO and STEREO Stream Formats
		
		/* 
		 *	The AudioUnitSampleType data type is the recommended type for sample 
		 *	data in audio units. This obtains the byte size of the type for use 
		 *	in filling in the ASBD.
		 */
		size_t bytesPerSample = sizeof (AudioUnitSampleType);
		
		/* 
		 *	Fill the application audio format struct's fields to define a linear 
		 *	PCM, stereo, noninterleaved stream at the hardware sample rate.
		 */
		stereoStreamFormat.mFormatID          = kAudioFormatLinearPCM;
		stereoStreamFormat.mFormatFlags       = kAudioFormatFlagsAudioUnitCanonical;
		stereoStreamFormat.mBytesPerPacket    = bytesPerSample;
		stereoStreamFormat.mFramesPerPacket   = 1;
		stereoStreamFormat.mBytesPerFrame     = bytesPerSample;
		stereoStreamFormat.mChannelsPerFrame  = 2;                    // 2 indicates stereo
		stereoStreamFormat.mBitsPerChannel    = 8 * bytesPerSample;
		stereoStreamFormat.mSampleRate        = graphSampleRate;
		
		monoStreamFormat.mFormatID            = kAudioFormatLinearPCM;
		monoStreamFormat.mFormatFlags         = kAudioFormatFlagsAudioUnitCanonical;
		monoStreamFormat.mBytesPerPacket      = bytesPerSample;
		monoStreamFormat.mFramesPerPacket     = 1;
		monoStreamFormat.mBytesPerFrame       = bytesPerSample;
		monoStreamFormat.mChannelsPerFrame    = 1;					  // 1 indicates mono
		monoStreamFormat.mBitsPerChannel      = 8 * bytesPerSample;
		monoStreamFormat.mSampleRate          = graphSampleRate;
		
		
		// .....................................................................
		// [ 3 ] Configure Audio Processing Graph
		
		OSStatus result = noErr;
		
		/*
		 *	Create Graph
		 */
		result = NewAUGraph(&processingGraph);
		
		if (result != noErr){
            [self printErrorMessage: @"NewAUGraph" withStatus: result]; 
            return;
        }
		
		
		/*
		 *	Specify the audio unit component descriptions for the audio units to 
		 *	be added to the graph.
		 */
		
		// Remote I/O Unit
		AudioComponentDescription ioUnitDescription;
		ioUnitDescription.componentType         = kAudioUnitType_Output;
		ioUnitDescription.componentSubType      = kAudioUnitSubType_RemoteIO;
		ioUnitDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
		ioUnitDescription.componentFlags        = 0;
		ioUnitDescription.componentFlagsMask    = 0;
		
		// Multichannel Mixer Unit		
		AudioComponentDescription mixerUnitDescription;
		mixerUnitDescription.componentType         = kAudioUnitType_Mixer;
		mixerUnitDescription.componentSubType      = kAudioUnitSubType_MultiChannelMixer;
		mixerUnitDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
		mixerUnitDescription.componentFlags        = 0;
		mixerUnitDescription.componentFlagsMask    = 0;
		
		/*
		 *	Add Nodes to the Processing Graph
		 */		

		AUNode ioNode;
		
		result = AUGraphAddNode(processingGraph, &ioUnitDescription, &ioNode);
		
		if (result != noErr){
            [self printErrorMessage: @"AUGraphNewNode failed for I/O unit" withStatus: result]; 
            return;
        }
		
		result = AUGraphAddNode(processingGraph, &mixerUnitDescription, &mixerNode);
		
		if (result != noErr){
            [self printErrorMessage: @"AUGraphNewNode failed for Mixer unit" withStatus: result];
            return;
        }
		
		/*
		 *	Open the Audio Processing Graph. 
		 *	Following this call, the audio units are instantiated but not 
		 *	initialized (no resource allocation occurs and the audio units are 
		 *	not in a state to process audio).
		 */
		result = AUGraphOpen(processingGraph);
		
		if (result != noErr){
            [self printErrorMessage: @"AUGraphOpen" withStatus: result]; 
            return;
        }
		
		/*
		 *	Obtain mixer unit instance from its corresponding node.
		 */
		
		result = AUGraphNodeInfo(processingGraph, 
                                 mixerNode, 
                                 NULL, 
                                 &mixerUnit);
		
		if (result != noErr){
            [self printErrorMessage: @"AUGraphNodeInfo" withStatus: result]; 
            return;
        }
		
		// .....................................................................
		// Multichannel Mixer unit Setup
		
		UInt32	busCount = MAX_CONCURRENT_SOUNDS;
		
		// Number of Buses (Stereo Channels in the Mixer)
		
		result = AudioUnitSetProperty(mixerUnit, 
		                              kAudioUnitProperty_ElementCount, 
		                              kAudioUnitScope_Input, 
		                              0, 
		                              &busCount, 
		                              sizeof(busCount));
		
		if (result != noErr){
            [self printErrorMessage: @"AudioUnitSetProperty (set mixer unit bus count)" withStatus: result]; 
            return;
        }

		/*
		 *	Increase the maximum frames per slice allows the mixer unit to 
		 *	accommodate the larger slice size used when the screen is locked.
		 */
		
		UInt32 maximumFramesPerSlice = 4096;
		
		result = AudioUnitSetProperty(mixerUnit, 
		                              kAudioUnitProperty_MaximumFramesPerSlice, 
		                              kAudioUnitScope_Global, 
		                              0, 
		                              &maximumFramesPerSlice, 
		                              sizeof(maximumFramesPerSlice));
		
		if (result != noErr){
            [self printErrorMessage: @"AudioUnitSetProperty (set mixer unit input stream format)" withStatus: result]; 
            return;
        }

		/*
		 *	Disable and Mute All Buses:
		 */
		for (UInt32 busNumber = 0; busNumber < busCount; busNumber++) {
			
			// Start Disabled (No Data)
			
			[self setMixerInput:busNumber gain:0];
			[self disableMixerBusNo:busNumber];
			
		}
		
		/*
		 *	Attach the input render callback and context to each input bus.
		 */
				 
		for (UInt32 busNumber = 0; busNumber < busCount; ++busNumber){
		
			inputCallbackStructArray[busNumber].inputProc       = &auRenderCallback;
			inputCallbackStructArray[busNumber].inputProcRefCon = playingSoundPtrArray;
			
			
			result = AUGraphSetNodeInputCallback(processingGraph,
			                                     mixerNode, 
			                                     busNumber, 
			                                     &inputCallbackStructArray[busNumber]);
			
			if (result != noErr){
                [self printErrorMessage: @"AUGraphSetNodeInputCallback" withStatus: result]; 
                return;
            }
		}
		 
		/*
		 *	Set All Buses to Stereo. For Mono Files, Replicate the only channel 
		 *	into L and R
		 */
		for (UInt32 busNumber = 0; busNumber < busCount; ++busNumber) {
			
			result = AudioUnitSetProperty(mixerUnit,
			                              kAudioUnitProperty_StreamFormat,
			                              kAudioUnitScope_Input,
                                          busNumber,
			                              &stereoStreamFormat,
			                              sizeof (stereoStreamFormat));
			
			if (result != noErr){
                [self printErrorMessage: @"AudioUnitSetProperty (set mixer unit input bus stream format)" withStatus: result];
                return;
            }
		}
		
		/*
		 *	Set the mixer unit's output sample rate format. This is the only 
		 *	aspect of the output stream format that must be explicitly set.
		 */
		result = AudioUnitSetProperty(mixerUnit,
		                              kAudioUnitProperty_SampleRate,
		                              kAudioUnitScope_Output,
		                              0,
		                              &graphSampleRate,
		                              sizeof (graphSampleRate));
		
		if (result != noErr){
            [self printErrorMessage: @"AudioUnitSetProperty (set mixer unit output stream format)" withStatus: result]; 
            return;
        }
		
		
		// .....................................................................
		// [ 6 ] Connect the Audio Unit Nodes

		AudioUnitElement mixerUnitOutputBus  = 0;
		AudioUnitElement ioUnitOutputElement = 0;
		
		result = AUGraphConnectNodeInput(processingGraph, 
		                                 mixerNode,           // source node 
		                                 mixerUnitOutputBus,  // source node bus
		                                 ioNode,              // destination node
		                                 ioUnitOutputElement  // destination node element
				 );
		
		if (result != noErr){
			[self printErrorMessage: @"AUGraphConnectNodeInput" withStatus: result]; return;
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
		 *	The graph is started from applicationDidBecomeActive.
		 *	If we also activate it here, it wont stop when locking the phone.
		 */
		
		if (result == noErr) {
		//	AUGraphStart(processingGraph);
			initialized = YES;
		}
		else {
			initialized = NO;
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
	 *	Called by Scene Director (=Main View Controller)
	 *  or App Delegate (TODO: DECIDE) when receiving a Memory Warning.
	 *	Release all Audio Data that is not being played.
	 */
	
	/*
		Remove least recently used half of sounds
	 */
	NSUInteger count = [ranking count];
	
	NSUInteger halfCount = count;// / 2;
	
	NSMutableArray* soundsToRemove = [[NSMutableArray alloc] init];
	
	for (NSUInteger i=0; i < halfCount; i++) {
		
		NSMutableDictionary* dictionary = (NSMutableDictionary*)[ranking objectAtIndex:i];

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
                
                NSLog(@"Purge Sound in Slot no. [%2d] - SUCCEEDED.\n", slotNumber);
			}
			else {
				NSLog(@"Purge Sound in Slot no. [%2d] - FAILED (use count: %lu).\n", slotNumber, data->usageCount);
			}
		}
		
		[dataBase removeObjectForKey:[dictionary objectForKey:kSoundFileNameKey]];
	}
	
	[ranking removeObjectsInArray:soundsToRemove];

	[soundsToRemove release];
}

// .............................................................................

- (void) printErrorMessage: (NSString *) errorString withStatus: (OSStatus) result 
{
	
    char resultString[5];
    UInt32 swappedResult = CFSwapInt32HostToBig (result);
    bcopy (&swappedResult, resultString, 4);
    resultString[4] = '\0';
	
    NSLog( @"*** %@ error: %s\n", errorString, (char*) &resultString);
}

// .............................................................................

- (void)startAUGraph
{
	/*
	 *	@ Description
	 *
	 *	  Starts Render.
	 */
    
	OSStatus result = AUGraphStart(processingGraph);
    
	if (result != noErr) {
		[self printErrorMessage: @"AUGraphStart" withStatus: result];
		return; 
	}
	
	playing = YES;
}

// .............................................................................

- (void)stopAUGraph
{
	/*
	 *	@ Description
	 *
	 *	  Stops Render.
	 */
	
	
    Boolean isRunning = NO;
    
    OSStatus result = AUGraphIsRunning(processingGraph, &isRunning);
    
	if (result != noErr) { 
		[self printErrorMessage: @"AUGraphIsRunning" withStatus: result];
		return; 
	}
    
    if (isRunning) {
        
		result = AUGraphStop(processingGraph);
        
		if (result != noErr){ 
			[self printErrorMessage: @"AUGraphStop" withStatus: result];
			return; 
		}
        playing = NO;
    }
}


// .............................................................................

- (void) enableMixerBusNo:(UInt32) busNumber
{
	
	
	OSStatus result;
	
	result = AudioUnitSetParameter(mixerUnit, 
	                               kMultiChannelMixerParam_Enable, 
	                               kAudioUnitScope_Input, 
	                               busNumber, 
	                               1, 
	                               0);
	
	if (result != noErr){
		[self printErrorMessage: @"EnableMixerBusNo" withStatus: result]; 
		return;
	}
	
	playingSoundPtrArray[busNumber]->playing = YES;
}

// .............................................................................

- (void) disableMixerBusNo:(UInt32) busNumber
{
	OSStatus result;
	
	result = AudioUnitSetParameter(mixerUnit, 
	                               kMultiChannelMixerParam_Enable, 
	                               kAudioUnitScope_Input, 
	                               busNumber, 
	                               0, 
	                               0);
	
	if (result != noErr){
		[self printErrorMessage: @"DisableMixerBusNo" withStatus: result]; 
        return;
	}
	
	playingSoundPtrArray[busNumber]->playing = NO;
}

// .............................................................................

- (void) setMixerInput:(UInt32) inputBus gain:(AudioUnitParameterValue) newGain
{
	OSStatus result = AudioUnitSetParameter(mixerUnit,
	                                        kMultiChannelMixerParam_Volume,
	                                        kAudioUnitScope_Input,
	                                        inputBus,
	                                        newGain,
	                                        0);
	
    if (result != noErr){
        [self printErrorMessage: @"AudioUnitSetParameter (set mixer unit input volume)" withStatus: result]; 
        return;
    }
}

// .............................................................................

- (void) setMixerOutputGain: (AudioUnitParameterValue) newGain {
	
    OSStatus result = AudioUnitSetParameter(mixerUnit,
	                                        kMultiChannelMixerParam_Volume,
	                                        kAudioUnitScope_Output,
	                                        0,
	                                        newGain,
	                                        0);
	
    if (result != noErr){
        [self printErrorMessage: @"AudioUnitSetParameter (set mixer unit output volume)" withStatus: result]; 
        return;
    }
}

// .............................................................................

- (NSUInteger) firstFreeMemorySlot
{
	/*
	 *	@ Description
	 *
	 *	Return the first available slot (index) in the loaded sounds array, using
	 *	the following criterion:
	 *
	 */

	
	// First, Search for Empty Slot
	for (NSUInteger i = SFX_FIRST_SLOT_NUMBER; i < MAX_FILES_IN_MEMORY; i++) {
	
		if (loadedSoundPtrArray[i]->audioDataLeft == NULL) {
			// No Sound Loaded on Slot; FOUND
			return i;
		}
	}
	
	// ...All Slots are Loaded. Check Usage Count
	NSUInteger smallestUsageCount = MAX_CONCURRENT_SOUNDS;
	
	NSUInteger leastUsedIndex = MAX_FILES_IN_MEMORY;
	
	for (NSUInteger i = SFX_FIRST_SLOT_NUMBER; i < MAX_FILES_IN_MEMORY; i++) {
		SoundData* soundData = loadedSoundPtrArray[i];
		
		if (soundData->usageCount < smallestUsageCount ) {
			// Update Minimum
			smallestUsageCount = soundData->usageCount;
			leastUsedIndex = i;
		}
	}
	
	if (smallestUsageCount == 0) {
		return leastUsedIndex;
	}
	
	// Flags Failure: (All Slots are Loaded AND Playing)
	return MAX_FILES_IN_MEMORY;
}

// .............................................................................

- (NSUInteger) firstFreeMixerBus
{
	/*
	 *	@ Description
	 *
	 *	Return the first available Mixer Bus
	 */
	
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

#pragma mark - ENGINE INTERFACE METHODS (public)

#pragma mark Loading of Sounds 


- (void) preloadEffect:(NSString*) audioFileName
{
	/*
	 *	@ Description
	 *
	 *	Loads specified audio file into the first available memory slot.
	 *	(If existent)
	 *
	 */
	

    if (!audioFileName) {
        return;
    }
    
	NSUInteger freeSlot = [self firstFreeMemorySlot];
	
	if (freeSlot >= MAX_FILES_IN_MEMORY) {
		// All Slots Loaded AND Playing; Abort.
		NSLog(@"Failed to load sound %@ : Out of memory Slots!", audioFileName);
		return;
	}
	
	NSMutableDictionary* existingEntry = [dataBase objectForKey:audioFileName];
	if (existingEntry) {
		// Already Loaded; Nothing to do.
		return;
	}
	
    
	//NSURL* url = [[NSBundle mainBundle] URLForResource:audioFileName withExtension:@"caf"];	// iOS 4.x
    
    NSString* path = [[NSBundle mainBundle] pathForResource:audioFileName ofType:@"caf"];
	
    if (!path) {
        NSLog(@"Error: Sound Does NOT Exist!");
        return;
    }
    
    NSURL* url = [NSURL fileURLWithPath:path];	// iOS 3.1.3
    
    CFURLRef urlRef = (CFURLRef)[url retain];
	
	ExtAudioFileRef audioFileObject = 0;
	
	// Open an audio file and associate it with the extended audio file object.
	OSStatus result = ExtAudioFileOpenURL(urlRef, &audioFileObject);
	[url release];
	
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
	
	if (noErr != result){
		[self printErrorMessage: @"ExtAudioFileGetProperty (audio file length in frames)" withStatus: result]; 
		ExtAudioFileDispose(audioFileObject); 
		return;
	}
	
	SoundData* data = loadedSoundPtrArray[freeSlot];
	
	if (data) {
		// Recycle:
		if (data->audioDataLeft){
            free(data->audioDataLeft);  
        }
        
		if (data->audioDataRight){
            free(data->audioDataRight);
        }
	}
	else{
		// Create and Insert to Array:
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
	
	if (result != noErr){
		[self printErrorMessage: @"ExtAudioFileGetProperty (file audio format)" withStatus: result]; 
		ExtAudioFileDispose (audioFileObject); 
		return;
	}
	
	UInt32 channelCount = fileAudioFormat.mChannelsPerFrame;
	
	/*
	 *	Allocate memory in the sound structure to hold the left channel
	 */
	//data->audioDataLeft = (AudioUnitSampleType*) calloc(totalFramesInFile, sizeof(AudioUnitSampleType));
	
	AudioStreamBasicDescription importFormat = { 0 };
	
	if (channelCount == 1) {
		// MONO
		
		data->isStereo = NO;
		importFormat   = monoStreamFormat;
	}
	else if( channelCount == 2 ) {
		// STEREO - Allocate Right Channel as well
		
		data->isStereo = YES;
		//data->audioDataRight = (AudioUnitSampleType*) calloc(totalFramesInFile, sizeof(AudioUnitSampleType));
		importFormat   = stereoStreamFormat;		
	}
	else {
		NSLog(@"*** WARNING: File format not supported - wrong number of channels");
		
		ExtAudioFileDispose (audioFileObject);
		return;
	}


	/*
	 *	Assign the appropriate mixer input bus stream data format to the 
	 *	extended audio file object. This is the format used for the audio data 
	 *  placed into the audio buffer in the SoundStruct data structure, which is
	 *	in turn used in the render callback function.
	 */
	result = ExtAudioFileSetProperty(audioFileObject,
	                                 kExtAudioFileProperty_ClientDataFormat,
	                                 sizeof(importFormat),
	                                 &importFormat);
	
	if (result != noErr){
		[self printErrorMessage: @"ExtAudioFileSetProperty (client data format)" withStatus: result]; 
		
		ExtAudioFileDispose (audioFileObject); 
		return;
	}
	
	/*
	 *	Setup an AudioBufferList struct, which has two roles:
	 *
	 *		1. It gives the ExtAudioFileRead function the configuration it needs
	 *			to correctly provide the data to the buffer.
	 *
	 *		2. It points to the Sound Structure's audioDataLeft buffer, so that
	 *			audio data obtained from disk using the ExtAudioFileRead
	 *			function goes to that buffer.
	 */
	AudioBufferList* bufferList;
	
	bufferList = (AudioBufferList*) malloc(sizeof(AudioBufferList) + sizeof(AudioBuffer)*(channelCount - 1));
	
	if (bufferList == NULL) {
		NSLog(@"*** malloc failure for allocating bufferList memory"); 

		ExtAudioFileDispose (audioFileObject); 
		return;
	}
	
	bufferList->mNumberBuffers = channelCount;
	
	AudioBuffer emptyBuffer = { 0 };
	size_t arrayIndex;
	for ( arrayIndex = 0; arrayIndex < channelCount; arrayIndex++ ) {
		bufferList->mBuffers[arrayIndex] = emptyBuffer;
	}
	
	
	/*
	 *	Allocate Data Buffers (Deferred until now to simplify abortion)
	 */
	data->audioDataLeft = (AudioUnitSampleType*) calloc(totalFramesInFile, sizeof(AudioUnitSampleType));
	
	if (channelCount == 2) {
		data->audioDataRight = (AudioUnitSampleType*) calloc(totalFramesInFile, sizeof(AudioUnitSampleType));
	}
	
	/*
	 *	Setup the AudioBuffer structs in the buffer list
	 */
	bufferList->mBuffers[0].mNumberChannels = 1;
	bufferList->mBuffers[0].mDataByteSize   = totalFramesInFile * sizeof(AudioUnitSampleType);
	bufferList->mBuffers[0].mData           = data->audioDataLeft;
	
	if (channelCount == 2) {
		bufferList->mBuffers[1].mNumberChannels = 1;
		bufferList->mBuffers[1].mDataByteSize   = totalFramesInFile * sizeof (AudioUnitSampleType);
		bufferList->mBuffers[1].mData           = data->audioDataRight;
	}
	
	/*
	 *	Perform a synchronous, sequential read of the audio data out of the file
	 *	and into the Sound Struct's audioDataLeft (and Right if Stereo)
	 */
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
	
	[dataBase setObject:dbEntry forKey:audioFileName];
	
	[ranking addObject:dbEntry];
	
	[dbEntry release];
	
	// DONE ***
}

// .............................................................................

- (void) preloadBGM:(NSString *)audioFileName
{
	/*
	 *	@ Description
	 *
	 *	Loads specified audio file for use as BGM. If an audio file is already
	 *	loaded, the data is discarded. If the previously loaded BGM is currently 
	 *	playing, it is stopped and playback resumes after the new file is loaded.
	 */
	
	BOOL restore = NO;
	
	if ([self isPlayingBGM]) {
		[self pauseBGM];
		restore = YES;
	}
	
	
	NSURL* url = [[NSBundle mainBundle] URLForResource:audioFileName withExtension:@"caf"]; // iOS 4.x
	//NSURL* url = [NSURL fileURLWithPath:[[NSBundle mainBundle] pathForResource:audioFileName ofType:@"caf"]];	// iOS 3.1.3
    
    if (!url) {
		url = [[NSBundle mainBundle] URLForResource:audioFileName withExtension:@"mp3"];                  // iOS 4.x
        //url = [NSURL fileURLWithPath:[[NSBundle mainBundle] pathForResource:audioFileName ofType:@"mp3"]];	// iOS 3.1.3
	}
	
	CFURLRef urlRef = (CFURLRef)[url retain];
	
	ExtAudioFileRef audioFileObject = 0;
	
	// Open an audio file and associate it with the extended audio file object.
	OSStatus result = ExtAudioFileOpenURL(urlRef, &audioFileObject);
	[url release];
	
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
	
	/*
	 *	Assign the frame count to the soundStruct instance variable
	 */
	pSoundData->frameCount = totalFramesInFile;
	
	
	/*
	 *	Get the Audio File's number of channels
	 */
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
		NSLog(@"*** WARNING: File format not supported - wrong number of channels");
		ExtAudioFileDispose (audioFileObject);
		return;
	}
	
	
	/*
	 *	Assign the appropriate mixer input bus stream data format to the 
	 *	extended audio file object. This is the format used for the audio data 
	 *  placed into the audio buffer in the SoundStruct data structure, which is
	 *	in turn used in the render callback function.
	 */
	result = ExtAudioFileSetProperty(audioFileObject,
	                                 kExtAudioFileProperty_ClientDataFormat,
	                                 sizeof(importFormat),
	                                 &importFormat);
	
	if (result != noErr) {
		[self printErrorMessage: @"ExtAudioFileSetProperty (client data format)" withStatus: result]; 
		
		ExtAudioFileDispose (audioFileObject); 	
		return;
	}
	
	/*
	 *	Setup an AudioBufferList struct, which has two roles:
	 *
	 *		1. It gives the ExtAudioFileRead function the configuration it needs
	 *			to correctly provide the data to the buffer.
	 *
	 *		2. It points to the Sound Structure's audioDataLeft buffer, so that
	 *			audio data obtained from disk using the ExtAudioFileRead
	 *			function goes to that buffer.
	 */
	AudioBufferList*	bufferList;
	
	bufferList = (AudioBufferList*) malloc(sizeof(AudioBufferList) + sizeof(AudioBuffer)*(channelCount - 1));
	
	if (bufferList == NULL) {
		NSLog(@"*** malloc failure for allocating bufferList memory"); 
		
		ExtAudioFileDispose (audioFileObject); 		
		return;
	}
	
	bufferList->mNumberBuffers = channelCount;
	
	AudioBuffer emptyBuffer = { 0 };
	size_t arrayIndex;
	for ( arrayIndex = 0; arrayIndex < channelCount; arrayIndex++ ) {
		bufferList->mBuffers[arrayIndex] = emptyBuffer;
	}
	
	/*
	 *	Allocate Audio Data Buffers (Deferred to simplify abortion)
	 */
	pSoundData->audioDataLeft = (AudioUnitSampleType*) calloc(totalFramesInFile, sizeof(AudioUnitSampleType));
	
	if (channelCount == 2) {
		pSoundData->audioDataRight = (AudioUnitSampleType*) calloc(totalFramesInFile, sizeof(AudioUnitSampleType));
	}
	
	/*
	 *	Setup the AudioBuffer structs in the buffer list
	 */
	bufferList->mBuffers[0].mNumberChannels = 1;
	bufferList->mBuffers[0].mDataByteSize   = totalFramesInFile * sizeof(AudioUnitSampleType);
	bufferList->mBuffers[0].mData           = pSoundData->audioDataLeft;
	
	if (channelCount == 2) {
		bufferList->mBuffers[1].mNumberChannels = 1;
		bufferList->mBuffers[1].mDataByteSize   = totalFramesInFile * sizeof (AudioUnitSampleType);
		bufferList->mBuffers[1].mData           = pSoundData->audioDataRight;
	}
	
	/*
	 *	Perform a synchronous, sequential read of the audio data out of the file
	 *	and into the Sound Struct's audioDataLeft (and Right if Stereo)
	 */
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
	
	/*
	 *	File Read Succeeded; 
	 */
	
	
	
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
	pSoundInstance->sample   = 0u;
	
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
	/*
	 *	Sets Master SFX Volume. Modulates each individual Effect's 
	 *  Volume (Specified on play)
	 */
	
	sfxVolume = volume;
}

// .............................................................................

- (void) setBGMVolume:(CGFloat) volume
{
	bgmVolume = volume;
}

// .............................................................................

#pragma mark Playback of Sounds


- (void) playEffect:(NSString *)audioFileName withVolume:(CGFloat) volume
{
	/*
	 *	@ Description
	 *
	 *	Play Effect. Preload if Necessary.
	 */
	
	if (!audioFileName) {
		return;
	}
	
	[self preloadEffect:audioFileName]; // Returns Immediately if Already Loaded
	
	NSMutableDictionary* effectDictionary = (NSMutableDictionary*)[dataBase objectForKey:audioFileName];
	

	/*
	 *	Play (un-mute)
	 */
	
	if (!effectDictionary) {
		// ERROR
		NSLog(@"ERROR: Effect not Cached!!!");
		return;
	}
	
	// Rank
	NSUInteger index = [ranking indexOfObject:effectDictionary];
	
	if (index != NSNotFound && index != [ranking count] - 1) {

		// Re-append at the END of the Array
		[ranking removeObjectAtIndex:[ranking indexOfObject:effectDictionary]];
		[ranking addObject:effectDictionary];
	}
	
	// Create an Instance in the first available Mixer Bus and Play
	
	UInt32 busNumber = (UInt32)[self firstFreeMixerBus];
	
	if (busNumber >= MAX_CONCURRENT_SOUNDS) {
		// Error; All Buses Full
		//NSLog(@"ERROR: All Buses are busy!!!");
		return;
	}

	SoundInstance* pSoundInstance = playingSoundPtrArray[busNumber];
	
	if (!pSoundInstance) {
		// Create
		pSoundInstance = (SoundInstance*)malloc(sizeof(SoundInstance));
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
	[self setMixerInput:busNumber gain:(sfxVolume*volume)];
}

// .............................................................................

- (void) playEffect:(NSString*) audioFileName
{
	/*
	 *	Used for Short Sound Effects
	 */
	[self playEffect:audioFileName withVolume:DEFAULT_SFX_VOLUME];
}

// .............................................................................

- (void) playBGM
{
	/*
	 *	@ Description
	 *
	 *	Plays (resumes) currently loaded BGM (if any), with current settings
	 *	(Volume, looping, etc)
	 */
	
	if (!playingBGM) {
		
		// Play
		
		SoundInstance* pInstance = playingSoundPtrArray[BGM_BUS_NUMBER];
		
		pInstance->playing = YES;
		pInstance->loop    = YES;
		[self enableMixerBusNo:BGM_BUS_NUMBER];
		[self setMixerInput:BGM_BUS_NUMBER gain:bgmVolume];
		
		playingBGM = YES;
	}	
}

// .............................................................................

- (void) pauseBGM
{
	if (playingBGM) {
		
		// Pause
		
		SoundInstance* pInstance = playingSoundPtrArray[BGM_BUS_NUMBER];
		
		pInstance->playing = NO;
		
		[self disableMixerBusNo:BGM_BUS_NUMBER];
		[self setMixerInput:BGM_BUS_NUMBER gain:0];
		
		playingBGM = NO;
	}	
}

// .............................................................................

- (void) stopBGM
{
	if (playingBGM) {
		
		// Stop playback
		
		[self disableMixerBusNo:BGM_BUS_NUMBER];
		[self setMixerInput:BGM_BUS_NUMBER gain:0];
		
		playingBGM = NO;
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
	if (playingBGM && !fadingOutBGM) {
		
		fadingOutBGM = YES;
		
		bgmFadeOutDuration = duration;
		bgmFadeOutCount    = 0.0f;
		
	}
}

// .............................................................................

#pragma mark Query Engine State

- (BOOL) isPlayingBGM
{
	return playingBGM;
}


// .............................................................................

- (void) update:(CGFloat) dt
{
	if (playingBGM && fadingOutBGM)
	{
		bgmFadeOutCount += dt;
		
		if (bgmFadeOutCount < bgmFadeOutDuration) {
			
			CGFloat gain = bgmVolume*(1.0f - (bgmFadeOutCount/bgmFadeOutDuration));
			[self setMixerInput:BGM_BUS_NUMBER gain:gain];
		}
		else {
			[self stopBGM];
			fadingOutBGM = NO;
			bgmFadeOutCount = 0.0f;
		}		
	}
}

// .............................................................................

#pragma mark Engine Control

- (void) pauseEngine
{
	/*
	 *	@ Description
	 *
	 *	  Pauses the whole engine (all sounds playing).
	 *	  No new sound can play until the Engine is resumed.
	 */
	
	[self stopAUGraph];
}

// .............................................................................

- (void) resumeEngine
{
	/*
	 *	@ Description
	 *	  
	 *	  Resumes the whole engine; i.e., undoes the effect of
	 *
	 *	  -(void) pauseEngine
	 */
	
	[self startAUGraph];
}

// .............................................................................

- (void) pauseAllPlayingSounds
{
	/*
	 *	@ Description
	 *
	 *	  Pauses all sounds currently playing at their current position,
	 *	  but still allows for new sounds to be played. 
	 *	  Used to freeze game sounds when pausing the game.
	 */
	
	[busesToResume removeAllObjects];
	
	for (NSUInteger i=0; i < MAX_CONCURRENT_SOUNDS; i++) {
		
		SoundInstance* pInstance = playingSoundPtrArray[i];
		
		if (pInstance->playing) {
			pInstance->playing = NO;
			[busesToResume addObject:[NSNumber numberWithUnsignedInt:i]];
			[self disableMixerBusNo:i];
		}
	}
}

// .............................................................................

- (void) resumeAllPausedSounds
{
	/*
	 *	@ Description
	 *
	 *	  Resumes all sounds that were paused last time 
	 *	  
	 *	  -(void) pauseAllPlayingSounds
	 *
	 *	  was invoked.
	 *    Used to resume playback of game sounds when resuming game
	 *	  after a pause.
	 */
	
	for (NSNumber* number in busesToResume) {
		
		NSUInteger i = [number unsignedIntValue];
		
		SoundInstance* pInstance = playingSoundPtrArray[i];
		
		pInstance->playing = YES;
		[self enableMixerBusNo:i];
	}
	
	[busesToResume removeAllObjects];
}

// .............................................................................

#pragma mark -
#pragma mark Audio Session Delegate Methods

- (void) beginInterruption
{
	NSLog(@"Audio session was interrupted.");
    
    if (playing) {
		
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

