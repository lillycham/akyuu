import { expect, test } from 'claude-code/testing'

const STATUS = 'root: /store\nmemories: 650, refs: 50, pins: 0\n'

// Stands for the engine: akyuu answers `status` and `note`, and the last
// status line is kept in `lines`.
const engine = (on: any, status = { exitCode: 0, stdout: STATUS, stderr: '' }) => {
  const lines: (string | undefined)[] = []
  const runs: string[][] = []
  on('command.register', () => ({ value: { command: 'akyuu-note' } }))
  on('session.start', (_: unknown, e: { cwd: string }) => ({ cwd: e.cwd }))
  on('tool.call', () => ({ result: {} }))
  on('process.run', (_: unknown, e: { argv: string[] }) => {
    runs.push([...e.argv])
    return e.argv[1] === 'note'
      ? { value: { exitCode: 0, stdout: 'sha256-abc\n', stderr: '' } }
      : { value: status }
  })
  on('ui.status', (_: unknown, e: { text: string | undefined }) => {
    lines.push(e.text)
    return { value: undefined }
  })
  return { lines, runs }
}

const start = { cwd: '/', surface: 'terminal', isInteractive: true } as const

test('the status line shows the counts of the store', async ($, on) => {
  const { lines } = engine(on)
  await $.session.start(start)
  expect(lines.at(-1)).toBe('650 memories, 50 refs')
})

test('a write through either server counts, a read does not', async ($, on) => {
  const { lines } = engine(on)
  await $.session.start(start)
  await $.tool.call({ tool: 'mcp__akyuu__recall', query: 'x' } as any)
  await $.tool.call({ tool: 'mcp__other__note', text: 'x' } as any)
  expect(lines.at(-1)).toBe('650 memories, 50 refs')
  await $.tool.call({ tool: 'mcp__plugin_akyuu_akyuu__note', text: 'x' } as any)
  await $.tool.call({ tool: 'mcp__akyuu__supersede', ref: 'a' } as any)
  expect(lines.at(-1)).toBe('650 memories, 50 refs · 2 written here')
})

test('a store that does not answer says so', async ($, on) => {
  const { lines } = engine(on, { exitCode: 1, stdout: '', stderr: 'no root' })
  await $.session.start(start)
  expect(lines.at(-1)).toBe('no store')
})

test('/akyuu-note writes the text as one argument', async ($, on) => {
  const { runs } = engine(on)
  await $.session.start(start)
  const empty = await $.command.run({ command: 'akyuu-note', args: '  ' } as any)
  expect(empty.text).toBe('Usage: /akyuu-note <text>')
  const done = await $.command.run({ command: 'akyuu-note', args: 'a "quoted" note' } as any)
  expect(done.text).toBe('Noted: sha256-abc')
  expect(runs).toContainEqual(['akyuu', 'note', 'a "quoted" note'])
})
