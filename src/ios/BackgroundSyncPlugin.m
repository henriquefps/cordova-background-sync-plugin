#import "BackgroundSyncPlugin.h"
#import "DatabaseInspectorViewController.h"
#import <UserNotifications/UserNotifications.h>
#import <Security/Security.h>

#define LogDebug(fmt, ...) if (self.showDebugLogs) { NSLog(fmt, ##__VA_ARGS__); }
#define FLogDebug(fmt, ...) if (self.showDebugLogs) { fprintf(stderr, fmt, ##__VA_ARGS__); }

@interface BackgroundSyncPlugin ()
// Caches the outcome of the first notification authorization check for this process, so
// subsequent notifications (e.g. one per record in a large sync batch) don't each pay for an
// async round-trip into UNUserNotificationCenter just to find out the (already known) answer.
@property (nonatomic, assign) BOOL notificationAuthorizationChecked;
@property (nonatomic, assign) BOOL notificationAuthorizationGranted;
// Sync run bookkeeping. The atomic ones are shared with the sync thread; the others are only
// touched on the main thread.
@property (atomic, assign) BOOL rerunRequested;
@property (atomic, assign) BOOL backgroundTimeExpired;
@property (nonatomic, assign) UIBackgroundTaskIdentifier syncBgTask;
@property (nonatomic, assign) BOOL resumeWhenActive;
@property (nonatomic, assign) NSUInteger retryGeneration;
@property (nonatomic, assign) NSTimeInterval retryDelay;
@end

// How a sync run ended (see -finishSyncRunWithOutcome:).
static NSString *const BSSyncOutcomeCompleted = @"completed";
static NSString *const BSSyncOutcomeCancelled = @"cancelled";
static NSString *const BSSyncOutcomeExpired = @"expired";
static NSString *const BSSyncOutcomeConnectivity = @"connectivity";
static NSString *const BSSyncOutcomeError = @"error";

// JS values arrive as NSString, NSNumber, NSNull, NSArray or NSDictionary. These helpers turn
// what the API documents as text into NSString, so a number (e.g. an id of 123) is stored as
// "123" the way Android's JSONArray.getString/optString does, and anything else (null, objects,
// arrays) is treated as absent instead of crashing on a selector NSString-only code relies on.
static NSString *BSSyncString(id value) {
  if ([value isKindOfClass:[NSString class]]) return value;
  if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
  return nil;
}

static NSDictionary *BSSyncDictionary(id value) {
  return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

// Keeps only string keys with string or number values (numbers become text). Header values
// and notification texts are written to NSUserDefaults and into HTTP headers, and both reject
// NSNull and other non-property-list values with an exception.
static NSDictionary *BSSyncStringDictionary(id value) {
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  NSDictionary *dict = BSSyncDictionary(value);
  for (id key in dict) {
    NSString *stringValue = BSSyncString(dict[key]);
    if ([key isKindOfClass:[NSString class]] && stringValue) out[key] = stringValue;
  }
  return out;
}

// Argument `index` of a command, or nil when it is missing or JS passed null.
static id BSSyncArgument(CDVInvokedUrlCommand *command, NSUInteger index) {
  id value = command.arguments.count > index ? command.arguments[index] : nil;
  return [value isKindOfClass:[NSNull class]] ? nil : value;
}

@implementation BackgroundSyncPlugin

@synthesize serverUrl;
@synthesize queueTableName;
@synthesize progressCallbackId;
@synthesize enableNotifications;
@synthesize autoDeleteCompleted;
@synthesize headers;
@synthesize notificationTexts;
@synthesize showDebugLogs;
@synthesize encryptDatabase;

- (void)pluginInitialize {
  [super pluginInitialize];

  self.syncBgTask = UIBackgroundTaskInvalid;
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(appDidBecomeActive:)
                                               name:UIApplicationDidBecomeActiveNotification
                                             object:nil];

  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  self.serverUrl = [defaults stringForKey:@"BackgroundSyncPlugin_ServerUrl"];
  self.queueTableName = [defaults stringForKey:@"BackgroundSyncPlugin_QueueTableName"];
  self.headers = BSSyncStringDictionary([defaults dictionaryForKey:@"BackgroundSyncPlugin_Headers"]);
  self.notificationTexts = BSSyncStringDictionary([defaults dictionaryForKey:@"BackgroundSyncPlugin_NotificationTexts"]);

  if ([defaults objectForKey:@"BackgroundSyncPlugin_EnableNotifications"] == nil) {
    self.enableNotifications = YES;
  } else {
    self.enableNotifications = [defaults boolForKey:@"BackgroundSyncPlugin_EnableNotifications"];
  }

  if ([defaults objectForKey:@"BackgroundSyncPlugin_AutoDeleteCompleted"] == nil) {
    self.autoDeleteCompleted = NO;
  } else {
    self.autoDeleteCompleted = [defaults boolForKey:@"BackgroundSyncPlugin_AutoDeleteCompleted"];
  }

  if ([defaults objectForKey:@"BackgroundSyncPlugin_ShowDebugLogs"] == nil) {
    self.showDebugLogs = NO;
  } else {
    self.showDebugLogs = [defaults boolForKey:@"BackgroundSyncPlugin_ShowDebugLogs"];
  }

  if ([defaults objectForKey:@"BackgroundSyncPlugin_EncryptDatabase"] == nil) {
    self.encryptDatabase = NO;
  } else {
    self.encryptDatabase = [defaults boolForKey:@"BackgroundSyncPlugin_EncryptDatabase"];
  }
}

- (void)initialize:(CDVInvokedUrlCommand *)command {
  NSDictionary *options = BSSyncDictionary(BSSyncArgument(command, 0)) ?: @{};

  NSString *url = BSSyncString(options[@"serverUrl"]);
  NSString *tableName = BSSyncString(options[@"queueTableName"]) ?: @"";

  if (!url || url.length == 0) {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"serverUrl is required."];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    return;
  }

  self.serverUrl = url;
  self.queueTableName = tableName;

  id notifOption = options[@"enableNotifications"];
  self.enableNotifications = [notifOption respondsToSelector:@selector(boolValue)] ? [notifOption boolValue] : YES;

  id autoDeleteOption = options[@"autoDeleteCompleted"];
  self.autoDeleteCompleted = [autoDeleteOption respondsToSelector:@selector(boolValue)] ? [autoDeleteOption boolValue] : NO;

  id showDebugOption = options[@"showDebugLogs"];
  self.showDebugLogs = [showDebugOption respondsToSelector:@selector(boolValue)] ? [showDebugOption boolValue] : NO;

  id encryptOption = options[@"encryptDatabase"];
  self.encryptDatabase = [encryptOption respondsToSelector:@selector(boolValue)] ? [encryptOption boolValue] : NO;

  self.headers = BSSyncStringDictionary(options[@"headers"]);
  self.notificationTexts = BSSyncStringDictionary(options[@"notificationTexts"]);

  // Persist settings
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults setObject:self.serverUrl forKey:@"BackgroundSyncPlugin_ServerUrl"];
  [defaults setObject:self.queueTableName forKey:@"BackgroundSyncPlugin_QueueTableName"];
  [defaults setBool:self.enableNotifications forKey:@"BackgroundSyncPlugin_EnableNotifications"];
  [defaults setBool:self.autoDeleteCompleted forKey:@"BackgroundSyncPlugin_AutoDeleteCompleted"];
  [defaults setObject:self.headers forKey:@"BackgroundSyncPlugin_Headers"];
  [defaults setObject:self.notificationTexts forKey:@"BackgroundSyncPlugin_NotificationTexts"];
  [defaults setBool:self.showDebugLogs forKey:@"BackgroundSyncPlugin_ShowDebugLogs"];
  [defaults setBool:self.encryptDatabase forKey:@"BackgroundSyncPlugin_EncryptDatabase"];
  [defaults synchronize];

  // Eagerly verify database structure and encryption configuration
  [self.commandDelegate runInBackground:^{
      sqlite3 *db = [self openWritableDatabase];
      if (db) sqlite3_close(db);
  }];

  CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"Background Sync Engine initialized."];
  [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)registerProgressListener:(CDVInvokedUrlCommand *)command {
  self.progressCallbackId = command.callbackId;
  CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_NO_RESULT];
  [result setKeepCallbackAsBool:YES];
  [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)cancelSync:(CDVInvokedUrlCommand *)command {
  // Stops the running run at the next record boundary, and drops any pending automatic
  // retry/resume and any sync() queued behind the run.
  self.isSyncCancelled = YES;
  self.rerunRequested = NO;
  dispatch_async(dispatch_get_main_queue(), ^{
    self.retryGeneration++;
    self.resumeWhenActive = NO;
    self.retryDelay = 0;
  });
  CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"Sync cancellation signal sent."];
  [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)requestNotificationsPermission:(CDVInvokedUrlCommand *)command {
  if (@available(iOS 10.0, *)) {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound) completionHandler:^(BOOL granted, NSError *_Nullable error) {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:granted];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
  } else {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:YES];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
  }
}

// Secure Keychain operations to get or generate the encryption passphrase
- (NSString *)getOrCreatePassphrase {
  // Cached for the process: every plugin call opens the database, and a keychain round trip
  // per open is needless. If storing a new passphrase fails, the next open would otherwise
  // generate yet another one and fail to read (and so recreate) the database every time.
  static NSString *cachedPassphrase = nil;
  static dispatch_once_t once;
  static NSObject *lock;
  dispatch_once(&once, ^{ lock = [NSObject new]; });
  @synchronized (lock) {
    if (!cachedPassphrase) cachedPassphrase = [self readOrCreateKeychainPassphrase];
    return cachedPassphrase;
  }
}

- (NSString *)readOrCreateKeychainPassphrase {
  NSString *serviceName = @"com.hfps.backgroundsync.passphrase";
  NSString *accountName = @"bgSyncDbKey";
  
  NSDictionary *query = @{
    (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService: serviceName,
    (__bridge id)kSecAttrAccount: accountName,
    (__bridge id)kSecReturnData: @YES
  };
  
  CFTypeRef resultRef = NULL;
  OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &resultRef);
  
  if (status == errSecSuccess) {
    NSData *resultData = (__bridge_transfer NSData *)resultRef;
    return [[NSString alloc] initWithData:resultData encoding:NSUTF8StringEncoding];
  }
  
  NSString *uuid = [[NSUUID UUID] UUIDString];
  NSData *uuidData = [uuid dataUsingEncoding:NSUTF8StringEncoding];
  
  NSDictionary *attributes = @{
    (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService: serviceName,
    (__bridge id)kSecAttrAccount: accountName,
    (__bridge id)kSecValueData: uuidData,
    (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlock
  };
  
  OSStatus addStatus = SecItemAdd((__bridge CFDictionaryRef)attributes, NULL);
  if (addStatus == errSecDuplicateItem) {
    // Another thread stored one first: use that.
    resultRef = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &resultRef) == errSecSuccess) {
      NSData *resultData = (__bridge_transfer NSData *)resultRef;
      return [[NSString alloc] initWithData:resultData encoding:NSUTF8StringEncoding];
    }
  } else if (addStatus != errSecSuccess) {
    LogDebug(@"[BG-SYNC-IOS] Could not store the database passphrase in the keychain (OSStatus %d); it lasts until the app exits.", (int)addStatus);
  }
  return uuid;
}

