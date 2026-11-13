// The state of one conversation turn, built from the server's events by a pure reducer.
//
// Every event type of `backend/app/schemas/turns.py` is handled: turn_started, route,
// agent_started, agent_finished, tool_started, tool_finished, text_delta, card,
// approval_required, device_action, turn_suspended, turn_completed and error. An unknown type
// is kept in `unknown` and changes nothing else, so a newer server never breaks the screen.

/** @typedef {'idle'|'starting'|'running'|'suspended'|'completed'|'failed'|'cancelled'|'disconnected'} TurnPhase */

export const EVENT_TYPES = Object.freeze([
  'turn_started',
  'route',
  'agent_started',
  'agent_finished',
  'tool_started',
  'tool_finished',
  'text_delta',
  'card',
  'approval_required',
  'device_action',
  'turn_suspended',
  'turn_completed',
  'error',
]);

/** @param {{ownerText?: string, modality?: string}} [seed] */
export function initialTurn(seed = {}) {
  return {
    /** @type {TurnPhase} */
    phase: seed.ownerText ? 'starting' : 'idle',
    ownerText: seed.ownerText ?? '',
    modality: seed.modality ?? 'text',
    turnId: null,
    conversationId: null,
    privacyMode: null,
    route: null,
    /** @type {{agent: string, task: string, status: 'working'|'done'|'failed', durationMs: number|null}[]} */
    agents: [],
    /** @type {{callId: string, tool: string, agent: string, risk: string, status: 'running'|'done'|'failed', summary: string|null, durationMs: number|null}[]} */
    tools: [],
    text: '',
    /** @type {{kind: string, title: string|null, payload: Record<string, any>}[]} */
    cards: [],
    approval: null,
    deviceAction: null,
    suspendedReason: null,
    completed: null,
    /** The last error event. With phase 'suspended' it is a notice (the request is still open). */
    error: null,
    unknown: 0,
  };
}

function replaceWhere(list, match, update) {
  let found = false;
  const next = list.map((item) => {
    if (found || !match(item)) return item;
    found = true;
    return { ...item, ...update };
  });
  return { next, found };
}

/** @param {ReturnType<typeof initialTurn>} state @param {Record<string, any>} event */
export function reduceTurn(state, event) {
  if (!event || typeof event.type !== 'string') return state;
  switch (event.type) {
    case 'turn_started':
      return {
        ...state,
        phase: 'running',
        turnId: event.turn_id,
        conversationId: event.conversation_id,
        privacyMode: event.privacy_mode ?? null,
        error: null,
      };

    case 'route':
      return {
        ...state,
        phase: 'running',
        route: {
          agents: Array.isArray(event.agents) ? event.agents : [],
          reason: event.reason ?? '',
          dataClasses: Array.isArray(event.data_classes) ? event.data_classes : [],
          engine: event.engine ?? 'deterministic',
        },
      };

    case 'agent_started': {
      const row = { agent: event.agent, task: event.task ?? '', status: 'working', durationMs: null };
      const { next, found } = replaceWhere(state.agents, (item) => item.agent === event.agent, row);
      return { ...state, phase: 'running', agents: found ? next : [...state.agents, row] };
    }

    case 'agent_finished': {
      const update = { status: event.ok ? 'done' : 'failed', durationMs: event.duration_ms ?? null };
      const { next, found } = replaceWhere(
        state.agents,
        (item) => item.agent === event.agent && item.status === 'working',
        update,
      );
      const agents = found ? next : [...state.agents, { agent: event.agent, task: '', ...update }];
      return { ...state, agents };
    }

    case 'tool_started': {
      const row = {
        callId: event.call_id,
        tool: event.tool,
        agent: event.agent,
        risk: event.risk ?? 'low',
        status: 'running',
        summary: null,
        durationMs: null,
      };
      // A resumed turn announces the suspended call again: keep one row per call.
      const { next, found } = replaceWhere(state.tools, (item) => item.callId === event.call_id, row);
      return { ...state, phase: 'running', tools: found ? next : [...state.tools, row] };
    }

    case 'tool_finished': {
      const update = {
        status: event.ok ? 'done' : 'failed',
        summary: event.summary ?? null,
        durationMs: event.duration_ms ?? null,
      };
      const { next, found } = replaceWhere(state.tools, (item) => item.callId === event.call_id, update);
      const tools = found
        ? next
        : [...state.tools, { callId: event.call_id, tool: '', agent: '', risk: 'low', ...update }];
      return { ...state, tools };
    }

    case 'text_delta':
      return { ...state, phase: 'running', text: state.text + (event.text ?? '') };

    case 'card': {
      const card = event.card;
      if (!card || typeof card.kind !== 'string') return state;
      return {
        ...state,
        cards: [...state.cards, { kind: card.kind, title: card.title ?? null, payload: card.payload ?? {} }],
      };
    }

    case 'approval_required':
      return { ...state, approval: event.approval ?? null, deviceAction: null };

    case 'device_action':
      return { ...state, deviceAction: event.action ?? null, approval: null };

    case 'turn_suspended':
      return {
        ...state,
        phase: 'suspended',
        turnId: event.turn_id ?? state.turnId,
        suspendedReason: event.reason ?? (state.approval ? 'approval' : 'device_action'),
      };

    case 'turn_completed':
      return {
        ...state,
        phase: 'completed',
        turnId: event.turn_id ?? state.turnId,
        approval: null,
        deviceAction: null,
        suspendedReason: null,
        completed: {
          messageId: event.message_id,
          language: event.language ?? 'en',
          dataClasses: Array.isArray(event.data_classes) ? event.data_classes : [],
          cloudVoiceAllowed: Boolean(event.cloud_voice_allowed),
          usage: event.usage ?? null,
        },
      };

    case 'error': {
      const error = {
        code: event.code ?? 'error',
        message: event.message ?? '',
        retryable: Boolean(event.retryable),
      };
      if (error.code === 'cancelled') {
        return { ...state, phase: 'cancelled', error, approval: null, deviceAction: null, suspendedReason: null };
      }
      // A refused answer (wrong signature, mismatched digest) is followed by the same request
      // and `turn_suspended` again; until then the turn counts as failed.
      return { ...state, phase: 'failed', error };
    }

    default:
      return { ...state, unknown: state.unknown + 1 };
  }
}

