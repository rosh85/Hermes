/**
 * @file Models/Pandora.m
 * @brief Implementation of the API with Pandora
 *
 * Currently this is an implementation of the JSON protocol version 5, as
 * documented here: http://pan-do-ra-api.wikia.com/wiki/Json/5
 */

#include <string.h>

#import "FMEngine/NSString+FMEngine.h"
#import "HermesAppDelegate.h"
#import "Pandora.h"
#import "Pandora/Crypt.h"
#import "Pandora/Song.h"
#import "Pandora/Station.h"
#import "PreferencesController.h"
#import <SBJson/SBJson.h>
#import "URLConnection.h"
#import "Notifications.h"
#import "PandoraDevice.h"

#pragma mark Error Codes

static NSString *lowerrs[] = {
  [0] = @"Internal Pandora error",
  [1] = @"Pandora is in Maintenance Mode",
  [2] = @"URL is missing method parameter",
  [3] = @"URL is missing auth token",
  [4] = @"URL is missing partner ID",
  [5] = @"URL is missing user ID",
  [6] = @"A secure protocol is required for this request",
  [7] = @"A certificate is required for the request",
  [8] = @"Paramter type mismatch",
  [9] = @"Parameter is missing",
  [10] = @"Parameter value is invalid",
  [11] = @"API version is not supported",
  [12] = @"Pandora is not available in this country",
  [13] = @"Bad sync time",
  [14] = @"Unknown method name",
  [15] = @"Wrong protocol used"
};

static NSString *hierrs[] = {
  [0] = @"Read only mode",
  [1] = @"Invalid authentication token",
  [2] = @"Wrong user credentials",
  [3] = @"Listener not authorized",
  [4] = @"User not authorized",
  [5] = @"Station limit reached",
  [6] = @"Station does not exist",
  [7] = @"Complimentary period already in use",
  [8] = @"Call not allowed",
  [9] = @"Device not found",
  [10] = @"Partner not authorized",
  [11] = @"Invalid username",
  [12] = @"Invalid password",
  [13] = @"Username already exists",
  [14] = @"Device already associated to account",
  [15] = @"Upgrade, device model is invalid",
  [18] = @"Explicit PIN incorrect",
  [20] = @"Explicit PIN malformed",
  [23] = @"Device model invalid",
  [24] = @"ZIP code invalid",
  [25] = @"Birth year invalid",
  [26] = @"Birth year too young",
  [27] = @"Invalid country code",
  [28] = @"Invalid gender",
  [32] = @"Cannot remove all seeds",
  [34] = @"Device disabled",
  [35] = @"Daily trial limit reached",
  [36] = @"Invalid sponsor",
  [37] = @"User already used trial"
};

#pragma mark - PandoraSearchResult

@implementation PandoraSearchResult

@end

#pragma mark - PandoraRequest

@implementation PandoraRequest

