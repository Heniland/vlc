/*****************************************************************************
 * intf.m: MacOS X interface module
 *****************************************************************************
 * Copyright (C) 2002-2013 VLC authors and VideoLAN
 * $Id$
 *
 * Authors: Jon Lech Johansen <jon-vl@nanocrew.net>
 *          Derk-Jan Hartman <hartman at videolan.org>
 *          Felix Paul Kühne <fkuehne at videolan dot org>
 *          Pierre d'Herbemont <pdherbemont # videolan org>
 *          David Fuhrmann <david dot fuhrmann at googlemail dot com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
 *****************************************************************************/

/*****************************************************************************
 * Preamble
 *****************************************************************************/
#ifdef HAVE_CONFIG_H
# include "config.h"
#endif

#import "intf.h"

#include <stdlib.h>                                      /* malloc(), free() */
#include <string.h>
#include <vlc_common.h>
#include <vlc_atomic.h>
#include <vlc_keys.h>
#include <vlc_dialog.h>
#include <vlc_url.h>
#include <vlc_modules.h>
#include <vlc_plugin.h>
#include <vlc_vout_display.h>
#include <unistd.h> /* execl() */

#import "CompatibilityFixes.h"
#import "InputManager.h"
#import "MainMenu.h"
#import "VideoView.h"
#import "prefs.h"
#import "playlist.h"
#import "playlistinfo.h"
#import "controls.h"
#import "open.h"
#import "wizard.h"
#import "bookmarks.h"
#import "coredialogs.h"
#import "AppleRemote.h"
#import "eyetv.h"
#import "simple_prefs.h"
#import "CoreInteraction.h"
#import "TrackSynchronization.h"
#import "ExtensionsManager.h"
#import "BWQuincyManager.h"
#import "ControlsBar.h"

#import "VideoEffects.h"
#import "AudioEffects.h"

#ifdef HAVE_SPARKLE
#import <Sparkle/Sparkle.h>                 /* we're the update delegate */
#endif

/*****************************************************************************
 * Local prototypes.
 *****************************************************************************/

static void updateProgressPanel (void *, const char *, float);
static bool checkProgressPanel (void *);
static void destroyProgressPanel (void *);

static int PLItemUpdated(vlc_object_t *, const char *,
                         vlc_value_t, vlc_value_t, void *);

static int PlaybackModeUpdated(vlc_object_t *, const char *,
                               vlc_value_t, vlc_value_t, void *);
static int VolumeUpdated(vlc_object_t *, const char *,
                         vlc_value_t, vlc_value_t, void *);
static int BossCallback(vlc_object_t *, const char *,
                         vlc_value_t, vlc_value_t, void *);

#pragma mark -
#pragma mark VLC Interface Object Callbacks

static atomic_bool b_intf_starting = ATOMIC_VAR_INIT(false);

static NSLock * o_vout_provider_lock = nil;


/*****************************************************************************
 * OpenIntf: initialize interface
 *****************************************************************************/
int OpenIntf (vlc_object_t *p_this)
{
    NSAutoreleasePool *o_pool = [[NSAutoreleasePool alloc] init];
    [VLCApplication sharedApplication];

    intf_thread_t *p_intf = (intf_thread_t*) p_this;
    msg_Dbg(p_intf, "Starting macosx interface");

    [VLCApplication sharedApplication];

    o_vout_provider_lock = [[NSLock alloc] init];

    [[VLCMain sharedInstance] setIntf: p_intf];

    [NSBundle loadNibNamed: @"MainMenu" owner: NSApp];

    [NSBundle loadNibNamed:@"MainWindow" owner: [VLCMain sharedInstance]];
    [[[VLCMain sharedInstance] mainWindow] makeKeyAndOrderFront:nil];

    atomic_store(&b_intf_starting, true);

    [o_pool release];
    return VLC_SUCCESS;
}

void CloseIntf (vlc_object_t *p_this)
{
    NSAutoreleasePool * o_pool = [[NSAutoreleasePool alloc] init];

    msg_Dbg(p_this, "Closing macosx interface");
    [[VLCMain sharedInstance] applicationWillTerminate:nil];
    [o_vout_provider_lock release];
    o_vout_provider_lock = nil;
    [o_pool release];
}

static int WindowControl(vout_window_t *, int i_query, va_list);

int WindowOpen(vout_window_t *p_wnd, const vout_window_cfg_t *cfg)
{
    if (cfg->type != VOUT_WINDOW_TYPE_INVALID
     && cfg->type != VOUT_WINDOW_TYPE_NSOBJECT)
        return VLC_EGENERIC;

    msg_Dbg(p_wnd, "Opening video window");

    if (!atomic_load(&b_intf_starting)) {
        msg_Err(p_wnd, "Cannot create vout as Mac OS X interface was not found");
        return VLC_EGENERIC;
    }

    NSAutoreleasePool *o_pool = [[NSAutoreleasePool alloc] init];

    NSRect proposedVideoViewPosition = NSMakeRect(cfg->x, cfg->y, cfg->width, cfg->height);

    [o_vout_provider_lock lock];
    VLCVoutWindowController *o_vout_controller = [[VLCMain sharedInstance] voutController];
    if (!o_vout_controller) {
        [o_vout_provider_lock unlock];
        [o_pool release];
        return VLC_EGENERIC;
    }

    SEL sel = @selector(setupVoutForWindow:withProposedVideoViewPosition:);
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:[o_vout_controller methodSignatureForSelector:sel]];
    [inv setTarget:o_vout_controller];
    [inv setSelector:sel];
    [inv setArgument:&p_wnd atIndex:2]; // starting at 2!
    [inv setArgument:&proposedVideoViewPosition atIndex:3];

    [inv performSelectorOnMainThread:@selector(invoke) withObject:nil
                       waitUntilDone:YES];

    VLCVoutView *videoView = nil;
    [inv getReturnValue:&videoView];

    // this method is not supposed to fail
    assert(videoView != nil);

    msg_Dbg(VLCIntf, "returning videoview with proposed position x=%i, y=%i, width=%i, height=%i", cfg->x, cfg->y, cfg->width, cfg->height);
    p_wnd->handle.nsobject = videoView;

    [o_vout_provider_lock unlock];

    p_wnd->type = VOUT_WINDOW_TYPE_NSOBJECT;
    p_wnd->control = WindowControl;

    [o_pool release];
    return VLC_SUCCESS;
}

