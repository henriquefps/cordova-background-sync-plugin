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
@end

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

  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  self.serverUrl = [defaults stringForKey:@"BackgroundSyncPlugin_ServerUrl"];
  self.queueTableName = [defaults stringForKey:@"BackgroundSyncPlugin_QueueTableName"];
  self.headers = [defaults dictionaryForKey:@"BackgroundSyncPlugin_Headers"];
  self.notificationTexts = [defaults dictionaryForKey:@"BackgroundSyncPlugin_NotificationTexts"];

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
  NSDictionary *options = [command.arguments objectAtIndex:0];

  NSString *url = options[@"serverUrl"];
  NSString *tableName = options[@"queueTableName"];

  if (!url || url.length == 0) {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"serverUrl is required."];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    return;
  }

  self.serverUrl = url;
  self.queueTableName = tableName;

  id notifOption = options[@"enableNotifications"];
  self.enableNotifications = notifOption != nil ? [notifOption boolValue] : YES;

  id autoDeleteOption = options[@"autoDeleteCompleted"];
  self.autoDeleteCompleted = autoDeleteOption != nil ? [autoDeleteOption boolValue] : NO;

  id showDebugOption = options[@"showDebugLogs"];
  self.showDebugLogs = showDebugOption != nil ? [showDebugOption boolValue] : NO;

  id encryptOption = options[@"encryptDatabase"];
  self.encryptDatabase = encryptOption != nil ? [encryptOption boolValue] : NO;

  NSDictionary *hdrOption = options[@"headers"];
  self.headers = [hdrOption isKindOfClass:[NSDictionary class]] ? hdrOption : @{};

  NSDictionary *notifTxtOption = options[@"notificationTexts"];
  self.notificationTexts = [notifTxtOption isKindOfClass:[NSDictionary class]] ? notifTxtOption : @{};

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
  self.isSyncCancelled = YES;
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
  
  SecItemAdd((__bridge CFDictionaryRef)attributes, NULL);
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

  // nocipher build: SQLCipher is not bundled, so the database is always opened unencrypted.
  if (self.encryptDatabase) {
    NSLog(@"[BackgroundSyncPlugin] encryptDatabase is not supported in the nocipher build; opening bg_sync.db unencrypted.");
  }
  
  sqlite3_stmt *stmt;
  if (sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, NULL) != SQLITE_OK) {
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
  } else {
    sqlite3_finalize(stmt);
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
  NSString *query = [command.arguments objectAtIndex:0];
  NSArray *queryArgs = [command.arguments objectAtIndex:1];

  __weak BackgroundSyncPlugin *weakSelf = self;
  [self.commandDelegate runInBackground:^{
    BackgroundSyncPlugin *strongSelf = weakSelf;
    if (!strongSelf) return;

    sqlite3 *db = [strongSelf openWritableDatabase];
    if (!db) {
      [strongSelf sendErrorResult:@"Failed to open SQLite database." command:command];
      return;
    }

    sqlite3_stmt *stmt;
    if (sqlite3_prepare_v2(db, [query UTF8String], -1, &stmt, NULL) == SQLITE_OK) {
      for (int i = 0; i < queryArgs.count; i++) {
        id arg = [queryArgs objectAtIndex:i];
        if ([arg isKindOfClass:[NSNull class]] || arg == nil) {
          sqlite3_bind_null(stmt, i + 1);
        } else {
          NSString *argStr = [NSString stringWithFormat:@"%@", arg];
          sqlite3_bind_text(stmt, i + 1, [argStr UTF8String], -1, SQLITE_TRANSIENT);
        }
      }

      NSString *trimmedQuery = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
      if ([trimmedQuery hasPrefix:@"select"]) {
        NSMutableArray *resultList = [NSMutableArray array];
        while (sqlite3_step(stmt) == SQLITE_ROW) {
          NSMutableDictionary *row = [NSMutableDictionary dictionary];
          int columnCount = sqlite3_column_count(stmt);
          for (int i = 0; i < columnCount; i++) {
            NSString *colName = [NSString stringWithUTF8String:sqlite3_column_name(stmt, i)];
            const char *valChar = (char *)sqlite3_column_text(stmt, i);
            NSString *colVal = valChar ? [NSString stringWithUTF8String:valChar] : @"";
            row[colName] = colVal;
          }
          [resultList addObject:row];
        }
        sqlite3_finalize(stmt);
        sqlite3_close(db);
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:resultList];
        [strongSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
      } else {
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
        sqlite3_close(db);
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"Query executed successfully."];
        [strongSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
      }
    } else {
      const char *errMsg = sqlite3_errmsg(db);
      sqlite3_close(db);
      [strongSelf sendErrorResult:[NSString stringWithFormat:@"SQL Prepare Error: %s", errMsg] command:command];
    }
  }];
}

