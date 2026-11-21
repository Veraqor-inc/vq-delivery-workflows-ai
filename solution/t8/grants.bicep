// Template T8, landing step 3: the DATA-PLANE grants, run ONCE by the environment OWNER after the first main.bicep
// deploy (M13 3.3; the deploy identity never grants). Each role is on ONE resource, to ONE identity:
//   - gateway   Cognitive Services User on this environment's Foundry account (the only model caller); Storage Blob
//               Data Contributor on the `spend` container only (shared spend counters);
//               App Configuration Data Reader (reads the kill switch);
//   - approval  a custom "sign only" role on the ONE approval key (keys/sign, keys/read);
//   - executor  a custom "read the key" role on the approval key (verifies signatures); App Configuration Data
//               Reader (kill switch). Its WRITE roles on back ends (e.g. Dunewell's T1 API app role) are granted
//               where those back ends live, never here and never to any other identity;
//   - agent     no data role here (skills ship inside the image, Omar B5). No Foundry role, no write role;
//   - tool      Search Index Data Reader on the search service (T8-K);
//   - ingestion Search Index Data Contributor (T8-K ingestion job, when it exists);
//   - all four apps: Monitoring Metrics Publisher on Application Insights (Entra ingestion, local auth off);
//   - deploy    T8-K only: a CUSTOM search role on the one search service (Omar B2): service read, index
//               definitions read/write and documents read/write. No admin or query keys, no service write (so it can
//               never set disableLocalAuth back to false). Nothing else;
//   - the customer's OWNER GROUP: App Configuration Data Owner, to flip the kill switch without a deploy (3.3.3).
// After this, the owner creates the run switch `agent:enabled` = "true" (until then the agent stays off; any other
// value stops both the gateway and the executor: one shared parser, Omar A2).

targetScope = 'resourceGroup'

@allowed(['dev', 'qa', 'uat', 'prod'])
param environmentName string

@minLength(3)
@maxLength(12)
param solution string

param foundryName string
param keyVaultName string
param appConfigName string
param storageName string
param appInsightsName string
@description('Empty when the solution has no knowledge tool.')
param searchName string = ''

param agentPrincipalId string
param gatewayPrincipalId string
param approvalPrincipalId string
param executorPrincipalId string
param toolPrincipalId string
@description('The deploy identity of this environment (landing.bicep output deployIdentityPrincipalId).')
param deployPrincipalId string
@description('T8-K ingestion job identity (empty until the job exists).')
param ingestionPrincipalId string = ''
@description('The customer\'s named owner group (Entra object ID) that may flip the kill switch.')
param ownerGroupObjectId string

var roles = {
  cognitiveServicesUser: 'a97b65f3-24c7-4388-baec-2e87135dc908'
  appConfigDataReader: '516239f1-63e1-4d78-a4de-a74fb236a071'
  appConfigDataOwner: '5ae67dd6-50cb-40e7-96ff-dc2bfa4b606b'
  searchIndexDataReader: '1407120a-92aa-4202-b7e9-c0e197c71c8f'
  searchIndexDataContributor: '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
  monitoringMetricsPublisher: '3913510d-42f4-4e42-8a64-420c390055eb'
  storageBlobDataContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
}
// Omar B2: the deploy identity's search role, in place of built-in Search Service Contributor (7ca78c08), which
// includes listAdminKeys and searchServices/write (and so could set disableLocalAuth back to false). [verify] Elena
// reads back the effective permissions after landing.
var searchDefinitionsActions = [
  'Microsoft.Search/searchServices/read'
  'Microsoft.Search/searchServices/indexes/read'
  'Microsoft.Search/searchServices/indexes/write'
]
var searchDefinitionsDataActions = [
  'Microsoft.Search/searchServices/indexes/documents/read'
  'Microsoft.Search/searchServices/indexes/documents/write'
]
func roleId(id string) string => subscriptionResourceId('Microsoft.Authorization/roleDefinitions', id)

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: foundryName
}
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}
resource approvalKey 'Microsoft.KeyVault/vaults/keys@2023-07-01' existing = {
  parent: kv
  name: 'approval'
}
resource appConfig 'Microsoft.AppConfiguration/configurationStores@2024-05-01' existing = {
  name: appConfigName
}
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageName
}
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' existing = {
  parent: storage
  name: 'default'
}
resource spendContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' existing = {
  parent: blobService
  name: 'spend'
}
resource appi 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}
resource search 'Microsoft.Search/searchServices@2024-06-01-preview' existing = if (!empty(searchName)) {
  name: empty(searchName) ? 'none' : searchName
}

// ---------- custom key roles, each assignable on this group only and assigned on the one key ----------
resource keySignRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(resourceGroup().id, 't8-approval-sign', solution, environmentName)
  properties: {
    roleName: 't8-approval-sign-${solution}-${environmentName}-${take(uniqueString(resourceGroup().id), 6)}'
    description: 'Sign with one Key Vault key and read its public part. Nothing else.'
    type: 'CustomRole'
    assignableScopes: [resourceGroup().id]
    permissions: [{ actions: [], notActions: [], dataActions: ['Microsoft.KeyVault/vaults/keys/sign/action', 'Microsoft.KeyVault/vaults/keys/read'], notDataActions: [] }]
  }
}

