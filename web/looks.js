/* Each provider's critter: its name, its body (see SPECIES in pet.js) and its colours. Shared by every page. */
window.MINI_LOOKS = {
  // Mochi, Claude Code's mascot.
  claude: { name: 'Claude', accent: '#e5714b' },
  // Codex's pet: periwinkle, with light eyes on its dark visor.
  codex: { name: 'Codex', accent: '#7183F2', species: 'codex',
    palette: { b: '#7183F2', l: '#97A6FF', s: '#5262D2', d: '#3C49A8', p: '#B9C3FF', e: '#D9E4FF' } },
  // Antigravity runs on Gemini: Gemini's blue-to-rose (in the sprite) with an indigo for its arms.
  antigravity: { name: 'Antigravity', accent: '#6C7EEB', species: 'gemini', palette: { b: '#6C7EEB', s: '#5465C9', p: '#F3B6D2' } },
  // Cursor: the Mac's black pointer with its white edge, white eyes, grey arms and legs.
  cursor: { name: 'Cursor', accent: '#55555c', species: 'cursor',
    palette: { b: '#1B1B20', l: '#2E2E35', s: '#141418', d: '#0E0E11', e: '#FFFFFF', p: '#5A5A64' } },
};