- (NSString *)getDatabasePath {
  NSString *libraryPath = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject];
  NSString *appSupportPath = [libraryPath stringByAppendingPathComponent:@"Application Support"];
  
  NSFileManager *fileManager = [NSFileManager defaultManager];
  if (![fileManager fileExistsAtPath:appSupportPath]) {
    [fileManager createDirectoryAtPath:appSupportPath withIntermediateDirectories:YES attributes:nil error:nil];
  }
  return [appSupportPath stringByAppendingPathComponent:@"bg_sync.db"];
}

- (sqlite3 *)openWritableDatabase {
  NSString *dbPath = [self getDatabasePath];
  sqlite3 *db = NULL;
  
  int openFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE;
  if (sqlite3_open_v2([dbPath UTF8String], &db, openFlags, NULL) != SQLITE_OK) {
    if (db) sqlite3_close(db);
    return NULL;
  }
  
  sqlite3_busy_timeout(db, 5000);
  
  if (self.encryptDatabase) {
    NSString *key = [self getOrCreatePassphrase];
    sqlite3_key(db, [key UTF8String], (int)[key length]);
  }
  
  // Probe that the current key (or no key) can actually read the file. Preparing a PRAGMA
  // never touches page 1, so it succeeded even when SQLCipher could not decrypt the file and
  // every later statement then failed with "out of memory" (SQLITE_NOMEM, SQLCipher's codec
  // error); stepping a read of sqlite_master does read page 1.
  sqlite3_stmt *stmt = NULL;
  BOOL readable = sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master;", -1, &stmt, NULL) == SQLITE_OK &&
                  sqlite3_step(stmt) == SQLITE_ROW;
  if (stmt) sqlite3_finalize(stmt);
  if (!readable) {
    sqlite3_close(db);

    // Best-effort visibility: this wipes any unsynchronized queued records with no
    // recovery path, so surface it to the app (if a progress listener is registered)
    // instead of silently discarding the database.
    [self broadcastEvent:@"databaseReset" percentage:0 completed:0 total:0 error:@"Failed to open database with current encryption state; recreating."];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    [fileManager removeItemAtPath:dbPath error:nil];
    [fileManager removeItemAtPath:[dbPath stringByAppendingString:@"-journal"] error:nil];
    [fileManager removeItemAtPath:[dbPath stringByAppendingString:@"-wal"] error:nil];
    [fileManager removeItemAtPath:[dbPath stringByAppendingString:@"-shm"] error:nil];
    
    if (sqlite3_open_v2([dbPath UTF8String], &db, openFlags, NULL) != SQLITE_OK) {
      if (db) sqlite3_close(db);
      return NULL;
    }
    sqlite3_busy_timeout(db, 5000);
    if (self.encryptDatabase) {
      NSString *key = [self getOrCreatePassphrase];
      sqlite3_key(db, [key UTF8String], (int)[key length]);
    }
  }
  
  char *errMsg = NULL;
  const char *createTableSQL = 
      "CREATE TABLE IF NOT EXISTS sync_queue ("
      "Id TEXT UNIQUE, "
      "Endpoint TEXT, "
      "Payload TEXT, "
      "FilePath TEXT, "
      "UploadStrategy TEXT, "
      "Status TEXT, "
      "Sequence INTEGER PRIMARY KEY AUTOINCREMENT, "
      "Error TEXT);";
      
  if (sqlite3_exec(db, createTableSQL, NULL, NULL, &errMsg) != SQLITE_OK) {
    LogDebug(@"[BG-SYNC-IOS] Failed to create table: %s", errMsg);
    sqlite3_free(errMsg);
  }
  
  const char *createDownloadTableSQL = 
      "CREATE TABLE IF NOT EXISTS download_queue ("
      "Id TEXT UNIQUE, "
      "Endpoint TEXT, "
      "Payload TEXT, "
      "FilePath TEXT, "
      "DownloadStrategy TEXT, "
      "Status TEXT, "
      "ResponseData TEXT, "
      "Sequence INTEGER PRIMARY KEY AUTOINCREMENT, "
      "Error TEXT);";
      
  if (sqlite3_exec(db, createDownloadTableSQL, NULL, NULL, &errMsg) != SQLITE_OK) {
    LogDebug(@"[BG-SYNC-IOS] Failed to create download_queue table: %s", errMsg);
    sqlite3_free(errMsg);
  }
  
  return db;
}

- (void)executeRawQuery:(CDVInvokedUrlCommand *)command {
  NSString *query = BSSyncString(BSSyncArgument(command, 0));
  id argsArg = BSSyncArgument(command, 1);
  NSArray *queryArgs = [argsArg isKindOfClass:[NSArray class]] ? argsArg : @[];

  __weak BackgroundSyncPlugin *weakSelf = self;
  [self.commandDelegate runInBackground:^{
    BackgroundSyncPlugin *strongSelf = weakSelf;
    if (!strongSelf) return;

    if (query.length == 0) {
      [strongSelf sendErrorResult:@"Database execution error: query is required." command:command];
      return;
    }

    sqlite3 *db = [strongSelf openWritableDatabase];
    if (!db) {
      [strongSelf sendErrorResult:@"Failed to open SQLite database." command:command];
      return;
    }

    sqlite3_stmt *stmt;
    if (sqlite3_prepare_v2(db, [query UTF8String], -1, &stmt, NULL) != SQLITE_OK) {
      // Copy the message before sqlite3_close frees it.
      NSString *message = [NSString stringWithFormat:@"SQL Prepare Error: %s", sqlite3_errmsg(db)];
      sqlite3_close(db);
      [strongSelf sendErrorResult:message command:command];
      return;
    }

    for (int i = 0; i < (int)queryArgs.count; i++) {
      id arg = queryArgs[i];
      NSString *argStr = BSSyncString(arg) ?: ([arg isKindOfClass:[NSNull class]] ? nil : [NSString stringWithFormat:@"%@", arg]);
      if (argStr) {
        sqlite3_bind_text(stmt, i + 1, [argStr UTF8String], -1, SQLITE_TRANSIENT);
      } else {
        sqlite3_bind_null(stmt, i + 1);
      }
    }

    // Any statement that produces columns (SELECT, PRAGMA, WITH ..., RETURNING) returns its
    // rows, as on Android for SELECT/PRAGMA; everything else returns a confirmation string.
    // A failing step (constraint violation, read-only table, ...) is reported as an error
    // instead of being swallowed.
    int columnCount = sqlite3_column_count(stmt);
    NSMutableArray *resultList = [NSMutableArray array];
    int rc;
    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
      NSMutableDictionary *row = [NSMutableDictionary dictionary];
      for (int i = 0; i < columnCount; i++) {
        NSString *colName = [NSString stringWithUTF8String:sqlite3_column_name(stmt, i)];
        const char *valChar = (const char *)sqlite3_column_text(stmt, i);
        row[colName] = valChar ? [NSString stringWithUTF8String:valChar] : @"";
      }
      [resultList addObject:row];
    }
    NSString *stepError = rc == SQLITE_DONE ? nil : [NSString stringWithFormat:@"Database execution error: %s", sqlite3_errmsg(db)];
    sqlite3_finalize(stmt);
    sqlite3_close(db);

    CDVPluginResult *result;
    if (stepError) {
      result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:stepError];
    } else if (columnCount > 0) {
      result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:resultList];
    } else {
      result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"Query executed successfully."];
    }
    [strongSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
  }];
}

- (void)enqueueRecord:(CDVInvokedUrlCommand *)command {
  NSDictionary *record = BSSyncDictionary(BSSyncArgument(command, 0)) ?: @{};
  
  __weak BackgroundSyncPlugin *weakSelf = self;
  [self.commandDelegate runInBackground:^{
    BackgroundSyncPlugin *strongSelf = weakSelf;
    if (!strongSelf) return;

    sqlite3 *db = [strongSelf openWritableDatabase];
    if (!db) {
      [strongSelf sendErrorResult:@"Failed to open SQLite database." command:command];
      return;
    }

    NSString *recordId = BSSyncString(record[@"id"]);
    if (recordId.length == 0) {
      recordId = [[NSUUID UUID] UUIDString];
    }
    NSString *endpoint = BSSyncString(record[@"endpoint"]) ?: @"";
    id payloadObj = record[@"payload"];
    NSString *payload = @"";
    if (payloadObj && ![payloadObj isKindOfClass:[NSNull class]]) {
      if ([payloadObj isKindOfClass:[NSDictionary class]] || [payloadObj isKindOfClass:[NSArray class]]) {
        NSData *payloadData = [NSJSONSerialization dataWithJSONObject:payloadObj options:0 error:nil];
        payload = [[NSString alloc] initWithData:payloadData encoding:NSUTF8StringEncoding];
      } else {
        payload = [NSString stringWithFormat:@"%@", payloadObj];
      }
    }
    NSString *filePath = BSSyncString(record[@"filePath"]) ?: @"";
    NSString *uploadStrategy = BSSyncString(record[@"uploadStrategy"]) ?: @"REST_PAYLOAD";

    const char *insertSQL = "INSERT OR REPLACE INTO sync_queue (Id, Endpoint, Payload, FilePath, UploadStrategy, Status) VALUES (?, ?, ?, ?, ?, 'pending');";
    sqlite3_stmt *stmt;
    if (sqlite3_prepare_v2(db, insertSQL, -1, &stmt, NULL) == SQLITE_OK) {
      sqlite3_bind_text(stmt, 1, [recordId UTF8String], -1, SQLITE_TRANSIENT);
      sqlite3_bind_text(stmt, 2, [endpoint UTF8String], -1, SQLITE_TRANSIENT);
      sqlite3_bind_text(stmt, 3, [payload UTF8String], -1, SQLITE_TRANSIENT);
      sqlite3_bind_text(stmt, 4, [filePath UTF8String], -1, SQLITE_TRANSIENT);
      sqlite3_bind_text(stmt, 5, [uploadStrategy UTF8String], -1, SQLITE_TRANSIENT);

      if (sqlite3_step(stmt) == SQLITE_DONE) {
        NSDictionary *response = @{@"id": recordId, @"status": @"pending"};
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:response];
        [strongSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
      } else {
        const char *errMsg = sqlite3_errmsg(db);
        [strongSelf sendErrorResult:[NSString stringWithFormat:@"SQL Insert Error: %s", errMsg] command:command];
      }
      sqlite3_finalize(stmt);
    } else {
      const char *errMsg = sqlite3_errmsg(db);
      [strongSelf sendErrorResult:[NSString stringWithFormat:@"SQL Prepare Error: %s", errMsg] command:command];
    }
    sqlite3_close(db);
  }];
}

