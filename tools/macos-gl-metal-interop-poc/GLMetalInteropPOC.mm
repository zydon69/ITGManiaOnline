#define GL_SILENCE_DEPRECATION

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <OpenGL/CGLIOSurface.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl.h>

#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

namespace {

uint32_t FourCC(char a, char b, char c, char d) {
  return (static_cast<uint32_t>(a) << 24) |
         (static_cast<uint32_t>(b) << 16) |
         (static_cast<uint32_t>(c) << 8) |
         static_cast<uint32_t>(d);
}

const char* NameForGLError(GLenum value) {
  switch (value) {
    case GL_NO_ERROR:
      return "GL_NO_ERROR";
    case GL_INVALID_ENUM:
      return "GL_INVALID_ENUM";
    case GL_INVALID_VALUE:
      return "GL_INVALID_VALUE";
    case GL_INVALID_OPERATION:
      return "GL_INVALID_OPERATION";
    case GL_OUT_OF_MEMORY:
      return "GL_OUT_OF_MEMORY";
    default:
      return "GL_UNKNOWN";
  }
}

const char* NameForFBOStatus(GLenum value) {
  switch (value) {
    case GL_FRAMEBUFFER_COMPLETE_EXT:
      return "GL_FRAMEBUFFER_COMPLETE";
    case GL_FRAMEBUFFER_UNSUPPORTED_EXT:
      return "GL_FRAMEBUFFER_UNSUPPORTED";
    case GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT_EXT:
      return "GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT";
    case GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT_EXT:
      return "GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT";
    case GL_FRAMEBUFFER_INCOMPLETE_DIMENSIONS_EXT:
      return "GL_FRAMEBUFFER_INCOMPLETE_DIMENSIONS";
    case GL_FRAMEBUFFER_INCOMPLETE_FORMATS_EXT:
      return "GL_FRAMEBUFFER_INCOMPLETE_FORMATS";
    default:
      return "GL_FRAMEBUFFER_UNKNOWN";
  }
}

struct Options {
  int width = 1496;
  int height = 935;
  bool windowedContext = false;
};

Options ParseArgs(int argc, char** argv) {
  Options options;
  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    auto nextInt = [&](int* out) {
      if (i + 1 >= argc) {
        std::cerr << "Missing value after " << arg << "\n";
        std::exit(2);
      }
      *out = std::atoi(argv[++i]);
    };
    if (arg == "--width") {
      nextInt(&options.width);
    } else if (arg == "--height") {
      nextInt(&options.height);
    } else if (arg == "--windowed-context") {
      options.windowedContext = true;
    } else if (arg == "--help" || arg == "-h") {
      std::cout
          << "Usage: gl_metal_interop_poc [--width N] [--height N] "
             "[--windowed-context]\n";
      std::exit(0);
    } else {
      std::cerr << "Unknown argument: " << arg << "\n";
      std::exit(2);
    }
  }
  return options;
}

struct Attempt {
  GLenum target;
  GLenum internalFormat;
  GLenum format;
  GLenum type;
  const char* name;
};

void ClearGLErrors() {
  while (glGetError() != GL_NO_ERROR) {
  }
}

bool TryAttempt(
    CGLContextObj cgl, IOSurfaceRef surface, int width, int height,
    const Attempt& attempt) {
  ClearGLErrors();

  GLuint texture = 0;
  GLuint framebuffer = 0;
  GLuint depth = 0;

  glGenTextures(1, &texture);
  glBindTexture(attempt.target, texture);
  glTexParameteri(attempt.target, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(attempt.target, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glTexParameteri(attempt.target, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(attempt.target, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

  std::cout << "GL_METAL_INTEROP_ATTEMPT start name=" << attempt.name
            << " target=0x" << std::hex << attempt.target
            << " internal=0x" << attempt.internalFormat
            << " format=0x" << attempt.format
            << " type=0x" << attempt.type << std::dec << "\n";

  const CGLError cglError = CGLTexImageIOSurface2D(
      cgl, attempt.target, attempt.internalFormat, width, height,
      attempt.format, attempt.type, surface, 0);
  const GLenum imageGLError = glGetError();

  GLenum fboStatus = GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT_EXT;
  if (cglError == kCGLNoError && imageGLError == GL_NO_ERROR) {
    glGenFramebuffersEXT(1, &framebuffer);
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, framebuffer);
    glFramebufferTexture2DEXT(
        GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, attempt.target, texture,
        0);

    glGenRenderbuffersEXT(1, &depth);
    glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, depth);
    glRenderbufferStorageEXT(
        GL_RENDERBUFFER_EXT, GL_DEPTH_COMPONENT16, width, height);
    glFramebufferRenderbufferEXT(
        GL_FRAMEBUFFER_EXT, GL_DEPTH_ATTACHMENT_EXT, GL_RENDERBUFFER_EXT,
        depth);
    fboStatus = glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT);
  }

  const bool ok = cglError == kCGLNoError && imageGLError == GL_NO_ERROR &&
                  fboStatus == GL_FRAMEBUFFER_COMPLETE_EXT;
  std::cout << "GL_METAL_INTEROP_ATTEMPT result name=" << attempt.name
            << " ok=" << (ok ? 1 : 0)
            << " cgl_error=" << static_cast<int>(cglError)
            << " gl_error=" << NameForGLError(imageGLError) << "(0x"
            << std::hex << imageGLError << std::dec << ")"
            << " fbo_status=" << NameForFBOStatus(fboStatus) << "(0x"
            << std::hex << fboStatus << std::dec << ")\n";

  glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
  glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, 0);
  glBindTexture(attempt.target, 0);
  if (depth != 0) {
    glDeleteRenderbuffersEXT(1, &depth);
  }
  if (framebuffer != 0) {
    glDeleteFramebuffersEXT(1, &framebuffer);
  }
  if (texture != 0) {
    glDeleteTextures(1, &texture);
  }
  ClearGLErrors();
  return ok;
}

}  // namespace

