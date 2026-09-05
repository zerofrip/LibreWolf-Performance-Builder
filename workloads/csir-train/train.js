(function () {
  const canvas = document.getElementById('c');
  if (!canvas) return;
  const ctx = canvas.getContext('2d');
  let x = 0;
  function frame() {
    ctx.fillStyle = '#111';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.fillStyle = '#0f0';
    ctx.fillRect(x, 40, 60, 60);
    x = (x + 7) % (canvas.width - 60);
  }
  for (let i = 0; i < 120; i++) frame();
  // Light JS work
  let acc = 0;
  for (let i = 0; i < 500000; i++) acc = (acc ^ (i * 2654435761)) >>> 0;
  document.getElementById('title').dataset.acc = String(acc);
})();
