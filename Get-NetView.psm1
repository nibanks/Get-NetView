$Global:Version = "2021.1.5.128"

$Global:ThreadPool = $null
$Global:QueueActivity = "Queueing tasks..."
$Global:FinishActivity = "Finishing..."

$Global:ChelsioDeviceDirs = @{}
$Global:MellanoxSystemLogDir = ""

$ExecFunctions = {
    $columns   = 4096
    $Global:DelayFactor = 0

    # Alias Write-CmdLog to Write-Host for background threads,
    # since console color only applies to the main thread.
    Set-Alias -Name Write-CmdLog -Value Write-Host

    <#
    .SYNOPSIS
        Log control path errors or issues.
    #>
    function ExecControlError {
        [CmdletBinding()]
        Param(
            [parameter(Mandatory=$true)] [String] $OutDir,
            [parameter(Mandatory=$true)] [String] $Function,
            [parameter(Mandatory=$true)] [String] $Message
        )

        $file = "$Function.Errors.txt"
        $out  = Join-Path $OutDir $file
        Write-Output $Message | Out-File -Encoding ascii -Append $out
    } # ExecControlError()

    enum CommandStatus {
        NotTested    # Indicates problem with TestCommand
        Unavailable  # [Part of] the command doesn't exist
        Failed       # An error prevented successful execution
        Success      # No errors or exceptions
    }

    # Powershell cmdlets have inconsistent implementations in command error handling. This function
    # performs a validation of the command prior to formal execution and will log any failures.
    function TestCommand {
        [CmdletBinding()]
        Param(
            [parameter(Mandatory=$true)] [String] $Command
        )

        $status = [CommandStatus]::NotTested
        $duration = [TimeSpan]::Zero
        $commandOut = ""

        try {
            $error.Clear()

            # Redirect all command output (expect errors) to stdout.
            # Any errors will still be output to $error variable.
            $silentCmd = '$({0}) 2>$null 3>&1 4>&1 5>&1 6>&1' -f $Command

            $duration = Measure-Command {
                # ErrorAction MUST be Stop for try catch to work.
                $commandOut = (Invoke-Expression $silentCmd -ErrorAction Stop)
            }

            # Sometimes commands output errors even on successful execution.
            # We only should fail commands if an error was their *only* output.
            if (($error -ne $null) -and [String]::IsNullOrWhiteSpace($commandOut)) {
                # Some PS commands are incorrectly implemented in return
                # code and require detecting SilentlyContinue
                if ($Command -notlike "*SilentlyContinue*") {
                    throw $error[0]
                }
            }

            $status = [CommandStatus]::Success
        } catch [Management.Automation.CommandNotFoundException] {
            $status = [CommandStatus]::Unavailable
        } catch {
            $status  = [CommandStatus]::Failed
            $commandOut = ($_ | Out-String)
        } finally {
            # Post-execution cleanup to avoid false positives
            $error.Clear()
        }

        return $status, $duration.TotalMilliseconds, $commandOut
    } # TestCommand()

    function ExecCommand {
        [CmdletBinding()]
        Param(
            [parameter(Mandatory=$true)] [String] $Command
        )

        $status, [Int] $duration, $commandOut = TestCommand -Command $Command

        # Mirror command execution context
        Write-Output "$env:USERNAME @ ${env:COMPUTERNAME}:"

        # Mirror command to execute
        Write-Output "$(prompt)$Command"

        $logPrefix = "({0,6:n0} ms)" -f $duration
        if ($status -ne [CommandStatus]::Success) {
            $logPrefix = "$logPrefix [$status]"
            Write-Output "[$status]"
        }
        Write-Output $commandOut

        Write-CmdLog "$logPrefix $Command"

        if ($Global:DelayFactor -gt 0) {
            Start-Sleep -Milliseconds ($duration * $Global:DelayFactor + 0.50) # round up
        }
    } # ExecCommand()

    function ExecCommands {
        [CmdletBinding()]
        Param(
            [parameter(Mandatory=$true)] [String] $File,
            [parameter(Mandatory=$true)] [String] $OutDir,
            [parameter(Mandatory=$true)] [String[]] $Commands
        )

        $out = (Join-Path -Path $OutDir -ChildPath $File)
        $($Commands | foreach {ExecCommand -Command $_}) | Out-File -Encoding ascii -Append $out

        # With high-concurreny, WMI-based cmdlets sometimes output in an
        # incorrect format or with missing fields. Somehow, this helps
        # reduce the frequency of the problem.
        $null = Get-NetAdapter
    } # ExecCommands()
} # $ExecFunctions

. $ExecFunctions # import into script context

<#
.SYNOPSIS
    Create a shortcut file (.LNK) pointing to $TargetPath.
.NOTES
    Used to avoid duplicate effort in IHV commands, which are
    executed per NIC, but some data is per system/ASIC.
#>
function New-LnkShortcut {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $LnkFile,
        [parameter(Mandatory=$true)] [String] $TargetPath
    )

    if ($LnkFile -notlike "*.lnk") {
        return
    }

    $shell = New-Object -ComObject "WScript.Shell"
    $lnk = $shell.CreateShortcut($LnkFile)
    $lnk.TargetPath = $TargetPath
    $null = $lnk.Save()
    $null = [Runtime.Interopservices.Marshal]::ReleaseComObject($shell)
} # New-LnkShortcut()

<#
.SYNOPSIS
    Replaces invalid characters with a placeholder to make a
    valid directory or filename.
.NOTES
    Do not pass in a path. It will replace '\' and '/'.
#>
function ConvertTo-Filename {
    [CmdletBinding()]
    Param(
        [parameter(Position=0, Mandatory=$true)] [String] $Filename
    )

    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars() -join ""
    return $Filename -replace "[$invalidChars]","_"
}

function TryCmd {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [ScriptBlock] $ScriptBlock
    )

    try {
        $out = &$ScriptBlock
    } catch {
        $out = $null
    }

    # Returning $null will cause foreach to iterate once
    # unless TryCmd call is in parentheses.
    if ($out -eq $null) {
        $out = @()
    }

    return $out
} # TryCmd()

function Write-CmdLog {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $CmdLog
    )

    $logColor = [ConsoleColor]::White
    switch -Wildcard ($CmdLog) {
        "*``[Failed``]*" {
            $logColor = [ConsoleColor]::Yellow
            break
        }
        "*``[Unavailable``]*" {
            $logColor = [ConsoleColor]::Gray
            break
        }
    }

    Write-Host $CmdLog -ForegroundColor $logColor
} # Write-CmdLog()

function Open-GlobalThreadPool {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [Int] $BackgroundThreads
    )

    if ($BackgroundThreads -gt 0) {
        $Global:ThreadPool = [RunspaceFactory]::CreateRunspacePool(1, $BackgroundThreads)
        $Global:ThreadPool.Open()
    }

    if ($BackgroundThreads -le 1) {
        Set-Alias ExecCommandsAsync ExecCommands
        $Global:QueueActivity = "Executing commands..."
    }
} # Open-GlobalThreadPool()

function Close-GlobalThreadPool {
    [CmdletBinding()]
    Param()

    if ($Global:ThreadPool -ne $null) {
        Write-Progress -Activity $Global:FinishActivity -Status "Cleanup background threads..."
        $Global:ThreadPool.Close()
        $Global:ThreadPool.Dispose()
        $Global:ThreadPool = $null
    }
} # Close-GlobalThreadPool()

