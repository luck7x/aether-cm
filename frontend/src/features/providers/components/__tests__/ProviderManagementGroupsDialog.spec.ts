import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createApp, nextTick, type App } from 'vue'
import type { ProviderWithEndpointsSummary } from '@/api/endpoints'
import ProviderManagementGroupsDialog from '../ProviderManagementGroupsDialog.vue'

const api = vi.hoisted(() => ({ getProviderManagementGroups: vi.fn(), saveProviderManagementGroups: vi.fn() }))
vi.mock('@/api/provider-management-groups', () => api)
const initial = { version: 4, groups: [
  { id: 'free', name: '免费', provider_ids: ['p1'] },
  { id: 'paid', name: '付费', provider_ids: ['p2'] },
] }
let app: App | null = null
let root: HTMLElement | null = null
const saved = vi.fn(), closed = vi.fn()
async function settle() { for (let i = 0; i < 6; i++) { await Promise.resolve(); await nextTick() } }
async function mountDialog() {
  root = document.createElement('div'); document.body.appendChild(root)
  app = createApp(ProviderManagementGroupsDialog, { modelValue: true, document: structuredClone(initial),
    providers: [ { id: 'p1', name: 'One' }, { id: 'p2', name: 'Two' } ] as ProviderWithEndpointsSummary[],
    onSaved: saved, 'onUpdate:modelValue': closed,
  })
  app.mount(root); await settle()
}
async function click(text: string) {
  const button = [...document.body.querySelectorAll<HTMLButtonElement>('button')].find(item => item.textContent?.trim() === text)!
  expect(button).toBeDefined(); button.click(); await settle()
}
beforeEach(() => {
  vi.clearAllMocks()
  api.saveProviderManagementGroups.mockImplementation(async document => ({ ...document, version: 5 }))
})
afterEach(() => { app?.unmount(); root?.remove(); document.body.innerHTML = ''; app = null; root = null })

describe('Provider management groups editor', () => {
  it('moves membership exclusively and saves only directory data', async () => {
    await mountDialog()
    const label = [...document.body.querySelectorAll('label')].find(item => item.textContent?.includes('Two'))!
    const input = label.querySelector<HTMLInputElement>('input[type="checkbox"]')!
    input.checked = true; input.dispatchEvent(new Event('change', { bubbles: true })); await settle()
    await click('保存分组')
    expect(api.saveProviderManagementGroups).toHaveBeenCalledWith({ version: 4, groups: [
      { id: 'free', name: '免费', provider_ids: ['p1', 'p2'] },
      { id: 'paid', name: '付费', provider_ids: [] },
    ] })
    expect(saved).toHaveBeenCalledOnce()
    expect(closed).toHaveBeenCalledWith(false)
    expect(initial.groups[1]!.provider_ids).toEqual(['p2'])
  })

  it('keeps failed saves open and requires explicit reload before replacing edits', async () => {
    api.saveProviderManagementGroups.mockRejectedValue(new Error('conflict'))
    api.getProviderManagementGroups.mockResolvedValue({ version: 7, groups: [] })
    await mountDialog()
    await click('保存分组')
    expect(saved).not.toHaveBeenCalled()
    expect(closed).not.toHaveBeenCalled()
    expect(document.body.querySelector('[role="alert"]')).not.toBeNull()
    expect(document.body.textContent).toContain('免费')
    await click('重新加载')
    expect(document.body.textContent).toContain('创建分组后即可选择提供商加入')
    await click('保存分组')
    expect(api.saveProviderManagementGroups).toHaveBeenLastCalledWith({ version: 7, groups: [] })
  })

  it('cancels edits without issuing a write', async () => {
    await mountDialog()
    const deletes = [...document.body.querySelectorAll<HTMLButtonElement>('button')].filter(item => item.textContent?.trim() === '删除分组')
    deletes[0]!.click(); await settle()
    await click('取消')
    expect(api.saveProviderManagementGroups).not.toHaveBeenCalled()
    expect(closed).toHaveBeenCalledWith(false)
  })
})