- (id) init {
  if (!(self = [super init])) { return nil; }
  self.authToken = self.partnerId = self.userId = @"";
  self.response = [[NSMutableData alloc] init];
  self.tls = self.encrypted = TRUE;
  return self;
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone {
  PandoraRequest *newRequest = [[PandoraRequest alloc] init];
  
  if (newRequest) {
    newRequest.method = self.method;
    newRequest.authToken = self.authToken;
    newRequest.partnerId = self.partnerId;
    newRequest.userId = self.userId;
    
    newRequest.request = self.request;
    newRequest.response = self.response;
    
    newRequest.callback = self.callback;
    newRequest.tls = self.tls;
    newRequest.encrypted = self.encrypted;
  }
  return newRequest;
}

@end

#pragma mark - Pandora

@interface Pandora ()

/**
 * Convenience method to send a notification from self.
 *
 */
- (void) sendNotification:(NSString*)notificationName withUserInfo:(NSDictionary*)userInfo;

/**
 * @brief Parse the dictionary provided to create a station
 *
 * @param s the dictionary describing the station
 * @return the station object
 */
- (Station*) parseStationFromDictionary: (NSDictionary*) s;

/**
 * @brief Create the default request, with appropriate fields set based on the
 *        current state of authentication
 *
 * @param method the method name for the request to be for
 * @return the PandoraRequest object to further add callbacks to
 */
- (PandoraRequest*) defaultRequestWithMethod: (NSString*) method;

/**
 * @brief Creates a dictionary which contains the default keys necessary for
 *        most requests
 *
 * Currently fills in the "userAuthToken" and "syncTime" fields
 */
- (NSMutableDictionary*) defaultRequestDictionary;

/**
 * Gets the current UNIX time
 */
- (int64_t) time;

@end

@implementation Pandora

@synthesize stations;

- (id)initWithPandoraDevice:(NSDictionary *)device {
  if (self = [self init]) {
    self.device = device;
  }
  return self;
}

- (id) init {
  if ((self = [super init])) {
    stations = [[NSMutableArray alloc] init];
    retries  = 0;
    json_parser = [[SBJsonParser alloc] init];
    json_writer = [[SBJsonWriter alloc] init];
    self.device = [PandoraDevice android];
  }
  return self;
}

- (void) sendNotification: (NSString*)notificationName withUserInfo:(NSDictionary*)userInfo {
  [[NSNotificationCenter defaultCenter] postNotificationName:notificationName
                                                      object:self
                                                    userInfo:userInfo];
}

#pragma mark - Error handling

+ (NSString*) stringForErrorCode: (int) code {
  if (code < 16) {
    return lowerrs[code];
  } else if (code >= 1000 && code <= 1037) {
    return hierrs[code - 1000];
  }
  return nil;
}

#pragma mark - Crypto

- (NSData *)encryptData:(NSData *)data {
  return PandoraEncryptData(data, self.device[kPandoraDeviceEncrypt]);
}

- (NSData *)decryptString:(NSString *)string {
  return PandoraDecryptString(string, self.device[kPandoraDeviceDecrypt]);
}

#pragma mark - Authentication

- (BOOL) authenticate:(NSString*)user
             password:(NSString*)pass
              request:(PandoraRequest*)req {
  PandoraCallback loginCallback = ^(NSDictionary *dict){
    if (req == nil) {
      [self sendNotification:PandoraDidAuthenticateNotification withUserInfo:nil];
    } else {
      NSLogd(@"Retrying request...");
      PandoraRequest *newreq = [req copy];
      
      // Update request with the new user auth token & up-to-date sync time
      [newreq request][@"userAuthToken"] = user_auth_token;
      [newreq request][@"syncTime"] = [self syncTimeNum];
      [self sendRequest:newreq];
    }
  };

  return [self userLogin:user password:pass callback:loginCallback];
}

- (BOOL)userLogin:(NSString *)username password:(NSString *)password callback:(PandoraCallback)callback {
  if (partner_id == nil) {
    // Get partner ID then reinvoke this method
    NSLogd(@"Getting parner ID...");
    return [self partnerLogin:^() {
      [self userLogin:username password:password callback:callback];
    }];
  }
  
  NSMutableDictionary *loginDictionary = [NSMutableDictionary dictionary];
  loginDictionary[@"loginType"]        = @"user";
  loginDictionary[@"username"]         = username;
  loginDictionary[@"password"]         = password;
  loginDictionary[@"partnerAuthToken"] = partner_auth_token;
  loginDictionary[@"syncTime"]         = [self syncTimeNum];
  
  PandoraRequest *loginRequest = [[PandoraRequest alloc] init];
  [loginRequest setRequest:loginDictionary];
  [loginRequest setMethod:@"auth.userLogin"];
  [loginRequest setPartnerId:partner_id];
  [loginRequest setAuthToken:partner_auth_token];
  
  PandoraCallback loginCallback = ^(NSDictionary *respDict) {
    NSDictionary *result = respDict[@"result"];
    user_auth_token = result[@"userAuthToken"];
    user_id = result[@"userId"];
    if (!self.cachedSubscriberStatus) {
      NSLogd(@"Getting subscriber status...");
      // Get subscriber status then reinvoke this method
      [self fetchSubscriberStatus:^(NSDictionary *subDict) {
        self.cachedSubscriberStatus = subDict[@"result"][@"isSubscriber"];
        [self userLogin:username password:password callback:callback];
      }];
      return;
    } else if (self.cachedSubscriberStatus.boolValue &&
               ! [self.device[kPandoraDeviceUsername] isEqualToString:@"pandora one"]) {
      NSLogd(@"Subscriber detected, re-logging-in");
      // Change our device to the desktop client, logout, then reinvoke this method
      self.device = [PandoraDevice desktop];
      [self logoutNoNotify];
      [self userLogin:username password:password callback:callback];
      return;
    }
    NSLogd(@"Logged in.");
    callback(respDict);
  };
  
  [loginRequest setCallback:loginCallback];
  return [self sendRequest:loginRequest];
}

- (BOOL) partnerLogin: (SyncCallback) callback {
  start_time = [self time];
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  d[@"username"] = self.device[kPandoraDeviceUsername];
  d[@"password"] = self.device[kPandoraDevicePassword];
  d[@"deviceModel"] = self.device[kPandoraDeviceDeviceID];
  d[@"version"] = PANDORA_API_VERSION;
  d[@"includeUrls"] = [NSNumber numberWithBool:TRUE];
  
  PandoraRequest *req = [[PandoraRequest alloc] init];
  [req setRequest: d];
  [req setMethod: @"auth.partnerLogin"];
  [req setEncrypted:FALSE];
  [req setCallback:^(NSDictionary* dict) {
    NSDictionary *result = dict[@"result"];
    partner_auth_token = result[@"partnerAuthToken"];
    partner_id = result[@"partnerId"];
    NSData *sync = [self decryptString:result[@"syncTime"]];
    const char *bytes = [sync bytes];
    sync_time = strtoul(bytes + 4, NULL, 10);
    callback();
  }];
  return [self sendRequest:req];
}

- (BOOL)fetchSubscriberStatus:(PandoraCallback)callback {
  assert(user_id != nil);
  
  PandoraRequest *request = [self defaultRequestWithMethod:@"user.canSubscribe"];
  request.callback = ^(NSDictionary *respDict) {
    self.cachedSubscriberStatus = (NSNumber *)respDict[@"result"][@"isSubscriber"];
    NSLogd(@"Subscriber status: %@", self.cachedSubscriberStatus);
    callback(respDict);
  };
  request.request = [self defaultRequestDictionary];
  return [self sendRequest:request];
}

- (void) logout {
  [self logoutNoNotify];
  for (Station *s in stations)
    [Station removeStation:s];
  [stations removeAllObjects];
  [self sendNotification:PandoraDidLogOutNotification withUserInfo:nil];
}

- (void) logoutNoNotify {
  user_auth_token = nil;
  partner_auth_token = nil;
  partner_id = nil;
  user_id = nil;
  sync_time = start_time = 0;
  self.cachedSubscriberStatus = nil;
}

- (BOOL) isAuthenticated {
  return user_auth_token != nil && self.cachedSubscriberStatus;
}

#pragma mark - Station Manipulation

- (BOOL) createStation: (NSString*)musicId {
  NSMutableDictionary *d = [self defaultRequestDictionary];
  d[@"musicToken"] = musicId;
  
  PandoraRequest *req = [self defaultRequestWithMethod:@"station.createStation"];
  [req setRequest:d];
  [req setTls:FALSE];
  [req setCallback:^(NSDictionary* d) {
    NSDictionary *result = d[@"result"];
    Station *s = [self parseStationFromDictionary:result];
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"station"] = s;
    [stations addObject:s];
    [Station addStation:s];
    [self sendNotification:PandoraDidCreateStationNotification withUserInfo:dict];
  }];
  return [self sendAuthenticatedRequest:req];
}

