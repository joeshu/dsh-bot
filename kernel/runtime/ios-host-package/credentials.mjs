import CredentialProvider from '@deepseek-ai/dsh-credentials'
import { iosHost } from './index.mjs'

const ephemeralRecords = new Map()

export default class IosKeychainCredentials extends CredentialProvider {
  async resolve(ref) {
    if (ref !== 'DEEPSEEK_API_KEY') return undefined
    const { rpc, runtime } = iosHost()
    const result = await rpc.request('credential.resolve', { apiBaseURL: runtime.apiBaseURL })
    return typeof result.value === 'string' && result.value.length
      ? { value: result.value, source: 'ios-keychain' } : undefined
  }
  async describe(ref) {
    if (ref !== 'DEEPSEEK_API_KEY') return { configured: false, writable: false }
    const { rpc, runtime } = iosHost()
    const result = await rpc.request('credential.describe', { apiBaseURL: runtime.apiBaseURL })
    return { configured: result.configured === true, source: result.configured ? 'ios-keychain' : undefined, writable: false }
  }
  async set() { throw new Error('Credentials are managed by iOS Keychain settings') }
  async unset() { throw new Error('Credentials are managed by iOS Keychain settings') }
  async readRecord(ref) {
    if (ref === 'DEEPSEEK_API_KEY') return undefined
    const value = ephemeralRecords.get(ref)
    return value === undefined ? undefined : { value, source: 'ios-ephemeral' }
  }
  async describeRecord(ref) {
    if (ref === 'DEEPSEEK_API_KEY') return { configured: false, writable: false }
    const configured = ephemeralRecords.has(ref)
    return { configured, source: configured ? 'ios-ephemeral' : undefined, writable: true }
  }
  async listRecords() { return [...ephemeralRecords.keys()] }
  async modifyRecord(ref, updater) {
    if (ref === 'DEEPSEEK_API_KEY') throw new Error('Credentials are managed by iOS Keychain settings')
    const current = ephemeralRecords.get(ref)
    const next = await updater(current)
    if (next === undefined) ephemeralRecords.delete(ref)
    else ephemeralRecords.set(ref, next)
    return next
  }
  async deleteRecord(ref) {
    if (ref === 'DEEPSEEK_API_KEY') throw new Error('Credentials are managed by iOS Keychain settings')
    ephemeralRecords.delete(ref)
  }
}
