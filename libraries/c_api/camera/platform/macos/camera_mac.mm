#include "camera_mac.hpp"

#import <CoreText/CoreText.h>
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <AppKit/AppKit.h>
#import <CoreData/CoreData.h>

#include <vector>

using namespace bnb;

@interface VideoCaptureManager : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
- (void)start:(camera_base::push_frame_cb_t)delegate;
- (void)stop;
@end


@interface VideoCaptureManager ()

@property AVCaptureSession* session;
@property AVCaptureDevice* currentDevice;
@property NSArray* videoDevices;
@property camera_base::push_frame_cb_t callback;


- (void)captureOutput:(AVCaptureOutput*)captureOutput
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection*)connection;

- (void)processFrame:(CMSampleBufferRef)sampleBuffer;
- (std::vector<bnb::camera_device_description>)getConnectedDevices;
- (void)switchCamera:(size_t)device_id;

@end

@implementation VideoCaptureManager
- (id)init
{
    self = [super init];
    //Get all media devices
    NSMutableArray* devices = (NSMutableArray*) [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];

    self.videoDevices = (NSArray*) devices;

    NSLog(@"Found Devices:");
    for (AVCaptureDevice* object in self.videoDevices) {
        NSLog(@"Device: %@", object.localizedName);
    }

    self.session = [[AVCaptureSession alloc] init];
    if (self.session) {
        [self.session beginConfiguration];

        NSError* error;
        self.currentDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];

        AVCaptureDeviceInput* input = [AVCaptureDeviceInput deviceInputWithDevice:self.currentDevice error:&error];

        if (!input || error) {
            NSLog(@"Error creating capture device input: %@", error.localizedDescription);
        } else {
            [self.session addInput:input];
        }

        AVCaptureVideoDataOutput* output = [[AVCaptureVideoDataOutput alloc] init];

        output.videoSettings = @{(NSString*) kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)};
        [output setSampleBufferDelegate:self queue:dispatch_get_main_queue()];
        [self.session addOutput:output];

        [self.session commitConfiguration];
    }

    return self;
}

- (id)init:(int)device_id
{
}

- (void)switchCamera:(size_t)device_id
{
    @synchronized(self) {
        AVCaptureDevice* newCamera = [self.videoDevices objectAtIndex:device_id];

        if (newCamera == nil) {
            NSLog(@"Not compatible name: %zu", device_id);
            newCamera = [self.videoDevices objectAtIndex:device_id];
            //return;
        }
        //Change camera source
        if (self.session) {
            //Indicate that some changes will be made to the session
            [self.session beginConfiguration];

            // //Remove existing input
            AVCaptureInput* currentCameraInput = [self.session.inputs objectAtIndex:0];

            if (currentCameraInput) {
                [self.session removeInput:currentCameraInput];
            }

            //Add input to session
            NSError* err = nil;
            AVCaptureDeviceInput* newVideoInput = [[AVCaptureDeviceInput alloc] initWithDevice:newCamera error:&err];
            if (!newVideoInput || err) {
                NSLog(@"Error creating capture device input: %@", err.localizedDescription);
            } else {
                [self.session addInput:newVideoInput];
            }

            //Commit all the configuration changes at once
            [self.session commitConfiguration];
        }
    }
}

- (void)start:(camera_base::push_frame_cb_t)delegate
{
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                             completionHandler:^(BOOL granted) {
                               if (granted) {
                                   dispatch_async(dispatch_get_main_queue(), ^{
                                     self.callback = delegate;
                                     [self.session startRunning];
                                   });

                               } else {
                                   dispatch_async(dispatch_get_main_queue(), ^{
                                     NSLog(@"Camera Has No Permission");
                                   });
                               }
                             }];
}

- (void)stop
{
    [self.session stopRunning];
}

- (void)captureOutput:(AVCaptureOutput*)captureOutput
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection*)connection
{
    @synchronized(self) {
        [self processFrame:sampleBuffer];
    }
}

- (void)processFrame:(CMSampleBufferRef)sampleBuffer
{
    CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);

    OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    std::shared_ptr<image_wrapper> img;

    switch (pixelFormat) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: {
            CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
            auto lumo = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0));
            auto chromo = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1));
            int bufferWidth = CVPixelBufferGetWidth(pixelBuffer);

            int bufferHeight = CVPixelBufferGetHeight(pixelBuffer);
            bnb_image_format_t format;
            format.orientation = BNB_DEG_0;
            format.face_orientation = 0;
            format.require_mirroring = true;
            format.width = bufferWidth;
            format.height = bufferHeight;

            // Retain twice. Each plane will release once.
            CVPixelBufferRetain(pixelBuffer);
            CVPixelBufferRetain(pixelBuffer);
            
            img = std::shared_ptr<image_wrapper>(
                    new image_wrapper(
                            format,
                            lumo,
                            int32_t(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)),
                            chromo,
                            int32_t(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1))
                    ), [pixelBuffer](auto*) {
                        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
                        CVPixelBufferRelease(pixelBuffer);
                        CVPixelBufferRelease(pixelBuffer);
                    }
            );

        } break;
        default:
            NSLog(@"ERROR TYPE : %d", pixelFormat);
            return;
    }

    if (self.callback) {
        self.callback(std::move(img));
    }
}

- (std::vector<bnb::camera_device_description>)getConnectedDevices
{
    std::vector<bnb::camera_device_description> devices;
    devices.reserve([self.videoDevices count]);
    for (AVCaptureDevice* obj in self.videoDevices) {
        camera_device_description descr;
        descr.localized_name = std::string([obj.localizedName UTF8String]);
        devices.emplace_back(std::move(descr));
    }

    return devices;
}
@end


struct bnb::camera_mac::impl
{
    impl()
        : wrapped([[VideoCaptureManager alloc] init])
    {
    }
    VideoCaptureManager* wrapped = nullptr;
};


bnb::camera_mac::camera_mac(const camera_base::push_frame_cb_t& cb)
    : camera_base(cb)
    , m_impl(std::make_unique<impl>())
{
    m_connected_devices = [m_impl->wrapped getConnectedDevices];
}

bnb::camera_mac::~camera_mac()
{
    if (m_impl->wrapped != nullptr) {
        [m_impl->wrapped stop];
        [m_impl->wrapped release];
    }
}

void bnb::camera_mac::set_device_by_index(uint32_t index)
{
    m_device_index = index;
    [m_impl->wrapped switchCamera:index];
}
void bnb::camera_mac::set_device_by_id(const std::string& device_id)
{
    for (size_t i = 0; i < m_connected_devices.size(); ++i) {
        if (device_id == m_connected_devices[i].localized_name) {
            m_device_index = i;
            [m_impl->wrapped switchCamera:i];
            break;
        }
    }
}

void camera_mac::start()
{
    [m_impl->wrapped start:m_push_frame_cb];
}

camera_sptr bnb::create_camera_device(camera_base::push_frame_cb_t cb, size_t index)
{
    auto cam_ptr = std::make_shared<bnb::camera_mac>(cb);
    cam_ptr->set_device_by_index(index);
    cam_ptr->start();
    return cam_ptr;
}