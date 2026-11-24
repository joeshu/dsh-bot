/**
 * Transparent Anthropic Messages -> OpenAI Chat Completions fallback adapter
 * for custom HTTP/HTTPS model endpoints in DS Bot iOS.
 *
 * - Never intercepts official DeepSeek endpoints (api.deepseek.com) or loopback.
 * - Injects Authorization: Bearer <key> alongside x-api-key for custom gateways.
 * - Tries native Anthropic POST /messages first; if the server returns 404/405/501
 *   (or path-unsupported 400), caches the origin as OpenAI-compatible and translates
 *   the request/SSE stream seamlessly via POST /chat/completions.
 */

function extractTextFromBlocks(content) {
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return ''
  return content
    .filter((b) => b && b.type === 'text' && typeof b.text === 'string')
    .map((b) => b.text)
    .join('\n')
}

export function anthropicToOpenAiRequest(body) {
  const messages = []

  const systemText = extractTextFromBlocks(body.system)
  if (systemText) {
    messages.push({ role: 'system', content: systemText })
  }

  for (const msg of Array.isArray(body.messages) ? body.messages : []) {
    if (!msg || !msg.role) continue
    if (typeof msg.content === 'string') {
      messages.push({ role: msg.role, content: msg.content })
      continue
    }
    if (!Array.isArray(msg.content)) continue

    if (msg.role === 'user') {
      const toolResults = msg.content.filter((b) => b && b.type === 'tool_result')
      const nonToolBlocks = msg.content.filter((b) => b && b.type !== 'tool_result')

      for (const tr of toolResults) {
        const text = typeof tr.content === 'string'
          ? tr.content
          : Array.isArray(tr.content)
            ? tr.content.map((c) => (typeof c === 'string' ? c : c?.text ?? JSON.stringify(c))).join('\n')
            : JSON.stringify(tr.content ?? '')
        messages.push({
          role: 'tool',
          tool_call_id: String(tr.tool_use_id ?? ''),
          content: text,
        })
      }

      if (nonToolBlocks.length > 0) {
        const hasImage = nonToolBlocks.some((b) => b.type === 'image')
        if (!hasImage) {
          const joined = nonToolBlocks
            .filter((b) => b.type === 'text' && typeof b.text === 'string')
            .map((b) => b.text)
            .join('\n')
          if (joined) messages.push({ role: 'user', content: joined })
        } else {
          const parts = []
          for (const b of nonToolBlocks) {
            if (b.type === 'text' && typeof b.text === 'string') {
              parts.push({ type: 'text', text: b.text })
            } else if (b.type === 'image' && b.source?.type === 'base64' && b.source?.data) {
              const media = b.source.media_type || 'image/png'
              parts.push({
                type: 'image_url',
                image_url: { url: `data:${media};base64,${b.source.data}` },
              })
            }
          }
          if (parts.length > 0) messages.push({ role: 'user', content: parts })
        }
      }
      continue
    }

    if (msg.role === 'assistant') {
      const textParts = []
      const toolCalls = []
      for (const b of msg.content) {
        if (!b) continue
        if (b.type === 'text' && typeof b.text === 'string') {
          textParts.push(b.text)
        } else if (b.type === 'tool_use') {
          toolCalls.push({
            id: String(b.id ?? `call_${toolCalls.length}`),
            type: 'function',
            function: {
              name: String(b.name ?? ''),
              arguments: typeof b.input === 'string' ? b.input : JSON.stringify(b.input ?? {}),
            },
          })
        }
      }
      const entry = {
        role: 'assistant',
        content: textParts.length > 0 ? textParts.join('') : (toolCalls.length > 0 ? null : ''),
      }
      if (toolCalls.length > 0) entry.tool_calls = toolCalls
      messages.push(entry)
    }
  }

  const out = {
    model: body.model,
    messages,
    stream: body.stream !== false,
  }
  if (typeof body.max_tokens === 'number' && body.max_tokens > 0 && body.max_tokens < 32768) {
    out.max_tokens = body.max_tokens
  }
  if (typeof body.temperature === 'number') out.temperature = body.temperature
  if (typeof body.top_p === 'number') out.top_p = body.top_p
  if (Array.isArray(body.stop_sequences) && body.stop_sequences.length > 0) {
    out.stop = body.stop_sequences
  }
  if (Array.isArray(body.tools) && body.tools.length > 0) {
    out.tools = body.tools.map((tool) => ({
      type: 'function',
      function: {
        name: tool.name,
        description: tool.description ?? '',
        parameters: tool.input_schema ?? { type: 'object', properties: {} },
      },
    }))
  }
  return out
}

