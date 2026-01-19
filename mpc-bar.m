// Copyright (C) 2023-2025 Spencer Williams

// SPDX-License-Identifier: GPL-2.0-or-later

// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License as
// published by the Free Software Foundation; either version 2 of the
// License, or (at your option) any later version.

// This program is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program; if not, see
// <https://www.gnu.org/licenses/>.

#include "ini.h"
#include "mpc/song_format.h"

#include <assert.h>
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <mpd/client.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#import <Cocoa/Cocoa.h>
#import <MediaPlayer/MediaPlayer.h>

#define VERSION "0.7.0"

static NSString *utf8String(const char *s) {
  return [NSString stringWithCString:s encoding:NSUTF8StringEncoding];
}

static NSString *formatTime(unsigned int t) {
  unsigned int hours = (t / 3600), minutes = (t % 3600 / 60),
               seconds = (t % 60);

  if (hours)
    return [NSString stringWithFormat:@"%u:%02u:%02u", hours, minutes, seconds];
  else
    return [NSString stringWithFormat:@"%u:%02u", minutes, seconds];
}

struct config {
  const char *host, *password, *format, *idle_message, *lua_filter;
  int show_queue, show_queue_idle, show_title_on_bar;
  unsigned port;
  unsigned title_max_length;
  double sleep_interval;
};

static int handler(void *userdata, const char *section, const char *name,
                   const char *value) {
#define MATCH(s, n) ((strcmp(section, s) == 0) && (strcmp(name, n) == 0))
  struct config *c = (struct config *)userdata;
  if (MATCH("connection", "host")) {
    c->host = strdup(value);
  } else if (MATCH("connection", "port")) {
    c->port = atoi(value);
  } else if (MATCH("connection", "password")) {
    c->password = strdup(value);
  } else if (MATCH("display", "format")) {
    c->format = strdup(value);
  } else if (MATCH("display", "idle_message")) {
    c->idle_message = strdup(value);
  } else if (MATCH("display", "show_queue")) {
    c->show_queue = (strcmp(value, "false") != 0);
  } else if (MATCH("display", "show_queue_idle")) {
    c->show_queue_idle = (strcmp(value, "false") != 0);
  } else if (MATCH("display", "show_title_on_bar")) {
    c->show_title_on_bar = (strcmp(value, "false") != 0);
  } else if (MATCH("display", "lua_filter")) {
    c->lua_filter = strdup(value);
  } else if (MATCH("display", "title_max_length")) {
    c->title_max_length = atoi(value);
  } else if (MATCH("display", "sleep_interval")) {
    c->sleep_interval = atof(value);
  } else {
    return 0;
  }
  return 1;
#undef MATCH
}

@interface MPDController : NSObject
@end

