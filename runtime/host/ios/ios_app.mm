// The iOS / iPadOS app's start (host/main.cpp calls ps2_ios_arguments first, on the main thread, after the app has launched):
// the command line a PC run would get, made from the app's own folders.
//
// - The bundle's game/ folder (PS2_IOS_GAME_DIR at build time) holds core.elf and args.txt: the arguments the game gets after its
//   name, one per line (the launcher's arguments for Splinter Cell Chaos Theory, for example).
// - The disc: a disc image (any .iso, or a .sparse image) the player copies into the app's Documents folder wins; else the file
//   PS2_IOS_DISC_FILE of the Apple-hosted Background Assets pack PS2_IOS_ASSET_PACK, which the system downloads with the app.
// - Documents (the Files app, "On My iPhone") holds what the app keeps: the memory card (card1.ps2), the quick saves, keys.ini,
//   log.txt (stdout and stderr of the last run; log-prev.txt the run before) and an optional env.txt of KEY=VALUE lines that set
//   environment variables (PS2_SCALE=2, for example) before anything reads them.
// Compiled with ARC.
#import <BackgroundAssets/BackgroundAssets.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <TargetConditionals.h>

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <unistd.h>
#include <vector>

#ifndef PS2_IOS_ASSET_PACK
#define PS2_IOS_ASSET_PACK ""
#endif
#ifndef PS2_IOS_DISC_FILE
#define PS2_IOS_DISC_FILE ""
#endif

namespace fs = std::filesystem;

namespace {

fs::path documents() {
    NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (dirs.count) return fs::path(dirs.firstObject.UTF8String);
    const char *home = std::getenv("HOME");
    return fs::path(home ? home : ".") / "Documents";
}

fs::path bundle_game() { return fs::path(NSBundle.mainBundle.bundlePath.UTF8String) / "game"; }

void load_env(const fs::path &file) {
    std::ifstream in(file);
    std::string line;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty() || line[0] == '#') continue;
        const std::size_t eq = line.find('=');
        if (eq == std::string::npos || eq == 0) continue;
        setenv(line.substr(0, eq).c_str(), line.substr(eq + 1).c_str(), 1);
        std::fprintf(stderr, "[ios] env.txt: %s\n", line.c_str());
    }
}

// waits for a completion handler while the main run loop keeps turning (the system delivers some handlers on the main queue)
bool wait_for(dispatch_semaphore_t done, double seconds) {
    const CFAbsoluteTime until = CFAbsoluteTimeGetCurrent() + seconds;
    while (dispatch_semaphore_wait(done, DISPATCH_TIME_NOW) != 0) {
        if (CFAbsoluteTimeGetCurrent() >= until) return false;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    }
    return true;
}

// A plain screen with one line of text, shown while the app waits for its disc before the game (and SDL's window) starts.
UIWindow *g_wait_window = nil;
UILabel *g_wait_label = nil;
void show_wait(NSString *text) {
    if (!g_wait_window) {
        UIWindowScene *scene = nil;
        for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes)
            if ([candidate isKindOfClass:UIWindowScene.class]) scene = (UIWindowScene *)candidate;
        g_wait_window = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        UIViewController *controller = [UIViewController new];
        controller.view.backgroundColor = UIColor.blackColor;
        g_wait_label = [[UILabel alloc] initWithFrame:CGRectInset(controller.view.bounds, 48, 48)];
        g_wait_label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        g_wait_label.textColor = [UIColor colorWithRed:0.55 green:0.95 blue:0.6 alpha:1.0];
        g_wait_label.textAlignment = NSTextAlignmentCenter;
        g_wait_label.numberOfLines = 0;
        g_wait_label.font = [UIFont systemFontOfSize:20 weight:UIFontWeightMedium];
        [controller.view addSubview:g_wait_label];
        g_wait_window.rootViewController = controller;
        [g_wait_window makeKeyAndVisible];
    }
    g_wait_label.text = text;
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
}
void hide_wait() {
    if (!g_wait_window) return;
    g_wait_window.hidden = YES;
    g_wait_window = nil;
    g_wait_label = nil;
}

