const SIZE = 120
const LINE_WIDTH = 8
const RADIUS = (SIZE - LINE_WIDTH) / 2
const CENTER = SIZE / 2

export interface ProgressRing {
  canvas: HTMLCanvasElement
  update(fraction: number): void
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

  function draw(fraction: number) {
    const appEl = document.querySelector('[data-xftp-app]') ?? document.getElementById('app')
    const s = appEl ? getComputedStyle(appEl) : null
    const bgColor = s?.getPropertyValue('--xftp-ring-bg').trim() || '#e0e0e0'
    const fgColor = s?.getPropertyValue('--xftp-ring-fg').trim() || '#3b82f6'
    const textColor = s?.getPropertyValue('--xftp-ring-text').trim() || '#333'

    ctx.clearRect(0, 0, SIZE, SIZE)
    // Background arc
    ctx.beginPath()
    ctx.arc(CENTER, CENTER, RADIUS, 0, 2 * Math.PI)
    ctx.strokeStyle = bgColor
    ctx.lineWidth = LINE_WIDTH
    ctx.lineCap = 'round'
    ctx.stroke()
    // Foreground arc
    if (fraction > 0) {
      ctx.beginPath()
      ctx.arc(CENTER, CENTER, RADIUS, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * fraction)
      ctx.strokeStyle = fgColor
      ctx.lineWidth = LINE_WIDTH
      ctx.lineCap = 'round'
      ctx.stroke()
    }
    // Percentage text
    const pct = Math.round(fraction * 100)
    ctx.fillStyle = textColor
    ctx.font = '600 20px system-ui, sans-serif'
    ctx.textAlign = 'center'
    ctx.textBaseline = 'middle'
    ctx.fillText(pct + '%', CENTER, CENTER)
  }

  draw(0)
  return {canvas, update: draw}
}