function Start-Thread {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [ScriptBlock] $ScriptBlock,
        [parameter(Mandatory=$false)] [Hashtable] $Params = @{}
    )

    if ($Global:ThreadPool -eq $null) {
        # Execute command synchronously instead
        &$ScriptBlock @Params
    } else {
        $ps = [PowerShell]::Create()

        $ps.RunspacePool = $Global:ThreadPool
        $null = $ps.AddScript("Set-Location `"$(Get-Location)`"")
        $null = $ps.AddScript($ExecFunctions) # import into thread context
        $null = $ps.AddScript($ScriptBlock, $true).AddParameters($Params)

        $async = $ps.BeginInvoke()

        return @{AsyncResult=$async; PowerShell=$ps}
    }
} # Start-Thread()

function Show-Threads {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$false)] [Hashtable[]] $Threads
    )

    $mThreads = [Collections.ArrayList]$Threads
    $totalTasks = $mThreads.Count

    while ($mThreads.Count -gt 0) {
        Write-Progress -Activity "Waiting for all tasks to complete..." -Status "$($mThreads.Count) remaining." -PercentComplete (100 * (1 - $mThreads.Count / $totalTasks))

        for ($i = 0; $i -lt $mThreads.Count; $i++) {
            $thread = $mThreads[$i]

            $thread.Powershell.Streams.Warning | Out-Host
            $thread.Powershell.Streams.Warning.Clear()
            $thread.Powershell.Streams.Information | foreach {Write-CmdLog "$_"}
            $thread.Powershell.Streams.Information.Clear()

            if ($thread.AsyncResult.IsCompleted) {
                # Accessing Streams.Error blocks until thread is completed
                $thread.Powershell.Streams.Error | Out-Host
                $thread.Powershell.Streams.Error.Clear()

                $thread.PowerShell.EndInvoke($thread.AsyncResult)
                $mThreads.RemoveAt($i)
                $i--
            }
        }

        Start-Sleep -Milliseconds 33 # ~30 Hz
    }
} # Show-Threads()

function ExecCommandsAsync {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $OutDir,
        [parameter(Mandatory=$true)] [String] $File,
        [parameter(Mandatory=$true)] [String[]] $Commands
    )

    return Start-Thread -ScriptBlock ${function:ExecCommands} -Params $PSBoundParameters
} # ExecCommandsAsync()

function ExecCopyItemsAsync {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $OutDir,
        [parameter(Mandatory=$true)] [String] $File,
        [parameter(Mandatory=$true)] [String[]] $Paths,
        [parameter(Mandatory=$true)] [String] $Destination
    )

    if (-not (Test-Path $Destination)) {
        $null = New-Item -ItemType "Container" -Path $Destination
    }

    [String[]] $cmds = $Paths | foreach {"Copy-Item -Path ""$_"" -Destination ""$Destination"" -Recurse -Verbose 4>&1"}
    return ExecCommandsAsync -OutDir $OutDir -File $File -Commands $cmds
} # ExecCopyItemsAsync()

#
# Data Collection Functions
#

function NetIpNic {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$false)] [String] $NicName,
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $name = $NicName
    $dir  = (Join-Path -Path $OutDir -ChildPath "NetIp")
    New-Item -ItemType directory -Path $dir | Out-Null

    $file = "Get-NetIpAddress.txt"
    [String []] $cmds = "Get-NetIpAddress -InterfaceAlias ""$name"" | Format-Table -AutoSize | Out-String -Width $columns",
                        "Get-NetIpAddress -InterfaceAlias ""$name"" | Format-Table -Property * -AutoSize | Out-String -Width $columns",
                        "Get-NetIpAddress -InterfaceAlias ""$name"" | Format-List",
                        "Get-NetIpAddress -InterfaceAlias ""$name"" | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetIPInterface.txt"
    [String []] $cmds = "Get-NetIPInterface -InterfaceAlias ""$name"" | Out-String -Width $columns",
                        "Get-NetIPInterface -InterfaceAlias ""$name"" | Format-Table -AutoSize",
                        "Get-NetIPInterface -InterfaceAlias ""$name"" | Format-Table -Property * -AutoSize | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetNeighbor.txt"
    [String []] $cmds = "Get-NetNeighbor -InterfaceAlias ""$name"" | Out-String -Width $columns",
                        "Get-NetNeighbor -InterfaceAlias ""$name"" | Format-Table -AutoSize | Out-String -Width $columns",
                        "Get-NetNeighbor -InterfaceAlias ""$name"" | Format-Table -Property * -AutoSize | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetRoute.txt"
    [String []] $cmds = "Get-NetRoute -InterfaceAlias ""$name"" | Format-Table -AutoSize | Out-String -Width $columns",
                        "Get-NetRoute -InterfaceAlias ""$name"" | Format-Table -Property * -AutoSize | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds
} # NetIpNic()

function NetIp {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $dir = (Join-Path -Path $OutDir -ChildPath "NetIp")
    New-Item -ItemType directory -Path $dir | Out-Null

    $file = "Get-NetIpAddress.txt"
    [String []] $cmds = "Get-NetIpAddress | Format-Table -AutoSize | Out-String -Width $columns",
                        "Get-NetIpAddress | Format-Table -Property * -AutoSize | Out-String -Width $columns",
                        "Get-NetIpAddress | Format-List",
                        "Get-NetIpAddress | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetIPInterface.txt"
    [String []] $cmds = "Get-NetIPInterface | Out-String -Width $columns",
                        "Get-NetIPInterface | Format-Table -AutoSize  | Out-String -Width $columns",
                        "Get-NetIPInterface | Format-Table -Property * -AutoSize | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetNeighbor.txt"
    [String []] $cmds = "Get-NetNeighbor | Format-Table -AutoSize | Out-String -Width $columns",
                        "Get-NetNeighbor | Format-Table -Property * -AutoSize | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetIPv4Protocol.txt"
    [String []] $cmds = "Get-NetIPv4Protocol | Out-String -Width $columns",
                        "Get-NetIPv4Protocol | Format-List  -Property *",
                        "Get-NetIPv4Protocol | Format-Table -Property * -AutoSize",
                        "Get-NetIPv4Protocol | Format-Table -Property * -AutoSize | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetIPv6Protocol.txt"
    [String []] $cmds = "Get-NetIPv6Protocol | Out-String -Width $columns",
                        "Get-NetIPv6Protocol | Format-List  -Property *",
                        "Get-NetIPv6Protocol | Format-Table -Property * -AutoSize",
                        "Get-NetIPv6Protocol | Format-Table -Property * -AutoSize | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetOffloadGlobalSetting.txt"
    [String []] $cmds = "Get-NetOffloadGlobalSetting | Out-String -Width $columns",
                        "Get-NetOffloadGlobalSetting | Format-List  -Property *",
                        "Get-NetOffloadGlobalSetting | Format-Table -AutoSize",
                        "Get-NetOffloadGlobalSetting | Format-Table -Property * -AutoSize | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetPrefixPolicy.txt"
    [String []] $cmds = "Get-NetPrefixPolicy | Format-Table -AutoSize",
                        "Get-NetPrefixPolicy | Format-Table -Property * -AutoSize | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetRoute.txt"
    [String []] $cmds = "Get-NetRoute | Format-Table -AutoSize",
                        "Get-NetRoute | Format-Table -Property * -AutoSize | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetTCPConnection.txt"
    [String []] $cmds = "Get-NetTCPConnection | Format-Table -AutoSize",
                        "Get-NetTCPConnection | Format-Table -Property * -AutoSize | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetTcpSetting.txt"
    [String []] $cmds = "Get-NetTcpSetting | Format-Table -AutoSize",
                        "Get-NetTcpSetting | Format-Table -Property * -AutoSize | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetTransportFilter.txt"
    [String []] $cmds = "Get-NetTransportFilter | Format-Table -AutoSize",
                        "Get-NetTransportFilter | Format-Table -Property * -AutoSize | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetUDPEndpoint.txt"
    [String []] $cmds = "Get-NetUDPEndpoint | Format-Table -AutoSize",
                        "Get-NetUDPEndpoint | Format-Table -Property * -AutoSize | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetUDPSetting.txt"
    [String []] $cmds = "Get-NetUDPSetting | Format-Table -AutoSize",
                        "Get-NetUDPSetting | Format-Table -Property * -AutoSize | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds
} # NetIp()

function NetNatDetail {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $dir = (Join-Path -Path $OutDir -ChildPath "NetNat")
    New-Item -ItemType directory -Path $dir | Out-Null

    $file = "Get-NetNat.txt"
    [String []] $cmds = "Get-NetNat | Format-Table -AutoSize | Out-String -Width $columns",
                        "Get-NetNat | Format-Table -Property * -AutoSize | Out-String -Width $columns",
                        "Get-NetNat | Format-List",
                        "Get-NetNat | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetNatExternalAddress.txt"
    [String []] $cmds = "Get-NetNatExternalAddress | Format-Table -AutoSize | Out-String -Width $columns",
                        "Get-NetNatExternalAddress | Format-Table -Property * -AutoSize | Out-String -Width $columns",
                        "Get-NetNatExternalAddress | Format-List",
                        "Get-NetNatExternalAddress | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetNatGlobal.txt"
    [String []] $cmds = "Get-NetNatGlobal | Format-Table -AutoSize | Out-String -Width $columns",
                        "Get-NetNatGlobal | Format-Table -Property * -AutoSize | Out-String -Width $columns",
                        "Get-NetNatGlobal | Format-List",
                        "Get-NetNatGlobal | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetNatSession.txt"
    [String []] $cmds = "Get-NetNatSession | Format-Table -AutoSize | Out-String -Width $columns",
                        "Get-NetNatSession | Format-Table -Property * -AutoSize | Out-String -Width $columns",
                        "Get-NetNatSession | Format-List",
                        "Get-NetNatSession | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetNatStaticMapping.txt"
    [String []] $cmds = "Get-NetNatStaticMapping | Format-Table -AutoSize | Out-String -Width $columns",
                        "Get-NetNatStaticMapping | Format-Table -Property * -AutoSize | Out-String -Width $columns",
                        "Get-NetNatStaticMapping | Format-List",
                        "Get-NetNatStaticMapping | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

} # NetNat()

function NetAdapterWorker {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$false)] [String] $NicName,
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $name = $NicName
    $dir  = $OutDir

    $file = "nmbind.txt"
    [String []] $cmds = "nmbind ""$name"" "
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetAdapter.txt"
    [String []] $cmds = "Get-NetAdapter -Name ""$name"" -IncludeHidden | Out-String -Width $columns",
                        "Get-NetAdapter -Name ""$name"" -IncludeHidden | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetAdapterAdvancedProperty.txt"
    [String []] $cmds = "Get-NetAdapterAdvancedProperty -Name ""$name"" -AllProperties -IncludeHidden | Sort-Object RegistryKeyword | Format-Table -AutoSize | Out-String -Width $columns",
                        "Get-NetAdapterAdvancedProperty -Name ""$name"" -AllProperties -IncludeHidden | Format-List -Property *",
                        "Get-NetAdapterAdvancedProperty -Name ""$name"" -AllProperties -IncludeHidden | Format-Table -Property * | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetAdapterBinding.txt"
    [String []] $cmds = "Get-NetAdapterBinding -Name ""$name"" -AllBindings -IncludeHidden | Sort-Object ComponentID | Out-String -Width $columns",
                        "Get-NetAdapterBinding -Name ""$name"" -AllBindings -IncludeHidden | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetAdapterChecksumOffload.txt"
    [String []] $cmds = "Get-NetAdapterChecksumOffload -Name ""$name"" -IncludeHidden | Out-String -Width $columns",
                        "Get-NetAdapterChecksumOffload -Name ""$name"" -IncludeHidden | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetAdapterLso.txt"
    [String []] $cmds = "Get-NetAdapterLso -Name ""$name"" -IncludeHidden | Out-String -Width $columns",
                        "Get-NetAdapterLso -Name ""$name"" -IncludeHidden | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetAdapterRss.txt"
    [String []] $cmds = "Get-NetAdapterRss -Name ""$name"" -IncludeHidden | Out-String -Width $columns",
                        "Get-NetAdapterRss -Name ""$name"" -IncludeHidden | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetAdapterStatistics.txt"
    [String []] $cmds = "Get-NetAdapterStatistics -Name ""$name"" -IncludeHidden | Out-String -Width $columns",
                        "Get-NetAdapterStatistics -Name ""$name"" -IncludeHidden | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetAdapterEncapsulatedPacketTaskOffload.txt"
    [String []] $cmds = "Get-NetAdapterEncapsulatedPacketTaskOffload -Name ""$name"" -IncludeHidden | Out-String -Width $columns",
                        "Get-NetAdapterEncapsulatedPacketTaskOffload -Name ""$name"" -IncludeHidden | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetAdapterHardwareInfo.txt"
    [String []] $cmds = "Get-NetAdapterHardwareInfo -Name ""$name"" -IncludeHidden | Out-String -Width $columns",
                        "Get-NetAdapterHardwareInfo -Name ""$name"" -IncludeHidden | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetAdapterIPsecOffload.txt"
    [String []] $cmds = "Get-NetAdapterIPsecOffload -Name ""$name"" -IncludeHidden | Out-String -Width $columns",
                        "Get-NetAdapterIPsecOffload -Name ""$name"" -IncludeHidden | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetAdapterPowerManagement.txt"
    [String []] $cmds = "Get-NetAdapterPowerManagement -Name ""$name"" -IncludeHidden | Out-String -Width $columns",
                        "Get-NetAdapterPowerManagement -Name ""$name"" -IncludeHidden | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetAdapterQos.txt"
    [String []] $cmds = "Get-NetAdapterQos -Name ""$name"" -IncludeHidden | Out-String -Width $columns",
                        "Get-NetAdapterQos -Name ""$name"" -IncludeHidden | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetAdapterRdma.txt"
    [String []] $cmds = "Get-NetAdapterRdma -Name ""$name"" -IncludeHidden | Out-String -Width $columns",
                        "Get-NetAdapterRdma -Name ""$name"" -IncludeHidden | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetAdapterPacketDirect.txt"
    [String []] $cmds = "Get-NetAdapterPacketDirect -Name ""$name"" -IncludeHidden | Out-String -Width $columns",
                        "Get-NetAdapterPacketDirect -Name ""$name"" -IncludeHidden | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetAdapterRsc.txt"
    [String []] $cmds = "Get-NetAdapterRsc -Name ""$name"" -IncludeHidden | Out-String -Width $columns",
                        "Get-NetAdapterRsc -Name ""$name"" -IncludeHidden | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetAdapterSriov.txt"
    [String []] $cmds = "Get-NetAdapterSriov -Name ""$name"" -IncludeHidden | Out-String -Width $columns",
                        "Get-NetAdapterSriov -Name ""$name"" -IncludeHidden | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetAdapterSriovVf.txt"
    [String []] $cmds = "Get-NetAdapterSriovVf -Name ""$name"" -IncludeHidden | Out-String -Width $columns",
                        "Get-NetAdapterSriovVf -Name ""$name"" -IncludeHidden | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetAdapterUso.txt"
    [String []] $cmds = "Get-NetAdapterUso -Name ""$name"" -IncludeHidden | Out-String -Width $columns",
                        "Get-NetAdapterUso -Name ""$name"" -IncludeHidden | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetAdapterVmq.txt"
    [String []] $cmds = "Get-NetAdapterVmq -Name ""$name"" -IncludeHidden | Out-String -Width $columns",
                        "Get-NetAdapterVmq -Name ""$name"" -IncludeHidden | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetAdapterVmqQueue.txt"
    [String []] $cmds = "Get-NetAdapterVmqQueue -Name ""$name"" -IncludeHidden | Out-String -Width $columns",
                        "Get-NetAdapterVmqQueue -Name ""$name"" -IncludeHidden | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetAdapterVPort.txt"
    [String []] $cmds = "Get-NetAdapterVPort -Name ""$name"" -IncludeHidden | Out-String -Width $columns",
                        "Get-NetAdapterVPort -Name ""$name"" -IncludeHidden | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds
} # NetAdapterWorker()

function NetAdapterWorkerPrepare {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$false)] [String] $NicName,
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $name = $NicName
    $dir  = $OutDir

    # Create dir for each NIC
    $nic   = Get-NetAdapter -Name $name -IncludeHidden
    $type  = if (Get-NetAdapterHardwareInfo -Name $name -IncludeHidden -ErrorAction "SilentlyContinue") {"pNIC"} else {"NIC"}
    $idx   = $nic.InterfaceIndex
    $desc  = $nic.InterfaceDescription
    $title = "$type.$idx.$name"

    if ("$desc") {
        $title = "$title.$desc"
    }

    if ($nic.Hidden) {
        $dir = Join-Path $dir "NIC.Hidden"
    }
    $dir = Join-Path $dir $(ConvertTo-Filename $title.Trim())
    New-Item -ItemType directory -Path $dir | Out-Null

    Write-Progress $Global:QueueActivity -Status "Processing $title"
    NetIpNic         -NicName $name -OutDir $dir
    NetAdapterWorker -NicName $name -OutDir $dir
    if (-not $nic.Hidden) {
        NicVendor    -NicName $name -OutDir $dir
    }
} # NetAdapterWorkerPrepare()

function LbfoWorker {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$false)] [String] $LbfoName,
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $name  = $LbfoName
    $title = "LBFO.$name"

    $dir   = Join-Path $OutDir $(ConvertTo-Filename $title)
    New-Item -ItemType directory -Path $dir | Out-Null

    Write-Progress -Activity $Global:QueueActivity -Status "Processing $title"
    $file = "Get-NetLbfoTeam.txt"
    [String []] $cmds = "Get-NetLbfoTeam -Name ""$name""",
                        "Get-NetLbfoTeam -Name ""$name"" | Format-List  -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetLbfoTeamNic.txt"
    [String []] $cmds = "Get-NetLbfoTeamNic -Team ""$name""",
                        "Get-NetLbfoTeamNic -Team ""$name"" | Format-List  -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetLbfoTeamMember.txt"
    [String []] $cmds = "Get-NetLbfoTeamMember -Team ""$name""",
                        "Get-NetLbfoTeamMember -Team ""$name"" | Format-List  -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    # Report the TNIC(S)
    foreach ($tnic in TryCmd {Get-NetLbfoTeamNic -Team $name}) {
        NetAdapterWorkerPrepare -NicName $tnic.Name -OutDir $OutDir
    }

    # Report the NIC Members
    foreach ($mnic in TryCmd {Get-NetLbfoTeamMember -Team $name}) {
        NetAdapterWorkerPrepare -NicName $mnic.Name -OutDir $OutDir
    }
} # LbfoWorker()

function LbfoDetail {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $dir = $OutDir

    $vmsNicNames = TryCmd {(Get-NetAdapterBinding -ComponentID "vms_pp" | where {$_.Enabled -eq $true}).Name}

    foreach ($lbfo in TryCmd {Get-NetLbfoTeam}) {
        # Skip all vSwitch Protocol NICs since the LBFO and member
        # reporting will occur as part of vSwitch reporting.
        $match = $false

        if ($lbfo.Name -in $vmsNicNames) {
            $match = $true
        }

        if (-not $match) {
            LbfoWorker -LbfoName $lbfo.Name -OutDir $dir
        }
    }
} # LbfoDetail()

function ProtocolNicDetail {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$false)] [String] $VMSwitchId,
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $id  = $VMSwitchId
    $dir = $OutDir

    $vmsNicDescriptions = TryCmd {(Get-VMSwitch -Id $id).NetAdapterInterfaceDescriptions}

    # Distinguish between LBFO from standard PTNICs and create the hierarchies accordingly
    foreach ($desc in $vmsNicDescriptions) {
        $nic = Get-NetAdapter -InterfaceDescription $desc
        if ($nic.DriverFileName -like "NdisImPlatform.sys") {
            LbfoWorker -LbfoName $nic.Name -OutDir $dir
        } else {
            NetAdapterWorkerPrepare -NicName $nic.Name -OutDir $dir
        }
    }
} # ProtocolNicDetail()

function NativeNicDetail {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $dir = $OutDir

    # Cache output
    $vmsNicNames = TryCmd {(Get-NetAdapterBinding -ComponentID "vms_pp" | where {$_.Enabled -eq $true}).Name}
    $lbfoNicNames = TryCmd {(Get-NetLbfoTeamMember).Name}

    foreach ($nic in Get-NetAdapter -IncludeHidden) {
        $native = $true

        # Skip vSwitch Host vNICs by checking the driver
        if ($nic.DriverFileName -in @("vmswitch.sys", "VmsProxyHNic.sys")) {
            continue
        }

        # Skip LBFO TNICs by checking the driver
        if ($nic.DriverFileName -like "NdisImPlatform.sys") {
            continue
        }

        # Skip all vSwitch Protocol NICs
        if ($nic.Name -in $vmsNicNames) {
            $native = $false
        }

        # Skip LBFO Team Member Adapters
        if ($nic.Name -in $lbfoNicNames) {
            $native = $false
        }

        if ($native) {
            NetAdapterWorkerPrepare -NicName $nic.Name -OutDir $dir
        }
    }
} # NativeNicDetail()

function ChelsioDetailPerASIC {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$false)] [String] $NicName,
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $hwInfo       = Get-NetAdapterHardwareInfo -Name "$NicName"
    $locationInfo = $hwInfo.LocationInformationString
    $dirBusName   = "BusDev_$($hwInfo.BusNumber)_$($hwInfo.DeviceNumber)_$($hwInfo.FunctionNumber)"
    $dir          = Join-Path $OutDir $dirBusName

    if ($Global:ChelsioDeviceDirs.ContainsKey($locationInfo)) {
        New-LnkShortcut -LnkFile "$dir.lnk" -TargetPath $Global:ChelsioDeviceDirs[$locationInfo]
        return # avoid duplicate work
    } else {
        $Global:ChelsioDeviceDirs[$locationInfo] = $dir
        $null = New-Item -ItemType Directory -Path $dir
    }

    # Enumerate VBD
    $ifNameVbd = ""
    [Array] $PnPDevices = Get-PnpDevice -FriendlyName "*Chelsio*Enumerator*" | where {$_.Status -eq "OK"}
    for ($i = 0; $i -lt $PnPDevices.Count; $i++) {
        $instanceId = $PnPDevices[$i].InstanceId
        $locationInfo = (Get-PnpDeviceProperty -InstanceId "$instanceId" -KeyName "DEVPKEY_Device_LocationInfo").Data
        if ($hwInfo.LocationInformationString -eq $locationInfo) {
            $ifNameVbd = "vbd$i"
            break
        }
    }

    if ([String]::IsNullOrEmpty($ifNameVbd)) {
        $msg =  "$NicName : Couldn't resolve interface name for bus device."
        ExecControlError -OutDir $dir -Function "ChelsioDetailPerASIC" -Message $msg
        return
    }

    $file = "ChelsioDetail-Firmware-BusDevice$i.txt"
    [String []] $cmds = "cxgbtool.exe $ifNameVbd firmware mbox 1",
                        "cxgbtool.exe $ifNameVbd firmware mbox 2",
                        "cxgbtool.exe $ifNameVbd firmware mbox 3",
                        "cxgbtool.exe $ifNameVbd firmware mbox 4",
                        "cxgbtool.exe $ifNameVbd firmware mbox 5",
                        "cxgbtool.exe $ifNameVbd firmware mbox 6",
                        "cxgbtool.exe $ifNameVbd firmware mbox 7"
    ExecCommands -OutDir $dir -File $file -Commands $cmds

    $file = "ChelsioDetail-Hardware-BusDevice$i.txt"
    [String []] $cmds = "cxgbtool.exe $ifNameVbd hardware sgedbg"
    ExecCommands -OutDir $dir -File $file -Commands $cmds

    $file = "ChelsioDetail-Dumps-BusDevice$i.txt"
    [String []] $cmds = "cxgbtool.exe $ifNameVbd hardware flash ""$dir\Hardware-BusDevice$i-flash.dmp""",
                        "cxgbtool.exe $ifNameVbd cudbg collect all ""$dir\Cudbg-Collect.dmp""",
                        "cxgbtool.exe $ifNameVbd cudbg readflash ""$dir\Cudbg-Readflash.dmp"""
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds
} # ChelsioDetailPerASIC()

function ChelsioDetail {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$false)] [String] $NicName,
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $dir = (Join-Path -Path $OutDir -ChildPath "ChelsioDetail")
    New-Item -ItemType Directory -Path $dir | Out-Null

    $file = "ChelsioDetail-Misc.txt"
    [String []] $cmds = "verifier /query",
                        "Get-PnpDevice -FriendlyName ""*Chelsio*Enumerator*"" | Get-PnpDeviceProperty -KeyName DEVPKEY_Device_DriverVersion | Format-Table -Autosize"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    # Check path for cxgbtool.exe, since it's needed to collect most Chelsio related logs.
    if (-not (Get-Command "cxgbtool.exe" -ErrorAction SilentlyContinue)) {
        $msg = "Unable to collect Chelsio debug logs as cxgbtool is not present."
        ExecControlError -OutDir $dir -Function "ChelsioDetail" -Message $msg
        return
    }

    ChelsioDetailPerASIC -NicName $NicName -OutDir $dir

    $ifIndex    = (Get-NetAdapter $NicName).InterfaceIndex
    $dirNetName = "NetDev_$ifIndex"
    $dirNet     = (Join-Path -Path $dir -ChildPath $dirNetName)
    New-Item -ItemType Directory -Path $dirNet | Out-Null

    # Enumerate NIC
    [Array] $NetDevices = Get-NetAdapter -InterfaceDescription "*Chelsio*" | where {$_.Status -eq "Up"} | Sort-Object -Property MacAddress
    $ifNameNic = $null
    for ($i = 0; $i -lt $NetDevices.Count; $i++) {
        if ($NicName -eq $NetDevices[$i].Name) {
            $ifNameNic = "nic$i"
            break
        }
    }

    if ([String]::IsNullOrEmpty($ifNameNic)) {
        $msg = "Couldn't resolve interface name for Network device(ifIndex:$ifIndex)"
        ExecControlError -OutDir $dir -Function "ChelsioDetail" -Message $msg
        return
    }

    $file = "ChelsioDetail-Debug.txt"
    [String []] $cmds = "cxgbtool.exe $ifNameNic debug filter",
                        "cxgbtool.exe $ifNameNic debug qsets",
                        "cxgbtool.exe $ifNameNic debug qstats txeth rxeth txvirt rxvirt txrdma rxrdma txnvgre rxnvgre",
                        "cxgbtool.exe $ifNameNic debug dumpctx",
                        "cxgbtool.exe $ifNameNic debug version",
                        "cxgbtool.exe $ifNameNic debug eps",
                        "cxgbtool.exe $ifNameNic debug qps",
                        "cxgbtool.exe $ifNameNic debug rdma_stats",
                        "cxgbtool.exe $ifNameNic debug stags",
                        "cxgbtool.exe $ifNameNic debug l2t"
    ExecCommandsAsync -OutDir $dirNet -File $file -Commands $cmds

    $file = "ChelsioDetail-Hardware.txt"
    [String []] $cmds = "cxgbtool.exe $ifNameNic hardware tid_info",
                        "cxgbtool.exe $ifNameNic hardware fec",
                        "cxgbtool.exe $ifNameNic hardware link_cfg",
                        "cxgbtool.exe $ifNameNic hardware pktfilter",
                        "cxgbtool.exe $ifNameNic hardware sensor"
    ExecCommandsAsync -OutDir $dirNet -File $file -Commands $cmds
} # ChelsioDetail()

function MellanoxFirmwareInfo {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$false)] [String] $NicName,
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $dir  = $OutDir

    $mstStatus = TryCmd {mst status -v}
    if ((-not $mstStatus) -or ($mstStatus -like "*error*")) {
        $msg = "MFT is not installed on this server"
        ExecControlError -OutDir $dir -Function "MellanoxFirmwareInfo" -Message $msg
        return
    }

    #
    # Parse "mst status" output and match to Nic
    #
    [Bool] $found = $false
    $hwInfo = Get-NetAdapterHardwareInfo -Name $NicName

    foreach ($line in ($mstStatus | where {$_ -like "*pciconf*"})) {
        $device, $info = $line.Trim() -split " "
        $busNum, $deviceNum, $functionNum = $info -split "[:.=]" | select -Last 3 | foreach {[Int64]"0x$_"}

        if (($hwInfo.Bus -eq $busNum) -and ($hwInfo.Device -eq $deviceNum) -and ($hwInfo.Function -eq $functionNum)) {
            $found = $true;
            $device = $device.Trim()
            break
        }
    }

    if (-not $found) {
        $msg = "No matching device found in mst status"
        ExecControlError -OutDir $dir -Function "MellanoxFirmwareInfo" -Message $msg
        return
    }

    $deviceDir = Join-Path $dir "mstdump-$device"
    $null = New-Item -ItemType Directory -Path $deviceDir

    $file = "MellanoxFirmwareInfo.txt"
    [String[]] $cmds = "mst status",
                       "flint -d $device query",
                       "flint -d $device dc",
                       "mstdump $device >> ""$deviceDir\1.txt""",
                       "mstdump $device >> ""$deviceDir\2.txt""",
                       "mstdump $device >> ""$deviceDir\3.txt""",
                       "mlxconfig -d $device query",
                       "mlxdump -d $device fsdump --type FT"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds
} # MellanoxFirmwareInfo()

function MellanoxWinOFTool{
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$false)] [String] $NicName,
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $dir = $OutDir

    $toolName = "mlxtool.exe"
    $toolPath = "$env:ProgramFiles\Mellanox\MLNX_VPI\Tools\$toolName"
    $mlxTool = "&""$toolPath"""

    $hardwareInfo = Get-NetAdapterHardwareInfo -Name $NicName
    $deviceLocation = "$($hardwareInfo.bus)`_$($hardwareInfo.device)`_$($hardwareInfo.function)"

    $toolCmds = "$mlxTool show ports",
                "$mlxTool show devices",
                "$mlxTool show tc-bw",
                "$mlxTool show vxlan",
                "$mlxTool show ecn config",
                "$mlxTool show packet-filter",
                "$mlxTool show qos",
                "$mlxTool show regkeys all miniport",
                "$mlxTool show regkeys all bus",
                "$mlxTool show nd connections",
                "$mlxTool show ndk connections",
                "$mlxTool show perfstats ""$NicName"" showall",
                "$mlxTool show driverparams",
                "$mlxTool show selfhealing port",
                "$mlxTool dbg oid-stats-ext",
                "$mlxTool dbg cmd-stats-ext",
                "$mlxTool dbg resources",
                "$mlxTool dbg pkeys",
                "$mlxTool dbg ipoib-ep",
                "$mlxTool dbg get-state",
                "$mlxTool dbg rfd-profiling ""$NicName"" dump",
                "$mlxTool dbg pddrinfo",
                "$mlxTool dbg dump-me-now",
                "$mlxTool dbg eq-data ""$deviceLocation""",
                "$mlxTool dbg dma-cached-stats ""$deviceLocation"""

    $file = "mlxtoolOutput.txt"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $toolCmds

} # MellanoxWinOFTool

function MellanoxDetailPerNic {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$false)] [String] $NicName,
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $dir = $OutDir

    $driverFileName = (Get-NetAdapter -name $NicName).DriverFileName
    $driverDir = switch ($driverFileName) {
        "mlx5.sys" {
            "$env:ProgramFiles\Mellanox\MLNX_WinOF2"
            break
        }
        "mlnx5.sys" {
            "$env:ProgramFiles\Mellanox\MLNX_WinOF2_Azure"
            break
        }
        "mlnx5hpc.sys" {
            "$env:ProgramFiles\Mellanox\MLNX_WinOF2_Azure_HPC"
            break
        }
        "ipoib6x.sys" {
            "$env:ProgramFiles\Mellanox\MLNX_VPI"
            break
        }
        "mlx4eth63.sys" {
            "$env:ProgramFiles\Mellanox\MLNX_VPI"
            break
        }
        default {
            $msg = "Driver $driverFileName isn't supported"
            ExecControlError -OutDir $dir -Function"MellanoxDetailPerNic" -Message $msg
            return
        }
    }

    #
    # Execute tool
    #

    $DriverName = $( if ($driverFileName -in @("Mlx5.sys", "Mlnx5.sys", "Mlnx5Hpc.sys")) {"WinOF2"} else {"WinOF"})
    if ($DriverName -eq "WinOF2"){
        $toolName = $driverFileName -replace ".sys", "Cmd"
        $toolPath = "$driverDir\Management Tools\$toolName.exe"

        $file = "$toolName-Snapshot.txt"
        [String []] $cmds = "&""$toolPath"" -SnapShot -name ""$NicName"""
        (Get-NetAdapterSriovVf -Name "$NicName" -ErrorAction SilentlyContinue).FunctionID | foreach {
            $cmds += "&""$toolPath"" -SnapShot -VfStats -name ""$NicName"" -vf $_ -register"
        }
        ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds
    } else {
        MellanoxWinOFTool -NicName $NicName -OutDir $Dir
    }

    #
    # Enumerate device location string
    #
    if ((Get-NetAdapter -Name $NicName).InterfaceDescription -like "*Mellanox*Virtual*Adapter*") {
        [String[]] $locationInfoArray = (Get-NetAdapterHardwareInfo -Name $NicName).LocationInformationString -split " "

        $slot   = $locationInfoArray[$locationInfoArray.IndexOf("Slot") + 1]
        $serial = $locationInfoArray[$locationInfoArray.IndexOf("Serial") + 1]

        $deviceLocation = "$slot`_$serial`_0"
    } else {
        $hardwareInfo = Get-NetAdapterHardwareInfo -Name $NicName
        $deviceLocation = "$($hardwareInfo.bus)`_$($hardwareInfo.device)`_$($hardwareInfo.function)"
    }

    #
    # Dump Me Now (DMN)
    #
    $deviceID     = (Get-NetAdapter -name $NicName).PnPDeviceID
    $driverRegKey = (Get-ItemProperty "HKLM:\System\CurrentControlSet\Enum\$deviceID").Driver
    $dumpMeNowDir = (Get-ItemProperty "HKLM:\System\CurrentControlSet\Control\Class\$driverRegKey").DumpMeNowDirectory

    if (($dumpMeNowDir -like "\DosDevice\*") -or ($dumpMeNowDir -like "\??\*")) {
        $dmpPath = $dumpMeNowDir.SubString($dumpMeNowDir.IndexOf("\", 1))
    } else {
        $dmpPath = "$env:windir\Temp\MLX{0}_Dump_Me_Now" -f $(if ($DriverName -eq "WinOF2") {"5"} else {"4"})
    }

    $file = "Copy-MellanoxDMN.txt"
    [String[]] $paths = "$dmpPath{0}" -f $(if ($DriverName -eq "WinOF2") {("-" + $deviceLocation -replace "_","-")})
    ExecCopyItemsAsync -OutDir $dir -File $file -Paths $paths -Destination $dir

    #
    # Device logs
    #

    $file = "Copy-DeviceLogs.txt"
    $destination = Join-Path $dir "DeviceLogs"
    $buildIdPath = "$driverDir\build_id.txt"

    ExecCopyItemsAsync -OutDir $dir -File $file -Paths $buildIdPath -Destination $destination

    if ($DriverName -eq "WinOF2"){
        [String[]] $paths = "$env:windir\Temp\SingleFunc*$deviceLocation*.log",
                            "$env:windir\Temp\SriovMaster*$deviceLocation*.log",
                            "$env:windir\Temp\SriovSlave*$deviceLocation*.log",
                            "$env:windir\Temp\Native*$deviceLocation*.log",
                            "$env:windir\Temp\Master*$deviceLocation*.log",
                            "$env:windir\Temp\ML?X5*$deviceLocation*.log",
                            "$env:windir\Temp\mlx5*$deviceLocation*.log",
                            "$env:windir\Temp\FwTrace"
        ExecCopyItemsAsync -OutDir $dir -File $file -Paths $paths -Destination $destination
    }
} # MellanoxDetailPerNic()

function MellanoxSystemDetail {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$false)] [String] $NicName,
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $dir = Join-Path $OutDir "SystemLogs"

    if ([String]::IsNullOrEmpty($Global:MellanoxSystemLogDir)){
        $Global:MellanoxSystemLogDir = $dir
        $null = New-Item -ItemType Directory -Path $dir
    } else {
        New-LnkShortcut -LnkFile "$dir.lnk" -TargetPath $Global:MellanoxSystemLogDir
        return # avoid duplicate effort
    }

    $file = "MellanoxMiscInfo.txt"
    [String []] $cmds = "netsh advfirewall show allprofiles",
                        "netstat -n",
                        "netstat -nasert",
                        "netstat -an",
                        "netstat -xan | where {`$_ -match ""445""}",
                        "Get-SmbConnection",
                        "Get-SmbServerConfiguration"
    ExecCommands -OutDir $dir -File $file -Commands $cmds

    $driverFileName = (Get-NetAdapter -name $NicName).DriverFileName
    $DriverName = if ($driverFileName -in @("Mlx5.sys", "Mlnx5.sys", "Mlnx5Hpc.sys")) {"WinOF2"} else {"WinOF"}

    $file = "Copy-LogFiles.txt"
    $destination = Join-Path $dir "LogFiles"

    $mlxEtl = "Mellanox{0}.etl*" -f $(if ($DriverName -eq "WinOF2") {"-WinOF2*"} else {"-System*"})
    $mlxLog = "MLNX_WINOF{0}.log"  -f $(if ($DriverName -eq "WinOF2") {"2"})

    [String[]] $paths = "$env:windir\System32\LogFiles\PerformanceTuning.log",
                        "$env:LOCALAPPDATA\$mlxLog",
                        "$env:windir\inf\setupapi.dev",
                        "$env:windir\inf\setupapi.dev.log",
                        "$env:temp\MpKdTraceLog.bin",
                        "$env:windir\System32\LogFiles\Mlnx\$mlxEtl",
                        "$env:windir\debug\$mlxEtl"
    ExecCopyItemsAsync -OutDir $dir -File $file -Paths $paths -Destination $destination
} # MellanoxSystemDetail()

