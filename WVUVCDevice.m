//
// Copyright © 2022 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import "WVUVCDevice.h"
#import <libuvc.h>

extern uvc_context_t *uvc_ctx;

@interface WVUVCDevice ()

@property uvc_device_t *device;
@property uvc_device_handle_t *handle;
@property (readwrite) NSString *name;

- (nullable instancetype)initWithDevice:(uvc_device_t *)device;

@end

@implementation WVUVCDevice

+ (NSArray<WVUVCDevice *> *)allDevices {
    NSMutableArray<WVUVCDevice *> *devices = [NSMutableArray array];
    uvc_device_t **devs;
    
    if (uvc_get_device_list(uvc_ctx, &devs) < 0) {
        return devices;
    }
    for (ssize_t i = 0; devs[i] != NULL; i++) {
        WVUVCDevice *device = [[WVUVCDevice alloc] initWithDevice:devs[i]];
        if (device) {
            [devices addObject:device];
        }
    }
    uvc_free_device_list(devs, 1);
    return devices;
}

- (instancetype)initWithDevice:(uvc_device_t *)device {
    if (self = [super init]) {
        self.device = device;
        self.name = [self createDescription];
        if (!self.name) {
            return nil;
        }
        uvc_ref_device(device);
    }
    return self;
}

- (void)dealloc {
    [self stopStream];
    uvc_unref_device(self.device);
}

- (nullable NSString *)createDescription {
    uvc_device_descriptor_t *desc;
    NSString *product;
    NSString *manufacturer;
    NSString *path;
    if (uvc_get_device_descriptor(self.device, &desc) < 0) {
        return nil;
    }
    path = [NSString stringWithFormat:@"%04X:%04X (bus %u, device %u)", desc->idVendor, desc->idProduct, uvc_get_bus_number(self.device), uvc_get_device_address(self.device)];
    if (desc->product) {
        product = [NSString stringWithCString:desc->product encoding:NSASCIIStringEncoding];
    }
    if (desc->manufacturer) {
        manufacturer = [NSString stringWithCString:desc->manufacturer encoding:NSASCIIStringEncoding];
    }
    uvc_free_device_descriptor(desc);
    if (product && manufacturer) {
        return [NSString stringWithFormat:@"%@ - %@ - %@", manufacturer, product, path];
    } else if (product) {
        return [NSString stringWithFormat:@"%@ - %@", product, path];
    } else if (manufacturer) {
        return [NSString stringWithFormat:@"%@ - %@", manufacturer, path];
    } else {
        return path;
    }
}

static NSError *uvcErrorToNSError(uvc_error_t res) {
    const char *errstr = uvc_strerror(res);
    if (errstr) {
        return [NSError errorWithDomain:@"com.osy86.WebcamViewer" code:-1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"libuvc error: %s", "WVUVCDevice"), errstr]}];
    } else {
        return [NSError errorWithDomain:@"com.osy86.WebcamViewer" code:-1 userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Unknown error.", "WVUVCDevice")}];
    }
}

static void streamCallback(struct uvc_frame *frame, void *user_ptr) {
    WVUVCDevice *self = (__bridge WVUVCDevice *)user_ptr;
    uvc_frame_t *bgr;
    uvc_error_t ret;
    
    /* We'll convert the image from YUV/JPEG to BGR, so allocate space */
    bgr = uvc_allocate_frame(frame->width * frame->height * 3);
    if (!bgr) {
        return;
    }
    
    /* Do the BGR conversion */
    // TODO: use CoreVideo to process the frame
    ret = uvc_any2bgr(frame, bgr);
    if (ret) {
        uvc_perror(ret, "uvc_any2bgr");
        uvc_free_frame(bgr);
        return;
    }
    
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, frame->data, frame->data_bytes, NULL);
    CGColorSpaceRef colorspace = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
    CGImageRef cgImage = CGImageCreate(/* width              */ frame->width,
                                       /* height             */ frame->height,
                                       /* bitsPerComponent   */ 8,
                                       /* bitsPerPixel       */ 24,
                                       /* bytesPerRow        */ frame->width * 3,
                                       /* colorspace         */ colorspace,
                                       /* bitmapInfo         */ kCGBitmapByteOrderDefault,
                                       /* provider           */ provider,
                                       /* decode             */ NULL,
                                       /* shouldInterpolate  */ YES,
                                       /* intent             */ kCGRenderingIntentDefault);
    CGColorSpaceRelease(colorspace);
    CGDataProviderRelease(provider);
    [self.delegate uvcDevice:self didRecieveFrame:cgImage];
    CGImageRelease(cgImage);
    
    uvc_free_frame(bgr);
}

- (BOOL)startStreamWithError:(NSError *__autoreleasing  _Nullable *)error {
    uvc_error_t res = UVC_SUCCESS;
    uvc_device_handle_t *devh = NULL;
    uvc_stream_ctrl_t ctrl;
    NSLog(@"Opening device...: %@", self.name);
    if ((res = uvc_open(self.device, &devh)) < 0) {
        goto err;
    }
    NSLog(@"Negotiate stream profile...");
    if ((res = uvc_get_stream_ctrl_format_size(devh, &ctrl, UVC_FRAME_FORMAT_YUYV, 640, 480, 30)) < 0) {
        goto err;
    }
    uvc_print_stream_ctrl(&ctrl, stderr);
    NSLog(@"Starting stream...");
    if ((res = uvc_start_streaming(devh, &ctrl, streamCallback, (__bridge void *)self, 0)) < 0) {
        goto err;
    }
    self.handle = devh;
err:
    if (error) {
        *error = uvcErrorToNSError(res);
    }
    if (devh) {
        uvc_close(devh);
    }
    return NO;
}

- (void)stopStream {
    if (self.handle) {
        NSLog(@"Stopping stream...");
        uvc_stop_streaming(self.handle);
        uvc_close(self.handle);
        self.handle = NULL;
    }
}

@end
