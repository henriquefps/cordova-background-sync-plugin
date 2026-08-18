#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import "BackgroundSyncPlugin.h"

/**
 * Standalone recovery/inspection screen for the plugin's private SQLite queue database.
 * Presented via the JS `openDatabaseInspector()` action; not part of the normal sync flow.
 */
@interface DatabaseInspectorViewController : UIViewController <WKScriptMessageHandler>

@property (nonatomic, weak) BackgroundSyncPlugin *plugin;

@end
