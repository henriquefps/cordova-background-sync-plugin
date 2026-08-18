var exec = require('cordova/exec');

var BackgroundSyncPlugin = {
    progressCallback: null,
    isInitialized: false,

    initialize: function(options, success, error) {
        options = options || {};
        options.serverUrl = options.serverUrl || '';
        options.queueTableName = options.queueTableName || '';
        options.syncOnlyOnWifi = options.syncOnlyOnWifi !== undefined ? options.syncOnlyOnWifi : true;
        options.syncOnlyWhenCharging = options.syncOnlyWhenCharging !== undefined ? options.syncOnlyWhenCharging : false;
        options.enableNotifications = options.enableNotifications !== undefined ? options.enableNotifications : true;
        options.autoDeleteCompleted = options.autoDeleteCompleted !== undefined ? options.autoDeleteCompleted : false;
        options.headers = options.headers || {};
        options.notificationTexts = options.notificationTexts || {};
        options.showDebugLogs = options.showDebugLogs !== undefined ? options.showDebugLogs : false;
        options.encryptDatabase = options.encryptDatabase !== undefined ? options.encryptDatabase : false;

        var self = this;
        self.showDebugLogs = options.showDebugLogs;
        var originalSuccess = success;
        var newSuccess = function(res) {
            self.isInitialized = true;
            if (originalSuccess) originalSuccess(res);
        };

        exec(newSuccess, error, 'BackgroundSyncPlugin', 'initialize', [options]);
    },

    enqueueSync: function(success, error) {
        exec(success, error, 'BackgroundSyncPlugin', 'enqueueSync', []);
    },

    sync: function(success, error) {
        exec(success, error, 'BackgroundSyncPlugin', 'enqueueSync', []);
    },

    cancelSync: function(success, error) {
        exec(success, error, 'BackgroundSyncPlugin', 'cancelSync', []);
    },

    requestNotificationsPermission: function(success, error) {
        exec(success, error, 'BackgroundSyncPlugin', 'requestNotificationsPermission', []);
    },

    executeRawQuery: function(query, args, success, error) {
        exec(success, error, 'BackgroundSyncPlugin', 'executeRawQuery', [query, args || []]);
    },

    enqueueRecord: function(record, success, error) {
        exec(success, error, 'BackgroundSyncPlugin', 'enqueueRecord', [record || {}]);
    },

    getQueuedRecords: function(success, error) {
        exec(success, error, 'BackgroundSyncPlugin', 'getQueuedRecords', []);
    },

    getSyncedRecords: function(success, error) {
        exec(success, error, 'BackgroundSyncPlugin', 'getSyncedRecords', []);
    },

    removeRecords: function(ids, success, error) {
        exec(success, error, 'BackgroundSyncPlugin', 'removeRecords', [ids || []]);
    },

    clearQueue: function(success, error) {
        exec(success, error, 'BackgroundSyncPlugin', 'clearQueue', []);
    },

    enqueueDownload: function(record, success, error) {
        exec(success, error, 'BackgroundSyncPlugin', 'enqueueDownload', [record || {}]);
    },

    getQueuedDownloads: function(success, error) {
        exec(success, error, 'BackgroundSyncPlugin', 'getQueuedDownloads', []);
    },

    getCompletedDownloads: function(options, success, error) {
        if (typeof options === 'function') {
            error = success;
            success = options;
            options = {};
        }
        exec(success, error, 'BackgroundSyncPlugin', 'getCompletedDownloads', [options || {}]);
    },

    removeDownloads: function(ids, success, error) {
        exec(success, error, 'BackgroundSyncPlugin', 'removeDownloads', [ids || []]);
    },

    clearDownloadQueue: function(success, error) {
        exec(success, error, 'BackgroundSyncPlugin', 'clearDownloadQueue', []);
    },

    openDatabaseInspector: function(success, error) {
        exec(success, error, 'BackgroundSyncPlugin', 'openDatabaseInspector', []);
    },

    onProgress: function(callback) {
        this.progressCallback = callback;
        // Register internally to map events to the old onProgress callback
        this.registerListeners({
            onProgress: callback
        });
    },

    registerListeners: function(listeners) {
        this.listeners = listeners || {};
        var self = this;
        
        exec(
            function(eventData) {
                if (eventData && eventData.event) {
                    var camelCased = eventData.event.replace(/_([a-z])/g, function(_, c) {
                        return c.toUpperCase();
                    });
                    var eventName = 'on' + camelCased.charAt(0).toUpperCase() + camelCased.slice(1);
                    if (self.listeners[eventName]) {
                        self.listeners[eventName](eventData);
                    }
                    // For backward compatibility, if progressCallback is registered and it's a progress event
                    if (eventData.event === 'progress' && self.progressCallback) {
                        self.progressCallback(eventData);
                    }
                }
            },
            function(err) {
                console.error("Progress listener registration error:", err);
            },
            'BackgroundSyncPlugin',
            'registerProgressListener',
            []
        );
    }
};

// Automatically trigger sync when the app is active and connection is restored
if (typeof window !== 'undefined') {
    window.addEventListener('online', function() {
        if (BackgroundSyncPlugin.isInitialized) {
            if (BackgroundSyncPlugin.showDebugLogs) {
                console.log("[BackgroundSyncPlugin] Connection restored. Retrying synchronization automatically...");
            }
            BackgroundSyncPlugin.enqueueSync(
                function(success) {
                    if (BackgroundSyncPlugin.showDebugLogs) {
                        console.log("[BackgroundSyncPlugin] Auto-retry queued: " + success);
                    }
                },
                function(err) {
                    if (BackgroundSyncPlugin.showDebugLogs) {
                        console.error("[BackgroundSyncPlugin] Auto-retry queuing failed: " + err);
                    }
                }
            );
        }
    });
}

module.exports = BackgroundSyncPlugin;
