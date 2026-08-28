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

    /// Apply a remote change to the local database.
    /// Uses last-write-wins: if remote timestamp is newer, apply the change.
    member _.ApplyRemoteChange(msg: SyncMessage) : bool =
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
                    // Document doesn't exist locally, create it
                    let doc = Document()

                    if msg.Data <> null then
                        for kv in msg.Data do
                            doc[kv.Key] <- kv.Value

                    doc["name"] <- msg.Name
                    Database.create conn dt doc |> ignore
                    true
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

    /// Start the sync engine - subscribes to incoming messages.
    member this.Start() =
        pubsub.MessageReceived.Add(fun msg ->
            this.ApplyRemoteChange(msg) |> ignore
            lastSyncTimestamp <- msg.Timestamp)

    /// Update the last sync timestamp.
    member _.UpdateTimestamp(timestamp: string) = lastSyncTimestamp <- timestamp