- (void)getQueuedRecords:(CDVInvokedUrlCommand *)command {
  __weak BackgroundSyncPlugin *weakSelf = self;
  [self.commandDelegate runInBackground:^{
    BackgroundSyncPlugin *strongSelf = weakSelf;
    if (!strongSelf) return;

    sqlite3 *db = [strongSelf openWritableDatabase];
    if (!db) {
      [strongSelf sendErrorResult:@"Failed to open SQLite database." command:command];
      return;
    }

    NSMutableArray *resultList = [NSMutableArray array];
    const char *selectSQL = "SELECT Id, Status, Error FROM sync_queue WHERE LOWER(Status) = 'pending' OR LOWER(Status) = 'failed' ORDER BY Sequence ASC;";
    sqlite3_stmt *stmt;
    if (sqlite3_prepare_v2(db, selectSQL, -1, &stmt, NULL) == SQLITE_OK) {
      while (sqlite3_step(stmt) == SQLITE_ROW) {
        const char *idChar = (char *)sqlite3_column_text(stmt, 0);
        const char *statusChar = (char *)sqlite3_column_text(stmt, 1);
        const char *errChar = (char *)sqlite3_column_text(stmt, 2);
        
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        row[@"id"] = idChar ? [NSString stringWithUTF8String:idChar] : @"";
        row[@"status"] = statusChar ? [NSString stringWithUTF8String:statusChar] : @"";
        row[@"error"] = errChar ? [NSString stringWithUTF8String:errChar] : @"";
        [resultList addObject:row];
      }
      sqlite3_finalize(stmt);
      CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:resultList];
      [strongSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    } else {
      const char *errMsg = sqlite3_errmsg(db);
      [strongSelf sendErrorResult:[NSString stringWithFormat:@"SQL Query Error: %s", errMsg] command:command];
    }
    sqlite3_close(db);
  }];
}

- (void)getSyncedRecords:(CDVInvokedUrlCommand *)command {
  __weak BackgroundSyncPlugin *weakSelf = self;
  [self.commandDelegate runInBackground:^{
    BackgroundSyncPlugin *strongSelf = weakSelf;
    if (!strongSelf) return;

    sqlite3 *db = [strongSelf openWritableDatabase];
    if (!db) {
      [strongSelf sendErrorResult:@"Failed to open SQLite database." command:command];
      return;
    }

    NSMutableArray *resultList = [NSMutableArray array];
    const char *selectSQL = "SELECT Id, Status FROM sync_queue WHERE LOWER(Status) = 'completed' ORDER BY Sequence ASC;";
    sqlite3_stmt *stmt;
    if (sqlite3_prepare_v2(db, selectSQL, -1, &stmt, NULL) == SQLITE_OK) {
      while (sqlite3_step(stmt) == SQLITE_ROW) {
        const char *idChar = (char *)sqlite3_column_text(stmt, 0);
        const char *statusChar = (char *)sqlite3_column_text(stmt, 1);
        
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        row[@"id"] = idChar ? [NSString stringWithUTF8String:idChar] : @"";
        row[@"status"] = statusChar ? [NSString stringWithUTF8String:statusChar] : @"";
        [resultList addObject:row];
      }
      sqlite3_finalize(stmt);
      CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:resultList];
      [strongSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    } else {
      const char *errMsg = sqlite3_errmsg(db);
      [strongSelf sendErrorResult:[NSString stringWithFormat:@"SQL Query Error: %s", errMsg] command:command];
    }
    sqlite3_close(db);
  }];
}

