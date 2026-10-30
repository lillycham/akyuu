import type { EngineInterface, Register } from 'claude-code'

// The tools of the MCP server that only read. Every other tool of the
// server writes, and a write counts toward the status line.
const READS = new Set(['recall', 'context', 'log', 'unfold', 'get', 'search', 'status', 'check', 'neighbours', 'compare'])

// The name of a tool of the akyuu server, without its prefix, or undefined
// for a tool of another server. A server from this plugin and one from the
// settings have different prefixes, so match the end.
const akyuuTool = (name: string): string | undefined =>
  /^mcp__(?:plugin_)?(?:akyuu_)?akyuu__(.+)$/.exec(name)?.[1]

// "memories: 650, refs: 50" in the output of `akyuu status`.
const counts = (status: string): string | undefined => {
  const m = /memories: (\d+), refs: (\d+)/.exec(status)
  return m ? `${m[1]} memories, ${m[2]} refs` : undefined
}

let writes = 0

const refresh = async ($: EngineInterface) => {
  try {
    const { exitCode, stdout } = await $.process.run(['akyuu', 'status'], { timeoutMs: 5000 })
    const store = exitCode === 0 ? counts(stdout) : undefined
    const written = writes > 0 ? ` · ${writes} written here` : ''
    $.ui.status(store ? `${store}${written}` : 'no store')
  } catch {
    $.ui.status('not found')
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'akyuu-note',
      description: 'Write a note in the akyuu log of this directory',
      argumentHint: '<text>',
    })
    const started = await next(e)
    await refresh($)
    return started
  })

  on('command.run', { command: 'akyuu-note' }, async ($, e) => {
    const text = e.args.trim()
    if (text === '') return { text: 'Usage: /akyuu-note <text>' }
    const { exitCode, stdout, stderr } = await $.process.run(['akyuu', 'note', text], { timeoutMs: 10000 })
    if (exitCode !== 0) return { text: `akyuu note failed: ${stderr.trim() || stdout.trim()}` }
    writes += 1
    await refresh($)
    return { text: `Noted: ${stdout.trim()}` }
  })

  on('tool.call', async ($, e, next) => {
    const result = await next(e)
    const name = akyuuTool(e.tool)
    if (name !== undefined && !READS.has(name) && result.deny === undefined && result.isError !== true) {
      writes += 1
      await refresh($)
    }
    return result
  })
}