function MellanoxDetail {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$false)] [String] $NicName,
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $dir = (Join-Path -Path $OutDir -ChildPath "MellanoxDetail")
    New-Item -ItemType Directory -Path $dir | Out-Null

    $driverVersionString = (Get-NetAdapter -name $NicName).DriverVersionString
    $versionMajor, $versionMinor, $_ = $driverVersionString -split "\."

    if (($versionMajor -lt 2) -or (($versionMajor -eq 2) -and ($versionMinor -lt 20))) {
        $msg = "Driver version is $versionMajor.$versionMinor, which is less than 2.20"
        ExecControlError -OutDir $dir -Function "MellanoxDetail" -Message $msg
        return
    }

    MellanoxSystemDetail -NicName $NicName -OutDir $dir
    MellanoxFirmwareInfo -NicName $NicName -OutDir $dir
    MellanoxDetailPerNic -NicName $NicName -OutDir $dir
} # MellanoxDetail()

function MarvellDetail{
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $NicName,
        [parameter(Mandatory=$true)] [String] $OutDir
    )

$MarvellGetDiagDataClass = @"
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public class MarvellGetDiagData
{
    private const uint B100_IOC_GET_IHV_DIAGNOSTIC_DATA = 0x80002538;
    private const uint B10_IOC_GET_IHV_DIAGNOSTIC_DATA = 0x80002130;
    private const uint B10_IHV_COLLECT_MASK = 0xFFFFFFFF;
    private const uint B100_IHV_COLLECT_MASK = 0xFFFFFD7F;
    private const uint IHV_DIAG_REVISION = 0x01;
    private const int FILE_ATTRIBUTE_NORMAL = 0x00000080;
    private const int BYTE_SIZE = (9 * 1024 * 1024);
    public int code;

    [StructLayout(LayoutKind.Sequential)]
    public struct DiagInput_t
    {
        public uint revision;
        public uint data_mask;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)]
        public int[] reserved;
    }

    [DllImport("Kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern SafeFileHandle CreateFile(
        string lpFileName,
        [MarshalAs(UnmanagedType.U4)] FileAccess dwDesiredAccess,
        [MarshalAs(UnmanagedType.U4)] FileShare dwShareMode,
        IntPtr lpSecurityAttributes,
        [MarshalAs(UnmanagedType.U4)] FileMode dwCreationDisposition,
        [MarshalAs(UnmanagedType.U4)] FileAttributes dwFlagsAndAttributes,
        IntPtr hTemplateFile);

    [DllImport("Kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool DeviceIoControl(
        SafeFileHandle hDevice,
        uint IoControlCode,
        ref DiagInput_t InBuffer,
        int nInBufferSize,
        byte[] OutBuffer,
        int nOutBufferSize,
        ref int pBytesReturned,
        IntPtr Overlapped
        );

    public int MarvellGetDiagDataIoctl(string DeviceID, string FilePath, string ServiceName, StringBuilder ErrString)
    {
        bool bResult;
        string FileName = string.Format("DiagData.bin");
        uint data_mask_set;
        uint ioctl_value;
        string DevPath;
        int bytesReturned = 0;
        int bufSize = BYTE_SIZE;
        SafeFileHandle shwnd = null;
        FileStream file = null;

        if ((DeviceID == null) || (FilePath == null))
        {
            ErrString.Append("MarvellGetDiagDataIoctl: Input parameter to MarvellGetDiagDataIoctl is invalid");
            return 0;
        }

        try
        {
            // Generate device path from device id.
            DevPath = "\\\\?\\Global\\" + DeviceID.Replace("\\","#");

            if (ServiceName.Equals("QEBDRV", StringComparison.OrdinalIgnoreCase))
            {
                data_mask_set = B100_IHV_COLLECT_MASK;
                ioctl_value = B100_IOC_GET_IHV_DIAGNOSTIC_DATA;
                DevPath += "#{5966d73c-bc2c-49b8-9315-c64c9919e976}";
            }
            else if (ServiceName.Equals("EBDRV", StringComparison.OrdinalIgnoreCase))
            {
                data_mask_set = B10_IHV_COLLECT_MASK;
                ioctl_value = B10_IOC_GET_IHV_DIAGNOSTIC_DATA;
                DevPath += "#{ea22615e-c443-434f-9e45-c4e32d83e97d}";
            }
            else
            {
                ErrString.Append("MarvellGetDiagDataIoctl: Invalid or not supported Service (" + ServiceName + ")");
                return 0;
            }

            shwnd = CreateFile(DevPath, FileAccess.Write | FileAccess.Read, FileShare.Read |
                FileShare.Write, IntPtr.Zero, FileMode.Open, FileAttributes.Normal, IntPtr.Zero);
            if (shwnd.IsClosed | shwnd.IsInvalid)
            {
                ErrString.Append("MarvellGetDiagDataIoctl: CreateFile failed with error " + Marshal.GetLastWin32Error());
                return 0;
            }

            byte[] OutBuffer = new byte[bufSize];
            Array.Clear(OutBuffer, 0, OutBuffer.Length);

            DiagInput_t InBuffer = new DiagInput_t
            {
                revision = IHV_DIAG_REVISION,
                data_mask = data_mask_set
            };

            bResult = DeviceIoControl(shwnd, ioctl_value, ref InBuffer, Marshal.SizeOf(InBuffer),
                OutBuffer, bufSize, ref bytesReturned, IntPtr.Zero);
            if (bResult)
            {
                FilePath += "\\" + FileName;

                file = File.Create(FilePath);
                file.Write(OutBuffer, 0, bytesReturned);
            }
            else
            {
                ErrString.Append("MarvellGetDiagDataIoctl: DeviceIoControl failed with error " + Marshal.GetLastWin32Error());
                bytesReturned = 0;
            }
        }
        catch (Exception e)
        {
            ErrString.Append("MarvellGetDiagDataIoctl: Exception generated: " + e.Message);
        }
        finally
        {
            if (file != null)
            {
                file.Close();
            }
            if (shwnd != null)
            {
                shwnd.Close();
            }
        }

        return bytesReturned;
    }
}
"@

    try {
        $NDIS_DeviceID = (Get-NetAdapter -Name $NicName).PnPDeviceID
        $VBD_DeviceID = (Get-PnpDeviceProperty -InstanceId "$NDIS_DeviceID" -KeyName "DEVPKEY_Device_Parent").Data
        $VBD_Service = (Get-PnpDeviceProperty -InstanceId "$VBD_DeviceID" -KeyName "DEVPKEY_Device_Service").Data

        $file = "$NicName-BusVerifierInfo.txt"
        [String []] $cmds = "verifier /query",
                            "Get-PnpDeviceProperty -InstanceId '$VBD_DeviceID' | Select-Object KeyName, Data | Format-Table -AutoSize"
        ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

        $file = "$NicName-NicVerifierInfo.txt"
        [String []] $cmds = "verifier /query",
                            "Get-PnpDeviceProperty -InstanceId '$NDIS_DeviceID' | Select-Object KeyName, Data | Format-Table -Autosize"
        ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

        TryCmd {Add-Type -TypeDefinition $MarvellGetDiagDataClass -ErrorAction Stop}

        $r = New-Object -TypeName MarvellGetDiagData

        $rrrorString = New-Object -TypeName "System.Text.StringBuilder";
        $Output = $r.MarvellGetDiagDataIoctl($VBD_DeviceID, $OutDir, $VBD_Service, $rrrorString)
        if ($Output -le 0) {
            ExecControlError -OutDir $OutDir -Function "MarvellDetail" -Message $rrrorString.ToString()
        }
    } catch {
        $msg = $($error[0] | Out-String)
        ExecControlError -OutDir $OutDir -Function "MarvellDetail" -Message $msg
    } finally {
        Remove-Variable MarvellGetDiagDataClass -ErrorAction SilentlyContinue
    }

} # Marvell Detail