- (void)removeRecords:(CDVInvokedUrlCommand *)command {
  id idsArg = BSSyncArgument(command, 0);
  NSArray *ids = [idsArg isKindOfClass:[NSArray class]] ? idsArg : @[];

  __weak BackgroundSyncPlugin *weakSelf = self;
  [self.commandDelegate runInBackground:^{
    BackgroundSyncPlugin *strongSelf = weakSelf;
    if (!strongSelf) return;

    sqlite3 *db = [strongSelf openWritableDatabase];
    if (!db) {
      [strongSelf sendErrorResult:@"Failed to open SQLite database." command:command];
      return;
    }

    const char *deleteSQL = "DELETE FROM sync_queue WHERE Id = ?;";
    sqlite3_stmt *stmt;
    if (sqlite3_prepare_v2(db, deleteSQL, -1, &stmt, NULL) == SQLITE_OK) {
      // Wrap all deletes in one transaction instead of letting SQLite auto-commit (and fsync)
      // after every single statement — matches the Android implementation's beginTransaction/
      // setTransactionSuccessful/endTransaction pattern.
      sqlite3_exec(db, "BEGIN TRANSACTION;", NULL, NULL, NULL);
      for (id item in ids) {
        // Numbers are matched as text, like Android; null and other values are skipped.
        NSString *recordId = BSSyncString(item);
        if (!recordId) continue;
        sqlite3_bind_text(stmt, 1, [recordId UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_step(stmt);
        sqlite3_reset(stmt);
      }
      sqlite3_exec(db, "COMMIT;", NULL, NULL, NULL);
      sqlite3_finalize(stmt);
      CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"Records removed successfully."];
      [strongSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    } else {
      const char *errMsg = sqlite3_errmsg(db);
      [strongSelf sendErrorResult:[NSString stringWithFormat:@"SQL Delete Error: %s", errMsg] command:command];
    }
    sqlite3_close(db);
  }];
}

- (void)clearQueue:(CDVInvokedUrlCommand *)command {
  __weak BackgroundSyncPlugin *weakSelf = self;
  [self.commandDelegate runInBackground:^{
    BackgroundSyncPlugin *strongSelf = weakSelf;
    if (!strongSelf) return;

    sqlite3 *db = [strongSelf openWritableDatabase];
    if (!db) {
      [strongSelf sendErrorResult:@"Failed to open SQLite database." command:command];
      return;
    }

    char *errMsg = NULL;
    if (sqlite3_exec(db, "DELETE FROM sync_queue;", NULL, NULL, &errMsg) == SQLITE_OK) {
      CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"Queue cleared successfully."];
      [strongSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    } else {
      [strongSelf sendErrorResult:[NSString stringWithFormat:@"SQL Clear Error: %s", errMsg] command:command];
      sqlite3_free(errMsg);
    }
    sqlite3_close(db);
  }];
}

- (void)enqueueDownload:(CDVInvokedUrlCommand *)command {
  NSDictionary *record = BSSyncDictionary(BSSyncArgument(command, 0)) ?: @{};
  
  __weak BackgroundSyncPlugin *weakSelf = self;
  [self.commandDelegate runInBackground:^{
    BackgroundSyncPlugin *strongSelf = weakSelf;
    if (!strongSelf) return;

    sqlite3 *db = [strongSelf openWritableDatabase];
    if (!db) {
      [strongSelf sendErrorResult:@"Failed to open SQLite database." command:command];
      return;
    }

    NSString *recordId = BSSyncString(record[@"id"]);
    if (recordId.length == 0) {
      recordId = [[NSUUID UUID] UUIDString];
    }
    NSString *endpoint = BSSyncString(record[@"endpoint"]) ?: @"";
    id payloadObj = record[@"payload"];
    NSString *payload = @"";
    if (payloadObj && ![payloadObj isKindOfClass:[NSNull class]]) {
      if ([payloadObj isKindOfClass:[NSDictionary class]] || [payloadObj isKindOfClass:[NSArray class]]) {
        NSData *payloadData = [NSJSONSerialization dataWithJSONObject:payloadObj options:0 error:nil];
        payload = [[NSString alloc] initWithData:payloadData encoding:NSUTF8StringEncoding];
      } else {
        payload = [NSString stringWithFormat:@"%@", payloadObj];
      }
    }
    NSString *filePath = BSSyncString(record[@"filePath"]) ?: @"";
    NSString *downloadStrategy = BSSyncString(record[@"downloadStrategy"]) ?: @"REST_PAYLOAD";

    NSString *resolvedPath = filePath;
    if (filePath.length > 0) {
      @try {
        NSURL *fileUrl = [NSURL URLWithString:filePath];
        if (fileUrl) {
          // Safely check if webView responds to resourceApi (Cordova) to avoid crashes in Capacitor (WKWebView)
          SEL resourceApiSel = NSSelectorFromString(@"resourceApi");
          if ([strongSelf.webView respondsToSelector:resourceApiSel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id resourceApi = [strongSelf.webView performSelector:resourceApiSel];
            #pragma clang diagnostic pop
            
            if (resourceApi && [resourceApi respondsToSelector:NSSelectorFromString(@"mapUriToFile:")]) {
              #pragma clang diagnostic push
              #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
              NSString *mappedPath = [resourceApi performSelector:NSSelectorFromString(@"mapUriToFile:") withObject:fileUrl];
              #pragma clang diagnostic pop
              
              if (mappedPath && mappedPath.length > 0) {
                resolvedPath = mappedPath;
              }
            }
          }
        }
      } @catch (NSException *e) {
        // Fallback
      }
    }

    const char *insertSQL = "INSERT OR REPLACE INTO download_queue (Id, Endpoint, Payload, FilePath, DownloadStrategy, Status) VALUES (?, ?, ?, ?, ?, 'pending');";
    sqlite3_stmt *stmt;
    if (sqlite3_prepare_v2(db, insertSQL, -1, &stmt, NULL) == SQLITE_OK) {
      sqlite3_bind_text(stmt, 1, [recordId UTF8String], -1, SQLITE_TRANSIENT);
      sqlite3_bind_text(stmt, 2, [endpoint UTF8String], -1, SQLITE_TRANSIENT);
      sqlite3_bind_text(stmt, 3, [payload UTF8String], -1, SQLITE_TRANSIENT);
      sqlite3_bind_text(stmt, 4, [resolvedPath UTF8String], -1, SQLITE_TRANSIENT);
      sqlite3_bind_text(stmt, 5, [downloadStrategy UTF8String], -1, SQLITE_TRANSIENT);

      if (sqlite3_step(stmt) == SQLITE_DONE) {
        NSDictionary *response = @{@"id": recordId, @"status": @"pending"};
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:response];
        [strongSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
      } else {
        const char *errMsg = sqlite3_errmsg(db);
        [strongSelf sendErrorResult:[NSString stringWithFormat:@"SQL Insert Error: %s", errMsg] command:command];
      }
      sqlite3_finalize(stmt);
    } else {
      const char *errMsg = sqlite3_errmsg(db);
      [strongSelf sendErrorResult:[NSString stringWithFormat:@"SQL Prepare Error: %s", errMsg] command:command];
    }
    sqlite3_close(db);
  }];
}

- (void)getQueuedDownloads:(CDVInvokedUrlCommand *)command {
  __weak BackgroundSyncPlugin *weakSelf = self;
  [self.commandDelegate runInBackground:^{
    BackgroundSyncPlugin *strongSelf = weakSelf;
    if (!strongSelf) return;

    sqlite3 *db = [strongSelf openWritableDatabase];
    if (!db) {
      [strongSelf sendErrorResult:@"Failed to open SQLite database." command:command];
      return;
    }

    NSMutableArray *resultList = [NSMutableArray array];
    const char *selectSQL = "SELECT Id, Status, Error FROM download_queue WHERE LOWER(Status) = 'pending' OR LOWER(Status) = 'failed' ORDER BY Sequence ASC;";
    sqlite3_stmt *stmt;
    if (sqlite3_prepare_v2(db, selectSQL, -1, &stmt, NULL) == SQLITE_OK) {
      while (sqlite3_step(stmt) == SQLITE_ROW) {
        const char *idChar = (char *)sqlite3_column_text(stmt, 0);
        const char *statusChar = (char *)sqlite3_column_text(stmt, 1);
        const char *errChar = (char *)sqlite3_column_text(stmt, 2);
        
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        row[@"id"] = idChar ? [NSString stringWithUTF8String:idChar] : @"";
        row[@"status"] = statusChar ? [NSString stringWithUTF8String:statusChar] : @"";
        row[@"error"] = errChar ? [NSString stringWithUTF8String:errChar] : @"";
        [resultList addObject:row];
      }
      sqlite3_finalize(stmt);
      CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:resultList];
      [strongSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    } else {
      const char *errMsg = sqlite3_errmsg(db);
      [strongSelf sendErrorResult:[NSString stringWithFormat:@"SQL Query Error: %s", errMsg] command:command];
    }
    sqlite3_close(db);
  }];
}

- (void)getCompletedDownloads:(CDVInvokedUrlCommand *)command {
  int limit = -1;
  int offset = 0;
  if (command.arguments.count > 0) {
    NSDictionary *options = BSSyncDictionary(BSSyncArgument(command, 0));
    NSString *limitValue = BSSyncString(options[@"limit"]);
    NSString *offsetValue = BSSyncString(options[@"offset"]);
    if (limitValue) limit = [limitValue intValue];
    if (offsetValue) offset = MAX(0, [offsetValue intValue]);
  }
  // When autoDeleteCompleted is true, each page is deleted as soon as it's read, so the
  // "next page" is always at offset 0 relative to what remains — a caller-supplied offset > 0
  // would skip records that shifted down after the previous page's delete.
  if (self.autoDeleteCompleted) {
    offset = 0;
  }

  __weak BackgroundSyncPlugin *weakSelf = self;
  [self.commandDelegate runInBackground:^{
    BackgroundSyncPlugin *strongSelf = weakSelf;
    if (!strongSelf) return;

    sqlite3 *db = [strongSelf openWritableDatabase];
    if (!db) {
      [strongSelf sendErrorResult:@"Failed to open SQLite database." command:command];
      return;
    }

    NSString *selectSQLStr = @"SELECT Id, Status, FilePath, ResponseData, DownloadStrategy FROM download_queue WHERE LOWER(Status) = 'completed' ORDER BY Sequence ASC";
    int selectLimit = (limit > 0) ? limit + 1 : -1;
    if (selectLimit > 0) {
      selectSQLStr = [selectSQLStr stringByAppendingFormat:@" LIMIT %d", selectLimit];
      if (offset > 0) {
        selectSQLStr = [selectSQLStr stringByAppendingFormat:@" OFFSET %d", offset];
      }
    }

    NSMutableArray *resultList = [NSMutableArray array];
    sqlite3_stmt *stmt;
    if (sqlite3_prepare_v2(db, [selectSQLStr UTF8String], -1, &stmt, NULL) == SQLITE_OK) {
      int count = 0;
      BOOL hasMore = NO;

      while (sqlite3_step(stmt) == SQLITE_ROW) {
        if (limit > 0 && count >= limit) {
          hasMore = YES;
          break;
        }

        const char *idChar = (char *)sqlite3_column_text(stmt, 0);
        const char *statusChar = (char *)sqlite3_column_text(stmt, 1);
        const char *filePathChar = (char *)sqlite3_column_text(stmt, 2);
        const char *respChar = (char *)sqlite3_column_text(stmt, 3);
        const char *strategyChar = (char *)sqlite3_column_text(stmt, 4);
        
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        row[@"id"] = idChar ? [NSString stringWithUTF8String:idChar] : @"";
        row[@"status"] = statusChar ? [NSString stringWithUTF8String:statusChar] : @"";
        row[@"filePath"] = filePathChar ? [NSString stringWithUTF8String:filePathChar] : @"";
        row[@"responseData"] = respChar ? [NSString stringWithUTF8String:respChar] : @"";
        row[@"downloadStrategy"] = strategyChar ? [NSString stringWithUTF8String:strategyChar] : @"REST_PAYLOAD";
        [resultList addObject:row];
        count++;
      }
      sqlite3_finalize(stmt);

      if (strongSelf.autoDeleteCompleted && resultList.count > 0) {
        const char *deleteSQL = "DELETE FROM download_queue WHERE Id = ?;";
        sqlite3_stmt *delStmt;
        if (sqlite3_prepare_v2(db, deleteSQL, -1, &delStmt, NULL) == SQLITE_OK) {
          for (NSDictionary *row in resultList) {
            NSString *recordId = row[@"id"];
            sqlite3_bind_text(delStmt, 1, [recordId UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_step(delStmt);
            sqlite3_reset(delStmt);
          }
          sqlite3_finalize(delStmt);
        }
      }

      NSDictionary *response = @{
        @"records": resultList,
        @"hasMore": @(hasMore)
      };

      CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:response];
      [strongSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    } else {
      const char *errMsg = sqlite3_errmsg(db);
      [strongSelf sendErrorResult:[NSString stringWithFormat:@"SQL Query Error: %s", errMsg] command:command];
    }
    sqlite3_close(db);
  }];
}

- (void)removeDownloads:(CDVInvokedUrlCommand *)command {
  id idsArg = BSSyncArgument(command, 0);
  NSArray *ids = [idsArg isKindOfClass:[NSArray class]] ? idsArg : @[];

  __weak BackgroundSyncPlugin *weakSelf = self;
  [self.commandDelegate runInBackground:^{
    BackgroundSyncPlugin *strongSelf = weakSelf;
    if (!strongSelf) return;

    sqlite3 *db = [strongSelf openWritableDatabase];
    if (!db) {
      [strongSelf sendErrorResult:@"Failed to open SQLite database." command:command];
      return;
    }

    const char *deleteSQL = "DELETE FROM download_queue WHERE Id = ?;";
    sqlite3_stmt *stmt;
    if (sqlite3_prepare_v2(db, deleteSQL, -1, &stmt, NULL) == SQLITE_OK) {
      // Wrap all deletes in one transaction instead of letting SQLite auto-commit (and fsync)
      // after every single statement — matches the Android implementation's beginTransaction/
      // setTransactionSuccessful/endTransaction pattern.
      sqlite3_exec(db, "BEGIN TRANSACTION;", NULL, NULL, NULL);
      for (id item in ids) {
        // Numbers are matched as text, like Android; null and other values are skipped.
        NSString *recordId = BSSyncString(item);
        if (!recordId) continue;
        sqlite3_bind_text(stmt, 1, [recordId UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_step(stmt);
        sqlite3_reset(stmt);
      }
      sqlite3_exec(db, "COMMIT;", NULL, NULL, NULL);
      sqlite3_finalize(stmt);
      CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"Downloads removed successfully."];
      [strongSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    } else {
      const char *errMsg = sqlite3_errmsg(db);
      [strongSelf sendErrorResult:[NSString stringWithFormat:@"SQL Delete Error: %s", errMsg] command:command];
    }
    sqlite3_close(db);
  }];
}

- (void)clearDownloadQueue:(CDVInvokedUrlCommand *)command {
  __weak BackgroundSyncPlugin *weakSelf = self;
  [self.commandDelegate runInBackground:^{
    BackgroundSyncPlugin *strongSelf = weakSelf;
    if (!strongSelf) return;

    sqlite3 *db = [strongSelf openWritableDatabase];
    if (!db) {
      [strongSelf sendErrorResult:@"Failed to open SQLite database." command:command];
      return;
    }

    char *errMsg = NULL;
    if (sqlite3_exec(db, "DELETE FROM download_queue;", NULL, NULL, &errMsg) == SQLITE_OK) {
      CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"Download queue cleared successfully."];
      [strongSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    } else {
      [strongSelf sendErrorResult:[NSString stringWithFormat:@"SQL Clear Error: %s", errMsg] command:command];
      sqlite3_free(errMsg);
    }
    sqlite3_close(db);
  }];
}

- (void)openDatabaseInspector:(CDVInvokedUrlCommand *)command {
  __weak BackgroundSyncPlugin *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    BackgroundSyncPlugin *strongSelf = weakSelf;
    if (!strongSelf) return;

    DatabaseInspectorViewController *inspectorVC = [[DatabaseInspectorViewController alloc] init];
    inspectorVC.plugin = strongSelf;
    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:inspectorVC];
    navController.modalPresentationStyle = UIModalPresentationFullScreen;
    [strongSelf.viewController presentViewController:navController animated:YES completion:nil];
  });

  CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"Database inspector opened."];
  [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)enqueueSync:(CDVInvokedUrlCommand *)command {
  if (!self.serverUrl || self.serverUrl.length == 0) {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Engine is not initialized. Please call initialize first."];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    return;
  }

  // Ack the JS call as soon as the native run has been scheduled — this mirrors Android,
  // where enqueueSync() resolves the moment WorkManager accepts the task rather than waiting
  // for the whole upload+download cycle to finish. From here on, progress/completion/failure
  // is reported exclusively through the registered progress listener
  // (onStarted/onProgress/onCompleted/onFailed), on both platforms.
  __weak BackgroundSyncPlugin *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    NSString *message = [weakSelf startSyncRun] ?: @"Background sync task scheduled successfully.";
    CDVPluginResult *ackResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:message];
    [weakSelf.commandDelegate sendPluginResult:ackResult callbackId:command.callbackId];
  });
}

// Main thread only. Starts a run, or, when one is already running, asks it to pick up the
// records queued since it started instead of cancelling it (which used to report a
// "Synchronization cancelled by user" failure the user never asked for, once per extra call).
- (NSString *)startSyncRun {
  self.retryGeneration++;  // a start supersedes any scheduled automatic retry
  self.resumeWhenActive = NO;

  if (self.isSyncRunning) {
    self.rerunRequested = YES;
    LogDebug(@"[BG-SYNC-IOS] Sync already running; records queued since it started join this run.");
    return @"Sync already running; records queued since it started are included in this run.";
  }

  self.isSyncCancelled = NO;
  self.backgroundTimeExpired = NO;
  self.rerunRequested = NO;
  self.isSyncRunning = YES;

  __weak BackgroundSyncPlugin *weakSelf = self;
  UIApplication *application = [UIApplication sharedApplication];
  self.syncBgTask = [application beginBackgroundTaskWithName:@"BackgroundSyncPluginTask" expirationHandler:^{
      // iOS grants about 30 s after the app leaves the foreground. Stop at the next record
      // boundary and give the time back now; the run is marked for an automatic resume when
      // the app is active again. isSyncRunning stays YES until the loop has really stopped,
      // so a sync() call meanwhile cannot start a second, concurrent run.
      BackgroundSyncPlugin *strongSelf = weakSelf;
      if (!strongSelf) return;
      strongSelf.backgroundTimeExpired = YES;
      strongSelf.isSyncCancelled = YES;
      if (strongSelf.enableNotifications) {
        NSString *title = strongSelf.notificationTexts[@"failureTitle"] ?: @"Sync Suspended";
        NSString *bodyPattern = strongSelf.notificationTexts[@"failureBody"] ?: @"Sync paused: {error}. Will resume automatically.";
        NSString *body = [bodyPattern stringByReplacingOccurrencesOfString:@"{error}" withString:@"Background execution limit reached"];
        [strongSelf sendLocalNotificationWithTitle:title body:body isSilent:NO];
      }
      [strongSelf endSyncBackgroundTask];
  }];

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      BackgroundSyncPlugin *strongSelf = weakSelf;
      if (!strongSelf) return;
      NSString *outcome = [strongSelf processSyncQueues];
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf finishSyncRunWithOutcome:outcome];
      });
  });
  return nil;
}

