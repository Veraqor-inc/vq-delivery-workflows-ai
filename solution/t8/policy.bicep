// Template T8, landing step 4 (Omar B2 part 2): Azure Policy DENY guards on ONE solution resource group, run by the
// environment OWNER (Policy writes are Microsoft.Authorization/*, which the deploy role never has).
//
// Whatever the deploy identity's role allows, Azure refuses any create or change in the solution group that:
//   - turns key sign-in back on: Foundry (Cognitive Services), AI Search and App Configuration need
//     disableLocalAuth = true; Storage needs allowSharedKeyAccess = false;
//   - gives a Key Vault access policies instead of RBAC (enableRbacAuthorization must be true);
//   - runs a container image from any registry other than this solution's own (Container Apps and Container Apps Jobs,
//     containers and init containers);
//   - switches off blob versioning, blob soft delete or container soft delete on a storage account (Omar's Low in
//     security-review-m13-t8-code.md 1.1: that would let a deleted spend counter read as 0 and reset the cap). The
//     account itself is protected from deletion by the CanNotDelete lock in grants.bicep.
//
// The definitions are created once per subscription (same names every time, so a second solution reuses them) and
// assigned on the solution resource group only. [verify] The policy aliases are checked by Elena before the first
// assignment (`az provider show --namespace <ns> --expand "resourceTypes/aliases"`), and after it she reads back that
// a what-if of main.bicep shows no policy refusal.

targetScope = 'subscription'

@description('The solution resource group the guards are assigned on.')
param solutionResourceGroup string

@description('Login server of this solution\'s registry (<name>.azurecr.io): the only registry images may come from.')
param registryServer string

@allowed(['dev', 'qa', 'uat', 'prod'])
param environmentName string

@minLength(3)
@maxLength(12)
param solution string

var checkedRegistry = endsWith(registryServer, '.azurecr.io') && !contains(registryServer, '/') ? registryServer : json('registryServer must be <name>.azurecr.io: ${registryServer}')

// Each "must be" guard: deny the type when the field is not exactly the required value (a missing field is denied too).
var mustBe = [
  { name: 't8-deny-foundry-local-auth', display: 'T8: Foundry (Cognitive Services) key sign-in must stay off', type: 'Microsoft.CognitiveServices/accounts', field: 'Microsoft.CognitiveServices/accounts/disableLocalAuth', value: true }
  { name: 't8-deny-search-local-auth', display: 'T8: AI Search key sign-in must stay off', type: 'Microsoft.Search/searchServices', field: 'Microsoft.Search/searchServices/disableLocalAuth', value: true }
  { name: 't8-deny-appconfig-local-auth', display: 'T8: App Configuration key sign-in must stay off', type: 'Microsoft.AppConfiguration/configurationStores', field: 'Microsoft.AppConfiguration/configurationStores/disableLocalAuth', value: true }
  { name: 't8-deny-storage-shared-key', display: 'T8: Storage shared keys must stay off', type: 'Microsoft.Storage/storageAccounts', field: 'Microsoft.Storage/storageAccounts/allowSharedKeyAccess', value: false }
  { name: 't8-deny-keyvault-access-policies', display: 'T8: Key Vault must use RBAC', type: 'Microsoft.KeyVault/vaults', field: 'Microsoft.KeyVault/vaults/enableRbacAuthorization', value: true }
  { name: 't8-deny-blob-versioning-off', display: 'T8: blob versioning must stay on', type: 'Microsoft.Storage/storageAccounts/blobServices', field: 'Microsoft.Storage/storageAccounts/blobServices/isVersioningEnabled', value: true }
  { name: 't8-deny-blob-soft-delete-off', display: 'T8: blob soft delete must stay on', type: 'Microsoft.Storage/storageAccounts/blobServices', field: 'Microsoft.Storage/storageAccounts/blobServices/deleteRetentionPolicy.enabled', value: true }
  { name: 't8-deny-container-soft-delete-off', display: 'T8: container soft delete must stay on', type: 'Microsoft.Storage/storageAccounts/blobServices', field: 'Microsoft.Storage/storageAccounts/blobServices/containerDeleteRetentionPolicy.enabled', value: true }
]

resource mustBeDefs 'Microsoft.Authorization/policyDefinitions@2023-04-01' = [for d in mustBe: {
  name: d.name
  properties: {
    displayName: d.display
    description: 'Omar B2: deny guard for T8 solution resource groups.'
    policyType: 'Custom'
    // 'All': blobServices carries no tags or location, so 'Indexed' would never evaluate it.
    mode: 'All'
    metadata: { category: 'Veraqor T8' }
    policyRule: {
      if: {
        allOf: [
          { field: 'type', equals: d.type }
          { field: d.field, notEquals: d.value }
        ]
      }
      then: { effect: 'deny' }
    }
  }
}]

// Images only from the allowed registry: deny when ANY container or init container image does not start with it.
// The four image checks are written out, not built with a `for` loop: a loop compiles to an ARM copy loop, which
// evaluates the policy's own '[concat(parameters(...))]' at deploy time and fails ("parameter 'allowedRegistry'
// not found"). As plain literals Bicep escapes the string ('[[') and Azure Policy evaluates it, as intended.
// `count.field` names the ARRAY alias (`...containers[*]`); only `where` looks at `.image`. Azure Policy refuses a
// `count.field` that ends in a property ("InvalidCountExpression", dev deploy 2026-11-21).

resource registryDef 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: 't8-deny-foreign-registry'
  properties: {
    displayName: 'T8: container images only from the solution\'s own registry'
    description: 'Omar B2: deny guard for T8 solution resource groups.'
    policyType: 'Custom'
    mode: 'Indexed'
    metadata: { category: 'Veraqor T8' }
    parameters: {
      allowedRegistry: { type: 'String', metadata: { displayName: 'Allowed registry login server' } }
    }
    policyRule: {
      if: {
        allOf: [
          { field: 'type', in: ['Microsoft.App/containerApps', 'Microsoft.App/jobs'] }
          {
            anyOf: [
              {
                count: { field: 'Microsoft.App/containerApps/template.containers[*]', where: { field: 'Microsoft.App/containerApps/template.containers[*].image', notLike: '[concat(parameters(\'allowedRegistry\'), \'/*\')]' } }
                greater: 0
              }
              {
                count: { field: 'Microsoft.App/containerApps/template.initContainers[*]', where: { field: 'Microsoft.App/containerApps/template.initContainers[*].image', notLike: '[concat(parameters(\'allowedRegistry\'), \'/*\')]' } }
                greater: 0
              }
              {
                count: { field: 'Microsoft.App/jobs/template.containers[*]', where: { field: 'Microsoft.App/jobs/template.containers[*].image', notLike: '[concat(parameters(\'allowedRegistry\'), \'/*\')]' } }
                greater: 0
              }
              {
                count: { field: 'Microsoft.App/jobs/template.initContainers[*]', where: { field: 'Microsoft.App/jobs/template.initContainers[*].image', notLike: '[concat(parameters(\'allowedRegistry\'), \'/*\')]' } }
                greater: 0
              }
            ]
          }
        ]
      }
      then: { effect: 'deny' }
    }
  }
}

module assign 'policy-rg.bicep' = {
  name: 't8-policy-${solution}-${environmentName}'
  scope: resourceGroup(solutionResourceGroup)
  params: {
    solution: solution
    environmentName: environmentName
    mustBeDefinitionIds: [for (d, i) in mustBe: mustBeDefs[i].id]
    registryDefinitionId: registryDef.id
    registryServer: checkedRegistry
  }
}

output assignmentIds array = assign.outputs.assignmentIds
