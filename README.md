# PSLocalSession

`New-LocalPSSession` is a "su" for PowerShell: it starts `pwsh.exe` as another local
account, connects a runspace to it over a local named pipe, and returns a normal
`PSSession`.

```powershell
$cred = Get-Credential 'CONTOSO\alice'
$session = New-LocalPSSession -Credential $cred -Name Alice

Invoke-Command -Session $session -ScriptBlock { whoami; $PSVersionTable.PSVersion }
Enter-PSSession -Session $session
Remove-PSSession -Session $session
```

The returned object is a real `PSSession` (`Transport = NamedPipe`). It appears in
`Get-PSSession`, works with `Invoke-Command`, `Enter-PSSession`, `Copy-Item -ToSession`,
and the other session cmdlets, and is removed with `Remove-PSSession`.

## Requirements

- Windows.
- PowerShell 7.6 or later, both in the calling session and at the target executable.
- A target account with a password (`-Credential`). Passwordless accounts (gMSAs,
  virtual/service accounts) are not supported yet. The user name can be `DOMAIN\user`,
  `MACHINE\user`, a UPN, or `.\user` to force a local account.
- The target must be able to read and execute the chosen `pwsh.exe`.
- Logon rights depend on the launch path:
  - **Elevated caller** starts the target through a temporary scheduled task, which is
    a *batch* logon. The account needs **Log on as a batch job**.
  - **Non-elevated caller** uses `CreateProcessWithLogonW`, which is an *interactive*
    logon. The account needs **Log on locally**, and the Secondary Logon service must be
    enabled.

`-CurrentUser` is a diagnostic/testing mode that starts a session as the caller without
using a password or a second account.

## Parameters

| Parameter | Meaning |
|---|---|
| `-Credential` | Account to run the target session as. |
| `-CurrentUser` | Run as the current user instead of a supplied credential. |
| `-Name` | Friendly name for the returned `PSSession`. |
| `-NoProfile` | Start the target with `-NoProfile`. |
| `-PowerShellPath` | `pwsh.exe` to use. Defaults to `$PSHOME\pwsh.exe`. |
| `-StartupTimeoutSeconds` | How long to wait for the target to become ready (default 30). |

The returned session also carries diagnostic note properties:

- `LocalPSSessionProcessId`
- `LocalPSSessionUserName`
- `LocalPSSessionPipeName`
- `LocalPSSessionLaunchMethod` (`CurrentUser`, `CreateProcessWithLogon`, or `ScheduledTask`)

## How it works

1. The caller chooses a random names for two local named pipes: a short-lived startup
   control pipe and the session pipe.
2. A target `pwsh.exe` is started:
   - directly for `-CurrentUser`;
   - through a temporary scheduled task for an elevated caller (batch logon);
   - through `CreateProcessWithLogonW` for a non-elevated caller (interactive logon).
3. The target runs a self-contained bootstrap. It creates the session pipe with an
   explicit DACL granting full control to the target account and the caller, then starts
   the same internal PSRP server that `pwsh -CustomPipeName` uses.
4. The target writes `OK <pid>` (or `ERROR <message>`) to the control pipe.
5. The caller opens the session pipe with `NamedPipeConnectionInfo`, wraps the remote
   runspace with `[System.Management.Automation.Runspaces.PSSession]::Create`, and returns
   it.
6. When the `PSSession` is removed, or the calling PowerShell process exits, the pipe
   disconnects and the target process exits by itself.

### Why not `pwsh -CustomPipeName`?

`-CustomPipeName` would work for an elevated caller (or a session as the current user),
because PowerShell's pipe DACL includes the target user and `BUILTIN\Administrators`.
For a non-elevated caller that started the target as *another* user, the caller is in
neither group.

The server handle itself lacks `WRITE_DAC`. `ReOpenFile` can return a second handle with
`WRITE_DAC` to the same pipe instance while it is idle, but `ConsoleHost` begins waiting
in `ConnectNamedPipe` during startup; by the time the bootstrap runs, `ReOpenFile` fails
with `ERROR_PIPE_BUSY` (231). Opening `\\.\pipe\name` instead creates a client connection
and consumes the single server instance. This module therefore creates the pipe itself
with the right DACL, then starts the same internal PSRP server that `-CustomPipeName`
uses. That is version-sensitive by design: the module targets PowerShell 7.6.

## Security notes

- The session pipe is local-only and its DACL contains only the target account and the
  caller. No network listener is created.
- The non-elevated path never puts the password on a command line; `ProcessStartInfo`
  carries it as a `SecureString`.
- The elevated path must give Task Scheduler a plaintext password for the duration of
  task registration. The task is unregistered as soon as the target process reports
  readiness, and stale `session-*` tasks older than ten minutes are swept before the next
  scheduled-task launch. If the caller is killed at exactly the wrong moment, a task can
  remain and hold the stored credential; the warning/cleanup path reports its name.
- The target process is launched with `-NonInteractive`. Target profiles still load unless
  `-NoProfile` is used, but profile prompts fail rather than consume the bootstrap stream.

## Limitations

- Windows only; PowerShell 7.6+ only.
- No gMSA, `NT SERVICE\*`, virtual, or other passwordless accounts yet.
- No reconnect after a session is disconnected; create a new session instead.
- The target process must allow `Add-Type`; the bootstrap compiles a small C# helper
  in-process. Constrained Language Mode, AppLocker/WDAC, or a read-only target TEMP can
  block that.
- The named-pipe server uses PowerShell's internal remoting types, so a future PowerShell
  version that changes them needs a module update.
- Loading the target profile can run arbitrary code as the target, exactly like starting a
  shell as that user. Use `-NoProfile` for a deterministic environment.

## Development and testing

```powershell
Import-Module Pester -MinimumVersion 6.0
Invoke-Pester ./tests -Output Detailed
```

The suite covers:

- the public surface and command-line quoting;
- current-user sessions end to end (real process, real pipe, real PSSession);
- concurrent sessions and process cleanup;
- the scheduled-task plumbing (registered with an interactive token, so no second
  account is needed);
- basic error cases.

The scheduled-task test needs an interactive logged-on session and permission to
register a task for the current user. On a headless agent, exclude the `ScheduledTask`
tag.

The only path the automated suite cannot cover is a *different* account's password. Run
this in both an elevated and a non-elevated PowerShell window to exercise the two launch
paths:

```powershell
./tools/Test-LocalPSSessionAnotherUser.ps1
```

### Verification notes

- On 2026-11-09 the full suite passed on Windows build 26300 with PowerShell 7.6.9.
- The non-elevated `CreateProcessWithLogonW` path was exercised end to end against a
  temporary local account: the target ran with the correct SID, loaded its own profile,
  could write to its own TEMP directory, and exited when the PSSession was removed. The
  temporary account and its profile were deleted afterwards.
- The scheduled-task path was exercised with an interactive-token task (registration,
  long encoded bootstrap, unregister-while-running, and disconnect cleanup). The
  stored-password / batch-logon variant shares that plumbing; the password-registration
  error path was also exercised.

## Layout

```text
PSLocalSession.psd1                 module manifest
PSLocalSession.psm1                 module implementation
tests/PSLocalSession.Tests.ps1      Pester 6 suite
tools/Test-LocalPSSessionAnotherUser.ps1
```