// Main thread only.
- (void)endSyncBackgroundTask {
  if (self.syncBgTask != UIBackgroundTaskInvalid) {
    [[UIApplication sharedApplication] endBackgroundTask:self.syncBgTask];
    self.syncBgTask = UIBackgroundTaskInvalid;
  }
}

// Main thread only. Decides what happens after a run stops.
- (void)finishSyncRunWithOutcome:(NSString *)outcome {
  self.isSyncRunning = NO;
  [self endSyncBackgroundTask];
  BOOL rerun = self.rerunRequested;
  self.rerunRequested = NO;

  if ([outcome isEqualToString:BSSyncOutcomeCompleted]) {
    self.retryDelay = 0;
  } else if ([outcome isEqualToString:BSSyncOutcomeExpired]) {
    // Nothing is lost: the remaining rows are still pending/failed. Continue as soon as the
    // app is in the foreground again.
    self.resumeWhenActive = YES;
  } else if ([outcome isEqualToString:BSSyncOutcomeConnectivity]) {
    // Android hands this case to WorkManager's retry with backoff. Do the same while the
    // process is alive: retry after 10 s, doubling up to 5 min, and immediately when the app
    // comes back to the foreground (the WebView's "online" event also calls sync()).
    self.retryDelay = self.retryDelay > 0 ? MIN(self.retryDelay * 2, 300) : 10;
    self.resumeWhenActive = YES;
    NSUInteger generation = ++self.retryGeneration;
    LogDebug(@"[BG-SYNC-IOS] Connectivity failure; retrying in %.0f s.", self.retryDelay);
    __weak BackgroundSyncPlugin *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.retryDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BackgroundSyncPlugin *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.retryGeneration != generation || strongSelf.isSyncRunning) return;
        [strongSelf startSyncRun];
    });
  }

  if (rerun) {
    // sync() was called after this run's last look at the queue (or before a cancel/expiry
    // took effect): honour it now.
    [self startSyncRun];
  } else if (self.resumeWhenActive && [UIApplication sharedApplication].applicationState == UIApplicationStateActive &&
             [outcome isEqualToString:BSSyncOutcomeExpired]) {
    [self startSyncRun];
  }
}

- (void)appDidBecomeActive:(NSNotification *)notification {
  if (self.resumeWhenActive && !self.isSyncRunning && self.serverUrl.length > 0) {
    LogDebug(@"[BG-SYNC-IOS] App active again; resuming the interrupted sync.");
    [self startSyncRun];
  }
}

// Pending/failed rows of a queue, in queue order, minus the ids this run already took.
- (NSArray<NSDictionary *> *)pendingRowsInTable:(NSString *)table strategyColumn:(NSString *)strategyColumn db:(sqlite3 *)db excluding:(NSSet<NSString *> *)taken {
  NSMutableArray *rows = [NSMutableArray array];
  NSString *sql = [NSString stringWithFormat:@"SELECT Id, Endpoint, FilePath, %@ FROM %@ WHERE LOWER(Status) = 'pending' OR LOWER(Status) = 'failed' ORDER BY Sequence ASC;", strategyColumn, table];
  sqlite3_stmt *stmt;
  if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &stmt, NULL) == SQLITE_OK) {
    while (sqlite3_step(stmt) == SQLITE_ROW) {
      const char *idChar = (const char *)sqlite3_column_text(stmt, 0);
      if (!idChar) {
        LogDebug(@"[BG-SYNC-IOS] Skipping %@ row with NULL Id.", table);
        continue;
      }
      NSString *recordId = [NSString stringWithUTF8String:idChar];
      if ([taken containsObject:recordId]) continue;
      const char *endpointChar = (const char *)sqlite3_column_text(stmt, 1);
      const char *filePathChar = (const char *)sqlite3_column_text(stmt, 2);
      const char *strategyChar = (const char *)sqlite3_column_text(stmt, 3);
      [rows addObject:@{
        @"Id" : recordId,
        @"Endpoint" : endpointChar ? [NSString stringWithUTF8String:endpointChar] : @"",
        @"FilePath" : filePathChar ? [NSString stringWithUTF8String:filePathChar] : [NSNull null],
        @"Strategy" : strategyChar ? [NSString stringWithUTF8String:strategyChar] : @"REST_PAYLOAD"
      }];
    }
    sqlite3_finalize(stmt);
  } else {
    LogDebug(@"[BG-SYNC-IOS] ERROR: Failed to read %@: %s", table, sqlite3_errmsg(db));
  }
  return rows;
}

// Re-reads one row right before it is sent. Returns nil when the row was removed (removeRecords,
// clearQueue, the inspector) or already completed since the run listed it, so it is skipped
// instead of being sent with an empty payload. A row re-enqueued under the same id is sent
// with its latest values.
- (NSDictionary *)currentRowInTable:(NSString *)table strategyColumn:(NSString *)strategyColumn recordId:(NSString *)recordId db:(sqlite3 *)db {
  NSString *sql = [NSString stringWithFormat:@"SELECT Payload, Endpoint, FilePath, %@, Status FROM %@ WHERE Id = ?;", strategyColumn, table];
  NSDictionary *row = nil;
  sqlite3_stmt *stmt;
  if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &stmt, NULL) == SQLITE_OK) {
    sqlite3_bind_text(stmt, 1, [recordId UTF8String], -1, SQLITE_TRANSIENT);
    if (sqlite3_step(stmt) == SQLITE_ROW) {
      const char *statusChar = (const char *)sqlite3_column_text(stmt, 4);
      NSString *status = statusChar ? [[NSString stringWithUTF8String:statusChar] lowercaseString] : @"";
      if ([status isEqualToString:@"pending"] || [status isEqualToString:@"failed"]) {
        const char *payloadChar = (const char *)sqlite3_column_text(stmt, 0);
        const char *endpointChar = (const char *)sqlite3_column_text(stmt, 1);
        const char *filePathChar = (const char *)sqlite3_column_text(stmt, 2);
        const char *strategyChar = (const char *)sqlite3_column_text(stmt, 3);
        row = @{
          @"Payload" : payloadChar ? [NSString stringWithUTF8String:payloadChar] : @"",
          @"Endpoint" : endpointChar ? [NSString stringWithUTF8String:endpointChar] : @"",
          @"FilePath" : filePathChar ? [NSString stringWithUTF8String:filePathChar] : @"",
          @"Strategy" : strategyChar ? [NSString stringWithUTF8String:strategyChar] : @"REST_PAYLOAD"
        };
      }
    }
    sqlite3_finalize(stmt);
  }
  return row;
}

