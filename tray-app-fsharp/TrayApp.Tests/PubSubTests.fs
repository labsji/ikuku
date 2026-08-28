module TrayApp.Tests.PubSubTests

open System.Collections.Generic
open System.Text
open System.Text.Json
open Xunit
open TrayApp.Sync
open TrayApp.DocType

[<Fact>]
let ``SyncMessage serialization produces correct JSON format`` () =
    let data = Dictionary<string, obj>()
    data["title"] <- "Test Page"
    data["content"] <- "Hello World"

    let msg =
        { Action = "create"
          DocType = "Wiki Page"
          Name = "page-1"
          Data = data
          Timestamp = "2024-01-01T00:00:00Z" }

    let bytes = SyncMessage.serialize msg
    let json = Encoding.UTF8.GetString(bytes)

    // Verify it contains expected fields
    Assert.Contains("\"action\":\"create\"", json)
    Assert.Contains("\"doctype\":\"Wiki Page\"", json)
    Assert.Contains("\"name\":\"page-1\"", json)
    Assert.Contains("\"timestamp\":\"2024-01-01T00:00:00Z\"", json)
    Assert.Contains("\"title\":\"Test Page\"", json)
    Assert.Contains("\"content\":\"Hello World\"", json)

[<Fact>]
let ``SyncMessage deserialization round-trips correctly`` () =
    let data = Dictionary<string, obj>()
    data["title"] <- "My Doc"
    data["published"] <- 1

    let original =
        { Action = "update"
          DocType = "Wiki Page"
          Name = "doc-123"
          Data = data
          Timestamp = "2024-06-15T12:30:00Z" }

    let bytes = SyncMessage.serialize original

    match SyncMessage.deserialize bytes with
    | Ok deserialized ->
        Assert.Equal("update", deserialized.Action)
        Assert.Equal("Wiki Page", deserialized.DocType)
        Assert.Equal("doc-123", deserialized.Name)
        Assert.Equal("2024-06-15T12:30:00Z", deserialized.Timestamp)
        Assert.NotNull(deserialized.Data)
        Assert.True(deserialized.Data.ContainsKey("title"))
    | Error e -> Assert.Fail(e)

[<Fact>]
let ``SyncMessage deserialization handles delete action`` () =
    let json =
        """{"action":"delete","doctype":"Wiki Page","name":"page-to-delete","data":{},"timestamp":"2024-01-02T10:00:00Z"}"""

    let bytes = Encoding.UTF8.GetBytes(json)

    match SyncMessage.deserialize bytes with
    | Ok msg ->
        Assert.Equal("delete", msg.Action)
        Assert.Equal("Wiki Page", msg.DocType)
        Assert.Equal("page-to-delete", msg.Name)
        Assert.Equal("2024-01-02T10:00:00Z", msg.Timestamp)
    | Error e -> Assert.Fail(e)

[<Fact>]
let ``SyncMessage deserialization returns error for invalid JSON`` () =
    let bytes = Encoding.UTF8.GetBytes("not json at all")

    match SyncMessage.deserialize bytes with
    | Ok _ -> Assert.Fail("Expected error for invalid JSON")
    | Error e -> Assert.Contains("Deserialize error", e)

[<Fact>]
let ``SyncMessage.create sets current timestamp`` () =
    let data = Dictionary<string, obj>()
    let msg = SyncMessage.create "create" "Wiki Page" "new-page" data

    Assert.Equal("create", msg.Action)
    Assert.Equal("Wiki Page", msg.DocType)
    Assert.Equal("new-page", msg.Name)
    Assert.False(System.String.IsNullOrEmpty(msg.Timestamp))
    // Timestamp should be in ISO format with Z suffix
    Assert.EndsWith("Z", msg.Timestamp)

[<Fact>]
let ``SyncMessage format matches Go server format`` () =
    // The Go server expects exactly: {action, doctype, name, data, timestamp}
    let data = Dictionary<string, obj>()
    data["title"] <- "Hello"

    let msg =
        { Action = "create"
          DocType = "Wiki Page"
          Name = "test"
          Data = data
          Timestamp = "2024-01-01T00:00:00Z" }

    let bytes = SyncMessage.serialize msg
    let json = Encoding.UTF8.GetString(bytes)

    // Parse as generic JSON to verify structure
    let doc = JsonDocument.Parse(json)
    let root = doc.RootElement

    // All expected properties must be present
    Assert.True(root.TryGetProperty("action") |> fst)
    Assert.True(root.TryGetProperty("doctype") |> fst)
    Assert.True(root.TryGetProperty("name") |> fst)
    Assert.True(root.TryGetProperty("data") |> fst)
    Assert.True(root.TryGetProperty("timestamp") |> fst)

[<Fact>]
let ``deserializeString works with JSON string`` () =
    let json =
        """{"action":"create","doctype":"Wiki Page","name":"page-1","data":{"title":"Test"},"timestamp":"2024-01-01T00:00:00Z"}"""

    match SyncMessage.deserializeString json with
    | Ok msg ->
        Assert.Equal("create", msg.Action)
        Assert.Equal("Wiki Page", msg.DocType)
        Assert.Equal("page-1", msg.Name)
    | Error e -> Assert.Fail(e)