# ========================================================================
# function stub for extension by IHV
# Copy and rename it, add your commands, and call it in NicVendor() below
# ========================================================================
function MyVendorDetail {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$false)] [String] $NicName,
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $dir = Join-Path -Path $OutDir -ChildPath "MyVendorDetail"

    # Try to keep the layout of this block of code
    # Feel free to copy it or wrap it in other control structures
    # See other functions in this file for examples
    $file = "$NicName.MyVendor.txt"
    [String []] $cmds = "Command 1",
                        "Command 2",
                        "Command 3",
                        "etc."
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds
} # MyVendorDetail()

function NicVendor {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $NicName, # Get-NetAdapter output
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $dir = $OutDir

    # Call appropriate vendor specific function
    $pciId = (Get-NetAdapterAdvancedProperty -Name $NicName -AllProperties -RegistryKeyword "ComponentID").RegistryValue
    switch -Wildcard($pciId) {
        "CHT*BUS\chnet*" {
            ChelsioDetail  $NicName $dir
            break
        }
        "PCI\VEN_15B3*" {
            MellanoxDetail $NicName $dir
            break
        }
        "*ConnectX-3*" {
            MellanoxDetail $NicName $dir
            break
        }
        "*EBDRV\L2ND*" {
            MarvellDetail  $NicName $dir
        }
        # Not implemented.  See MyVendorDetail() for examples.
        #
        #"PCI\VEN_8086*" {
        #    IntelDetail $Nic $dir
        #    break
        #}
        default {
            # Not implemented, not native, or N/A
        }
    }
} # NicVendor()

