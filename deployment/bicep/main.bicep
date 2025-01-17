targetScope='subscription'

// Parameters
@description('A short name for the workload being deployed')
param workloadName string

@description('The environment for which the deployment is being executed')
@allowed([
  'dev'
  'uat'
  'prod'
  'dr'
])
param environment string

@description('The user name to be used as the Administrator for all VMs created by this deployment')
param vmUsername string

@description('The password for the Administrator user for all VMs created by this deployment')
param vmPassword string

@description('The CI/CD platform to be used, and for which an agent will be configured for the ASE deployment. Specify \'none\' if no agent needed')
@allowed([
  'github'
  'azuredevops'
  'none'
])
param CICDAgentType string

@description('The Azure DevOps or GitHub account name to be used when configuring the CI/CD agent, in the format https://dev.azure.com/ORGNAME OR github.com/ORGUSERNAME OR none')
param accountName string

@description('The Azure DevOps or GitHub personal access token (PAT) used to setup the CI/CD agent')
@secure()
param personalAccessToken string



@description('The FQDN for the Application Gateway. Example - api.example.com.')
param appGatewayFqdn string

@description('The pfx password file for the Application Gataeway TLS listener. (base64 encoded)')
param appGatewayCertificateData     string

// Variables
var location = deployment().location
var resourceSuffix = '${workloadName}-${environment}-${location}-001'
var networkingResourceGroupName = 'rg-networking-${resourceSuffix}'
var sharedResourceGroupName = 'rg-shared-${resourceSuffix}'

var vmSuffix=environment
// RG Names Declaration

var backendResourceGroupName = 'rg-backend-${resourceSuffix}'

var apimResourceGroupName = 'rg-apim-${resourceSuffix}'

// Create resources name using these objects and pass it as a params in module
var sharedResourceGroupResources = {
  'appInsightsName':'appin-${resourceSuffix}'
  'logAnalyticsWorkspaceName': 'logananalyticsws-${resourceSuffix}'
   'environmentName': environment
   'resourceSuffix' : resourceSuffix
   'vmSuffix' : vmSuffix
   'keyVaultName':'kv-${workloadName}-${environment}' // Must be between 3-24 alphanumeric characters 
}

resource networkingRG 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: networkingResourceGroupName
  location: location
}

resource backendRG 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: backendResourceGroupName
  location: location
}

resource sharedRG 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: sharedResourceGroupName
  location: location
}

resource apimRG 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: apimResourceGroupName
  location: location
}

module networking 'networking.bicep' = {
  name: 'networkingresources'
  scope: resourceGroup(networkingRG.name)
  params: {
    workloadName: workloadName
    environment: environment
  }
}

module backend 'backend.bicep' = {
  name: 'backendresources'
  scope: resourceGroup(backendRG.name)
  params: {
    workloadName: workloadName
    environment: environment    
  }
}

var jumpboxSubnetId= networking.outputs.jumpBoxSubnetid
var CICDAgentSubnetId = networking.outputs.CICDAgentSubnetId

module shared './shared/shared.bicep' = {  dependsOn: [
  networking
]
name: 'sharedresources'
scope: resourceGroup(sharedRG.name)
params: {
  accountName: accountName
  CICDAgentSubnetId: CICDAgentSubnetId
  CICDAgentType: CICDAgentType
  environment: environment
  jumpboxSubnetId: jumpboxSubnetId
  location: location
  personalAccessToken: personalAccessToken
  resourceGroupName: sharedRG.name
  resourceSuffix: resourceSuffix
  vmPassword: vmPassword
  vmUsername: vmUsername
}
}

module apimModule 'apim/apim.bicep'  = {
  name: 'apimDeploy'
  scope: resourceGroup(apimRG.name)
  params: {
    apimSubnetId: networking.outputs.apimSubnetid
    location: location
    appInsightsName: shared.outputs.appInsightsName
    appInsightsId: shared.outputs.appInsightsId
    appInsightsInstrumentationKey: shared.outputs.appInsightsInstrumentationKey
  }
}

//Creation of private DNS zones
module dnsZoneModule 'shared/dnszone.bicep'  = {
  name: 'apimDnsZoneDeploy'
  scope: resourceGroup(sharedRG.name)
  params: {
    vnetName: networking.outputs.apimCSVNetName
    vnetRG: networkingRG.name
    apimName: apimModule.outputs.apimName
    apimRG: apimRG.name
  }
}

module appgwModule 'gateway/appgw.bicep' = {
  name: 'appgwDeploy'
  scope: resourceGroup(apimRG.name)
  dependsOn: [
    apimModule
    dnsZoneModule
  ]
  params: {
    appGatewayName:                 'appgw-${resourceSuffix}'
    appGatewayFQDN:                 appGatewayFqdn
    location:                       location
    appGatewaySubnetId:             networking.outputs.appGatewaySubnetid
    primaryBackendEndFQDN:          '${apimModule.outputs.apimName}.azure-api.net'
    appGatewayCertificateData:      appGatewayCertificateData
    keyVaultName:                   shared.outputs.keyVaultName
    keyVaultResourceGroupName:      sharedRG.name
  }
}
