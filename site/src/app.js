(() => {
'use strict';
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
const root = document.documentElement;
const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const sleep = ms => new Promise(r => setTimeout(r, reduce ? Math.min(ms, 60) : ms));

/* ------------------------------------------------------------------ */
/* Data: what the model browser shows                                  */
/* ------------------------------------------------------------------ */
// The group and profile palette is the app's own (Groups.swift).
const COLORS = ['rgb(140,181,245)', 'rgb(245,158,163)', 'rgb(153,212,168)', 'rgb(250,189,133)', 'rgb(189,166,237)', 'rgb(245,179,212)', 'rgb(133,207,207)', 'rgb(245,217,140)'];
const COLOR_NAMES = ['Blue', 'Red', 'Green', 'Orange', 'Purple', 'Pink', 'Teal', 'Yellow'];

const PROFILES = [
  { name: 'Main', who: 'Mira Kaya', ini: 'M', color: 3, h: 72, c: .11, l: .56 },
  { name: 'Work', who: 'mira@studio', ini: 'W', color: 0, h: 255, c: .1, l: .5 },
  { name: 'Home', who: 'Mira', ini: 'H', color: 2, h: 152, c: .075, l: .5 },
  { name: 'Play', who: 'miraplays', ini: 'P', color: 5, h: 350, c: .095, l: .52 },
];

// Seeded pictures: ridgelines drawn in the page's own hue, so there is no image file to carry.
function rng(seed) { let a = seed >>> 0; return () => { a = (a + 0x6D2B79F5) >>> 0; let t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }
function art(seed, h, mood = 'day', bird = false) {
  const r = rng(seed), W = 1600, H = 740;
  const sky = mood === 'night' ? [`oklch(.25 .06 ${h})`, `oklch(.42 .1 ${h + 30})`] : mood === 'dusk' ? [`oklch(.72 .1 ${h + 30})`, `oklch(.9 .07 ${h - 20})`] : [`oklch(.8 .08 ${h})`, `oklch(.95 .045 ${h + 25})`];
  let s = `<svg class="art" viewBox="0 0 ${W} ${H}" preserveAspectRatio="xMidYMid slice" aria-hidden="true"><defs><linearGradient id="g${seed}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${sky[0]}"/><stop offset="1" stop-color="${sky[1]}"/></linearGradient></defs><rect width="${W}" height="${H}" fill="url(#g${seed})"/>`;
  const sx = 280 + r() * 1000, sy = 130 + r() * 150;
  s += `<circle cx="${sx}" cy="${sy}" r="${58 + r() * 30}" fill="${mood === 'night' ? `oklch(.92 .04 ${h})` : `oklch(.97 .05 ${h + 50})`}" opacity=".92"/>`;
  const layers = 5;
  for (let i = 0; i < layers; i++) {
    const base = H * (.42 + i * .11), amp = 60 - i * 7, f1 = .0016 + r() * .002, f2 = .004 + r() * .004, p1 = r() * 9, p2 = r() * 9;
    let d = `M0 ${H} L0 ${base}`;
    for (let x = 0; x <= W; x += 20) d += ` L${x} ${(base + Math.sin(x * f1 + p1) * amp + Math.sin(x * f2 + p2) * amp * .35).toFixed(1)}`;
    d += ` L${W} ${H} Z`;
    const L = mood === 'night' ? .3 - i * .04 : .72 - i * .115, C = .09 + i * .014;
    s += `<path d="${d}" fill="oklch(${L} ${C} ${h + i * 7})"/>`;
  }
  if (bird) s += `<g transform="translate(${W * .58} ${H * .3}) scale(1.6)" fill="oklch(.25 .04 ${h})"><path d="M-46 4c10-14 26-16 46-6 20-10 36-8 46 6-14-4-28-2-46 8-18-10-32-12-46-8z"/><path d="M-4 -4l4 -8 4 8-4 16z"/></g>`;
  return s + '</svg>';
}

// Pages. kind "article" has a Reader; "list" does not (as in the app, only a page with an article offers it).
const PAGES = {
  kestrel: { site: 'Field Guide', letter: 'F', host: 'fieldguide.example', path: '/birds/kestrel', kind: 'article', hue: 200, seed: 7, mood: 'day', bird: true,
    kick: 'Birds of open country', title: 'The kestrel hangs in the wind and waits',
    lede: 'A small falcon that can hold still in the air, eyes fixed on the ground, for as long as the wind lets it.',
    media: { type: 'video', cap: 'Kestrel over a hayfield · 0:21', file: 'kestrel-hover.mp4', mb: 21.4 },
    paras: ['Look along a motorway verge in the early afternoon and you will see it: a pale brown bird, wings quivering, tail fanned, apparently nailed to the sky. This is hovering, and the kestrel does it better than any other bird of prey in Europe.',
      'It is not effort the bird is spending on staying put. By facing into the wind and adjusting its wings a few degrees at a time, it holds its head almost perfectly still, which is what lets it see a vole move in the grass thirty metres below.',
      'Kestrels see ultraviolet light, and voles leave trails of urine that glow in it. A hunting kestrel is partly reading a map. It drops in short stages, hovering again at each, and only commits when the target stops moving.'],
    facts: [['Length', '31 to 37 cm'], ['Wingspan', '68 to 78 cm'], ['Weight', '136 to 252 g'], ['Eats', 'Voles, beetles'], ['Seen in', 'Open fields, verges']],
    related: ['How to tell a kestrel from a sparrowhawk', 'Where hovering kestrels hunt, by month', 'Nest boxes that work'] },
  tides: list('TideClock', 'T', 'tideclock.example', '/saint-malo', 'Saint-Malo, this week', 'Heights in metres, times local', 200, [
    ['H|High water|Mon 06:41|12.1 m'], ['L|Low water|Mon 12:58|1.8 m'], ['H|High water|Mon 19:04|12.4 m'], ['L|Low water|Tue 01:22|1.6 m'], ['H|High water|Tue 07:25|12.6 m']]),
  porto: { site: 'Rail Notes', letter: 'R', host: 'railnotes.example', path: '/night-train/porto', kind: 'article', hue: 28, seed: 21, mood: 'dusk',
    kick: 'Slow travel', title: 'Night train to Porto, and why the top bunk wins',
    lede: 'Sixteen hours, three countries, and one very good reason to bring your own pillow.',
    media: { type: 'photo', cap: 'The border at dawn', file: 'border-dawn.jpg', mb: 3.2 },
    paras: ['The sleeper leaves at nine in the evening and the whole point of it is that you do not have to be awake for most of it. By the time the carriage lights go to their dim setting you have already crossed one border without noticing.',
      'Take the top bunk. It costs the same, it is quieter, and the small window by your head is the best seat on the train when the light changes over the Spanish plateau at about six.',
      'Bring a pillow, a scarf, and food that does not smell. Bring a paper ticket as a backup, because the one thing the night train cannot forgive is a flat phone at the platform.'],
    facts: [['Departs', '21:04'], ['Arrives', '13:20 next day'], ['Changes', 'None'], ['Bunk', 'Top, by the window']],
    related: ['Seat map for the sleeper car', 'Hostels near Ribeira'] },
  seatmap: list('Rail Notes', 'R', 'railnotes.example', '/night-train/seat-map', 'Seat map, sleeper car', 'Compartments of four, top bunks marked', 28, [
    ['1|Compartment 1|2 free|Lower'], ['2|Compartment 2|1 free|Top'], ['3|Compartment 3|Full|None'], ['4|Compartment 4|3 free|Mixed']]),
  hostels: list('Stay Porto', 'S', 'stayporto.example', '/ribeira', 'Hostels near Ribeira', 'Under 30 euros a night', 28, [
    ['C|Casa do Rio|24 euros|0.3 km'], ['A|Alma Hostel|27 euros|0.5 km'], ['T|Terraço|22 euros|0.8 km']]),
  inbox: list('Mail', 'M', 'mail.example', '/inbox', 'Inbox', '3 unread', 255, [['M|Maya from the allotment|Seeds are in, come Saturday|08:12'], ['T|Tomás|Photos from the weekend|Yesterday'], ['R|Rail Notes|Your booking is confirmed|Mon']]),
  calendar: list('Calendar', 'C', 'calendar.example', '/week', 'This week', 'Nothing before ten', 255, [['M|Mon|Dentist|10:30'], ['W|Wed|Allotment, with Maya|17:00'], ['F|Fri|Train to Porto|21:04']]),
  notes: list('Notes', 'N', 'notes.example', '/all', 'Notes', '14 notes', 255, [['L|Packing list|Pillow, scarf, paper ticket|Today'], ['I|Birds seen|Kestrel, two buzzards|Sun'], ['B|Books|Three to start|Sat']]),
  roadmap: list('Roadmap', 'R', 'roadmap.example', '/q3', 'Q3 roadmap', 'Four things, in order', 52, [['1|Ship the quiet release|Done|Aug'], ['2|Reader typography|In review|Sep'], ['3|Profiles import|Planned|Sep'], ['4|Onboarding|Planned|Oct']]),
  board: list('Board', 'B', 'board.example', '/team', 'Team board', '11 cards open', 52, [['P|Pin sync bug|Mira|Today'], ['D|Docs for groups|Ali|Wed'], ['T|Tab tree lines|Mira|Thu']]),
  docs: list('Docs', 'D', 'docs.example', '/home', 'Docs', 'Recently edited', 52, [['S|Style notes|Edited 2 h ago|Mira'], ['R|Release checklist|Edited yesterday|Ali'], ['P|Press kit|Edited Mon|Sam']]),
  review: { site: 'Studio Notes', letter: 'S', host: 'studionotes.example', path: '/design-review', kind: 'article', hue: 52, seed: 33, mood: 'dusk',
    kick: 'Design review', title: 'What the review taught us about empty states',
    lede: 'Three rounds of feedback, one surprise: the quietest screens were the ones people talked about most.',
    media: { type: 'photo', cap: 'The wall after round two', file: 'review-wall.jpg', mb: 2.4 },
    paras: ['We expected the debate to be about the busy screens, the dashboards and the tables. It was about the empty ones. What a screen says when there is nothing on it is the first thing a new person ever reads.',
      'The fix was not more illustration. It was one plain sentence that says what will appear here and how to make it appear, followed by a single button. People stopped asking where to start.',
      'We kept the rule short enough to put on the wall: an empty state explains itself, offers one next step, and never apologises.'],
    facts: [['Rounds', '3'], ['People', '9'], ['Screens', '14'], ['Decision', 'One sentence, one button']], related: ['Release checklist', 'Changelog draft'] },
  checklist: list('Studio Notes', 'S', 'studionotes.example', '/release-checklist', 'Release checklist', '5 of 8 done', 52, [['✓|Update the notes|Done|Ali'], ['✓|Build from a clean clone|Done|Mira'], ['✓|Check the signature|Done|Mira'], ['8|Tell people|Open|Sam']]),
  changelog: { site: 'Studio Notes', letter: 'S', host: 'studionotes.example', path: '/changelog', kind: 'article', hue: 300, seed: 41, mood: 'day',
    kick: 'Changelog, draft', title: 'Version 0.9: groups that remember where you were',
    lede: 'Folded groups now stay folded between launches, and a tab opened from a link finds its place under its parent.',
    media: { type: 'photo', cap: 'Groups in the sidebar', file: 'groups.png', mb: .9 },
    paras: ['A group that you folded yesterday is folded today. It sounds like nothing and it is the thing people noticed first when they tried the build.',
      'Tabs opened from a link now sit under the tab they came from, with a line of the group colour down the tree. Closing one returns you to the tab you were on before.',
      'Also fixed: a pinned tab dragged into a group now unpins itself, instead of staying in two places at once.'],
    facts: [['Version', '0.9'], ['Status', 'Draft'], ['Reviewer', 'Ali']], related: ['Release checklist'] },
  recipes: list('Kitchen', 'K', 'kitchen.example', '/saved', 'Saved recipes', '23 saved', 152, [['S|Sourdough, week two|45 min hands-on|★ 4.8'], ['T|Tomato and bread soup|30 min|★ 4.6'], ['L|Lemon polenta cake|50 min|★ 4.9']]),
  maps: list('Maps', 'M', 'maps.example', '/saved', 'Saved places', '9 places', 152, [['A|Allotment|12 min by bike|Open'], ['B|Bakery on Elm|4 min walk|Closes 18:00'], ['P|Pool|20 min by bus|Open']]),
  radio: list('Radio', 'R', 'radio.example', '/now', 'Now playing', 'Quiet hours', 152, [['1|Slow morning|Ambient|Live'], ['2|Kitchen jazz|Instrumental|Live'], ['3|Rain on a tin roof|Sounds|Loop']]),
  sourdough: { site: 'Kitchen', letter: 'K', host: 'kitchen.example', path: '/sourdough/week-two', kind: 'article', hue: 75, seed: 55, mood: 'day',
    kick: 'Bread, week two', title: 'Sourdough, week two: it finally rises',
    lede: 'The starter doubled in four hours, and the loaf, for the first time, had an ear.',
    media: { type: 'photo', cap: 'Loaf number two, cooling', file: 'loaf-two.jpg', mb: 4.1 },
    paras: ['Last week the dough sat there like a wet sandbag. This week I fed the starter twice a day, kept it by the radiator, and waited until it smelled like green apples instead of nail polish.',
      'The change that mattered was patience in the first rise. Six hours, not four, with a fold every hour for the first three. The dough went from sticky to springy, and it held its shape on the board.',
      'Baked at 240 degrees in a covered pot for twenty minutes, then uncovered for twenty more. The ear, the little ridge along the score, opened and stayed open.'],
    facts: [['Flour', '500 g'], ['Water', '375 g'], ['Starter', '100 g'], ['Rise', '6 hours'], ['Bake', '240 °C, 40 min']], related: ['Tomato and bread soup', 'Saved recipes'] },
  tomatoes: { site: 'Kitchen', letter: 'K', host: 'kitchen.example', path: '/balcony-tomatoes', kind: 'article', hue: 25, seed: 61, mood: 'dusk',
    kick: 'Growing', title: 'Balcony tomatoes, and the one thing that matters',
    lede: 'It is not the soil and it is not the feed. It is the light, and where you put the pot.',
    media: { type: 'photo', cap: 'South wall, July', file: 'tomatoes.jpg', mb: 3.6 },
    paras: ['Four plants, one south-facing wall, and a summer where nothing ripened until August. The mistake was putting the pots against the wall, where the brick kept them in shade until noon.',
      'Moved forward by half a metre, the same plants had three more hours of sun. Fruit set within a week, and the leaves stopped curling.',
      'Water in the morning, never at night, and pinch the side shoots every Sunday. That is the whole method.'],
    facts: [['Plants', '4'], ['Pot', '20 litres'], ['Sun', '8 hours'], ['First ripe', '9 August']], related: ['Sourdough, week two'] },
  paint: list('Hardware', 'H', 'hardware.example', '/paint', 'Paint samples', 'For the hallway', 152, [['W|Warm white|Matt|12 euros'], ['S|Sage|Silk|14 euros'], ['C|Clay|Matt|14 euros']]),
  boxes: list('Hardware', 'H', 'hardware.example', '/boxes', 'Boxes and tape', 'Moving on the 14th', 152, [['B|Book boxes ×10|In stock|18 euros'], ['T|Brown tape ×6|In stock|7 euros'], ['M|Marker pens|In stock|4 euros']]),
  arcade: list('Arcade', 'A', 'arcade.example', '/daily', 'Daily puzzle', 'Resets at midnight', 350, [['1|Sliding tiles|Medium|2:41'], ['2|Word ladder|Easy|1:12'], ['3|Light switch|Hard|4:50']]),
  music: list('Music', 'M', 'music.example', '/library', 'Library', 'Recently played', 350, [['C|Chiptune weekly|Playlist|42 tracks'], ['S|Synth sketches|Album|11 tracks'], ['L|Lo-fi for coding|Playlist|60 tracks']]),
  chat: list('Chat', 'C', 'chat.example', '/rooms', 'Rooms', '2 unread', 350, [['J|jam-2026|3 new|11:02'], ['G|garden-devlog|Quiet|Mon'], ['H|hello|Quiet|Sun']]),
  pixel: { site: 'Pixel Garden', letter: 'P', host: 'pixelgarden.example', path: '/devlog/12', kind: 'article', hue: 330, seed: 77, mood: 'night', dark: true,
    kick: 'Devlog 12', title: 'The garden grows when you leave',
    lede: 'Plants now keep growing while the game is closed, and the first thing you see on return is what changed.',
    media: { type: 'video', cap: 'Offline growth, captured · 0:34', file: 'garden-growth.mp4', mb: 12.7 },
    paras: ['Until this week the garden waited for you. It felt dead, like a diorama. Now the game works out how long you have been away and grows each plant by that much, within a ceiling so nothing overruns the screen.',
      'On opening, a short banner lists the three biggest changes. People told us this was the part that made them want to come back the next day, so we made it skippable but never silent.',
      'Next up: weather. Rain will fill the pond faster, and a dry week will make the sunflowers lean.'],
    facts: [['Build', '0.12'], ['Platform', 'Browser'], ['Size', '3.1 MB'], ['Players', '412']], related: ['Chiptune weekly', 'Jam rules'] },
  chiptune: list('Music', 'M', 'music.example', '/chiptune', 'Chiptune weekly', '42 tracks', 350, [['1|Pocket sunrise|Nibble|2:48'], ['2|Level select|Quarter|3:05'], ['3|Boss, second phase|Nibble|2:31']]),
  jam: { site: 'Jam', letter: 'J', host: 'jam.example', path: '/2026/rules', kind: 'article', hue: 195, seed: 83, mood: 'day',
    kick: 'Game jam 2026', title: 'Jam rules: one theme, 72 hours, no excuses',
    lede: 'Make something small that you can finish. A finished small thing beats a large unfinished one every time.',
    media: { type: 'photo', cap: 'Last year\'s winning entry', file: 'jam-winner.png', mb: 1.2 },
    paras: ['The theme is announced at the start and stays secret until then. You may work alone or in a team of up to four, and you may use any engine, as long as the game runs in a browser.',
      'Everything you submit must be made during the jam, except tools and fonts that are free to use. Credit everything. A credits screen is not optional.',
      'Judging looks at three things: does it work, does it fit the theme, and is it fun for two minutes. In that order.'],
    facts: [['Length', '72 hours'], ['Team', 'Up to 4'], ['Runs in', 'A browser']], related: ['Sprite sheet'] },
  sprite: list('Jam', 'J', 'jam.example', '/assets/sprites', 'Sprite sheet', 'Free to use, credit required', 195, [['1|Hero, 16 frames|PNG|42 KB'], ['2|Tiles, grass|PNG|18 KB'], ['3|Coins and keys|PNG|9 KB']]),
};
function list(site, letter, host, path, title, sub, hue, rows) {
  return { site, letter, host, path, kind: 'list', hue, title, sub, rows: rows.map(r => r[0].split('|')) };
}

const T = (id, title, page, extra = {}) => ({ id, title, page, ...extra });
const FAV = { F: 'oklch(.55 .12 200)', T: 'oklch(.5 .12 230)', R: 'oklch(.52 .14 28)', S: 'oklch(.52 .13 52)', M: 'oklch(.5 .15 255)', C: 'oklch(.52 .14 300)', N: 'oklch(.55 .13 85)', B: 'oklch(.5 .14 160)', D: 'oklch(.5 .14 20)', K: 'oklch(.55 .13 75)', H: 'oklch(.5 .08 150)', A: 'oklch(.55 .17 350)', J: 'oklch(.5 .13 195)', P: 'oklch(.52 .17 330)' };
const favOf = pg => FAV[PAGES[pg].letter] || '#666';

function seed() {
  return [
    { tabs: [T('m-in', 'Inbox', 'inbox', { pinned: 1 }), T('m-cal', 'Calendar', 'calendar', { pinned: 1 }), T('m-no', 'Notes', 'notes', { pinned: 1 }),
      T('m-k', 'Kestrel, a field guide', 'kestrel'), T('m-t', 'Tide tables, Saint-Malo', 'tides'),
      T('m-p', 'Night train to Porto', 'porto', { group: 'trip' }), T('m-s', 'Seat map, sleeper car', 'seatmap', { group: 'trip', depth: 1 }), T('m-h', 'Hostels near Ribeira', 'hostels', { group: 'trip' })],
      groups: [{ id: 'trip', name: 'Trip', color: 2 }], sel: 'm-k' },
    { tabs: [T('w-r', 'Roadmap', 'roadmap', { pinned: 1 }), T('w-b', 'Board', 'board', { pinned: 1 }), T('w-d', 'Docs', 'docs', { pinned: 1 }),
      T('w-v', 'What the review taught us', 'review'), T('w-c', 'Release checklist', 'checklist', { group: 'launch' }), T('w-l', 'Changelog draft', 'changelog', { group: 'launch' })],
      groups: [{ id: 'launch', name: 'Launch', color: 4 }], sel: 'w-v' },
    { tabs: [T('h-r', 'Recipes', 'recipes', { pinned: 1 }), T('h-m', 'Maps', 'maps', { pinned: 1 }), T('h-ra', 'Radio', 'radio', { pinned: 1 }),
      T('h-s', 'Sourdough, week two', 'sourdough'), T('h-t', 'Balcony tomatoes', 'tomatoes'),
      T('h-p', 'Paint samples', 'paint', { group: 'move' }), T('h-b', 'Boxes and tape', 'boxes', { group: 'move' })],
      groups: [{ id: 'move', name: 'Move', color: 7 }], sel: 'h-s' },
    { tabs: [T('p-a', 'Arcade', 'arcade', { pinned: 1 }), T('p-m', 'Music', 'music', { pinned: 1 }), T('p-c', 'Chat', 'chat', { pinned: 1 }),
      T('p-g', 'Pixel garden, devlog 12', 'pixel'), T('p-ch', 'Chiptune weekly', 'chiptune'),
      T('p-j', 'Jam rules', 'jam', { group: 'jam' }), T('p-sp', 'Sprite sheet', 'sprite', { group: 'jam' })],
      groups: [{ id: 'jam', name: 'Jam', color: 6 }], sel: 'p-g' },
  ];
}

/* ------------------------------------------------------------------ */
/* State                                                               */
/* ------------------------------------------------------------------ */
const D = seed();
const S = {
  p: 0, mode: 'window', layout: 'both', pinSide: false, pinTop: false,
  side: false, top: false, menu: false, dlOpen: false, omni: false, ctx: null,
  reader: false, rTheme: 'light', rSans: false, rSize: 2, rWidth: 1,
  duskSetting: false, duskOff: new Set(), duskPause: false, awake: new Set(), peeked: false,
  stars: new Set(), split: null, touched: false, hint: true, dl: [], newTab: null, popPin: null,
};
const prof = () => D[S.p];
const tabById = id => prof().tabs.find(t => t.id === id);
const cur = () => tabById(prof().sel) || prof().tabs[0];
const page = () => PAGES[cur().page];

/* ------------------------------------------------------------------ */
/* Icons                                                               */
/* ------------------------------------------------------------------ */
const svg = p => `<svg viewBox="0 0 24 24" aria-hidden="true">${p}</svg>`;
const IC = {
  back: svg('<path d="m14.5 6-6 6 6 6"/>'), fwd: svg('<path d="m9.5 6 6 6-6 6"/>'),
  reload: svg('<path d="M19.5 12a7.5 7.5 0 1 1-2.4-5.5"/><path d="M19.5 4.5v4.2h-4.2"/>'),
  side: svg('<rect x="3.5" y="5" width="17" height="14" rx="3.2"/><path d="M9.5 5v14"/>'),
  pin: svg('<path d="m9 4 6 0 -1 5 3 3H7l3-3z"/><path d="M12 12v8"/>'),
  plus: svg('<path d="M12 5v14M5 12h14"/>'),
  glasses: svg('<circle cx="7" cy="14.5" r="3.4"/><circle cx="17" cy="14.5" r="3.4"/><path d="M10.4 14.5h3.2M3.7 14.5 5.3 7.5M20.3 14.5 18.7 7.5"/>'),
  reader: svg('<path d="M7 3.5h7l4 4V20a.5.5 0 0 1-.5.5h-10A.5.5 0 0 1 7 20z"/><path d="M10 12h5M10 16h5"/>'),
  half: svg('<circle cx="12" cy="12" r="7.6"/><path d="M12 4.4a7.6 7.6 0 0 1 0 15.2z" fill="currentColor"/>'),
  zzz: svg('<path d="M18.5 15.5A7 7 0 0 1 9 6a7 7 0 1 0 9.5 9.5z"/><path d="M14.5 3.5h4l-4 4h4"/>'),
  sun: svg('<circle cx="12" cy="12" r="3.8" fill="currentColor"/><path d="M12 3.5v2M12 18.5v2M3.5 12h2M18.5 12h2M6 6l1.4 1.4M16.6 16.6 18 18M18 6l-1.4 1.4M7.4 16.6 6 18"/>'),
  ublock: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="7.4" fill="#b3262d" stroke="none"/><path d="M8.6 12h6.8" stroke="#fff" stroke-width="2"/></svg>',
  dl: svg('<circle cx="12" cy="12" r="8.5"/><path d="M12 7.8v6.4M9 11.4l3 3 3-3"/>'),
  star: svg('<path d="m12 4.2 2.4 5 5.4.7-4 3.8 1 5.4-4.8-2.7-4.8 2.7 1-5.4-4-3.8 5.4-.7z"/>'),
  starOn: svg('<path d="m12 4.2 2.4 5 5.4.7-4 3.8 1 5.4-4.8-2.7-4.8 2.7 1-5.4-4-3.8 5.4-.7z" fill="currentColor"/>'),
  lock: svg('<rect x="6" y="11" width="12" height="8.5" rx="2.2"/><path d="M8.7 11V8.6a3.3 3.3 0 0 1 6.6 0V11"/>'),
  translate: svg('<path d="M4 6h8M8 4v2M5.5 6c.7 3 2.6 5.4 5 6.6M11 6c-.7 3-2.8 5.6-6 7"/><path d="m13.5 19 3.3-8 3.2 8M14.6 16.6h4.4"/>'),
  arrow: svg('<path d="M12 4.5v11M7.5 11 12 15.5 16.5 11M5.5 19.5h13"/>'),
  chev: svg('<path d="m6.5 9 5.5 5.5L17.5 9"/>'),
  file: svg('<path d="M7 4h7l4 4v12H7z"/><path d="M14 4v4h4"/>'),
  pause: svg('<path d="M9 6v12M15 6v12"/>'), cancel: svg('<path d="m7 7 10 10M17 7 7 17"/>'), find: svg('<circle cx="11" cy="11" r="6"/><path d="m16 16 4 4"/>'),
};
const ib = (icon, act, o = {}) => `<button class="ib${o.on ? ' on' : ''}${o.cls ? ' ' + o.cls : ''}" data-act="${act}"${o.id ? ` data-id="${o.id}"` : ''} aria-label="${esc(o.label || act)}"${o.off ? ' disabled' : ''}>${IC[icon]}${o.badge ? '<i class="badge"></i>' : ''}${o.ring ? '<i class="ring" id="dlRing"></i>' : ''}</button>`;

/* ------------------------------------------------------------------ */
/* DOM handles                                                         */
/* ------------------------------------------------------------------ */
const screen = $('#screen'), win = $('#win'), sb = $('#sb'), tb = $('#tb'), dlp = $('#dlp'), ctx = $('#ctx'), toastEl = $('#toast');
const pageEl = $('#page'), pageIn = $('#pageIn'), page2 = $('#page2'), pageIn2 = $('#pageIn2'), sdiv = $('#sdiv'), readerEl = $('#reader'), rtools = $('#readerTools'), pagehost = $('#pagehost');

/* ------------------------------------------------------------------ */
/* Rendering                                                           */
/* ------------------------------------------------------------------ */
const hostOnly = () => page().host;
const isArticle = () => page().kind === 'article';
const duskOffered = () => S.duskSetting;
const duskFor = P => S.duskSetting && !S.duskPause && !S.duskOff.has(P.host) && !P.dark;
const duskNow = () => duskFor(page());

function addrHTML() {
  return `<div class="addr"><button class="ib lock" data-act="info" aria-label="Site information">${IC.lock}</button><button class="host" data-act="omni" style="background:none;border:0;color:inherit;font:inherit;padding:0;min-width:0;cursor:text">${esc(hostOnly())}</button><button class="ib" data-act="tr" aria-label="Translate page">${IC.translate}</button>${ib('reload', 'reload', { label: 'Reload' })}</div>`;
}
function toolsHTML(ext = true) {
  const k = S.stars.has(cur().id), awake = S.awake.has(page().host);
  return (isArticle() || S.reader ? ib('reader', 'reader', { on: S.reader, label: S.reader ? 'Hide Reader' : 'Show Reader' }) : '') +
    (duskOffered() ? ib('half', 'duskmenu', { on: duskNow(), label: 'Dark pages', cls: 'dusk-btn' + (S.duskPause ? ' paused' : '') }) : '') +
    ib(awake ? 'sun' : 'zzz', 'awake', { label: awake ? 'Let this site sleep' : 'Keep this site awake', cls: awake ? 'awake-on' : '' }) +
    (ext ? `<button class="ib" data-act="ext" aria-label="uBlock Origin Lite">${IC.ublock}</button>` : '') +
    (S.dl.length || S.dlOpen ? ib('dl', 'dl', { on: S.dlOpen, label: 'Downloads', ring: true }) : '') +
    ib(k ? 'starOn' : 'star', 'star', { label: 'Bookmark', on: false, cls: k ? 'kept' : '' });
}
const fav = (pg, round) => `<span class="fav${round ? ' round' : ''}" style="--fc:${favOf(pg)}">${PAGES[pg].letter}</span>`;

const pairOf = id => S.split && id !== prof().sel && (id === S.split.a || id === S.split.b) ? ' pair' : '';
function tabRow(t) {
  const g = t.group ? prof().groups.find(x => x.id === t.group) : null;
  const gc = g ? ` style="--gc:${COLORS[g.color]}"` : '';
  return `<button class="tab${t.id === prof().sel ? ' sel' : ''}${pairOf(t.id)}${t.depth ? ' depth' + t.depth : ''}${S.newTab === t.id ? ' enter' : ''}" data-act="tab" data-id="${t.id}"${gc}>${fav(t.page, true)}<span class="t">${esc(t.title)}</span><span class="x" data-act="close" data-id="${t.id}" role="button" aria-label="Close tab">×</span></button>`;
}
function sidebarHTML() {
  const P = prof(), sideOnly = S.layout === 'side', pinned = P.tabs.filter(t => t.pinned), loose = P.tabs.filter(t => !t.pinned);
  let h = '';
  const newtabs = `<div style="display:flex">${ib('plus', 'omni', { label: 'New tab' })}${ib('glasses', 'private', { label: 'New private tab' })}</div>`;
  const pin = ib(S.pinSide ? 'side' : 'pin', 'pinside', { label: S.pinSide ? 'Hide sidebar when not in use' : 'Keep sidebar open' });
  if (sideOnly) {
    h += `<div class="sb-row"><div class="lights"><i></i><i></i><i></i></div>${ib('back', 'back', { off: 1, label: 'Back' })}${ib('fwd', 'fwd', { off: 1, label: 'Forward' })}<span style="flex:1"></span>${pin}</div>`;
    h += `<div class="sb-row">${addrHTML()}</div>`;
    h += `<div class="sb-row sp">${newtabs}<div style="display:flex">${toolsHTML(false)}</div></div>`;
  } else {
    h += `<div class="sb-row sp">${newtabs}${pin}</div>`;
  }
  h += `<div class="prof">${PROFILES.map((p, i) => `<button class="dot${i === S.p ? ' cur' : ''}" data-act="prof" data-id="${i}" style="--dc:${COLORS[p.color]}" aria-label="${p.name} profile"></button>`).join('')}<button class="plus" data-act="newprof" aria-label="New profile">+</button><span class="pname" style="--pc:${COLORS[PROFILES[S.p].color]}">${PROFILES[S.p].name}</span></div>`;
  if (pinned.length) h += `<div class="pins">${pinned.map(t => `<button class="pin${t.id === P.sel ? ' sel' : ''}${pairOf(t.id)}${S.popPin === t.id ? ' pop' : ''}" data-act="tab" data-id="${t.id}" aria-label="${esc(t.title)}" title="${esc(t.title)}">${fav(t.page)}</button>`).join('')}</div><div class="sb-sep"></div>`;
  h += `<button class="newtab" data-act="omni"><svg viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg>New Tab</button>`;
  h += '<div class="tabs">';
  const done = new Set();
  for (const t of loose) {
    if (!t.group) { h += tabRow(t); continue; }
    if (done.has(t.group)) continue; done.add(t.group);
    const g = P.groups.find(x => x.id === t.group), members = loose.filter(x => x.group === g.id);
    h += `<div class="grp${g.folded ? ' folded' : ''}" data-gid="${g.id}" style="--gc:${COLORS[g.color]}"><button class="grp-h" data-act="fold" data-id="${g.id}">${IC.chev}<span class="gn">${esc(g.name)}</span><span class="count">${members.length}</span></button><div class="grp-body"><div class="grp-in">${members.map(tabRow).join('')}<button class="newtab" data-act="newin" data-id="${g.id}"><svg viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg>New Tab</button></div></div></div>`;
  }
  h += '</div>';
  return h;
}
function topbarHTML() {
  const nb = S.mode === 'full';
  const nav = ib('back', 'back', { off: 1, label: 'Back' }) + ib('fwd', 'fwd', { off: 1, label: 'Forward' });
  if (nb) return `<div class="half l"><div class="lights"><i></i><i></i><i></i></div>${nav}<span class="sp"></span>${toolsHTML()}</div><div class="gap"></div><div class="half r">${addrHTML()}</div>`;
  return `<div class="lights"><i></i><i></i><i></i></div>${nav}<div class="mid">${addrHTML()}</div><div class="tools">${toolsHTML()}</div>`;
}
function dlHTML() {
  if (!S.dl.length) return `<h5>Downloads</h5><div class="dl-empty">Nothing yet. Hover a large photo or video on a listed site and press its button.</div>`;
  return `<h5>Downloads</h5>` + S.dl.map((d, i) => `<div class="dl-row" data-i="${i}"><div class="dl-ic">${IC.file}</div><div style="min-width:0"><div class="dl-name">${esc(d.name)}</div><div class="dl-meta"></div><div class="dl-bar"><i style="--p:${d.p}"></i></div></div><div class="dl-act"><button class="ib" data-act="dlpause" data-id="${i}" aria-label="Pause">${IC.pause}</button><button class="ib" data-act="dlx" data-id="${i}" aria-label="Cancel">${IC.cancel}</button></div></div>`).join('<div style="height:6px"></div>');
}
function renderSidebar() { sb.innerHTML = sidebarHTML(); S.newTab = null; S.popPin = null; }
function renderTop() { tb.innerHTML = topbarHTML(); }
function renderDl() { dlp.innerHTML = dlHTML(); paintDl(); }

function pageHTML(P) {
  const who = PROFILES[S.p];
  const head = `<div class="pg-head"><div class="pg-brand"><i>${P.letter}</i>${esc(P.site)}</div><nav><span>Latest</span><span>Guide</span><span>Maps</span><span>About</span></nav><div class="who">Signed in as ${esc(who.who)}<b>${who.ini}</b></div></div>`;
  if (P.kind === 'list') {
    return head + `<div class="pg-list"><h1>${esc(P.title)}</h1><p class="sub">${esc(P.sub)}</p><div class="rows">${P.rows.map(r => `<div class="r"><i>${esc(r[0])}</i><div><b>${esc(r[1])}</b><span>${esc(r[2])}</span></div><em>${esc(r[3])}</em></div>`).join('')}</div></div>`;
  }
  const m = P.media;
  const media = `<div class="media" id="media">${art(P.seed, P.hue, P.mood, P.bird)}<span class="cap">${esc(m.cap)}</span>${m.type === 'video' ? `<div class="play"><span class="pbtn"><svg viewBox="0 0 24 24"><path d="M7 4.5v15l13-7.5z"/></svg></span><span class="scrub"><i></i></span><span>0:08 / ${esc(m.cap.split('· ')[1] || '0:21')}</span></div>` : ''}<button class="dlb" data-act="dlb" aria-label="Save ${esc(m.type === 'video' ? 'this video' : 'this picture')}">${IC.arrow}</button></div>`;
  return head + `<div class="pg-main"><div><p class="pg-kick">${esc(P.kick)}</p><h1>${esc(P.title)}</h1><p class="pg-lede">${esc(P.lede)}</p>${media}<div class="pg-body">${P.paras.map(p => `<p>${esc(p)}</p>`).join('')}</div></div><aside class="pg-side"><div class="facts"><h3>At a glance</h3><dl>${P.facts.map(f => `<dt>${esc(f[0])}</dt><dd>${esc(f[1])}</dd>`).join('')}</dl></div><div class="related">${P.related.map(r => `<a>${esc(r)}</a>`).join('')}</div></aside></div><div style="height:90px"></div>`;
}
function drawPane(inner, P, swap) {
  inner.parentElement.style.setProperty('--ph', P.hue);
  inner.innerHTML = pageHTML(P);
  inner.scrollTop = 0;
  if (swap && !reduce) { inner.classList.remove('swap'); void inner.offsetWidth; inner.classList.add('swap'); }
}
const splitPage = k => PAGES[tabById(S.split[k]).page];
function renderPage(swap) {
  const P = S.split ? splitPage('a') : page();
  drawPane(pageIn, P, swap);
  if (S.split) drawPane(pageIn2, splitPage('b'), swap);
  applyDusk();
  if (!isArticle() && S.reader) S.reader = false;
  renderReader();
}
function applyDusk() {
  const A = S.split ? splitPage('a') : page();
  pageEl.classList.toggle('dusk', duskFor(A)); pageEl.classList.toggle('nd', !!A.dark);
  if (S.split) { const B = splitPage('b'); page2.classList.toggle('dusk', duskFor(B)); page2.classList.toggle('nd', !!B.dark); }
}
function renderReader() {
  const P = page();
  const open = S.reader && isArticle();
  readerEl.classList.toggle('open', open);
  readerEl.setAttribute('aria-hidden', open ? 'false' : 'true');
  rtools.hidden = !open;
  readerEl.dataset.th = S.rTheme;
  readerEl.classList.toggle('sans', S.rSans);
  const sizes = [18, 20, 22, 25, 29], widths = [600, 720, 860];
  readerEl.style.setProperty('--rs', sizes[S.rSize] + 'px');
  readerEl.style.setProperty('--rw', widths[S.rWidth] + 'px');
  if (isArticle()) {
    readerEl.innerHTML = `<div class="col"><h1>${esc(P.title)}</h1><p class="by">${esc(P.site)} · 4 min read</p><p>${esc(P.lede)}</p><figure class="rfig">${art(P.seed, P.hue, P.mood, P.bird)}</figure>${P.paras.map(p => `<p>${esc(p)}</p>`).join('')}</div>`;
    rtools.innerHTML = ['light', 'sepia', 'dark'].map(t => `<button class="th" data-act="rth" data-id="${t}" aria-pressed="${S.rTheme === t}" aria-label="${t} theme" style="background:${{ light: '#fbfbfa', sepia: '#f4ecd8', dark: '#19191b' }[t]}"></button>`).join('') + `<i></i><button data-act="rfont" aria-pressed="${S.rSans}" aria-label="Typeface" style="font-family:${S.rSans ? 'var(--mac)' : 'var(--serif)'}">${S.rSans ? 'Sans' : 'Serif'}</button><button data-act="rsm" aria-label="Smaller">A−</button><button data-act="rlg" aria-label="Larger">A+</button><button data-act="rw" aria-label="Width">Width ${S.rWidth + 1}/3</button><i></i><button data-act="reader" aria-label="Close Reader">✕</button>`;
  }
  syncChips();
}

/* ------------------------------------------------------------------ */
/* Layout classes: what is out, what is pinned                         */
/* ------------------------------------------------------------------ */
function apply() {
  const full = S.mode === 'full', both = S.layout === 'both';
  screen.classList.toggle('full', full);
  screen.classList.toggle('notch-bar', full && both);
  screen.classList.toggle('layout-side', !both);
  screen.classList.toggle('menu-down', full && S.menu);
  const topOut = both && (S.pinTop || S.top || S.dlOpen);
  const sideOut = S.pinSide || S.side || !!S.ctx || S.omni || (!both && S.dlOpen);
  win.classList.toggle('pin-side', S.pinSide);
  win.classList.toggle('pin-top', both && S.pinTop);
  win.classList.toggle('tb-open', topOut);
  sb.classList.toggle('out', sideOut);
  tb.classList.toggle('out', topOut);
  tb.classList.toggle('nb', full);
  screen.classList.toggle('tb-open', topOut);
  screen.classList.toggle('hint', S.hint && !sideOut && !topOut);
  screen.classList.toggle('show-top', both);
  tb.hidden = !both;
  dlp.classList.toggle('open', S.dlOpen);
  dlp.classList.toggle('beside', !both);
  $('#swSide').checked = S.pinSide; $('#swTop').checked = S.pinTop;
  $$('[data-mode]').forEach(b => b.setAttribute('aria-pressed', b.dataset.mode === S.mode));
  $$('[data-layout]').forEach(b => b.setAttribute('aria-pressed', b.dataset.layout === S.layout));
  $('#swTop').disabled = !both;
  positionDl();
}
function positionDl() {
  const both = S.layout === 'both', full = S.mode === 'full';
  if (both) { dlp.style.left = 'auto'; dlp.style.right = '12px'; dlp.style.top = (full ? 50 : 54) + (S.menu && full ? 37 : 0) + 'px'; dlp.style.transformOrigin = 'top right'; }
  else { dlp.style.right = 'auto'; dlp.style.left = '264px'; dlp.style.top = (full ? 44 : 44) + 'px'; dlp.style.transformOrigin = 'top left'; }
}
function fullRender() { renderSidebar(); renderTop(); renderReader(); applyDusk(); apply(); }

/* ------------------------------------------------------------------ */
/* Actions                                                             */
/* ------------------------------------------------------------------ */
let toastT;
function toast(html, ms = 3200, buttons = []) {
  toastEl.innerHTML = html + buttons.map((b, i) => `<button data-toast="${i}">${esc(b[0])}</button>`).join('');
  toastEl.classList.add('open');
  toastEl._b = buttons;
  clearTimeout(toastT); if (ms) toastT = setTimeout(() => toastEl.classList.remove('open'), ms);
}
toastEl.addEventListener('click', e => { const b = e.target.closest('[data-toast]'); if (!b) return; toastEl._b[+b.dataset.toast][1](); toastEl.classList.remove('open'); });

function paint(i) { const p = PROFILES[i]; root.style.setProperty('--h', p.h); root.style.setProperty('--c', p.c); root.style.setProperty('--l', p.l); root.dataset.profile = p.name; }
function setProfile(i, quiet) {
  const was = !!S.split; if (was) endSplit(true);
  if (i === S.p) { if (was) { renderPage(false); renderSidebar(); renderTop(); apply(); syncSiteDots(); syncChips(); } return; }
  S.p = i;
  paint(i);
  S.reader = false; closeCtx(); S.omni = false; omniEl.classList.remove('open');
  renderSidebar(); renderTop(); renderPage(true); apply(); syncSiteDots(); tintPulse(i);
  document.querySelector('meta[name=theme-color]').content = getComputedStyle(root).getPropertyValue('--brand') || '#3b5bdb';
}
function tintPulse(i) {
  const sec = $('.stage-sec'); if (!sec || reduce) return;
  const el = document.createElement('i'); el.className = 'pulse'; el.style.setProperty('--pc', `oklch(.84 ${PROFILES[i].c * .95} ${PROFILES[i].h})`);
  sec.appendChild(el); setTimeout(() => el.remove(), 1500);
}
/* Split view: two tabs side by side, a divider to drag, a frame round the half that has the keyboard.
   In the app both halves are one profile's. Here each half also wears a colour, so the page can show which one you are in. */
function startSplit(id) {
  const P = prof(); if (!id || id === P.sel) { toast('Pick another tab to put beside this one.', 2200); return; }
  if (S.split) endSplit(true);
  S.reader = false;
  S.split = { a: P.sel, b: id, focus: 'a', l: S.p, r: (S.p + 1) % PROFILES.length };
  syncSplit(); renderPage(false); renderReader(); renderSidebar(); renderTop(); apply(); syncSiteDots(); syncChips();
  tintPulse(S.split.r);
}
function focusSplit(which) {
  const sp = S.split; if (!sp || sp.focus === which) return;
  sp.focus = which; prof().sel = sp[which];
  paint(which === 'a' ? sp.l : sp.r); tintPulse(which === 'a' ? sp.l : sp.r);
  syncSplit(); renderSidebar(); renderTop(); apply(); syncSiteDots();
}
function endSplit(quiet) {
  if (!S.split) return;
  S.split = null; syncSplit(); paint(S.p);
  if (!quiet) { renderPage(false); renderSidebar(); renderTop(); apply(); syncSiteDots(); syncChips(); }
}
function syncSplit() {
  const sp = S.split, L = sp && PROFILES[sp.l], R = sp && PROFILES[sp.r];
  pagehost.classList.toggle('twopane', !!sp); pagehost.dataset.focus = sp ? sp.focus : '';
  root.classList.toggle('twin', !!sp);
  if (sp) { root.style.setProperty('--hl', L.h); root.style.setProperty('--cl', L.c); root.style.setProperty('--hr', R.h); root.style.setProperty('--cr', R.c); }
  page2.hidden = !sp; sdiv.hidden = !sp; $('#sframe').hidden = !sp;
}
(() => {
  let drag = false;
  const move = e => { const r = pagehost.getBoundingClientRect(); const v = Math.min(.8, Math.max(.2, (e.clientX - r.left) / r.width)); pagehost.style.setProperty('--sr', v); };
  sdiv.addEventListener('pointerdown', e => { drag = true; sdiv.setPointerCapture(e.pointerId); pagehost.classList.add('dragging'); bump(); e.preventDefault(); });
  sdiv.addEventListener('pointermove', e => { if (drag) move(e); });
  const up = () => { drag = false; pagehost.classList.remove('dragging'); };
  sdiv.addEventListener('pointerup', up); sdiv.addEventListener('pointercancel', up);
  pagehost.addEventListener('pointerdown', e => { if (!S.split) return; const w = e.target.closest('#page2') ? 'b' : e.target.closest('#page') ? 'a' : null; if (w) { bump(); focusSplit(w); } });
})();
function selectTab(id) {
  if (S.split) { if (id === S.split.a || id === S.split.b) { focusSplit(id === S.split.a ? 'a' : 'b'); return; } endSplit(true); }
  const P = prof(); if (P.sel === id) return;
  P.sel = id; S.reader = false; closeCtx();
  renderSidebar(); renderTop(); renderPage(true); apply();
}
function closeTab(id) {
  const P = prof(), i = P.tabs.findIndex(t => t.id === id); if (i < 0) return;
  if (P.tabs.length <= 1) return;
  if (S.split && (id === S.split.a || id === S.split.b)) endSplit(true);
  const t = P.tabs[i]; P.tabs.splice(i, 1);
  if (P.sel === id) { const n = P.tabs[Math.max(0, i - 1)]; P.sel = n.id; renderPage(true); }
  renderSidebar(); renderTop(); apply();
}
function togglePin(id) {
  const t = tabById(id); t.pinned = t.pinned ? 0 : 1; if (t.pinned) { t.group = null; t.depth = 0; S.popPin = id; }
  // pinned tiles first, in the order they were pinned; the rest keep theirs
  const P = prof(); P.tabs = [...P.tabs.filter(x => x.pinned && x.id !== id), ...(t.pinned ? [t] : []), ...P.tabs.filter(x => !x.pinned && x.id !== id)];
  if (!t.pinned) { const at = P.tabs.findIndex(x => !x.pinned); P.tabs.splice(at < 0 ? P.tabs.length : at, 0, t); }
  P.tabs = [...P.tabs.filter(x => x.pinned), ...P.tabs.filter(x => !x.pinned)];
  renderSidebar(); apply(); toast(t.pinned ? `Pinned “${esc(t.title)}”. It is a tile now.` : `Unpinned “${esc(t.title)}”.`, 2200);
}
function addToGroup(id, gid) {
  const P = prof(), t = tabById(id);
  if (gid === '__new') {
    const used = new Set(P.groups.map(g => g.color)); const color = [...COLORS.keys()].find(c => !used.has(c)) ?? 0;
    const g = { id: 'g' + Date.now(), name: ['Reading', 'Ideas', 'Later', 'Errands'][P.groups.length % 4], color }; P.groups.push(g); gid = g.id;
  }
  t.group = gid; t.pinned = 0; t.depth = 0;
  const rest = P.tabs.filter(x => x.id !== id), last = rest.map(x => x.group).lastIndexOf(gid);
  rest.splice(last < 0 ? rest.length : last + 1, 0, t); P.tabs = [...rest.filter(x => x.pinned), ...rest.filter(x => !x.pinned)];
  renderSidebar(); apply();
}
function removeFromGroup(id) { const t = tabById(id); t.group = null; t.depth = 0; renderSidebar(); apply(); }

/* context menu */
function openCtx(id, x, y) {
  const P = prof(), t = tabById(id); S.ctx = id;
  const groups = P.groups.map(g => `<button data-act="cgrp" data-id="${g.id}"><span><i class="sw-c" style="background:${COLORS[g.color]}"></i>${esc(g.name)}</span></button>`).join('');
  ctx.innerHTML = `<button data-act="cpin"><span>${t.pinned ? 'Unpin Tab' : 'Pin Tab'}</span></button>` +
    (t.pinned ? '' : `<div class="has"><button><span>Add to Group</span><span>›</span></button><div class="sub glass"><button data-act="cgrp" data-id="__new"><span>New Group</span></button>${groups ? '<hr>' + groups : ''}${t.group ? `<hr><button data-act="cungrp"><span>Remove from Group</span></button>` : ''}</div></div>`) +
    `<hr><button data-act="cside"><span>Open Side by Side</span></button><hr><button data-act="cclose"><span>Close Tab</span></button>`;
  const r = win.getBoundingClientRect(), k = kNow();
  ctx.style.left = Math.min(x, r.width / k - 230) + 'px'; ctx.style.top = Math.min(y, r.height / k - 190) + 'px';
  ctx.classList.add('open'); apply();
}
function closeCtx() { if (!S.ctx) return; S.ctx = null; ctx.classList.remove('open'); if (S.peeked) { S.peeked = false; if (!S.pinSide) S.side = false; } apply(); }

/* a small menu at a button, the way the dark pages button has one */
function openMenu(items, el) {
  S.ctx = 'menu';
  ctx.innerHTML = items.map(i => i === '-' ? '<hr>' : `<button data-act="${i[1]}"><span>${esc(i[0])}</span><span style="opacity:.55">${i[2] || ''}</span></button>`).join('');
  const r = el.getBoundingClientRect(), w = win.getBoundingClientRect(), k = kNow();
  ctx.style.left = Math.min((r.left - w.left) / k - 150, w.width / k - 330) + 'px'; ctx.style.top = (r.bottom - w.top) / k + 6 + 'px';
  ctx.classList.add('open'); apply();
}

/* new-tab field */
const omniEl = document.createElement('div');
omniEl.className = 'omni glass'; omniEl.innerHTML = `<input id="omniIn" type="text" placeholder="Search or enter address" autocomplete="off" spellcheck="false" aria-label="Search or enter address"><ul id="omniList"></ul>`;
win.appendChild(omniEl);
const HISTORY = [['Github notifications', 'code.example'], ['Pixel art tutorial', 'pixelgarden.example'], ['Kestrel nest box plans', 'fieldguide.example'], ['Bread flour, 25 kg', 'kitchen.example']];
function fuzzy(q, s) { q = q.toLowerCase().replace(/\s+/g, ''); s = s.toLowerCase(); let i = 0; for (const ch of s) if (ch === q[i]) i++; return i === q.length; }
function omniList() {
  const q = $('#omniIn').value.trim(), items = [];
  D[S.p].tabs.forEach(t => items.push({ k: 'Tab', title: t.title, sub: PAGES[t.page].host, id: t.id, pg: t.page }));
  HISTORY.forEach(h => items.push({ k: 'History', title: h[0], sub: h[1], pg: 'kestrel' }));
  const res = (q ? items.filter(it => fuzzy(q, it.title) || fuzzy(q, it.sub)) : items.filter(i => i.k === 'Tab')).slice(0, 6);
  $('#omniList').innerHTML = res.length ? res.map((r, i) => `<li><button data-act="omnipick" data-id="${r.id || ''}"><span class="fav round" style="--fc:${r.id ? favOf(r.pg) : '#666'}">${(r.title[0] || '').toUpperCase()}</span><span class="ot">${esc(r.title)}</span><span class="os">${esc(r.sub)}</span><em>${r.k}</em></button></li>`).join('') : `<li class="empty">Press Return to search for “${esc(q)}”</li>`;
}
function openOmni() { S.omni = true; omniEl.classList.add('open'); $('#omniIn').value = ''; omniList(); apply(); setTimeout(() => $('#omniIn').focus({ preventScroll: true }), 30); }
function closeOmni() { S.omni = false; omniEl.classList.remove('open'); $('#omniIn').blur(); apply(); }
$('#omniIn').addEventListener('input', omniList);
$('#omniIn').addEventListener('keydown', e => { if (e.key === 'Escape') { closeOmni(); e.stopPropagation(); } if (e.key === 'Enter') { const first = $('#omniList button'); if (first && first.dataset.id) { closeOmni(); selectTab(first.dataset.id); } else { closeOmni(); toast('In the browser this would search or open the address.', 2400); } } });

/* downloads, driven by the clock so that slow motion slows it */
let dlRaf = 0;
function startDownload() {
  const m = page().media; if (!m) return;
  const speed = 3.1 + Math.random() * .6;
  S.dl.unshift({ name: m.file, size: m.mb, p: 0, state: 'run', t: 0, speed, done: false });
  S.dlOpen = true; renderTop(); renderSidebar(); renderDl(); apply();
  cancelAnimationFrame(dlRaf); let last = performance.now();
  const tick = now => {
    const dt = Math.min(.1, (now - last) / 1000) / (slow() ? 3 : 1); last = now;
    let any = false;
    for (const d of S.dl) if (d.state === 'run') { d.p = Math.min(100, d.p + (d.speed * dt / d.size) * 100 * (reduce ? 8 : 2.2)); if (d.p >= 100) { d.state = 'done'; finishDl(d); } else any = true; }
    paintDl();
    if (any) dlRaf = requestAnimationFrame(tick);
  };
  dlRaf = requestAnimationFrame(tick);
}
function paintDl() {
  const run = S.dl.find(d => d.state === 'run');
  $$('#dlRing').forEach(r => { r.style.setProperty('--p', run ? run.p : 0); r.classList.toggle('on', !!run); });
  $$('.dl-row', dlp).forEach(row => {
    const d = S.dl[+row.dataset.i]; if (!d) return;
    row.querySelector('.dl-bar i').style.setProperty('--p', d.p);
    const got = d.size * d.p / 100, eta = Math.max(0, Math.ceil((d.size - got) / d.speed / (reduce ? 8 : 2.2) * 2.2));
    row.querySelector('.dl-meta').textContent = d.state === 'done' ? `${d.size.toFixed(1)} MB · Done` : d.state === 'pause' ? `${got.toFixed(1)} of ${d.size.toFixed(1)} MB · Paused` : `${got.toFixed(1)} of ${d.size.toFixed(1)} MB · ${d.speed.toFixed(1)} MB/s · ${eta} s left`;
  });
}
function finishDl(d) {
  toast(`<span>Saved <b>${esc(d.name)}</b> to Downloads</span>`, 3600, [['Show in Finder', () => { }]]);
  setTimeout(() => { if (!dlp.matches(':hover')) { S.dlOpen = false; apply(); } }, reduce ? 300 : 2600);
}
const slow = () => $('#swSlow').checked;

/* ------------------------------------------------------------------ */
/* Events on the demo                                                  */
/* ------------------------------------------------------------------ */
const kNow = () => parseFloat(screen.style.getPropertyValue('--k')) || .7;
function bump() { if (S.hint) { S.hint = false; apply(); } S.touched = true; }

win.addEventListener('click', e => {
  const a = e.target.closest('[data-act]');
  if (!a) {
    if (e.target.closest('.ctx') || e.target.closest('.omni')) return;
    if (S.ctx) closeCtx();
    if (S.omni && !e.target.closest('.omni')) closeOmni();
    if (e.target.closest('#pagehost') && !e.target.closest('.reader-tools')) { if (S.side && !S.pinSide) { S.side = false; } if (S.top && !S.pinTop) { S.top = false; } if (S.dlOpen && !e.target.closest('.dlb')) S.dlOpen = false; apply(); }
    return;
  }
  bump();
  if (S.ctx && !a.closest('.ctx')) closeCtx();
  const id = a.dataset.id;
  switch (a.dataset.act) {
    case 'tab': selectTab(id); break;
    case 'close': e.stopPropagation(); closeTab(id); break;
    case 'prof': setProfile(+id); break;
    case 'newprof': toast('A new profile gets a name and a colour in the app.', 2400); break;
    case 'fold': { const g = prof().groups.find(x => x.id === id); g.folded = !g.folded; a.closest('.grp').classList.toggle('folded', g.folded); break; }
    case 'pinside': S.pinSide = !S.pinSide; S.side = true; renderSidebar(); apply(); break;
    case 'pintop': S.pinTop = !S.pinTop; apply(); break;
    case 'reader': if (S.split) endSplit(true); S.reader = !S.reader; renderTop(); renderSidebar(); renderReader(); apply(); break;
    case 'private': toast('A private tab keeps nothing: its cookies stay in memory and go when the app quits.', 3000); break;
    case 'ext': toast('uBlock Origin Lite: its button turns it off for this site.', 2600); break;
    case 'awake': { const h = page().host; S.awake.has(h) ? S.awake.delete(h) : S.awake.add(h); renderTop(); renderSidebar(); apply(); toast(S.awake.has(h) ? `${esc(h)} is kept awake.` : `${esc(h)} may sleep again.`, 2200); break; }
    case 'duskmenu': { const h = page().host; openMenu(S.duskPause ? [['Darken light pages again', 'duskpause', '⌥⇧⌘D']] : [[S.duskOff.has(h) || page().dark ? `Darken ${h}` : `Leave ${h} as it is`, 'dusksite', '⇧⌘D'], ['Pause dark pages everywhere', 'duskpause', '⌥⇧⌘D']], a); break; }
    case 'dusksite': closeCtx(); toggleDusk(); break;
    case 'duskpause': closeCtx(); S.duskPause = !S.duskPause; refreshDusk(); toast(S.duskPause ? 'Dark pages are paused everywhere.' : 'Dark pages are back.', 2200); break;
    case 'rth': S.rTheme = id; renderReader(); break;
    case 'rfont': S.rSans = !S.rSans; renderReader(); break;
    case 'rsm': S.rSize = Math.max(0, S.rSize - 1); renderReader(); break;
    case 'rlg': S.rSize = Math.min(4, S.rSize + 1); renderReader(); break;
    case 'rw': S.rWidth = (S.rWidth + 1) % 3; renderReader(); break;
    case 'dl': S.dlOpen = !S.dlOpen; if (S.dlOpen) renderDl(); apply(); break;
    case 'dlb': e.stopPropagation(); startDownload(); break;
    case 'dlpause': { const d = S.dl[+id]; if (d.state === 'run') { d.state = 'pause'; } else if (d.state === 'pause') { d.state = 'run'; resume(); } paintDl(); break; }
    case 'dlx': S.dl.splice(+id, 1); renderDl(); paintDl(); break;
    case 'star': { const k = cur().id; S.stars.has(k) ? S.stars.delete(k) : S.stars.add(k); renderTop(); renderSidebar(); apply(); toast(S.stars.has(k) ? 'Bookmarked.' : 'Bookmark removed.', 1600); break; }
    case 'omni': openOmni(); break;
    case 'omnipick': closeOmni(); if (id) selectTab(id); else toast('In the browser this would open the page.', 2000); break;
    case 'newin': { const g = id, n = { id: 'n' + Date.now(), title: 'New tab', page: 'kestrel', group: g }; toast('In the browser this opens a field over the page.', 2200); break; }
    case 'cpin': { const t = S.ctx; closeCtx(); togglePin(t); break; }
    case 'cgrp': { const t = S.ctx; closeCtx(); addToGroup(t, id); break; }
    case 'cungrp': { const t = S.ctx; closeCtx(); removeFromGroup(t); break; }
    case 'cclose': { const t = S.ctx; closeCtx(); closeTab(t); break; }
    case 'cside': { const t = S.ctx; closeCtx(); startSplit(t); break; }
    case 'info': toast('The lock shows the certificate, what the site may do, and what it keeps.', 2600); break;
    case 'tr': toast('Translate Page: the system\'s own translation, on this Mac.', 2600); break;
    case 'reload': renderPage(true); break;
  }
});
function resume() { if (S.dl.some(d => d.state === 'run')) { const d = S.dl.find(x => x.state === 'run'); startDownloadLoop(); } }
function startDownloadLoop() {
  cancelAnimationFrame(dlRaf); let last = performance.now();
  const tick = now => { const dt = Math.min(.1, (now - last) / 1000) / (slow() ? 3 : 1); last = now; let any = false;
    for (const d of S.dl) if (d.state === 'run') { d.p = Math.min(100, d.p + (d.speed * dt / d.size) * 100 * (reduce ? 8 : 2.2)); if (d.p >= 100) { d.state = 'done'; finishDl(d); } else any = true; }
    paintDl(); if (any) dlRaf = requestAnimationFrame(tick); };
  dlRaf = requestAnimationFrame(tick);
}
function closeSoon() { S.side = false; if (!S.pinSide) apply(); }
function refreshDusk() { applyDusk(); renderTop(); renderSidebar(); apply(); syncChips(); }
function toggleDusk() {
  if (!S.duskSetting) return toast('Dark pages are off. Settings › General turns them on.', 2600);
  const P = page();
  if (P.dark) return duskNote();
  if (S.duskPause) S.duskPause = false; else if (S.duskOff.has(P.host)) S.duskOff.delete(P.host); else S.duskOff.add(P.host);
  refreshDusk(); duskNote();
}
function setDuskSetting(on) {
  S.duskSetting = on; if (on) { S.duskOff.delete(page().host); S.duskPause = false; }
  refreshDusk(); if (on) duskNote(); else toast('Dark pages are off in Settings.', 2200);
}
function duskNote() {
  const P = page();
  if (P.dark) return toast('This page is dark already, so it is left as it is.', 2800);
  if (duskNow()) toast(`<span class="q">Dark pages on for</span> ${esc(P.host)}`, 5200, [['Off for this site', () => { S.duskOff.add(P.host); refreshDusk(); }], ['Pause everywhere', () => { S.duskPause = true; refreshDusk(); }]]);
  else toast(S.duskPause ? 'Dark pages are paused everywhere.' : `Dark pages off for ${esc(P.host)}.`, 2200);
}
$('#screen').addEventListener('contextmenu', e => {
  const t = e.target.closest('.tab,.pin'); if (!t) return;
  e.preventDefault(); bump();
  const r = win.getBoundingClientRect(), k = kNow();
  openCtx(t.dataset.id, (e.clientX - r.left) / k, (e.clientY - r.top) / k);
});
// the demo's own keys, only while the pointer is over it
let over = false;
$('#screen').addEventListener('pointerenter', () => over = true);
$('#screen').addEventListener('pointerleave', () => over = false);
addEventListener('keydown', e => {
  if (!over) return;
  const k = e.key.toLowerCase();
  if (e.key === 'Escape') { if (S.reader) { S.reader = false; renderReader(); renderTop(); renderSidebar(); } closeCtx(); if (S.omni) closeOmni(); return; }
  if ((e.metaKey || e.ctrlKey) && e.shiftKey && k === 'd') { e.preventDefault(); toggleDusk(); }
  if ((e.metaKey || e.ctrlKey) && e.altKey && (k === 'r' || k === '®')) { e.preventDefault(); if (isArticle()) { S.reader = !S.reader; renderReader(); renderTop(); renderSidebar(); apply(); } }
});

/* The edges: the pointer at the left edge brings the sidebar, at the top the address; leaving takes them back. */
const TM = { show: {}, hide: {}, menu: 0 };
function schedule(which, on, delay) {
  const same = on ? TM.show : TM.hide, opp = on ? TM.hide : TM.show;
  clearTimeout(opp[which]); opp[which] = 0;
  if (!!S[which] === on || same[which]) return;
  same[which] = setTimeout(() => { same[which] = 0; S[which] = on; if (!on && which === 'top') S.menu = false; apply(); }, delay * (slow() ? 3 : 1));
}
const cancel = (which, kind) => { clearTimeout(TM[kind][which]); TM[kind][which] = 0; };
win.addEventListener('pointermove', e => {
  if (e.pointerType === 'touch') return;
  const r = win.getBoundingClientRect(), k = kNow(), x = (e.clientX - r.left) / k, y = (e.clientY - r.top) / k, w = r.width / k;
  const both = S.layout === 'both', full = S.mode === 'full';
  if (x <= 6 && y >= 0) { bump(); schedule('side', true, 120); }
  else { cancel('side', 'show'); if (S.side && !S.pinSide && !S.omni && !S.ctx) { if (x > 250 + 6 + 24) schedule('side', false, 120); else cancel('side', 'hide'); } }
  if (both) {
    if (y <= 6) { bump(); schedule('top', true, 120); }
    else { cancel('top', 'show'); if (S.top && !S.pinTop && !S.dlOpen) { if (y > 46 + 24 + (S.menu ? 37 : 0)) schedule('top', false, 120); else cancel('top', 'hide'); } }
  }
  // pressed against the very top of a full screen: macOS's own menu bar comes down over the bar
  if (full) {
    if (y <= 1.5) { if (!TM.menu && !S.menu) TM.menu = setTimeout(() => { S.menu = true; TM.menu = 0; apply(); }, 420 * (slow() ? 3 : 1)); }
    else { clearTimeout(TM.menu); TM.menu = 0; if (S.menu && y > 37.5 + 46 + 20) { S.menu = false; apply(); } }
  }
});
win.addEventListener('pointerleave', e => { if (e.pointerType === 'touch') return; clearTimeout(TM.menu); TM.menu = 0; if (S.omni || S.ctx) return; if (!S.pinSide) schedule('side', false, 120); if (!S.pinTop) schedule('top', false, 120); if (S.menu) { S.menu = false; apply(); } });
$('#handleL').addEventListener('click', () => { bump(); S.side = !S.side; apply(); });
$('#handleT').addEventListener('click', () => { bump(); S.top = !S.top; apply(); });

/* ------------------------------------------------------------------ */
/* Controls under the laptop                                           */
/* ------------------------------------------------------------------ */
const CAP = {
  start: ['A working model of the browser. Move to the left edge of the screen, or pick something to try.'],
  edges: ['The sidebar comes out of the left edge as glass, and the top edge brings the address down. Neither takes room until you want it.'],
  profiles: ['Each profile has its own sign-ins, tabs, history and bookmarks. Notice that this whole page takes the color of the profile you are in.'],
  tabs: ['Pinned tabs are tiles. Right-click a tab to pin it or add it to a group. Tabs opened from a link sit under the one they came from.'],
  reader: ['Reader, on ⌥⌘R: just the article, in light, sepia or dark. Only a page that has an article offers it.'],
  dusk: ['Dark pages, on ⇧⌘D once turned on in Settings: a page that stays white while macOS is dark gets dark colors. A page that is dark already is left alone.'],
  save: ['On the sites you list, the download button comes up over a large photo or video. It also joins videos that a site sends in pieces.'],
  split: ['Right-click a tab, then Open Side by Side. Drag the divider; the framed half has the keyboard, and the address follows it. In the app both halves share a profile, but here the second gets its own color so you can tell them apart.'],
  window: ['A window with the page across all of it. The menu bar and the Dock are macOS\'s own.'],
  full: ['Full screen on a Mac with a notch: the top bar runs around it, with the clock on glass at the far end. Press against the very top and macOS\'s menu bar comes down.'],
  both: ['Top and side bars: the sidebar holds the tabs, the top bar the address and the site\'s buttons. Each comes out at its edge.'],
  side: ['Sidebar only, how a new install starts: back, forward, the site and its buttons sit above the tabs, and a click on the site shows its whole address.'],
};
function caption(key) { $('#capText').textContent = CAP[key][0]; }
function syncChips() { $$('.chip[data-preset=reader]').forEach(c => c.setAttribute('aria-pressed', S.reader)); $$('.chip[data-preset=dusk]').forEach(c => c.setAttribute('aria-pressed', S.duskSetting)); $$('.chip[data-preset=split]').forEach(c => c.setAttribute('aria-pressed', !!S.split)); }
/* a bar shown for a moment, so that a button in it can be seen */
function peek(which, ms = 2200) { if (which === 'top' && S.layout !== 'both') which = 'side'; S[which] = true; apply(); setTimeout(() => { if (which === 'side' ? !S.pinSide : !S.pinTop) { S[which] = false; apply(); } }, ms * (slow() ? 3 : 1)); }
let runId = 0;
async function preset(key) {
  const my = ++runId; const live = () => my === runId;
  const chip = $(`[data-preset=${key}]`); if (chip && !['reader', 'dusk', 'split'].includes(key)) { chip.classList.remove('ran'); void chip.offsetWidth; chip.classList.add('ran'); }
  caption(key); S.hint = false; closeCtx(); if (S.omni) closeOmni(); toastEl.classList.remove('open');
  const article = () => prof().tabs.find(t => PAGES[t.page].kind === 'article');
  if (key === 'edges') {
    S.reader = false; renderReader(); syncChips();
    S.side = true; apply(); await sleep(1700); if (!live()) return; if (!S.pinSide) S.side = false; apply(); await sleep(500);
    if (!live() || S.layout !== 'both') return; S.top = true; apply(); await sleep(1700); if (!live()) return; if (!S.pinTop) S.top = false; apply(); S.hint = true; apply();
  } else if (key === 'profiles') {
    if (!S.pinSide) { S.side = true; apply(); } await sleep(700);
    for (const i of [1, 2, 3, 0, 1]) { if (!live()) return; setProfile(i); await sleep(1400); }
    if (live() && !S.pinSide) { S.side = false; apply(); }
  } else if (key === 'tabs') {
    S.reader = false; renderReader(); syncChips();
    const t = prof().tabs.find(x => !x.pinned && !x.group); if (!t) return;
    if (!S.pinSide) { S.side = true; S.peeked = true; apply(); } await sleep(700); if (!live()) return;
    const r = sb.querySelector(`[data-id="${t.id}"]`).getBoundingClientRect(), wr = win.getBoundingClientRect(), k = kNow();
    openCtx(t.id, (r.left - wr.left) / k + 120, (r.top - wr.top) / k + 22);
    await sleep(500); if (!live() || !S.ctx) return; ctx.querySelector('.has')?.classList.add('hov');
  } else if (key === 'split') {
    if (S.split) { endSplit(); return; }
    S.reader = false; renderReader(); syncChips();
    const P = prof(), t = P.tabs.find(x => !x.pinned && !x.group && x.id !== P.sel) || P.tabs.find(x => !x.pinned && x.id !== P.sel) || P.tabs.find(x => x.id !== P.sel);
    if (!S.pinSide) { S.side = true; S.peeked = true; apply(); } await sleep(700); if (!live()) return;
    const r = sb.querySelector(`[data-id="${t.id}"]`).getBoundingClientRect(), wr = win.getBoundingClientRect(), k = kNow();
    openCtx(t.id, (r.left - wr.left) / k + 120, (r.top - wr.top) / k + 22);
    await sleep(500); if (!live() || !S.ctx) return; ctx.querySelector('[data-act=cside]')?.classList.add('hot');
    await sleep(1100); if (!live()) return;
    closeCtx(); startSplit(t.id); if (!S.pinSide) { S.side = false; apply(); }
    await sleep(2200); if (!live() || !S.split) return; focusSplit('b');
    await sleep(2200); if (!live() || !S.split) return; focusSplit('a');
  } else if (key === 'reader') {
    if (S.split) endSplit(true);
    if (S.reader) { S.reader = false; renderReader(); renderTop(); renderSidebar(); apply(); syncChips(); return; }
    const t = isArticle() ? cur() : article(); if (t) selectTab(t.id);
    peek('top', 1600); await sleep(700); if (!live()) return;
    S.reader = true; renderReader(); renderTop(); renderSidebar(); apply(); syncChips();
  } else if (key === 'dusk') {
    if (S.duskSetting) { setDuskSetting(false); return; }
    S.reader = false; renderReader();
    if (page().dark || !isArticle()) { const t = prof().tabs.find(x => PAGES[x.page].kind === 'article' && !PAGES[x.page].dark); if (t) selectTab(t.id); }
    setDuskSetting(true); peek('top', 2600);
  } else if (key === 'save') {
    S.reader = false; renderReader(); syncChips();
    const t = prof().tabs.find(x => PAGES[x.page].media); if (t) selectTab(t.id); else return;
    await sleep(500); if (!live()) return; pageIn.scrollTop = 0; $('#media')?.classList.add('hov');
  }
}
function clearAll() { closeCtx(); if (S.omni) closeOmni(); ['side','top'].forEach(k => { cancel(k,'show'); cancel(k,'hide'); }); S.side = false; S.top = false; S.menu = false; $('#media')?.classList.remove('hov'); toastEl.classList.remove('open'); }
$('#chips').addEventListener('click', e => { const b = e.target.closest('[data-preset]'); if (b) preset(b.dataset.preset); });
$$('[data-mode]').forEach(b => b.addEventListener('click', () => { runId++; S.mode = b.dataset.mode; S.menu = false; bump(); renderTop(); renderSidebar(); apply(); caption(S.mode === 'full' ? 'full' : 'window'); if (S.layout === 'both') peek('top', 2600); }));
$$('[data-layout]').forEach(b => b.addEventListener('click', () => { runId++; S.layout = b.dataset.layout; bump(); if (S.layout === 'side') S.pinTop = false; renderTop(); renderSidebar(); apply(); caption(S.layout === 'side' ? 'side' : 'both'); peek(S.layout === 'side' ? 'side' : 'top', 2400); }));
$('#swSide').addEventListener('change', e => { S.pinSide = e.target.checked; S.side = false; bump(); renderSidebar(); apply(); });
$('#swTop').addEventListener('change', e => { S.pinTop = e.target.checked; S.top = false; bump(); apply(); });
$('#swSlow').addEventListener('change', e => { root.style.setProperty('--slow', e.target.checked ? 4 : 1); });

/* ------------------------------------------------------------------ */
/* Scale the 1710 x 1112 screen to whatever width it is given          */
/* ------------------------------------------------------------------ */
const wrap = $('#screenWrap');
function fit() { const k = wrap.clientWidth / 1710; screen.style.setProperty('--k', k); }
new ResizeObserver(fit).observe(wrap); fit();
// on a phone the laptop is wider than the screen: start in the middle of it
(() => { const sc = $('.stage-scroll'); const mid = () => { if (sc.scrollWidth > sc.clientWidth) sc.scrollLeft = (sc.scrollWidth - sc.clientWidth) / 2; }; mid(); addEventListener('load', mid); })();

/* Wallpaper, drawn in the page's own hue */
$('#wall').innerHTML = `<defs>
 <linearGradient id="wb" x1="0" y1="0" x2="1" y2="1"><stop offset="0" style="stop-color:oklch(.46 .06 calc(var(--h) - 20))"/><stop offset=".55" style="stop-color:oklch(.6 .07 var(--h))"/><stop offset="1" style="stop-color:oklch(.78 .07 calc(var(--h) + 40))"/></linearGradient>
 <radialGradient id="wr1" cx=".25" cy=".2" r=".6"><stop offset="0" style="stop-color:oklch(.9 .06 calc(var(--h) + 50) / .8)"/><stop offset="1" style="stop-color:oklch(.9 .06 calc(var(--h) + 50) / 0)"/></radialGradient>
 <radialGradient id="wr2" cx=".85" cy=".8" r=".55"><stop offset="0" style="stop-color:oklch(.4 .06 calc(var(--h) - 40) / .75)"/><stop offset="1" style="stop-color:oklch(.4 .06 calc(var(--h) - 40) / 0)"/></radialGradient>
 <linearGradient id="wr3" x1="0" y1="0" x2="1" y2="0"><stop offset="0" style="stop-color:oklch(.93 .04 calc(var(--h) + 20) / 0)"/><stop offset=".5" style="stop-color:oklch(.93 .04 calc(var(--h) + 20) / .45)"/><stop offset="1" style="stop-color:oklch(.93 .04 calc(var(--h) + 20) / 0)"/></linearGradient></defs>
 <rect width="1710" height="1112" fill="url(#wb)"/><rect width="1710" height="1112" fill="url(#wr1)"/><rect width="1710" height="1112" fill="url(#wr2)"/>
 <path d="M-100 760C260 560 520 900 900 700s640-260 980-60V1112H-100Z" style="fill:oklch(.5 .06 calc(var(--h) - 10) / .5)"/>
 <path d="M-100 880C300 740 640 1020 1000 860s520-160 810-30V1112H-100Z" style="fill:oklch(.4 .055 calc(var(--h) - 20) / .55)"/>
 <path d="M-100 330C300 150 700 470 1100 270S1600 60 1900 220" fill="none" stroke="url(#wr3)" stroke-width="130"/>`;

/* The clock in the menu bar and beside the notch */
function clockTick() { const d = new Date(), hm = d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' }), wd = d.toLocaleDateString('en-GB', { weekday: 'short' }); $('#clock').textContent = hm; $('#menuClock').textContent = `${wd} ${hm}`; }
clockTick(); setInterval(clockTick, 20000);

/* ------------------------------------------------------------------ */
/* The site                                                            */
/* ------------------------------------------------------------------ */
function syncSiteDots() {
  const pd = $('#profdots');
  if (pd) pd.innerHTML = `<span class="lbl">Profile</span>` + PROFILES.map((p, i) => `<button style="background:${COLORS[p.color]}" data-site-prof="${i}" aria-pressed="${i === S.p || (S.split && i === S.split.r)}" aria-label="${p.name} profile"></button>`).join('') + `<span class="pn">${S.split ? PROFILES[S.p].name + ' + ' + PROFILES[S.split.r].name : PROFILES[S.p].name}</span>`;
}
syncSiteDots();
document.addEventListener('click', e => { const b = e.target.closest('[data-site-prof]'); if (b) setProfile(+b.dataset.siteProf); });

// where the disc looks, shared with the light: the crescent (and the light that leaks) is on the far side
const look = { x: 0, y: 0 };

// the hero's light: moonlight through a dark room. It is the light that gets past the dark disc: where the crescent opens, light pours
// out in soft wide lobes; where the disc covers the light, little does. Move the disc and the light moves with it. A fragment shader
// draws it at the screen's own resolution (no rays, a lit haze with a few broad shafts in it); dust hangs in the same light, and the
// pointer is a torch for it.
(() => {
  const hero = $('.hero'), cv = $('#dots'), sh = $('#shafts'), eye = $('#eye'), g = cv.getContext('2d');
  const gl = sh.getContext('webgl', { premultipliedAlpha: true, alpha: true, antialias: false });
  let W = 0, H = 0, dpr = 1, sdpr = 1, mx = -999, my = -999, on = true, raf = 0, last = 0, t0 = performance.now();
  const TAU = 6.2832, mqDark = matchMedia('(prefers-color-scheme: dark)');
  const rnd = (() => { let a = 20261107; return () => { a = (a + 0x6D2B79F5) >>> 0; let t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; })();
  // broad lobes of light round the disc: where, how wide (radians) and how strong; they drift slowly
  const N = 9, lobes = Array.from({ length: N }, (_, i) => ({ a: (i / N) * TAU + (rnd() - .5) * .5, w: .1 + rnd() * .17, s: .55 + rnd() * .45, sw: rnd() * TAU, sp: .02 + rnd() * .04 }));
  const lobeData = new Float32Array(N * 3);
  let motes = [];
  const seed = () => { motes = Array.from({ length: Math.round(Math.min(300, Math.max(110, W * H / 4300))) }, () => ({ x: rnd() * W, y: rnd() * H, vx: (rnd() - .4) * 5, vy: -2 - rnd() * 6, r: .6 + rnd() * 1.7, p: rnd() * TAU, f: .5 + rnd() * 1.3 })); };
  // the light itself, on the GPU
  let prog = null, U = {};
  if (gl) {
    const compile = (type, src) => { const x = gl.createShader(type); gl.shaderSource(x, src); gl.compileShader(x); if (gl.getShaderParameter(x, gl.COMPILE_STATUS)) return x; console.warn('light shader:', gl.getShaderInfoLog(x)); return null; };
    const vs = compile(gl.VERTEX_SHADER, 'attribute vec2 q; void main(){ gl_Position = vec4(q, 0., 1.); }');
    const fs = compile(gl.FRAGMENT_SHADER, `precision highp float;
      uniform vec2 res, c, off; uniform float dpr, R, Rd, L, t, gain; uniform vec3 col; uniform vec3 lobe[${N}];
      float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
      void main() {
        vec2 p = vec2(gl_FragCoord.x, res.y - gl_FragCoord.y) / dpr, v = p - c;
        float r = length(v); if (r < R * .9) { gl_FragColor = vec4(0.); return; }   // under the disc there is only the disc
        vec2 u = v / r; float th = atan(v.y, v.x);
        // how much light gets past the dark disc along this direction
        float s = dot(off, u), perp = off.x * u.y - off.y * u.x, h = Rd * Rd - perp * perp;
        float far = h > 0. ? s + sqrt(h) : 0.;
        float vis = smoothstep(0., R * .55, max(R - far, 0.));
        float ang = 0.;
        for (int i = 0; i < ${N}; i++) { float d = abs(mod(th - lobe[i].x + 3.14159, 6.28318) - 3.14159); ang += lobe[i].z * exp(-(d * d) / (lobe[i].y * lobe[i].y)); }
        ang = .06 + .94 * min(ang, 1.25);
        float streak = .8 + .2 * sin(th * 11. + t * .12 + r * .0025);
        float out_ = max(r - R * .92, 0.);
        float fall = exp(-out_ / L);
        float I = (.04 + .96 * vis) * ang * streak * fall * 1.8;
        I += .3 * exp(-out_ / (R * .25)) * (.2 + .8 * vis);
        I *= gain; I = min(I, .92);
        I += (hash(gl_FragCoord.xy + t) - .5) / 255.;
        gl_FragColor = vec4(col * I, I);
      }`);
    prog = gl.createProgram(); gl.attachShader(prog, vs); gl.attachShader(prog, fs); gl.linkProgram(prog);
    if (!vs || !fs || !gl.getProgramParameter(prog, gl.LINK_STATUS)) { if (vs && fs) console.warn('light shader link:', gl.getProgramInfoLog(prog)); prog = null; }
    else {
      gl.useProgram(prog); const b = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, b);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
      const q = gl.getAttribLocation(prog, 'q'); gl.enableVertexAttribArray(q); gl.vertexAttribPointer(q, 2, gl.FLOAT, false, 0, 0);
      for (const n of ['res', 'c', 'off', 'dpr', 'R', 'Rd', 'L', 't', 'gain', 'col', 'lobe']) U[n] = gl.getUniformLocation(prog, n);
    }
  }
  const size = () => {
    const r = cv.getBoundingClientRect(); dpr = Math.min(2, devicePixelRatio || 1); W = r.width; H = r.height;
    cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr);
    // the light is smooth, so it is drawn at one pixel per CSS pixel and the browser stretches it: a quarter of the work on a sharp screen
    sdpr = Math.min(1, dpr); sh.width = Math.round(W * sdpr); sh.height = Math.round(H * sdpr);
    g.setTransform(dpr, 0, 0, dpr, 0, 0); if (prog) gl.viewport(0, 0, sh.width, sh.height); seed();
  };
  // the colour of the light as the shader wants it
  // (a colour the page wrote in oklch comes back as oklch: a 1 px canvas turns it into red, green and blue)
  const px = document.createElement('canvas'); px.width = px.height = 1; const pg = px.getContext('2d', { willReadFrequently: true });
  let seenCss = '', seenRgb = [1, .8, .5];
  const rgb = css => { if (css !== seenCss) { seenCss = css; pg.clearRect(0, 0, 1, 1); pg.fillStyle = css; pg.fillRect(0, 0, 1, 1); const d = pg.getImageData(0, 0, 1, 1).data; seenRgb = [d[0] / 255, d[1] / 255, d[2] / 255]; } return seenRgb; };
  let geo = null;
  const draw = (t, dt) => {
    g.clearRect(0, 0, W, H);
    const cssCol = getComputedStyle(cv).color, e = eye.getBoundingClientRect(), r0 = cv.getBoundingClientRect();
    const k = e.width / 400, gain = mqDark.matches && document.documentElement.dataset.theme !== 'light' ? 1 : .42;
    // the two discs, as the drawing has them: the light at 188, the dark one at 214 plus where it has been moved to
    const c = { x: e.left - r0.left + e.width / 2 + (188 - 200) * k, y: e.top - r0.top + e.height / 2 };
    const off = { x: (26 + look.x) * k, y: look.y * k }, R = 150 * k, Rd = 136 * k, L = Math.hypot(W, H) * .4;
    geo = { c, off, R, Rd };
    lobes.forEach((b, i) => { lobeData[i * 3] = b.a + t * b.sp * .6 + Math.sin(t * .07 + b.sw) * .08; lobeData[i * 3 + 1] = b.w; lobeData[i * 3 + 2] = b.s; });
    if (prog) {
      gl.clearColor(0, 0, 0, 0); gl.clear(gl.COLOR_BUFFER_BIT);
      gl.uniform2f(U.res, sh.width, sh.height); gl.uniform2f(U.c, c.x, c.y); gl.uniform2f(U.off, off.x, off.y); gl.uniform1f(U.dpr, sdpr);
      gl.uniform1f(U.R, R); gl.uniform1f(U.Rd, Rd); gl.uniform1f(U.L, L); gl.uniform1f(U.t, t); gl.uniform1f(U.gain, gain);
      gl.uniform3fv(U.col, rgb(cssCol)); gl.uniform3fv(U.lobe, lobeData); gl.drawArrays(gl.TRIANGLES, 0, 3);
    }
    // the same light, in numbers, for the dust
    const light = (th, r) => {
      const ux = Math.cos(th), uy = Math.sin(th), s = off.x * ux + off.y * uy, perp = off.x * uy - off.y * ux, h = Rd * Rd - perp * perp;
      const far = h > 0 ? s + Math.sqrt(h) : 0, x = Math.max(R - far, 0) / (R * .55), vis = Math.min(1, x) * Math.min(1, x) * (3 - 2 * Math.min(1, x));
      let a = 0; for (let i = 0; i < N; i++) { const d = Math.abs(((th - lobeData[i * 3] + Math.PI) % TAU + TAU) % TAU - Math.PI); a += lobeData[i * 3 + 2] * Math.exp(-(d * d) / (lobeData[i * 3 + 1] ** 2)); }
      return (.04 + .96 * vis) * (.06 + .94 * Math.min(a, 1.25)) * 1.8 * Math.exp(-Math.max(r - R * .92, 0) / L);
    };
    g.save(); g.fillStyle = cssCol;
    for (const m of motes) {
      const dx = m.x - mx, dy = m.y - my, dd = dx * dx + dy * dy;
      let torch = 0;
      if (dd < 40000) {
        const d = Math.sqrt(dd) || 1;
        if (d > 46) { const pull = (1 - d / 200) * 16 * dt; m.x -= dx / d * pull; m.y -= dy / d * pull; }
        else { const push = (1 - d / 46) * 90 * dt; m.x += dx / d * push; m.y += dy / d * push; }
        torch = Math.pow(1 - d / 200, 2);
      }
      m.x += (m.vx + Math.sin(t * .3 + m.p) * 2) * dt; m.y += m.vy * dt;
      if (m.y < -6) { m.y = H + 6; m.x = rnd() * W; } if (m.x < -6) m.x = W + 6; if (m.x > W + 6) m.x = -6;
      const ax = m.x - c.x, ay = m.y - c.y, dist = Math.hypot(ax, ay), tw = .6 + .4 * Math.sin(t * m.f + m.p);
      const seen = dist > R * .9 ? light(Math.atan2(ay, ax), dist) : 0;
      const a = Math.min(.95, (seen * 1.5 + torch * .85) * tw * (gain < 1 ? 1.4 : 1));
      if (a < .03) continue;
      g.globalAlpha = a; g.beginPath(); g.arc(m.x, m.y, m.r * (1 + torch * .6), 0, TAU); g.fill();
    }
    g.restore();
  };
  const frame = now => { raf = 0; if (!on) return; const dt = Math.min(.1, (now - last) / 1000 || .033); if (now - last > 30) { last = now; draw((now - t0) / 1000, dt); } raf = requestAnimationFrame(frame); };
  const start = () => { if (!raf && on && !reduce) raf = requestAnimationFrame(frame); };
  size(); draw(9, 0);
  new ResizeObserver(() => { size(); draw((performance.now() - t0) / 1000, 0); }).observe(cv);
  hero.addEventListener('pointermove', e => { const r = cv.getBoundingClientRect(); mx = e.clientX - r.left; my = e.clientY - r.top; });
  hero.addEventListener('pointerleave', () => { mx = my = -999; });
  new IntersectionObserver(es => { on = es[0].isIntersecting && !document.hidden; start(); }).observe(hero);
  document.addEventListener('visibilitychange', () => { on = !document.hidden; start(); });
  start();
})();

// the disc looks at the pointer: it slides toward it inside the light, leaving the crescent on the far side
(() => {
  const eye = $('#eye'), iris = $('#iris'), hero = $('.hero');
  const MAX = 38; let tx = 0, ty = 0, x = 0, y = 0, raf = 0, seen = true;
  const draw = () => iris.setAttribute('transform', `translate(${x.toFixed(2)} ${y.toFixed(2)})`);
  const tick = () => { raf = 0; x += (tx - x) * .14; y += (ty - y) * .14; look.x = x; look.y = y; draw(); if (Math.hypot(tx - x, ty - y) > .04 && seen) raf = requestAnimationFrame(tick); };
  const aim = (px, py) => {
    const r = eye.getBoundingClientRect(), dx = px - (r.left + r.width / 2), dy = py - (r.top + r.height / 2), d = Math.hypot(dx, dy) || 1, k = Math.min(1, d / (r.width * .8));
    tx = dx / d * MAX * k; ty = dy / d * MAX * k;
    if (!raf && seen && !reduce) raf = requestAnimationFrame(tick);
  };
  addEventListener('pointermove', e => aim(e.clientX, e.clientY), { passive: true });
  document.addEventListener('pointerleave', () => { tx = 0; ty = 0; if (!raf && !reduce) raf = requestAnimationFrame(tick); });
  new IntersectionObserver(es => { seen = es[0].isIntersecting; }).observe(hero);
})();

// reveal on scroll
const io = new IntersectionObserver(es => es.forEach(e => { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } }), { rootMargin: '0px 0px -8% 0px', threshold: .08 });
$$('.reveal').forEach(el => io.observe(el));

// the section in view, in the nav
const spyTargets = [...new Set($$('[data-spy]').map(a => a.dataset.spy))].map(id => document.getElementById(id)).filter(Boolean);
const spy = new IntersectionObserver(es => es.forEach(e => { if (e.isIntersecting) $$('[data-spy]').forEach(a => a.classList.toggle('on', a.dataset.spy === e.target.id)); }), { rootMargin: '-45% 0px -50% 0px' });
spyTargets.forEach(t => spy.observe(t));

// the feature index: search and parts
(() => {
  const groups = $$('.fgroup'), input = $('#finder'), nav = $('#gnav'), none = $('#none'); let part = 'all';
  nav.innerHTML = `<button data-g="all" aria-pressed="true">Everything</button>` + groups.map(g => `<button data-g="${g.dataset.group}" aria-pressed="false">${esc(g.dataset.title)}</button>`).join('');
  const run = () => {
    const q = input.value.trim().toLowerCase().split(/\s+/).filter(Boolean); let any = false;
    groups.forEach(g => {
      let n = 0;
      $$('.frow', g).forEach(r => { const ok = q.every(w => (r.textContent + ' ' + g.dataset.title).toLowerCase().includes(w)); r.hidden = !ok; if (ok) n++; });
      const show = n > 0 && (part === 'all' || g.dataset.group === part); g.hidden = !show; if (show) any = true;
    });
    none.hidden = any;
  };
  input.addEventListener('input', run);
  nav.addEventListener('click', e => { const b = e.target.closest('[data-g]'); if (!b) return; part = b.dataset.g; $$('button', nav).forEach(x => x.setAttribute('aria-pressed', x === b)); run(); });
  $('#clearFind').addEventListener('click', () => { input.value = ''; part = 'all'; $$('button', nav).forEach((x, i) => x.setAttribute('aria-pressed', i === 0)); run(); });
})();

// the agent example plays once when it is seen
(() => {
  const demo = $('#agentDemo'), items = $$('#agentLog li'); let playing = false;
  const play = async () => {
    if (playing) return; playing = true; items.forEach(li => li.classList.remove('on')); demo.classList.remove('work'); $('.ask .y', demo).classList.remove('press');
    await sleep(500); items[0].classList.add('on');
    await sleep(900); demo.classList.add('asking'); await sleep(2300); $('.ask .y', demo).classList.add('press'); await sleep(450);
    demo.classList.remove('asking'); demo.classList.add('work');
    for (const li of items.slice(1)) { await sleep(750); li.classList.add('on'); }
    await sleep(2600); demo.classList.remove('work'); playing = false;
  };
  new IntersectionObserver((es, o) => es.forEach(e => { if (e.isIntersecting) { play(); } }), { threshold: .55 }).observe(demo);
  demo.addEventListener('click', play);
})();

/* ------------------------------------------------------------------ */
/* Start                                                               */
/* ------------------------------------------------------------------ */
renderPage(false); fullRender(); renderDl(); caption('start'); syncChips();
// the first time the laptop is seen, show where the edges are
new IntersectionObserver((es, o) => es.forEach(async e => {
  if (!e.isIntersecting || S.touched) return; o.disconnect();
  await sleep(900); if (S.touched || reduce) return;
  S.side = true; apply(); await sleep(1500); if (S.touched) { return; } S.side = false; apply();
}), { threshold: .6 }).observe($('#laptop'));
})();
