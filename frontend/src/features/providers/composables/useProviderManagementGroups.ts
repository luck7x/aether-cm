import { computed, ref } from 'vue'
import { useLocalStorage } from '@vueuse/core'
import { getProviderManagementGroups, type ProviderManagementGroups } from '@/api/provider-management-groups'
import { parseApiError } from '@/utils/errorParser'
import { useI18n } from '@/i18n'

export function useProviderManagementGroups() {
  const { t } = useI18n()
  const document = ref<ProviderManagementGroups>({ version: 0, groups: [] })
  const loading = ref(false)
  const ready = ref(false)
  const error = ref('')
  const filter = ref('all')
  const collapsed = useLocalStorage<string[]>('aether-provider-management-collapsed', [])
  const grouped = computed(() => document.value.groups.length > 0)
  let requestId = 0

  function replace(next: ProviderManagementGroups) {
    document.value = next
    ready.value = true
    error.value = ''
    if (filter.value !== 'all' && filter.value !== '__ungrouped__'
      && !next.groups.some(group => group.id === filter.value)) filter.value = 'all'
    const valid = new Set([...next.groups.map(group => group.id), '__ungrouped__'])
    collapsed.value = collapsed.value.filter(id => valid.has(id))
  }

  async function load() {
    const id = ++requestId
    loading.value = true
    error.value = ''
    try {
      const next = await getProviderManagementGroups()
      if (id === requestId) replace(next)
    } catch (err) {
      if (id === requestId) error.value = parseApiError(err, t('providers.management.loadFailed'))
    } finally {
      if (id === requestId) loading.value = false
    }
  }

  function toggle(id: string) {
    collapsed.value = collapsed.value.includes(id)
      ? collapsed.value.filter(value => value !== id) : [...collapsed.value, id]
  }

  return { document, loading, ready, error, filter, collapsed, grouped, replace, load, toggle }
}