function mapStopReason(finishReason, hadToolCalls) {
  if (hadToolCalls || finishReason === 'tool_calls' || finishReason === 'function_call') return 'tool_use'
  if (finishReason === 'length') return 'max_tokens'
  return 'end_turn'
}

function formatSse(event, data) {
  return `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`
}

export function createAnthropicSseFromOpenAiResponse(openAiResponse, fallbackModel) {
  const encoder = new TextEncoder()
  const contentType = (openAiResponse.headers.get('content-type') || '').toLowerCase()

  const stream = new ReadableStream({
    async start(controller) {
      const emit = (event, data) => {
        controller.enqueue(encoder.encode(formatSse(event, data)))
      }

      const msgId = `msg_oai_${Date.now().toString(36)}`
      let modelName = fallbackModel || 'custom-model'
      let started = false
      let nextBlockIndex = 0
      let activeThinkingIndex = null
      let activeTextIndex = null
      const activeTools = new Map() // openAi tool index -> { blockIndex, id, name }
      let finishReason = null
      let inputTokens = 0
      let outputTokens = 0

      const ensureStarted = () => {
        if (started) return
        started = true
        emit('message_start', {
          type: 'message_start',
          message: {
            id: msgId,
            type: 'message',
            role: 'assistant',
            model: modelName,
            content: [],
            stop_reason: null,
            stop_sequence: null,
            usage: { input_tokens: inputTokens, output_tokens: 0 },
          },
        })
      }

      const closeThinking = () => {
        if (activeThinkingIndex !== null) {
          emit('content_block_stop', { type: 'content_block_stop', index: activeThinkingIndex })
          activeThinkingIndex = null
        }
      }

      const closeText = () => {
        if (activeTextIndex !== null) {
          emit('content_block_stop', { type: 'content_block_stop', index: activeTextIndex })
          activeTextIndex = null
        }
      }

      const closeAllBlocks = () => {
        closeThinking()
        closeText()
        for (const t of activeTools.values()) {
          if (!t.closed) {
            emit('content_block_stop', { type: 'content_block_stop', index: t.blockIndex })
            t.closed = true
          }
        }
      }

      const handleChunk = (parsed) => {
        if (!parsed || typeof parsed !== 'object') return
        if (parsed.error) {
          const msg = typeof parsed.error === 'string'
            ? parsed.error
            : (parsed.error.message || JSON.stringify(parsed.error))
          emit('error', { type: 'error', error: { type: 'api_error', message: msg } })
          return
        }
        if (typeof parsed.model === 'string' && parsed.model) modelName = parsed.model
        if (parsed.usage) {
          if (typeof parsed.usage.prompt_tokens === 'number') inputTokens = parsed.usage.prompt_tokens
          if (typeof parsed.usage.completion_tokens === 'number') outputTokens = parsed.usage.completion_tokens
        }
        const choice = Array.isArray(parsed.choices) ? parsed.choices[0] : null
        if (!choice) return
        if (choice.finish_reason) finishReason = choice.finish_reason

        // Support both streaming delta and non-streaming message objects
        const delta = choice.delta || choice.message || {}
        const reasoning = typeof delta.reasoning_content === 'string'
          ? delta.reasoning_content
          : (typeof delta.reasoning === 'string' ? delta.reasoning : '')

        if (reasoning) {
          ensureStarted()
          closeText()
          if (activeThinkingIndex === null) {
            activeThinkingIndex = nextBlockIndex++
            emit('content_block_start', {
              type: 'content_block_start',
              index: activeThinkingIndex,
              content_block: { type: 'thinking', thinking: '' },
            })
          }
          emit('content_block_delta', {
            type: 'content_block_delta',
            index: activeThinkingIndex,
            delta: { type: 'thinking_delta', thinking: reasoning },
          })
        }

        if (typeof delta.content === 'string' && delta.content.length > 0) {
          ensureStarted()
          closeThinking()
          if (activeTextIndex === null) {
            activeTextIndex = nextBlockIndex++
            emit('content_block_start', {
              type: 'content_block_start',
              index: activeTextIndex,
              content_block: { type: 'text', text: '' },
            })
          }
          emit('content_block_delta', {
            type: 'content_block_delta',
            index: activeTextIndex,
            delta: { type: 'text_delta', text: delta.content },
          })
        }

        if (Array.isArray(delta.tool_calls)) {
          ensureStarted()
          closeThinking()
          closeText()
          for (let i = 0; i < delta.tool_calls.length; i += 1) {
            const tc = delta.tool_calls[i]
            const key = typeof tc.index === 'number' ? tc.index : i
            let state = activeTools.get(key)
            if (!state) {
              const blockIndex = nextBlockIndex++
              state = {
                blockIndex,
                id: tc.id || `toolu_${blockIndex}_${Date.now().toString(36)}`,
                name: tc.function?.name || '',
                closed: false,
              }
              activeTools.set(key, state)
              emit('content_block_start', {
                type: 'content_block_start',
                index: blockIndex,
                content_block: { type: 'tool_use', id: state.id, name: state.name, input: {} },
              })
            }
            const argsChunk = tc.function?.arguments
            if (typeof argsChunk === 'string' && argsChunk.length > 0) {
              emit('content_block_delta', {
                type: 'content_block_delta',
                index: state.blockIndex,
                delta: { type: 'input_json_delta', partial_json: argsChunk },
              })
            }
          }
        }
      }

      try {
        if (!contentType.includes('text/event-stream')) {
          const text = await openAiResponse.text()
          const parsed = JSON.parse(text)
          handleChunk(parsed)
        } else if (openAiResponse.body) {
          const reader = openAiResponse.body.getReader()
          const decoder = new TextDecoder()
          let buffer = ''
          while (true) {
            const { value, done } = await reader.read()
            if (done) break
            buffer += decoder.decode(value, { stream: true })
            let nl
            while ((nl = buffer.indexOf('\n')) !== -1) {
              const line = buffer.slice(0, nl).replace(/\r$/, '')
              buffer = buffer.slice(nl + 1)
              if (!line.startsWith('data:')) continue
              const payload = line.slice(5).trim()
              if (!payload || payload === '[DONE]') continue
              try {
                handleChunk(JSON.parse(payload))
              } catch {}
            }
          }
          if (buffer.trim().startsWith('data:')) {
            const payload = buffer.trim().slice(5).trim()
            if (payload && payload !== '[DONE]') {
              try { handleChunk(JSON.parse(payload)) } catch {}
            }
          }
        }

        ensureStarted()
        closeAllBlocks()
        emit('message_delta', {
          type: 'message_delta',
          delta: {
            stop_reason: mapStopReason(finishReason, activeTools.size > 0),
            stop_sequence: null,
          },
          usage: {
            input_tokens: inputTokens,
            output_tokens: outputTokens,
          },
        })
        emit('message_stop', { type: 'message_stop' })
        controller.close()
      } catch (err) {
        controller.error(err)
      }
    },
  })

  return new Response(stream, {
    status: 200,
    headers: {
      'content-type': 'text/event-stream; charset=utf-8',
      'cache-control': 'no-cache',
    },
  })
}

