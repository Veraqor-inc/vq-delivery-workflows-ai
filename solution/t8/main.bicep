// Template T8 "AI agents and skills" (M13 3.3, 3.3.2, 3.3.3, 3.4; Omar T8-H8, H9, H10 and S12-23).
//
// What one environment of one T8 solution gets, deployed by the platform's T8 deploy workflow under that
// solution's deploy identity for THIS environment:
//   - a Container Apps environment (workload profiles, VNet-integrated) with five apps, each with ITS OWN identity:
//       agent     the front doors (web chat API, Teams /api/messages) and the Agent SDK turn. Public ingress (Bot
//                 Service and the web page must reach it). It holds NO write role and NO model credential, and has
//                 no approval route.
//       approvals the APPROVAL DOOR (Omar A1): takes the approver's delegated Approvals.Decide token for the approvals
//                 API (approvalsAudience, never the agent's chat audience) and posts the decision with its OWN
//                 identity, so the agent identity can never relay a decision. Public ingress.
//       gateway   the metering gateway (the platform's gateway image): the ONLY caller of Foundry, caps and the
//                 kill switch. Internal ingress.
//       approval  the approval service: signs approval records with its Key Vault key (sign right only). Internal.
//       executor  the only identity with write roles on back ends; checks the kill switch. Internal.
//     Images are pulled BY DIGEST with a pull identity whose lifecycle is None (not usable at run time).
//   - Foundry (AIServices) with one Claude deployment, key sign-in OFF, reached through a private endpoint;
//   - Key Vault (RBAC, purge protection) holding the approval key (EC P-256, sign/verify, not exportable);
//   - App Configuration (key sign-in off) holding the run switch `agent:enabled` (created by the owner at
//     landing; a missing flag counts as OFF, so the agent stays off until the owner sets it to exactly "true");
//   - Storage (shared keys off, blob soft delete and versioning) for the gateway's spend counters;
//   - T8-K only (enableKnowledge): Azure AI Search, key sign-in off;
//   - Log Analytics (key sign-in off, daily cap) and Application Insights (local auth off); every app logs there
//     through Azure Monitor (no shared key);
//   - an Azure Bot (single tenant, the agent's user-assigned identity, no secret) when enableTeams.
//
// What this file deliberately does NOT do (the deploy role excludes Microsoft.Authorization/*):
//   - no role assignments: the owner runs grants.bicep once (landing kit). The tools' data roles and the
//     executor's write roles are never the deploy identity's;
//   - no identities: they live in the identity resource group (landing.bicep);
//   - no secrets anywhere: no API keys, no connection strings, no app-setting secrets (`secrets: []` on every app);
//   - no Teams channel: Bot Service channel set-up may need rights outside the group [verify], so it is an owner
//     landing step, with the Teams app uploaded by the tenant's Teams admin (readiness item).

targetScope = 'resourceGroup'

@allowed(['dev', 'qa', 'uat', 'prod'])
param environmentName string

@minLength(3)
@maxLength(12)
@description('The solution short name: lower-case letters and digits, 3 to 12.')
param solution string

@description('Azure region. West US 3 by default (Omar M19-1; the customer profile\'s allowed region for a T8 solution\'s Claude, decision M13-19).')
param location string = 'westus3'

@description('The identity resource group (landing.bicep).')
param identityResourceGroup string

param agentIdentityName string
param gatewayIdentityName string
param approvalIdentityName string
@description('The approval door\'s identity (Omar A1(b)): the only identity that may post decisions; never the agent\'s.')
param approvalDoorIdentityName string
param executorIdentityName string
@description('The tools\' read identity (maintenance API read, Search Index Data Reader). Attached to the agent app for its in-process tools.')
param toolIdentityName string
@description('T8-K ingestion job identity (Search Index Data Contributor; grants.bicep).')
param ingestionIdentityName string = ''
@description('Image pull only (AcrPull on the registry), attached with lifecycle None.')
param pullIdentityName string

@description('Login server of the registry the images come from, e.g. <name>.azurecr.io.')
param registryServer string
@description('The T8 image by digest: <registry>/<repo>@sha256:<64 hex>.')
param agentImage string
@description('The platform gateway image by digest.')
param gatewayImage string

