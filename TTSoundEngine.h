//
//  TTSoundEngine.h
//  
//
//  Created by nicolasmiari on 9/17/10.
//  Copyright 2010 Nicolás Miari. All rights reserved.
//

#import <Foundation/Foundation.h>

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

/*
 *	Notification
 */
#define sAudioEngineDidInitialize	@"AudioEngineDidInitialize"


/* -----------------------------------------------------------------------------
 *	HELPER DATA TYPES
 */


/*!
	Each instance of this struct represents a unique audio file loaded into 
	memory, and this structs holds the actual audio data (as well as several 
	audio format parameters). 
 
	@see SoundInstance
 */
typedef struct tSoundData
{
	BOOL                    isStereo;       //  TRUE: Stereo
	                                        // FALSE: Mono
	
	UInt32                  frameCount;     // Total Audio Frames

	UInt32                  usageCount;     // Number of Active (Playing or Paused)
	                                        // SoundInstance objects referencing this Data.

	AudioUnitSampleType*    audioDataLeft;	// Left Channel Data
	AudioUnitSampleType*    audioDataRight;	// Right Channel Data; NULL if 'isStereo' equals FALSE
	
}SoundData;


/*!
	Each instance of this struct represents a unique instance of a sound 
	playing on a bus of the engine's Multichannel Mixer. Different, concurrent 
	instances of the same sound (file) are possible but share the same audio data. 
 	On startup, a fixed number of these is instantiated and an array 
 	of pointers to them is initialized.
 
	@see SoundData
 */
typedef struct tSoundInstance
{
	BOOL                 isEffect;           // Unused (yet)
	
	BOOL                 playing;            //  TRUE: Render callback is Connected.
	                                         // FALSE: Render callback is Disconnected. (PAUSED)
		
	BOOL                 loop;               //  TRUE: Play again after finishing.
	                                         // FALSE: Relinquish Mixer Bus after finishing.
	    
	float                volume;             // 0.0 (Silence) to 1.0f (Full). Setup 
	                                         // assigned volume of assigned mixer bus
	                                         // to this value.
	
	UInt32               sample;             // the next audio sample to play (Play head position in data)
	
	SoundData*           data;               // Actual Audio Data in memory (Shared by All Instances)
	
}SoundInstance;


// Dictionary Keys for each sound in the memory database

#define kSoundFileNameKey				@"SoundFileName"
#define kMemorySlotNumberKey			@"MemorySlotNumber"
#define kNumberOfActiveInstancesKey		@"NumberOfActiveInstances"


// .............................................................................

/*!
	Sound Engine (Manager)

	Allows for low-latency, simultaneous playback of  1 BGM 
 	and several Sound Effects. Wraps Apple's Audio Unit directly for 
	maximum performance.
 	
 @note
	Internally, the engine consists of a number of independent 'buses', each 
	of which is able of loading one sound from file and playing it back.
	One of the buses is dedicated to lengthy sounds and is referred to as "BGM".
	This is because the iPhone hardware can decompress one sound stream at any 
	given moment, so this bus is the only one that can play compressed files 
	such as mp3. The rest (dubbed 'effect buses') are meant to play short sounds
	and only support audio in the uncompressed, .caf format.
 */
@interface TTSoundEngine : NSObject <AVAudioSessionDelegate>
{
	BOOL            initialized;

	AudioUnit       mixerUnit;
	
	// These could be static globals...
	AudioStreamBasicDescription  stereoStreamFormat;
	AudioStreamBasicDescription  monoStreamFormat;
	
	BOOL            playing;
	BOOL            playingBGM;
	
	BOOL            interruptedDuringPlayback;
	double          graphSampleRate;
	NSTimeInterval  ioBufferDuration;
	
	
	/*!
		Database of sounds loaded in memory
		Each entry is accessed by a key (string) equal to the corresponding 
		file name (without path or extension).
		
		Each entry in turn is an NSMutableDictionary with the following keys:
	 
		Key:kMemorySlotNumberKey
		Object:NSNumber object representing NSUInteger Value (Index in Array)
	 
		Key:kNumberOfActiveInstancesKey
		Object:NSNumber object representing NSUInteger Value (# of Instances Playing or Paused)
	 */
	NSMutableDictionary*    dataBase;
	
	/*!
		Array containing the SAME objects as dataBase, in an MRU order.
		Everytime a sound is played, it is moved to the top of the array.
	 */
	NSMutableArray*   ranking;
	
	/*!
		Overall sound effect volume. Each effect bus' individual volume is
		modulated (multiplied) by this value.
	 */
	CGFloat  sfxVolume;
	
	/*!
		Volume of the BGM bus.
	 */
	CGFloat  bgmVolume;
	
	
	NSMutableArray* busesToResume;
	
	BOOL            fadingOutBGM;
	CGFloat         bgmFadeOutDuration;
	CGFloat         bgmFadeOutCount;
}

