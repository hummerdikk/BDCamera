//
//  BDCamera.m
//
//  Created by Kirill Kunst.
//  Copyright (c) 2014 Borodutch Studio. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//

#import "BDCamera.h"
#import <GLKit/GLKit.h>
#import "BDLivePreview.h"

#import <LetSeeLogger/Logger.h>
#import <libextobjc/EXTScope.h>
#import <LetSeeHelpers/LSSafeBlock.h>

@interface BDCamera() <AVCaptureFileOutputRecordingDelegate, AVCaptureVideoDataOutputSampleBufferDelegate> {
	frameCompletitionBlock handler;
}

@property (nonatomic, strong, readwrite) CIContext *ciContext;
@property (nonatomic, strong, readwrite) EAGLContext *eaglContext;
@property (nonatomic, strong, readwrite) GLKView * glView;

@property (nonatomic, strong, readwrite) AVCaptureSession *captureSession;
@property (nonatomic, strong, readwrite) AVCaptureDevice *videoDevice;

@property (nonatomic, strong) AVCaptureDeviceInput *videoInput;
@property (nonatomic, strong, readwrite) AVCaptureMovieFileOutput *fileOutput;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoDataOutput;

@property (nonatomic, strong, readwrite) AVCaptureDeviceFormat *defaultFormat;
@property (nonatomic, strong, readwrite) AVCaptureVideoPreviewLayer *previewLayer;

@property (nonatomic, assign) CMTime defaultVideoMaxFrameDuration;
@property (nonatomic, strong) NSString *capturePreset;
@property (nonatomic, strong) dispatch_queue_t captureSessionQueue;
//@property (nonatomic, assign) CMVideoDimensions currentVideoDimensions;

@property (nonatomic, assign) BOOL isFaceCamera;


@end

@implementation BDCamera

@synthesize delegate = _delegate;

#pragma mark - Initialize methods -

+ (instancetype)sharedCamera {
	
	static BDCamera *_default = nil;
		
	static dispatch_once_t onceToken;
	
	dispatch_once(&onceToken, ^{
		
		_default = [[BDCamera alloc] init];
		
		_default.useMic = NO;
		
		_default.useFileOutput = NO;
		
		_default->handler = ^(UIImage * a, NSDictionary * d, NSError * b) {};
		
		_default.delegate = NULL;
		
		[_default prepareWithPreset:AVCaptureSessionPresetMedium];
	});
	
	return _default;
}

- (instancetype)initWithPreviewView:(UIView *)previewView
{
    return [self initWithPreviewView:previewView
							  preset:AVCaptureSessionPresetInputPriority
				  microphoneRequired:NO
				  fileOutputRequired:NO
			   frameWithCompletition:nil];
}

- (instancetype)initWithPreviewView:(UIView *)previewView preset:(NSString *)capturePreset microphoneRequired:(BOOL)mic fileOutputRequired:(BOOL)fout
{
	return [self initWithPreviewView:previewView
							  preset:capturePreset
				  microphoneRequired:mic
				  fileOutputRequired:fout
			   frameWithCompletition:nil];
}

- (instancetype)initWithPreviewView:(UIView *)previewView preset:(NSString *)capturePreset microphoneRequired:(BOOL)mic fileOutputRequired:(BOOL)fout frameWithCompletition:(frameCompletitionBlock)completion {
	
	self = [super init];
	
	if (self) {
		
		_useMic = mic;
		
		_useFileOutput = fout;
		
		handler = completion;
		
		[self prepareWithPreset:capturePreset];
		
		[self addPreviewToUIView:previewView];
	}
	
	return self;
}

- (instancetype)initWithPreset:(NSString *)capturePreset microphoneRequired:(BOOL)mic fileOutputRequired:(BOOL)fout frameWithCompletition:(frameCompletitionBlock)completion {
	
	self = [super init];
	
	if (self) {
		
		_useMic = mic;
		
		_useFileOutput = fout;
		
		handler = completion;
		
		[self prepareWithPreset:capturePreset];
	}
	
	return self;
}