- (BOOL) removeStation: (NSString*)stationToken {
  NSMutableDictionary *d = [self defaultRequestDictionary];
  d[@"stationToken"] = stationToken;
  
  PandoraRequest *req = [self defaultRequestWithMethod:@"station.deleteStation"];
  [req setRequest:d];
  [req setTls:FALSE];
  [req setCallback:^(NSDictionary* d) {
    unsigned int i;
    
    /* Remove the station internally */
    for (i = 0; i < [stations count]; i++) {
      if ([[stations[i] token] isEqual:stationToken]) {
        break;
      }
    }
    
    if ([stations count] == i) {
      NSLogd(@"Deleted unknown station?!");
    } else {
      [Station removeStation:stations[i]];
      [stations removeObjectAtIndex:i];
    }
    
    [self sendNotification:PandoraDidDeleteStationNotification withUserInfo:nil];
  }];
  return [self sendAuthenticatedRequest:req];
}

- (BOOL) renameStation: (NSString*)stationToken to:(NSString*)name {
  NSMutableDictionary *d = [self defaultRequestDictionary];
  d[@"stationToken"] = stationToken;
  d[@"stationName"] = name;
  
  PandoraRequest *req = [self defaultRequestWithMethod:@"station.renameStation"];
  [req setRequest:d];
  [req setTls:FALSE];
  [req setCallback:^(NSDictionary* d) {
    [self sendNotification:PandoraDidRenameStationNotification withUserInfo:nil];
  }];
  return [self sendAuthenticatedRequest:req];
}