function HostVNicWorker {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$false)] [String] $HostVNicName, # Note: "" is a valid Host vNIC name.
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $name = $HostVNicName
    $dir  = $OutDir

    $file = "Get-VMNetworkAdapter.txt"
    [String []] $cmds = "Get-VMNetworkAdapter -ManagementOS -VMNetworkAdapterName ""$name"" | Out-String -Width $columns",
                        "Get-VMNetworkAdapter -ManagementOS -VMNetworkAdapterName ""$name"" | Format-List  -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMNetworkAdapterAcl.txt"
    [String []] $cmds = "Get-VMNetworkAdapterAcl -ManagementOS -VMNetworkAdapterName ""$name"" | Out-String -Width $columns",
                        "Get-VMNetworkAdapterAcl -ManagementOS -VMNetworkAdapterName ""$name"" | Format-List  -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMNetworkAdapterExtendedAcl.txt"
    [String []] $cmds = "Get-VMNetworkAdapterExtendedAcl -ManagementOS -VMNetworkAdapterName ""$name"" | Out-String -Width $columns",
                        "Get-VMNetworkAdapterExtendedAcl -ManagementOS -VMNetworkAdapterName ""$name"" | Format-List  -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMNetworkAdapterFailoverConfiguration.txt"
    [String []] $cmds = "Get-VMNetworkAdapterFailoverConfiguration -ManagementOS -VMNetworkAdapterName ""$name"" | Out-String -Width $columns",
                        "Get-VMNetworkAdapterFailoverConfiguration -ManagementOS -VMNetworkAdapterName ""$name"" | Format-List  -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMNetworkAdapterIsolation.txt"
    [String []] $cmds = "Get-VMNetworkAdapterIsolation -ManagementOS -VMNetworkAdapterName ""$name"" | Out-String -Width $columns",
                        "Get-VMNetworkAdapterIsolation -ManagementOS -VMNetworkAdapterName ""$name"" | Format-List  -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMNetworkAdapterRoutingDomainMapping.txt"
    [String []] $cmds = "Get-VMNetworkAdapterRoutingDomainMapping -ManagementOS -VMNetworkAdapterName ""$name"" | Out-String -Width $columns",
                        "Get-VMNetworkAdapterRoutingDomainMapping -ManagementOS -VMNetworkAdapterName ""$name"" | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMNetworkAdapterTeamMapping.txt"
    [String []] $cmds = "Get-VMNetworkAdapterTeamMapping -ManagementOS -VMNetworkAdapterName ""$name"" | Out-String -Width $columns",
                        "Get-VMNetworkAdapterTeamMapping -ManagementOS -VMNetworkAdapterName ""$name"" | Format-List  -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMNetworkAdapterVlan.txt"
    [String []] $cmds = "Get-VMNetworkAdapterVlan -ManagementOS -VMNetworkAdapterName ""$name"" | Out-String -Width $columns",
                        "Get-VMNetworkAdapterVlan -ManagementOS -VMNetworkAdapterName ""$name"" | Format-List  -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds
} # HostVNicWorker()

function HostVNicDetail {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$false)] [String] $VMSwitchId,
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    # Cache output
    $allNetAdapters = Get-NetAdapter

    foreach ($hnic in TryCmd {Get-VMNetworkAdapter -ManagementOS} | where {$_.SwitchId -eq $VMSwitchId}) {
        # Use device ID to find corresponding NetAdapter instance
        $vnic = $allNetAdapters | where {$_.DeviceID -eq $hnic.DeviceID}

        # Create dir for the hNIC
        $ifIndex = $vnic.InterfaceIndex
        $title   = "hNic.$ifIndex.$($hnic.Name)"

        $dir     = Join-Path $OutDir $(ConvertTo-Filename $title)
        New-Item -ItemType directory -Path $dir | Out-Null

        Write-Progress -Activity $Global:QueueActivity -Status "Processing $title"
        HostVNicWorker   -HostVNicName $hnic.Name -OutDir $dir
        NetAdapterWorker -NicName      $vnic.Name -OutDir $dir
        NetIpNic         -NicName      $vnic.Name -OutDir $dir
    }
} # HostVNicDetail()

function VMNetworkAdapterDetail {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$false)] [String] $VMName,
        [parameter(Mandatory=$false)] [String] $VMNicName,
        [parameter(Mandatory=$false)] [String] $VMNicId,
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $name  = $VMNicName
    $id    = $VMNicId
    $title = "VMNic.$name.$id"

    $dir  = Join-Path $OutDir $(ConvertTo-Filename $title)
    $null = New-Item -ItemType directory -Path $dir

    # We must use Id to identity VMNics, because different VMNics
    # can have the same MAC (if VM is off), Name, VMName, and SwitchName.
    [String] $vmNicObject = "`$(Get-VMNetworkAdapter -VMName ""$VMName"" -Name ""$VMNicName"" | where {`$_.Id -like ""*$id""})"

    Write-Progress -Activity $Global:QueueActivity -Status "Processing $title"
    $file = "Get-VMNetworkAdapter.txt"
    [String []] $cmds = "$vmNicObject | Out-String -Width $columns",
                        "$vmNicObject | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMNetworkAdapterAcl.txt"
    [String []] $cmds = "Get-VMNetworkAdapterAcl -VMNetworkAdapter $vmNicObject | Out-String -Width $columns",
                        "Get-VMNetworkAdapterAcl -VMNetworkAdapter $vmNicObject | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMNetworkAdapterExtendedAcl.txt"
    [String []] $cmds = "Get-VMNetworkAdapterExtendedAcl -VMNetworkAdapter $vmNicObject | Out-String -Width $columns",
                        "Get-VMNetworkAdapterExtendedAcl -VMNetworkAdapter $vmNicObject | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMNetworkAdapterFailoverConfiguration.txt"
    [String []] $cmds = "Get-VMNetworkAdapterFailoverConfiguration -VMNetworkAdapter $vmNicObject | Out-String -Width $columns",
                        "Get-VMNetworkAdapterFailoverConfiguration -VMNetworkAdapter $vmNicObject | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMNetworkAdapterIsolation.txt"
    [String []] $cmds = "Get-VMNetworkAdapterIsolation -VMNetworkAdapter $vmNicObject | Out-String -Width $columns",
                        "Get-VMNetworkAdapterIsolation -VMNetworkAdapter $vmNicObject | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMNetworkAdapterRoutingDomainMapping.txt"
    [String []] $cmds = "Get-VMNetworkAdapterRoutingDomainMapping -VMNetworkAdapter $vmNicObject | Out-String -Width $columns",
                        "Get-VMNetworkAdapterRoutingDomainMapping -VMNetworkAdapter $vmNicObject | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMNetworkAdapterTeamMapping.txt"
    [String []] $cmds = "Get-VMNetworkAdapterTeamMapping -VMNetworkAdapter $vmNicObject | Out-String -Width $columns",
                        "Get-VMNetworkAdapterTeamMapping -VMNetworkAdapter $vmNicObject | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMNetworkAdapterVlan.txt"
    [String []] $cmds = "Get-VMNetworkAdapterVlan -VMNetworkAdapter $vmNicObject | Out-String -Width $columns",
                        "Get-VMNetworkAdapterVlan -VMNetworkAdapter $vmNicObject | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMSwitchExtensionPortFeature.txt"
    [String []] $cmds = "Get-VMSwitchExtensionPortFeature -VMNetworkAdapter $vmNicObject | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMSwitchExtensionPortData.txt"
    [String []] $cmds = "Get-VMSwitchExtensionPortData -VMNetworkAdapter $vmNicObject | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds
} # VMNetworkAdapterDetail()

function VMWorker {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$false)] [String] $VMId,
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $id  = $VMId
    $dir = $OutDir

    # Different VMs can have the same name
    [String] $vmObject = "`$(Get-VM -Id $id)"

    $file = "Get-VM.txt"
    [String []] $cmds = "$vmObject | Out-String -Width $columns",
                        "$vmObject | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMBios.txt"
    [String []] $cmds = "Get-VMBios -VM $vmObject | Out-String -Width $columns",
                        "Get-VMBios -VM $vmObject | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMFirmware.txt"
    [String []] $cmds = "Get-VMFirmware -VM $vmObject | Out-String -Width $columns",
                        "Get-VMFirmware -VM $vmObject | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMProcessor.txt"
    [String []] $cmds = "Get-VMProcessor -VM $vmObject | Out-String -Width $columns",
                        "Get-VMProcessor -VM $vmObject | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMMemory.txt"
    [String []] $cmds = "Get-VMMemory -VM $vmObject | Out-String -Width $columns",
                        "Get-VMMemory -VM $vmObject | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMVideo.txt"
    [String []] $cmds = "Get-VMVideo -VM $vmObject | Out-String -Width $columns",
                        "Get-VMVideo -VM $vmObject | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMHardDiskDrive.txt"
    [String []] $cmds = "Get-VMHardDiskDrive -VM $vmObject | Out-String -Width $columns",
                        "Get-VMHardDiskDrive -VM $vmObject | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMComPort.txt"
    [String []] $cmds = "Get-VMComPort -VM $vmObject | Out-String -Width $columns",
                        "Get-VMComPort -VM $vmObject | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMSecurity.txt"
    [String []] $cmds = "Get-VMSecurity -VM $vmObject | Out-String -Width $columns",
                        "Get-VMSecurity -VM $vmObject | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds
} # VMWorker()

function VMNetworkAdapterPerVM {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$false)] [String] $VMSwitchId,
        [parameter(Mandatory=$true)]  [String] $OutDir
    )

    if (-not $SkipVm) {
        [Int] $index = 1
        foreach ($vm in TryCmd {Get-VM}) {
            $vmName = $vm.Name
            $vmId   = $vm.VMId
            $title  = "VM.$index.$vmName"
            $dir    = Join-Path $OutDir $(ConvertTo-Filename $title)

            $vmQuery = $false
            foreach ($vmNic in TryCmd {Get-VMNetworkAdapter -VM $vm} | where {$_.SwitchId -eq $VMSwitchId}) {
                $vmNicId = ($vmNic.Id -split "\\")[1] # Same as AdapterId, but works if VM is off
                if (-not $vmQuery)
                {
                    Write-Progress -Activity $Global:QueueActivity -Status "Processing $title"
                    New-Item -ItemType "Directory" -Path $dir | Out-Null
                    VMWorker -VMId $vmId -OutDir $dir
                    $vmQuery = $true
                }
                VMNetworkAdapterDetail -VMName $vmName -VMNicName $vmNic.Name -VMNicId $vmNicId -OutDir $dir
            }
            $index++
        }
    }
} # VMNetworkAdapterPerVM()

function VMSwitchWorker {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$false)] [String] $VMSwitchId,
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $id  = $VMSwitchId
    $dir = $OutDir

    $vmSwitchObject = "`$(Get-VMSwitch -Id $id)"

    $file = "Get-VMSwitch.txt"
    [String []] $cmds = "$vmSwitchObject",
                        "$vmSwitchObject | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMSwitchExtension.txt"
    [String []] $cmds = "Get-VMSwitchExtension -VMSwitch $vmSwitchObject | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMSwitchExtensionSwitchData.txt"
    [String []] $cmds = "Get-VMSwitchExtensionSwitchData -VMSwitch $vmSwitchObject | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMSwitchExtensionSwitchFeature.txt"
    [String []] $cmds = "Get-VMSwitchExtensionSwitchFeature -VMSwitch $vmSwitchObject | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMSwitchTeam.txt"
    [String []] $cmds = "Get-VMSwitchTeam -VMSwitch $vmSwitchObject | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMNetworkAdapterTeamMapping.txt"
    [String []] $cmds = "Get-VMNetworkAdapterTeamMapping -ManagementOS -SwitchName $vmSwitchObject | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds
} # VMSwitchWorker()

