<template>
  <Dialog
    :model-value="modelValue"
    :title="t('providers.management.title')"
    :description="t('providers.management.hint')"
    size="2xl"
    persistent
    @update:model-value="close"
  >
    <div class="space-y-4">
      <form class="flex gap-2" @submit.prevent="createGroup">
        <Input v-model="newName" :placeholder="t('providers.management.newName')" :aria-label="t('providers.management.newName')" :disabled="busy" maxlength="80" />
        <Button type="submit" variant="outline" :disabled="busy || !newName.trim()">{{ t('providers.management.create') }}</Button>
      </form>
      <p class="text-xs text-muted-foreground">{{ t('providers.management.deleteHint') }}</p>
      <div class="grid gap-4 md:grid-cols-[15rem_minmax(0,1fr)]">
        <div class="max-h-[50vh] space-y-2 overflow-y-auto">
          <div v-for="(group, index) in draft.groups" :key="group.id" class="rounded-lg border p-2" :class="{ 'border-primary bg-primary/5': selectedId === group.id }">
            <button type="button" class="mb-2 w-full truncate text-left text-sm font-medium" :disabled="busy" :aria-pressed="selectedId === group.id" @click="selectedId = group.id">
              {{ group.name }} ({{ group.provider_ids.length }})
            </button>
            <Input v-model="group.name" :aria-label="t('providers.management.name')" :disabled="busy" maxlength="80" class="h-8" />
            <div class="mt-2 flex gap-1">
              <Button variant="ghost" size="sm" :disabled="busy || index === 0" :aria-label="t('providers.management.up')" @click="moveGroup(index, -1)">↑</Button>
              <Button variant="ghost" size="sm" :disabled="busy || index === draft.groups.length - 1" :aria-label="t('providers.management.down')" @click="moveGroup(index, 1)">↓</Button>
              <Button variant="ghost" size="sm" :disabled="busy" @click="removeGroup(group.id)">{{ t('providers.management.delete') }}</Button>
            </div>
          </div>
          <p v-if="!draft.groups.length" class="text-sm text-muted-foreground">{{ t('providers.management.emptyGroups') }}</p>
        </div>
        <div v-if="selectedGroup" class="min-w-0 space-y-3">
          <p class="text-xs text-muted-foreground">{{ t('providers.management.choose') }}</p>
          <Input v-model="search" :placeholder="t('providers.management.search')" :aria-label="t('providers.management.search')" :disabled="busy" />
          <div class="flex flex-wrap gap-2">
            <Button variant="outline" size="sm" :disabled="busy || !matching.length" @click="addMatching">{{ t('providers.management.selectFiltered') }}</Button>
            <Button variant="ghost" size="sm" :disabled="busy || !matching.length" @click="removeMatching">{{ t('providers.management.removeFiltered') }}</Button>
          </div>
          <div class="max-h-[40vh] divide-y overflow-y-auto rounded-lg border">
            <div v-for="provider in matching" :key="provider.id" class="flex items-center gap-2 px-3 py-2">
              <label class="flex min-w-0 flex-1 cursor-pointer items-center gap-2">
                <Checkbox :checked="selectedGroup.provider_ids.includes(provider.id)" :disabled="busy" @update:checked="assign(provider.id, $event)" />
                <span class="min-w-0"><span class="block truncate text-sm">{{ provider.name }}</span><span class="block truncate text-xs text-muted-foreground">{{ membership.get(provider.id) || t('providers.management.ungrouped') }}</span></span>
              </label>
              <template v-if="selectedGroup.provider_ids.includes(provider.id)">
                <Button variant="ghost" size="sm" :disabled="busy || selectedGroup.provider_ids.indexOf(provider.id) === 0" :aria-label="t('providers.management.up')" @click="moveProvider(provider.id, -1)">↑</Button>
                <Button variant="ghost" size="sm" :disabled="busy || selectedGroup.provider_ids.indexOf(provider.id) === selectedGroup.provider_ids.length - 1" :aria-label="t('providers.management.down')" @click="moveProvider(provider.id, 1)">↓</Button>
              </template>
            </div>
            <p v-if="!matching.length" class="p-4 text-sm text-muted-foreground">{{ t('providers.management.noMatches') }}</p>
          </div>
        </div>
      </div>
      <div v-if="error" role="alert" class="space-y-2 text-sm text-destructive">
        <p>{{ error }}</p>
        <p class="text-xs">{{ t('providers.management.conflict') }}</p>
        <Button variant="outline" size="sm" :disabled="busy" @click="reload">{{ t('providers.management.retry') }}</Button>
      </div>
    </div>
    <template #footer>
      <Button variant="outline" :disabled="busy" @click="close(false)">{{ t('providers.management.cancel') }}</Button>
      <Button :disabled="busy || !validNames" @click="save">{{ t('providers.management.save') }}</Button>
    </template>
  </Dialog>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { Button, Checkbox, Dialog, Input } from '@/components/ui'