@implementation MPDController {
  struct config config;
  struct mpd_connection *connection;
  BOOL songMenuNeedsUpdate;

  NSString *errorMessage;
  NSMenu *controlMenu;
  NSMenuItem *titleItem, *timeItem, *timeSeparator, *playPauseItem, *stopItem, *nextItem,
      *previousItem, *singleItem, *clearItem, *updateDatabaseItem,
      *addToQueueItem;
  NSImage *playImage, *pauseImage, *stopImage, *nextImage, *previousImage,
      *singleImage, *clearImage;
  NSButton *menuButton;

  NSMenu *songMenu;
  NSMapTable *songMap;

  lua_State *L;
  const char *luaFilterPath;
  NSString *luaFilterContent;
}
- (void)initConfig {
  config.host = "localhost";
  config.port = 6600;
  config.format =
      "[%name%: &[[%artist%|%performer%|%composer%|%albumartist%] - "
      "]%title%]|%name%|[[%artist%|%performer%|%composer%|%albumartist%] - "
      "]%title%|%file%";
  config.idle_message = "No song playing";
  config.show_queue = 1;
  config.show_queue_idle = -1;
  config.show_title_on_bar = 1;
  config.title_max_length = 96;
  config.sleep_interval = 0.2;
}
- (BOOL)tryReadConfigFile:(NSString *)file {
  return (0 == ini_parse([[NSHomeDirectory()
                             stringByAppendingPathComponent:file] UTF8String],
                         handler, &config));
}
- (void)readConfigFile {
  if (!([self tryReadConfigFile:@".mpc-bar.ini"] ||
        [self tryReadConfigFile:@".mpcbar"])) {
    NSLog(@"Failed to read config file");
  }
  if (config.show_queue_idle == -1) {
    config.show_queue_idle = config.show_queue;
  }
}
- (BOOL)loadLuaFilter {
  // Read the current file content
  NSString *path = [NSString stringWithUTF8String:luaFilterPath];
  NSError *error = nil;
  NSString *content = [NSString stringWithContentsOfFile:path
                                                encoding:NSUTF8StringEncoding
                                                   error:&error];
  if (!content) {
    NSLog(@"Failed to read Lua filter file: %@", error);
    return NO;
  }

  // Load or reload the Lua filter script
  if (luaL_dofile(L, luaFilterPath) != LUA_OK) {
    NSLog(@"Failed to load Lua filter: %s", lua_tostring(L, -1));
    return NO;
  }

  // Verify the filter function exists
  lua_getglobal(L, "filter");
  if (!lua_isfunction(L, -1)) {
    NSLog(@"Lua filter script must define a 'filter' function");
    lua_pop(L, 1);
    return NO;
  }
  lua_pop(L, 1);  // Remove function from stack, leaving it in global namespace

  // Store the content for comparison next time
  luaFilterContent = content;

  return YES;
}
- (void)initLua {
  if (config.lua_filter) {
    L = luaL_newstate();
    luaL_openlibs(L);
    luaFilterPath = [[utf8String(config.lua_filter) stringByStandardizingPath]
        cStringUsingEncoding:NSUTF8StringEncoding];
    luaFilterContent = nil;

    // Load the Lua script once at initialization
    if (![self loadLuaFilter]) {
      lua_close(L);
      L = NULL;
    }
  }
}
- (const char *)runLuaFilterOn:(const char *)s {
  // L will be NULL if initialization failed or no filter configured
  if (!L) {
    return s;
  }

  // Check if the file content has changed
  NSString *path = [NSString stringWithUTF8String:luaFilterPath];
  NSString *currentContent = [NSString stringWithContentsOfFile:path
                                                       encoding:NSUTF8StringEncoding
                                                          error:nil];

  // Reload if content changed
  if (currentContent && ![currentContent isEqualToString:luaFilterContent]) {
    NSLog(@"Lua filter file changed, reloading...");
    [self loadLuaFilter];
  }

  // Clean up any previous results on the stack
  lua_settop(L, 0);

  lua_getglobal(L, "filter");
  if (!lua_isfunction(L, -1)) {
    return s;
  }
  lua_pushstring(L, s);
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
    return s;
  }
  // Return pointer to string on stack (caller must copy immediately)
  return lua_tostring(L, -1);
}
- (void)connect {
  assert(connection == NULL);

  connection = mpd_connection_new(config.host, config.port, 0);
  if (!connection) {
    NSLog(@"Failed to create MPD connection");
    exit(1);
  }

  errorMessage = @"Failed to get status (is MPD running?)";
  if (mpd_connection_get_error(connection) == MPD_ERROR_SUCCESS) {
    if (config.password != NULL) {
      if (!mpd_run_password(connection, config.password)) {
        errorMessage = @"Auth failed (please fix password and restart service)";
      }
    }
  }

  songMenuNeedsUpdate = YES;
}
- (void)disconnect {
  assert(connection != NULL);
  mpd_connection_free(connection);
  connection = NULL;
  [songMap removeAllObjects];
  [songMenu removeAllItems];
}
- (void)disableAllItems {
  [playPauseItem setEnabled:NO];
  [stopItem setEnabled:NO];
  [nextItem setEnabled:NO];
  [previousItem setEnabled:NO];
  [singleItem setEnabled:NO];
  [updateDatabaseItem setEnabled:NO];
  [addToQueueItem setEnabled:NO];
}
- (void)updateLoop {
  for (;;) {
    [NSThread sleepForTimeInterval:config.sleep_interval];
    if (!connection) {
      [self disableAllItems];
      [self showError:errorMessage];
      [self connect];
    }
    if (!mpd_send_idle(connection)) {
      [self disconnect];
      continue;
    }
    enum mpd_idle mask = mpd_run_noidle(connection);
    enum mpd_error err;
    if (mask == 0 &&
        (err = mpd_connection_get_error(connection)) != MPD_ERROR_SUCCESS) {
      NSLog(@"mpd_run_idle error code %d: %s", err,
            mpd_connection_get_error_message(connection));
      [self disconnect];
      continue;
    }

    if ((mask & MPD_IDLE_DATABASE) || songMenuNeedsUpdate) {
      [self performSelectorOnMainThread:@selector(updateSongMenu)
                             withObject:nil
                          waitUntilDone:YES];
      songMenuNeedsUpdate = NO;
    }

    [self performSelectorOnMainThread:@selector(updateControlMenu)
                           withObject:nil
                        waitUntilDone:YES];

    [self performSelectorOnMainThread:@selector(updateStatus)
                           withObject:nil
                        waitUntilDone:YES];
  }
}
- (void)updateControlMenu {
  if (!connection)
    return;

  struct mpd_status *status = NULL;
  struct mpd_song *song = NULL;
  NSString *errorMsg = nil;
  NSString *displayTitle = nil;

  NSMutableString *output = [NSMutableString new];

  status = mpd_run_status(connection);
  if (!status) {
    NSLog(@"%s", mpd_connection_get_error_message(connection));

    [self disconnect];
    goto cleanup;
  }

  enum mpd_state state = mpd_status_get_state(status);
  enum mpd_single_state single = mpd_status_get_single_state(status);
  bool active = (state == MPD_STATE_PLAY || state == MPD_STATE_PAUSE);
  if (active) {
    song = mpd_run_current_song(connection);
    if (!song) {
      errorMsg = @"Failed to retrieve current song";
      goto cleanup;
    }

    if (mpd_connection_get_error(connection) != MPD_ERROR_SUCCESS) {
      errorMsg = utf8String(mpd_connection_get_error_message(connection));
      goto cleanup;
    }

    if (state == MPD_STATE_PAUSE)
      [menuButton setImage:pauseImage];
    else if (state == MPD_STATE_PLAY &&
             (single == MPD_SINGLE_ON || single == MPD_SINGLE_ONESHOT))
      [menuButton setImage:singleImage];
    else if (config.show_title_on_bar)
      [menuButton setImage:nil];
    else
      [menuButton setImage:playImage];

    char *s = format_song(song, config.format);
    if (L) {
      [output appendString:utf8String([self runLuaFilterOn:s])];
    } else {
      [output appendString:utf8String(s)];
    }
    free(s);
  } else {
    // FIXME: There's no point calling utf8String more than once, as
    // idle_message never changes.
    [output setString:utf8String(config.idle_message)];
    if (config.show_title_on_bar)
      [menuButton setImage:nil];
    else
      [menuButton setImage:stopImage];
  }

  int song_pos = mpd_status_get_song_pos(status);
  unsigned int queue_length = mpd_status_get_queue_length(status);

  if ((active && config.show_queue) || (!active && config.show_queue_idle)) {
    if (song_pos < 0)
      [output appendFormat:@" (%u)", queue_length];
    else
      [output appendFormat:@" (%u/%u)", song_pos + 1, queue_length];
  }

  if ([output length] > config.title_max_length) {
    int leftCount = (config.title_max_length - 3) / 2;
    int rightCount = config.title_max_length - leftCount - 3;
    displayTitle = [@[
                  [output substringToIndex:leftCount],
                  [output substringFromIndex:[output length] - rightCount]
                ] componentsJoinedByString:@"..."];
  } else {
    displayTitle = output;
  }

  // Always show title in dropdown menu
  [titleItem setTitle:displayTitle];

  // Conditionally show title on menu bar
  if (config.show_title_on_bar) {
    [menuButton setTitle:displayTitle];
  } else {
    [menuButton setTitle:@""];
  }

  if (state == MPD_STATE_PLAY) {
    [playPauseItem setTitle:@"Pause"];
    [playPauseItem setImage:pauseImage];
    [playPauseItem setAction:@selector(pause)];
    [playPauseItem setEnabled:YES];
  } else {
    [playPauseItem setTitle:@"Play"];
    [playPauseItem setImage:playImage];
    [playPauseItem setAction:@selector(play)];
    [playPauseItem setEnabled:(queue_length > 0)];
  }
  [stopItem setEnabled:active];
  [nextItem setEnabled:(active && (song_pos < (queue_length - 1)))];
  [previousItem setEnabled:(active && (song_pos > 0))];

  if (queue_length == 0 && single == MPD_SINGLE_ONESHOT) {
    [self single_off];
    single = MPD_SINGLE_OFF;
  }

  if (single == MPD_SINGLE_OFF) {
    [singleItem setTitle:@"Pause After This Track"];
    [singleItem setAction:@selector(single_oneshot)];
  } else {
    [singleItem setTitle:@"Keep Playing After This Track"];
    [singleItem setAction:@selector(single_off)];
  }

  [singleItem setEnabled:(active && (song_pos < queue_length))];
  [clearItem setEnabled:(queue_length > 0)];
  [updateDatabaseItem setEnabled:YES];

  [self updateNowPlayingInfoWithStatus:status song:song];

cleanup:
  if (song)
    mpd_song_free(song);
  if (status)
    mpd_status_free(status);

  if (errorMsg)
    [self showError:errorMsg];
}
- (void)updateNowPlayingInfoWithStatus:(struct mpd_status *)status song:(struct mpd_song *)song {
  // Clear Now Playing when disconnected or no status
  if (!connection || !status) {
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = nil;
    return;
  }

  enum mpd_state state = mpd_status_get_state(status);
  bool active = (state == MPD_STATE_PLAY || state == MPD_STATE_PAUSE);

  // Clear Now Playing when stopped/inactive or no current song
  if (!active || !song) {
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = nil;
    return;
  }

  // Extract metadata from MPD song
  const char *title_raw = mpd_song_get_tag(song, MPD_TAG_TITLE, 0);
  const char *artist_raw = mpd_song_get_tag(song, MPD_TAG_ARTIST, 0);
  const char *album_raw = mpd_song_get_tag(song, MPD_TAG_ALBUM, 0);
  const char *name_raw = mpd_song_get_tag(song, MPD_TAG_NAME, 0);

  // Fallback strategy: use stream name if title is missing, or URI as last resort
  NSString *title = title_raw ? utf8String(title_raw)
                              : (name_raw ? utf8String(name_raw)
                                          : utf8String(mpd_song_get_uri(song)));
  NSString *artist = artist_raw ? utf8String(artist_raw) : @"";
  NSString *album = album_raw ? utf8String(album_raw) : @"";

  // Get timing information
  unsigned int elapsed = mpd_status_get_elapsed_time(status);
  unsigned int duration = mpd_song_get_duration(song);

  // Build Now Playing info dictionary
  NSMutableDictionary *nowPlayingInfo = [NSMutableDictionary dictionary];

  nowPlayingInfo[MPMediaItemPropertyTitle] = title;
  if ([artist length] > 0) {
    nowPlayingInfo[MPMediaItemPropertyArtist] = artist;
  }
  if ([album length] > 0) {
    nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = album;
  }

  // Set playback rate: 1.0 for playing, 0.0 for paused
  nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] =
    @(state == MPD_STATE_PLAY ? 1.0 : 0.0);

  // Set elapsed time
  nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(elapsed);

  // Set duration if available (0 means unknown/stream)
  if (duration > 0) {
    nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = @(duration);
  }

  // Update Now Playing Info Center
  MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = nowPlayingInfo;
}
- (NSMenuItem *)addControlMenuItemWithTitle:(NSString *)title
                                      image:(NSImage *)image
                                     action:(SEL)selector {
  NSMenuItem *item = [controlMenu addItemWithTitle:title
                                            action:selector
                                     keyEquivalent:@""];
  [item setTarget:self];
  [item setEnabled:NO];
  [item setImage:image];

  return item;
}
- (void)initControlMenu {
  controlMenu = [NSMenu new];
  [controlMenu setAutoenablesItems:NO];

#define ICON(NAME, DESC)                                                       \
  [NSImage imageWithSystemSymbolName:@NAME accessibilityDescription:@DESC]

  playImage = ICON("play.fill", "Play");
  pauseImage = ICON("pause.fill", "Pause");
  stopImage = ICON("stop.fill", "Stop");
  nextImage = ICON("forward.fill", "Next");
  previousImage = ICON("backward.fill", "Previous");
  singleImage = ICON("playpause.fill", "Single");
  clearImage = ICON("clear.fill", "Clear");

  titleItem = [NSMenuItem new];
  [titleItem setEnabled:NO];
  [controlMenu insertItem:titleItem atIndex:0];

  timeItem = [NSMenuItem new];
  [timeItem setEnabled:NO];
  timeSeparator = [NSMenuItem separatorItem];

#define ADD_ITEM(TITLE, IMAGE, ACTION)                                         \
  [self addControlMenuItemWithTitle:@TITLE image:IMAGE action:@selector(ACTION)]

  playPauseItem = ADD_ITEM("Play", playImage, play);
  stopItem = ADD_ITEM("Stop", stopImage, stop);
  nextItem = ADD_ITEM("Next Track", nextImage, next);
  previousItem = ADD_ITEM("Previous Track", previousImage, previous);
  singleItem = ADD_ITEM("Pause After This Track", singleImage, single_oneshot);

  [controlMenu addItem:[NSMenuItem separatorItem]];

  updateDatabaseItem = ADD_ITEM("Update Database", nil, update);

  addToQueueItem = [controlMenu addItemWithTitle:@"Add to Queue"
                                          action:nil
                                   keyEquivalent:@""];
  [addToQueueItem setSubmenu:songMenu];
  [addToQueueItem setEnabled:NO];

  [controlMenu addItem:[NSMenuItem separatorItem]];

  clearItem = ADD_ITEM("Clear Queue", nil, clear);

  [controlMenu addItem:[NSMenuItem separatorItem]];
  [controlMenu addItemWithTitle:@"Quit MPC Bar"
                         action:@selector(terminate:)
                  keyEquivalent:@"q"];

  NSStatusBar *bar = [NSStatusBar systemStatusBar];
  NSStatusItem *item = [bar statusItemWithLength:NSVariableStatusItemLength];
  menuButton = [item button];
  [menuButton setImagePosition:NSImageLeft];
  [item setMenu:controlMenu];
  [self updateControlMenu];
  [self updateStatus];
}
- (void)initRemoteCommandCenter {
  MPRemoteCommandCenter *commandCenter = MPRemoteCommandCenter.sharedCommandCenter;

  // Play command
  [commandCenter.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
    [self play];
    return MPRemoteCommandHandlerStatusSuccess;
  }];

  // Pause command
  [commandCenter.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
    [self pause];
    return MPRemoteCommandHandlerStatusSuccess;
  }];

  // Toggle play/pause (for unified play/pause buttons)
  [commandCenter.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
    if (!self->connection) {
      return MPRemoteCommandHandlerStatusNoActionableNowPlayingItem;
    }

    struct mpd_status *status = mpd_run_status(self->connection);
    if (!status) {
      return MPRemoteCommandHandlerStatusNoActionableNowPlayingItem;
    }

    enum mpd_state state = mpd_status_get_state(status);
    mpd_status_free(status);

    if (state == MPD_STATE_PLAY) {
      [self pause];
    } else {
      [self play];
    }
    return MPRemoteCommandHandlerStatusSuccess;
  }];

  // Next track command
  [commandCenter.nextTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
    [self next];
    return MPRemoteCommandHandlerStatusSuccess;
  }];

  // Previous track command
  [commandCenter.previousTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
    [self previous];
    return MPRemoteCommandHandlerStatusSuccess;
  }];

  // Stop command
  [commandCenter.stopCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
    [self stop];
    return MPRemoteCommandHandlerStatusSuccess;
  }];

  // Enable commands
  commandCenter.playCommand.enabled = YES;
  commandCenter.pauseCommand.enabled = YES;
  commandCenter.togglePlayPauseCommand.enabled = YES;
  commandCenter.nextTrackCommand.enabled = YES;
  commandCenter.previousTrackCommand.enabled = YES;
  commandCenter.stopCommand.enabled = YES;
}
- (void)initSongMenu {
  songMap = [NSMapTable new];
  songMenu = [NSMenu new];
  [self updateSongMenu];
}
- (void)updateSongMenu {
  if (!connection)
    return;

  [songMap removeAllObjects];
  [songMenu removeAllItems];
  if (!mpd_send_list_all(connection, "")) {
    [self disconnect];
    return;
  }

  [addToQueueItem setEnabled:YES];

  struct mpd_entity *entity;
  NSMutableArray *menus = [NSMutableArray new];
  [menus addObject:songMenu];
  BOOL directory;
  const char *s;
  while ((entity = mpd_recv_entity(connection))) {
    switch (mpd_entity_get_type(entity)) {
    case MPD_ENTITY_TYPE_DIRECTORY:
      directory = YES;
      s = mpd_directory_get_path(mpd_entity_get_directory(entity));
      break;
    case MPD_ENTITY_TYPE_SONG:
      directory = NO;
      s = mpd_song_get_uri(mpd_entity_get_song(entity));
      break;
    default:
      continue;
    }

    NSString *ss = utf8String(s);
    NSArray *components = [ss pathComponents];

    while ([menus count] > [components count])
      [menus removeLastObject];

    NSString *title =
        directory ? [components lastObject]
                  : [[components lastObject] stringByDeletingPathExtension];

    NSMenuItem *item = [[NSMenuItem alloc]
        initWithTitle:[title stringByReplacingOccurrencesOfString:@":"
                                                       withString:@"/"]
               action:@selector(enqueue:)
        keyEquivalent:@""];

    [item setTarget:self];
    [songMap setObject:ss forKey:item];
    [[menus lastObject] addItem:item];
    if (directory) {
      NSMenu *menu = [NSMenu new];
      [item setSubmenu:menu];
      [menus addObject:menu];
    }
    mpd_entity_free(entity);
  }
}
- (instancetype)init {
  if (self = [super init]) {
    [self initConfig];
    [self readConfigFile];
    [self initLua];
    [self connect];
    [self initSongMenu];
    [self initControlMenu];
    [self initRemoteCommandCenter];

    [[[NSThread alloc] initWithTarget:self
                             selector:@selector(updateLoop)
                               object:nil] start];
  }
  return self;
}
- (void)dealloc {
  mpd_connection_free(connection);
}
- (void)showError:(NSString *)msg {
  [menuButton setTitle:[NSString stringWithFormat:@"MPC Bar: %@", msg]];
}
- (void)play {
  mpd_run_play(connection);
}
- (void)pause {
  mpd_run_pause(connection, true);
}
- (void)stop {
  mpd_run_stop(connection);
}
- (void)next {
  mpd_run_next(connection);
}
- (void)previous {
  mpd_run_previous(connection);
}
- (void)single_oneshot {
  mpd_run_single_state(connection, MPD_SINGLE_ONESHOT);
}
- (void)single_off {
  mpd_run_single_state(connection, MPD_SINGLE_OFF);
}
- (void)update {
  mpd_run_update(connection, NULL);
}
- (void)clear {
  mpd_run_clear(connection);
}
- (void)enqueue:(id)item {
  mpd_run_add(connection, [[songMap objectForKey:item]
                              cStringUsingEncoding:NSUTF8StringEncoding]);
}
- (void)updateStatus {
  struct mpd_status *status = NULL;
  struct mpd_song *song = NULL;

  if (connection)
    status = mpd_run_status(connection);

  if (!status) {
    if (connection)
      [self disconnect];
    return;
  }

  enum mpd_state state = mpd_status_get_state(status);
  bool active = (state == MPD_STATE_PLAY || state == MPD_STATE_PAUSE);

  if (!active || !(song = mpd_run_current_song(connection))) {
    if ([controlMenu indexOfItem:timeItem] >= 0)
      [controlMenu removeItem:timeItem];
    if ([controlMenu indexOfItem:timeSeparator] >= 0)
      [controlMenu removeItem:timeSeparator];
    mpd_status_free(status);
    return;
  }

  unsigned int elapsed = mpd_status_get_elapsed_time(status);
  unsigned int dur = mpd_song_get_duration(song);
  [timeItem
      setTitle:[NSString stringWithFormat:@"%@ / %@", formatTime(elapsed),
                                          (dur > 0) ? formatTime(dur) : @"?"]];

  // Update Now Playing elapsed time if we're playing
  if (state == MPD_STATE_PLAY) {
    NSMutableDictionary *nowPlayingInfo =
      [MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo mutableCopy];
    if (nowPlayingInfo) {
      nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(elapsed);
      MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = nowPlayingInfo;
    }
  }

  if ([controlMenu indexOfItem:timeItem] < 0)
    [controlMenu insertItem:timeItem atIndex:0];
  if ([controlMenu indexOfItem:timeSeparator] < 0)
    [controlMenu insertItem:timeSeparator atIndex:1];

  mpd_song_free(song);
  mpd_status_free(status);
}
@end

int main(int argc, char *argv[]) {
  if (argc > 1 && strcmp(argv[1], "-v") == 0) {
    puts("MPC Bar " VERSION);
    return 0;
  }

  [NSApplication sharedApplication];
  [MPDController new];
  [NSApp run];

  return 0;
}
