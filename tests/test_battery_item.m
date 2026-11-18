// Exercise the same AppKit artwork the status button uses without depending on a logged-in menu bar.
#import "henge-battery.h"
#include <assert.h>
#include <stdio.h>

static NSBitmapImageRep *render(HengeBatteryReading reading, int scale) {
    NSImage *image = HengeBatteryImage(reading);
    NSSize size = image.size;
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:(NSInteger)size.width * scale pixelsHigh:(NSInteger)size.height * scale
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
        bytesPerRow:0 bitsPerPixel:32];
    bitmap.size = size;
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    [image drawInRect:NSMakeRect(0, 0, size.width, size.height) fromRect:NSZeroRect
            operation:NSCompositingOperationCopy fraction:1];
    [NSGraphicsContext restoreGraphicsState];
    return bitmap;
}

int main(void) {
    @autoreleasepool {
        unsigned long seq = 0;
        HengeBatteryReading reading = {0};
        assert(HengeParseBattery(@"2 -1 0 0", &seq, &reading));
        assert(seq == 2 && reading.percent == -1);
        assert(HengeParseBattery(@"15 76 2 1", &seq, &reading));
        assert(seq == 15 && reading.percent == 76 && reading.state == HV_BATTERY_CHARGING && reading.lowPower);
        for (NSString *bad in @[@"", @"1 60", @"1 101 2 0", @"1 -2 1 0", @"1 50 4 0", @"1 60 2 3", @"1 0 0 0 x"]) {
            assert(!HengeParseBattery(bad, &seq, &reading));
        }
        for (int scale = 1; scale <= 2; scale++) {
            NSBitmapImageRep *half = render((HengeBatteryReading){50, HV_BATTERY_UNPLUGGED, NO}, scale);
            assert([half colorAtX:5 * scale y:8 * scale].alphaComponent > 0.8);
            assert([half colorAtX:18 * scale y:8 * scale].alphaComponent < 0.1);
            NSBitmapImageRep *threeQuarters = render((HengeBatteryReading){75, HV_BATTERY_UNPLUGGED, NO}, scale);
            assert([threeQuarters colorAtX:14 * scale y:8 * scale].alphaComponent > 0.8);
            for (NSAppearanceName name in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
                [[NSAppearance appearanceNamed:name] performAsCurrentDrawingAppearance:^{
                    NSBitmapImageRep *low = render((HengeBatteryReading){50, HV_BATTERY_UNPLUGGED, YES}, scale);
                    NSColor *yellow = [[low colorAtX:5 * scale y:8 * scale] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                    assert(yellow.redComponent > yellow.blueComponent && yellow.greenComponent > yellow.blueComponent);
                }];
            }
            NSData *charging = render((HengeBatteryReading){100, HV_BATTERY_CHARGING, NO}, scale).TIFFRepresentation;
            NSData *full = render((HengeBatteryReading){100, HV_BATTERY_FULL, NO}, scale).TIFFRepresentation;
            assert(charging && full && ![charging isEqualToData:full]);
        }
        puts("Battery menu: wire readings and AppKit artwork at 1x/2x in light and dark passed");
    }
    return 0;
}
