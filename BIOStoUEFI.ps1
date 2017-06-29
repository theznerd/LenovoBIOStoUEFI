######################################################
## Lenovo BIOS to UEFI TS Converter with CG/DG Prep ##
## Written By: Nathan Ziehnert                      ##
## Website: http://z-nerd.com                       ##
## Version: 0.4                                     ##
######################################################
<#
.SYNOPSIS
    Allows you to configure SecureBoot/UEFI settings, as well as Virtualization 
    Technology and TPM for Credential Guard and Device Guard. This script is
    designed to work on both ThinkPad and ThinkCentre machines.

.DESCRIPTION
    This script connects to the WMI instances for Lenovo machines, and then
    configures the requested settings. This script is designed to be used
    as part of a task sequence where you want to convert from legacy BIOS
    to UEFI and at the same time prepare the machine for Credential Guard
    and Device Guard.

    IMPORTANT NOTE: For ThinkCentre machines, this requires a later BIOS
    revision than may have come with your machine. I only had access to 
    the following models during my testing:

    M93p - Min BIOS Rev required: FBKTCAA (9/18/2016)
    M900 - Min BIOS Rev required: FWKT5AA (10/4/2016)

.PARAMETER Verbose
    This script is verbose enabled. Use this switch to get verbose output.

.PARAMETER BTU
    A switch to enable configuration of BIOS to UEFI configuration.

.PARAMETER CGDG
    A switch to enable virtualization technology and TPM (if not currently enabled) - requires the BTU switch

.PARAMETER BIOSPassword [string]
    If you have a supervisor password set on your machines, you will need to input it here.

.PARAMETER LogPath [string]
    This is a full path to a log file for troubleshooting the script. If a value is set here logging will be enabled.

.PARAMETER WhatIf
    A switch to keep the script from actually performing any changes to BIOS. Use in conjunction with the -Verbose switch to see what the script would have done.

.NOTES
    File Name: BIOStoUEFI.ps1
    Author: Nathan Ziehnert

.LINK
    http://z-nerd.com/2016/10/lenovo-bios-to-uefi-conversion-during-task-sequence-secureboot-and-virtualization-technology-too/
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory=$false)]
    [switch]$BTU,
    [Parameter(Mandatory=$false)]
    [switch]$CGDG,
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf,
    [Parameter(Mandatory=$false)]
    [string]$BIOSPassword,
    [Parameter(Mandatory=$false)]
    [string]$LogPath
)

## Logging function
if($LogPath){
    if(-not (Test-Path "$LogPath")){
        New-Item -ItemType File -Path "$LogPath" -Force
    }
}
Function Write-Log($textToLog) {
    if($LogPath){
        $date = Get-Date -Format "yyyy.MM.dd.hh:mm:ss |"
        Add-Content -Path "$LogPath" -Value "$date $textToLog"
    }
}

## Check first for BIOS manufacturer / computer model
Write-Verbose "Gathering Manufacturer and Model Information"
Write-Log "Gathering Manufacturer and Model Information"
$manufacturer = (gwmi Win32_ComputerSystem).Manufacturer
$model = (gwmi Win32_ComputerSystem).Model

## Since this script is for Lenovo only, throw error if manufacturer is not Lenovo
if($manufacturer -ne "LENOVO"){
    Write-Verbose "Exiting script because manufacturer is not Lenovo"
    Write-Log "Exiting script because manufacturer is not Lenovo"
    Write-Error -Category InvalidResult -Message "Manufacturer is not LENOVO." -ErrorId 0x00000002
    Exit 2
}

## Okay - Lenovo got close with their latest BIOS update... but no cigar...
## check to see if computer is a desktop or a laptop
$PCTypeInt = (gwmi -Class Win32_ComputerSystem -Property PCSystemType).PCSystemType
$PCTypeStr = $null
if($PCTypeInt -ne 2){
    $PCTypeStr = "Desktop"
    Write-Verbose "This is a Desktop PC"
    Write-Log "This is a Desktop PC"
}else{
    $PCTypeStr = "Laptop"
    Write-Verbose "This is a Laptop PC"
    Write-Log "This is a Laptop PC"
}

