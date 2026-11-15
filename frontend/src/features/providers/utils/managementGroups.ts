import type { ProviderManagementGroup } from '@/api/provider-management-groups'

export const UNGROUPED = '__ungrouped__'

/** Assignment is a move: remove the provider from every old group first. */
export function assignManagementProviders(
  groups: ProviderManagementGroup[], targetId: string, providerIds: string[],
): ProviderManagementGroup[] {
  const moving = new Set(providerIds)
  return groups.map(group => ({
    ...group,
    provider_ids: group.id === targetId
      ? [...group.provider_ids.filter(id => !moving.has(id)), ...providerIds]
      : group.provider_ids.filter(id => !moving.has(id)),
  }))
}

export interface ManagementSection<T> {
  id: string
  name: string
  providers: T[]
}

export function managementSections<T extends { id: string }>(
  groups: ProviderManagementGroup[], providers: T[], ungroupedName: string,
): ManagementSection<T>[] {
  const byId = new Map(providers.map(provider => [provider.id, provider]))
  const assigned = new Set(groups.flatMap(group => group.provider_ids))
  return [
    ...groups.map(group => ({
      id: group.id,
      name: group.name,
      providers: group.provider_ids.flatMap(id => {
        const provider = byId.get(id)
        return provider ? [provider] : []
      }),
    })),
    { id: UNGROUPED, name: ungroupedName, providers: providers.filter(provider => !assigned.has(provider.id)) },
  ]
}