static int WindowControl(vout_window_t *p_wnd, int i_query, va_list args)
{
    NSAutoreleasePool *o_pool = [[NSAutoreleasePool alloc] init];

    [o_vout_provider_lock lock];
    VLCVoutWindowController *o_vout_controller = [[VLCMain sharedInstance] voutController];
    if (!o_vout_controller) {
        [o_vout_provider_lock unlock];
        [o_pool release];
        return VLC_EGENERIC;
    }

    switch(i_query) {
        case VOUT_WINDOW_SET_STATE:
        {
            unsigned i_state = va_arg(args, unsigned);

            if (i_state & VOUT_WINDOW_STATE_BELOW)
            {
                msg_Dbg(p_wnd, "Ignore change to VOUT_WINDOW_STATE_BELOW");
                goto out;
            }

            NSInteger i_cooca_level = NSNormalWindowLevel;
            if (i_state & VOUT_WINDOW_STATE_ABOVE)
                i_cooca_level = NSStatusWindowLevel;

            SEL sel = @selector(setWindowLevel:forWindow:);
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:[o_vout_controller methodSignatureForSelector:sel]];
            [inv setTarget:o_vout_controller];
            [inv setSelector:sel];
            [inv setArgument:&i_cooca_level atIndex:2]; // starting at 2!
            [inv setArgument:&p_wnd atIndex:3];
            [inv performSelectorOnMainThread:@selector(invoke) withObject:nil
                               waitUntilDone:NO];

            break;
        }
        case VOUT_WINDOW_SET_SIZE:
        {
            unsigned int i_width  = va_arg(args, unsigned int);
            unsigned int i_height = va_arg(args, unsigned int);

            NSSize newSize = NSMakeSize(i_width, i_height);
            SEL sel = @selector(setNativeVideoSize:forWindow:);
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:[o_vout_controller methodSignatureForSelector:sel]];
            [inv setTarget:o_vout_controller];
            [inv setSelector:sel];
            [inv setArgument:&newSize atIndex:2]; // starting at 2!
            [inv setArgument:&p_wnd atIndex:3];
            [inv performSelectorOnMainThread:@selector(invoke) withObject:nil
                               waitUntilDone:NO];

            break;
        }
        case VOUT_WINDOW_SET_FULLSCREEN:
        {
            if (var_InheritBool(VLCIntf, "video-wallpaper")) {
                msg_Dbg(p_wnd, "Ignore fullscreen event as video-wallpaper is on");
                goto out;
            }

            int i_full = va_arg(args, int);
            BOOL b_animation = YES;

            SEL sel = @selector(setFullscreen:forWindow:withAnimation:);
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:[o_vout_controller methodSignatureForSelector:sel]];
            [inv setTarget:o_vout_controller];
            [inv setSelector:sel];
            [inv setArgument:&i_full atIndex:2]; // starting at 2!
            [inv setArgument:&p_wnd atIndex:3];
            [inv setArgument:&b_animation atIndex:4];
            [inv performSelectorOnMainThread:@selector(invoke) withObject:nil
                               waitUntilDone:NO];

            break;
        }
        default:
        {
            msg_Warn(p_wnd, "unsupported control query");
            [o_vout_provider_lock unlock];
            [o_pool release];
            return VLC_EGENERIC;
        }
    }

out:
    [o_vout_provider_lock unlock];
    [o_pool release];
    return VLC_SUCCESS;
}

void WindowClose(vout_window_t *p_wnd)
{
    NSAutoreleasePool *o_pool = [[NSAutoreleasePool alloc] init];

    [o_vout_provider_lock lock];
    VLCVoutWindowController *o_vout_controller = [[VLCMain sharedInstance] voutController];
    if (!o_vout_controller) {
        [o_vout_provider_lock unlock];
        [o_pool release];
        return;
    }

    [o_vout_controller performSelectorOnMainThread:@selector(removeVoutforDisplay:) withObject:[NSValue valueWithPointer:p_wnd] waitUntilDone:NO];
    [o_vout_provider_lock unlock];

    [o_pool release];
}

#pragma mark -
#pragma mark Variables Callback

/**
 * Callback for item-change variable. Is triggered after update of duration or metadata.
 */
static int PLItemUpdated(vlc_object_t *p_this, const char *psz_var,
                         vlc_value_t oldval, vlc_value_t new_val, void *param)
{
    NSAutoreleasePool * o_pool = [[NSAutoreleasePool alloc] init];

    [[VLCMain sharedInstance] performSelectorOnMainThread:@selector(plItemUpdated) withObject:nil waitUntilDone:NO];

    [o_pool release];
    return VLC_SUCCESS;
}

static int PLItemAppended(vlc_object_t *p_this, const char *psz_var,
                           vlc_value_t oldval, vlc_value_t new_val, void *param)
{
    NSAutoreleasePool * o_pool = [[NSAutoreleasePool alloc] init];

    playlist_add_t *p_add = new_val.p_address;
    NSArray *o_val = [NSArray arrayWithObjects:[NSNumber numberWithInt:p_add->i_node], [NSNumber numberWithInt:p_add->i_item], nil];
    [[VLCMain sharedInstance] performSelectorOnMainThread:@selector(plItemAppended:) withObject:o_val waitUntilDone:NO];

    [o_pool release];
    return VLC_SUCCESS;
}

static int PLItemRemoved(vlc_object_t *p_this, const char *psz_var,
                           vlc_value_t oldval, vlc_value_t new_val, void *param)
{
    NSAutoreleasePool * o_pool = [[NSAutoreleasePool alloc] init];

    NSNumber *o_val = [NSNumber numberWithInt:new_val.i_int];
    [[VLCMain sharedInstance] performSelectorOnMainThread:@selector(plItemRemoved:) withObject:o_val waitUntilDone:NO];

    [o_pool release];
    return VLC_SUCCESS;
}

static int PlaybackModeUpdated(vlc_object_t *p_this, const char *psz_var,
                         vlc_value_t oldval, vlc_value_t new_val, void *param)
{
    NSAutoreleasePool * o_pool = [[NSAutoreleasePool alloc] init];
    [[VLCMain sharedInstance] performSelectorOnMainThread:@selector(playbackModeUpdated) withObject:nil waitUntilDone:NO];

    [o_pool release];
    return VLC_SUCCESS;
}

static int VolumeUpdated(vlc_object_t *p_this, const char *psz_var,
                         vlc_value_t oldval, vlc_value_t new_val, void *param)
{
    NSAutoreleasePool * o_pool = [[NSAutoreleasePool alloc] init];
    [[VLCMain sharedInstance] performSelectorOnMainThread:@selector(updateVolume) withObject:nil waitUntilDone:NO];

    [o_pool release];
    return VLC_SUCCESS;
}

static int BossCallback(vlc_object_t *p_this, const char *psz_var,
                        vlc_value_t oldval, vlc_value_t new_val, void *param)
{
    NSAutoreleasePool * o_pool = [[NSAutoreleasePool alloc] init];

    [[VLCCoreInteraction sharedInstance] performSelectorOnMainThread:@selector(pause) withObject:nil waitUntilDone:NO];
    [[VLCApplication sharedApplication] hide:nil];

    [o_pool release];
    return VLC_SUCCESS;
}

/*****************************************************************************
 * ShowController: Callback triggered by the show-intf playlist variable
 * through the ShowIntf-control-intf, to let us show the controller-win;
 * usually when in fullscreen-mode
 *****************************************************************************/
