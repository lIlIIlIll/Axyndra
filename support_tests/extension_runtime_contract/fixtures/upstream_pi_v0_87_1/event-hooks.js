let calls = 0;

export default function (pi) {
  pi.on('tool_call', (event) => {
    calls += 1;
    event.input.text += ':' + calls;
  });
  pi.on('tool_result', () => ({ replacement: true }));
}
