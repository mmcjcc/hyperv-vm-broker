# Validation.Tests.ps1 - Test-VmbLabel, Test-VmbGuestPath, Resolve-VmbStage: what a consumer string may be.
# Pester 3.4, Windows PowerShell 5.1, ASCII only.
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'VmbTestHelpers.ps1')

try {
Describe 'Test-VmbLabel: checkpoint labels' {
    It 'refuses the label <Shown>' -TestCases @(
        @{ Shown = 'Bad'; Label = 'Bad' }
        @{ Shown = 'CH1'; Label = 'CH1' }
        @{ Shown = '../x'; Label = '../x' }
        @{ Shown = 'a b'; Label = 'a b' }
        @{ Shown = 'empty'; Label = '' }
        @{ Shown = '49 characters'; Label = ('a' * 49) }
        @{ Shown = '-x'; Label = '-x' }
        @{ Shown = '.x'; Label = '.x' }
        @{ Shown = 'x/y'; Label = 'x/y' }
        @{ Shown = 'x\y'; Label = 'x\y' }
        @{ Shown = 'ch1;'; Label = 'ch1;' }
        @{ Shown = 'ch1 + newline'; Label = "ch1`n" }
        @{ Shown = 'newline in the middle'; Label = "ch`n1" }
    ) {
        param($Shown, $Label)
        $r = Get-VmbRefusal { Test-VmbLabel $Label }
        $r | Should Not BeNullOrEmpty
        $r.exit | Should Be 2
        $r.error | Should BeExactly 'rejected'
        $r.hint | Should Match '^label: must match '
    }

    It 'accepts the label <Label>' -TestCases @(
        @{ Label = 'a' }, @{ Label = '0' }, @{ Label = 'ch1' }, @{ Label = 'chapter-1.part_2' }, @{ Label = ('a' * 48) }, @{ Label = 'x-' }
    ) {
        param($Label)
        Get-VmbRefusal { Test-VmbLabel $Label } | Should BeNullOrEmpty
    }
}

Describe 'Test-VmbGuestPath: guest paths for copy-to and copy-from' {
    It 'refuses <Shown>' -TestCases @(
        @{ Shown = 'a relative name'; Path = 'notes.txt' }
        @{ Shown = 'a relative path'; Path = 'Users\student\notes.txt' }
        @{ Shown = 'a rooted path without a drive'; Path = '\Users\student\notes.txt' }
        @{ Shown = 'a drive-relative path'; Path = 'C:notes.txt' }
        @{ Shown = 'a UNC path'; Path = '\\server\share\notes.txt' }
        @{ Shown = '.. in the middle'; Path = 'C:\Users\..\Windows\notes.txt' }
        @{ Shown = '.. at the end'; Path = 'C:\Users\student\..' }
        @{ Shown = 'a * wildcard'; Path = 'C:\Users\student\*.txt' }
        @{ Shown = 'a ? wildcard'; Path = 'C:\Users\student\note?.txt' }
        @{ Shown = 'double quotes'; Path = 'C:\Users\student\"notes".txt' }
        @{ Shown = 'a < or >'; Path = 'C:\Users\student\a<b>.txt' }
        @{ Shown = 'a pipe'; Path = 'C:\Users\student\a|b.txt' }
        @{ Shown = 'a newline'; Path = "C:\Users\student\a`nb.txt" }
        @{ Shown = 'a tab'; Path = "C:\Users\student\a`tb.txt" }
        @{ Shown = 'a trailing backslash'; Path = 'C:\Users\student\' }
        @{ Shown = 'the drive root'; Path = 'C:\' }
        @{ Shown = '261 characters'; Path = ('C:\' + ('a' * 258)) }
        @{ Shown = 'empty'; Path = '' }
    ) {
        param($Shown, $Path)
        $r = Get-VmbRefusal { Test-VmbGuestPath $Path }
        $r | Should Not BeNullOrEmpty
        $r.exit | Should Be 2
        $r.error | Should BeExactly 'rejected'
        $r.hint | Should Match '^guest path: '
    }

    It 'accepts <Shown>' -TestCases @(
        @{ Shown = 'a plain file path'; Path = 'C:\Users\student\Desktop\notes.txt' }
        @{ Shown = '260 characters'; Path = ('C:\' + ('a' * 257)) }
        @{ Shown = 'an apostrophe'; Path = "C:\Users\student\it's.txt" }
        @{ Shown = 'two dots inside a name'; Path = 'D:\out\x..y.txt' }
        @{ Shown = 'a hidden name'; Path = 'C:\ProgramData\LabDirector\out\.marker' }
        @{ Shown = 'spaces'; Path = 'C:\Program Files\x y\z.txt' }
    ) {
        param($Shown, $Path)
        Get-VmbRefusal { Test-VmbGuestPath $Path } | Should BeNullOrEmpty
    }
}

Describe 'Resolve-VmbStage: only a 32-hex folder directly under stage\' {
    It 'accepts <root>\stage\<32 hex> and returns the full path' {
        $root = New-VmbTestRoot
        $id = New-VmbId
        Resolve-VmbStage (Join-Path $root "stage\$id") | Should BeExactly (Join-Path $root "stage\$id")
    }

    It 'refuses <Shown>' -TestCases @(
        @{ Shown = 'a folder below a stage folder'; Rel = 'stage\<id>\sub' }
        @{ Shown = 'a leaf that is not hex'; Rel = 'stage\not-a-stage-folder-at-all-xx' }
        @{ Shown = '31 hex digits'; Rel = 'stage\0123456789abcdef0123456789abcde' }
        @{ Shown = '33 hex digits'; Rel = 'stage\0123456789abcdef0123456789abcdef0' }
        @{ Shown = 'the stage folder itself'; Rel = 'stage' }
        @{ Shown = 'a trailing backslash on stage'; Rel = 'stage\' }
        @{ Shown = 'a way out through ..'; Rel = 'stage\..\state\<id>' }
        @{ Shown = 'another folder of the root'; Rel = 'vms\<id>' }
        @{ Shown = 'a sibling with the same prefix'; Rel = 'stagex\<id>' }
        @{ Shown = 'the root itself'; Rel = '.' }
    ) {
        param($Shown, $Rel)
        $root = New-VmbTestRoot
        $p = (Join-Path $root $Rel.Replace('<id>', (New-VmbId)))
        $r = Get-VmbRefusal { Resolve-VmbStage $p }
        $r | Should Not BeNullOrEmpty
        $r.exit | Should Be 2
        $r.hint | Should Match 'directly under vmb\\stage'
    }

    It 'refuses a hex folder elsewhere and a relative path' {
        $null = New-VmbTestRoot
        $id = New-VmbId
        (Get-VmbRefusal { Resolve-VmbStage "C:\Windows\Temp\$id" }).exit | Should Be 2
        (Get-VmbRefusal { Resolve-VmbStage "stage\$id" }).exit | Should Be 2
        (Get-VmbRefusal { Resolve-VmbStage $id }).exit | Should Be 2
    }

    It 'resolves a trailing newline away: GetFullPath drops it, so the result is the clean stage path' {
        $root = New-VmbTestRoot
        $p = Join-Path $root "stage\$(New-VmbId)"
        $out = Resolve-VmbStage ($p + "`n")
        ($out -ceq $p) | Should Be $true
    }
}
} finally { Remove-VmbTestRoots }
