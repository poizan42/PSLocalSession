# PSLocalSession

`New-LocalPSSession` is a "su" for PowerShell: it starts `pwsh.exe` or `powershell.exe`
as another local account, connects a runspace to it over a local named pipe, and returns a
normal `PSSession`.

```powershell
$cred = Get-Credential 'CONTOSO\alice'
$session = New-LocalPSSession -Credential $cred -Name Alice

Invoke-Command -Session $session -ScriptBlock { whoami; $PSVersionTable.PSVersion }
Enter-PSSession -Session $session
Remove-PSSession -Session $session
```

The returned object is a real `PSSession` (`Transport = NamedPipe` on 7.1+; 5.1 has no
`Transport` property). It appears in `Get-PSSession`, works with `Invoke-Command`,
`Enter-PSSession`, `Copy-Item -ToSession`, and the other session cmdlets, and is removed
with `Remove-PSSession`.

## Requirements

- Windows.
- Windows PowerShell 5.1 or PowerShell 7.1+, both in the calling session and at the
  target executable. PowerShell 7.0/6.2 are not supported.
- A target account with a password (`-Credential`). Passwordless accounts (gMSAs,
  virtual/service accounts) are not supported yet. The user name can be `DOMAIN\user`,
  `MACHINE\user`, a UPN, or `.\user` to force a local account.