## Let's make sure we'll be able to make changes
$BIOSWriteLocked = (gwmi -class Win32_ComputerSystem -Property AdminPasswordStatus).AdminPasswordStatus
if(($BIOSWriteLocked -eq 1) -and (($biosPassword -eq $null) -or ($biosPassword -eq ""))){
    Write-Log "BIOS is write locked and you did not specify a password - you may specify a password with the -BIOSPassword switch"
    Write-Error -Category InvalidResult -Message "BIOS is write locked and you did not specify a password - you may specify a password with the -BIOSPassword switch" -ErrorId 0x00000003
    Exit 3
}

## Set the BIOS password string
if($BIOSPassword){
    Write-Verbose "BIOS Password flag was set - creating BIOS string ',$BIOSPassword,ascii,us' to append to WMI queries"
    Write-Log "BIOS Password flag was set - creating BIOS string ',PASSWORD NOT LISTED FOR SECURITY REASONS,ascii,us' to append to WMI queries"
    $BIOSString = "$BIOSPassword,ascii,us"
}else{
    Write-Verbose "BIOS Password flag was NOT set."
    Write-Log "BIOS Password flag was NOT set."
    $BIOSString = $null
}

#######################################
## STATIC DEFINITIONS                ##
## (DIFFERENT FOR DESKTOP VS LAPTOP) ##
#######################################
Write-Verbose "Creating static definitions based on chassis type."
Write-Log "Creating static definitions based on chassis type."
if($PCTypeStr -eq "Desktop"){ $sbNoun = "Secure Boot" }else{ $sbNoun = "SecureBoot" }
if($PCTypeStr -eq "Desktop"){ $vNoun = "Intel(R) Virtualization Technology" }else{ $vNoun = "VirtualizationTechnology" }
if($PCTypeStr -eq "Desktop"){ $vtdNoun = "VT-d" }else{ $vtdNoun = "VTdFeature" }
if($PCTypeStr -eq "Desktop"){ $tpmNoun = "Security Chip" }else{ $tpmNoun = "SecurityChip" }
if($PCTypeStr -eq "Desktop"){ $exVerb = "Enabled" }else{ $exVerb = "Enable" }
$secureboot = $null #not necessary, but better safe than sorry
$virtualization = $null #not necessary, but better safe than sorry
$vtd = $null #not necessary, but better safe than sorry
$tpmStatus = $null #not necessary, but better safe than sorry

## Assuming we've made it this far, let's grab the current status of booting, virtualization, and TPM
Write-Verbose "Gathering current values for SecureBoot, Virtualization, VT-d, and TPM Status"
Write-Log "Gathering current values for SecureBoot, Virtualization, VT-d, and TPM Status"
$secureboot = (gwmi -class Lenovo_BiosSetting -namespace root\wmi | Where-Object {$_.CurrentSetting.split(",",[StringSplitOptions]::RemoveEmptyEntries) -eq $sbNoun}).CurrentSetting
$virtualization = (gwmi -class Lenovo_BiosSetting -namespace root\wmi | Where-Object {$_.CurrentSetting.split(",",[StringSplitOptions]::RemoveEmptyEntries) -eq $vNoun}).CurrentSetting
$vtd = (gwmi -class Lenovo_BiosSetting -namespace root\wmi | Where-Object {$_.CurrentSetting.split(",",[StringSplitOptions]::RemoveEmptyEntries) -eq $vtdNoun}).CurrentSetting
$tpmStatus = (gwmi -class Lenovo_BiosSetting -namespace root\wmi | Where-Object {$_.CurrentSetting.split(",",[StringSplitOptions]::RemoveEmptyEntries) -eq $tpmNoun}).CurrentSetting

## One final preflight check - let's make sure those properties actually exist...
## If they don't - throw an error that the bios may be out of date
Write-Verbose "Validating whether or not the settings exist - rich man's BIOS version check"
Write-Log "Validating whether or not the settings exist - rich man's BIOS version check"
if(-not ($secureboot)){
    Write-Log "WMI is not seeing one of the commands. Your BIOS may need to be updated first."
    Write-Error -Category InvalidResult -Message "WMI is not seeing one of the commands. Your BIOS may need to be updated first." -ErrorId 0x00000004
    Exit 4
}
if($CGDG -and (-not ($virtualization -or $vtd -or $tpmStatus))){
    Write-Log "WMI is not seeing one or more of the commands. Your BIOS may need to be updated first."
    Write-Error -Category InvalidResult -Message "WMI is not seeing one or more of the commands. Your BIOS may need to be updated first." -ErrorId 0x00000004
    Exit 4
}

