#import "DatabaseInspectorViewController.h"
#import <sqlite3.h>

@interface DatabaseInspectorViewController ()
@property (nonatomic, strong) WKWebView *webView;
+ (NSURL *)inspectorHtmlUrl;
@end

@implementation DatabaseInspectorViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Database Inspector";
  if (@available(iOS 13.0, *)) {
    self.view.backgroundColor = [UIColor systemBackgroundColor];
  } else {
    self.view.backgroundColor = [UIColor whiteColor];
  }

  self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemDone
      target:self
      action:@selector(closeTapped)];

  WKUserContentController *contentController = [[WKUserContentController alloc] init];
  [contentController addScriptMessageHandler:self name:@"inspectorBridge"];

  WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
  config.userContentController = contentController;

  self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
  self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:self.webView];

  NSURL *htmlUrl = [[self class] inspectorHtmlUrl];
  if (htmlUrl) {
    [self.webView loadFileURL:htmlUrl allowingReadAccessToURL:[htmlUrl URLByDeletingLastPathComponent]];
  }
}

/**
 * Locates the bundled inspector.html across both supported install mechanisms:
 * - Plain Cordova CLI / CocoaPods: <resource-file> copies it directly into the main app bundle.
 * - Capacitor (Swift Package Manager, the default since Capacitor's Cordova-compat layer
 *   generates a Package.swift for this plugin): resources are packaged into a dedicated
 *   "<PackageName>_<TargetName>.bundle" inside the main bundle, per SwiftPM convention.
 */
+ (NSURL *)inspectorHtmlUrl {
  NSURL *directUrl = [[NSBundle mainBundle] URLForResource:@"inspector" withExtension:@"html"];
  if (directUrl) return directUrl;

  NSURL *spmBundleUrl = [[NSBundle mainBundle] URLForResource:@"CordovaPluginLocalstorageBackgroundsync_CordovaPluginLocalstorageBackgroundsync" withExtension:@"bundle"];
  if (spmBundleUrl) {
    NSBundle *spmBundle = [NSBundle bundleWithURL:spmBundleUrl];
    NSURL *bundledUrl = [spmBundle URLForResource:@"inspector" withExtension:@"html"];
    if (bundledUrl) return bundledUrl;
  }

  return nil;
}

- (void)dealloc {
  [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"inspectorBridge"];
}

- (void)closeTapped {
  [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - WKScriptMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController
       didReceiveScriptMessage:(WKScriptMessage *)message {
  NSDictionary *body = message.body;
  if (![body isKindOfClass:[NSDictionary class]]) return;

  NSNumber *callId = body[@"callId"];
  NSString *action = body[@"action"];
  NSDictionary *args = [body[@"args"] isKindOfClass:[NSDictionary class]] ? body[@"args"] : @{};

  if ([action isEqualToString:@"close"]) {
    [self closeTapped];
    return;
  }

  __weak DatabaseInspectorViewController *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    DatabaseInspectorViewController *strongSelf = weakSelf;
    if (!strongSelf) return;

    NSString *resultJson = [strongSelf handleAction:action args:args];

    dispatch_async(dispatch_get_main_queue(), ^{
      NSData *jsonData = [NSJSONSerialization dataWithJSONObject:@[resultJson ?: @"null"] options:0 error:nil];
      NSString *arrayLiteral = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
      // arrayLiteral is like ["...escaped json string..."] — strip the wrapping brackets to get
      // a properly-escaped JS string literal for the raw JSON payload.
      NSString *escaped = [arrayLiteral substringWithRange:NSMakeRange(1, arrayLiteral.length - 2)];
      NSString *js = [NSString stringWithFormat:@"window.__inspectorResolve(%@, %@)", callId, escaped];
      [strongSelf.webView evaluateJavaScript:js completionHandler:nil];
    });
  });
}

#pragma mark - Action handling

- (NSString *)handleAction:(NSString *)action args:(NSDictionary *)args {
  if ([action isEqualToString:@"getSyncQueue"]) {
    return [self queryTableAsJson:@"sync_queue"];
  } else if ([action isEqualToString:@"getDownloadQueue"]) {
    return [self queryTableAsJson:@"download_queue"];
  } else if ([action isEqualToString:@"getSyncRecordDetail"]) {
    return [self recordDetailFromTable:@"sync_queue" recordId:args[@"id"]];
  } else if ([action isEqualToString:@"getDownloadRecordDetail"]) {
    return [self recordDetailFromTable:@"download_queue" recordId:args[@"id"]];
  } else if ([action isEqualToString:@"deleteSyncRecord"]) {
    return [self deleteRecordFromTable:@"sync_queue" recordId:args[@"id"]];
  } else if ([action isEqualToString:@"deleteDownloadRecord"]) {
    return [self deleteRecordFromTable:@"download_queue" recordId:args[@"id"]];
  } else if ([action isEqualToString:@"retrySyncRecord"]) {
    return [self retryRecordInTable:@"sync_queue" recordId:args[@"id"]];
  } else if ([action isEqualToString:@"retryDownloadRecord"]) {
    return [self retryRecordInTable:@"download_queue" recordId:args[@"id"]];
  } else if ([action isEqualToString:@"getConfig"]) {
    return [self getConfig];
  } else if ([action isEqualToString:@"exportAll"]) {
    return [self exportAll];
  }
  return @"{\"error\":\"Unknown action\"}";
}

