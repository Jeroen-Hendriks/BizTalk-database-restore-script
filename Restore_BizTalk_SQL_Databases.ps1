<#
Written by: Jeroen Hendriks
E-mail: 	jeroen@hendriks.io
Version: 	1.3
Date: 		1 august 2018
This script generates a SQL file that restores BizTalk databases
#>

#Set variables
[STRING]$SQLServerName = "BIZTALK2016"
[STRING]$InstanceName = "MSSQLSERVER" #Use MSSQLSERVER if you are using a default instance
[ARRAY]$Databases = @("SSODB", "BAMPrimaryImport", "BizTalkDTADb", "BizTalkMsgBoxDb", "BizTalkRuleEngineDb", "BizTalkMgmtDb")
[STRING]$FullBackupLocation = "C:\Backups\Data"
[STRING]$LogBackupLocation = "C:\Backups\Log"
[STRING]$SQLOutputLocation = "C:\temp"
[BOOL]$DropDatabases = $False 

#Function to check if a location exists
function CheckLocation ($location)
{
	if (Test-Path $location)
	{
		Write-host "The location $location exists." -ForegroundColor Green
	}
	else
	{
		Write-host "The location $location does not exist."  -ForegroundColor Red
		[BOOL]$script:LocationNotExist = $True
	}
}

#Funcion to get the last full backup filename and last full backup Mark for the $Database
Function Get-Lastfullback ($SQLServerName, $InstanceName, $database, $FullBackupLocation)
{
	[STRING]$FullBackupFilePrefix
    If ($InstanceName -eq "MSSQLSERVER")
    {
        $FullBackupFilePrefix = ($SQLServerName + "_" + $database + "_Full_").ToUpper()
    }
    Else
    {
        $FullBackupFilePrefix = ($SQLServerName + "_" + $InstanceName + "_" + $database + "_Full_").ToUpper()
    }  
    #$script:Lastfullback = New-Object System.Object 
	$Lastfullback = New-Object System.Object 
    $Lastfullback | Add-Member -type NoteProperty -name "FileName" -value ((Get-ChildItem $FullBackupLocation | Where-Object {$_.name -like "$FullBackupFilePrefix*"} | sort-object name -descending | select-object -first 1 -expand name).ToUpper())
    $Lastfullback | Add-Member -type NoteProperty -name "Mark" -value ((($Lastfullback.Filename).replace("$FullBackupFilePrefix", "")).TrimEnd(".BAK")) 
	return $Lastfullback
}

#Function to get all the log backups since the full backup
Function Get-Logbackups ($SQLServerName, $InstanceName, $database, $LogBackupLocation, $Lastfullback)
{
    If ($InstanceName -eq "MSSQLSERVER")
    {
        $LogBackupFilePrefix = ($SQLServerName + "_" + $database + "_Log_").ToUpper()
    }
    Else
    {
        $LogBackupFilePrefix = ($SQLServerName + "_" + $InstanceName + "_" + $database + "_Log_").ToUpper()
    }
    #Empty the array
    $LogFilesSinceLastFullBackup = New-Object System.Collections.ArrayList 
    $LogFilesSinceLastFullBackup.Clear()

    #Get all the log backups for the $database
    $LogBackups = Get-ChildItem $LogBackupLocation | Where-Object {$_.name -like "$LogBackupFilePrefix*"} | sort-object name -descending
	Foreach ($LogBackup in $LogBackups) 
	{
        $LogFile = New-Object System.Object 
        $LogFile | Add-Member -type NoteProperty -name "LogFileName" -value ($LogBackup.Name.ToUpper())
        $LogFile | Add-Member -type NoteProperty -name "Mark" -value (((($LogBackup.Name).ToUpper()).replace("$LogBackupFilePrefix", "")).TrimEnd(".BAK"))

        #Only keep files from the array that are older then the last full backup 
        if ($LogFile.mark -gt ($Lastfullback.Mark))
        {    
            $LogFilesSinceLastFullBackup.Add($Logfile) | out-null
        }
    } 
	Return $LogFilesSinceLastFullBackup
}