export function installCustomEndpointCompatFetch({ getProviderBaseURL, isOfficialBase }) {
  if (globalThis.__DSBOT_COMPAT_FETCH_INSTALLED__) return
  const baseFetch = globalThis.fetch.bind(globalThis)
  const openAiFallbackOrigins = new Set()

  const shouldTryOpenAiFallback = (status, bodyText) => {
    if (status === 404 || status === 405 || status === 501) return true
    if ((status === 400 || status === 422) && /not found|not implemented|unknown path|invalid url|unsupported|unrecognized|messages/i.test(bodyText)) {
      return true
    }
    return false
  }

  const wrappedFetch = async (input, init) => {
    const rawUrl = typeof input === 'string' ? input : (input instanceof URL ? input.href : input?.url)
    const method = (init?.method || (typeof input === 'object' && input?.method) || 'GET').toUpperCase()
    if (!rawUrl || method !== 'POST') {
      return await baseFetch(input, init)
    }

    let parsedUrl
    try {
      parsedUrl = new URL(rawUrl)
    } catch {
      return await baseFetch(input, init)
    }

    const activeBase = getProviderBaseURL?.()
    if (!activeBase || isOfficialBase?.(activeBase)) {
      return await baseFetch(input, init)
    }

    let activeParsed
    try {
      activeParsed = new URL(activeBase)
    } catch {
      return await baseFetch(input, init)
    }

    // Only intercept Anthropic Messages POSTs targeting the active custom endpoint origin
    if (parsedUrl.origin !== activeParsed.origin || !parsedUrl.pathname.endsWith('/messages')) {
      return await baseFetch(input, init)
    }

    const headers = new Headers(init?.headers || (input instanceof Request ? input.headers : undefined))
    const apiKey = headers.get('x-api-key')
    if (apiKey && !headers.has('authorization')) {
      headers.set('authorization', `Bearer ${apiKey}`)
    }

    const bodyText = typeof init?.body === 'string' ? init.body : null
    const chatCompletionsUrl = new URL(parsedUrl.href)
    chatCompletionsUrl.pathname = parsedUrl.pathname.replace(/\/messages$/, '/chat/completions')

    const callOpenAiFallback = async () => {
      if (!bodyText) return null
      let anthropicBody
      try {
        anthropicBody = JSON.parse(bodyText)
      } catch {
        return null
      }
      const openAiBody = anthropicToOpenAiRequest(anthropicBody)
      const oaiHeaders = new Headers({
        'content-type': 'application/json',
        'accept': 'text/event-stream, application/json',
      })
      if (apiKey) {
        oaiHeaders.set('authorization', `Bearer ${apiKey}`)
        oaiHeaders.set('x-api-key', apiKey)
      } else if (headers.has('authorization')) {
        oaiHeaders.set('authorization', headers.get('authorization'))
      }
      const oaiResp = await baseFetch(chatCompletionsUrl.href, {
        method: 'POST',
        headers: oaiHeaders,
        body: JSON.stringify(openAiBody),
        signal: init?.signal,
        redirect: 'follow',
      })
      if (!oaiResp.ok) return oaiResp
      return createAnthropicSseFromOpenAiResponse(oaiResp, anthropicBody.model)
    }

    if (openAiFallbackOrigins.has(parsedUrl.origin) && bodyText) {
      const fallback = await callOpenAiFallback()
      if (fallback) return fallback
    }

    const primaryResp = await baseFetch(input, { ...init, headers })
    if (primaryResp.ok) {
      const ct = (primaryResp.headers.get('content-type') || '').toLowerCase()
      if (ct.includes('text/event-stream') && primaryResp.body) {
        return ensureAnthropicStreamComplete(primaryResp)
      }
      return primaryResp
    }
    if (!bodyText) {
      return primaryResp
    }

    const clonedText = await primaryResp.clone().text().catch(() => '')
    if (shouldTryOpenAiFallback(primaryResp.status, clonedText)) {
      const fallback = await callOpenAiFallback()
      if (fallback && fallback.ok) {
        openAiFallbackOrigins.add(parsedUrl.origin)
        return fallback
      }
      // If fallback also failed with a more specific error (e.g. 401/400 model error), return it
      if (fallback) return fallback
    }

    return primaryResp
  }

  wrappedFetch.__original = baseFetch
  globalThis.fetch = wrappedFetch
  globalThis.__DSBOT_COMPAT_FETCH_INSTALLED__ = true
}

