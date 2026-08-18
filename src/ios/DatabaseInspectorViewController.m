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
  } else if ([action isEqualToString:@"deleteSyncRecord"]) {
    return [self deleteRecordFromTable:@"sync_queue" recordId:args[@"id"]];
  } else if ([action isEqualToString:@"deleteDownloadRecord"]) {
    return [self deleteRecordFromTable:@"download_queue" recordId:args[@"id"]];
  } else if ([action isEqualToString:@"exportAll"]) {
    return [self exportAll];
  }
  return @"{\"error\":\"Unknown action\"}";
}

- (NSArray *)queryTableRows:(sqlite3 *)db table:(NSString *)table {
  NSString *sql = [NSString stringWithFormat:@"SELECT * FROM %@ ORDER BY Sequence DESC;", table];
  NSMutableArray *rows = [NSMutableArray array];
  sqlite3_stmt *stmt;
  if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &stmt, NULL) == SQLITE_OK) {
    int columnCount = sqlite3_column_count(stmt);
    while (sqlite3_step(stmt) == SQLITE_ROW) {
      NSMutableDictionary *row = [NSMutableDictionary dictionary];
      for (int i = 0; i < columnCount; i++) {
        NSString *colName = [NSString stringWithUTF8String:sqlite3_column_name(stmt, i)];
        const char *valChar = (char *)sqlite3_column_text(stmt, i);
        row[colName] = valChar ? [NSString stringWithUTF8String:valChar] : @"";
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

  NSArray *rows = [self queryTableRows:db table:table];
  sqlite3_close(db);

  NSData *data = [NSJSONSerialization dataWithJSONObject:rows options:0 error:nil];
  return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"[]";
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

  NSArray *syncQueue = [self queryTableRows:db table:@"sync_queue"];
  NSArray *downloadQueue = [self queryTableRows:db table:@"download_queue"];
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