#pragma mark Fetch & parse station information from API

- (BOOL) fetchStations {
  NSLogd(@"Fetching stations...");
  
  NSMutableDictionary *d = [self defaultRequestDictionary];
  
  PandoraRequest *r = [self defaultRequestWithMethod:@"user.getStationList"];
  [r setRequest:d];
  [r setTls:FALSE];
  [r setCallback: ^(NSDictionary* dict) {
    NSDictionary *result = dict[@"result"];
    for (NSDictionary *s in result[@"stations"]) {
      Station *station = [self parseStationFromDictionary:s];
      if (![stations containsObject:station]) {
        [stations addObject:station];
        [Station addStation:station];
      }
    };
    
    [self sendNotification:PandoraDidLoadStationsNotification withUserInfo:nil];
  }];
  
  return [self sendAuthenticatedRequest:r];
}

- (Station*) parseStationFromDictionary: (NSDictionary*) s {
  Station *station = [[Station alloc] init];
  
  [station setName:           s[@"stationName"]];
  [station setStationId:      s[@"stationId"]];
  [station setToken:          s[@"stationToken"]];
  [station setShared:        [s[@"isShared"] boolValue]];
  [station setAllowAddMusic: [s[@"allowAddMusic"] boolValue]];
  [station setAllowRename:   [s[@"allowRename"] boolValue]];
  [station setCreated:       [s[@"dateCreated"][@"time"] integerValue]];
  [station setRadio:self];
  
  if ([s[@"isQuickMix"] boolValue]) {
    [station setName:@"QuickMix"];
  }
  return station;
}

// FIXME: Should post a standard notification, not per-invocation choice.
- (BOOL) fetchPlaylistForStation: (Station*) station {
  NSLogd(@"Getting fragment for %@...", [station name]);
  
  NSMutableDictionary *d = [self defaultRequestDictionary];
  d[@"stationToken"] = [station token];
  d[@"additionalAudioUrl"] = @"HTTP_32_AACPLUS_ADTS,HTTP_64_AACPLUS_ADTS,HTTP_128_MP3";
  
  PandoraRequest *r = [self defaultRequestWithMethod:@"station.getPlaylist"];
  [r setRequest:d];
  [r setCallback: ^(NSDictionary* dict) {
    NSDictionary *result = dict[@"result"];
    NSMutableArray *songs = [NSMutableArray array];
    
    for (NSDictionary *s in result[@"items"]) {
      if (s[@"adToken"] != nil) continue; // Skip if this is an adToken
      
      Song *song = [[Song alloc] init];
      
      [song setArtist: s[@"artistName"]];
      [song setTitle: s[@"songName"]];
      [song setAlbum: s[@"albumName"]];
      [song setArt: s[@"albumArtUrl"]];
      [song setStationId: s[@"stationId"]];
      [song setToken: s[@"trackToken"]];
      [song setNrating: s[@"songRating"]];
      [song setAlbumUrl: s[@"albumDetailUrl"]];
      [song setArtistUrl: s[@"artistDetailUrl"]];
      [song setTitleUrl: s[@"songDetailUrl"]];
      
      id urls = s[@"additionalAudioUrl"];
      if ([urls isKindOfClass:[NSArray class]]) {
        NSArray *urlArray = urls;
        [song setLowUrl:urlArray[0]];
        if ([urlArray count] > 1) {
          [song setMedUrl:urlArray[1]];
        } else {
          [song setMedUrl:[song lowUrl]];
          NSLog(@"bad medium format specified in request");
        }
        if ([urlArray count] > 2) {
          [song setHighUrl:urlArray[2]];
        } else {
          [song setHighUrl:[song medUrl]];
          NSLog(@"bad high format specified in request");
        }
      } else {
        NSLog(@"all bad formats in request?");
        [song setLowUrl:urls];
        [song setMedUrl:urls];
        [song setHighUrl:urls];
      }
      
      [songs addObject: song];
    };
    
    NSString *name = [NSString stringWithFormat:@"hermes.fragment-fetched.%@",
                      [station token]];
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"songs"] = songs;
    [self sendNotification:name withUserInfo:d];
  }];
  
  return [self sendAuthenticatedRequest:r];
}

