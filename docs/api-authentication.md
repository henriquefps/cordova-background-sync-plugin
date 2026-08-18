# API Authentication Strategies

When exposing REST endpoints to receive background synchronization data, you must ensure that connections are securely authenticated, untampered with, and linked to valid application users. 

This document outlines two recommended authentication strategies: a **Basic Strategy** (suitable for simple setups and fast time-to-market) and an **Advanced Strategy** (designed for enterprise-grade, high-security systems).

---

## 1. Basic Strategy: Rotation API Keys per Device/User

This strategy maps a unique, server-managed API Key to a specific device and user profile. The key is injected into custom HTTP headers during plugin initialization.

```
+------------------+                    (1) HTTP GET /sync                 +-------------------+
|  Mobile Device   | ----------------------------------------------------> | OutSystems Server |
| [Header: X-Key]  | <---------------------------------------------------- |   REST Endpoint   |
+------------------+                   (2) HTTP 200 OK                     +-------------------+
                                                                                     |
                                                                                     v
                                                                           [Authenticate User]
                                                                           Query: Key -> UserId
```

### How it works:
1. **User Activation**: During the initial online login, the OutSystems backend generates a random cryptographic API Key (e.g., a UUID string) and saves it in a backend table: `User_Device_Keys` (attributes: `UserId`, `DeviceUUID`, `ApiKey`, `ExpirationDate`).
2. **Local Storage**: The client application saves this key in secure storage (SQLite or Encrypted Local Storage).
3. **Plugin Initialization**: Pass the key inside the headers structure during the JavaScript `initialize()` handshake:
   ```javascript
   BackgroundSyncPlugin.initialize({
       serverUrl: "https://yourcompany.api.com",
       headers: {
           "X-API-Key": myStoredApiKey
       }
   });
   ```
4. **Server Authentication Logic**:
   - In OutSystems, expose the REST API and add `X-API-Key` as an input parameter (Set property `Receive In: Header`).
   - Inside the Action Flow, query `User_Device_Keys` to find a match.
   - If a valid match is found, retrieve the associated `UserId` to context-bind database audits.
   - If not found or expired, raise a REST exception returning an **HTTP 401 Unauthorized** error.

### Safe Key Rotation Guidelines:
To prevent synchronization failures, key rotation must be **resilient to offline usage**:
- **Never** trigger key rotation via automatic background timers on the server.
- Rotate keys **exclusively** when the user opens the application online in the foreground. Make a handshake call to exchange the old key for a new one, immediately updating it in the client database.

---

## 2. Advanced Strategy: Short-Lived JWT & Refresh Token (OAuth 2.0)

This is the standard enterprise configuration. It utilizes short-lived JSON Web Tokens (JWT) for API requests and a long-lived Refresh Token to securely request new access tokens without prompting user credentials.

> [!WARNING]
> **The plugin does NOT refresh tokens natively.** The native workers (`SyncWorker.kt` on Android, `BackgroundSyncPlugin.m` on iOS) send whatever `headers` were last stored during `initialize()` and have no logic to detect an HTTP 401, call a refresh endpoint, or retry with a new token. If the server returns 401, it is treated like any other non-transient HTTP error: the record is marked `"failed"`, the sync cycle stops (`Result.failure()` on Android — no automatic `WorkManager` retry, since 401 is not in the transient-error list), and it is retried later only when your app calls `sync()`/`enqueueSync()` again — with the same (still expired) header, unless you have refreshed it yourself in the meantime.

```
       Mobile Device                                                OutSystems Server
+-------------------------+                                     +-----------------------+
| AccessToken (15 min)    | ------------ (1) POST /sync --------> |   Validate JWT Token  |
| RefreshToken (30 days)  | <----------- (2) HTTP 401 ----------  | (Token has expired)   |
+-------------------------+                                       +-----------------------+
```

### How it works (app-side responsibility)

1. **Authentication Token Exchange**: When logging into the application, the identity provider returns a payload containing:
   - `AccessToken`: Short-lived cryptographic JWT containing claims (UserId, Roles) signed by the server.
   - `RefreshToken`: Long-lived random token associated with the session.
2. **Foreground Synchronization**: The `AccessToken` is injected during initialization:
   - `Authorization: Bearer <AccessToken>`
3. **Keeping the token fresh for background runs**: Because the native worker cannot refresh tokens itself, your app must ensure the `AccessToken` stays valid for the entire window a background sync might run in:
   - **Recommended:** Issue `AccessToken`s with an expiry comfortably longer than your expected background execution window (Android foreground-service runs and iOS background task budgets are typically minutes, not hours), or use a non-expiring/rotating API key (see Basic Strategy above) for the background channel specifically.
   - **Proactive refresh pattern:** Whenever the app is in the foreground and the current `AccessToken` is close to expiring, call your `/refresh` endpoint yourself from JavaScript, then call `initialize()` again with the updated `headers` object. `initialize()` overwrites the stored header value used by the next `sync()` run — there is no separate "update headers" method.
   - **Handling a stale-token failure:** Listen for `onFailed` (see [Notifications](notifications.md)); if the queue stalls with repeated non-transient failures, refresh the token and other headers in the foreground and call `sync()` again to resume the queue from where it stopped.

### OutSystems Server Implementation:
- Utilize JWT helper components from the OutSystems Forge (e.g., *JWT Tool*) to decode and validate incoming bearer signatures natively in your REST Action flow.
- Expose a `/refresh` endpoint your **JavaScript layer** calls proactively — it is not called by the native plugin.