static int ShowController(vlc_object_t *p_this, const char *psz_variable,
                     vlc_value_t old_val, vlc_value_t new_val, void *param)
{
    intf_thread_t * p_intf = VLCIntf;
    if (p_intf) {
        playlist_t * p_playlist = pl_Get(p_intf);
        BOOL b_fullscreen = var_GetBool(p_playlist, "fullscreen");
        if (b_fullscreen)
            [[VLCMain sharedInstance] performSelectorOnMainThread:@selector(showFullscreenController) withObject:nil waitUntilDone:NO];
        else if (!strcmp(psz_variable, "intf-show"))
            [[VLCMain sharedInstance] performSelectorOnMainThread:@selector(showMainWindow) withObject:nil waitUntilDone:NO];
    }

    return VLC_SUCCESS;
}

/*****************************************************************************
 * DialogCallback: Callback triggered by the "dialog-*" variables
 * to let the intf display error and interaction dialogs
 *****************************************************************************/
static int DialogCallback(vlc_object_t *p_this, const char *type, vlc_value_t previous, vlc_value_t value, void *data)
{
    NSAutoreleasePool * o_pool = [[NSAutoreleasePool alloc] init];

    if ([[NSString stringWithUTF8String:type] isEqualToString: @"dialog-progress-bar"]) {
        /* the progress panel needs to update itself and therefore wants special treatment within this context */
        dialog_progress_bar_t *p_dialog = (dialog_progress_bar_t *)value.p_address;

        p_dialog->pf_update = updateProgressPanel;
        p_dialog->pf_check = checkProgressPanel;
        p_dialog->pf_destroy = destroyProgressPanel;
        p_dialog->p_sys = VLCIntf->p_libvlc;
    }

    NSValue *o_value = [NSValue valueWithPointer:value.p_address];
    [[[VLCMain sharedInstance] coreDialogProvider] performEventWithObject: o_value ofType: type];

    [o_pool release];
    return VLC_SUCCESS;
}

void updateProgressPanel (void *priv, const char *text, float value)
{
    NSAutoreleasePool *o_pool = [[NSAutoreleasePool alloc] init];

    NSString *o_txt = toNSStr(text);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[[VLCMain sharedInstance] coreDialogProvider] updateProgressPanelWithText: o_txt andNumber: (double)(value * 1000.)];
    });

    [o_pool release];
}

void destroyProgressPanel (void *priv)
{
    NSAutoreleasePool *o_pool = [[NSAutoreleasePool alloc] init];

    if ([[NSApplication sharedApplication] isRunning])
        [[[VLCMain sharedInstance] coreDialogProvider] performSelectorOnMainThread:@selector(destroyProgressPanel) withObject:nil waitUntilDone:YES];

    [o_pool release];
}

bool checkProgressPanel (void *priv)
{
    return [[[VLCMain sharedInstance] coreDialogProvider] progressCancelled];
}

#pragma mark -
#pragma mark Helpers

input_thread_t *getInput(void)
{
    intf_thread_t *p_intf = VLCIntf;
    if (!p_intf)
        return NULL;
    return pl_CurrentInput(p_intf);
}

vout_thread_t *getVout(void)
{
    input_thread_t *p_input = getInput();
    if (!p_input)
        return NULL;
    vout_thread_t *p_vout = input_GetVout(p_input);
    vlc_object_release(p_input);
    return p_vout;
}

vout_thread_t *getVoutForActiveWindow(void)
{
    vout_thread_t *p_vout = nil;

    id currentWindow = [NSApp keyWindow];
    if ([currentWindow respondsToSelector:@selector(videoView)]) {
        VLCVoutView *videoView = [currentWindow videoView];
        if (videoView) {
            p_vout = [videoView voutThread];
        }
    }

    if (!p_vout)
        p_vout = getVout();

    return p_vout;
}

audio_output_t *getAout(void)
{
    intf_thread_t *p_intf = VLCIntf;
    if (!p_intf)
        return NULL;
    return playlist_GetAout(pl_Get(p_intf));
}

#pragma mark -
#pragma mark Private

@interface VLCMain () <BWQuincyManagerDelegate>
- (void)removeOldPreferences;
@end

@interface VLCMain (Internal)
- (void)resetMediaKeyJump;
- (void)coreChangedMediaKeySupportSetting: (NSNotification *)o_notification;
@end

/*****************************************************************************
 * VLCMain implementation
 *****************************************************************************/
@implementation VLCMain

@synthesize voutController=o_vout_controller;
@synthesize nativeFullscreenMode=b_nativeFullscreenMode;

#pragma mark -
#pragma mark Initialization

static VLCMain *_o_sharedMainInstance = nil;

+ (VLCMain *)sharedInstance
{
    return _o_sharedMainInstance ? _o_sharedMainInstance : [[self alloc] init];
}

- (id)init
{
    if (_o_sharedMainInstance) {
        [self dealloc];
        return _o_sharedMainInstance;
    } else
        _o_sharedMainInstance = [super init];

    p_intf = NULL;

    o_open = [[VLCOpen alloc] init];
    o_coredialogs = [[VLCCoreDialogProvider alloc] init];
    o_mainmenu = [[VLCMainMenu alloc] init];
    o_coreinteraction = [[VLCCoreInteraction alloc] init];
    o_eyetv = [[VLCEyeTVController alloc] init];

    /* announce our launch to a potential eyetv plugin */
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName: @"VLCOSXGUIInit"
                                                                   object: @"VLCEyeTVSupport"
                                                                 userInfo: NULL
                                                       deliverImmediately: YES];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *appDefaults = [NSDictionary dictionaryWithObject:@"NO" forKey:@"LiveUpdateTheMessagesPanel"];
    [defaults registerDefaults:appDefaults];

    o_vout_controller = [[VLCVoutWindowController alloc] init];

    return _o_sharedMainInstance;
}

- (void)setIntf: (intf_thread_t *)p_mainintf
{
    p_intf = p_mainintf;
}

- (intf_thread_t *)intf
{
    return p_intf;
}

