import CredentialProvider from '@deepseek-ai/dsh-credentials'
import { iosHost } from './index.mjs'

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
  async readRecord() { return undefined }
  async describeRecord() { return { configured: false, writable: false } }
  async listRecords() { return [] }
  async modifyRecord() { throw new Error('Credentials are managed by iOS Keychain settings') }
  async deleteRecord() { throw new Error('Credentials are managed by iOS Keychain settings') }
}