- (void)setFrameCompletitionBlock:(frameCompletitionBlock)block {
	handler = block;
}

- (void)prepareWithPreset:(NSString *)capturePreset {
	
	self.isFaceCamera = NO;
	
	NSError *error = nil;
	
	_captureSessionQueue = dispatch_queue_create("capture_session_queue", NULL);
	
	self.capturePreset = capturePreset;
	
	
	self.captureSession = [[AVCaptureSession alloc] init];
	
	
	[self.captureSession beginConfiguration];
	
	self.captureSession.sessionPreset = capturePreset;
	
	self.videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
	
	self.videoInput = [AVCaptureDeviceInput deviceInputWithDevice:self.videoDevice error:&error];

	if (error) {
		NSLog(@"Video input creation failed");
	}
	
	if (![self.captureSession canAddInput:self.videoInput]) {
		NSLog(@"Video input add-to-session failed");
	}
	
	[self.captureSession addInput:self.videoInput];
	
	self.defaultFormat = self.videoDevice.activeFormat;
	self.defaultVideoMaxFrameDuration = self.videoDevice.activeVideoMaxFrameDuration;

	if (_useMic) {
		AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
		AVCaptureDeviceInput *audioIn = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice error:&error];
		[self.captureSession addInput:audioIn];
	}
	
	NSDictionary *outputSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey : [NSNumber numberWithInteger:kCVPixelFormatType_32BGRA]};
	
	self.videoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
	self.videoDataOutput.videoSettings = outputSettings;
	[self.videoDataOutput setAlwaysDiscardsLateVideoFrames:YES];
	
	[_captureSession addOutput:self.videoDataOutput];
	
	if (_useFileOutput) {
		self.fileOutput = [[AVCaptureMovieFileOutput alloc] init];
		[self.captureSession addOutput:self.fileOutput];
	}

	[self.captureSession commitConfiguration];
	
	[self setupContexts];
	
//	self.previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:self.captureSession];
//	self.previewLayer.contentsGravity = kCAGravityResizeAspectFill;
//	self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
	
	[self useDefaultDelegate];
	
	_glView = nil;
}

- (void)useDefaultDelegate {
	_delegate = self;
	TRACE(@"useDefaultDelegate")
}


- (AVCaptureVideoPreviewLayer *)defaultPreviewLayer {
	
	TRACE(@"defaultPreviewLayer::start")
	
	if (_previewLayer)
		return _previewLayer;
	
	TRACE(@"defaultPreviewLayer::after_check")
	
	_previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:self.captureSession];
	_previewLayer.contentsGravity = kCAGravityResizeAspectFill;
	_previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
	
	TRACE(@"defaultPreviewLayer::end")
	
	return _previewLayer;
}

- (void)applyConfigForPreviewLayer:(AVCaptureVideoPreviewLayer *)layer withCompletitionBlock:(dispatch_block_t)block {

	TRACE(@"applyConfigForPreviewLayer::start")
	
	if (!layer)
		return;
	
	TRACE(@"applyConfigForPreviewLayer::after_check")
	
	@weakify(self)
	
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^(void) {
		
		TRACE(@"applyConfigForPreviewLayer::block::start")
		
		@strongify(self)
		
//		if (self.previewLayer)
//			[self.previewLayer setSession:nil];
		
		[layer setSession:self.captureSession];
		
		TRACE(@"applyConfigForPreviewLayer::block::after_set_session")
		
		layer.contentsGravity = kCAGravityResizeAspectFill;
		layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
			
		AVCaptureConnection * previewLayerConnection = layer.connection;
		
		if ([previewLayerConnection isVideoOrientationSupported]) {

			__block UIInterfaceOrientation ui_orientation;
			AVCaptureVideoOrientation orientation;

			[LSSafeBlock runBlockOnMainThreadSync:^{
				ui_orientation = [[UIApplication sharedApplication] statusBarOrientation];
			}];
			
			switch (ui_orientation) {
					
				case UIInterfaceOrientationPortrait:
					orientation = AVCaptureVideoOrientationPortrait; break;
					
				case UIInterfaceOrientationLandscapeRight:
					orientation = AVCaptureVideoOrientationLandscapeRight; break;
					
				case UIInterfaceOrientationLandscapeLeft:
					orientation = AVCaptureVideoOrientationLandscapeLeft; break;
					
				default:
					orientation = AVCaptureVideoOrientationPortrait; break;
			}
			
			[previewLayerConnection setVideoOrientation:orientation];
		}
		
		dispatch_async(dispatch_get_main_queue(), block);

		TRACE(@"applyConfigForPreviewLayer::block::end")
	});

	_previewLayer = nil;
	
	_previewLayer = layer;
	
	TRACE(@"applyConfigForPreviewLayer::end")
}