- (void)awakeFromNib
{
    playlist_t *p_playlist;
    if (!p_intf) return;
    var_Create(p_intf, "intf-change", VLC_VAR_BOOL);

    /* Check if we already did this once. Opening the other nibs calls it too,
     because VLCMain is the owner */
    if (nib_main_loaded)
        return;

    // TODO: take care of VLCIntf initialization order
    o_input_manager = [[InputManager alloc] initWithMain:self];

    p_playlist = pl_Get(p_intf);

    var_AddCallback(p_intf->p_libvlc, "intf-toggle-fscontrol", ShowController, self);
    var_AddCallback(p_intf->p_libvlc, "intf-show", ShowController, self);
    var_AddCallback(p_intf->p_libvlc, "intf-boss", BossCallback, self);
    var_AddCallback(p_playlist, "item-change", PLItemUpdated, self);
    var_AddCallback(p_playlist, "playlist-item-append", PLItemAppended, self);
    var_AddCallback(p_playlist, "playlist-item-deleted", PLItemRemoved, self);
    var_AddCallback(p_playlist, "random", PlaybackModeUpdated, self);
    var_AddCallback(p_playlist, "repeat", PlaybackModeUpdated, self);
    var_AddCallback(p_playlist, "loop", PlaybackModeUpdated, self);
    var_AddCallback(p_playlist, "volume", VolumeUpdated, self);
    var_AddCallback(p_playlist, "mute", VolumeUpdated, self);

    if (!OSX_SNOW_LEOPARD) {
        if ([NSApp currentSystemPresentationOptions] & NSApplicationPresentationFullScreen)
            var_SetBool(p_playlist, "fullscreen", YES);
    }

    /* load our Shared Dialogs nib */
    [NSBundle loadNibNamed:@"SharedDialogs" owner: NSApp];

    /* subscribe to various interactive dialogues */
    var_Create(p_intf, "dialog-error", VLC_VAR_ADDRESS);
    var_AddCallback(p_intf, "dialog-error", DialogCallback, self);
    var_Create(p_intf, "dialog-critical", VLC_VAR_ADDRESS);
    var_AddCallback(p_intf, "dialog-critical", DialogCallback, self);
    var_Create(p_intf, "dialog-login", VLC_VAR_ADDRESS);
    var_AddCallback(p_intf, "dialog-login", DialogCallback, self);
    var_Create(p_intf, "dialog-question", VLC_VAR_ADDRESS);
    var_AddCallback(p_intf, "dialog-question", DialogCallback, self);
    var_Create(p_intf, "dialog-progress-bar", VLC_VAR_ADDRESS);
    var_AddCallback(p_intf, "dialog-progress-bar", DialogCallback, self);
    dialog_Register(p_intf);

    /* init Apple Remote support */
    o_remote = [[AppleRemote alloc] init];
    [o_remote setClickCountEnabledButtons: kRemoteButtonPlay];
    [o_remote setDelegate: _o_sharedMainInstance];

    /* yeah, we are done */
    b_nativeFullscreenMode = NO;
#ifdef MAC_OS_X_VERSION_10_7
    if (!OSX_SNOW_LEOPARD)
        b_nativeFullscreenMode = var_InheritBool(p_intf, "macosx-nativefullscreenmode");
#endif

    if (config_GetInt(VLCIntf, "macosx-icon-change")) {
        /* After day 354 of the year, the usual VLC cone is replaced by another cone
         * wearing a Father Xmas hat.
         * Note: this icon doesn't represent an endorsement of The Coca-Cola Company.
         */
        NSCalendar *gregorian =
        [[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar];
        NSUInteger dayOfYear = [gregorian ordinalityOfUnit:NSDayCalendarUnit inUnit:NSYearCalendarUnit forDate:[NSDate date]];
        [gregorian release];

        if (dayOfYear >= 354)
            [[VLCApplication sharedApplication] setApplicationIconImage: [NSImage imageNamed:@"vlc-xmas"]];
    }

    nib_main_loaded = TRUE;
}

- (void)applicationWillFinishLaunching:(NSNotification *)aNotification
{
    playlist_t * p_playlist = pl_Get(VLCIntf);
    PL_LOCK;
    items_at_launch = p_playlist->p_local_category->i_children;
    PL_UNLOCK;

#ifdef HAVE_SPARKLE
    [[SUUpdater sharedUpdater] setDelegate:self];
#endif
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    launched = YES;

    if (!p_intf)
        return;

    NSString *appVersion = [[[NSBundle mainBundle] infoDictionary] valueForKey: @"CFBundleVersion"];
    NSRange endRande = [appVersion rangeOfString:@"-"];
    if (endRande.location != NSNotFound)
        appVersion = [appVersion substringToIndex:endRande.location];

    BWQuincyManager *quincyManager = [BWQuincyManager sharedQuincyManager];
    [quincyManager setApplicationVersion:appVersion];
    [quincyManager setSubmissionURL:@"http://crash.videolan.org/crash_v200.php"];
    [quincyManager setDelegate:self];
    [quincyManager setCompanyName:@"VideoLAN"];

    [self updateCurrentlyUsedHotkeys];

    /* init media key support */
    b_mediaKeySupport = var_InheritBool(VLCIntf, "macosx-mediakeys");
    if (b_mediaKeySupport) {
        o_mediaKeyController = [[SPMediaKeyTap alloc] initWithDelegate:self];
        [[NSUserDefaults standardUserDefaults] registerDefaults:[NSDictionary dictionaryWithObjectsAndKeys:
                                                                 [SPMediaKeyTap defaultMediaKeyUserBundleIdentifiers], kMediaKeyUsingBundleIdentifiersDefaultsKey,
                                                                 nil]];
    }
    [[NSNotificationCenter defaultCenter] addObserver: self selector: @selector(coreChangedMediaKeySupportSetting:) name: @"VLCMediaKeySupportSettingChanged" object: nil];

    [self removeOldPreferences];

    /* Handle sleep notification */
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(computerWillSleep:)
           name:NSWorkspaceWillSleepNotification object:nil];

    /* update the main window */
    [o_mainwindow updateWindow];
    [o_mainwindow updateTimeSlider];
    [o_mainwindow updateVolumeSlider];

    /* Hack: Playlist is started before the interface.
     * Thus, call additional updaters as we might miss these events if posted before
     * the callbacks are registered.
     */
    [o_input_manager inputThreadChanged];
    [self playbackModeUpdated];

    // respect playlist-autostart
    // note that PLAYLIST_PLAY will not stop any playback if already started
    playlist_t * p_playlist = pl_Get(VLCIntf);
    PL_LOCK;
    BOOL kidsAround = p_playlist->p_local_category->i_children != 0;
    if (kidsAround && var_GetBool(p_playlist, "playlist-autostart"))
        playlist_Control(p_playlist, PLAYLIST_PLAY, true);
    PL_UNLOCK;
}

#pragma mark -
#pragma mark Termination

