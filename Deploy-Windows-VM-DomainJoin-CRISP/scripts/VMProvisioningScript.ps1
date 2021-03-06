param (
    #Location of CRISP components
    [string]$agentURI,
    #Domain group to add to remote desktop users for Server 2016 installs
    [string]$groupToAdd
)

add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@

$AllProtocols = [System.Net.SecurityProtocolType]'Ssl3,Tls,Tls11,Tls12'
[System.Net.ServicePointManager]::SecurityProtocol = $AllProtocols
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

#Function to write output to log file @ C:\Windows\Temp\ProvisioningScript.log
function WriteLog {
    Param( 
         $message
    )

    $timestampedMessage = $("[" + [System.DateTime]::Now + "] " + $message) | % {
        Out-File -InputObject $_ -FilePath "$env:WinDir\Temp\ProvisioningScript.log" -Append
    }
}

function unzip {
    param( [string]$ziparchive, [string]$extractpath )
    [System.IO.Compression.ZipFile]::ExtractToDirectory( $ziparchive, $extractpath )
}

#Cert URI for VA public cert chain
$certURI="http://aia.pki.va.gov/pki/aia/va/"

#Create temp directories for CRISP components and Certs
$agentsTemp = "C:\Temp\Agents"
$certsTemp = "C:\Temp\Certs"

WriteLog "Script Begin"

WriteLog "Agent URL: $agentURI"

#Add assembly for unzipping CRISP components
Add-Type -AssemblyName System.IO.Compression.FileSystem

#Create Temp Directory
New-Item -ItemType Directory -Path $agentsTemp -Force -Confirm: $false -Verbose
New-Item -ItemType Directory -Path $certsTemp -Force -Confirm: $false -Verbose

#Download Installers Zip File
Invoke-WebRequest -Uri $agentURI -OutFile "$agentsTemp\agents.zip" -Verbose

#Download Certificates required to join a machine to the domain
Invoke-WebRequest -Uri $certURI/VAInternalRoot.cer -OutFile "$certsTemp\VAInternalRoot.cer"
Invoke-WebRequest -Uri $certURI/VA-Internal-S2-RCA1-v1.cer -OutFile "$certsTemp\VA-Internal-S2-RCA1-v1.cer"
Invoke-WebRequest -Uri $certURI/VA-Internal-S2-ICA2-v1.cer -OutFile "$certsTemp\VA-Internal-S2-ICA2-v1.cer"
Invoke-WebRequest -Uri $certURI/VA-Internal-S2-ICA1-v1.cer -OutFile "$certsTemp\VA-Internal-S2-ICA1-v1.cer"
Invoke-WebRequest -Uri $certURI/InternalSubCA2.cer -OutFile "$certsTemp\InternalSubCA2.cer"
Invoke-WebRequest -Uri $certURI/InternalSubCA1.cer -OutFile "$certsTemp\InternalSubCA1.cer"

#Build array of certificates to import
$certsToImport=Get-ChildItem $certsTemp

#Import certs to Root store
ForEach ($cert in $certsToImport){

        $certDetails = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2

        $certDetails.Import($certsTemp+'\'+$cert.Name)

        if ($certDetails.SerialNumber -eq '28d5cb40101c62a44627e2d8c17f1ce9' -or $certDetails.SerialNumber -eq '037f7dcefd2991ac40cba54ee229be84'){

            #Check to see if the certificate is already imported into the Root store
            if (-not (Get-Childitem cert:\LocalMachine\Root | Where-Object {$_.Thumbprint -eq $certDetails.Thumbprint})) {

                $store = New-Object System.Security.Cryptography.X509Certificates.X509Store "Root", "LocalMachine"

                #Open the Root store in Read/Write mode
                $store.Open("ReadWrite")

                #Import the cert
                $store.Add($certsTemp+'\'+$cert)

                #Close the store
                $store.Close()

                WriteLog "$cert has been imported into the Root store"
               }

                else {
                    WriteLog "$cert was already present in the Root Certificate Store"
               }
        }
        #if (-not($certDetails.SerialNumber -eq '28d5cb40101c62a44627e2d8c17f1ce9' -or $certDetails.SerialNumber -eq '037f7dcefd2991ac40cba54ee229be84')){
            elseif (-not (Get-Childitem cert:\LocalMachine\CA | Where-Object {$_.Thumbprint -eq $certDetails.Thumbprint})) {
         
                $store = New-Object System.Security.Cryptography.X509Certificates.X509Store "CA", "LocalMachine"

                    #Open the Root store in Read/Write mode
                    $store.Open("ReadWrite")

                    #Import the cert
                    $store.Add($certsTemp+'\'+$cert)

                    #Close the store
                    $store.Close()

                    WriteLog "$cert has been imported into the CA store"
                    }
               
                    else {
                        WriteLog "$cert was already present in the CA Certificate Store"
                   }
      
                 
        }

#Extracting Zip File
unzip "$agentsTemp\agents.zip" $agentsTemp

#Install Chocolatey
Set-ExecutionPolicy Bypass -Scope Process -Force
Invoke-Expression $agentsTemp\chocolatey\chocolateyInstall.ps1

#Build array of CRISP components to install
$nupkgs=Get-ChildItem $agentsTemp | where {$_.name -like '*.nupkg'}

#Install CRISP components
Set-Location $agentsTemp

#Loop through array and install CRISP
ForEach ($pkg in $nupkgs){ 
    WriteLog "Installing Package $pkg.name"
    choco install $pkg.name -y -dv -s . 
    }

#Cleanup after install
Remove-Item -path $certsTemp -Recurse

Set-Location -path 'C:\Temp'

Remove-Item -path $agentsTemp -Recurse

#Add domain group for Server 2016 installs
if ((Get-WmiObject -Class Win32_OperatingSystem).Version -ge "10*" -and (Get-WmiObject -Class Win32_OperatingSystem).Caption -like "*2016*") {

        WriteLog "Server 2016 Detected. Adding group $groupToAdd to local groups"
            
        Add-LocalGroupMember -Group 'Administrators' -Member $groupToAdd
        Add-LocalGroupMember -Group 'Remote Desktop Users' -Member $groupToAdd
        }
            
ElseIf ((Get-WmiObject -Class Win32_OperatingSystem).Version -like "6.3*" -and (Get-WmiObject -Class Win32_OperatingSystem).Caption -like "*2012 R2*") {
       WriteLog "Windows Server 2012 R2 detected."
       WriteLog "Not adding any local group/accounts..."
    }
        
