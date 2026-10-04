// Thin promise wrapper around the Background Sync plugin
// (cordova.plugins.BackgroundSyncPlugin). Every number the UI shows
// comes from these calls or from the plugin's listener events.
import { Filesystem, Directory } from '@capacitor/filesystem';

export const SERVER_URL = import.meta.env.VITE_SERVER_URL || 'http://10.0.2.2:8791';
// Per-device key checked by the local demo backoffice. Not a real credential.
export const DEVICE_KEY = import.meta.env.VITE_DEVICE_KEY || 'demo-device-key';
export const PHOTO_ENDPOINT = 'api/v1/audits/photos';

const engine = () => window.cordova?.plugins?.BackgroundSyncPlugin;
export const isNative = () => !!engine();

const call = (method, ...args) =>
  new Promise((resolve, reject) => {
    const e = engine();
    if (!e) return reject(new Error('Background Sync plugin not available'));
    e[method](...args, resolve, reject);
  });

export function whenDeviceReady() {
  return new Promise((resolve) => {
    if (window.cordova?.plugins?.BackgroundSyncPlugin) return resolve(true);
    document.addEventListener('deviceready', () => resolve(true), { once: true });
    setTimeout(() => resolve(!!engine()), 4000);
  });
}

// Test builds only: tests/ios can persist extra initialize options (for
// example encryptDatabase) so they survive an app relaunch.
function testOverrides() {
  if (import.meta.env.VITE_TEST_CONTROL !== '1') return {};
  try { return JSON.parse(localStorage.getItem('fieldbook.initOverrides') || '{}'); } catch { return {}; }
}

export function initialize() {
  return call('initialize', {
    serverUrl: SERVER_URL,
    syncOnlyOnWifi: false,
    syncOnlyWhenCharging: false,
    enableNotifications: true,
    autoDeleteCompleted: false,
    showDebugLogs: true,
    headers: { 'X-Api-Key': DEVICE_KEY },
    notificationTexts: {
      progressTitle: 'Syncing audit photos',
      progressBody: 'Photo {current} of {total} ({percentage}%)',
      preparingBody: 'Preparing the photo queue',
      successTitle: 'Audit synced',
      successBody: 'All photos are on the server.',
      failureTitle: 'Sync paused',
      failureBody: 'Upload interrupted. The queue resumes on its own when the device is back online.',
    },
    ...testOverrides(),
  });
}

export const requestNotifications = () => call('requestNotificationsPermission').catch(() => null);
export const enqueueRecord = (record) => call('enqueueRecord', record);
export const triggerSync = () => call('enqueueSync');
export const getQueued = () => call('getQueuedRecords');
export const getSynced = () => call('getSyncedRecords');
export const clearQueue = () => call('clearQueue');
export const cancelSync = () => call('cancelSync');

// The plugin keeps a single listener set; App registers it once.
export function registerListeners(listeners) {
  const e = engine();
  if (e) e.registerListeners(listeners);
}

let baseUri = null;
// Photos live in the app's private files dir, like photos captured in the field:
//   /data/user/0/com.hfps.fieldaudit/files/audits/<auditId>/{photos,thumbs}
export async function photoBase() {
  if (baseUri) return baseUri;
  if (!isNative()) return (baseUri = '');
  const res = await Filesystem.getUri({ directory: Directory.Data, path: '' });
  baseUri = res.uri.replace(/\/$/, '');
  return baseUri;
}