// Audiences are plain application (client) IDs (GUIDs), not api://<appId>: every T8 registration issues v2 tokens
// (requestedAccessTokenVersion 2), the apps accept only the v2 issuer, and a v2 token's aud claim is the appId.
@description('Application (client) ID GUID of the agent\'s API registration (the aud of the people\'s v2 tokens). Not a secret.')
param agentAudience string
@description('Application (client) ID GUID the apps use between themselves (aud of the service-to-service v2 tokens). Not a secret.')
param serviceAudience string
@description('Application (client) ID GUID of the APPROVALS API (its own app registration, delegated scope Approvals.Decide only; Omar A1(a)); aud of the approver\'s v2 token. Must differ from agentAudience. Not a secret.')
param approvalsAudience string
@description('Application (client) ID GUID of the gateway audience (aud of the agent\'s managed-identity v2 token). Not a secret.')
param gatewayAudience string

@description('Skill the agent loads (a folder under skills/).')
param skill string

@description('The skills hash of the release being deployed (sha256:<64 hex>). The image is the ONLY source of skills (Omar B5): the agent refuses to start unless the skills inside its image hash to exactly this value.')
param skillsHash string

@description('The Claude deployment: name, model, version, sku (DataZoneStandard), capacity (30 or less: Omar M19-3, VQ Data Zone quota).')
param model object
@description('Provider data Foundry needs for Claude deployments (organisation, country, industry).')
param claudeProviderData object

@description('Dunewell-style tools: the T1 maintenance API base URL and its Entra scope (empty: no maintenance tools).')
param maintenanceApiUrl string = ''
param maintenanceApiScope string = ''

@description('T8-K: create Azure AI Search for the knowledge tool.')
param enableKnowledge bool = false
param searchIndex string = 'documents'
@description('T8-K source: the SharePoint site, library (drive) and root folder by Graph ID (empty: the synthetic folder in the image).')
param sharePointSiteId string = ''
param sharePointDriveId string = ''
param sharePointRootItemId string = ''
@description('Expand nested groups in access lists (needs GroupMember.Read.All on the ingestion identity: Omar approval per customer).')
param expandNestedGroups bool = false
@description('T8-K access-list refresh: the schedule of the ingestion job (cron, UTC). Default every 4 hours (M13 3.4).')
param ingestionSchedule string = '0 */4 * * *'

@description('Teams front door: create the Azure Bot (single tenant, the agent\'s identity).')
param enableTeams bool = false

@description('Approver object IDs for consequential actions (the customer\'s recorded list). Required in uat and prod (Omar A1(c)); in dev and qa empty = any signed-in approver other than the requester.')
param approverObjectIds array = []

@description('Who may chat with the agent (Entra object IDs; CHAT_USER_OIDS). Empty = anyone signed in and assigned. Never an approver: an overlap with approverObjectIds is refused (Omar ruling 3.1).')
param chatUserObjectIds array = []

@description('Per-person daily limits on top of the gateway caps (Omar M1): turns per day (1 to 1000) and estimated USD per day (more than 0, at most 100; a string so decimals pass through).')
@minValue(1)
@maxValue(1000)
param dailyTurnsPerPerson int = 60
param dailyUsdPerPerson string = '10'

@minValue(1)
@maxValue(24)
param approvalLifetimeHours int = 24

@description('Spend caps the solution gateway enforces (USD; strings so decimals pass through).')
param conversationCapUsd string = '2'
param monthlyCapUsd string = '100'

param vnetPrefix string = '10.70.0.0/24'
param logDailyCapGb string = '0.2'
param extraTags object = {}

var isProd = environmentName == 'prod'
var isPrivateTier = environmentName == 'uat' || environmentName == 'prod'
var base = '${solution}-${environmentName}'
var uniq = take(uniqueString(subscription().id, resourceGroup().id, solution, environmentName), 6)
var compact = '${take(solution, 10)}${take(environmentName, 4)}${uniq}'
var tags = union(extraTags, {
  solution: solution
  environment: environmentName
  template: 't8'
  'managed-by': 'pipeline'
})

// ---------- Images by digest only (3.3.1 item 2: the same digest runs in every environment) ----------
var digestOk = contains(agentImage, '@sha256:') && length(last(split(agentImage, '@sha256:'))) == 64 && contains(gatewayImage, '@sha256:') && length(last(split(gatewayImage, '@sha256:'))) == 64
var checkedAgentImage = digestOk ? agentImage : json('images must be pinned by digest (<repo>@sha256:<64 hex>): ${agentImage} ${gatewayImage}')
var checkedGatewayImage = digestOk ? gatewayImage : json('images must be pinned by digest (<repo>@sha256:<64 hex>): ${agentImage} ${gatewayImage}')