@property                                BOOL  interruptedDuringPlayback;
@property (readonly, getter = isPlaying) BOOL  playing;

// .............................................................................

/*!
	Provides a handle to the (unique) engine instance.
 */
+ (TTSoundEngine*) sharedEngine;


/*!
	Low-level configuration. Turns a given bus (sound) on.
	
	@param busNumber 
		The number of bus that you wish to enable.
 */
- (void) enableMixerBusNo:(UInt32) busNumber;


/*!
	Low-level configuration. Turns a given bus (sound) off.
	
	@param busNumber 
		The number of bus that you wish to disable.
 */
- (void) disableMixerBusNo:(UInt32) busNumber;


/*!
	Starts loading a sound file for use as Sound Effect (NOT BGM).
	The file should be in the un-compressed caf format, since the only
	hardware decompressor is reserved for the (likely more lengthy) BGM sound.
 
	@param audioFileName
		The file name of the sound to load. Path and file extension should NOT
		be part of the string. An extension of .caf is assumed.
 */
- (void) preloadEffect:(NSString*) audioFileName;


/*!
 */
- (void) preloadBGM:(NSString*) audioFileName;


/*!
	Sets the overall gain for the sound effect buses. BGM bus is not affected.
 
	@param volume
		A float between 0.0 and 1.0 representing the desired gain. 
 */
- (void) setEffectVolume:(CGFloat) volume;


/*!
	Sets the gain at the BGM-dedicated bus.
 
	@param volume
		A float between 0.0 and 1.0 representing the desired gain. 
 */
- (void) setBGMVolume:(CGFloat) volume;


/*!
	Plays the effect previously loaded from a file called 'audioFileName'.
	If the file wasn't loaded yet, it is loaded now but this slows execution.
	For best performance, preload all effects prior to playback.
	Equivalent to calling playEffect:audioFileName withVolume:DEFAULT_SFX_VOLUME
 
	@param fileName 
		The file name of the sound to play. Path and file extension should NOT
		be part of the string. An extension of .caf is assumed. If the file isn't 
		preloaded yet, on-demand loading follows.
 
	@see
		playEffect:withVolume:
 */
- (void) playEffect:(NSString*) audioFileName;


/*!
	Plays the effect previously loaded from a file called 'audioFileName', at 
	the specified volume. If the file wasn't loaded yet, it is loaded now but 
	this slows execution. For best performance, preload all effects prior to 
	playback (for example, on application startup).
	
	@param fileName 
		The file name of the sound to play. Path and file extension should NOT
		be part of the string. An extension of .caf is assumed. If the file 
		isn't preloaded yet, on-demand loading follows.
 
	@param volume
		A float between 0.0 and 1.0 representing the volume at which to play the 
		sound. The final volume is the result of modulating this value by the 
		overall effect volume, set elsewhere.

	@see
		playEffect:
 */
- (void) playEffect:(NSString*) audioFileName withVolume:(CGFloat) volume;


/*!
	Plays the sound currently loaded into the BGM bus.
 */
- (void) playBGM;


/*!
	Pauses the sound currently loaded into the BGM bus.
 */
- (void) pauseBGM;


/*!
	Resumes playback of the sound currently loaded into the BGM bus, from the 
	head position at the moment of calling pauseBGM.
 */
- (void) resumeBGM;


/*!
	Stops (and "rewinds") playback of the sound currently loaded into the BGM 
	bus. A subsequent call to playBGM causes playback to start from the 
	berginning of the audio file.
 */
- (void) stopBGM;


/*!
	Initiates a fade-out effect of the gain in the BGM bus, from its current 
	value all the way down to 0.0 (silence), in the specified ammount of seconds.
 
	@param duration
		Duration of the fade-out, from start to full silence, in seconds.
 */
- (void) fadeOutBGMWithDuration:(CGFloat) duration;


// Query Engine State
/*!
	Queries if the engine is currently playing the sound on the BGM bus or not.
 
	@return
		YES if the BGM bus is playing, NO if it is not.
 */
- (BOOL) isPlayingBGM;

// Engine Control
/*!
	Pauses all the render callbacks, effectively silencing the whole engine
	immediately. All playback positions are maintained.
 */
- (void) pauseEngine;

/*!
	Resumes playback of all sounds that where playing at the moment pauseEngine
	was called. Sounds that where individually paused are not resumed.
 */
- (void) resumeEngine;

/*!
	
 */
- (void) pauseAllPlayingSounds;

/*!
 */
- (void) resumeAllPausedSounds;

// Cleanup
/*!
	Reclaims the memory occupied by sounds not currently playing.
 */
- (void) purgeUnusedSounds;


/*!
    If there is an object with a CADisplayLink somewhere in the application, it
    should call this method on the engine every frame, with the ellapsed time
    (seconds) passed in 'dt'. 
    Used to orchestrate fades.
 */
- (void) update:(CGFloat) dt;


@end
