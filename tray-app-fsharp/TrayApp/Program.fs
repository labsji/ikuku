namespace TrayApp

open System
open System.Diagnostics
open System.Net.Http
open System.Threading
open System.Threading.Tasks
open System.Windows.Forms
open TrayApp.DocType
open TrayApp.Sync

/// Application state matching the existing Go tray app.
type AppState =
    | Installing
    | Ready
    | Active
    | Errored

module Program =

    let private healthUrl = "http://localhost:8000/api/method/frappe.ping"
    let private remoteWikiUrl = "http://localhost:8080/api/method/ping"
    let private healthInterval = TimeSpan.FromSeconds(60.0)

    let mutable private currentState = Installing
    let mutable private notifyIcon: NotifyIcon option = None
    let mutable private statusMenuItem: ToolStripMenuItem option = None
    let mutable private cts = new CancellationTokenSource()

    /// Determine current state based on environment.
    let determineState () =
        // Check if status file exists (mirrors Go logic)
        let statusFile = @"C:\ikuku\status.txt"

        try
            if IO.File.Exists(statusFile) then
                let status = IO.File.ReadAllText(statusFile).Trim()

                match status with
                | "installing" -> Installing
                | "ready" -> Ready
                | "active" -> Active
                | "error" -> Errored
                | _ -> Installing
            else
                Installing
        with _ ->
            Installing

    /// Update the status display text.
    let private statusText (state: AppState) =
        match state with
        | Installing -> "Status: Installing..."
        | Ready -> "Status: Ready"
        | Active -> "Status: Running"
        | Errored -> "Status: Error"

    /// Update menu item states based on current state.
    let private updateMenuState
        (mStatus: ToolStripMenuItem)
        (mOpenWiki: ToolStripMenuItem)
        (mTalkKiro: ToolStripMenuItem)
        (mRestart: ToolStripMenuItem)
        =
        mStatus.Text <- statusText currentState

        match currentState with
        | Installing ->
            mOpenWiki.Enabled <- false
            mTalkKiro.Enabled <- false
            mRestart.Enabled <- false
        | Ready ->
            mOpenWiki.Enabled <- false
            mTalkKiro.Enabled <- false
            mRestart.Enabled <- false
        | Active ->
            mOpenWiki.Enabled <- true
            mTalkKiro.Enabled <- true
            mRestart.Enabled <- true
        | Errored ->
            mOpenWiki.Enabled <- false
            mTalkKiro.Enabled <- false
            mRestart.Enabled <- true

    /// Health check loop that polls localhost:8000 and remote wiki server.
    let private healthCheckLoop (ct: CancellationToken) =
        task {
            use client = new HttpClient()
            client.Timeout <- TimeSpan.FromSeconds(10.0)

            while not ct.IsCancellationRequested do
                try
                    do! Task.Delay(healthInterval, ct)

                    if currentState = Active || currentState = Errored then
                        try
                            let! resp = client.GetAsync(healthUrl, ct)

                            if resp.IsSuccessStatusCode then
                                if currentState = Errored then
                                    currentState <- Active
                            else
                                currentState <- Errored
                        with _ ->
                            currentState <- Errored

                        // Also check remote wiki server
                        try
                            let! _ = client.GetAsync(remoteWikiUrl, ct)
                            ()
                        with _ ->
                            () // Remote failure is non-fatal
                with :? OperationCanceledException ->
                    ()
        }

    /// Open URL in default browser.
    let private openBrowser (url: string) =
        try
            Process.Start(ProcessStartInfo(url, UseShellExecute = true))
            |> ignore
        with _ ->
            ()

    /// Create the system tray icon and context menu.
    let private setupTray () =
        let icon = new NotifyIcon()
        icon.Text <- "ikuku - ERPNext"
        icon.Visible <- true

        // Create context menu
        let menu = new ContextMenuStrip()

        // Status (disabled, shows current state)
        let mStatus = new ToolStripMenuItem(statusText currentState)
        mStatus.Enabled <- false
        menu.Items.Add(mStatus) |> ignore

        menu.Items.Add(new ToolStripSeparator()) |> ignore

        // Open Wiki
        let mOpenWiki = new ToolStripMenuItem("Open Wiki")
        mOpenWiki.Click.Add(fun _ -> openBrowser "http://localhost:8000/wiki")
        menu.Items.Add(mOpenWiki) |> ignore

        // Talk to Kiro
        let mTalkKiro = new ToolStripMenuItem("Talk to Kiro")

        mTalkKiro.Click.Add(fun _ ->
            match Kiro.KiroClient.chat "hello" with
            | Ok _ -> ()
            | Error _ -> ())

        menu.Items.Add(mTalkKiro) |> ignore

        // Restart
        let mRestart = new ToolStripMenuItem("Restart")

        mRestart.Click.Add(fun _ ->
            try
                Process
                    .Start(ProcessStartInfo("wsl.exe", "-u root -- bash -c \"cd /opt/ikuku; podman-compose restart\"", UseShellExecute = false, CreateNoWindow = true))
                |> ignore
            with _ ->
                ())

        menu.Items.Add(mRestart) |> ignore

        menu.Items.Add(new ToolStripSeparator()) |> ignore

        // Exit
        let mExit = new ToolStripMenuItem("Exit")

        mExit.Click.Add(fun _ ->
            cts.Cancel()
            icon.Visible <- false
            Application.Exit())

        menu.Items.Add(mExit) |> ignore

        icon.ContextMenuStrip <- menu
        notifyIcon <- Some icon
        statusMenuItem <- Some mStatus

        // Set initial menu state
        updateMenuState mStatus mOpenWiki mTalkKiro mRestart

        // Start health check
        healthCheckLoop cts.Token |> ignore

        icon

    [<EntryPoint>]
    [<STAThread>]
    let main _argv =
        // Determine initial state
        currentState <- determineState ()

        // Load doctypes
        let doctypePath =
            IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "doctypes")

        let _doctypes = Parser.loadFromDirectory doctypePath

        // Setup tray
        Application.EnableVisualStyles()
        Application.SetCompatibleTextRenderingDefault(false)

        let _icon = setupTray ()

        // Run the application message loop
        Application.Run()
        0
