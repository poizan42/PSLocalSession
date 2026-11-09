# PowerShell version compatibility

## What the module supports

`PSLocalSession.psd1`, the `#Requires` line, the public cmdlet, and the target bootstrap
accept:

- **Windows PowerShell 5.1** (`PSEdition = Desktop`), on both the caller and target sides;
- **PowerShell Core 7.1 or later** (`PSEdition = Core`), on both the caller and target
  sides.

PowerShell 7.0 and 6.2 remain unsupported; see [If support is extended
further](#if-support-is-extended-further).

The caller and target do not have to be the same edition or version. The static bootstrap
and both C# helper files ship with the module. The target selects the helper at runtime,
and selects the connection mode from its own edition plus the caller-edition argument.

## Measured behaviour

These results were measured on 2026-11-09 with portable release builds on Windows build 26300
and the inbox Windows PowerShell 5.1. Compatibility runs used `-CurrentUser`; the
cross-user matrix used a temporary local account.

### Target executable

| Target | Result | Notes |
|---|---|---|
| 7.6.9, 7.5.9, 7.4.22, 7.3.12, 7.2.24, 7.1.7 | **supported** | custom session pipe; exercised end to end |
| Windows PowerShell 5.1 | **supported** | default IPC pipe clone; exercised end to end |
| 7.0.13 | **unsupported** | `NamedPipeServerStreamAcl` does not exist in .NET Core 3.1; would need a portable `CreateNamedPipeW`/P-Invoke pipe-creation path |
| 6.2.7 | **unsupported** | same as 7.0; .NET Core 2.1 has no `NamedPipeServerStreamAcl` |

The 7.1 target needs the conditional `Add-Type -ReferencedAssemblies` block in the
bootstrap. From 7.2 onward the default `Add-Type` reference set is sufficient. The
bootstrap deliberately does not use `PipeOptions.FirstPipeInstance`, which is .NET 8+.

### Caller

| Caller | Result | Notes |
|---|---|---|
| 7.6.9, 7.5, 7.4, 7.3 | **supported** | all required public APIs are present |
| 7.2 / 7.1 | **supported** | internal `PSSession(RemoteRunspace)` constructor plus `RunspaceRepository.Add`; public `PSSession.Create` starts in 7.3 |
| Windows PowerShell 5.1 | **supported** | default IPC pipe mode, `ProcessStartInfo.Arguments`, internal `PSSession` constructor |
| 7.0 / 6.2 | **unsupported** | no `NamedPipeServerStreamAcl` for the control pipe; would need the portable named-pipe creation helper |

Exercised caller/target combinations:

| Caller | Target | Connection mode |
|---|---|---|
| 5.1 | 5.1 | Default |
| 5.1 | 7.1.7, 7.2.24, 7.6.9 | Default |
| 7.1.7, 7.2.24, 7.6.9 | 5.1 | Default |
| 7.1.7, 7.2.24, 7.6.9 | 7.1.7, 7.2.24, 7.6.9 | Custom |

Cross-user sessions (`-Credential` through `CreateProcessWithLogonW`) passed for
5.1 caller -> 5.1 target, 7.6 caller -> 5.1 target, and 7.6 caller -> 7.6 target against a
temporary local account. The target wrote to its own TEMP and exited when the session was
removed. The temporary account and profile were deleted afterwards.

The scheduled-task path was exercised for both a 5.1 target and a 7.6 target. It used the
test-only `-InteractiveToken` registration, which shares the target launch/cleanup plumbing
with the production stored-password/batch-logon path. The production stored-password path
was also exercised from an elevated caller against a temporary administrator account with
the default `Highest` run level; the target reported High integrity. The task and staging
copy were removed afterwards.

## Connection modes

### `Custom` (7.1+ caller and 7.1+ target)

The caller chooses the pipe name. The target creates the session pipe itself with a DACL
containing only the target account and the caller, swaps the stream into PowerShell's
internal `RemoteSessionNamedPipeServer`, and the caller connects with
`NamedPipeConnectionInfo(string customPipeName)`.

### `Default` (any 5.1 caller or 5.1 target)

Windows PowerShell 5.1 has no `NamedPipeConnectionInfo(string customPipeName)` constructor
and no `-CustomPipeName`. Both editions also expose different internal
`RemoteSessionNamedPipeServer` shapes, so the module embeds a reflection-only 5.1-specific
helper alongside the 7.1+ one. The target compiles only the helper matching its edition.

For a 5.1 target, the 5.1 helper:

1. sets `RemoteSessionNamedPipeServer.IPCNamedPipeServerEnabled = false`;
2. reads the pipe name from the existing default `IPCNamedPipeServer` and disposes it;
3. creates a replacement internal `RemoteSessionNamedPipeServer` with the same **default
   AppDomain pipe name**;
4. replaces its `_serverPipeStream` field with a `NamedPipeServerStream` created through the
   .NET Framework constructor that takes a `PipeSecurity`;
5. starts the listener through a reflection-created delegate to the internal
   `NamedPipeProcessMediator.Run(string, RemoteSessionNamedPipeServer)`.

The caller then connects with `NamedPipeConnectionInfo(targetProcessId)`. The session
records `LocalPSSessionConnectionMode = 'Default'` and
`LocalPSSessionPipeName = '<default IPC pipe>'`.

The default AppDomain pipe name is mandatory. A custom AppDomain name / custom pipe name
connected but did not complete the 5.1 PSRP handshake, while the default name did. A 7.1+
target uses its own `StartDefault` path when the caller is 5.1, because that caller can
only use the process-id constructor. That path performs the same replace-and-ACL operation
but swaps the 7.1+ `<Stream>k__BackingField`.

## Relevant API history

- `NamedPipeConnectionInfo(string customPipeName)` and the `-CustomPipeName` target switch
  exist from **6.2**. Windows PowerShell 5.1 only has the process-id/app-domain constructors.
- `RemoteSessionNamedPipeServer`, `StartListening`, and
  `NamedPipeProcessMediator.Run(string, RemoteSessionNamedPipeServer)` exist from **6.2**.
  In 5.1 they are internal, the stream is stored in `_serverPipeStream`, and the type has no
  public `NamedPipeServerStream` ACL factory.
- `RunspaceFactory.CreateRunspace(RunspaceConnectionInfo)` accepts `NamedPipeConnectionInfo`
  in 5.1 and all 6.2+ versions.
- `PSSession.Create(Runspace, string, PSCmdlet)` became public in **7.3.0**
  (`Add Custom Remote Connections Feature`, #17011). 5.1-7.2 only expose the internal
  `PSSession(RemoteRunspace)` constructor.
- `NamedPipeServerStreamAcl` is a .NET **5.0+** API, so it exists in PowerShell **7.1+**.
  It is absent in 7.0, 6.2, and 5.1. On 7.1 the related types are type-forwarded and
  `Add-Type` needs explicit references to `System.IO.Pipes.AccessControl.dll`.
- `PipeOptions.FirstPipeInstance` is a .NET **8.0+** API, so it exists in PowerShell
  **7.4+** but not 7.1-7.3. The bootstrap does not use it; the old pipe is disposed
  before the replacement is created.
- `ProcessStartInfo.ArgumentList` exists from .NET Core 2.1 (PowerShell 6.2+), but not in
  Windows PowerShell 5.1. The module falls back to
  `ProcessStartInfo.Arguments` with explicit Windows command-line quoting.
- `PipesAclExtensions.SetAccessControl` exists in 6.2/7.0 but fails on an unconnected server
  pipe handle with an unauthorized-operation error; it is not a substitute for creating
  the pipe with the desired DACL.
- `GetEffectiveRightsFromAclW` is available on every supported Windows version. It is
  deprecated in favor of the Authz API, but it evaluates a DACL for a SID without a token,
  which is enough for the conservative "can the target read this?" check. Any failure or
  ambiguity falls back to staging a copy.

## Bootstrap delivery

The static `PSLocalSession.Bootstrap.ps1` script and the two plain C# pipe helpers ship as
module files. Every launch path uses the same delivery mechanism: the target command line
contains `-ExecutionPolicy Bypass -File <bootstrap.ps1>` plus the per-session parameters,
never the script text:

```text
-File C:\...\PSLocalSession.Bootstrap.ps1
-PipeName PSLocalSession...
-ControlPipeName PSLocalSession.Ctl...
-CallerSid S-1-5-...
-ConnectTimeoutSeconds 90
-CallerIsDesktop 0|1
```

For `-CurrentUser`, the script is loaded from the module directory. For `-Credential`, a
module under the caller profile is staged directly. For other locations, the caller checks
the target SID's effective read access to the bootstrap and helper files, and traverse
access to their parent directories, using `GetEffectiveRightsFromAclW`. This does not
require a token for the target account. If the check fails for any reason (including an
unreachable domain group or an inherited deny ACE), the module treats it as no access and
stages a copy under `%ProgramData%\PSLocalSession-<guid>` with a caller/target-only DACL.
The caller uses the module path when the target can read it, and removes any staged copy
after the target reports readiness.

This keeps the command line under `CreateProcessWithLogonW`'s 1024-character limit and well
under Task Scheduler's action-argument limit (`0x800700CE`). It also gives antivirus
software a static script and C# files on disk to inspect, and allows the bootstrap to be
code-signed later. No script, base64 blob, or reader stub is placed on the command line or
executed from a pipe.

## Elevation and run level

- `-CurrentUser` inherits the caller token. An elevated caller gives an elevated target; a
  non-elevated caller gives a limited target.
- An elevated caller or `LocalSystem` with `-Credential` uses Task Scheduler. The default
  requested run level is `Highest`; if task registration is denied, the module retries with
  `Limited`. `-RunLevel Limited` forces the limited level.
- `LocalSystem` is treated as privileged even though it is not a member of the local
  Administrators group.
- A non-elevated caller with `-Credential` uses an interactive logon. Ordinary
  administrator accounts are UAC-filtered on that path. The built-in Administrator is the
  documented exception when `FilterAdministratorToken` is disabled.
- A non-elevated, non-interactive caller has no supported way to obtain a full
  administrator token from credentials alone; it needs an elevated/SYSTEM caller, a UAC
  prompt where available, or a pre-provisioned privileged task/service.

## If support is extended further

1. **7.0/6.2** - replace `NamedPipeServerStreamAcl` with a portable
   `CreateNamedPipeW`/security-descriptor helper in both the target and the caller control
   pipe. The 5.1 default-IPC-clone path is not a substitute because those editions still
   lack the public ACL type.
2. Other Windows PowerShell 5.1 configurations - Constrained Language Mode, AppLocker/WDAC,
   or a read-only target TEMP can block the in-process `Add-Type`; the module currently
   requires the target to compile the helper.
