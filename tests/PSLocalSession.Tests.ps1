$modulePath = Join-Path $PSScriptRoot '..\PSLocalSession.psd1'
Import-Module $modulePath -Force

BeforeAll {
    function Test-PSLocalSessionTestHostElevated {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        if ($identity.User.Value -eq 'S-1-5-18') { return $true }
        return [System.Security.Principal.WindowsPrincipal]::new($identity).IsInRole(
            [System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    function Test-PSLocalSessionProcessRunning {
        param([int]$ProcessId)
        return [bool](Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
    }

    function Wait-PSLocalSessionProcessExit {
        param([int]$ProcessId, [int]$TimeoutSeconds = 10)
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ((Test-PSLocalSessionProcessRunning -ProcessId $ProcessId) -and
               [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 200
        }
        return -not (Test-PSLocalSessionProcessRunning -ProcessId $ProcessId)
    }
}

AfterAll {
    Get-PSSession -ErrorAction SilentlyContinue |
        Where-Object { $_.Transport -eq 'NamedPipe' } |
        Remove-PSSession -ErrorAction SilentlyContinue
    Remove-Module PSLocalSession -Force -ErrorAction SilentlyContinue
}

Describe 'Module surface' {
    It 'exports exactly the public entry point' {
        $commands = @(Get-Command -Module PSLocalSession)
        $commands.Name | Should -Contain 'New-LocalPSSession'
        $commands.Count | Should -Be 1
    }

    It 'uses -Identity for passwordless accounts, not a -ServiceAccount argument' {
        $parameters = (Get-Command New-LocalPSSession).Parameters.Keys
        $parameters | Should -Contain 'Identity'
        $parameters | Should -Not -Contain 'ServiceAccount'
    }
}

Describe 'Command-line quoting' {
    InModuleScope PSLocalSession {
        It 'leaves simple arguments alone' {
            ConvertTo-PSLocalSessionCommandLineArgument -Argument 'simple' | Should -Be 'simple'
        }

        It 'quotes whitespace' {
            ConvertTo-PSLocalSessionCommandLineArgument -Argument 'two words' | Should -Be '"two words"'
        }

        It 'quotes empty strings' {
            ConvertTo-PSLocalSessionCommandLineArgument -Argument '' | Should -Be '""'
        }

        It 'escapes embedded quotes' {
            ConvertTo-PSLocalSessionCommandLineArgument -Argument 'a"b' | Should -Be '"a\"b"'
        }

        It 'doubles backslashes before the closing quote' {
            ConvertTo-PSLocalSessionCommandLineArgument -Argument 'a b\' | Should -Be '"a b\\"'
        }

        It 'joins a list' {
            ConvertTo-PSLocalSessionCommandLine -ArgumentList @('a', 'b c', 'd"e') |
                Should -Be 'a "b c" "d\"e"'
        }
    }
}

Describe 'Bootstrap delivery' {
    InModuleScope PSLocalSession {
        It 'uses the static bootstrap and C# files shipped with the module' {
            Test-Path -LiteralPath $script:BootstrapScriptPath -PathType Leaf | Should -BeTrue
            $moduleDirectory = Split-Path -Parent $script:BootstrapScriptPath
            foreach ($name in $script:BootstrapSupportFiles) {
                Test-Path -LiteralPath (Join-Path $moduleDirectory $name) -PathType Leaf |
                    Should -BeTrue
            }

            $bootstrapText = Get-Content -LiteralPath $script:BootstrapScriptPath -Raw
            $bootstrapText | Should -Not -Match 'FromBase64String|__CS'
        }

        It 'checks effective rights without a target token' {
            $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
            $probe = Join-Path $env:TEMP ('PSLocalSession-acl-{0}.txt' -f [guid]::NewGuid().ToString('N'))
            try {
                Set-Content -LiteralPath $probe -Value 'probe'
                Test-PSLocalSessionEffectiveAccess -Path $probe -TargetSid $sid `
                    -RequiredMask 0x81 | Should -BeTrue
            }
            finally {
                Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            }
        }

        It 'passes the script path and arguments without inline code' {
            $bootstrapArguments = New-PSLocalSessionBootstrapArguments `
                -PipeName 'PSLocalSession.session' `
                -ControlPipeName 'PSLocalSession.Ctl.test' `
                -CallerSid 'S-1-5-21-1-2-3-1001' `
                -ConnectTimeoutSeconds 60 -CallerIsDesktop $true
            $arguments = New-PSLocalSessionTargetArguments `
                -BootstrapScriptPath 'C:\Program Files\PSLocalSession\PSLocalSession.Bootstrap.ps1' `
                -BootstrapArguments $bootstrapArguments

            $arguments | Should -Contain '-File'
            $arguments | Should -Contain 'C:\Program Files\PSLocalSession\PSLocalSession.Bootstrap.ps1'
            $arguments | Should -Contain '-ExecutionPolicy'
            $arguments | Should -Contain 'Bypass'
            $arguments | Should -Contain '-PipeName'
            $arguments | Should -Contain 'PSLocalSession.session'
            $arguments | Should -Contain '-CallerIsDesktop'
            $arguments | Should -Contain '1'
            ($arguments -join ' ') | Should -Not -Match 'ScriptBlock|CSharp|Invoke-Expression'

            $argumentLine = ConvertTo-PSLocalSessionCommandLine -ArgumentList $arguments
            $argumentLine.Length | Should -BeLessThan 1024
        }
    }
}

Describe 'User resolution' {
    InModuleScope PSLocalSession {
        It 'resolves the current user to the current SID' {
            $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            $resolved = Resolve-PSLocalSessionUser -UserName $identity.Name
            $resolved.Sid.Value | Should -Be $identity.User.Value
            $resolved.IsCurrentUser | Should -BeTrue
        }

        It 'accepts .\name for a local account' {
            $localUser = Get-LocalUser -ErrorAction SilentlyContinue |
                Where-Object Enabled |
                Select-Object -First 1
            if (-not $localUser) {
                Set-ItResult -Skipped -Because 'this machine has no enabled local accounts'
                return
            }

            $resolved = Resolve-PSLocalSessionUser -UserName ".\$($localUser.Name)"
            $resolved.Sid.Value | Should -Be $localUser.SID.Value
        }
    }
}

Describe 'Built-in identity resolution' {
    InModuleScope PSLocalSession {
        It 'accepts canonical names, aliases, and raw SIDs' {
            $cases = @{
                'NT AUTHORITY\SYSTEM'          = 'S-1-5-18'
                'SYSTEM'                       = 'S-1-5-18'
                'LocalSystem'                  = 'S-1-5-18'
                'S-1-5-18'                     = 'S-1-5-18'
                'NT AUTHORITY\LOCAL SERVICE'   = 'S-1-5-19'
                'LocalService'                 = 'S-1-5-19'
                'S-1-5-19'                     = 'S-1-5-19'
                'NT AUTHORITY\NETWORK SERVICE' = 'S-1-5-20'
                'NetworkService'               = 'S-1-5-20'
                'S-1-5-20'                     = 'S-1-5-20'
            }

            foreach ($case in $cases.GetEnumerator()) {
                $resolved = Resolve-PSLocalSessionBuiltInIdentity -Identity $case.Key
                $resolved.Sid.Value | Should -Be $case.Value
            }
        }

        It 'rejects an ordinary account and points at -Credential' {
            { Resolve-PSLocalSessionBuiltInIdentity -Identity '.\PSLocalSessionNoSuchAccount' } |
                Should -Throw -ExpectedMessage '*not a built-in passwordless account*Use -Credential*'
        }

        It 'rejects virtual accounts that Task Scheduler cannot use as a principal' {
            { Resolve-PSLocalSessionBuiltInIdentity -Identity 'NT SERVICE\foo' } |
                Should -Throw -ExpectedMessage '*NT SERVICE virtual account*'
            { Resolve-PSLocalSessionBuiltInIdentity -Identity 'NT TASK\foo' } |
                Should -Throw -ExpectedMessage '*NT TASK virtual account*'
            { Resolve-PSLocalSessionBuiltInIdentity -Identity 'IIS APPPOOL\DefaultAppPool' } |
                Should -Throw -ExpectedMessage '*virtual account*not supported*'
        }

        It 'builds a ServiceAccount task principal without a password' {
            foreach ($identity in 'NT AUTHORITY\SYSTEM',
                                  'NT AUTHORITY\LOCAL SERVICE',
                                  'NT AUTHORITY\NETWORK SERVICE') {
                $principal = New-PSLocalSessionTaskPrincipal -TargetUserName $identity `
                    -LogonType ServiceAccount -RunLevel Limited
                $principal.LogonType | Should -Be 'ServiceAccount'
                $principal.RunLevel | Should -Be 'Limited'
            }
        }
    }
}

Describe 'Current-user session' {
    BeforeAll {
        $script:session = New-LocalPSSession -CurrentUser -NoProfile -Name 'PSLocalSessionTest'
        $script:targetPid = [int]$script:session.LocalPSSessionProcessId
    }

    AfterAll {
        if ($script:session) {
            Remove-PSSession -Session $script:session -ErrorAction SilentlyContinue
            $script:session = $null
        }
        if ($script:targetPid) {
            [void](Wait-PSLocalSessionProcessExit -ProcessId $script:targetPid)
            if (Test-PSLocalSessionProcessRunning -ProcessId $script:targetPid) {
                Stop-Process -Id $script:targetPid -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'returns an opened PSSession over a named pipe' {
        $script:session.GetType().FullName |
            Should -Be 'System.Management.Automation.Runspaces.PSSession'
        $script:session.Transport | Should -Be 'NamedPipe'
        $script:session.ComputerName | Should -Be 'localhost'
        $script:session.Name | Should -Be 'PSLocalSessionTest'
        $script:session.Runspace.RunspaceStateInfo.State |
            Should -Be ([System.Management.Automation.Runspaces.RunspaceState]::Opened)
    }

    It 'adds the session to the normal Get-PSSession repository' {
        $found = Get-PSSession -Name 'PSLocalSessionTest'
        $found | Should -Not -BeNullOrEmpty
        $found.InstanceId | Should -Be $script:session.InstanceId
    }

    It 'records the target process and user on the session' {
        $script:targetPid | Should -BeGreaterThan 0
        $script:session.LocalPSSessionUserName |
            Should -Be ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
        $script:session.LocalPSSessionLaunchMethod | Should -Be 'CurrentUser'
        $script:session.LocalPSSessionRunLevel | Should -Be 'Inherited'
        $script:session.LocalPSSessionPipeName | Should -Match '^PSLocalSession\.'
    }

    It 'runs commands in the target process as the current user' {
        $result = Invoke-Command -Session $script:session -ScriptBlock {
            [pscustomobject]@{
                ProcessId = $PID
                UserName  = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            }
        }
        $result.ProcessId | Should -Be $script:targetPid
        $result.UserName | Should -Be ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
    }

    It 'keeps session state between invocations' {
        $null = Invoke-Command -Session $script:session -ScriptBlock { $global:PSLocalSessionTestValue = 42 }
        Invoke-Command -Session $script:session -ScriptBlock { $global:PSLocalSessionTestValue } |
            Should -Be 42
    }

    It 'stops the target process when the session is removed' {
        $targetPid = $script:targetPid
        Remove-PSSession -Session $script:session
        $script:session = $null
        Wait-PSLocalSessionProcessExit -ProcessId $targetPid | Should -BeTrue
        $script:targetPid = 0
    }
}

Describe 'Windows PowerShell 5.1 target' -Tag 'PowerShell51' {
    It 'connects through the default IPC pipe' {
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $powershell)) {
            Set-ItResult -Skipped -Because 'Windows PowerShell 5.1 is not installed'
            return
        }

        $session = $null
        $targetPid = 0
        try {
            $session = New-LocalPSSession -CurrentUser -NoProfile `
                -PowerShellPath $powershell -StartupTimeoutSeconds 60
            $targetPid = [int]$session.LocalPSSessionProcessId

            $session.LocalPSSessionConnectionMode | Should -Be 'Default'
            $session.LocalPSSessionPipeName | Should -Be '<default IPC pipe>'

            $info = Invoke-Command -Session $session -ScriptBlock {
                [pscustomobject]@{
                    Edition = $PSVersionTable.PSEdition
                    Version = $PSVersionTable.PSVersion.ToString()
                    Pid     = $PID
                }
            }
            $info.Edition | Should -Be 'Desktop'
            $info.Version | Should -Match '^5\.1\.'
            $info.Pid | Should -Be $targetPid
        }
        finally {
            if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
            if ($targetPid) {
                [void](Wait-PSLocalSessionProcessExit -ProcessId $targetPid)
                Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe 'Concurrent sessions' {
    It 'keeps unrelated sessions alive when one is removed' {
        $one = $null
        $two = $null
        $onePid = 0
        $twoPid = 0
        try {
            $one = New-LocalPSSession -CurrentUser -NoProfile -Name 'PSLocalSessionOne'
            $two = New-LocalPSSession -CurrentUser -NoProfile -Name 'PSLocalSessionTwo'
            $onePid = [int]$one.LocalPSSessionProcessId
            $twoPid = [int]$two.LocalPSSessionProcessId
            (Invoke-Command -Session $one -ScriptBlock { $PID }) | Should -Be $onePid
            (Invoke-Command -Session $two -ScriptBlock { $PID }) | Should -Be $twoPid

            Remove-PSSession -Session $two
            $two = $null
            Wait-PSLocalSessionProcessExit -ProcessId $twoPid | Should -BeTrue
            (Invoke-Command -Session $one -ScriptBlock { $PID }) | Should -Be $onePid
        }
        finally {
            if ($one) { Remove-PSSession -Session $one -ErrorAction SilentlyContinue }
            if ($two) { Remove-PSSession -Session $two -ErrorAction SilentlyContinue }
            if ($onePid) {
                [void](Wait-PSLocalSessionProcessExit -ProcessId $onePid)
                Stop-Process -Id $onePid -Force -ErrorAction SilentlyContinue
            }
            if ($twoPid) {
                [void](Wait-PSLocalSessionProcessExit -ProcessId $twoPid)
                Stop-Process -Id $twoPid -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe 'Error handling' {
    It 'rejects an unresolvable account before starting anything' {
        $credential = [pscredential]::new(
            '.\PSLocalSessionNoSuchAccount12345',
            (ConvertTo-SecureString 'irrelevant' -AsPlainText -Force))
        { New-LocalPSSession -Credential $credential } |
            Should -Throw -ExpectedMessage '*Cannot resolve the account*'
    }

    It 'rejects an ordinary account passed as -Identity' {
        { New-LocalPSSession -Identity '.\PSLocalSessionNoSuchAccount12345' -NoProfile } |
            Should -Throw -ExpectedMessage '*not a built-in passwordless account*'
    }

    It 'requires an elevated caller for a built-in identity' {
        if (Test-PSLocalSessionTestHostElevated) {
            Set-ItResult -Skipped -Because 'the test host is already elevated'
            return
        }

        { New-LocalPSSession -Identity 'NT AUTHORITY\SYSTEM' -NoProfile } |
            Should -Throw -ExpectedMessage '*require an elevated caller*'
    }

    It 'rejects a missing PowerShell path' {
        { New-LocalPSSession -CurrentUser -PowerShellPath 'C:\PSLocalSession\no-such-pwsh.exe' } |
            Should -Throw
    }

    It 'rejects an invalid run level' {
        { New-LocalPSSession -CurrentUser -RunLevel 'Bogus' } | Should -Throw
    }
}

Describe 'Built-in service account sessions' -Tag 'ServiceAccount' {
    It 'runs the target as <Identity>' -ForEach @(
        @{ Identity = 'NT AUTHORITY\SYSTEM'; Sid = 'S-1-5-18' }
        @{ Identity = 'NT AUTHORITY\LOCAL SERVICE'; Sid = 'S-1-5-19' }
        @{ Identity = 'NT AUTHORITY\NETWORK SERVICE'; Sid = 'S-1-5-20' }
    ) {
        if (-not (Test-PSLocalSessionTestHostElevated)) {
            Set-ItResult -Skipped -Because 'built-in service account sessions require an elevated caller'
            return
        }

        $session = $null
        $targetPid = 0
        try {
            $session = New-LocalPSSession -Identity $Identity -NoProfile -StartupTimeoutSeconds 60
            $targetPid = [int]$session.LocalPSSessionProcessId

            $session.LocalPSSessionUserName | Should -Be $Identity
            $session.LocalPSSessionLaunchMethod | Should -Be 'ScheduledTask'
            $session.LocalPSSessionRunLevel | Should -BeIn @('Highest', 'Limited')

            $info = Invoke-Command -Session $session -ScriptBlock {
                $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
                $tempDirectory = [System.IO.Path]::GetTempPath()
                $probe = Join-Path $tempDirectory (
                    'PSLocalSession-probe-{0}.txt' -f [guid]::NewGuid().ToString('N'))
                try {
                    'probe' | Set-Content -LiteralPath $probe -ErrorAction Stop
                    $tempWritable = (Get-Content -LiteralPath $probe -Raw).Trim() -eq 'probe'
                }
                finally {
                    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
                }

                [pscustomobject]@{
                    Sid          = $identity.User.Value
                    ProcessId    = $PID
                    Temp         = $tempDirectory
                    TempWritable = $tempWritable
                }
            }

            $info.Sid | Should -Be $Sid
            $info.ProcessId | Should -Be $targetPid
            $info.TempWritable | Should -BeTrue -Because "the target's TEMP is '$($info.Temp)'"
        }
        finally {
            if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
            if ($targetPid) {
                [void](Wait-PSLocalSessionProcessExit -ProcessId $targetPid -TimeoutSeconds 30)
                Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe 'Scheduled-task plumbing' -Tag 'ScheduledTask' {
    It 'runs the target from a task, unregisters it, and stops the process on disconnect' {
        InModuleScope PSLocalSession {
            $caller = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            $target = Resolve-PSLocalSessionUser -UserName $caller.Name
            $pwsh = Get-PSLocalSessionPowerShellPath
            $pipe = 'PSLocalSession.{0}' -f [guid]::NewGuid().ToString('N')
            $controlName = 'PSLocalSession.Ctl.{0}' -f [guid]::NewGuid().ToString('N')
            $bootstrapArguments = New-PSLocalSessionBootstrapArguments -PipeName $pipe `
                -ControlPipeName $controlName -CallerSid $caller.User.Value `
                -ConnectTimeoutSeconds 60 -CallerIsDesktop $false

            $control = New-PSLocalSessionControlPipe -PipeName $controlName `
                -CallerSid $caller.User -TargetSid $target.Sid
            $connectionTask = $control.WaitForConnectionAsync()
            $task = $null
            $runspace = $null
            $targetPid = 0
            try {
                $task = Start-PSLocalSessionScheduledTask -PowerShellPath $pwsh `
                    -BootstrapScriptPath $script:BootstrapScriptPath `
                    -BootstrapArguments $bootstrapArguments -TargetUserName $target.UserName `
                    -InteractiveToken -NoProfile
                $task.Registered | Should -BeTrue

                $startup = Wait-PSLocalSessionControlMessage -ControlPipe $control `
                    -ConnectionTask $connectionTask -TimeoutMs 30000
                $targetPid = [int]$startup.ProcessId

                Unregister-PSLocalSessionScheduledTask -Task $task
                $task.Registered | Should -BeFalse
                Start-Sleep -Milliseconds 500
                [bool](Get-Process -Id $targetPid -ErrorAction SilentlyContinue) | Should -BeTrue

                $connectionInfo = [System.Management.Automation.Runspaces.NamedPipeConnectionInfo]::new($pipe)
                $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($connectionInfo)
                $runspace.Open()
                $shell = [powershell]::Create()
                try {
                    $shell.Runspace = $runspace
                    $null = $shell.AddScript('[System.Security.Principal.WindowsIdentity]::GetCurrent().Name')
                    $shell.Invoke() | Should -Be $caller.Name
                }
                finally {
                    $shell.Dispose()
                }

                $runspace.Close()
                $runspace.Dispose()
                $runspace = $null

                $deadline = [DateTime]::UtcNow.AddSeconds(30)
                while ((Get-Process -Id $targetPid -ErrorAction SilentlyContinue) -and
                       [DateTime]::UtcNow -lt $deadline) {
                    Start-Sleep -Milliseconds 200
                }
                [bool](Get-Process -Id $targetPid -ErrorAction SilentlyContinue) | Should -BeFalse
            }
            finally {
                if ($control) { $control.Dispose() }
                if ($runspace) { $runspace.Dispose() }
                if ($task -and $task.Registered) { Stop-PSLocalSessionScheduledTask -Task $task }
                if ($targetPid) { Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue }
            }
        }
    }
}