/**
 * Pass-through SSE transformer for custom Anthropic-compatible endpoints.
 * Forwards every chunk immediately, and if the upstream closes cleanly after
 * emitting `message_start` without a trailing `message_stop`, synthesizes the
 * missing closing events so DSH does not abort with "stream ended before message_stop".
 */
export function ensureAnthropicStreamComplete(response) {
  const decoder = new TextDecoder()
  const encoder = new TextEncoder()
  let seenMessageStart = false
  let seenMessageDelta = false
  let seenMessageStop = false
  let openBlockIndex = null
  let tail = ''

  const scanText = (chunkText) => {
    const combined = tail + chunkText
    const lines = combined.split('\n')
    tail = lines.pop() ?? ''
    for (const rawLine of lines) {
      const line = rawLine.trim()
      if (!line.startsWith('data:')) continue
      const payload = line.slice(5).trim()
      if (!payload || payload === '[DONE]') continue
      try {
        const evt = JSON.parse(payload)
        if (evt.type === 'message_start') seenMessageStart = true
        else if (evt.type === 'content_block_start' && typeof evt.index === 'number') openBlockIndex = evt.index
        else if (evt.type === 'content_block_stop' && evt.index === openBlockIndex) openBlockIndex = null
        else if (evt.type === 'message_delta') seenMessageDelta = true
        else if (evt.type === 'message_stop') seenMessageStop = true
      } catch {}
    }
  }

  const stream = new ReadableStream({
    async start(controller) {
      const reader = response.body.getReader()
      try {
        while (true) {
          const { value, done } = await reader.read()
          if (done) break
          if (value && value.byteLength > 0) {
            scanText(decoder.decode(value, { stream: true }))
            controller.enqueue(value)
          }
        }
        if (tail.trim()) scanText('\n')
        if (seenMessageStart && !seenMessageStop) {
          let suffix = '\n\n'
          if (openBlockIndex !== null) {
            suffix += formatSse('content_block_stop', { type: 'content_block_stop', index: openBlockIndex })
          }
          if (!seenMessageDelta) {
            suffix += formatSse('message_delta', {
              type: 'message_delta',
              delta: { stop_reason: 'end_turn', stop_sequence: null },
              usage: { output_tokens: 0 },
            })
          }
          suffix += formatSse('message_stop', { type: 'message_stop' })
          controller.enqueue(encoder.encode(suffix))
        }
        controller.close()
      } catch (err) {
        controller.error(err)
      }
    },
  })

  return new Response(stream, {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers,
  })
}
