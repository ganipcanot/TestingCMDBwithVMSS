Configuration Main
{
  param (
    [Parameter(Mandatory=$True)][string]                                    $WebDeployPackagePath,
    [Parameter(Mandatory=$True)][string]                                    $CmdDeployPackagePath,
    [Parameter(Mandatory=$True)][string]                                    $StorageKey,
    [Parameter(Mandatory=$True)][System.Management.Automation.PSCredential] $DomainAccount)

  Node ("localhost")
  {
    $windowsFeatures = @( 'Web-Mgmt-Tools', 'Web-Mgmt-Console', 'Web-Server', 'Web-App-Dev', 'Web-Scripting-Tools', 'Web-Net-Ext', 'Web-Net-Ext45', 'Web-Asp-Net',  'Web-Asp-Net45', 'Web-ISAPI-Ext', 'Web-ISAPI-Filter', 'Web-Includes', 'Web-Windows-Auth')
    foreach($feature in $windowsFeatures)
    {
      WindowsFeature $feature
      {
          Ensure = 'Present' 
          Name = $feature 
      }
    }

    #script block to download WebPI MSI from the Azure storage blob
    Script DownloadWebPIImage
    {
        GetScript = {
            @{
                Result = "WebPIInstall"
            }
        }
        TestScript = {
            Test-Path "C:\WindowsAzure\wpilauncher.exe"
        }
        SetScript ={
            $source = "http://go.microsoft.com/fwlink/?LinkId=255386"
            $destination = "C:\WindowsAzure\wpilauncher.exe"
            Invoke-WebRequest $source -OutFile $destination
        }
    }

    Package WebPi_Installation
    {
        Ensure = "Present"
        Name = "Microsoft Web Platform Installer 5.0"
        Path = "C:\WindowsAzure\wpilauncher.exe"
        ProductId = '4D84C195-86F0-4B34-8FDE-4A17EB41306A'
        Arguments = ''
    }

    Package WebDeploy_Installation
    {
        Ensure = "Present"
        Name = "Microsoft Web Deploy 3.5"
        Path = "$env:ProgramFiles\Microsoft\Web Platform Installer\WebPiCmd-x64.exe"
        ProductId = ''
        Arguments = "/install /products:WDeploy  /AcceptEula"
        DependsOn = @("[Package]WebPi_Installation")
    }

    Script DeployWebPackage
    {
        GetScript = {
            @{
                Result = ""
            }
        }
        TestScript = {
            $false
        }
        SetScript ={
            # Make sure we have the Azure powershell extensions installed
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
            Install-Module AzureRM -Force -AllowClobber
            Install-Module Azure -Force -AllowClobber

            # establish CTX and SA
            $ctx = New-AzureStorageContext -StorageAccountName cmdbstuff -StorageAccountKey $using:StorageKey
            $s = Get-AzureStorageShare cmdbbinaries -Context $ctx

            # Get the WEB BITS (From Azure SA)
            $Destination = "C:\WindowsAzure\Portal.WebModern.zip"
            Get-AzureStorageFileContent -Share $s -path $using:WebDeployPackagePath $Destination # Example: WebDeployPackagePath: "Portal.WebModern.zip"

            # Get the WEB deployment file (From Azure SA)
            $DestinationCMD = "C:\WindowsAzure\WebApplication1.deploy.cmd"
            Get-AzureStorageFileContent -Share $s -path $using:CmdDeployPackagePath $DestinationCMD # Example: CmdDeployPackagePath: "Portal.WebModern.deploy.cmd"

            # Make sure the Default site is deleted
            $Appcmd = "C:\Windows\System32\inetsrv\appcmd.exe"
            Start-Process $Appcmd -ArgumentList "delete site ""Default Web Site""" -Wait
            # Recycle the IIS memory every 10 requests otherwise RAM gets out of control
            # Start-Process $Appcmd -ArgumentList "set apppool /apppool.name: DefaultAppPool /recycling.periodicRestart.requests:10" -Wait
            
            # Create the site in IIS
            Start-Process $Appcmd -ArgumentList "add site /name:""CMDBModern"" /physicalPath:""C:\inetpub\Test"" /bindings:""http/*:80:""" -Wait

            # Execute the deployment of the web files
            Start-Process $DestinationCMD /Y -Verb runas -Wait

            # Add MSFT UN/PW to application pool
            Write-Host "BEGIN CONVERSION: Writing out the USERNAME and PASSWORD for DEBUG"
            $accName = $DomainAccount.UserName.Substring($DomainAccount.UserName.IndexOf("\")+1)
            $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($using:DomainAccount.Password)
            $UnsecurePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
            Start-Process $Appcmd -ArgumentList "set config /section:applicationPools /[name='DefaultAppPool'].processModel.identityType:SpecificUser /[name='DefaultAppPool'].processModel.userName:$accName /[name='DefaultAppPool'].processModel.password:$UnsecurePassword" -Wait

            # Enable Windows Authentication, Disable Anonymous Authentication
            Set-WebConfigurationProperty -filter /system.webServer/security/authentication/windowsAuthentication -name enabled -value true -PSPath IIS:\ -location CMDBModern
            Set-WebConfigurationProperty -Filter /system.webServer/security/authentication/anonymousAuthentication -Name Enabled -Value False -PSPath IIS:\ -Location CMDBModern

            Write-Host "Starting UN adding"
            ##### ADDING A COMPUTER TO THE REDMOND DOMAIN #####
            if ($env:userdomain -ne "REDMOND")
            {
                $domain     = "redmond.corp.microsoft.com"
                Add-Computer -DomainName $domain -Credential $DomainAccount

                # Pause for 10 seconds
                Start-Sleep -s 10

                ##### ADDING A USER AS ADMIN: #####
                Write-Host "START: ADDING USER as ADMIN"
                $group = [ADSI]("WinNT://"+$env:COMPUTERNAME+"/Administrators,group")
                $group.add("WinNT://" + $domain + "/" + $DomainAccount.UserName.Substring($DomainAccount.UserName.IndexOf("\")+1) +",user")
                Write-Host "END: ADDING USER as ADMIN"

                ##### RESTART COMPUTER (local): #####
                Restart-Computer -Force 
            }
        }
        DependsOn = @("[Package]WebDeploy_Installation")
    }
    
  } # end node

} # end Configuration