- (BOOL) fetchGenreStations {
  NSMutableDictionary *d = [self defaultRequestDictionary];
  
  PandoraRequest *req = [self defaultRequestWithMethod:@"station.getGenreStations"];
  [req setRequest:d];
  [req setTls:FALSE];
  [req setCallback:^(NSDictionary* d) {
    [self sendNotification:PandoraDidLoadGenreStationsNotification withUserInfo:d[@"result"]];
  }];
  return [self sendAuthenticatedRequest:req];
}

- (BOOL) fetchStationInfo:(Station *)station {
  NSMutableDictionary *d = [self defaultRequestDictionary];
  d[@"stationToken"] = [station token];
  d[@"includeExtendedAttributes"] = [NSNumber numberWithBool:TRUE];
  
  PandoraRequest *req = [self defaultRequestWithMethod:@"station.getStation"];
  [req setRequest:d];
  [req setTls:FALSE];
  [req setCallback:^(NSDictionary* d) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    NSDictionary *result = d[@"result"];
    
    /* General metadata */
    info[@"name"] = result[@"stationName"];
    uint64_t created = [result[@"dateCreated"][@"time"] longLongValue];
    info[@"created"] = [NSDate dateWithTimeIntervalSince1970:created];
    NSString *art = result[@"artUrl"];
    if (art != nil) { info[@"art"] = art; }
    info[@"genres"] = result[@"genre"];
    info[@"url"] = result[@"stationDetailUrl"];
    
    /* Seeds */
    NSMutableDictionary *seeds = [NSMutableDictionary dictionary];
    NSDictionary *music = result[@"music"];
    seeds[@"songs"] = music[@"songs"];
    seeds[@"artists"] = music[@"artists"];
    info[@"seeds"] = seeds;
    
    /* Feedback */
    NSDictionary *feedback = result[@"feedback"];
    info[@"likes"] = feedback[@"thumbsUp"];
    info[@"dislikes"] = feedback[@"thumbsDown"];
    
    [self sendNotification:PandoraDidLoadStationInfoNotification withUserInfo:info];
  }];
  return [self sendAuthenticatedRequest:req];
}

#pragma mark Seed & Feedback Management (see also Song Manipulation)

- (BOOL) deleteFeedback: (NSString*)feedbackId {
  NSLogd(@"deleting feedback: '%@'", feedbackId);
  NSMutableDictionary *d = [self defaultRequestDictionary];
  d[@"feedbackId"] = feedbackId;
  
  PandoraRequest *req = [self defaultRequestWithMethod:@"station.deleteFeedback"];
  [req setRequest:d];
  [req setTls:FALSE];
  [req setCallback:^(NSDictionary* d) {
    [self sendNotification:PandoraDidDeleteFeedbackNotification withUserInfo:nil];
  }];
  return [self sendAuthenticatedRequest:req];
}

- (BOOL) addSeed: (NSString*)token toStation:(Station*)station {
  NSMutableDictionary *d = [self defaultRequestDictionary];
  d[@"musicToken"] = token;
  d[@"stationToken"] = [station token];
  
  PandoraRequest *req = [self defaultRequestWithMethod:@"station.addMusic"];
  [req setRequest:d];
  [req setTls:FALSE];
  [req setCallback:^(NSDictionary* d) {
    [self sendNotification:PandoraDidAddSeedNotification withUserInfo:d[@"result"]];
  }];
  return [self sendAuthenticatedRequest:req];
}

- (BOOL) removeSeed: (NSString*)seedId {
  NSMutableDictionary *d = [self defaultRequestDictionary];
  d[@"seedId"] = seedId;
  
  PandoraRequest *req = [self defaultRequestWithMethod:@"station.deleteMusic"];
  [req setRequest:d];
  [req setTls:FALSE];
  [req setCallback:^(NSDictionary* d) {
    [self sendNotification:PandoraDidDeleteSeedNotification withUserInfo:nil];
  }];
  return [self sendAuthenticatedRequest:req];
}

