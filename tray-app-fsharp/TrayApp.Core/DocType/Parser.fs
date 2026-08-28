namespace TrayApp.DocType

open System
open System.IO
open System.Text.Json

module Parser =

    let private jsonOptions =
        let opts = JsonSerializerOptions()
        opts.PropertyNameCaseInsensitive <- true
        opts.PropertyNamingPolicy <- JsonNamingPolicy.CamelCase
        opts

    /// Parses a single DocType JSON string into a DocType record.
    let parseDocType (json: string) : Result<DocType, string> =
        try
            let dt = JsonSerializer.Deserialize<DocType>(json, jsonOptions)

            if String.IsNullOrWhiteSpace(dt.Name) then
                Error "DocType parse error: missing 'name' field"
            else
                // Ensure null lists are replaced with empty lists
                let dt =
                    { dt with
                        Fields = if obj.ReferenceEquals(dt.Fields, null) then [] else dt.Fields
                        FieldOrder =
                            if obj.ReferenceEquals(dt.FieldOrder, null) then
                                []
                            else
                                dt.FieldOrder
                        Permissions =
                            if obj.ReferenceEquals(dt.Permissions, null) then
                                []
                            else
                                dt.Permissions }

                Ok dt
        with ex ->
            Error(sprintf "DocType parse error: %s" ex.Message)

    /// Parses a DocType JSON file from disk.
    let parseFromFile (path: string) : Result<DocType, string> =
        try
            let json = File.ReadAllText(path)
            parseDocType json
        with ex ->
            Error(sprintf "Read doctype file %s: %s" path ex.Message)

    /// Loads all DocType JSON files from a directory (recursively).
    let loadFromDirectory (path: string) : DocType list =
        if not (Directory.Exists(path)) then
            []
        else
            Directory.GetFiles(path, "*.json", SearchOption.AllDirectories)
            |> Array.choose (fun file ->
                match parseFromFile file with
                | Ok dt -> Some dt
                | Error _ -> None)
            |> Array.toList
