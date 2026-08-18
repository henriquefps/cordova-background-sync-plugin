# Required Signature for Exposed REST APIs

This document outlines the API signature requirements that your backend services must expose to receive synchronization payloads from the **BackgroundSyncPlugin**.

---

## Request Protocol

The REST APIs you expose to receive synchronization payloads must be configured to receive a standard **POST** request with a single consolidated **JSON Body** (`Content-Type: application/json`).

---

## JSON Body Structure

Each synchronization call is sent as a unified JSON body object containing the following parameters:

| Field Name | Data Type | Description |
| :--- | :--- | :--- |
| **`payload`** | JSON Object / Array | Contains the deserialized object structure of the record (parsed natively on-the-fly from the stored JSON string in `Local_SyncQueue.Payload`). |
| **`file`** | JSON Object (Optional) | Nested object populated only when the record features an associated local file path (`Local_SyncQueue.FilePath`). Contains file metadata and base64-encoded representation. |

### Structure of the Nested `file` Object

When a local file is uploaded along with the record, the `file` object contains the following attributes:

* **`filename`** (Text): The original name of the file (e.g. `"inspection_102.jpg"`).
* **`contentType`** (Text): The guessed MIME type of the file (e.g. `"image/jpeg"`, `"application/pdf"`).
* **`base64Data`** (Text): The raw, un-wrapped base64 string representation of the file. 

> [!TIP]
> **Decoding in OutSystems (ODC/O11):**
> You can decode the `base64Data` back to standard binary data using the system action **`Base64ToBinary`**.

---

## Example JSON Request Body

Below is an example of a POST request payload sent by the native background sync engine:

```http
POST /api/v1/sync/inspection HTTP/1.1
Host: yourcompany.api.com
Connection: Keep-Alive
Content-Type: application/json; charset=UTF-8

{
  "payload": {
    "inspectionId": 1422,
    "operator": "Henrique Silva",
    "status": "Finalized",
    "notes": "Inspection completed successfully under normal conditions."
  },
  "file": {
    "filename": "photo_1422_2026.jpg",
    "contentType": "image/jpeg",
    "base64Data": "/9j/4AAQSkZJRgABAQEASABIAAD/2wBD..."
  }
}
```

---

## Server HTTP Headers

The plugin supports custom headers (like static Authorization bearer tokens, custom keys, etc.) configured during the `initialize` method. These headers are automatically injected into each HTTP upload request.