// ---------- The skills hash the image must carry (Omar B5) ----------
var checkedSkillsHash = startsWith(skillsHash, 'sha256:') && length(skillsHash) == 71 ? skillsHash : json('skillsHash must be sha256:<64 hex>: ${skillsHash}')

// ---------- Model capacity (Omar M19-3): VQ's Data Zone quota for claude-sonnet-5-5 in West US 3 is shared with the
// eval deployment (80 total, eval 50), so one solution environment takes at most 30. More needs a quota request first.
var maxModelCapacity = 30
var checkedModelCapacity = int(model.capacity) >= 1 && int(model.capacity) <= maxModelCapacity ? int(model.capacity) : json('model.capacity must be 1 to ${maxModelCapacity} (VQ quota, Omar M19-3): ${model.capacity}')

// ---------- Approvals (Omar A1): an approver list in uat and prod, and an approvals audience of its own ----------
var checkedApprovers = isPrivateTier && empty(approverObjectIds) ? json('${environmentName} needs an approver list (approverObjectIds): an empty list lets anyone in the tenant approve') : approverObjectIds
// Object ID lists (approvers and chat users): every entry a lower-case-able GUID. Removing the 16 hex digits must leave
// exactly the four dashes, in the 8-4-4-4-12 places. The dash checks read a copy padded to at least 36 characters by
// concatenation (ARM's padLeft allows a width of at most 16), so a short entry fails the length check, not substring().
var oidPad = '000000000000000000000000000000000000'
var oidProblems = filter(concat(approverObjectIds, chatUserObjectIds), o => length(string(o)) != 36 || replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(toLower(string(o)), '0', ''), '1', ''), '2', ''), '3', ''), '4', ''), '5', ''), '6', ''), '7', ''), '8', ''), '9', ''), 'a', ''), 'b', ''), 'c', ''), 'd', ''), 'e', ''), 'f', '') != '----' || substring('${string(o)}${oidPad}', 8, 1) != '-' || substring('${string(o)}${oidPad}', 13, 1) != '-' || substring('${string(o)}${oidPad}', 18, 1) != '-' || substring('${string(o)}${oidPad}', 23, 1) != '-')
var approversLower = map(approverObjectIds, o => toLower(string(o)))
var chatUsersLower = map(chatUserObjectIds, o => toLower(string(o)))
var oidOverlap = intersection(approversLower, chatUsersLower)
var checkedApproverList = !empty(oidProblems) ? json('approverObjectIds and chatUserObjectIds must list Entra object IDs (GUIDs): ${join(map(oidProblems, o => string(o)), ', ')}') : !empty(oidOverlap) ? json('a chat user can never be an approver (Omar ruling 3.1): ${join(oidOverlap, ', ')}') : join(map(checkedApprovers, o => toLower(string(o))), ',')
var checkedChatUsers = empty(oidProblems) && empty(oidOverlap) ? join(chatUsersLower, ',') : json('chat users refused (see approverObjectIds): ${join(chatUsersLower, ', ')}')

// Per-person daily spend limit: more than 0 and at most 100 USD (the app refuses anything else at start, too).
var checkedDailyUsd = json(dailyUsdPerPerson) > 0 && json(dailyUsdPerPerson) <= 100 ? dailyUsdPerPerson : json('dailyUsdPerPerson must be more than 0 and at most 100: ${dailyUsdPerPerson}')

var checkedApprovalsAudience = approvalsAudience == agentAudience ? json('approvalsAudience ${approvalsAudience} must be its own app registration, not the agent\'s chat audience') : approvalsAudience

// ---------- Identities (landing.bicep, identity group) ----------
resource agentId 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  scope: resourceGroup(identityResourceGroup)
  name: agentIdentityName
}
resource gatewayId 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  scope: resourceGroup(identityResourceGroup)
  name: gatewayIdentityName
}
resource approvalId 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  scope: resourceGroup(identityResourceGroup)
  name: approvalIdentityName
}
resource approvalDoorId 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  scope: resourceGroup(identityResourceGroup)
  name: approvalDoorIdentityName
}
resource executorId 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  scope: resourceGroup(identityResourceGroup)
  name: executorIdentityName
}
resource toolId 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  scope: resourceGroup(identityResourceGroup)
  name: toolIdentityName
}
resource ingestionId 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = if (enableKnowledge) {
  scope: resourceGroup(identityResourceGroup)
  name: empty(ingestionIdentityName) ? 'none' : ingestionIdentityName
}
resource pullId 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  scope: resourceGroup(identityResourceGroup)
  name: pullIdentityName
}

