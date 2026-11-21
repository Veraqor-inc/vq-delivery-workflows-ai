// Template T8, landing step 2: the DEPLOY identity's custom role (M13 3.3 "Deploy identity, least privilege";
// same pattern as T1, Omar S12-5c, P2A-4). Run ONCE per solution per environment by the environment OWNER, into the
// SOLUTION resource group, after landing.bicep.
//
// Allowed: the resource types main.bicep deploys, and nothing else. It NEVER gets the tools' data roles or the
// executor's write roles, and never grants (Microsoft.Authorization/*).
//
// Hidden powers removed (lessons L1, L2; M13 3.3 "Hidden powers to check"):
//   - Cognitive Services listKeys/regenerateKey: key sign-in is off on Foundry anyway, so a listed key is useless;
//   - Search admin and query keys, App Configuration keys, storage keys and SAS: key sign-in off on each, removed here
//     too;
//   - Container Apps secrets and auth tokens (listSecrets, getAuthtoken) [verify the exact action names with --debug];
//   - Bot Service channel keys (listChannelWithKeys) [verify];
//   - Key Vault secrets and access policies; key DATA actions (sign) are data plane and never in this role.
// Deploy through Bicep by image digest (never `az containerapp up`/`update`, which may read registry credentials or
// workspace keys [verify with --debug]); the call inventory (catalogue t8.calls.json) lists every call.

targetScope = 'resourceGroup'

@allowed(['dev', 'qa', 'uat', 'prod'])
param environmentName string

@minLength(3)
@maxLength(12)
param solution string

@description('Object (principal) ID of this environment\'s deploy identity (landing.bicep output deployIdentityPrincipalId).')
param deployIdentityPrincipalId string

var deployActions = [
  'Microsoft.Resources/deployments/*'
  'Microsoft.Resources/subscriptions/resourceGroups/read'
  'Microsoft.Network/virtualNetworks/*'
  'Microsoft.Network/privateEndpoints/*'
  'Microsoft.Network/privateDnsZones/*'
  'Microsoft.OperationalInsights/workspaces/*'
  'Microsoft.Insights/components/*'
  'Microsoft.Insights/diagnosticSettings/*'
  'Microsoft.App/managedEnvironments/*'
  'Microsoft.App/containerApps/*'
  'Microsoft.App/jobs/*'
  // Container Apps long-running operations are polled through these (names checked against
  // `az provider operation show --namespace Microsoft.App`; 'Microsoft.App/operationResults/read' does not exist).
  'Microsoft.App/locations/containerappOperationResults/read'
  'Microsoft.App/locations/containerappOperationStatuses/read'
  'Microsoft.App/locations/managedEnvironmentOperationResults/read'
  'Microsoft.App/locations/managedEnvironmentOperationStatuses/read'
  'Microsoft.App/locations/containerappsjobOperationResults/read'
  'Microsoft.App/locations/containerappsjobOperationStatuses/read'
  'Microsoft.CognitiveServices/accounts/*'
  'Microsoft.KeyVault/vaults/*'
  'Microsoft.AppConfiguration/configurationStores/*'
  'Microsoft.Storage/storageAccounts/*'
  'Microsoft.Search/searchServices/*'
  'Microsoft.BotService/botServices/*'
]

var deployNotActions = [
  'Microsoft.Authorization/*'
  'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/*'
  'Microsoft.CognitiveServices/accounts/listKeys/action'
  'Microsoft.CognitiveServices/accounts/regenerateKey/action'
  'Microsoft.Search/searchServices/listAdminKeys/action'
  'Microsoft.Search/searchServices/regenerateAdminKey/action'
  'Microsoft.Search/searchServices/listQueryKeys/action'
  'Microsoft.Search/searchServices/createQueryKey/action'
  'Microsoft.AppConfiguration/configurationStores/ListKeys/action'
  'Microsoft.AppConfiguration/configurationStores/RegenerateKey/action'
  'Microsoft.Storage/storageAccounts/listKeys/action'
  'Microsoft.Storage/storageAccounts/regenerateKey/action'
  'Microsoft.Storage/storageAccounts/ListAccountSas/action'
  'Microsoft.Storage/storageAccounts/listServiceSas/action'
  'Microsoft.Storage/storageAccounts/localUsers/*'
  'Microsoft.Insights/components/ApiKeys/*'
  'Microsoft.OperationalInsights/workspaces/sharedKeys/action'
  'Microsoft.KeyVault/vaults/accessPolicies/write'
  'Microsoft.KeyVault/vaults/secrets/write'
  'Microsoft.App/containerApps/listSecrets/action'
  'Microsoft.App/containerApps/getAuthtoken/action'
  'Microsoft.App/jobs/listSecrets/action'
  'Microsoft.App/managedEnvironments/getAuthtoken/action'
  'Microsoft.BotService/botServices/channels/listChannelWithKeys/action'
  'Microsoft.CognitiveServices/accounts/privateEndpointConnections/write'
  'Microsoft.KeyVault/vaults/privateEndpointConnections/write'
  'Microsoft.Storage/storageAccounts/privateEndpointConnections/write'
  'Microsoft.AppConfiguration/configurationStores/privateEndpointConnections/write'
  'Microsoft.Search/searchServices/privateEndpointConnections/write'
]

resource deployRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(resourceGroup().id, 't8-deploy', solution, environmentName)
  properties: {
    roleName: 't8-deploy-${solution}-${environmentName}-${take(uniqueString(resourceGroup().id), 6)}'
    description: 'T8 deploy identity for ${solution} ${environmentName}: the template\'s resource types only; never grants, never reads keys, secrets or settings.'
    type: 'CustomRole'
    assignableScopes: [resourceGroup().id]
    permissions: [
      {
        actions: deployActions
        notActions: deployNotActions
        dataActions: []
        notDataActions: []
      }
    ]
  }
}

resource deployRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, deployIdentityPrincipalId, deployRole.id)
  properties: {
    principalId: deployIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: deployRole.id
  }
}

output roleDefinitionId string = deployRole.id
output roleName string = deployRole.properties.roleName