- (void)setStatus:(NSString *)status error:(NSString *)error responseData:(NSString *)responseData table:(NSString *)table recordId:(NSString *)recordId db:(sqlite3 *)db {
  NSString *sql;
  if (responseData) {
    sql = [NSString stringWithFormat:@"UPDATE %@ SET Status = ?, Error = ?, ResponseData = ? WHERE Id = ?;", table];
  } else {
    sql = [NSString stringWithFormat:@"UPDATE %@ SET Status = ?, Error = ? WHERE Id = ?;", table];
  }
  sqlite3_stmt *stmt;
  if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &stmt, NULL) == SQLITE_OK) {
    int i = 1;
    sqlite3_bind_text(stmt, i++, [status UTF8String], -1, SQLITE_TRANSIENT);
    if (error) sqlite3_bind_text(stmt, i++, [error UTF8String], -1, SQLITE_TRANSIENT); else sqlite3_bind_null(stmt, i++);
    if (responseData) sqlite3_bind_text(stmt, i++, [responseData UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, i, [recordId UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
  }
}

- (NSString *)stopOutcomeForCancellation {
  return self.backgroundTimeExpired ? BSSyncOutcomeExpired : BSSyncOutcomeCancelled;
}

- (NSString *)stopMessageForCancellation {
  return self.backgroundTimeExpired ? @"iOS background execution time expired" : @"Synchronization cancelled by user";
}

// Runs on a background queue. Drains sync_queue, then download_queue, and returns one of the
// BSSyncOutcome values. When sync() is called during the run, rows queued since the run
// started are picked up before it ends (one onStarted/onCompleted pair per run).
- (NSString *)processSyncQueues {
  LogDebug(@"[BG-SYNC-IOS] processSyncQueues execution started.");

  sqlite3 *db = [self openWritableDatabase];
  if (!db) {
    LogDebug(@"[BG-SYNC-IOS] ERROR: Failed to open SQLite database.");
    [self broadcastEvent:@"failed" percentage:0 completed:0 total:0 error:@"Failed to open SQLite database."];
    return BSSyncOutcomeError;
  }

  if (self.enableNotifications) {
    NSString *title = self.notificationTexts[@"progressTitle"] ?: @"Background Sync Active";
    NSString *body = [self.notificationTexts[@"preparingBody"] ?: @"Preparing database synchronization..." copy];
    [self sendLocalNotificationWithTitle:title body:body isSilent:YES];
  }

  NSMutableSet<NSString *> *takenUploads = [NSMutableSet set];
  NSMutableSet<NSString *> *takenDownloads = [NSMutableSet set];
  int totalCount = 0, completedCount = 0;
  int totalDownloadCount = 0, completedDownloadCount = 0;
  BOOL firstPass = YES, uploadsStarted = NO, downloadsStarted = NO;
  NSString *outcome = nil;

  for (;;) {
    NSArray *uploads = [self pendingRowsInTable:@"sync_queue" strategyColumn:@"UploadStrategy" db:db excluding:takenUploads];
    NSArray *downloads = [self pendingRowsInTable:@"download_queue" strategyColumn:@"DownloadStrategy" db:db excluding:takenDownloads];
    if (uploads.count == 0 && downloads.count == 0) {
      if (firstPass) {
        if (self.enableNotifications) {
          [self sendLocalNotificationWithTitle:self.notificationTexts[@"successTitle"] ?: @"Synchronization Complete"
                                          body:self.notificationTexts[@"successBody"] ?: @"All offline records successfully uploaded."
                                      isSilent:NO];
        }
        [self broadcastEvent:@"completed" percentage:100 completed:0 total:0 error:nil];
        sqlite3_close(db);
        return BSSyncOutcomeCompleted;
      }
      break;
    }

    // ----------------- UPLOAD PROCESS -----------------
    if (uploads.count > 0) {
      for (NSDictionary *item in uploads) [takenUploads addObject:item[@"Id"]];
      if (!uploadsStarted) {
        [self broadcastEvent:@"started" percentage:0 completed:0 total:(int)uploads.count error:nil];
        uploadsStarted = YES;
      }
      totalCount += (int)uploads.count;
      outcome = [self uploadItems:uploads db:db completed:&completedCount total:&totalCount];
      if (outcome) break;
    }

    // ----------------- DOWNLOAD PROCESS -----------------
    if (downloads.count > 0) {
      for (NSDictionary *item in downloads) [takenDownloads addObject:item[@"Id"]];
      if (!downloadsStarted) {
        [self broadcastEvent:@"started_download" percentage:0 completed:0 total:(int)downloads.count error:nil];
        downloadsStarted = YES;
      }
      totalDownloadCount += (int)downloads.count;
      outcome = [self downloadItems:downloads db:db completed:&completedDownloadCount total:&totalDownloadCount uploadCompleted:completedCount uploadTotal:totalCount];
      if (outcome) break;
    }

    if (!self.rerunRequested) break;
    self.rerunRequested = NO;
    firstPass = NO;
  }

  if (outcome) {
    sqlite3_close(db);
    return outcome;
  }

  if (self.enableNotifications) {
    NSString *title = self.notificationTexts[@"successTitle"] ?: @"Sync Complete";
    NSString *bodyPattern = self.notificationTexts[@"successBody"] ?: @"Successfully synchronized {current} of {total} records.";
    NSString *body = [bodyPattern stringByReplacingOccurrencesOfString:@"{current}" withString:[NSString stringWithFormat:@"%d", completedCount + completedDownloadCount]];
    body = [body stringByReplacingOccurrencesOfString:@"{total}" withString:[NSString stringWithFormat:@"%d", totalCount + totalDownloadCount]];
    [self sendLocalNotificationWithTitle:title body:body isSilent:NO];
  }

  [self broadcastEvent:@"completed" percentage:100 completed:completedCount + completedDownloadCount total:totalCount + totalDownloadCount error:nil];
  sqlite3_close(db);
  return BSSyncOutcomeCompleted;
}

// Returns nil when every item was attempted, otherwise the outcome that stopped the loop.
- (NSString *)uploadItems:(NSArray<NSDictionary *> *)items db:(sqlite3 *)db completed:(int *)completedCount total:(int *)totalCount {
  for (NSDictionary *item in items) {
    // One pool per record: the file data, its base64 and the request body are autoreleased,
    // and without a pool they all stayed alive until the whole run ended (about 1.5 GB for
    // the 336-photo demo audit).
    @autoreleasepool {
      if (self.isSyncCancelled) {
        [self broadcastEvent:@"failed" percentage:*totalCount > 0 ? (int)(((float)*completedCount / (float)*totalCount) * 100) : 0 completed:*completedCount total:*totalCount error:[self stopMessageForCancellation]];
        return [self stopOutcomeForCancellation];
      }
      NSString *recordId = item[@"Id"];
      NSDictionary *row = [self currentRowInTable:@"sync_queue" strategyColumn:@"UploadStrategy" recordId:recordId db:db];
      if (!row) {
        LogDebug(@"[BG-SYNC-IOS] Record %@ was removed or completed during the run; skipping it.", recordId);
        (*totalCount)--;
        continue;
      }
      NSString *filePath = [row[@"FilePath"] length] > 0 ? row[@"FilePath"] : nil;

      NSString *uploadError = nil;
      if ([row[@"Strategy"] caseInsensitiveCompare:@"PRESIGNED_URL"] == NSOrderedSame) {
        uploadError = [self uploadItemViaPresignedUrlWithPayload:row[@"Payload"] endpoint:row[@"Endpoint"] filePath:filePath];
      } else {
        uploadError = [self uploadItemWithPayload:row[@"Payload"] endpoint:row[@"Endpoint"] filePath:filePath];
      }

      int percentage = (int)(((float)(*completedCount + 1) / (float)*totalCount) * 100);

      if (uploadError == nil) {
        (*completedCount)++;
        if (self.autoDeleteCompleted) {
          sqlite3_stmt *delStmt;
          if (sqlite3_prepare_v2(db, "DELETE FROM sync_queue WHERE Id = ?;", -1, &delStmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(delStmt, 1, [recordId UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_step(delStmt);
            sqlite3_finalize(delStmt);
          }
        } else {
          [self setStatus:@"completed" error:nil responseData:nil table:@"sync_queue" recordId:recordId db:db];
        }

        [self broadcastEvent:@"progress" percentage:percentage completed:*completedCount total:*totalCount error:nil];

        if (self.enableNotifications) {
          NSString *title = self.notificationTexts[@"progressTitle"] ?: @"Syncing in Background";
          NSString *bodyPattern = self.notificationTexts[@"progressBody"] ?: @"Synchronizing: {current} of {total} records ({percentage}%)";
          NSString *body = [bodyPattern stringByReplacingOccurrencesOfString:@"{current}" withString:[NSString stringWithFormat:@"%d", *completedCount]];
          body = [body stringByReplacingOccurrencesOfString:@"{total}" withString:[NSString stringWithFormat:@"%d", *totalCount]];
          body = [body stringByReplacingOccurrencesOfString:@"{percentage}" withString:[NSString stringWithFormat:@"%d", percentage]];
          [self sendLocalNotificationWithTitle:title body:body isSilent:YES];
        }
        continue;
      }

      [self setStatus:@"failed" error:uploadError responseData:nil table:@"sync_queue" recordId:recordId db:db];

      // Only a genuine connectivity failure (the request never reached the server) should
      // abort the whole run. An HTTP error response means the server was reached and
      // rejected this specific record — it's already marked "failed" above; let the loop
      // continue so unrelated queued items still get attempted.
      BOOL isConnectivityFailure = [uploadError hasPrefix:@"Upload Exception:"] ||
          [uploadError hasPrefix:@"Handshake exception:"] ||
          [uploadError hasPrefix:@"Cloud upload Exception:"];

      if (self.enableNotifications && !(isConnectivityFailure && self.backgroundTimeExpired)) {
        NSString *title = self.notificationTexts[@"failureTitle"] ?: @"Sync Suspended";
        NSString *bodyPattern = self.notificationTexts[@"failureBody"] ?: @"Sync paused: {error}. Will resume automatically.";
        NSString *body = [bodyPattern stringByReplacingOccurrencesOfString:@"{error}" withString:uploadError];
        [self sendLocalNotificationWithTitle:title body:body isSilent:NO];
      }
      [self broadcastEvent:@"failed" percentage:percentage completed:*completedCount total:*totalCount error:uploadError];

      if (isConnectivityFailure) {
        // A request cut by the app's suspension after the background time ran out is not a
        // network problem: resume when the app is back instead of backing off.
        return self.backgroundTimeExpired ? BSSyncOutcomeExpired : BSSyncOutcomeConnectivity;
      }
    }
  }
  return nil;
}

- (NSString *)downloadItems:(NSArray<NSDictionary *> *)items db:(sqlite3 *)db completed:(int *)completedDownloadCount total:(int *)totalDownloadCount uploadCompleted:(int)completedCount uploadTotal:(int)totalCount {
  for (NSDictionary *item in items) {
    @autoreleasepool {
      if (self.isSyncCancelled) {
        [self broadcastEvent:@"failed" percentage:*totalDownloadCount > 0 ? (int)(((float)*completedDownloadCount / (float)*totalDownloadCount) * 100) : 0 completed:completedCount + *completedDownloadCount total:totalCount + *totalDownloadCount error:[self stopMessageForCancellation]];
        return [self stopOutcomeForCancellation];
      }

      NSString *recordId = item[@"Id"];
      NSDictionary *row = [self currentRowInTable:@"download_queue" strategyColumn:@"DownloadStrategy" recordId:recordId db:db];
      if (!row) {
        LogDebug(@"[BG-SYNC-IOS] Download %@ was removed or completed during the run; skipping it.", recordId);
        (*totalDownloadCount)--;
        continue;
      }
      NSString *filePath = [row[@"FilePath"] length] > 0 ? row[@"FilePath"] : nil;

      int percentage = (int)(((float)(*completedDownloadCount + 1) / (float)*totalDownloadCount) * 100);

      [self broadcastEvent:@"progress_download" percentage:percentage completed:*completedDownloadCount + 1 total:*totalDownloadCount error:nil];

      if (self.enableNotifications) {
        NSString *title = self.notificationTexts[@"downloadProgressTitle"] ?: @"Background Download Active";
        NSString *bodyPattern = self.notificationTexts[@"downloadProgressBody"] ?: @"Downloading: {current} of {total} files ({percentage}%)";
        NSString *body = [bodyPattern stringByReplacingOccurrencesOfString:@"{current}" withString:[NSString stringWithFormat:@"%d", *completedDownloadCount + 1]];
        body = [body stringByReplacingOccurrencesOfString:@"{total}" withString:[NSString stringWithFormat:@"%d", *totalDownloadCount]];
        body = [body stringByReplacingOccurrencesOfString:@"{percentage}" withString:[NSString stringWithFormat:@"%d", percentage]];
        [self sendLocalNotificationWithTitle:title body:body isSilent:YES];
      }

      NSString *downloadError = nil;
      NSString *responseData = nil;

      if ([row[@"Strategy"] caseInsensitiveCompare:@"BINARY_FILE"] == NSOrderedSame) {
        downloadError = [self performBinaryFileDownloadWithUrl:row[@"Endpoint"] filePath:filePath];
      } else {
        downloadError = [self performDownloadWithEndpoint:row[@"Endpoint"] payload:row[@"Payload"] responseData:&responseData];
      }

      if (downloadError == nil) {
        (*completedDownloadCount)++;
        [self setStatus:@"completed" error:nil responseData:responseData ?: @"" table:@"download_queue" recordId:recordId db:db];
        continue;
      }

      [self setStatus:@"failed" error:downloadError responseData:nil table:@"download_queue" recordId:recordId db:db];

      BOOL isConnectivityFailure = [downloadError hasPrefix:@"Download Exception:"];
      if (self.enableNotifications && !(isConnectivityFailure && self.backgroundTimeExpired)) {
        NSString *title = self.notificationTexts[@"downloadFailureTitle"] ?: @"Download Suspended";
        NSString *bodyPattern = self.notificationTexts[@"downloadFailureBody"] ?: @"Download failed: {error}. Will retry automatically.";
        NSString *body = [bodyPattern stringByReplacingOccurrencesOfString:@"{error}" withString:downloadError];
        [self sendLocalNotificationWithTitle:title body:body isSilent:NO];
      }
      [self broadcastEvent:@"failed_download" percentage:percentage completed:*completedDownloadCount total:*totalDownloadCount error:downloadError];

      // Only a genuine connectivity failure (the request never reached the server) should
      // abort the whole run. An HTTP error response means the server was reached and
      // rejected this specific record — it's already marked "failed" above; let the loop
      // continue so unrelated queued items still get attempted.
      if (isConnectivityFailure) {
        return self.backgroundTimeExpired ? BSSyncOutcomeExpired : BSSyncOutcomeConnectivity;
      }
    }
  }
  return nil;
}

// Returns nil on success, or an error description on failure. A "Upload Exception:" prefix
// means the request never reached the server (network/timeout/DNS) — a genuine connectivity
// failure. An "HTTP $code:" prefix means the server was reached and responded with an error
// status, which is specific to this one record.
- (NSString *)uploadItemWithPayload:(NSString *)payload endpoint:(NSString *)endpoint filePath:(NSString *)filePath {
  NSString *fullUrlStr = [NSString stringWithFormat:@"%@/%@",
                       [self.serverUrl stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]],
                       [endpoint stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]]];

  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:fullUrlStr]];
  [request setTimeoutInterval:300.0];
  [request setHTTPMethod:@"POST"];
  [request setValue:@"Keep-Alive" forHTTPHeaderField:@"Connection"];
  [request setValue:@"application/json; charset=UTF-8" forHTTPHeaderField:@"Content-Type"];

  if (self.headers && self.headers.count > 0) {
    for (NSString *key in self.headers) {
      NSString *value = self.headers[key];
      [request setValue:value forHTTPHeaderField:key];
    }
  }

  NSMutableDictionary *requestDict = [NSMutableDictionary dictionary];
  NSError *jsonError = nil;
  id parsedPayload = [NSJSONSerialization JSONObjectWithData:[payload dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingAllowFragments error:&jsonError];
  if (jsonError || !parsedPayload) {
    requestDict[@"payload"] = payload;
  } else {
    requestDict[@"payload"] = parsedPayload;
  }

  if (filePath && filePath.length > 0) {
    NSString *cleanPath = [filePath stringByReplacingOccurrencesOfString:@"file://" withString:@""];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:cleanPath]) {
      NSString *fileName = [cleanPath lastPathComponent];
      NSData *fileData = [NSData dataWithContentsOfFile:cleanPath];
      NSString *base64Data = [fileData base64EncodedStringWithOptions:0];

      NSString *mimeType = @"application/octet-stream";
      NSString *extension = [fileName pathExtension].lowercaseString;
      if ([extension isEqualToString:@"jpg"] || [extension isEqualToString:@"jpeg"]) {
        mimeType = @"image/jpeg";
      } else if ([extension isEqualToString:@"png"]) {
        mimeType = @"image/png";
      } else if ([extension isEqualToString:@"gif"]) {
        mimeType = @"image/gif";
      } else if ([extension isEqualToString:@"pdf"]) {
        mimeType = @"application/pdf";
      } else if ([extension isEqualToString:@"mp4"]) {
        mimeType = @"video/mp4";
      }

      NSMutableDictionary *fileDict = [NSMutableDictionary dictionary];
      fileDict[@"filename"] = fileName;
      fileDict[@"contentType"] = mimeType;
      fileDict[@"base64Data"] = base64Data;

      requestDict[@"file"] = fileDict;
    }
  }

  NSData *bodyData = [NSJSONSerialization dataWithJSONObject:requestDict options:0 error:nil];
  [request setHTTPBody:bodyData];

  __block NSData *responseData = nil;
  __block NSURLResponse *response = nil;
  __block NSError *error = nil;
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

  NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
      responseData = data;
      response = r;
      error = e;
      dispatch_semaphore_signal(semaphore);
  }];
  [task resume];
  dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

  if (error) {
    LogDebug(@"Error: Background Upload Request Failed: %@", error.localizedDescription);
    return [NSString stringWithFormat:@"Upload Exception: %@", error.localizedDescription];
  }

  NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
  if (httpResponse.statusCode >= 200 && httpResponse.statusCode < 300) {
    return nil;
  }

  NSString *details = responseData ? [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding] : @"No details";
  NSString *err = [NSString stringWithFormat:@"HTTP %ld: %@", (long)httpResponse.statusCode, details];
  LogDebug(@"Error: Background Upload Request Failed: %@", err);
  return err;
}