resource keyReadRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(resourceGroup().id, 't8-approval-read', solution, environmentName)
  properties: {
    roleName: 't8-approval-read-${solution}-${environmentName}-${take(uniqueString(resourceGroup().id), 6)}'
    description: 'Read the public part of one Key Vault key (verify signatures locally). Nothing else.'
    type: 'CustomRole'
    assignableScopes: [resourceGroup().id]
    permissions: [{ actions: [], notActions: [], dataActions: ['Microsoft.KeyVault/vaults/keys/read'], notDataActions: [] }]
  }
}

resource searchDefinitionsRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = if (!empty(searchName)) {
  name: guid(resourceGroup().id, 't8-search-definitions', solution, environmentName)
  properties: {
    roleName: 't8-search-definitions-${solution}-${environmentName}-${take(uniqueString(resourceGroup().id), 6)}'
    description: 'Read the search service; read and write index definitions and documents. No keys, no service write.'
    type: 'CustomRole'
    assignableScopes: [resourceGroup().id]
    permissions: [{ actions: searchDefinitionsActions, notActions: [], dataActions: searchDefinitionsDataActions, notDataActions: [] }]
  }
}

resource gatewayFoundry 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundry
  name: guid(foundry.id, gatewayPrincipalId, roles.cognitiveServicesUser)
  properties: { principalId: gatewayPrincipalId, principalType: 'ServicePrincipal', roleDefinitionId: roleId(roles.cognitiveServicesUser) }
}

resource gatewaySwitch 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: appConfig
  name: guid(appConfig.id, gatewayPrincipalId, roles.appConfigDataReader)
  properties: { principalId: gatewayPrincipalId, principalType: 'ServicePrincipal', roleDefinitionId: roleId(roles.appConfigDataReader) }
}

resource executorSwitch 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: appConfig
  name: guid(appConfig.id, executorPrincipalId, roles.appConfigDataReader)
  properties: { principalId: executorPrincipalId, principalType: 'ServicePrincipal', roleDefinitionId: roleId(roles.appConfigDataReader) }
}

resource ownerSwitch 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: appConfig
  name: guid(appConfig.id, ownerGroupObjectId, roles.appConfigDataOwner)
  properties: { principalId: ownerGroupObjectId, principalType: 'Group', roleDefinitionId: roleId(roles.appConfigDataOwner) }
}

resource approvalSign 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: approvalKey
  name: guid(approvalKey.id, approvalPrincipalId, keySignRole.id)
  properties: { principalId: approvalPrincipalId, principalType: 'ServicePrincipal', roleDefinitionId: keySignRole.id }
}

resource executorKeyRead 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: approvalKey
  name: guid(approvalKey.id, executorPrincipalId, keyReadRole.id)
  properties: { principalId: executorPrincipalId, principalType: 'ServicePrincipal', roleDefinitionId: keyReadRole.id }
}

resource toolSearch 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(searchName)) {
  scope: search
  name: guid(resourceGroup().id, searchName, toolPrincipalId, roles.searchIndexDataReader)
  properties: { principalId: toolPrincipalId, principalType: 'ServicePrincipal', roleDefinitionId: roleId(roles.searchIndexDataReader) }
}

resource ingestionSearch 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(searchName) && !empty(ingestionPrincipalId)) {
  scope: search
  name: guid(resourceGroup().id, searchName, ingestionPrincipalId, roles.searchIndexDataContributor)
  properties: { principalId: ingestionPrincipalId, principalType: 'ServicePrincipal', roleDefinitionId: roleId(roles.searchIndexDataContributor) }
}

resource telemetry 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for p in [agentPrincipalId, gatewayPrincipalId, approvalPrincipalId, executorPrincipalId]: {
  scope: appi
  name: guid(appi.id, p, roles.monitoringMetricsPublisher)
  properties: { principalId: p, principalType: 'ServicePrincipal', roleDefinitionId: roleId(roles.monitoringMetricsPublisher) }
}]

resource deploySearch 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(searchName)) {
  scope: search
  name: guid(resourceGroup().id, searchName, deployPrincipalId, 't8-search-definitions')
  properties: { principalId: deployPrincipalId, principalType: 'ServicePrincipal', roleDefinitionId: searchDefinitionsRole.id }
}

// Omar's Low (security-review-m13-t8-code.md 1.1): the deploy role holds Microsoft.Storage/storageAccounts/*, so it
// could delete the account and with it every spend counter and its history (a fresh account reads as 0). The owner's
// CanNotDelete lock stops that; the deploy role can never remove it (Microsoft.Authorization/* is denied). Versioning
// and soft delete staying on is enforced by Policy (policy.bicep).
resource spendLock 'Microsoft.Authorization/locks@2020-05-01' = {
  scope: storage
  name: 'no-delete-spend-counters'
  properties: {
    level: 'CanNotDelete'
    notes: 'T8: the gateway spend counters and their history live here. Removing this lock is an owner action (deploy-notes).'
  }
}

resource gatewaySpend 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: spendContainer
  name: guid(spendContainer.id, gatewayPrincipalId, roles.storageBlobDataContributor)
  properties: { principalId: gatewayPrincipalId, principalType: 'ServicePrincipal', roleDefinitionId: roleId(roles.storageBlobDataContributor) }
}