#pragma mark Sort stations in UI

- (void) sortStations:(int)sort {
  [stations sortUsingComparator:
   ^NSComparisonResult (Station *s1, Station *s2) {
     NSInteger factor = 1;
     switch (sort) {
       case SORT_NAME_ASC: return [[s1 name] caseInsensitiveCompare:[s2 name]];
       case SORT_NAME_DSC: return -[[s1 name] caseInsensitiveCompare:[s2 name]];
         
       case SORT_DATE_DSC:
         factor = -1;
       default:
       case SORT_DATE_ASC:
         if ([s1 created] < [s2 created]) {
           return factor * NSOrderedAscending;
         } else if ([s1 created] > [s2 created]) {
           return factor * NSOrderedDescending;
         }
         return NSOrderedSame;
     }
   }];
}

#pragma mark - Song Manipulation

- (BOOL) rateSong:(Song*) song as:(BOOL) liked {
  NSLogd(@"Rating song '%@' as %d...", [song title], liked);
  
  if (liked == TRUE) {
    [song setNrating:@1];
  } else {
    [song setNrating:@-1];
  }
  
  NSMutableDictionary *d = [self defaultRequestDictionary];
  d[@"trackToken"] = [song token];
  d[@"isPositive"] = @(liked);
  d[@"stationToken"] = [[song station] token];
  
  PandoraRequest *req = [self defaultRequestWithMethod:@"station.addFeedback"];
  [req setRequest:d];
  [req setTls:FALSE];
  [req setCallback:^(NSDictionary* _) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"song"] = song;
    [self sendNotification:PandoraDidRateSongNotification withUserInfo:dict];
  }];
  return [self sendAuthenticatedRequest:req];
}

- (BOOL) deleteRating:(Song*)song {
  NSLogd(@"Removing rating on '%@'", [song title]);
  [song setNrating:@0];
  
  NSMutableDictionary *d = [self defaultRequestDictionary];
  d[@"stationToken"] = [[song station] token];
  d[@"includeExtendedAttributes"] = [NSNumber numberWithBool:TRUE];
  
  PandoraRequest *req = [self defaultRequestWithMethod:@"station.getStation"];
  [req setRequest:d];
  [req setTls:FALSE];
  [req setCallback:^(NSDictionary* d) {
    for (NSString *thumb in @[@"thumbsUp", @"thumbsDown"]) {
      for (NSDictionary* feed in d[@"result"][@"feedback"][thumb]) {
        if ([feed[@"songName"] isEqualToString:[song title]]) {
          [self deleteFeedback:feed[@"feedbackId"]];
          break;
        }
      }
    }
  }];
  return [self sendAuthenticatedRequest:req];
}

- (BOOL) tiredOfSong: (Song*) song {
  NSLogd(@"Getting tired of %@...", [song title]);
  
  NSMutableDictionary *d = [self defaultRequestDictionary];
  d[@"trackToken"] = [song token];
  
  PandoraRequest *req = [self defaultRequestWithMethod:@"user.sleepSong"];
  [req setRequest:d];
  [req setTls:FALSE];
  [req setCallback:^(NSDictionary* _) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"song"] = song;
    [self sendNotification:PandoraDidTireSongNotification withUserInfo:dict];
  }];
  
  return [self sendAuthenticatedRequest:req];
}

#pragma mark - syncTime

- (NSNumber*) syncTimeNum {
  return [NSNumber numberWithLongLong: sync_time + ([self time] - start_time)];
}

- (int64_t) time {
  return [[NSDate date] timeIntervalSince1970];
}

#pragma mark - Search for music