// Returns nil on success, or an error description on failure. "Handshake exception:" and
// "Cloud upload Exception:" prefixes mean a request never reached the server — a genuine
// connectivity failure. An "HTTP $code:" prefix means the server was reached and responded
// with an error status, specific to this one record. "Local error:" prefixes mean the
// problem is local to this device/record (missing file, malformed response) and isn't a
// connectivity issue either.
- (NSString *)uploadItemViaPresignedUrlWithPayload:(NSString *)payload endpoint:(NSString *)endpoint filePath:(NSString *)filePath {
  if (!filePath || filePath.length == 0) {
    LogDebug(@"Error: FilePath is required for Presigned URL strategy.");
    return @"Local error: FilePath is required for Presigned URL strategy.";
  }

  NSString *cleanPath = [filePath stringByReplacingOccurrencesOfString:@"file://" withString:@""];
  NSFileManager *fileManager = [NSFileManager defaultManager];
  if (![fileManager fileExistsAtPath:cleanPath]) {
    LogDebug(@"Error: Local file not found for Presigned URL upload: %@", cleanPath);
    return [NSString stringWithFormat:@"Local error: Local file not found at path: %@", cleanPath];
  }

  NSString *handshakeUrlStr = [NSString stringWithFormat:@"%@/%@",
                       [self.serverUrl stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]],
                       [endpoint stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]]];

  NSMutableURLRequest *handshakeRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:handshakeUrlStr]];
  [handshakeRequest setTimeoutInterval:300.0];
  [handshakeRequest setHTTPMethod:@"POST"];
  [handshakeRequest setValue:@"Keep-Alive" forHTTPHeaderField:@"Connection"];
  [handshakeRequest setValue:@"application/json; charset=UTF-8" forHTTPHeaderField:@"Content-Type"];

  if (self.headers && self.headers.count > 0) {
    for (NSString *key in self.headers) {
      NSString *value = self.headers[key];
      [handshakeRequest setValue:value forHTTPHeaderField:key];
    }
  }

  NSMutableDictionary *handshakeDict = [NSMutableDictionary dictionary];
  NSError *jsonError = nil;
  id parsedPayload = [NSJSONSerialization JSONObjectWithData:[payload dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingAllowFragments error:&jsonError];
  if (jsonError || !parsedPayload) {
    handshakeDict[@"payload"] = payload;
  } else {
    handshakeDict[@"payload"] = parsedPayload;
  }

  NSData *handshakeBody = [NSJSONSerialization dataWithJSONObject:handshakeDict options:0 error:nil];
  [handshakeRequest setHTTPBody:handshakeBody];

  __block NSData *handshakeData = nil;
  __block NSURLResponse *handshakeResponse = nil;
  __block NSError *handshakeError = nil;
  dispatch_semaphore_t handshakeSemaphore = dispatch_semaphore_create(0);

  NSURLSessionDataTask *handshakeTask = [[NSURLSession sharedSession] dataTaskWithRequest:handshakeRequest completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
      handshakeData = d;
      handshakeResponse = r;
      handshakeError = e;
      dispatch_semaphore_signal(handshakeSemaphore);
  }];
  [handshakeTask resume];
  dispatch_semaphore_wait(handshakeSemaphore, DISPATCH_TIME_FOREVER);

  if (handshakeError) {
    LogDebug(@"Error: Presigned URL handshake failed: %@", handshakeError.localizedDescription);
    return [NSString stringWithFormat:@"Handshake exception: %@", handshakeError.localizedDescription];
  }

  NSHTTPURLResponse *httpHandshakeResponse = (NSHTTPURLResponse *)handshakeResponse;
  if (httpHandshakeResponse.statusCode < 200 || httpHandshakeResponse.statusCode >= 300) {
    NSString *details = handshakeData ? [[NSString alloc] initWithData:handshakeData encoding:NSUTF8StringEncoding] : @"No details";
    LogDebug(@"Error: Handshake returned HTTP status %ld", (long)httpHandshakeResponse.statusCode);
    return [NSString stringWithFormat:@"HTTP %ld: %@", (long)httpHandshakeResponse.statusCode, details];
  }

  NSDictionary *responseJson = [NSJSONSerialization JSONObjectWithData:handshakeData options:0 error:nil];
  if (!responseJson || ![responseJson isKindOfClass:[NSDictionary class]]) {
    LogDebug(@"Error: Failed to parse handshake response JSON.");
    return @"Local error: Failed to parse handshake response JSON.";
  }

  NSString *uploadUrl = responseJson[@"uploadUrl"];
  NSString *httpMethod = responseJson[@"method"] ?: @"PUT";
  NSDictionary *customHeaders = responseJson[@"headers"];

  if (!uploadUrl || uploadUrl.length == 0) {
    LogDebug(@"Error: Handshake response did not contain 'uploadUrl'.");
    return @"Local error: Handshake response did not contain 'uploadUrl'.";
  }

  LogDebug(@"[BG-SYNC-CLOUD] Starting direct streaming cloud upload on iOS: %@", uploadUrl);
  NSMutableURLRequest *uploadRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:uploadUrl]];
  [uploadRequest setTimeoutInterval:300.0];
  [uploadRequest setHTTPMethod:httpMethod.uppercaseString];

  if (customHeaders && [customHeaders isKindOfClass:[NSDictionary class]]) {
    for (NSString *key in customHeaders) {
      NSString *value = customHeaders[key];
      [uploadRequest setValue:value forHTTPHeaderField:key];
    }
  }

  if (![uploadRequest valueForHTTPHeaderField:@"Content-Type"]) {
    NSString *mimeType = @"application/octet-stream";
    NSString *extension = [cleanPath pathExtension].lowercaseString;
    if ([extension isEqualToString:@"jpg"] || [extension isEqualToString:@"jpeg"]) {
      mimeType = @"image/jpeg";
    } else if ([extension isEqualToString:@"png"]) {
      mimeType = @"image/png";
    } else if ([extension isEqualToString:@"gif"]) {
      mimeType = @"image/gif";
    } else if ([extension isEqualToString:@"pdf"]) {
      mimeType = @"application/pdf";
    }
    [uploadRequest setValue:mimeType forHTTPHeaderField:@"Content-Type"];
  }

  NSInputStream *fileStream = [NSInputStream inputStreamWithFileAtPath:cleanPath];
  [uploadRequest setHTTPBodyStream:fileStream];

  __block NSURLResponse *uploadResponse = nil;
  __block NSError *uploadError = nil;
  dispatch_semaphore_t uploadSemaphore = dispatch_semaphore_create(0);

  NSURLSessionDataTask *uploadTask = [[NSURLSession sharedSession] dataTaskWithRequest:uploadRequest completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
      uploadResponse = r;
      uploadError = e;
      dispatch_semaphore_signal(uploadSemaphore);
  }];
  [uploadTask resume];
  dispatch_semaphore_wait(uploadSemaphore, DISPATCH_TIME_FOREVER);

  if (uploadError) {
    LogDebug(@"Error: Direct cloud upload request failed: %@", uploadError.localizedDescription);
    return [NSString stringWithFormat:@"Cloud upload Exception: %@", uploadError.localizedDescription];
  }

  NSHTTPURLResponse *httpUploadResponse = (NSHTTPURLResponse *)uploadResponse;
  if (httpUploadResponse.statusCode >= 200 && httpUploadResponse.statusCode < 300) {
    LogDebug(@"[BG-SYNC-CLOUD] Cloud upload completed successfully with HTTP status %ld", (long)httpUploadResponse.statusCode);
    return nil;
  } else {
    LogDebug(@"Error: Cloud upload request failed with HTTP status %ld", (long)httpUploadResponse.statusCode);
    return [NSString stringWithFormat:@"HTTP %ld: Cloud upload failed", (long)httpUploadResponse.statusCode];
  }
}