- (BOOL)isTerminating
{
    return b_intf_terminating;
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    if (b_intf_terminating)
        return;
    b_intf_terminating = true;

    [o_input_manager resumeItunesPlayback:nil];

    if (notification == nil)
        [[NSNotificationCenter defaultCenter] postNotificationName: NSApplicationWillTerminateNotification object: nil];

    playlist_t * p_playlist = pl_Get(p_intf);

    /* save current video and audio profiles */
    [[VLCVideoEffects sharedInstance] saveCurrentProfile];
    [[VLCAudioEffects sharedInstance] saveCurrentProfile];

    /* Save some interface state in configuration, at module quit */
    config_PutInt(p_intf, "random", var_GetBool(p_playlist, "random"));
    config_PutInt(p_intf, "loop", var_GetBool(p_playlist, "loop"));
    config_PutInt(p_intf, "repeat", var_GetBool(p_playlist, "repeat"));

    msg_Dbg(p_intf, "Terminating");

    /* unsubscribe from the interactive dialogues */
    dialog_Unregister(p_intf);
    var_DelCallback(p_intf, "dialog-error", DialogCallback, self);
    var_DelCallback(p_intf, "dialog-critical", DialogCallback, self);
    var_DelCallback(p_intf, "dialog-login", DialogCallback, self);
    var_DelCallback(p_intf, "dialog-question", DialogCallback, self);
    var_DelCallback(p_intf, "dialog-progress-bar", DialogCallback, self);
    var_DelCallback(p_playlist, "item-change", PLItemUpdated, self);
    var_DelCallback(p_playlist, "playlist-item-append", PLItemAppended, self);
    var_DelCallback(p_playlist, "playlist-item-deleted", PLItemRemoved, self);
    var_DelCallback(p_playlist, "random", PlaybackModeUpdated, self);
    var_DelCallback(p_playlist, "repeat", PlaybackModeUpdated, self);
    var_DelCallback(p_playlist, "loop", PlaybackModeUpdated, self);
    var_DelCallback(p_playlist, "volume", VolumeUpdated, self);
    var_DelCallback(p_playlist, "mute", VolumeUpdated, self);
    var_DelCallback(p_intf->p_libvlc, "intf-toggle-fscontrol", ShowController, self);
    var_DelCallback(p_intf->p_libvlc, "intf-show", ShowController, self);
    var_DelCallback(p_intf->p_libvlc, "intf-boss", BossCallback, self);

    /* remove global observer watching for vout device changes correctly */
    [[NSNotificationCenter defaultCenter] removeObserver: self];

    [o_vout_provider_lock lock];
    // release before o_info!
    // closes all open vouts
    [o_vout_controller release];
    o_vout_controller = nil;
    [o_vout_provider_lock unlock];

    [o_input_manager release];

    /* release some other objects here, because it isn't sure whether dealloc
     * will be called later on */
    if (o_sprefs)
        [o_sprefs release];

    if (o_prefs)
        [o_prefs release];

    [o_open release];

    if (o_info)
        [o_info release];

    if (o_wizard)
        [o_wizard release];

    if (!o_bookmarks)
        [o_bookmarks release];

    [o_coredialogs release];
    [o_eyetv release];
    [o_remote release];

    /* unsubscribe from libvlc's debug messages */
    vlc_LogSet(p_intf->p_libvlc, NULL, NULL);

    [o_usedHotkeys release];
    o_usedHotkeys = NULL;

    [o_mediaKeyController release];

    /* write cached user defaults to disk */
    [[NSUserDefaults standardUserDefaults] synchronize];

    [o_mainmenu release];
    [o_coreinteraction release];

    o_mainwindow = NULL;

    [self setIntf:nil];
}

#pragma mark -
#pragma mark Sparkle delegate

#ifdef HAVE_SPARKLE
/* received directly before the update gets installed, so let's shut down a bit */
- (void)updater:(SUUpdater *)updater willInstallUpdate:(SUAppcastItem *)update
{
    [NSApp activateIgnoringOtherApps:YES];
    [o_remote stopListening: self];
    [[VLCCoreInteraction sharedInstance] stop];
}

/* don't be enthusiastic about an update if we currently play a video */
- (BOOL)updaterMayCheckForUpdates:(SUUpdater *)bundle
{
    if ([self activeVideoPlayback])
        return NO;

    return YES;
}
#endif

#pragma mark -
#pragma mark Media Key support

-(void)mediaKeyTap:(SPMediaKeyTap*)keyTap receivedMediaKeyEvent:(NSEvent*)event
{
    if (b_mediaKeySupport) {
        assert([event type] == NSSystemDefined && [event subtype] == SPSystemDefinedEventMediaKeys);

        int keyCode = (([event data1] & 0xFFFF0000) >> 16);
        int keyFlags = ([event data1] & 0x0000FFFF);
        int keyState = (((keyFlags & 0xFF00) >> 8)) == 0xA;
        int keyRepeat = (keyFlags & 0x1);

        if (keyCode == NX_KEYTYPE_PLAY && keyState == 0)
            [[VLCCoreInteraction sharedInstance] playOrPause];

        if ((keyCode == NX_KEYTYPE_FAST || keyCode == NX_KEYTYPE_NEXT) && !b_mediakeyJustJumped) {
            if (keyState == 0 && keyRepeat == 0)
                [[VLCCoreInteraction sharedInstance] next];
            else if (keyRepeat == 1) {
                [[VLCCoreInteraction sharedInstance] forwardShort];
                b_mediakeyJustJumped = YES;
                [self performSelector:@selector(resetMediaKeyJump)
                           withObject: NULL
                           afterDelay:0.25];
            }
        }

        if ((keyCode == NX_KEYTYPE_REWIND || keyCode == NX_KEYTYPE_PREVIOUS) && !b_mediakeyJustJumped) {
            if (keyState == 0 && keyRepeat == 0)
                [[VLCCoreInteraction sharedInstance] previous];
            else if (keyRepeat == 1) {
                [[VLCCoreInteraction sharedInstance] backwardShort];
                b_mediakeyJustJumped = YES;
                [self performSelector:@selector(resetMediaKeyJump)
                           withObject: NULL
                           afterDelay:0.25];
            }
        }
    }
}

#pragma mark -
#pragma mark Other notification

/* Listen to the remote in exclusive mode, only when VLC is the active
   application */
- (void)applicationDidBecomeActive:(NSNotification *)aNotification
{
    if (!p_intf)
        return;
    if (var_InheritBool(p_intf, "macosx-appleremote") == YES)
        [o_remote startListening: self];
}
- (void)applicationDidResignActive:(NSNotification *)aNotification
{
    if (!p_intf)
        return;
    [o_remote stopListening: self];
}

/* Triggered when the computer goes to sleep */
- (void)computerWillSleep: (NSNotification *)notification
{
    [[VLCCoreInteraction sharedInstance] pause];
}

#pragma mark -
#pragma mark File opening over dock icon

- (void)application:(NSApplication *)o_app openFiles:(NSArray *)o_names
{
    // Only add items here which are getting dropped to to the application icon
    // or are given at startup. If a file is passed via command line, libvlccore
    // will add the item, but cocoa also calls this function. In this case, the
    // invocation is ignored here.
    if (launched == NO) {
        if (items_at_launch) {
            int items = [o_names count];
            if (items > items_at_launch)
                items_at_launch = 0;
            else
                items_at_launch -= items;
            return;
        }
    }

    char *psz_uri = vlc_path2uri([[o_names objectAtIndex:0] UTF8String], NULL);

    // try to add file as subtitle
    if ([o_names count] == 1 && psz_uri) {
        input_thread_t * p_input = pl_CurrentInput(VLCIntf);
        if (p_input) {
            int i_result = input_AddSubtitleOSD(p_input, [[o_names objectAtIndex:0] UTF8String], true, true);
            vlc_object_release(p_input);
            if (i_result == VLC_SUCCESS) {
                free(psz_uri);
                return;
            }
        }
    }
    free(psz_uri);

    NSArray *o_sorted_names = [o_names sortedArrayUsingSelector: @selector(caseInsensitiveCompare:)];
    NSMutableArray *o_result = [NSMutableArray arrayWithCapacity: [o_sorted_names count]];
    for (NSUInteger i = 0; i < [o_sorted_names count]; i++) {
        psz_uri = vlc_path2uri([[o_sorted_names objectAtIndex:i] UTF8String], "file");
        if (!psz_uri)
            continue;

        NSDictionary *o_dic = [NSDictionary dictionaryWithObject:[NSString stringWithCString:psz_uri encoding:NSUTF8StringEncoding] forKey:@"ITEM_URL"];
        free(psz_uri);
        [o_result addObject: o_dic];
    }

    [[[VLCMain sharedInstance] playlist] addPlaylistItems:o_result];
}

