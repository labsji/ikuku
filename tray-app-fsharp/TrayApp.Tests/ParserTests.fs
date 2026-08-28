module TrayApp.Tests.ParserTests

open System.IO
open Xunit
open TrayApp.DocType

[<Fact>]
let ``parseDocType parses wiki_page json correctly`` () =
    let json =
        """{"name":"Wiki Page","module":"Wiki","autoname":"hash","naming_rule":"Random","issingle":0,"istable":0,"fields":[{"fieldname":"content","fieldtype":"Markdown Editor","label":"Content","reqd":1,"default":"No Content"},{"fieldname":"published","fieldtype":"Check","label":"Published","default":"0"},{"fieldname":"route","fieldtype":"Data","label":"Route","reqd":1,"unique":1,"in_list_view":1,"in_standard_filter":1},{"fieldname":"title","fieldtype":"Data","label":"Title","reqd":1},{"fieldname":"content_section","fieldtype":"Section Break","label":"Title & Content"},{"fieldname":"column_break_2","fieldtype":"Column Break"},{"fieldname":"section_break_4","fieldtype":"Section Break"},{"fieldname":"allow_guest","fieldtype":"Check","label":"Allow Guest","default":"1"},{"fieldname":"meta_tags_section","fieldtype":"Section Break","label":"Meta Tags"},{"fieldname":"meta_description","fieldtype":"Small Text","label":"Description"},{"fieldname":"meta_image","fieldtype":"Attach Image","label":"Image"},{"fieldname":"meta_keywords","fieldtype":"Small Text","label":"Keywords"}],"permissions":[{"role":"System Manager","read":1,"write":1,"create":1,"delete":1}],"has_web_view":1,"title_field":"title","sort_field":"modified","sort_order":"DESC","allow_rename":1,"allow_import":1,"allow_guest_to_view":1,"track_changes":1}"""

    match Parser.parseDocType json with
    | Ok dt ->
        Assert.Equal("Wiki Page", dt.Name)
        Assert.Equal("Wiki", dt.Module)
        Assert.Equal("hash", dt.Autoname)
        Assert.Equal("Random", dt.NamingRule)
        Assert.Equal(0, dt.IsSingle)
        Assert.Equal(0, dt.IsTable)
        Assert.Equal(1, dt.HasWebView)
        Assert.Equal("title", dt.TitleField)
        Assert.Equal("modified", dt.SortField)
        Assert.Equal("DESC", dt.SortOrder)
        Assert.Equal(1, dt.AllowRename)
        Assert.Equal(1, dt.AllowImport)
        Assert.Equal(1, dt.AllowGuestToView)
        Assert.Equal(1, dt.TrackChanges)
        Assert.Equal(12, dt.Fields.Length)
        Assert.Single(dt.Permissions) |> ignore
    | Error e -> Assert.Fail(e)

[<Fact>]
let ``parseDocType extracts data fields excluding layout fields`` () =
    let json =
        """{"name":"Wiki Page","module":"Wiki","fields":[{"fieldname":"content","fieldtype":"Markdown Editor","label":"Content","reqd":1},{"fieldname":"section_break","fieldtype":"Section Break","label":"Section"},{"fieldname":"column_break","fieldtype":"Column Break"},{"fieldname":"title","fieldtype":"Data","label":"Title","reqd":1}],"permissions":[]}"""

    match Parser.parseDocType json with
    | Ok dt ->
        let dataFields = FieldHelpers.dataFields dt
        Assert.Equal(2, dataFields.Length)
        Assert.Equal("content", dataFields[0].Fieldname)
        Assert.Equal("title", dataFields[1].Fieldname)
    | Error e -> Assert.Fail(e)

[<Fact>]
let ``parseDocType returns error for missing name`` () =
    let json = """{"module":"Wiki","fields":[],"permissions":[]}"""

    match Parser.parseDocType json with
    | Ok _ -> Assert.Fail("Expected error for missing name")
    | Error e -> Assert.Contains("missing 'name' field", e)

[<Fact>]
let ``parseDocType returns error for invalid json`` () =
    let json = "not valid json"

    match Parser.parseDocType json with
    | Ok _ -> Assert.Fail("Expected error for invalid JSON")
    | Error e -> Assert.Contains("parse error", e)

[<Fact>]
let ``isLayoutField correctly identifies layout fields`` () =
    let sectionBreak =
        { Fieldname = "sb"
          Fieldtype = "Section Break"
          Label = ""
          Options = ""
          Reqd = 0
          Unique = 0
          Default = ""
          ReadOnly = 0
          InListView = 0
          InPreview = 0
          InStandardFilter = 0
          Description = ""
          FetchFrom = "" }

    let dataField =
        { sectionBreak with
            Fieldname = "title"
            Fieldtype = "Data" }

    Assert.True(FieldHelpers.isLayoutField sectionBreak)
    Assert.False(FieldHelpers.isLayoutField dataField)

[<Fact>]
let ``sqlType returns correct types`` () =
    let checkField =
        { Fieldname = "published"
          Fieldtype = "Check"
          Label = ""
          Options = ""
          Reqd = 0
          Unique = 0
          Default = ""
          ReadOnly = 0
          InListView = 0
          InPreview = 0
          InStandardFilter = 0
          Description = ""
          FetchFrom = "" }

    let dataField = { checkField with Fieldtype = "Data" }
    let textField = { checkField with Fieldtype = "Text" }

    Assert.Equal("INTEGER", FieldHelpers.sqlType checkField)
    Assert.Equal("TEXT", FieldHelpers.sqlType dataField)
    Assert.Equal("TEXT", FieldHelpers.sqlType textField)

[<Fact>]
let ``tableName follows Frappe convention`` () =
    let json =
        """{"name":"Wiki Page","module":"Wiki","fields":[],"permissions":[]}"""

    match Parser.parseDocType json with
    | Ok dt -> Assert.Equal("tabWiki Page", FieldHelpers.tableName dt)
    | Error e -> Assert.Fail(e)

[<Fact>]
let ``loadFromDirectory loads actual doctype files`` () =
    // Find the doctypes directory relative to test execution
    let basePaths =
        [ Path.Combine(Directory.GetCurrentDirectory(), "doctypes")
          Path.Combine(Directory.GetCurrentDirectory(), "..", "..", "..", "..", "TrayApp", "doctypes")
          Path.Combine(Directory.GetCurrentDirectory(), "..", "..", "..", "doctypes") ]

    let doctypePath =
        basePaths |> List.tryFind Directory.Exists

    match doctypePath with
    | Some path ->
        let doctypes = Parser.loadFromDirectory path
        Assert.True(doctypes.Length > 0, "Should load at least one doctype")
        // Verify Wiki Page is among them
        let wikiPage = doctypes |> List.tryFind (fun dt -> dt.Name = "Wiki Page")
        Assert.True(wikiPage.IsSome, "Should find Wiki Page doctype")
    | None ->
        // If doctypes directory not found in test context, skip gracefully
        ()