- The target must be able to read and execute the chosen `pwsh.exe`/`powershell.exe`.
- For `-Credential` sessions, the target account must be able to read the module's
  `PSLocalSession.Bootstrap.ps1` and pipe-server `.cs` files. A module under the caller's
  profile is staged directly; for other paths the module checks the target's effective
  read/traverse rights with `GetEffectiveRightsFromAclW`. If needed, it copies those static
  files to `%ProgramData%\PSLocalSession-<guid>\` with a caller/target-only DACL.
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
| `-PowerShellPath` | Target executable. Defaults to `$PSHOME\pwsh.exe` on 7.1+, or `$PSHOME\powershell.exe` on 5.1. |
| `-RunLevel` | `Highest` (default) or `Limited` for the temporary scheduled task. Applies only when an elevated caller uses the scheduled-task path. |
| `-StartupTimeoutSeconds` | How long to wait for the target to become ready (default 30). |

The returned session also carries diagnostic note properties:

- `LocalPSSessionProcessId`
- `LocalPSSessionUserName`
- `LocalPSSessionConnectionMode` (`Custom` or `Default`)
- `LocalPSSessionPipeName` (the custom pipe name, or `<default IPC pipe>`)
- `LocalPSSessionRunLevel` (`Highest`, `Limited`, or `Inherited`)
- `LocalPSSessionLaunchMethod` (`CurrentUser`, `CreateProcessWithLogon`, or `ScheduledTask`)

## How it works

1. The caller creates a short-lived control pipe with an explicit DACL for the caller and
   target. In 7.1+ custom-pipe mode it also chooses a random session-pipe name.
2. If the target is another user, the caller stages a copy when the module is under its
   profile; otherwise it checks whether the target SID can read and traverse the module's
   bootstrap files. If needed, it copies the static script and C# pipe helpers to a unique
   directory under `%ProgramData%` with a caller/target-only DACL.
3. A target `pwsh.exe` (7.1+) or `powershell.exe` (5.1) is started:
   - directly for `-CurrentUser`;
   - through a temporary scheduled task for an elevated caller or `LocalSystem`
     (batch logon), using `Highest` by default and falling back to `Limited` if the
     caller cannot create a highest-privilege task;
   - through `CreateProcessWithLogonW` for a non-elevated caller (interactive logon).

   The command line contains `-File <bootstrap.ps1>` and the per-session arguments, never
   the script itself.
4. The target runs the static bootstrap:
   - it selects the 5.1 or 7.1+ `.cs` pipe helper at runtime;
   - 7.1+ with a 7.1+ caller creates a custom session pipe with the explicit DACL and
     starts the internal PSRP server;
   - 5.1, or any session involving a 5.1 caller, replaces the target's default IPC
     server with an ACL-adjusted clone using the same default AppDomain pipe name.
5. The target writes `OK <pid> Custom` or `OK <pid> Default` (or `ERROR <message>`) to
   the control pipe.
6. The caller opens the session pipe with `NamedPipeConnectionInfo`: the string constructor
   for `Custom`, the process-id constructor for `Default`. It creates the remote runspace
   with the caller host and a default type table, then wraps it in a `PSSession` using the
   public `PSSession.Create` on 7.3+, or the internal-constructor fallback on 5.1/7.1/7.2.
7. The temporary bootstrap copy is removed. When the `PSSession` is removed, or the
   calling PowerShell process exits, the pipe disconnects and the target process exits by
   itself.

### Token elevation

- `-CurrentUser` inherits the caller's token exactly: an elevated caller gives an elevated
  target, and a non-elevated caller gives a limited target.
- `-Credential` with an elevated caller or `LocalSystem` uses the scheduled-task path. The
  task is registered with `Highest` by default; if the caller is not allowed to create a
  highest-privilege task, it falls back to `Limited`. Use `-RunLevel Limited` to request
  limited explicitly.
- `-Credential` from a non-elevated caller uses an interactive logon. An ordinary
  administrator account gets a UAC-filtered token on that path, and there is no UAC prompt
  in a non-interactive session. The built-in `Administrator` account is the documented
  exception when `FilterAdministratorToken` is disabled.

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
uses. Calling `RemoteSessionNamedPipeServer.CreateCustomNamedPipeServer()` directly is
equivalent to `-CustomPipeName` - it uses the same default DACL and starts listening
before returning - so it has the same limitation.

Windows PowerShell 5.1 has no `-CustomPipeName` and no custom-pipe-name
`NamedPipeConnectionInfo` constructor. A custom AppDomain/pipe name also did not complete
the 5.1 PSRP handshake, so the 5.1 path instead clones the default IPC server with the
caller/target DACL and connects through the process-id constructor. The module supports
Windows PowerShell 5.1 and PowerShell 7.1+.

## Security notes

- The control and session pipes are local-only. Their DACLs contain only the target
  account and the caller. In the 5.1/default mode the target's default IPC server is
  replaced with an ACL-adjusted clone; the original inherited server is disposed. No
  network listener is created.
- The bootstrap is a static script and plain C# files shipped with the module, executed by
  path. When a target-readable copy is needed, the staging directory has a caller/target
  DACL and is removed after the target starts. Other users cannot read or modify it.
- The non-elevated path never puts the password on a command line; `ProcessStartInfo`
  carries it as a `SecureString`.
- The elevated path must give Task Scheduler a plaintext password for the duration of
  task registration. The task is unregistered as soon as the target process reports
  readiness, and stale `session-*` tasks older than ten minutes are swept before the next
  scheduled-task launch. If the caller is killed at exactly the wrong moment, a task can
  remain and hold the stored credential; the warning/cleanup path reports its name.
- The target process is launched with `-NonInteractive`. Target profiles still load unless
  `-NoProfile` is used, but profile prompts fail rather than consume startup input.

## Limitations

- Windows only; Windows PowerShell 5.1 or PowerShell 7.1+. PowerShell 7.0/6.2 are not
  supported; see `docs/compatibility.md`.
- No gMSA, `NT SERVICE\*`, virtual, or other passwordless accounts yet.
- A non-elevated, non-interactive caller cannot silently obtain a full administrator token
  for an ordinary administrator account. Run the caller elevated/`LocalSystem`, use the
  UAC credential prompt where available, or pre-provision a privileged task/service.
- `-RunLevel Highest` only has an effect when the caller uses the scheduled-task path.
  The non-elevated interactive path inherits the target's logon token.
- No reconnect after a session is disconnected; create a new session instead.
- The target process must allow `Add-Type`; the bootstrap compiles a small C# helper
  in-process. Constrained Language Mode, AppLocker/WDAC, and execution policy can block
  that. `-ExecutionPolicy Bypass` is passed, but Group Policy `AllSigned`/`Restricted`
  can still win over it.
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
- a Windows PowerShell 5.1 target through the default IPC pipe clone;
- concurrent sessions and process cleanup;
- the scheduled-task plumbing, including static bootstrap-file delivery;
- basic error cases.

The scheduled-task test needs an interactive logged-on session and permission to
register a task for the current user. On a headless agent, exclude the `ScheduledTask`
tag. The suite requires Pester 6 installed for the host; the inbox Windows PowerShell
Pester 3.4 is not enough. Use the manual 5.1 script below when testing from Windows
PowerShell 5.1 without Pester 6.

The automated suite does not cover a *different* account's password on either the 5.1 or
7.1+ path. Run the appropriate manual scripts in both elevated and non-elevated PowerShell
windows:

```powershell
./tools/Test-PowerShell51.ps1
./tools/Test-LocalPSSessionAnotherUser.ps1
```

### Verification notes

- On 2026-11-09 the full suite passed on Windows build 26300 with PowerShell 7.6.9.
- Target processes 7.1.7, 7.2.24, 7.3.12, 7.4.22, 7.5.9, and 7.6.9 were exercised with
  `-CurrentUser` from a 7.6.9 caller. Caller/target combinations across 7.1.7, 7.2.24, and
  7.6.9 also worked, including the 7.1/7.2 `PSSession` fallback.
- Windows PowerShell 5.1 target and caller combinations (5.1->5.1, 5.1->7.1/7.2/7.6,
  7.1/7.2/7.6->5.1) were exercised. The 5.1 scheduled-task path was exercised with both a
  5.1 and a 7.6 target. A cross-user matrix (5.1 caller->5.1 target, 7.6 caller->5.1
  target, and 7.6 caller->7.6 target) passed against a temporary local account. Because
  that module was under a user profile, the effective-rights check selected the staged
  copy; the staging directory was removed after each session.
- The non-elevated `CreateProcessWithLogonW` path was exercised end to end against a
  temporary local account: the target ran with the correct SID, loaded its own profile,
  could write to its own TEMP directory, and exited when the PSSession was removed. The
  temporary account and its profile were deleted afterwards.
- From an elevated caller, the default `-RunLevel Highest` scheduled-task path was
  exercised against a temporary administrator account. The target reported High integrity
  and `IsInRole(Administrator) = true`; the task and staging copy were removed.
- Interactive `Enter-PSSession` was exercised in a real console with `-NoProfile` on both
  sides. Commands such as `whoami` and `Get-Location` produced output after the remote
  runspace was created with a type table (without it, commands ran but output was dropped).
- The scheduled-task path was exercised with an interactive-token task (registration,
  static bootstrap-file delivery, unregister-while-running, and disconnect cleanup). The
  stored-password / batch-logon variant shares that plumbing; the password-registration
  error path was also exercised.

## Layout

```text
LICENSE                             MIT license
PSLocalSession.psd1                 module manifest
PSLocalSession.psm1                 module implementation
PSLocalSession.Bootstrap.ps1        target-side bootstrap
PSLocalSession.PipeServer.Core.cs   7.1+ pipe helper
PSLocalSession.PipeServer.Desktop.cs 5.1 pipe helper
PSLocalSession.AccessCheck.cs       caller-side effective-rights check
tests/PSLocalSession.Tests.ps1      Pester 6 suite
tools/Test-PowerShell51.ps1         manual 5.1 caller/target check
tools/Test-LocalPSSessionAnotherUser.ps1
```

## Author and license

Kasper Fabæch Brandt

Copyright (c) 2026 Kasper Fabæch Brandt

Released under the [MIT License](LICENSE).