- (void)addPreviewToUIView:(UIView *)view {
	
	__block AVCaptureVideoPreviewLayer * layer = [self defaultPreviewLayer];

	void (^block)() = ^{
		
		layer.frame = view.bounds;
		
		[view.layer insertSublayer:layer atIndex:0];
	};
	
	BOOL isMainThread = [NSThread isMainThread];
	
	if (isMainThread)
		block();
	else
		dispatch_async(dispatch_get_main_queue(), block);
}

- (void)removePreviewFromUIView:(UIView *)view {
	
	if (!_previewLayer)
		return;
	
	void (^block)() = ^{
		
		[self.previewLayer removeFromSuperlayer];
	};
	
	BOOL isMainThread = [NSThread isMainThread];
	
	if (isMainThread)
		block();
	else
		dispatch_async(dispatch_get_main_queue(), block);
}


#pragma mark - For preview copies -
- (void)setupContexts
{
    _eaglContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    _ciContext = [CIContext contextWithEAGLContext:_eaglContext
                                           options:@{kCIContextWorkingColorSpace : [NSNull null]} ];
}

- (void)captureSampleBuffer:(BOOL)capture
{
	LSLogVerbose(@"setSampleBufferDelegate called")
	
    if (capture) {
        [self.videoDataOutput setSampleBufferDelegate:_delegate queue:_captureSessionQueue];
    } else {
        [self.videoDataOutput setSampleBufferDelegate:nil queue:_captureSessionQueue];
    }
}

- (AVCaptureConnection *)videoCaptureConnection
{
    for (AVCaptureConnection *connection in [self.fileOutput connections] ) {
		for (AVCaptureInputPort *port in [connection inputPorts] ) {
			if ([[port mediaType] isEqual:AVMediaTypeVideo] ) {
				return connection;
			}
		}
	}
    return nil;
}

#pragma mark - Rotating Camera -
+ (BOOL)isFrontFacingCameraPresent
{
	NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
	
	for (AVCaptureDevice *device in devices)
	{
		if ([device position] == AVCaptureDevicePositionFront)
			return YES;
	}
	
	return NO;
}

- (BOOL)isFrontFacingCameraPresent
{
    return [[self class] isFrontFacingCameraPresent];
}

- (void)rotateCamera
{
	if (self.isFrontFacingCameraPresent == NO)
		return;
	
    NSError *error;
    AVCaptureDeviceInput *newVideoInput;
    AVCaptureDevicePosition currentCameraPosition = [self.videoInput.device position];
    
    if (currentCameraPosition == AVCaptureDevicePositionBack)
    {
        currentCameraPosition = AVCaptureDevicePositionFront;
    }
    else
    {
        currentCameraPosition = AVCaptureDevicePositionBack;
    }
    
    AVCaptureDevice *backFacingCamera = nil;
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
	for (AVCaptureDevice *device in devices)
	{
		if ([device position] == currentCameraPosition)
		{
			backFacingCamera = device;
		}
	}
    newVideoInput = [[AVCaptureDeviceInput alloc] initWithDevice:backFacingCamera error:&error];
    
    if (newVideoInput != nil)
    {
        [_captureSession beginConfiguration];
        
        [_captureSession removeInput:self.videoInput];
        if ([_captureSession canAddInput:newVideoInput])
        {
            [_captureSession addInput:newVideoInput];
            self.videoInput = newVideoInput;
        }
        else
        {
            [_captureSession addInput:self.videoInput];
        }
        [_captureSession commitConfiguration];
    }
    
    self.videoDevice = backFacingCamera;
    [self setOutputImageOrientation:_outputImageOrientation];
    self.isFaceCamera = !self.isFaceCamera;
}

