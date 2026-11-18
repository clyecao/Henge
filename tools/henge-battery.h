#import <AppKit/AppKit.h>
#import "share.h"

typedef struct {
    int percent; /* -1 when the host has no reading */
    HvBatteryState state;
    BOOL lowPower;
} HengeBatteryReading;

BOOL HengeParseBattery(NSString *header, unsigned long *revision, HengeBatteryReading *reading);
NSImage *HengeBatteryImage(HengeBatteryReading reading);

@interface HengeBatteryItem : NSObject
- (void)update:(HengeBatteryReading)reading;
@end
