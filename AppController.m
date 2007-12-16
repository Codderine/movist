//
//  Movist
//
//  Copyright 2006, 2007 Yong-Hoe Kim. All rights reserved.
//      Yong-Hoe Kim  <cocoable@gmail.com>
//
//  This file is part of Movist.
//
//  Movist is free software; you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation; either version 3 of the License, or
//  (at your option) any later version.
//
//  Movist is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

#import "AppController.h"
#import "NewVersionChecker.h"
#import "UserDefaults.h"

#import "MMovie_FFMPEG.h"
#import "MMovie_QuickTime.h"
#import "Playlist.h"
#import "PlaylistController.h"
#import "PreferenceController.h"

#import "MMovieView.h"
#import "MainWindow.h"
#import "FullScreener.h"
#import "FullWindow.h"
#import "PlayPanel.h"
#import "CustomControls.h"
#import "ControlPanel.h"

@implementation AppController

- (id)init
{
    TRACE(@"%s", __PRETTY_FUNCTION__);
    if (self = [super init]) {
        NSDictionary* dict = [NSDictionary dictionaryWithContentsOfFile:
                            @"/System/Library/CoreServices/SystemVersion.plist"];
        NSString* systemVersion = [dict objectForKey:@"ProductVersion"];
        _isSystemLeopard = (0 <= [systemVersion compare:@"10.5"]);

        _playlist = [[Playlist alloc] init];
        _audioTrackIndexSet = [[NSMutableIndexSet alloc] init];
        _subtitleNameSet = [[NSMutableSet alloc] init];
        _fullScreenLock = [[NSLock alloc] init];

        _defaults = [NSUserDefaults standardUserDefaults];
    }
    return self;
}

- (void)awakeFromNib
{
    TRACE(@"%s", __PRETTY_FUNCTION__);
    // init UI
    [_mainWindow setReleasedWhenClosed:FALSE];
    [_mainWindow setExcludedFromWindowsMenu:TRUE];
    [_playPanel setControlPanel:_controlPanel];
    [self updatePlayUI];

    [_volumeSlider      setMinValue:0.0];   [_volumeSlider      setMaxValue:MAX_VOLUME];
    [_panelVolumeSlider setMinValue:0.0];   [_panelVolumeSlider setMaxValue:MAX_VOLUME];
    [self updateVolumeUI];

    _playRate = 1.0;
    _prevMovieTime = 0.0;
    _viewDuration = [_defaults boolForKey:MViewDurationKey];
    [_lTimeTextField setClickable:FALSE];   [_panelLTimeTextField setClickable:FALSE];
    [_rTimeTextField setClickable:TRUE];    [_panelRTimeTextField setClickable:TRUE];

    _decoderButton = [_mainWindow createDecoderButton];
    [self updateDecoderUI];

    initSubtitleEncodingMenu(_subtitleEncodingMenu, @selector(reopenSubtitleAction:));

    // set modifier keys (I don't know how to set Shift key mask)
    unsigned int mask = NSAlternateKeyMask | NSShiftKeyMask;
    [_seekBackward3MenuItem setKeyEquivalentModifierMask:mask];
    [_seekForward3MenuItem setKeyEquivalentModifierMask:mask];

    mask = NSAlternateKeyMask | NSShiftKeyMask | NSControlKeyMask;
    [_seekPrevSubtitleMenuItem setKeyEquivalentModifierMask:mask];
    [_seekNextSubtitleMenuItem setKeyEquivalentModifierMask:mask];

    mask = NSCommandKeyMask | NSShiftKeyMask;
    [_rateSlowerMenuItem setKeyEquivalentModifierMask:mask];
    [_rateFasterMenuItem setKeyEquivalentModifierMask:mask];
    [_rateDefaultMenuItem setKeyEquivalentModifierMask:mask];

    mask = NSControlKeyMask | NSShiftKeyMask;
    [_syncLaterMenuItem setKeyEquivalentModifierMask:mask];
    [_syncEarlierMenuItem setKeyEquivalentModifierMask:mask];
    [_syncDefaultMenuItem setKeyEquivalentModifierMask:mask];

    [self initRemoteControl];
}