// ---------- Network ----------
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${base}'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [vnetPrefix] }
    subnets: [
      {
        name: 'snet-apps'
        properties: {
          addressPrefix: cidrSubnet(vnetPrefix, 25, 0)
          delegations: [{ name: 'apps', properties: { serviceName: 'Microsoft.App/environments' } }]
        }
      }
      {
        name: 'snet-pe'
        properties: {
          addressPrefix: cidrSubnet(vnetPrefix, 26, 2)
          privateEndpointNetworkPolicies: 'Disabled'
          defaultOutboundAccess: false
        }
      }
    ]
  }
}

var appsSubnetId = '${vnet.id}/subnets/snet-apps'
var peSubnetId = '${vnet.id}/subnets/snet-pe'

var zoneNames = {
  vault: 'privatelink.vaultcore.azure.net'
  blob: 'privatelink.blob.${environment().suffixes.storage}'
  cognitive: 'privatelink.cognitiveservices.azure.com'
  openai: 'privatelink.openai.azure.com'
  aiservices: 'privatelink.services.ai.azure.com'
  appconfig: 'privatelink.azconfig.io'
  search: 'privatelink.search.windows.net'
}
var zoneList = concat([zoneNames.vault, zoneNames.blob, zoneNames.cognitive, zoneNames.openai, zoneNames.aiservices], isPrivateTier ? [zoneNames.appconfig] : [], enableKnowledge ? [zoneNames.search] : [])
var zoneIds = {
  vault: resourceId('Microsoft.Network/privateDnsZones', zoneNames.vault)
  blob: resourceId('Microsoft.Network/privateDnsZones', zoneNames.blob)
  cognitive: resourceId('Microsoft.Network/privateDnsZones', zoneNames.cognitive)
  openai: resourceId('Microsoft.Network/privateDnsZones', zoneNames.openai)
  aiservices: resourceId('Microsoft.Network/privateDnsZones', zoneNames.aiservices)
  appconfig: resourceId('Microsoft.Network/privateDnsZones', zoneNames.appconfig)
  search: resourceId('Microsoft.Network/privateDnsZones', zoneNames.search)
}

resource zones 'Microsoft.Network/privateDnsZones@2024-06-01' = [for z in zoneList: {
  name: z
  location: 'global'
  tags: tags
}]

resource zoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (z, i) in zoneList: {
  parent: zones[i]
  name: 'link-${base}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}]

// ---------- Monitoring (Entra-only ingestion, capped) ----------
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${base}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: isProd ? 90 : 30
    features: { disableLocalAuth: true }
    workspaceCapping: { dailyQuotaGb: json(logDailyCapGb) }
  }
}

resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${base}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
    DisableLocalAuth: true
  }
}

// ---------- Foundry: the model, key sign-in off, only the gateway's identity is granted (grants.bicep) ----------
resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: 'aif-${base}-${uniq}'
  location: location
  tags: tags
  kind: 'AIServices'
  sku: { name: 'S0' }
  properties: {
    customSubDomainName: 'aif-${base}-${uniq}'
    disableLocalAuth: true
    publicNetworkAccess: 'Disabled'
    networkAcls: { defaultAction: 'Deny', ipRules: [], virtualNetworkRules: [] }
  }
}

// Omar M19-2: deployment API 2025-10-01-preview, exactly as the platform's working eval harness
// (infra/m13-harness/harness.bicep): on 2025-06-01 the RP ignored modelProviderData in VQ (InvalidModelProviderData).
// Proven by probe t1-claude-probe, 17 Nov 2026, with the account left on 2025-06-01 (as here).
resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-10-01-preview' = {
  parent: foundry
  name: model.name
  sku: { name: model.sku, capacity: checkedModelCapacity }
  properties: {
    model: { format: 'Anthropic', name: model.model, version: model.version }
    #disable-next-line BCP037
    modelProviderData: {
      organizationName: claudeProviderData.organizationName
      countryCode: claudeProviderData.countryCode
      industry: claudeProviderData.industry
    }
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}

// ---------- Key Vault and the approval key (sign/verify, not exportable) ----------
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-${take(compact, 21)}'
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enablePurgeProtection: true
    softDeleteRetentionInDays: 90
    publicNetworkAccess: 'Disabled'
    networkAcls: { defaultAction: 'Deny', bypass: 'None' }
  }
}

resource approvalKey 'Microsoft.KeyVault/vaults/keys@2023-07-01' = {
  parent: kv
  name: 'approval'
  properties: {
    kty: 'EC'
    curveName: 'P-256'
    keyOps: ['sign', 'verify']
    attributes: { enabled: true, exportable: false }
  }
}

