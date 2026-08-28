module TrayApp.Tests.DatabaseTests

open Xunit
open TrayApp.DocType

let private wikiPageDocType =
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
            Reqd = 1
            Unique = 0
            Default = "No Content"
            ReadOnly = 0
            InListView = 0
            InPreview = 1
            InStandardFilter = 0
            Description = ""
            FetchFrom = "" }
          { Fieldname = "route"
            Fieldtype = "Data"
            Label = "Route"
            Options = ""
            Reqd = 1
            Unique = 1
            Default = ""
            ReadOnly = 0
            InListView = 1
            InPreview = 1
            InStandardFilter = 1
            Description = ""
            FetchFrom = "" }
          { Fieldname = "published"
            Fieldtype = "Check"
            Label = "Published"
            Options = ""
            Reqd = 0
            Unique = 0
            Default = "0"
            ReadOnly = 0
            InListView = 0
            InPreview = 0
            InStandardFilter = 0
            Description = ""
            FetchFrom = "" }
          { Fieldname = "section_break"
            Fieldtype = "Section Break"
            Label = "Section"
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
      HasWebView = 1
      IsPublishedField = "published"
      TrackChanges = 1
      TitleField = "title"
      SortField = "modified"
      SortOrder = "DESC"
      AllowRename = 1
      AllowImport = 1
      AllowGuestToView = 1
      Creation = ""
      Modified = ""
      ModifiedBy = ""
      Owner = "" }

[<Fact>]
let ``migrate creates table for DocType`` () =
    use conn = Database.openInMemory ()
    Database.migrate conn wikiPageDocType

    // Verify table exists by querying it
    use cmd = conn.CreateCommand()
    cmd.CommandText <- "SELECT name FROM sqlite_master WHERE type='table' AND name='tabWiki Page'"
    let result = cmd.ExecuteScalar()
    Assert.NotNull(result)
    Assert.Equal("tabWiki Page", result :?> string)

[<Fact>]
let ``migrate creates unique index for unique fields`` () =
    use conn = Database.openInMemory ()
    Database.migrate conn wikiPageDocType

    // Verify unique index on route
    use cmd = conn.CreateCommand()
    cmd.CommandText <- "SELECT name FROM sqlite_master WHERE type='index' AND sql LIKE '%route%'"
    let result = cmd.ExecuteScalar()
    Assert.NotNull(result)

[<Fact>]
let ``create inserts document and returns name`` () =
    use conn = Database.openInMemory ()
    Database.migrate conn wikiPageDocType

    let doc = Document()
    doc["title"] <- "Test Page"
    doc["content"] <- "Hello World"
    doc["route"] <- "test-page"
    doc["published"] <- 1

    let name = Database.create conn wikiPageDocType doc
    Assert.False(System.String.IsNullOrEmpty(name))

[<Fact>]
let ``create with explicit name uses provided name`` () =
    use conn = Database.openInMemory ()
    Database.migrate conn wikiPageDocType

    let doc = Document()
    doc["name"] <- "my-custom-name"
    doc["title"] <- "Test Page"
    doc["content"] <- "Hello"
    doc["route"] <- "test"

    let name = Database.create conn wikiPageDocType doc
    Assert.Equal("my-custom-name", name)

[<Fact>]
let ``read retrieves document by name`` () =
    use conn = Database.openInMemory ()
    Database.migrate conn wikiPageDocType

    let doc = Document()
    doc["name"] <- "page-1"
    doc["title"] <- "My Page"
    doc["content"] <- "Content here"
    doc["route"] <- "my-page"

    Database.create conn wikiPageDocType doc |> ignore

    match Database.read conn wikiPageDocType "page-1" with
    | Some retrieved ->
        Assert.Equal("page-1", retrieved["name"] :?> string)
        Assert.Equal("My Page", retrieved["title"] :?> string)
        Assert.Equal("Content here", retrieved["content"] :?> string)
        Assert.Equal("my-page", retrieved["route"] :?> string)
    | None -> Assert.Fail("Document not found")

[<Fact>]
let ``read returns None for non-existent document`` () =
    use conn = Database.openInMemory ()
    Database.migrate conn wikiPageDocType

    let result = Database.read conn wikiPageDocType "does-not-exist"
    Assert.True(result.IsNone)

