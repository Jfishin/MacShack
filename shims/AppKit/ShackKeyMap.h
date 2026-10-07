#import <UIKit/UIKit.h>
static inline unsigned short ShackMacKeyCode(UIKeyboardHIDUsage u) {
    switch (u) {
        case UIKeyboardHIDUsageKeyboardA: return 0; case UIKeyboardHIDUsageKeyboardS: return 1; case UIKeyboardHIDUsageKeyboardD: return 2;
        case UIKeyboardHIDUsageKeyboardF: return 3; case UIKeyboardHIDUsageKeyboardH: return 4; case UIKeyboardHIDUsageKeyboardG: return 5;
        case UIKeyboardHIDUsageKeyboardZ: return 6; case UIKeyboardHIDUsageKeyboardX: return 7; case UIKeyboardHIDUsageKeyboardC: return 8;
        case UIKeyboardHIDUsageKeyboardV: return 9; case UIKeyboardHIDUsageKeyboardB: return 11; case UIKeyboardHIDUsageKeyboardQ: return 12;
        case UIKeyboardHIDUsageKeyboardW: return 13; case UIKeyboardHIDUsageKeyboardE: return 14; case UIKeyboardHIDUsageKeyboardR: return 15;
        case UIKeyboardHIDUsageKeyboardY: return 16; case UIKeyboardHIDUsageKeyboardT: return 17; case UIKeyboardHIDUsageKeyboard1: return 18;
        case UIKeyboardHIDUsageKeyboard2: return 19; case UIKeyboardHIDUsageKeyboard3: return 20; case UIKeyboardHIDUsageKeyboard4: return 21;
        case UIKeyboardHIDUsageKeyboard6: return 22; case UIKeyboardHIDUsageKeyboard5: return 23; case UIKeyboardHIDUsageKeyboardEqualSign: return 24;
        case UIKeyboardHIDUsageKeyboard9: return 25; case UIKeyboardHIDUsageKeyboard7: return 26; case UIKeyboardHIDUsageKeyboardHyphen: return 27;
        case UIKeyboardHIDUsageKeyboard8: return 28; case UIKeyboardHIDUsageKeyboard0: return 29; case UIKeyboardHIDUsageKeyboardCloseBracket: return 30;
        case UIKeyboardHIDUsageKeyboardO: return 31; case UIKeyboardHIDUsageKeyboardU: return 32; case UIKeyboardHIDUsageKeyboardOpenBracket: return 33;
        case UIKeyboardHIDUsageKeyboardI: return 34; case UIKeyboardHIDUsageKeyboardP: return 35; case UIKeyboardHIDUsageKeyboardReturnOrEnter: return 36;
        case UIKeyboardHIDUsageKeyboardL: return 37; case UIKeyboardHIDUsageKeyboardJ: return 38; case UIKeyboardHIDUsageKeyboardQuote: return 39;
        case UIKeyboardHIDUsageKeyboardK: return 40; case UIKeyboardHIDUsageKeyboardSemicolon: return 41; case UIKeyboardHIDUsageKeyboardBackslash: return 42;
        case UIKeyboardHIDUsageKeyboardComma: return 43; case UIKeyboardHIDUsageKeyboardSlash: return 44; case UIKeyboardHIDUsageKeyboardN: return 45;
        case UIKeyboardHIDUsageKeyboardM: return 46; case UIKeyboardHIDUsageKeyboardPeriod: return 47; case UIKeyboardHIDUsageKeyboardTab: return 48;
        case UIKeyboardHIDUsageKeyboardSpacebar: return 49; case UIKeyboardHIDUsageKeyboardGraveAccentAndTilde: return 50;
        case UIKeyboardHIDUsageKeyboardDeleteOrBackspace: return 51; case UIKeyboardHIDUsageKeyboardEscape: return 53;
        case UIKeyboardHIDUsageKeyboardRightGUI: return 54; case UIKeyboardHIDUsageKeyboardLeftGUI: return 55; case UIKeyboardHIDUsageKeyboardLeftShift: return 56; case UIKeyboardHIDUsageKeyboardCapsLock: return 57;
        case UIKeyboardHIDUsageKeyboardLeftAlt: return 58; case UIKeyboardHIDUsageKeyboardLeftControl: return 59; case UIKeyboardHIDUsageKeyboardRightShift: return 60;
        case UIKeyboardHIDUsageKeyboardRightAlt: return 61; case UIKeyboardHIDUsageKeyboardRightControl: return 62;
        case UIKeyboardHIDUsageKeyboardF5: return 96; case UIKeyboardHIDUsageKeyboardF6: return 97; case UIKeyboardHIDUsageKeyboardF7: return 98;
        case UIKeyboardHIDUsageKeyboardF3: return 99; case UIKeyboardHIDUsageKeyboardF8: return 100; case UIKeyboardHIDUsageKeyboardF9: return 101;
        case UIKeyboardHIDUsageKeyboardF11: return 103; case UIKeyboardHIDUsageKeyboardF10: return 109; case UIKeyboardHIDUsageKeyboardF12: return 111;
        case UIKeyboardHIDUsageKeyboardF4: return 118; case UIKeyboardHIDUsageKeyboardF2: return 120; case UIKeyboardHIDUsageKeyboardF1: return 122;
        case UIKeyboardHIDUsageKeyboardLeftArrow: return 123; case UIKeyboardHIDUsageKeyboardRightArrow: return 124;
        case UIKeyboardHIDUsageKeyboardDownArrow: return 125; case UIKeyboardHIDUsageKeyboardUpArrow: return 126;
        default: return 0xFFFF;
    }
}