// ---------- App Configuration: the kill-switch flag (read-only for gateway and executor; grants.bicep) ----------
resource appConfig 'Microsoft.AppConfiguration/configurationStores@2024-05-01' = {
  name: 'ac-${take(compact, 40)}'
  location: location
  tags: tags
  sku: { name: isPrivateTier ? 'standard' : 'free' }
  properties: {
    disableLocalAuth: true
    publicNetworkAccess: isPrivateTier ? 'Disabled' : 'Enabled'
    enablePurgeProtection: isPrivateTier
  }
}

// ---------- Storage: the gateway's spend counters (skills ship inside the image, Omar B5) ----------
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'st${take(compact, 22)}'
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: isProd ? 'Standard_ZRS' : 'Standard_LRS' }
  properties: {
    allowSharedKeyAccess: false
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Disabled'
    defaultToOAuthAuthentication: true
    networkAcls: { defaultAction: 'Deny', bypass: 'None' }
  }
}

// Omar B8: deleting a spend counter must never reset the cap. Blob soft delete, container soft delete and versioning
// keep every earlier counter, and the gateway refuses a missing counter that has history (spend-store.ts).
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    isVersioningEnabled: true
    deleteRetentionPolicy: { enabled: true, days: 30 }
    containerDeleteRetentionPolicy: { enabled: true, days: 30 }
  }
}

// No skills container (Omar B5): the image is the only source of skills; the agent checks their hash at start.
// The solution gateway's shared spend counters (caps hold across replicas and restarts).
resource spendContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'spend'
  properties: { publicAccess: 'None' }
}

// ---------- T8-K: Azure AI Search, key sign-in off ----------
resource search 'Microsoft.Search/searchServices@2024-06-01-preview' = if (enableKnowledge) {
  name: 'srch-${base}-${uniq}'
  location: location
  tags: tags
  sku: { name: isPrivateTier ? 'basic' : 'free' }
  properties: {
    replicaCount: 1
    partitionCount: 1
    disableLocalAuth: true
    publicNetworkAccess: isPrivateTier ? 'disabled' : 'enabled'
  }
}

// ---------- Private endpoints: each names its zone(s) by KEY ----------
var peDefs = concat(
  [
    { name: 'pe-${base}-kv', target: kv.id, group: 'vault', zones: ['vault'] }
    { name: 'pe-${base}-blob', target: storage.id, group: 'blob', zones: ['blob'] }
    { name: 'pe-${base}-aif', target: foundry.id, group: 'account', zones: ['cognitive', 'openai', 'aiservices'] }
  ],
  isPrivateTier ? [{ name: 'pe-${base}-ac', target: appConfig.id, group: 'configurationStores', zones: ['appconfig'] }] : [],
  enableKnowledge && isPrivateTier ? [{ name: 'pe-${base}-srch', target: resourceId('Microsoft.Search/searchServices', 'srch-${base}-${uniq}'), group: 'searchService', zones: ['search'] }] : []
)

resource pes 'Microsoft.Network/privateEndpoints@2024-05-01' = [for p in peDefs: {
  name: p.name
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: p.name
        properties: { privateLinkServiceId: p.target, groupIds: [p.group] }
      }
    ]
  }
  dependsOn: [search]
}]

resource peZoneGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = [for (p, i) in peDefs: {
  parent: pes[i]
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [for z in p.zones: { name: z, properties: { privateDnsZoneId: zoneIds[z] } }]
  }
  dependsOn: [zones, zoneLinks]
}]

// ---------- Container Apps ----------
resource cae 'Microsoft.App/managedEnvironments@2025-07-01' = {
  name: 'cae-${base}'
  location: location
  tags: tags
  properties: {
    zoneRedundant: isProd
    vnetConfiguration: { infrastructureSubnetId: appsSubnetId, internal: false }
    workloadProfiles: [{ name: 'Consumption', workloadProfileType: 'Consumption' }]
    appLogsConfiguration: { destination: 'azure-monitor' }
  }
}

resource caeDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: cae
  name: 'to-${law.name}'
  properties: {
    workspaceId: law.id
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
  }
}

// Omar A2, B8: audit logs of the run switch store and the key vault go to the solution's Log Analytics workspace, so
// who flipped `agent:enabled`, and every use of the approval signing key, can be read back.
resource appConfigDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: appConfig
  name: 'audit-to-${law.name}'
  properties: {
    workspaceId: law.id
    logs: [{ category: 'Audit', enabled: true }]
  }
}