## Game time...
# did the user want us to do anything with BIOS to UEFI?
if($BTU){
    #first things first, if secure boot is already enabled, then skip
    if(($secureboot -eq "SecureBoot,Disable") -or ($secureboot -eq "CurrentSetting : Secure Boot,Disabled;[Optional:Disabled,Enabled]") -or ($secureboot -eq "Secure Boot,Disabled;[Optional:Disabled,Enabled]")){
        Write-Verbose "Beginning SecureBoot configuration."
        Write-Log "Beginning SecureBoot configuration."
        
        # Prepare the BIOS string - only used if bios has password.
        if($BIOSString){
            $commandString = $sbNoun+","+$exVerb+","+$BIOSString        
        }else{
            $commandString = $sbNoun+","+$exVerb
        }
        if(-not $WhatIf){
            $sbResult = (gwmi -class Lenovo_SetBiosSetting -namespace root\wmi).SetBiosSetting("$commandString") #Set the SecureBoot setting
            $sbSaveResult = (gwmi -class Lenovo_SaveBiosSettings -namespace root\wmi).SaveBiosSettings("$BIOSString") #Save the SecureBoot setting
            if(($sbResult.return -ne "Success") -or ($sbSaveResult.return -ne "Success")){
                Write-Log "There was an error setting the SecureBoot configuration."
                Write-Error -Category InvalidResult -Message "There was an error setting the SecureBoot configuration." -ErrorId 0x00000005
                Exit 5
            }
        }else{
            Write-Verbose "WHAT IF: Running (gwmi -class Lenovo_SetBiosSetting -namespace root\wmi).SetBiosSetting(`"$commandString`")"
            Write-Verbose "WHAT IF: Running (gwmi -class Lenovo_SaveBiosSettings -namespace root\wmi).SaveBiosSettings(`"$BIOSString`")"
        }
    }else{
        Write-Verbose "SecureBoot is already enabled. Skipping this step."
        Write-Log "SecureBoot is already enabled. Skipping this step."
    }

    # now if the user wanted us to enable features for Credential Guard / Device Guard, do that now
    if($CGDG){
        Write-Verbose "Beginning Credential Guard / Device Guard configuration."
        Write-Log "Beginning Credential Guard / Device Guard configuration."

        if(($tpmStatus -eq "SecurityChip,Disabled") -or ($tpmStatus -eq "SecurityChip,Inactive") -or ($tpmStatus -eq "Security Chip,Disabled;[Optional:Disabled,Active,Inactive]") -or ($tpmStatus -eq "Security Chip,Inactive;[Optional:Disabled,Active,Inactive]")){
            Write-Verbose "Configuring TPM"
            Write-Log "Configuring TPM"
            # Prepare the BIOS string - only used if bios has password.
            if($BIOSString){
                $commandString = $tpmNoun+",Active,"+$BIOSString
            }else{
                $commandString = $tpmNoun+",Active"
            }

            if(-not $WhatIf){
                $scResult = (gwmi -class Lenovo_SetBiosSetting -namespace root\wmi).SetBiosSetting("$commandString") #Set the SecurityChip setting
                $scSaveResult = (gwmi -class Lenovo_SaveBiosSettings -namespace root\wmi).SaveBiosSettings("$BIOSString") #Save the SecurityChip setting
                if(($scResult.return -ne "Success") -or ($scSaveResult.return -ne "Success")){
                    Write-Log "There was an error setting the TPM configuration."
                    Write-Error -Category InvalidResult -Message "There was an error setting the TPM configuration." -ErrorId 0x00000006
                    Exit 6
                }
            }else{
                Write-Verbose "WHAT IF: Running (gwmi -class Lenovo_SetBiosSetting -namespace root\wmi).SetBiosSetting(`"$commandString`")"
                Write-Verbose "WHAT IF: Running (gwmi -class Lenovo_SaveBiosSettings -namespace root\wmi).SaveBiosSettings(`"$BIOSString`")"
            }
        }else{
            Write-Verbose "TPM is already configured."
            Write-Log "TPM is already configured."
        }
                
        if(($virtualization -eq "VirtualizationTechnology,Disable") -or ($virtualization -eq "Intel(R) Virtualization Technology = Disabled;[Optional:Disabled = Enabled]") -or ($virtualization -eq "Intel(R) Virtualization Technology,Disabled;[Optional:Disabled,Enabled]")){
            Write-Verbose "Configuring Virtualization Technology"
            Write-Log "Configuring Virtualization Technology"

            # Prepare the BIOS string - only used if bios has password.
            if($BIOSString){
                $commandString = $vNoun+","+$exVerb+","+$BIOSString
            }else{
                $commandString = $vNoun+","+$exVerb
            }

            if(-not $WhatIf){
                $vtResult = (gwmi -class Lenovo_SetBiosSetting -namespace root\wmi).SetBiosSetting("$commandString") #Set the VirtualizationTechnology setting
                $vtSaveResult = (gwmi -class Lenovo_SaveBiosSettings -namespace root\wmi).SaveBiosSettings("$BIOSString") #Save the VirtualizationTechnology setting
                if(($vtResult.return -ne "Success") -or ($vtSaveResult.return -ne "Success")){
                    Write-Log "There was an error setting the Virtualization Technology configuration."
                    Write-Error -Category InvalidResult -Message "There was an error setting the Virtualization Technology configuration." -ErrorId 0x00000007
                    Exit 7
                }
            }else{
                Write-Verbose "WHAT IF: Running (gwmi -class Lenovo_SetBiosSetting -namespace root\wmi).SetBiosSetting(`"$commandString`")"
                Write-Verbose "WHAT IF: Running (gwmi -class Lenovo_SaveBiosSettings -namespace root\wmi).SaveBiosSettings(`"$BIOSString`")"
            }
        }else{
            Write-Verbose "Virtualization technology is already enabled."
            Write-Log "Virtualization technology is already enabled."
        }
		
	#need to add it here too because if it's disabled, desktops adds a weird switch...
	$vtd = (gwmi -class Lenovo_BiosSetting -namespace root\wmi | Where-Object {$_.CurrentSetting.split(",",[StringSplitOptions]::RemoveEmptyEntries) -eq $vtdNoun}).CurrentSetting
        
	if(($vtd -eq "VTdFeature,Disable") -or ($vtd -eq "VT-d,Disabled;[Optional:Disabled,Enabled]") -or ($vtd -eq "VT-d,Disabled;[Optional:Disabled,Enabled]")){
            Write-Verbose "Configuring VTdFeature"
            Write-Log "Configuring VTdFeature"
            # Prepare the BIOS string - only used if bios has password.
            if($BIOSString){
                $commandString = $vtdNoun+","+$exVerb+","+$BIOSString
            }else{
                $commandString = $vtdNoun+","+$exVerb
            }

            if(-not $WhatIf){
                $vtdResult = (gwmi -class Lenovo_SetBiosSetting -namespace root\wmi).SetBiosSetting("$commandString") #Set the VTdFeature setting
                $vtdSaveResult = (gwmi -class Lenovo_SaveBiosSettings -namespace root\wmi).SaveBiosSettings("$BIOSString") #Save the VTdFeature setting
                if(($vtdResult.return -ne "Success") -or ($vtdSaveResult.return -ne "Success")){
                    Write-Log "There was an error setting the Virtualization Technology configuration."
                    Write-Error -Category InvalidResult -Message "There was an error setting the Virtualization Technology configuration." -ErrorId 0x00000007
                    Exit 7
                }
            }else{
                Write-Verbose "WHAT IF: Running (gwmi -class Lenovo_SetBiosSetting -namespace root\wmi).SetBiosSetting(`"$commandString`")"
                Write-Verbose "WHAT IF: Running (gwmi -class Lenovo_SaveBiosSettings -namespace root\wmi).SaveBiosSettings(`"$BIOSString`")"
            }
        }else{
            Write-Verbose "VTdFeature is already enabled."
            Write-Log "VTdFeature is already enabled."
        }
        Write-Verbose "Credential Guard / Device Guard configuration is complete."
        Write-Log "Credential Guard / Device Guard configuration is complete."
    }
}
elseif((-not $BTU) -and $CGDG){
    Write-Verbose "BIOS to UEFI conversion required for DG/CG. You should run this script with both the -BTU and -CGDG flags."
    Write-Log "BIOS to UEFI conversion required for DG/CG. You should run this script with both the -BTU and -CGDG flags."
}
else{
    Write-Verbose "No actions selected."
    Write-Log "No actions selected."
}