function VfpExtensionDetail {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$false)] [String] $VMSwitchId,
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    #FIXME: Find a non-vSwitch CMDLET mechanism to dump the VFP settings
    #       Necessary for HNS scenarios where vSwitch CMDLETs are not available
    $id = $VMSwitchId
    $vfpExtension = TryCmd {Get-VMSwitch -Id $id | Get-VMSwitchExtension} | where {$_.Name -like "Microsoft Azure VFP Switch Extension"}

    if ($vfpExtension.Enabled -ne "True") {
        return
    }

    $dir  = (Join-Path -Path $OutDir -ChildPath "VFP")
    New-Item -ItemType directory -Path $dir | Out-Null

    $file = "VfpCtrl.help.txt"
    [String []] $cmds = "vfpctrl.exe /h"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-CimInstance.CIM_DataFile.vfpext.txt"
    $vfpExtPath = ((Join-Path $env:SystemRoot "System32\drivers\vfpext.sys") -replace "\\","\\")
    [String []] $cmds = "Get-CimInstance -ClassName ""CIM_DataFile"" -Filter ""Name='$vfpExtPath'"""
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $currSwitch = Get-CimInstance -Filter "Name='$id'" -ClassName "Msvm_VirtualEthernetSwitch" -Namespace "Root\Virtualization\v2"
    $ports = Get-CimAssociatedInstance -InputObject $currSwitch -ResultClassName "Msvm_EthernetSwitchPort"

    foreach ($portGuid in $ports.Name) {
        $file = "VfpCtrl.PortGuid.$portGuid.txt"
        [String []] $cmds = "vfpctrl.exe /list-vmswitch-port",
                            "vfpctrl.exe /list-space /port $portGuid",
                            "vfpctrl.exe /list-mapping /port $portGuid",
                            "vfpctrl.exe /list-rule /port $portGuid",
                            "vfpctrl.exe /port $portGuid /get-port-state"
        ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds
    }
} # VfpExtensionDetail()

function VMSwitchDetail {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    # Acquire switch properties/settings via CMD tools
    $dir  = (Join-Path -Path $OutDir -ChildPath "VMSwitch.Detail")
    New-Item -ItemType directory -Path $dir | Out-Null

    $file = "VmspRegistry.txt"
    [String []] $cmds = "Get-ChildItem HKLM:\SYSTEM\CurrentControlSet\Services\vmsmp -Recurse"
    ExecCommands -OutDir $dir -File $file -Commands $cmds

    $file = "NvspInfo.txt"
    [String []] $cmds = "nvspinfo -a -i -h -D -p -d -m -q "
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "NvspInfo_bindings.txt"
    [String []] $cmds = "nvspinfo -a -i -h -D -p -d -m -q -b "
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "NvspInfo_ExecMon.txt"
    [String []] $cmds = "nvspinfo -X --count --sort max ",
                        "nvspinfo -X --count IOCTL --sort max",
                        "nvspinfo -X --count OID --sort max",
                        "nvspinfo -X --count WORKITEM --sort max",
                        "nvspinfo -X --count RNDIS --sort max"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "NmScrub.txt"
    [String []] $cmds = "nmscrub -a -n -t "
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    # FIXME!!!
    # See this command to get VFs on vSwitch
    # Get-NetAdapterSriovVf -SwitchId 2

    # Acquire per vSwitch instance info/mappings
    [Int] $index = 1
    foreach ($vmSwitch in TryCmd {Get-VMSwitch}) {
        $name  = $vmSwitch.Name
        $type  = $vmSwitch.SwitchType
        $id    = $vmSwitch.Id
        $title = "VMSwitch.$index.$type.$name"

        $dir  =  Join-Path $OutDir $(ConvertTo-Filename $title)
        New-Item -ItemType directory -Path $dir | Out-Null

        Write-Progress -Activity $Global:QueueActivity -Status "Processing $title"
        VfpExtensionDetail    -VMSwitchId $id -OutDir $dir
        VMSwitchWorker        -VMSwitchId $id -OutDir $dir
        ProtocolNicDetail     -VMSwitchId $id -OutDir $dir
        HostVNicDetail        -VMSwitchId $id -OutDir $dir
        VMNetworkAdapterPerVM -VMSwitchId $id -OutDir $dir

        $index++
    }
} # VMSwitchDetail()

function NetworkSummary {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $dir = $OutDir

    $file = "Get-NetOffloadGlobalSetting.txt"
    [String []] $cmds = "Get-NetOffloadGlobalSetting",
                        "Get-NetOffloadGlobalSetting | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMSwitch.txt"
    [String []] $cmds = "Get-VMSwitch | Sort-Object Name | Format-Table -AutoSize | Out-String -Width $columns",
                        "Get-VMSwitch | Sort-Object Name | Format-Table -Property * -AutoSize | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMNetworkAdapter.txt"
    [String []] $cmds = "Get-VmNetworkAdapter -All | Sort-Object IsManagementOS | Sort-Object SwitchName | Format-Table -AutoSize | Out-String -Width $columns",
                        "Get-VmNetworkAdapter -All | Sort-Object IsManagementOS | Sort-Object SwitchName | Format-Table -Property * -AutoSize | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetAdapter.txt"
    [String []] $cmds = "Get-NetAdapter -IncludeHidden | Sort-Object InterfaceDescription | Format-Table -AutoSize | Out-String -Width $columns ",
                        "Get-NetAdapter -IncludeHidden | Sort-Object InterfaceDescription | Format-Table -Property * -AutoSize | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetAdapterStatistics.txt"
    [String []] $cmds = "Get-NetAdapterStatistics -IncludeHidden | Sort-Object InterfaceDescription | Format-Table -Autosize  | Out-String -Width $columns",
                        "Get-NetAdapterStatistics -IncludeHidden | Sort-Object InterfaceDescription | Format-Table -Property * -Autosize | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetLbfoTeam.txt"
    [String []] $cmds = "Get-NetLbfoTeam | Sort-Object InterfaceDescription | Format-Table -Autosize  | Out-String -Width $columns",
                        "Get-NetLbfoTeam | Sort-Object InterfaceDescription | Format-Table -Property * -AutoSize  | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetIpAddress.txt"
    [String []] $cmds = "Get-NetIpAddress | Format-Table -Autosize | Format-Table -Autosize  | Out-String -Width $columns",
                        "Get-NetIpAddress | Format-Table -Property * -AutoSize | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "_ipconfig.txt"
    [String []] $cmds = "ipconfig",
                        "ipconfig /allcompartments /all"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "_arp.txt"
    [String []] $cmds = "arp -a"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "_netstat.txt"
    [String []] $cmds = "netstat -nasert",
                        "netstat -an",
                        "netstat -xan | ? {`$_ -match ""445""}"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "_nmbind.txt"
    [String []] $cmds = "nmbind"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds
    $file = "_advfirewall.txt"
    [String []] $cmds = "netsh advfirewall show allprofiles"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds
} # NetworkSummary()

function SMBDetail {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $dir = (Join-Path -Path $OutDir -ChildPath "SMB")
    New-Item -ItemType directory -Path $dir | Out-Null

    $file = "Get-SmbConnection.txt"
    [String []] $cmds = "Get-SmbConnection"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-SmbMapping.txt"
    [String []] $cmds = "Get-SmbMapping"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-SmbOpenFile.txt"
    [String []] $cmds = "Get-SmbOpenFile"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-SmbSession.txt"
    [String []] $cmds = "Get-SmbSession"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-SmbShare.txt"
    [String []] $cmds = "Get-SmbShare"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-SmbClientNetworkInterface.txt"
    [String []] $cmds = "Get-SmbClientNetworkInterface | Sort-Object FriendlyName | Format-Table -AutoSize | Out-String -Width $columns",
                        "Get-SmbClientNetworkInterface | Format-List  -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-SmbServerNetworkInterface.txt"
    [String []] $cmds = "Get-SmbServerNetworkInterface | Sort-Object FriendlyName | Format-Table -AutoSize | Out-String -Width $columns",
                        "Get-SmbServerNetworkInterface | Format-List  -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-SmbClientConfiguration.txt"
    [String []] $cmds = "Get-SmbClientConfiguration"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-SmbServerConfiguration.txt"
    [String []] $cmds = "Get-SmbServerConfiguration"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-SmbMultichannelConnection.txt"
    [String []] $cmds = "Get-SmbMultichannelConnection | Sort-Object Name | Format-Table -AutoSize | Out-String -Width $columns",
                        "Get-SmbMultichannelConnection -IncludeNotSelected | Format-List -Property *",
                        "Get-SmbMultichannelConnection -SmbInstance CSV -IncludeNotSelected | Format-List -Property *",
                        "Get-SmbMultichannelConnection -SmbInstance SBL -IncludeNotSelected | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-SmbMultichannelConstraint.txt"
    [String []] $cmds = "Get-SmbMultichannelConstraint"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-SmbBandwidthLimit.txt"
    [String []] $cmds = "Get-SmbBandwidthLimit"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Smb-WindowsEvents.txt"
    [String []] $cmds = "Get-WinEvent -ListLog ""*SMB*"" | Format-List -Property *",
                        "Get-WinEvent -FilterHashtable @{LogName=""Microsoft-Windows-SMB*""; ProviderName=""Microsoft-Windows-SMB*""} | where {`$_.Message -like ""*RDMA*""} | Format-List -Property *"

    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds
} # SMBDetail()

function NetSetupDetail {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $dir = (Join-Path -Path $OutDir -ChildPath "NetSetup")
    New-Item -ItemType directory -Path $dir | Out-Null

    $file = "NetSetup.txt"
    [String []] $paths = "$env:SystemRoot\System32\NetSetupMig.log",
                         "$env:SystemRoot\Panther\setupact.log",
                         "$env:SystemRoot\INF\setupapi.*",
                         "$env:SystemRoot\logs\NetSetup"
    ExecCopyItemsAsync -OutDir $dir -File $file -Paths $paths -Destination $dir
} # NetSetupDetail()

function HNSDetail {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    try {
        $null = Get-Service "hns" -ErrorAction Stop
    } catch {
        Write-Host "$($MyInvocation.MyCommand.Name): hns service not found, skipping."
        return
    }

    $dir = (Join-Path -Path $OutDir -ChildPath "HNS")
    New-Item -ItemType Directory -Path $dir | Out-Null

    # Data collected before stop -> start must be collected synchronously

    $file = "HNSRegistry-1.txt"
    [String []] $cmds = "Get-ChildItem HKLM:\SYSTEM\CurrentControlSet\Services\hns -Recurse",
                        "Get-ChildItem HKLM:\SYSTEM\CurrentControlSet\Services\vmsmp -Recurse"
    ExecCommands -OutDir $dir -File $file -Commands $cmds

    $file = "Get-HNSNetwork-1.txt"
    [String []] $cmds = "Get-HNSNetwork | ConvertTo-Json -Depth 10"
    ExecCommands -OutDir $dir -File $file -Commands $cmds

    $file = "Get-HNSEndpoint-1.txt"
    [String []] $cmds = "Get-HNSEndpoint | ConvertTo-Json -Depth 10"
    ExecCommands -OutDir $dir -File $file -Commands $cmds

    # HNS service stop -> start occurs after capturing the current HNS state info.
    $hnsRunning = (Get-Service hns).Status -eq "Running"
    try {
        if ($hnsRunning) {
            # Force stop to avoid command line prompt
            $null = net stop hns /y
        }

        $file = "HNSData.txt"
        [String []] $cmds = "Copy-Item -Path ""$env:ProgramData\Microsoft\Windows\HNS\HNS.data"" -Destination $dir -Verbose 4>&1"
        ExecCommands -OutDir $dir -File $file -Commands $cmds
    } finally {
        if ($hnsRunning) {
            $null = net start hns
        }
    }

    # Acquire all settings again after stop -> start services
    # From now on we can collect data asynchronously.
    $file = "HNSRegistry-2.txt"
    [String []] $cmds = "Get-ChildItem HKLM:\SYSTEM\CurrentControlSet\Services\hns -Recurse",
                        "Get-ChildItem HKLM:\SYSTEM\CurrentControlSet\Services\vmsmp -Recurse"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-HNSNetwork-2.txt"
    [String []] $cmds = "Get-HNSNetwork | ConvertTo-Json -Depth 10"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-HNSEndpoint-2.txt"
    [String []] $cmds = "Get-HNSEndpoint | ConvertTo-Json -Depth 10"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "HNSDiag_all.txt"
    [String []] $cmds = "HNSDiag list all"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "HNSDiag_all_d.txt"
    [String []] $cmds = "HNSDiag list all -d"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "HNSDiag_all_df.txt"
    [String []] $cmds = "HNSDiag list all -df"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "HNSDiag_all_dfl.txt"
    [String []] $cmds = "HNSDiag list all -dfl"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    #netsh trace start scenario=Virtualization provider=Microsoft-Windows-tcpip provider=Microsoft-Windows-winnat capture=yes captureMultilayer=yes capturetype=both report=disabled tracefile=$dir\server.etl overwrite=yes
    #Start-Sleep 120
    #netsh trace stop
} # HNSDetail()

