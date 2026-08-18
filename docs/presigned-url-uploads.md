# Direct Cloud Uploads via Presigned URLs

This document explains the technical implementation, database configurations, and request payloads required to upload heavy binary files (images, PDFs, videos) directly to Object Storage providers (like AWS S3, Google Cloud Storage, or Azure Blob Storage) using **Presigned URLs** to prevent memory saturation and network overhead.

---

## 1. Architectural Strategy

Standard background uploads convert files to Base64 and wrap them inside JSON request bodies. This adds a **33% network footprint overhead** and forces hybrid WebViews and native processes to load entire media blobs into the device's RAM, triggering Out-Of-Memory (OOM) background task terminations on iOS when handling files larger than 20MB.

**The Solution:**
Enable direct streaming uploads to Object Storage. The plugin nativelly handles a two-step handshake:
1. **Handshake**: The native plugin fires a lightweight metadata request to your OutSystems backend.
2. **Direct Upload**: The backend generates a secure temporary signed URL and returns it to the native plugin along with target headers. The plugin then streams the binary data directly from storage using chunked output buffers.

```
       Mobile Device                                                OutSystems Backend
+-------------------------+                                     +-----------------------+
|  Read queue record      | ------------ (1) POST /handshake --> | Generate Presigned URL|
|  Identify PRESIGNED_URL | <----------- (2) Returns URL/Header -| (AWS S3, Azure SAS)   |
+-------------------------+                                     +-----------------------+
            |
            | (3) HTTP PUT Raw binary stream
            v
  +--------------------+
  | Cloud Storage (S3) |
  +--------------------+
```

---

## 2. Enqueuing Presigned URL Records

To use this feature, enqueue a record into the plugin's private database using the `enqueueRecord()` JavaScript API. Set `uploadStrategy` to `"PRESIGNED_URL"`.

Set the record properties as follows when registering an attachment for direct cloud sync:

| Property | Recommended Value | Description |
| :--- | :--- | :--- |
| **`endpoint`** | `"/api/v1/attachments/signature"` | The relative path of your OutSystems endpoint responsible for generating the Presigned URL. |
| **`payload`** | `{"localParentId": "101", "fileName": "inspect_base.jpg"}` | Crucial metadata parameters (objects, strings, or arrays) sent to your signature endpoint to tie the file with its parent transaction. |
| **`filePath`** | `"file:///var/mobile/.../inspect_base.jpg"` | Local file URL pointing to the device storage. |
| **`uploadStrategy`**| `"PRESIGNED_URL"` | **Mandatory**. Instructs the native engine to execute the signed URL handshake flow instead of standard REST payload JSON serialization. |

Example:
```javascript
const record = {
    id: "req_902",
    endpoint: "/api/v1/attachments/signature",
    payload: { localParentId: "101", fileName: "inspect_base.jpg" },
    filePath: "file:///var/mobile/.../inspect_base.jpg",
    uploadStrategy: "PRESIGNED_URL"
};

syncEngine.enqueueRecord(record, onSuccess, onError);
```

---

## 3. The Handshake JSON Contracts

### Step A: Native Handshake Request (From Device to OutSystems Backend)
The native worker calls your endpoint using a standard `POST` request:

```http
POST /api/v1/attachments/signature HTTP/1.1
Host: yourcompany.api.com
Content-Type: application/json

{
  "payload": {
    "localParentId": "101",
    "fileName": "inspect_base.jpg"
  }
}
```

### Step B: Signature Response (From OutSystems Backend to Device)
Your server must generate the temporary URL and return it in a JSON body containing the keys `uploadUrl`, `method` (PUT/POST), and `headers`. Below are examples for the primary cloud providers:

#### 1. AWS S3 Example:
For S3, return a signed URL containing AWS authentication query params and required headers:

```json
{
  "uploadUrl": "https://your-bucket.s3.amazonaws.com/uploads/inspect_base.jpg?AWSAccessKeyId=AKIAIOSFODNN7EXAMPLE&Signature=vjbyPxybdZaNmGa%2ByT272YEAiv4%3D&Expires=1700000000",
  "method": "PUT",
  "headers": {
    "Content-Type": "image/jpeg",
    "x-amz-acl": "private"
  }
}
```

#### 2. Google Cloud Storage (GCS) Example:
For Google Cloud, generate a signed URL using V4 credentials (typically using a Service Account JSON private key):

```json
{
  "uploadUrl": "https://storage.googleapis.com/background-sync-test/inspections/101/inspect_base.jpg?GoogleAccessId=uploader%40finances-app.iam.gserviceaccount.com&Expires=1700000000&Signature=...",
  "method": "PUT",
  "headers": {
    "Content-Type": "application/octet-stream"
  }
}
```

