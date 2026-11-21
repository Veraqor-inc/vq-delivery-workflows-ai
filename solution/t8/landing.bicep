// Template T8, landing step 1 (run ONCE per solution per environment by the environment OWNER, never by the
// pipeline; same pattern as T1, Omar S12-5b, S12-5d and P2A-4). Deploy it into the separate IDENTITY resource group.
//
// It creates the identities of one T8 environment, ONE PER ROLE, so no role can borrow another's rights (M13 3.3,
// 3.3.2):
//   - AGENT: the front doors and the agent turn. It gets NO write role and NO Foundry role (grants.bicep): it reaches
//     the model only through the gateway, and writes only by drafting;
//   - GATEWAY: the only identity with the Foundry data role, on this environment's Foundry account only;
//   - APPROVAL: sign right on the one approval key only;
//   - APPROVAL DOOR: the only identity that may post an approver's decision to the approval service (Omar A1(b));
//     no data role at all. Never the agent's identity, so the agent can never relay a decision;
//   - EXECUTOR: the only identity that holds write roles on back ends (granted where those back ends live);
//   - TOOL: the tools' read identity (maintenance API read, Search Index Data Reader for T8-K);
//   - INGESTION: T8-K's scheduled ingestion job (Search Index Data Contributor; reads the source);
//   - PULL: AcrPull on the image registry only, attached with lifecycle None (never usable at run time);
//   - DEPLOY: the platform deploy workflow's identity, through ONE federated credential whose subject is checked
//     character for character, in the T1 solution-organisation form (repo:<owner>@<ID>/<repo>@<ID>:environment:<env>;
//     no job_workflow_ref and no platform SHA here: the release gate binds the deploy workflow, Omar ruling 3).
// The deploy identity gets Managed Identity Operator on the eight runtime identities (attach only; no credential
// write, no grant).

targetScope = 'resourceGroup'

@allowed(['dev', 'qa', 'uat', 'prod'])
param environmentName string

@minLength(3)
@maxLength(12)
param solution string

@description('Azure region. West US 3 by default (Omar M19-1).')
param location string = 'westus3'

@description('The exact OIDC subject: repo:<owner>@<owner ID>/<repo>@<repo ID>:environment:<env> (no job_workflow_ref; Omar ruling 3). It must equal the subject composed from the parts below.')
param deploySubject string

@minLength(1)
@maxLength(39)
@description('The solution repository\'s owner (GitHub organisation) name.')
param repositoryOwner string

@minLength(1)
@maxLength(20)
@description('The owner\'s numeric GitHub ID (immutable).')
param repositoryOwnerId string

@minLength(1)
@maxLength(100)
@description('The solution repository\'s name.')
param repositoryName string

@minLength(1)
@maxLength(20)
@description('The repository\'s numeric GitHub ID (immutable).')
param repositoryId string

// Omar B10: GitHub's token issuer is fixed (a var, not a parameter), so no landing can trust another issuer.
var deployIssuer = 'https://token.actions.githubusercontent.com'

param extraTags object = {}

var base = '${solution}-${environmentName}'
var tags = union(extraTags, {
  solution: solution
  environment: environmentName
  template: 't8'
  'managed-by': 'environment-owner'
})

// ---------- The deploy subject, composed and checked (P2A-4; mirrors checkDeploySubject in the engine) ----------
var digits = '0123456789'
var ownerChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-'
var repoChars = '${ownerChars}._'

@description('True when value is not empty and every character of it is in allowed.')
func onlyChars(value string, allowed string) bool => !empty(value) && empty(filter(map(range(0, length(value)), i => substring(value, i, 1)), c => !contains(allowed, c)))

// Omar ruling 3 (security-review-m13-t8-landing-rulings.md): the T1 solution-organisation form. The organisation's
// subject template is `repo, context`, so the subject never carries job_workflow_ref; the workflow binding is the
// release gate's (RELEASE_GATE_DEPLOY_WORKFLOWS_AI), set later per reviewed SHA.
var expectedSubject = 'repo:${repositoryOwner}@${repositoryOwnerId}/${repositoryName}@${repositoryId}:environment:${environmentName}'

var subjectChecks = [
  { ok: onlyChars(repositoryOwner, ownerChars), problem: 'repositoryOwner is not a GitHub owner name' }
  { ok: onlyChars(repositoryOwnerId, digits), problem: 'repositoryOwnerId is not a numeric ID' }
  { ok: onlyChars(repositoryName, repoChars), problem: 'repositoryName is not a GitHub repository name' }
  { ok: onlyChars(repositoryId, digits), problem: 'repositoryId is not a numeric ID' }
  { ok: deploySubject == expectedSubject, problem: 'deploySubject is not exactly the expected subject (immutable IDs, environment)' }
]
var subjectProblems = map(filter(subjectChecks, c => !c.ok), c => c.problem)
// ARM evaluates only the branch taken: with any problem, json() of a non-JSON message fails the deployment
// before the credential exists, and the error carries the message.
var checkedSubject = empty(subjectProblems) ? deploySubject : json('deploy subject refused: ${join(subjectProblems, '; ')}')