function QosDetail {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $dir = (Join-Path -Path $OutDir -ChildPath "NetQoS")
    New-Item -ItemType directory -Path $dir | Out-Null

    $file = "Get-NetAdapterQos.txt"
    [String []] $cmds = "Get-NetAdapterQos",
                        "Get-NetAdapterQos -IncludeHidden | Out-String -Width $columns",
                        "Get-NetAdapterQos -IncludeHidden | Format-List -Property *"
    ExecCommands -OutDir $dir -File $file -Commands $cmds # Get-NetAdapterQos has severe concurrency issues

    $file = "Get-NetQosDcbxSetting.txt"
    [String []] $cmds = "Get-NetQosDcbxSetting",
                        "Get-NetQosDcbxSetting | Format-List  -Property *",
                        "Get-NetQosDcbxSetting | Format-Table -Property *  -AutoSize | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetQosFlowControl.txt"
    [String []] $cmds = "Get-NetQosFlowControl",
                        "Get-NetQosFlowControl | Format-List  -Property *",
                        "Get-NetQosFlowControl | Format-Table -Property *  -AutoSize | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetQosPolicy.txt"
    [String []] $cmds = "Get-NetQosPolicy",
                        "Get-NetQosPolicy | Format-List  -Property *",
                        "Get-NetQosPolicy | Format-Table -Property *  -AutoSize | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-NetQosTrafficClass.txt"
    [String []] $cmds = "Get-NetQosTrafficClass",
                        "Get-NetQosTrafficClass | Format-List  -Property *",
                        "Get-NetQosTrafficClass | Format-Table -Property *  -AutoSize | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds
} # QosDetail()

# Only run if Azure Stack HCI Edition
$edition = Get-WindowsEdition -Online
if ($edition.Edition -eq 'ServerAzureStackHCICor') {
    Function ATCDetail {
        [CmdletBinding()]

        param (
            [parameter(Mandatory=$true)] [String] $OutDir
        )

        $dir = (Join-Path -Path $OutDir -ChildPath "ATC")
        New-Item -ItemType directory -Path $dir | Out-Null

        # Local Intents
        $IntentExists = Get-NetIntent

        $file = "Get-NetIntent_Standalone.txt"
        [String []] $cmds = "Get-NetIntent"
        ExecCommands -OutDir $dir -File $file -Commands $cmds

        $file = "Get-NetIntentStatus_Standalone.txt"
        [String []] $cmds = "Get-NetIntentStatus"
        ExecCommands -OutDir $dir -File $file -Commands $cmds

        $file = "Get-NetIntentAllGoalStates_Standalone.txt"
        [String []] $cmds = "Get-NetIntentAllGoalStates | ConvertTo-Json -Depth 10"
        ExecCommands -OutDir $dir -File $file -Commands $cmds

        # Cluster Intents
        try   { $Cluster =  Get-Cluster -ErrorAction SilentlyContinue }
        Catch { Remove-Variable Cluster -ErrorAction SilentlyContinue }

        if ($Cluster) {
            $file = "Get-NetIntent_Cluster.txt"
            [String []] $cmds = "Get-NetIntent -ClusterName $($Cluster.Name)"
            ExecCommands -OutDir $dir -File $file -Commands $cmds

            $file = "Get-NetIntentStatus_Cluster.txt"
            [String []] $cmds = "Get-NetIntentStatus -ClusterName $($Cluster.Name)"
            ExecCommands -OutDir $dir -File $file -Commands $cmds

            $file = "Get-NetIntentAllGoalStates_Cluster.txt"
            [String []] $cmds = "Get-NetIntentAllGoalStates -ClusterName $($Cluster.Name) | ConvertTo-Json -Depth 10"
            ExecCommands -OutDir $dir -File $file -Commands $cmds
        }
    } # ATCDetail ()
}

function ServicesDrivers {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $dir = (Join-Path -Path $OutDir -ChildPath "ServicesDrivers")
    New-Item -ItemType Directory -Path $dir | Out-Null

    $file = "sc.txt"
    [String []] $cmds = "sc.exe queryex vmsp",
                        "sc.exe queryex vmsproxy",
                        "sc.exe queryex PktMon"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-Service.txt"
    [String []] $cmds = "Get-Service ""*"" | Sort-Object Name | Format-Table -AutoSize",
                        "Get-Service ""*"" | Sort-Object Name | Format-Table -Property * -AutoSize"
    ExecCommands -OutDir $dir -File $file -Commands $cmds # Get-Service has concurrency issues

    $file = "Get-WindowsDriver.txt"
    [String []] $cmds = "Get-WindowsDriver -Online -All"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-WindowsEdition.txt"
    [String []] $cmds = "Get-WindowsEdition -Online"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-HotFix.txt"
    [String []] $cmds = "Get-Hotfix | Sort-Object InstalledOn | Format-Table -AutoSize | Out-String -Width $columns",
                        "Get-Hotfix | Sort-Object InstalledOn | Format-Table -Property * -AutoSize | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-PnpDevice.txt"
    [String []] $cmds = "Get-PnpDevice | Sort-Object Class, FriendlyName, InstanceId | Format-Table -AutoSize | Out-String -Width $columns",
                        "Get-PnpDevice | Sort-Object Class, FriendlyName, InstanceId | Format-List -Property * | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-CimInstance.Win32_PnPSignedDriver.txt"
    [String []] $cmds = "Get-CimInstance Win32_PnPSignedDriver | Select-Object DeviceName, DeviceId, DriverVersion | Format-Table -AutoSize | Out-String -Width $columns",
                        "Get-CimInstance Win32_PnPSignedDriver | Format-List -Property * | Out-String -Width $columns"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "dism.txt"
    [String []] $cmds = "dism /online /get-features"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

} # ServicesDrivers()

function VMHostDetail {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $dir = (Join-Path -Path $OutDir -ChildPath "VMHost")
    New-Item -ItemType Directory -Path $dir | Out-Null

    $file = "Get-VMHostSupportedVersion.txt"
    [String []] $cmds = "Get-VMHostSupportedVersion | Format-Table -AutoSize | Out-String -Width $columns",
                        "Get-VMHostSupportedVersion | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMHostNumaNode.txt"
    [String []] $cmds = "Get-VMHostNumaNode"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMHostNumaNodeStatus.txt"
    [String []] $cmds = "Get-VMHostNumaNodeStatus"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMSystemSwitchExtension.txt"
    [String []] $cmds = "Get-VMSystemSwitchExtension | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMSystemSwitchExtensionSwitchFeature.txt"
    [String []] $cmds = "Get-VMSystemSwitchExtensionSwitchFeature | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Get-VMSystemSwitchExtensionPortFeature.txt"
    [String []] $cmds = "Get-VMSystemSwitchExtensionPortFeature | Format-List -Property *"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds
} # VMHostDetail()

function NetshTrace {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $dir = (Join-Path -Path $OutDir -ChildPath "Netsh")
    New-Item -ItemType directory -Path $dir | Out-Null

    <# Deprecated / DELETEME
        #Figure out how to get this netsh rundown command executing under Powershell with logging...
        $ndiswpp = "{DD7A21E6-A651-46D4-B7C2-66543067B869}"
        $vmswpp  = "{1F387CBC-6818-4530-9DB6-5F1058CD7E86}"
        netsh trace start provider=$vmswpp level=1 keywords=0x00010000 provider=$ndiswpp level=1 keywords=0x02 correlation=disabled report=disabled overwrite=yes tracefile=$dir\NetRundown.etl
        netsh trace stop
    #>

    #$wpp_vswitch  = "{1F387CBC-6818-4530-9DB6-5F1058CD7E86}"
    #$wpp_ndis     = "{DD7A21E6-A651-46D4-B7C2-66543067B869}"

    # The sequence below triggers the ETW providers to dump their internal traces when the session starts.  Thus allowing for capturing a
    # snapshot of their logs/traces.
    #
    # NOTE: This does not cover IFR (in-memory) traces.  More work needed to address said traces.
    $file = "NetRundown.txt"
    [String []] $cmds = "New-NetEventSession    NetRundown -CaptureMode SaveToFile -LocalFilePath $dir\NetRundown.etl",
                        "Add-NetEventProvider   ""{1F387CBC-6818-4530-9DB6-5F1058CD7E86}"" -SessionName NetRundown -Level 1 -MatchAnyKeyword 0x10000",
                        "Add-NetEventProvider   ""{DD7A21E6-A651-46D4-B7C2-66543067B869}"" -SessionName NetRundown -Level 1 -MatchAnyKeyword 0x2",
                        "Start-NetEventSession  NetRundown",
                        "Stop-NetEventSession   NetRundown",
                        "Remove-NetEventSession NetRundown"
    ExecCommands -OutDir $dir -File $file -Commands $cmds

    #
    # The ETL file can be converted to text using the following command:
    #    netsh trace convert NetRundown.etl tmfpath=\\winbuilds\release\RS_ONECORE_STACK_SDN_DEV1\15014.1001.170117-1700\amd64fre\symbols.pri\TraceFormat
    #    Specifying a path to the TMF symbols. Output is attached.

    $file = "NetshDump.txt"
    [String []] $cmds = "netsh dump"
    ExecCommands -OutDir $dir -File $file -Commands $cmds

    $file = "NetshStatistics.txt"
    [String []] $cmds = "netsh interface ipv4 show icmpstats",
                        "netsh interface ipv4 show ipstats",
                        "netsh interface ipv4 show tcpstats",
                        "netsh interface ipv4 show udpstats",
                        "netsh interface ipv6 show ipstats",
                        "netsh interface ipv6 show tcpstats",
                        "netsh interface ipv6 show udpstats"
    ExecCommands -OutDir $dir -File $file -Commands $cmds

    $file = "NetshTrace.txt"
    [String []] $cmds = "netsh -?",
                        "netsh trace show scenarios",
                        "netsh trace show providers",
                        "netsh trace diagnose scenario=NetworkSnapshot mode=Telemetry saveSessionTrace=yes report=yes ReportFile=$dir\Snapshot.cab"
    ExecCommands -OutDir $dir -File $file -Commands $cmds
} # NetshTrace()

function OneX {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $dir = (Join-Path -Path $OutDir -ChildPath "802.1X")
    New-Item -ItemType directory -Path $dir | Out-Null

    $file = "OneX.txt"
    [String []] $cmds = "netsh lan show interface",
                        "netsh lan show profile"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds
} # OneX

function Counters {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $dir = (Join-Path -Path $OutDir -ChildPath "Counters")
    New-Item -ItemType directory -Path $dir | Out-Null

    $file = "CounterSetName.txt"
    [String []] $cmds = "typeperf -q | foreach {(`$_ -split ""\\"")[1]} | Sort-Object -Unique"
    ExecCommands -OutDir $dir -File $file -Commands $cmds

    $file = "CounterSetName.Paths.txt"
    [String []] $cmds = "typeperf -q"
    ExecCommands -OutDir $dir -File $file -Commands $cmds

    $file = "CounterSetName.PathsWithInstances.txt"
    [String []] $cmds = "typeperf -qx"
    ExecCommands -OutDir $dir -File $file -Commands $cmds

    # Get paths for counters of interest
    $file = "CounterDetail.InstancesToQuery.txt"
    $in = Join-Path $dir $file

    $pathFilters = @("\Hyper-V*", "\ICMP*", "*Intel*", "*Cavium*", "\IP*", "*Mellanox*", "\Network*", "\Physical Network*", "\RDMA*", "\SMB*", "\TCP*", "\UDP*","\VFP*", "\WFP*", "*WinNAT*")
    $instancesToQuery = typeperf -qx | where {
        $instance = $_
        $pathFilters | foreach {
            if ($instance -like $_) {
                return $true
            }
        }
        return $false
    }
    $instancesToQuery | Out-File -FilePath $in -Encoding ascii

    $file = "CounterDetail.csv"
    $out  = Join-Path $dir $file
    [String []] $cmds = "typeperf -cf $in -sc 10 -si 5 -f CSV -o $out > `$null"
    ExecCommands -OutDir $dir -File $file -Commands $cmds
} # Counters()

function SystemLogs {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    if (-not $SkipLogs) {
        $dir = $OutDir

        $file = "WinEVT.txt"
        [String []] $paths = "$env:SystemRoot\System32\winevt"
        ExecCopyItemsAsync -OutDir $dir -File $file -Paths $paths -Destination $dir

        $file = "WER.txt"
        [String []] $paths = "$env:ProgramData\Microsoft\Windows\WER"
        ExecCopyItemsAsync -OutDir $dir -File $file -Paths $paths -Destination $dir
    }
} # SystemLogs()

