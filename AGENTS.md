# AGENTS.md

## What this is

Windows-only PowerShell module. One public cmdlet, `New-LocalPSSession`, implemented in the
single file `PSLocalSession.psm1`. There is no build, lint, typecheck, or codegen step.

Read `README.md` for behavior and `docs/compatibility.md` before changing version checks,
the pipe ACL, or the target bootstrap. Compatibility is version-sensitive.

## Commands

```powershell
# Full suite (requires Pester 6; inbox Windows PowerShell Pester 3.4 is not enough)
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 6.0; Invoke-Pester ./tests -Output Detailed"

# One test / one area
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 6.0; Invoke-Pester ./tests -FullNameFilter '*stops the target process*' -Output Detailed"

# Headless agent: skip the task-scheduler test
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 6.0; Invoke-Pester ./tests -ExcludeTagFilter ScheduledTask -Output Detailed"

# Manual second-account test; run once elevated and once non-elevated
pwsh -NoProfile -File ./tools/Test-LocalPSSessionAnotherUser.ps1
```

The suite spawns real `pwsh` processes and real named pipes; there are no mocks for the
launch path. Use `-NoProfile` in tests and smoke runs; a target profile can hang startup.

`-CurrentUser` exists for local iteration and does **not** exercise the cross-user ACL or
logon paths. The scheduled-task test registers a task under the current user and needs an
interactive logged-on session.

## Architecture invariants

- Two pipes per session: a short-lived startup control pipe carrying `OK <pid>`/`ERROR
  <message>`, and the PSRP session pipe. The caller then opens `NamedPipeConnectionInfo`,
  `RunspaceFactory.CreateRunspace`, and wraps it with `PSSession.Create(..., $PSCmdlet)`.
- `$PSCmdlet` must be passed to `PSSession.Create`; that is what registers the session in
  `Get-PSSession`. Do not replace it with the internal constructor for PowerShell 7.6.
- The target bootstrap creates the session pipe itself with the explicit DACL before
  starting the listener. The embedded C# helper swaps the stream into
  `RemoteSessionNamedPipeServer` and starts the internal `NamedPipeProcessMediator.Run`.
- Both pipe DACLs contain only the target account and the caller. Do not broaden them to
  `Everyone`/`Authenticated Users` to work around access failures; fix the SID/ACL.
- Do **not** replace this with `pwsh -CustomPipeName`, `CreateCustomNamedPipeServer`, or
  `ReOpenFile`-then-`SetSecurityInfo`. `CustomPipeName` starts `ConnectNamedPipe` before
  the bootstrap runs, so `ReOpenFile` on its listening handle fails with
  `ERROR_PIPE_BUSY (231)`. Opening `\\.\pipe\name` is a client connection and consumes the
  single server instance. The current helper exists specifically to place the ACL before
  listening.
- Launch matrix is intentional:
  - elevated caller -> temporary scheduled task -> batch logon;
  - non-elevated caller -> `CreateProcessWithLogonW` -> interactive logon;
  - `-CurrentUser` -> direct child process.
- On the scheduled-task success path, unregister the task after the target reports
  `OK`, but do **not** call `Stop-ScheduledTask`; unregistering leaves the already-started
  process alive, and stopping it would kill the session.
- Direct/non-admin bootstrap delivery uses stdin:
  `[ScriptBlock]::Create([Console]::In.ReadToEnd()).Invoke()`. This is required because
  `CreateProcessWithLogonW` has a 1024-character command-line limit. Do not use
  `-Command -` (only the first stdin line is executed) and do not switch this path to
  `-EncodedCommand`. The scheduled-task path uses `-EncodedCommand`.
- The target exits when the PSRP pipe disconnects; that is the session lifecycle. Do not
  add a second shutdown mechanism or kill processes on the success path.
- The C# helper is `$script:CSharpSource` inside `PSLocalSession.psm1`, base64-inserted
  into the bootstrap and compiled by `Add-Type` **inside the target process**. There is
  no separate C# project; C# changes are only exercised by starting a real target.
- Keep the target bootstrap self-contained (stdin/encoded command). The target account
  may not be able to read the caller's module directory; do not replace it with
  `Import-Module`, a shared script, or a separate C# file.
- The helper depends on PowerShell 7.6 internals (`RemoteSessionNamedPipeServer`,
  `<Stream>k__BackingField`, `StartListening`, `NamedPipeProcessMediator.Run`). A
  PowerShell upgrade may require updating it; run the suite if touching it.
- Target accounts need a password. Passwordless/gMSA/virtual accounts are not supported.

## Testing traps

- Current-user tests can pass while cross-user ACLs are broken. Use the manual second-account
  script for ACL, profile, TEMP, and logon-right changes.
- The scheduled-task test leaves tasks under `\PSLocalSession\` if the process is killed;
  clean those by hand before rerunning.
- The suite reads local accounts and registers real scheduled tasks; avoid parallel runs.
- The scheduled-task test uses the test-only `-InteractiveToken` path. Production uses
  `-Credential` and a stored-password/batch logon; do not "simplify" the production path
  to the test path.
- When adding a test that creates a session, always remove it and wait for the target PID
  from `LocalPSSessionProcessId` to exit; otherwise later tests inherit live pipes/processes.

## Git commits

- AI-authored commits use an imperative subject, then a short body (1-3 sentences) for
  non-trivial changes explaining what changed and why. Omit the body for truly trivial
  changes; never restate the subject.
- End the message with a `Co-Authored-By` trailer naming the model and its version:
  `Co-Authored-By: <Model name and version> (<provider-id>/<model-id>) <noreply@localhost>`
  Use the real model identity reported by the current harness or model metadata. If the
  display name has no version, include the exact model ID (and a release date if useful);
  never invent a version. Use a provider/harness `noreply` address when one is known;
  `noreply@localhost` is the neutral fallback because the trailer is a record, not a
  deliverable mailbox. If no model identity is exposed at all, use
  `Co-Authored-By: AI assistant <noreply@localhost>` rather than guessing.
- One trailer per model that materially contributed, all at the end after a blank line.
  Human-authored commits are unaffected.
- Do not carry a model identity over from another session or harness. If you switch
  models, use the model that actually authored the commit.

### OpenCode-specific model discovery

The system prompt's `Your Model` block is authoritative under OpenCode: Name, Provider ID,
and Model ID. Current session example:

`Co-Authored-By: DeepSeek V4.1 Flash (opencode-go/deepseek-v4.1-flash) <noreply@opencode.ai>`

`OPENCODE_*` environment variables do not expose the model. `tools.opencode.models` can
confirm the display name and model ID. Other harnesses should use their equivalent model
metadata (system prompt, CLI, config, or model catalog); the general trailer rule above
still applies.

## Version compatibility

The manifest, `#Requires`, public cmdlet, and target bootstrap currently enforce
PowerShell 7.6+. Do not lower a guard casually: `docs/compatibility.md` contains measured
per-version failures, required patches, and the viable Windows PowerShell 5.1
default-IPC-server path. If you change a guard or an API used by the bootstrap, update
that document and rerun the relevant target-version checks.

Notable thresholds (details in `docs/compatibility.md`):

- `PipeOptions.FirstPipeInstance`: .NET 8 / PowerShell 7.4+.
- `NamedPipeServerStreamAcl`: .NET 5 / PowerShell 7.1+.
- Public `PSSession.Create`: PowerShell 7.3+.
- `NamedPipeConnectionInfo(string customPipeName)`: PowerShell 6.2+.