#pragma mark - Truncation (list/export views only — detail fetch is always untruncated)

/**
 * Columns that can legitimately hold large blobs of text (a base64 payload, a raw HTTP error
 * response body/page) — the only ones truncated for list/export views, so short columns are
 * never mangled even if something unexpectedly long ends up in them.
 */
- (NSSet<NSString *> *)truncateColumns {
  return [NSSet setWithObjects:@"Payload", @"Error", @"ResponseData", nil];
}

- (NSString *)truncateForDisplay:(NSString *)value {
  static const NSInteger threshold = 1000;
  static const NSInteger head = 400;
  static const NSInteger tail = 200;
  if (value.length <= threshold) return value;
  NSInteger omitted = value.length - head - tail;
  NSString *headStr = [value substringToIndex:head];
  NSString *tailStr = [value substringFromIndex:(value.length - tail)];
  return [NSString stringWithFormat:@"%@\n...<TRUNCATED: %ld of %lu chars omitted — use \"View full\" to see everything>...\n%@",
          headStr, (long)omitted, (unsigned long)value.length, tailStr];
}

- (NSArray *)queryTableRows:(sqlite3 *)db table:(NSString *)table truncate:(BOOL)truncate {
  NSString *sql = [NSString stringWithFormat:@"SELECT * FROM %@ ORDER BY Sequence DESC;", table];
  NSMutableArray *rows = [NSMutableArray array];
  NSSet<NSString *> *truncateColumns = [self truncateColumns];
  sqlite3_stmt *stmt;
  if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &stmt, NULL) == SQLITE_OK) {
    int columnCount = sqlite3_column_count(stmt);
    while (sqlite3_step(stmt) == SQLITE_ROW) {
      NSMutableDictionary *row = [NSMutableDictionary dictionary];
      for (int i = 0; i < columnCount; i++) {
        NSString *colName = [NSString stringWithUTF8String:sqlite3_column_name(stmt, i)];
        const char *valChar = (char *)sqlite3_column_text(stmt, i);
        NSString *value = valChar ? [NSString stringWithUTF8String:valChar] : @"";
        if (truncate && [truncateColumns containsObject:colName]) {
          value = [self truncateForDisplay:value];
        }
        row[colName] = value;
      }
      [rows addObject:row];
    }
    sqlite3_finalize(stmt);
  }
  return rows;
}

- (NSString *)queryTableAsJson:(NSString *)table {
  sqlite3 *db = [self.plugin openWritableDatabase];
  if (!db) return @"{\"error\":\"Failed to open database\"}";

  NSArray *rows = [self queryTableRows:db table:table truncate:YES];
  sqlite3_close(db);

  NSData *data = [NSJSONSerialization dataWithJSONObject:rows options:0 error:nil];
  return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"[]";
}

/** Untruncated single-row fetch, for the "View full" button on a truncated cell. */
- (NSString *)recordDetailFromTable:(NSString *)table recordId:(NSString *)recordId {
  if (![recordId isKindOfClass:[NSString class]] || recordId.length == 0) {
    return @"{\"error\":\"Missing id\"}";
  }
  sqlite3 *db = [self.plugin openWritableDatabase];
  if (!db) return @"{\"error\":\"Failed to open database\"}";

  NSString *sql = [NSString stringWithFormat:@"SELECT * FROM %@ WHERE Id = ? LIMIT 1;", table];
  NSMutableDictionary *row = nil;
  sqlite3_stmt *stmt;
  if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &stmt, NULL) == SQLITE_OK) {
    sqlite3_bind_text(stmt, 1, [recordId UTF8String], -1, SQLITE_TRANSIENT);
    if (sqlite3_step(stmt) == SQLITE_ROW) {
      row = [NSMutableDictionary dictionary];
      int columnCount = sqlite3_column_count(stmt);
      for (int i = 0; i < columnCount; i++) {
        NSString *colName = [NSString stringWithUTF8String:sqlite3_column_name(stmt, i)];
        const char *valChar = (char *)sqlite3_column_text(stmt, i);
        row[colName] = valChar ? [NSString stringWithUTF8String:valChar] : @"";
      }
    }
    sqlite3_finalize(stmt);
  }
  sqlite3_close(db);

  if (!row) return @"{\"error\":\"Record not found\"}";
  NSData *data = [NSJSONSerialization dataWithJSONObject:row options:0 error:nil];
  return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{\"error\":\"Failed to serialize record\"}";
}

/**
 * Resets a stuck record back to `pending` and clears its last error, so the next `sync()` run
 * picks it up again (SyncWorker/upload loop already selects WHERE Status IN ('pending',
 * 'failed'), but this lets you force just ONE record back to a clean state to retry in
 * isolation, without waiting for/depending on whatever else is queued alongside it).
 */
