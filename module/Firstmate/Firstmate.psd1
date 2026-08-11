@{
    RootModule           = 'Firstmate.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'a3f0a5a4-2f28-4a1b-9b2e-3d6a1c7f5b40'
    Author               = 'firstmate'
    CompanyName          = 'firstmate'
    Copyright            = 'MIT'
    Description          = 'Native Windows PowerShell 7 port of firstmate: home layout, state files, locks, and process identity.'

    # PowerShell 7 only, per the port contract. No Windows PowerShell 5.1.
    PowerShellVersion    = '7.0'
    CompatiblePSEditions = @('Core')

    # The loader (Firstmate.psm1) decides the exported set: the explicit
    # foundation list plus every top-level function in Public/*.ps1. Keeping the
    # manifest at '*' means adding a Public file never requires editing this
    # file, so parallel work on separate areas cannot collide here.
    FunctionsToExport    = '*'
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData          = @{
        PSData = @{
            Tags       = @('firstmate', 'windows', 'automation')
            ProjectUri = 'https://github.com/kunchenguid/firstmate-win'
        }
    }
}