resource kvDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: kv
  name: 'audit-to-${law.name}'
  properties: {
    workspaceId: law.id
    logs: [{ category: 'AuditEvent', enabled: true }]
  }
}

var registries = [{ server: registryServer, identity: pullId.id }]
var pullOnly = { identity: pullId.id, lifecycle: 'None' }
var gatewayFqdn = 'ca-${base}-gateway.internal.${cae.properties.defaultDomain}'
var approvalFqdn = 'ca-${base}-approval.internal.${cae.properties.defaultDomain}'
var executorFqdn = 'ca-${base}-executor.internal.${cae.properties.defaultDomain}'
// URLs are built here, one per line (the platform's Bicep scanners strip "//" comments line by line).
var gatewayUrl = 'https://${gatewayFqdn}'
var approvalUrl = 'https://${approvalFqdn}'
var executorUrl = 'https://${executorFqdn}'
var searchEndpoint = 'https://srch-${base}-${uniq}.search.windows.net'
var spendStoreUrl = 'https://${storage.name}.blob.${environment().suffixes.storage}/spend'
var foundryUrl = 'https://${foundry.properties.customSubDomainName}.services.ai.azure.com/anthropic'
var commonEnv = [
  { name: 'TENANT_ID', value: tenant().tenantId }
  { name: 'SERVICE_AUDIENCE', value: serviceAudience }
  { name: 'AGENT_AUDIENCE', value: agentAudience }
  { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appi.properties.ConnectionString }
  { name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING', value: 'Authorization=AAD' }
]
// Internal apps: reachable from inside the environment only; every route also checks the caller's token.
var internalIngress = { external: false, targetPort: 8080, transport: 'http', allowInsecure: false }

resource agentApp 'Microsoft.App/containerApps@2025-07-01' = {
  name: 'ca-${base}-agent'
  location: location
  tags: tags
  identity: { type: 'UserAssigned', userAssignedIdentities: { '${agentId.id}': {}, '${toolId.id}': {}, '${pullId.id}': {} } }
  properties: {
    environmentId: cae.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true, targetPort: 8080, transport: 'http', allowInsecure: false }
      registries: registries
      identitySettings: [{ identity: agentId.id, lifecycle: 'Main' }, { identity: toolId.id, lifecycle: 'Main' }, pullOnly]
      secrets: []
    }
    template: {
      containers: [
        {
          name: 'agent'
          image: checkedAgentImage
          resources: { cpu: json('1.0'), memory: '2Gi' }
          env: concat(commonEnv, [
            { name: 'ROLE', value: 'agent' }
            { name: 'AZURE_CLIENT_ID', value: agentId.properties.clientId }
            { name: 'TOOL_CLIENT_ID', value: toolId.properties.clientId }
            { name: 'SKILL', value: skill }
            { name: 'SKILLS_HASH', value: checkedSkillsHash }
            { name: 'CHAT_USER_OIDS', value: checkedChatUsers }
            { name: 'DAILY_TURNS_PER_PERSON', value: string(dailyTurnsPerPerson) }
            { name: 'DAILY_USD_PER_PERSON', value: checkedDailyUsd }
            { name: 'GATEWAY_URL', value: gatewayUrl }
            { name: 'GATEWAY_AUDIENCE', value: gatewayAudience }
            { name: 'APPROVAL_URL', value: approvalUrl }
            { name: 'MAINTENANCE_API_URL', value: maintenanceApiUrl }
            { name: 'MAINTENANCE_API_SCOPE', value: maintenanceApiScope }
            { name: 'SEARCH_ENDPOINT', value: enableKnowledge ? searchEndpoint : '' }
            { name: 'SEARCH_INDEX', value: searchIndex }
            { name: 'BOT_APP_ID', value: enableTeams ? agentId.properties.clientId : '' }
          ])
        }
      ]
      scale: { minReplicas: isPrivateTier ? 1 : 0, maxReplicas: 3 }
    }
  }
}