- (NSString *)retryRecordInTable:(NSString *)table recordId:(NSString *)recordId {
  if (![recordId isKindOfClass:[NSString class]] || recordId.length == 0) {
    return @"{\"error\":\"Missing id\"}";
  }
  sqlite3 *db = [self.plugin openWritableDatabase];
  if (!db) return @"{\"error\":\"Failed to open database\"}";

  NSString *sql = [NSString stringWithFormat:@"UPDATE %@ SET Status = 'pending', Error = NULL WHERE Id = ?;", table];
  sqlite3_stmt *stmt;
  BOOL success = NO;
  if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &stmt, NULL) == SQLITE_OK) {
    sqlite3_bind_text(stmt, 1, [recordId UTF8String], -1, SQLITE_TRANSIENT);
    success = sqlite3_step(stmt) == SQLITE_DONE;
    sqlite3_finalize(stmt);
  }
  BOOL found = success && sqlite3_changes(db) > 0;
  sqlite3_close(db);
  return found ? @"{\"success\":true}" : @"{\"error\":\"Record not found\"}";
}

- (NSString *)maskSecret:(NSString *)value {
  if (value.length <= 8) return @"****";
  NSString *head = [value substringToIndex:4];
  NSString *tail = [value substringFromIndex:(value.length - 4)];
  return [NSString stringWithFormat:@"%@…%@", head, tail];
}

/**
 * Current connection config — meant to catch exactly the class of bug that motivated this: a
 * misconfigured `ServerUrl`/`Endpoint` that only shows up as a cryptic native HTTP error deep
 * in a queue row, instead of being visible up front.
 */
- (NSString *)getConfig {
  NSMutableDictionary *maskedHeaders = [NSMutableDictionary dictionary];
  NSDictionary *headers = self.plugin.headers;
  if ([headers isKindOfClass:[NSDictionary class]]) {
    for (NSString *key in headers) {
      id value = headers[key];
      NSString *strValue = [value isKindOfClass:[NSString class]] ? value : [value description];
      maskedHeaders[key] = [self maskSecret:strValue ?: @""];
    }
  }
  NSDictionary *config = @{
    @"serverUrl": self.plugin.serverUrl ?: @"",
    @"headers": maskedHeaders,
    @"encryptDatabase": @(self.plugin.encryptDatabase)
  };
  NSData *data = [NSJSONSerialization dataWithJSONObject:config options:0 error:nil];
  return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{\"error\":\"Failed to serialize config\"}";
}

- (NSString *)deleteRecordFromTable:(NSString *)table recordId:(NSString *)recordId {
  if (![recordId isKindOfClass:[NSString class]] || recordId.length == 0) {
    return @"{\"error\":\"Missing id\"}";
  }
  sqlite3 *db = [self.plugin openWritableDatabase];
  if (!db) return @"{\"error\":\"Failed to open database\"}";

  NSString *sql = [NSString stringWithFormat:@"DELETE FROM %@ WHERE Id = ?;", table];
  sqlite3_stmt *stmt;
  BOOL success = NO;
  if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &stmt, NULL) == SQLITE_OK) {
    sqlite3_bind_text(stmt, 1, [recordId UTF8String], -1, SQLITE_TRANSIENT);
    success = sqlite3_step(stmt) == SQLITE_DONE;
    sqlite3_finalize(stmt);
  }
  sqlite3_close(db);
  return success ? @"{\"success\":true}" : @"{\"error\":\"Delete failed\"}";
}

- (NSString *)exportAll {
  sqlite3 *db = [self.plugin openWritableDatabase];
  if (!db) return @"{\"error\":\"Failed to open database\"}";

  NSArray *syncQueue = [self queryTableRows:db table:@"sync_queue" truncate:YES];
  NSArray *downloadQueue = [self queryTableRows:db table:@"download_queue" truncate:YES];
  sqlite3_close(db);

  NSDictionary *export = @{@"syncQueue": syncQueue, @"downloadQueue": downloadQueue};
  NSData *data = [NSJSONSerialization dataWithJSONObject:export options:NSJSONWritingPrettyPrinted error:nil];
  if (!data) return @"{\"error\":\"Failed to serialize export\"}";

  NSString *fileName = [NSString stringWithFormat:@"bg_sync_export_%.0f.json", [[NSDate date] timeIntervalSince1970]];
  NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
  [data writeToFile:tempPath atomically:YES];

  __weak DatabaseInspectorViewController *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    DatabaseInspectorViewController *strongSelf = weakSelf;
    if (!strongSelf) return;
    NSURL *fileUrl = [NSURL fileURLWithPath:tempPath];
    UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[fileUrl] applicationActivities:nil];
    activityVC.popoverPresentationController.sourceView = strongSelf.webView;
    [strongSelf presentViewController:activityVC animated:YES completion:nil];
  });

  return @"{\"success\":true}";
}

@end