function Environment {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $dir = $OutDir

    $file = "Get-ComputerInfo.txt"
    [String []] $cmds = "Get-ComputerInfo"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Verifier.txt"
    [String []] $cmds = "verifier /querysettings"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Powercfg.txt"
    [String []] $cmds = "powercfg /List"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds

    $file = "Environment.txt"
    [String []] $cmds = "Get-Variable -Name ""PSVersionTable"" -ValueOnly",
                        "date",
                        "Get-CimInstance ""Win32_OperatingSystem"" | select -ExpandProperty ""LastBootUpTime""",
                        "Get-CimInstance ""Win32_Processor"" | Format-List -Property *",
                        "systeminfo"
    ExecCommandsAsync -OutDir $dir -File $file -Commands $cmds
} # Environment()

function LocalhostDetail {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    $dir = (Join-Path -Path $OutDir -ChildPath "_Localhost") # sort to top
    New-Item -ItemType directory -Path $dir | Out-Null

    SystemLogs        -OutDir $dir
    ServicesDrivers   -OutDir $dir
    VMHostDetail      -OutDir $dir
} # LocalhostDetail()

function CustomModule {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$false)] [String[]] $Commands, # Passed in as [ScriptBlock[]]
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    if ($Commands.Count -eq 0) {
        return
    }

    $CustomModule  = (Join-Path $OutDir "CustomModule")
    New-Item -ItemType Directory -Path $CustomModule | Out-Null

    $file = "ExtraCommands.txt"
    ExecCommands -OutDir $CustomModule -File $file -Commands $Commands
} # CustomModule()

function Sanity {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $OutDir,
        [parameter(Mandatory=$true)] [Hashtable] $Params
    )

    $dir  = (Join-Path -Path $OutDir -ChildPath "Sanity")
    New-Item -ItemType directory -Path $dir | Out-Null

    Write-Progress -Activity $Global:FinishActivity -Status "Processing output..."

    $file = "Get-ChildItem.txt"
    [String []] $cmds = "Get-ChildItem -Path $OutDir -Exclude Get-NetView.log -File -Recurse | Get-FileHash -Algorithm SHA1 | Format-Table -AutoSize | Out-String -Width $columns"
    ExecCommands -OutDir $dir -File $file -Commands $cmds

    $file = "Metadata.txt"
    $out = Join-Path $dir $file
    $paramString = if ($Params.Count -eq 0) {"None`n`n"} else {"`n$($Params | Out-String)"}
    Write-Output "Script Version: $($Global:Version)" | Out-File -Encoding ascii -Append $out
    Write-Output "Module Version: $($MyInvocation.MyCommand.Module.Version)" | Out-File -Encoding ascii -Append $out
    Write-Output "Bound Parameters: $paramString" | Out-File -Encoding ascii -Append $out

    [String []] $cmds = "Get-FileHash -Path ""$PSCommandPath"" -Algorithm SHA1 | Format-List -Property * | Out-String -Width $columns"
    ExecCommands -OutDir $dir -File $file -Commands $cmds
} # Sanity()

#
# Setup & Validation Functions
#

function CheckAdminPrivileges {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [Bool] $SkipAdminCheck
    )

    if (-not $SkipAdminCheck) {
        # Yep, this is the easiest way to do this.
        $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
        if (-not $isAdmin) {
            throw "Get-NetView : You do not have the required permission to complete this task. Please run this command in an Administrator PowerShell window or specify the -SkipAdminCheck option."
        }
    }
} # CheckAdminPrivileges()

function NormalizeWorkDir {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$false)] [String] $OutputDirectory
    )

    # Output dir priority - $OutputDirectory, Desktop, Temp
    $baseDir = if (-not [String]::IsNullOrWhiteSpace($OutputDirectory)) {
                   if (Test-Path $OutputDirectory) {
                       (Resolve-Path $OutputDirectory).Path # full path
                   } else {
                       throw "Get-NetView : The directory ""$OutputDirectory"" does not exist."
                   }
               } elseif (($desktop = [Environment]::GetFolderPath("Desktop"))) {
                   $desktop
               } else {
                   $env:TEMP
               }
    $workDirName = "msdbg.$env:COMPUTERNAME"

    return (Join-Path $baseDir $workDirName).TrimEnd("\")
} # NormalizeWorkDir()

function EnvDestroy {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    If (Test-Path $OutDir) {
        Remove-Item $OutDir -Recurse # Careful - Deletes $OurDir and all its contents
    }
} # EnvDestroy()

function EnvCreate {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    # Attempt to create working directory, stopping on failure.
    New-Item -ItemType directory -Path $OutDir -ErrorAction Stop | Out-Null
} # EnvCreate()

function Initialize {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [Int] $BackgroundThreads,
        [parameter(Mandatory=$true)] [Double] $ExecutionRate,
        [parameter(Mandatory=$true)] [String] $OutDir
    )

    # Remove alias to Write-Host set in $ExecCommands
    Remove-Item alias:Write-CmdLog -ErrorAction "SilentlyContinue"

    # Setup output folder
    EnvDestroy $OutDir
    EnvCreate $OutDir

    Clear-Host
    Start-Transcript -Path "$OutDir\Get-NetView.log"

    if ($ExecutionRate -lt 1) {
        $Global:DelayFactor = (1 / $ExecutionRate) - 1

        Write-Host "Forcing BackgroundThreads=0 because ExecutionRate is less than 1."
        $BackgroundThreads = 0
    }

    Open-GlobalThreadPool -BackgroundThreads $BackgroundThreads
} # Initialize()

function CreateZip {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $Src,
        [parameter(Mandatory=$true)] [String] $Out
    )

    if (Test-path $Out) {
        Remove-item $Out
    }

    Add-Type -assembly "system.io.compression.filesystem"
    [io.compression.zipfile]::CreateFromDirectory($Src, $Out)
} # CreateZip()

function Completion {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)] [String] $Src
    )

    $timestamp = $start | Get-Date -f yyyy.MM.dd_hh.mm.ss

    $dirs = (Get-ChildItem $Src -Recurse | Measure-Object -Property length -Sum) # out folder size
    $hash = (Get-FileHash -Path $MyInvocation.PSCommandPath -Algorithm "SHA1").Hash # script hash

    # Display version and file save location
    Write-Host ""
    Write-Host "Diagnostics Data:"
    Write-Host "-----------------"
    Write-Host "Get-NetView"
    Write-Host "Version: $($Global:Version)"
    Write-Host "SHA1:  $(if ($hash) {$hash} else {"N/A"})"
    Write-Host ""
    Write-Host $Src
    Write-Host "Size:    $("{0:N2} MB" -f ($dirs.sum / 1MB))"
    Write-Host "Dirs:    $((Get-ChildItem $Src -Directory -Recurse | Measure-Object).Count)"
    Write-Host "Files:   $((Get-ChildItem $Src -File -Recurse | Measure-Object).Count)"
    Write-Host ""
    Write-Host "Execution Time:"
    Write-Host "---------------"
    $delta = (Get-Date) - $Start
    Write-Host "$($delta.Minutes) Min $($delta.Seconds) Sec"
    Write-Host ""

    TryCmd {Stop-Transcript}

    # Sort Get-NetView.log by sub-command execution time
    Get-Content $Src\Get-NetView.log | Sort-Object -Descending > $Src\Get-NetView-Time.Log

    Write-Progress -Activity $Global:FinishActivity -Status "Creating zip..."
    $outzip = "$Src-$timestamp.zip"
    CreateZip -Src $Src -Out $outzip
    Write-Host $outzip
    Write-Host "Size:    $("{0:N2} MB" -f ((Get-Item $outzip).Length / 1MB))"

    Write-Progress -Activity $Global:FinishActivity -Completed
} # Completion()

<#
.SYNOPSIS
    Collects data on system and network configuration for diagnosing Microsoft Networking.

.DESCRIPTION
    Collects comprehensive configuration data to aid in troubleshooting Microsoft Network issues.
    Data is collected from the following sources:
        - Get-NetView metadata (path, args, etc.)
        - Environment (OS, hardware, domain, hostname, etc.)
        - Physical, virtual, Container, NICs
        - Network Configuration, IP Addresses, MAC Addresses, Neighbors, Routes
        - Physical Switch configuration, QOS polices
        - Virtual Machine configuration
        - Virtual Switches, Bridges, NATs
        - Device Drivers
        - Performance Counters
        - Logs, Traces, etc.
        - System and Application Events

    The data is collected in a folder on the Desktop (by default), which is zipped on completion.
    Use Feedback hub to submit a new feedback.  Select one of these Categories:
        Network and Internet -> Virtual Networking
        Network and Internet -> Connecting to an Ethernet Network.
    Attach the Zip file to the feedback and submit.

    Do not share the zip file over email or other file sharing tools.  Only submit the file through the feedback hub.

    The output is most easily viewed with Visual Studio Code or similar editor with a navigation panel.

.PARAMETER OutputDirectory
    Optional path to the directory where the output should be saved. Can be either a relative or an absolute path.
    If unspecified, the current user's Desktop will be used by default.

.PARAMETER ExtraCommands
    Optional list of additional commands, given as ScriptBlocks. Their output is saved to the CustomModule directory,
    which can be accessed by using "$CustomModule" as a placeholder. For example, {Copy-Item .\MyFile.txt $CustomModule}
    copies "MyFile.txt" to "CustomModule\MyFile.txt".

.PARAMETER BackgroundThreads
    Maximum number of background tasks, from 0 - 16. Defaults to 5.

.PARAMETER ExecutionRate
    Relative rate at which commands are executed, with 1 being normal speed. Reduce to slow down execution and spread
    CPU usage over time. Useful on live or production systems to avoid disruption.

    NOTE: This will force BackgroundThreads = 0.

.PARAMETER SkipAdminCheck
    If present, skip the check for admin privileges before execution. Note that without admin privileges, the scope and
    usefulness of the collected data is limited.

.PARAMETER SkipLogs
    If present, skip the EVT and WER logs gather phases.

.PARAMETER SkipNetshTrace
    If present, skip the Netsh Trace data gather phases.

.PARAMETER SkipCounters
    If present, skip the Windows Performance Counters (WPM) data gather phases.

.PARAMETER SkipVm
    If present, skip the Virtual Machine (VM) data gather phases.

.EXAMPLE
    Get-NetView -OutputDirectory ".\"
    Runs Get-NetView and outputs to the current working directory.

.LINK
    https://github.com/microsoft/Get-NetView
#>
function Get-NetView {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$false)]
        [ValidateScript({Test-Path $_ -PathType Container})]
        [String] $OutputDirectory = "",

        [parameter(Mandatory=$false)]
        [ScriptBlock[]] $ExtraCommands = @(),

        [Alias("MaxThreads")]
        [parameter(Mandatory=$false, ParameterSetName="BackgroundThreads")]
        [ValidateRange(0, 16)]
        [Int] $BackgroundThreads = 5,

        [parameter(Mandatory=$false)]
        [ValidateRange(0.0001, 1)]
        [Double] $ExecutionRate = 1,

        [parameter(Mandatory=$false)]  [Switch] $SkipAdminCheck = $false,
        [parameter(Mandatory=$false)]  [Switch] $SkipLogs       = $false,
        [parameter(Mandatory=$false)]  [Switch] $SkipNetshTrace = $false,
        [parameter(Mandatory=$false)]  [Switch] $SkipCounters   = $false,
        [parameter(Mandatory=$false)]  [Switch] $SkipVm         = $false
    )

    $start = Get-Date

    # Input Validation
    CheckAdminPrivileges $SkipAdminCheck
    $workDir = NormalizeWorkDir -OutputDirectory $OutputDirectory

    Initialize -BackgroundThreads $BackgroundThreads -ExecutionRate $ExecutionRate -OutDir $workDir

    # Start Run
    try {
        CustomModule -OutDir $workDir -Commands $ExtraCommands

        Write-Progress -Activity $Global:QueueActivity
        $threads = if ($true) {
            if (-not $SkipNetshTrace) {
                Start-Thread ${function:NetshTrace} -Params @{OutDir=$workDir}
            }
            if (-not $SkipCounters) {
                Start-Thread ${function:Counters}   -Params @{OutDir=$workDir}
            }

            Environment       -OutDir $workDir
            LocalhostDetail   -OutDir $workDir
            NetworkSummary    -OutDir $workDir
            NetSetupDetail    -OutDir $workDir
            VMSwitchDetail    -OutDir $workDir
            LbfoDetail        -OutDir $workDir
            NativeNicDetail   -OutDir $workDir
            OneX              -OutDir $workDir

            QosDetail         -OutDir $workDir
            SMBDetail         -OutDir $workDir
            NetIp             -OutDir $workDir
            NetNatDetail      -OutDir $workDir
            HNSDetail         -OutDir $workDir
            #ATCDetail         -OutDir $workDir
        }

        # Wait for threads to complete
        Show-Threads -Threads $threads
    } catch {
        $msg = $($_ | Out-String)
        ExecControlError -OutDir $workDir -Function "Get-NetView" -Message $msg

        throw $_
    } finally {
        Close-GlobalThreadPool

        Sanity -OutDir $workDir -Params $PSBoundParameters
        Completion -Src $workDir
    }
} # Get-NetView

# For backwards compat, support direct execution as a .ps1 file (no dot sourcing needed).
if (-not [String]::IsNullOrEmpty($MyInvocation.InvocationName)) {
    if (($MyInvocation.InvocationName -eq "&") -or
        ($MyInvocation.MyCommand.Path -eq (Resolve-Path -Path $MyInvocation.InvocationName).ProviderPath)) {
        Get-NetView @args
    }
}