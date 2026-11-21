import { defineTool } from '@deepseek-ai/dsh-tools'
import { delegationDepthOf } from '@deepseek-ai/dsh-subagent'
import { isIOSPrivateSessionId } from './private-session-access.mjs'

const outputSchema = {
  type: 'object',
  properties: { output: { type: 'string', required: true } },
  additionalProperties: false,
}

function output(value) {
  return { output: JSON.stringify(value) }
}

export function iosSchedulePublicTask(task) {
  const {
    involvedSessionIds: _involved,
    target: _target,
    createdAt: _created,
    executionActive: _executionActive,
    deliveryFloorEndsAt: _deliveryFloorEndsAt,
    lastDelivery,
    ...visible
  } = task
  if (!lastDelivery) return visible
  const { targetSessionId: _targetSessionId, ...receipt } = lastDelivery
  return { ...visible, lastDelivery: receipt }
}

function callerSession(exec) {
  const session = exec?.agent?.session
  if (!session || delegationDepthOf(exec.agent) > 0) return undefined
  return session
}

export function iosScheduleTaskVisible(task, sessionId) {
  const involved = Array.isArray(task?.involvedSessionIds) ? task.involvedSessionIds : []
  if (!involved.includes(sessionId)) return false
  // Never disclose a task that crosses into another private Session, including
  // when an internal plugin has retargeted a task outside the native tools.
  if (involved.some((id) => isIOSPrivateSessionId(id) && id !== sessionId)) return false
  return true
}

function errorOutput(error) {
  const code = typeof error?.code === 'string' && /^[a-z][a-z0-9_-]{0,63}$/.test(error.code)
    ? error.code
    : 'schedule_error'
  const message = typeof error?.message === 'string' ? error.message.slice(0, 500) : 'Schedule operation failed.'
  return output({ code, message })
}