resource agentIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${base}-agent'
  location: location
  tags: tags
}

resource gatewayIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${base}-gateway'
  location: location
  tags: tags
}

resource approvalIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${base}-approval'
  location: location
  tags: tags
}

resource approvalDoorIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${base}-approvaldoor'
  location: location
  tags: tags
}

resource executorIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${base}-executor'
  location: location
  tags: tags
}

resource toolIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${base}-tool'
  location: location
  tags: tags
}

resource ingestionIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${base}-ingestion'
  location: location
  tags: tags
}

resource pullIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${base}-pull'
  location: location
  tags: tags
}

resource deployIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${base}-deploy'
  location: location
  tags: tags
}

resource deployCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: deployIdentity
  name: 'github-deploy-${environmentName}'
  properties: {
    issuer: deployIssuer
    subject: checkedSubject
    audiences: ['api://AzureADTokenExchange']
  }
}

// Managed Identity Operator: read and assign only (no federatedIdentityCredentials/write).
var managedIdentityOperator = 'f1a07417-d97a-45cb-824c-7a7467783830'

resource deployMayAssignAgent 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: agentIdentity
  name: guid(agentIdentity.id, deployIdentity.id, managedIdentityOperator)
  properties: {
    principalId: deployIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', managedIdentityOperator)
  }
}

resource deployMayAssignGateway 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: gatewayIdentity
  name: guid(gatewayIdentity.id, deployIdentity.id, managedIdentityOperator)
  properties: {
    principalId: deployIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', managedIdentityOperator)
  }
}

resource deployMayAssignApproval 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: approvalIdentity
  name: guid(approvalIdentity.id, deployIdentity.id, managedIdentityOperator)
  properties: {
    principalId: deployIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', managedIdentityOperator)
  }
}

resource deployMayAssignApprovalDoor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: approvalDoorIdentity
  name: guid(approvalDoorIdentity.id, deployIdentity.id, managedIdentityOperator)
  properties: {
    principalId: deployIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', managedIdentityOperator)
  }
}

resource deployMayAssignExecutor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: executorIdentity
  name: guid(executorIdentity.id, deployIdentity.id, managedIdentityOperator)
  properties: {
    principalId: deployIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', managedIdentityOperator)
  }
}

resource deployMayAssignTool 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: toolIdentity
  name: guid(toolIdentity.id, deployIdentity.id, managedIdentityOperator)
  properties: {
    principalId: deployIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', managedIdentityOperator)
  }
}

resource deployMayAssignIngestion 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: ingestionIdentity
  name: guid(ingestionIdentity.id, deployIdentity.id, managedIdentityOperator)
  properties: {
    principalId: deployIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', managedIdentityOperator)
  }
}

resource deployMayAssignPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: pullIdentity
  name: guid(pullIdentity.id, deployIdentity.id, managedIdentityOperator)
  properties: {
    principalId: deployIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', managedIdentityOperator)
  }
}

output agentIdentityName string = agentIdentity.name
output agentIdentityPrincipalId string = agentIdentity.properties.principalId
output agentIdentityClientId string = agentIdentity.properties.clientId
output gatewayIdentityName string = gatewayIdentity.name
output gatewayIdentityPrincipalId string = gatewayIdentity.properties.principalId
output gatewayIdentityClientId string = gatewayIdentity.properties.clientId
output approvalIdentityName string = approvalIdentity.name
output approvalIdentityPrincipalId string = approvalIdentity.properties.principalId
output approvalIdentityClientId string = approvalIdentity.properties.clientId
output approvalDoorIdentityName string = approvalDoorIdentity.name
output approvalDoorIdentityPrincipalId string = approvalDoorIdentity.properties.principalId
output approvalDoorIdentityClientId string = approvalDoorIdentity.properties.clientId
output executorIdentityName string = executorIdentity.name
output executorIdentityPrincipalId string = executorIdentity.properties.principalId
output executorIdentityClientId string = executorIdentity.properties.clientId
output toolIdentityName string = toolIdentity.name
output toolIdentityPrincipalId string = toolIdentity.properties.principalId
output toolIdentityClientId string = toolIdentity.properties.clientId
output ingestionIdentityName string = ingestionIdentity.name
output ingestionIdentityPrincipalId string = ingestionIdentity.properties.principalId
output ingestionIdentityClientId string = ingestionIdentity.properties.clientId
output pullIdentityName string = pullIdentity.name
output pullIdentityPrincipalId string = pullIdentity.properties.principalId
output pullIdentityClientId string = pullIdentity.properties.clientId
output deployIdentityClientId string = deployIdentity.properties.clientId
output deployIdentityPrincipalId string = deployIdentity.properties.principalId
// For the read-back: this must be in the gate's RELEASE_GATE_DEPLOY_WORKFLOWS_AI.
output deploySubject string = deployCredential.properties.subject