[<Fact>]
let ``SyncEngine applies remote create`` () =
    use conn = Database.openInMemory ()

    let dt =
        { Name = "Wiki Page"
          Module = "Wiki"
          Autoname = "hash"
          NamingRule = "Random"
          IsSingle = 0
          IsTable = 0
          Fields =
            [ { Fieldname = "title"
                Fieldtype = "Data"
                Label = "Title"
                Options = ""
                Reqd = 1
                Unique = 0
                Default = ""
                ReadOnly = 0
                InListView = 0
                InPreview = 0
                InStandardFilter = 0
                Description = ""
                FetchFrom = "" }
              { Fieldname = "content"
                Fieldtype = "Markdown Editor"
                Label = "Content"
                Options = ""
                Reqd = 0
                Unique = 0
                Default = ""
                ReadOnly = 0
                InListView = 0
                InPreview = 0
                InStandardFilter = 0
                Description = ""
                FetchFrom = "" } ]
          FieldOrder = []
          Permissions = []
          HasWebView = 0
          IsPublishedField = ""
          TrackChanges = 0
          TitleField = ""
          SortField = ""
          SortOrder = ""
          AllowRename = 0
          AllowImport = 0
          AllowGuestToView = 0
          Creation = ""
          Modified = ""
          ModifiedBy = ""
          Owner = "" }

    Database.migrate conn dt

    let pubsub = new PubSubClient("ws://localhost:9999", "test-token")
    let engine = SyncEngine(pubsub, conn, [ dt ])

    let data = Dictionary<string, obj>()
    data["title"] <- "Remote Page"
    data["content"] <- "From server"

    let msg =
        { Action = "create"
          DocType = "Wiki Page"
          Name = "remote-1"
          Data = data
          Timestamp = "2024-06-15T12:00:00Z" }

    let applied = engine.ApplyRemoteChange(msg)
    Assert.True(applied)

    // Verify document was created
    match Database.read conn dt "remote-1" with
    | Some doc ->
        Assert.Equal("Remote Page", doc["title"] :?> string)
        Assert.Equal("From server", doc["content"] :?> string)
    | None -> Assert.Fail("Document was not created by sync engine")

    (pubsub :> System.IDisposable).Dispose()

[<Fact>]
let ``SyncEngine last-write-wins conflict resolution`` () =
    use conn = Database.openInMemory ()

    let dt =
        { Name = "Wiki Page"
          Module = "Wiki"
          Autoname = "hash"
          NamingRule = "Random"
          IsSingle = 0
          IsTable = 0
          Fields =
            [ { Fieldname = "title"
                Fieldtype = "Data"
                Label = "Title"
                Options = ""
                Reqd = 1
                Unique = 0
                Default = ""
                ReadOnly = 0
                InListView = 0
                InPreview = 0
                InStandardFilter = 0
                Description = ""
                FetchFrom = "" } ]
          FieldOrder = []
          Permissions = []
          HasWebView = 0
          IsPublishedField = ""
          TrackChanges = 0
          TitleField = ""
          SortField = ""
          SortOrder = ""
          AllowRename = 0
          AllowImport = 0
          AllowGuestToView = 0
          Creation = ""
          Modified = ""
          ModifiedBy = ""
          Owner = "" }

    Database.migrate conn dt

    // Create a local document with a recent modified timestamp
    let doc = Document()
    doc["name"] <- "conflict-page"
    doc["title"] <- "Local Version"
    doc["modified"] <- "2024-06-15T14:00:00Z"
    Database.create conn dt doc |> ignore

    let pubsub = new PubSubClient("ws://localhost:9999", "test-token")
    let engine = SyncEngine(pubsub, conn, [ dt ])

    // Remote update with OLDER timestamp - should NOT apply
    let olderData = Dictionary<string, obj>()
    olderData["title"] <- "Older Remote"

    let olderMsg =
        { Action = "update"
          DocType = "Wiki Page"
          Name = "conflict-page"
          Data = olderData
          Timestamp = "2024-06-15T12:00:00Z" }

    let applied = engine.ApplyRemoteChange(olderMsg)
    Assert.False(applied)

    // Verify local version is preserved
    match Database.read conn dt "conflict-page" with
    | Some d -> Assert.Equal("Local Version", d["title"] :?> string)
    | None -> Assert.Fail("Document not found")

    // Remote update with NEWER timestamp - should apply
    let newerData = Dictionary<string, obj>()
    newerData["title"] <- "Newer Remote"

    let newerMsg =
        { Action = "update"
          DocType = "Wiki Page"
          Name = "conflict-page"
          Data = newerData
          Timestamp = "2024-06-15T16:00:00Z" }

    let applied2 = engine.ApplyRemoteChange(newerMsg)
    Assert.True(applied2)

    // Verify remote version was applied
    match Database.read conn dt "conflict-page" with
    | Some d -> Assert.Equal("Newer Remote", d["title"] :?> string)
    | None -> Assert.Fail("Document not found after update")

    (pubsub :> System.IDisposable).Dispose()
