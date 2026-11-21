// Template T8 (Omar B2): assigns the deny guards from policy.bicep on ONE solution resource group. Called by
// policy.bicep only; never run on its own.

targetScope = 'resourceGroup'

param solution string
param environmentName string
param mustBeDefinitionIds array
param registryDefinitionId string
param registryServer string

resource mustBeAssignments 'Microsoft.Authorization/policyAssignments@2024-04-01' = [for (id, i) in mustBeDefinitionIds: {
  name: 't8-${solution}-${environmentName}-guard-${i}'
  properties: {
    displayName: 'T8 ${solution} ${environmentName}: ${last(split(id, '/'))}'
    policyDefinitionId: id
    enforcementMode: 'Default'
  }
}]

resource registryAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 't8-${solution}-${environmentName}-registry'
  properties: {
    displayName: 'T8 ${solution} ${environmentName}: images only from ${registryServer}'
    policyDefinitionId: registryDefinitionId
    enforcementMode: 'Default'
    parameters: { allowedRegistry: { value: registryServer } }
  }
}

var guardIds = [for (id, i) in mustBeDefinitionIds: mustBeAssignments[i].id]
output assignmentIds array = concat(guardIds, [registryAssignment.id])