/* When user click in the Dock icon our double click in the finder */
- (BOOL)applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)hasVisibleWindows
{
    if (!hasVisibleWindows)
        [o_mainwindow makeKeyAndOrderFront:self];

    return YES;
}

#pragma mark -
#pragma mark Apple Remote Control

/* Helper method for the remote control interface in order to trigger forward/backward and volume
   increase/decrease as long as the user holds the left/right, plus/minus button */
- (void) executeHoldActionForRemoteButton: (NSNumber*) buttonIdentifierNumber
{
    if (b_remote_button_hold) {
        switch([buttonIdentifierNumber intValue]) {
            case kRemoteButtonRight_Hold:
                [[VLCCoreInteraction sharedInstance] forward];
                break;
            case kRemoteButtonLeft_Hold:
                [[VLCCoreInteraction sharedInstance] backward];
                break;
            case kRemoteButtonVolume_Plus_Hold:
                if (p_intf)
                    var_SetInteger(p_intf->p_libvlc, "key-action", ACTIONID_VOL_UP);
                break;
            case kRemoteButtonVolume_Minus_Hold:
                if (p_intf)
                    var_SetInteger(p_intf->p_libvlc, "key-action", ACTIONID_VOL_DOWN);
                break;
        }
        if (b_remote_button_hold) {
            /* trigger event */
            [self performSelector:@selector(executeHoldActionForRemoteButton:)
                         withObject:buttonIdentifierNumber
                         afterDelay:0.25];
        }
    }
}

/* Apple Remote callback */
- (void) appleRemoteButton: (AppleRemoteEventIdentifier)buttonIdentifier
               pressedDown: (BOOL) pressedDown
                clickCount: (unsigned int) count
{
    switch(buttonIdentifier) {
        case k2009RemoteButtonFullscreen:
            [[VLCCoreInteraction sharedInstance] toggleFullscreen];
            break;
        case k2009RemoteButtonPlay:
            [[VLCCoreInteraction sharedInstance] playOrPause];
            break;
        case kRemoteButtonPlay:
            if (count >= 2)
                [[VLCCoreInteraction sharedInstance] toggleFullscreen];
            else
                [[VLCCoreInteraction sharedInstance] playOrPause];
            break;
        case kRemoteButtonVolume_Plus:
            if (config_GetInt(VLCIntf, "macosx-appleremote-sysvol"))
                [NSSound increaseSystemVolume];
            else
                if (p_intf)
                    var_SetInteger(p_intf->p_libvlc, "key-action", ACTIONID_VOL_UP);
            break;
        case kRemoteButtonVolume_Minus:
            if (config_GetInt(VLCIntf, "macosx-appleremote-sysvol"))
                [NSSound decreaseSystemVolume];
            else
                if (p_intf)
                    var_SetInteger(p_intf->p_libvlc, "key-action", ACTIONID_VOL_DOWN);
            break;
        case kRemoteButtonRight:
            if (config_GetInt(VLCIntf, "macosx-appleremote-prevnext"))
                [[VLCCoreInteraction sharedInstance] forward];
            else
                [[VLCCoreInteraction sharedInstance] next];
            break;
        case kRemoteButtonLeft:
            if (config_GetInt(VLCIntf, "macosx-appleremote-prevnext"))
                [[VLCCoreInteraction sharedInstance] backward];
            else
                [[VLCCoreInteraction sharedInstance] previous];
            break;
        case kRemoteButtonRight_Hold:
        case kRemoteButtonLeft_Hold:
        case kRemoteButtonVolume_Plus_Hold:
        case kRemoteButtonVolume_Minus_Hold:
            /* simulate an event as long as the user holds the button */
            b_remote_button_hold = pressedDown;
            if (pressedDown) {
                NSNumber* buttonIdentifierNumber = [NSNumber numberWithInt:buttonIdentifier];
                [self performSelector:@selector(executeHoldActionForRemoteButton:)
                           withObject:buttonIdentifierNumber];
            }
            break;
        case kRemoteButtonMenu:
            [o_controls showPosition: self]; //FIXME
            break;
        case kRemoteButtonPlay_Sleep:
        {
            NSAppleScript * script = [[NSAppleScript alloc] initWithSource:@"tell application \"System Events\" to sleep"];
            [script executeAndReturnError:nil];
            [script release];
            break;
        }
        default:
            /* Add here whatever you want other buttons to do */
            break;
    }
}

#pragma mark -
#pragma mark Key Shortcuts

/*****************************************************************************
 * hasDefinedShortcutKey: Check to see if the key press is a defined VLC
 * shortcut key.  If it is, pass it off to VLC for handling and return YES,
 * otherwise ignore it and return NO (where it will get handled by Cocoa).
 *****************************************************************************/
- (BOOL)hasDefinedShortcutKey:(NSEvent *)o_event force:(BOOL)b_force
{
    unichar key = 0;
    vlc_value_t val;
    unsigned int i_pressed_modifiers = 0;

    val.i_int = 0;
    i_pressed_modifiers = [o_event modifierFlags];

    if (i_pressed_modifiers & NSControlKeyMask)
        val.i_int |= KEY_MODIFIER_CTRL;

    if (i_pressed_modifiers & NSAlternateKeyMask)
        val.i_int |= KEY_MODIFIER_ALT;

    if (i_pressed_modifiers & NSShiftKeyMask)
        val.i_int |= KEY_MODIFIER_SHIFT;

    if (i_pressed_modifiers & NSCommandKeyMask)
        val.i_int |= KEY_MODIFIER_COMMAND;

    NSString * characters = [o_event charactersIgnoringModifiers];
    if ([characters length] > 0) {
        key = [[characters lowercaseString] characterAtIndex: 0];

        /* handle Lion's default key combo for fullscreen-toggle in addition to our own hotkeys */
        if (key == 'f' && i_pressed_modifiers & NSControlKeyMask && i_pressed_modifiers & NSCommandKeyMask) {
            [[VLCCoreInteraction sharedInstance] toggleFullscreen];
            return YES;
        }

        if (!b_force) {
            switch(key) {
                case NSDeleteCharacter:
                case NSDeleteFunctionKey:
                case NSDeleteCharFunctionKey:
                case NSBackspaceCharacter:
                case NSUpArrowFunctionKey:
                case NSDownArrowFunctionKey:
                case NSEnterCharacter:
                case NSCarriageReturnCharacter:
                    return NO;
            }
        }

        val.i_int |= CocoaKeyToVLC(key);

        BOOL b_found_key = NO;
        for (NSUInteger i = 0; i < [o_usedHotkeys count]; i++) {
            NSString *str = [o_usedHotkeys objectAtIndex:i];
            unsigned int i_keyModifiers = [[VLCStringUtility sharedInstance] VLCModifiersToCocoa: str];

            if ([[characters lowercaseString] isEqualToString: [[VLCStringUtility sharedInstance] VLCKeyToString: str]] &&
               (i_keyModifiers & NSShiftKeyMask)     == (i_pressed_modifiers & NSShiftKeyMask) &&
               (i_keyModifiers & NSControlKeyMask)   == (i_pressed_modifiers & NSControlKeyMask) &&
               (i_keyModifiers & NSAlternateKeyMask) == (i_pressed_modifiers & NSAlternateKeyMask) &&
               (i_keyModifiers & NSCommandKeyMask)   == (i_pressed_modifiers & NSCommandKeyMask)) {
                b_found_key = YES;
                break;
            }
        }

        if (b_found_key) {
            var_SetInteger(p_intf->p_libvlc, "key-pressed", val.i_int);
            return YES;
        }
    }

    return NO;
}

