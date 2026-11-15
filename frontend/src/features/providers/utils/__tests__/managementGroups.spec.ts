import { describe, expect, it } from 'vitest'
import { assignManagementProviders, managementSections, UNGROUPED } from '../managementGroups'

const groups = [
  { id: 'free', name: 'Free', provider_ids: ['p2', 'p1'] },
  { id: 'paid', name: 'Paid', provider_ids: ['p3', 'deleted'] },
]

describe('display-only provider management groups', () => {
  it('moves providers exclusively and keeps unrelated memberships in place', () => {
    const moved = assignManagementProviders(groups, 'paid', ['p1', 'p2'])
    expect(moved[0]!.provider_ids).toEqual([])
    expect(moved[1]!.provider_ids).toEqual(['p3', 'deleted', 'p1', 'p2'])
    expect(groups[0]!.provider_ids).toEqual(['p2', 'p1'])
    expect(assignManagementProviders(moved, UNGROUPED, ['p1'])[1]!.provider_ids).toEqual(['p3', 'deleted', 'p2'])
  })

  it('uses stored display order without touching scheduler priorities', () => {
    const providers = [{ id: 'p1', provider_priority: 1 }, { id: 'p2', provider_priority: 99 }, { id: 'p3', provider_priority: 0 }, { id: 'p4', provider_priority: 2 }]
    const before = structuredClone(providers)
    const sections = managementSections(groups, providers, 'Ungrouped')
    expect(sections.map(section => section.providers.map(provider => provider.id))).toEqual([['p2', 'p1'], ['p3'], ['p4']])
    expect(providers).toEqual(before)
  })

  it('returns deleted group members to ungrouped and ignores deleted providers', () => {
    const providers = ['p1', 'p2', 'p3'].map(id => ({ id }))
    const sections = managementSections(groups.slice(1), providers, 'Ungrouped')
    expect(sections[1]!.providers.map(provider => provider.id)).toEqual(['p1', 'p2'])
    expect(sections.flatMap(section => section.providers)).toHaveLength(3)
  })
})
