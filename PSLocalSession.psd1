@{
    RootModule           = 'PSLocalSession.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '355975f9-7008-43f4-ad07-d3e0486b0142'
    Author               = 'PSLocalSession'
    Copyright            = '(c) PSLocalSession. All rights reserved.'
    Description          = 'Starts PowerShell as another local user and returns a PSSession connected over a local named pipe.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @('New-LocalPSSession')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags = @('PSSession', 'Remoting', 'NamedPipe', 'Windows', 'RunAs', 'Su')
        }
    }
}