- (void)updateCurrentlyUsedHotkeys
{
    NSMutableArray *o_tempArray = [[NSMutableArray alloc] init];
    /* Get the main Module */
    module_t *p_main = module_get_main();
    assert(p_main);
    unsigned confsize;
    module_config_t *p_config;

    p_config = module_config_get (p_main, &confsize);

    for (size_t i = 0; i < confsize; i++) {
        module_config_t *p_item = p_config + i;

        if (CONFIG_ITEM(p_item->i_type) && p_item->psz_name != NULL
           && !strncmp(p_item->psz_name , "key-", 4)
           && !EMPTY_STR(p_item->psz_text)) {
            if (p_item->value.psz)
                [o_tempArray addObject: [NSString stringWithUTF8String:p_item->value.psz]];
        }
    }
    module_config_free (p_config);

    if (o_usedHotkeys)
        [o_usedHotkeys release];
    o_usedHotkeys = [[NSArray alloc] initWithArray: o_tempArray copyItems: YES];
    [o_tempArray release];
}

#pragma mark -
#pragma mark Interface updaters

- (void)plItemAppended:(NSArray *)o_val
{
    int i_node = [[o_val objectAtIndex:0] intValue];
    int i_item = [[o_val objectAtIndex:1] intValue];

    [[[self playlist] model] addItem:i_item withParentNode:i_node];

    // update badge in sidebar
    [o_mainwindow updateWindow];

    [[NSNotificationCenter defaultCenter] postNotificationName: @"VLCMediaKeySupportSettingChanged"
                                                        object: nil
                                                      userInfo: nil];
}

- (void)plItemRemoved:(NSNumber *)o_val
{
    int i_item = [o_val intValue];

    [[[self playlist] model] removeItem:i_item];
    [[self playlist] deletionCompleted];

    // update badge in sidebar
    [o_mainwindow updateWindow];

    [[NSNotificationCenter defaultCenter] postNotificationName: @"VLCMediaKeySupportSettingChanged"
                                                        object: nil
                                                      userInfo: nil];
}

- (void)plItemUpdated
{
    [o_mainwindow updateName];

    if (o_info != NULL)
        [o_info updateMetadata];
}

- (void)updateMainMenu
{
    [o_mainmenu setupMenus];
    [o_mainmenu updatePlaybackRate];
    [[VLCCoreInteraction sharedInstance] resetAtoB];
}

- (void)updateMainWindow
{
    [o_mainwindow updateWindow];
}

- (void)showMainWindow
{
    [o_mainwindow performSelectorOnMainThread:@selector(makeKeyAndOrderFront:) withObject:nil waitUntilDone:NO];
}

- (void)showFullscreenController
{
    // defer selector here (possibly another time) to ensure that keyWindow is set properly
    // (needed for NSApplicationDidBecomeActiveNotification)
    [o_mainwindow performSelectorOnMainThread:@selector(showFullscreenController) withObject:nil waitUntilDone:NO];
}

- (void)updateDelays
{
    [[VLCTrackSynchronization sharedInstance] performSelectorOnMainThread: @selector(updateValues) withObject: nil waitUntilDone:NO];
}

- (void)updateName
{
    [o_mainwindow updateName];
}

- (void)updatePlaybackPosition
{
    [o_mainwindow updateTimeSlider];
    [[VLCCoreInteraction sharedInstance] updateAtoB];
}

- (void)updateVolume
{
    [o_mainwindow updateVolumeSlider];
}

- (void)updateRecordState: (BOOL)b_value
{
    [o_mainmenu updateRecordState:b_value];
}

- (void)playbackModeUpdated
{
    playlist_t * p_playlist = pl_Get(VLCIntf);

    bool loop = var_GetBool(p_playlist, "loop");
    bool repeat = var_GetBool(p_playlist, "repeat");
    if (repeat) {
        [[o_mainwindow controlsBar] setRepeatOne];
        [o_mainmenu setRepeatOne];
    } else if (loop) {
        [[o_mainwindow controlsBar] setRepeatAll];
        [o_mainmenu setRepeatAll];
    } else {
        [[o_mainwindow controlsBar] setRepeatOff];
        [o_mainmenu setRepeatOff];
    }

    [[o_mainwindow controlsBar] setShuffle];
    [o_mainmenu setShuffle];
}

#pragma mark -
#pragma mark Window updater

- (void)setActiveVideoPlayback:(BOOL)b_value
{
    assert([NSThread isMainThread]);

    b_active_videoplayback = b_value;
    if (o_mainwindow) {
        [o_mainwindow setVideoplayEnabled];
    }

    // update sleep blockers
    [o_input_manager playbackStatusUpdated];
}

#pragma mark -
#pragma mark Other objects getters

- (VLCMainMenu *)mainMenu
{
    return o_mainmenu;
}

- (VLCMainWindow *)mainWindow
{
    return o_mainwindow;
}

- (id)controls
{
    return o_controls;
}

- (id)bookmarks
{
    if (!o_bookmarks)
        o_bookmarks = [[VLCBookmarks alloc] init];

    if (!nib_bookmarks_loaded)
        nib_bookmarks_loaded = [NSBundle loadNibNamed:@"Bookmarks" owner: NSApp];

    return o_bookmarks;
}

- (id)open
{
    if (!nib_open_loaded)
        nib_open_loaded = [NSBundle loadNibNamed:@"Open" owner: NSApp];

    return o_open;
}

