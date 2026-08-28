namespace TrayApp.Kiro

open System
open System.Diagnostics
open System.Threading.Tasks

/// Client for invoking kiro-cli subprocess.
module KiroClient =

    /// Default path for kiro-cli executable.
    let private defaultKiroPath = @"C:\ikuku\kiro-cli.exe"

    /// Invokes kiro-cli with the given prompt and returns the output.
    let chat (prompt: string) : Result<string, string> =
        try
            let kiroPath =
                match Environment.GetEnvironmentVariable("KIRO_CLI_PATH") with
                | null | "" -> defaultKiroPath
                | path -> path

            let psi = ProcessStartInfo()
            psi.FileName <- kiroPath
            psi.Arguments <- sprintf "chat \"%s\"" (prompt.Replace("\"", "\\\""))
            psi.UseShellExecute <- false
            psi.RedirectStandardOutput <- true
            psi.RedirectStandardError <- true
            psi.CreateNoWindow <- true

            use proc = Process.Start(psi)
            let output = proc.StandardOutput.ReadToEnd()
            let errorOutput = proc.StandardError.ReadToEnd()
            proc.WaitForExit(30000) |> ignore

            if proc.ExitCode = 0 then
                Ok(output.TrimEnd())
            else
                Error(sprintf "kiro-cli exited with code %d: %s" proc.ExitCode errorOutput)
        with ex ->
            Error(sprintf "Failed to invoke kiro-cli: %s" ex.Message)

    /// Invokes kiro-cli asynchronously.
    let chatAsync (prompt: string) : Task<Result<string, string>> =
        Task.Run(fun () -> chat prompt)

    /// Check if kiro-cli is available.
    let isAvailable () : bool =
        let kiroPath =
            match Environment.GetEnvironmentVariable("KIRO_CLI_PATH") with
            | null | "" -> defaultKiroPath
            | path -> path

        IO.File.Exists(kiroPath)