- (void)scheduleNotificationContentWithTitle:(NSString *)title body:(NSString *)body isSilent:(BOOL)isSilent {
  UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
  content.title = title;
  content.body = body;
  if (!isSilent) {
    content.sound = [UNNotificationSound defaultSound];
  }

  UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:1 repeats:NO];
  UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:@"LocalStorageSyncNotification" content:content trigger:trigger];
  [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
}

- (void)sendLocalNotificationWithTitle:(NSString *)title body:(NSString *)body isSilent:(BOOL)isSilent {
  if (@available(iOS 10.0, *)) {
    // A sync cycle can post one notification per record (dozens in a large batch). Once we
    // know the authorization answer for this process, reuse it instead of paying for an async
    // requestAuthorizationWithOptions round-trip before every single notification.
    if (self.notificationAuthorizationChecked) {
      if (self.notificationAuthorizationGranted) {
        [self scheduleNotificationContentWithTitle:title body:body isSilent:isSilent];
      }
      return;
    }

    __weak BackgroundSyncPlugin *weakSelf = self;
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound) completionHandler:^(BOOL granted, NSError *_Nullable error) {
        BackgroundSyncPlugin *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.notificationAuthorizationChecked = YES;
        strongSelf.notificationAuthorizationGranted = granted;
        if (granted) {
          [strongSelf scheduleNotificationContentWithTitle:title body:body isSilent:isSilent];
        }
    }];
  }
}

- (void)sendErrorResult:(NSString *)message command:(CDVInvokedUrlCommand *)command {
  CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:message];
  [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)broadcastEvent:(NSString *)event percentage:(int)percentage completed:(int)completed total:(int)total error:(NSString *)error {
  if (!self.progressCallbackId) return;

  NSMutableDictionary *eventData = [NSMutableDictionary dictionary];
  eventData[@"event"] = event;
  eventData[@"percentage"] = @(percentage);
  eventData[@"completedCount"] = @(completed);
  eventData[@"totalCount"] = @(total);
  if (error) {
    eventData[@"error"] = error;
  }

  CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:eventData];
  [result setKeepCallbackAsBool:YES];
  [self.commandDelegate sendPluginResult:result callbackId:self.progressCallbackId];
}

- (NSString *)performDownloadWithEndpoint:(NSString *)endpoint payload:(NSString *)payload responseData:(NSString **)outResponseData {
  NSString *fullUrlStr = nil;
  if ([endpoint hasPrefix:@"http://"] || [endpoint hasPrefix:@"https://"]) {
    fullUrlStr = endpoint;
  } else {
    fullUrlStr = [NSString stringWithFormat:@"%@/%@",
                         [self.serverUrl stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]],
                         [endpoint stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]]];
  }

  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:fullUrlStr]];
  [request setTimeoutInterval:300.0];
  [request setHTTPMethod:(payload && payload.length > 0) ? @"POST" : @"GET"];
  [request setValue:@"Keep-Alive" forHTTPHeaderField:@"Connection"];
  [request setValue:@"application/json; charset=UTF-8" forHTTPHeaderField:@"Content-Type"];

  if (self.headers && self.headers.count > 0) {
    for (NSString *key in self.headers) {
      NSString *value = self.headers[key];
      [request setValue:value forHTTPHeaderField:key];
    }
  }

  if (payload && payload.length > 0) {
    NSMutableDictionary *requestDict = [NSMutableDictionary dictionary];
    NSError *jsonError = nil;
    id parsedPayload = [NSJSONSerialization JSONObjectWithData:[payload dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingAllowFragments error:&jsonError];
    if (jsonError || !parsedPayload) {
      requestDict[@"payload"] = payload;
    } else {
      requestDict[@"payload"] = parsedPayload;
    }
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:requestDict options:0 error:nil];
    [request setHTTPBody:bodyData];
  }

  __block NSData *responseData = nil;
  __block NSURLResponse *response = nil;
  __block NSError *error = nil;
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

  NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
      responseData = data;
      response = r;
      error = e;
      dispatch_semaphore_signal(semaphore);
  }];
  [task resume];
  dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

  if (error) {
    return [NSString stringWithFormat:@"Download Exception: %@", error.localizedDescription];
  }

  NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
  if (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
    NSString *details = responseData ? [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding] : @"No details";
    return [NSString stringWithFormat:@"HTTP %ld: %@", (long)httpResponse.statusCode, details];
  }

  if (responseData && outResponseData) {
    *outResponseData = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
  }
  return nil;
}

- (NSString *)performBinaryFileDownloadWithUrl:(NSString *)downloadUrl filePath:(NSString *)filePath {
  NSString *fullUrlStr = nil;
  if ([downloadUrl hasPrefix:@"http://"] || [downloadUrl hasPrefix:@"https://"]) {
    fullUrlStr = downloadUrl;
  } else {
    fullUrlStr = [NSString stringWithFormat:@"%@/%@",
                         [self.serverUrl stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]],
                         [downloadUrl stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]]];
  }

  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:fullUrlStr]];
  [request setTimeoutInterval:300.0];
  [request setHTTPMethod:@"GET"];
  [request setValue:@"Keep-Alive" forHTTPHeaderField:@"Connection"];

  if (self.headers && self.headers.count > 0) {
    for (NSString *key in self.headers) {
      NSString *value = self.headers[key];
      [request setValue:value forHTTPHeaderField:key];
    }
  }

  __block NSURL *locationUrl = nil;
  __block NSURLResponse *response = nil;
  __block NSError *error = nil;
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

  NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithRequest:request completionHandler:^(NSURL *location, NSURLResponse *r, NSError *e) {
      locationUrl = location;
      response = r;
      error = e;
      dispatch_semaphore_signal(semaphore);
  }];
  [task resume];
  dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

  if (error) {
    return [NSString stringWithFormat:@"Download Exception: %@", error.localizedDescription];
  }

  NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
  if (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
    return [NSString stringWithFormat:@"HTTP %ld: File download failed", (long)httpResponse.statusCode];
  }

  if (locationUrl) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *cleanPath = [filePath stringByReplacingOccurrencesOfString:@"file://" withString:@""];
    
    NSString *parentDir = [cleanPath stringByDeletingLastPathComponent];
    if (![fileManager fileExistsAtPath:parentDir]) {
      [fileManager createDirectoryAtPath:parentDir withIntermediateDirectories:YES attributes:nil error:nil];
    }

    if ([fileManager fileExistsAtPath:cleanPath]) {
      [fileManager removeItemAtPath:cleanPath error:nil];
    }

    NSError *copyError = nil;
    if ([fileManager copyItemAtURL:locationUrl toURL:[NSURL fileURLWithPath:cleanPath] error:&copyError]) {
      return nil;
    } else {
      return [NSString stringWithFormat:@"File copy error: %@", copyError.localizedDescription];
    }
  }

  return @"Downloaded location is empty";
}

@end