#pragma mark - Public
- (void)stopCameraCapture
{
    if ([self.captureSession isRunning])
    {
        [self.captureSession stopRunning];
    }
}

- (void)startCameraCapture
{
    if (![self.captureSession isRunning])
	{
		[self.captureSession startRunning];
	};
}

- (void)setVideoGravity:(NSString *)videoGravity
{
    _videoGravity = videoGravity;
    self.previewLayer.videoGravity = videoGravity;
}

- (void)toggleContentsGravity
{
    if ([self.previewLayer.videoGravity isEqualToString:AVLayerVideoGravityResizeAspectFill]) {
        self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    }
    else {
        self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    }
}

- (void)setZoom:(CGFloat)zoom
{
    _zoom = zoom;
    CGFloat maxZoom = self.videoDevice.activeFormat.videoMaxZoomFactor;
    if (zoom < maxZoom) {
        if ([self.videoDevice lockForConfiguration:nil]) {
            self.videoDevice.videoZoomFactor = zoom;
            [self.videoDevice unlockForConfiguration];
        }
    }
}

#pragma mark - FPS Control -
- (void)resetToDefaultFormat
{
    BOOL isRunning = self.captureSession.isRunning;
    if (isRunning) {
        [self.captureSession stopRunning];
    }
    
    AVCaptureDevice *videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    [videoDevice lockForConfiguration:nil];
    videoDevice.activeFormat = self.defaultFormat;
    videoDevice.activeVideoMaxFrameDuration = self.defaultVideoMaxFrameDuration;
    [videoDevice unlockForConfiguration];
    
    if (isRunning) {
        [self.captureSession startRunning];
    }
}

- (void)switchFPS:(CGFloat)desiredFPS
{
    BOOL isRunning = self.captureSession.isRunning;
    if (isRunning)  [self.captureSession stopRunning];
    
    AVCaptureDevice *videoDevice = self.videoDevice;
    AVCaptureDeviceFormat *selectedFormat = nil;
    int32_t maxWidth = 0;
    AVFrameRateRange *frameRateRange = nil;
    
    for (AVCaptureDeviceFormat *format in [videoDevice formats]) {
        for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
            CMFormatDescriptionRef desc = format.formatDescription;
            CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(desc);
            int32_t width = dimensions.width;
            if (range.minFrameRate <= desiredFPS && desiredFPS <= range.maxFrameRate && width >= maxWidth) {
                selectedFormat = format;
                frameRateRange = range;
                maxWidth = width;
            }
        }
    }
    
    if (selectedFormat) {
        if ([videoDevice lockForConfiguration:nil]) {
            NSLog(@"selected format:%@", selectedFormat);
            videoDevice.activeFormat = selectedFormat;
            videoDevice.activeVideoMinFrameDuration = CMTimeMake(1, (int32_t)desiredFPS);
            videoDevice.activeVideoMaxFrameDuration = CMTimeMake(1, (int32_t)desiredFPS);
            [videoDevice unlockForConfiguration];
        }
    }
    
    if (isRunning) [self.captureSession startRunning];
}

#pragma mark - Recordning
- (void)startRecordingWithURL:(NSURL *)url
{
    [self.fileOutput startRecordingToOutputFileURL:url recordingDelegate:self];
}

- (void)stopRecording
{
    [self.fileOutput stopRecording];
}

#pragma mark - Orientation
- (void)setOutputImageOrientation:(UIInterfaceOrientation)outputImageOrientation
{
    _outputImageOrientation = outputImageOrientation;
    [self updateOrientationWithInterfaceOrientation:outputImageOrientation];
}

