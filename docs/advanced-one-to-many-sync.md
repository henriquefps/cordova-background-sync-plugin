# Advanced Sync Patterns: One-to-Many File Attachments

This document provides a guide and technical pattern on how to synchronize a single business record featuring multiple heavy file attachments (e.g., an Inspection with $N$ photos) using the current single-file, sequential architecture of the **BackgroundSyncPlugin**.

---

## The Normalized Queue Pattern

Because loading multiple heavy files into memory simultaneously on mobile devices causes memory saturation and Out-Of-Memory (OOM) crashes (especially on iOS), the plugin enforces a **single-file-per-record** queue limit.

To send a record with multiple attachments, you must **normalize your queue insertions**. Instead of sending one massive payload with all images, you split the transaction into $1$ metadata record followed by $N$ attachment records.

```
       Local_SyncQueue
+-------------------------------------------------------------------------+
| Seq | Endpoint               | FilePath        | Payload (JSON)         |
+-----+------------------------+-----------------+------------------------+
| 1   | /api/sync/inspection   | NULL            | { "InspectionId": 12 } | <- Header
| 2   | /api/sync/media        | file://img1.jpg | { "InspectionId": 12 } | <- Photo 1
| 3   | /api/sync/media        | file://img2.jpg | { "InspectionId": 12 } | <- Photo 2
+-----+------------------------+-----------------+------------------------+
```

Since the queue is processed sequentially based on the `Sequence` column, the server is guaranteed to receive and create the parent Inspection header *before* the native background thread uploads the corresponding attachment payloads.

---

## 1. Local Database & Queue Setup

When a user submits an inspection offline, you write the parent record to your own business database and loop through the local file collection to enqueue corresponding sync records into the plugin's private database.

### Example JavaScript Enqueue Calls

```javascript
// 1. Enqueue the main inspection metadata first
syncEngine.enqueueRecord({
    id: 'req_901',
    endpoint: '/api/v1/inspections',
    payload: {
        localInspectionId: 'L_4021',
        operator: 'Henrique Silva',
        notes: 'Wind turbine check completed.'
    },
    filePath: null
}, onSuccess, onError);

// 2. Enqueue Photo #1 attaching the foreign reference
syncEngine.enqueueRecord({
    id: 'req_902',
    endpoint: '/api/v1/inspections/attachments',
    payload: {
        localInspectionId: 'L_4021',
        attachmentType: 'FrontView'
    },
    filePath: 'cdvfile://localhost/persistent/inspections/turbine_front.jpg'
}, onSuccess, onError);

// 3. Enqueue Photo #2 attaching the foreign reference
syncEngine.enqueueRecord({
    id: 'req_903',
    endpoint: '/api/v1/inspections/attachments',
    payload: {
        localInspectionId: 'L_4021',
        attachmentType: 'DetailZoom'
    },
    filePath: 'cdvfile://localhost/persistent/inspections/turbine_detail.jpg'
}, onSuccess, onError);
```

---

## 2. Server-Side API Handlers (.NET Core example)

Your backend endpoints must be split to process the metadata first, followed by the incremental media uploads.

### Endpoint 1: The Parent Receiver (`POST /api/v1/inspections`)

```csharp
[HttpPost]
public async Task<IActionResult> CreateInspection([FromBody] InspectionPayload request)
{
    // 1. Create inspection record in database and generate/track server ID
    var inspection = new Inspection 
    {
        LocalId = request.LocalInspectionId,
        Operator = request.Operator,
        Notes = request.Notes,
        CreatedAt = DateTime.UtcNow
    };
    
    _dbContext.Inspections.Add(inspection);
    await _dbContext.SaveChangesAsync();
    
    return Ok(new { serverInspectionId = inspection.Id });
}
```

### Endpoint 2: The Attachment Receiver (`POST /api/v1/inspections/attachments`)

This endpoint processes the single file attachment sent natively as Base64 alongside the relational payload reference.

```csharp
[HttpPost("attachments")]
public async Task<IActionResult> UploadAttachment([FromBody] AttachmentRequest request)
{
    // 1. Resolve parent inspection using the local reference
    var parent = await _dbContext.Inspections
        .FirstOrDefaultAsync(i => i.LocalId == request.Payload.LocalInspectionId);
        
    if (parent == null)
    {
         // 503 triggers a transient retry if the parent upload was delayed
         return StatusCode(503, "Parent inspection not synchronized yet.");
    }

    // 2. Decode native file payload
    byte[] fileBytes = Convert.FromBase64String(request.File.Base64Data);
    var filePath = Path.Combine("uploads", request.File.Filename);
    await System.IO.File.WriteAllBytesAsync(filePath, fileBytes);

    // 3. Save attachment metadata linked to the parent
    var attachment = new InspectionAttachment
    {
        InspectionId = parent.Id,
        Type = request.Payload.AttachmentType,
        FilePath = filePath
    };
    
    _dbContext.Attachments.Add(attachment);
    await _dbContext.SaveChangesAsync();

    return Ok();
}
```

---

## 3. OutSystems Mobile Client Setup

Inside your OutSystems Mobile app, manage this flow within a client action (e.g., `Offline_SubmitInspection`):

1. **Local Save**: Save the main record and its details to your local SQLite business entities.
2. **Retrieve File Paths**: Fetch all temporary binary file URLs associated with your offline inspection records.
3. **Loop & Enqueue**:
   - Enqueue the Inspection metadata record using `enqueueRecord` with `filePath = null`.
   - Start a loop for the attachments. For each file, call `enqueueRecord` with the corresponding `filePath`, linking the parent `localInspectionId` inside the `payload`.
4. **Trigger Background Sync**: Call the native plugin's `sync()` method to initiate the background upload process.
