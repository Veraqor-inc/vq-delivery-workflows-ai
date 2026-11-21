// Template T8, landing step 1b (Elena's first-landing read-back; Omar's registry-name ruling,
// security-review-m13-t8-code.md section 3): the SOLUTION's container registry, run ONCE per solution per environment
// by the environment OWNER into the SOLUTION resource group, after landing.bicep (it needs the pull identity).
//
//   - the registry: no admin user (no registry password), no anonymous pull, no export, untagged images kept 7 days;
//   - AcrPull for the pull identity (landing.bicep `pullIdentityPrincipalId`) on this registry only; that identity is
//     attached to every app with lifecycle None, so it pulls images and is never usable at run time;
//   - AcrPush for the engine's identity on this registry only (when given): the engine is the only pusher, by digest,
//     to `<solution>/agent` (the engine refuses any release that names another registry or repository).
// The deploy role never grants and holds no Microsoft.ContainerRegistry right, so the pipeline cannot change it.
// After this: the owner records the output `loginServer` in the engine, once:
//   npm run operator -- record-solution-registry --tenant <id> --project <id> --registry <loginServer> --solution <solution>
// and passes the same value as `registryServer` to policy.bicep and main.bicep. Elena imports the platform gateway image
// into this registry at the digest the ai deploy workflow pins (GATEWAY_IMAGE_DIGEST).

targetScope = 'resourceGroup'

@allowed(['dev', 'qa', 'uat', 'prod'])
param environmentName string

@minLength(3)
@maxLength(12)
@description('The solution short name (the same as landing.bicep and main.bicep); the image repository is <solution>/agent.')
param solution string

param location string = 'westus3'

@description('Object (principal) ID of this environment\'s pull identity (landing.bicep output pullIdentityPrincipalId).')
param pullIdentityPrincipalId string

@description('Object (principal) ID of the engine\'s managed identity that pushes release images by digest. Empty: no push grant yet.')
param enginePushPrincipalId string = ''

param extraTags object = {}

var isPrivateTier = environmentName == 'uat' || environmentName == 'prod'
var uniq = take(uniqueString(subscription().id, resourceGroup().id, solution, environmentName), 6)
var tags = union(extraTags, {
  solution: solution
  environment: environmentName
  template: 't8'
  'managed-by': 'environment-owner'
})
var roleAcrPull = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var roleAcrPush = '8311e382-0749-4cb8-b61a-304f252e45ec'

resource registry 'Microsoft.ContainerRegistry/registries@2025-04-01' = {
  // Lower-case letters and digits only, so the login server matches the engine's <name>.azurecr.io rule.
  name: 'cr${solution}${take(environmentName, 4)}${uniq}'
  location: location
  tags: tags
  sku: { name: isPrivateTier ? 'Premium' : 'Basic' }
  properties: {
    adminUserEnabled: false
    anonymousPullEnabled: false
    publicNetworkAccess: 'Enabled'
    zoneRedundancy: 'Disabled'
    policies: isPrivateTier ? {
      exportPolicy: { status: 'disabled' }
      retentionPolicy: { status: 'enabled', days: 7 }
    } : {}
  }
}

resource pullGrant 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: registry
  name: guid(registry.id, pullIdentityPrincipalId, roleAcrPull)
  properties: {
    principalId: pullIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleAcrPull)
    description: 'T8: image pull only (attached with lifecycle None on every app and job).'
  }
}

resource enginePush 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(enginePushPrincipalId)) {
  scope: registry
  name: guid(registry.id, enginePushPrincipalId, roleAcrPush)
  properties: {
    principalId: enginePushPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleAcrPush)
    description: 'T8: the engine pushes release images by digest to ${solution}/agent only.'
  }
}

output loginServer string = registry.properties.loginServer
output registryName string = registry.name
output imageRepository string = '${solution}/agent'