#Check if the locations exist. If one of the locations does not exist, exit the script.
CheckLocation $SQLOutputLocation
CheckLocation $FullBackupLocation
CheckLocation $LogBackupLocation
Write-host ""
if ($LocationNotExist -eq $true) {exit}

#Combine the name and location of the SQL output file
[STRING]$SQLOutputfile = join-path -path $SQLOutputLocation -childpath ("BizTalk_DB_restore_$(get-date -f dd-MM-yyyy_HH.mm.ss).sql")
[STRING]$FullBackupLocationAndFile = join-path -path $FullBackupLocation -childpath ($Lastfullback.FileName)

write-host "Generating BizTalk database restore file"
Add-Content $SQLOutputfile "--Generated BizTalk database restore file"
Add-Content $SQLOutputfile ("USE MASTER")
Add-Content $SQLOutputfile ("GO")
Add-Content $SQLOutputfile `n`n

Foreach ($database in $databases)
{
    write-host ""
    write-host $Database
    Add-Content $SQLOutputfile "--$Database"

	# Write the drop database statement for the $database to the restore file 
	if ($DropDatabases -eq $true)
	{
		Add-Content $SQLOutputfile ("ALTER DATABASE " + $Database)
		Add-Content $SQLOutputfile ("SET SINGLE_USER")
		Add-Content $SQLOutputfile ("WITH ROLLBACK IMMEDIATE;")
		Add-Content $SQLOutputfile ("GO")
		Add-Content $SQLOutputfile ("DROP DATABASE " + $Database)
		Add-Content $SQLOutputfile ("GO")
	}

    #Get the last full backup from the $FullBackupLocation
    $Lastfullback = Get-Lastfullback $SQLServerName $InstanceName $database $FullBackupLocation
    # Write the restore statement for the full backup to the restore file
    Add-Content $SQLOutputfile ("RESTORE DATABASE " + $Database + " FROM DISK = N'" + (join-path -path $FullBackupLocation -childpath ($Lastfullback.FileName)) + "' With NORECOVERY")
    write-host "The last full backup file is:" $Lastfullback.FileName

    #Get the log backups from the $LogBackupLocation since the last fullbackup
    $LogFilesSinceLastFullBackup = Get-Logbackups $SQLServerName $InstanceName $database $LogBackupLocation $Lastfullback
	write-host "Found" $LogFilesSinceLastFullBackup.count "log backup files."

    #If the count of log backups is 1 then the $OrderedLogFilesSinceLastFullBackup is the last log backup
    If ($LogFilesSinceLastFullBackup.count -eq 1)
    {  
        # Write the restore statement for the last log backup to the restore file       
        Add-Content $SQLOutputfile ("RESTORE LOG " + $Database + " FROM DISK = N'" + (join-path -path $LogBackupLocation -childpath ($LogFilesSinceLastFullBackup.LogFileName)) + "' With STOPATMARK = '" + ($LogFilesSinceLastFullBackup.Mark) + "'")  
    }
    Else
    { 
        #Get the last log backup
        $LogFilesSinceLastFullBackup = $LogFilesSinceLastFullBackup | sort-object Mark
        $script:LastLogBackup = $LogFilesSinceLastFullBackup[($LogFilesSinceLastFullBackup.Count-1)]

        Foreach ($logfile in ($LogFilesSinceLastFullBackup  | where-object {$_.mark -ne $LastLogBackup.mark}))
        {    
            # Write the restore statement for the log backup to the restore file   
            Add-Content $SQLOutputfile ("RESTORE LOG " + $Database + " FROM DISK = N'" + (join-path -path $LogBackupLocation -childpath ($logfile.LogFileName)) + "' With NORECOVERY")       
        }

    # Write the restore statement for the last log backup to the restore file 
    Add-Content $SQLOutputfile ("RESTORE LOG " + $Database + " FROM DISK = N'" + (join-path -path $LogBackupLocation -childpath ($LastLogBackup.LogFileName)) + "' With STOPATMARK = '" + ($LastLogBackup.Mark) + "'")
    }

Add-Content $SQLOutputfile "GO"
Add-Content $SQLOutputfile `n`n
}

write-host ""
write-host "Finished generating" -ForegroundColor Green
write-host "You can find the file here:" $SQLOutputfile -ForegroundColor Green