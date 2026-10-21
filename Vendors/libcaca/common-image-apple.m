#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "caca.h"
#include "common-image.h"

static size_t image_property_dimension(CFDictionaryRef properties, CFStringRef key)
{
    CFNumberRef number;
    int64_t value = 0;

    if(!properties)
        return 0;
    number = (CFNumberRef)CFDictionaryGetValue(properties, key);
    if(!number || CFGetTypeID(number) != CFNumberGetTypeID()
        || !CFNumberGetValue(number, kCFNumberSInt64Type, &value) || value <= 0)
        return 0;
    return (uint64_t)value > SIZE_MAX ? 0 : (size_t)value;
}

static CGImageRef create_oriented_image(CGImageSourceRef source)
{
    CFDictionaryRef properties;
    CFMutableDictionaryRef options;
    CFNumberRef maximum_pixel_size;
    CGImageRef image = NULL;
    size_t width, height, maximum_dimension;
    int64_t maximum_dimension_value;

    properties = CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
    width = image_property_dimension(properties, kCGImagePropertyPixelWidth);
    height = image_property_dimension(properties, kCGImagePropertyPixelHeight);
    if(properties)
        CFRelease(properties);

    maximum_dimension = width > height ? width : height;
    if(maximum_dimension > 0 && maximum_dimension <= INT64_MAX)
    {
        maximum_dimension_value = (int64_t)maximum_dimension;
        maximum_pixel_size = CFNumberCreate(kCFAllocatorDefault,
                                             kCFNumberSInt64Type,
                                             &maximum_dimension_value);
        options = CFDictionaryCreateMutable(kCFAllocatorDefault, 4,
                                             &kCFTypeDictionaryKeyCallBacks,
                                             &kCFTypeDictionaryValueCallBacks);
        if(maximum_pixel_size && options)
        {
            CFDictionarySetValue(options,
                                 kCGImageSourceCreateThumbnailFromImageAlways,
                                 kCFBooleanTrue);
            CFDictionarySetValue(options,
                                 kCGImageSourceCreateThumbnailWithTransform,
                                 kCFBooleanTrue);
            CFDictionarySetValue(options,
                                 kCGImageSourceShouldCacheImmediately,
                                 kCFBooleanTrue);
            CFDictionarySetValue(options, kCGImageSourceThumbnailMaxPixelSize,
                                 maximum_pixel_size);
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options);
        }
        if(options)
            CFRelease(options);
        if(maximum_pixel_size)
            CFRelease(maximum_pixel_size);
    }

    if(!image)
        image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    return image;
}

struct image *load_image(char const *name)
{
    struct image *result = NULL;

    if(!name)
        return NULL;

    @autoreleasepool
    {
        NSString *path = [NSString stringWithUTF8String:name];
        NSURL *url;
        CGImageSourceRef source;
        CGImageRef decoded_image;
        CGColorSpaceRef color_space;
        CGContextRef context;
        uint8_t *pixels;
        size_t width, height, row_bytes, byte_count, offset;

        if(!path)
            return NULL;
        url = [NSURL fileURLWithPath:path];
        source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
        if(!source)
            return NULL;

        decoded_image = create_oriented_image(source);
        CFRelease(source);
        if(!decoded_image)
            return NULL;

        width = CGImageGetWidth(decoded_image);
        height = CGImageGetHeight(decoded_image);
        if(!width || !height || width > INT_MAX || height > INT_MAX
            || width > INT_MAX / 4 || height > SIZE_MAX / (width * 4))
        {
            CGImageRelease(decoded_image);
            return NULL;
        }

        row_bytes = width * 4;
        byte_count = row_bytes * height;
        pixels = calloc(1, byte_count);
        color_space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        context = pixels && color_space
            ? CGBitmapContextCreate(pixels, width, height, 8, row_bytes,
                                    color_space,
                                    kCGBitmapByteOrder32Little
                                        | kCGImageAlphaPremultipliedFirst)
            : NULL;
        if(color_space)
            CGColorSpaceRelease(color_space);
        if(!context)
        {
            free(pixels);
            CGImageRelease(decoded_image);
            return NULL;
        }

        CGContextSetBlendMode(context, kCGBlendModeCopy);
        CGContextTranslateCTM(context, 0, (CGFloat)height);
        CGContextScaleCTM(context, 1, -1);
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), decoded_image);
        CGContextRelease(context);
        CGImageRelease(decoded_image);

        /* The bitmap context stores premultiplied BGRA. libcaca expects the
         * channels described by its masks to contain straight-alpha values. */
        for(offset = 0; offset < byte_count; offset += 4)
        {
            uint8_t alpha = pixels[offset + 3];
            int channel;

            if(alpha == 0)
            {
                pixels[offset] = pixels[offset + 1] = pixels[offset + 2] = 0;
            }
            else if(alpha != UINT8_MAX)
            {
                for(channel = 0; channel < 3; ++channel)
                {
                    unsigned int value =
                        (pixels[offset + channel] * UINT8_MAX + alpha / 2) / alpha;
                    pixels[offset + channel] =
                        value > UINT8_MAX ? UINT8_MAX : (uint8_t)value;
                }
            }
        }

        result = calloc(1, sizeof(*result));
        if(!result)
        {
            free(pixels);
            return NULL;
        }
        result->pixels = (char *)pixels;
        result->w = width;
        result->h = height;
        result->dither = caca_create_dither(32, (int)width, (int)height,
                                              (int)row_bytes,
                                              0x00ff0000, 0x0000ff00,
                                              0x000000ff, 0xff000000);
        if(!result->dither)
        {
            free(result->pixels);
            free(result);
            return NULL;
        }
    }
    return result;
}

void unload_image(struct image *image)
{
    if(!image)
        return;
    caca_free_dither(image->dither);
    free(image->pixels);
    free(image);
}