#### 3. Azure Blob Storage (SAS) Example:
For Azure, return the Shared Access Signature (SAS) URL and include the mandatory `x-ms-blob-type` header to define it as a Block Blob:

```json
{
  "uploadUrl": "https://myaccount.blob.core.windows.net/mycontainer/inspect_base.jpg?sv=2021-08-06&se=2026-06-07T12%3A00%3A00Z&sr=b&sp=w&sig=...",
  "method": "PUT",
  "headers": {
    "x-ms-blob-type": "BlockBlob",
    "Content-Type": "image/jpeg"
  }
}
```

---

## 4. How the Native Upload is Processed

Once the native background engine receives the handshake JSON response, it initiates the second request:
1. **HTTP Headers Injection**: The plugin injects all key-value pairs specified inside the response's `headers` JSON block dynamically into the HTTP connection.
2. **Buffer Streaming**:
   - **Android**: Opens a connection using chunked streaming mode (`setChunkedStreamingMode(4096)`) and reads the local file in 4KB blocks, avoiding memory heap allocations.
   - **iOS**: Uses the native `NSInputStream` via `setHTTPBodyStream` which streams bytes directly from the storage file descriptor to the network socket, avoiding OOM background crashes.

---

## 5. Fallback: Building Your Own Receiving Endpoint

You are not required to point `uploadUrl` at a cloud object storage provider. The native plugin treats `uploadUrl` as an opaque HTTP destination — it does not validate the hostname, and it has no idea (or interest in) whether it's talking to S3, GCS, Azure, or your own server. Your handshake endpoint can return a URL pointing at **any endpoint you control**, and the upload step behaves identically.

This is a reasonable fallback for:

- Environments/customers that don't have (or don't want to configure) an object storage bucket.
- Persisting the file directly into your own backend's database or filesystem instead of a third-party storage service.

### What actually changes vs. what doesn't

Routing the upload to your own endpoint still gets you the two real benefits of `PRESIGNED_URL` over `REST_PAYLOAD`:

- No Base64 encoding, so no ~33% network overhead.
- The device streams the file from disk in small chunks rather than loading the whole file into memory, avoiding the OOM crashes `REST_PAYLOAD` can cause on large files.

**It does *not* remove the payload-size or execution-timeout limits your own backend enforces.** Whatever ceiling your web server, API gateway, or platform imposes on request body size and execution time still applies — the file still arrives as a single HTTP request body that your backend must accept in full before it can do anything with it. Switching from `REST_PAYLOAD` to a self-hosted `PRESIGNED_URL` endpoint does not, by itself, let you accept larger files than your backend's own request-size ceiling allows; you still need to raise that ceiling on your own infrastructure to support larger files.

### Requirements for your own receiving endpoint

1. **Accept a raw binary body, not JSON.** Configure the route/method to expect a Content-Type like `application/octet-stream` (or the real MIME type) and read the request body as a binary stream/blob — do not attempt to parse it as JSON.
2. **Carry metadata via the URL or headers, not the body.** Since the entire HTTP body is the file's bytes, pass identifiers (parent record ID, filename, etc.) as path segments, query parameters, or custom headers instead.
3. **Persist the bytes** — to a database BLOB/binary column, a local filesystem, or by forwarding them on to a real object storage service. This is entirely up to your backend implementation.
4. **Respond with a 2xx status.** The plugin only inspects the HTTP status code to decide whether the record is marked as synced or retried; the response body isn't parsed on this step.
5. **Raise your server's request-size and timeout limits** to accommodate the largest file you intend to accept. This is unavoidable — no client-side plugin behavior can compensate for a backend that rejects large request bodies outright.

### Example handshake response

Your handshake endpoint's response looks exactly like the cloud-provider examples in Section 3 — only the URL and headers differ:

```json
{
  "uploadUrl": "https://your-backend.example.com/api/v1/files/101/inspect_base.jpg",
  "method": "PUT",
  "headers": {
    "Content-Type": "image/jpeg"
  }
}
```

The plugin's behavior on the upload step (chunked streaming, 5-minute timeout, header injection) is identical regardless of the destination — see [Section 4](#4-how-the-native-upload-is-processed).

### Caveats specific to storing files in a relational database

If your endpoint persists the file into a database BLOB/binary column rather than a filesystem or object storage:

- Large binary columns inflate database size, increasing backup/restore time and, on managed/cloud database plans, storage cost.
- Avoid selecting the binary column in list/query operations that don't need it — project only metadata columns, and fetch the binary data lazily, only on the specific screen/endpoint that actually needs to serve or display the file.
- This pattern is reasonable for moderate-sized attachments (documents, photos). For very large media (video), consider whether your backend's practical size limit is acceptable, or whether object storage is warranted once this fallback's limits are reached.
