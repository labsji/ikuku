namespace TrayApp.Sync

open System
open System.Net.WebSockets
open System.Text
open System.Text.Json
open System.Text.Json.Serialization
open System.Threading
open System.Threading.Tasks

/// Represents a document synchronization event matching the Go server format.
[<CLIMutable>]
type SyncMessage =
    { [<JsonPropertyName("action")>]
      Action: string
      [<JsonPropertyName("doctype")>]
      DocType: string
      [<JsonPropertyName("name")>]
      Name: string
      [<JsonPropertyName("data")>]
      Data: System.Collections.Generic.Dictionary<string, obj>
      [<JsonPropertyName("timestamp")>]
      Timestamp: string }

module SyncMessage =

    /// Creates a new SyncMessage with the current UTC timestamp.
    let create (action: string) (doctype: string) (name: string) (data: System.Collections.Generic.Dictionary<string, obj>) =
        { Action = action
          DocType = doctype
          Name = name
          Data = data
          Timestamp = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ") }

    /// Serializes a SyncMessage to JSON bytes.
    let serialize (msg: SyncMessage) : byte[] =
        let json = JsonSerializer.Serialize(msg)
        Encoding.UTF8.GetBytes(json)

    /// Deserializes JSON bytes into a SyncMessage.
    let deserialize (data: byte[]) : Result<SyncMessage, string> =
        try
            let json = Encoding.UTF8.GetString(data)
            let msg = JsonSerializer.Deserialize<SyncMessage>(json)
            Ok msg
        with ex ->
            Error(sprintf "Deserialize error: %s" ex.Message)

    /// Deserializes a JSON string into a SyncMessage.
    let deserializeString (json: string) : Result<SyncMessage, string> =
        try
            let msg = JsonSerializer.Deserialize<SyncMessage>(json)
            Ok msg
        with ex ->
            Error(sprintf "Deserialize error: %s" ex.Message)

/// WebSocket-based PubSub client for document synchronization.
type PubSubClient(serverUrl: string, token: string) =
    let mutable ws: ClientWebSocket option = None
    let mutable reconnectDelay = 1000 // Start with 1 second
    let maxReconnectDelay = 30000 // Max 30 seconds
    let messageReceived = Event<SyncMessage>()
    let connectionStateChanged = Event<bool>()

    /// Event fired when a sync message is received.
    [<CLIEvent>]
    member _.MessageReceived = messageReceived.Publish

    /// Event fired when connection state changes (true = connected, false = disconnected).
    [<CLIEvent>]
    member _.ConnectionStateChanged = connectionStateChanged.Publish

    /// Connect to the WebSocket server.
    member this.ConnectAsync(ct: CancellationToken) =
        task {
            let client = new ClientWebSocket()
            let uri = Uri(sprintf "%s/ws/sync?token=%s" serverUrl token)

            try
                do! client.ConnectAsync(uri, ct)
                ws <- Some client
                reconnectDelay <- 1000
                connectionStateChanged.Trigger(true)
            with ex ->
                connectionStateChanged.Trigger(false)
                raise ex
        }

    /// Send a sync message.
    member _.SendAsync(msg: SyncMessage, ct: CancellationToken) =
        task {
            match ws with
            | Some client when client.State = WebSocketState.Open ->
                let data = SyncMessage.serialize msg
                let segment = ArraySegment<byte>(data)
                do! client.SendAsync(segment, WebSocketMessageType.Text, true, ct)
            | _ -> ()
        }

    /// Receive loop - reads messages until cancelled or disconnected.
    member _.ReceiveLoopAsync(ct: CancellationToken) =
        task {
            match ws with
            | Some client ->
                let buffer = Array.zeroCreate<byte> (64 * 1024)

                try
                    while not ct.IsCancellationRequested && client.State = WebSocketState.Open do
                        let segment = ArraySegment<byte>(buffer)
                        let! result = client.ReceiveAsync(segment, ct)

                        if result.MessageType = WebSocketMessageType.Close then
                            connectionStateChanged.Trigger(false)
                        elif result.MessageType = WebSocketMessageType.Text then
                            let data = Array.sub buffer 0 result.Count

                            match SyncMessage.deserialize data with
                            | Ok msg -> messageReceived.Trigger(msg)
                            | Error _ -> ()
                with
                | :? OperationCanceledException -> ()
                | _ -> connectionStateChanged.Trigger(false)
            | None -> ()
        }

    /// Disconnect from the server.
    member _.DisconnectAsync(ct: CancellationToken) =
        task {
            match ws with
            | Some client when client.State = WebSocketState.Open ->
                try
                    do! client.CloseAsync(WebSocketCloseStatus.NormalClosure, "Closing", ct)
                with _ ->
                    ()

                client.Dispose()
                ws <- None
                connectionStateChanged.Trigger(false)
            | Some client ->
                client.Dispose()
                ws <- None
            | None -> ()
        }

    /// Attempt reconnection with exponential backoff.
    member this.ReconnectAsync(ct: CancellationToken) =
        task {
            do! Task.Delay(reconnectDelay, ct)
            reconnectDelay <- Math.Min(reconnectDelay * 2, maxReconnectDelay)

            try
                do! this.ConnectAsync(ct)
            with _ ->
                ()
        }

    /// Returns true if connected.
    member _.IsConnected =
        match ws with
        | Some client -> client.State = WebSocketState.Open
        | None -> false

    interface IDisposable with
        member _.Dispose() =
            match ws with
            | Some client ->
                client.Dispose()
                ws <- None
            | None -> ()
