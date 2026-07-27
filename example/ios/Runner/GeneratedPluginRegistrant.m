//
//  Generated file. Do not edit.
//

// clang-format off

#import "GeneratedPluginRegistrant.h"

#if __has_include(<flutter_pdfview/FLTPDFViewFlutterPlugin.h>)
#import <flutter_pdfview/FLTPDFViewFlutterPlugin.h>
#else
@import flutter_pdfview;
#endif

#if __has_include(<integration_test/IntegrationTestPlugin.h>)
#import <integration_test/IntegrationTestPlugin.h>
#else
@import integration_test;
#endif

#if __has_include(<keyboard_height_plugin/KeyboardHeightPlugin.h>)
#import <keyboard_height_plugin/KeyboardHeightPlugin.h>
#else
@import keyboard_height_plugin;
#endif

#if __has_include(<native_device_orientation/NativeDeviceOrientationPlugin.h>)
#import <native_device_orientation/NativeDeviceOrientationPlugin.h>
#else
@import native_device_orientation;
#endif

#if __has_include(<pdf_annotations/PdfAnnotationsPlugin.h>)
#import <pdf_annotations/PdfAnnotationsPlugin.h>
#else
@import pdf_annotations;
#endif

@implementation GeneratedPluginRegistrant

+ (void)registerWithRegistry:(NSObject<FlutterPluginRegistry>*)registry {
  [FLTPDFViewFlutterPlugin registerWithRegistrar:[registry registrarForPlugin:@"FLTPDFViewFlutterPlugin"]];
  [IntegrationTestPlugin registerWithRegistrar:[registry registrarForPlugin:@"IntegrationTestPlugin"]];
  [KeyboardHeightPlugin registerWithRegistrar:[registry registrarForPlugin:@"KeyboardHeightPlugin"]];
  [NativeDeviceOrientationPlugin registerWithRegistrar:[registry registrarForPlugin:@"NativeDeviceOrientationPlugin"]];
  [PdfAnnotationsPlugin registerWithRegistrar:[registry registrarForPlugin:@"PdfAnnotationsPlugin"]];
}

@end