// The path of `file` in Apple-hosted asset pack `pack` (iOS 26), once the pack is on the device: a path the app can open, or
// /dev/fd/<n> for the descriptor the system opens for it (the runtime seeks before every read, so a shared offset is fine).
bool asset_pack_file(const char *pack, const char *file, std::string &path) {
#if TARGET_OS_SIMULATOR
    (void)pack;
    (void)file;
    (void)path;
    std::fprintf(stderr, "[ios-assets] no asset packs in the simulator\n");
    return false;
#else
    if (!*pack || !*file) return false;
    if (![[NSBundle.mainBundle objectForInfoDictionaryKey:@"BAUsesAppleHosting"] boolValue]) {
        std::fprintf(stderr, "[ios-assets] this build has no asset packs (no Background Assets keys in Info.plist)\n");
        return false;
    }
    if (@available(iOS 26.0, *)) {
        BAAssetPackManager *manager = [BAAssetPackManager sharedManager];
        NSString *identifier = [NSString stringWithUTF8String:pack];
        __block BAAssetPack *found = nil;
        __block NSError *failure = nil;
        dispatch_semaphore_t got = dispatch_semaphore_create(0);
        [manager getAssetPackWithIdentifier:identifier
                          completionHandler:^(BAAssetPack *assetPack, NSError *error) {
                              found = assetPack;
                              failure = error;
                              dispatch_semaphore_signal(got);
                          }];
        if (!wait_for(got, 30.0) || !found) {
            std::fprintf(stderr, "[ios-assets] asset pack %s unavailable: %s\n", pack, failure ? failure.localizedDescription.UTF8String : "no answer");
            return false;
        }
        std::fprintf(stderr, "[ios-assets] %s version %ld, %lld bytes\n", pack, static_cast<long>(found.version), static_cast<long long>(found.downloadSize));
        // returns at once for a pack on the device; a missing one is downloaded now (the essential pack normally came with the app)
        show_wait(@"Getting the game's disc ready.\nIf it is still downloading, keep the app open: the game starts by itself when it is done.");
        __block NSError *availability = nil;
        dispatch_semaphore_t ready = dispatch_semaphore_create(0);
        [manager ensureLocalAvailabilityOfAssetPack:found
                                  completionHandler:^(NSError *error) {
                                      availability = error;
                                      dispatch_semaphore_signal(ready);
                                  }];
        if (!wait_for(ready, 3600.0)) {
            std::fprintf(stderr, "[ios-assets] %s is still downloading\n", pack);
            return false;
        }
        if (availability) {
            std::fprintf(stderr, "[ios-assets] %s: %s\n", pack, availability.localizedDescription.UTF8String);
            return false;
        }
        NSString *name = [NSString stringWithUTF8String:file];
        NSError *url_error = nil;
        NSURL *url = [manager URLForPath:name error:&url_error];
        if (url && url.fileURL) {
            if (std::FILE *probe = std::fopen(url.path.UTF8String, "rb")) {
                std::fclose(probe);
                path = url.path.UTF8String;
                std::fprintf(stderr, "[ios-assets] %s at %s\n", file, path.c_str());
                return true;
            }
            std::fprintf(stderr, "[ios-assets] %s not readable by path (%s): %s\n", file, std::strerror(errno), url.path.UTF8String);
        } else {
            std::fprintf(stderr, "[ios-assets] %s: no URL (%s)\n", file, url_error ? url_error.localizedDescription.UTF8String : "none");
        }
        NSError *fd_error = nil;
        const int fd = [manager fileDescriptorForPath:name searchingInAssetPackWithIdentifier:identifier error:&fd_error];
        if (fd < 0) {
            std::fprintf(stderr, "[ios-assets] %s: no descriptor (%s)\n", file, fd_error ? fd_error.localizedDescription.UTF8String : "none");
            return false;
        }
        path = "/dev/fd/" + std::to_string(fd);
        std::fprintf(stderr, "[ios-assets] %s through descriptor %d\n", file, fd);
        return true;
    }
    std::fprintf(stderr, "[ios-assets] asset packs need iOS 26\n");
    return false;
#endif
}