import { getProviderManagementGroups, saveProviderManagementGroups, type ProviderManagementGroups } from '@/api/provider-management-groups'
import type { ProviderWithEndpointsSummary } from '@/api/endpoints'
import { assignManagementProviders } from '../utils/managementGroups'
import { parseApiError } from '@/utils/errorParser'
import { useI18n } from '@/i18n'

const props = defineProps<{ modelValue: boolean; document: ProviderManagementGroups; providers: ProviderWithEndpointsSummary[] }>()
const emit = defineEmits<{ 'update:modelValue': [value: boolean]; saved: [document: ProviderManagementGroups] }>()
const { t } = useI18n()
const draft = ref<ProviderManagementGroups>({ version: 0, groups: [] })
const selectedId = ref('')
const newName = ref('')
const search = ref('')
const busy = ref(false)
const error = ref('')
const selectedGroup = computed(() => draft.value.groups.find(group => group.id === selectedId.value))
const membership = computed(() => new Map(draft.value.groups.flatMap(group => group.provider_ids.map(id => [id, group.name] as const))))
const validNames = computed(() => {
  const names = draft.value.groups.map(group => group.name.trim().toLocaleLowerCase())
  return names.every(name => name.length > 0 && [...name].length <= 80) && new Set(names).size === names.length
})
const matching = computed(() => {
  const query = search.value.trim().toLocaleLowerCase()
  const order = new Map(selectedGroup.value?.provider_ids.map((id, index) => [id, index]) ?? [])
  return props.providers.filter(provider => !query || `${provider.name} ${provider.description ?? ''}`.toLocaleLowerCase().includes(query))
    .sort((a, b) => (order.get(a.id) ?? Infinity) - (order.get(b.id) ?? Infinity) || a.name.localeCompare(b.name))
})

function reset(document: ProviderManagementGroups) {
  const existing = new Set(props.providers.map(provider => provider.id))
  draft.value = { version: document.version, groups: document.groups.map(group => ({ ...group, provider_ids: group.provider_ids.filter(id => existing.has(id)) })) }
  selectedId.value = draft.value.groups[0]?.id ?? ''
  newName.value = ''
  search.value = ''
  error.value = ''
}
watch(() => props.modelValue, open => { if (open) reset(props.document) }, { immediate: true })

function close(open: boolean) { if (!busy.value) emit('update:modelValue', open) }
function createGroup() {
  const name = newName.value.trim()
  if (!name || [...name].length > 80 || draft.value.groups.some(group => group.name.trim().toLocaleLowerCase() === name.toLocaleLowerCase())) {
    error.value = t('providers.management.invalidName'); return
  }
  if (draft.value.groups.length >= 200) { error.value = t('providers.management.limit'); return }
  const id = crypto.randomUUID()
  draft.value.groups.push({ id, name, provider_ids: [] })
  selectedId.value = id
  newName.value = ''
  error.value = ''
}
function removeGroup(id: string) {
  draft.value.groups = draft.value.groups.filter(group => group.id !== id)
  if (selectedId.value === id) selectedId.value = draft.value.groups[0]?.id ?? ''
}
function moveGroup(index: number, delta: number) {
  const next = index + delta
  if (next < 0 || next >= draft.value.groups.length) return
  const group = draft.value.groups.splice(index, 1)[0]!
  draft.value.groups.splice(next, 0, group)
}
function assign(id: string, checked: boolean) {
  if (checked) draft.value.groups = assignManagementProviders(draft.value.groups, selectedId.value, [id])
  else if (selectedGroup.value) selectedGroup.value.provider_ids = selectedGroup.value.provider_ids.filter(value => value !== id)
}
function addMatching() {
  draft.value.groups = assignManagementProviders(draft.value.groups, selectedId.value, matching.value.map(provider => provider.id))
}
function removeMatching() {
  const ids = new Set(matching.value.map(provider => provider.id))
  if (selectedGroup.value) selectedGroup.value.provider_ids = selectedGroup.value.provider_ids.filter(id => !ids.has(id))
}
function moveProvider(id: string, delta: number) {
  const ids = selectedGroup.value?.provider_ids
  if (!ids) return
  const index = ids.indexOf(id), next = index + delta
  if (index < 0 || next < 0 || next >= ids.length) return
  ids.splice(index, 1); ids.splice(next, 0, id)
}
async function reload() {
  busy.value = true
  try { reset(await getProviderManagementGroups()) }
  catch (err) { error.value = parseApiError(err, t('providers.management.loadFailed')) }
  finally { busy.value = false }
}
async function save() {
  if (busy.value || !validNames.value) return
  busy.value = true
  error.value = ''
  try {
    const existing = new Set(props.providers.map(provider => provider.id))
    const document = await saveProviderManagementGroups({ ...draft.value, groups: draft.value.groups.map(group => ({
      ...group, name: group.name.trim(), provider_ids: group.provider_ids.filter(id => existing.has(id)),
    })) })
    emit('saved', document)
    emit('update:modelValue', false)
  } catch (err) { error.value = parseApiError(err, t('providers.management.saveFailed')) }
  finally { busy.value = false }
}
</script>