/** Fold a list of events (for example `ApprovalDecisionResult.events`).
 * @param {ReturnType<typeof initialTurn>} state @param {Record<string, any>[]} events */
export function reduceAll(state, events) {
  return events.reduce(reduceTurn, state);
}

/** The turn was handed the answer it waited for and is running again. */
export function resumed(state) {
  return { ...state, phase: 'running', approval: null, deviceAction: null, suspendedReason: null, error: null };
}

/** The stream broke before the turn ended. The server keeps working; history has the reply. */
export function disconnected(state, message = '') {
  if (['completed', 'failed', 'cancelled', 'suspended', 'idle'].includes(state.phase)) return state;
  return { ...state, phase: 'disconnected', error: { code: 'unreachable', message, retryable: true } };
}

export function isActive(state) {
  return state.phase === 'starting' || state.phase === 'running';
}

export function isFinal(state) {
  return state.phase === 'completed' || state.phase === 'failed' || state.phase === 'cancelled';
}

export function workingAgents(state) {
  return state.agents.filter((item) => item.status === 'working').map((item) => item.agent);
}

export function runningTools(state) {
  return state.tools.filter((item) => item.status === 'running');
}

/** Which of the eight orb states the screen shows. Voice wins over the turn, the turn over rest.
 * @param {ReturnType<typeof initialTurn>} turn
 * @param {{listening?: boolean, speaking?: boolean, privateMode?: boolean, errorFlash?: boolean}} [context] */
export function orbStateFor(turn, context = {}) {
  if (context.listening) return 'listening';
  if (context.speaking) return 'speaking';
  if (context.errorFlash) return 'error';
  if (isActive(turn)) {
    if (runningTools(turn).length > 0) return 'tool';
    if (workingAgents(turn).length > 0) return 'delegating';
    return 'processing';
  }
  if (turn.phase === 'suspended') {
    // Waiting for the owner: the agent that asked stays docked.
    return turn.tools.length > 0 ? 'tool' : 'delegating';
  }
  return context.privateMode ? 'private' : 'idle';
}

/** Agents to draw as satellites: those working now, else the one whose call waits for the owner.
 * @param {ReturnType<typeof initialTurn>} turn */
export function satellitesFor(turn) {
  if (!isActive(turn) && turn.phase !== 'suspended') return [];
  const working = workingAgents(turn);
  if (working.length > 0) return working.slice(0, 6);
  const running = runningTools(turn).map((item) => item.agent).filter(Boolean);
  if (running.length > 0) return [...new Set(running)].slice(0, 6);
  if (turn.phase === 'suspended') {
    const agent = turn.approval?.agent || turn.tools[turn.tools.length - 1]?.agent;
    return agent ? [agent] : [];
  }
  return [];
}

/** Rows for the Activity screen, one per agent, with the status word to show:
 * 'working' | 'needs_owner' | 'done' | 'failed'. A row still open when the turn ended without
 * completing is shown as "couldn't finish" rather than as working for ever.
 * @param {ReturnType<typeof initialTurn>} turn */
export function activityRows(turn) {
  const ended = turn.phase === 'failed' || turn.phase === 'cancelled' || turn.phase === 'disconnected';
  const waitingAgent = turn.phase === 'suspended' ? satellitesFor(turn)[0] ?? null : null;
  const rows = turn.agents.map((item) => {
    const tools = turn.tools.filter((tool) => tool.agent === item.agent);
    const last = tools[tools.length - 1] ?? null;
    let status = item.status;
    if (tools.some((tool) => tool.status === 'running')) status = 'working';
    if (waitingAgent === item.agent) status = 'needs_owner';
    else if (status === 'working' && turn.phase === 'completed') status = 'done';
    else if (status === 'working' && ended) status = 'failed';
    else if (status === 'done' && tools.some((tool) => tool.status === 'failed')) status = 'failed';
    return {
      agent: item.agent,
      task: item.task,
      status,
      tool: last?.tool ?? null,
      summary: [...tools].reverse().find((tool) => tool.summary)?.summary ?? null,
    };
  });
  // A tool can be reported for an agent that never announced itself.
  for (const tool of turn.tools) {
    if (!tool.agent || rows.some((row) => row.agent === tool.agent)) continue;
    const status = waitingAgent === tool.agent ? 'needs_owner' : tool.status === 'running' ? (ended ? 'failed' : 'working') : tool.status;
    rows.push({ agent: tool.agent, task: '', status, tool: tool.tool, summary: tool.summary });
  }
  return rows;
}
