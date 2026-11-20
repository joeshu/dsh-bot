let host

export function configureIOSHost(value) {
  if (!value || !value.rpc || !value.runtime || typeof value.workspace !== 'string') {
    throw new TypeError('Invalid iOS DSH host configuration')
  }
  host = value
}

export function iosHost() {
  if (!host) throw new Error('The iOS DSH host has not been configured')
  return host
}
