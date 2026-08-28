namespace TrayApp.Sync

open System
open System.Collections.Generic
open System.Threading
open System.Threading.Tasks
open TrayApp.DocType

/// 2-way sync engine with last-write-wins conflict resolution.
type SyncEngine(pubsub: PubSubClient, conn: Microsoft.Data.Sqlite.SqliteConnection, doctypes: DocType list) =
    let mutable lastSyncTimestamp = DateTime.MinValue.ToString("yyyy-MM-ddTHH:mm:ssZ")
    let doctypeMap = doctypes |> List.map (fun dt -> dt.Name, dt) |> dict

    /// Gets or sets the last sync timestamp.
    member _.LastSyncTimestamp
        with get () = lastSyncTimestamp
        and set v = lastSyncTimestamp <- v

    /// Check whether a document has all required fields populated.
    member private _.HasRequiredFields (dt: DocType) (doc: Document) : bool =
        let requiredFields =
            FieldHelpers.dataFields dt
            |> List.filter (fun f -> f.Reqd = 1)

        requiredFields
        |> List.forall (fun f ->
            doc.ContainsKey(f.Fieldname)
            && doc[f.Fieldname] <> null
            && (string doc[f.Fieldname]) <> "")

    /// Apply a remote change to the local database.
    /// Uses last-write-wins: if remote timestamp is newer, apply the change.
    member this.ApplyRemoteChange(msg: SyncMessage) : bool =
        // Skip self-originated messages
        if not (String.IsNullOrEmpty(msg.Sender))
           && not (String.IsNullOrEmpty(pubsub.ClientId))
           && msg.Sender = pubsub.ClientId then
            false
        else

        match doctypeMap.TryGetValue(msg.DocType) with
        | false, _ -> false
        | true, dt ->
            match msg.Action with
            | "create" ->
                let doc = Document()

                if msg.Data <> null then
                    for kv in msg.Data do
                        doc[kv.Key] <- kv.Value

                doc["name"] <- msg.Name
                Database.create conn dt doc |> ignore
                true
            | "update" ->
                // Last-write-wins: check if remote timestamp is newer
                match Database.read conn dt msg.Name with
                | None ->
                    // Document doesn't exist locally - only create from update
                    // if we have all required fields to avoid incomplete records.
                    let doc = Document()

                    if msg.Data <> null then
                        for kv in msg.Data do
                            doc[kv.Key] <- kv.Value

                    doc["name"] <- msg.Name

                    if this.HasRequiredFields dt doc then
                        Database.create conn dt doc |> ignore
                        true
                    else
                        // Skip: partial update data lacks required fields
                        false
                | Some existingDoc ->
                    let localModified =
                        if existingDoc.ContainsKey("modified") && existingDoc["modified"] <> null then
                            string existingDoc["modified"]
                        else
                            ""

                    // Compare timestamps - remote wins if newer or equal
                    if String.Compare(msg.Timestamp, localModified, StringComparison.Ordinal) >= 0 then
                        let updates = Document()

                        if msg.Data <> null then
                            for kv in msg.Data do
                                updates[kv.Key] <- kv.Value

                        Database.update conn dt msg.Name updates |> ignore
                        true
                    else
                        false // Local is newer, skip
            | "delete" ->
                Database.delete conn dt msg.Name |> ignore
                true
            | _ -> false

    /// Create a SyncMessage for a local change to push to remote.
    member _.CreateLocalChange(action: string, dt: DocType, name: string, data: Document) : SyncMessage =
        let msgData = Dictionary<string, obj>()

        if data <> null then
            for kv in data do
                if kv.Key <> "name" then
                    msgData[kv.Key] <- kv.Value

        SyncMessage.create action dt.Name name msgData

    /// Push a local change to the remote server.
    member _.PushLocalChangeAsync(action: string, dt: DocType, name: string, data: Document, ct: CancellationToken) =
        task {
            let msg = SyncMessage.create action dt.Name name (Dictionary<string, obj>())

            if data <> null then
                for kv in data do
                    if kv.Key <> "name" then
                        msg.Data[kv.Key] <- kv.Value

            do! pubsub.SendAsync(msg, ct)
        }

    /// Perform catch-up by fetching missed sync log entries from the server.
    member this.CatchUpAsync(ct: CancellationToken) =
        task {
            let! missedMessages = pubsub.FetchSyncLogAsync(lastSyncTimestamp, ct)

            for msg in missedMessages do
                this.ApplyRemoteChange(msg) |> ignore

                if not (String.IsNullOrEmpty(msg.Timestamp)) then
                    lastSyncTimestamp <- msg.Timestamp
        }

    /// Start the sync engine - subscribes to incoming messages.
    member this.Start() =
        pubsub.MessageReceived.Add(fun msg ->
            this.ApplyRemoteChange(msg) |> ignore
            lastSyncTimestamp <- msg.Timestamp)

        // Perform catch-up after reconnection.
        pubsub.ConnectionStateChanged.Add(fun connected ->
            if connected then
                this.CatchUpAsync(CancellationToken.None)
                |> Async.AwaitTask
                |> Async.Start)

    /// Update the last sync timestamp.
    member _.UpdateTimestamp(timestamp: string) = lastSyncTimestamp <- timestamp