- (BOOL) search: (NSString*) search {
  NSLogd(@"Searching for %@...", search);

  NSMutableDictionary *d = [self defaultRequestDictionary];
  d[@"searchText"] = search;

  PandoraRequest *req = [self defaultRequestWithMethod:@"music.search"];
  [req setRequest:d];
  [req setTls:FALSE];
  [req setCallback:^(NSDictionary* d) {
    NSDictionary *result = d[@"result"];
    NSLogd(@"%@", result);
    NSMutableDictionary *map = [NSMutableDictionary dictionary];

    NSMutableArray *search_songs, *search_artists;
    search_songs    = [NSMutableArray array];
    search_artists  = [NSMutableArray array];

    map[@"Songs"] = search_songs;
    map[@"Artists"] = search_artists;

    for (NSDictionary *s in result[@"songs"]) {
      PandoraSearchResult *r = [[PandoraSearchResult alloc] init];
      NSString *name = [NSString stringWithFormat:@"%@ - %@",
                          s[@"songName"],
                          s[@"artistName"]];
      [r setName:name];
      [r setValue:s[@"musicToken"]];
      [search_songs addObject:r];
    }

    for (NSDictionary *a in result[@"artists"]) {
      PandoraSearchResult *r = [[PandoraSearchResult alloc] init];
      [r setValue:a[@"musicToken"]];
      [r setName:a[@"artistName"]];
      [search_artists addObject:r];
    }

    [self sendNotification:PandoraDidLoadSearchResultsNotification withUserInfo:map];
  }];

  return [self sendAuthenticatedRequest:req];
}

#pragma mark - Prepare and Send Requests

- (NSMutableDictionary*) defaultRequestDictionary {
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  if (user_auth_token != nil) {
    d[@"userAuthToken"] = user_auth_token;
  }
  d[@"syncTime"] = [self syncTimeNum];
  return d;
}

- (PandoraRequest*) defaultRequestWithMethod: (NSString*) method {
  PandoraRequest *req = [[PandoraRequest alloc] init];
  [req setUserId:user_id];
  [req setAuthToken:user_auth_token];
  [req setMethod:method];
  [req setPartnerId:partner_id];
  return req;
}

- (BOOL) sendAuthenticatedRequest: (PandoraRequest*) req {
  if ([self isAuthenticated]) {
    return [self sendRequest:req];
  }
  NSString *user = [[NSApp delegate] getCachedUsername];
  NSString *pass = [[NSApp delegate] getCachedPassword];
  return [self authenticate:user password:pass request:req];
}


- (BOOL) sendRequest: (PandoraRequest*) request {
  NSString *url  = [NSString stringWithFormat:
                    @"http%s://%@" PANDORA_API_PATH
                    @"?method=%@&partner_id=%@&auth_token=%@&user_id=%@",
                    [request tls] ? "s" : "",
                    self.device[kPandoraDeviceAPIHost],
                    [request method], [request partnerId],
                    [[request authToken] urlEncoded], [request userId]];
  NSLogd(@"%@", url);
  
  /* Prepare the request */
  NSURL *nsurl = [NSURL URLWithString:url];
  NSMutableURLRequest *nsrequest = [NSMutableURLRequest requestWithURL:nsurl];
  [nsrequest setHTTPMethod: @"POST"];
  [nsrequest addValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  
  /* Create the body */
  NSData *data = [json_writer dataWithObject: [request request]];
  if ([request encrypted]) { data = [self encryptData:data]; }
  [nsrequest setHTTPBody: data];
  
  /* Create the connection with necessary callback for when done */
  URLConnection *c =
  [URLConnection connectionForRequest:nsrequest
                    completionHandler:^(NSData *d, NSError *e) {
                      /* Parse the JSON if we don't have an error */
                      NSDictionary *dict = nil;
                      if (e == nil) {
                        NSString *s = [[NSString alloc] initWithData:d
                                                            encoding:NSUTF8StringEncoding];
                        dict = [json_parser objectWithString:s error:&e];
                      }
                      /* If we still don't have an error, look at the JSON for an error */
                      NSString *err = e == nil ? nil : [e localizedDescription];
                      if (dict != nil && err == nil) {
                        NSString *stat = dict[@"stat"];
                        if ([stat isEqualToString:@"fail"]) {
                          err = dict[@"message"];
                        }
                      }
                      
                      /* If we don't have an error, then all we need to do is invoked the
                       specified callback, otherwise build the error dictionary. */
                      if (err == nil) {
                        assert(dict != nil);
                        [request callback](dict);
                        return;
                      }
                      
                      NSMutableDictionary *info = [NSMutableDictionary dictionary];
                      
                      [info setValue:request forKey:@"request"];
                      [info setValue:err     forKey:@"error"];
                      if (dict != nil) {
                        [info setValue:dict[@"code"] forKey:@"code"];
                      }
                      [[NSNotificationCenter defaultCenter] postNotificationName:PandoraDidErrorNotification
                                                                          object:self
                                                                        userInfo:info];
                    }];
  [c start];
  return TRUE;
}

@end

