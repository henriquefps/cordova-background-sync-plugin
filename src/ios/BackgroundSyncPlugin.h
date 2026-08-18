#import <Cordova/CDVPlugin.h>
#import <sqlite3.h>

int sqlite3_key(sqlite3 *db, const void *zKey, int nKey);

@interface BackgroundSyncPlugin : CDVPlugin

@property (nonatomic, strong) NSString *serverUrl;
@property (nonatomic, strong) NSString *queueTableName;
@property (nonatomic, strong) NSString *progressCallbackId;
@property (nonatomic, assign) BOOL enableNotifications;
@property (nonatomic, assign) BOOL autoDeleteCompleted;
@property (nonatomic, strong) NSDictionary *headers;
@property (nonatomic, strong) NSDictionary *notificationTexts;
@property (nonatomic, assign) BOOL isSyncCancelled;
@property (nonatomic, assign) BOOL isSyncRunning;
@property (nonatomic, assign) BOOL showDebugLogs;
@property (nonatomic, assign) BOOL encryptDatabase;

- (void)initialize:(CDVInvokedUrlCommand*)command;
- (void)enqueueSync:(CDVInvokedUrlCommand*)command;
- (void)cancelSync:(CDVInvokedUrlCommand*)command;
- (void)registerProgressListener:(CDVInvokedUrlCommand*)command;
- (void)executeRawQuery:(CDVInvokedUrlCommand*)command;
- (void)requestNotificationsPermission:(CDVInvokedUrlCommand*)command;

- (void)enqueueRecord:(CDVInvokedUrlCommand*)command;
- (void)getQueuedRecords:(CDVInvokedUrlCommand*)command;
- (void)getSyncedRecords:(CDVInvokedUrlCommand*)command;
- (void)removeRecords:(CDVInvokedUrlCommand*)command;
- (void)clearQueue:(CDVInvokedUrlCommand*)command;
- (void)enqueueDownload:(CDVInvokedUrlCommand*)command;
- (void)getQueuedDownloads:(CDVInvokedUrlCommand*)command;
- (void)getCompletedDownloads:(CDVInvokedUrlCommand*)command;
- (void)removeDownloads:(CDVInvokedUrlCommand*)command;
- (void)clearDownloadQueue:(CDVInvokedUrlCommand*)command;
- (void)openDatabaseInspector:(CDVInvokedUrlCommand*)command;

- (void)broadcastEvent:(NSString *)event percentage:(int)percentage completed:(int)completed total:(int)total error:(NSString *)error;

// Exposed so DatabaseInspectorViewController can reuse the same SQLCipher key-derivation
// and connection logic as the rest of the plugin, instead of duplicating it.
- (sqlite3 *)openWritableDatabase;

@end