- (void)enqueueRecord:(CDVInvokedUrlCommand *)command {
  NSDictionary *record = [command.arguments objectAtIndex:0];
  
  __weak BackgroundSyncPlugin *weakSelf = self;
  [self.commandDelegate runInBackground:^{
    BackgroundSyncPlugin *strongSelf = weakSelf;
    if (!strongSelf) return;

    sqlite3 *db = [strongSelf openWritableDatabase];
    if (!db) {
      [strongSelf sendErrorResult:@"Failed to open SQLite database." command:command];
      return;
    }

    NSString *recordId = record[@"id"];
    if (!recordId || [recordId isKindOfClass:[NSNull class]] || recordId.length == 0) {
      recordId = [[NSUUID UUID] UUIDString];
    }
    NSString *endpoint = record[@"endpoint"];
    if (!endpoint || [endpoint isKindOfClass:[NSNull class]]) {
      endpoint = @"";
    }
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
    NSString *filePath = record[@"filePath"];
    if (!filePath || [filePath isKindOfClass:[NSNull class]]) {
      filePath = @"";
    }
    NSString *uploadStrategy = record[@"uploadStrategy"];
    if (!uploadStrategy || [uploadStrategy isKindOfClass:[NSNull class]]) {
      uploadStrategy = @"REST_PAYLOAD";
    }

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
  NSArray *ids = [command.arguments objectAtIndex:0];

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
        if (![item isKindOfClass:[NSString class]]) continue;
        NSString *recordId = (NSString *)item;
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
  NSDictionary *record = [command.arguments objectAtIndex:0];
  
  __weak BackgroundSyncPlugin *weakSelf = self;
  [self.commandDelegate runInBackground:^{
    BackgroundSyncPlugin *strongSelf = weakSelf;
    if (!strongSelf) return;

    sqlite3 *db = [strongSelf openWritableDatabase];
    if (!db) {
      [strongSelf sendErrorResult:@"Failed to open SQLite database." command:command];
      return;
    }

    NSString *recordId = record[@"id"];
    if (!recordId || [recordId isKindOfClass:[NSNull class]] || recordId.length == 0) {
      recordId = [[NSUUID UUID] UUIDString];
    }
    NSString *endpoint = record[@"endpoint"];
    if (!endpoint || [endpoint isKindOfClass:[NSNull class]]) {
      endpoint = @"";
    }
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
    NSString *filePath = record[@"filePath"];
    if (!filePath || [filePath isKindOfClass:[NSNull class]]) {
      filePath = @"";
    }
    NSString *downloadStrategy = record[@"downloadStrategy"];
    if (!downloadStrategy || [downloadStrategy isKindOfClass:[NSNull class]]) {
      downloadStrategy = @"REST_PAYLOAD";
    }

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
    NSDictionary *options = [command.arguments objectAtIndex:0];
    if ([options isKindOfClass:[NSDictionary class]]) {
      if (options[@"limit"]) limit = [options[@"limit"] intValue];
      if (options[@"offset"]) offset = [options[@"offset"] intValue];
    }
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
  NSArray *ids = [command.arguments objectAtIndex:0];

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
        if (![item isKindOfClass:[NSString class]]) continue;
        NSString *recordId = (NSString *)item;
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

  if (self.isSyncRunning) {
    LogDebug(@"[BG-SYNC-IOS] Sync already running. Cancelling current and scheduling retry...");
    self.isSyncCancelled = YES;
    __weak BackgroundSyncPlugin *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf enqueueSync:command];
    });
    return;
  }

  self.isSyncCancelled = NO;
  self.isSyncRunning = YES;

  __weak BackgroundSyncPlugin *weakSelf = self;
  UIApplication *application = [UIApplication sharedApplication];
  __block UIBackgroundTaskIdentifier bgTask = [application beginBackgroundTaskWithName:@"BackgroundSyncPluginTask" expirationHandler:^{
      BackgroundSyncPlugin *strongSelf = weakSelf;
      if (strongSelf) {
        if (strongSelf.enableNotifications) {
          NSString *title = strongSelf.notificationTexts[@"failureTitle"] ?: @"Sync Suspended";
          NSString *bodyPattern = strongSelf.notificationTexts[@"failureBody"] ?: @"Sync paused: {error}. Will resume automatically.";
          NSString *body = [bodyPattern stringByReplacingOccurrencesOfString:@"{error}" withString:@"Background execution limit reached"];
          [strongSelf sendLocalNotificationWithTitle:title body:body isSilent:NO];
        }
        [strongSelf broadcastEvent:@"failed" percentage:0 completed:0 total:0 error:@"iOS background execution time expired"];
        strongSelf.isSyncRunning = NO;
      }

      if (bgTask != UIBackgroundTaskInvalid) {
        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
      }
  }];

  // Ack the JS call as soon as the native background task has been scheduled — this
  // mirrors Android, where enqueueSync() resolves the moment WorkManager accepts the
  // task rather than waiting for the whole upload+download cycle to finish. From here
  // on, progress/completion/failure is reported exclusively through the registered
  // progress listener (onStarted/onProgress/onCompleted/onFailed), on both platforms.
  CDVPluginResult *ackResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"Background sync task scheduled successfully."];
  [self.commandDelegate sendPluginResult:ackResult callbackId:command.callbackId];

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      BackgroundSyncPlugin *strongSelf = weakSelf;
      if (!strongSelf) {
        if (bgTask != UIBackgroundTaskInvalid) {
          [application endBackgroundTask:bgTask];
          bgTask = UIBackgroundTaskInvalid;
        }
        return;
      }
      [strongSelf processSyncQueueWithBgTask:bgTask];
  });
}

