@{
    RootModule           = 'gx.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'e16ea194-bbad-4cce-a17c-b843150b19c5'
    Author               = 'sgkens'
    Copyright            = '(c) 2026 sgkens. MIT License.'
    Description          = 'A Git quality-of-life command for repository setup, everyday workflows, diagnostics, and guarded commits.'
    PowerShellVersion    = '7.3'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @('gx')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('Git', 'CLI', 'GitLab', 'GitHub', 'Gitea')
            LicenseUri   = 'https://gitlab.com/sgkens/gx/-/blob/main/LICENSE'
            ProjectUri   = 'https://gitlab.com/sgkens/gx'
            ReleaseNotes = 'See CHANGELOG.md.'
        }
    }
}
