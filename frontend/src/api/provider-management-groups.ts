import client from './client'

/** Display order only. Never use these groups to construct a routing policy. */
export interface ProviderManagementGroup {
  id: string
  name: string
  provider_ids: string[]
}

export interface ProviderManagementGroups {
  version: number
  groups: ProviderManagementGroup[]
}

export async function getProviderManagementGroups(): Promise<ProviderManagementGroups> {
  return (await client.get<ProviderManagementGroups>('/api/admin/provider-management-groups')).data
}

export async function saveProviderManagementGroups(document: ProviderManagementGroups): Promise<ProviderManagementGroups> {
  return (await client.put<ProviderManagementGroups>('/api/admin/provider-management-groups', document)).data
}