- (void)dealloc
{
    TRACE(@"%s", __PRETTY_FUNCTION__);
    [self cleanupRemoteControl];
    [self closeMovie];
    [_decoderButton release];
    [_fullScreenLock release];
    [_subtitleNameSet release];
    [_audioTrackIndexSet release];
    [_playlist release];
    [_playlistController release];
    [_preferenceController release];
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    [super dealloc];
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark -

- (void)applicationWillFinishLaunching:(NSNotification*)aNotification
{
    TRACE(@"%s", __PRETTY_FUNCTION__);
    // hover-images should be set after -awakeFromNib.
    [_controlPanelButton setHoverImage:[NSImage imageNamed:@"MainControlPanelHover"]];
    [_playlistButton setHoverImage:[NSImage imageNamed:@"MainPlaylistHover"]];

    // initial update preferences: general
    [_mainWindow setAlwaysOnTop:[_defaults boolForKey:MAlwaysOnTopKey]];
    [_movieView setActivateOnDragging:[_defaults boolForKey:MActivateOnDraggingKey]];
    [self setQuitWhenWindowClose:[_defaults boolForKey:MQuitWhenWindowCloseKey]];
    [self setSeekInterval:[_defaults floatForKey:MSeekInterval0Key] atIndex:0];
    [self setSeekInterval:[_defaults floatForKey:MSeekInterval1Key] atIndex:1];
    [self setSeekInterval:[_defaults floatForKey:MSeekInterval2Key] atIndex:2];

    // initial update preferences: video
    [_movieView setFullScreenUnderScan:[_defaults floatForKey:MFullScreenUnderScanKey]];

    // initial update preferences: audio
    // ...

    // initial update preferences: subtitle
    BOOL displayOnLetterBox = [_defaults boolForKey:MSubtitleDisplayOnLetterBoxKey];
    [_movieView setSubtitleFontName:[_defaults stringForKey:MSubtitleFontNameKey]
                               size:[_defaults floatForKey:MSubtitleFontSizeKey]];
    [_movieView setSubtitleTextColor:[_defaults colorForKey:MSubtitleTextColorKey]];
    [_movieView setSubtitleStrokeColor:[_defaults colorForKey:MSubtitleStrokeColorKey]];
    [_movieView setSubtitleStrokeWidth:[_defaults floatForKey:MSubtitleStrokeWidthKey]];
    [_movieView setSubtitleShadowColor:[_defaults colorForKey:MSubtitleShadowColorKey]];
    [_movieView setSubtitleShadowBlur:[_defaults floatForKey:MSubtitleShadowBlurKey]];
    [_movieView setSubtitleShadowOffset:[_defaults floatForKey:MSubtitleShadowOffsetKey]];
    [_movieView setSubtitleShadowDarkness:[_defaults integerForKey:MSubtitleShadowDarknessKey]];
    [_movieView setSubtitleDisplayOnLetterBox:displayOnLetterBox];
    [_movieView setLetterBoxHeight:[_defaults integerForKey:MSubtitleLetterBoxHeightKey]];
    [_movieView setSubtitleHMargin:[_defaults floatForKey:MSubtitleHMarginKey]];
    [_movieView setSubtitleVMargin:[_defaults floatForKey:MSubtitleVMarginKey]];
    [_subtitleDisplayOnLetterBoxMenuItem setState:displayOnLetterBox];
    [_subtitleDisplayOnLetterBoxButton setState:displayOnLetterBox];
    [_letterBoxHigherButton setEnabled:displayOnLetterBox];
    [_letterBoxLowerButton setEnabled:displayOnLetterBox];
    [_letterBoxDefaultHeightButton setEnabled:displayOnLetterBox];

    // initial update preferences: advanced
    // ...

    [self updateUI];
    
    [self checkForUpdatesOnStartup];
}

- (void)applicationWillBecomeActive:(NSNotification*)aNotification
{
    TRACE(@"%s", __PRETTY_FUNCTION__);
    [self startRemoteControl];
}

- (void)applicationWillResignActive:(NSNotification*)aNotification
{
    TRACE(@"%s", __PRETTY_FUNCTION__);
    [self stopRemoteControl];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)theApplication
{
    TRACE(@"%s", __PRETTY_FUNCTION__);
    return _quitWhenWindowClose;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication*)theApplication
                    hasVisibleWindows:(BOOL)flag
{
    TRACE(@"%s %d", __PRETTY_FUNCTION__, flag);
    [_mainWindow makeKeyAndOrderFront:self];
    return FALSE;
}

- (void)applicationWillTerminate:(NSNotification*)aNotification
{
    TRACE(@"%s", __PRETTY_FUNCTION__);
    [_defaults synchronize];
}

- (BOOL)application:(NSApplication*)theApplication openFile:(NSString*)filename
{
    TRACE(@"%s:\"%@\"", __PRETTY_FUNCTION__, filename);
    return [self openFile:filename];
}

- (void)application:(NSApplication*)theApplication openFiles:(NSArray*)filenames
{
    TRACE(@"%s:{%@}", __PRETTY_FUNCTION__, filenames);
    if ([self openFiles:filenames]) {
        [NSApp replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
    }
    else {
        [NSApp replyToOpenOrPrint:NSApplicationDelegateReplyFailure];
    }
}

- (void)windowWillClose:(NSNotification*)aNotification
{
    if ([aNotification object] != [_movieView window]) {
        [[_movieView window] makeKeyWindow];
    }
}

- (BOOL)isSystemLeopard { return _isSystemLeopard; }

////////////////////////////////////////////////////////////////////////////////
#pragma mark -

- (MMovie*)movie     { return _movie; }
- (NSURL*)movieURL    { return (_movie) ?     [[_playlist currentItem] movieURL] : nil; }
- (NSURL*)subtitleURL { return (_subtitles) ? [[_playlist currentItem] subtitleURL] : nil; }

- (void)updateUI
{
    //TRACE(@"%s", __PRETTY_FUNCTION__);
    NSURL* movieURL = [self movieURL];
    [_mainWindow setMovieURL:movieURL];
    [_fullScreener setMovieURL:movieURL];
    [_controlPanel setMovieURL:movieURL];
    [_propertiesView reloadData];
    [self updateAspectRatioMenu];
    [self updateAudioTrackMenuItems];
    [self updateSubtitleLanguageMenuItems];
    [self updateRepeatUI];
    [self updateVolumeUI];
    [self updateTimeUI];
    [self updatePlayUI];
    [self updateDecoderUI];
    [_playlistController updateUI];
}

- (void)setQuitWhenWindowClose:(BOOL)quitWhenWindowClose
{
    TRACE(@"%s %d", __PRETTY_FUNCTION__, quitWhenWindowClose);
    _quitWhenWindowClose = quitWhenWindowClose;
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark -

- (void)checkForUpdatesOnStartup
{
    NSTimeInterval timeInterval;
    switch ([_defaults integerForKey:MUpdateCheckIntervalKey]) {
        case CHECK_UPDATE_NEVER   : return; // don't check automatically
        case CHECK_UPDATE_DAILY   : timeInterval =  1 * 24 * 60 * 60;   break;
        case CHECK_UPDATE_WEEKLY  : timeInterval =  7 * 24 * 60 * 60;   break;
        case CHECK_UPDATE_MONTHLY :
        default                   : timeInterval = 30 * 24 * 60 * 60;   break;
    }
    NSDate* lastCheckTime = [_defaults objectForKey:MLastUpdateCheckTimeKey];
    NSTimeInterval interval = [[NSDate date] timeIntervalSinceDate:lastCheckTime];
    if (timeInterval <= interval) {
        [self checkForUpdates:FALSE];
    }
}

- (void)checkForUpdates:(BOOL)manual
{
    [_movieView setMessage:NSLocalizedString(@"Checking for Updates...", nil)];
    [_movieView display];

    NSError* error;
    NewVersionChecker* checker = [[NewVersionChecker alloc] init];
    int ret = [checker checkNewVersion:&error];
    [_defaults setObject:[NSDate date] forKey:MLastUpdateCheckTimeKey];
    [_preferenceController updateLastUpdateCheckTimeTextField];

    if (ret == NEW_VERSION_CHECK_FAILED) {
        NSString* s = [NSString stringWithFormat:@"%@", error];
        if (manual) {   // only for manual checking
            NSRunAlertPanel([NSApp localizedAppName], s,
                            NSLocalizedString(@"OK", nil), nil, nil);
        }
        else {
            [_movieView setMessage:s];
        }
    }
    else if (ret == NEW_VERSION_NONE) {
        NSString* s = NSLocalizedString(@"No new version", nil);
        if (manual) {   // only for manual checking
            NSRunAlertPanel([NSApp localizedAppName], s,
                            NSLocalizedString(@"OK", nil), nil, nil);
        }
        else {
            [_movieView setMessage:s];
        }
    }
    else if (ret == NEW_VERSION_IS_AVAILABLE) {
        // new version alert always show.
        NSString* newVersion = [checker newVersion];
        NSURL* newVersionURL = [checker newVersionURL];
        NSString* s = [NSString stringWithFormat:
                        NSLocalizedString(@"New version is available. (v%@)", nil),
                        newVersion];
        ret = NSRunAlertPanel([NSApp localizedAppName], s,
                              NSLocalizedString(@"Show New Version", nil),
                              NSLocalizedString(@"Cancel", nil), nil);
        if (ret == NSAlertDefaultReturn) {
            [[NSWorkspace sharedWorkspace] openURL:newVersionURL];
        }
    }
    [checker release];
}

- (IBAction)viewDurationAction:(id)sender
{
    //NSLog(@"%s", __PRETTY_FUNCTION__);
    _viewDuration = !_viewDuration;
    [_defaults setBool:_viewDuration forKey:MViewDurationKey];
    [self updateTimeUI];
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark panels

- (IBAction)controlPanelAction:(id)sender
{
    TRACE(@"%s", __PRETTY_FUNCTION__);
    if ([_controlPanel isVisible]) {
        [_controlPanel hidePanel];
    }
    else {
        [_controlPanel showPanel];
        //[_controlPanel makeKeyWindow];
    }
}

- (IBAction)preferencePanelAction:(id)sender
{
    TRACE(@"%s", __PRETTY_FUNCTION__);
    if (!_preferenceController) {
        _preferenceController = [[PreferenceController alloc]
                            initWithAppController:self mainWindow:_mainWindow];
    }
    [_preferenceController showWindow:self];
    [[_preferenceController window] setDelegate:self];
    [[_preferenceController window] makeKeyWindow];
    [_playPanel orderOutWithFadeOut:self];
}

@end

////////////////////////////////////////////////////////////////////////////////
#pragma mark -

@implementation AppController (NSMenuValidation)

- (BOOL)validateMenuItem:(NSMenuItem*)menuItem
{
    //TRACE(@"%s \"%@\"", __PRETTY_FUNCTION__, [menuItem title]);
    if ([[NSApp keyWindow] firstResponder] != _movieView) {
        if ([NSApp keyWindow] == [_playlistController window] &&
            [menuItem action] == @selector(playlistAction:)) {
            return TRUE;
        }
        return FALSE;
    }
    if (![self isFullScreen] && _playlistController &&
        [[_playlistController window] isVisible]) {
        return FALSE;
    }

    // File
    if ([menuItem action] == @selector(openURLAction:)) {
        return FALSE;   // not supported yet
    }
    if ([menuItem action] == @selector(reopenMovieAction:)) {
        return (_movie != nil);
    }

    // Controls
    if ([menuItem action] == @selector(seekAction:)) {
        if ([menuItem tag] == 40 || [menuItem tag] == -40) {
            return (_movie != nil && _subtitles != nil);
        }
        else {
            return (_movie != nil);
        }
    }
    if ([menuItem action] == @selector(prevNextMovieAction:)) {
        return (0 < [_playlist count]);
    }
    if ([menuItem action] == @selector(rangeRepeatAction:)) {
        return (_movie != nil);
    }
    
    // Movie
    if ([menuItem action] == @selector(movieSizeAction:)) {
        return _movie && ![self isFullScreen];
    }
    if ([menuItem action] == @selector(fullScreenAction:) ||
        [menuItem action] == @selector(fullScreenFillAction:) ||
        [menuItem action] == @selector(aspectRatioAction:)) {
        return (_movie != nil);
    }
    if ([menuItem action] == @selector(fullScreenUnderScanAction:)) {
        return (_movie && 0 < [_defaults floatForKey:MFullScreenUnderScanKey]);
    }
    if ([menuItem action] == @selector(audioTrackAction:)) {
        return (_movie && 0 < [[_movie audioTracks] count]);
    }

    // Subtitle
    if ([menuItem action] == @selector(openSubtitleFileAction:)) {
        return _movie && [_defaults boolForKey:MSubtitleEnableKey];
    }
    if ([menuItem action] == @selector(subtitleLanguageAction:)) {
        return (_subtitles && 0 < [_subtitles count]);
    }
    if ([menuItem action] == @selector(reopenSubtitleAction:) ||
        [menuItem action] == @selector(subtitleVisibleAction:) ||
        [menuItem action] == @selector(subtitleFontSizeAction:) ||
        [menuItem action] == @selector(subtitleVMarginAction:) ||
        [menuItem action] == @selector(subtitleDisplayOnLetterBoxAction:) ||
        [menuItem action] == @selector(subtitleSyncAction:)) {
        return (_subtitles != nil);
    }
    if ([menuItem action] == @selector(letterBoxHeightAction:)) {
        return (_subtitles && [_movieView subtitleDisplayOnLetterBox]);
    }

    return TRUE;
}

@end