- (void)updateOrientationWithInterfaceOrientation:(UIInterfaceOrientation)outputImageOrientation
{
    AVCaptureConnection *connection = [self videoCaptureConnection];
	
	if (connection.isVideoOrientationSupported) {
        AVCaptureVideoOrientation videoOrientation;
        switch (outputImageOrientation) {
            case UIInterfaceOrientationPortrait:
                videoOrientation = AVCaptureVideoOrientationPortrait;
                break;
            case UIInterfaceOrientationPortraitUpsideDown:
                videoOrientation = AVCaptureVideoOrientationPortraitUpsideDown;
                break;
            case UIInterfaceOrientationLandscapeLeft:
                videoOrientation = AVCaptureVideoOrientationLandscapeLeft;
                break;
            case UIInterfaceOrientationLandscapeRight:
                videoOrientation = AVCaptureVideoOrientationLandscapeRight;
                break;
                
            default:
				videoOrientation = AVCaptureVideoOrientationPortrait;
                break;
        }
        connection.videoOrientation = videoOrientation;
    }
}

#pragma mark - CaptureBuffer
- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
		
	CFTimeInterval cp1, cp2, cp3;
	
	cp1 = CACurrentMediaTime();
	
	CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
	CIImage *sourceImage = [CIImage imageWithCVPixelBuffer:(CVPixelBufferRef)imageBuffer options:nil];
		
	CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)imageBuffer;
	
	CIContext *context = [CIContext contextWithOptions:nil];
	CGImageRef myImage = [context
						  createCGImage:sourceImage
						  fromRect:CGRectMake(0, 0,
											  CVPixelBufferGetWidth(pixelBuffer),
											  CVPixelBufferGetHeight(pixelBuffer))];
	
	UIImage *image = [UIImage imageWithCGImage:myImage];
	
	CGImageRelease(myImage);
	
	cp2 = CACurrentMediaTime();
	
	CFDictionaryRef metadataDict;
	NSDictionary * metadata = nil;
	
	metadataDict = CMCopyDictionaryOfAttachments(NULL, sampleBuffer, kCMAttachmentMode_ShouldPropagate);
	
	metadata = [[NSMutableDictionary alloc] initWithDictionary:(__bridge NSDictionary*)metadataDict];
	
	CFRelease(metadataDict);
	
	cp3 = CACurrentMediaTime();
	
//	NSLog(@"BDCAM - UIImage create [%.04f ms]", (cp2 - cp1) * 1000);
//	NSLog(@"BDCAM - ExifBrightness [%.04f ms]", (cp3 - cp2) * 1000);
//	NSLog(@"BDCAM - Full time [%.04f ms]", (cp3 - cp1) * 1000);
	
    @weakify(self);
	dispatch_sync(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^(void) {
		
        @strongify(self);
        
        if (!self->handler)
            return;
        
		if (image) {
			self->handler(image, metadata, nil);
		} else {
			self->handler(nil, nil, [NSError errorWithDomain:@"image is nil" code:1 userInfo:nil]);
		}
	});
}


- (BOOL)isDelegateSet {
    
    return self.videoDataOutput.sampleBufferDelegate != nil;
}

#pragma mark - AVCaptureFileOutputRecordingDelegate
- (void)captureOutput:(AVCaptureFileOutput *)captureOutput didStartRecordingToOutputFileAtURL:(NSURL *)fileURL fromConnections:(NSArray *)connections
{
    _isRecording = YES;
}

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL fromConnections:(NSArray *)connections error:(NSError *)error
{
    _isRecording = NO;
    
    if ([self.videoDelegate respondsToSelector:@selector(didFinishRecordingToOutputFileAtURL:error:)]) {
        [self.videoDelegate didFinishRecordingToOutputFileAtURL:outputFileURL error:error];
    }
}

#pragma mark - Lazy array property
- (NSMutableArray *)displayedPreviews
{
    if (!_displayedPreviews) {
        _displayedPreviews = [NSMutableArray array];
    }
    return _displayedPreviews;
}

@end
