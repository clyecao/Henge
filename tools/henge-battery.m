#import "henge-battery.h"

BOOL HengeParseBattery(NSString *header, unsigned long *revision, HengeBatteryReading *reading) {
    int percent, state, lowPower;
    unsigned long seq;
    char extra;
    if (!header || sscanf(header.UTF8String, "%lu %d %d %d %c", &seq, &percent, &state, &lowPower, &extra) != 4 ||
        percent < -1 || percent > 100 || state < HV_BATTERY_UNKNOWN || state > HV_BATTERY_FULL ||
        (lowPower != 0 && lowPower != 1)) return NO;
    *revision = seq;
    *reading = (HengeBatteryReading){percent, (HvBatteryState)state, lowPower != 0};
    return YES;
}

// Menu-bar points. AppKit rasterizes at the screen's backing scale and tints template images
// against the actual menu-bar background, which can differ from the desktop appearance.
NSImage *HengeBatteryImage(HengeBatteryReading reading) {
    NSColor *tint = nil;
    if (reading.percent >= 0) {
        if (reading.lowPower) tint = NSColor.systemYellowColor;
        else if (reading.percent <= 10 && reading.state == HV_BATTERY_UNPLUGGED) tint = NSColor.systemRedColor;
    }
    NSImage *image = [NSImage imageWithSize:NSMakeSize(26, 16) flipped:NO drawingHandler:^BOOL(NSRect bounds) {
        (void)bounds;
        NSColor *ink = tint ? NSColor.labelColor : NSColor.blackColor;
        [[ink colorWithAlphaComponent:0.55] set];
        NSBezierPath *shell = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0.75, 2.75, 21.5, 10.5)
                                                             xRadius:2.6 yRadius:2.6];
        shell.lineWidth = 1;
        [shell stroke];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(23.5, 6, 1.5, 4) xRadius:0.75 yRadius:0.75] fill];

        NSRect inside = NSMakeRect(2.25, 4.25, 18.5, 7.5);
        if (reading.percent > 0) {
            [NSGraphicsContext saveGraphicsState];
            [[NSBezierPath bezierPathWithRoundedRect:inside xRadius:1.25 yRadius:1.25] addClip];
            [(tint ?: ink) setFill];
            NSRectFill(NSMakeRect(inside.origin.x, inside.origin.y, inside.size.width * reading.percent / 100.0,
                                  inside.size.height));
            [NSGraphicsContext restoreGraphicsState];
        }

        NSBezierPath *mark = nil;
        if (reading.percent < 0) {
            mark = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(8.5, 7.25, 6, 1.5) xRadius:0.75 yRadius:0.75];
        } else if (reading.state == HV_BATTERY_CHARGING) {
            mark = [NSBezierPath bezierPath];
            [mark moveToPoint:NSMakePoint(13.7, 14.8)];
            [mark lineToPoint:NSMakePoint(7.6, 7.4)];
            [mark lineToPoint:NSMakePoint(11.3, 7.4)];
            [mark lineToPoint:NSMakePoint(9.6, 1.2)];
            [mark lineToPoint:NSMakePoint(16.1, 9.0)];
            [mark lineToPoint:NSMakePoint(12.1, 9.0)];
            [mark closePath];
        } else if (reading.state == HV_BATTERY_FULL) {
            mark = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(8.4, 6.1, 6.2, 4.4) xRadius:1.6 yRadius:1.6];
            [mark appendBezierPathWithRect:NSMakeRect(9.1, 10.3, 1.4, 2.6)];
            [mark appendBezierPathWithRect:NSMakeRect(12.4, 10.3, 1.4, 2.6)];
            [mark appendBezierPathWithRect:NSMakeRect(10.8, 3.0, 1.4, 3.3)];
        }
        if (mark) {
            // Cut a transparent keyline so the mark reads over both the fill and the empty part.
            [NSGraphicsContext saveGraphicsState];
            NSGraphicsContext.currentContext.compositingOperation = NSCompositingOperationClear;
            mark.lineWidth = 2;
            mark.lineJoinStyle = NSLineJoinStyleRound;
            [mark stroke];
            [NSGraphicsContext restoreGraphicsState];
            [ink setFill];
            [mark fill];
        }
        return YES;
    }];
    image.template = (tint == nil);
    return image;
}

@implementation HengeBatteryItem {
    NSStatusItem *_item;
    NSMenuItem *_level, *_source, *_mode, *_toggle;
    HengeBatteryReading _reading;
    BOOL _hasReading, _showPercentage;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults registerDefaults:@{@"ShowBatteryPercentage": @YES}];
        _showPercentage = [defaults boolForKey:@"ShowBatteryPercentage"];
        _item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
        _item.autosaveName = @"HengeHostBattery";
        _item.button.imageScaling = NSImageScaleNone;
        [_item.button setAccessibilityLabel:@"Device battery"];
        NSMenu *menu = [NSMenu new];
        _level = [menu addItemWithTitle:@"" action:NULL keyEquivalent:@""];
        _source = [menu addItemWithTitle:@"" action:NULL keyEquivalent:@""];
        _mode = [menu addItemWithTitle:@"Low Power Mode" action:NULL keyEquivalent:@""];
        [menu addItem:NSMenuItem.separatorItem];
        _toggle = [menu addItemWithTitle:@"Show Percentage" action:@selector(togglePercentage:) keyEquivalent:@""];
        _toggle.target = self;
        _item.menu = menu;
        [self update:(HengeBatteryReading){-1, HV_BATTERY_UNKNOWN, NO}];
    }
    return self;
}

- (void)render {
    NSString *percent = _reading.percent < 0 ? @"—" :
        [NSNumberFormatter localizedStringFromNumber:@(_reading.percent / 100.0) numberStyle:NSNumberFormatterPercentStyle];
    NSString *source = @"Power source unavailable";
    switch (_reading.state) {
        case HV_BATTERY_UNPLUGGED: source = @"Power Source: Battery"; break;
        case HV_BATTERY_CHARGING: source = @"Power Adapter · Charging"; break;
        case HV_BATTERY_FULL: source = @"Power Adapter · Fully Charged"; break;
        default: break;
    }
    _level.title = [NSString stringWithFormat:@"Battery   %@", percent];
    _source.title = source;
    _mode.hidden = !_reading.lowPower;
    _toggle.state = _showPercentage ? NSControlStateValueOn : NSControlStateValueOff;
    _item.button.title = _showPercentage ? percent : @"";
    _item.button.imagePosition = _showPercentage ? NSImageRight : NSImageOnly;
    _item.button.image = HengeBatteryImage(_reading);
    _item.button.toolTip = [NSString stringWithFormat:@"Device battery: %@ · %@", percent, source];
    [_item.button setAccessibilityValue:_item.button.toolTip];
}

- (void)togglePercentage:(id)sender {
    (void)sender;
    _showPercentage = !_showPercentage;
    [NSUserDefaults.standardUserDefaults setBool:_showPercentage forKey:@"ShowBatteryPercentage"];
    [self render];
}

- (void)update:(HengeBatteryReading)reading {
    if (_hasReading && _reading.percent == reading.percent && _reading.state == reading.state &&
        _reading.lowPower == reading.lowPower) return;
    _hasReading = YES;
    _reading = reading;
    [self render];
}
@end
