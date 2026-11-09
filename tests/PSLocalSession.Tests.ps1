$modulePath = Join-Path $PSScriptRoot '..\PSLocalSession.psd1'
Import-Module $modulePath -Force

BeforeAll {
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

    It 'rejects a missing PowerShell path' {
        { New-LocalPSSession -CurrentUser -PowerShellPath 'C:\PSLocalSession\no-such-pwsh.exe' } |
            Should -Throw
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
            $bootstrap = New-PSLocalSessionBootstrapScript -PipeName $pipe `
                -ControlPipeName $controlName -CallerSid $caller.User.Value `
                -ConnectTimeoutSeconds 60 -CallerIsDesktop $false -TargetIsDesktop $false
            $taskCommand = ConvertTo-PSLocalSessionCompressedBootstrapCommand -Script $bootstrap

            $control = New-PSLocalSessionControlPipe -PipeName $controlName `
                -CallerSid $caller.User -TargetSid $target.Sid
            $connectionTask = $control.WaitForConnectionAsync()
            $task = $null
            $runspace = $null
            $targetPid = 0
            try {
                $task = Start-PSLocalSessionScheduledTask -PowerShellPath $pwsh `
                    -BootstrapCommand $taskCommand -TargetUserName $target.UserName `
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

                $deadline = [DateTime]::UtcNow.AddSeconds(10)
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
