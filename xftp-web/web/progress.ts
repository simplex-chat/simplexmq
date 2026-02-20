const SIZE = 120
const LINE_WIDTH = 8
const RADIUS = (SIZE - LINE_WIDTH) / 2
const CENTER = SIZE / 2
const LERP_SPEED = 0.12

export interface ProgressRing {
  canvas: HTMLCanvasElement
  update(fraction: number, fgVar?: string): void
  setIndeterminate(on: boolean): void
  destroy(): void
}

export function createProgressRing(): ProgressRing {
  const canvas = document.createElement('canvas')
  canvas.width = SIZE * devicePixelRatio
  canvas.height = SIZE * devicePixelRatio
  canvas.style.width = SIZE + 'px'
  canvas.style.height = SIZE + 'px'
  canvas.className = 'progress-ring'
  const ctx = canvas.getContext('2d')!
  ctx.scale(devicePixelRatio, devicePixelRatio)

  let displayed = 0
  let target = 0
  let animId = 0
  let spinAngle = 0
  let spinning = false
  let currentFgVar = '--xftp-ring-fg'

  function getColors() {
    const appEl = document.querySelector('[data-xftp-app]') ?? document.getElementById('app')
    const s = appEl ? getComputedStyle(appEl) : null
    return {
      bg: s?.getPropertyValue('--xftp-ring-bg').trim() || '#e0e0e0',
      fg: s?.getPropertyValue(currentFgVar).trim() || s?.getPropertyValue('--xftp-ring-fg').trim() || '#3b82f6',
      text: s?.getPropertyValue('--xftp-ring-text').trim() || '#333',
      done: s?.getPropertyValue('--xftp-ring-done').trim() || '#16a34a',
    }
  }

  function drawBgRing(c: ReturnType<typeof getColors>, color?: string) {
    ctx.beginPath()
    ctx.arc(CENTER, CENTER, RADIUS, 0, 2 * Math.PI)
    ctx.strokeStyle = color ?? c.bg
    ctx.lineWidth = LINE_WIDTH
    ctx.lineCap = 'round'
    ctx.stroke()
  }

  function render(fraction: number) {
    const c = getColors()
    ctx.clearRect(0, 0, SIZE, SIZE)
    drawBgRing(c, fraction >= 1 ? c.done : undefined)

    if (fraction > 0 && fraction < 1) {
      ctx.beginPath()
      ctx.arc(CENTER, CENTER, RADIUS, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * fraction)
      ctx.strokeStyle = c.fg
      ctx.lineWidth = LINE_WIDTH
      ctx.lineCap = 'round'
      ctx.stroke()
    }

    if (fraction >= 1) {
      ctx.strokeStyle = c.done
      ctx.lineWidth = 5
      ctx.lineCap = 'round'
      ctx.lineJoin = 'round'
      ctx.beginPath()
      ctx.moveTo(CENTER - 18, CENTER + 2)
      ctx.lineTo(CENTER - 4, CENTER + 16)
      ctx.lineTo(CENTER + 22, CENTER - 14)
      ctx.stroke()
    } else {
      const pct = Math.round(fraction * 100)
      ctx.fillStyle = c.text
      ctx.font = '600 20px system-ui, sans-serif'
      ctx.textAlign = 'center'
      ctx.textBaseline = 'middle'
      ctx.fillText(pct + '%', CENTER, CENTER)
    }
  }

  function tick() {
    if (spinning) return
    const diff = target - displayed
    if (Math.abs(diff) < 0.002) {
      displayed = target
      render(displayed)
      animId = 0
      return
    }
    displayed += diff * LERP_SPEED
    render(displayed)
    animId = requestAnimationFrame(tick)
  }

  function startTick() {
    if (!animId && !spinning) { animId = requestAnimationFrame(tick) }
  }

  function stopAnim() {
    if (animId) { cancelAnimationFrame(animId); animId = 0 }
    spinning = false
  }

  function spinFrame() {
    const c = getColors()
    ctx.clearRect(0, 0, SIZE, SIZE)
    drawBgRing(c)
    ctx.beginPath()
    ctx.arc(CENTER, CENTER, RADIUS, spinAngle, spinAngle + Math.PI * 0.75)
    ctx.strokeStyle = c.fg
    ctx.lineWidth = LINE_WIDTH
    ctx.lineCap = 'round'
    ctx.stroke()
    spinAngle += 0.06
    if (spinning) animId = requestAnimationFrame(spinFrame)
  }

  function redraw() {
    if (spinning) return
    render(displayed)
  }

  const mql = matchMedia('(prefers-color-scheme: dark)')
  mql.addEventListener('change', redraw)
  const observer = new MutationObserver(redraw)
  observer.observe(document.documentElement, {attributes: true, attributeFilter: ['class']})

  render(0)
  return {
    canvas,
    update(fraction: number, fgVar?: string) {
      stopAnim()
      if (fgVar) currentFgVar = fgVar
      // Snap immediately on phase reset (0) and completion (1)
      if ((fraction === 0 && target > 0) || fraction >= 1) {
        displayed = fraction
        target = fraction
        render(fraction)
        return
      }
      target = fraction
      startTick()
    },
    setIndeterminate(on: boolean) {
      stopAnim()
      if (on) { spinning = true; spinFrame() }
    },
    destroy() {
      stopAnim()
      mql.removeEventListener('change', redraw)
      observer.disconnect()
    },
  }
}