- (void)processSyncQueueWithBgTask:(UIBackgroundTaskIdentifier)bgTask {
  LogDebug(@"[BG-SYNC-IOS] processSyncQueueWithBgTask execution started.");

  sqlite3 *db = [self openWritableDatabase];
  if (!db) {
    LogDebug(@"[BG-SYNC-IOS] ERROR: Failed to open SQLite database.");
    self.isSyncRunning = NO;
    [self broadcastEvent:@"failed" percentage:0 completed:0 total:0 error:@"Failed to open SQLite database."];
    if (bgTask != UIBackgroundTaskInvalid) {
      [[UIApplication sharedApplication] endBackgroundTask:bgTask];
      bgTask = UIBackgroundTaskInvalid;
    }
    return;
  }

  if (self.enableNotifications) {
    NSString *title = self.notificationTexts[@"progressTitle"] ?: @"Background Sync Active";
    NSString *body = [self.notificationTexts[@"preparingBody"] ?: @"Preparing database synchronization..." copy];
    [self sendLocalNotificationWithTitle:title body:body isSilent:YES];
  }

  NSMutableArray *pendingItems = [NSMutableArray array];
  const char *query = "SELECT Id, Endpoint, FilePath, UploadStrategy FROM sync_queue WHERE LOWER(Status) = 'pending' OR LOWER(Status) = 'failed' ORDER BY Sequence ASC;";
  sqlite3_stmt *stmt;

  if (sqlite3_prepare_v2(db, query, -1, &stmt, NULL) == SQLITE_OK) {
    while (sqlite3_step(stmt) == SQLITE_ROW) {
      const char *idChar = (char *)sqlite3_column_text(stmt, 0);
      const char *endpointChar = (char *)sqlite3_column_text(stmt, 1);
      if (!idChar) {
        LogDebug(@"[BG-SYNC-IOS] Skipping sync_queue row with NULL Id.");
        continue;
      }
      NSString *recordId = [NSString stringWithUTF8String:idChar];
      NSString *endpoint = endpointChar ? [NSString stringWithUTF8String:endpointChar] : @"";

      const char *filePathChar = (char *)sqlite3_column_text(stmt, 2);
      NSString *filePath = filePathChar ? [NSString stringWithUTF8String:filePathChar] : nil;

      const char *strategyChar = (char *)sqlite3_column_text(stmt, 3);
      NSString *uploadStrategy = strategyChar ? [NSString stringWithUTF8String:strategyChar] : @"REST_PAYLOAD";

      [pendingItems addObject:@{
        @"Id" : recordId,
        @"Endpoint" : endpoint,
        @"FilePath" : filePath ?: [NSNull null],
        @"UploadStrategy" : uploadStrategy
      }];
    }
    sqlite3_finalize(stmt);
  } else {
    const char *errMsg = sqlite3_errmsg(db);
    LogDebug(@"[BG-SYNC-IOS] ERROR: Failed to prepare query statement: %s", errMsg);
  }

  NSMutableArray *pendingDownloads = [NSMutableArray array];
  const char *downloadQuery = "SELECT Id, Endpoint, FilePath, DownloadStrategy FROM download_queue WHERE LOWER(Status) = 'pending' OR LOWER(Status) = 'failed' ORDER BY Sequence ASC;";
  sqlite3_stmt *downloadStmt;
  if (sqlite3_prepare_v2(db, downloadQuery, -1, &downloadStmt, NULL) == SQLITE_OK) {
    while (sqlite3_step(downloadStmt) == SQLITE_ROW) {
      const char *idChar = (char *)sqlite3_column_text(downloadStmt, 0);
      const char *endpointChar = (char *)sqlite3_column_text(downloadStmt, 1);
      if (!idChar) {
        LogDebug(@"[BG-SYNC-IOS] Skipping download_queue row with NULL Id.");
        continue;
      }
      NSString *recordId = [NSString stringWithUTF8String:idChar];
      NSString *endpoint = endpointChar ? [NSString stringWithUTF8String:endpointChar] : @"";

      const char *filePathChar = (char *)sqlite3_column_text(downloadStmt, 2);
      NSString *filePath = filePathChar ? [NSString stringWithUTF8String:filePathChar] : nil;

      const char *strategyChar = (char *)sqlite3_column_text(downloadStmt, 3);
      NSString *downloadStrategy = strategyChar ? [NSString stringWithUTF8String:strategyChar] : @"REST_PAYLOAD";

      [pendingDownloads addObject:@{
        @"Id" : recordId,
        @"Endpoint" : endpoint,
        @"FilePath" : filePath ?: [NSNull null],
        @"DownloadStrategy" : downloadStrategy
      }];
    }
    sqlite3_finalize(downloadStmt);
  } else {
    const char *errMsg = sqlite3_errmsg(db);
    LogDebug(@"[BG-SYNC-IOS] ERROR: Failed to prepare download query statement: %s", errMsg);
  }

  // Note: `db` is intentionally kept open for the remainder of this method — reused for
  // per-record payload reads and status writes below — instead of being reopened per record,
  // which was needlessly re-running table-creation/key-derivation work on every open.

  int totalCount = (int)pendingItems.count;
  int totalDownloadCount = (int)pendingDownloads.count;

  if (totalCount == 0 && totalDownloadCount == 0) {
    if (self.enableNotifications) {
      [self sendLocalNotificationWithTitle:self.notificationTexts[@"successTitle"] ?: @"Synchronization Complete"
                                      body:self.notificationTexts[@"successBody"] ?: @"All offline records successfully uploaded."
                                  isSilent:NO];
    }
    [self broadcastEvent:@"completed" percentage:100 completed:0 total:0 error:nil];
    self.isSyncRunning = NO;
    sqlite3_close(db);
    if (bgTask != UIBackgroundTaskInvalid) {
      [[UIApplication sharedApplication] endBackgroundTask:bgTask];
      bgTask = UIBackgroundTaskInvalid;
    }
    return;
  }

  int completedCount = 0;
  BOOL syncAborted = NO;

  if (totalCount > 0) {
    [self broadcastEvent:@"started" percentage:0 completed:0 total:totalCount error:nil];
  for (NSDictionary *item in pendingItems) {
    if (self.isSyncCancelled) {
      [self broadcastEvent:@"failed" percentage:(int)(((float)completedCount / (float)totalCount) * 100) completed:completedCount total:totalCount error:@"Synchronization cancelled by user"];
      syncAborted = YES;
      break;
    }
    NSString *recordId = item[@"Id"];
    NSString *endpoint = item[@"Endpoint"];
    id filePathObj = item[@"FilePath"];
    NSString *filePath = [filePathObj isKindOfClass:[NSNull class]] ? nil : filePathObj;
    NSString *strategy = item[@"UploadStrategy"];

    NSString *payload = @"";
    sqlite3_stmt *payloadStmt;
    const char *payloadQuery = "SELECT Payload FROM sync_queue WHERE Id = ?;";
    if (sqlite3_prepare_v2(db, payloadQuery, -1, &payloadStmt, NULL) == SQLITE_OK) {
      sqlite3_bind_text(payloadStmt, 1, [recordId UTF8String], -1, SQLITE_TRANSIENT);
      if (sqlite3_step(payloadStmt) == SQLITE_ROW) {
        const char *payloadChar = (char *)sqlite3_column_text(payloadStmt, 0);
        if (payloadChar) {
          payload = [NSString stringWithUTF8String:payloadChar];
        }
      }
      sqlite3_finalize(payloadStmt);
    }

    NSString *uploadError = nil;
    if ([strategy caseInsensitiveCompare:@"PRESIGNED_URL"] == NSOrderedSame) {
      uploadError = [self uploadItemViaPresignedUrlWithPayload:payload endpoint:endpoint filePath:filePath];
    } else {
      uploadError = [self uploadItemWithPayload:payload endpoint:endpoint filePath:filePath];
    }
    BOOL success = (uploadError == nil);

    int percentage = (int)(((float)(completedCount + 1) / (float)totalCount) * 100);

    if (success) {
      completedCount++;
      if (self.autoDeleteCompleted) {
        sqlite3_stmt *delStmt;
        if (sqlite3_prepare_v2(db, "DELETE FROM sync_queue WHERE Id = ?;", -1, &delStmt, NULL) == SQLITE_OK) {
          sqlite3_bind_text(delStmt, 1, [recordId UTF8String], -1, SQLITE_TRANSIENT);
          sqlite3_step(delStmt);
          sqlite3_finalize(delStmt);
        }
      } else {
        sqlite3_stmt *updStmt;
        if (sqlite3_prepare_v2(db, "UPDATE sync_queue SET Status = 'completed', Error = NULL WHERE Id = ?;", -1, &updStmt, NULL) == SQLITE_OK) {
          sqlite3_bind_text(updStmt, 1, [recordId UTF8String], -1, SQLITE_TRANSIENT);
          sqlite3_step(updStmt);
          sqlite3_finalize(updStmt);
        }
      }

      [self broadcastEvent:@"progress" percentage:percentage completed:completedCount total:totalCount error:nil];

      if (self.enableNotifications) {
        NSString *title = self.notificationTexts[@"progressTitle"] ?: @"Syncing in Background";
        NSString *bodyPattern = self.notificationTexts[@"progressBody"] ?: @"Synchronizing: {current} of {total} records ({percentage}%)";
        NSString *body = [bodyPattern stringByReplacingOccurrencesOfString:@"{current}" withString:[NSString stringWithFormat:@"%d", completedCount]];
        body = [body stringByReplacingOccurrencesOfString:@"{total}" withString:[NSString stringWithFormat:@"%d", totalCount]];
        body = [body stringByReplacingOccurrencesOfString:@"{percentage}" withString:[NSString stringWithFormat:@"%d", percentage]];
        [self sendLocalNotificationWithTitle:title body:body isSilent:YES];
      }
    } else {
      NSString *errorMessage = uploadError ?: @"Network upload error";
      sqlite3_stmt *updStmt;
      if (sqlite3_prepare_v2(db, "UPDATE sync_queue SET Status = 'failed', Error = ? WHERE Id = ?;", -1, &updStmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(updStmt, 1, [errorMessage UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(updStmt, 2, [recordId UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_step(updStmt);
        sqlite3_finalize(updStmt);
      }

      if (self.enableNotifications) {
        NSString *title = self.notificationTexts[@"failureTitle"] ?: @"Sync Suspended";
        NSString *bodyPattern = self.notificationTexts[@"failureBody"] ?: @"Sync paused: {error}. Will resume automatically.";
        NSString *body = [bodyPattern stringByReplacingOccurrencesOfString:@"{error}" withString:errorMessage];
        [self sendLocalNotificationWithTitle:title body:body isSilent:NO];
      }
      [self broadcastEvent:@"failed" percentage:percentage completed:completedCount total:totalCount error:errorMessage];

      // Only a genuine connectivity failure (the request never reached the server) should
      // abort the whole run. An HTTP error response means the server was reached and
      // rejected this specific record — it's already marked "failed" above; let the loop
      // continue so unrelated queued items still get attempted.
      BOOL isConnectivityFailure = [errorMessage hasPrefix:@"Upload Exception:"] ||
          [errorMessage hasPrefix:@"Handshake exception:"] ||
          [errorMessage hasPrefix:@"Cloud upload Exception:"];
      if (isConnectivityFailure) {
        syncAborted = YES;
      }
    }

    if (syncAborted) {
      break;
    }
  }

  }

  if (syncAborted) {
    self.isSyncRunning = NO;
    sqlite3_close(db);
    if (bgTask != UIBackgroundTaskInvalid) {
      [[UIApplication sharedApplication] endBackgroundTask:bgTask];
      bgTask = UIBackgroundTaskInvalid;
    }
    return;
  }

  // ----------------- DOWNLOAD PROCESS -----------------
  int completedDownloadCount = 0;
  BOOL downloadAborted = NO;

  if (totalDownloadCount > 0) {
    [self broadcastEvent:@"started_download" percentage:0 completed:0 total:totalDownloadCount error:nil];

    for (NSDictionary *item in pendingDownloads) {
      if (self.isSyncCancelled) {
        [self broadcastEvent:@"failed" percentage:(int)(((float)completedDownloadCount / (float)totalDownloadCount) * 100) completed:completedCount + completedDownloadCount total:totalCount + totalDownloadCount error:@"Synchronization cancelled by user"];
        downloadAborted = YES;
        break;
      }

      NSString *recordId = item[@"Id"];
      NSString *endpoint = item[@"Endpoint"];
      id filePathObj = item[@"FilePath"];
      NSString *filePath = [filePathObj isKindOfClass:[NSNull class]] ? nil : filePathObj;
      NSString *strategy = item[@"DownloadStrategy"];

      NSString *payload = @"";
      sqlite3_stmt *payloadStmt;
      const char *payloadQuery = "SELECT Payload FROM download_queue WHERE Id = ?;";
      if (sqlite3_prepare_v2(db, payloadQuery, -1, &payloadStmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(payloadStmt, 1, [recordId UTF8String], -1, SQLITE_TRANSIENT);
        if (sqlite3_step(payloadStmt) == SQLITE_ROW) {
          const char *payloadChar = (char *)sqlite3_column_text(payloadStmt, 0);
          if (payloadChar) {
            payload = [NSString stringWithUTF8String:payloadChar];
          }
        }
        sqlite3_finalize(payloadStmt);
      }

      int percentage = (int)(((float)(completedDownloadCount + 1) / (float)totalDownloadCount) * 100);

      [self broadcastEvent:@"progress_download" percentage:percentage completed:completedDownloadCount + 1 total:totalDownloadCount error:nil];

      if (self.enableNotifications) {
        NSString *title = self.notificationTexts[@"downloadProgressTitle"] ?: @"Background Download Active";
        NSString *bodyPattern = self.notificationTexts[@"downloadProgressBody"] ?: @"Downloading: {current} of {total} files ({percentage}%)";
        NSString *body = [bodyPattern stringByReplacingOccurrencesOfString:@"{current}" withString:[NSString stringWithFormat:@"%d", completedDownloadCount + 1]];
        body = [body stringByReplacingOccurrencesOfString:@"{total}" withString:[NSString stringWithFormat:@"%d", totalDownloadCount]];
        body = [body stringByReplacingOccurrencesOfString:@"{percentage}" withString:[NSString stringWithFormat:@"%d", percentage]];
        [self sendLocalNotificationWithTitle:title body:body isSilent:YES];
      }

      NSString *downloadError = nil;
      NSString *responseData = nil;

      if ([strategy caseInsensitiveCompare:@"BINARY_FILE"] == NSOrderedSame) {
        downloadError = [self performBinaryFileDownloadWithUrl:endpoint filePath:filePath];
      } else {
        downloadError = [self performDownloadWithEndpoint:endpoint payload:payload responseData:&responseData];
      }

      if (downloadError == NULL) {
        completedDownloadCount++;
        sqlite3_stmt *updStmt;
        const char *updateSQL = "UPDATE download_queue SET Status = 'completed', ResponseData = ?, Error = NULL WHERE Id = ?;";
        if (sqlite3_prepare_v2(db, updateSQL, -1, &updStmt, NULL) == SQLITE_OK) {
          sqlite3_bind_text(updStmt, 1, responseData ? [responseData UTF8String] : "", -1, SQLITE_TRANSIENT);
          sqlite3_bind_text(updStmt, 2, [recordId UTF8String], -1, SQLITE_TRANSIENT);
          sqlite3_step(updStmt);
          sqlite3_finalize(updStmt);
        }
      } else {
        sqlite3_stmt *updStmt;
        const char *updateSQL = "UPDATE download_queue SET Status = 'failed', Error = ? WHERE Id = ?;";
        if (sqlite3_prepare_v2(db, updateSQL, -1, &updStmt, NULL) == SQLITE_OK) {
          sqlite3_bind_text(updStmt, 1, [downloadError UTF8String], -1, SQLITE_TRANSIENT);
          sqlite3_bind_text(updStmt, 2, [recordId UTF8String], -1, SQLITE_TRANSIENT);
          sqlite3_step(updStmt);
          sqlite3_finalize(updStmt);
        }

        if (self.enableNotifications) {
          NSString *title = self.notificationTexts[@"downloadFailureTitle"] ?: @"Download Suspended";
          NSString *bodyPattern = self.notificationTexts[@"downloadFailureBody"] ?: @"Download failed: {error}. Will retry automatically.";
          NSString *body = [bodyPattern stringByReplacingOccurrencesOfString:@"{error}" withString:downloadError];
          [self sendLocalNotificationWithTitle:title body:body isSilent:NO];
        }
        [self broadcastEvent:@"failed_download" percentage:percentage completed:completedDownloadCount total:totalDownloadCount error:downloadError];

        // Only a genuine connectivity failure (the request never reached the server) should
        // abort the whole run. An HTTP error response means the server was reached and
        // rejected this specific record — it's already marked "failed" above; let the loop
        // continue so unrelated queued items still get attempted.
        BOOL isConnectivityFailure = [downloadError hasPrefix:@"Download Exception:"];
        if (isConnectivityFailure) {
          downloadAborted = YES;
        }
      }

      if (downloadAborted) {
        break;
      }
    }
  }

  if (downloadAborted) {
    self.isSyncRunning = NO;
    sqlite3_close(db);
    if (bgTask != UIBackgroundTaskInvalid) {
      [[UIApplication sharedApplication] endBackgroundTask:bgTask];
      bgTask = UIBackgroundTaskInvalid;
    }
    return;
  }

  if (self.enableNotifications) {
    NSString *title = self.notificationTexts[@"successTitle"] ?: @"Sync Complete";
    NSString *bodyPattern = self.notificationTexts[@"successBody"] ?: @"Successfully synchronized {current} of {total} records.";
    NSString *body = [bodyPattern stringByReplacingOccurrencesOfString:@"{current}" withString:[NSString stringWithFormat:@"%d", completedCount + completedDownloadCount]];
    body = [body stringByReplacingOccurrencesOfString:@"{total}" withString:[NSString stringWithFormat:@"%d", totalCount + totalDownloadCount]];
    [self sendLocalNotificationWithTitle:title body:body isSilent:NO];
  }

  [self broadcastEvent:@"completed" percentage:100 completed:completedCount + completedDownloadCount total:totalCount + totalDownloadCount error:nil];

  self.isSyncRunning = NO;
  sqlite3_close(db);

  if (bgTask != UIBackgroundTaskInvalid) {
    [[UIApplication sharedApplication] endBackgroundTask:bgTask];
    bgTask = UIBackgroundTaskInvalid;
  }
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