std::string lower(std::string s) {
    for (char &c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

}  // namespace

// The arguments of a PC run (ps2run core.elf --disc ... --window ...), for main().
std::vector<std::string> ps2_ios_arguments() {
    const fs::path docs = documents();
    std::error_code ec;
    fs::create_directories(docs, ec);

    // the log: the run before is kept; stdout and stderr share one descriptor (two would overwrite each other)
    const fs::path log = docs / "log.txt";
    if (fs::exists(log, ec)) fs::rename(log, docs / "log-prev.txt", ec);
    if (std::freopen(log.c_str(), "w", stdout)) {
        std::setvbuf(stdout, nullptr, _IOLBF, 0);
        dup2(fileno(stdout), fileno(stderr));
        std::setvbuf(stderr, nullptr, _IONBF, 0);
    }
    chdir(docs.c_str());
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    std::fprintf(stderr, "[ios] %s %s (%s), %s %s\n", [info[@"CFBundleName"] UTF8String] ?: "app", [info[@"CFBundleShortVersionString"] UTF8String] ?: "",
                 [info[@"CFBundleVersion"] UTF8String] ?: "", NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String,
                 NSProcessInfo.processInfo.isiOSAppOnMac ? "(on a Mac)" : "");

    // nothing is compiled on the phone, the pad is not recorded to a file, the log is this file only; the console's language English
    setenv("PS2_LANGUAGE", "1", 0);
    setenv("PS2_VU_LIVE", "0", 0);
    setenv("PS2_EE_LIVE", "0", 0);
    setenv("PS2_RECORD", "0", 0);
    setenv("PS2_NO_LOG_COPY", "1", 0);
    load_env(docs / "env.txt");

    const fs::path game = bundle_game();
    std::vector<std::string> args{"ps2run", (game / "core.elf").string()};

    std::string disc;
    for (const auto &entry : fs::directory_iterator(docs, ec)) {
        const std::string ext = lower(entry.path().extension().string());
        if (entry.is_regular_file(ec) && (ext == ".iso" || ext == ".sparse")) {
            disc = entry.path().string();
            std::fprintf(stderr, "[ios] the disc from Documents: %s\n", disc.c_str());
            break;
        }
    }
    // no disc yet: say so and look again every 15 s (the asset pack still downloading, or the player copying a disc image in)
    for (int attempt = 0; disc.empty(); ++attempt) {
        if (asset_pack_file(PS2_IOS_ASSET_PACK, PS2_IOS_DISC_FILE, disc)) break;
        std::fprintf(stderr, "[ios] no disc: neither the app's asset pack nor a .iso in Documents (Files app, On My iPhone); attempt %d\n", attempt + 1);
#if TARGET_OS_SIMULATOR
        break;  // (the simulator check also starts the game without a disc)
#endif
        show_wait(@"The game's disc is not on this iPhone yet.\n\nIt downloads with the app from TestFlight: keep the app open and online.\nOr copy a disc image (.iso) into the app's folder in the Files app.");
        const CFAbsoluteTime until = CFAbsoluteTimeGetCurrent() + 15.0;
        while (CFAbsoluteTimeGetCurrent() < until) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, true);
        for (const auto &entry : fs::directory_iterator(docs, ec)) {
            const std::string ext = lower(entry.path().extension().string());
            if (entry.is_regular_file(ec) && (ext == ".iso" || ext == ".sparse")) disc = entry.path().string();
        }
    }
    hide_wait();
    if (!disc.empty()) {
        args.push_back("--disc");
        args.push_back(disc);
    }
    args.insert(args.end(), {"--window", "--game-dir", game.string(), "--memcard", (docs / "card1.ps2").string(), "--quick-dir", docs.string()});
    std::ifstream guest(game / "args.txt");
    std::string line;
    while (std::getline(guest, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty()) continue;
        args.push_back("--arg");
        args.push_back(line);
    }
    std::string said;
    for (const std::string &a : args) said += " " + a;
    std::fprintf(stderr, "[ios] command line:%s\n", said.c_str());
    return args;
}