- (id)simplePreferences
{
    if (!o_sprefs)
        o_sprefs = [[VLCSimplePrefs alloc] init];

    if (!nib_prefs_loaded)
        nib_prefs_loaded = [NSBundle loadNibNamed:@"Preferences" owner: NSApp];

    return o_sprefs;
}

- (id)preferences
{
    if (!o_prefs)
        o_prefs = [[VLCPrefs alloc] init];

    if (!nib_prefs_loaded)
        nib_prefs_loaded = [NSBundle loadNibNamed:@"Preferences" owner: NSApp];

    return o_prefs;
}

- (VLCPlaylist *)playlist
{
    return o_playlist;
}

- (VLCInfo *)info
{
    if (!o_info)
        o_info = [[VLCInfo alloc] init];

    if (! nib_info_loaded)
        nib_info_loaded = [NSBundle loadNibNamed:@"MediaInfo" owner: NSApp];

    return o_info;
}

- (id)wizard
{
    if (!o_wizard)
        o_wizard = [[VLCWizard alloc] init];

    if (!nib_wizard_loaded) {
        nib_wizard_loaded = [NSBundle loadNibNamed:@"Wizard" owner: NSApp];
        [o_wizard initStrings];
    }

    return o_wizard;
}

- (id)coreDialogProvider
{
    if (!nib_coredialogs_loaded) {
        nib_coredialogs_loaded = [NSBundle loadNibNamed:@"CoreDialogs" owner: NSApp];
    }

    return o_coredialogs;
}

- (id)eyeTVController
{
    return o_eyetv;
}

- (id)appleRemoteController
{
    return o_remote;
}

- (BOOL)activeVideoPlayback
{
    return b_active_videoplayback;
}

#pragma mark -
#pragma mark Remove old prefs


static NSString * kVLCPreferencesVersion = @"VLCPreferencesVersion";
static const int kCurrentPreferencesVersion = 3;

+ (void)initialize
{
    NSDictionary *appDefaults = [NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCurrentPreferencesVersion]
                                                            forKey:kVLCPreferencesVersion];

    [[NSUserDefaults standardUserDefaults] registerDefaults:appDefaults];
}

- (void)resetAndReinitializeUserDefaults
{
    // note that [NSUserDefaults resetStandardUserDefaults] will NOT correctly reset to the defaults

    NSString *appDomain = [[NSBundle mainBundle] bundleIdentifier];
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:appDomain];

    // set correct version to avoid question about outdated config
    [[NSUserDefaults standardUserDefaults] setInteger:kCurrentPreferencesVersion forKey:kVLCPreferencesVersion];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)removeOldPreferences
{
    NSUserDefaults * defaults = [NSUserDefaults standardUserDefaults];
    int version = [defaults integerForKey:kVLCPreferencesVersion];

    /*
     * Store version explicitely in file, for ease of debugging.
     * Otherwise, the value will be just defined at app startup,
     * as initialized above.
     */
    [defaults setInteger:version forKey:kVLCPreferencesVersion];
    if (version >= kCurrentPreferencesVersion)
        return;

    if (version == 1) {
        [defaults setInteger:kCurrentPreferencesVersion forKey:kVLCPreferencesVersion];
        [defaults synchronize];

        if (![[VLCCoreInteraction sharedInstance] fixPreferences])
            return;
        else
            config_SaveConfigFile(VLCIntf); // we need to do manually, since we won't quit libvlc cleanly
    } else if (version == 2) {
        /* version 2 (used by VLC 2.0.x and early versions of 2.1) can lead to exceptions within 2.1 or later
         * so we reset the OS X specific prefs here - in practice, no user will notice */
        [self resetAndReinitializeUserDefaults];

    } else {
        NSArray *libraries = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory,
            NSUserDomainMask, YES);
        if (!libraries || [libraries count] == 0) return;
        NSString * preferences = [[libraries objectAtIndex:0] stringByAppendingPathComponent:@"Preferences"];

        int res = NSRunInformationalAlertPanel(_NS("Remove old preferences?"),
                    _NS("We just found an older version of VLC's preferences files."),
                    _NS("Move To Trash and Relaunch VLC"), _NS("Ignore"), nil, nil);
        if (res != NSOKButton) {
            [defaults setInteger:kCurrentPreferencesVersion forKey:kVLCPreferencesVersion];
            return;
        }

        // Do NOT add the current plist file here as this would conflict with caching.
        // Instead, just reset below.
        NSArray * ourPreferences = [NSArray arrayWithObjects:@"org.videolan.vlc", @"VLC", nil];

        /* Move the file to trash one by one. Using above array the method would stop after first file
           not found. */
        for (NSString *file in ourPreferences) {
            [[NSWorkspace sharedWorkspace] performFileOperation:NSWorkspaceRecycleOperation source:preferences destination:@"" files:[NSArray arrayWithObject:file] tag:nil];
        }

        [self resetAndReinitializeUserDefaults];
    }

    /* Relaunch now */
    const char * path = [[[NSBundle mainBundle] executablePath] UTF8String];

    /* For some reason we need to fork(), not just execl(), which reports a ENOTSUP then. */
    if (fork() != 0) {
        exit(0);
    }
    execl(path, path, NULL);
}

#pragma mark -
#pragma mark Playlist toggling

- (void)updateTogglePlaylistState
{
    [[self playlist] outlineViewSelectionDidChange: NULL];
}

#pragma mark -

@end

@implementation VLCMain (Internal)

- (void)resetMediaKeyJump
{
    b_mediakeyJustJumped = NO;
}

- (void)coreChangedMediaKeySupportSetting: (NSNotification *)o_notification
{
    b_mediaKeySupport = var_InheritBool(VLCIntf, "macosx-mediakeys");
    if (b_mediaKeySupport && !o_mediaKeyController)
        o_mediaKeyController = [[SPMediaKeyTap alloc] initWithDelegate:self];

    if (b_mediaKeySupport && ([[[[VLCMain sharedInstance] playlist] model] hasChildren] ||
                              [o_input_manager hasInput])) {
        if (!b_mediaKeyTrapEnabled) {
            b_mediaKeyTrapEnabled = YES;
            msg_Dbg(p_intf, "Enable media key support");
            [o_mediaKeyController startWatchingMediaKeys];
        }
    } else {
        if (b_mediaKeyTrapEnabled) {
            b_mediaKeyTrapEnabled = NO;
            msg_Dbg(p_intf, "Disable media key support");
            [o_mediaKeyController stopWatchingMediaKeys];
        }
    }
}

@end

/*****************************************************************************
 * VLCApplication interface
 *****************************************************************************/

@implementation VLCApplication
// when user selects the quit menu from dock it sends a terminate:
// but we need to send a stop: to properly exits libvlc.
// However, we are not able to change the action-method sent by this standard menu item.
// thus we override terminate: to send a stop:
// see [af97f24d528acab89969d6541d83f17ce1ecd580] that introduced the removal of setjmp() and longjmp()
- (void)terminate:(id)sender
{
    [self activateIgnoringOtherApps:YES];
    [self stop:sender];
}

@end