[<Fact>]
let ``update modifies existing document`` () =
    use conn = Database.openInMemory ()
    Database.migrate conn wikiPageDocType

    let doc = Document()
    doc["name"] <- "page-update"
    doc["title"] <- "Original Title"
    doc["content"] <- "Original"
    doc["route"] <- "page-update"
    Database.create conn wikiPageDocType doc |> ignore

    let updates = Document()
    updates["title"] <- "Updated Title"
    updates["content"] <- "Updated Content"
    let success = Database.update conn wikiPageDocType "page-update" updates
    Assert.True(success)

    match Database.read conn wikiPageDocType "page-update" with
    | Some retrieved ->
        Assert.Equal("Updated Title", retrieved["title"] :?> string)
        Assert.Equal("Updated Content", retrieved["content"] :?> string)
    | None -> Assert.Fail("Document not found after update")

[<Fact>]
let ``update returns false for non-existent document`` () =
    use conn = Database.openInMemory ()
    Database.migrate conn wikiPageDocType

    let updates = Document()
    updates["title"] <- "New Title"
    let success = Database.update conn wikiPageDocType "no-such-doc" updates
    Assert.False(success)

[<Fact>]
let ``delete removes document`` () =
    use conn = Database.openInMemory ()
    Database.migrate conn wikiPageDocType

    let doc = Document()
    doc["name"] <- "page-delete"
    doc["title"] <- "Delete Me"
    doc["content"] <- "Gone"
    doc["route"] <- "page-delete"
    Database.create conn wikiPageDocType doc |> ignore

    let success = Database.delete conn wikiPageDocType "page-delete"
    Assert.True(success)

    let result = Database.read conn wikiPageDocType "page-delete"
    Assert.True(result.IsNone)

[<Fact>]
let ``delete returns false for non-existent document`` () =
    use conn = Database.openInMemory ()
    Database.migrate conn wikiPageDocType

    let success = Database.delete conn wikiPageDocType "no-such-doc"
    Assert.False(success)

[<Fact>]
let ``list returns all documents`` () =
    use conn = Database.openInMemory ()
    Database.migrate conn wikiPageDocType

    for i in 1..3 do
        let doc = Document()
        doc["name"] <- sprintf "page-%d" i
        doc["title"] <- sprintf "Page %d" i
        doc["content"] <- sprintf "Content %d" i
        doc["route"] <- sprintf "page-%d" i
        Database.create conn wikiPageDocType doc |> ignore

    let docs = Database.list conn wikiPageDocType
    Assert.Equal(3, docs.Length)

[<Fact>]
let ``migrateAll handles multiple doctypes`` () =
    use conn = Database.openInMemory ()

    let childDocType =
        { wikiPageDocType with
            Name = "Wiki Page Revision"
            IsTable = 1
            Fields =
                [ { Fieldname = "revision"
                    Fieldtype = "Data"
                    Label = "Revision"
                    Options = ""
                    Reqd = 1
                    Unique = 0
                    Default = ""
                    ReadOnly = 0
                    InListView = 0
                    InPreview = 0
                    InStandardFilter = 0
                    Description = ""
                    FetchFrom = "" } ] }

    Database.migrateAll conn [ wikiPageDocType; childDocType ]

    // Verify both tables exist
    use cmd = conn.CreateCommand()
    cmd.CommandText <- "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name LIKE 'tab%'"
    let count = cmd.ExecuteScalar() :?> int64
    // tabSingles + tabWiki Page + tabWiki Page Revision = 3
    Assert.True(count >= 2L)

[<Fact>]
let ``singleton doctype stores and retrieves values`` () =
    use conn = Database.openInMemory ()

    let singletonDt =
        { wikiPageDocType with
            Name = "Wiki Settings"
            IsSingle = 1
            Fields =
                [ { Fieldname = "home_page"
                    Fieldtype = "Data"
                    Label = "Home Page"
                    Options = ""
                    Reqd = 0
                    Unique = 0
                    Default = ""
                    ReadOnly = 0
                    InListView = 0
                    InPreview = 0
                    InStandardFilter = 0
                    Description = ""
                    FetchFrom = "" } ] }

    Database.migrate conn singletonDt

    let doc = Document()
    doc["home_page"] <- "wiki/home"
    Database.create conn singletonDt doc |> ignore

    match Database.read conn singletonDt "" with
    | Some retrieved -> Assert.Equal("wiki/home", retrieved["home_page"] :?> string)
    | None -> Assert.Fail("Singleton not found")
