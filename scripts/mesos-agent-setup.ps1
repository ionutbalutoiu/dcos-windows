# Copyright 2018 Microsoft Corporation
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.
#

Param(
    [Parameter(Mandatory=$true)]
    [string]$AgentBlobDirectory,
    [Parameter(Mandatory=$true)]
    [string[]]$MasterAddress,
    [string]$AgentPrivateIP,
    [switch]$Public=$false,
    [string]$CustomAttributes
)

$ErrorActionPreference = "Stop"

$utils = (Resolve-Path "$PSScriptRoot\Modules\Utils").Path
Import-Module $utils

$variables = (Resolve-Path "$PSScriptRoot\variables.ps1").Path
. $variables


$TEMPLATES_DIR = Join-Path $PSScriptRoot "Templates"


function Get-MesosServiceDetails {
    if($Public) {
        return @{
            "name" = $MESOS_PUBLIC_SERVICE_NAME
            "display_name" = $MESOS_PUBLIC_SERVICE_DISPLAY_NAME
            "description" = $MESOS_PUBLIC_SERVICE_DESCRIPTION
        }
    }
    return @{
        "name" = $MESOS_SERVICE_NAME
        "display_name" = $MESOS_SERVICE_DISPLAY_NAME
        "description" = $MESOS_SERVICE_DESCRIPTION
    }
}

function New-MesosEnvironment {
    $serviceDetails = Get-MesosServiceDetails
    $service = Get-Service $serviceDetails["name"] -ErrorAction SilentlyContinue
    if($service) {
        Stop-Service -Force -Name $serviceDetails["name"]
        & sc.exe delete $serviceDetails["name"]
        if($LASTEXITCODE) {
            Throw "Failed to delete exiting $($serviceDetails["name"]) service"
        }
        Write-Log "Deleted existing $($serviceDetails["name"]) service"
    }
    New-Directory -RemoveExisting $MESOS_DIR
    New-Directory $MESOS_BIN_DIR
    New-Directory $MESOS_LOG_DIR
    New-Directory $MESOS_WORK_DIR
    New-Directory $MESOS_SERVICE_DIR
}

function Install-MesosBinaries {
    $binariesPath = Join-Path $AgentBlobDirectory "mesos.zip"
    Write-Log "Extracting $binariesPath to $MESOS_BIN_DIR"
    Expand-7ZIPFile -File $binariesPath -DestinationPath $MESOS_BIN_DIR
    Add-ToSystemPath $MESOS_BIN_DIR
    Remove-File -Path $binariesPath -Fatal $false
}

function Get-MesosAgentAttributes {
    if($CustomAttributes) {
        return $CustomAttributes
    }
    $attributes = "os:windows"
    if($Public) {
        $attributes += ";public_ip:yes"
    }
    return $attributes
}

function Get-MesosAgentPrivateIP {
    if($AgentPrivateIP) {
        return $AgentPrivateIP
    }
    $primaryIfIndex = (Get-NetRoute -DestinationPrefix "0.0.0.0/0").ifIndex
    return (Get-NetIPAddress -AddressFamily IPv4 -ifIndex $primaryIfIndex).IPAddress
}

function New-MesosWindowsAgent {
    $mesosBinary = Join-Path $MESOS_BIN_DIR "mesos-agent.exe"
    $agentAddress = Get-MesosAgentPrivateIP
    $mesosAttributes = Get-MesosAgentAttributes
    $masterZkAddress = "zk://" + ($MasterAddress -join ":2181,") + ":2181/mesos"
    $mesosPath = ($DOCKER_HOME -replace '\\', '\\') + ';' + ($MESOS_BIN_DIR -replace '\\', '\\')
    $logFile = Join-Path $MESOS_LOG_DIR "mesos-agent.log"
    New-Item -ItemType File -Path $logFile
    $mesosAgentArguments = ("--master=`"${masterZkAddress}`"" + `
                           " --work_dir=`"${MESOS_WORK_DIR}`"" + `
                           " --runtime_dir=`"${MESOS_WORK_DIR}`"" + `
                           " --launcher_dir=`"${MESOS_BIN_DIR}`"" + `
                           " --external_log_file=`"${logFile}`"" + `
                           " --ip=`"${agentAddress}`"" + `
                           " --isolation=`"windows/cpu,windows/mem,filesystem/windows`"" + `
                           " --containerizers=`"docker,mesos`"" + `
                           " --attributes=`"${mesosAttributes}`"" + `
                           " --executor_registration_timeout=$MESOS_REGISTER_TIMEOUT" + `
                           " --hostname=`"${AgentPrivateIP}`"" +
                           " --executor_environment_variables=`"{\\\`"PATH\\\`": \\\`"${mesosPath}\\\`"}`"")
    if($Public) {
        $mesosAgentArguments += " --default_role=`"slave_public`""
    }
    $environmentFile = Join-Path $MESOS_ETC_SERVICE_DIR "environment-file"
    if (!(Test-Path $environmentFile)) {
        if(!(Test-Path $MESOS_ETC_SERVICE_DIR)) {
            New-Item -ItemType "Directory" -Path $MESOS_ETC_SERVICE_DIR -Force
        }
        Set-Content -Path $environmentFile -Value @(
            "MESOS_AUTHENTICATE_HTTP_READONLY=false",
            "MESOS_AUTHENTICATE_HTTP_READWRITE=false"
        )
    }
    $serviceDetails = Get-MesosServiceDetails
    New-DCOSWindowsService -Name $serviceDetails["name"] -DisplayName $serviceDetails["display_name"] -Description $serviceDetails["description"] `
                           -LogFile $logFile -WrapperPath $SERVICE_WRAPPER -BinaryPath "$mesosBinary $mesosAgentArguments" `
                           -EnvironmentFiles @($environmentFile)
    Start-Service $serviceDetails["name"]
}

try {
    New-MesosEnvironment
    Install-MesosBinaries
    New-MesosWindowsAgent
    Open-WindowsFirewallRule -Name "Allow inbound TCP Port $MESOS_AGENT_PORT for Mesos Slave" -Direction "Inbound" -LocalPort $MESOS_AGENT_PORT -Protocol "TCP"
    Open-WindowsFirewallRule -Name "Allow inbound TCP Port $ZOOKEEPER_PORT for Zookeeper" -Direction "Inbound" -LocalPort $ZOOKEEPER_PORT -Protocol "TCP" # It's needed on the private DCOS agents
} catch {
    Write-Log $_.ToString()
    exit 1
}
Write-Log "Successfully finished setting up the Windows Mesos Agent"
exit 0
