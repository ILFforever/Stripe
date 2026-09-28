//
//  TouchBarSupport.h
//  MTMR
//
//  Created by Anton Palgunov on 08/04/2018.
//  Copyright © 2018 Anton Palgunov. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface MediaKeys : NSObject

+ (void)HIDPostAuxKey:(UInt8)keyCode;
/// Stripe: shows the system's volume (image 3, muted 4) or brightness (1)
/// overlay at `level` (0...1), as the keys do, without changing anything.
+ (void)showLevelOverlay:(long long)image level:(double)level;

@end