function register(ctx) {
  const removers = []
  const definitions = [
    defineTool({
      name: 'schedule_create',
      description: 'Only create or modify scheduled tasks at the user’s explicit request. Create a durable task that delivers its prompt to this Bot session on each RFC 5545 recurrence. The task runs only while the iOS DSH host is active; iOS may suspend or terminate it.',
      parameters: {
        title: { type: 'string', required: true, description: 'Short task title, at most 120 characters.' },
        prompt: { type: 'string', required: true, description: 'Instruction delivered to the target session at each occurrence.' },
        rrule: { type: 'string', required: true, description: 'One DTSTART line and one RRULE line. Use TZID= with an IANA zone to preserve local time. A one-time task uses RRULE:FREQ=DAILY;COUNT=1.' },
      },
      output: { schema: outputSchema, render: (_args, value) => [{ type: 'text', text: value.output }] },
      async execute(args, exec) {
        const session = callerSession(exec)
        if (!session) return output({ code: 'subagent_session', message: 'Delegated agents cannot create schedules.' })
        try {
          const task = await ctx.schedule.create({
            title: args.title,
            prompt: args.prompt,
            timing: { kind: 'rrule', rrule: args.rrule },
            target: { kind: 'session', sessionId: session.id },
          }, session.id, exec.signal)
          return output(iosSchedulePublicTask(task))
        } catch (error) {
          return errorOutput(error)
        }
      },
    }),
    defineTool({
      name: 'schedule_list',
      description: 'List only scheduled tasks owned by or delivered to this Bot session. Tasks from other Bot sessions, including private sessions, are not returned.',
      parameters: {
        active: { type: 'boolean', description: 'true lists active tasks; false lists paused or ended tasks.' },
        limit: { type: 'integer', description: 'Page size from 1 to 100; defaults to 50.' },
        offset: { type: 'integer', description: 'Number of visible tasks to skip; defaults to 0.' },
      },
      output: { schema: outputSchema, render: (_args, value) => [{ type: 'text', text: value.output }] },
      isConcurrencySafe: () => true,
      async execute(args, exec) {
        const session = callerSession(exec)
        if (!session) return output({ code: 'subagent_session', message: 'Delegated agents cannot list schedules.' })
        const limit = args.limit === undefined ? 50 : args.limit
        const offset = args.offset === undefined ? 0 : args.offset
        if (!Number.isInteger(limit) || limit < 1 || limit > 100 || !Number.isInteger(offset) || offset < 0) {
          return output({ code: 'invalid_page', message: 'limit must be 1–100 and offset must be nonnegative.' })
        }
        try {
          const visible = (await ctx.schedule.catalog())
            .filter((task) => iosScheduleTaskVisible(task, session.id))
            .filter((task) => args.active === undefined || (task.status === 'active') === args.active)
          const items = visible.slice(offset, offset + limit).map(iosSchedulePublicTask)
          return output({ items, shown: items.length, total: visible.length, limit, offset })
        } catch (error) {
          return errorOutput(error)
        }
      },
    }),
    defineTool({
      name: 'schedule_view',
      description: 'View one schedule owned by or delivered to this Bot session. A task outside this session is reported as not found.',
      parameters: { id: { type: 'string', required: true, description: 'Schedule task ID.' } },
      output: { schema: outputSchema, render: (_args, value) => [{ type: 'text', text: value.output }] },
      isConcurrencySafe: () => true,
      async execute(args, exec) {
        const session = callerSession(exec)
        if (!session) return output({ code: 'subagent_session', message: 'Delegated agents cannot view schedules.' })
        try {
          const task = await ctx.schedule.view({ id: args.id })
          if (!iosScheduleTaskVisible(task, session.id)) return output({ id: args.id, code: 'schedule_not_found' })
          return output(iosSchedulePublicTask(task))
        } catch (error) {
          return errorOutput(error)
        }
      },
    }),
    defineTool({
      name: 'schedule_history',
      description: 'Read the bounded delivery receipt history for a task visible to this Bot session. A receipt means the reminder was durably written to the Session inbox; it does not mean the model completed it. Other sessions’ tasks and target IDs are hidden.',
      parameters: {
        id: { type: 'string', required: true, description: 'Schedule task ID.' },
        limit: { type: 'integer', description: 'Page size from 1 to 100; defaults to 20.' },
        before: { type: 'string', description: 'Exclusive message ID cursor returned by the previous page.' },
      },
      output: { schema: outputSchema, render: (_args, value) => [{ type: 'text', text: value.output }] },
      isConcurrencySafe: () => true,
      async execute(args, exec) {
        const session = callerSession(exec)
        if (!session) return output({ code: 'subagent_session', message: 'Delegated agents cannot read schedule history.' })
        const limit = args.limit === undefined ? 20 : args.limit
        if (!Number.isInteger(limit) || limit < 1 || limit > 100
          || (args.before !== undefined && (typeof args.before !== 'string' || args.before.length > 256))) {
          return output({ code: 'invalid_page', message: 'limit must be 1–100 and before must be a valid message cursor.' })
        }
        try {
          const task = await ctx.schedule.view({ id: args.id })
          if (!iosScheduleTaskVisible(task, session.id)) return output({ id: args.id, code: 'schedule_not_found' })
          const history = await ctx.schedule.history({ id: args.id, limit, ...(args.before === undefined ? {} : { before: args.before }) })
          if (!Array.isArray(history?.records)) return output({ id: args.id, code: 'schedule_not_found' })
          return output({
            ...history,
            records: history.records.map(({ targetSessionId: _targetSessionId, ...receipt }) => receipt),
          })
        } catch (error) {
          return errorOutput(error)
        }
      },
    }),
    defineTool({
      name: 'schedule_edit',
      description: 'Update, pause, resume or delete a task owned by or delivered to this Bot session. Other Bot sessions’ tasks are hidden. Only edit or delete at the user’s explicit request.',
      parameters: {
        id: { type: 'string', required: true, description: 'Schedule task ID.' },
        action: { type: 'string', required: true, enum: ['update', 'delete'] },
        title: { type: 'string' },
        prompt: { type: 'string' },
        rrule: { type: 'string', description: 'Replacement DTSTART and RRULE lines.' },
        active: { type: 'boolean', description: 'false pauses; true resumes when there is a future occurrence.' },
        expectedUpdatedAt: { type: 'string', description: 'Optional schedule revision to reject stale edits.' },
      },
      output: { schema: outputSchema, render: (_args, value) => [{ type: 'text', text: value.output }] },
      async execute(args, exec) {
        const session = callerSession(exec)
        if (!session) return output({ code: 'subagent_session', message: 'Delegated agents cannot edit schedules.' })
        try {
          const current = await ctx.schedule.view({ id: args.id })
          if (!iosScheduleTaskVisible(current, session.id)) return output({ id: args.id, code: 'schedule_not_found' })
          const expectedUpdatedAt = args.expectedUpdatedAt ?? current.updatedAt
          const revision = expectedUpdatedAt === undefined ? {} : { expectedUpdatedAt }
          let request
          if (args.action === 'delete') {
            if (['title', 'prompt', 'rrule', 'active'].some((key) => args[key] !== undefined)) {
              return output({ id: args.id, code: 'invalid_selector', message: 'delete accepts only id, action and expectedUpdatedAt.' })
            }
            request = { id: args.id, action: 'delete', ...revision }
          } else if (args.action === 'update') {
            const patch = {
              ...(args.title === undefined ? {} : { title: args.title }),
              ...(args.prompt === undefined ? {} : { prompt: args.prompt }),
              ...(args.rrule === undefined ? {} : { timing: { kind: 'rrule', rrule: args.rrule } }),
              ...(args.active === undefined ? {} : { active: args.active }),
            }
            if (Object.keys(patch).length === 0) return output({ id: args.id, code: 'invalid_selector', message: 'update requires a field to change.' })
            request = { id: args.id, action: 'update', patch, ...revision }
          } else {
            return output({ id: args.id, code: 'invalid_action', message: 'action must be update or delete.' })
          }
          const result = await ctx.schedule.edit(request, session.id, exec.signal)
          return output(result?.kind ? iosSchedulePublicTask(result) : result)
        } catch (error) {
          return errorOutput(error)
        }
      },
    }),
  ]

  for (const definition of definitions) removers.push(ctx.tools.register(definition))
  const removePrompt = ctx.systemPrompt.section({
    name: 'ios-schedule-guidance',
    order: ctx.systemPrompt.getSectionOrder('TOOL_SCHEDULE'),
    text: 'Only create, change, pause, resume, or delete a scheduled task when the user explicitly asks. Use schedule_history only when the user asks about delivery records; a receipt confirms durable inbox delivery, not model completion. Schedule tools are scoped to this Bot session; do not claim exact iOS background delivery. The host must be active to deliver, and after relaunch only the latest missed recurring occurrence is caught up.',
  })
  return () => {
    removePrompt?.()
    removers.reverse().forEach((remove) => remove?.())
  }
}

export function mountIOSScheduleTools(ctx) {
  ctx.inject(['schedule'], register)
}