int main(int argc, char** argv) {
  @autoreleasepool {
    const Options options = ParseArgs(argc, argv);
    if (options.width <= 0 || options.height <= 0) {
      std::cerr << "Invalid size " << options.width << "x" << options.height
                << "\n";
      return 2;
    }

    NSOpenGLPixelFormatAttribute attributes[] = {
        NSOpenGLPFANoRecovery,
        NSOpenGLPFAAccelerated,
        NSOpenGLPFAMinimumPolicy,
        NSOpenGLPFAColorSize,
        24,
        NSOpenGLPFAAlphaSize,
        8,
        NSOpenGLPFADepthSize,
        16,
        0};
    NSOpenGLPixelFormat* pixelFormat =
        [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
    if (pixelFormat == nil) {
      std::cerr << "Failed to create NSOpenGLPixelFormat\n";
      return 1;
    }

    NSOpenGLContext* context =
        [[NSOpenGLContext alloc] initWithFormat:pixelFormat shareContext:nil];
    [pixelFormat release];
    if (context == nil) {
        std::cerr << "Failed to create NSOpenGLContext\n";
      return 1;
    }

    NSWindow* window = nil;
    if (options.windowedContext) {
      [NSApplication sharedApplication];
      const NSRect rect =
          NSMakeRect(0, 0, options.width, options.height);
      window = [[NSWindow alloc]
          initWithContentRect:rect
                    styleMask:(NSWindowStyleMaskTitled |
                               NSWindowStyleMaskClosable |
                               NSWindowStyleMaskResizable)
                      backing:NSBackingStoreBuffered
                        defer:NO];
      [window setReleasedWhenClosed:NO];
      [window setTitle:@"GL/Metal Interop POC"];
      [context setView:[window contentView]];
      [context update];
      [window orderFrontRegardless];
    }
    [context makeCurrentContext];

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil) {
      std::cerr << "Metal is unavailable\n";
      [context release];
      return 1;
    }

    const int bytesPerPixel = 4;
    const int bytesPerRow = options.width * bytesPerPixel;
    NSDictionary* surfaceProperties = @{
      (NSString*)kIOSurfaceWidth: @(options.width),
      (NSString*)kIOSurfaceHeight: @(options.height),
      (NSString*)kIOSurfaceBytesPerElement: @(bytesPerPixel),
      (NSString*)kIOSurfaceBytesPerRow: @(bytesPerRow),
      (NSString*)kIOSurfaceAllocSize: @(bytesPerRow * options.height),
      (NSString*)kIOSurfacePixelFormat: @(FourCC('B', 'G', 'R', 'A'))
    };
    IOSurfaceRef surface =
        IOSurfaceCreate((CFDictionaryRef)surfaceProperties);
    if (surface == nullptr) {
      std::cerr << "IOSurfaceCreate failed\n";
      [context release];
      return 1;
    }

    MTLTextureDescriptor* descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
                                  MTLPixelFormatBGRA8Unorm
                                                     width:options.width
                                                    height:options.height
                                                 mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    id<MTLTexture> metalTexture =
        [device newTextureWithDescriptor:descriptor iosurface:surface plane:0];
    if (metalTexture == nil) {
      std::cerr << "Metal failed to import IOSurface\n";
      CFRelease(surface);
      [context release];
      return 1;
    }

    std::cout << "GL_METAL_INTEROP_START"
              << " size=" << options.width << "x" << options.height
              << " windowed_context=" << (options.windowedContext ? 1 : 0)
              << " gl_renderer=\"" << glGetString(GL_RENDERER) << "\""
              << " gl_version=\"" << glGetString(GL_VERSION) << "\""
              << " metal_device=\"" << [[device name] UTF8String] << "\"\n";

    const std::vector<Attempt> attempts = {
        {GL_TEXTURE_RECTANGLE_ARB, GL_RGBA, GL_BGRA,
         GL_UNSIGNED_INT_8_8_8_8_REV, "rect_rgba_bgra8888rev"},
        {GL_TEXTURE_RECTANGLE_ARB, GL_RGBA8, GL_BGRA,
         GL_UNSIGNED_INT_8_8_8_8_REV, "rect_rgba8_bgra8888rev"},
        {GL_TEXTURE_2D, GL_RGBA, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV,
         "2d_rgba_bgra8888rev"},
        {GL_TEXTURE_2D, GL_RGBA8, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV,
         "2d_rgba8_bgra8888rev"},
    };

    bool anyOk = false;
    for (const Attempt& attempt : attempts) {
      if (TryAttempt(
              [context CGLContextObj], surface, options.width, options.height,
              attempt)) {
        anyOk = true;
      }
    }

    std::cout << "GL_METAL_INTEROP_SUMMARY ok=" << (anyOk ? 1 : 0) << "\n";

    [metalTexture release];
    CFRelease(surface);
    [context clearDrawable];
    [context release];
    if (window != nil) {
      [window close];
      [window release];
    }
    return anyOk ? 0 : 1;
  }
}