resource gatewayApp 'Microsoft.App/containerApps@2025-07-01' = {
  name: 'ca-${base}-gateway'
  location: location
  tags: tags
  identity: { type: 'UserAssigned', userAssignedIdentities: { '${gatewayId.id}': {}, '${pullId.id}': {} } }
  properties: {
    environmentId: cae.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: internalIngress
      registries: registries
      identitySettings: [{ identity: gatewayId.id, lifecycle: 'Main' }, pullOnly]
      secrets: []
    }
    template: {
      containers: [
        {
          name: 'gateway'
          image: checkedGatewayImage
          // The platform gateway image in SOLUTION MODE (packages/gateway solution-main.ts) [verify the path in the image].
          command: ['node', 'packages/gateway/dist/solution-main.js']
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: concat(commonEnv, [
            { name: 'AZURE_CLIENT_ID', value: gatewayId.properties.clientId }
            { name: 'FOUNDRY_BASE_URL', value: foundryUrl }
            { name: 'GATEWAY_DEPLOYMENTS', value: modelDeployment.name }
            { name: 'GATEWAY_CALLER_AUDIENCE', value: gatewayAudience }
            { name: 'GATEWAY_CALLER_OBJECT_ID', value: agentId.properties.principalId }
            { name: 'APP_CONFIG_ENDPOINT', value: appConfig.properties.endpoint }
            { name: 'SOLUTION', value: solution }
            { name: 'SOLUTION_CONVERSATION_CAP_USD', value: conversationCapUsd }
            { name: 'SOLUTION_MONTHLY_CAP_USD', value: monthlyCapUsd }
            { name: 'SPEND_STORE_URL', value: spendStoreUrl }
          ])
        }
      ]
      scale: { minReplicas: isPrivateTier ? 1 : 0, maxReplicas: 2 }
    }
  }
}

resource approvalApp 'Microsoft.App/containerApps@2025-07-01' = {
  name: 'ca-${base}-approval'
  location: location
  tags: tags
  identity: { type: 'UserAssigned', userAssignedIdentities: { '${approvalId.id}': {}, '${pullId.id}': {} } }
  properties: {
    environmentId: cae.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: internalIngress
      registries: registries
      identitySettings: [{ identity: approvalId.id, lifecycle: 'Main' }, pullOnly]
      secrets: []
    }
    template: {
      containers: [
        {
          name: 'approval'
          image: checkedAgentImage
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: concat(commonEnv, [
            { name: 'ROLE', value: 'approval' }
            { name: 'AZURE_CLIENT_ID', value: approvalId.properties.clientId }
            { name: 'APPROVAL_KEY_ID', value: approvalKey.properties.keyUriWithVersion }
            { name: 'APPROVAL_LIFETIME_HOURS', value: string(approvalLifetimeHours) }
            { name: 'ENVIRONMENT', value: environmentName }
            { name: 'APPROVALS_AUDIENCE', value: checkedApprovalsAudience }
            { name: 'APPROVER_OIDS', value: checkedApproverList }
            { name: 'CHAT_USER_OIDS', value: checkedChatUsers }
            { name: 'AGENT_OID', value: agentId.properties.principalId }
            { name: 'APPROVAL_DOOR_OID', value: approvalDoorId.properties.principalId }
            { name: 'EXECUTOR_OID', value: executorId.properties.principalId }
            { name: 'EXECUTOR_URL', value: executorUrl }
          ])
        }
      ]
      // One replica: the single-use numbers live in this app (a shared store comes with production scale-out).
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
}

// The approval door (Omar A1(b)): its own identity, no model, no tools, no write role. Public ingress (the approval
// card's page posts here with the approver's delegated approvals token).
resource approvalDoorApp 'Microsoft.App/containerApps@2025-07-01' = {
  name: 'ca-${base}-approvals'
  location: location
  tags: tags
  identity: { type: 'UserAssigned', userAssignedIdentities: { '${approvalDoorId.id}': {}, '${pullId.id}': {} } }
  properties: {
    environmentId: cae.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true, targetPort: 8080, transport: 'http', allowInsecure: false }
      registries: registries
      identitySettings: [{ identity: approvalDoorId.id, lifecycle: 'Main' }, pullOnly]
      secrets: []
    }
    template: {
      containers: [
        {
          name: 'approvals'
          image: checkedAgentImage
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: concat(commonEnv, [
            { name: 'ROLE', value: 'approval-door' }
            { name: 'AZURE_CLIENT_ID', value: approvalDoorId.properties.clientId }
            { name: 'APPROVALS_AUDIENCE', value: checkedApprovalsAudience }
            { name: 'APPROVAL_URL', value: approvalUrl }
          ])
        }
      ]
      scale: { minReplicas: isPrivateTier ? 1 : 0, maxReplicas: 2 }
    }
  }
}

