namespace TrayApp.DocType

open System
open System.Collections.Generic
open Microsoft.Data.Sqlite

/// Represents a generic document as a dictionary of field names to values.
type Document = Dictionary<string, obj>

module Database =

    /// Standard columns added to every non-singleton doctype table.
    let private standardColumns =
        [ "\"name\" TEXT PRIMARY KEY"
          "\"creation\" TEXT"
          "\"modified\" TEXT"
          "\"modified_by\" TEXT"
          "\"owner\" TEXT"
          "\"docstatus\" INTEGER DEFAULT 0" ]

    /// Additional columns for child table (istable=1) doctypes.
    let private childColumns =
        [ "\"parent\" TEXT"
          "\"parentfield\" TEXT"
          "\"parenttype\" TEXT"
          "\"idx\" INTEGER" ]

    /// Standard column names.
    let private standardColumnNames =
        [ "name"; "creation"; "modified"; "modified_by"; "owner"; "docstatus" ]

    /// Child column names.
    let private childColumnNames = [ "parent"; "parentfield"; "parenttype"; "idx" ]

    /// Quote a default value appropriately for SQL.
    let private quoteDefault (value: string) (sqlType: string) =
        if sqlType = "INTEGER" then
            value
        else
            let escaped = value.Replace("'", "''")
            sprintf "'%s'" escaped

    /// Sanitize a string for use in identifier names (removes spaces).
    let private sanitize (s: string) = s.Replace(" ", "_")

    /// Generate a random name (10 hex chars).
    let private generateName () =
        let bytes = Array.zeroCreate<byte> 5
        use rng = System.Security.Cryptography.RandomNumberGenerator.Create()
        rng.GetBytes(bytes)
        BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant()

    /// Current timestamp in ISO format.
    let private nowISO () =
        DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm:ss.ffffff")

    /// Opens or creates a SQLite database at the given path.
    let openDatabase (path: string) : SqliteConnection =
        let connStr = sprintf "Data Source=%s" path
        let conn = new SqliteConnection(connStr)
        conn.Open()
        conn

    /// Opens an in-memory SQLite database (useful for testing).
    let openInMemory () : SqliteConnection =
        let conn = new SqliteConnection("Data Source=:memory:")
        conn.Open()
        conn

    /// Ensures the tabSingles table exists.
    let ensureSinglesTable (conn: SqliteConnection) =
        use cmd = conn.CreateCommand()

        cmd.CommandText <-
            """CREATE TABLE IF NOT EXISTS "tabSingles" (
                "doctype" TEXT,
                "field" TEXT,
                "value" TEXT,
                PRIMARY KEY ("doctype", "field")
            )"""

        cmd.ExecuteNonQuery() |> ignore

    /// Migrate creates or updates the table for a DocType.
    let migrate (conn: SqliteConnection) (dt: DocType) =
        if dt.IsSingle = 1 then
            ensureSinglesTable conn
        else
            let tblName = FieldHelpers.tableName dt

            let columns =
                [ yield! standardColumns

                  if dt.IsTable = 1 then
                      yield! childColumns

                  for f in FieldHelpers.dataFields dt do
                      let col = sprintf "\"%s\" %s" f.Fieldname (FieldHelpers.sqlType f)

                      let col =
                          if String.IsNullOrEmpty(f.Default) then
                              col
                          else
                              sprintf "%s DEFAULT %s" col (quoteDefault f.Default (FieldHelpers.sqlType f))

                      yield col ]

            let createSql =
                sprintf "CREATE TABLE IF NOT EXISTS \"%s\" (%s)" tblName (String.Join(", ", columns))

            use cmd = conn.CreateCommand()
            cmd.CommandText <- createSql
            cmd.ExecuteNonQuery() |> ignore

            // Create unique indexes
            for f in FieldHelpers.dataFields dt do
                if f.Unique = 1 then
                    let idxName = sprintf "idx_%s_%s_unique" (sanitize tblName) f.Fieldname

                    let idxSql =
                        sprintf "CREATE UNIQUE INDEX IF NOT EXISTS \"%s\" ON \"%s\" (\"%s\")" idxName tblName f.Fieldname

                    use idxCmd = conn.CreateCommand()
                    idxCmd.CommandText <- idxSql
                    idxCmd.ExecuteNonQuery() |> ignore

    /// Migrate all DocTypes.
    let migrateAll (conn: SqliteConnection) (doctypes: DocType list) =
        ensureSinglesTable conn

        for dt in doctypes do
            migrate conn dt

    /// Create a new document. Returns the generated name.
    let create (conn: SqliteConnection) (dt: DocType) (doc: Document) : string =
        if dt.IsSingle = 1 then
            ensureSinglesTable conn

            for kv in doc do
                use cmd = conn.CreateCommand()

                cmd.CommandText <-
                    """INSERT OR REPLACE INTO "tabSingles" ("doctype", "field", "value") VALUES (@doctype, @field, @value)"""

                cmd.Parameters.AddWithValue("@doctype", dt.Name) |> ignore
                cmd.Parameters.AddWithValue("@field", kv.Key) |> ignore

                cmd.Parameters.AddWithValue("@value", (if kv.Value = null then "" else string kv.Value))
                |> ignore

                cmd.ExecuteNonQuery() |> ignore

            dt.Name
        else
            let tblName = FieldHelpers.tableName dt

            // Generate name if not provided
            let name =
                if doc.ContainsKey("name") && doc["name"] <> null && string doc["name"] <> "" then
                    string doc["name"]
                else
                    let generated = generateName ()
                    doc["name"] <- generated
                    generated

            // Set standard fields
            let now = nowISO ()

            if not (doc.ContainsKey("creation")) then
                doc["creation"] <- now

            if not (doc.ContainsKey("modified")) then
                doc["modified"] <- now

            if not (doc.ContainsKey("owner")) then
                doc["owner"] <- "Administrator"

            if not (doc.ContainsKey("modified_by")) then
                doc["modified_by"] <- "Administrator"

            // Build column list
            let allCols =
                [ yield! standardColumnNames

                  if dt.IsTable = 1 then
                      yield! childColumnNames

                  for f in FieldHelpers.dataFields dt do
                      yield f.Fieldname ]

            let quotedCols = allCols |> List.map (sprintf "\"%s\"")
            let placeholders = allCols |> List.map (fun c -> sprintf "@%s" (c.Replace(" ", "_")))

            let insertSql =
                sprintf
                    "INSERT INTO \"%s\" (%s) VALUES (%s)"
                    tblName
                    (String.Join(", ", quotedCols))
                    (String.Join(", ", placeholders))

            use cmd = conn.CreateCommand()
            cmd.CommandText <- insertSql

            for i in 0 .. allCols.Length - 1 do
                let col = allCols[i]
                let paramName = placeholders[i]

                let value =
                    if doc.ContainsKey(col) && doc[col] <> null then
                        doc[col]
                    else
                        box DBNull.Value

                cmd.Parameters.AddWithValue(paramName, value) |> ignore

            cmd.ExecuteNonQuery() |> ignore
            name

    /// Read a document by name.
    let read (conn: SqliteConnection) (dt: DocType) (name: string) : Document option =
        if dt.IsSingle = 1 then
            ensureSinglesTable conn
            use cmd = conn.CreateCommand()
            cmd.CommandText <- """SELECT "field", "value" FROM "tabSingles" WHERE "doctype" = @doctype"""
            cmd.Parameters.AddWithValue("@doctype", dt.Name) |> ignore
            use reader = cmd.ExecuteReader()
            let doc = Document()

            while reader.Read() do
                let field = reader.GetString(0)
                let value = reader.GetString(1)
                doc[field] <- value

            if doc.Count > 0 then Some doc else None
        else
            let tblName = FieldHelpers.tableName dt
            use cmd = conn.CreateCommand()
            cmd.CommandText <- sprintf "SELECT * FROM \"%s\" WHERE \"name\" = @name" tblName
            cmd.Parameters.AddWithValue("@name", name) |> ignore
            use reader = cmd.ExecuteReader()

            if reader.Read() then
                let doc = Document()

                for i in 0 .. reader.FieldCount - 1 do
                    let colName = reader.GetName(i)

                    let value =
                        if reader.IsDBNull(i) then
                            null
                        else
                            reader.GetValue(i)

                    doc[colName] <- value

                Some doc
            else
                None

    /// Update a document by name.
    let update (conn: SqliteConnection) (dt: DocType) (name: string) (updates: Document) : bool =
        if dt.IsSingle = 1 then
            for kv in updates do
                use cmd = conn.CreateCommand()

                cmd.CommandText <-
                    """INSERT OR REPLACE INTO "tabSingles" ("doctype", "field", "value") VALUES (@doctype, @field, @value)"""

                cmd.Parameters.AddWithValue("@doctype", dt.Name) |> ignore
                cmd.Parameters.AddWithValue("@field", kv.Key) |> ignore

                cmd.Parameters.AddWithValue("@value", (if kv.Value = null then "" else string kv.Value))
                |> ignore

                cmd.ExecuteNonQuery() |> ignore

            true
        else
            let tblName = FieldHelpers.tableName dt
            updates["modified"] <- nowISO ()

            // Only update data fields and modified/modified_by
            let allowedFields =
                set
                    [ for f in FieldHelpers.dataFields dt do
                          yield f.Fieldname

                      yield "modified"
                      yield "modified_by" ]

            let setClauses =
                updates
                |> Seq.filter (fun kv -> kv.Key <> "name" && allowedFields.Contains(kv.Key))
                |> Seq.toList

            if setClauses.IsEmpty then
                true
            else
                let setStr =
                    setClauses
                    |> List.mapi (fun i kv -> sprintf "\"%s\" = @p%d" kv.Key i)
                    |> String.concat ", "

                let sql = sprintf "UPDATE \"%s\" SET %s WHERE \"name\" = @name" tblName setStr
                use cmd = conn.CreateCommand()
                cmd.CommandText <- sql

                for i in 0 .. setClauses.Length - 1 do
                    let value =
                        if setClauses[i].Value = null then
                            box DBNull.Value
                        else
                            setClauses[i].Value

                    cmd.Parameters.AddWithValue(sprintf "@p%d" i, value) |> ignore

                cmd.Parameters.AddWithValue("@name", name) |> ignore
                let affected = cmd.ExecuteNonQuery()
                affected > 0

    /// Delete a document by name.
    let delete (conn: SqliteConnection) (dt: DocType) (name: string) : bool =
        if dt.IsSingle = 1 then
            use cmd = conn.CreateCommand()
            cmd.CommandText <- """DELETE FROM "tabSingles" WHERE "doctype" = @doctype"""
            cmd.Parameters.AddWithValue("@doctype", dt.Name) |> ignore
            cmd.ExecuteNonQuery() > 0
        else
            let tblName = FieldHelpers.tableName dt
            use cmd = conn.CreateCommand()
            cmd.CommandText <- sprintf "DELETE FROM \"%s\" WHERE \"name\" = @name" tblName
            cmd.Parameters.AddWithValue("@name", name) |> ignore
            let affected = cmd.ExecuteNonQuery()
            affected > 0

    /// List all documents for a DocType.
    let list (conn: SqliteConnection) (dt: DocType) : Document list =
        if dt.IsSingle = 1 then
            match read conn dt "" with
            | Some doc -> [ doc ]
            | None -> []
        else
            let tblName = FieldHelpers.tableName dt
            use cmd = conn.CreateCommand()
            cmd.CommandText <- sprintf "SELECT * FROM \"%s\"" tblName
            use reader = cmd.ExecuteReader()
            let results = ResizeArray<Document>()

            while reader.Read() do
                let doc = Document()

                for i in 0 .. reader.FieldCount - 1 do
                    let colName = reader.GetName(i)

                    let value =
                        if reader.IsDBNull(i) then
                            null
                        else
                            reader.GetValue(i)

                    doc[colName] <- value

                results.Add(doc)

            results |> Seq.toList
