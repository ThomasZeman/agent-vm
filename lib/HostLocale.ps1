# The host's time zone and locale, in the forms Linux wants. Dot-sourced by
# packer\Build-GoldenImage.ps1, which bakes them into the golden image, and by
# Test-AgentVM.ps1, which checks that a VM still matches the host.

function Get-HostIanaTimeZone {
    # The installer wants an IANA name ("Australia/Sydney"); Windows only knows its own
    # ("AUS Eastern Standard Time"). Windows PowerShell's .NET Framework cannot translate
    # between them, but the ICU library Windows has shipped since 10 1903 can, from the same
    # CLDR table everyone else uses - so there is no mapping list here to go stale.
    $windowsId = (Get-TimeZone).Id
    try {
        if (-not ('AgentVm.Icu' -as [type])) {
            Add-Type -Namespace AgentVm -Name Icu -MemberDefinition @'
[DllImport("icu.dll", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Cdecl)]
public static extern int ucal_getTimeZoneIDForWindowsID(string winid, int len, [MarshalAs(UnmanagedType.LPStr)] string region, System.Text.StringBuilder id, int idCapacity, ref int status);
'@
        }
        $buffer = New-Object System.Text.StringBuilder 64
        $status = 0
        $length = [AgentVm.Icu]::ucal_getTimeZoneIDForWindowsID($windowsId, -1, $null, $buffer, $buffer.Capacity, [ref]$status)
        if ($status -le 0 -and $length -gt 0) { return $buffer.ToString().Substring(0, $length) }
    }
    catch {
        Write-Verbose "ICU time zone lookup failed: $($_.Exception.Message)"
    }
    Write-Warning "Could not translate the host time zone '$windowsId' to an IANA name; using Etc/UTC. Pass -TimeZone (e.g. Australia/Sydney) to set it."
    return 'Etc/UTC'
}

function Get-HostLocale {
    # Windows culture "en-AU" -> glibc locale "en_AU.UTF-8". A neutral culture ("en") or a
    # script-qualified one ("zh-Hans-CN") has no direct glibc name, so fall back rather than
    # bake a LANG that names a locale that does not exist.
    $culture = (Get-Culture).Name
    if ($culture -match '^(?<lang>[a-z]{2,3})-(?<region>[A-Z]{2})$') {
        return "$($Matches.lang)_$($Matches.region).UTF-8"
    }
    Write-Warning "Host culture '$culture' has no direct Linux locale; using en_US.UTF-8. Pass -Locale (e.g. en_AU.UTF-8) to set it."
    return 'en_US.UTF-8'
}
