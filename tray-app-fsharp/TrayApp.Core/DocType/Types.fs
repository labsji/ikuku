namespace TrayApp.DocType

open System.Text.Json.Serialization

/// Represents a single field in a DocType.
[<CLIMutable>]
type Field =
    { [<JsonPropertyName("fieldname")>]
      Fieldname: string
      [<JsonPropertyName("fieldtype")>]
      Fieldtype: string
      [<JsonPropertyName("label")>]
      Label: string
      [<JsonPropertyName("options")>]
      Options: string
      [<JsonPropertyName("reqd")>]
      Reqd: int
      [<JsonPropertyName("unique")>]
      Unique: int
      [<JsonPropertyName("default")>]
      Default: string
      [<JsonPropertyName("read_only")>]
      ReadOnly: int
      [<JsonPropertyName("in_list_view")>]
      InListView: int
      [<JsonPropertyName("in_preview")>]
      InPreview: int
      [<JsonPropertyName("in_standard_filter")>]
      InStandardFilter: int
      [<JsonPropertyName("description")>]
      Description: string
      [<JsonPropertyName("fetch_from")>]
      FetchFrom: string }

/// Represents a role-based permission entry.
[<CLIMutable>]
type Permission =
    { [<JsonPropertyName("role")>]
      Role: string
      [<JsonPropertyName("read")>]
      Read: int
      [<JsonPropertyName("write")>]
      Write: int
      [<JsonPropertyName("create")>]
      Create: int
      [<JsonPropertyName("delete")>]
      Delete: int
      [<JsonPropertyName("export")>]
      Export: int
      [<JsonPropertyName("email")>]
      Email: int
      [<JsonPropertyName("print")>]
      Print: int
      [<JsonPropertyName("report")>]
      Report: int
      [<JsonPropertyName("share")>]
      Share: int
      [<JsonPropertyName("select")>]
      Select: int }

/// Represents a Frappe DocType definition parsed from JSON.
[<CLIMutable>]
type DocType =
    { [<JsonPropertyName("name")>]
      Name: string
      [<JsonPropertyName("module")>]
      Module: string
      [<JsonPropertyName("autoname")>]
      Autoname: string
      [<JsonPropertyName("naming_rule")>]
      NamingRule: string
      [<JsonPropertyName("issingle")>]
      IsSingle: int
      [<JsonPropertyName("istable")>]
      IsTable: int
      [<JsonPropertyName("fields")>]
      Fields: Field list
      [<JsonPropertyName("field_order")>]
      FieldOrder: string list
      [<JsonPropertyName("permissions")>]
      Permissions: Permission list
      [<JsonPropertyName("has_web_view")>]
      HasWebView: int
      [<JsonPropertyName("is_published_field")>]
      IsPublishedField: string
      [<JsonPropertyName("track_changes")>]
      TrackChanges: int
      [<JsonPropertyName("title_field")>]
      TitleField: string
      [<JsonPropertyName("sort_field")>]
      SortField: string
      [<JsonPropertyName("sort_order")>]
      SortOrder: string
      [<JsonPropertyName("allow_rename")>]
      AllowRename: int
      [<JsonPropertyName("allow_import")>]
      AllowImport: int
      [<JsonPropertyName("allow_guest_to_view")>]
      AllowGuestToView: int
      [<JsonPropertyName("creation")>]
      Creation: string
      [<JsonPropertyName("modified")>]
      Modified: string
      [<JsonPropertyName("modified_by")>]
      ModifiedBy: string
      [<JsonPropertyName("owner")>]
      Owner: string }

module FieldHelpers =

    /// Returns true if the field is a layout-only field (no data stored).
    let isLayoutField (f: Field) =
        match f.Fieldtype with
        | "Section Break"
        | "Column Break"
        | "Tab Break" -> true
        | _ -> false

    /// Returns true if the field is a Table type (child table reference).
    let isTableField (f: Field) = f.Fieldtype = "Table"

    /// Returns the SQLite column type for this field.
    let sqlType (f: Field) =
        match f.Fieldtype with
        | "Check"
        | "Int" -> "INTEGER"
        | _ -> "TEXT"

    /// Returns only the fields that store data (excludes layout and table fields).
    let dataFields (dt: DocType) =
        dt.Fields
        |> List.filter (fun f -> not (isLayoutField f) && not (isTableField f))

    /// Returns only the Table fields (child table references).
    let tableFields (dt: DocType) =
        dt.Fields |> List.filter isTableField

    /// Returns the table name for a DocType (Frappe convention: "tab" + name).
    let tableName (dt: DocType) = "tab" + dt.Name
