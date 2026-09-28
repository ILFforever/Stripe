//
//  NowPlayingHelper.m
//  Stripe
//
//  Reports whether media is playing, system-wide. Since macOS 15.4 MediaRemote
//  only answers Apple-signed processes, so this library isn't loaded into Stripe:
//  NowPlaying.swift runs it inside /usr/bin/perl, which loads it and calls
//  stripe_now_playing_run().
//
//  Prints lines on stdout whenever something changes, and exits when stdin
//  closes (i.e. when Stripe quits):
//
//    playing 1                                   (or 0)
//    info {"title":"…","artist":"…","pid":123}   (the track, and the app playing it)
//

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>

typedef void (*RegisterFn)(dispatch_queue_t);
typedef void (*IsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*InfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*PIDFn)(dispatch_queue_t, void (^)(int));

__attribute__((visibility("default"))) void stripe_now_playing_run(void) {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    RegisterFn registerForNotifications = mr ? (RegisterFn)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications") : NULL;
    IsPlayingFn isPlaying = mr ? (IsPlayingFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") : NULL;
    InfoFn getInfo = mr ? (InfoFn)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo") : NULL;
    PIDFn getPID = mr ? (PIDFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationPID") : NULL;
    if (!isPlaying) {
        fprintf(stderr, "Stripe now playing: MediaRemote unavailable\n");
        exit(1);
    }

    dispatch_queue_t queue = dispatch_get_main_queue();
    __block int last = -1;
    __block NSString *lastInfo = nil;
    void (^report)(void) = ^{
        isPlaying(queue, ^(Boolean playing) {
            if (playing != last) {
                last = playing;
                printf("playing %d\n", playing ? 1 : 0);
                fflush(stdout);
            }
        });
        if (!getInfo) return;
        getInfo(queue, ^(NSDictionary *info) {
            void (^emit)(int) = ^(int pid) {
                NSDictionary *line = @{
                    @"title": [info[@"kMRMediaRemoteNowPlayingInfoTitle"] description] ?: @"",
                    @"artist": [info[@"kMRMediaRemoteNowPlayingInfoArtist"] description] ?: @"",
                    @"pid": @(pid),
                };
                NSData *json = [NSJSONSerialization dataWithJSONObject:line options:0 error:nil];
                NSString *text = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil;
                if (text && ![text isEqualToString:lastInfo]) {
                    lastInfo = text;
                    printf("info %s\n", text.UTF8String);
                    fflush(stdout);
                }
            };
            if (getPID) getPID(queue, ^(int pid) { emit(pid); });
            else emit(0);
        });
    };

    if (registerForNotifications) registerForNotifications(queue);
    for (NSString *name in @[@"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingInfoDidChangeNotification"]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil
                                                      usingBlock:^(NSNotification *note) { report(); }];
    }

    // In case a change arrives without a notification.
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), 3 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(timer, report);
    dispatch_resume(timer);

    // Stripe holds our stdin open; end of input means it quit.
    dispatch_source_t input = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, queue);
    dispatch_source_set_event_handler(input, ^{
        char buffer[64];
        if (read(STDIN_FILENO, buffer, sizeof buffer) <= 0) exit(0);
    });
    dispatch_resume(input);

    dispatch_main();
}