resource executorApp 'Microsoft.App/containerApps@2025-07-01' = {
  name: 'ca-${base}-executor'
  location: location
  tags: tags
  identity: { type: 'UserAssigned', userAssignedIdentities: { '${executorId.id}': {}, '${pullId.id}': {} } }
  properties: {
    environmentId: cae.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: internalIngress
      registries: registries
      identitySettings: [{ identity: executorId.id, lifecycle: 'Main' }, pullOnly]
      secrets: []
    }
    template: {
      containers: [
        {
          name: 'executor'
          image: checkedAgentImage
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: concat(commonEnv, [
            { name: 'ROLE', value: 'executor' }
            { name: 'AZURE_CLIENT_ID', value: executorId.properties.clientId }
            { name: 'APPROVAL_URL', value: approvalUrl }
            { name: 'APPROVAL_KEY_ID', value: approvalKey.properties.keyUriWithVersion }
            { name: 'APPROVAL_OID', value: approvalId.properties.principalId }
            { name: 'APP_CONFIG_ENDPOINT', value: appConfig.properties.endpoint }
            { name: 'MAINTENANCE_API_URL', value: maintenanceApiUrl }
            { name: 'MAINTENANCE_API_SCOPE', value: maintenanceApiScope }
          ])
        }
      ]
      scale: { minReplicas: 0, maxReplicas: 1 }
    }
  }
}

// ---------- T8-K: the ingestion job (scheduled; refreshes every access list) ----------
resource ingestionJob 'Microsoft.App/jobs@2025-07-01' = if (enableKnowledge) {
  name: 'caj-${base}-ingest'
  location: location
  tags: tags
  identity: { type: 'UserAssigned', userAssignedIdentities: { '${ingestionId!.id}': {}, '${pullId.id}': {} } }
  properties: {
    environmentId: cae.id
    workloadProfileName: 'Consumption'
    configuration: {
      triggerType: 'Schedule'
      scheduleTriggerConfig: { cronExpression: ingestionSchedule, parallelism: 1, replicaCompletionCount: 1 }
      replicaTimeout: 3600
      replicaRetryLimit: 1
      registries: registries
      identitySettings: [{ identity: ingestionId!.id, lifecycle: 'Main' }, pullOnly]
      secrets: []
    }
    template: {
      containers: [
        {
          name: 'ingestion'
          image: checkedAgentImage
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: concat(commonEnv, [
            { name: 'ROLE', value: 'ingestion' }
            { name: 'AZURE_CLIENT_ID', value: ingestionId!.properties.clientId }
            { name: 'SEARCH_ENDPOINT', value: searchEndpoint }
            { name: 'SEARCH_INDEX', value: searchIndex }
            { name: 'INGESTION_SOURCE_DIR', value: '/app/synthetic-documents' }
            { name: 'SHAREPOINT_SITE_ID', value: sharePointSiteId }
            { name: 'SHAREPOINT_DRIVE_ID', value: sharePointDriveId }
            { name: 'SHAREPOINT_ROOT_ITEM_ID', value: sharePointRootItemId }
            { name: 'EXPAND_NESTED_GROUPS', value: string(expandNestedGroups) }
          ])
        }
      ]
    }
  }
}

var botEndpoint = 'https://${agentApp.properties.configuration.ingress.fqdn}/api/messages'

// ---------- Teams front door: Azure Bot, single tenant, the agent's identity (no secret) ----------
resource bot 'Microsoft.BotService/botServices@2022-09-15' = if (enableTeams) {
  name: 'bot-${base}-${uniq}'
  location: 'global'
  tags: tags
  kind: 'azurebot'
  sku: { name: isPrivateTier ? 'S1' : 'F0' }
  properties: {
    displayName: '${solution} ${environmentName}'
    endpoint: botEndpoint
    msaAppType: 'UserAssignedMSI'
    msaAppId: agentId.properties.clientId
    msaAppTenantId: tenant().tenantId
    msaAppMSIResourceId: agentId.id
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
  }
}

output agentFqdn string = agentApp.properties.configuration.ingress.fqdn
output gatewayFqdn string = gatewayFqdn
output foundryName string = foundry.name
output modelDeploymentName string = modelDeployment.name
output keyVaultName string = kv.name
output approvalKeyId string = approvalKey.properties.keyUriWithVersion
output appConfigName string = appConfig.name
output appConfigEndpoint string = appConfig.properties.endpoint
output storageName string = storage.name
output searchName string = enableKnowledge ? 'srch-${base}-${uniq}' : ''
output logAnalyticsName string = law.name
output botName string = enableTeams ? 'bot-${base}-${uniq}' : ''
